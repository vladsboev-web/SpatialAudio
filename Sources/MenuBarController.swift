import AppKit
import SwiftUI
import Combine

public final class MenuBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    
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
            button.action = #selector(togglePopover(_:))
        }
        
        let pop = NSPopover()
        pop.contentSize = NSSize(width: 320, height: 575)
        pop.behavior = .transient
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
    
    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let pop = popover, let button = statusItem?.button else { return }
        
        if pop.isShown {
            pop.performClose(sender)
        } else {
            AudioCoordinator.shared.refreshDevices()
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            pop.contentViewController?.view.window?.makeKey()
        }
    }
    
    // MARK: - NSPopoverDelegate (Управление активностью UI для 0% нагрузки в фоне)
    
    public func popoverWillShow(_ notification: Notification) {
        AudioCoordinator.shared.isUIVisible = true
    }
    
    public func popoverDidClose(_ notification: Notification) {
        AudioCoordinator.shared.isUIVisible = false
    }
}
