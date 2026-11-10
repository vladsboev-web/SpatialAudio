import AppKit
import SwiftUI
import Combine
import QuartzCore

/// Кастомная плавающая панель в стиле macOS Control Center (принимает фокус ввода для TextField при создании/переименовании профилей)
private final class FloatingControlPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

public final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var panel: FloatingControlPanel?
    private var hostingController: NSHostingController<SpatialControlView>?
    private var cancellables = Set<AnyCancellable>()
    
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var appResignObserver: Any?
    
    private var isPanelOpen = false
    private var isAnimatingClose = false
    private var closeWorkItem: DispatchWorkItem?
    
    public override init() {
        super.init()
        setupMenuBar()
    }
    
    deinit {
        removeEventMonitors()
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
        
        let host = NSHostingController(rootView: SpatialControlView())
        if #available(macOS 13.0, *) {
            host.sizingOptions = [.intrinsicContentSize]
        }
        host.view.wantsLayer = true
        host.view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        self.hostingController = host
        
        let p = FloatingControlPanel(
            contentRect: NSRect(x: 0, y: 0, width: 344, height: 530),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.contentViewController = host
        self.panel = p
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
            togglePanel()
        }
    }
    
    private func showContextMenu() {
        if isPanelOpen {
            closePanelAnimated()
        }
        
        let menu = NSMenu()
        menu.delegate = self
        
        let isRunning = AudioCoordinator.shared.isRunning
        let toggleTitle = isRunning ? L10n.stopBtn : L10n.startBtn
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(togglePlayback), keyEquivalent: "")
        toggleItem.target = self
        if let icon = NSImage(systemSymbolName: isRunning ? "stop.fill" : "play.fill", accessibilityDescription: nil) {
            toggleItem.image = icon
        }
        menu.addItem(toggleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: L10n.quitMenuTitle, action: #selector(quitApp), keyEquivalent: "q")
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
    
    private func togglePanel() {
        if isPanelOpen && !isAnimatingClose {
            closePanelAnimated()
        } else {
            openPanelAnimated()
        }
    }
    
    private func calculateTargetFrame(for panel: NSPanel, relativeTo button: NSStatusBarButton) -> NSRect {
        hostingController?.view.layoutSubtreeIfNeeded()
        let fittingSize = hostingController?.view.fittingSize ?? NSSize(width: 344, height: 530)
        let panelWidth: CGFloat = max(344, fittingSize.width)
        let panelHeight: CGFloat = max(480, fittingSize.height)
        
        guard let buttonWindow = button.window else {
            return NSRect(x: 100, y: 100, width: panelWidth, height: panelHeight)
        }
        
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = buttonWindow.convertToScreen(buttonRectInWindow)
        let screen = buttonWindow.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let fullFrame = screen?.frame ?? visibleFrame
        
        var x = round(buttonRectOnScreen.midX - panelWidth / 2.0)
        let minX = fullFrame.minX + 10.0
        let maxX = fullFrame.maxX - panelWidth - 10.0
        x = max(minX, min(maxX, x))
        
        // Размещаем панель ровно на 6pt ниже строки меню
        let y = round(buttonRectOnScreen.minY - panelHeight - 6.0)
        return NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
    }
    
    private func openPanelAnimated() {
        guard let panel = panel, let button = statusItem?.button else { return }
        
        closeWorkItem?.cancel()
        closeWorkItem = nil
        isAnimatingClose = false
        
        // Выставляем финальный frame ОДИН раз до показа, чтобы WindowServer не пересчитывал текстуру тени в каждом кадре
        let targetFrame = calculateTargetFrame(for: panel, relativeTo: button)
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: false)
        }
        
        AudioCoordinator.shared.isUIVisible = true
        isPanelOpen = true
        
        panel.alphaValue = 0.0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        
        // Чистая аппаратная GPU-анимация CoreAnimation на слое (120 Гц без пересчёта геометрии SwiftUI и тени окна)
        if let layer = panel.contentView?.layer {
            layer.removeAllAnimations()
            
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = 8.0
            slide.toValue = 0.0
            slide.duration = 0.14
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            layer.add(slide, forKey: "openSlide")
        }
        
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            panel.animator().alphaValue = 1.0
        }
        
        installEventMonitors()
        
        // Обновляем список аудиоустройств уже после завершения анимации открытия, чтобы не блокировать главный поток
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard self?.isPanelOpen == true else { return }
            AudioCoordinator.shared.refreshDevices()
        }
    }
    
    public func closePanelAnimated() {
        guard let panel = panel, isPanelOpen, !isAnimatingClose else { return }
        
        isAnimatingClose = true
        removeEventMonitors()
        
        // Останавливаем фоновые волны сразу в начале закрытия, чтобы освободить GPU для самой анимации закрытия
        AudioCoordinator.shared.isUIVisible = false
        
        if let layer = panel.contentView?.layer {
            layer.removeAllAnimations()
            
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = 0.0
            slide.toValue = 6.0
            slide.duration = 0.11
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0)
            layer.add(slide, forKey: "closeSlide")
        }
        
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.11
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0)
            panel.animator().alphaValue = 0.0
        }
        
        let workItem = DispatchWorkItem { [weak self, weak panel] in
            guard let self = self else { return }
            panel?.orderOut(nil)
            panel?.alphaValue = 1.0
            panel?.contentView?.layer?.removeAllAnimations()
            self.isPanelOpen = false
            self.isAnimatingClose = false
        }
        closeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.115, execute: workItem)
    }
    
    private func installEventMonitors() {
        removeEventMonitors()
        
        // Закрытие при клике в любое место экрана вне панели (и вне иконки статус-бара)
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let panel = self.panel else { return }
            let mouseLoc = NSEvent.mouseLocation
            if !panel.frame.contains(mouseLoc) {
                if let buttonWindow = self.statusItem?.button?.window,
                   buttonWindow.frame.contains(mouseLoc) {
                    return
                }
                self.closePanelAnimated()
            }
        }
        
        // Закрытие по клавише Escape
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.closePanelAnimated()
                return nil
            }
            return event
        }
        
        // Закрытие при переключении фокуса на другое приложение
        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.closePanelAnimated()
        }
    }
    
    private func removeEventMonitors() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        if let obs = appResignObserver {
            NotificationCenter.default.removeObserver(obs)
            appResignObserver = nil
        }
    }
}
