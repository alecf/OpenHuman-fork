import Foundation
import MailActions
import MailModel
import Observation

public enum GlobalHotkeyRules {
    public static let defaultBinding = KeyBinding.chord("m", [.control, .option])

    public enum Problem: Error, Hashable, Sendable, CustomStringConvertible {
        case unreadable(String)
        case sequence
        case unsupportedKey
        case needsTwoModifiers
        case usedByMail(String)

        public var description: String {
            switch self {
            case .unreadable(let reason): "That isn't a shortcut Mail can read (\(reason)). Type it like ⌃⌥M or ctrl+opt+m."
            case .sequence: "Use one key combination, not a sequence."
            case .unsupportedKey: "Use a letter or a digit."
            case .needsTwoModifiers: "Hold at least two of ⌃ ⌥ ⌘, so the shortcut doesn't take a key other apps use."
            case .usedByMail(let title): "Mail already uses that for \(title)."
            }
        }
    }

    public static func parse(_ text: String, catalog: [ActionDescriptor] = ActionCatalog.all) -> Result<KeyBinding, Problem> {
        let binding: KeyBinding
        do {
            binding = try KeyBinding(parsing: text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .failure(.unreadable((error as? KeyBindingParseError)?.description ?? "\(error)"))
        }
        return hotkey(for: binding, catalog: catalog).map { _ in binding }
    }

    public static func recorded(key: String, modifiers: KeyBinding.Modifiers) -> KeyBinding? {
        guard key.count == 1, let scalar = key.unicodeScalars.first, scalar.isASCII, scalar.value > 0x20, scalar.value < 0x7F
        else { return nil }
        var modifiers = modifiers
        var character = key.lowercased()
        if scalar.properties.isAlphabetic, modifiers.contains(.shift) {
            character = key.uppercased()
            modifiers.remove(.shift)
        }
        return .chord(character, modifiers)
    }

    public static func hotkey(for binding: KeyBinding, catalog: [ActionDescriptor] = ActionCatalog.all) -> Result<GlobalHotkey, Problem> {
        guard binding.chords.count == 1, let chord = binding.chords.first else { return .failure(.sequence) }
        guard case .character(let character) = chord.key, character.count == 1, let scalar = character.unicodeScalars.first,
              scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(character) else {
            return .failure(.unsupportedKey)
        }
        let strong = chord.modifiers.intersection([.command, .option, .control])
        guard [KeyBinding.Modifiers.command, .option, .control].filter(strong.contains).count >= 2 else {
            return .failure(.needsTwoModifiers)
        }
        if let taken = catalog.first(where: { $0.defaultBindings.contains { $0.chords == [chord] } }) {
            return .failure(.usedByMail(taken.title))
        }
        var modifiers: GlobalHotkey.Modifiers = []
        if chord.modifiers.contains(.command) { modifiers.insert(.command) }
        if chord.modifiers.contains(.option) { modifiers.insert(.option) }
        if chord.modifiers.contains(.control) { modifiers.insert(.control) }
        if scalar.properties.isUppercase || chord.modifiers.contains(.shift) { modifiers.insert(.shift) }
        return .success(GlobalHotkey(key: character, modifiers: modifiers))
    }
}

@MainActor @Observable
public final class GlobalHotkeyModel {
    public private(set) var binding: KeyBinding
    public private(set) var isRegistered = false
    public private(set) var errorMessage: String?

    @ObservationIgnored private let registrar: any GlobalHotkeyRegistering
    @ObservationIgnored private let preferences: SystemPreferences
    @ObservationIgnored private let action: @MainActor () -> Void
    @ObservationIgnored private let catalog: @MainActor () -> [ActionDescriptor]
    @ObservationIgnored private var running = false

    public init(registrar: any GlobalHotkeyRegistering, preferences: SystemPreferences,
                catalog: @escaping @MainActor () -> [ActionDescriptor] = { ActionCatalog.all },
                action: @escaping @MainActor () -> Void) {
        self.registrar = registrar
        self.preferences = preferences
        self.catalog = catalog
        self.action = action
        binding = Self.binding(stored: preferences.globalHotkeyBinding)
    }

    public nonisolated static func binding(stored text: String) -> KeyBinding {
        (try? GlobalHotkeyRules.parse(text).get()) ?? GlobalHotkeyRules.defaultBinding
    }

    isolated deinit {
        if running { registrar.unregister() }
    }

    public var display: String { binding.description }

    public func start() {
        running = true
        register()
    }

    public func stop() {
        running = false
        registrar.unregister()
        isRegistered = false
        errorMessage = nil
    }

    @discardableResult
    public func change(to text: String) -> GlobalHotkeyRules.Problem? {
        switch GlobalHotkeyRules.parse(text, catalog: catalog()) {
        case .failure(let problem):
            return problem
        case .success(let next):
            if next == binding, isRegistered { return nil }
            binding = next
            preferences.globalHotkeyBinding = next.grammar
            if running { register() }
            return nil
        }
    }

    private func register() {
        guard case .success(let hotkey) = GlobalHotkeyRules.hotkey(for: binding, catalog: catalog()) else {
            registrar.unregister()
            isRegistered = false
            errorMessage = "Choose another shortcut."
            return
        }
        let action = self.action
        do {
            try registrar.register(hotkey) { action() }
            isRegistered = true
            errorMessage = nil
        } catch {
            isRegistered = false
            errorMessage = Self.message(error, hotkey: hotkey)
        }
    }

    static func message(_ error: any Error, hotkey: GlobalHotkey) -> String {
        switch error as? GlobalHotkeyError {
        case .unsupportedKey?: "\(hotkey) can't be used. Choose a letter or a digit."
        case .refused(let code)?: "macOS didn't accept \(hotkey) (\(code)). Another app may use it; choose other keys."
        case nil: "macOS didn't accept \(hotkey). Choose other keys."
        }
    }
}
