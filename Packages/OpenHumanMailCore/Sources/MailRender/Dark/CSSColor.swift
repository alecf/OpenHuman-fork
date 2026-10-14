import Foundation
import MailTheme

enum CSSColorValue: Equatable {
    case color(ThemeColor)
    case transparent
    case inherited
    case unknown
}

enum CSSColor {
    static func value(of component: CSSComponent) -> CSSColorValue? {
        switch component {
        case .token(.hash(let hex)):
            return parseHex(hex).map(CSSColorValue.color) ?? .unknown
        case .token(.ident(let name)):
            let lower = name.lowercased()
            if lower == "transparent" { return .transparent }
            if ["currentcolor", "inherit", "initial", "unset", "revert", "revert-layer"].contains(lower) { return .inherited }
            if let rgb = namedColors[lower] { return .color(ThemeColor(r8: rgb.0, g8: rgb.1, b8: rgb.2)) }
            if let rgb = lightSystemColors[lower] { return .color(ThemeColor(r8: rgb.0, g8: rgb.1, b8: rgb.2)) }
            if systemColors.contains(lower) { return .unknown }
            return nil
        case .function(let name, let args):
            switch name.lowercased() {
            case "rgb", "rgba": return parseRGB(args).map(CSSColorValue.color) ?? .unknown
            case "hsl", "hsla": return parseHSL(args).map(CSSColorValue.color) ?? .unknown
            case "lab", "lch", "oklab", "oklch", "color", "hwb", "color-mix", "light-dark", "var", "env", "attr":
                return .unknown
            default:
                return nil
            }
        default:
            return nil
        }
    }

    static func parseHex(_ hex: String) -> ThemeColor? {
        let digits = Array(hex.unicodeScalars)
        guard [3, 4, 6, 8].contains(digits.count) else { return nil }
        var values: [UInt8] = []
        for d in digits {
            guard let v = hexValue(d) else { return nil }
            values.append(v)
        }
        func pair(_ i: Int) -> UInt8 { values[i] << 4 | values[i + 1] }
        switch digits.count {
        case 3, 4:
            let a = digits.count == 4 ? Double(values[3] * 17) / 255 : 1
            return ThemeColor(r8: values[0] * 17, g8: values[1] * 17, b8: values[2] * 17, alpha: a)
        default:
            let a = digits.count == 8 ? Double(pair(6)) / 255 : 1
            return ThemeColor(r8: pair(0), g8: pair(2), b8: pair(4), alpha: a)
        }
    }

    private static func hexValue(_ c: Unicode.Scalar) -> UInt8? {
        switch c {
        case "0"..."9": return UInt8(c.value - 48)
        case "a"..."f": return UInt8(c.value - 87)
        case "A"..."F": return UInt8(c.value - 55)
        default: return nil
        }
    }

    private static func numericArguments(_ args: [CSSComponent]) -> [(value: Double, isPercent: Bool, unit: String?)]? {
        var out: [(Double, Bool, String?)] = []
        for a in args {
            switch a {
            case .token(.whitespace), .token(.comma), .token(.delim("/")): continue
            case .token(.number(let n)): guard let v = Double(n) else { return nil }; out.append((v, false, nil))
            case .token(.percentage(let n)): guard let v = Double(n) else { return nil }; out.append((v, true, nil))
            case .token(.dimension(let n, let unit)): guard let v = Double(n) else { return nil }; out.append((v, false, unit.lowercased()))
            case .token(.ident(let i)) where i.lowercased() == "none": out.append((0, false, nil))
            default: return nil
            }
        }
        return out
    }

    static func parseRGB(_ args: [CSSComponent]) -> ThemeColor? {
        guard let n = numericArguments(args), n.count == 3 || n.count == 4 else { return nil }
        func channel(_ x: (value: Double, isPercent: Bool, unit: String?)) -> Double? {
            guard x.unit == nil else { return nil }
            return min(max(x.isPercent ? x.value / 100 : x.value / 255, 0), 1)
        }
        guard let r = channel(n[0]), let g = channel(n[1]), let b = channel(n[2]) else { return nil }
        let a = n.count == 4 ? alpha(n[3]) : 1
        guard let a else { return nil }
        return ThemeColor(red: r, green: g, blue: b, alpha: a)
    }

    static func parseHSL(_ args: [CSSComponent]) -> ThemeColor? {
        guard let n = numericArguments(args), n.count == 3 || n.count == 4 else { return nil }
        var hue = n[0].value
        switch n[0].unit {
        case nil, "deg": break
        case "rad": hue = hue * 180 / .pi
        case "grad": hue = hue * 0.9
        case "turn": hue = hue * 360
        default: return nil
        }
        guard !n[0].isPercent else { return nil }
        let s = min(max(n[1].value / 100, 0), 1)
        let l = min(max(n[2].value / 100, 0), 1)
        let a = n.count == 4 ? alpha(n[3]) : 1
        guard let a else { return nil }
        let (r, g, b) = hslToRGB(hue: hue, saturation: s, lightness: l)
        return ThemeColor(red: r, green: g, blue: b, alpha: a)
    }

    private static func alpha(_ x: (value: Double, isPercent: Bool, unit: String?)) -> Double? {
        guard x.unit == nil else { return nil }
        return min(max(x.isPercent ? x.value / 100 : x.value, 0), 1)
    }

    static func hslToRGB(hue: Double, saturation s: Double, lightness l: Double) -> (Double, Double, Double) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        func f(_ n: Double) -> Double {
            let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
            let a = s * min(l, 1 - l)
            return l - a * max(-1, min(k - 3, 9 - k, 1))
        }
        return (f(0), f(8), f(4))
    }

    static func parseLegacyAttribute(_ raw: String) -> CSSColorValue {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .unknown }
        let lower = input.lowercased()
        if lower == "transparent" { return .transparent }
        if let rgb = namedColors[lower] { return .color(ThemeColor(r8: rgb.0, g8: rgb.1, b8: rgb.2)) }
        let scalars = Array(input.unicodeScalars)
        if scalars.count == 4, scalars[0] == "#", let c = parseHex(String(String.UnicodeScalarView(scalars[1...]))) {
            return .color(c)
        }
        var chars: [Unicode.Scalar] = []
        for s in input.unicodeScalars {
            if s.value > 0xFFFF { chars += ["0", "0"] } else { chars.append(s) }
        }
        if chars.count > 128 { chars = Array(chars.prefix(128)) }
        if chars.first == "#" { chars.removeFirst() }
        chars = chars.map { hexValue($0) == nil ? "0" : $0 }
        while chars.isEmpty || chars.count % 3 != 0 { chars.append("0") }
        let length = chars.count / 3
        var parts = [Array(chars[0..<length]), Array(chars[length..<2 * length]), Array(chars[2 * length..<3 * length])]
        if length > 8 { parts = parts.map { Array($0.suffix(8)) } }
        while parts[0].count > 2, parts.allSatisfy({ $0.first == "0" }) { parts = parts.map { Array($0.dropFirst()) } }
        if parts[0].count > 2 { parts = parts.map { Array($0.prefix(2)) } }
        func value(_ p: [Unicode.Scalar]) -> UInt8 { p.reduce(0) { $0 << 4 | (hexValue($1) ?? 0) } }
        return .color(ThemeColor(r8: value(parts[0]), g8: value(parts[1]), b8: value(parts[2])))
    }

    static let systemColors: Set<String> = [
        "canvas", "canvastext", "linktext", "visitedtext", "activetext", "buttonface", "buttontext", "buttonborder",
        "field", "fieldtext", "highlight", "highlighttext", "selecteditem", "selecteditemtext", "mark", "marktext",
        "graytext", "accentcolor", "accentcolortext", "activeborder", "activecaption", "appworkspace", "background",
        "buttonhighlight", "buttonshadow", "captiontext", "inactiveborder", "inactivecaption", "inactivecaptiontext",
        "infobackground", "infotext", "menu", "menutext", "scrollbar", "threeddarkshadow", "threedface",
        "threedhighlight", "threedlightshadow", "threedshadow", "window", "windowframe", "windowtext",
        "-apple-system-label", "-webkit-link", "-webkit-text", "-webkit-focus-ring-color",
    ]

    static let lightSystemColors: [String: (UInt8, UInt8, UInt8)] = [
        "windowtext": (0, 0, 0), "canvastext": (0, 0, 0), "fieldtext": (0, 0, 0), "buttontext": (0, 0, 0),
        "infotext": (0, 0, 0), "menutext": (0, 0, 0), "captiontext": (0, 0, 0), "-webkit-text": (0, 0, 0),
        "window": (255, 255, 255), "canvas": (255, 255, 255), "field": (255, 255, 255),
        "graytext": (128, 128, 128),
    ]

    static let namedColors: [String: (UInt8, UInt8, UInt8)] = [
        "aliceblue": (240, 248, 255), "antiquewhite": (250, 235, 215), "aqua": (0, 255, 255),
        "aquamarine": (127, 255, 212), "azure": (240, 255, 255), "beige": (245, 245, 220), "bisque": (255, 228, 196),
        "black": (0, 0, 0), "blanchedalmond": (255, 235, 205), "blue": (0, 0, 255), "blueviolet": (138, 43, 226),
        "brown": (165, 42, 42), "burlywood": (222, 184, 135), "cadetblue": (95, 158, 160),
        "chartreuse": (127, 255, 0), "chocolate": (210, 105, 30), "coral": (255, 127, 80),
        "cornflowerblue": (100, 149, 237), "cornsilk": (255, 248, 220), "crimson": (220, 20, 60),
        "cyan": (0, 255, 255), "darkblue": (0, 0, 139), "darkcyan": (0, 139, 139), "darkgoldenrod": (184, 134, 11),
        "darkgray": (169, 169, 169), "darkgreen": (0, 100, 0), "darkgrey": (169, 169, 169),
        "darkkhaki": (189, 183, 107), "darkmagenta": (139, 0, 139), "darkolivegreen": (85, 107, 47),
        "darkorange": (255, 140, 0), "darkorchid": (153, 50, 204), "darkred": (139, 0, 0),
        "darksalmon": (233, 150, 122), "darkseagreen": (143, 188, 143), "darkslateblue": (72, 61, 139),
        "darkslategray": (47, 79, 79), "darkslategrey": (47, 79, 79), "darkturquoise": (0, 206, 209),
        "darkviolet": (148, 0, 211), "deeppink": (255, 20, 147), "deepskyblue": (0, 191, 255),
        "dimgray": (105, 105, 105), "dimgrey": (105, 105, 105), "dodgerblue": (30, 144, 255),
        "firebrick": (178, 34, 34), "floralwhite": (255, 250, 240), "forestgreen": (34, 139, 34),
        "fuchsia": (255, 0, 255), "gainsboro": (220, 220, 220), "ghostwhite": (248, 248, 255), "gold": (255, 215, 0),
        "goldenrod": (218, 165, 32), "gray": (128, 128, 128), "green": (0, 128, 0), "greenyellow": (173, 255, 47),
        "grey": (128, 128, 128), "honeydew": (240, 255, 240), "hotpink": (255, 105, 180),
        "indianred": (205, 92, 92), "indigo": (75, 0, 130), "ivory": (255, 255, 240), "khaki": (240, 230, 140),
        "lavender": (230, 230, 250), "lavenderblush": (255, 240, 245), "lawngreen": (124, 252, 0),
        "lemonchiffon": (255, 250, 205), "lightblue": (173, 216, 230), "lightcoral": (240, 128, 128),
        "lightcyan": (224, 255, 255), "lightgoldenrodyellow": (250, 250, 210), "lightgray": (211, 211, 211),
        "lightgreen": (144, 238, 144), "lightgrey": (211, 211, 211), "lightpink": (255, 182, 193),
        "lightsalmon": (255, 160, 122), "lightseagreen": (32, 178, 170), "lightskyblue": (135, 206, 250),
        "lightslategray": (119, 136, 153), "lightslategrey": (119, 136, 153), "lightsteelblue": (176, 196, 222),
        "lightyellow": (255, 255, 224), "lime": (0, 255, 0), "limegreen": (50, 205, 50), "linen": (250, 240, 230),
        "magenta": (255, 0, 255), "maroon": (128, 0, 0), "mediumaquamarine": (102, 205, 170),
        "mediumblue": (0, 0, 205), "mediumorchid": (186, 85, 211), "mediumpurple": (147, 112, 219),
        "mediumseagreen": (60, 179, 113), "mediumslateblue": (123, 104, 238), "mediumspringgreen": (0, 250, 154),
        "mediumturquoise": (72, 209, 204), "mediumvioletred": (199, 21, 133), "midnightblue": (25, 25, 112),
        "mintcream": (245, 255, 250), "mistyrose": (255, 228, 225), "moccasin": (255, 228, 181),
        "navajowhite": (255, 222, 173), "navy": (0, 0, 128), "oldlace": (253, 245, 230), "olive": (128, 128, 0),
        "olivedrab": (107, 142, 35), "orange": (255, 165, 0), "orangered": (255, 69, 0), "orchid": (218, 112, 214),
        "palegoldenrod": (238, 232, 170), "palegreen": (152, 251, 152), "paleturquoise": (175, 238, 238),
        "palevioletred": (219, 112, 147), "papayawhip": (255, 239, 213), "peachpuff": (255, 218, 185),
        "peru": (205, 133, 63), "pink": (255, 192, 203), "plum": (221, 160, 221), "powderblue": (176, 224, 230),
        "purple": (128, 0, 128), "rebeccapurple": (102, 51, 153), "red": (255, 0, 0), "rosybrown": (188, 143, 143),
        "royalblue": (65, 105, 225), "saddlebrown": (139, 69, 19), "salmon": (250, 128, 114),
        "sandybrown": (244, 164, 96), "seagreen": (46, 139, 87), "seashell": (255, 245, 238),
        "sienna": (160, 82, 45), "silver": (192, 192, 192), "skyblue": (135, 206, 235), "slateblue": (106, 90, 205),
        "slategray": (112, 128, 144), "slategrey": (112, 128, 144), "snow": (255, 250, 250),
        "springgreen": (0, 255, 127), "steelblue": (70, 130, 180), "tan": (210, 180, 140), "teal": (0, 128, 128),
        "thistle": (216, 191, 216), "tomato": (255, 99, 71), "turquoise": (64, 224, 208), "violet": (238, 130, 238),
        "wheat": (245, 222, 179), "white": (255, 255, 255), "whitesmoke": (245, 245, 245), "yellow": (255, 255, 0),
        "yellowgreen": (154, 205, 50),
    ]
}
