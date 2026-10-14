public struct KeyBindingConflict: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: Hashable, Sendable {
        case sameKeys
        case prefixShadowsSequence
    }

    public let kind: Kind
    public let first: ActionID
    public let second: ActionID
    public let binding: KeyBinding
    public let scope: ActionScope

    public var description: String {
        switch kind {
        case .sameKeys: "\(binding) is bound to \(first) and \(second) in \(scope)"
        case .prefixShadowsSequence: "\(binding) of \(first) is the prefix of a sequence of \(second) in \(scope)"
        }
    }
}

public enum KeyBindingConflicts {
    public static func overlap(_ a: ActionScope, _ b: ActionScope) -> Bool {
        a == b || a == .global || b == .global
    }

    public static func find(in descriptors: [ActionDescriptor],
                            bindings: [ActionID: [KeyBinding]] = [:]) -> [KeyBindingConflict] {
        var entries: [(id: ActionID, scope: ActionScope, binding: KeyBinding)] = []
        for descriptor in descriptors {
            let effective = bindings[descriptor.id].map(descriptor.rebound) ?? descriptor
            for binding in effective.defaultBindings {
                for scope in effective.scopes(of: binding) { entries.append((descriptor.id, scope, binding)) }
            }
        }
        var conflicts: [KeyBindingConflict] = []
        for (i, a) in entries.enumerated() {
            for b in entries[(i + 1)...] where a.id != b.id && overlap(a.scope, b.scope) {
                let scope = a.scope == .global ? b.scope : a.scope
                if a.binding.chords == b.binding.chords {
                    conflicts.append(KeyBindingConflict(kind: .sameKeys, first: a.id, second: b.id, binding: a.binding,
                                                        scope: scope))
                } else if b.binding.chords.count == 2, a.binding.chords == [b.binding.chords[0]] {
                    conflicts.append(KeyBindingConflict(kind: .prefixShadowsSequence, first: a.id, second: b.id,
                                                        binding: a.binding, scope: scope))
                } else if a.binding.chords.count == 2, b.binding.chords == [a.binding.chords[0]] {
                    conflicts.append(KeyBindingConflict(kind: .prefixShadowsSequence, first: b.id, second: a.id,
                                                        binding: b.binding, scope: scope))
                }
            }
        }
        return conflicts
    }

    // Why: the text system acts on these chords in every text view, so binding one would take an editing key
    public static let reserved: [KeyBinding.Chord: String] = {
        var table: [KeyBinding.Chord: String] = [
            KeyBinding.Chord(.character("."), modifiers: .command): "cancelOperation:",
            KeyBinding.Chord(.named(.enter), modifiers: .option): "insertNewlineIgnoringFieldEditor:",
            KeyBinding.Chord(.named(.enter), modifiers: .control): "insertLineBreak:",
            KeyBinding.Chord(.named(.escape), modifiers: .option): "complete:",
            KeyBinding.Chord(.named(.tab), modifiers: .control): "selectNextKeyView:",
            KeyBinding.Chord(.named(.tab), modifiers: [.control, .shift]): "selectPreviousKeyView:",
            KeyBinding.Chord(.named(.delete), modifiers: .command): "deleteToBeginningOfLine:",
        ]
        for arrow: KeyBinding.NamedKey in [.up, .down, .left, .right] {
            table[KeyBinding.Chord(.named(arrow), modifiers: .command)] = "document and line start or end"
            table[KeyBinding.Chord(.named(arrow), modifiers: [.command, .shift])] = "document and line start or end"
        }
        for named: KeyBinding.NamedKey in [.delete, .left, .right] {
            table[KeyBinding.Chord(.named(named), modifiers: .option)] = "word editing"
        }
        for letter in ["a", "e", "k", "d", "h", "t", "y", "n", "p", "f", "b", "v", "o", "l"] {
            table[KeyBinding.Chord(.character(letter), modifiers: .control)] = "Emacs-style editing"
        }
        return table
    }()

    public static let reservedExceptions: [KeyBinding.Chord: ActionID] = [
        KeyBinding.Chord(.named(.delete), modifiers: .command): .discardDraft,
    ]

    public static func textSystemConflicts(in descriptors: [ActionDescriptor],
                                           bindings: [ActionID: [KeyBinding]] = [:]) -> [TextSystemConflict] {
        var found: [TextSystemConflict] = []
        for descriptor in descriptors {
            let effective = bindings[descriptor.id].map(descriptor.rebound) ?? descriptor
            for binding in effective.defaultBindings where effective.scopes(of: binding).contains(.composer) {
                let chord = binding.chords[0]
                guard let use = reserved[chord], reservedExceptions[chord] != descriptor.id else { continue }
                found.append(TextSystemConflict(action: descriptor.id, binding: binding, textSystemUse: use))
            }
        }
        return found
    }
}

public struct TextSystemConflict: Hashable, Sendable, CustomStringConvertible {
    public let action: ActionID
    public let binding: KeyBinding
    public let textSystemUse: String

    public var description: String { "\(binding) of \(action) is the text system's \(textSystemUse) in the composer" }
}

public struct KeymapOverrides: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var bindings: [String: [String]]

    public init(version: Int = KeymapOverrides.currentVersion, bindings: [String: [String]] = [:]) {
        self.version = version
        self.bindings = bindings
    }

    public var isEmpty: Bool { bindings.isEmpty }
}

public enum KeymapIssue: Hashable, Sendable, CustomStringConvertible {
    case unsupportedVersion(Int)
    case unknownAction(String)
    case unparsable(action: ActionID, text: String, error: KeyBindingParseError)
    case conflict(KeyBindingConflict)
    case reserved(action: ActionID)
    case textSystem(TextSystemConflict)
    case fixedKey(action: ActionID, binding: KeyBinding, use: String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let v): "keymap version \(v) is not supported"
        case .unknownAction(let id): "unknown action \(id)"
        case .unparsable(let action, let text, let error): "\(action): \"\(text)\": \(error)"
        case .conflict(let conflict): conflict.description
        case .reserved(let action): "\(action): the command palette's ⌘K cannot be rebound"
        case .textSystem(let conflict): conflict.description
        case .fixedKey(let action, let binding, let use): "\(action): \(binding) is \(use) and cannot be reassigned"
        }
    }
}

public struct Keymap: Hashable, Sendable {
    public let overrides: [ActionID: [KeyBinding]]
    public let issues: [KeymapIssue]

    public static let defaults = Keymap(overrides: [:], issues: [])

    public static let fixedChords: [KeyBinding.Chord: String] = [
        KeyBinding.Chord(.character("q"), modifiers: .command): "Quit Mail",
        KeyBinding.Chord(.character("w"), modifiers: .command): "Close Window",
        KeyBinding.Chord(.character("h"), modifiers: .command): "Hide Mail",
        KeyBinding.Chord(.character("m"), modifiers: .command): "Minimize",
        KeyBinding.Chord(.character(","), modifiers: .command): "Settings",
    ]

    public static func fixedUse(of binding: KeyBinding) -> String? {
        binding.chords.first.flatMap { fixedChords[$0] }
    }

    init(overrides: [ActionID: [KeyBinding]], issues: [KeymapIssue]) {
        self.overrides = overrides
        self.issues = issues
    }

    public static func resolve(_ user: KeymapOverrides, descriptors: [ActionDescriptor]) -> Keymap {
        guard user.version == KeymapOverrides.currentVersion else {
            return Keymap(overrides: [:], issues: [.unsupportedVersion(user.version)])
        }
        guard !user.bindings.isEmpty else { return .defaults }
        let known = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
        var candidates: [(ActionID, [KeyBinding])] = []
        var issues: [KeymapIssue] = []
        for (raw, texts) in user.bindings.sorted(by: { $0.key < $1.key }) {
            let id = ActionID(raw)
            guard let descriptor = known[id] else {
                issues.append(.unknownAction(raw))
                continue
            }
            if id == .commandPalette {
                issues.append(.reserved(action: id))
                continue
            }
            var parsed: [KeyBinding] = []
            var failed = false
            for text in texts {
                do {
                    let binding = try KeyBinding(parsing: text)
                    let restriction = descriptor.defaultBindings.first { $0.chords == binding.chords }?.onlyIn
                    parsed.append(KeyBinding(binding.chords, onlyIn: restriction))
                } catch let error as KeyBindingParseError {
                    issues.append(.unparsable(action: id, text: text, error: error))
                    failed = true
                } catch {
                    failed = true
                }
            }
            guard !failed else { continue }
            if let fixed = parsed.first(where: { binding in
                Self.fixedUse(of: binding) != nil && !descriptor.defaultBindings.contains { $0.chords == binding.chords }
            }), let use = Self.fixedUse(of: fixed) {
                issues.append(.fixedKey(action: id, binding: fixed, use: use))
                continue
            }
            candidates.append((id, parsed))
        }
        var accepted = Dictionary(candidates, uniquingKeysWith: { first, _ in first })
        for conflict in KeyBindingConflicts.textSystemConflicts(in: descriptors, bindings: accepted)
        where accepted[conflict.action] != nil {
            accepted[conflict.action] = nil
            issues.append(.textSystem(conflict))
        }
        while let conflict = KeyBindingConflicts.find(in: descriptors, bindings: accepted).first(where: {
            accepted[$0.first] != nil || accepted[$0.second] != nil
        }) {
            let rejected = accepted[conflict.second] != nil ? conflict.second : conflict.first
            accepted[rejected] = nil
            issues.append(.conflict(conflict))
        }
        return Keymap(overrides: accepted, issues: issues)
    }

    public func bindings(for descriptor: ActionDescriptor) -> [KeyBinding] {
        overrides[descriptor.id] ?? descriptor.defaultBindings
    }

    public func apply(to descriptors: [ActionDescriptor]) -> [ActionDescriptor] {
        descriptors.map { d in overrides[d.id].map(d.rebound) ?? d }
    }

    public var asOverrides: KeymapOverrides {
        KeymapOverrides(bindings: Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value.map(\.grammar)) }))
    }
}
