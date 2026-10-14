import Foundation
import MailTheme

public struct OKLCH: Sendable, Equatable {
    public var l: Double
    public var c: Double
    public var h: Double
    public var alpha: Double

    public init(l: Double, c: Double, h: Double, alpha: Double = 1) {
        self.l = l
        self.c = c
        self.h = h
        self.alpha = alpha
    }

    public init(_ color: ThemeColor) {
        let r = OKLCH.linear(color.red), g = OKLCH.linear(color.green), b = OKLCH.linear(color.blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let chroma = (A * A + B * B).squareRoot()
        var hue = atan2(B, A) * 180 / .pi
        if hue < 0 { hue += 360 }
        self.init(l: L, c: chroma, h: chroma < 1e-6 ? 0 : hue, alpha: color.alpha)
    }

    public var srgb: ThemeColor {
        var chroma = max(0, c)
        var rgb = OKLCH.toLinearRGB(l: l, c: chroma, h: h)
        if !OKLCH.inGamut(rgb) {
            var low = 0.0, high = chroma
            for _ in 0..<24 {
                chroma = (low + high) / 2
                if OKLCH.inGamut(OKLCH.toLinearRGB(l: l, c: chroma, h: h)) { low = chroma } else { high = chroma }
            }
            rgb = OKLCH.toLinearRGB(l: l, c: low, h: h)
        }
        return ThemeColor(red: OKLCH.encode(rgb.0), green: OKLCH.encode(rgb.1), blue: OKLCH.encode(rgb.2), alpha: alpha)
    }

    static func linear(_ c: Double) -> Double {
        let c = min(max(c, 0), 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func encode(_ c: Double) -> Double {
        let c = min(max(c, 0), 1)
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    static func toLinearRGB(l L: Double, c: Double, h: Double) -> (Double, Double, Double) {
        let A = c * cos(h * .pi / 180), B = c * sin(h * .pi / 180)
        let l = pow(L + 0.3963377774 * A + 0.2158037573 * B, 3)
        let m = pow(L - 0.1055613458 * A - 0.0638541728 * B, 3)
        let s = pow(L - 0.0894841775 * A - 1.2914855480 * B, 3)
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    static func inGamut(_ rgb: (Double, Double, Double)) -> Bool {
        let e = 1e-6
        return rgb.0 >= -e && rgb.0 <= 1 + e && rgb.1 >= -e && rgb.1 <= 1 + e && rgb.2 >= -e && rgb.2 <= 1 + e
    }
}

extension ThemeColor {
    var cieLightness: Double {
        let y = relativeLuminance
        return y > 216.0 / 24389.0 ? 116 * cbrt(y) - 16 : 24389.0 / 27.0 * y
    }

    var overWhite: ThemeColor { composited(over: ThemeColor(red: 1, green: 1, blue: 1)) }
}
