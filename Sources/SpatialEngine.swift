import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

public final class SpatialEngine {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private var limiterNode: AVAudioUnitEffect?
    
    private var leftSourceNode: AVAudioSourceNode?
    private var rightSourceNode: AVAudioSourceNode?
    
    private let leftRingBuffer: AudioRingBuffer
    private let rightRingBuffer: AudioRingBuffer
    
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
    
    public var distance: Float = 1.0 { // 0.5m ... 3.0m
        didSet { updateAlgorithmAndPositions() }
    }
    
    public var reverbBlend: Float = 0.01 { // 0.0 ... 0.03 (деликатная акустика помещения)
        didSet { updateReverb() }
    }
    
    public var gainMultiplier: Float = 1.25 { // Чистое усиление (+2 dB)
        didSet { updateVolume() }
    }
    
    public var volume: Float = 1.0 {
        didSet { updateVolume() }
    }
    
    // MARK: - Нормализация громкости
    private func updateVolume() {
        // Точная математическая компенсация закона затухания Apple SpatialMixer:
        // Для d <= 1.0 затухание 1.0. Для d > 1.0 затухание = 1.0 / distance.
        // Умножение на max(1.0, distance) делает громкость АБСОЛЮТНО ПОСТОЯННОЙ на любой дистанции!
        let distComp = max(1.0, distance)
        let effectiveVolume = isSpatialEnabled ? (volume * gainMultiplier * distComp) : volume
        engine.mainMixerNode.outputVolume = effectiveVolume
    }
    
    private func updateReverb() {
        guard let left = leftSourceNode, let right = rightSourceNode else { return }
        // Диапазон AVAudioNode.reverbBlend строго 0.0 (сухо) ... 1.0 (мокро)
        let blendVal = isSpatialEnabled ? min(1.0, max(0.0, reverbBlend)) : 0.0
        left.reverbBlend = blendVal
        right.reverbBlend = blendVal
    }
    
    public init(leftRingBuffer: AudioRingBuffer, rightRingBuffer: AudioRingBuffer) {
        self.leftRingBuffer = leftRingBuffer
        self.rightRingBuffer = rightRingBuffer
    }
    
    deinit {
        stop()
    }
    
    public func setup(outputDeviceID: AudioDeviceID, sampleRate: Double = 44100.0) -> Bool {
        stop()
        
        // Отсоединяем предыдущие временные ноды, если они были созданы
        if let left = leftSourceNode {
            engine.detach(left)
            leftSourceNode = nil
        }
        if let right = rightSourceNode {
            engine.detach(right)
            rightSourceNode = nil
        }
        if let lim = limiterNode {
            engine.detach(lim)
            limiterNode = nil
        }
        
        self.currentOutputDeviceID = outputDeviceID
        
        // 1. Привязываем выход AVAudioEngine к выбранному устройству вывода
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(outputDeviceID)
        } catch {
            print("[SpatialEngine] setDeviceID предупреждение: \(error)")
        }
        
        if let outputUnit = engine.outputNode.audioUnit {
            var devID = outputDeviceID
            _ = AudioUnitSetProperty(
                outputUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        
        let hwFormat = engine.outputNode.outputFormat(forBus: 0)
        let actualRate = hwFormat.sampleRate > 0 ? hwFormat.sampleRate : sampleRate
        self.sampleRate = actualRate
        
        if environment.engine == nil {
            engine.attach(environment)
        }
        
        // 2. Создаем системный Peak Limiter от Apple для исключения перегрузок и хрипов
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
        
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: actualRate, channels: 1),
              let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: actualRate, channels: 2) else {
            print("[SpatialEngine] Ошибка создания аудиоформатов")
            return false
        }
        
        let lRing = self.leftRingBuffer
        let rRing = self.rightRingBuffer
        
        // 3. Левый виртуальный источник
        let leftNode = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            guard let buffers = audioBufferList.pointee.mBuffers.mData else { return noErr }
            let ptr = buffers.assumingMemoryBound(to: Float.self)
            lRing.read(into: ptr, count: Int(frameCount))
            return noErr
        }
        
        // 4. Правый виртуальный источник
        let rightNode = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            guard let buffers = audioBufferList.pointee.mBuffers.mData else { return noErr }
            let ptr = buffers.assumingMemoryBound(to: Float.self)
            rRing.read(into: ptr, count: Int(frameCount))
            return noErr
        }
        
        self.leftSourceNode = leftNode
        self.rightSourceNode = rightNode
        
        engine.attach(leftNode)
        engine.attach(rightNode)
        
        engine.connect(leftNode, to: environment, format: monoFormat)
        engine.connect(rightNode, to: environment, format: monoFormat)
        
        // Цепочка обработки: Окружение -> PeakLimiter (защита от клиппинга) -> Главный микшер -> Выход
        engine.connect(environment, to: limiter, format: stereoFormat)
        engine.connect(limiter, to: engine.mainMixerNode, format: stereoFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: stereoFormat)
        
        // 5. Акустика комнаты (натуральная комната прослушивания)
        environment.reverbParameters.enable = true
        environment.reverbParameters.loadFactoryReverbPreset(.smallRoom)
        environment.reverbParameters.level = 0.0
        
        // 6. Позиция слушателя
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
        
        updateAlgorithmAndPositions()
        
        return true
    }
    
    public func updateAlgorithmAndPositions() {
        guard let left = leftSourceNode, let right = rightSourceNode else { return }
        
        if isSpatialEnabled {
            // Настоящий Apple HRTFHQ алгоритм
            left.renderingAlgorithm = .HRTFHQ
            right.renderingAlgorithm = .HRTFHQ
            
            let rad = speakerAngleDeg * .pi / 180.0
            let x = distance * sin(rad)
            let z = -distance * cos(rad)
            
            left.position = AVAudio3DPoint(x: -x, y: 0.0, z: z)
            right.position = AVAudio3DPoint(x: x, y: 0.0, z: z)
            
            left.pan = 0.0
            right.pan = 0.0
        } else {
            // Обычное стерео
            left.renderingAlgorithm = .equalPowerPanning
            right.renderingAlgorithm = .equalPowerPanning
            
            left.pan = -1.0
            right.pan = 1.0
        }
        
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
