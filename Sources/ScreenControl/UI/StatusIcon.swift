import AppKit

/// The menu bar icon: a display, with a small coffee cup on its screen while Keep Awake is on.
enum StatusIcon {
    static func image(keepAwake: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let display = NSImage(systemSymbolName: "display", accessibilityDescription: "Displays")?
            .withSymbolConfiguration(config) else { return nil }
        let cup = keepAwake ? NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 6.5, weight: .bold)) : nil
        // Both states are drawn the same way, into an image of the symbol's size with the
        // symbol's alignment rect: the status button centres an image on its alignment rect,
        // so a plain symbol and a drawn image would otherwise sit a fraction of a point apart
        // and the display would shift when the cup appears.
        let size = display.size
        let image = NSImage(size: size, flipped: false) { rect in
            display.draw(in: rect)
            if let cup {
                // The screen is the upper part of the symbol, above the stand: centre the cup in it.
                let screenCenter = NSPoint(x: rect.midX, y: rect.minY + rect.height * 0.60)
                let cupRect = NSRect(x: screenCenter.x - cup.size.width / 2, y: screenCenter.y - cup.size.height / 2,
                                     width: cup.size.width, height: cup.size.height)
                cup.draw(in: cupRect)
            }
            return true
        }
        image.alignmentRect = display.alignmentRect
        image.isTemplate = true
        image.accessibilityDescription = keepAwake ? "Displays, Keep Awake on" : "Displays"
        return image
    }
}
