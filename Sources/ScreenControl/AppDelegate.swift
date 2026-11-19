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
    private var hotKey: HotKey?
    private var outsideClickMonitor: Any?
    /// The display whose menu bar the panel was opened from.
    private var anchorDisplay: CGDirectDisplayID?
    /// That display's size and scale when last seen, to tell a resolution change on it from
    /// changes on other displays.
    private var anchorMode: (size: NSSize, scale: CGFloat)?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "display", accessibilityDescription: "Displays")?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            image?.isTemplate = true
            button.image = image
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
    }

    // MARK: Status item

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            closePanel()
            showContextMenu()
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
        let statusWindows = NSApp.windows.filter { $0.className.contains("StatusBar") && $0.isVisible }
        guard let window = statusWindows.first(where: { Self.displayID(of: $0) == anchorDisplay }) else {
            closePanel()
            return
        }
        panel.place(below: window, animated: animated)
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
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        displays.setPanelVisible(false)
        keyboard.setPanelVisible(false)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let restore = NSMenuItem(title: "Turn Off Reduce Brightness", action: #selector(turnOffDimming), keyEquivalent: "b")
        restore.keyEquivalentModifierMask = [.control, .option, .command]
        restore.target = self
        restore.isEnabled = displays.displays.contains { $0.dimEnabled }
        menu.addItem(restore)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ScreenControl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
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
