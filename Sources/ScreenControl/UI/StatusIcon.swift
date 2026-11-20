import AppKit

/// The menu bar icon: a display, with a small coffee cup on its screen while Keep Awake is on.
enum StatusIcon {
    static func image(keepAwake: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let display = NSImage(systemSymbolName: "display", accessibilityDescription: "Displays")?
            .withSymbolConfiguration(config) else { return nil }
        guard keepAwake, let cup = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 6.5, weight: .bold)) else {
            display.isTemplate = true
            return display
        }
        let size = display.size
        let image = NSImage(size: size, flipped: false) { rect in
            display.draw(in: rect)
            // The screen is the upper part of the symbol, above the stand: centre the cup in it.
            let screenCenter = NSPoint(x: rect.midX, y: rect.minY + rect.height * 0.60)
            let cupRect = NSRect(x: screenCenter.x - cup.size.width / 2, y: screenCenter.y - cup.size.height / 2,
                                 width: cup.size.width, height: cup.size.height)
            cup.draw(in: cupRect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Displays, Keep Awake on"
        return image
    }
}
