import AppKit
import SwiftUI
import Combine

public final class MenuBarController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    private var windowMoveObserver: Any?
    private var isAdjustingFrame = false
    
    public override init() {
        super.init()
        setupMenuBar()
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        updateStatusButton(isRunning: AudioCoordinator.shared.isRunning)
        
        AudioCoordinator.shared.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                self?.updateStatusButton(isRunning: running)
            }
            .store(in: &cancellables)
        
        if let button = statusItem?.button {
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        let pop = NSPopover()
        pop.contentSize = NSSize(width: 320, height: 575)
        pop.behavior = .transient
        pop.animates = false
        pop.delegate = self
        pop.contentViewController = NSHostingController(rootView: SpatialControlView())
        self.popover = pop
    }
    
    private func updateStatusButton(isRunning: Bool) {
        guard let button = statusItem?.button else { return }
        let symbolName = isRunning ? "person.wave.2.fill" : "person.wave.2"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: isRunning ? .semibold : .medium)
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Spatial Audio")?.withSymbolConfiguration(config) {
            img.isTemplate = true
            button.image = img
            button.title = ""
        } else {
            button.title = isRunning ? "🔊" : "🔈"
        }
    }
    
    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp ||
            (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        
        if isRightClick {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }
    
    private func showContextMenu() {
        if let pop = popover, pop.isShown {
            pop.performClose(nil)
        }
        
        let menu = NSMenu()
        menu.delegate = self
        
        let isRunning = AudioCoordinator.shared.isRunning
        let toggleTitle = isRunning ? "Остановить" : "Запустить"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(togglePlayback), keyEquivalent: "")
        toggleItem.target = self
        if let icon = NSImage(systemSymbolName: isRunning ? "stop.fill" : "play.fill", accessibilityDescription: nil) {
            toggleItem.image = icon
        }
        menu.addItem(toggleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Закрыть SpatialAudio", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        if let icon = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil) {
            quitItem.image = icon
        }
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
    }
    
    public func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
    }
    
    @objc private func togglePlayback() {
        AudioCoordinator.shared.toggle()
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
    
    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let pop = popover, let button = statusItem?.button else { return }
        
        if pop.isShown {
            pop.performClose(sender)
        } else {
            AudioCoordinator.shared.refreshDevices()
            
            NSApp.activate(ignoringOtherApps: true)
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            
            if let window = pop.contentViewController?.view.window {
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.level = .floating
                window.makeKey()
                clampWindowToScreen(window: window)
                
                if windowMoveObserver == nil {
                    windowMoveObserver = NotificationCenter.default.addObserver(
                        forName: NSWindow.didMoveNotification,
                        object: window,
                        queue: .main
                    ) { [weak self, weak window] _ in
                        guard let window = window else { return }
                        self?.clampWindowToScreen(window: window)
                    }
                }
            }
        }
    }
    
    private func clampWindowToScreen(window: NSWindow) {
        guard !isAdjustingFrame else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        var frame = window.frame
        let topBoundary = screen.frame.maxY
        
        if frame.maxY > topBoundary {
            isAdjustingFrame = true
            frame.origin.y = topBoundary - frame.size.height
            window.setFrame(frame, display: true)
            isAdjustingFrame = false
        }
    }
    
    // MARK: - NSPopoverDelegate (Управление активностью UI для 0% нагрузки в фоне)
    
    public func popoverWillShow(_ notification: Notification) {
        AudioCoordinator.shared.isUIVisible = true
    }
    
    public func popoverDidClose(_ notification: Notification) {
        AudioCoordinator.shared.isUIVisible = false
        if let obs = windowMoveObserver {
            NotificationCenter.default.removeObserver(obs)
            windowMoveObserver = nil
        }
    }
}
