import AppKit
import MailActions

public struct KeyTable {
    public var bindings: [ActionScope: [KeyChord: ActionID]] = [:]
    public var sequences: [ActionScope: [KeyChord: [KeyChord: ActionID]]] = [:]
    public var nonRepeating: Set<ActionID> = []
    public var whileTyping: [KeyChord: ActionID] = [:]
    public var hints: [ActionScope: [KeyChord: SequenceHint]] = [:]

    public init() {}

    public static func build(_ descriptors: [ActionDescriptor]) -> KeyTable {
        var table = KeyTable()
        var prefixes: [ActionScope: [KeyChord: KeyBinding.Chord]] = [:]
        for descriptor in descriptors {
            if !descriptor.allowsKeyRepeat { table.nonRepeating.insert(descriptor.id) }
            for binding in descriptor.defaultBindings {
                if descriptor.activeWhileTyping, binding.chords.count == 1, binding.hasCommandOrControl {
                    for chord in chords(binding.chords[0]) { table.whileTyping[chord] = descriptor.id }
                }
                for scope in descriptor.scopes(of: binding) {
                    switch binding.chords.count {
                    case 1:
                        for chord in chords(binding.chords[0]) { table.bindings[scope, default: [:]][chord] = descriptor.id }
                    default:
                        for prefix in chords(binding.chords[0]) {
                            prefixes[scope, default: [:]][prefix] = binding.chords[0]
                            for second in chords(binding.chords[1]) {
                                table.sequences[scope, default: [:]][prefix, default: [:]][second] = descriptor.id
                            }
                        }
                    }
                }
            }
        }
        for (scope, byPrefix) in prefixes {
            for (prefix, chord) in byPrefix {
                table.hints[scope, default: [:]][prefix] = SequenceHint.make(prefix: chord, scopes: [scope],
                                                                             descriptors: descriptors)
            }
        }
        return table
    }

    public static func chords(_ chord: KeyBinding.Chord) -> [KeyChord] {
        let modifiers = flags(chord.modifiers)
        switch chord.key {
        case .character(let c):
            return [KeyChord(.character(c), modifiers: modifiers)]
        case .named(let named):
            let keys: [KeyChord.NamedKey] = switch named {
            case .enter: [.returnKey, .keypadEnter]
            case .tab: [.tab]
            case .escape: [.escape]
            case .delete: [.delete]
            case .up: [.up]
            case .down: [.down]
            case .left: [.left]
            case .right: [.right]
            }
            return keys.map { KeyChord(.named($0), modifiers: modifiers) }
        }
    }

    public static func composer(_ descriptors: [ActionDescriptor]) -> [KeyChord: ActionID] {
        var table: [KeyChord: ActionID] = [:]
        for descriptor in descriptors {
            for binding in descriptor.defaultBindings where binding.chords.count == 1
                && descriptor.scopes(of: binding).contains(.composer) {
                for chord in chords(binding.chords[0]) { table[chord] = descriptor.id }
            }
        }
        return table
    }

    static func flags(_ modifiers: KeyBinding.Modifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }
}

extension KeyRouter {
    public func load(_ table: KeyTable) {
        bindings = table.bindings
        sequences = table.sequences
        nonRepeating = table.nonRepeating
        whileTyping = table.whileTyping
        hints = table.hints
    }

    public static func catalog(_ descriptors: [ActionDescriptor] = ActionCatalog.all) -> KeyRouter {
        let router = KeyRouter(bindings: [:])
        router.load(KeyTable.build(descriptors))
        return router
    }
}
