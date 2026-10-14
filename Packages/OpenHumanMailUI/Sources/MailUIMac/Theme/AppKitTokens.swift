import AppKit
import MailTheme

extension ThemeColor {
    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

extension TypeStyle {
    public var nsWeight: NSFont.Weight {
        switch weight {
        case ..<150: return .ultraLight
        case ..<250: return .thin
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        case ..<850: return .heavy
        default: return .black
        }
    }

    public var font: NSFont {
        let system = monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: nsWeight)
            : NSFont.systemFont(ofSize: size, weight: nsWeight)
        let design: NSFontDescriptor.SystemDesign? = switch family {
        case .system, .named: nil
        case .systemSerif: .serif
        case .systemRounded: .rounded
        case .systemMono: .monospaced
        }
        if case .named(let name) = family {
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: name, .traits: [NSFontDescriptor.TraitKey.weight: nsWeight],
            ])
            if let named = NSFont(descriptor: descriptor, size: size), named.familyName == name { return named }
            return system
        }
        if let design, let descriptor = system.fontDescriptor.withDesign(design),
           let designed = NSFont(descriptor: descriptor, size: size) {
            return designed
        }
        return system
    }

    public func paragraphStyle(lineBreak: NSLineBreakMode = .byWordWrapping) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        p.lineBreakMode = lineBreak
        return p
    }

    public var baselineOffset: CGFloat {
        let f = font
        return (lineHeight - (f.ascender - f.descender)) / 2
    }

    public var kern: CGFloat { effectiveTracking }
}

extension ThemeShadow {
    public func apply(to layer: CALayer) {
        guard let top = layers.last else {
            layer.shadowOpacity = 0
            return
        }
        layer.shadowColor = NSColor(srgbRed: top.color.red, green: top.color.green, blue: top.color.blue, alpha: 1).cgColor
        layer.shadowOpacity = Float(top.color.alpha)
        layer.shadowRadius = top.blur / 2
        layer.shadowOffset = CGSize(width: top.x, height: -top.y)
    }
}

extension MotionSpec {
    public var timingFunction: CAMediaTimingFunction {
        switch easing {
        case .none, .linear: CAMediaTimingFunction(name: .linear)
        case let .cubicBezier(a, b, c, d): CAMediaTimingFunction(controlPoints: Float(a), Float(b), Float(c), Float(d))
        }
    }
}

@MainActor
public enum MotionAnimator {
    private static let fadeKey = "oh.motion.fade"
    private static let riseKey = "oh.motion.rise"

    public static func setVisible(_ view: NSView, _ visible: Bool, enter: MotionSpec, offset: CGFloat = 0) {
        guard visible else {
            view.layer?.removeAnimation(forKey: fadeKey)
            view.layer?.removeAnimation(forKey: riseKey)
            view.isHidden = true
            return
        }
        guard view.isHidden else { return }
        view.isHidden = false
        guard enter.animates, view.window != nil else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = enter.seconds
        fade.timingFunction = enter.timingFunction
        layer.add(fade, forKey: fadeKey)
        guard enter.allowsTransform, offset != 0 else { return }
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = layer.isGeometryFlipped ? offset : -offset
        rise.toValue = 0
        rise.duration = enter.seconds
        rise.timingFunction = enter.timingFunction
        layer.add(rise, forKey: riseKey)
    }
}
