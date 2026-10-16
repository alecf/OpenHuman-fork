public struct ShortcutTip: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let title: String
        public let keycaps: [String]

        public init(title: String, keycaps: [String]) {
            self.title = title
            self.keycaps = keycaps
        }
    }

    public let rows: [Row]
    public let hint: String?

    public init(rows: [Row], hint: String? = nil) {
        self.rows = rows
        self.hint = hint.flatMap { $0.isEmpty ? nil : $0 }
    }

    public init(title: String, keycaps: [String] = [], hint: String? = nil) {
        self.init(rows: [Row(title: title, keycaps: keycaps)], hint: hint)
    }

    public static func action(_ id: ActionID, in descriptors: [ActionDescriptor], title: String? = nil,
                              hint: String? = nil) -> ShortcutTip? {
        let descriptor = descriptors.first { $0.id == id }
        guard let name = title ?? descriptor.map({ displayTitle($0.title) }), !name.isEmpty else { return nil }
        return ShortcutTip(title: name, keycaps: descriptor.map(keycaps) ?? [], hint: hint)
    }

    public static func keycaps(_ descriptor: ActionDescriptor) -> [String] {
        descriptor.defaultBindings.first?.separatedKeycaps ?? []
    }

    public static func keycaps(symbols: String) -> [String] {
        var modifiers: Set<Character> = []
        var key = Substring(symbols)
        while key.count > 1, let first = key.first, Self.modifierOrder.contains(first) {
            modifiers.insert(first)
            key = key.dropFirst()
        }
        let caps = Self.modifierOrder.filter(modifiers.contains).map { $0 == "⇧" ? "shift" : String($0) }
        return key.isEmpty ? caps : caps + [key.uppercased()]
    }

    private static let modifierOrder: [Character] = ["⌃", "⌥", "⌘", "⇧"]

    public static func displayTitle(_ title: String) -> String {
        var text = Substring(title)
        while let last = text.last, last == "…" || last == "." || last == " " { text = text.dropLast() }
        return String(text)
    }

    public var title: String { rows.first?.title ?? "" }

    public var keycaps: [String] { rows.first?.keycaps ?? [] }

    public var spokenDetail: String {
        let keys = rows.count == 1 ? [SelectAllShortcuts.spoken(keycaps)] : rows.map { row in
            row.keycaps.isEmpty ? row.title : "\(row.title): \(SelectAllShortcuts.spoken(row.keycaps))"
        }
        return (keys + [hint].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: ". ")
    }
}
