import CoreGraphics
import Foundation

/// Darkens a display below its hardware minimum by scaling its gamma table.
///
/// The table dims everything, the cursor included, and does not show in screenshots. macOS
/// resets it when the app quits (even after a crash) and sometimes on its own (wake, display
/// reconfiguration, colour profile changes), so a watchdog re-applies it while dimming is on.
final class GammaDimmer {
    private struct Table {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
    }

    /// Gamma multiplier per display, below 1.
    private var factors: [CGDirectDisplayID: Double] = [:]
    /// The system's own table, captured before dimming.
    private var base: [CGDirectDisplayID: Table] = [:]
    private var applied: [CGDirectDisplayID: Table] = [:]
    private var watchdog: Timer?
    private let guardLock = NSLock()
    /// Tables the guard thread holds in place, each until its own deadline.
    private var guarded: [CGDirectDisplayID: (table: Table, until: Date)] = [:]
    private var guardRunning = false
    private var animations: [CGDirectDisplayID: Timer] = [:]
    /// Every write to the window server goes through this queue, in order, so the main thread
    /// (and the panel's animations) never wait on it.
    private let writer = DispatchQueue(label: "ScreenControl.gamma", qos: .userInteractive)

    private func write(_ display: CGDirectDisplayID, _ table: Table) {
        writer.async {
            CGSetDisplayTransferByTable(display, UInt32(table.red.count), table.red, table.green, table.blue)
        }
    }

    private static let debug = ProcessInfo.processInfo.environment["SCREENCONTROL_GAMMA_LOG"] == "1"
    private func log(_ text: @autoclosure () -> String) {
        if Self.debug { NSLog("gamma: %@", text()) }
    }

    func setFactor(_ factor: Double, for display: CGDirectDisplayID) {
        log("setFactor \(factor) display \(display) base \(base[display].map { String($0.red.last ?? -1) } ?? "nil") count \(base[display]?.red.count ?? 0)")
        if factor >= 0.999 {
            guard factors.removeValue(forKey: display) != nil else { return }
            // Stop guarding first, or the guard could put the last dimmed table back over the
            // normal one written next.
            unguard(display)
            // Put back this display's own system table. (CGDisplayRestoreColorSyncSettings would
            // reset every display for a moment, a flash on the other dimmed screens.)
            if let table = base[display] {
                write(display, table)
                log("restore base display \(display) top \(table.red.last ?? -1)")
            }
            base[display] = nil
            applied[display] = nil
        } else {
            factors[display] = max(factor, 0)
            if base[display] == nil {
                // Only a table that reaches (near) white is the display's own: a darker one is
                // a fade or dimming in progress, and using it as the base would leave the
                // screen dark for good.
                if let current = read(display), Self.isSystemTable(current) {
                    base[display] = current
                } else {
                    base[display] = Self.identity
                }
            }
            apply(display)
        }
        updateWatchdog()
    }

    /// For a display that has just been turned off: puts its own table back (it keeps it while
    /// off, and must not come back black), then drops it.
    func restoreAndForget(_ display: CGDirectDisplayID) {
        animations[display]?.invalidate()
        animations[display] = nil
        unguard(display)
        if let table = base[display] { write(display, table) }
        forget(display)
    }

    /// Drops a display that is gone or turned off, without writing to it.
    func forget(_ display: CGDirectDisplayID) {
        animations[display]?.invalidate()
        animations[display] = nil
        factors[display] = nil
        base[display] = nil
        applied[display] = nil
        unguard(display)
        updateWatchdog()
    }

    /// The guard must always hold the table the app wants now, never an older one (a stale
    /// black table from a fade would otherwise be put back over the normal one).
    private func unguard(_ display: CGDirectDisplayID) {
        guardLock.withLock { guarded[display] = nil }
    }

    private func updateGuard(_ display: CGDirectDisplayID, _ table: Table) {
        guardLock.withLock {
            if let entry = guarded[display] { guarded[display] = (table, entry.until) }
        }
    }

    func restoreAll() {
        guardLock.withLock { guarded.removeAll() }
        factors.removeAll()
        base.removeAll()
        applied.removeAll()
        writer.sync { CGDisplayRestoreColorSyncSettings() }
        updateWatchdog()
    }

    /// Waits until queued writes have reached the window server (tests only).
    func flush() {
        writer.sync {}
    }

    /// The multiplier currently applied to a display (1 = untouched).
    func factor(for display: CGDirectDisplayID) -> Double {
        factors[display] ?? 1
    }

    /// Re-applies any table macOS has replaced.
    func check() {
        // Never wait for the writer queue here: during a display reconfiguration the window
        // server waits for this app's main thread, and the queue waits for the window server.
        guard !factors.isEmpty else { return }
        for display in factors.keys {
            guard let current = read(display), let mine = applied[display] else {
                apply(display)
                continue
            }
            if !Self.similar(current, mine) {
                // A table that does not reach full white is a system fade in progress, not a
                // new colour profile: keep the known base instead of adopting it.
                if Self.reachesWhite(current) { base[display] = current }
                apply(display)
            }
        }
    }

    /// Guards the dimmed displays closely for a few seconds. About a quarter of a second after
    /// a display is turned on or off, macOS resets every gamma table to full brightness. A
    /// background thread watches every 2 ms and puts the dimmed table straight back, so the
    /// reset lasts a few milliseconds instead of a visible flash. Call it before reconfiguring.
    func guardTables(for duration: TimeInterval = 1.5, excluding excluded: Set<CGDirectDisplayID> = []) {
        let tables = applied.filter { !excluded.contains($0.key) }
        guard !tables.isEmpty else { return }
        startGuard(tables, duration: duration)
    }

    /// Holds one display's current table (for example black, before a fade-in) through the
    /// reset that follows turning it on.
    func guardDisplay(_ display: CGDirectDisplayID, for duration: TimeInterval) {
        guard let table = applied[display] else { return }
        startGuard([display: table], duration: duration)
    }

    private func startGuard(_ tables: [CGDirectDisplayID: Table], duration: TimeInterval) {
        let until = Date().addingTimeInterval(duration)
        let startThread: Bool = guardLock.withLock {
            for (display, table) in tables { guarded[display] = (table, until) }
            defer { guardRunning = true }
            return !guardRunning
        }
        if startThread {
            Thread.detachNewThread { [weak self] in self?.guardLoop() }
        }
    }

    private func guardLoop() {
        while true {
            let tables: [CGDirectDisplayID: Table]? = guardLock.withLock {
                let now = Date()
                guarded = guarded.filter { $0.value.until > now }
                if guarded.isEmpty {
                    guardRunning = false
                    return nil
                }
                return guarded.mapValues(\.table)
            }
            guard let tables else { break }
            for display in tables.keys {
                guard let current = read(display), Self.reachesWhite(current) else { continue }
                // Write under the lock, and only if the entry is still wanted: the app may have
                // just restored the normal table (and dropped the entry) since the snapshot.
                guardLock.withLock {
                    if let table = guarded[display]?.table {
                        CGSetDisplayTransferByTable(display, UInt32(table.red.count), table.red, table.green, table.blue)
                    }
                }
            }
            usleep(2_000)
        }
        DispatchQueue.main.async { [weak self] in self?.check() }
    }

    /// Animates a display's multiplier, for fading a screen out before it is turned off and in
    /// after it is turned on. Ending at 1 restores the system table.
    func animate(_ display: CGDirectDisplayID, to target: Double, duration: TimeInterval, completion: @escaping () -> Void = {}) {
        let start = factor(for: display)
        let began = Date()
        animations[display]?.invalidate()
        let step: (Timer) -> Void = { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let t = min(Date().timeIntervalSince(began) / duration, 1)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            self.setFactor(start + (target - start) * eased, for: display)
            if t >= 1 {
                timer.invalidate()
                self.animations[display] = nil
                completion()
            }
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true, block: step)
        RunLoop.main.add(timer, forMode: .common)
        animations[display] = timer
    }

    private func apply(_ display: CGDirectDisplayID) {
        guard let factor = factors[display], let table = base[display] else { return }
        let f = CGGammaValue(factor)
        let dimmed = Table(red: table.red.map { $0 * f }, green: table.green.map { $0 * f }, blue: table.blue.map { $0 * f })
        applied[display] = dimmed
        updateGuard(display, dimmed)
        write(display, dimmed)
    }

    private func read(_ display: CGDirectDisplayID) -> Table? {
        let capacity = CGDisplayGammaTableCapacity(display)
        guard capacity > 1 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red, blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &count) == .success, count > 1 else { return nil }
        let n = Int(count)
        return Table(red: Array(red[0..<n]), green: Array(green[0..<n]), blue: Array(blue[0..<n]))
    }

    private static let identity: Table = {
        let ramp = (0..<256).map { CGGammaValue($0) / 255 }
        return Table(red: ramp, green: ramp, blue: ramp)
    }()

    /// Looks like the system's own table: near white at the top (allowing for a warm colour
    /// profile), not a dimmed or faded one.
    private static func isSystemTable(_ table: Table) -> Bool {
        let tops: [CGGammaValue] = [table.red.last ?? 0, table.green.last ?? 0, table.blue.last ?? 0]
        return (tops.max() ?? 0) > 0.9 && (tops.min() ?? 0) > 0.6
    }

    private static func reachesWhite(_ table: Table) -> Bool {
        (table.red.last ?? 0) > 0.97 && (table.green.last ?? 0) > 0.97 && (table.blue.last ?? 0) > 0.97
    }

    private static func similar(_ a: Table, _ b: Table) -> Bool {
        for position in [0.25, 0.5, 0.75, 1.0] {
            for (x, y) in [(a.red, b.red), (a.green, b.green), (a.blue, b.blue)] {
                let vx = x[Int(Double(x.count - 1) * position)]
                let vy = y[Int(Double(y.count - 1) * position)]
                if abs(vx - vy) > 0.02 { return false }
            }
        }
        return true
    }

    private func updateWatchdog() {
        if factors.isEmpty {
            watchdog?.invalidate()
            watchdog = nil
        } else if watchdog == nil {
            watchdog = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.check() }
        }
    }
}
