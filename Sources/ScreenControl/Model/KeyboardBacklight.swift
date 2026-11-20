import Combine
import SwiftUI

/// Built-in keyboard backlight, shown as a slider when the Mac has one.
final class KeyboardBacklight: ObservableObject {
    @Published var brightness: Double = 0
    @Published var available = false

    private let client: KeyboardBacklightClient?
    private var pollTimer: Timer?
    private var dragging = false
    private var lastWrite = Date.distantPast

    init(live: Bool = true) {
        client = live ? KeyboardBacklightClient() : nil
        available = client?.keyboardID != nil
        refresh()
    }

    func refresh(animated: Bool = false) {
        guard !dragging, Date().timeIntervalSince(lastWrite) > 0.6, let value = client?.brightness,
              abs(value - brightness) > 0.002 else { return }
        if animated {
            withAnimation(DisplayController.followAnimation) { brightness = value }
        } else {
            brightness = value
        }
    }

    func setBrightness(_ value: Double) {
        brightness = min(max(value, 0), 1)
        lastWrite = Date()
        client?.setBrightness(brightness)
    }

    func setDragging(_ value: Bool) { dragging = value }

    /// While the panel is open, follows changes from the keyboard keys and ambient light,
    /// gliding between readings ten times a second.
    func setPanelVisible(_ visible: Bool) {
        pollTimer?.invalidate()
        pollTimer = nil
        guard visible, client != nil else { return }
        refresh()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh(animated: true) }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
}
