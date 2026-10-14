public struct KeyBinding: Hashable, Sendable, CustomStringConvertible {
    public enum NamedKey: String, Hashable, Sendable, Codable, CaseIterable {
        case enter
        case tab, escape, delete, up, down, left, right
    }

    public enum Key: Hashable, Sendable {
        case character(String)
        case named(NamedKey)
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    public struct Chord: Hashable, Sendable {
        public let key: Key
        public let modifiers: Modifiers

        public init(_ key: Key, modifiers: Modifiers = []) {
            self.key = key
            if case .character(let c) = key, !KeyBinding.keepsShift(c, modifiers) {
                self.modifiers = modifiers.subtracting(.shift)
            } else {
                self.modifiers = modifiers
            }
        }
    }

    public static func isDigit(_ character: String) -> Bool {
        character.count == 1 && character.first.map { $0.isASCII && $0.isWholeNumber } == true
    }

    static func keepsShift(_ character: String, _ modifiers: Modifiers) -> Bool {
        isDigit(character) && !modifiers.intersection([.command, .control]).isEmpty
    }

    public let chords: [Chord]
    public let onlyIn: Set<ActionScope>?

    public init(_ chords: [Chord], onlyIn: Set<ActionScope>? = nil) {
        precondition((1...2).contains(chords.count), "a binding is one chord or a two-chord sequence")
        self.chords = chords
        self.onlyIn = onlyIn
    }

    public static func key(_ character: String, onlyIn: Set<ActionScope>? = nil) -> KeyBinding {
        KeyBinding([Chord(.character(character))], onlyIn: onlyIn)
    }

    public static func named(_ key: NamedKey, _ modifiers: Modifiers = [], onlyIn: Set<ActionScope>? = nil) -> KeyBinding {
        KeyBinding([Chord(.named(key), modifiers: modifiers)], onlyIn: onlyIn)
    }

    public static func chord(_ character: String, _ modifiers: Modifiers, onlyIn: Set<ActionScope>? = nil) -> KeyBinding {
        KeyBinding([Chord(.character(character), modifiers: modifiers)], onlyIn: onlyIn)
    }

    public static func sequence(_ first: String, _ second: String) -> KeyBinding {
        KeyBinding([Chord(.character(first)), Chord(.character(second))])
    }

    public var isMenuKeyEquivalent: Bool {
        chords.count == 1 && !chords[0].modifiers.intersection([.command, .control]).isEmpty
    }

    public var hasCommandOrControl: Bool { !chords[0].modifiers.intersection([.command, .control]).isEmpty }

    public var description: String { chords.map(Self.display).joined(separator: " ") }

    public var keycaps: [String] { chords.map(Self.display) }

    public var grammar: String {
        chords.map { chord in
            var text = Self.modifierSymbols(chord.modifiers)
            switch chord.key {
            case .character(let c): text += c
            case .named(let named): text += Self.symbol(named)
            }
            return text
        }.joined(separator: " ")
    }

    static func display(_ chord: Chord) -> String {
        var modifiers = chord.modifiers
        if case .character(let c) = chord.key, c.count == 1, let scalar = c.unicodeScalars.first,
           scalar.properties.isUppercase {
            modifiers.insert(.shift)
        }
        var text = modifierSymbols(modifiers)
        switch chord.key {
        case .character(let c):
            text += c.uppercased()
        case .named(let named):
            text += symbol(named)
        }
        return text
    }

    static func modifierSymbols(_ modifiers: Modifiers) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text
    }

    static func symbol(_ key: NamedKey) -> String {
        switch key {
        case .enter: "↵"
        case .tab: "⇥"
        case .escape: "Esc"
        case .delete: "⌫"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        }
    }
}

public enum KeyBindingParseError: Error, Hashable, Sendable, CustomStringConvertible {
    case empty
    case tooManyChords(String)
    case missingKey(String)
    case unknownKey(String)
    case shiftedSymbol(String)
    case duplicateModifier(String)

    public var description: String {
        switch self {
        case .empty: "empty binding"
        case .tooManyChords(let s): "\"\(s)\": a binding is one chord or two (a sequence)"
        case .missingKey(let s): "\"\(s)\": modifiers without a key"
        case .unknownKey(let s): "\"\(s)\": unknown key"
        case .shiftedSymbol(let s): "\"\(s)\": write the character ⇧ produces (e.g. \"!\" for ⇧1)"
        case .duplicateModifier(let s): "\"\(s)\": a modifier is repeated"
        }
    }
}

extension KeyBinding {
    public init(parsing text: String, onlyIn: Set<ActionScope>? = nil) throws {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !parts.isEmpty else { throw KeyBindingParseError.empty }
        guard parts.count <= 2 else { throw KeyBindingParseError.tooManyChords(text) }
        self.init(try parts.map(Self.parseChord), onlyIn: onlyIn)
    }

    private static let asciiModifiers: [(String, Modifiers)] = [
        ("cmd+", .command), ("command+", .command), ("opt+", .option), ("option+", .option), ("alt+", .option),
        ("ctrl+", .control), ("control+", .control), ("shift+", .shift),
    ]
    private static let symbolModifiers: [Character: Modifiers] = ["⌘": .command, "⌥": .option, "⌃": .control, "⇧": .shift]
    private static let namedKeys: [String: NamedKey] = [
        "↵": .enter, "⏎": .enter, "return": .enter, "enter": .enter,
        "⇥": .tab, "tab": .tab,
        "esc": .escape, "escape": .escape, "⎋": .escape,
        "⌫": .delete, "delete": .delete, "backspace": .delete,
        "↑": .up, "up": .up, "↓": .down, "down": .down, "←": .left, "left": .left, "→": .right, "right": .right,
    ]

    static func parseChord(_ text: String) throws -> Chord {
        var rest = Substring(text)
        var modifiers: Modifiers = []
        func add(_ modifier: Modifiers) throws {
            guard !modifiers.contains(modifier) else { throw KeyBindingParseError.duplicateModifier(text) }
            modifiers.insert(modifier)
        }
        scanning: while !rest.isEmpty {
            if rest.count > 1, let first = rest.first, let modifier = symbolModifiers[first] {
                try add(modifier)
                rest = rest.dropFirst()
                continue
            }
            for (prefix, modifier) in asciiModifiers where rest.count > prefix.count && rest.lowercased().hasPrefix(prefix) {
                try add(modifier)
                rest = rest.dropFirst(prefix.count)
                continue scanning
            }
            break
        }
        let keyText = String(rest)
        let isBareModifier = keyText.count == 1 && symbolModifiers[keyText.first!] != nil
            || asciiModifiers.contains { $0.0 == keyText.lowercased() }
        guard !keyText.isEmpty, !isBareModifier else { throw KeyBindingParseError.missingKey(text) }
        if let named = namedKeys[keyText.lowercased()] ?? namedKeys[keyText] {
            return Chord(.named(named), modifiers: modifiers)
        }
        guard keyText.count == 1, let character = keyText.first, !character.isWhitespace else {
            throw KeyBindingParseError.unknownKey(text)
        }
        if modifiers.contains(.shift) {
            if keepsShift(String(character), modifiers) { return Chord(.character(String(character)), modifiers: modifiers) }
            guard character.isLetter else { throw KeyBindingParseError.shiftedSymbol(text) }
            return Chord(.character(character.uppercased()), modifiers: modifiers)
        }
        return Chord(.character(String(character)), modifiers: modifiers)
    }
}
