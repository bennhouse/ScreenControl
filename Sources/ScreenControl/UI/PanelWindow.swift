import AppKit
import SwiftUI

/// Borderless, non-activating panel with Control Center's translucent material and 6 pt
/// corners, like the panels Control Center opens from the menu bar.
final class PanelWindow: NSPanel {
    static let cornerRadius: CGFloat = 6
    /// Shared with the SwiftUI layout animation so the window and its content move together.
    static let resizeDuration: TimeInterval = 0.3
    /// Space between the bottom of the menu bar and the top of the panel.
    static let menuBarGap: CGFloat = 5

    var onClose: (() -> Void)?
    private let hosting: NSHostingView<AnyView>

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
        setFrame(frame(below: statusWindow), display: true)
        alphaValue = 1
        makeKeyAndOrderFront(nil)
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
