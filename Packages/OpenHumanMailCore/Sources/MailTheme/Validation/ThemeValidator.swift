import Foundation

public struct ValidationResult: Sendable {
    public let file: ThemeFile?
    public let issues: [ThemeIssue]

    public var isRefused: Bool { file == nil }
}

public enum ThemeValidator {
    public static let maxFileSize = 64 * 1024
    public static let maxDepth = 16
    public static let maxKeys = 2_000
    public static let maxStringLength = 200
    public static let maxNameLength = 40
    public static let maxShadowLayers = 3
    public static let supportedFormatVersion = 1

    public static func validate(data: Data, registry: TokenRegistry = .v1, allowReservedIDs: Bool = false) -> ValidationResult {
        var run = Run(registry: registry, allowReservedIDs: allowReservedIDs)
        let file = run.validate(data)
        if run.issues.isRefused { return ValidationResult(file: nil, issues: run.issues) }
        return ValidationResult(file: file, issues: run.issues)
    }
}

private struct Run {
    let registry: TokenRegistry
    let allowReservedIDs: Bool
    var issues: [ThemeIssue] = []

    init(registry: TokenRegistry, allowReservedIDs: Bool) {
        self.registry = registry
        self.allowReservedIDs = allowReservedIDs
    }

    mutating func warn(_ code: ThemeIssue.Code, _ path: [String], _ message: String) {
        issues.append(.warning(code, display(path), message))
    }

    mutating func refuse(_ code: ThemeIssue.Code, _ path: [String], _ message: String) {
        issues.append(.refused(code, display(path), message))
    }

    func display(_ path: [String]) -> String { path.joined(separator: ".") }

    mutating func validate(_ data: Data) -> ThemeFile? {
        guard data.count <= ThemeValidator.maxFileSize else {
            refuse(.tooLarge, [], "file is \(data.count) bytes; the limit is \(ThemeValidator.maxFileSize)")
            return nil
        }
        guard String(data: data, encoding: .utf8) != nil else {
            refuse(.invalidJSON, [], "not UTF-8 text")
            return nil
        }
        let scan = Run.scan(data)
        guard scan.depth <= ThemeValidator.maxDepth else {
            refuse(.tooDeep, [], "nested deeper than \(ThemeValidator.maxDepth) levels")
            return nil
        }
        guard !scan.trailingComma else {
            refuse(.invalidJSON, [], "not valid JSON (comments and trailing commas are not allowed)")
            return nil
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            refuse(.invalidJSON, [], "not valid JSON (comments and trailing commas are not allowed)")
            return nil
        }
        guard let root = object as? [String: Any] else {
            refuse(.notAnObject, [], "the top level must be a JSON object")
            return nil
        }
        var keyCount = 0
        guard checkStructure(root, depth: 1, keyCount: &keyCount, path: []) else { return nil }

        guard let formatString = root["format"] as? String else {
            refuse(.missingField, ["format"], "missing \"format\" (openhuman-theme or openhuman-accent)")
            return nil
        }
        guard let kind = ThemeFile.Kind(rawValue: formatString) else {
            refuse(.unknownFormat, ["format"], "unknown format; expected openhuman-theme or openhuman-accent")
            return nil
        }
        guard let version = integer(root["formatVersion"]) else {
            refuse(.missingField, ["formatVersion"], "missing or non-integer \"formatVersion\"")
            return nil
        }
        guard version <= ThemeValidator.supportedFormatVersion else {
            refuse(.unsupportedVersion, ["formatVersion"],
                   "made for a newer version of Mail (format \(version)); this version reads format 1")
            return nil
        }
        guard version == ThemeValidator.supportedFormatVersion else {
            refuse(.unsupportedVersion, ["formatVersion"], "unknown format version \(version)")
            return nil
        }
        guard let id = root["id"] as? String, ThemeFile.isValidID(id) else {
            refuse(.invalidID, ["id"], "id must match name.name (lowercase ASCII letters, digits and hyphens, 2-4 parts)")
            return nil
        }
        if ThemeFile.isReserved(id) && !allowReservedIDs {
            refuse(.reservedID, ["id"], "ids starting with openhuman. are reserved for built-in themes")
            return nil
        }
        var file = ThemeFile(kind: kind, formatVersion: version, id: id, name: id)
        file.name = plainText(root["name"], path: ["name"], limit: ThemeValidator.maxNameLength, required: true) ?? id
        file.author = plainText(root["author"], path: ["author"], limit: 64, required: false)

        switch kind {
        case .theme: validateTheme(root, into: &file)
        case .accent: validateAccent(root, into: &file)
        }
        return issues.isRefused ? nil : file
    }

    static func scan(_ data: Data) -> (depth: Int, trailingComma: Bool) {
        var depth = 0
        var deepest = 0
        var inString = false
        var escaped = false
        var lastSignificant: UInt8 = 0
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"):
                continue
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                deepest = max(deepest, depth)
                if deepest > ThemeValidator.maxDepth { return (deepest, false) }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if lastSignificant == UInt8(ascii: ",") { return (deepest, true) }
                depth -= 1
            default:
                break
            }
            lastSignificant = byte
        }
        return (deepest, false)
    }

    mutating func checkStructure(_ value: Any, depth: Int, keyCount: inout Int, path: [String]) -> Bool {
        guard depth <= ThemeValidator.maxDepth || !(value is [String: Any] || value is [Any]) else {
            refuse(.tooDeep, path, "nested deeper than \(ThemeValidator.maxDepth) levels")
            return false
        }
        if let dict = value as? [String: Any] {
            keyCount += dict.count
            guard keyCount <= ThemeValidator.maxKeys else {
                refuse(.tooManyKeys, [], "more than \(ThemeValidator.maxKeys) keys")
                return false
            }
            for key in dict.keys.sorted() {
                guard key.count <= ThemeValidator.maxStringLength else {
                    refuse(.stringTooLong, path, "a key is longer than \(ThemeValidator.maxStringLength) characters")
                    return false
                }
                guard let child = dict[key], checkStructure(child, depth: depth + 1, keyCount: &keyCount, path: path + [key]) else { return false }
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                guard checkStructure(child, depth: depth + 1, keyCount: &keyCount, path: path + ["[\(index)]"]) else { return false }
            }
        } else if let string = value as? String {
            guard string.count <= ThemeValidator.maxStringLength else {
                refuse(.stringTooLong, path, "string longer than \(ThemeValidator.maxStringLength) characters")
                return false
            }
        }
        return true
    }

    static let themeTopLevel: Set<String> = ["format", "formatVersion", "id", "name", "author", "appearance", "extends",
                                             "defaultAccent", "primitives"]
    static let accentTopLevel: Set<String> = ["format", "formatVersion", "id", "name", "author", "primitives", "light", "dark"]

    mutating func validateTheme(_ root: [String: Any], into file: inout ThemeFile) {
        if let raw = root["appearance"] {
            if let s = raw as? String, let appearance = ThemeFile.Appearance(rawValue: s) {
                file.appearance = appearance
            } else {
                checkInjection(raw, ["appearance"])
                warn(.invalidAppearance, ["appearance"], "appearance must be light, dark or any; using any")
            }
        }
        if let raw = root["extends"], !(raw is NSNull) {
            if let parent = raw as? String, ThemeFile.isValidID(parent) {
                if parent == file.id {
                    refuse(.extendsCycle, ["extends"], "a theme cannot extend itself")
                } else {
                    file.extends = parent
                }
            } else {
                checkInjection(raw, ["extends"])
                warn(.invalidValue, ["extends"], "extends must be a theme id or null; ignored")
            }
        }
        if let raw = root["defaultAccent"], !(raw is NSNull) {
            if let accent = raw as? String, ThemeFile.isValidAccentShortID(accent) {
                file.defaultAccent = accent
            } else {
                checkInjection(raw, ["defaultAccent"])
                warn(.invalidAccentID, ["defaultAccent"], "defaultAccent must be a short accent id such as blue; ignored")
            }
        }
        file.primitives = primitives(root["primitives"])
        for key in root.keys.sorted() where !Run.themeTopLevel.contains(key) {
            guard let value = root[key] else { continue }
            if registry.isSection([key]) && key != "accent" {
                guard let dict = value as? [String: Any] else {
                    warn(.wrongType, [key], "expected an object; section ignored")
                    continue
                }
                walk(dict, path: [key], into: &file)
            } else {
                warn(.unknownKey, [key], "unknown key ignored")
            }
        }
    }

    mutating func walk(_ node: [String: Any], path: [String], into file: inout ThemeFile) {
        for key in node.keys.sorted() {
            guard let value = node[key] else { continue }
            let p = path + [key]
            if let entry = registry.entry(at: p), entry.layer != .accent {
                if entry.type == .typography {
                    if let spec = typography(value, p) { file.typography[entry.key] = spec }
                } else if let source = tokenSource(value, entry: entry, path: p) {
                    file.tokens[entry.key] = source
                }
            } else if registry.isSection(p) {
                guard let dict = value as? [String: Any] else {
                    warn(.wrongType, p, "expected an object; ignored")
                    continue
                }
                walk(dict, path: p, into: &file)
            } else {
                warn(.unknownKey, p, "unknown key ignored")
            }
        }
    }

    mutating func validateAccent(_ root: [String: Any], into file: inout ThemeFile) {
        file.primitives = primitives(root["primitives"])
        for key in root.keys.sorted() where !Run.accentTopLevel.contains(key) {
            warn(.unknownKey, [key], "unknown key ignored")
        }
        for appearance in ThemeAppearance.allCases {
            let key = appearance.rawValue
            guard let raw = root[key] else {
                warn(.missingToken, [key], "no \(key) map; the default accent fills it")
                continue
            }
            guard let map = raw as? [String: Any] else {
                warn(.wrongType, [key], "expected an object; ignored")
                continue
            }
            var tokens: [String: TokenSource] = [:]
            for name in map.keys.sorted() {
                guard let value = map[name] else { continue }
                guard let entry = registry.entry(named: name), entry.layer == .accent else {
                    warn(.unknownKey, [key, name], "not an accent token; ignored")
                    continue
                }
                if let source = tokenSource(value, entry: entry, path: [key, name]) { tokens[name] = source }
            }
            file.accent[appearance] = tokens
        }
    }

    mutating func primitives(_ raw: Any?) -> [String: ThemeColor] {
        guard let raw else { return [:] }
        guard let dict = raw as? [String: Any] else {
            warn(.wrongType, ["primitives"], "expected an object; ignored")
            return [:]
        }
        var result: [String: ThemeColor] = [:]
        for key in dict.keys.sorted() {
            guard let value = dict[key] else { continue }
            guard key == "color", let colors = value as? [String: Any] else {
                warn(key == "color" ? .wrongType : .unknownKey, ["primitives", key],
                     key == "color" ? "expected an object; ignored" : "unknown key ignored")
                continue
            }
            for name in colors.keys.sorted() {
                guard let raw = colors[name] else { continue }
                let p = ["primitives", "color", name]
                guard Run.isValidPrimitiveName(name) else {
                    warn(.invalidValue, p, "primitive names are lowercase name.number (e.g. gray.976); ignored")
                    continue
                }
                if registry.entry(named: name) != nil {
                    warn(.invalidValue, p, "a primitive cannot reuse a token name; ignored")
                    continue
                }
                guard let string = raw as? String else {
                    warn(.wrongType, p, "expected a color string; ignored")
                    continue
                }
                guard let color = ThemeColor(literal: string) else {
                    if !checkInjection(string, p) {
                        warn(.invalidValue, p, "not a color (#RRGGBB, #RRGGBBAA or rgba(r,g,b,a)); ignored")
                    }
                    continue
                }
                result[name] = color
            }
        }
        return result
    }

    static func isValidPrimitiveName(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count), let first = name.utf8.first,
              first >= UInt8(ascii: "a"), first <= UInt8(ascii: "z") else { return false }
        let segments = name.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count <= 4, !segments.contains(where: \.isEmpty) else { return false }
        return name.utf8.allSatisfy {
            ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: ".")
        }
    }

    mutating func tokenSource(_ raw: Any, entry: TokenRegistry.Entry, path p: [String]) -> TokenSource? {
        if let string = raw as? String, let name = Run.reference(string) {
            return referenceSource(name, entry: entry, path: p)
        }
        switch entry.type {
        case .color:
            guard let string = raw as? String else { return wrongType(p, "a color string") }
            if let color = ThemeColor(literal: string) { return .value(.color(color)) }
            return invalid(string, p, "not a color (#RRGGBB, #RRGGBBAA or rgba(r,g,b,a))")
        case .shadow:
            guard let string = raw as? String else { return wrongType(p, "a shadow string") }
            if let shadow = Run.shadow(string) { return .value(.shadow(shadow)) }
            return invalid(string, p, "not a shadow (up to 3 layers of \"x y blur spread color\")")
        case .number:
            guard let number = number(raw) else { return wrongNumber(raw, p) }
            return .value(.number(clamp(number, entry, p)))
        case .duration:
            guard let number = number(raw) else { return wrongNumber(raw, p) }
            return .value(.duration(clamp(number, entry, p)))
        case .percent:
            guard let string = raw as? String else { return wrongType(p, "a percentage such as \"100%\"") }
            guard let percent = Run.percent(string) else { return invalid(string, p, "not a percentage such as \"100%\"") }
            return .value(.percent(clamp(percent, entry, p)))
        case .emailColors:
            guard let string = raw as? String else { return wrongType(p, "adaptWhenSafe, alwaysOriginal or alwaysAdapt") }
            guard let value = EmailColors(rawValue: string) else {
                return invalid(string, p, "must be adaptWhenSafe, alwaysOriginal or alwaysAdapt")
            }
            return .value(.emailColors(value))
        case .fontFamily:
            guard let string = raw as? String else { return wrongType(p, "a font family name") }
            guard let family = FontFamily(token: string) else {
                return invalid(string, p, "font names are ≤ 64 letters, digits, spaces or hyphens; using system")
            }
            return .value(.fontFamily(family))
        case .motion:
            guard let dict = raw as? [String: Any] else { return wrongType(p, "an object with duration and easing") }
            for key in dict.keys.sorted() where key != "duration" && key != "easing" {
                warn(.unknownKey, p + [key], "unknown key ignored")
            }
            guard let durationRaw = dict["duration"], let duration = number(durationRaw) else {
                warn(.invalidValue, p + ["duration"], "duration (milliseconds) is required; using the parent's motion")
                return nil
            }
            var easing = Easing.none
            if let easingRaw = dict["easing"] {
                guard let string = easingRaw as? String else { return wrongType(p + ["easing"], "an easing string") }
                guard let parsed = Run.easing(string) else {
                    return invalid(string, p + ["easing"], "easing must be linear or cubic-bezier(a,b,c,d) with a, c in 0-1")
                }
                easing = parsed
            }
            return .value(.motion(ThemeMotion(durationMs: clamp(duration, entry, p + ["duration"]), easing: easing)))
        case .typography:
            return nil
        }
    }

    mutating func referenceSource(_ name: String, entry: TokenRegistry.Entry, path p: [String]) -> TokenSource? {
        if let target = registry.entry(named: name) {
            guard Run.compatible(entry.type, target.type) else {
                warn(.incompatibleReference, p, "{\(name)} is a \(target.type.rawValue), not a \(entry.type.rawValue); ignored")
                return nil
            }
            if target.name == entry.name && target.layer == entry.layer {
                refuse(.referenceCycle, p, "a token cannot reference itself")
                return nil
            }
        } else if entry.type != .color {
            warn(.unknownReference, p, "{\(name)} is not a \(entry.type.rawValue) token; ignored")
            return nil
        }
        return .reference(name)
    }

    static func compatible(_ wanted: TokenRegistry.ValueType, _ actual: TokenRegistry.ValueType) -> Bool {
        wanted == actual && wanted != .typography
    }

    mutating func typography(_ raw: Any, _ p: [String]) -> TypographySpec? {
        guard let dict = raw as? [String: Any] else { return wrongType(p, "an object with size, lineHeight and weight") }
        var spec = TypographySpec()
        for key in dict.keys.sorted() {
            guard let value = dict[key] else { continue }
            let kp = p + [key]
            switch key {
            case "size":
                guard let n = number(value) else { let _: Double? = wrongNumber(value, kp); continue }
                spec.size = clampRange(n, 9, 32, kp)
            case "lineHeight":
                guard let n = number(value) else { let _: Double? = wrongNumber(value, kp); continue }
                spec.lineHeight = clampRange(n, 9, 64, kp)
            case "weight":
                guard let n = number(value) else { let _: Double? = wrongNumber(value, kp); continue }
                spec.weight = Int(clampRange(n, 100, 900, kp).rounded())
            case "trackingEm":
                guard let n = number(value) else { let _: Double? = wrongNumber(value, kp); continue }
                spec.trackingEm = clampRange(n, -0.1, 0.1, kp)
            case "numerals":
                guard let s = value as? String, s == "tabular" || s == "proportional" else {
                    let _: Bool? = invalid(value, kp, "numerals must be tabular or proportional")
                    continue
                }
                spec.tabularNumerals = s == "tabular"
            case "family":
                guard let s = value as? String, let role = FontRole(rawValue: s) else {
                    let _: FontRole? = invalid(value, kp, "family must be ui, reader or mono")
                    continue
                }
                spec.role = role
            default:
                warn(.unknownKey, kp, "unknown key ignored")
            }
        }
        if let size = spec.size, let lh = spec.lineHeight, !(size...(2 * size)).contains(lh) {
            let fixed = min(max(lh, size), 2 * size)
            warn(.clamped, p + ["lineHeight"], "line height must be between size and 2 × size; using \(ThemeColor.shortNumber(fixed))")
            spec.lineHeight = fixed
        }
        return spec
    }

    mutating func wrongType<T>(_ p: [String], _ expected: String) -> T? {
        warn(.wrongType, p, "expected \(expected); ignored")
        return nil
    }

    mutating func wrongNumber<T>(_ raw: Any, _ p: [String]) -> T? {
        if checkInjection(raw, p) { return nil }
        warn(.wrongType, p, "expected a number; ignored")
        return nil
    }

    mutating func invalid<T>(_ raw: Any, _ p: [String], _ message: String) -> T? {
        if let string = raw as? String, Run.isMalformedReference(string) {
            warn(.unknownReference, p, "references look like {token.name} (letters, digits, dots, hyphens); ignored")
            return nil
        }
        if checkInjection(raw, p) { return nil }
        warn(.invalidValue, p, message + "; ignored")
        return nil
    }

    static func isMalformedReference(_ string: String) -> Bool {
        guard string.hasPrefix("{"), string.hasSuffix("}"), string.utf8.count <= 66 else { return false }
        let inner = string.dropFirst().dropLast()
        return inner.unicodeScalars.allSatisfy { s in
            s.isASCII && (s.properties.isAlphabetic || ("0"..."9").contains(s) || s == "." || s == "-" || s == "_" || s == " ")
        }
    }

    mutating func clamp(_ value: Double, _ entry: TokenRegistry.Entry, _ p: [String]) -> Double {
        clampRange(value, entry.min ?? -Double.greatestFiniteMagnitude, entry.max ?? Double.greatestFiniteMagnitude, p)
    }

    mutating func clampRange(_ value: Double, _ lo: Double, _ hi: Double, _ p: [String]) -> Double {
        guard value.isFinite else {
            warn(.clamped, p, "not a finite number; using \(ThemeColor.shortNumber(lo))")
            return lo
        }
        let clamped = min(max(value, lo), hi)
        if clamped != value {
            warn(.clamped, p, "\(ThemeColor.shortNumber(value)) is outside \(ThemeColor.shortNumber(lo))-\(ThemeColor.shortNumber(hi)); using \(ThemeColor.shortNumber(clamped))")
        }
        return clamped
    }

    mutating func plainText(_ raw: Any?, path p: [String], limit: Int, required: Bool) -> String? {
        guard let raw else {
            if required { warn(.missingField, p, "missing; the id is shown instead") }
            return nil
        }
        guard let string = raw as? String else {
            warn(.wrongType, p, "expected text; ignored")
            return nil
        }
        let cleaned = String(String.UnicodeScalarView(string.unicodeScalars.filter { s in
            !(s.properties.generalCategory == .control || s.properties.generalCategory == .format
              || s.properties.generalCategory == .lineSeparator || s.properties.generalCategory == .paragraphSeparator)
        })).trimmingCharacters(in: .whitespaces)
        if cleaned != string { warn(.invalidName, p, "control or direction-override characters removed") }
        guard !cleaned.isEmpty else {
            if required { warn(.invalidName, p, "empty; the id is shown instead") }
            return nil
        }
        if cleaned.count > limit {
            warn(.invalidName, p, "longer than \(limit) characters; shortened")
            return String(cleaned.prefix(limit))
        }
        return cleaned
    }

    func number(_ raw: Any?) -> Double? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    func integer(_ raw: Any?) -> Int? {
        guard let d = number(raw), d.isFinite, d == d.rounded(), abs(d) < 1_000_000 else { return nil }
        return Int(d)
    }

    @discardableResult
    mutating func checkInjection(_ raw: Any, _ p: [String]) -> Bool {
        guard let string = raw as? String, Run.looksLikeCode(string) else { return false }
        refuse(.injection, p, "value looks like code (CSS functions, markup or escapes are never allowed)")
        return true
    }

    static func looksLikeCode(_ string: String) -> Bool {
        let lower = string.lowercased()
        if lower.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return true }
        for needle in ["<", ">", ";", "\\", "\"", "'", "`", "/*", "*/", "{", "}", "@", "!important", "javascript:",
                       "data:", "http:", "https:", "file:", "expression"] where lower.contains(needle) {
            return true
        }
        let stripped = lower.replacingOccurrences(of: "rgba(", with: "").replacingOccurrences(of: "cubic-bezier(", with: "")
        return stripped.contains("(")
    }

    static func reference(_ string: String) -> String? {
        guard string.hasPrefix("{"), string.hasSuffix("}"), string.utf8.count >= 3, string.utf8.count <= 66 else { return nil }
        let name = string.dropFirst().dropLast()
        guard let first = name.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic || ("0"..."9").contains(first),
              name.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "." || $0 == "-") })
        else { return nil }
        return String(name)
    }

    static func shadow(_ string: String) -> ThemeShadow? {
        if string == "none" { return ThemeShadow.none }
        var layers: [String] = []
        var depth = 0
        var current = ""
        for ch in string {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
            if ch == "," && depth == 0 {
                layers.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        layers.append(current)
        guard (1...ThemeValidator.maxShadowLayers).contains(layers.count) else { return nil }
        var result: [ShadowLayer] = []
        for (index, raw) in layers.enumerated() {
            let layer = index == 0 ? raw[...] : raw.drop(while: { $0 == " " })
            let parts = layer.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5,
                  let x = integerPart(parts[0], digits: 2, signed: true), let y = integerPart(parts[1], digits: 2, signed: true),
                  let blur = integerPart(parts[2], digits: 3, signed: false), let spread = integerPart(parts[3], digits: 2, signed: true),
                  let color = ThemeColor(literal: String(parts[4])) else { return nil }
            result.append(ShadowLayer(x: Double(x), y: Double(y), blur: Double(blur), spread: Double(spread), color: color))
        }
        return ThemeShadow(layers: result)
    }

    static func integerPart(_ text: Substring, digits: Int, signed: Bool) -> Int? {
        var body = text
        if signed, body.first == "-" { body = body.dropFirst() }
        guard (1...digits).contains(body.count), body.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    static func easing(_ string: String) -> Easing? {
        if string == "linear" { return .linear }
        guard string.hasPrefix("cubic-bezier("), string.hasSuffix(")"), string.utf8.count <= 60 else { return nil }
        let parts = string.dropFirst(13).dropLast().split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4 else { return nil }
        var values: [Double] = []
        for part in parts {
            guard (1...8).contains(part.count),
                  part.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-") }),
                  let v = Double(part), v.isFinite else { return nil }
            values.append(v)
        }
        guard (0...1).contains(values[0]), (0...1).contains(values[2]),
              (-2...3).contains(values[1]), (-2...3).contains(values[3]) else { return nil }
        return .cubicBezier(values[0], values[1], values[2], values[3])
    }

    static func percent(_ string: String) -> Double? {
        guard string.hasSuffix("%") else { return nil }
        let digits = string.dropLast()
        guard (1...3).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Double(digits) else { return nil }
        return v
    }
}

extension ThemeShadow {
    public init?(literal: String) {
        guard let shadow = Run.shadow(literal) else { return nil }
        self = shadow
    }
}

extension Easing {
    public init?(literal: String) {
        guard let easing = Run.easing(literal) else { return nil }
        self = easing
    }
}
