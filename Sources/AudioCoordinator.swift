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
    
    private let ringBuffer = AudioRingBuffer(capacityPowerOfTwo: 15)
    
    private lazy var captureUnit = AudioCaptureUnit(ringBuffer: ringBuffer)
    private lazy var spatialEngine = SpatialEngine(ringBuffer: ringBuffer)
    
    private var isApplyingProfile: Bool = false
    private var profileSaveDebounceWorkItem: DispatchWorkItem?
    
    @Published public var isSpatialEnabled: Bool = true {
        didSet {
            guard isSpatialEnabled != oldValue else { return }
            spatialEngine.isSpatialEnabled = isSpatialEnabled
            saveActiveProfileSettings()
        }
    }
    
    @Published public var speakerAngleDeg: Double = 30.0 {
        didSet {
            guard abs(speakerAngleDeg - oldValue) > 0.001 else { return }
            spatialEngine.speakerAngleDeg = Float(speakerAngleDeg)
            saveActiveProfileSettings()
        }
    }
    
    @Published public var reverbBlend: Double = 0.01 { // 1% легкой естественной акустики (диапазон 0-3%)
        didSet {
            guard abs(reverbBlend - oldValue) > 0.00001 else { return }
            spatialEngine.reverbBlend = Float(reverbBlend)
            saveActiveProfileSettings()
        }
    }
    
    @Published public var volume: Double = 1.0 {
        didSet {
            guard abs(volume - oldValue) > 0.0001 else { return }
            spatialEngine.volume = Float(volume)
            saveActiveProfileSettings()
        }
    }

    // MARK: - Режим колонок (Этап 4.5)
    @Published public var isSpeakerMode: Bool = false {
        didSet {
            guard isSpeakerMode != oldValue else { return }
            spatialEngine.isSpeakerMode = isSpeakerMode
            if !isApplyingProfile {
                if let targetProfile = ProfileManager.shared.switchMode(isSpeakerMode: isSpeakerMode) {
                    applyProfile(targetProfile)
                }
            }
        }
    }

    @Published public var physicalSpeakerAngleDeg: Double = 22.5 {
        didSet {
            guard abs(physicalSpeakerAngleDeg - oldValue) > 0.05 else { return }
            spatialEngine.physicalSpeakerAngleDeg = Float(physicalSpeakerAngleDeg)
            saveActiveProfileSettings()
        }
    }
    
    @Published public var inputDevices: [AudioDevice] = []
    @Published public var outputDevices: [AudioDevice] = []
    @Published public var selectedInputDeviceID: AudioDeviceID = 0
    @Published public var selectedOutputDeviceID: AudioDeviceID = 0
    
    @Published public var isRunning: Bool = false
    @Published public var isBlackHoleInstalled: Bool = false
    @Published public var statusMessage: String = L10n.readyToStart
    
    private enum StatusState {
        case readyToStart
        case stopped
        case routingSystemAudio
        case connectingTo(String)
        case devicesNotFound
        case outputError(String)
        case pausedOnDevice(String)
        case active(String, Int, Bool)
    }
    private var currentStatusState: StatusState = .readyToStart {
        didSet {
            updateLocalizedStatusMessage()
        }
    }
    
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
    
    // MARK: - Управление состоянием сессии и переходов устройств
    
    /// Истинное состояние: включил ли пользователь Spatial Audio (не сбрасывается при реконфигурации/подключении/отключении наушников)
    private var isActiveSession: Bool = false
    
    /// Набор полных сигнатур всех устройств (ID + hasOutput + hasInput + dataSourceID + name)
    private var lastKnownDeviceSignatures: Set<AudioDevice> = []
    /// Стабильный снимок физических устройств вывода (обновляется после обработки событий хот-плага)
    private var stableOutputDeviceMap: [AudioDeviceID: AudioDevice] = [:]
    /// Время последнего аппаратного изменения списка/потоков устройств (для точного отделения автопереключения macOS от ручного выбора)
    private var lastHardwareTopologyChangeTime: TimeInterval = 0
    
    private var deviceChangeDebounceWorkItem: DispatchWorkItem?
    private var btStreamDiscoveryWorkItems: [DispatchWorkItem] = []
    private var previousOutputDeviceID: AudioDeviceID?
    private var pendingConnectedDeviceID: AudioDeviceID?
    private var isConnectingDevice: Bool = false
    private var isHandlingDeviceDisconnection: Bool = false
    private var connectingDeviceResetWorkItem: DispatchWorkItem?
    private var disconnectingDeviceResetWorkItem: DispatchWorkItem?
    private var pipelineRetryWorkItem: DispatchWorkItem?
    private var safetyRoutingWorkItem: DispatchWorkItem?
    private var volumeReinforceWorkItems: [DispatchWorkItem] = []
    private var pipelineRetryCount: Int = 0
    
    /// Флаг: нужно ли возобновить системное медиавоспроизведение после завершения инициализации нового/резервного устройства
    private var shouldResumeMediaAfterTransition: Bool = false
    /// Активные слушатели потоков/источников на физических устройствах
    private var devicePropertyListenerBlocks: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    
    private init() {
        if let currentProfile = ProfileManager.shared.activeProfile {
            applyProfile(currentProfile)
        }
        refreshDevices(preserveUserSelection: false)
        let initialDevs = AudioDeviceHelper.getAllDevices()
        self.lastKnownDeviceSignatures = Set(initialDevs)
        self.updateStableOutputSnapshot(from: initialDevs)
        
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
        syncPerDevicePropertyListeners(devices: initialDevs)
        
        // Если в системе уже выбран BlackHole — сразу автоматически запускаем
        if let currentDef = AudioDeviceHelper.getDefaultOutputDeviceID(),
           let bh = AudioDeviceHelper.findBlackHoleDevice(),
           currentDef == bh.id {
            self.isActiveSession = true
            startPipeline(routeSystemAudio: false)
        }
    }
    
    private func updateStableOutputSnapshot(from allDevs: [AudioDevice]) {
        var map: [AudioDeviceID: AudioDevice] = [:]
        for dev in allDevs where dev.hasOutput && !dev.isVirtual && !dev.isInternalAggregate {
            map[dev.id] = dev
        }
        self.stableOutputDeviceMap = map
    }
    
    // MARK: - Явный выбор устройств пользователем в UI
    
    public func selectInputDeviceByUser(_ newID: AudioDeviceID) {
        guard newID != 0 && newID != selectedInputDeviceID else { return }
        selectedInputDeviceID = newID
        if isActiveSession || isRunning {
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
        if isActiveSession || isRunning {
            restartPipeline()
        }
    }
    
    // MARK: - Управление профилями (Синхронизация с debounce 350 мс)
    
    private func saveActiveProfileSettings() {
        guard !isApplyingProfile else { return }
        profileSaveDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isApplyingProfile else { return }
            ProfileManager.shared.updateActiveProfileSettings(
                isSpatialEnabled: self.isSpatialEnabled,
                speakerAngleDeg: self.speakerAngleDeg,
                reverbBlend: self.reverbBlend,
                volume: self.volume,
                isSpeakerMode: self.isSpeakerMode,
                physicalSpeakerAngleDeg: self.physicalSpeakerAngleDeg
            )
        }
        profileSaveDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }
    
    public func applyProfile(_ profile: SpatialProfile) {
        profileSaveDebounceWorkItem?.cancel()
        isApplyingProfile = true
        let mode = profile.isSpeakerMode ?? ProfileManager.shared.currentModeIsSpeaker
        ProfileManager.shared.switchMode(isSpeakerMode: mode)
        self.isSpeakerMode = mode
        self.isSpatialEnabled = profile.isSpatialEnabled
        if mode {
            self.physicalSpeakerAngleDeg = profile.physicalSpeakerAngleDeg ?? 22.5
        } else {
            self.speakerAngleDeg = profile.speakerAngleDeg
        }
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
        let isSettable = AudioDeviceHelper.isVolumeSettable(deviceID: devID)
        if isActiveSession || isRunning || pendingTargetSystemDefaultID != nil || isConnectingDevice || isHandlingDeviceDisconnection {
            if isSettable {
                let currentDevVol = AudioDeviceHelper.getDeviceVolume(deviceID: devID)
                if currentDevVol == nil || abs((currentDevVol ?? 0) - volume) > 0.01 {
                    let applied = AudioDeviceHelper.setDeviceVolume(deviceID: devID, volume: volume)
                    debugLog("[AudioCoordinator] syncSessionVolumeToOutputs: devID=\(devID) -> set to \(volume), applied=\(applied)")
                }
                if volume > 0.005 {
                    let bhID = self.monitoredBlackHoleID ?? AudioDeviceHelper.findBlackHoleDevice()?.id
                    let db: Float32 = {
                        if let bhID = bhID, let readDb = AudioDeviceHelper.getDeviceVolumeDecibels(deviceID: bhID) {
                            return readDb
                        }
                        return 64.0 * (volume - 1.0)
                    }()
                    let scale = (db <= -64.0) ? 0.0 : pow(Float(10.0), -db / 20.0)
                    spatialEngine.inputVolumeScale = min(2000.0, scale)
                } else {
                    spatialEngine.inputVolumeScale = 0.0
                }
            } else {
                spatialEngine.inputVolumeScale = 1.0
            }
        } else {
            let applied = AudioDeviceHelper.setDeviceVolume(deviceID: devID, volume: volume)
            spatialEngine.inputVolumeScale = 1.0
            debugLog("[AudioCoordinator] syncSessionVolumeToOutputs: inactive -> set devID=\(devID) to \(volume), applied=\(applied)")
        }
    }
    
    public func currentOutputDeviceName() -> String {
        return AudioDeviceHelper.getDevice(id: selectedOutputDeviceID)?.name ?? L10n.headphonesFallback
    }
    
    private func updateLocalizedStatusMessage() {
        switch currentStatusState {
        case .readyToStart:
            statusMessage = L10n.readyToStart
        case .stopped:
            statusMessage = L10n.stopped
        case .routingSystemAudio:
            statusMessage = L10n.routingSystemAudio
        case .connectingTo(let name):
            statusMessage = L10n.connectingTo(name)
        case .devicesNotFound:
            statusMessage = L10n.devicesNotFound
        case .outputError(let name):
            statusMessage = L10n.outputError(name)
        case .pausedOnDevice(let name):
            statusMessage = L10n.pausedOnDevice(name)
        case .active(let name, let pct, let isMuted):
            statusMessage = isMuted ? L10n.spatialAudioMuted(name) : L10n.spatialAudioActive(name, pct)
        }
    }
    
    public func refreshLocalizedStatus() {
        if isRunning {
            let isMuted = AudioDeviceHelper.isDeviceMuted(deviceID: selectedInputDeviceID)
            let pct = Int(round(currentSessionVolume * 100))
            currentStatusState = .active(currentOutputDeviceName(), pct, isMuted)
        } else {
            updateLocalizedStatusMessage()
        }
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
                    self.currentStatusState = .active(self.currentOutputDeviceName(), pct, isMuted)
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
        AudioObjectRemovePropertyListenerBlock(bhID, &addrVMVC, DispatchQueue.main, block)
        
        var addrMain = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(bhID, &addrMain, DispatchQueue.main, block)
        
        var addrCh1 = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 1
        )
        AudioObjectRemovePropertyListenerBlock(bhID, &addrCh1, DispatchQueue.main, block)
        
        var addrMute = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(bhID, &addrMute, DispatchQueue.main, block)
        
        self.blackHoleVolumeListenerBlock = nil
        self.monitoredBlackHoleID = nil
    }
    
    // MARK: - CoreAudio Hardware Listeners (Горячее подключение наушников/BT и системное переключение)
    
    private func scheduleResetConnectingDevice(delay: TimeInterval) {
        connectingDeviceResetWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.isConnectingDevice = false
        }
        connectingDeviceResetWorkItem = item
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
        for delay in [0.5, 1.1, 2.0, 3.0] {
            let item = DispatchWorkItem { [weak self] in
                guard let self = self, self.isActiveSession, self.selectedOutputDeviceID == deviceID else { return }
                AudioDeviceHelper.setDeviceVolume(deviceID: deviceID, volume: self.currentSessionVolume)
            }
            volumeReinforceWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }
    
    /// Планируем серию отложенных проверок при подключении Bluetooth-устройства,
    /// чтобы гарантированно подгрузить его в список, когда профиль A2DP откроет выходные потоки (hasOutput == true)
    private func scheduleBluetoothStreamDiscoveryPolls() {
        for item in btStreamDiscoveryWorkItems {
            item.cancel()
        }
        btStreamDiscoveryWorkItems.removeAll()
        
        for delay in [0.35, 0.8, 1.5, 2.5, 3.8] {
            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                let allDevs = AudioDeviceHelper.getAllDevices()
                let currentSet = Set(allDevs)
                if currentSet != self.lastKnownDeviceSignatures {
                    debugLog("[AudioCoordinator] BT Stream Discovery poll at \(delay)s detected newly ready streams!")
                    self.handleHardwareDevicesChanged()
                } else {
                    let liveOuts = allDevs.filter { $0.hasOutput && !$0.isVirtual }
                    if liveOuts != self.outputDevices {
                        self.refreshDevices(preserveUserSelection: true)
                    }
                }
            }
            btStreamDiscoveryWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }
    
    /// Подписка на изменения потоков (kAudioDevicePropertyStreams) и источника (kAudioDevicePropertyDataSource) каждого устройства
    private func syncPerDevicePropertyListeners(devices: [AudioDevice]) {
        let currentIDs = Set(devices.filter { !$0.isVirtual && !$0.isInternalAggregate }.map { $0.id })
        
        // Удаляем слушатели для отключенных устройств
        for (oldID, block) in devicePropertyListenerBlocks where !currentIDs.contains(oldID) {
            for scope in [kAudioObjectPropertyScopeGlobal, kAudioDevicePropertyScopeInput, kAudioDevicePropertyScopeOutput] {
                var streamsAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyStreams,
                    mScope: scope,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectRemovePropertyListenerBlock(oldID, &streamsAddr, DispatchQueue.main, block)
            }
            
            var dataSourceAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDataSource,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(oldID, &dataSourceAddr, DispatchQueue.main, block)
            devicePropertyListenerBlocks.removeValue(forKey: oldID)
        }
        
        // Добавляем слушатели для новых физических устройств (особенно Bluetooth, где потоки появляются позже)
        for id in currentIDs where devicePropertyListenerBlocks[id] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self = self else { return }
                debugLog("[AudioCoordinator] Per-device stream/datasource property changed for device \(id)")
                self.lastHardwareTopologyChangeTime = ProcessInfo.processInfo.systemUptime
                self.handleHardwareDevicesChanged()
            }
            devicePropertyListenerBlocks[id] = block
            
            for scope in [kAudioObjectPropertyScopeGlobal, kAudioDevicePropertyScopeInput, kAudioDevicePropertyScopeOutput] {
                var streamsAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyStreams,
                    mScope: scope,
                    mElement: kAudioObjectPropertyElementMain
                )
                if AudioObjectHasProperty(id, &streamsAddr) {
                    AudioObjectAddPropertyListenerBlock(id, &streamsAddr, DispatchQueue.main, block)
                }
            }
            
            var dataSourceAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDataSource,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectHasProperty(id, &dataSourceAddr) {
                AudioObjectAddPropertyListenerBlock(id, &dataSourceAddr, DispatchQueue.main, block)
            }
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
    }
    
    /// Начать подготовку к переключению устройства: если приложение активно, принудительно удерживаем BlackHole
    /// и ставим системное воспроизведение на паузу на время инициализации нового выхода
    private func beginHardwareTransitionIfActive() {
        guard isActiveSession else { return }
        if let bh = AudioDeviceHelper.findBlackHoleDevice() {
            if AudioDeviceHelper.getDefaultOutputDeviceID() != bh.id {
                AudioDeviceHelper.setDefaultOutputDevice(deviceID: bh.id)
            }
        }
        // Проверяем, играет ли сейчас системное медиа, и ставим на паузу на время переключения
        AudioDeviceHelper.pauseSystemMediaIfPlaying { [weak self] didPause in
            guard let self = self else { return }
            if didPause {
                debugLog("[AudioCoordinator] Системное воспроизведение поставлено на паузу на время инициализации устройства")
                self.shouldResumeMediaAfterTransition = true
            }
        }
    }
    
    private func handleHardwareDevicesChanged() {
        let allDevs = AudioDeviceHelper.getAllDevices()
        syncPerDevicePropertyListeners(devices: allDevs)
        
        let currentSignatureSet = Set(allDevs)
        
        // Игнорируем ложные срабатывания от создания/удаления внутренних CADefaultDeviceAggregate,
        // если сигнатуры всех реальных устройств (ID + hasOutput + hasInput + dataSource + name) не изменились
        if currentSignatureSet == self.lastKnownDeviceSignatures &&
           self.pendingConnectedDeviceID == nil &&
           !self.isConnectingDevice &&
           !self.isHandlingDeviceDisconnection {
            return
        }
        
        // Проверяем, появились ли новые устройства вообще (даже если у BT еще hasOutput == false)
        let previousIDs = Set(self.lastKnownDeviceSignatures.map { $0.id })
        let currentIDs = Set(allDevs.map { $0.id })
        if currentIDs != previousIDs {
            self.lastHardwareTopologyChangeTime = ProcessInfo.processInfo.systemUptime
            scheduleBluetoothStreamDiscoveryPolls()
        }
        
        self.lastKnownDeviceSignatures = currentSignatureSet
        
        let currentOuts = allDevs.filter { $0.hasOutput && !$0.isVirtual && !$0.isInternalAggregate }
        
        // Сравниваем со стабильным снимком выходных устройств (чтобы видеть появление hasOutput или смену dataSourceID на разъеме наушников)
        let newlyAvailableOuts = currentOuts.filter { cur in
            guard let prev = self.stableOutputDeviceMap[cur.id] else {
                return true // Полностью новый AudioDeviceID с выходом
            }
            // Или у существующего устройства изменился источник (например, подключили проводные наушники в Built-in)
            return prev.dataSourceID != cur.dataSourceID && cur.isHeadphones
        }
        
        let disappearedOutIDs = Set(self.stableOutputDeviceMap.keys).subtracting(Set(currentOuts.map { $0.id }))
        let didBuiltInHeadphonesUnplug: Bool = {
            if let curSelected = currentOuts.first(where: { $0.id == self.selectedOutputDeviceID }),
               let prevSelected = self.stableOutputDeviceMap[self.selectedOutputDeviceID] {
                return prevSelected.dataSourceID != curSelected.dataSourceID && prevSelected.isHeadphones && !curSelected.isHeadphones
            }
            return false
        }()
        
        if !newlyAvailableOuts.isEmpty || !disappearedOutIDs.isEmpty || didBuiltInHeadphonesUnplug {
            self.lastHardwareTopologyChangeTime = ProcessInfo.processInfo.systemUptime
        }
        
        // 1. Быстрая предварительная проверка: появилось ли новое выходное устройство (наушники, любое BT-устройство или внешняя карта)
        if let newDev = newlyAvailableOuts.first(where: { $0.isBluetooth || $0.isHeadphones || !$0.isBuiltIn }) ?? newlyAvailableOuts.first {
            debugLog("[AudioCoordinator] Pre-detected connecting output device: \(newDev.name) (\(newDev.id), BT=\(newDev.isBluetooth))")
            self.isConnectingDevice = true
            self.pendingConnectedDeviceID = newDev.id
            
            // Заблаговременно сохраняем предыдущее устройство до любых обновлений списков
            if self.selectedOutputDeviceID != 0 && self.selectedOutputDeviceID != newDev.id {
                if let curDev = self.stableOutputDeviceMap[self.selectedOutputDeviceID], !curDev.isVirtual {
                    self.previousOutputDeviceID = curDev.id
                    debugLog("[AudioCoordinator] Pre-saved previous device: \(curDev.name) (\(curDev.id))")
                }
            }
            
            beginHardwareTransitionIfActive()
            scheduleResetConnectingDevice(delay: 4.0)
        }
        
        // 2. Быстрая предварительная проверка: отключилось ли текущее или любое внешнее устройство вывода
        let didCurrentDisappear = (self.selectedOutputDeviceID != 0 && !currentOuts.contains(where: { $0.id == self.selectedOutputDeviceID })) || didBuiltInHeadphonesUnplug
        if didCurrentDisappear || !disappearedOutIDs.isEmpty {
            debugLog("[AudioCoordinator] Pre-detected device disconnection (currentDisappeared=\(didCurrentDisappear), disappearedIDs=\(disappearedOutIDs))")
            self.isHandlingDeviceDisconnection = true
            
            if didCurrentDisappear && self.isActiveSession {
                // При отключении наушников macOS часто сама ставит плеер на паузу, поэтому запоминаем,
                // работал ли сейчас звук (по уровню сигнала ИЛИ по статусу MediaRemote), чтобы возобновить воспроизведение
                let hadRecentAudioSignal = (self.captureUnit.peakLevelL > 0.0005 || self.captureUnit.peakLevelR > 0.0005)
                if hadRecentAudioSignal {
                    self.shouldResumeMediaAfterTransition = true
                }
            }
            
            beginHardwareTransitionIfActive()
            scheduleResetDisconnectingDevice(delay: 3.5)
        }
        
        // Немедленно обновляем публичные списки inputDevices / outputDevices, чтобы UI всегда видел актуальные носители
        self.inputDevices = allDevs.filter { $0.hasInput }
        self.outputDevices = currentOuts
        
        // Устраняем дребезг (debounce 450 мс) для завершения Bluetooth handshake в macOS
        deviceChangeDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.deviceChangeDebounceWorkItem = nil
            self.performHardwareDevicesChanged()
        }
        deviceChangeDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }
    
    private func performHardwareDevicesChanged() {
        let allDevs = AudioDeviceHelper.getAllDevices()
        let currentOuts = allDevs.filter { $0.hasOutput && !$0.isVirtual && !$0.isInternalAggregate }
        let oldSelectedOutputID = self.selectedOutputDeviceID
        let oldStableMap = self.stableOutputDeviceMap
        
        // Обновляем стабильный снимок и списки UI
        updateStableOutputSnapshot(from: allDevs)
        refreshDevices(preserveUserSelection: true)
        
        // 1. Проверяем, появилось ли новое устройство вывода (Bluetooth, наушники, USB и т.д.)
        var newlyConnectedDev = currentOuts.first(where: { newDev in
            guard let prev = oldStableMap[newDev.id] else {
                return true
            }
            return prev.dataSourceID != newDev.dataSourceID && newDev.isHeadphones
        })
        if newlyConnectedDev == nil, let pendingID = self.pendingConnectedDeviceID {
            newlyConnectedDev = currentOuts.first(where: { $0.id == pendingID })
        }
        self.pendingConnectedDeviceID = nil
        
        if let newlyConnected = newlyConnectedDev {
            debugLog("[AudioCoordinator] Подключено новое устройство вывода: \(newlyConnected.name) (\(newlyConnected.id))")
            
            // Сохраняем физическое устройство, которое было активно ДО подключения, и возвращаем ему сессионную громкость
            if oldSelectedOutputID != 0 && oldSelectedOutputID != newlyConnected.id {
                if let prevDev = oldStableMap[oldSelectedOutputID], !prevDev.isVirtual {
                    self.previousOutputDeviceID = prevDev.id
                    AudioDeviceHelper.setDeviceVolume(deviceID: prevDev.id, volume: self.currentSessionVolume)
                    debugLog("[AudioCoordinator] Запомнили предыдущее устройство: \(prevDev.name) (\(prevDev.id))")
                }
            }
            
            self.selectedOutputDeviceID = newlyConnected.id
            self.savedSystemDefaultOutputDeviceID = newlyConnected.id
            
            if self.isActiveSession {
                debugLog("[AudioCoordinator] Сессия активна -> переключаем вывод на \(newlyConnected.name) и удерживаем BlackHole")
                self.stopAudioUnitsOnly()
                self.currentStatusState = .connectingTo(newlyConnected.name)
                if let bh = AudioDeviceHelper.findBlackHoleDevice() {
                    AudioDeviceHelper.setDefaultOutputDevice(deviceID: bh.id)
                }
                self.pipelineRetryCount = 0
                self.startPipeline(routeSystemAudio: true)
                scheduleVolumeReinforcement(for: newlyConnected.id)
            } else {
                self.isConnectingDevice = false
            }
            return
        }
        
        // 2. Проверяем, отключилось ли текущее устройство вывода (наушники/BT выключены или убраны в кейс, либо выдернут 3.5мм разъем)
        let didBuiltInHeadphonesUnplug: Bool = {
            if let curSelected = currentOuts.first(where: { $0.id == oldSelectedOutputID }),
               let prevSelected = oldStableMap[oldSelectedOutputID] {
                return prevSelected.dataSourceID != curSelected.dataSourceID && prevSelected.isHeadphones && !curSelected.isHeadphones
            }
            return false
        }()
        
        let didCurrentDisconnect = (oldSelectedOutputID != 0 && !currentOuts.contains(where: { $0.id == oldSelectedOutputID })) || didBuiltInHeadphonesUnplug
        
        if didCurrentDisconnect || self.isHandlingDeviceDisconnection {
            if didCurrentDisconnect {
                debugLog("[AudioCoordinator] Выбранное устройство вывода отключено (\(oldSelectedOutputID))")
                
                var fallbackDev: AudioDevice? = nil
                if let prevID = self.previousOutputDeviceID,
                   let prevDev = currentOuts.first(where: { $0.id == prevID }) {
                    fallbackDev = prevDev
                    debugLog("[AudioCoordinator] Возврат на предыдущее устройство: \(prevDev.name) (\(prevDev.id))")
                } else {
                    fallbackDev = AudioDeviceHelper.findPreferredOutputDevice()
                    debugLog("[AudioCoordinator] Возврат на предпочтительное устройство: \(fallbackDev?.name ?? "none")")
                }
                
                if let fallback = fallbackDev {
                    self.selectedOutputDeviceID = fallback.id
                    self.savedSystemDefaultOutputDeviceID = fallback.id
                    self.previousOutputDeviceID = nil
                    
                    if self.isActiveSession {
                        self.stopAudioUnitsOnly()
                        self.currentStatusState = .connectingTo(fallback.name)
                        if let bh = AudioDeviceHelper.findBlackHoleDevice() {
                            AudioDeviceHelper.setDefaultOutputDevice(deviceID: bh.id)
                        }
                        self.pipelineRetryCount = 0
                        self.startPipeline(routeSystemAudio: true)
                        scheduleVolumeReinforcement(for: fallback.id)
                    }
                    scheduleResetDisconnectingDevice(delay: 1.5)
                } else {
                    self.isHandlingDeviceDisconnection = false
                }
            } else if self.isActiveSession {
                // Отключилось какое-то другое внешнее устройство, но macOS могла сбросить дефолт с BlackHole
                if let bh = AudioDeviceHelper.findBlackHoleDevice(),
                   AudioDeviceHelper.getDefaultOutputDeviceID() != bh.id {
                    AudioDeviceHelper.setDefaultOutputDevice(deviceID: bh.id)
                }
                if !self.isRunning {
                    self.pipelineRetryCount = 0
                    self.startPipeline(routeSystemAudio: true)
                }
                scheduleResetDisconnectingDevice(delay: 1.0)
            } else {
                self.isHandlingDeviceDisconnection = false
            }
        }
    }
    
    /// Определяет, вызвана ли смена системного устройства вывода автоматической реакцией macOS на подключение/отключение оборудования,
    /// или пользователь переключил устройство вручную в меню macOS.
    private func isSystemAutoSwitchDueToHardwareEvent(newDefaultID: AudioDeviceID, liveOuts: [AudioDevice]) -> Bool {
        // 1. Явные флаги активного процесса подключения/отключения или debounce-таймера
        if isConnectingDevice || isHandlingDeviceDisconnection || deviceChangeDebounceWorkItem != nil || pipelineRetryWorkItem != nil {
            return true
        }
        
        // 2. Временнóе окно после любого аппаратного события (Bluetooth профили и отключение носителей занимают до 3.5 сек)
        let elapsedSinceTopologyChange = ProcessInfo.processInfo.systemUptime - lastHardwareTopologyChangeTime
        if elapsedSinceTopologyChange < 3.5 {
            return true
        }
        
        // 3. Прямая сверка живой топологии со стабильным снимком (на случай, если колбэк DefaultOutputDevice пришел раньше Devices):
        // 3а. Исчезло ли хотя бы одно выходное устройство из стабильного снимка?
        let liveOutIDs = Set(liveOuts.map { $0.id })
        let stableOutIDs = Set(stableOutputDeviceMap.keys)
        if !stableOutIDs.isSubset(of: liveOutIDs) {
            return true
        }
        
        // 3б. Появилось ли новое выходное устройство, которого еще не было в стабильном снимке?
        if !liveOutIDs.isSubset(of: stableOutIDs) {
            return true
        }
        
        // 3в. Изменился ли dataSourceID на выбранном или новом дефолтном устройстве (например, разъем проводных наушников)?
        for dev in liveOuts {
            if let oldDev = stableOutputDeviceMap[dev.id], oldDev.dataSourceID != dev.dataSourceID {
                return true
            }
        }
        
        return false
    }
    
    private func handleDefaultOutputDeviceChanged() {
        guard let currentDefault = AudioDeviceHelper.getDefaultOutputDeviceID() else { return }
        debugLog("[AudioCoordinator] handleDefaultOutputDeviceChanged: currentDefault=\(currentDefault), pending=\(String(describing: pendingTargetSystemDefaultID)), isActiveSession=\(isActiveSession), isConnecting=\(isConnectingDevice), isDisconnecting=\(isHandlingDeviceDisconnection), isRunning=\(self.isRunning)")
        
        let bh = AudioDeviceHelper.findBlackHoleDevice()
        
        // 1. Если мы сами программно инициировали переход на BlackHole при старте — обрабатываем в первую очередь!
        if let pending = pendingTargetSystemDefaultID {
            if currentDefault == pending {
                debugLog("[AudioCoordinator] pending target \(pending) reached!")
                pendingTargetSystemDefaultID = nil
                safetyRoutingWorkItem?.cancel()
                safetyRoutingWorkItem = nil
                
                if let bh = bh, currentDefault == bh.id {
                    debugLog("[AudioCoordinator] BlackHole готов в macOS -> немедленный старт пайплайна")
                    if !self.isRunning {
                        self.startPipeline(routeSystemAudio: false)
                    }
                    return
                }
            } else if isActiveSession, let bh = bh, pending == bh.id {
                // Во время старта система попыталась перебросить дефолт — удерживаем BlackHole
                AudioDeviceHelper.setDefaultOutputDevice(deviceID: bh.id)
                return
            } else {
                pendingTargetSystemDefaultID = nil
                safetyRoutingWorkItem?.cancel()
                safetyRoutingWorkItem = nil
            }
        }
        
        // 2. Сценарий 1: В системе выбран BlackHole 2ch
        if let bh = bh, currentDefault == bh.id {
            if !self.isActiveSession || !self.isRunning {
                debugLog("[AudioCoordinator] В macOS выбран BlackHole -> активация сессии и старт пайплайна")
                self.isActiveSession = true
                self.startPipeline(routeSystemAudio: false)
            }
            return
        }
        
        // 3. В системе выбрано физическое устройство (НЕ BlackHole).
        // Определяем: это автоматическое переключение системой (при подключении/отключении наушников/BT) ИЛИ ручной выбор пользователя?
        let allLiveDevs = AudioDeviceHelper.getAllDevices()
        let liveOuts = allLiveDevs.filter { $0.hasOutput && !$0.isVirtual && !$0.isInternalAggregate }
        
        if isSystemAutoSwitchDueToHardwareEvent(newDefaultID: currentDefault, liveOuts: liveOuts) {
            debugLog("[AudioCoordinator] Автопереключение системой на \(currentDefault) из-за подключения/отключения устройства! Удерживаем BlackHole.")
            self.lastHardwareTopologyChangeTime = ProcessInfo.processInfo.systemUptime
            
            // Если это новое устройство, которого еще не было в списке — помечаем его как подключаемое
            if let newDev = liveOuts.first(where: { $0.id == currentDefault }),
               self.stableOutputDeviceMap[currentDefault] == nil {
                self.isConnectingDevice = true
                self.pendingConnectedDeviceID = newDev.id
                scheduleResetConnectingDevice(delay: 4.0)
            } else if self.selectedOutputDeviceID != 0 && !liveOuts.contains(where: { $0.id == self.selectedOutputDeviceID }) {
                self.isHandlingDeviceDisconnection = true
                scheduleResetDisconnectingDevice(delay: 3.5)
            }
            
            if self.isActiveSession {
                // Удерживаем BlackHole в системе!
                if let bh = bh {
                    AudioDeviceHelper.setDefaultOutputDevice(deviceID: bh.id)
                }
            }
            
            // Запускаем обработку аппаратных изменений (она обновит список и переключит выход внутри приложения)
            handleHardwareDevicesChanged()
            return
        }
        
        // 4. ⏸ Сценарий 2: Топология оборудования стабильна -> Пользователь ВРУЧНУЮ выбрал другое устройство в системном меню macOS
        if self.isActiveSession || self.isRunning {
            stopMonitoringBlackHoleVolume()
            if let bh = bh, let currentBhVol = AudioDeviceHelper.getDeviceVolume(deviceID: bh.id) {
                self.currentSessionVolume = currentBhVol
            }
            if self.selectedOutputDeviceID != 0 {
                AudioDeviceHelper.setDeviceVolume(deviceID: self.selectedOutputDeviceID, volume: self.currentSessionVolume)
            }
            AudioDeviceHelper.setDeviceVolume(deviceID: currentDefault, volume: self.currentSessionVolume)
            
            let devName = AudioDeviceHelper.getDevice(id: currentDefault)?.name ?? L10n.otherDevice
            debugLog("[AudioCoordinator] Пользователь вручную выбрал в macOS '\(devName)' -> приостановка приложения и включение выбранного устройства")
            self.isActiveSession = false
            self.pausePipeline()
            self.currentStatusState = .pausedOnDevice(devName)
        }
        
        if let nonVirtualDev = AudioDeviceHelper.getDevice(id: currentDefault), !nonVirtualDev.isVirtual && nonVirtualDev.hasOutput {
            self.savedSystemDefaultOutputDeviceID = currentDefault
            self.selectedOutputDeviceID = currentDefault
            if let v = AudioDeviceHelper.getDeviceVolume(deviceID: currentDefault) {
                self.currentSessionVolume = v
            }
            debugLog("[AudioCoordinator] Запомнили выбранное вручную устройство из macOS: \(nonVirtualDev.name) (\(currentDefault)) с vol=\(self.currentSessionVolume)")
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
            if !isConnectingDevice && !isHandlingDeviceDisconnection {
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
        
        // Таймаут безопасности: запустить пайплайн через 0.4 сек, если системное событие задержалось
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: safetyItem)
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
        self.lastKnownDeviceSignatures = Set(all)
        syncPerDevicePropertyListeners(devices: all)
        
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
        debugLog("[AudioCoordinator] refreshDevices: inID=\(selectedInputDeviceID), outID=\(selectedOutputDeviceID), totalOutputs=\(outputDevices.count)")
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
        cancelVolumeReinforcement()
        stopAudioUnitsOnly()
        isRunning = false
        if selectedOutputDeviceID != 0 {
            AudioDeviceHelper.setDeviceVolume(deviceID: selectedOutputDeviceID, volume: currentSessionVolume)
        }
    }
    
    public func startPipeline(routeSystemAudio: Bool = true) {
        debugLog("[AudioCoordinator] startPipeline(routeSystemAudio: \(routeSystemAudio))")
        isActiveSession = true
        pipelineRetryWorkItem?.cancel()
        pipelineRetryWorkItem = nil
        
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
            currentStatusState = .devicesNotFound
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
                currentStatusState = .routingSystemAudio
                return
            }
        }
        
        // Убеждаемся, что при активной сессии в системе точно стоит BlackHole
        if let bh = AudioDeviceHelper.findBlackHoleDevice(),
           AudioDeviceHelper.getDefaultOutputDeviceID() != bh.id {
            AudioDeviceHelper.setDefaultOutputDevice(deviceID: bh.id)
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
        
        // 4. Синхронизируем частоту BlackHole с фактической частотой наушников/выхода
        AudioDeviceHelper.setSampleRate(deviceID: inDev.id, rate: sampleRate)
        
        ringBuffer.reset()
        
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
        let postStartDevs = AudioDeviceHelper.getAllDevices()
        self.lastKnownDeviceSignatures = Set(postStartDevs)
        self.updateStableOutputSnapshot(from: postStartDevs)
        
        // 6. Архитектура Single Attenuation (Unity Gain 1:1):
        AudioDeviceHelper.setDeviceVolume(deviceID: inDev.id, volume: currentSessionVolume)
        
        isRunning = true
        pipelineRetryCount = 0
        syncSessionVolumeToOutputs(volume: currentSessionVolume)
        startMonitoringBlackHoleVolume(bhID: inDev.id)
        
        let isMuted = AudioDeviceHelper.isDeviceMuted(deviceID: inDev.id)
        let pct = Int(round(currentSessionVolume * 100))
        currentStatusState = .active(outDev.name, pct, isMuted)
        debugLog("[AudioCoordinator] startPipeline SUCCESS! isRunning=true, outDev=\(outDev.name)")
        
        // Если перед переключением устройства играло медиа (или было остановлено при отключении наушников) — возобновляем!
        if shouldResumeMediaAfterTransition {
            shouldResumeMediaAfterTransition = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                debugLog("[AudioCoordinator] Автоматическое возобновление воспроизведения после инициализации \(outDev.name)")
                AudioDeviceHelper.resumeSystemMedia()
            }
        }
        
        // Плавно снимаем флаги переходных процессов через управляемый таймер
        if isConnectingDevice {
            scheduleResetConnectingDevice(delay: 1.5)
        }
        if isHandlingDeviceDisconnection {
            scheduleResetDisconnectingDevice(delay: 1.0)
        }
        
        if isUIVisible {
            startLevelTimer()
        }
    }
    
    private func handlePipelineFailure(outDev: AudioDevice) {
        if isActiveSession {
            if let bh = AudioDeviceHelper.findBlackHoleDevice(),
               AudioDeviceHelper.getDefaultOutputDeviceID() != bh.id {
                AudioDeviceHelper.setDefaultOutputDevice(deviceID: bh.id)
            }
        }
        
        if pipelineRetryCount < 8 {
            pipelineRetryCount += 1
            debugLog("[AudioCoordinator] Ожидание готовности \(outDev.name), попытка #\(pipelineRetryCount)/8 через 0.45 сек...")
            currentStatusState = .connectingTo(outDev.name)
            pipelineRetryWorkItem?.cancel()
            let retryItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.isActiveSession else { return }
                self.pipelineRetryWorkItem = nil
                self.startPipeline(routeSystemAudio: false)
            }
            pipelineRetryWorkItem = retryItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: retryItem)
        } else {
            pipelineRetryCount = 0
            isConnectingDevice = false
            isHandlingDeviceDisconnection = false
            
            // Если целевое устройство (например, зависший BT-профиль) не запустилось после 8 попыток,
            // НЕ останавливаем приложение и НЕ оставляем тишину: откатываемся на рабочий резервный выход (например, динамики Mac)!
            let fallbackCandidates = outputDevices.filter { $0.id != outDev.id && !$0.isVirtual }
            if isActiveSession, let fallback = fallbackCandidates.first(where: { $0.isBuiltIn }) ?? fallbackCandidates.first {
                debugLog("[AudioCoordinator] Устройство \(outDev.name) не ответило, автоматический откат на \(fallback.name) с сохранением работы через BlackHole")
                self.selectedOutputDeviceID = fallback.id
                self.savedSystemDefaultOutputDeviceID = fallback.id
                self.startPipeline(routeSystemAudio: true)
            } else {
                debugLog("[AudioCoordinator] Ошибка старта: нет доступных устройств вывода. Восстанавливаем системный звук.")
                isActiveSession = false
                currentStatusState = .outputError(outDev.name)
                restoreSystemSound()
            }
        }
    }
    
    public func stopPipeline(restoreSystemAudio: Bool = true) {
        isActiveSession = false
        shouldResumeMediaAfterTransition = false
        isConnectingDevice = false
        isHandlingDeviceDisconnection = false
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
        
        currentStatusState = .stopped
    }
    
    public func restartPipeline() {
        if isActiveSession || isRunning {
            startPipeline(routeSystemAudio: false)
        }
    }
    
    public func toggle() {
        if isActiveSession || isRunning {
            stopPipeline()
        } else {
            startPipeline()
        }
    }
    
    private func startLevelTimer() {
        guard levelTimer == nil, isRunning else { return }
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let scale = max(0.0, self.spatialEngine.inputVolumeScale)
            let rawL = self.captureUnit.consumePeakL() * scale
            let rawR = self.captureUnit.consumePeakR() * scale
            
            // Логарифмически-перцептивная шкала (корень из мощности, VU-стандарт)
            let targetL = min(1.0, sqrt(max(0.0, rawL)))
            let targetR = min(1.0, sqrt(max(0.0, rawR)))
            
            // Мгновенная атака на пиках, мягкий баллистический спад
            if targetL >= self.leftLevel {
                self.leftLevel = targetL
            } else {
                self.leftLevel = max(0.0, self.leftLevel * 0.78 + targetL * 0.22)
                if self.leftLevel < 0.001 { self.leftLevel = 0.0 }
            }
            
            if targetR >= self.rightLevel {
                self.rightLevel = targetR
            } else {
                self.rightLevel = max(0.0, self.rightLevel * 0.78 + targetR * 0.22)
                if self.rightLevel < 0.001 { self.rightLevel = 0.0 }
            }
        }
    }
    
    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        leftLevel = 0.0
        rightLevel = 0.0
    }
}
