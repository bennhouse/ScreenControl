import AppKit
import SwiftUI

extension Color {
    static var systemAccent: Color { Color(nsColor: .controlAccentColor) }
    /// Control Center's Night Shift button when on: always this orange, whatever the accent colour.
    static let nightShiftOrange = Color(.sRGB, red: 1, green: 166 / 255, blue: 0)
}

// MARK: - Slider

/// Control Center slider: a 22 pt capsule, white fill up to a white knob, glyph at the start.
struct CCSlider: View {
    enum Glyph { case sun, dim, keyboard }

    var value: Double
    var enabled: Bool
    var glyph: Glyph
    var onChange: (Double) -> Void
    var onDragging: (Bool) -> Void = { _ in }

    @Environment(\.colorScheme) private var scheme
    @State private var dragging = false

    private let height: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let knobCenter = height / 2 + CGFloat(min(max(value, 0), 1)) * (width - height)
            ZStack(alignment: .leading) {
                Capsule().fill(trackColor)
                // Fill and knob fade out when the slider is greyed out, rather than vanish.
                Capsule().fill(Color.white).frame(width: knobCenter + height / 2)
                    .opacity(enabled ? 1 : 0)
                // The system draws its thin grey outline over the white fill too.
                Capsule().strokeBorder(rimColor, lineWidth: 1)
                do {
                    // 1 pt smaller all round than the track, so it sits inside the thin outline.
                    // Its dark edge fades out on the left as the knob reaches the glyph, so it
                    // never cuts across it, and comes back as the knob moves away.
                    let size = height - 2
                    // The glyph ends about 18 pt from the start; the edge (knob centre - 10 pt)
                    // fades over the last 7 pt before it and is gone while over the glyph.
                    let clear = min(max((knobCenter - 28) / 7, 0), 1)
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.25), radius: 0.8, x: 0, y: 0.3)
                            .frame(width: size, height: size)
                            .padding(3)
                            .mask(LinearGradient(stops: [.init(color: .black.opacity(clear), location: 0),
                                                         .init(color: .black.opacity(clear), location: 0.45),
                                                         .init(color: .black, location: 0.7)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .padding(-3)
                        Circle()
                            .fill(Color.white)
                            .frame(width: size, height: size)
                    }
                    .offset(x: knobCenter - height / 2 + 1)
                    .opacity(enabled ? 1 : 0)
                }
                glyphView
                    .frame(width: height, height: height)
                    .allowsHitTesting(false)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard enabled else { return }
                        if !dragging {
                            dragging = true
                            onDragging(true)
                        }
                        let fraction = (drag.location.x - height / 2) / max(width - height, 1)
                        onChange(Double(min(max(fraction, 0), 1)))
                    }
                    .onEnded { _ in
                        guard dragging else { return }
                        dragging = false
                        onDragging(false)
                    }
            )
        }
        .frame(height: height)
    }

    @ViewBuilder private var glyphView: some View {
        let color = Color(white: scheme == .dark ? 0.55 : 0.8)
        switch glyph {
        case .sun: SliderSunIcon(color: color)
        case .dim: SliderDimIcon(color: color)
        case .keyboard: SliderKeyboardIcon(color: color)
        }
    }

    private var trackColor: Color {
        switch (enabled, scheme) {
        case (true, .dark): return Color.white.opacity(0.17)
        case (true, _): return Color.black.opacity(0.13)
        case (false, .dark): return Color.white.opacity(0.07)
        case (false, _): return Color.white.opacity(0.22)
        }
    }

    private var rimColor: Color {
        switch (enabled, scheme) {
        case (true, .dark): return Color.white.opacity(0.06)
        case (true, _): return Color.black.opacity(0.2)
        case (false, .dark): return Color.white.opacity(0.12)
        case (false, _): return Color.black.opacity(0.17)
        }
    }
}

// MARK: - Round toggle

/// Control Center button: 36 pt circle, accent colour when on, bold title and status below.
struct RoundToggle<Icon: View>: View {
    var title: String
    var subtitle: String
    var isOn: Bool
    var enabled: Bool = true
    var onFill: Color = .systemAccent
    var onIcon: Color = .white
    var icon: (Color) -> Icon
    var action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                ZStack {
                    Circle().fill(isOn ? onFill : offFill)
                    icon(isOn ? onIcon : (scheme == .dark ? Color(white: 0.88) : Color(white: 0.3)))
                }
                .frame(width: 36, height: 36)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)

            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .padding(.top, 5)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Color.primary.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 95)
    }

    private var offFill: Color {
        scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10)
    }
}

// MARK: - Check row

/// A small checkable option: an empty circle when off; when on, a filled check mark and the
/// label both take the accent colour.
struct CheckRow: View {
    var title: String
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Group {
                    if isOn {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.systemAccent)
                    } else {
                        Image(systemName: "circle")
                            .foregroundStyle(Color.primary.opacity(0.4))
                    }
                }
                .font(.system(size: 13, weight: .regular))
                // 22 pt wide, like the slider's knob, so the check sits right under the sun glyph.
                .frame(width: 22, height: 15)

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isOn ? Color.systemAccent : Color.primary.opacity(0.7))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Power button

/// Turns a display off and on. On: a grey power glyph. Off: "Off" and a green power button.
struct PowerButton: View {
    var isOff: Bool
    var isSwitching: Bool = false
    var enabled: Bool
    var offLabel: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isSwitching {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .frame(width: 16, height: 16)
                } else if isOff {
                    Text(offLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.primary.opacity(0.6))
                    ZStack {
                        Circle().fill(Color(nsColor: .systemGreen))
                        Image(systemName: "power").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white)
                    }
                    .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(hovering && enabled ? 0.75 : 0.42))
                        .frame(width: 16, height: 16)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || isSwitching)
        .opacity(enabled || isSwitching ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.2), value: isSwitching)
        .animation(.easeInOut(duration: 0.2), value: isOff)
        .onHover { hovering = $0 }
        .help(isOff ? "Turn display on" : (enabled ? "Turn display off (it stays connected)" : "The last display on can't be turned off"))
    }
}

// MARK: - Menu row

/// A plain text row with the rounded hover highlight of a menu item.
struct MenuRow: View {
    var title: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .onHover { hovering = $0 }
    }
}
