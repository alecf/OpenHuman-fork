import Foundation
import MailActions
import Observation

@MainActor @Observable
public final class ShortcutHelpModel {
    public var filter = ""
    @ObservationIgnored private let sheet: ShortcutSheet

    public init(descriptors: [ActionDescriptor]) {
        sheet = ShortcutSheet(descriptors: descriptors)
    }

    public var sections: [ShortcutSheet.Section] { sheet.filtered(filter) }

    public var allLines: [ShortcutLine] { sheet.sections.flatMap(\.lines) }
}
