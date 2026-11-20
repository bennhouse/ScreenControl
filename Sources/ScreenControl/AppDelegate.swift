import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PanelWindow!
    private let displays = DisplayController()
    private let toggles = SystemToggles()
    private let keyboard = KeyboardBacklight()
    private let keepAwake = KeepAwake()
    private var hotKey: HotKey?
    private var outsideClickMonitor: Any?
    /// The display whose menu bar the panel was opened from.
    private var anchorDisplay: CGDirectDisplayID?
    /// That display's size and scale when last seen, to tell a resolution change on it from
    /// changes on other displays.
    private var anchorMode: (size: NSSize, scale: CGFloat)?
    /// Pending move of the panel to another screen (its own display was turned off).
    private var relocateWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = StatusIcon.image(keepAwake: false)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        let view = PanelView(displays: displays, toggles: toggles, keyboard: keyboard, onOpenSettings: { [weak self] in
            self?.closePanel()
            if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        })
        panel = PanelWindow(content: view)
        panel.onClose = { [weak self] in self?.closePanel() }

        displays.start()
        toggles.start()
        displays.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.panel.isVisible else { return }
                DispatchQueue.main.async { self.followAnchor(animated: true) }
            }
            .store(in: &cancellables)
        // macOS moves open windows when a display comes or goes: put the panel back.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            // Moving to another screen: every change restarts the wait for things to settle.
            if self.relocateWork != nil {
                self.relocatePanel()
                return
            }
            let mode = self.anchorScreen().map { (size: $0.frame.size, scale: $0.backingScaleFactor) }
            let resized = mode.map { $0.size != self.anchorMode?.size || $0.scale != self.anchorMode?.scale } ?? false
            self.anchorMode = mode ?? self.anchorMode
            self.followAnchor(animated: false)
            guard resized else {
                // Another display changed: just stay in place (the status item windows are
                // rebuilt a moment later).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.followAnchor(animated: false) }
                return
            }
            // The panel's own screen changed resolution, which blanks every window for a
            // moment. Hide the panel, put it back under its icon once the status item windows
            // are rebuilt, then fade it in instead of letting it pop back.
            self.panel.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.followAnchor(animated: false)
                guard self.panel.isVisible else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.panel.animator().alphaValue = 1
                }
            }
        }

        // ⌃⌥⌘B turns "Reduce brightness" off on every display.
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | optionKey | controlKey)) { [weak self] in
            self?.displays.disableAllDimming()
        }

        // Keep Awake: the coffee cup on the icon while it is on, and its shortcut (⇧⌘L by default).
        keepAwake.registerShortcut()
        keepAwake.$isActive
            .removeDuplicates()
            .sink { [weak self] active in self?.statusItem.button?.image = StatusIcon.image(keepAwake: active) }
            .store(in: &cancellables)
        SettingsWindow.shared.keepAwake = keepAwake
        NSApp.mainMenu = makeMainMenu()

        if ProcessInfo.processInfo.environment["SCREENCONTROL_OPEN_PANEL"] == "1" {
            // Development aid: open the panel at launch (for screenshots). Login item untouched.
            if ProcessInfo.processInfo.environment["SCREENCONTROL_APPEARANCE"] == "dark" {
                NSApp.appearance = NSAppearance(named: .darkAqua)
            }
            let delay = Double(ProcessInfo.processInfo.environment["SCREENCONTROL_OPEN_DELAY"] ?? "") ?? 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.openPanel()
                if let path = ProcessInfo.processInfo.environment["SCREENCONTROL_CAPTURE"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        SelfTest.capture(windowNumber: self.panel.windowNumber, to: path)
                    }
                }
            }
            return
        }
        setUpLaunchAtLoginOnce()
    }

    func applicationWillTerminate(_ notification: Notification) {
        displays.stop()
        keepAwake.stop()
    }

    /// A menu bar app shows no menu bar, but its main menu still handles the standard key
    /// equivalents (⌘W, ⌘Q, editing) while the Settings window is in front.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "ScreenControl")
        appMenu.addItem(NSMenuItem(title: "Quit ScreenControl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }

    // MARK: Status item

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            closePanel()
            showContextMenu(trigger: event)
        } else if panel.isVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        guard let button = statusItem.button else { return }
        let clicked = NSApp.currentEvent?.window
        guard let statusWindow = (clicked?.className.contains("StatusBar") == true ? clicked : nil) ?? button.window else { return }
        toggles.refresh()
        displays.setPanelVisible(true)
        keyboard.setPanelVisible(true)
        toggles.setPanelVisible(true)
        anchorDisplay = Self.displayID(of: statusWindow)
        anchorMode = statusWindow.screen.map { (size: $0.frame.size, scale: $0.backingScaleFactor) }
        panel.show(below: statusWindow)
        button.highlight(true)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    /// Keeps the panel under its status item, at the right height; closes it if that menu bar
    /// has gone (its display was turned off).
    private func followAnchor(animated: Bool) {
        guard panel.isVisible else { return }
        guard let window = statusWindows().first(where: { Self.displayID(of: $0) == anchorDisplay }) else {
            relocatePanel()
            return
        }
        guard relocateWork == nil else { return } // moving to another screen: wait for it
        panel.place(below: window, animated: animated)
    }

    private func statusWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.className.contains("StatusBar") && $0.isVisible }
    }

    /// The panel's display was turned off. Hide the panel, wait until the displays have
    /// settled (resolution changes, menu bars rebuilt; every new change restarts the wait),
    /// then fade it in under the status item of the main display.
    private func relocatePanel() {
        panel.alphaValue = 0
        relocateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishRelocation() }
        relocateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func finishRelocation() {
        relocateWork = nil
        guard panel.isVisible else { return }
        let windows = statusWindows()
        guard let window = windows.first(where: { $0.screen == NSScreen.screens.first }) ?? windows.first else {
            closePanel()
            return
        }
        anchorDisplay = Self.displayID(of: window)
        anchorMode = window.screen.map { (size: $0.frame.size, scale: $0.backingScaleFactor) }
        panel.place(below: window, animated: false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func anchorScreen() -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == anchorDisplay
        }
    }

    private static func displayID(of window: NSWindow) -> CGDirectDisplayID? {
        (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        relocateWork?.cancel()
        relocateWork = nil
        panel.orderOut(nil)
        panel.alphaValue = 1
        statusItem.button?.highlight(false)
        displays.setPanelVisible(false)
        keyboard.setPanelVisible(false)
        toggles.setPanelVisible(false)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func showContextMenu(trigger: NSEvent?) {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()

        // Keep Awake, laid out like Vorssaint's menu: a switch, then a submenu of durations.
        let toggle = NSMenuItem(title: keepAwake.isActive ? "Turn Off Keep Awake" : "Turn On Keep Awake",
                                action: #selector(toggleKeepAwake), keyEquivalent: "")
        toggle.target = self
        if keepAwake.shortcutActive {
            toggle.keyEquivalent = keepAwake.shortcut.menuKeyEquivalent
            toggle.keyEquivalentModifierMask = keepAwake.shortcut.flags
        }
        menu.addItem(toggle)
        let forItem = NSMenuItem(title: "Turn On For…", action: nil, keyEquivalent: "")
        let durations = NSMenu()
        for (index, duration) in KeepAwake.durations.enumerated() {
            let item = NSMenuItem(title: duration.title, action: #selector(keepAwakeFor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            durations.addItem(item)
        }
        forItem.submenu = durations
        menu.addItem(forItem)
        if keepAwake.isActive {
            let status: String
            if let end = keepAwake.endDate {
                let time = end.formatted(date: Calendar.current.isDateInToday(end) ? .omitted : .abbreviated, time: .shortened)
                status = "Keeping awake until \(time)"
            } else {
                status = "Keeping awake until turned off"
            }
            let info = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(.separator())

        let restore = NSMenuItem(title: "Turn Off Reduce Brightness", action: #selector(turnOffDimming), keyEquivalent: "b")
        restore.keyEquivalentModifierMask = [.control, .option, .command]
        restore.target = self
        restore.isEnabled = displays.displays.contains { $0.dimEnabled }
        menu.addItem(restore)

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ScreenControl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        // The menu opened on mouse down and took the mouse up, while the status button is still
        // tracking that click: hand it the mouse up, so it stops tracking and the app goes back to
        // its normal event loop. Otherwise global shortcuts wait for the next click.
        if let trigger, let window = button.window,
           let up = NSEvent.mouseEvent(with: trigger.type == .rightMouseDown ? .rightMouseUp : .leftMouseUp,
                                       location: trigger.locationInWindow, modifierFlags: trigger.modifierFlags,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
            NSApp.postEvent(up, atStart: true)
        }
    }

    @objc private func toggleKeepAwake() {
        keepAwake.toggle()
    }

    @objc private func keepAwakeFor(_ sender: NSMenuItem) {
        keepAwake.start(minutes: KeepAwake.durations[sender.tag].minutes)
    }

    @objc private func openSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func turnOffDimming() {
        displays.disableAllDimming()
    }

    // MARK: Launch at login

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else {
                NSSound.beep()
            }
        }
    }

    private func setUpLaunchAtLoginOnce() {
        let key = "didSetUpLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }
}
