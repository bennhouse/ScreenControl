import AppKit
import CoreGraphics

/// Private macOS functions, resolved at run time so that a missing symbol turns a feature off
/// instead of crashing the app.
enum PrivateAPI {
    private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static let coreBrightness = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)

    static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(handle ?? UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    // MARK: Built-in display brightness (DisplayServices)

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool

    private static let getBrightness = symbol(displayServices, "DisplayServicesGetBrightness", as: GetBrightness.self)
    private static let setBrightness = symbol(displayServices, "DisplayServicesSetBrightness", as: SetBrightness.self)
    private static let canChange = symbol(displayServices, "DisplayServicesCanChangeBrightness", as: CanChangeBrightness.self)

    static func brightness(of display: CGDirectDisplayID) -> Double? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        guard getBrightness(display, &value) == 0 else { return nil }
        return Double(min(max(value, 0), 1))
    }

    @discardableResult
    static func setBrightness(_ value: Double, of display: CGDirectDisplayID) -> Bool {
        guard let setBrightness else { return false }
        return setBrightness(display, Float(min(max(value, 0), 1))) == 0
    }

    private typealias RegisterBrightness = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFNotificationCallback) -> Int32
    private static let registerBrightness = symbol(displayServices, "DisplayServicesRegisterForBrightnessChangeNotifications", as: RegisterBrightness.self)

    /// Calls `callback` whenever the display's brightness changes, from anywhere (keys,
    /// Touch Bar, Control Center, auto-brightness, other apps), with the new value in the
    /// user info under "value". The callback runs on a background thread.
    @discardableResult
    static func observeBrightness(of display: CGDirectDisplayID, observer: UnsafeRawPointer, callback: CFNotificationCallback) -> Bool {
        guard let registerBrightness else { return false }
        return registerBrightness(display, observer, callback) == 0
    }

    static func canChangeBrightness(of display: CGDirectDisplayID) -> Bool {
        if let canChange { return canChange(display) }
        return brightness(of: display) != nil
    }

    // MARK: Appearance (SkyLight)

    private typealias GetBool = @convention(c) () -> Bool
    private typealias SetBool = @convention(c) (Bool) -> Int32

    private static let getDarkTheme = symbol(skyLight, "SLSGetAppearanceThemeLegacy", as: GetBool.self)
    private static let setDarkTheme = symbol(skyLight, "SLSSetAppearanceThemeLegacy", as: SetBool.self)
    private static let getAutoTheme = symbol(skyLight, "SLSGetAppearanceThemeSwitchesAutomatically", as: GetBool.self)

    static var isDarkMode: Bool {
        if let getDarkTheme { return getDarkTheme() }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    static var appearanceSwitchesAutomatically: Bool {
        if let getAutoTheme { return getAutoTheme() }
        return UserDefaults.standard.bool(forKey: "AppleInterfaceStyleSwitchesAutomatically")
    }

    private typealias SetThemeNotifying = @convention(c) (Bool, Bool) -> Void
    private static let setDarkThemeNotifying = symbol(skyLight, "SLSSetAppearanceThemeNotifying", as: SetThemeNotifying.self)
    /// Kept alive until the system transition finishes.
    private static var activeTransition: NSObject?

    /// Switches Dark Mode the way Control Center does: the screen is frozen, every app redraws
    /// in the new appearance, then the whole display cross-fades (about half a second).
    /// `completion` runs when the transition is over.
    static func setDarkMode(_ on: Bool, completion: @escaping () -> Void = {}) {
        let postSel = Selector(("postChangeNotification:completionHandler:"))
        if let setDarkThemeNotifying,
           let transitionClass = NSClassFromString("NSGlobalPreferenceTransition") as AnyObject?,
           transitionClass.responds(to: Selector(("transition"))),
           let transition = transitionClass.perform(Selector(("transition")))?.takeUnretainedValue() as? NSObject,
           transition.responds(to: postSel) {
            activeTransition = transition
            setDarkThemeNotifying(on, false)
            typealias Post = @convention(c) (AnyObject, Selector, UInt64, AnyObject) -> Void
            let done: @convention(block) () -> Void = {
                DispatchQueue.main.async {
                    activeTransition = nil
                    completion()
                }
            }
            unsafeBitCast(transition.method(for: postSel), to: Post.self)(transition, postSel, 0, done as AnyObject)
            return
        }
        if let setDarkTheme {
            _ = setDarkTheme(on)
        } else {
            // Fallback: System Events (macOS asks once for Automation permission).
            let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)"
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
        completion()
    }
}

// MARK: - Night Shift (CoreBrightness CBBlueLightClient)

final class NightShiftClient {
    struct Status {
        var enabled: Bool
        /// 0 = no schedule, 1 = sunset to sunrise, 2 = custom.
        var mode: Int32
        var from: (hour: Int32, minute: Int32)
        var to: (hour: Int32, minute: Int32)
        var available: Bool
    }

    private let client: NSObject?

    init() {
        _ = PrivateAPI.coreBrightness
        client = (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init()
    }

    var isSupported: Bool { client?.responds(to: Selector(("getBlueLightStatus:"))) ?? false }

    func status() -> Status? {
        let sel = Selector(("getBlueLightStatus:"))
        guard let client, client.responds(to: sel) else { return nil }
        // struct { BOOL active; BOOL enabled; BOOL sunSchedulePermitted; int mode;
        //          struct { int h, m; } from, to; unsigned long long disableFlags; BOOL available; }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { buffer.deallocate() }
        memset(buffer, 0, 64)
        typealias Fn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let fn = unsafeBitCast(client.method(for: sel), to: Fn.self)
        guard fn(client, sel, buffer) else { return nil }
        let bytes = buffer.assumingMemoryBound(to: UInt8.self)
        return Status(
            enabled: bytes[1] != 0,
            mode: buffer.load(fromByteOffset: 4, as: Int32.self),
            from: (buffer.load(fromByteOffset: 8, as: Int32.self), buffer.load(fromByteOffset: 12, as: Int32.self)),
            to: (buffer.load(fromByteOffset: 16, as: Int32.self), buffer.load(fromByteOffset: 20, as: Int32.self)),
            available: bytes[32] != 0
        )
    }

    func setEnabled(_ on: Bool) {
        let sel = Selector(("setEnabled:"))
        guard let client, client.responds(to: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Bool
        _ = unsafeBitCast(client.method(for: sel), to: Fn.self)(client, sel, on)
    }

    func onChange(_ handler: @escaping () -> Void) {
        let sel = Selector(("setStatusNotificationBlock:"))
        guard let client, client.responds(to: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, @convention(block) () -> Void) -> Void
        let block: @convention(block) () -> Void = { DispatchQueue.main.async(execute: handler) }
        unsafeBitCast(client.method(for: sel), to: Fn.self)(client, sel, block)
    }
}

// MARK: - True Tone (CoreBrightness CBTrueToneClient)

final class TrueToneClient {
    private let client: NSObject?

    init() {
        _ = PrivateAPI.coreBrightness
        client = (NSClassFromString("CBTrueToneClient") as? NSObject.Type)?.init()
    }

    private func bool(_ name: String) -> Bool? {
        let sel = Selector((name))
        guard let client, client.responds(to: sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(client.method(for: sel), to: Fn.self)(client, sel)
    }

    var isSupported: Bool { (bool("supported") ?? false) && (bool("available") ?? true) }
    var isEnabled: Bool { bool("enabled") ?? false }

    func setEnabled(_ on: Bool) {
        let sel = Selector(("setEnabled:"))
        guard let client, client.responds(to: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Bool
        _ = unsafeBitCast(client.method(for: sel), to: Fn.self)(client, sel, on)
    }
}

// MARK: - Display power (SkyLight)

extension PrivateAPI {
    private typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private static let configureEnabled =
        symbol(dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY), "SLSConfigureDisplayEnabled", as: ConfigureEnabled.self)
        ?? symbol(nil, "CGSConfigureDisplayEnabled", as: ConfigureEnabled.self)

    static var canSwitchDisplays: Bool { configureEnabled != nil }

    /// Turns a display off or on in software: the monitor stays connected, but macOS stops using
    /// it, so windows and the desktop move to the displays that are still on. Lasts until it is
    /// turned back on or the user logs out.
    @discardableResult
    static func setDisplayEnabled(_ enabled: Bool, _ display: CGDirectDisplayID) -> Bool {
        setDisplaysEnabled([(display, enabled)])
    }

    /// Several changes in one reconfiguration: turning one display on and another off happens
    /// at once, so there is never a moment with no display.
    @discardableResult
    static func setDisplaysEnabled(_ changes: [(CGDirectDisplayID, Bool)]) -> Bool {
        guard let configureEnabled else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        // Note: any CGConfigureDisplayFadeEffect setting makes this fail (error 1006), and macOS
        // resets every gamma table shortly after: GammaDimmer.guardTables covers that.
        for (display, enabled) in changes {
            guard configureEnabled(config, display, enabled) == .success else {
                CGCancelDisplayConfiguration(config)
                return false
            }
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }
}

// MARK: - Keyboard backlight (CoreBrightness KeyboardBrightnessClient)

final class KeyboardBacklightClient {
    private let client: NSObject?
    let keyboardID: UInt64?

    init() {
        _ = PrivateAPI.coreBrightness
        let client = (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
        self.client = client
        let copySel = Selector(("copyKeyboardBacklightIDs"))
        guard let client, client.responds(to: copySel),
              let ids = client.perform(copySel)?.takeRetainedValue() as? [NSNumber], !ids.isEmpty else {
            keyboardID = nil
            return
        }
        let builtInSel = Selector(("isKeyboardBuiltIn:"))
        typealias IsBuiltIn = @convention(c) (AnyObject, Selector, UInt64) -> Bool
        let builtIn = client.responds(to: builtInSel)
            ? ids.first { unsafeBitCast(client.method(for: builtInSel), to: IsBuiltIn.self)(client, builtInSel, $0.uint64Value) }
            : nil
        keyboardID = (builtIn ?? ids[0]).uint64Value
    }

    var brightness: Double? {
        let sel = Selector(("brightnessForKeyboard:"))
        guard let client, let keyboardID, client.responds(to: sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, UInt64) -> Float
        return Double(unsafeBitCast(client.method(for: sel), to: Fn.self)(client, sel, keyboardID))
    }

    func setBrightness(_ value: Double) {
        let sel = Selector(("setBrightness:forKeyboard:"))
        guard let client, let keyboardID, client.responds(to: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        _ = unsafeBitCast(client.method(for: sel), to: Fn.self)(client, sel, Float(min(max(value, 0), 1)), keyboardID)
    }
}
