import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Устанавливаем режим только в строке меню (без значка в Dock)
        NSApp.setActivationPolicy(.accessory)
        // Инициализируем аудио-координатор немедленно при старте
        _ = AudioCoordinator.shared
        menuBarController = MenuBarController()
        print("[SpatialAudio] Приложение запущено в строке меню")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        AudioCoordinator.shared.stopPipeline()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
