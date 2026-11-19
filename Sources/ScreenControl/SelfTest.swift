import AppKit

/// `ScreenControl --selftest`: checks every hardware path without visible changes (the DDC
/// write sends back the value just read; the gamma test dims for half a second and restores).
enum SelfTest {
    static func run() {
        var list = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &list, &count)
        let displays = Array(list.prefix(Int(count)))
        let endpoints = DDC.discover()
        print("DDC endpoints: \(endpoints.count)", endpoints.map { "vendor \($0.vendor ?? 0) model \($0.model ?? 0) serial \($0.serial ?? 0)" })
        let externals = displays.filter { CGDisplayIsBuiltin($0) == 0 }
        let channels = DDC.match(externals.map { (id: $0, vendor: CGDisplayVendorNumber($0), model: CGDisplayModelNumber($0), serial: CGDisplaySerialNumber($0)) }, endpoints)

        for id in displays {
            let builtin = CGDisplayIsBuiltin(id) != 0
            print("\nDisplay \(id) \(builtin ? "built-in" : "external") vendor \(CGDisplayVendorNumber(id)) model \(CGDisplayModelNumber(id))")
            if builtin {
                print("  DisplayServices brightness: \(PrivateAPI.brightness(of: id).map { String(format: "%.3f", $0) } ?? "unavailable"), can change: \(PrivateAPI.canChangeBrightness(of: id))")
            } else if let channel = channels[id] {
                if let value = channel.read(0x10) {
                    print("  DDC brightness: \(value.current)/\(value.maximum)")
                    channel.write(0x10, value: value.current)
                    usleep(300_000)
                    let after = channel.read(0x10)
                    print("  DDC write-back: \(after.map { "\($0.current)/\($0.maximum)" } ?? "no reply after write")")
                } else {
                    print("  DDC: matched but no reply")
                }
            } else {
                print("  DDC: no channel matched")
            }

            let dimmer = GammaDimmer()
            let capacity = CGDisplayGammaTableCapacity(id)
            dimmer.setFactor(0.6, for: id)
            dimmer.flush()
            var r = [CGGammaValue](repeating: 0, count: Int(capacity)), g = r, b = r
            var n: UInt32 = 0
            CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &n)
            let top = n > 0 ? r[Int(n) - 1] : -1
            usleep(500_000)
            dimmer.setFactor(1, for: id)
            dimmer.flush()
            CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &n)
            let restored = n > 0 ? r[Int(n) - 1] : -1
            print(String(format: "  Gamma: table top while dimmed %.3f (expected ≈0.600), after restore %.3f", top, restored))
        }

        testReduceBrightness()

        let nightShift = NightShiftClient()
        if let status = nightShift.status() {
            print("\nNight Shift: available \(status.available), on \(status.enabled), mode \(status.mode), schedule \(status.from) → \(status.to)")
        } else {
            print("\nNight Shift: unavailable")
        }
        let trueTone = TrueToneClient()
        print("True Tone: supported \(trueTone.isSupported), on \(trueTone.isEnabled)")
        print("Dark Mode: on \(PrivateAPI.isDarkMode), automatic \(PrivateAPI.appearanceSwitchesAutomatically)")
    }

    /// Runs "Reduce brightness" on the first external display through the real controller:
    /// on → slider to 0 → off, checking the hardware value and the gamma table at each step.
    private static func testReduceBrightness() {
        let controller = DisplayController()
        controller.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(2)) // DDC discovery runs in the background
        guard let item = controller.displays.first(where: { !$0.isBuiltin }) else {
            print("\nReduce brightness: no external display")
            return
        }
        func gammaTop() -> CGGammaValue {
            let capacity = CGDisplayGammaTableCapacity(item.id)
            var r = [CGGammaValue](repeating: 0, count: Int(capacity)), g = r, b = r
            var n: UInt32 = 0
            CGGetDisplayTransferByTable(item.id, capacity, &r, &g, &b, &n)
            return n > 0 ? r[Int(n) - 1] : -1
        }
        func hardware() -> String {
            item.ddc?.read(0x10).map { "\($0.current)/\($0.maximum)" } ?? "n/a"
        }
        let wasOn = item.dimEnabled
        if wasOn { controller.setDimEnabled(false, for: item) }
        print("\nReduce brightness on \(item.name): DDC \(item.ddc != nil ? "connected" : "missing"), brightness \(String(format: "%.2f", item.brightness)) (hardware \(hardware()))")
        controller.setDimEnabled(true, for: item)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        print(String(format: "  on:  hardware %@, saved %.2f, slider %.2f, gamma %.3f", hardware(), item.savedBrightness ?? -1, item.dimLevel, gammaTop()))
        controller.setDimLevel(0, for: item)
        controller.flushGamma()
        print(String(format: "  slider 0: gamma %.3f (expected %.3f)", gammaTop(), DisplayController.dimFloor))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        controller.setDimEnabled(false, for: item)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        print(String(format: "  off: hardware %@, gamma %.3f", hardware(), gammaTop()))
        if wasOn { controller.setDimEnabled(true, for: item) }
    }
}

extension SelfTest {
    /// `ScreenControl --selftest-writes`: flips Dark Mode, Night Shift and True Tone and puts each
    /// back, checks that dimming survives Night Shift, and checks that turning Reduce brightness
    /// off restores a non-zero hardware brightness. Visible for a few seconds.
    static func runWrites() {
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        // Dark Mode
        let dark = PrivateAPI.isDarkMode, auto = PrivateAPI.appearanceSwitchesAutomatically
        PrivateAPI.setDarkMode(!dark)
        wait(1.5)
        print("Dark Mode: \(dark) → set \(!dark) → reads \(PrivateAPI.isDarkMode), automatic \(auto) → \(PrivateAPI.appearanceSwitchesAutomatically)")
        PrivateAPI.setDarkMode(dark)
        wait(1.5)
        print("  restored: \(PrivateAPI.isDarkMode), automatic \(PrivateAPI.appearanceSwitchesAutomatically)")

        // Keyboard backlight
        let keyboard = KeyboardBacklightClient()
        if let before = keyboard.brightness {
            keyboard.setBrightness(before > 0.5 ? 0.1 : 0.8)
            wait(0.8)
            let changed = keyboard.brightness ?? -1
            keyboard.setBrightness(before)
            wait(0.8)
            print(String(format: "Keyboard backlight: %.2f → %.2f → restored %.2f", before, changed, keyboard.brightness ?? -1))
        } else {
            print("Keyboard backlight: unavailable")
        }

        // True Tone
        let trueTone = TrueToneClient()
        let ttWas = trueTone.isEnabled
        trueTone.setEnabled(!ttWas)
        wait(0.8)
        print("True Tone: \(ttWas) → reads \(trueTone.isEnabled)")
        trueTone.setEnabled(ttWas)
        wait(0.8)
        print("  restored: \(trueTone.isEnabled)")

        // Night Shift, with dimming on the external display
        let controller = DisplayController()
        controller.refresh()
        wait(2)
        let nightShift = NightShiftClient()
        let nsWas = nightShift.status()?.enabled ?? false
        if let item = controller.displays.first(where: { !$0.isBuiltin }) {
            func gammaTop() -> CGGammaValue {
                let capacity = CGDisplayGammaTableCapacity(item.id)
                var r = [CGGammaValue](repeating: 0, count: Int(capacity)), g = r, b = r
                var n: UInt32 = 0
                CGGetDisplayTransferByTable(item.id, capacity, &r, &g, &b, &n)
                return n > 0 ? r[Int(n) - 1] : -1
            }
            controller.setDimEnabled(true, for: item)
            controller.setDimLevel(0.5, for: item)
            let expected = DisplayController.gammaFactor(0.5)
            print(String(format: "Night Shift + dimming: gamma before %.3f (expected %.3f)", gammaTop(), expected))
            nightShift.setEnabled(!nsWas)
            var ticks: [String] = []
            for _ in 0..<5 {
                wait(1)
                ticks.append(String(format: "%.3f", gammaTop()))
            }
            print("  Night Shift \(nsWas) → reads \(nightShift.status()?.enabled ?? false); gamma each second: \(ticks.joined(separator: " "))")
            nightShift.setEnabled(nsWas)
            wait(1)
            print(String(format: "  Night Shift restored: %@; gamma %.3f", (nightShift.status()?.enabled ?? false) ? "true" : "false", gammaTop()))
            controller.setDimEnabled(false, for: item)

            // Restore of a non-zero hardware brightness
            if item.ddc != nil {
                let original = item.brightness
                controller.setBrightness(0.05, for: item)
                wait(0.6)
                let set = item.ddc?.read(0x10)
                controller.setDimEnabled(true, for: item)
                wait(0.6)
                let dimmed = item.ddc?.read(0x10)
                controller.setDimEnabled(false, for: item)
                wait(0.6)
                let restored = item.ddc?.read(0x10)
                print("Reduce brightness restore: set \(set?.current ?? 999) → on \(dimmed?.current ?? 999) → off \(restored?.current ?? 999) (expected 5 → 0 → 5)")
                controller.setBrightness(original, for: item)
                wait(0.6)
                print("  back to \(item.ddc?.read(0x10)?.current ?? 999)")
            }
        } else {
            print("Night Shift: no external display for the dimming check")
        }
    }

    /// Captures one of this process's own windows (development aid for the panel's look).
    static func capture(windowNumber: Int, to path: String) {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let create = PrivateAPI.symbol(nil, "CGWindowListCreateImage", as: CreateImage.self),
              let image = create(.null, 1 << 3 /* including window */, UInt32(windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("capture failed")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("captured \(image.width)x\(image.height) to \(path)")
    }
}

extension SelfTest {
    /// `ScreenControl --selftest-power`: turns the built-in display off for two seconds through
    /// the controller and back on, checking that it stays listed while off.
    static func runPower() {
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        _ = NSApplication.shared
        let controller = DisplayController()
        controller.start()
        wait(1.5)
        guard let item = controller.displays.first(where: { $0.isBuiltin }) else { print("no built-in display"); return }
        let other = controller.displays.first { !$0.isBuiltin }
        func describe() -> String { controller.displays.map { "\($0.name)\($0.isOff ? " (off)" : "")" }.joined(separator: ", ") }

        // Dim the other display and watch its gamma table while the built-in one switches.
        var samples: [(Double, CGGammaValue)] = []
        let lock = NSLock()
        var sampling = true
        let expected = DisplayController.gammaFactor(0.5)
        if let other {
            controller.setDimEnabled(true, for: other)
            controller.setDimLevel(0.5, for: other)
            let id = other.id, t0 = Date()
            Thread.detachNewThread {
                let capacity = CGDisplayGammaTableCapacity(id)
                var r = [CGGammaValue](repeating: 0, count: Int(capacity)), g = r, b = r
                while lock.withLock({ sampling }) {
                    var n: UInt32 = 0
                    if CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &n) == .success, n > 0 {
                        lock.withLock { samples.append((Date().timeIntervalSince(t0), r[Int(n) - 1])) }
                    }
                    usleep(10_000)
                }
            }
        }

        func builtinTop() -> String {
            let capacity = CGDisplayGammaTableCapacity(item.id)
            var r = [CGGammaValue](repeating: 0, count: Int(capacity)), g = r, b = r
            var n: UInt32 = 0
            guard CGGetDisplayTransferByTable(item.id, capacity, &r, &g, &b, &n) == .success, n > 0 else { return "n/a" }
            return String(format: "%.3f", r[Int(n) - 1])
        }
        var builtinTimeline: [String] = []
        do {
            let id = item.id, t0 = Date()
            Thread.detachNewThread {
                var last: Float = -2
                let capacity = CGDisplayGammaTableCapacity(id)
                var r = [CGGammaValue](repeating: 0, count: Int(capacity)), g = r, b = r
                while lock.withLock({ sampling }) {
                    var n: UInt32 = 0
                    let ok = CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &n) == .success && n > 0
                    let v: Float = ok ? r[Int(n) - 1] : -1
                    if abs(v - last) > 0.08 || (v == 0) != (last == 0) {
                        lock.withLock { builtinTimeline.append(String(format: "%.2f:%.2f", Date().timeIntervalSince(t0), v)) }
                        last = v
                    }
                    usleep(2_000)
                }
            }
        }
        let brightnessBefore = PrivateAPI.brightness(of: item.id) ?? -1
        print(String(format: "before: %@, built-in brightness %.3f, gamma top %@", describe(), brightnessBefore, builtinTop()))
        let t0 = Date()
        controller.setPower(false, for: item)
        print(String(format: "  switching started, call returned in %.0f ms (main thread free)", Date().timeIntervalSince(t0) * 1000))
        while item.isSwitching { wait(0.05) }
        print(String(format: "off after %.2fs: %@, active displays: %d, saved brightness %.3f, brightness while off %.3f",
                     Date().timeIntervalSince(t0), describe(), activeCount(), item.powerBrightness ?? -1, PrivateAPI.brightness(of: item.id) ?? -1))
        wait(1.5)
        let t1 = Date()
        print(String(format: "  turning on at %.2fs", t1.timeIntervalSince(t0)))
        controller.setPower(true, for: item)
        while item.isSwitching { wait(0.05) }
        print(String(format: "on after %.2fs: %@, active displays: %d", Date().timeIntervalSince(t1), describe(), activeCount()))
        wait(2)
        print(String(format: "2 s later: built-in brightness %.3f (was %.3f), gamma top %@ (must be ≈1, not 0)",
                     PrivateAPI.brightness(of: item.id) ?? -1, brightnessBefore, builtinTop()))
        lock.withLock { sampling = false }
        if let other {
            let values = lock.withLock { samples }
            let peaks = values.filter { $0.1 > CGGammaValue(expected) + 0.02 }
            print(String(format: "%@ gamma during the test: %d samples, min %.3f, max %.3f (dimmed level %.3f), above it: %d samples",
                         other.name, values.count, values.map(\.1).min() ?? -1, values.map(\.1).max() ?? -1, expected, peaks.count))
            if !peaks.isEmpty { print("  peaks at:", peaks.prefix(10).map { String(format: "%.2fs=%.2f", $0.0, $0.1) }) }
            print("  built-in gamma timeline:", lock.withLock { builtinTimeline }.joined(separator: " "))
            controller.setDimEnabled(false, for: other)
        }
        controller.stop()
    }

    private static func activeCount() -> Int {
        var list = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &list, &count)
        return Int(count)
    }
}

extension SelfTest {
    /// `ScreenControl --selftest-persist`: turns the built-in display off, "quits", checks it
    /// stays off, "relaunches", checks it is listed as Off, and turns it back on.
    static func runPersist() {
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        _ = NSApplication.shared
        let first = DisplayController()
        first.start()
        wait(1.5)
        guard let item = first.displays.first(where: { $0.isBuiltin }) else { print("no built-in display"); return }
        first.setPower(false, for: item)
        while item.isSwitching { wait(0.05) }
        wait(1)
        first.stop() // what quitting does
        print("after quit: active displays \(activeCount()) (expected 1)")
        wait(1.5)

        let second = DisplayController()
        second.start()
        wait(1.5)
        print("relaunch: \(second.displays.map { "\($0.name)\($0.isOff ? " (off)" : "")" }.joined(separator: ", "))")
        guard let again = second.displays.first(where: { $0.isBuiltin && $0.isOff }) else { print("built-in not listed as off"); return }
        second.setPower(true, for: again)
        while again.isSwitching { wait(0.05) }
        wait(2)
        let capacity = CGDisplayGammaTableCapacity(again.id)
        var r = [CGGammaValue](repeating: 0, count: Int(capacity)), g = r, b = r
        var n: UInt32 = 0
        CGGetDisplayTransferByTable(again.id, capacity, &r, &g, &b, &n)
        print(String(format: "turned on again: active displays %d, built-in gamma top %.3f, brightness %.3f",
                     activeCount(), n > 0 ? r[Int(n) - 1] : -1, PrivateAPI.brightness(of: again.id) ?? -1))
        second.stop()
    }
}
