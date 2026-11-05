import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let monitor = SystemMonitor()
    let settings = AppSettings()

    private var window: NSWindow!
    private var hostingView: NSHostingView<AnyView>!
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIcon.make()
        buildMainMenu()
        buildWindow()
        buildStatusItem()
        applyWindowPreferences()
        applyDockPreference()

        monitor.start(interval: settings.interval)

        settings.$interval.dropFirst().removeDuplicates()
            .sink { [weak self] in self?.monitor.start(interval: $0) }
            .store(in: &cancellables)
        settings.$alwaysOnTop.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyWindowPreferences() }
            .store(in: &cancellables)
        settings.$allSpaces.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyWindowPreferences() }
            .store(in: &cancellables)
        monitor.$snapshot
            .sink { [weak self] in self?.updateStatusItem($0) }
            .store(in: &cancellables)
        settings.$menuBar.receive(on: RunLoop.main)
            .sink { [weak self] _ in self.map { $0.updateStatusItem($0.monitor.snapshot) } }
            .store(in: &cancellables)

        showDashboard()
        if ProcessInfo.processInfo.environment["VITALS_DEBUG_STATUS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let item = self?.statusItem else { return }
                print("status item visible=\(item.isVisible) frame=\(item.button?.window?.frame ?? .zero) image=\(item.button?.image?.size ?? .zero)")
                fflush(stdout)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }

    // MARK: Window

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Vitals"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0x0d / 255, green: 0x0d / 255, blue: 0x0d / 255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 420)
        hostingView = NSHostingView(rootView: dashboard())
        window.contentView = hostingView
        // Stop rendering while the window is hidden, minimised or fully covered; history keeps
        // recording in the monitor, so the graphs are complete again when it reappears.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRenderingForVisibility() }
        }
        window.center()
        window.setFrameAutosaveName("VitalsDashboard")
    }

    private func dashboard() -> AnyView {
        AnyView(DashboardView(monitor: monitor, settings: settings))
    }

    private var isRendering = true

    private func updateRenderingForVisibility() {
        let visible = window.occlusionState.contains(.visible)
        guard visible != isRendering else { return }
        isRendering = visible
        hostingView.rootView = visible ? dashboard() : AnyView(Palette.page)
    }

    private func applyWindowPreferences() {
        window.level = settings.alwaysOnTop ? .floating : .normal
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary]
        behavior.insert(settings.allSpaces ? .canJoinAllSpaces : .managed)
        window.collectionBehavior = behavior
    }

    private func applyDockPreference() {
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
    }

    @objc func showDashboard() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu bar item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Dashboard", action: #selector(showDashboard), keyEquivalent: "").target = self
        menu.addItem(.separator())
        for item in preferenceItems() { menu.addItem(item) }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Vitals", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func updateStatusItem(_ s: Snapshot) {
        guard let button = statusItem?.button else { return }
        button.attributedTitle = NSAttributedString(string: "")
        if let image = MenuBarRenderer.image(for: s, items: settings.menuBar) {
            button.image = image
        } else {
            button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Vitals")
        }
        button.setAccessibilityLabel("Vitals: CPU \(Fmt.percent(s.cpu.total)), memory \(Fmt.percent(s.memory.usedFraction))")
    }

    // MARK: Menus

    /// Preference items shared by the menu bar menu and the app's View menu.
    private func preferenceItems() -> [NSMenuItem] {
        let menuBarMenu = NSMenu()
        for item in MenuBarItem.allCases {
            let mi = NSMenuItem(title: item.title, action: #selector(toggleMenuBarItem(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = item.rawValue
            menuBarMenu.addItem(mi)
        }
        let menuBar = NSMenuItem(title: "Menu Bar Shows", action: nil, keyEquivalent: "")
        menuBar.submenu = menuBarMenu

        let intervalMenu = NSMenu()
        for (title, value) in [("0.5 seconds", 0.5), ("1 second", 1.0), ("2 seconds", 2.0), ("5 seconds", 5.0)] {
            let mi = NSMenuItem(title: title, action: #selector(setInterval(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = value
            intervalMenu.addItem(mi)
        }
        let interval = NSMenuItem(title: "Update Interval", action: nil, keyEquivalent: "")
        interval.submenu = intervalMenu

        func toggle(_ title: String, _ action: Selector) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            return mi
        }
        return [menuBar, interval, .separator(),
                toggle("Keep Dashboard on Top", #selector(toggleOnTop)),
                toggle("Show Dashboard on All Spaces", #selector(toggleAllSpaces)),
                toggle("Show Dock Icon", #selector(toggleDockIcon)),
                toggle("Open at Login", #selector(toggleLoginItem))]
    }

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Vitals", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Vitals", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Vitals", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        for item in preferenceItems() { viewMenu.addItem(item) }
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Show Dashboard", action: #selector(showDashboard), keyEquivalent: "0").target = self
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    @objc private func toggleMenuBarItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let item = MenuBarItem(rawValue: raw) else { return }
        if settings.menuBar.contains(item) { settings.menuBar.remove(item) } else { settings.menuBar.insert(item) }
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { settings.interval = v }
    }

    @objc private func toggleOnTop() { settings.alwaysOnTop.toggle() }
    @objc private func toggleAllSpaces() { settings.allSpaces.toggle() }

    @objc private func toggleDockIcon() {
        settings.showDockIcon.toggle()
        applyDockPreference()
        showDashboard()
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can add Vitals manually in System Settings → General → Login Items."
            alert.runModal()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleMenuBarItem(_:)):
            let item = (menuItem.representedObject as? String).flatMap(MenuBarItem.init(rawValue:))
            menuItem.state = item.map { settings.menuBar.contains($0) } == true ? .on : .off
        case #selector(setInterval(_:)):
            menuItem.state = (menuItem.representedObject as? Double) == settings.interval ? .on : .off
        case #selector(toggleOnTop): menuItem.state = settings.alwaysOnTop ? .on : .off
        case #selector(toggleAllSpaces): menuItem.state = settings.allSpaces ? .on : .off
        case #selector(toggleDockIcon): menuItem.state = settings.showDockIcon ? .on : .off
        case #selector(toggleLoginItem): menuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        default: break
        }
        return true
    }
}
