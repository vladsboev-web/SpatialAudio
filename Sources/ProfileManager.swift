import Foundation

public struct SpatialProfile: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var isSpatialEnabled: Bool
    public var speakerAngleDeg: Double
    public var distance: Double
    public var reverbBlend: Double
    public var volume: Double
    public var gainMultiplier: Double
    
    public init(
        id: UUID = UUID(),
        name: String,
        isSpatialEnabled: Bool = true,
        speakerAngleDeg: Double = 30.0,
        distance: Double = 1.0,
        reverbBlend: Double = 0.01,
        volume: Double = 1.0,
        gainMultiplier: Double = 1.25
    ) {
        self.id = id
        self.name = name
        self.isSpatialEnabled = isSpatialEnabled
        self.speakerAngleDeg = speakerAngleDeg
        self.distance = distance
        self.reverbBlend = reverbBlend
        self.volume = volume
        self.gainMultiplier = gainMultiplier
    }
}

public final class ProfileManager: ObservableObject {
    public static let shared = ProfileManager()
    
    private let profilesKey = "SpatialAudio_Profiles_List"
    private let activeProfileIDKey = "SpatialAudio_Active_Profile_ID"
    
    @Published public var profiles: [SpatialProfile] = []
    @Published public var activeProfileID: UUID = UUID()
    
    public var activeProfile: SpatialProfile? {
        profiles.first(where: { $0.id == activeProfileID }) ?? profiles.first
    }
    
    private init() {
        loadProfiles()
    }
    
    public func loadProfiles() {
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([SpatialProfile].self, from: data),
           !decoded.isEmpty {
            self.profiles = decoded
            // Миграция старых значений реверберации (> 3%)
            var didMigrate = false
            for i in 0..<self.profiles.count {
                if self.profiles[i].reverbBlend > 0.03 {
                    // Если стояло старое значение по умолчанию 6%, переводим на новое 1%
                    if abs(self.profiles[i].reverbBlend - 0.06) < 0.005 {
                        self.profiles[i].reverbBlend = 0.01
                    } else {
                        self.profiles[i].reverbBlend = min(0.03, self.profiles[i].reverbBlend)
                    }
                    didMigrate = true
                }
            }
            if didMigrate {
                saveProfiles()
            }
        } else {
            // Создаем единственный чистый начальный профиль без предустановок
            let defaultProfile = SpatialProfile(
                name: "Основной",
                isSpatialEnabled: true,
                speakerAngleDeg: 30.0,
                distance: 1.0,
                reverbBlend: 0.01,
                volume: 1.0,
                gainMultiplier: 1.25
            )
            self.profiles = [defaultProfile]
            saveProfiles()
        }
        
        if let savedIDString = UserDefaults.standard.string(forKey: activeProfileIDKey),
           let savedUUID = UUID(uuidString: savedIDString),
           profiles.contains(where: { $0.id == savedUUID }) {
            self.activeProfileID = savedUUID
        } else if let first = profiles.first {
            self.activeProfileID = first.id
            UserDefaults.standard.set(first.id.uuidString, forKey: activeProfileIDKey)
        }
    }
    
    public func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
        UserDefaults.standard.set(activeProfileID.uuidString, forKey: activeProfileIDKey)
    }
    
    // MARK: - CRUD операции
    
    /// Create: Создание нового профиля (копирует текущие настройки пользователя)
    @discardableResult
    public func createProfile(
        name: String,
        isSpatialEnabled: Bool = true,
        speakerAngleDeg: Double = 30.0,
        distance: Double = 1.0,
        reverbBlend: Double = 0.01,
        volume: Double = 1.0,
        gainMultiplier: Double = 1.25
    ) -> SpatialProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Профиль \(profiles.count + 1)" : trimmed
        
        let newProfile = SpatialProfile(
            name: finalName,
            isSpatialEnabled: isSpatialEnabled,
            speakerAngleDeg: speakerAngleDeg,
            distance: distance,
            reverbBlend: min(0.03, max(0.0, reverbBlend)),
            volume: volume,
            gainMultiplier: gainMultiplier
        )
        
        profiles.append(newProfile)
        activeProfileID = newProfile.id
        saveProfiles()
        return newProfile
    }
    
    /// Read / Select: Выбор профиля
    public func selectProfile(id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        UserDefaults.standard.set(id.uuidString, forKey: activeProfileIDKey)
    }
    
    /// Update: Сохранение настроек в активный профиль при движении ползунков
    public func updateActiveProfileSettings(
        isSpatialEnabled: Bool,
        speakerAngleDeg: Double,
        distance: Double,
        reverbBlend: Double,
        volume: Double,
        gainMultiplier: Double
    ) {
        guard let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        profiles[index].isSpatialEnabled = isSpatialEnabled
        profiles[index].speakerAngleDeg = speakerAngleDeg
        profiles[index].distance = distance
        profiles[index].reverbBlend = min(0.03, max(0.0, reverbBlend))
        profiles[index].volume = volume
        profiles[index].gainMultiplier = gainMultiplier
        saveProfiles()
    }
    
    /// Update: Переименование профиля
    public func renameProfile(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = trimmed
        saveProfiles()
    }
    
    /// Delete: Удаление профиля (минимум 1 профиль всегда сохраняется)
    @discardableResult
    public func deleteProfile(id: UUID) -> Bool {
        guard profiles.count > 1 else { return false }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        
        profiles.remove(at: index)
        
        if activeProfileID == id {
            let nextIndex = min(index, profiles.count - 1)
            activeProfileID = profiles[nextIndex].id
        }
        
        saveProfiles()
        return true
    }
}
