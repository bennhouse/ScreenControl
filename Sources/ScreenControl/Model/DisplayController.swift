import AppKit
import Combine
import SwiftUI

final class DisplayItem: ObservableObject, Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    /// Stable identity for saved settings (display IDs can change on reconnect).
    let key: String

    /// Hardware brightness, 0...1.
    @Published var brightness: Double = 0
    @Published var canSetBrightness = false
    /// "Reduce brightness": hardware at minimum, plus gamma dimming.
    @Published var dimEnabled = false
    /// Dimming slider, 1 = no extra dimming, 0 = darkest.
    @Published var dimLevel: Double = 1
    /// Turned off in software: still connected, but not part of the desktop.
    @Published var isOff = false
    /// Being turned off or on (the switch takes a moment).
    @Published var isSwitching = false
    /// What the panel shows: changes as soon as the power button is clicked, so the panel
    /// settles while the screen fades, instead of jumping once macOS has switched.
    @Published var showsOff = false

    var ddc: DDCChannel?
    /// The monitor has answered a brightness read on its DDC channel at least once. A monitor
    /// that is matched but never answers (or reports brightness as unsupported) can't be set:
    /// its slider stays disabled and nothing is written to it.
    var ddcAnswered = false
    var ddcMaximum: UInt16 = 100
    /// Hardware brightness before "Reduce brightness" was turned on.
    var savedBrightness: Double?
    /// Hardware brightness before the display was turned off (it goes to minimum while off).
    var powerBrightness: Double?
    /// Brightness to write once the display's DDC channel is found again after turning on.
    var pendingBrightness: Double?
    /// Hardware brightness before "Black screen" was turned on.
    var blackSavedBrightness: Double?

    /// "Black screen" (built-in display): hardware brightness at a true 0, backlight off. Any
    /// other brightness change, here or with the brightness keys, ends it.
    var isBlack: Bool { isBuiltin && brightness <= 0 }
    /// The Black screen button's slide is under way: the slider stays lit until it is over.
    @Published var blackSliding = false
    /// Black screen is being turned off: the button already shows it off.
    @Published var blackLeaving = false
    /// What the panel shows: a greyed-out slider and a checked Black screen row.
    var showsBlack: Bool { isBlack && !blackSliding }
    var showsBlackChecked: Bool { isBlack && !blackLeaving }

    init(id: CGDirectDisplayID, name: String, isBuiltin: Bool, key: String) {
        self.id = id
        self.name = name
        self.isBuiltin = isBuiltin
        self.key = key
    }
}

final class DisplayController: ObservableObject {
    @Published private(set) var displays: [DisplayItem] = []

    /// Gamma multiplier at the bottom of the dimming slider. Gamma-encoded values scale
    /// luminance roughly by f^2.2, so 0.35 leaves about 10% of the light: dark, never black.
    static let dimFloor = 0.35
    /// Lowest built-in brightness the slider writes (1%). At 0 the backlight goes off, as with
    /// the brightness keys; the slider stops just above, so it never turns the screen off.
    /// "Black screen" goes to 0.
    static let builtinMinimum = 0.01
    /// The panel's layout animation; the window resizes with the same curve and duration.
    static let layoutAnimation = Animation.easeInOut(duration: PanelWindow.resizeDuration)

    fileprivate let gamma = GammaDimmer()
    private let defaults = UserDefaults.standard
    private var refreshWork: DispatchWorkItem?
    private var pollTimer: Timer?
    private var draggingDisplay: CGDirectDisplayID?
    private var ddcGeneration = 0
    /// Displays just turned on: macOS lists them as active a moment later.
    private var turnedOnAt: [CGDirectDisplayID: Date] = [:]
    private var brightnessRamps: [CGDirectDisplayID: Timer] = [:]
    /// Built-in brightness is written off the main thread, keeping only the latest value.
    private let builtinWriter = LatestValueWriter(label: "ScreenControl.brightness")
    /// When brightness was last written: polling skips a display for a moment after that, so
    /// the slider does not bounce back while the write is still on its way.
    private var lastWrite: [CGDirectDisplayID: Date] = [:]
    /// Built-in displays whose brightness changes are observed.
    private var observedBrightness: Set<CGDirectDisplayID> = []
    private var panelVisible = false
    private let live: Bool

    init(live: Bool = true) {
        self.live = live
    }

    /// For snapshots: a fixed set of displays, no hardware access.
    init(mock: [DisplayItem]) {
        live = false
        displays = mock
    }

    // MARK: Lifecycle

    func start() {
        guard live else { return }
        defaults.removeObject(forKey: "power.off") // format of an earlier version
        // Displays turned off in an earlier run stay off (macOS keeps them off until they are
        // turned on or the user logs out): show them as Off again.
        displays = loadOffRecords().map { record in
            let item = DisplayItem(id: record.id, name: record.name, isBuiltin: record.builtin, key: record.key)
            item.isOff = true
            item.showsOff = true
            item.powerBrightness = record.brightness
            loadDim(into: item)
            return item
        }
        refresh()
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard let context, !flags.contains(.beginConfigurationFlag) else { return }
            let controller = Unmanaged<DisplayController>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                controller.gamma.guardTables()
                controller.scheduleRefresh()
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRefresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.gamma.check() }
            }
        }
    }

    /// On quit: removes the gamma dimming (macOS would anyway). Displays that are off stay off,
    /// and hardware brightness stays where it is.
    func stop() {
        gamma.restoreAll()
    }

    /// Tests only: waits for queued gamma writes.
    func flushGamma() {
        gamma.flush()
    }

    /// Called while the panel is visible: picks up changes made elsewhere (brightness keys,
    /// auto-brightness, the monitor's own buttons).
    func setPanelVisible(_ visible: Bool) {
        pollTimer?.invalidate()
        pollTimer = nil
        panelVisible = visible
        guard live, visible else { return }
        readBuiltinBrightness()
        readExternalBrightness()
        // Externals without a channel, or whose monitor has not answered yet, are looked for again.
        if displays.contains(where: { !$0.isBuiltin && !$0.isOff && !$0.canSetBrightness }) { connectDDC() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.readBuiltinBrightness()
        }
    }

    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func refresh() {
        var list = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &list, &count)
        let active = list.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }

        // Never leave the Mac without a display: if the only display that was on has gone
        // (unplugged), turn the ones that are off back on.
        if active.isEmpty {
            let off = displays.filter(\.isOff).map { ($0.id, true) }
            if !off.isEmpty, PrivateAPI.setDisplaysEnabled(off) {
                displays.removeAll { $0.isOff }
                saveOffRecords()
            }
            return
        }

        // A display turned on a moment ago may not be listed yet: keep it (and its fade-in)
        // instead of treating it as unplugged, and look again shortly.
        let now = Date()
        turnedOnAt = turnedOnAt.filter { now.timeIntervalSince($0.value) < 5 }
        // Same for a display in the middle of being switched.
        let arriving = displays.filter { !$0.isOff && !active.contains($0.id) && (turnedOnAt[$0.id] != nil || $0.isSwitching) }
        if !arriving.isEmpty { scheduleRefresh() }

        for old in displays where !active.contains(old.id) && !old.isOff && turnedOnAt[old.id] == nil && !old.isSwitching {
            gamma.forget(old.id)
        }
        var items = active.map { id in displays.first { $0.id == id } ?? makeItem(id) } + arriving
        // A display that is listed again was turned on elsewhere (or by logging out).
        for item in items where item.isOff {
            item.isOff = false
            item.showsOff = false
        }
        // Displays turned off here are no longer listed by macOS: keep them, to turn them on again.
        items += displays.filter { $0.isOff && !active.contains($0.id) }
        func rank(_ item: DisplayItem) -> Int {
            item.isBuiltin ? 2 : (CGDisplayIsMain(item.id) != 0 ? 0 : 1)
        }
        items.sort { (rank($0), $0.id) < (rank($1), $1.id) }
        displays = items
        saveOffRecords()

        for item in items where item.isBuiltin && !item.isOff {
            item.canSetBrightness = PrivateAPI.canChangeBrightness(of: item.id)
            observeBrightness(of: item.id)
        }
        readBuiltinBrightness()
        for item in items where item.dimEnabled && !item.isOff && turnedOnAt[item.id] == nil {
            gamma.setFactor(Self.gammaFactor(item.dimLevel), for: item.id)
        }
        connectDDC()
    }

    private func makeItem(_ id: CGDirectDisplayID) -> DisplayItem {
        let builtin = CGDisplayIsBuiltin(id) != 0
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        let name: String
        if builtin {
            name = (screen?.backingScaleFactor ?? 2) > 1 ? "Built-in Retina Display" : "Built-in Display"
        } else {
            name = screen?.localizedName ?? "External Display"
        }
        let key = "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
        let item = DisplayItem(id: id, name: name, isBuiltin: builtin, key: key)
        loadDim(into: item)
        return item
    }

    private func loadDim(into item: DisplayItem) {
        guard !item.isBuiltin else { return }
        let key = item.key
        item.dimEnabled = defaults.bool(forKey: "dim.\(key).enabled")
        item.dimLevel = defaults.object(forKey: "dim.\(key).level") as? Double ?? 1
        item.savedBrightness = defaults.object(forKey: "dim.\(key).saved") as? Double
        item.brightness = defaults.object(forKey: "ddc.\(key).last") as? Double ?? 0.5
    }

    // MARK: Brightness

    private func readBuiltinBrightness() {
        for item in displays where item.isBuiltin && !item.isOff {
            if let value = PrivateAPI.brightness(of: item.id) { showOutsideBrightness(value, for: item) }
        }
    }

    /// Follows built-in brightness changes made elsewhere as they happen: the brightness keys
    /// and the Touch Bar send a stream of values, and the slider glides between them.
    private func observeBrightness(of display: CGDirectDisplayID) {
        guard live, !observedBrightness.contains(display) else { return }
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let registered = PrivateAPI.observeBrightness(of: display, observer: observer) { _, observer, _, _, info in
            guard let observer, let value = (info as NSDictionary?)?["value"] as? NSNumber else { return }
            let controller = Unmanaged<DisplayController>.fromOpaque(observer).takeUnretainedValue()
            let brightness = value.doubleValue
            DispatchQueue.main.async {
                for item in controller.displays where item.isBuiltin && !item.isOff {
                    controller.showOutsideBrightness(brightness, for: item)
                }
            }
        }
        if registered { observedBrightness.insert(display) }
    }

    /// A brightness read back or reported by macOS. Skipped while this app is the one changing
    /// it (dragging, ramping, or a write still on its way), so the slider never bounces back.
    private func showOutsideBrightness(_ value: Double, for item: DisplayItem) {
        guard item.id != draggingDisplay, brightnessRamps[item.id] == nil,
              Date().timeIntervalSince(lastWrite[item.id] ?? .distantPast) > 0.6,
              abs(value - item.brightness) > 0.002 else { return }
        let value = min(max(value, 0), 1)
        if panelVisible {
            withAnimation(Self.followAnimation) { item.brightness = value }
        } else {
            item.brightness = value
        }
    }

    /// How a slider moves to a value changed elsewhere: short enough to keep up with a drag on
    /// the Touch Bar, long enough to smooth over the steps between updates.
    static let followAnimation = Animation.easeOut(duration: 0.18)

    /// Matches external displays to DDC channels and reads their brightness. A monitor that is
    /// still waking up may not answer: up to three more attempts follow, two seconds apart.
    private func connectDDC(attempt: Int = 0) {
        let externals = displays.filter { !$0.isBuiltin && !$0.isOff }
        guard !externals.isEmpty else { return }
        ddcGeneration += 1
        let generation = ddcGeneration
        let specs = externals.map { ($0.id, CGDisplayVendorNumber($0.id), CGDisplayModelNumber($0.id), CGDisplaySerialNumber($0.id)) }
        DispatchQueue.global(qos: .userInitiated).async {
            let channels = DDC.match(specs.map { (id: $0.0, vendor: $0.1, model: $0.2, serial: $0.3) }, DDC.discover())
            var values: [CGDirectDisplayID: (current: UInt16, maximum: UInt16)] = [:]
            for (id, channel) in channels {
                values[id] = channel.read(0x10)
            }
            DispatchQueue.main.async {
                guard generation == self.ddcGeneration else { return }
                NSLog("ScreenControl: DDC matched %d of %d external displays, %d answered", channels.count, specs.count, values.count)
                for item in self.displays where !item.isBuiltin && !item.isOff {
                    item.ddc = channels[item.id]
                    if item.ddc == nil { item.ddcAnswered = false }
                    if values[item.id] != nil { item.ddcAnswered = true }
                    item.canSetBrightness = item.ddc != nil && item.ddcAnswered
                    if let value = values[item.id], item.id != self.draggingDisplay {
                        item.ddcMaximum = value.maximum
                        item.brightness = Double(value.current) / Double(value.maximum)
                    }
                    // Back from off: bring its brightness back now that DDC answers again.
                    if let pending = item.pendingBrightness, item.canSetBrightness {
                        item.pendingBrightness = nil
                        self.rampBrightness(item, to: pending, duration: 0.5)
                    }
                }
                if values.count < specs.count, attempt < 3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        guard generation == self.ddcGeneration else { return }
                        self.connectDDC(attempt: attempt + 1)
                    }
                }
            }
        }
    }

    private func readExternalBrightness() {
        for item in displays where !item.isBuiltin {
            guard item.canSetBrightness, let channel = item.ddc else { continue }
            DispatchQueue.global(qos: .userInitiated).async {
                guard let value = channel.read(0x10) else { return }
                DispatchQueue.main.async {
                    guard item.id != self.draggingDisplay else { return }
                    item.ddcMaximum = value.maximum
                    item.brightness = Double(value.current) / Double(value.maximum)
                }
            }
        }
    }

    /// The brightness slider's position. On the built-in display the slider's bottom is
    /// `builtinMinimum`, not off.
    func sliderBrightness(of item: DisplayItem) -> Double {
        guard item.isBuiltin else { return item.brightness }
        let floor = Self.builtinMinimum
        return min(max((item.brightness - floor) / (1 - floor), 0), 1)
    }

    func setSliderBrightness(_ position: Double, for item: DisplayItem) {
        guard item.isBuiltin else { return setBrightness(position, for: item) }
        let floor = Self.builtinMinimum
        setBrightness(floor + (1 - floor) * min(max(position, 0), 1), for: item)
    }

    func setBrightness(_ value: Double, for item: DisplayItem) {
        let value = min(max(value, 0), 1)
        item.brightness = value
        lastWrite[item.id] = Date()
        if item.isBuiltin {
            let id = item.id
            builtinWriter.submit(value) { PrivateAPI.setBrightness($0, of: id) }
        } else if item.canSetBrightness, let channel = item.ddc {
            channel.write(0x10, value: UInt16((value * Double(item.ddcMaximum)).rounded()))
            defaults.set(value, forKey: "ddc.\(item.key).last")
        }
    }

    /// Moves hardware brightness smoothly (built-in: DisplayServices; external: DDC, whose
    /// writes are coalesced, so a slow monitor simply takes fewer steps).
    /// With `updatesSlider` false only the hardware moves: the caller animates the slider.
    func rampBrightness(_ item: DisplayItem, to target: Double, duration: TimeInterval, updatesSlider: Bool = true) {
        brightnessRamps[item.id]?.invalidate()
        let start = item.isBuiltin ? (PrivateAPI.brightness(of: item.id) ?? item.brightness) : item.brightness
        let began = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let t = min(Date().timeIntervalSince(began) / duration, 1)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let value = start + (target - start) * eased
            if updatesSlider || !item.isBuiltin {
                self.setBrightness(value, for: item)
            } else {
                self.lastWrite[item.id] = Date()
                let id = item.id
                self.builtinWriter.submit(value) { PrivateAPI.setBrightness($0, of: id) }
            }
            if t >= 1 {
                timer.invalidate()
                self.brightnessRamps[item.id] = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        brightnessRamps[item.id] = timer
    }

    func setDragging(_ dragging: Bool, for item: DisplayItem) {
        draggingDisplay = dragging ? item.id : nil
    }

    // MARK: Power

    private struct OffRecord: Codable {
        var id: CGDirectDisplayID
        var key: String
        var name: String
        var builtin: Bool
        var brightness: Double?
    }

    private static let offRecordsKey = "power.offDisplays"

    private func loadOffRecords() -> [OffRecord] {
        guard let data = defaults.data(forKey: Self.offRecordsKey) else { return [] }
        return (try? JSONDecoder().decode([OffRecord].self, from: data)) ?? []
    }

    private func saveOffRecords() {
        guard live else { return }
        let records = displays.filter(\.isOff).map {
            OffRecord(id: $0.id, key: $0.key, name: $0.name, builtin: $0.isBuiltin, brightness: $0.powerBrightness)
        }
        if records.isEmpty {
            defaults.removeObject(forKey: Self.offRecordsKey)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.offRecordsKey)
        }
    }

    /// Any display can be turned off when there is more than one: turning off the last one
    /// that is on turns another one on in its place.
    var canTurnOff: Bool {
        displays.count > 1 && PrivateAPI.canSwitchDisplays
    }

    func setPower(_ on: Bool, for item: DisplayItem) {
        guard on == item.isOff, !item.isSwitching, !displays.contains(where: \.isSwitching) else { return }
        if on {
            item.isSwitching = true
            withAnimation(Self.layoutAnimation) {
                objectWillChange.send()
                item.showsOff = false
            }
            switchPower(turnOn: [item], turnOff: [])
            return
        }
        guard canTurnOff else { NSSound.beep(); return }
        // Never all off: if this is the last display on, another one comes on in its place.
        let othersOn = displays.filter { !$0.isOff && $0.id != item.id }
        let partner = othersOn.isEmpty ? (displays.first { $0.isOff && $0.isBuiltin } ?? displays.first(where: \.isOff)) : nil
        item.isSwitching = true
        partner?.isSwitching = true
        // The panel settles right away, while the screen fades out.
        withAnimation(Self.layoutAnimation) {
            objectWillChange.send()
            item.showsOff = true
            partner?.showsOff = false
        }
        // Fade the screen to black first, so it goes off softly.
        gamma.animate(item.id, to: 0, duration: 0.25) { [weak self] in
            self?.switchPower(turnOn: partner.map { [$0] } ?? [], turnOff: [item])
        }
    }

    /// Reconfigures the displays off the main thread (it takes a moment), with the other
    /// screens' dimming guarded through macOS's gamma reset.
    private func switchPower(turnOn: [DisplayItem], turnOff: [DisplayItem]) {
        gamma.guardTables(excluding: Set((turnOn + turnOff).map(\.id)))

        // Displays going off: hardware brightness to minimum, remembering it for later.
        for item in turnOff {
            if item.isBuiltin {
                item.powerBrightness = PrivateAPI.brightness(of: item.id)
                PrivateAPI.setBrightness(0, of: item.id)
            } else if item.canSetBrightness, let channel = item.ddc {
                item.powerBrightness = item.dimEnabled ? (item.savedBrightness ?? item.brightness) : item.brightness
                let channelCopy = channel
                DispatchQueue.global(qos: .userInitiated).sync { channelCopy.writeNow(0x10, value: 0) }
            }
        }

        let changes = turnOn.map { ($0.id, true) } + turnOff.map { ($0.id, false) }
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = PrivateAPI.setDisplaysEnabled(changes)
            if !ok && changes.count > 1 {
                // One change at a time, the display coming on first.
                ok = changes.allSatisfy { PrivateAPI.setDisplayEnabled($0.1, $0.0) }
            }
            DispatchQueue.main.async { self.finishSwitch(ok: ok, turnOn: turnOn, turnOff: turnOff) }
        }
    }

    private func finishSwitch(ok: Bool, turnOn: [DisplayItem], turnOff: [DisplayItem]) {
        for item in turnOn + turnOff { item.isSwitching = false }
        guard ok else {
            NSSound.beep()
            withAnimation(Self.layoutAnimation) {
                objectWillChange.send()
                for item in turnOff { item.showsOff = false }
                for item in turnOn { item.showsOff = true }
            }
            for item in turnOff {
                gamma.setFactor(item.dimEnabled ? Self.gammaFactor(item.dimLevel) : 1, for: item.id)
                if let saved = item.powerBrightness { setBrightness(saved, for: item) }
            }
            // A display that can't be turned on is no longer there (unplugged): drop it.
            displays.removeAll { item in turnOn.contains { $0 === item } }
            saveOffRecords()
            return
        }
        objectWillChange.send()
        for item in turnOff { item.isOff = true }
        for item in turnOn { item.isOff = false }
        for item in turnOff {
            // It keeps its gamma table while off: put the normal one back, or it would come
            // back black.
            gamma.restoreAndForget(item.id)
            item.ddc = nil
            item.ddcAnswered = false
            // Found again (and asked) once it is back on: until then nothing is written to it,
            // and its brightness waits in `pendingBrightness`.
            if !item.isBuiltin { item.canSetBrightness = false }
        }
        for item in turnOn {
            turnedOnAt[item.id] = Date()
            let saved = item.powerBrightness
            item.powerBrightness = nil
            // About 0.25 s after a display comes on, macOS puts its gamma back to full for a
            // moment. Hardware brightness stays at its minimum (where it was while off) and
            // the gamma is held black through that, so nothing lights up; then both rise
            // together.
            if item.isBuiltin { PrivateAPI.setBrightness(0, of: item.id) }
            gamma.setFactor(0, for: item.id)
            gamma.guardDisplay(item.id, for: 0.7)
            let target = item.dimEnabled ? Self.gammaFactor(item.dimLevel) : 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                self.gamma.animate(item.id, to: target, duration: 0.5)
                guard let saved else { return }
                if item.isBuiltin {
                    self.rampBrightness(item, to: saved, duration: 0.5)
                } else if item.canSetBrightness {
                    self.rampBrightness(item, to: saved, duration: 0.5)
                } else {
                    item.pendingBrightness = saved // ramped once DDC answers again
                }
            }
        }
        saveOffRecords()
        scheduleRefresh()
    }

    // MARK: Reduce brightness

    static func gammaFactor(_ level: Double) -> Double {
        dimFloor + (1 - dimFloor) * min(max(level, 0), 1)
    }

    func setDimEnabled(_ on: Bool, for item: DisplayItem) {
        guard on != item.dimEnabled else { return }
        if on {
            item.savedBrightness = item.canSetBrightness ? item.brightness : nil
            item.dimLevel = 1
            item.dimEnabled = true
            if item.canSetBrightness { setBrightness(0, for: item) }
            gamma.setFactor(1, for: item.id)
        } else {
            gamma.setFactor(1, for: item.id)
            item.dimEnabled = false
            if let saved = item.savedBrightness, item.canSetBrightness { setBrightness(saved, for: item) }
        }
        saveDim(item)
    }

    func setDimLevel(_ level: Double, for item: DisplayItem) {
        item.dimLevel = min(max(level, 0), 1)
        gamma.setFactor(Self.gammaFactor(item.dimLevel), for: item.id)
        saveDim(item)
    }

    /// Emergency shortcut: turns "Reduce brightness" off everywhere.
    func disableAllDimming() {
        for item in displays where item.dimEnabled {
            setDimEnabled(false, for: item)
        }
        gamma.restoreAll()
    }

    // MARK: Black screen

    /// Built-in display only. On: hardware brightness to a true 0, so the backlight goes off
    /// while the display stays on and part of the desktop. Off: the brightness from before.
    ///
    /// The slider glides to 0 and then fades to grey; turning it off, it fades back in and
    /// then glides up. The backlight follows the slider.
    func setBlackScreen(_ on: Bool, for item: DisplayItem) {
        guard item.isBuiltin, item.canSetBrightness, on != item.isBlack, !item.blackSliding else { return }
        let slide = 0.4, fade = 0.3
        if on {
            item.blackSavedBrightness = item.brightness
            item.blackSliding = true
            rampBrightness(item, to: 0, duration: slide, updatesSlider: false)
            withAnimation(.easeInOut(duration: slide)) { item.brightness = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + slide) {
                withAnimation(.easeInOut(duration: fade)) { item.blackSliding = false }
            }
        } else {
            let target = max(item.blackSavedBrightness ?? 0.5, Self.builtinMinimum)
            item.blackSavedBrightness = nil
            withAnimation(.easeInOut(duration: fade)) {
                item.blackSliding = true
                item.blackLeaving = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + fade) {
                self.rampBrightness(item, to: target, duration: slide, updatesSlider: false)
                withAnimation(.easeInOut(duration: slide)) { item.brightness = target }
                DispatchQueue.main.asyncAfter(deadline: .now() + slide) {
                    item.blackSliding = false
                    item.blackLeaving = false
                }
            }
        }
    }

    private func saveDim(_ item: DisplayItem) {
        guard live else { return }
        defaults.set(item.dimEnabled, forKey: "dim.\(item.key).enabled")
        defaults.set(item.dimLevel, forKey: "dim.\(item.key).level")
        if let saved = item.savedBrightness {
            defaults.set(saved, forKey: "dim.\(item.key).saved")
        } else {
            defaults.removeObject(forKey: "dim.\(item.key).saved")
        }
    }
}

/// Runs a write on a background queue; while one is running, newer values replace older
/// pending ones, so a fast slider or ramp never piles up work.
final class LatestValueWriter {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: (Double, (Double) -> Void)?
    private var running = false

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    func submit(_ value: Double, _ apply: @escaping (Double) -> Void) {
        let start: Bool = lock.withLock {
            pending = (value, apply)
            defer { running = true }
            return !running
        }
        guard start else { return }
        queue.async { self.drain() }
    }

    private func drain() {
        while true {
            let next: (Double, (Double) -> Void)? = lock.withLock {
                defer { pending = nil }
                if pending == nil { running = false }
                return pending
            }
            guard let (value, apply) = next else { return }
            apply(value)
        }
    }
}
