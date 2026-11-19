import AppKit
import QuartzCore

/// The translucent material of Control Center and menu bar extra windows on macOS 15, rebuilt
/// layer for layer from the window SwiftUI's `MenuBarExtra(.window)` creates:
///
/// - a backdrop of what is behind the window, at quarter resolution, saturated and blurred
///   (radius 60), under a light or dark grey veil;
/// - a solid grey on top with a darken (light) or lighten (dark) blend, which evens out the
///   brightness while keeping the colours of the background.
///
/// Falls back to the `.menu` visual effect if the private layer classes are missing.
final class SystemMaterialView: NSView {
    private let backdrop: CALayer?
    private let tint = CALayer()
    private let saturate: NSObject?
    private var fallback: NSVisualEffectView?

    override init(frame: NSRect) {
        let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type
        backdrop = backdropClass?.init()
        saturate = Self.filter("colorSaturate")
        let blur = Self.filter("gaussianBlur")
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        if let backdrop, let saturate, let blur {
            backdrop.setValue(true, forKey: "windowServerAware")
            backdrop.setValue(0.25, forKey: "scale")
            blur.setValue(60, forKey: "inputRadius")
            blur.setValue(true, forKey: "inputNormalizeEdges")
            backdrop.filters = [saturate, blur]
            layer?.addSublayer(backdrop)
            layer?.addSublayer(tint)
            updateColors()
        } else {
            let effect = NSVisualEffectView(frame: bounds)
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.autoresizingMask = [.width, .height]
            addSubview(effect)
            fallback = effect
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var cornerRadius: CGFloat = 0 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop?.frame = bounds
        tint.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if dark {
            backdrop?.backgroundColor = CGColor(srgbRed: 0.1569, green: 0.1569, blue: 0.1569, alpha: 0.5)
            saturate?.setValue(1.8, forKey: "inputAmount")
            tint.backgroundColor = CGColor(srgbRed: 0.095, green: 0.095, blue: 0.095, alpha: 1)
            tint.compositingFilter = "lightenBlendMode"
        } else {
            // MenuBarExtra uses a 0.48 veil and a 0.96 grey; the Control Center Display menu
            // measures a little darker and more see-through (0.42 and 0.92).
            backdrop?.backgroundColor = CGColor(srgbRed: 0.9646, green: 0.9648, blue: 0.9646, alpha: 0.42)
            saturate?.setValue(1.9, forKey: "inputAmount")
            tint.backgroundColor = CGColor(srgbRed: 0.92, green: 0.92, blue: 0.92, alpha: 1)
            tint.compositingFilter = "darkenBlendMode"
        }
        // Filters are copied when assigned: re-assign so the new amount takes effect.
        if let filters = backdrop?.filters { backdrop?.filters = filters.map { ($0 as AnyObject) === saturate ? saturate! : $0 } }
        CATransaction.commit()
    }

    private static func filter(_ type: String) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as AnyObject?,
              filterClass.responds(to: NSSelectorFromString("filterWithType:")) else { return nil }
        return filterClass.perform(NSSelectorFromString("filterWithType:"), with: type)?.takeUnretainedValue() as? NSObject
    }
}
