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
    
    @Published public var inputDevices: [AudioDevice] = []
    @Published public var outputDevices: [AudioDevice] = []
    @Published public var selectedInputDeviceID: AudioDeviceID = 0
    @Published public var selectedOutputDeviceID: AudioDeviceID = 0 {
        didSet {
            if selectedOutputDeviceID != 0 && selectedOutputDeviceID != oldValue {
                if let dev = AudioDeviceHelper.getDevice(id: selectedOutputDeviceID), !dev.isVirtual && dev.hasOutput {
                    savedSystemDefaultOutputDeviceID = selectedOutputDeviceID
                    syncSessionVolumeToOutputs(volume: currentSessionVolume)
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
    private var currentSessionVolume: Float32 = 0.5
    private var blackHoleVolumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var monitoredBlackHoleID: AudioDeviceID?
    private var deviceChangeDebounceWorkItem: DispatchWorkItem?
    private var previousOutputDeviceID: AudioDeviceID?
    private var isConnectingHeadphones: Bool = false
    
    private init() {
        if let currentProfile = ProfileManager.shared.activeProfile {
            applyProfile(currentProfile)
        }
        refreshDevices(preserveUserSelection: false)
        
        // Синхронизируем выход с текущим активным физическим устройством в macOS
        if let currentDef = AudioDeviceHelper.getDefaultOutputDeviceID(),
           let dev = AudioDeviceHelper.getDevice(id: currentDef) {
            if !dev.isVirtual && dev.hasOutput {
                self.savedSystemDefaultOutputDeviceID = currentDef
                self.selectedOutputDeviceID = currentDef
                if let vol = AudioDeviceHelper.getDeviceVolume(deviceID: currentDef) {
                    self.currentSessionVolume = vol
                }
            } else if dev.isVirtual {
                // Если при запуске уже выбран BlackHole — читаем его текущую громкость и выбираем физический выход
                if let vol = AudioDeviceHelper.getDeviceVolume(deviceID: currentDef) {
                    self.currentSessionVolume = vol
                }
                if let pref = AudioDeviceHelper.findPreferredOutputDevice() {
                    self.selectedOutputDeviceID = pref.id
                    self.savedSystemDefaultOutputDeviceID = pref.id
                }
            }
        }
        
        setupHardwareListeners()
        
        // Если в системе уже выбран BlackHole — сразу автоматически запускаем
        if let currentDef = AudioDeviceHelper.getDefaultOutputDeviceID(),
           let bh = AudioDeviceHelper.findBlackHoleDevice(),
           currentDef == bh.id {
            startPipeline(routeSystemAudio: false)
        }
    }
    
    // MARK: - Управление профилями (Синхронизация)
    
    private func saveActiveProfileSettings() {
        guard !isApplyingProfile else { return }
        ProfileManager.shared.updateActiveProfileSettings(
            isSpatialEnabled: isSpatialEnabled,
            speakerAngleDeg: speakerAngleDeg,
            reverbBlend: reverbBlend,
            volume: volume
        )
    }
    
    public func applyProfile(_ profile: SpatialProfile) {
        isApplyingProfile = true
        self.isSpatialEnabled = profile.isSpatialEnabled
        self.speakerAngleDeg = profile.speakerAngleDeg
        self.reverbBlend = min(0.03, max(0.0, profile.reverbBlend))
        self.volume = profile.volume
        isApplyingProfile = false
        
        ProfileManager.shared.selectProfile(id: profile.id)
    }
    
    // MARK: - Мониторинг системной громкости через BlackHole
    
    public func syncSessionVolumeToOutputs(volume: Float32) {
        self.currentSessionVolume = volume
        let devID = self.selectedOutputDeviceID
        guard devID != 0 else { return }
        
        let supportsHwVolume = AudioDeviceHelper.isVolumeSettable(deviceID: devID)
        if supportsHwVolume {
            if isRunning {
                // Архитектура Single Attenuation (Unity Gain 1:1):
                // Системный аудиопоток уже ослаблен нативным CoreAudio на входе в BlackHole по заводской кривой macOS.
                // Физический ЦАП наушников/динамиков удерживается на 1.0 (Full Scale / 0 dB / Unity),
                // что полностью исключает двойное/квадратичное затухание (V^2) и сохраняет естественную системную шкалу.
                // При нулевой громкости или заглушении (Mute) выставляем 0.0 для абсолютной тишины.
                let hwVolume: Float32 = (volume > 0.001) ? 1.0 : 0.0
                AudioDeviceHelper.setDeviceVolume(deviceID: devID, volume: hwVolume)
            } else {
                // Когда пайплайн остановлен или на паузе — устанавливаем реальную громкость сессии
                AudioDeviceHelper.setDeviceVolume(deviceID: devID, volume: volume)
            }
        }
    }
    
    public func currentOutputDeviceName() -> String {
        return AudioDeviceHelper.getDevice(id: selectedOutputDeviceID)?.name ?? "Наушники"
    }
    
    private func startMonitoringBlackHoleVolume(bhID: AudioDeviceID) {
        stopMonitoringBlackHoleVolume()
        monitoredBlackHoleID = bhID
        
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            let isMuted = AudioDeviceHelper.isDeviceMuted(deviceID: bhID)
            if let vol = AudioDeviceHelper.getDeviceVolume(deviceID: bhID) {
                let effectiveVol: Float32 = isMuted ? 0.0 : vol
                DispatchQueue.main.async {
                    self.syncSessionVolumeToOutputs(volume: effectiveVol)
                    let pct = Int(round(vol * 100))
                    if isMuted {
                        self.statusMessage = "Spatial Audio: \(self.currentOutputDeviceName()) (Заглушено)"
                    } else {
                        self.statusMessage = "Spatial Audio: \(self.currentOutputDeviceName()) (\(pct)%)"
                    }
                    debugLog("[AudioCoordinator] Системная громкость BlackHole -> \(vol) (\(pct)%), muted=\(isMuted)")
                }
            }
        }
        self.blackHoleVolumeListenerBlock = block
        
        // 1. VirtualMainVolume (основной селектор macOS для изменения громкости клавишами F11/F12)
        var addrVMVC = AudioObjectPropertyAddress(
            mSelector: AudioDeviceHelper.kVirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(bhID, &addrVMVC) {
            AudioObjectAddPropertyListenerBlock(bhID, &addrVMVC, DispatchQueue.main, block)
        }
        
        // 2. VolumeScalar на Main
        var addrMain = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(bhID, &addrMain) {
            AudioObjectAddPropertyListenerBlock(bhID, &addrMain, DispatchQueue.main, block)
        }
        
        // 3. VolumeScalar на Ch1
        var addrCh1 = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 1
        )
        if AudioObjectHasProperty(bhID, &addrCh1) {
            AudioObjectAddPropertyListenerBlock(bhID, &addrCh1, DispatchQueue.main, block)
        }
        
        // 4. Mute на выходе BlackHole (клавиша F10)
        var addrMute = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(bhID, &addrMute) {
            AudioObjectAddPropertyListenerBlock(bhID, &addrMute, DispatchQueue.main, block)
        }
    }
    
    private func stopMonitoringBlackHoleVolume() {
        guard let bhID = monitoredBlackHoleID, let block = blackHoleVolumeListenerBlock else { return }
        
        var addrVMVC = AudioObjectPropertyAddress(
            mSelector: AudioDeviceHelper.kVirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(bhID, &addrVMVC) {
            AudioObjectRemovePropertyListenerBlock(bhID, &addrVMVC, DispatchQueue.main, block)
        }
        
        var addrMain = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(bhID, &addrMain) {
            AudioObjectRemovePropertyListenerBlock(bhID, &addrMain, DispatchQueue.main, block)
        }
        
        var addrCh1 = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 1
        )
        if AudioObjectHasProperty(bhID, &addrCh1) {
            AudioObjectRemovePropertyListenerBlock(bhID, &addrCh1, DispatchQueue.main, block)
        }
        
        var addrMute = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(bhID, &addrMute) {
            AudioObjectRemovePropertyListenerBlock(bhID, &addrMute, DispatchQueue.main, block)
        }
        
        self.blackHoleVolumeListenerBlock = nil
        self.monitoredBlackHoleID = nil
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
        
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            debugLog("[AudioCoordinator] AVAudioEngineConfigurationChange received, restarting pipeline")
            self.spatialEngine.resetEngine()
            self.startPipeline(routeSystemAudio: false)
        }
    }
    
    private func handleHardwareDevicesChanged() {
        // Быстрая предварительная проверка: появились ли новые наушники/Bluetooth с выходом звука
        let allDevs = AudioDeviceHelper.getAllDevices()
        let currentOuts = allDevs.filter { $0.hasOutput && !$0.isVirtual && !$0.isInternalAggregate }
        let newOuts = currentOuts.filter { newDev in !self.outputDevices.contains(where: { $0.id == newDev.id }) }
        
        if let newHeadphones = newOuts.first(where: { ($0.isBluetooth || $0.isHeadphones) && $0.hasOutput }) {
            debugLog("[AudioCoordinator] Pre-detected connecting headphones: \(newHeadphones.name) (\(newHeadphones.id))")
            self.isConnectingHeadphones = true
            // Защитный таймаут сброса флага на случай сбоя соединения
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.isConnectingHeadphones = false
            }
        }
        
        // Устраняем дребезг (debounce 500 мс) для завершения Bluetooth handshake в macOS
        deviceChangeDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.performHardwareDevicesChanged()
        }
        deviceChangeDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
    
    private func performHardwareDevicesChanged() {
        defer {
            self.isConnectingHeadphones = false
        }
        
        let oldDevices = self.outputDevices
        refreshDevices(preserveUserSelection: false)
        
        // 1. Проверяем, появились ли новые Bluetooth-наушники или гарнитура
        let newDevices = self.outputDevices.filter { newDev in
            !oldDevices.contains(where: { $0.id == newDev.id })
        }
        
        if let newlyConnectedBT = newDevices.first(where: { ($0.isBluetooth || $0.isHeadphones) && $0.hasOutput }) {
            debugLog("[AudioCoordinator] Подключены новые наушники: \(newlyConnectedBT.name) (\(newlyConnectedBT.id))")
            
            // Сохраняем физическое устройство, которое было активно ДО подключения этих наушников
            if self.selectedOutputDeviceID != 0 && self.selectedOutputDeviceID != newlyConnectedBT.id {
                if let curDev = AudioDeviceHelper.getDevice(id: self.selectedOutputDeviceID), !curDev.isVirtual {
                    self.previousOutputDeviceID = self.selectedOutputDeviceID
                    debugLog("[AudioCoordinator] Запомнили предыдущее устройство до наушников: \(curDev.name) (\(self.selectedOutputDeviceID))")
                }
            }
            
            self.selectedOutputDeviceID = newlyConnectedBT.id
            self.savedSystemDefaultOutputDeviceID = newlyConnectedBT.id
            
            // Применяем системную громкость к новым наушникам
            syncSessionVolumeToOutputs(volume: self.currentSessionVolume)
            if let bh = AudioDeviceHelper.findBlackHoleDevice() {
                AudioDeviceHelper.setDeviceVolume(deviceID: bh.id, volume: self.currentSessionVolume)
                if AudioDeviceHelper.getDefaultOutputDeviceID() != bh.id {
                    AudioDeviceHelper.setDefaultOutputDevice(deviceID: bh.id)
                }
            }
            
            if self.isRunning {
                self.spatialEngine.resetEngine()
                self.startPipeline(routeSystemAudio: false)
            }
            return
        }
        
        // 2. Проверяем, отключились ли текущие наушники / устройство вывода
        if !self.outputDevices.contains(where: { $0.id == self.selectedOutputDeviceID }) {
            debugLog("[AudioCoordinator] Выбранное устройство вывода отключено (\(self.selectedOutputDeviceID))")
            
            // Приоритет возврата:
            // 1. Устройство, которое использовалось ДО наушников (например, внешняя колонка или другое BT устройство)
            // 2. Preferred устройство (встроенные динамики и т.д.)
            var fallbackDev: AudioDevice? = nil
            if let prevID = self.previousOutputDeviceID,
               let prevDev = self.outputDevices.first(where: { $0.id == prevID }) {
                fallbackDev = prevDev
                debugLog("[AudioCoordinator] Возврат на источник до наушников: \(prevDev.name) (\(prevDev.id))")
            } else {
                fallbackDev = AudioDeviceHelper.findPreferredOutputDevice()
                debugLog("[AudioCoordinator] Предыдущий источник недоступен, возврат на preferred: \(fallbackDev?.name ?? "none")")
            }
            
            if let fallback = fallbackDev {
                self.selectedOutputDeviceID = fallback.id
                self.savedSystemDefaultOutputDeviceID = fallback.id
                self.previousOutputDeviceID = nil // Сбрасываем, так как уже вернулись
                
                // Применяем системную громкость к fallback устройству
                syncSessionVolumeToOutputs(volume: self.currentSessionVolume)
                if let bh = AudioDeviceHelper.findBlackHoleDevice() {
                    AudioDeviceHelper.setDeviceVolume(deviceID: bh.id, volume: self.currentSessionVolume)
                    if AudioDeviceHelper.getDefaultOutputDeviceID() != bh.id {
                        AudioDeviceHelper.setDefaultOutputDevice(deviceID: bh.id)
                    }
                }
                
                if self.isRunning {
                    self.spatialEngine.resetEngine()
                    self.startPipeline(routeSystemAudio: false)
                }
            } else {
                self.stopPipeline(restoreSystemAudio: false)
            }
        }
    }
    
    private func handleDefaultOutputDeviceChanged() {
        guard let currentDefault = AudioDeviceHelper.getDefaultOutputDeviceID() else { return }
        debugLog("[AudioCoordinator] handleDefaultOutputDeviceChanged: currentDefault=\(currentDefault), pending=\(String(describing: pendingTargetSystemDefaultID)), isConnectingHeadphones=\(isConnectingHeadphones), isRunning=\(self.isRunning)")
        
        // 1. Если сейчас идет физическое подключение новых наушников в HAL — не ставим на паузу, ждем завершения handshake
        if isConnectingHeadphones {
            debugLog("[AudioCoordinator] handleDefaultOutputDeviceChanged: подключение наушников в процессе, игнорируем переход на \(currentDefault)")
            return
        }
        
        // 2. Если мы сами программно инициировали переход на BlackHole при старте
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
                // Если пользователь выбрал другое устройство во время ожидания — сбрасываем pending
                pendingTargetSystemDefaultID = nil
            }
        }
        
        let bh = AudioDeviceHelper.findBlackHoleDevice()
        
        // 3. Проверяем текущее системное устройство
        if let bh = bh, currentDefault == bh.id {
            // 🟢 Сценарий 1: В системном меню macOS выбран BlackHole 2ch (запуск приложения пользователем)
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
            // ⏸ Сценарий 2: Пользователь явно выбрал в системном меню macOS другой источник (динамики, другие наушники и т.д.)
            if self.isRunning {
                stopMonitoringBlackHoleVolume()
                if let bh = AudioDeviceHelper.findBlackHoleDevice(),
                   let currentBhVol = AudioDeviceHelper.getDeviceVolume(deviceID: bh.id) {
                    self.currentSessionVolume = currentBhVol
                }
                // Восстанавливаем актуальную громкость на устройствах вывода
                if self.selectedOutputDeviceID != 0 {
                    AudioDeviceHelper.setDeviceVolume(deviceID: self.selectedOutputDeviceID, volume: self.currentSessionVolume)
                }
                AudioDeviceHelper.setDeviceVolume(deviceID: currentDefault, volume: self.currentSessionVolume)
                
                let devName = AudioDeviceHelper.getDevice(id: currentDefault)?.name ?? "другое устройство"
                debugLog("[AudioCoordinator] В macOS выбран \(devName) -> пауза пайплайна")
                self.pausePipeline()
                self.statusMessage = "Приостановлено (\(devName))"
            }
            if let nonVirtualDev = AudioDeviceHelper.getDevice(id: currentDefault), !nonVirtualDev.isVirtual && nonVirtualDev.hasOutput {
                self.savedSystemDefaultOutputDeviceID = currentDefault
                self.selectedOutputDeviceID = currentDefault
                if let v = AudioDeviceHelper.getDeviceVolume(deviceID: currentDefault) {
                    self.currentSessionVolume = v
                }
                debugLog("[AudioCoordinator] Запомнили физическое устройство вывода из macOS: \(nonVirtualDev.name) (\(currentDefault)) с vol=\(self.currentSessionVolume)")
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
            // Считываем физическую громкость устройства до переключения:
            if let currentPhysVol = AudioDeviceHelper.getDeviceVolume(deviceID: currentDef) {
                currentSessionVolume = currentPhysVol
                debugLog("[AudioCoordinator] routeSystemSoundToBlackHole: pre-sync session volume: \(currentSessionVolume)")
            }
        }
        
        // Синхронизируем BlackHole с актуальной системной громкостью
        AudioDeviceHelper.setDeviceVolume(deviceID: bh.id, volume: currentSessionVolume)
        startMonitoringBlackHoleVolume(bhID: bh.id)
        
        pendingTargetSystemDefaultID = bh.id
        debugLog("[AudioCoordinator] routeSystemSoundToBlackHole: setting default to \(bh.id) with vol=\(currentSessionVolume)")
        AudioDeviceHelper.setDefaultOutputDevice(deviceID: bh.id)
        
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
            AudioDeviceHelper.setDeviceVolume(deviceID: tid, volume: currentSessionVolume)
            AudioDeviceHelper.setDefaultOutputDevice(deviceID: tid)
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
        if selectedOutputDeviceID != 0 {
            AudioDeviceHelper.setDeviceVolume(deviceID: selectedOutputDeviceID, volume: currentSessionVolume)
        }
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
        
        // 7. Архитектура Single Attenuation (Unity Gain 1:1):
        // BlackHole синхронизируется с текущей громкостью сессии (для системных F11/F12):
        AudioDeviceHelper.setDeviceVolume(deviceID: inDev.id, volume: currentSessionVolume)
        
        isRunning = true
        syncSessionVolumeToOutputs(volume: currentSessionVolume)
        startMonitoringBlackHoleVolume(bhID: inDev.id)
        debugLog("[AudioCoordinator] Volume setup: BlackHole=\(currentSessionVolume), outDev(\(outDev.name)) Unity Gain 1.0")
        
        let isMuted = AudioDeviceHelper.isDeviceMuted(deviceID: inDev.id)
        let pct = Int(round(currentSessionVolume * 100))
        if isMuted {
            statusMessage = "Spatial Audio: \(outDev.name) (Заглушено)"
        } else {
            statusMessage = "Spatial Audio: \(outDev.name) (\(pct)%)"
        }
        debugLog("[AudioCoordinator] startPipeline SUCCESS! isRunning=true")
        
        if isUIVisible {
            startLevelTimer()
        }
    }
    
    public func stopPipeline(restoreSystemAudio: Bool = true) {
        pausePipeline()
        stopMonitoringBlackHoleVolume()
        
        // Считываем актуальную громкость BlackHole
        if let bh = AudioDeviceHelper.findBlackHoleDevice(),
           let currentBhVol = AudioDeviceHelper.getDeviceVolume(deviceID: bh.id) {
            currentSessionVolume = currentBhVol
        }
        
        // Восстанавливаем эту громкость физическому устройству ДО переключения
        AudioDeviceHelper.setDeviceVolume(deviceID: selectedOutputDeviceID, volume: currentSessionVolume)
        debugLog("[AudioCoordinator] Restoring physical device \(selectedOutputDeviceID) volume to: \(currentSessionVolume)")
        
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
    
    public func toggle() {
        if isRunning {
            stopPipeline()
        } else {
            startPipeline()
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
