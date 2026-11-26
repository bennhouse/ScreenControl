import Carbon
import Cocoa
import IOKit.pwr_mgt

/// Keep Awake: stops the Mac and its display from going to sleep while idle, until turned off or
/// for a chosen time. It holds a power assertion, the same thing `caffeinate -d` does; macOS drops
/// it if ScreenControl quits. Closing the lid still puts the Mac to sleep.
final class KeepAwake: ObservableObject {
    @Published private(set) var isActive = false
    /// When a timed session ends; nil while on until turned off.
    @Published private(set) var endDate: Date?
    @Published private(set) var shortcut: Shortcut
    /// False when the shortcut could not be registered (another app owns it).
    @Published private(set) var shortcutActive = true
    /// Called when a session is turned off because it reached `maximumDuration`.
    var onReachedLimit: (() -> Void)?

    /// The longest a session lasts, however it was turned on (the shortcut, "Indefinitely", or
    /// choosing another duration while on): counted from when it was turned on, never reset.
    /// `SCREENCONTROL_KEEPAWAKE_LIMIT=<seconds>` shortens it, for testing.
    static var maximumDuration: TimeInterval =
        Double(ProcessInfo.processInfo.environment["SCREENCONTROL_KEEPAWAKE_LIMIT"] ?? "") ?? 24 * 60 * 60
    /// When the running session was turned on.
    private(set) var sessionStart: Date?
    /// When the running session is turned off at the latest.
    var limitDate: Date? { sessionStart.map { $0.addingTimeInterval(Self.maximumDuration) } }

    static let defaultShortcut = Shortcut(keyCode: UInt16(kVK_ANSI_L), modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)
    static let durations: [(title: String, minutes: Int?)] = [
        ("15 minutes", 15), ("30 minutes", 30), ("1 hour", 60), ("2 hours", 120),
        ("4 hours", 240), ("8 hours", 480), ("Indefinitely", nil),
    ]

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?
    private var limitTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var hotKey: HotKey?
    private static let shortcutKey = "keepAwakeShortcut"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.shortcutKey),
           let saved = try? JSONDecoder().decode(Shortcut.self, from: data) {
            shortcut = saved
        } else {
            shortcut = Self.defaultShortcut
        }
    }

    // MARK: Session

    /// The shortcut and the menu's first item: on until turned off, or off.
    func toggle() {
        if isActive { stop() } else { start(minutes: nil) }
    }

    func start(minutes: Int?) {
        start(seconds: minutes.map { TimeInterval($0 * 60) })
    }

    func start(seconds: TimeInterval?) {
        if assertion == 0 {
            let reason = "ScreenControl Keep Awake" as CFString
            guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                              IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion) == kIOReturnSuccess else {
                assertion = 0
                NSSound.beep()
                return
            }
        }
        timer?.invalidate()
        timer = nil
        if sessionStart == nil {
            sessionStart = Date()
            scheduleLimit()
        }
        // A timed session never runs past the limit either.
        if let seconds, let limit = limitDate, Date().addingTimeInterval(seconds) < limit {
            let end = Date().addingTimeInterval(seconds)
            endDate = end
            let t = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in self?.stop() }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            endDate = nil
        }
        isActive = true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        limitTimer?.invalidate()
        limitTimer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        sessionStart = nil
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
        endDate = nil
        isActive = false
    }

    /// The limit is checked by a timer and again on wake: timers don't count time asleep
    /// (lid closed), so the Mac could otherwise stay awake past 24 hours of wall time.
    private func scheduleLimit() {
        guard let limit = limitDate else { return }
        let t = Timer(fire: limit, interval: 0, repeats: false) { [weak self] _ in self?.checkLimit() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        limitTimer = t
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.checkLimit() }
    }

    private func checkLimit() {
        guard isActive, let limit = limitDate else { return }
        guard Date() >= limit.addingTimeInterval(-1) else {
            // Woke before the limit: the timer, paused while asleep, is late now. Set it again.
            limitTimer?.invalidate()
            let t = Timer(fire: limit, interval: 0, repeats: false) { [weak self] _ in self?.checkLimit() }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            limitTimer = t
            return
        }
        stop()
        onReachedLimit?()
    }

    // MARK: Shortcut

    func registerShortcut() {
        hotKey = nil
        hotKey = HotKey(keyCode: UInt32(shortcut.keyCode), modifiers: shortcut.carbonModifiers) { [weak self] in self?.toggle() }
        shortcutActive = hotKey != nil
    }

    /// Unregisters the shortcut while a new one is being recorded, so its keys reach the recorder.
    func pauseShortcut() {
        hotKey = nil
    }

    /// Returns false (and keeps the old one) if the keys can't be registered.
    @discardableResult
    func setShortcut(_ new: Shortcut) -> Bool {
        hotKey = nil
        guard let key = HotKey(keyCode: UInt32(new.keyCode), modifiers: new.carbonModifiers, action: { [weak self] in self?.toggle() }) else {
            registerShortcut()
            return false
        }
        hotKey = key
        shortcut = new
        shortcutActive = true
        UserDefaults.standard.set(try? JSONEncoder().encode(new), forKey: Self.shortcutKey)
        return true
    }
}
