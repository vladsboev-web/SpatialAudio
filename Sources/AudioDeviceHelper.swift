import Foundation
import CoreAudio
import AudioToolbox

public struct AudioDevice: Identifiable, Hashable {
    public let id: AudioDeviceID
    public let name: String
    public let hasInput: Bool
    public let hasOutput: Bool
    public let sampleRate: Double
    public let transportType: UInt32
    
    public var isBluetooth: Bool {
        return transportType == kAudioDeviceTransportTypeBluetooth ||
               transportType == kAudioDeviceTransportTypeBluetoothLE
    }
    
    public var isBuiltIn: Bool {
        return transportType == kAudioDeviceTransportTypeBuiltIn
    }
    
    public var isVirtual: Bool {
        return transportType == kAudioDeviceTransportTypeVirtual ||
               name.localizedCaseInsensitiveContains("BlackHole")
    }
    
    /// Внутренние служебные агрегатные устройства CoreAudio (CADefaultDeviceAggregate-<PID>-<index>)
    public var isInternalAggregate: Bool {
        return name.contains("CADefaultDeviceAggregate") ||
               name.contains("CADefaultDevice")
    }
    
    public var isHeadphones: Bool {
        if isBluetooth { return true }
        let n = name.lowercased()
        let keywords = ["airpod", "headphone", "headset", "earphone", "buds", "wh-", "wf-", "ugreen", "bose", "sony", "beats", "sennheiser", "jbl", "shure", "anker", "soundcore"]
        return keywords.contains { n.contains($0) }
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    public static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        lhs.id == rhs.id
    }
}

public final class AudioDeviceHelper {
    
    /// Список всех аудиоустройств в системе с актуальными ID
    public static func getAllDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr else { return [] }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard dataStatus == noErr else { return [] }
        
        var devices: [AudioDevice] = []
        for id in deviceIDs {
            if let dev = getDevice(id: id) {
                // Исключаем скрытые внутренние агрегатные устройства macOS CoreAudio
                if !dev.isInternalAggregate {
                    devices.append(dev)
                }
            }
        }
        return devices
    }
    
    public static func getDevice(id: AudioDeviceID) -> AudioDevice? {
        // Name
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let nameStatus = AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name)
        guard nameStatus == noErr else { return nil }
        
        // Input streams
        var inStreamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var inStreamSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &inStreamAddress, 0, nil, &inStreamSize)
        let hasIn = (inStreamSize / UInt32(MemoryLayout<AudioStreamID>.size)) > 0
        
        // Output streams
        var outStreamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var outStreamSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &outStreamAddress, 0, nil, &outStreamSize)
        let hasOut = (outStreamSize / UInt32(MemoryLayout<AudioStreamID>.size)) > 0
        
        // Sample Rate
        var sampleRate: Float64 = 44100.0
        var srSize = UInt32(MemoryLayout<Float64>.size)
        var srAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(id, &srAddress, 0, nil, &srSize, &sampleRate)
        
        // Transport Type
        var transport: UInt32 = 0
        var transSize = UInt32(MemoryLayout<UInt32>.size)
        var transAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(id, &transAddress, 0, nil, &transSize, &transport)
        
        return AudioDevice(
            id: id,
            name: name as String,
            hasInput: hasIn,
            hasOutput: hasOut,
            sampleRate: sampleRate,
            transportType: transport
        )
    }
    
    /// Получить актуальный BlackHole (поиск по имени)
    public static func findBlackHoleDevice() -> AudioDevice? {
        let devices = getAllDevices()
        return devices.first { $0.hasInput && $0.isVirtual }
    }
    
    /// Получить наиболее подходящие наушники вывода (Bluetooth / гарнитура)
    public static func findPreferredOutputDevice() -> AudioDevice? {
        let devices = getAllDevices().filter { $0.hasOutput && !$0.isVirtual }
        
        // 1. Приоритет: наушники и Bluetooth устройства
        if let bt = devices.first(where: { $0.isBluetooth || $0.isHeadphones }) {
            return bt
        }
        
        // 2. Внешние устройства (USB DAC, внешняя карта и т.д.)
        if let external = devices.first(where: { !$0.isBuiltIn }) {
            return external
        }
        
        // 3. Встроенные динамики Mac
        return devices.first(where: { $0.isBuiltIn }) ?? devices.first
    }
    
    /// Получить текущее системное устройство вывода macOS
    public static func getDefaultOutputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID)
        return status == noErr ? devID : nil
    }
    
    /// Назначить системное устройство вывода macOS (например, направить звук всей системы в BlackHole)
    @discardableResult
    public static func setDefaultOutputDevice(deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &devID)
        return status == noErr
    }
    
    /// Установить частоту дискретизации устройства (только если она отличается)
    @discardableResult
    public static func setSampleRate(deviceID: AudioDeviceID, rate: Double) -> Bool {
        if let dev = getDevice(id: deviceID), abs(dev.sampleRate - rate) < 1.0 {
            return true // Уже установлена нужная частота! Не сбрасываем устройство
        }
        var newRate = Float64(rate)
        var setAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            deviceID,
            &setAddress,
            0,
            nil,
            UInt32(MemoryLayout<Float64>.size),
            &newRate
        )
        return status == noErr
    }
    
    public static let kVirtualMainVolume = AudioObjectPropertySelector(0x766d7663) // 'vmvc' (kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    
    
    /// Получить системную громкость устройства (VirtualMainVolume, Main или канал 1)
    public static func getDeviceVolume(deviceID: AudioDeviceID) -> Float32? {
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        
        // 1. Проверяем VirtualMainVolume (основное системное свойство macOS)
        var addrVMVC = AudioObjectPropertyAddress(
            mSelector: kVirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &addrVMVC) {
            let status = AudioObjectGetPropertyData(deviceID, &addrVMVC, 0, nil, &size, &vol)
            if status == noErr { return vol }
        }
        
        // 2. VolumeScalar на Main
        var addrMain = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &addrMain) {
            let status = AudioObjectGetPropertyData(deviceID, &addrMain, 0, nil, &size, &vol)
            if status == noErr { return vol }
        }
        
        // 3. VolumeScalar на Channel 1
        var addrCh1 = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 1
        )
        if AudioObjectHasProperty(deviceID, &addrCh1) {
            let status = AudioObjectGetPropertyData(deviceID, &addrCh1, 0, nil, &size, &vol)
            if status == noErr { return vol }
        }
        return nil
    }
    
    /// Установить системную громкость устройства (VirtualMainVolume, Main и каналы 1..2)
    @discardableResult
    public static func setDeviceVolume(deviceID: AudioDeviceID, volume: Float32) -> Bool {
        var v = volume
        var didApply = false
        
        // 1. VirtualMainVolume
        var addrVMVC = AudioObjectPropertyAddress(
            mSelector: kVirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &addrVMVC) {
            let s = AudioObjectSetPropertyData(deviceID, &addrVMVC, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
            if s == noErr { didApply = true }
        }
        
        // 2. VolumeScalar Main
        var addrMain = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &addrMain) {
            let s = AudioObjectSetPropertyData(deviceID, &addrMain, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
            if s == noErr { didApply = true }
        }
        
        // 3. VolumeScalar каналы 1 и 2
        for ch in 1...2 {
            var addrCh = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: UInt32(ch)
            )
            if AudioObjectHasProperty(deviceID, &addrCh) {
                let s = AudioObjectSetPropertyData(deviceID, &addrCh, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
                if s == noErr { didApply = true }
            }
        }
        
        // 4. Снятие заглушения (Mute)
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmuted: UInt32 = (v > 0.001) ? 0 : 1
        if AudioObjectHasProperty(deviceID, &muteAddr) {
            _ = AudioObjectSetPropertyData(deviceID, &muteAddr, 0, nil, 4, &unmuted)
        }
        return didApply
    }
    
    /// Проверить, заглушено ли устройство (Mute)
    public static func isDeviceMuted(deviceID: AudioDeviceID) -> Bool {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &muteAddr) {
            let s = AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &size, &muted)
            if s == noErr { return muted != 0 }
        }
        return false
    }
}
