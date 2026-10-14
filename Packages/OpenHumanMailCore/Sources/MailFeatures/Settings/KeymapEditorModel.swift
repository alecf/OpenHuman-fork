import Foundation
import MailActions
import Observation

public enum KeyRecorder {
    static let namedKeys: [UInt16: KeyBinding.NamedKey] = [
        36: .enter, 76: .enter, 48: .tab, 53: .escape, 51: .delete, 123: .left, 124: .right, 125: .down, 126: .up,
    ]
    static let digitKeys: [UInt16: String] = [
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
    ]

    public static func chord(keyCode: UInt16, characters: String?, command: Bool, option: Bool, control: Bool,
                             shift: Bool) -> KeyBinding.Chord? {
        var modifiers: KeyBinding.Modifiers = []
        if command { modifiers.insert(.command) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        if shift { modifiers.insert(.shift) }
        if let named = namedKeys[keyCode] { return KeyBinding.Chord(.named(named), modifiers: modifiers) }
        if command || control, let digit = digitKeys[keyCode] {
            return KeyBinding.Chord(.character(digit), modifiers: modifiers)
        }
        guard let characters, characters.count == 1, let character = characters.first,
              !character.isWhitespace, let scalar = character.unicodeScalars.first,
              !(0xF700...0xF8FF).contains(scalar.value), scalar.value >= 0x21 else { return nil }
        let text = shift && character.isLetter ? String(character).uppercased() : String(character)
        return KeyBinding.Chord(.character(text), modifiers: modifiers)
    }
}

public struct KeymapImportPreview: Sendable, Hashable {
    public let accepted: KeymapOverrides
    public let changedCount: Int
    public let refused: [String]

    public var summary: String {
        let changes = changedCount == 1 ? "1 shortcut" : "\(changedCount) shortcuts"
        let refusals = refused.isEmpty ? "" : refused.count == 1 ? " 1 line is skipped." : " \(refused.count) lines are skipped."
        return "This file changes \(changes).\(refusals)"
    }
}

public enum KeymapFileError: Error, Hashable, Sendable, CustomStringConvertible {
    case unreadable
    case unsupportedVersion(Int)

    public var description: String {
        switch self {
        case .unreadable: "That file isn't a Mail keymap."
        case .unsupportedVersion(let v): "That keymap is version \(v); this Mail reads version \(KeymapOverrides.currentVersion)."
        }
    }
}

@MainActor @Observable
public final class KeymapEditorModel {
    public enum Outcome: Hashable, Sendable {
        case changed
        case refused(String)
        case cancelled
        case waitingForSecondKey
        case notRecording
    }

    public private(set) var recording: ActionID?
    public private(set) var pending: [KeyBinding.Chord] = []
    public private(set) var message: String?
    public private(set) var messageIsRefusal = false
    public private(set) var overrides: KeymapOverrides

    @ObservationIgnored private let registry: ActionRegistry
    @ObservationIgnored private let store: any KeymapStoring

    public init(registry: ActionRegistry, store: any KeymapStoring) {
        self.registry = registry
        self.store = store
        overrides = registry.userKeymapOverrides
    }

    public static let recordingHint = "Press the new shortcut. Esc cancels."
    public static let footnote = "⌘K, ⌘Q, ⌘W, ⌘H, ⌘M and ⌘, can't be changed. A shortcut another action uses where this "
        + "one works is refused."

    public func isCustomized(_ id: ActionID) -> Bool { overrides.bindings[id.rawValue] != nil }

    public func canChange(_ id: ActionID) -> Bool { id != .commandPalette && registry.descriptor(id) != nil }

    public var pendingText: String? {
        pending.isEmpty ? nil : KeyBinding(pending).description + "…"
    }

    public func startRecording(_ id: ActionID) {
        guard canChange(id) else { return }
        recording = id
        pending = []
        message = nil
    }

    public func cancelRecording() {
        recording = nil
        pending = []
    }

    @discardableResult
    public func record(_ chord: KeyBinding.Chord) -> Outcome {
        guard let id = recording else { return .notRecording }
        if pending.isEmpty, chord == KeyBinding.Chord(.named(.escape)) {
            cancelRecording()
            return .cancelled
        }
        pending.append(chord)
        if pending.count == 1, isSequencePrefix(chord) { return .waitingForSecondKey }
        let binding = KeyBinding(pending)
        cancelRecording()
        return assign(binding, to: id)
    }

    @discardableResult
    public func finishPending() -> Outcome {
        guard let id = recording, !pending.isEmpty else { return .notRecording }
        let binding = KeyBinding(pending)
        cancelRecording()
        return assign(binding, to: id)
    }

    private func isSequencePrefix(_ chord: KeyBinding.Chord) -> Bool {
        registry.descriptors.contains { d in d.defaultBindings.contains { $0.chords.count == 2 && $0.chords[0] == chord } }
    }

    @discardableResult
    public func assign(_ binding: KeyBinding, to id: ActionID) -> Outcome {
        guard canChange(id), let current = registry.descriptor(id) else {
            return refuse(id == .commandPalette ? "⌘K always opens the command palette." : "That action can't be changed.")
        }
        if let use = Keymap.fixedUse(of: binding) {
            return refuse("\(binding.description) is \(use) and can't be changed.")
        }
        var keys = current.defaultBindings.map { KeyBinding($0.chords) }
        if keys.isEmpty { keys = [binding] } else { keys[0] = binding }
        var seen: Set<[KeyBinding.Chord]> = []
        keys = keys.filter { seen.insert($0.chords).inserted }
        var next = overrides
        let defaults = registry.defaultDescriptors.first { $0.id == id }?.defaultBindings.map(\.chords) ?? []
        if keys.map(\.chords) == defaults {
            next.bindings[id.rawValue] = nil
        } else {
            next.bindings[id.rawValue] = keys.map(\.grammar)
        }
        return apply(next, focus: id, done: "“\(current.title)” is now \(binding.description).")
    }

    @discardableResult
    public func reset(_ id: ActionID) -> Outcome {
        guard isCustomized(id) else { return .changed }
        var next = overrides
        next.bindings[id.rawValue] = nil
        let title = registry.descriptor(id)?.title ?? id.rawValue
        return apply(next, focus: id, done: "“\(title)” has its standard shortcut again.")
    }

    public func resetAll() {
        cancelRecording()
        overrides = KeymapOverrides()
        store.save(overrides)
        registry.applyKeymap(overrides)
        say("All shortcuts are back to standard.", refusal: false)
    }

    private func apply(_ next: KeymapOverrides, focus id: ActionID, done: String) -> Outcome {
        let base = registry.defaultDescriptors
        let before = Keymap.resolve(overrides, descriptors: base)
        let after = Keymap.resolve(next, descriptors: base)
        let wanted = next.bindings[id.rawValue]
        let got = after.overrides[id].map { $0.map(\.grammar) }
        let lostOther = before.overrides.keys.contains { $0 != id && after.overrides[$0] == nil && next.bindings[$0.rawValue] != nil }
        let newIssues = after.issues.filter { !before.issues.contains($0) }
        if got != wanted || lostOther || !newIssues.isEmpty {
            let reason = newIssues.first.map { describe($0, focus: id) } ?? "That shortcut can't be used here."
            return refuse(reason)
        }
        overrides = next
        store.save(next)
        registry.applyKeymap(next)
        say(done, refusal: false)
        return .changed
    }

    func describe(_ issue: KeymapIssue, focus id: ActionID) -> String {
        func title(_ action: ActionID) -> String { registry.descriptor(action)?.title ?? action.rawValue }
        switch issue {
        case .conflict(let conflict):
            let other = conflict.first == id ? conflict.second : conflict.first
            let place = ShortcutLine.placeName(of: [conflict.scope]).lowercased()
            switch conflict.kind {
            case .sameKeys:
                return "\(conflict.binding.description) is already “\(title(other))” (\(place))."
            case .prefixShadowsSequence:
                return conflict.first == id
                    ? "\(conflict.binding.description) starts other shortcuts, such as “\(title(conflict.second))”."
                    : "That shortcut starts with \(conflict.binding.description), which is “\(title(conflict.first))”."
            }
        case .textSystem(let conflict):
            return "\(conflict.binding.description) edits text in the composer, so it can't be a shortcut there."
        case .fixedKey(_, let binding, let use):
            return "\(binding.description) is \(use) and can't be changed."
        case .reserved:
            return "⌘K always opens the command palette."
        case .unparsable:
            return "Mail can't read that shortcut."
        case .unknownAction(let raw):
            return "Mail has no action named \(raw)."
        case .unsupportedVersion(let version):
            return KeymapFileError.unsupportedVersion(version).description
        }
    }

    private func refuse(_ reason: String) -> Outcome {
        say(reason, refusal: true)
        return .refused(reason)
    }

    private func say(_ text: String, refusal: Bool) {
        message = text
        messageIsRefusal = refusal
    }

    public func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(overrides)
    }

    public func importPreview(_ data: Data) throws -> KeymapImportPreview {
        guard let file = try? JSONDecoder().decode(KeymapOverrides.self, from: data) else { throw KeymapFileError.unreadable }
        guard file.version == KeymapOverrides.currentVersion else { throw KeymapFileError.unsupportedVersion(file.version) }
        let base = registry.defaultDescriptors
        let resolved = Keymap.resolve(file, descriptors: base)
        let accepted = resolved.asOverrides
        let now = Keymap.resolve(overrides, descriptors: base)
        let ids = Set(now.overrides.keys).union(resolved.overrides.keys)
        let changed = ids.filter { now.overrides[$0] != resolved.overrides[$0] }.count
        let refused = resolved.issues.map { issue -> String in
            switch issue {
            case .conflict(let c): return "\(c.binding.description): " + describe(issue, focus: c.second)
            default: return describe(issue, focus: .commandPalette)
            }
        }
        return KeymapImportPreview(accepted: accepted, changedCount: changed, refused: refused)
    }

    public func applyImport(_ preview: KeymapImportPreview) {
        cancelRecording()
        overrides = preview.accepted
        store.save(preview.accepted)
        registry.applyKeymap(preview.accepted)
        say(preview.changedCount == 1 ? "1 shortcut imported." : "\(preview.changedCount) shortcuts imported.", refusal: false)
    }
}
