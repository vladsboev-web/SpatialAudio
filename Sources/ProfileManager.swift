import Foundation

public struct SpatialProfile: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var isSpatialEnabled: Bool
    public var speakerAngleDeg: Double
    public var distance: Double? = 1.0
    public var reverbBlend: Double
    public var volume: Double
    public var gainMultiplier: Double?
    public var isSpeakerMode: Bool? = false
    public var physicalSpeakerAngleDeg: Double? = 22.5
    
    public init(
        id: UUID = UUID(),
        name: String,
        isSpatialEnabled: Bool = true,
        speakerAngleDeg: Double = 30.0,
        distance: Double? = 1.0,
        reverbBlend: Double = 0.01,
        volume: Double = 1.0,
        gainMultiplier: Double? = 1.0,
        isSpeakerMode: Bool? = false,
        physicalSpeakerAngleDeg: Double? = 22.5
    ) {
        self.id = id
        self.name = name
        self.isSpatialEnabled = isSpatialEnabled
        self.speakerAngleDeg = speakerAngleDeg
        self.distance = distance ?? 1.0
        self.reverbBlend = reverbBlend
        self.volume = volume
        self.gainMultiplier = gainMultiplier
        self.isSpeakerMode = isSpeakerMode ?? false
        self.physicalSpeakerAngleDeg = physicalSpeakerAngleDeg ?? 22.5
    }
}

public final class ProfileManager: ObservableObject {
    public static let shared = ProfileManager()
    
    // Раздельные хранилища профилей для режима Наушников и режима Колонок
    private let headphoneProfilesKey = "SpatialAudio_Headphone_Profiles_List"
    private let activeHeadphoneProfileIDKey = "SpatialAudio_Active_Headphone_Profile_ID"
    private let speakerProfilesKey = "SpatialAudio_Speaker_Profiles_List"
    private let activeSpeakerProfileIDKey = "SpatialAudio_Active_Speaker_Profile_ID"
    private let lastActiveModeKey = "SpatialAudio_Last_Active_SpeakerMode"
    
    // Legacy-ключи для мягкой миграции старых профилей
    private let legacyProfilesKey = "SpatialAudio_Profiles_List"
    private let legacyActiveProfileIDKey = "SpatialAudio_Active_Profile_ID"
    
    @Published public var headphoneProfiles: [SpatialProfile] = []
    @Published public var activeHeadphoneProfileID: UUID = UUID()
    
    @Published public var speakerProfiles: [SpatialProfile] = []
    @Published public var activeSpeakerProfileID: UUID = UUID()
    
    /// Текущий выбранный режим (false = Наушники, true = Колонки), синхронизированный со списком профилей
    @Published public var currentModeIsSpeaker: Bool = false
    
    /// Профили текущего активного режима (Наушники или Колонки)
    public var profiles: [SpatialProfile] {
        currentModeIsSpeaker ? speakerProfiles : headphoneProfiles
    }
    
    /// ID активного профиля в текущем режиме
    public var activeProfileID: UUID {
        currentModeIsSpeaker ? activeSpeakerProfileID : activeHeadphoneProfileID
    }
    
    /// Активный профиль текущего режима
    public var activeProfile: SpatialProfile? {
        let list = profiles
        let targetID = activeProfileID
        return list.first(where: { $0.id == targetID }) ?? list.first
    }
    
    private init() {
        loadProfiles()
    }
    
    private static func makeDefaultHeadphoneProfile(isRU: Bool) -> SpatialProfile {
        SpatialProfile(
            name: isRU ? "Стандартный" : "Default",
            isSpatialEnabled: true,
            speakerAngleDeg: 30.0,
            distance: 1.0,
            reverbBlend: 0.01,
            volume: 1.0,
            gainMultiplier: 1.0,
            isSpeakerMode: false,
            physicalSpeakerAngleDeg: 22.5
        )
    }
    
    private static func makeDefaultSpeakerProfile(isRU: Bool) -> SpatialProfile {
        SpatialProfile(
            name: isRU ? "Стандартный" : "Default",
            isSpatialEnabled: true,
            speakerAngleDeg: 30.0,
            distance: 1.0,
            reverbBlend: 0.01,
            volume: 1.0,
            gainMultiplier: 1.0,
            isSpeakerMode: true,
            physicalSpeakerAngleDeg: 22.5
        )
    }
    
    private static let defaultProfileNames: Set<String> = ["Основной", "Стандартный", "Default"]
    
    private static func normalizeDefaultName(_ name: String, isRU: Bool) -> String {
        if defaultProfileNames.contains(name) {
            return isRU ? "Стандартный" : "Default"
        }
        return name
    }
    
    public func loadProfiles() {
        let isRU = (Locale.preferredLanguages.first?.lowercased().hasPrefix("ru") == true)
        let defaults = UserDefaults.standard
        
        if defaults.object(forKey: lastActiveModeKey) != nil {
            self.currentModeIsSpeaker = defaults.bool(forKey: lastActiveModeKey)
        }
        
        var loadedHP: [SpatialProfile] = []
        var loadedSP: [SpatialProfile] = []
        
        if let hpData = defaults.data(forKey: headphoneProfilesKey),
           let decodedHP = try? JSONDecoder().decode([SpatialProfile].self, from: hpData),
           !decodedHP.isEmpty {
            loadedHP = decodedHP
        }
        
        if let spData = defaults.data(forKey: speakerProfilesKey),
           let decodedSP = try? JSONDecoder().decode([SpatialProfile].self, from: spData),
           !decodedSP.isEmpty {
            loadedSP = decodedSP
        }
        
        // Миграция из старого единого списка, если новые списки ещё не созданы
        if loadedHP.isEmpty && loadedSP.isEmpty,
           let legacyData = defaults.data(forKey: legacyProfilesKey),
           let legacyDecoded = try? JSONDecoder().decode([SpatialProfile].self, from: legacyData),
           !legacyDecoded.isEmpty {
            for var p in legacyDecoded {
                p.reverbBlend = min(0.03, max(0.0, p.reverbBlend > 0.03 ? 0.01 : p.reverbBlend))
                p.name = Self.normalizeDefaultName(p.name, isRU: isRU)
                if p.isSpeakerMode == true {
                    loadedSP.append(p)
                } else {
                    p.isSpeakerMode = false
                    loadedHP.append(p)
                }
            }
        }
        
        // Гарантируем наличие индивидуального профиля «Стандартный» для Наушников
        if loadedHP.isEmpty {
            loadedHP = [Self.makeDefaultHeadphoneProfile(isRU: isRU)]
        } else {
            for i in 0..<loadedHP.count {
                loadedHP[i].isSpeakerMode = false
                loadedHP[i].reverbBlend = min(0.03, max(0.0, loadedHP[i].reverbBlend))
                loadedHP[i].name = Self.normalizeDefaultName(loadedHP[i].name, isRU: isRU)
            }
        }
        
        // Гарантируем наличие индивидуального профиля «Стандартный» для Колонок
        if loadedSP.isEmpty {
            loadedSP = [Self.makeDefaultSpeakerProfile(isRU: isRU)]
        } else {
            for i in 0..<loadedSP.count {
                loadedSP[i].isSpeakerMode = true
                loadedSP[i].reverbBlend = min(0.03, max(0.0, loadedSP[i].reverbBlend))
                loadedSP[i].name = Self.normalizeDefaultName(loadedSP[i].name, isRU: isRU)
            }
        }
        
        self.headphoneProfiles = loadedHP
        self.speakerProfiles = loadedSP
        
        if let savedHPIDStr = defaults.string(forKey: activeHeadphoneProfileIDKey),
           let savedHPUUID = UUID(uuidString: savedHPIDStr),
           loadedHP.contains(where: { $0.id == savedHPUUID }) {
            self.activeHeadphoneProfileID = savedHPUUID
        } else if let legacyIDStr = defaults.string(forKey: legacyActiveProfileIDKey),
                  let legacyUUID = UUID(uuidString: legacyIDStr),
                  loadedHP.contains(where: { $0.id == legacyUUID }) {
            self.activeHeadphoneProfileID = legacyUUID
        } else if let firstHP = loadedHP.first {
            self.activeHeadphoneProfileID = firstHP.id
        }
        
        if let savedSPIDStr = defaults.string(forKey: activeSpeakerProfileIDKey),
           let savedSPUUID = UUID(uuidString: savedSPIDStr),
           loadedSP.contains(where: { $0.id == savedSPUUID }) {
            self.activeSpeakerProfileID = savedSPUUID
        } else if let firstSP = loadedSP.first {
            self.activeSpeakerProfileID = firstSP.id
        }
        
        saveProfiles()
    }
    
    public func saveProfiles() {
        let defaults = UserDefaults.standard
        if let hpData = try? JSONEncoder().encode(headphoneProfiles) {
            defaults.set(hpData, forKey: headphoneProfilesKey)
        }
        if let spData = try? JSONEncoder().encode(speakerProfiles) {
            defaults.set(spData, forKey: speakerProfilesKey)
        }
        defaults.set(activeHeadphoneProfileID.uuidString, forKey: activeHeadphoneProfileIDKey)
        defaults.set(activeSpeakerProfileID.uuidString, forKey: activeSpeakerProfileIDKey)
        defaults.set(currentModeIsSpeaker, forKey: lastActiveModeKey)
    }
    
    /// Переключение активного набора профилей при смене режима Наушники <-> Колонки
    @discardableResult
    public func switchMode(isSpeakerMode: Bool) -> SpatialProfile? {
        if currentModeIsSpeaker != isSpeakerMode {
            currentModeIsSpeaker = isSpeakerMode
            UserDefaults.standard.set(isSpeakerMode, forKey: lastActiveModeKey)
        }
        return activeProfile
    }
    
    // MARK: - CRUD операции (индивидуально для активного режима Наушники или Колонки)
    
    @discardableResult
    public func createProfile(
        name: String,
        isSpatialEnabled: Bool = true,
        speakerAngleDeg: Double = 30.0,
        reverbBlend: Double = 0.01,
        volume: Double = 1.0,
        isSpeakerMode: Bool = false,
        physicalSpeakerAngleDeg: Double = 22.5
    ) -> SpatialProfile {
        let currentList = isSpeakerMode ? speakerProfiles : headphoneProfiles
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? L10n.newProfileDefaultName(currentList.count + 1) : trimmed
        
        let newProfile = SpatialProfile(
            name: finalName,
            isSpatialEnabled: isSpatialEnabled,
            speakerAngleDeg: speakerAngleDeg,
            distance: 1.0,
            reverbBlend: min(0.03, max(0.0, reverbBlend)),
            volume: volume,
            gainMultiplier: 1.0,
            isSpeakerMode: isSpeakerMode,
            physicalSpeakerAngleDeg: physicalSpeakerAngleDeg
        )
        
        if isSpeakerMode {
            speakerProfiles.append(newProfile)
            activeSpeakerProfileID = newProfile.id
        } else {
            headphoneProfiles.append(newProfile)
            activeHeadphoneProfileID = newProfile.id
        }
        saveProfiles()
        return newProfile
    }
    
    public func selectProfile(id: UUID) {
        if currentModeIsSpeaker {
            guard speakerProfiles.contains(where: { $0.id == id }) else { return }
            activeSpeakerProfileID = id
            UserDefaults.standard.set(id.uuidString, forKey: activeSpeakerProfileIDKey)
        } else {
            guard headphoneProfiles.contains(where: { $0.id == id }) else { return }
            activeHeadphoneProfileID = id
            UserDefaults.standard.set(id.uuidString, forKey: activeHeadphoneProfileIDKey)
        }
    }
    
    public func updateActiveProfileSettings(
        isSpatialEnabled: Bool,
        speakerAngleDeg: Double,
        reverbBlend: Double,
        volume: Double,
        isSpeakerMode: Bool = false,
        physicalSpeakerAngleDeg: Double = 22.5
    ) {
        if isSpeakerMode {
            guard let index = speakerProfiles.firstIndex(where: { $0.id == activeSpeakerProfileID }) else { return }
            speakerProfiles[index].isSpatialEnabled = isSpatialEnabled
            speakerProfiles[index].reverbBlend = min(0.03, max(0.0, reverbBlend))
            speakerProfiles[index].volume = volume
            speakerProfiles[index].isSpeakerMode = true
            speakerProfiles[index].physicalSpeakerAngleDeg = physicalSpeakerAngleDeg
        } else {
            guard let index = headphoneProfiles.firstIndex(where: { $0.id == activeHeadphoneProfileID }) else { return }
            headphoneProfiles[index].isSpatialEnabled = isSpatialEnabled
            headphoneProfiles[index].speakerAngleDeg = speakerAngleDeg
            headphoneProfiles[index].reverbBlend = min(0.03, max(0.0, reverbBlend))
            headphoneProfiles[index].volume = volume
            headphoneProfiles[index].isSpeakerMode = false
        }
        saveProfiles()
    }
    
    public func renameProfile(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if currentModeIsSpeaker {
            guard let index = speakerProfiles.firstIndex(where: { $0.id == id }) else { return }
            speakerProfiles[index].name = trimmed
        } else {
            guard let index = headphoneProfiles.firstIndex(where: { $0.id == id }) else { return }
            headphoneProfiles[index].name = trimmed
        }
        saveProfiles()
    }
    
    /// Автоматический перевод имени стандартного профиля при переключении языка RU <-> EN
    public func localizeDefaultProfileNameIfNeeded(for lang: AppLanguage) {
        let isRU = (lang == .ru)
        var changed = false
        
        for i in 0..<headphoneProfiles.count {
            let normalized = Self.normalizeDefaultName(headphoneProfiles[i].name, isRU: isRU)
            if headphoneProfiles[i].name != normalized {
                headphoneProfiles[i].name = normalized
                changed = true
            }
        }
        for i in 0..<speakerProfiles.count {
            let normalized = Self.normalizeDefaultName(speakerProfiles[i].name, isRU: isRU)
            if speakerProfiles[i].name != normalized {
                speakerProfiles[i].name = normalized
                changed = true
            }
        }
        if changed {
            saveProfiles()
        }
    }
    
    @discardableResult
    public func deleteProfile(id: UUID) -> Bool {
        if currentModeIsSpeaker {
            guard speakerProfiles.count > 1,
                  let index = speakerProfiles.firstIndex(where: { $0.id == id }) else { return false }
            speakerProfiles.remove(at: index)
            if activeSpeakerProfileID == id {
                let nextIndex = min(index, speakerProfiles.count - 1)
                activeSpeakerProfileID = speakerProfiles[nextIndex].id
            }
        } else {
            guard headphoneProfiles.count > 1,
                  let index = headphoneProfiles.firstIndex(where: { $0.id == id }) else { return false }
            headphoneProfiles.remove(at: index)
            if activeHeadphoneProfileID == id {
                let nextIndex = min(index, headphoneProfiles.count - 1)
                activeHeadphoneProfileID = headphoneProfiles[nextIndex].id
            }
        }
        saveProfiles()
        return true
    }
}
