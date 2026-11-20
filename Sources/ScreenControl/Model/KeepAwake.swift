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

    static let defaultShortcut = Shortcut(keyCode: UInt16(kVK_ANSI_L), modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)
    static let durations: [(title: String, minutes: Int?)] = [
        ("15 minutes", 15), ("30 minutes", 30), ("1 hour", 60), ("2 hours", 120),
        ("4 hours", 240), ("8 hours", 480), ("Indefinitely", nil),
    ]

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?
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
        if let seconds {
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
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
        endDate = nil
        isActive = false
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
