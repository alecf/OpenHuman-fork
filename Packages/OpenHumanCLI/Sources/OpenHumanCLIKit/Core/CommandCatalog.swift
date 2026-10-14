import Foundation

public enum WriteKind: String, Sendable {
    case none
    case localData
    case mail
    case storedItems
}

public enum Reserved: Sendable, Equatable {
    case send(hint: String)
    case notSupported
}

public struct CommandMeta: Sendable {
    public var path: String
    public var aliases: [String] = []
    public var priority: String
    public var stage: String
    public var implemented: Bool
    public var writes: WriteKind = .none
    public var network: Bool = false
    public var confirm: Bool = false
    public var output: String
    public var plain: [String] = []
    public var reserved: Reserved?
    public var usesAccounts: Bool = false
}

public enum CommandCatalog {
    static func m(_ path: String, _ priority: String, _ stage: String, _ output: String, impl: Bool = true,
                  writes: WriteKind = .none, net: Bool = false, confirm: Bool = false, plain: [String] = [],
                  aliases: [String] = [], accounts: Bool = false) -> CommandMeta {
        CommandMeta(path: path, aliases: aliases, priority: priority, stage: stage, implemented: impl, writes: writes,
                    network: net, confirm: confirm, output: output, plain: plain, usesAccounts: accounts)
    }

    static let threadColumns = ["threadId", "account", "lastMessageAt", "unread", "from", "subject", "snippet", "link"]
    static let draftColumns = ["draftId", "account", "origin", "review", "state", "to", "subject", "reviewLink"]
    static let opColumns = ["status", "operationIds", "threadIds"]
    static let snippetColumns = ["snippetId", "name", "shortcut", "account", "subject", "variables", "useCount"]

    public static let entries: [CommandMeta] = {
        var list: [CommandMeta] = [
            m("accounts.list", "P1", "1", "Account[]", plain: ["email", "alias", "status", "default", "syncedAt"]),
            m("accounts.add", "P1", "2", "Account", impl: false, writes: .localData, net: true),
            m("accounts.remove", "P1", "2", "Account", impl: false, writes: .localData, net: true, confirm: true),
            m("accounts.alias", "P1", "1", "Account", writes: .localData, plain: ["email", "alias"]),
            m("accounts.default", "P1", "1", "Account", writes: .localData, plain: ["email", "default"]),
            m("auth.status", "P1", "1", "Account[]", plain: ["email", "status", "scopes", "syncPhase", "syncedAt"]),
            m("auth.login", "P1", "2", "Account", impl: false, writes: .localData, net: true),
            m("auth.logout", "P1", "2", "Account", impl: false, writes: .localData, net: true, confirm: true),
            m("sync.run", "P1", "1", "SyncRequest", writes: .localData, plain: ["requested", "ownerPid", "dataAgeSeconds"]),
            m("sync.status", "P1", "1", "SyncStatus[]", plain: ["email", "phase", "lastSuccessAt", "pendingOperations", "failedOperations"]),
            m("sync.watch", "P3", "2", "SyncEvent[]", impl: false, net: true),

            m("gmail.search", "P1", "1", "ThreadSummary[]", plain: threadColumns, accounts: true),
            m("gmail.list", "P1", "1", "ThreadSummary[]", plain: threadColumns, accounts: true),
            m("gmail.inbox", "P1", "1", "ThreadSummary[]", plain: threadColumns, accounts: true),
            m("gmail.get", "P1", "1", "Message", plain: ["messageId", "threadId", "date", "from", "subject", "link"], accounts: true),
            m("gmail.thread.get", "P1", "1", "ThreadDetail", plain: ["messageId", "threadId", "date", "from", "subject", "link"], accounts: true),
            m("gmail.thread.modify", "P2", "later", "OperationResult", impl: false, writes: .mail),
            m("gmail.batch.modify", "P2", "later", "OperationResult", impl: false, writes: .mail),
            m("gmail.done", "P1", "1b", "OperationResult", writes: .mail, plain: opColumns, aliases: ["gmail.archive"], accounts: true),
            m("gmail.move-to-inbox", "P1", "1b", "OperationResult", writes: .mail, plain: opColumns, aliases: ["gmail.unarchive"], accounts: true),
            m("gmail.read", "P1", "1b", "OperationResult", writes: .mail, plain: opColumns, accounts: true),
            m("gmail.unread", "P1", "1b", "OperationResult", writes: .mail, plain: opColumns, accounts: true),
            m("gmail.star", "P1", "1b", "OperationResult", writes: .mail, plain: opColumns, accounts: true),
            m("gmail.unstar", "P1", "1b", "OperationResult", writes: .mail, plain: opColumns, accounts: true),
            m("gmail.trash", "P2", "later", "OperationResult", impl: false, writes: .mail, confirm: true),
            m("gmail.untrash", "P2", "later", "OperationResult", impl: false, writes: .mail),
            m("gmail.spam", "P2", "later", "OperationResult", impl: false, writes: .mail, confirm: true),
            m("gmail.not-spam", "P2", "later", "OperationResult", impl: false, writes: .mail),
            m("gmail.snooze", "P1", "1b", "OperationResult", writes: .mail, plain: opColumns, accounts: true),
            m("gmail.unsnooze", "P1", "1b", "OperationResult", writes: .mail, plain: opColumns, accounts: true),
            m("gmail.remind", "P1", "1b", "OperationResult", writes: .mail, plain: opColumns, accounts: true),
            m("gmail.unremind", "P1", "1b", "OperationResult", writes: .mail, plain: opColumns, accounts: true),
            m("gmail.labels.list", "P1", "1", "Label[]", plain: ["labelId", "account", "name", "type", "totalThreads", "unreadThreads"], accounts: true),
            m("gmail.labels.create", "P2", "later", "OperationResult", impl: false, writes: .mail),
            m("gmail.counts", "P1", "1", "Counts[]", plain: ["account", "inboxUnread", "drafts", "pendingReview", "failedOperations"], accounts: true),
            m("gmail.splits.list", "P1", "1", "Split[]", plain: ["splitId", "account", "name", "unreadThreads", "totalThreads"], accounts: true),
            m("gmail.splits.show", "P1", "1", "ThreadSummary[]", plain: threadColumns, accounts: true),
            m("gmail.splits.create", "P2", "later", "Split", impl: false, writes: .localData),
            m("gmail.splits.update", "P2", "later", "Split", impl: false, writes: .localData),
            m("gmail.splits.delete", "P2", "later", "Split", impl: false, writes: .localData),
            m("gmail.splits.reorder", "P2", "later", "Split[]", impl: false, writes: .localData),
            m("gmail.drafts.list", "P1", "1b", "Draft[]", plain: draftColumns, accounts: true),
            m("gmail.drafts.get", "P1", "1b", "Draft", plain: draftColumns, aliases: ["gmail.drafts.show"], accounts: true),
            m("gmail.drafts.create", "P1", "1b", "Draft", writes: .mail, plain: draftColumns, accounts: true),
            m("gmail.drafts.update", "P1", "1b", "Draft", writes: .mail, plain: draftColumns, accounts: true),
            m("gmail.drafts.reply", "P1", "1b", "Draft", writes: .mail, plain: draftColumns, accounts: true),
            m("gmail.drafts.forward", "P2", "1c", "Draft", writes: .mail, plain: draftColumns, accounts: true),
            m("gmail.drafts.delete", "P2", "1c", "OperationResult", writes: .mail, confirm: true,
              plain: ["status", "draftId", "operationIds"], accounts: true),
            m("gmail.review.list", "P1", "1b", "Draft[]", plain: draftColumns, accounts: true),
            m("gmail.review.show", "P2", "1c", "Draft", plain: draftColumns, accounts: true),
            m("gmail.review.approve", "P2", "1c", "Draft[]", writes: .mail, plain: draftColumns, accounts: true),
            m("gmail.review.reject", "P2", "1c", "Draft[]", writes: .mail, plain: draftColumns, accounts: true),
            m("gmail.review.open", "P2", "1c", "Link", plain: ["link", "count", "opened"], accounts: true),
            m("gmail.snippets.list", "P2", "1c", "Snippet[]", plain: snippetColumns),
            m("gmail.snippets.show", "P2", "1c", "Snippet", plain: snippetColumns),
            m("gmail.snippets.render", "P2", "1c", "RenderedSnippet", plain: ["name", "subject", "bodyText", "unresolved"]),
            m("gmail.snippets.add", "P2", "1c", "Snippet", writes: .storedItems, plain: snippetColumns),
            m("gmail.snippets.delete", "P2", "1c", "Snippet", writes: .storedItems, confirm: true, plain: snippetColumns),
            m("gmail.snippets.export", "P2", "1c", "SnippetFile", plain: ["format", "version", "count", "path"]),
            m("gmail.snippets.import", "P2", "1c", "SnippetImport", writes: .storedItems, confirm: true,
              plain: ["status", "toAdd", "toReplace", "shortcutsDropped"]),
            m("gmail.undo", "P2", "1c", "OperationResult", writes: .mail, plain: opColumns, accounts: true),
            m("gmail.attachments.get", "P2", "later", "Attachment", impl: false),
            m("gmail.history", "P3", "2", "History", impl: false, net: true),

            m("calendar.events", "P5", "2", "Event[]", impl: false, net: true),

            m("link.thread", "P1", "1", "Link", plain: ["link"]),
            m("link.draft", "P1", "1", "Link", plain: ["link"]),
            m("link.review", "P1", "1b", "Link", plain: ["link"]),
            m("link.search", "P1", "1", "Link", plain: ["link"]),
            m("link.compose", "P1", "1", "Link", plain: ["link"]),
            m("schema", "P1", "1", "Schema"),
            m("doctor", "P1", "1", "Check[]", plain: ["name", "status", "detail"]),
            m("config.get", "P1", "1", "Setting", plain: ["key", "value"]),
            m("config.list", "P1", "1", "Setting[]", plain: ["key", "value", "safety"]),
            m("config.set", "P1", "1", "Setting", writes: .localData, plain: ["key", "value"]),
            m("mcp", "P3", "1c", "McpServer", plain: ["name", "group", "path", "writes"]),
        ]
        let send = "Create a draft with `openhuman gmail drafts create` and send it from OpenHuman Mail."
        for name in ["gmail.send", "gmail.reply", "gmail.reply-all", "gmail.forward", "gmail.drafts.send"] {
            var meta = m(name, "P1", "later", "Error", impl: false)
            meta.reserved = .send(hint: send)
            list.append(meta)
        }
        var filters = m("gmail.filters", "P1", "later", "Error", impl: false)
        filters.reserved = .notSupported
        list.append(filters)
        return list
    }()

    private static let index: [String: CommandMeta] = {
        var map: [String: CommandMeta] = [:]
        for meta in entries { map[meta.path] = meta; for alias in meta.aliases { map[alias] = meta } }
        return map
    }()

    public static func meta(for path: String) -> CommandMeta? { index[path] }
}
