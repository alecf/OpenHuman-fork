import Foundation
import MailActions
import Observation

@MainActor @Observable
public final class ShortcutsSettingsModel {
    public var searchText = ""
    public let editor: KeymapEditorModel?

    @ObservationIgnored private let fixedSheet: ShortcutSheet?
    @ObservationIgnored private let registry: ActionRegistry?

    public init(descriptors: [ActionDescriptor]) {
        fixedSheet = ShortcutSheet(descriptors: descriptors)
        registry = nil
        editor = nil
    }

    public init(environment: AppEnvironment) {
        fixedSheet = nil
        registry = environment.actions
        editor = KeymapEditorModel(registry: environment.actions, store: environment.keymapStore)
    }

    public var sheet: ShortcutSheet {
        if let registry { return ShortcutSheet(descriptors: registry.descriptors) }
        return fixedSheet ?? ShortcutSheet(descriptors: [])
    }

    public var sections: [ShortcutSheet.Section] {
        sheet.filtered(searchText).map { section in
            let reviewOnly: (ShortcutLine) -> Bool = { line in !line.places.isEmpty && line.places.allSatisfy { $0 == Self.reviewPlace } }
            let lines = section.lines.filter { !reviewOnly($0) } + section.lines.filter(reviewOnly)
            return ShortcutSheet.Section(title: section.title, lines: lines)
        }
    }

    public static let unassignedTitle = "No shortcut yet"

    public var unassignedLines: [ShortcutLine] {
        guard let registry, let editor else { return [] }
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return registry.descriptors.compactMap { descriptor in
            guard descriptor.defaultBindings.isEmpty, descriptor.appearsInPalette, editor.canChange(descriptor.id),
                  !descriptor.scopes.subtracting([.palette]).isEmpty else { return nil }
            guard needle.isEmpty || descriptor.title.lowercased().contains(needle) else { return nil }
            return ShortcutLine(action: descriptor.id, title: descriptor.title, keys: [], places: [])
        }
    }

    private static let reviewPlace = ShortcutLine.placeName(of: [.review])

    public var cheatSheetText: String {
        var out = "OpenHuman Mail: keyboard shortcuts\n"
        for section in sheet.sections where !section.lines.isEmpty {
            out += "\n\(section.title)\n"
            for line in section.lines { out += "  \(line.keys.joined(separator: " or "))   \(line.title)\n" }
        }
        return out
    }
}
