import AppKit
import SwiftUI
import IOKit.pwr_mgt

/// `ScreenControl --selftest-keepawake [icon-dir]`: turns Keep Awake on and off, lets a short timed
/// session run out, and checks the power assertion each time. With a folder, also writes the menu
/// bar icon (off and on, 1x and 2x) there.
enum KeepAwakeSelfTest {
    static func run() -> Bool {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok    " : "FAIL  ") + name)
            if !ok { failures += 1 }
        }
        let keepAwake = KeepAwake()
        let before = assertions()
        keepAwake.start(minutes: nil)
        check("on: active, no end time", keepAwake.isActive && keepAwake.endDate == nil)
        check("on: one display-sleep assertion held", assertions() == before + 1)
        keepAwake.start(minutes: 30)
        check("switching to 30 minutes keeps a single assertion", assertions() == before + 1)
        check("30 minutes: end time set", abs((keepAwake.endDate?.timeIntervalSinceNow ?? 0) - 1800) < 5)
        keepAwake.toggle()
        check("toggle off: inactive", !keepAwake.isActive && keepAwake.endDate == nil)
        check("toggle off: assertion released", assertions() == before)

        keepAwake.start(seconds: 1)
        check("timed: active", keepAwake.isActive)
        RunLoop.main.run(until: Date().addingTimeInterval(1.6))
        check("timed: ends by itself", !keepAwake.isActive)
        check("timed: assertion released", assertions() == before)

        if CommandLine.arguments.count > 2 {
            let dir = URL(fileURLWithPath: CommandLine.arguments[2])
            for on in [false, true] {
                for scale in [1, 2] {
                    if let image = StatusIcon.image(keepAwake: on) {
                        let size = NSSize(width: image.size.width * CGFloat(scale), height: image.size.height * CGFloat(scale))
                        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                        NSColor.white.setFill()
                        NSRect(origin: .zero, size: size).fill()
                        image.draw(in: NSRect(origin: .zero, size: size))
                        NSGraphicsContext.restoreGraphicsState()
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: dir.appendingPathComponent("icon-\(on ? "on" : "off")@\(scale)x.png"))
                    }
                }
            }
        }
        // Changing the shortcut (saved under this test binary's own defaults, not the app's).
        keepAwake.registerShortcut()
        let custom = Shortcut(keyCode: 40, modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue) // ⌃⌥⌘K
        check("new shortcut registers", keepAwake.setShortcut(custom) && keepAwake.shortcut == custom && keepAwake.shortcutActive)
        check("back to the default", keepAwake.setShortcut(KeepAwake.defaultShortcut) && keepAwake.shortcut == KeepAwake.defaultShortcut)
        check("shortcut shows as ⇧⌘L", KeepAwake.defaultShortcut.displayString == "⇧⌘L")

        if CommandLine.arguments.count > 2 {
            let host = NSHostingView(rootView: SettingsView(keepAwake: keepAwake).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.layoutIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("settings-sc.png"))
        }
        print(failures == 0 ? "All Keep Awake checks passed." : "\(failures) Keep Awake check(s) failed.")
        return failures == 0
    }

    /// Display-sleep assertions held by this process.
    private static func assertions() -> Int {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess, let all = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return -1 }
        let mine = all[NSNumber(value: getpid())] ?? []
        return mine.filter { ($0[kIOPMAssertionTypeKey as String] as? String) == kIOPMAssertionTypePreventUserIdleDisplaySleep as String }.count
    }
}
