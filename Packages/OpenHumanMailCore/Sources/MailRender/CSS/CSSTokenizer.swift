import Foundation

public enum CSSToken: Equatable, Sendable {
    case ident(String)
    case function(String)
    case atKeyword(String)
    case hash(String)
    case string(String)
    case badString
    case url(String)
    case badURL
    case delim(Unicode.Scalar)
    case number(String)
    case percentage(String)
    case dimension(String, unit: String)
    case whitespace
    case cdo
    case cdc
    case colon
    case semicolon
    case comma
    case openSquare
    case closeSquare
    case openParen
    case closeParen
    case openCurly
    case closeCurly
}

public struct CSSTokenizer {
    private var input: [Unicode.Scalar]
    private var pos = 0

    public init(_ text: String) {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(text.unicodeScalars.count)
        var previousWasCR = false
        for s in text.unicodeScalars {
            switch s {
            case "\r":
                scalars.append("\n"); previousWasCR = true; continue
            case "\n":
                if previousWasCR { previousWasCR = false; continue }
                scalars.append("\n")
            case "\u{0C}":
                scalars.append("\n")
            case "\u{00}":
                scalars.append("\u{FFFD}")
            default:
                scalars.append(s)
            }
            previousWasCR = false
        }
        input = scalars
    }

    public static func tokenize(_ text: String) -> [CSSToken] {
        var tokenizer = CSSTokenizer(text)
        var tokens: [CSSToken] = []
        while let token = tokenizer.next() { tokens.append(token) }
        return tokens
    }

    private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        let i = pos + offset
        return i < input.count ? input[i] : nil
    }

    public mutating func next() -> CSSToken? {
        consumeComments()
        guard let c = peek() else { return nil }
        if Self.isWhitespace(c) {
            while let w = peek(), Self.isWhitespace(w) { pos += 1 }
            return .whitespace
        }
        switch c {
        case "\"", "'":
            pos += 1
            return consumeString(ending: c)
        case "#":
            if let n = peek(1), Self.isNameChar(n) || Self.isValidEscape(peek(1), peek(2)) {
                pos += 1
                return .hash(consumeName())
            }
            pos += 1
            return .delim(c)
        case "(": pos += 1; return .openParen
        case ")": pos += 1; return .closeParen
        case "[": pos += 1; return .openSquare
        case "]": pos += 1; return .closeSquare
        case "{": pos += 1; return .openCurly
        case "}": pos += 1; return .closeCurly
        case ",": pos += 1; return .comma
        case ":": pos += 1; return .colon
        case ";": pos += 1; return .semicolon
        case "+":
            if startsNumber(at: pos) { return consumeNumeric() }
            pos += 1
            return .delim(c)
        case "-":
            if startsNumber(at: pos) { return consumeNumeric() }
            if peek(1) == "-", peek(2) == ">" { pos += 3; return .cdc }
            if startsIdent(at: pos) { return consumeIdentLike() }
            pos += 1
            return .delim(c)
        case ".":
            if startsNumber(at: pos) { return consumeNumeric() }
            pos += 1
            return .delim(c)
        case "<":
            if peek(1) == "!", peek(2) == "-", peek(3) == "-" { pos += 4; return .cdo }
            pos += 1
            return .delim(c)
        case "@":
            if startsIdent(at: pos + 1) {
                pos += 1
                return .atKeyword(consumeName())
            }
            pos += 1
            return .delim(c)
        case "\\":
            if Self.isValidEscape(c, peek(1)) { return consumeIdentLike() }
            pos += 1
            return .delim(c)
        default:
            if Self.isDigit(c) { return consumeNumeric() }
            if Self.isNameStart(c) { return consumeIdentLike() }
            pos += 1
            return .delim(c)
        }
    }

    private mutating func consumeComments() {
        while peek() == "/", peek(1) == "*" {
            pos += 2
            while pos < input.count {
                if peek() == "*", peek(1) == "/" { pos += 2; break }
                pos += 1
            }
        }
    }

    private mutating func consumeString(ending: Unicode.Scalar) -> CSSToken {
        var value = String.UnicodeScalarView()
        while let c = peek() {
            if c == ending { pos += 1; return .string(String(value)) }
            if c == "\n" { return .badString }
            if c == "\\" {
                guard let n = peek(1) else { pos += 1; continue }
                if n == "\n" { pos += 2; continue }
                pos += 1
                value.append(consumeEscape())
                continue
            }
            value.append(c)
            pos += 1
        }
        return .string(String(value))
    }

    private mutating func consumeEscape() -> Unicode.Scalar {
        guard let c = peek() else { return "\u{FFFD}" }
        if Self.isHexDigit(c) {
            var hex = ""
            while hex.count < 6, let h = peek(), Self.isHexDigit(h) {
                hex.unicodeScalars.append(h)
                pos += 1
            }
            if let w = peek(), Self.isWhitespace(w) { pos += 1 }
            guard let value = UInt32(hex, radix: 16), value != 0, value <= 0x10FFFF,
                  !(0xD800...0xDFFF).contains(value), let scalar = Unicode.Scalar(value) else { return "\u{FFFD}" }
            return scalar
        }
        pos += 1
        return c
    }

    private mutating func consumeName() -> String {
        var name = String.UnicodeScalarView()
        while let c = peek() {
            if Self.isNameChar(c) {
                name.append(c)
                pos += 1
            } else if Self.isValidEscape(c, peek(1)) {
                pos += 1
                name.append(consumeEscape())
            } else {
                break
            }
        }
        return String(name)
    }

    private mutating func consumeNumeric() -> CSSToken {
        var repr = ""
        if let c = peek(), c == "+" || c == "-" { repr.unicodeScalars.append(c); pos += 1 }
        while let c = peek(), Self.isDigit(c) { repr.unicodeScalars.append(c); pos += 1 }
        if peek() == ".", let d = peek(1), Self.isDigit(d) {
            repr += "."
            pos += 1
            while let c = peek(), Self.isDigit(c) { repr.unicodeScalars.append(c); pos += 1 }
        }
        if let e = peek(), e == "e" || e == "E" {
            if let d = peek(1), Self.isDigit(d) {
                repr.unicodeScalars.append(e); pos += 1
                while let c = peek(), Self.isDigit(c) { repr.unicodeScalars.append(c); pos += 1 }
            } else if let s = peek(1), s == "+" || s == "-", let d = peek(2), Self.isDigit(d) {
                repr.unicodeScalars.append(e); repr.unicodeScalars.append(s); pos += 2
                while let c = peek(), Self.isDigit(c) { repr.unicodeScalars.append(c); pos += 1 }
            }
        }
        if startsIdent(at: pos) { return .dimension(repr, unit: consumeName()) }
        if peek() == "%" { pos += 1; return .percentage(repr) }
        return .number(repr)
    }

    private mutating func consumeIdentLike() -> CSSToken {
        let name = consumeName()
        if name.lowercased() == "url", peek() == "(" {
            pos += 1
            while let a = peek(), Self.isWhitespace(a), let b = peek(1), Self.isWhitespace(b) { pos += 1 }
            let first = peek()
            let afterSpace = (first.map(Self.isWhitespace) ?? false) ? peek(1) : first
            if afterSpace == "\"" || afterSpace == "'" { return .function(name) }
            return consumeURL()
        }
        if peek() == "(" {
            pos += 1
            return .function(name)
        }
        return .ident(name)
    }

    private mutating func consumeURL() -> CSSToken {
        var value = String.UnicodeScalarView()
        while let w = peek(), Self.isWhitespace(w) { pos += 1 }
        while true {
            guard let c = peek() else { return .url(String(value)) }
            if c == ")" { pos += 1; return .url(String(value)) }
            if Self.isWhitespace(c) {
                while let w = peek(), Self.isWhitespace(w) { pos += 1 }
                if peek() == nil { return .url(String(value)) }
                if peek() == ")" { pos += 1; return .url(String(value)) }
                consumeBadURLRemnants()
                return .badURL
            }
            if c == "\"" || c == "'" || c == "(" || Self.isNonPrintable(c) {
                consumeBadURLRemnants()
                return .badURL
            }
            if c == "\\" {
                if Self.isValidEscape(c, peek(1)) {
                    pos += 1
                    value.append(consumeEscape())
                    continue
                }
                consumeBadURLRemnants()
                return .badURL
            }
            value.append(c)
            pos += 1
        }
    }

    private mutating func consumeBadURLRemnants() {
        while let c = peek() {
            if c == ")" { pos += 1; return }
            if Self.isValidEscape(c, peek(1)) {
                pos += 1
                _ = consumeEscape()
                continue
            }
            pos += 1
        }
    }

    private func startsIdent(at i: Int) -> Bool {
        guard i < input.count else { return false }
        let a = input[i]
        let b: Unicode.Scalar? = i + 1 < input.count ? input[i + 1] : nil
        let c: Unicode.Scalar? = i + 2 < input.count ? input[i + 2] : nil
        if a == "-" {
            guard let b else { return false }
            return Self.isNameStart(b) || b == "-" || Self.isValidEscape(b, c)
        }
        if Self.isNameStart(a) { return true }
        if a == "\\" { return Self.isValidEscape(a, b) }
        return false
    }

    private func startsNumber(at i: Int) -> Bool {
        guard i < input.count else { return false }
        let a = input[i]
        let b: Unicode.Scalar? = i + 1 < input.count ? input[i + 1] : nil
        let c: Unicode.Scalar? = i + 2 < input.count ? input[i + 2] : nil
        if a == "+" || a == "-" {
            if let b, Self.isDigit(b) { return true }
            if b == ".", let c, Self.isDigit(c) { return true }
            return false
        }
        if a == "." { return b.map(Self.isDigit) ?? false }
        return Self.isDigit(a)
    }

    static func isWhitespace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" }
    static func isDigit(_ c: Unicode.Scalar) -> Bool { ("0"..."9").contains(c) }
    static func isHexDigit(_ c: Unicode.Scalar) -> Bool {
        isDigit(c) || ("a"..."f").contains(c) || ("A"..."F").contains(c)
    }
    static func isLetter(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) || ("A"..."Z").contains(c) }
    static func isNameStart(_ c: Unicode.Scalar) -> Bool { isLetter(c) || c == "_" || c.value >= 0x80 }
    static func isNameChar(_ c: Unicode.Scalar) -> Bool { isNameStart(c) || isDigit(c) || c == "-" }
    static func isNonPrintable(_ c: Unicode.Scalar) -> Bool {
        c.value <= 0x08 || c.value == 0x0B || (0x0E...0x1F).contains(c.value) || c.value == 0x7F
    }
    static func isValidEscape(_ a: Unicode.Scalar?, _ b: Unicode.Scalar?) -> Bool {
        a == "\\" && b != nil && b != "\n"
    }
}

// Why: CDO/CDC and stray `<` and `\` delims are dropped so output can never close a <style> element
public enum CSSSerializer {
    public static func serialize(_ tokens: [CSSToken]) -> String {
        var out = ""
        var previous: CSSToken?
        for token in tokens {
            guard let text = text(for: token) else { continue }
            if let previous, needsSeparator(previous, token) { out += "/**/" }
            out += text
            previous = token
        }
        return out
    }

    static func text(for token: CSSToken) -> String? {
        switch token {
        case .ident(let s): return ident(s)
        case .function(let s): return ident(s) + "("
        case .atKeyword(let s): return "@" + ident(s)
        case .hash(let s): return "#" + name(s)
        case .string(let s): return string(s)
        case .url(let s): return "url(" + string(s) + ")"
        case .badString, .badURL, .cdo, .cdc: return nil
        case .delim(let c): return c == "<" || c == "\\" ? nil : String(Character(c))
        case .number(let s): return s
        case .percentage(let s): return s + "%"
        case .dimension(let s, let unit): return s + dimensionUnit(unit)
        case .whitespace: return " "
        case .colon: return ":"
        case .semicolon: return ";"
        case .comma: return ","
        case .openSquare: return "["
        case .closeSquare: return "]"
        case .openParen: return "("
        case .closeParen: return ")"
        case .openCurly: return "{"
        case .closeCurly: return "}"
        }
    }

    private enum Kind { case ident, function, url, atKeyword, hash, dimension, number, percentage, other }

    private static func kind(_ t: CSSToken) -> Kind {
        switch t {
        case .ident: return .ident
        case .function: return .function
        case .url, .badURL: return .url
        case .atKeyword: return .atKeyword
        case .hash: return .hash
        case .dimension: return .dimension
        case .number: return .number
        case .percentage: return .percentage
        default: return .other
        }
    }

    static func needsSeparator(_ a: CSSToken, _ b: CSSToken) -> Bool {
        let kb = kind(b)
        let bIsMinus = b == .delim("-")
        let identLike = kb == .ident || kb == .function || kb == .url
        let numericB = kb == .number || kb == .percentage || kb == .dimension
        switch a {
        case .ident:
            return identLike || numericB || bIsMinus || b == .cdc || b == .openParen
        case .atKeyword, .hash, .dimension:
            return identLike || numericB || bIsMinus || b == .cdc
        case .delim("#"), .delim("-"):
            return identLike || numericB || bIsMinus
        case .number:
            return identLike || numericB || b == .delim("%")
        case .delim("@"):
            return identLike || bIsMinus
        case .delim("."), .delim("+"):
            return numericB
        case .delim("/"):
            return b == .delim("*")
        default:
            return false
        }
    }

    static func ident(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        if scalars == ["-"] { return "\\-" }
        var out = ""
        for (i, c) in scalars.enumerated() {
            if c.value == 0 { out += "\u{FFFD}"; continue }
            if CSSTokenizer.isDigit(c), i == 0 || (i == 1 && scalars[0] == "-") {
                out += hexEscape(c)
            } else if CSSTokenizer.isNameChar(c) {
                out.unicodeScalars.append(c)
            } else {
                out += hexEscape(c)
            }
        }
        return out
    }

    static func name(_ s: String) -> String {
        var out = ""
        for c in s.unicodeScalars {
            if c.value == 0 { out += "\u{FFFD}" } else if CSSTokenizer.isNameChar(c) { out.unicodeScalars.append(c) } else { out += hexEscape(c) }
        }
        return out
    }

    // Why: `<` is hex-escaped so the text cannot form `</style`
    static func string(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "<": out += hexEscape(c)
            default:
                if c.value == 0 { out += "\u{FFFD}" } else if c.value < 0x20 || c.value == 0x7F { out += hexEscape(c) } else { out.unicodeScalars.append(c) }
            }
        }
        return out + "\""
    }

    // Why: a unit like `e3` would read as an exponent (`1e3`), so its first letter is escaped
    static func dimensionUnit(_ unit: String) -> String {
        let serialized = ident(unit)
        let scalars = Array(serialized.unicodeScalars)
        if let first = scalars.first, first == "e" || first == "E", scalars.count > 1 {
            let second = scalars[1]
            let signDigit = (second == "+" || second == "-") && scalars.count > 2 && CSSTokenizer.isDigit(scalars[2])
            if CSSTokenizer.isDigit(second) || signDigit || second == "\\" {
                return hexEscape(first) + String(String.UnicodeScalarView(scalars.dropFirst()))
            }
        }
        if serialized == "e" || serialized == "E" { return hexEscape(scalars[0]) }
        return serialized
    }

    static func hexEscape(_ c: Unicode.Scalar) -> String { "\\" + String(c.value, radix: 16) + " " }
}
