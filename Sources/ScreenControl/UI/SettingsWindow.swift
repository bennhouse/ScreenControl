import Carbon
import Cocoa
import SwiftUI

/// ScreenControl's settings: the Keep Awake shortcut.
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    var keepAwake: KeepAwake?

    func show() {
        guard let keepAwake else { return }
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(keepAwake: keepAwake))
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.title = "ScreenControl Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        // A menu bar app is never frontmost on its own: ask to be activated and put the window in front.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.activate()
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var keepAwake: KeepAwake
    @State private var message: String?
    @State private var clearWork: DispatchWorkItem?
    private let detailWidth: CGFloat = 250

    /// ⌃⌥⌘B is taken by "Turn Off Reduce Brightness".
    static let reserved = Shortcut(keyCode: UInt16(kVK_ANSI_B), modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue)

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 20) {
            GridRow {
                Text("Keep Awake:").gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        RecorderView(shortcut: keepAwake.shortcut,
                                     onStart: { keepAwake.pauseShortcut(); show("Type the new keys. Esc cancels.", autoClear: false) },
                                     onEnd: { keepAwake.registerShortcut(); if message == "Type the new keys. Esc cancels." { show(nil) } },
                                     onRecord: record)
                        Button("Default") { record(KeepAwake.defaultShortcut) }
                            .controlSize(.small)
                            .disabled(keepAwake.shortcut == KeepAwake.defaultShortcut && keepAwake.shortcutActive)
                    }
                    Text(message ?? (keepAwake.shortcutActive
                                     ? "Turns Keep Awake on or off from anywhere. Click the field, then press the new keys."
                                     : "\(keepAwake.shortcut.displayString) is used by another app. Choose a different shortcut."))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: detailWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 28)
        .fixedSize()
    }

    private func record(_ new: Shortcut) {
        if new == Self.reserved {
            show("\(new.displayString) already turns off Reduce Brightness. Choose a different shortcut.")
        } else if new == keepAwake.shortcut && keepAwake.shortcutActive {
            show("Keep Awake already uses \(new.displayString).")
        } else if keepAwake.setShortcut(new) {
            show("Shortcut set to \(new.displayString).")
        } else {
            show("\(new.displayString) is used by another app. Choose a different shortcut.")
        }
    }

    private func show(_ text: String?, autoClear: Bool = true) {
        clearWork?.cancel()
        message = text
        guard autoClear, let text else { return }
        let work = DispatchWorkItem { if message == text { message = nil } }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}

/// SwiftUI wrapper of the recorder field.
struct RecorderView: NSViewRepresentable {
    let shortcut: Shortcut
    let onStart: () -> Void
    let onEnd: () -> Void
    let onRecord: (Shortcut) -> Void

    func makeNSView(context: Context) -> RecorderField { RecorderField() }

    func updateNSView(_ field: RecorderField, context: Context) {
        field.onStart = onStart
        field.onEnd = onEnd
        field.onRecord = onRecord
        field.shortcut = shortcut
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecorderField, context: Context) -> CGSize? {
        CGSize(width: 104, height: 22)
    }
}

/// A compact field that records a shortcut: click it (or Tab to it and press Space), then press the
/// keys. Recording ends with Esc, a click, leaving the window, or 10 seconds without keys.
final class RecorderField: NSView {
    var onRecord: ((Shortcut) -> Void)?
    var onStart: (() -> Void)?
    var onEnd: (() -> Void)?
    var shortcut = KeepAwake.defaultShortcut { didSet { if !recording { refresh() } } }

    private let label = NSTextField(labelWithString: "")
    private var recording = false
    private var monitor: Any?
    private var hint: String?
    private var liveModifiers = ""
    private var idleTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -8),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { stop() }

    override var intrinsicContentSize: NSSize { NSSize(width: 104, height: 22) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill() }

    override func mouseDown(with event: NSEvent) {
        if recording {
            stop()
        } else {
            window?.makeFirstResponder(self)
            start()
        }
    }

    override func keyDown(with event: NSEvent) {
        if !recording && event.keyCode == 49 { start() } else if recording { handle(event) } else { super.keyDown(with: event) }
    }

    override func resignFirstResponder() -> Bool {
        stop()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResigned), name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowResigned), name: NSWindow.willCloseNotification, object: window)
        } else {
            stop()
        }
    }

    @objc private func windowResigned() { stop() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func start() {
        guard !recording else { return }
        recording = true
        hint = nil
        onStart?()
        restartIdleTimer()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.recording else { return event }
            self.restartIdleTimer()
            // ⌘W, ⌘Q and ⌘, keep their usual job.
            if event.type == .keyDown, [13, 12, 43].contains(event.keyCode),
               event.modifierFlags.intersection(Shortcut.relevantModifiers) == .command {
                self.stop()
                return event
            }
            if event.type == .flagsChanged {
                self.showModifiers(event.modifierFlags)
                return event
            }
            self.handle(event)
            return nil
        }
        refresh()
    }

    private func handle(_ event: NSEvent) {
        let s = Shortcut(event: event)
        if event.keyCode == 53 && s.flags.isEmpty { // Esc
            stop()
        } else if s.isValid {
            stop()
            onRecord?(s)
        } else {
            hint = "Add ⌘ ⌥ or ⌃"
            refresh()
        }
    }

    private func restartIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in self?.stop() }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        idleTimer?.invalidate()
        idleTimer = nil
        onEnd?()
        refresh()
    }

    private func showModifiers(_ flags: NSEvent.ModifierFlags) {
        let f = flags.intersection(Shortcut.relevantModifiers)
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        liveModifiers = s
        hint = nil
        refresh()
    }

    private func refresh() {
        let text: String
        if recording {
            text = hint ?? (liveModifiers.isEmpty ? "Type keys…" : liveModifiers)
        } else {
            liveModifiers = ""
            text = shortcut.displayString
        }
        label.stringValue = text
        label.font = .systemFont(ofSize: 12, weight: recording && liveModifiers.isEmpty ? .regular : .medium)
        label.textColor = recording && liveModifiers.isEmpty ? .secondaryLabelColor : .labelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderColor = (recording ? NSColor.controlAccentColor.withAlphaComponent(0.8) : NSColor.separatorColor).cgColor
        }
        layer?.borderWidth = recording ? 1.5 : 1
    }
}
