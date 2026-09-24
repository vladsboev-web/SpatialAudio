import Foundation
import CoreAudio
import Combine

public func debugLog(_ message: String) {
    #if DEBUG
    print("[SpatialAudio] \(message)")
    #endif
}

public final class AudioCoordinator: ObservableObject {
    public static let shared = AudioCoordinator()
    
    private let leftRingBuffer = AudioRingBuffer(capacityPowerOfTwo: 15)
    private let rightRingBuffer = AudioRingBuffer(capacityPowerOfTwo: 15)
    
    private lazy var captureUnit = AudioCaptureUnit(leftRingBuffer: leftRingBuffer, rightRingBuffer: rightRingBuffer)
    private lazy var spatialEngine = SpatialEngine(leftRingBuffer: leftRingBuffer, rightRingBuffer: rightRingBuffer)
    
    private var isApplyingProfile: Bool = false
    
    @Published public var isSpatialEnabled: Bool = true {
        didSet {
            spatialEngine.isSpatialEnabled = isSpatialEnabled
            saveActiveProfileSettings()
        }
    }
    
    @Published public var speakerAngleDeg: Double = 30.0 {
        didSet {
            spatialEngine.speakerAngleDeg = Float(speakerAngleDeg)
            saveActiveProfileSettings()
        }
    }
    
    @Published public var distance: Double = 1.0 {
        didSet {
            spatialEngine.distance = Float(distance)
            saveActiveProfileSettings()
        }
    }
    
    @Published public var reverbBlend: Double = 0.01 { // 1% легкой естественной акустики (диапазон 0-3%)
        didSet {
            spatialEngine.reverbBlend = Float(reverbBlend)
            saveActiveProfileSettings()
        }
    }
    
    @Published public var volume: Double = 1.0 {
        didSet {
            spatialEngine.volume = Float(volume)
            saveActiveProfileSettings()
        }
    }
    
    @Published public var gainMultiplier: Double = 1.25 {
        didSet {
            spatialEngine.gainMultiplier = Float(gainMultiplier)
            saveActiveProfileSettings()
        }
    }
    
    @Published public var inputDevices: [AudioDevice] = []
    @Published public var outputDevices: [AudioDevice] = []
    @Published public var selectedInputDeviceID: AudioDeviceID = 0
    @Published public var selectedOutputDeviceID: AudioDeviceID = 0 {
        didSet {
            if selectedOutputDeviceID != 0 && selectedOutputDeviceID != oldValue {
                if let dev = AudioDeviceHelper.getDevice(id: selectedOutputDeviceID), !dev.isVirtual && dev.hasOutput {
                    savedSystemDefaultOutputDeviceID = selectedOutputDeviceID
                }
            }
        }
    }
    
    @Published public var isRunning: Bool = false
    @Published public var isBlackHoleInstalled: Bool = false
    @Published public var statusMessage: String = "Готов к запуску"
    
    @Published public var leftLevel: Float = 0.0
    @Published public var rightLevel: Float = 0.0
    
    public var isUIVisible: Bool = false {
        didSet {
            if isUIVisible {
                startLevelTimer()
            } else {
                stopLevelTimer()
            }
        }
    }
    
    private var levelTimer: Timer?
    private var savedSystemDefaultOutputDeviceID: AudioDeviceID?
    private var pendingTargetSystemDefaultID: AudioDeviceID?
    
    private init() {
        if let currentProfile = ProfileManager.shared.activeProfile {
            applyProfile(currentProfile)
        }
        refreshDevices(preserveUserSelection: false)
        
        // Синхронизируем выход с текущим активным физическим устройством в macOS
        if let currentDef = AudioDeviceHelper.getDefaultOutputDeviceID(),
           let dev = AudioDeviceHelper.getDevice(id: currentDef),
           !dev.isVirtual && dev.hasOutput {
            self.savedSystemDefaultOutputDeviceID = currentDef
            self.selectedOutputDeviceID = currentDef
        }
        
        setupHardwareListeners()
        
        // Если в системе уже выбран BlackHole — сразу автоматически запускаем
        if let currentDef = AudioDeviceHelper.getDefaultOutputDeviceID(),
           let bh = AudioDeviceHelper.findBlackHoleDevice(),
           currentDef == bh.id {
            AudioDeviceHelper.setDeviceVolume(deviceID: bh.id, volume: 1.0)
            startPipeline(routeSystemAudio: false)
        }
    }
    
    // MARK: - Управление профилями (Синхронизация)
    
    private func saveActiveProfileSettings() {
        guard !isApplyingProfile else { return }
        ProfileManager.shared.updateActiveProfileSettings(
            isSpatialEnabled: isSpatialEnabled,
            speakerAngleDeg: speakerAngleDeg,
            distance: distance,
            reverbBlend: reverbBlend,
            volume: volume,
            gainMultiplier: gainMultiplier
        )
    }
    
    public func applyProfile(_ profile: SpatialProfile) {
        isApplyingProfile = true
        self.isSpatialEnabled = profile.isSpatialEnabled
        self.speakerAngleDeg = profile.speakerAngleDeg
        self.distance = profile.distance
        self.reverbBlend = min(0.03, max(0.0, profile.reverbBlend))
        self.volume = profile.volume
        self.gainMultiplier = profile.gainMultiplier
        isApplyingProfile = false
        
        ProfileManager.shared.selectProfile(id: profile.id)
    }
    
    // MARK: - CoreAudio Hardware Listeners (Горячее подключение наушников и системное переключение)
    
    private func setupHardwareListeners() {
        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddr,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.handleHardwareDevicesChanged()
        }
        
        var defaultOutAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutAddr,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.handleDefaultOutputDeviceChanged()
        }
    }
    
    private func handleHardwareDevicesChanged() {
        let oldDevices = self.outputDevices
        refreshDevices(preserveUserSelection: true)
        
        // 1. Проверяем, появились ли новые Bluetooth-наушники
        let newDevices = self.outputDevices.filter { newDev in
            !oldDevices.contains(where: { $0.id == newDev.id })
        }
        
        if let newlyConnectedBT = newDevices.first(where: { ($0.isBluetooth || $0.isHeadphones) && $0.hasOutput }) {
            print("[AudioCoordinator] Подключены новые наушники: \(newlyConnectedBT.name)")
            self.selectedOutputDeviceID = newlyConnectedBT.id
            if self.isRunning {
                self.startPipeline(routeSystemAudio: false)
            }
            return
        }
        
        // 2. Проверяем, отключились ли текущие наушники
        if !self.outputDevices.contains(where: { $0.id == self.selectedOutputDeviceID }) {
            print("[AudioCoordinator] Выбранное устройство вывода отключено")
            if let fallback = AudioDeviceHelper.findPreferredOutputDevice() {
                self.selectedOutputDeviceID = fallback.id
                if self.isRunning {
                    self.startPipeline(routeSystemAudio: false)
                }
            } else {
                self.stopPipeline(restoreSystemAudio: false)
            }
        }
    }
    
    private func handleDefaultOutputDeviceChanged() {
        guard let currentDefault = AudioDeviceHelper.getDefaultOutputDeviceID() else { return }
        debugLog("[AudioCoordinator] handleDefaultOutputDeviceChanged: currentDefault=\(currentDefault), pending=\(String(describing: pendingTargetSystemDefaultID)), isRunning=\(self.isRunning)")
        
        // Если мы сами инициировали системный переход — ждем целевого устройства
        if let pending = pendingTargetSystemDefaultID {
            if currentDefault == pending {
                debugLog("[AudioCoordinator] pending target \(pending) reached!")
                pendingTargetSystemDefaultID = nil
                
                let bh = AudioDeviceHelper.findBlackHoleDevice()
                if let bh = bh, currentDefault == bh.id {
                    debugLog("[AudioCoordinator] BlackHole готов в macOS -> даем 300 мс на стабилизацию")
                    statusMessage = "Подключение..."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self = self, !self.isRunning else { return }
                        if let cur = AudioDeviceHelper.getDefaultOutputDeviceID(), cur == bh.id {
                            self.startPipeline(routeSystemAudio: false)
                        }
                    }
                    return
                }
            } else {
                debugLog("[AudioCoordinator] waiting for pending target \(pending), ignoring intermediate \(currentDefault)")
                return
            }
        }
        
        let bh = AudioDeviceHelper.findBlackHoleDevice()
        
        if let bh = bh, currentDefault == bh.id {
            // 🟢 Сценарий 1: В системном меню macOS выбран BlackHole 2ch (вариант приложения)
            AudioDeviceHelper.setDeviceVolume(deviceID: bh.id, volume: 1.0)
            if !self.isRunning {
                debugLog("[AudioCoordinator] В macOS выбран BlackHole -> даем 300 мс на стабилизацию системных потоков")
                statusMessage = "Подключение..."
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self, !self.isRunning else { return }
                    if let cur = AudioDeviceHelper.getDefaultOutputDeviceID(), cur == bh.id {
                        debugLog("[AudioCoordinator] Старт пайплайна после стабилизации")
                        self.startPipeline(routeSystemAudio: false)
                    }
                }
            }
        } else {
            // ⏸ Сценарий 2: Пользователь явно выбрал в macOS другой источник (динамики, другие наушники и т.д.)
            if let nonVirtualDev = AudioDeviceHelper.getDevice(id: currentDefault), !nonVirtualDev.isVirtual && nonVirtualDev.hasOutput {
                self.savedSystemDefaultOutputDeviceID = currentDefault
                self.selectedOutputDeviceID = currentDefault
                debugLog("[AudioCoordinator] Запомнили физическое устройство вывода из macOS: \(nonVirtualDev.name) (\(currentDefault))")
            }
            if self.isRunning {
                let devName = AudioDeviceHelper.getDevice(id: currentDefault)?.name ?? "другое устройство"
                debugLog("[AudioCoordinator] В macOS выбран \(devName) -> приостановка приложения")
                self.pausePipeline()
                self.statusMessage = "Приостановлено (\(devName))"
            }
        }
    }
    
    // MARK: - Системная маршрутизация
    
    private func routeSystemSoundToBlackHole() {
        guard let bh = AudioDeviceHelper.findBlackHoleDevice() else { return }
        if let currentDef = AudioDeviceHelper.getDefaultOutputDeviceID(), currentDef != bh.id {
            if savedSystemDefaultOutputDeviceID == nil {
                savedSystemDefaultOutputDeviceID = currentDef
                debugLog("[AudioCoordinator] savedSystemDefaultOutputDeviceID = \(currentDef)")
            }
        }
        pendingTargetSystemDefaultID = bh.id
        debugLog("[AudioCoordinator] routeSystemSoundToBlackHole: setting default to \(bh.id)")
        AudioDeviceHelper.setDefaultOutputDevice(deviceID: bh.id)
        AudioDeviceHelper.setDeviceVolume(deviceID: bh.id, volume: 1.0)
        
        // Таймаут безопасности: запустить пайплайн через 0.8 сек, если системное событие задержалось
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self else { return }
            if self.pendingTargetSystemDefaultID == bh.id {
                debugLog("[AudioCoordinator] Safety timeout reached, starting pipeline")
                self.pendingTargetSystemDefaultID = nil
                self.startPipeline(routeSystemAudio: false)
            }
        }
    }
    
    private func restoreSystemSound() {
        let targetID: AudioDeviceID? = {
            if let saved = savedSystemDefaultOutputDeviceID,
               outputDevices.contains(where: { $0.id == saved && !$0.isVirtual }) {
                return saved
            }
            if outputDevices.contains(where: { $0.id == selectedOutputDeviceID && !$0.isVirtual }) {
                return selectedOutputDeviceID
            }
            return AudioDeviceHelper.findPreferredOutputDevice()?.id
        }()
        
        if let tid = targetID {
            debugLog("[AudioCoordinator] restoreSystemSound: setting default to \(tid)")
            pendingTargetSystemDefaultID = tid
            AudioDeviceHelper.setDefaultOutputDevice(deviceID: tid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if self?.pendingTargetSystemDefaultID == tid {
                    self?.pendingTargetSystemDefaultID = nil
                }
            }
        }
        savedSystemDefaultOutputDeviceID = nil
    }
    
    // MARK: - Управление списком устройств
    
    public func refreshDevices(preserveUserSelection: Bool = true) {
        let all = AudioDeviceHelper.getAllDevices()
        self.inputDevices = all.filter { $0.hasInput }
        self.outputDevices = all.filter { $0.hasOutput && !$0.isVirtual }
        
        let bh = AudioDeviceHelper.findBlackHoleDevice()
        self.isBlackHoleInstalled = (bh != nil)
        
        // Вход: сохраняем выбор пользователя, если он актуален
        if !preserveUserSelection || !inputDevices.contains(where: { $0.id == selectedInputDeviceID }) {
            if let bh = bh {
                self.selectedInputDeviceID = bh.id
            } else if let firstIn = inputDevices.first {
                self.selectedInputDeviceID = firstIn.id
            }
        }
        
        // Выход: сохраняем выбор пользователя, если он актуален
        if !preserveUserSelection || !outputDevices.contains(where: { $0.id == selectedOutputDeviceID }) {
            if let prefOut = AudioDeviceHelper.findPreferredOutputDevice() {
                self.selectedOutputDeviceID = prefOut.id
            } else if let firstOut = outputDevices.first {
                self.selectedOutputDeviceID = firstOut.id
            }
        }
        debugLog("[AudioCoordinator] refreshDevices: inID=\(selectedInputDeviceID), outID=\(selectedOutputDeviceID)")
    }
    
    // MARK: - Пайплайн обработки звука
    
    private func stopAudioUnitsOnly() {
        stopLevelTimer()
        captureUnit.stop()
        spatialEngine.stop()
        leftLevel = 0.0
        rightLevel = 0.0
    }
    
    public func pausePipeline() {
        debugLog("[AudioCoordinator] pausePipeline called")
        stopAudioUnitsOnly()
        isRunning = false
    }
    
    public func startPipeline(routeSystemAudio: Bool = true) {
        debugLog("[AudioCoordinator] startPipeline(routeSystemAudio: \(routeSystemAudio))")
        stopAudioUnitsOnly()
        refreshDevices(preserveUserSelection: true)
        
        // 1. Определяем устройства
        let inDev = (AudioDeviceHelper.getDevice(id: selectedInputDeviceID)?.hasInput == true ? AudioDeviceHelper.getDevice(id: selectedInputDeviceID) : nil)
            ?? AudioDeviceHelper.findBlackHoleDevice()
            ?? inputDevices.first
        
        let outDev = (AudioDeviceHelper.getDevice(id: selectedOutputDeviceID)?.hasOutput == true && AudioDeviceHelper.getDevice(id: selectedOutputDeviceID)?.isVirtual == false ? AudioDeviceHelper.getDevice(id: selectedOutputDeviceID) : nil)
            ?? AudioDeviceHelper.findPreferredOutputDevice()
            ?? outputDevices.first
        
        guard let inDev = inDev, let outDev = outDev else {
            debugLog("[AudioCoordinator] Error: Devices not found!")
            statusMessage = "Устройства не найдены"
            return
        }
        
        self.selectedInputDeviceID = inDev.id
        self.selectedOutputDeviceID = outDev.id
        debugLog("[AudioCoordinator] Using inDev: \(inDev.name) (\(inDev.id)), outDev: \(outDev.name) (\(outDev.id))")
        
        // 2. Направляем системный звук macOS в BlackHole, если требуется
        if routeSystemAudio {
            let currentDef = AudioDeviceHelper.getDefaultOutputDeviceID()
            if let bh = AudioDeviceHelper.findBlackHoleDevice(), currentDef != bh.id {
                debugLog("[AudioCoordinator] Current default is not BlackHole, initiating routing...")
                routeSystemSoundToBlackHole()
                statusMessage = "Подключение к аудиосистеме..."
                return
            }
        }
        
        let sampleRate = outDev.sampleRate > 0 ? outDev.sampleRate : 44100.0
        debugLog("[AudioCoordinator] SampleRate: \(sampleRate)")
        
        // 3. Синхронизируем частоту BlackHole с наушниками
        AudioDeviceHelper.setSampleRate(deviceID: inDev.id, rate: sampleRate)
        
        leftRingBuffer.reset()
        rightRingBuffer.reset()
        
        // 5. Настройка Spatial Engine
        guard spatialEngine.setup(outputDeviceID: outDev.id, sampleRate: sampleRate) else {
            debugLog("[AudioCoordinator] Error: spatialEngine.setup failed!")
            statusMessage = "Ошибка вывода на \(outDev.name)"
            return
        }
        
        // 6. Настройка захвата
        guard captureUnit.setup(deviceID: inDev.id, sampleRate: sampleRate) else {
            debugLog("[AudioCoordinator] Error: captureUnit.setup failed!")
            statusMessage = "Ошибка захвата с \(inDev.name)"
            return
        }
        
        guard captureUnit.start() else {
            debugLog("[AudioCoordinator] Error: captureUnit.start failed!")
            statusMessage = "Не удалось запустить захват"
            return
        }
        
        guard spatialEngine.start() else {
            debugLog("[AudioCoordinator] Error: spatialEngine.start failed!")
            captureUnit.stop()
            statusMessage = "Не удалось запустить вывод"
            return
        }
        
        isRunning = true
        statusMessage = "Spatial Audio: \(outDev.name)"
        debugLog("[AudioCoordinator] startPipeline SUCCESS! isRunning=true")
        
        if isUIVisible {
            startLevelTimer()
        }
    }
    
    public func stopPipeline(restoreSystemAudio: Bool = true) {
        pausePipeline()
        
        if restoreSystemAudio {
            restoreSystemSound()
        }
        
        statusMessage = "Остановлено"
    }
    
    public func restartPipeline() {
        if isRunning {
            startPipeline(routeSystemAudio: false)
        }
    }
    
    private func startLevelTimer() {
        guard levelTimer == nil, isRunning else { return }
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.leftLevel = self.captureUnit.peakLevelL
            self.rightLevel = self.captureUnit.peakLevelR
        }
    }
    
    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        leftLevel = 0.0
        rightLevel = 0.0
    }
}
