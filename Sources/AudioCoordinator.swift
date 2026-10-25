import Foundation
import CoreAudio
import AVFoundation
import Combine

public func debugLog(_ message: String) {
    print("[SpatialAudio] \(message)")
    fflush(stdout)
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
    @Published public var selectedOutputDeviceID: AudioDeviceID = 0
    
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
    private var engineConfigChangeDebounceWorkItem: DispatchWorkItem?
    private var previousOutputDeviceID: AudioDeviceID?
    private var lastKnownHardwareDeviceIDs: Set<AudioDeviceID> = []
    private var pendingConnectedHeadphonesID: AudioDeviceID?
    private var isConnectingHeadphones: Bool = false
    private var isHandlingDeviceDisconnection: Bool = false
    private var connectingHeadphonesResetWorkItem: DispatchWorkItem?
    private var disconnectingDeviceResetWorkItem: DispatchWorkItem?
    private var pipelineRetryWorkItem: DispatchWorkItem?
    private var safetyRoutingWorkItem: DispatchWorkItem?
    private var volumeReinforceWorkItems: [DispatchWorkItem] = []
    private var wasStreamingActive: Bool = false
    private var pipelineRetryCount: Int = 0
    
    private init() {
        if let currentProfile = ProfileManager.shared.activeProfile {
            applyProfile(currentProfile)
        }
        refreshDevices(preserveUserSelection: false)
        self.lastKnownHardwareDeviceIDs = Set(AudioDeviceHelper.getAllDevices().map { $0.id })
        
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
    
    // MARK: - Явный выбор устройств пользователем в UI
    
    public func selectInputDeviceByUser(_ newID: AudioDeviceID) {
        guard newID != 0 && newID != selectedInputDeviceID else { return }
        selectedInputDeviceID = newID
        if isRunning {
            restartPipeline()
        }
    }
    
    public func selectOutputDeviceByUser(_ newID: AudioDeviceID) {
        guard newID != 0 && newID != selectedOutputDeviceID else { return }
        let oldID = selectedOutputDeviceID
        if oldID != 0 {
            AudioDeviceHelper.setDeviceVolume(deviceID: oldID, volume: currentSessionVolume)
        }
        selectedOutputDeviceID = newID
        if let dev = AudioDeviceHelper.getDevice(id: newID), !dev.isVirtual && dev.hasOutput {
            savedSystemDefaultOutputDeviceID = newID
        }
        if isRunning {
            restartPipeline()
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
        if isRunning || pendingTargetSystemDefaultID != nil || isConnectingHeadphones || isHandlingDeviceDisconnection {
            let hwVolume: Float32 = (volume > 0.001) ? 1.0 : 0.0
            let currentDevVol = AudioDeviceHelper.getDeviceVolume(deviceID: devID)
            if currentDevVol == nil || abs((currentDevVol ?? 0) - hwVolume) > 0.01 {
                let applied = AudioDeviceHelper.setDeviceVolume(deviceID: devID, volume: hwVolume)
                debugLog("[AudioCoordinator] syncSessionVolumeToOutputs: active -> set devID=\(devID) to \(hwVolume), applied=\(applied)")
            }
        } else {
            let applied = AudioDeviceHelper.setDeviceVolume(deviceID: devID, volume: volume)
            debugLog("[AudioCoordinator] syncSessionVolumeToOutputs: inactive -> set devID=\(devID) to \(volume), applied=\(applied)")
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
    
    private func scheduleResetConnectingHeadphones(delay: TimeInterval) {
        connectingHeadphonesResetWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.isConnectingHeadphones = false
        }
        connectingHeadphonesResetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
    
    private func scheduleResetDisconnectingDevice(delay: TimeInterval) {
        disconnectingDeviceResetWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.isHandlingDeviceDisconnection = false
        }
        disconnectingDeviceResetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
    
    private func cancelVolumeReinforcement() {
        for item in volumeReinforceWorkItems {
            item.cancel()
        }
        volumeReinforceWorkItems.removeAll()
    }
    
    private func scheduleVolumeReinforcement(for deviceID: AudioDeviceID) {
        cancelVolumeReinforcement()
        for delay in [0.6, 1.2, 2.0] {
            let item = DispatchWorkItem { [weak self] in
                guard let self = self, self.isRunning, self.selectedOutputDeviceID == deviceID else { return }
                let hwVolume: Float32 = (self.currentSessionVolume > 0.001) ? 1.0 : 0.0
                AudioDeviceHelper.setDeviceVolume(deviceID: deviceID, volume: hwVolume)
            }
            volumeReinforceWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }
    
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
        ) { [weak self] notification in
            guard let self = self, self.isRunning else { return }
            // Игнорируем уведомления от старых или уже освобожденных экземпляров AVAudioEngine
            if let senderEngine = notification.object as? AVAudioEngine,
               senderEngine !== self.spatialEngine.currentEngine {
                return
            }
            if self.isConnectingHeadphones || self.isHandlingDeviceDisconnection || self.deviceChangeDebounceWorkItem != nil {
                debugLog("[AudioCoordinator] AVAudioEngineConfigurationChange ignored during hardware transition")
                return
            }
            self.engineConfigChangeDebounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.isRunning else { return }
                if self.isConnectingHeadphones || self.isHandlingDeviceDisconnection || self.deviceChangeDebounceWorkItem != nil {
                    return
                }
                debugLog("[AudioCoordinator] AVAudioEngineConfigurationChange executing restart")
                self.startPipeline(routeSystemAudio: false)
            }
            self.engineConfigChangeDebounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
        }
    }
    
    private func handleHardwareDevicesChanged() {
        let allDevs = AudioDeviceHelper.getAllDevices()
        let currentDeviceIDSet = Set(allDevs.map { $0.id })
        
        // Игнорируем ложные срабатывания от создания/удаления внутренних CADefaultDeviceAggregate,
        // если список реальных физических устройств не изменился и нет активного перехода
        if currentDeviceIDSet == self.lastKnownHardwareDeviceIDs &&
           self.pendingConnectedHeadphonesID == nil &&
           !self.isHandlingDeviceDisconnection {
            return
        }
        self.lastKnownHardwareDeviceIDs = currentDeviceIDSet
        
        let currentOuts = allDevs.filter { $0.hasOutput && !$0.isVirtual && !$0.isInternalAggregate }
        let newOuts = currentOuts.filter { newDev in !self.outputDevices.contains(where: { $0.id == newDev.id }) }
        let shouldKeepStreaming = self.isRunning || self.wasStreamingActive
        
        // 1. Быстрая предварительная проверка: появились ли новые наушники/Bluetooth с выходом звука
        if let newHeadphones = newOuts.first(where: { ($0.isBluetooth || $0.isHeadphones) && $0.hasOutput }) {
            debugLog("[AudioCoordinator] Pre-detected connecting headphones: \(newHeadphones.name) (\(newHeadphones.id))")
            self.isConnectingHeadphones = true
            self.pendingConnectedHeadphonesID = newHeadphones.id
            
            // Заблаговременно сохраняем предыдущее устройство до любых обновлений списков
            if self.selectedOutputDeviceID != 0 && self.selectedOutputDeviceID != newHeadphones.id {
                if let curDev = self.outputDevices.first(where: { $0.id == self.selectedOutputDeviceID }), !curDev.isVirtual {
                    self.previousOutputDeviceID = curDev.id
                    debugLog("[AudioCoordinator] Pre-saved previous device before headphones: \(curDev.name) (\(curDev.id))")
                }
            }
            
            // 🛡️ Защита от удара 100%: удерживаем BlackHole дефолтом, только если приложение было активно
            if shouldKeepStreaming, let bh = AudioDeviceHelper.findBlackHoleDevice() {
                AudioDeviceHelper.setDefaultOutputDevice(deviceID: bh.id)
            }
            
            scheduleResetConnectingHeadphones(delay: 2.5)
        }
        
        // 2. Быстрая предварительная проверка: отключилось ли текущее устройство вывода (наушники убраны в кейс)
        if self.selectedOutputDeviceID != 0 && !currentOuts.contains(where: { $0.id == self.selectedOutputDeviceID }) {
            debugLog("[AudioCoordinator] Pre-detected disconnection of current output device: \(self.selectedOutputDeviceID)")
            self.isHandlingDeviceDisconnection = true
            
            if shouldKeepStreaming, let bh = AudioDeviceHelper.findBlackHoleDevice() {
                AudioDeviceHelper.setDefaultOutputDevice(deviceID: bh.id)
            }
            
            scheduleResetDisconnectingDevice(delay: 2.0)
        }
        
        // Устраняем дребезг (debounce 500 мс) для завершения Bluetooth handshake в macOS
        deviceChangeDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.deviceChangeDebounceWorkItem = nil
            self.performHardwareDevicesChanged()
        }
        deviceChangeDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
    
    private func performHardwareDevicesChanged() {
        let oldDevices = self.outputDevices
        let oldSelectedOutputID = self.selectedOutputDeviceID
        
        // Обновляем списки устройств, сохраняя текущий выбор, чтобы не затереть oldSelectedOutputID раньше времени
        refreshDevices(preserveUserSelection: true)
        
        // 1. Проверяем, появились ли новые Bluetooth-наушники или гарнитура
        var newlyConnectedBT = self.outputDevices.first(where: { newDev in
            !oldDevices.contains(where: { $0.id == newDev.id }) && (newDev.isBluetooth || newDev.isHeadphones) && newDev.hasOutput
        })
        if newlyConnectedBT == nil, let pendingID = self.pendingConnectedHeadphonesID {
            newlyConnectedBT = self.outputDevices.first(where: { $0.id == pendingID })
        }
        self.pendingConnectedHeadphonesID = nil
        
        if let newlyConnectedBT = newlyConnectedBT {
            debugLog("[AudioCoordinator] Подключены новые наушники: \(newlyConnectedBT.name) (\(newlyConnectedBT.id))")
            
            // Сохраняем физическое устройство, которое было активно ДО подключения этих наушников, и возвращаем ему сессионную громкость
            if oldSelectedOutputID != 0 && oldSelectedOutputID != newlyConnectedBT.id {
                if let prevDev = oldDevices.first(where: { $0.id == oldSelectedOutputID }), !prevDev.isVirtual {
                    self.previousOutputDeviceID = prevDev.id
                    AudioDeviceHelper.setDeviceVolume(deviceID: prevDev.id, volume: self.currentSessionVolume)
                    debugLog("[AudioCoordinator] Запомнили предыдущее устройство до наушников: \(prevDev.name) (\(prevDev.id))")
                }
            }
            
            self.selectedOutputDeviceID = newlyConnectedBT.id
            self.savedSystemDefaultOutputDeviceID = newlyConnectedBT.id
            
            let shouldResume = self.isRunning || self.wasStreamingActive
            self.isRunning = false
            self.stopAudioUnitsOnly()
            
            if shouldResume {
                debugLog("[AudioCoordinator] Возобновляем воспроизведение на новых наушниках")
                self.pipelineRetryCount = 0
                self.startPipeline(routeSystemAudio: true)
                scheduleVolumeReinforcement(for: newlyConnectedBT.id)
            } else {
                self.isConnectingHeadphones = false
            }
            return
        }
        
        // 2. Проверяем, отключились ли текущие наушники / устройство вывода
        let didCurrentDisconnect = self.isHandlingDeviceDisconnection ||
            (oldSelectedOutputID != 0 && !self.outputDevices.contains(where: { $0.id == oldSelectedOutputID }))
        
        if didCurrentDisconnect {
            debugLog("[AudioCoordinator] Выбранное устройство вывода отключено (\(oldSelectedOutputID))")
            
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
                
                let shouldResume = self.isRunning || self.wasStreamingActive
                self.isRunning = false
                self.stopAudioUnitsOnly()
                
                if shouldResume {
                    if let bh = AudioDeviceHelper.findBlackHoleDevice() {
                        AudioDeviceHelper.setDefaultOutputDevice(deviceID: bh.id)
                    }
                    self.pipelineRetryCount = 0
                    self.startPipeline(routeSystemAudio: true)
                }
                scheduleResetDisconnectingDevice(delay: 0.5)
            } else {
                self.isHandlingDeviceDisconnection = false
                self.stopPipeline(restoreSystemAudio: false)
            }
        }
    }
    
    private func handleDefaultOutputDeviceChanged() {
        guard let currentDefault = AudioDeviceHelper.getDefaultOutputDeviceID() else { return }
        debugLog("[AudioCoordinator] handleDefaultOutputDeviceChanged: currentDefault=\(currentDefault), pending=\(String(describing: pendingTargetSystemDefaultID)), isConnectingHeadphones=\(isConnectingHeadphones), isDisconnecting=\(isHandlingDeviceDisconnection), isRunning=\(self.isRunning)")
        
        // 1. Если мы сами программно инициировали переход на BlackHole при старте — обрабатываем в первую очередь!
        if let pending = pendingTargetSystemDefaultID {
            if currentDefault == pending {
                debugLog("[AudioCoordinator] pending target \(pending) reached!")
                pendingTargetSystemDefaultID = nil
                safetyRoutingWorkItem?.cancel()
                safetyRoutingWorkItem = nil
                
                let bh = AudioDeviceHelper.findBlackHoleDevice()
                if let bh = bh, currentDefault == bh.id {
                    debugLog("[AudioCoordinator] BlackHole готов в macOS -> даем 200 мс на стабилизацию")
                    statusMessage = "Подключение..."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        guard let self = self, !self.isRunning else { return }
                        if let cur = AudioDeviceHelper.getDefaultOutputDeviceID(), cur == bh.id {
                            self.startPipeline(routeSystemAudio: false)
                        }
                    }
                    return
                }
            } else {
                // Если во время подключения/отключения наушников система временно перебросила дефолт — удерживаем BlackHole
                if (isConnectingHeadphones || isHandlingDeviceDisconnection),
                   let bh = AudioDeviceHelper.findBlackHoleDevice(),
                   pending == bh.id {
                    AudioDeviceHelper.setDefaultOutputDevice(deviceID: bh.id)
                    return
                }
                pendingTargetSystemDefaultID = nil
                safetyRoutingWorkItem?.cancel()
                safetyRoutingWorkItem = nil
            }
        }
        
        // 2. Если сейчас идет физическое подключение или отключение наушников в HAL — не ставим на паузу
        if isConnectingHeadphones || isHandlingDeviceDisconnection || deviceChangeDebounceWorkItem != nil {
            debugLog("[AudioCoordinator] handleDefaultOutputDeviceChanged: аппаратное переключение в процессе, игнорируем переход на \(currentDefault)")
            if (isRunning || wasStreamingActive),
               let bh = AudioDeviceHelper.findBlackHoleDevice(),
               currentDefault != bh.id {
                AudioDeviceHelper.setDefaultOutputDevice(deviceID: bh.id)
            }
            return
        }
        
        let bh = AudioDeviceHelper.findBlackHoleDevice()
        
        // 3. Проверяем текущее системное устройство
        if let bh = bh, currentDefault == bh.id {
            // 🟢 Сценарий 1: В системном меню macOS выбран BlackHole 2ch (запуск приложения пользователем)
            if !self.isRunning {
                debugLog("[AudioCoordinator] В macOS выбран BlackHole -> даем 200 мс на стабилизацию системных потоков")
                statusMessage = "Подключение..."
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self = self, !self.isRunning else { return }
                    if let cur = AudioDeviceHelper.getDefaultOutputDeviceID(), cur == bh.id {
                        debugLog("[AudioCoordinator] Старт пайплайна после стабилизации")
                        self.startPipeline(routeSystemAudio: false)
                    }
                }
            }
        } else {
            // Проверяем, не вызвано ли это событие подключением или отключением наушников,
            // которое пришло на несколько миллисекунд раньше kAudioHardwarePropertyDevices:
            let liveDevs = AudioDeviceHelper.getAllDevices().filter { $0.hasOutput && !$0.isVirtual && !$0.isInternalAggregate }
            
            // Проверка А: Текущее устройство вывода физически исчезло из системы (наушники отключились)
            if self.selectedOutputDeviceID != 0 && !liveDevs.contains(where: { $0.id == self.selectedOutputDeviceID }) {
                debugLog("[AudioCoordinator] handleDefaultOutputDeviceChanged: обнаружено физическое отключение \(self.selectedOutputDeviceID) до события списка устройств!")
                self.isHandlingDeviceDisconnection = true
                scheduleResetDisconnectingDevice(delay: 2.0)
                handleHardwareDevicesChanged()
                return
            }
            
            // Проверка Б: Новое дефолтное устройство — это только что подключенные наушники, которых еще не было в outputDevices
            if let newDefaultDev = liveDevs.first(where: { $0.id == currentDefault }),
               !self.outputDevices.contains(where: { $0.id == currentDefault }),
               (newDefaultDev.isBluetooth || newDefaultDev.isHeadphones) {
                debugLog("[AudioCoordinator] handleDefaultOutputDeviceChanged: обнаружено физическое подключение новых наушников \(newDefaultDev.name) до события списка устройств!")
                self.isConnectingHeadphones = true
                self.pendingConnectedHeadphonesID = newDefaultDev.id
                scheduleResetConnectingHeadphones(delay: 2.5)
                handleHardwareDevicesChanged()
                return
            }
            
            // ⏸ Сценарий 2: Пользователь явно выбрал в системном меню macOS другой существующий источник
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
                self.wasStreamingActive = false
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
        let currentDef = AudioDeviceHelper.getDefaultOutputDeviceID()
        if let currentDef = currentDef, currentDef == bh.id {
            debugLog("[AudioCoordinator] routeSystemSoundToBlackHole: BlackHole is already default, starting pipeline immediately")
            startMonitoringBlackHoleVolume(bhID: bh.id)
            self.startPipeline(routeSystemAudio: false)
            return
        }
        
        if let nonBhDef = currentDef, nonBhDef != bh.id {
            if savedSystemDefaultOutputDeviceID == nil {
                savedSystemDefaultOutputDeviceID = nonBhDef
                debugLog("[AudioCoordinator] savedSystemDefaultOutputDeviceID = \(nonBhDef)")
            }
            // Считываем физическую громкость устройства до переключения ТОЛЬКО при обычном ручном старте
            // (во время автоперехода на наушники не перезаписываем громкость сессии их аппаратным уровнем 1.0)
            if !isConnectingHeadphones && !isHandlingDeviceDisconnection {
                if let currentPhysVol = AudioDeviceHelper.getDeviceVolume(deviceID: nonBhDef) {
                    currentSessionVolume = currentPhysVol
                    debugLog("[AudioCoordinator] routeSystemSoundToBlackHole: pre-sync session volume: \(currentSessionVolume)")
                }
            }
        }
        
        // Синхронизируем BlackHole с актуальной системной громкостью ДО переключения
        pendingTargetSystemDefaultID = bh.id
        AudioDeviceHelper.setDeviceVolume(deviceID: bh.id, volume: currentSessionVolume)
        startMonitoringBlackHoleVolume(bhID: bh.id)
        
        debugLog("[AudioCoordinator] routeSystemSoundToBlackHole: setting default to \(bh.id) with vol=\(currentSessionVolume)")
        AudioDeviceHelper.setDefaultOutputDevice(deviceID: bh.id)
        
        // Раскрываем аппаратный усилитель наушников в 1.0 ПОСЛЕ переключения дефолта на BlackHole,
        // чтобы не было мгновенного удара 100% громкости прямого системного звука
        if let nonBhDef = currentDef, nonBhDef != bh.id {
            let hwVol: Float32 = (currentSessionVolume > 0.001) ? 1.0 : 0.0
            AudioDeviceHelper.setDeviceVolume(deviceID: nonBhDef, volume: hwVol)
            debugLog("[AudioCoordinator] routeSystemSoundToBlackHole: unlocked physical device \(nonBhDef) to \(hwVol) via AVRCP")
        }
        
        // Таймаут безопасности: запустить пайплайн через 0.6 сек, если системное событие задержалось
        safetyRoutingWorkItem?.cancel()
        let safetyItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.pendingTargetSystemDefaultID == bh.id {
                debugLog("[AudioCoordinator] Safety timeout reached, starting pipeline")
                self.pendingTargetSystemDefaultID = nil
                self.startPipeline(routeSystemAudio: false)
            }
        }
        safetyRoutingWorkItem = safetyItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: safetyItem)
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
        self.lastKnownHardwareDeviceIDs = Set(all.map { $0.id })
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
        pipelineRetryWorkItem?.cancel()
        pipelineRetryWorkItem = nil
        engineConfigChangeDebounceWorkItem?.cancel()
        engineConfigChangeDebounceWorkItem = nil
        cancelVolumeReinforcement()
        stopAudioUnitsOnly()
        isRunning = false
        if selectedOutputDeviceID != 0 {
            AudioDeviceHelper.setDeviceVolume(deviceID: selectedOutputDeviceID, volume: currentSessionVolume)
        }
    }
    
    public func startPipeline(routeSystemAudio: Bool = true) {
        debugLog("[AudioCoordinator] startPipeline(routeSystemAudio: \(routeSystemAudio))")
        pipelineRetryWorkItem?.cancel()
        pipelineRetryWorkItem = nil
        engineConfigChangeDebounceWorkItem?.cancel()
        engineConfigChangeDebounceWorkItem = nil
        
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
        
        let nominalRate = outDev.sampleRate > 0 ? outDev.sampleRate : 44100.0
        
        // 3. Настройка Spatial Engine (определяет фактическую аппаратную частоту выходного устройства)
        guard spatialEngine.setup(outputDeviceID: outDev.id, sampleRate: nominalRate) else {
            debugLog("[AudioCoordinator] Error: spatialEngine.setup failed!")
            handlePipelineFailure(outDev: outDev)
            return
        }
        
        let sampleRate = spatialEngine.sampleRate > 0 ? spatialEngine.sampleRate : nominalRate
        debugLog("[AudioCoordinator] SampleRate: \(sampleRate)")
        
        // 4. Синхронизируем частоту BlackHole с фактической частотой наушников
        AudioDeviceHelper.setSampleRate(deviceID: inDev.id, rate: sampleRate)
        
        leftRingBuffer.reset()
        rightRingBuffer.reset()
        
        // 5. Настройка захвата
        guard captureUnit.setup(deviceID: inDev.id, sampleRate: sampleRate) else {
            debugLog("[AudioCoordinator] Error: captureUnit.setup failed!")
            handlePipelineFailure(outDev: outDev)
            return
        }
        
        guard captureUnit.start() else {
            debugLog("[AudioCoordinator] Error: captureUnit.start failed!")
            handlePipelineFailure(outDev: outDev)
            return
        }
        
        guard spatialEngine.start() else {
            debugLog("[AudioCoordinator] Error: spatialEngine.start failed!")
            captureUnit.stop()
            handlePipelineFailure(outDev: outDev)
            return
        }
        
        // Обновляем снимок известных устройств, чтобы создание CADefaultDeviceAggregate внутри AVAudioEngine не вызвало ложный рестарт
        self.lastKnownHardwareDeviceIDs = Set(AudioDeviceHelper.getAllDevices().map { $0.id })
        
        // 6. Архитектура Single Attenuation (Unity Gain 1:1):
        // BlackHole синхронизируется с текущей громкостью сессии (для системных F11/F12):
        AudioDeviceHelper.setDeviceVolume(deviceID: inDev.id, volume: currentSessionVolume)
        
        isRunning = true
        wasStreamingActive = true
        pipelineRetryCount = 0
        syncSessionVolumeToOutputs(volume: currentSessionVolume)
        startMonitoringBlackHoleVolume(bhID: inDev.id)
        if let actualVol = AudioDeviceHelper.getDeviceVolume(deviceID: outDev.id) {
            debugLog("[AudioCoordinator] Single Attenuation setup: BlackHole=\(currentSessionVolume), outDev(\(outDev.name)) hardware volume=\(actualVol)")
        } else {
            debugLog("[AudioCoordinator] Single Attenuation setup: BlackHole=\(currentSessionVolume), outDev(\(outDev.name))=1.0")
        }
        
        let isMuted = AudioDeviceHelper.isDeviceMuted(deviceID: inDev.id)
        let pct = Int(round(currentSessionVolume * 100))
        if isMuted {
            statusMessage = "Spatial Audio: \(outDev.name) (Заглушено)"
        } else {
            statusMessage = "Spatial Audio: \(outDev.name) (\(pct)%)"
        }
        debugLog("[AudioCoordinator] startPipeline SUCCESS! isRunning=true")
        
        // Плавно снимаем флаги переходных процессов через единый управляемый таймер
        if isConnectingHeadphones {
            scheduleResetConnectingHeadphones(delay: 1.5)
        }
        if isHandlingDeviceDisconnection {
            scheduleResetDisconnectingDevice(delay: 0.5)
        }
        
        if isUIVisible {
            startLevelTimer()
        }
    }
    
    private func handlePipelineFailure(outDev: AudioDevice) {
        if pipelineRetryCount < 3 {
            pipelineRetryCount += 1
            debugLog("[AudioCoordinator] Ошибка старта на \(outDev.name), retry #\(pipelineRetryCount) через 0.6 сек...")
            statusMessage = "Подключение к \(outDev.name)..."
            pipelineRetryWorkItem?.cancel()
            let retryItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.pipelineRetryWorkItem = nil
                self.startPipeline(routeSystemAudio: false)
            }
            pipelineRetryWorkItem = retryItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: retryItem)
        } else {
            pipelineRetryCount = 0
            isConnectingHeadphones = false
            isHandlingDeviceDisconnection = false
            debugLog("[AudioCoordinator] Ошибка старта: превышен лимит попыток. Восстанавливаем системный звук.")
            statusMessage = "Ошибка вывода на \(outDev.name)"
            restoreSystemSound()
        }
    }
    
    public func stopPipeline(restoreSystemAudio: Bool = true) {
        wasStreamingActive = false
        pendingTargetSystemDefaultID = nil
        safetyRoutingWorkItem?.cancel()
        safetyRoutingWorkItem = nil
        // Считываем актуальную громкость BlackHole до остановки мониторинга
        if let bh = AudioDeviceHelper.findBlackHoleDevice(),
           let currentBhVol = AudioDeviceHelper.getDeviceVolume(deviceID: bh.id) {
            currentSessionVolume = currentBhVol
        }
        
        pausePipeline()
        stopMonitoringBlackHoleVolume()
        
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
