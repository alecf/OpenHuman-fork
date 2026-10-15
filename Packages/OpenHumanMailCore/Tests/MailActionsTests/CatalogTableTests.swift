import Foundation
import Testing
@testable import MailActions

@Suite struct CatalogTableTests {
    struct Row: Sendable, CustomStringConvertible {
        let id: ActionID
        let key: String?
        let cli: [String]?
        let module: FeatureModuleID?
        var description: String { id.rawValue }
    }

    static let table: [Row] = [
        Row(id: .markDone, key: "E", cli: ["gmail", "done"], module: nil),
        Row(id: .moveToInbox, key: "⇧E", cli: ["gmail", "move-to-inbox"], module: nil),
        Row(id: .trash, key: "#", cli: ["gmail", "trash"], module: nil),
        Row(id: .toggleStar, key: "S", cli: ["gmail", "star"], module: nil),
        Row(id: .toggleRead, key: "U", cli: ["gmail", "read"], module: nil),
        Row(id: .spam, key: "!", cli: ["gmail", "spam"], module: nil),
        Row(id: .label, key: "L", cli: ["gmail", "thread", "modify"], module: nil),
        Row(id: .createLabel, key: nil, cli: ["gmail", "labels", "create"], module: nil),
        Row(id: .move, key: "V", cli: nil, module: nil),
        Row(id: .unsubscribe, key: "⌘U", cli: nil, module: .unsubscribe),
        Row(id: .snooze, key: ActionCatalog.remindOnH ? "⇧H" : "H", cli: ["gmail", "snooze"], module: .snooze),
        Row(id: .unsnooze, key: nil, cli: ["gmail", "unsnooze"], module: .snooze),
        Row(id: .remind, key: ActionCatalog.remindOnH ? "H" : "⇧H", cli: ["gmail", "remind"], module: .reminders),
        Row(id: .clearReminder, key: nil, cli: ["gmail", "unremind"], module: .reminders),
        Row(id: .goReminders, key: "G H", cli: nil, module: .reminders),
        Row(id: .goScheduled, key: "G Y", cli: nil, module: .sendLater),
        Row(id: .send, key: "⌘↵", cli: nil, module: nil),
        Row(id: .sendLater, key: "⇧⌘L", cli: nil, module: .sendLater),
        Row(id: .cancelSendLater, key: nil, cli: nil, module: .sendLater),
        Row(id: .discardDraft, key: "⌘⌫", cli: nil, module: nil),
        Row(id: .reviewSend, key: "⌘↵", cli: nil, module: .review),
        Row(id: .reviewKeep, key: "A", cli: ["gmail", "review", "approve"], module: .review),
        Row(id: .reviewDiscard, key: "#", cli: ["gmail", "review", "reject"], module: .review),
        Row(id: .reviewSkip, key: "S", cli: nil, module: .review),
        Row(id: .reviewNext, key: "J", cli: nil, module: .review),
        Row(id: .reviewPrevious, key: "K", cli: nil, module: .review),
        Row(id: .reviewEdit, key: "↵", cli: nil, module: .review),
        Row(id: .goReview, key: "G R", cli: ["gmail", "review", "open"], module: .review),
        Row(id: .aiAskInbox, key: "⌘J", cli: nil, module: .ai),
        Row(id: .search, key: "/", cli: ["gmail", "search"], module: nil),
        Row(id: .compose, key: "C", cli: nil, module: nil),
        Row(id: .alwaysImportantSender, key: "+", cli: nil, module: .importance),
        Row(id: .neverImportantDomain, key: "-", cli: nil, module: .importance),
    ]

    @Test(arguments: table) func everyTableIDExistsAsSpecified(_ row: Row) throws {
        let descriptor = try #require(ActionCatalog.descriptor(row.id), "\(row.id) is missing from the catalog")
        #expect(descriptor.shortcutHint == row.key)
        #expect(descriptor.cliCommand == row.cli)
        #expect(descriptor.module == row.module)
    }

    @Test func theMUR1ActionListIsInThePalette() {
        let mur1: [ActionID] = [.markDone, .trash, .spam, .toggleStar, .toggleRead, .label, .removeLabel, .move,
                                .snooze, .remind, .unsubscribe, .undo, .redo, .toggleCheck, .extendSelectionDown,
                                .checkAll, .alwaysImportantSender, .alwaysImportantDomain, .neverImportant,
                                .neverImportantDomain, .removeFromSplit, .notAPitch, .explainPlacement, .search,
                                .searchGmail, .compose,
                                .shortcutHelp]
        for id in mur1 {
            let descriptor = ActionCatalog.descriptor(id)
            #expect(descriptor != nil, "\(id) is missing")
            #expect(descriptor?.appearsInPalette == true, "\(id) is not in the palette")
        }
        #expect(ActionCatalog.descriptor(.searchGmail)?.effect == .view)
        #expect(ActionCatalog.descriptor(.commandPalette)?.shortcutHint == "⌘K")
        #expect(ActionCatalog.descriptor(.commandPalette)?.activeWhileTyping == true)
        #expect(ActionCatalog.descriptor(.trash)?.defaultBindings.map(\.description) == ["#", "⌫"])
    }

    @Test func importanceActionsBelongToTheirModuleAndChangeMail() {
        for id in [ActionID.alwaysImportantSender, .alwaysImportantDomain, .neverImportant, .neverImportantDomain,
                   .removeFromSplit, .notAPitch] {
            #expect(ActionCatalog.descriptor(id)?.module == .importance)
            #expect(ActionCatalog.descriptor(id)?.changesMail == true)
        }
        #expect(ActionCatalog.descriptor(.explainPlacement)?.changesMail == false, "explaining only reads")
    }

    @Test func effectsDriveKeyRepeat() {
        for descriptor in ActionCatalog.all where descriptor.effect != .view {
            #expect(!descriptor.allowsKeyRepeat, "\(descriptor.id)")
        }
        #expect(ActionCatalog.descriptor(.send)?.effect == .external)
        #expect(ActionCatalog.descriptor(.unsubscribe)?.effect == .external)
        #expect(ActionCatalog.descriptor(.sendLater)?.effect == .external)
        #expect(ActionCatalog.descriptor(.undo)?.allowsMenuKeyEquivalent == false)
        #expect(ActionCatalog.descriptor(.checkAll)?.allowsMenuKeyEquivalent == false, "⌘A stays Select All in fields")
    }

    static let cliCommandPaths: Set<String> = [
        "gmail.search", "gmail.list", "gmail.inbox", "gmail.get", "gmail.thread.get", "gmail.thread.modify",
        "gmail.batch.modify", "gmail.done", "gmail.move-to-inbox", "gmail.read", "gmail.unread", "gmail.star",
        "gmail.unstar", "gmail.trash", "gmail.untrash", "gmail.spam", "gmail.not-spam", "gmail.snooze",
        "gmail.unsnooze", "gmail.remind", "gmail.unremind", "gmail.labels.list", "gmail.labels.create",
        "gmail.counts", "gmail.splits.list", "gmail.splits.show", "gmail.drafts.list", "gmail.drafts.get",
        "gmail.drafts.create", "gmail.drafts.update", "gmail.drafts.reply", "gmail.drafts.forward",
        "gmail.drafts.delete", "gmail.review.list", "gmail.review.show", "gmail.review.approve",
        "gmail.review.reject", "gmail.review.open",
    ]

    @Test func cliPathsAreCommandsOfTheCLITree() {
        for descriptor in ActionCatalog.all {
            guard let path = descriptor.cliCommand else { continue }
            #expect(Self.cliCommandPaths.contains(path.joined(separator: ".")), "\(descriptor.id): \(path)")
            #expect(path.first == "gmail")
        }
        for id in [ActionID.send, .reviewSend, .sendLater] { #expect(ActionCatalog.descriptor(id)?.cliCommand == nil) }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: CatalogTableTests.schemaURL.path)))
    func cliPathsAreInThePublishedSchema() throws {
        let data = try Data(contentsOf: Self.schemaURL)
        let text = String(decoding: data, as: UTF8.self)
        for descriptor in ActionCatalog.all {
            guard let path = descriptor.cliCommand?.joined(separator: ".") else { continue }
            #expect(text.contains("\"\(path)\""), "\(descriptor.id): \(path) is not in docs/cli/schema.json")
        }
    }

    static var schemaURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/cli/schema.json")
    }
}
