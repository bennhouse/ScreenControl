import AppKit
import SwiftUI

/// Off-screen rendering of the panel for layout checks (no blur: a flat grey stands in for it).
enum Snapshot {
    @MainActor
    static func render(to path: String, dark: Bool, reference: Bool) {
        let external = DisplayItem(id: 2, name: "PHL 288E2", isBuiltin: false, key: "mock-ext")
        external.brightness = reference ? 0 : 0.35
        external.canSetBrightness = !reference
        let builtin = DisplayItem(id: 1, name: reference ? "Monitor Retina integrato" : "Built-in Retina Display",
                                  isBuiltin: true, key: "mock-int")
        builtin.brightness = 0.728
        builtin.canSetBrightness = true

        if CommandLine.arguments.contains("--off") { builtin.isOff = true; builtin.showsOff = true }
        external.dimEnabled = CommandLine.arguments.contains("--dimmed")
        external.dimLevel = 0.6
        let controller = DisplayController(mock: [external, builtin])
        let toggles = SystemToggles(live: false)
        toggles.darkModeAutomatic = true
        toggles.darkMode = dark && !reference
        toggles.nightShiftAvailable = true
        toggles.trueToneAvailable = true
        toggles.trueTone = true

        var strings = PanelStrings()
        if reference {
            strings.darkMode = "Modalità scura"
            strings.displaySettings = "Impostazioni Schermi…"
            toggles.nightShiftSubtitle = "Non attivo fino\nal tramonto"
        } else {
            toggles.nightShiftSubtitle = "Off until\nsunset"
        }

        let keyboard = KeyboardBacklight(live: false)
        keyboard.available = !reference
        keyboard.brightness = 0.42
        let view = PanelView(displays: controller, toggles: toggles, keyboard: keyboard, strings: strings,
                             showReduceRow: !reference)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(dark ? Color(white: 0.17) : Color(white: reference ? 0.92 : 0.80))
            .environment(\.locale, Locale(identifier: "en_US"))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("render failed")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(image.size)")
    }
}
