import SwiftUI

/// Glyphs drawn to match Control Center's Display module (sizes in points, measured from the
/// system menu at 2x).

private func drawRays(_ context: inout GraphicsContext, center: CGPoint, inner: CGFloat, outer: CGFloat,
                      width: CGFloat, color: Color) {
    var rays = Path()
    for index in 0..<8 {
        let angle = Double(index) * .pi / 4
        let dx = CGFloat(cos(angle)), dy = CGFloat(sin(angle))
        rays.move(to: CGPoint(x: center.x + dx * inner, y: center.y + dy * inner))
        rays.addLine(to: CGPoint(x: center.x + dx * outer, y: center.y + dy * outer))
    }
    context.stroke(rays, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
}

private func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
}

/// The small sun at the start of a brightness slider.
struct SliderSunIcon: View {
    var color: Color
    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            context.fill(circle(c, 2.6), with: .color(color))
            drawRays(&context, center: c, inner: 4.2, outer: 5.6, width: 1.05, color: color)
        }
        .frame(width: 12, height: 12)
    }
}

/// The dimming slider's glyph: a smaller sun with dotted rays, like `sun.min`.
struct SliderDimIcon: View {
    var color: Color
    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            context.fill(circle(c, 2.4), with: .color(color))
            for index in 0..<8 {
                let angle = Double(index) * .pi / 4
                let p = CGPoint(x: c.x + CGFloat(cos(angle)) * 4.6, y: c.y + CGFloat(sin(angle)) * 4.6)
                context.fill(circle(p, 0.75), with: .color(color))
            }
        }
        .frame(width: 12, height: 12)
    }
}

/// The keyboard backlight glyph (like `light.max`): rays fanning up from a short base line.
struct SliderKeyboardIcon: View {
    var color: Color
    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2 + 2.6)
            var path = Path()
            path.move(to: CGPoint(x: c.x - 2.4, y: c.y + 1.4))
            path.addLine(to: CGPoint(x: c.x + 2.4, y: c.y + 1.4))
            for degrees in [180.0, 225, 270, 315, 360] {
                let a = degrees * .pi / 180
                path.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * 3.0, y: c.y + CGFloat(sin(a)) * 3.0))
                path.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * 4.9, y: c.y + CGFloat(sin(a)) * 4.9))
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
        }
        .frame(width: 12, height: 12)
    }
}

/// Dark Mode: a ring with its left half filled, and a small inverted half-disc pair inside.
struct DarkModeIcon: View {
    var color: Color
    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func half(_ radius: CGFloat, left: Bool) -> Path {
                var path = Path()
                path.addArc(center: c, radius: radius, startAngle: .degrees(left ? 90 : -90),
                            endAngle: .degrees(left ? 270 : 90), clockwise: false)
                path.closeSubpath()
                return path
            }
            context.drawLayer { layer in
                layer.stroke(circle(c, 7.85), with: .color(color), lineWidth: 1.3)
                layer.fill(half(7.85, left: true), with: .color(color))
                layer.blendMode = .destinationOut
                layer.fill(half(3.25, left: true), with: .color(.black))
                layer.blendMode = .normal
                layer.fill(half(3.25, left: false), with: .color(color))
            }
        }
        .frame(width: 20, height: 20)
    }
}

/// Night Shift: a sun whose ring holds a moon offset to the upper right (a crescent of sky).
struct NightShiftIcon: View {
    var color: Color
    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            drawRays(&context, center: c, inner: 6.5, outer: 8.4, width: 1.6, color: color)
            context.drawLayer { moon in
                moon.clip(to: circle(c, 3.3))
                moon.fill(circle(CGPoint(x: c.x + 0.95, y: c.y - 0.95), 2.55), with: .color(color))
            }
            context.stroke(circle(c, 3.9), with: .color(color), lineWidth: 1.5)
        }
        .frame(width: 20, height: 20)
        .compositingGroup()
    }
}

/// True Tone: a sun whose disc is drawn as horizontal stripes.
struct TrueToneIcon: View {
    var color: Color
    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            drawRays(&context, center: c, inner: 6.5, outer: 8.4, width: 1.6, color: color)
            context.clip(to: circle(c, 4.6))
            var y = c.y - 4.6
            while y < c.y + 4.6 {
                context.fill(Path(CGRect(x: c.x - 5, y: y, width: 10, height: 1.15)), with: .color(color))
                y += 1.9
            }
        }
        .frame(width: 20, height: 20)
    }
}
