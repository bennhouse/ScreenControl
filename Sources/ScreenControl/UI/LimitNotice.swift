import AppKit
import SwiftUI

/// "Keep Awake turned off": a small popover under the menu bar icon, shown when a session
/// reaches the 24-hour limit. Built like Scene's icon picker popover (an AppKit NSPopover with
/// SwiftUI content, its size fixed before opening so it stays centred on the icon). It fades in
/// and out, closes by itself after a few seconds, on a click anywhere, or when the panel opens.
final class LimitNotice: NSObject, NSPopoverDelegate {
    static let visibleDuration: TimeInterval = 6
    static let fadeInDuration: TimeInterval = 0.25
    static let fadeOutDuration: TimeInterval = 0.35

    private var popover: NSPopover?
    private var closeWork: DispatchWorkItem?
    private var clickMonitor: Any?

    func show(below button: NSView) {
        close()
        let p = NSPopover()
        // Closed by this class (timer, clicks): a transient popover only notices clicks
        // outside while the app is active, which a menu bar app seldom is.
        p.behavior = .applicationDefined
        // Faded here, on the popover's own window: NSPopover's closing animation swaps in a
        // snapshot window, which is how a white flash got into ScreenControl's panel.
        p.animates = false
        let host = NSHostingController(rootView: LimitNoticeView())
        host.view.layoutSubtreeIfNeeded()
        // An even width in whole points, so the popover (and its arrow) can sit exactly
        // centred on the icon instead of half a point to one side.
        var size = host.view.fittingSize
        size.width = (size.width / 2).rounded(.up) * 2
        size.height = size.height.rounded(.up)
        host.preferredContentSize = size
        p.contentSize = size
        p.contentViewController = host
        p.delegate = self
        popover = p
        // Anchored on the icon's centre line rather than the whole button.
        let anchor = NSRect(x: button.bounds.midX - 1, y: button.bounds.minY, width: 2, height: button.bounds.height)
        p.show(relativeTo: anchor, of: button, preferredEdge: .minY)
        if let window = host.view.window {
            window.animationBehavior = .none
            window.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeInDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        }

        let work = DispatchWorkItem { [weak self] in self?.close() }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: work)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    var isShown: Bool { popover != nil }
    var windowNumber: Int? { popover?.contentViewController?.view.window?.windowNumber }

    /// Fades out, then closes.
    func close() {
        closeWork?.cancel()
        closeWork = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard let p = popover else { return }
        popover = nil
        guard let window = p.contentViewController?.view.window else { return p.close() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            window.animator().alphaValue = 0
        } completionHandler: {
            p.close()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if (notification.object as? NSPopover) === popover { close() }
    }
}

private struct LimitNoticeView: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "cup.and.saucer")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Keep Awake turned off")
                    .font(.system(size: 13, weight: .semibold))
                Text("It had been on for 24 hours.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .fixedSize()
    }
}
