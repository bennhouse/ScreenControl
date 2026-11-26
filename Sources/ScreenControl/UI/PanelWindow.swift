import AppKit
import SwiftUI

/// Borderless, non-activating panel with Control Center's translucent material and 6 pt
/// corners, like the panels Control Center opens from the menu bar.
final class PanelWindow: NSPanel {
    static let cornerRadius: CGFloat = 6
    /// Shared with the SwiftUI layout animation so the window and its content move together.
    static let resizeDuration: TimeInterval = 0.3
    /// Space between the bottom of the status item window and the top of the panel: 2 pt, as
    /// macOS places its own menu bar extra windows (measured on a `MenuBarExtra(.window)`:
    /// status window bottom at 876, its window top at 874), 1 pt under the menu bar itself.
    static let menuBarGap: CGFloat = 2
    /// Closing fade: linear, twice as long as the system's (about 0.11 s, measured from the
    /// window server).
    static let fadeOutDuration: TimeInterval = 0.22

    var onClose: (() -> Void)?
    private let hosting: NSHostingView<AnyView>
    /// Set while the closing fade runs; the panel is still on screen but already closed.
    private(set) var isFadingOut = false
    private var fadeGeneration = 0

    /// Open, and not on its way out.
    var isShown: Bool { isVisible && !isFadingOut }

    init<Content: View>(content: Content) {
        hosting = NSHostingView(rootView: AnyView(content))
        super.init(contentRect: NSRect(x: 0, y: 0, width: PanelView.width, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let effect = SystemMaterialView(frame: NSRect(x: 0, y: 0, width: PanelView.width, height: 200))
        effect.cornerRadius = Self.cornerRadius
        contentView = effect

        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        let border = BorderView()
        border.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(border)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            border.topAnchor.constraint(equalTo: effect.topAnchor),
            border.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
    }

    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { Self.resizeDuration }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    var fittingHeight: CGFloat {
        hosting.fittingSize.height
    }

    /// Shows the panel under the status item, its left edge on the item's left edge.
    /// `statusWindow` is the status item window that was clicked: with several displays there is
    /// one per menu bar.
    func show(below statusWindow: NSWindow) {
        // Reopened during the closing fade: stop it where it is.
        fadeGeneration += 1
        isFadingOut = false
        ignoresMouseEvents = false
        animationBehavior = .utilityWindow
        setFrame(frame(below: statusWindow), display: true)
        alphaValue = 1
        makeKeyAndOrderFront(nil)
    }

    /// Closes with its own fade instead of the system's: macOS fades a snapshot of the window,
    /// in which the live backdrop material can't be captured and shows as a white flash.
    /// Fading the window itself keeps the material live to the end.
    func fadeOut() {
        guard isVisible, !isFadingOut else { return }
        isFadingOut = true
        ignoresMouseEvents = true
        fadeGeneration += 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, generation == self.fadeGeneration else { return }
            // No system animation on the way out: the window is already transparent.
            self.animationBehavior = .none
            self.orderOut(nil)
            self.isFadingOut = false
            self.ignoresMouseEvents = false
            self.alphaValue = 1
        }
    }

    /// Puts the panel back under its status item after macOS has rearranged the displays
    /// (it moves open windows when a display comes or goes).
    func place(below statusWindow: NSWindow, animated: Bool) {
        let target = frame(below: statusWindow)
        guard target != frame else { return }
        // Only a change of height is animated (the panel growing or shrinking under its icon).
        // A move means the screen coordinates changed (another display came or went): the
        // panel is already in the right place on screen, so it just follows, without sliding.
        let sameAnchor = abs(target.minX - frame.minX) < 1 && abs(target.maxY - frame.maxY) < 1
        if animated && sameAnchor {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.resizeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(target, display: true)
            }
        } else {
            setFrame(target, display: true)
        }
    }

    private func frame(below statusWindow: NSWindow) -> NSRect {
        let anchor = statusWindow.frame
        let screen = statusWindow.screen ?? NSScreen.main
        let size = NSSize(width: PanelView.width, height: fittingHeight)
        // A small gap under the menu bar, as Control Center's panels have (the status item
        // window spans the bar's full height).
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - Self.menuBarGap - size.height)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - size.width - 6)
        }
        return NSRect(origin: origin, size: size)
    }

    func resizeKeepingTop(animated: Bool = true) {
        let height = fittingHeight
        guard abs(height - frame.height) > 0.5 else { return }
        var newFrame = frame
        newFrame.origin.y = frame.maxY - height
        newFrame.size.height = height
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.resizeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(newFrame, display: true)
            }
        } else {
            setFrame(newFrame, display: true)
        }
    }
}

/// Hairline around the panel, as on system menus.
private final class BorderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let rect = bounds.insetBy(dx: 0.25, dy: 0.25)
        let path = NSBezierPath(roundedRect: rect, xRadius: PanelWindow.cornerRadius, yRadius: PanelWindow.cornerRadius)
        path.lineWidth = 0.5
        (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.08)).setStroke()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        needsDisplay = true
    }
}
