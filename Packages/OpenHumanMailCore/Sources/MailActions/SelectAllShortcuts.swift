public enum SelectAllShortcuts {
    public static let commandA: ActionID = .checkFromHere
    public static let commandShiftA: ActionID = .checkAll

    public static func bindings(for id: ActionID) -> [KeyBinding] {
        switch id {
        case commandA: [.chord("a", .command)]
        case commandShiftA: [.chord("A", .command)]
        default: []
        }
    }

    public typealias TipRow = ShortcutTip.Row

    public static func tipRows(_ descriptors: [ActionDescriptor] = ActionCatalog.all) -> [TipRow] {
        [TipRow(title: "Select All", keycaps: keycaps(for: .checkAll, in: descriptors)),
         TipRow(title: "Select All From Here", keycaps: keycaps(for: .checkFromHere, in: descriptors))]
            .filter { !$0.keycaps.isEmpty }
    }

    public static func keycaps(for id: ActionID, in descriptors: [ActionDescriptor] = ActionCatalog.all) -> [String] {
        descriptors.first { $0.id == id }.map(ShortcutTip.keycaps) ?? []
    }

    public static func tip(_ descriptors: [ActionDescriptor] = ActionCatalog.all) -> ShortcutTip? {
        let rows = tipRows(descriptors)
        return rows.isEmpty ? nil : ShortcutTip(rows: rows)
    }

    public static func spoken(_ keycaps: [String]) -> String {
        keycaps.map { spokenNames[$0] ?? $0 }.joined(separator: " ")
    }

    static let spokenNames: [String: String] = [
        "⌘": "Command", "shift": "Shift", "⌥": "Option", "⌃": "Control", "Esc": "Escape", "↵": "Return", "⇥": "Tab",
        "⌫": "Delete", "↑": "Up Arrow", "↓": "Down Arrow", "←": "Left Arrow", "→": "Right Arrow",
    ]
}

extension KeyBinding {
    public var separatedKeycaps: [String] {
        guard let chord = chords.first else { return [] }
        var modifiers = chord.modifiers
        var key: String
        switch chord.key {
        case .character(let c):
            if c.count == 1, let scalar = c.unicodeScalars.first, scalar.properties.isUppercase { modifiers.insert(.shift) }
            key = c.uppercased()
        case .named(let named):
            key = Self.symbol(named)
        }
        var caps: [String] = []
        if modifiers.contains(.control) { caps.append("⌃") }
        if modifiers.contains(.option) { caps.append("⌥") }
        if modifiers.contains(.command) { caps.append("⌘") }
        if modifiers.contains(.shift) { caps.append("shift") }
        if key.isEmpty { key = description }
        return caps + [key] + chords.dropFirst().map { Self.display($0) }
    }
}
