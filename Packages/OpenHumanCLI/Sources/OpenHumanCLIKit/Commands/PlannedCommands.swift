import ArgumentParser
import Foundation

struct ThreadModify: PlannedCommand {
    static let path = "gmail.thread.modify"
    static let configuration = CommandConfiguration(commandName: "modify", abstract: "Add or remove labels on threads (planned).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Gmail thread ids.") var threadIds: [String] = []
    @Option(name: .long, help: "Labels to add, comma separated.") var add: String?
    @Option(name: .long, help: "Labels to remove, comma separated.") var remove: String?
}

struct BatchGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "batch", abstract: "Batch label changes (planned).", subcommands: [BatchModify.self])
}

struct BatchModify: PlannedCommand {
    static let path = "gmail.batch.modify"
    static let configuration = CommandConfiguration(commandName: "modify", abstract: "Modify labels on many messages (planned).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Message ids, comma separated.") var ids: String?
    @Flag(name: .long, help: "Read ids from stdin.") var stdin = false
    @Option(name: .long, help: "Labels to add, comma separated.") var add: String?
    @Option(name: .long, help: "Labels to remove, comma separated.") var remove: String?
}

struct GmailTrash: PlannedCommand {
    static let path = "gmail.trash"
    static let configuration = CommandConfiguration(commandName: "trash", abstract: "Move threads to Trash (planned; needs --yes under --no-input).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Gmail thread ids.") var threadIds: [String] = []
    @Flag(name: .long, help: "Confirm under --no-input.") var yes = false
}

struct GmailUntrash: PlannedCommand {
    static let path = "gmail.untrash"
    static let configuration = CommandConfiguration(commandName: "untrash", abstract: "Restore threads from Trash (planned).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Gmail thread ids.") var threadIds: [String] = []
}

struct GmailSpam: PlannedCommand {
    static let path = "gmail.spam"
    static let configuration = CommandConfiguration(commandName: "spam", abstract: "Report spam (planned; needs --yes under --no-input).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Gmail thread ids.") var threadIds: [String] = []
    @Flag(name: .long, help: "Confirm under --no-input.") var yes = false
}

struct GmailNotSpam: PlannedCommand {
    static let path = "gmail.not-spam"
    static let configuration = CommandConfiguration(commandName: "not-spam", abstract: "Not spam (planned).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Gmail thread ids.") var threadIds: [String] = []
}

struct LabelsCreate: PlannedCommand {
    static let path = "gmail.labels.create"
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a label (planned).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Label name.") var name: String
}

struct SplitsCreate: PlannedCommand {
    static let path = "gmail.splits.create"
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a split (planned).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Split name.") var name: String
    @Option(name: .long, help: "Rule text.") var rule: String?
}

struct SplitsUpdate: PlannedCommand {
    static let path = "gmail.splits.update"
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a split (planned).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Split name or id.") var split: String
    @Option(name: .long, help: "New name.") var name: String?
    @Option(name: .long, help: "Rule text.") var rule: String?
}

struct SplitsDelete: PlannedCommand {
    static let path = "gmail.splits.delete"
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a split (planned).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Split name or id.") var split: String
}

struct SplitsReorder: PlannedCommand {
    static let path = "gmail.splits.reorder"
    static let configuration = CommandConfiguration(commandName: "reorder", abstract: "Reorder splits (planned).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Split names or ids in the new order.") var splits: [String] = []
}

struct AttachmentsGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "attachments", abstract: "Attachments (planned).", subcommands: [AttachmentsGet.self])
}

struct AttachmentsGet: PlannedCommand {
    static let path = "gmail.attachments.get"
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Copy a downloaded attachment (planned).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Gmail message id.") var messageId: String
    @Argument(help: "Attachment part id.") var partId: String
    @Option(name: .long, help: "Output path.") var out: String?
}

struct GmailHistory: PlannedCommand {
    static let path = "gmail.history"
    static let configuration = CommandConfiguration(commandName: "history", abstract: "Gmail history passthrough (needs network access: deferred).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "History id to start from.") var since: String?
}

struct GmailSend: PlannedCommand {
    static let path = "gmail.send"
    static let configuration = CommandConfiguration(commandName: "send", abstract: "Reserved: the CLI never sends.", shouldDisplay: false)
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var rest: [String] = []
}

struct GmailReplyReserved: PlannedCommand {
    static let path = "gmail.reply"
    static let configuration = CommandConfiguration(commandName: "reply", abstract: "Reserved: the CLI never sends. Use `drafts reply`.", shouldDisplay: false)
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var rest: [String] = []
}

struct GmailReplyAll: PlannedCommand {
    static let path = "gmail.reply-all"
    static let configuration = CommandConfiguration(commandName: "reply-all", abstract: "Reserved: the CLI never sends. Use `drafts reply --all`.", shouldDisplay: false)
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var rest: [String] = []
}

struct GmailForward: PlannedCommand {
    static let path = "gmail.forward"
    static let configuration = CommandConfiguration(commandName: "forward", abstract: "Reserved: the CLI never sends. Use `drafts forward`.", shouldDisplay: false)
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var rest: [String] = []
}

struct GmailFilters: PlannedCommand {
    static let path = "gmail.filters"
    static let configuration = CommandConfiguration(commandName: "filters", abstract: "Not supported: filters and Gmail settings edits.", shouldDisplay: false)
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var rest: [String] = []
}

struct CalendarGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "calendar", abstract: "Calendar (needs network access: deferred).", subcommands: [CalendarEvents.self])
}

struct CalendarEvents: PlannedCommand {
    static let path = "calendar.events"
    static let configuration = CommandConfiguration(commandName: "events", abstract: "Calendar events (needs network access: deferred).")
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var rest: [String] = []
}
