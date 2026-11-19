import Combine
import Foundation

/// Built-in keyboard backlight, shown as a slider when the Mac has one.
final class KeyboardBacklight: ObservableObject {
    @Published var brightness: Double = 0
    @Published var available = false

    private let client: KeyboardBacklightClient?
    private var pollTimer: Timer?
    private var dragging = false

    init(live: Bool = true) {
        client = live ? KeyboardBacklightClient() : nil
        available = client?.keyboardID != nil
        refresh()
    }

    func refresh() {
        guard !dragging, let value = client?.brightness else { return }
        if abs(value - brightness) > 0.002 { brightness = value }
    }

    func setBrightness(_ value: Double) {
        brightness = min(max(value, 0), 1)
        client?.setBrightness(brightness)
    }

    func setDragging(_ value: Bool) { dragging = value }

    /// While the panel is open, follows changes from the keyboard keys and ambient light.
    func setPanelVisible(_ visible: Bool) {
        pollTimer?.invalidate()
        pollTimer = nil
        guard visible, client != nil else { return }
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.refresh() }
    }
}
