import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import Accelerate

/// Разводит один стерео-поток из кольцевого буфера на два пути рендера.
/// Все колбэки вызываются в одном IO-потоке AVAudioEngine, поэтому дополнительная синхронизация не нужна.
private final class StereoFeed {
    static let maxFrames = 8192

    let ring: AudioRingBuffer
    /// true — звук идёт прямым путём (bypass), false — через 3D-сцену
    var isBypass: Bool = false

    private let stashL = UnsafeMutablePointer<Float>.allocate(capacity: StereoFeed.maxFrames)
    private let stashR = UnsafeMutablePointer<Float>.allocate(capacity: StereoFeed.maxFrames)
    private let rampBuf = UnsafeMutablePointer<Float>.allocate(capacity: StereoFeed.maxFrames)
    private var stashFrames: Int = 0
    private var consumedL: Bool = true
    private var consumedR: Bool = true
    
    /// Масштаб громкости для компенсации ослабления BlackHole в Float32 до физического ЦАП
    var volumeScale: Float = 1.0
    private var currentScale: Float = 1.0

    init(ring: AudioRingBuffer) {
        self.ring = ring
        stashL.initialize(repeating: 0, count: StereoFeed.maxFrames)
        stashR.initialize(repeating: 0, count: StereoFeed.maxFrames)
        rampBuf.initialize(repeating: 0, count: StereoFeed.maxFrames)
    }

    deinit {
        stashL.deallocate()
        stashR.deallocate()
        rampBuf.deallocate()
    }
    
    private func applyScale(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let target = volumeScale
        if frames >= 2 && abs(currentScale - target) > 0.0001 {
            var start = currentScale
            var end = target
            vDSP_vgen(&start, &end, rampBuf, 1, vDSP_Length(frames))
            vDSP_vmul(left, 1, rampBuf, 1, left, 1, vDSP_Length(frames))
            vDSP_vmul(right, 1, rampBuf, 1, right, 1, vDSP_Length(frames))
            currentScale = target
        } else if abs(target - 1.0) > 0.0001 {
            var scale = target
            vDSP_vsmul(left, 1, &scale, left, 1, vDSP_Length(frames))
            vDSP_vsmul(right, 1, &scale, right, 1, vDSP_Length(frames))
            currentScale = target
        } else {
            currentScale = 1.0
        }
    }

    /// Моно-канал для 3D-источника. Пара L/R читается из кольцевого буфера одним вызовом
    /// и раздаётся двум моно-узлам — каналы остаются строго синхронными.
    func fetchMono(channel: Int, into dst: UnsafeMutablePointer<Float>, frames: Int) {
        guard !isBypass, frames <= StereoFeed.maxFrames else {
            vDSP_vclr(dst, 1, vDSP_Length(frames))
            return
        }
        let alreadyConsumed = (channel == 0) ? consumedL : consumedR
        if alreadyConsumed || frames != stashFrames {
            ring.read(left: stashL, right: stashR, count: frames)
            applyScale(left: stashL, right: stashR, frames: frames)
            stashFrames = frames
            consumedL = false
            consumedR = false
        }
        if channel == 0 {
            dst.update(from: stashL, count: frames)
            consumedL = true
        } else {
            dst.update(from: stashR, count: frames)
            consumedR = true
        }
    }

    /// Прямой стерео-путь (bypass): без 3D-сцены, без лимитера.
    func fetchStereo(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard isBypass else {
            vDSP_vclr(left, 1, vDSP_Length(frames))
            vDSP_vclr(right, 1, vDSP_Length(frames))
            return
        }
        ring.read(left: left, right: right, count: frames)
        applyScale(left: left, right: right, frames: frames)
        // При следующем переключении в 3D начинаем с чистого состояния
        consumedL = true
        consumedR = true
    }
}

public final class SpatialEngine {
    private var engine = AVAudioEngine()
    public var currentEngine: AVAudioEngine { engine }
    private var environment = AVAudioEnvironmentNode()
    private var limiterNode: AVAudioUnitEffect?
    
    private var leftSourceNode: AVAudioSourceNode?
    private var rightSourceNode: AVAudioSourceNode?
    private var bypassSourceNode: AVAudioSourceNode?
    
    private let feed: StereoFeed
    
    public private(set) var isRunning: Bool = false
    public private(set) var sampleRate: Double = 44100.0
    private var currentOutputDeviceID: AudioDeviceID?
    
    public private(set) var leftLevel: Float = 0.0
    public private(set) var rightLevel: Float = 0.0
    
    // MARK: - Настройки сцены
    public var isSpatialEnabled: Bool = true {
        didSet { updateAlgorithmAndPositions() }
    }
    
    public var speakerAngleDeg: Float = 30.0 { // 15° ... 60°
        didSet { updateAlgorithmAndPositions() }
    }
    
    public private(set) var distance: Float = 1.0 // Фиксированная оптимальная дистанция 1.0м
    
    public var reverbBlend: Float = 0.01 { // 0.0 ... 0.03 (акустика помещения)
        didSet { updateReverb() }
    }
    
    public var volume: Float = 1.0 {
        didSet { updateVolume() }
    }
    
    public var inputVolumeScale: Float = 1.0 {
        didSet {
            feed.volumeScale = inputVolumeScale
        }
    }
    
    /// Компенсация затухания HRTFHQ (+4 dB). Применяется ТОЛЬКО в 3D-цепочке через pre-gain лимитера,
    /// прямой путь (bypass) остаётся с единичным усилением.
    private let hrtfCompensationDB: Float = 4.0
    
    private func updateVolume() {
        // Главный микшер — общий для обоих путей; при volume = 1.0 это бит-в-бит прохождение
        engine.mainMixerNode.outputVolume = volume
    }
    
    private func updateReverb() {
        guard let left = leftSourceNode, let right = rightSourceNode else { return }
        // Акустика помещения: от 0.0 (абсолютно сухой звук) до 0.03 (естественная комната)
        let blendVal = isSpatialEnabled ? min(1.0, max(0.0, reverbBlend)) : 0.0
        left.reverbBlend = blendVal
        right.reverbBlend = blendVal
    }
    
    public init(ringBuffer: AudioRingBuffer) {
        self.feed = StereoFeed(ring: ringBuffer)
    }
    
    deinit {
        teardownCurrentGraph()
    }
    
    private func teardownCurrentGraph() {
        stop()
        engine.stop()
        for node in [leftSourceNode, rightSourceNode, bypassSourceNode] {
            if let node = node, node.engine != nil { engine.detach(node) }
        }
        leftSourceNode = nil
        rightSourceNode = nil
        bypassSourceNode = nil
        if let lim = limiterNode {
            if lim.engine != nil { engine.detach(lim) }
            limiterNode = nil
        }
        if environment.engine != nil {
            engine.detach(environment)
        }
        engine.reset()
    }
    
    /// Полный синхронный сброс графа и пересоздание AVAudioEngine без гонки потоков в CoreAudio HAL
    public func resetEngine() {
        teardownCurrentGraph()
        self.engine = AVAudioEngine()
        self.environment = AVAudioEnvironmentNode()
    }
    
    private func configureLimiter(_ limiter: AVAudioUnitEffect) {
        let au = limiter.audioUnit
        // Более плавное восстановление — меньше искажений на басу и «пампинга»
        AudioUnitSetParameter(au, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.007, 0)
        AudioUnitSetParameter(au, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.05, 0)
        AudioUnitSetParameter(au, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, hrtfCompensationDB, 0)
    }
    
    public func setup(outputDeviceID: AudioDeviceID, sampleRate: Double = 44100.0) -> Bool {
        resetEngine()
        
        self.currentOutputDeviceID = outputDeviceID
        
        // 1. Привязываем выход AVAudioEngine к выбранному устройству вывода (строго один раз)
        var deviceAssigned = false
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(outputDeviceID)
            deviceAssigned = true
        } catch {
            print("[SpatialEngine] auAudioUnit.setDeviceID предупреждение: \(error)")
        }
        
        if !deviceAssigned, let outputUnit = engine.outputNode.audioUnit {
            var devID = outputDeviceID
            let status = AudioUnitSetProperty(
                outputUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status == noErr {
                deviceAssigned = true
            } else {
                print("[SpatialEngine] Ошибка привязки устройства \(outputDeviceID): \(status)")
                return false
            }
        }
        
        var hwFormat = engine.outputNode.outputFormat(forBus: 0)
        if hwFormat.channelCount == 0 {
            // Быстрое ожидание готовности потока Bluetooth (до 150 мс с шагом 30 мс)
            for _ in 0..<5 {
                usleep(30_000)
                hwFormat = engine.outputNode.outputFormat(forBus: 0)
                if hwFormat.channelCount > 0 { break }
            }
        }
        guard hwFormat.channelCount > 0 else {
            print("[SpatialEngine] Выходной поток устройства \(outputDeviceID) ещё не готов (0 каналов)")
            return false
        }
        let actualRate = hwFormat.sampleRate > 0 ? hwFormat.sampleRate : sampleRate
        self.sampleRate = actualRate
        
        engine.attach(environment)
        
        // Отключаем физическое затухание расстояния:
        // Дистанция колонок меняет геометрию сцены, задержку и акустику, но уровень громкости не затухает!
        environment.distanceAttenuationParameters.rolloffFactor = 0.0
        
        // 2. Системный Peak Limiter от Apple — только для 3D-цепочки (страховка после +4 dB компенсации HRTF)
        let limiterDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let limiter = AVAudioUnitEffect(audioComponentDescription: limiterDesc)
        self.limiterNode = limiter
        engine.attach(limiter)
        configureLimiter(limiter)
        
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: actualRate, channels: 1),
              let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: actualRate, channels: 2) else {
            print("[SpatialEngine] Ошибка создания аудиоформатов")
            return false
        }
        
        let feed = self.feed
        
        // 3. Левый виртуальный источник (3D)
        let leftNode = AVAudioSourceNode(format: monoFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = abl[0].mData else { return noErr }
            feed.fetchMono(channel: 0, into: data.assumingMemoryBound(to: Float.self), frames: Int(frameCount))
            return noErr
        }
        
        // 4. Правый виртуальный источник (3D)
        let rightNode = AVAudioSourceNode(format: monoFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = abl[0].mData else { return noErr }
            feed.fetchMono(channel: 1, into: data.assumingMemoryBound(to: Float.self), frames: Int(frameCount))
            return noErr
        }
        
        // 5. Прямой стерео-источник (Bypass): мимо 3D-сцены и лимитера, единичное усиление
        let bypassNode = AVAudioSourceNode(format: stereoFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            feed.fetchStereo(left: l, right: r, frames: Int(frameCount))
            return noErr
        }
        
        self.leftSourceNode = leftNode
        self.rightSourceNode = rightNode
        self.bypassSourceNode = bypassNode
        
        engine.attach(leftNode)
        engine.attach(rightNode)
        engine.attach(bypassNode)
        
        // Цепочки обработки:
        //   3D:     L/R (моно) -> Окружение (HRTF) -> Peak Limiter (+4 dB pre-gain) -> Главный микшер -> Выход
        //   Bypass: Стерео -----------------------------------------------------> Главный микшер -> Выход
        engine.connect(leftNode, to: environment, format: monoFormat)
        engine.connect(rightNode, to: environment, format: monoFormat)
        engine.connect(environment, to: limiter, format: stereoFormat)
        engine.connect(limiter, to: engine.mainMixerNode, format: stereoFormat)
        engine.connect(bypassNode, to: engine.mainMixerNode, format: stereoFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: stereoFormat)
        
        // 6. Акустика комнаты (натуральная комната прослушивания)
        environment.reverbParameters.enable = true
        environment.reverbParameters.loadFactoryReverbPreset(.smallRoom)
        environment.reverbParameters.level = 0.0
        
        // 7. Позиция слушателя
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
        
        updateAlgorithmAndPositions()
        
        return true
    }
    
    public func updateAlgorithmAndPositions() {
        // Переключение пути рендера (атомарно для IO-потока: читается один Bool в начале колбэка)
        feed.isBypass = !isSpatialEnabled
        
        guard let left = leftSourceNode, let right = rightSourceNode else { return }
        
        // Настоящий Apple HRTFHQ алгоритм (в режиме Bypass 3D-источники просто получают тишину)
        left.renderingAlgorithm = .HRTFHQ
        right.renderingAlgorithm = .HRTFHQ
        
        let rad = speakerAngleDeg * .pi / 180.0
        let x = distance * sin(rad)
        let z = -distance * cos(rad)
        
        left.position = AVAudio3DPoint(x: -x, y: 0.0, z: z)
        right.position = AVAudio3DPoint(x: x, y: 0.0, z: z)
        
        updateReverb()
        updateVolume()
    }
    
    public func start() -> Bool {
        guard !isRunning else { return true }
        do {
            try engine.start()
            isRunning = true
            return true
        } catch {
            print("[SpatialEngine] Ошибка запуска AVAudioEngine: \(error)")
            return false
        }
    }
    
    public func stop() {
        guard isRunning else { return }
        engine.stop()
        isRunning = false
    }
}
