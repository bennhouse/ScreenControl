import AppKit
import Combine

/// Dark Mode, Night Shift and True Tone, with the status lines Control Center shows.
final class SystemToggles: ObservableObject {
    @Published var darkMode = false
    @Published var darkModeAutomatic = false
    @Published var nightShift = false
    @Published var nightShiftAvailable = false
    @Published var nightShiftSubtitle = "Off"
    @Published var trueTone = false
    @Published var trueToneAvailable = false

    private let nightShiftClient: NightShiftClient?
    private let trueToneClient: TrueToneClient?

    init(live: Bool = true) {
        nightShiftClient = live ? NightShiftClient() : nil
        trueToneClient = live ? TrueToneClient() : nil
    }

    var darkModeSubtitle: String {
        if darkModeAutomatic { return darkMode ? "On until tomorrow" : "Off until later" }
        return darkMode ? "On" : "Off"
    }

    var trueToneSubtitle: String { trueTone ? "On" : "Off" }

    func start() {
        guard nightShiftClient != nil else { return }
        refresh()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        nightShiftClient?.onChange { [weak self] in self?.refresh() }
    }

    func refresh() {
        guard let nightShiftClient, let trueToneClient else { return }
        darkMode = PrivateAPI.isDarkMode
        darkModeAutomatic = PrivateAPI.appearanceSwitchesAutomatically

        if let status = nightShiftClient.status() {
            nightShiftAvailable = status.available
            nightShift = status.enabled
            nightShiftSubtitle = Self.nightShiftSubtitle(status)
        } else {
            nightShiftAvailable = false
            nightShift = false
            nightShiftSubtitle = "Off"
        }

        trueToneAvailable = trueToneClient.isSupported
        trueTone = trueToneAvailable && trueToneClient.isEnabled
    }

    private static func nightShiftSubtitle(_ status: NightShiftClient.Status) -> String {
        switch status.mode {
        case 1:
            return status.enabled ? "On until sunrise" : "Off until sunset"
        case 2:
            let time = status.enabled ? status.to : status.from
            return (status.enabled ? "On until " : "Off until ") + timeString(hour: Int(time.hour), minute: Int(time.minute))
        default:
            return status.enabled ? "On" : "Off"
        }
    }

    private static func timeString(hour: Int, minute: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        guard let date = Calendar.current.date(from: components) else { return String(format: "%d:%02d", hour, minute) }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    // MARK: Actions

    func toggleDarkMode() {
        let on = !darkMode
        darkMode = on
        PrivateAPI.setDarkMode(on) { [weak self] in self?.refresh() }
    }

    func toggleNightShift() {
        guard nightShiftAvailable else { return }
        nightShift.toggle()
        nightShiftClient?.setEnabled(nightShift)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    func toggleTrueTone() {
        guard trueToneAvailable else { return }
        trueTone.toggle()
        trueToneClient?.setEnabled(trueTone)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }
}
