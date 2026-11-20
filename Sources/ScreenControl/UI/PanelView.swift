import SwiftUI

struct PanelStrings {
    var darkMode = "Dark Mode"
    var nightShift = "Night Shift"
    var trueTone = "True Tone"
    var reduceBrightness = "Reduce brightness"
    var blackScreen = "Black screen"
    var keyboardBrightness = "Keyboard Brightness"
    var off = "Off"
    var displaySettings = "Display Settings…"
}

/// The panel content. Metrics are taken from the system Display menu (298 pt wide).
struct PanelView: View {
    @ObservedObject var displays: DisplayController
    @ObservedObject var toggles: SystemToggles
    @ObservedObject var keyboard: KeyboardBacklight
    var strings = PanelStrings()
    var showReduceRow = true
    var onOpenSettings: () -> Void = {}

    static let width: CGFloat = 298

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(displays.displays) { item in
                DisplaySection(item: item, controller: displays, strings: strings, showReduceRow: showReduceRow)
            }

            if keyboard.available {
                VStack(alignment: .leading, spacing: 0) {
                    SectionTitle(text: strings.keyboardBrightness)
                    CCSlider(value: keyboard.brightness, enabled: true, glyph: .keyboard,
                             onChange: keyboard.setBrightness, onDragging: keyboard.setDragging)
                }
                .padding(.horizontal, 14)
            }

            HStack(alignment: .top, spacing: 0) {
                // As in Control Center, when on: Dark Mode turns white, Night Shift orange,
                // True Tone the accent colour.
                RoundToggle(title: strings.darkMode, subtitle: toggles.darkModeSubtitle, isOn: toggles.darkMode,
                            onFill: .white, onIcon: Color(white: 0.1),
                            icon: { DarkModeIcon(color: $0) }, action: toggles.toggleDarkMode)
                RoundToggle(title: strings.nightShift, subtitle: toggles.nightShiftSubtitle, isOn: toggles.nightShift,
                            enabled: toggles.nightShiftAvailable, onFill: .nightShiftOrange, icon: { NightShiftIcon(color: $0) }, action: toggles.toggleNightShift)
                RoundToggle(title: strings.trueTone, subtitle: toggles.trueToneSubtitle, isOn: toggles.trueTone,
                            enabled: toggles.trueToneAvailable, icon: { TrueToneIcon(color: $0) }, action: toggles.toggleTrueTone)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.top, 14)

            Rectangle()
                .fill(Color.primary.opacity(0.13))
                .frame(height: 1)
                .padding(.horizontal, 14)
                .padding(.top, 11)

            MenuRow(title: strings.displaySettings, action: onOpenSettings)
                .padding(.top, 4)
                .padding(.bottom, 6)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Bold section title with the spacing of the system menu (baseline 26 pt below the previous
/// slider, slider 14 pt below the baseline).
private struct SectionTitle<Accessory: View>: View {
    var text: String
    var accessory: Accessory

    init(text: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.text = text
        self.accessory = accessory()
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) { accessory }
            .padding(.top, 13.5)
            .padding(.bottom, 10.5)
    }
}

private struct DisplaySection: View {
    @ObservedObject var item: DisplayItem
    @ObservedObject var controller: DisplayController
    let strings: PanelStrings
    let showReduceRow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: item.name) {
                PowerButton(isOff: item.showsOff, isSwitching: item.isSwitching, enabled: item.showsOff || controller.canTurnOff, offLabel: strings.off) {
                    controller.setPower(item.isOff, for: item)
                }
            }
            .padding(.bottom, item.showsOff ? -8 : 0)

            if !item.showsOff {
                CCSlider(
                    value: item.dimEnabled ? item.dimLevel : controller.sliderBrightness(of: item),
                    // Greyed out while the built-in screen is black (brightness at 0, from Black screen
                    // or the brightness keys), as the system slider does.
                    enabled: item.dimEnabled || (item.canSetBrightness && !item.showsBlack),
                    glyph: item.dimEnabled ? .dim : .sun,
                    onChange: { value in
                        if item.dimEnabled {
                            controller.setDimLevel(value, for: item)
                        } else {
                            controller.setSliderBrightness(value, for: item)
                        }
                    },
                    onDragging: { controller.setDragging($0, for: item) }
                )
                .transition(.opacity)

                if showReduceRow && !item.isBuiltin {
                    CheckRow(title: strings.reduceBrightness, isOn: item.dimEnabled) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            controller.setDimEnabled(!item.dimEnabled, for: item)
                        }
                    }
                    .padding(.top, 8)
                    .transition(.opacity)
                }
                if showReduceRow && item.isBuiltin && item.canSetBrightness {
                    CheckRow(title: strings.blackScreen, isOn: item.showsBlackChecked) {
                        controller.setBlackScreen(!item.isBlack, for: item)
                    }
                    .padding(.top, 8)
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 14)
    }
}
