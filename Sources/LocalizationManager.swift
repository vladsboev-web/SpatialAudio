import Foundation
import Combine

public enum AppLanguage: String, CaseIterable, Codable {
    case ru = "ru"
    case en = "en"
    
    public var badgeTitle: String {
        switch self {
        case .ru: return "RU"
        case .en: return "EN"
        }
    }
}

public final class LocalizationManager: ObservableObject {
    public static let shared = LocalizationManager()
    
    private let languageKey = "SpatialAudio_App_Language"
    
    @Published public var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: languageKey)
            ProfileManager.shared.localizeDefaultProfileNameIfNeeded(for: language)
            AudioCoordinator.shared.refreshLocalizedStatus()
        }
    }
    
    private init() {
        if let saved = UserDefaults.standard.string(forKey: languageKey),
           let parsed = AppLanguage(rawValue: saved) {
            self.language = parsed
        } else {
            // Автоопределение при первом запуске по системному языку macOS
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            if preferred.hasPrefix("ru") {
                self.language = .ru
            } else {
                self.language = .en
            }
            UserDefaults.standard.set(self.language.rawValue, forKey: languageKey)
        }
    }
    
    public func toggleLanguage() {
        language = (language == .ru) ? .en : .ru
    }
}

public enum L10n {
    private static var isRU: Bool {
        LocalizationManager.shared.language == .ru
    }
    
    // MARK: - Header & Status
    public static var pausedBadge: String {
        isRU ? "Пауза" : "Paused"
    }
    
    public static var readyToStart: String {
        isRU ? "Готов к запуску" : "Ready to start"
    }
    
    public static var connecting: String {
        isRU ? "Подключение..." : "Connecting..."
    }
    
    public static var routingSystemAudio: String {
        isRU ? "Подключение к аудиосистеме..." : "Routing system audio..."
    }
    
    public static func connectingTo(_ name: String) -> String {
        isRU ? "Подключение к \(name)..." : "Connecting to \(name)..."
    }
    
    public static func spatialAudioMuted(_ name: String) -> String {
        isRU ? "Spatial Audio: \(name) (Заглушено)" : "Spatial Audio: \(name) (Muted)"
    }
    
    public static func spatialAudioActive(_ name: String, _ pct: Int) -> String {
        "Spatial Audio: \(name) (\(pct)%)"
    }
    
    public static func pausedOnDevice(_ name: String) -> String {
        isRU ? "Приостановлено (\(name))" : "Paused (\(name))"
    }
    
    public static var otherDevice: String {
        isRU ? "другое устройство" : "other device"
    }
    
    public static var headphonesFallback: String {
        isRU ? "Наушники" : "Headphones"
    }
    
    public static var devicesNotFound: String {
        isRU ? "Устройства не найдены" : "Audio devices not found"
    }
    
    public static func outputError(_ name: String) -> String {
        isRU ? "Ошибка вывода на \(name)" : "Output error on \(name)"
    }
    
    public static var stopped: String {
        isRU ? "Остановлено" : "Stopped"
    }
    
    // MARK: - BlackHole Banner
    public static var blackHoleRequiredTitle: String {
        isRU ? "Требуется драйвер BlackHole" : "BlackHole Driver Required"
    }
    
    public static var blackHoleRequiredDesc: String {
        isRU ? "Для перехвата звука с Mac установите драйвер BlackHole 2ch:" : "Install BlackHole 2ch driver to capture system audio on your Mac:"
    }
    
    public static var installBlackHoleBtn: String {
        isRU ? "Установить BlackHole (в 1 клик)" : "Install BlackHole (1-Click)"
    }
    
    // MARK: - Profiles
    public static var profileLabel: String {
        isRU ? "Профиль:" : "Profile:"
    }
    
    public static var defaultProfileName: String {
        isRU ? "Основной" : "Default"
    }
    
    public static func newProfileDefaultName(_ index: Int) -> String {
        isRU ? "Профиль \(index)" : "Profile \(index)"
    }
    
    public static var createProfileHelp: String {
        isRU ? "Создать новый профиль с текущими настройками" : "Create a new profile with current settings"
    }
    
    public static var renameProfileHelp: String {
        isRU ? "Переименовать текущий профиль" : "Rename active profile"
    }
    
    public static func deleteProfileHelp(_ canDelete: Bool) -> String {
        if canDelete {
            return isRU ? "Удалить текущий профиль" : "Delete active profile"
        } else {
            return isRU ? "Нельзя удалить единственный профиль" : "Cannot delete the only profile"
        }
    }
    
    public static var profileNamePlaceholder: String {
        isRU ? "Имя профиля" : "Profile name"
    }
    
    public static var newNamePlaceholder: String {
        isRU ? "Новое имя" : "New name"
    }
    
    public static var createBtn: String {
        isRU ? "Создать" : "Create"
    }
    
    public static var saveBtn: String {
        isRU ? "Сохранить" : "Save"
    }
    
    public static var cancelBtn: String {
        isRU ? "Отмена" : "Cancel"
    }
    
    // MARK: - Visualizer & Controls
    public static var listenerYou: String {
        isRU ? "Вы" : "You"
    }
    
    public static var spatialStereoTitle: String {
        isRU ? "Пространственное стерео" : "Spatial Stereo"
    }
    
    public static var spatialStereoSubtitle: String {
        isRU ? "Вынос звука из головы (Apple HRTF)" : "Out-of-head speaker soundstage (Apple HRTF)"
    }
    
    public static var stageWidthLabel: String {
        isRU ? "Ширина сцены (угол):" : "Soundstage Width (Angle):"
    }
    
    public static var roomAcousticsLabel: String {
        isRU ? "Акустика комнаты:" : "Room Acoustics:"
    }
    
    public static var inputLabel: String {
        isRU ? "Вход:" : "Input:"
    }
    
    public static var outputLabel: String {
        isRU ? "Выход:" : "Output:"
    }
    
    // MARK: - Actions & Menu
    public static var startBtn: String {
        isRU ? "Запустить" : "Start"
    }
    
    public static var stopBtn: String {
        isRU ? "Остановить" : "Stop"
    }
    
    public static var soundSettingsHelp: String {
        isRU ? "Настройки звука macOS" : "macOS Sound Settings"
    }
    
    public static var quitHelp: String {
        isRU ? "Выйти из приложения" : "Quit SpatialAudio"
    }
    
    public static var quitMenuTitle: String {
        isRU ? "Закрыть SpatialAudio" : "Quit SpatialAudio"
    }
    
    public static var languageToggleHelp: String {
        isRU ? "Переключить язык интерфейса (RU / EN)" : "Switch interface language (RU / EN)"
    }
}
