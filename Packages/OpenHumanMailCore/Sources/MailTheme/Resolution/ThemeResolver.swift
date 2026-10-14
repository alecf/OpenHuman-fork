import Foundation

struct ThemeResolver {
    static let maxReferenceHops = 8

    let registry: TokenRegistry
    let chain: [ThemeFile]
    let accent: ThemeFile?
    let accentMode: ThemeAppearance
    let overrides: [String: TokenSource]
    let typographyOverrides: [String: TypographySpec]
    private(set) var issues: [ThemeIssue] = []
    private let primitives: [String: ThemeColor]
    private var memo: [String: TokenValue?] = [:]
    private var visiting: Set<String> = []

    init(registry: TokenRegistry, chain: [ThemeFile], accent: ThemeFile?, accentMode: ThemeAppearance,
         overrides: [String: TokenSource] = [:], typographyOverrides: [String: TypographySpec] = [:]) {
        self.registry = registry
        self.chain = chain
        self.accent = accent
        self.accentMode = accentMode
        self.overrides = overrides
        self.typographyOverrides = typographyOverrides
        var merged: [String: ThemeColor] = [:]
        for file in chain.reversed() { merged.merge(file.primitives) { _, child in child } }
        primitives = merged
    }

    mutating func resolveTable() -> (table: [String: TokenValue], missing: [String]) {
        var table: [String: TokenValue] = [:]
        var missing: [String] = []
        for entry in registry.entries {
            if entry.type == .typography {
                if let style = typography(entry) { table[entry.key] = .typography(style) } else { missing.append(entry.name) }
                continue
            }
            if let value = value(entry, hops: 0) {
                table[entry.key] = value
            } else if definition(entry) == nil {
                missing.append(entry.name)
            }
        }
        return (table, missing)
    }

    func definition(_ entry: TokenRegistry.Entry) -> TokenSource? {
        if let override = overrides[entry.key] { return override }
        if entry.layer == .accent { return accent?.accent[accentMode]?[entry.name] }
        for file in chain {
            if let source = file.tokens[entry.key] { return source }
        }
        return nil
    }

    func displayPath(_ entry: TokenRegistry.Entry) -> String {
        entry.layer == .accent ? "\(accentMode.rawValue).\(entry.name)" : entry.path.joined(separator: ".")
    }

    mutating func value(_ entry: TokenRegistry.Entry, hops: Int) -> TokenValue? {
        if let cached = memo[entry.key] { return cached }
        guard !visiting.contains(entry.key) else {
            issues.append(.refused(.referenceCycle, displayPath(entry), "references form a cycle"))
            return nil
        }
        guard let definition = definition(entry) else { return nil }
        visiting.insert(entry.key)
        defer { visiting.remove(entry.key) }
        let result: TokenValue?
        switch definition {
        case .value(let value): result = value
        case .reference(let name): result = follow(name, from: entry, hops: hops + 1)
        }
        memo[entry.key] = .some(result)
        return result
    }

    mutating func follow(_ name: String, from entry: TokenRegistry.Entry, hops: Int) -> TokenValue? {
        guard hops <= Self.maxReferenceHops else {
            issues.append(.refused(.referenceTooDeep, displayPath(entry), "reference chain longer than \(Self.maxReferenceHops)"))
            return nil
        }
        if entry.layer == .accent {
            if let color = accent?.primitives[name] { return .color(color) }
            if let target = registry.entry(named: name), target.layer == .accent { return value(target, hops: hops) }
            issues.append(.warning(.unknownReference, displayPath(entry), "{\(name)} is not defined in the accent file; using the default"))
            return nil
        }
        if let target = registry.entry(named: name) {
            guard target.type == entry.type else {
                issues.append(.warning(.incompatibleReference, displayPath(entry),
                                       "{\(name)} is a \(target.type.rawValue), not a \(entry.type.rawValue); using the default"))
                return nil
            }
            return value(target, hops: hops)
        }
        if entry.type == .color, let color = primitives[name] { return .color(color) }
        issues.append(.warning(.unknownReference, displayPath(entry), "{\(name)} is not defined; using the default"))
        return nil
    }

    func typography(_ entry: TokenRegistry.Entry) -> TypeStyle? {
        var spec = TypographySpec()
        for file in chain.reversed() {
            if let s = file.typography[entry.key] { spec = s.merged(over: spec) }
        }
        if let s = typographyOverrides[entry.key] { spec = s.merged(over: spec) }
        guard let size = spec.size, let lineHeight = spec.lineHeight, let weight = spec.weight else { return nil }
        let styleName = entry.path.last ?? ""
        let defaultRole: FontRole = styleName == "mono" ? .mono : styleName == "reader" ? .reader : .ui
        return TypeStyle(size: size, lineHeight: min(max(lineHeight, size), 2 * size).rounded(), weight: weight,
                         monospacedDigits: spec.tabularNumerals ?? false, trackingEm: spec.trackingEm ?? 0,
                         role: spec.role ?? defaultRole, family: .system)
    }
}
