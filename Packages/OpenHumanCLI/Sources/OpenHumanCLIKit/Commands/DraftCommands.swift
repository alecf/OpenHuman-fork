import ArgumentParser
import Foundation
import OpenHumanCore
import OpenHumanLinks
import OpenHumanMIME
import OpenHumanStore
import OpenHumanSync

enum DraftInput {
    static let maxBodyBytes = 1_048_576

    static func addresses(_ values: [String], field: String) throws -> [EmailAddress] {
        var out: [EmailAddress] = []
        for value in values {
            for part in value.split(whereSeparator: { $0 == "," || $0 == ";" }) {
                let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                var name: String?
                var email = text
                if let open = text.lastIndex(of: "<"), text.hasSuffix(">") {
                    email = String(text[text.index(after: open)..<text.index(before: text.endIndex)]).trimmingCharacters(in: .whitespaces)
                    let n = String(text[..<open]).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
                    name = n.isEmpty ? nil : n
                }
                guard valid(email) else { throw CLIError.usage("An address in --\(field) is not valid.", code: "bad_address") }
                if let name, name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                    throw CLIError.usage("An address in --\(field) is not valid.", code: "bad_address")
                }
                out.append(EmailAddress(name: name, email: email))
            }
        }
        guard out.count <= LinkGrammar.maxRecipients else { throw CLIError.usage("Too many recipients in --\(field).", code: "too_many_recipients") }
        return out
    }

    static func valid(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), email.utf8.count <= 254 else { return false }
        return !email.unicodeScalars.contains { $0.properties.generalCategory == .control || $0 == " " || $0 == "<" || $0 == ">" || $0 == "," || $0 == ";" || $0 == "\"" }
    }

    static func subject(_ text: String) throws -> String {
        guard text.count <= LinkGrammar.maxSubjectCharacters, !text.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            throw CLIError.usage("The subject must be one line of at most 998 characters.", code: "bad_subject")
        }
        return text
    }

    static func body(file: String?, inline: String?, _ ctx: CLIContext) throws -> String? {
        if file != nil, inline != nil { throw CLIError.usage("Pass --body-file or --body, not both.", code: "body_conflict") }
        var text: String
        if let file {
            if file == "-" { text = ctx.env.readStdin() } else {
                let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
                guard let data = try? Data(contentsOf: url) else { throw CLIError.usage("Cannot read the --body-file.", code: "bad_body_file") }
                guard data.count <= maxBodyBytes else { throw CLIError.usage("The body is larger than 1 MiB.", code: "body_too_large") }
                text = String(decoding: data, as: UTF8.self)
            }
        } else if let inline {
            text = inline == "-" ? ctx.env.readStdin() : inline
        } else { return nil }
        guard text.utf8.count <= maxBodyBytes else { throw CLIError.usage("The body is larger than 1 MiB.", code: "body_too_large") }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        return text
    }

    static func html(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>\n")
        return "<div dir=\"ltr\">\(escaped)</div>"
    }
}

enum DraftSupport {
    static func find(_ id: String, _ ctx: CLIContext) throws -> DraftListItem {
        let store = try ctx.store()
        if let draft = try store.draft(DraftID(id)) { return draft }
        for account in try ctx.lookupAccounts() {
            if let draft = try store.draft(account: account.id, gmailDraftID: GmailDraftID(id)) { return draft }
        }
        throw CLIError.notFound("The draft", id: id)
    }

    static func uploadOps(_ store: MailStore, _ draft: DraftListItem) throws -> [OperationID] {
        try store.operations(account: draft.accountID, statuses: [.pending, .inFlight, .succeeded], limit: 500).compactMap { op in
            if case .upsertDraft(let id, _) = op.payload, id == draft.id { return op.id }
            return nil
        }
    }

    static func deleteOps(_ store: MailStore, _ draft: DraftListItem) throws -> [OperationID] {
        try store.operations(account: draft.accountID, statuses: [.pending, .inFlight, .succeeded], limit: 500).compactMap { op in
            if case .deleteDraft(let id, _) = op.payload, id == draft.id { return op.id }
            return nil
        }
    }

    static func account(of draft: DraftListItem, _ ctx: CLIContext) throws -> AccountItem {
        guard let account = try ctx.store().accounts().first(where: { $0.id == draft.accountID }) else {
            throw CLIError.notFound("The account")
        }
        return account
    }

    static func requireAgentOwned(_ draft: DraftListItem) throws {
        guard draft.origin != .user else {
            throw CLIError.policy("not_agent_draft", "Only drafts created by an agent or the CLI can be changed here.")
        }
    }

    static func messageAccount(_ messageID: String, _ ctx: CLIContext) throws -> AccountItem {
        let store = try ctx.store()
        var hits: [AccountItem] = []
        for account in try ctx.lookupAccounts() where try store.message(account: account.id, gmailMessageID: GmailMessageID(messageID)) != nil {
            hits.append(account)
        }
        if hits.count > 1 { throw CLIError.usage("That id exists in several accounts. Pass --account <email>.", code: "ambiguous_account") }
        guard let account = hits.first else { throw CLIError.notFound("The message", id: messageID) }
        return account
    }

    static let queuedNote = "Saved locally. OpenHuman Mail adds it to your Gmail Drafts for review when it runs."

    static func settle(_ ctx: CLIContext, engine: MailEngine, accounts: [AccountItem], ids: [OperationID], wait: Bool,
                       note: String) async -> (status: String, exit: CLIStatus, notes: [String]) {
        if ids.isEmpty { return ("succeeded", .ok, []) }
        guard ctx.appIsRunning(accounts), wait else { return ("queued", .queued, [note]) }
        let statuses = await engine.waitForOperations(ids, timeout: ctx.timeout)
        if statuses.values.contains(where: { $0 == .failed || $0 == .cancelled }) {
            let store = try? ctx.store()
            if ids.contains(where: { ((try? store?.operation($0)) ?? nil)?.lastErrorCode == "not_applied_outside_app" }) {
                return ("refused", .policyBlocked, ["OpenHuman Mail did not apply this to Gmail: it keeps changes from the CLI on this Mac until you review them there."])
            }
            return ("failed", .failure, ["The app could not apply the change. Run `openhuman sync status` for details."])
        }
        if statuses.values.allSatisfy({ $0 == .succeeded }) { return ("succeeded", .ok, []) }
        return ("queued", .queued, ["Queued; the app has not confirmed it within the timeout."])
    }

    static func result(_ ctx: CLIContext, engine: MailEngine, mapper: Mapper, draft: DraftListItem, accounts: [AccountItem],
                       wait: Bool) async throws -> CommandResult {
        let ops = try uploadOps(try ctx.store(), draft)
        let (status, exit, notes) = await settle(ctx, engine: engine, accounts: accounts, ids: ops, wait: wait, note: queuedNote)
        var value = mapper.draft(draft)
        if case .object(var fields) = value {
            fields["sent"] = .bool(false)
            fields["status"] = .string(status)
            fields["operationIds"] = .array(ops.map { .int(Int($0.rawValue)) })
            value = .object(fields)
        }
        return CommandResult(data: value, table: Table(columns: CommandCatalog.draftColumns, rows: [mapper.draftRow(draft)]),
                             status: exit, notes: notes + ["Draft saved for review: \(mapper.draftLink(draft)). Send it from OpenHuman Mail."])
    }

    static func dryRun(_ content: DraftContent, mode: ComposeMode, account: AccountItem, note: String?, extra: [String: OutValue] = [:]) -> CommandResult {
        func addrs(_ a: [EmailAddress]) -> OutValue { .array(a.map { obj(["name": OutValue.optUntrusted($0.name), "email": .string($0.email)]) }) }
        var fields: [String: OutValue] = [
            "dryRun": .bool(true), "sent": .bool(false), "account": .string(account.email), "mode": .string(mode.rawValue),
            "to": addrs(content.to), "cc": addrs(content.cc), "subject": .untrusted(content.subject),
            "bodyText": .body(content.bodyText ?? ""), "envelopeBcc": addrs(content.bcc),
            "wouldQueue": .strings(["upsert_draft"]),
        ]
        if let note { fields["agentNote"] = .untrusted(note) }
        for (k, v) in extra { fields[k] = v }
        return CommandResult(data: .object(fields),
                             table: Table(columns: ["dryRun", "account", "mode", "subject"], rows: [[.bool(true), .string(account.email), .string(mode.rawValue), .untrusted(content.subject)]]))
    }
}

struct DraftsGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drafts", abstract: "Agent drafts for review. The CLI never sends.",
        subcommands: [DraftsList.self, DraftsGet.self, DraftsCreate.self, DraftsUpdate.self, DraftsReply.self,
                      DraftsForward.self, DraftsDelete.self, DraftsSend.self])
}

enum ReviewFilter: String, ExpressibleByArgument, CaseIterable { case pending, all }
enum OriginFilter: String, ExpressibleByArgument, CaseIterable { case agent, user, cli }

struct DraftsList: CLICommand {
    static let path = "gmail.drafts.list"
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Drafts in the cache.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "pending or all (default).") var review: ReviewFilter = .all
    @Option(name: .long, help: "agent, user or cli.") var origin: OriginFilter?

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let store = try ctx.store()
        let accounts = try ctx.accounts(.oneOrAll)
        ctx.noteReauth(accounts)
        let mapper = try Mapper(store: store)
        var drafts: [DraftListItem] = []
        for account in accounts {
            drafts += try store.drafts(account: account.id, states: [.editing, .scheduled, .sending, .failed], limit: 500)
        }
        drafts = drafts.filter { d in
            (review == .all || d.reviewState == .pending) && (origin.map { d.origin.rawValue == $0.rawValue } ?? true)
        }
        let values = drafts.map(mapper.draft)
        let agent = drafts.filter { $0.origin != .user }.prefix(LinkGrammar.maxReviewIDs)
        return CommandResult(data: obj(["drafts": .array(values), "reviewLink": agent.isEmpty ? nil : .string(mapper.reviewLink(Array(agent)))]),
                             items: values, table: Table(columns: CommandCatalog.draftColumns, rows: drafts.map(mapper.draftRow)))
    }
}

struct DraftsGet: CLICommand {
    static let path = "gmail.drafts.get"
    static let configuration = CommandConfiguration(commandName: "get", abstract: "One draft by local id or Gmail draft id.",
                                                    aliases: ["show"])
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Draft id (local UUID or Gmail draft id).") var draftId: String

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let draft = try DraftSupport.find(draftId, ctx)
        let mapper = try Mapper(store: try ctx.store())
        return CommandResult(data: mapper.draft(draft), table: Table(columns: CommandCatalog.draftColumns, rows: [mapper.draftRow(draft)]))
    }
}

struct DraftsCreate: CLICommand {
    static let path = "gmail.drafts.create"
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a draft for review. It is never sent from the CLI.")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Option(name: .long, help: "Recipient (repeatable, or comma separated).") var to: [String] = []
    @Option(name: .long, help: "Cc (repeatable).") var cc: [String] = []
    @Option(name: .long, help: "Bcc (repeatable).") var bcc: [String] = []
    @Option(name: .long, help: "Subject.") var subject: String
    @Option(name: .long, help: "Body text file (`-` for stdin).") var bodyFile: String?
    @Option(name: .long, help: "Body text, or `-` for stdin.") var body: String?
    @Option(name: .long, help: "A note for the reviewer.") var note: String?

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let recipients = try DraftInput.addresses(to, field: "to")
        guard !recipients.isEmpty else { throw CLIError.usage("At least one --to is required.", code: "recipient_required") }
        guard let text = try DraftInput.body(file: bodyFile, inline: body, ctx) else {
            throw CLIError.usage("A body is required: --body-file F or --body -.", code: "body_required")
        }
        let content = DraftContent(to: recipients, cc: try DraftInput.addresses(cc, field: "cc"), bcc: try DraftInput.addresses(bcc, field: "bcc"),
                                   subject: try DraftInput.subject(subject), bodyHTML: DraftInput.html(text), bodyText: text, attachments: [])
        let account = try ctx.accounts(.one)[0]
        try ctx.requireWritable(account)
        if ctx.dryRun { return DraftSupport.dryRun(content, mode: .new, account: account, note: note) }
        let engine = try ctx.engine()
        let id = try await engine.createAgentDraft(account: account.id, mode: .new, replyTo: nil, content: content, note: note, origin: .cli)
        let store = try ctx.store()
        guard let draft = try store.draft(id) else { throw CLIError.notFound("The draft") }
        return try await DraftSupport.result(ctx, engine: engine, mapper: Mapper(store: store), draft: draft, accounts: [account], wait: write.wait)
    }
}

struct DraftsReply: CLICommand {
    static let path = "gmail.drafts.reply"
    static let configuration = CommandConfiguration(commandName: "reply", abstract: "Create a reply draft for review. It is never sent from the CLI.")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Gmail message id to reply to.") var messageId: String
    @Flag(name: .long, help: "Reply to all.") var all = false
    @Option(name: .long, help: "Body text file (`-` for stdin).") var bodyFile: String?
    @Option(name: .long, help: "Body text, or `-` for stdin.") var body: String?
    @Option(name: .long, help: "A note for the reviewer.") var note: String?

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        guard let text = try DraftInput.body(file: bodyFile, inline: body, ctx) else {
            throw CLIError.usage("A body is required: --body-file F or --body -.", code: "body_required")
        }
        let store = try ctx.store()
        var hits: [AccountItem] = []
        for account in try ctx.lookupAccounts() where try store.message(account: account.id, gmailMessageID: GmailMessageID(messageId)) != nil {
            hits.append(account)
        }
        if hits.count > 1 { throw CLIError.usage("That id exists in several accounts. Pass --account <email>.", code: "ambiguous_account") }
        guard let account = hits.first else { throw CLIError.notFound("The message", id: messageId) }
        try ctx.requireWritable(account)
        let mode: ComposeMode = all ? .replyAll : .reply
        let content = DraftContent(to: [], cc: [], bcc: [], subject: "", bodyHTML: DraftInput.html(text), bodyText: text, attachments: [])
        if ctx.dryRun { return DraftSupport.dryRun(content, mode: mode, account: account, note: note, extra: ["replyTo": .string(messageId)]) }
        let engine = try ctx.engine()
        let id = try await engine.createAgentDraft(account: account.id, mode: mode, replyTo: GmailMessageID(messageId), content: content,
                                                   note: note, origin: .cli)
        guard let draft = try store.draft(id) else { throw CLIError.notFound("The draft") }
        return try await DraftSupport.result(ctx, engine: engine, mapper: Mapper(store: store), draft: draft, accounts: [account], wait: write.wait)
    }
}

struct DraftsUpdate: CLICommand {
    static let path = "gmail.drafts.update"
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Replace the text of an agent draft; it goes back to review.")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Draft id (local UUID or Gmail draft id).") var draftId: String
    @Option(name: .long, help: "Recipient (repeatable). Empty keeps the stored ones.") var to: [String] = []
    @Option(name: .long, help: "Cc (repeatable).") var cc: [String] = []
    @Option(name: .long, help: "Bcc (repeatable).") var bcc: [String] = []
    @Option(name: .long, help: "Subject. Empty keeps the stored one.") var subject: String?
    @Option(name: .long, help: "Body text file (`-` for stdin).") var bodyFile: String?
    @Option(name: .long, help: "Body text, or `-` for stdin.") var body: String?
    @Option(name: .long, help: "A note for the reviewer.") var note: String?

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let existing = try DraftSupport.find(draftId, ctx)
        guard existing.origin != .user else {
            throw CLIError.policy("not_agent_draft", "Only drafts created by an agent or the CLI can be updated here.")
        }
        guard existing.state == .editing else { throw CLIError.usage("That draft is no longer editable.", code: "draft_not_editing") }
        guard let text = try DraftInput.body(file: bodyFile, inline: body, ctx) else {
            throw CLIError.usage("A body is required: --body-file F or --body -.", code: "body_required")
        }
        let account = try ctx.store().accounts().first { $0.id == existing.accountID }
        guard let account else { throw CLIError.notFound("The account") }
        try ctx.requireWritable(account)
        let content = DraftContent(to: try DraftInput.addresses(to, field: "to"), cc: try DraftInput.addresses(cc, field: "cc"),
                                   bcc: try DraftInput.addresses(bcc, field: "bcc"), subject: try DraftInput.subject(subject ?? ""),
                                   bodyHTML: DraftInput.html(text), bodyText: text, attachments: [])
        if ctx.dryRun {
            return DraftSupport.dryRun(content, mode: existing.composeMode, account: account, note: note, extra: ["draftId": .string(existing.id.rawValue)])
        }
        let engine = try ctx.engine()
        try await engine.updateAgentDraft(existing.id, content: content, note: note)
        let store = try ctx.store()
        guard let draft = try store.draft(existing.id) else { throw CLIError.notFound("The draft") }
        return try await DraftSupport.result(ctx, engine: engine, mapper: Mapper(store: store), draft: draft, accounts: [account], wait: write.wait)
    }
}

struct DraftsForward: CLICommand {
    static let path = "gmail.drafts.forward"
    static let configuration = CommandConfiguration(commandName: "forward",
                                                    abstract: "Create a forward draft for review. It is never sent from the CLI.")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Gmail message id to forward.") var messageId: String
    @Option(name: .long, help: "Recipient (repeatable, or comma separated).") var to: [String] = []
    @Option(name: .long, help: "Cc (repeatable).") var cc: [String] = []
    @Option(name: .long, help: "Bcc (repeatable).") var bcc: [String] = []
    @Option(name: .long, help: "Text above the forwarded message, from a file (`-` for stdin).") var bodyFile: String?
    @Option(name: .long, help: "Text above the forwarded message, or `-` for stdin.") var body: String?
    @Option(name: .long, help: "A note for the reviewer.") var note: String?

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let recipients = try DraftInput.addresses(to, field: "to")
        guard !recipients.isEmpty else { throw CLIError.usage("At least one --to is required.", code: "recipient_required") }
        let text = try DraftInput.body(file: bodyFile, inline: body, ctx) ?? ""
        let account = try DraftSupport.messageAccount(messageId, ctx)
        try ctx.requireWritable(account)
        let content = DraftContent(to: recipients, cc: try DraftInput.addresses(cc, field: "cc"), bcc: try DraftInput.addresses(bcc, field: "bcc"),
                                   subject: "", bodyHTML: text.isEmpty ? "" : DraftInput.html(text), bodyText: text.isEmpty ? nil : text,
                                   attachments: [])
        let message = try ctx.store().message(account: account.id, gmailMessageID: GmailMessageID(messageId))
        let files = message?.attachments.filter { !$0.isInline }.count ?? 0
        let warning = files > 0 ? ["the forwarded message has \(files) attachment(s); the CLI does not forward attachments, add them in Mail by OpenHuman"] : []
        if ctx.dryRun {
            var result = DraftSupport.dryRun(content, mode: .forward, account: account, note: note, extra: ["forwardOf": .string(messageId)])
            result.warnings += warning
            return result
        }
        let engine = try ctx.engine()
        let id = try await engine.createAgentDraft(account: account.id, mode: .forward, replyTo: GmailMessageID(messageId), content: content,
                                                   note: note, origin: .cli)
        let store = try ctx.store()
        guard let draft = try store.draft(id) else { throw CLIError.notFound("The draft") }
        var result = try await DraftSupport.result(ctx, engine: engine, mapper: Mapper(store: store), draft: draft, accounts: [account], wait: write.wait)
        result.warnings += warning
        return result
    }
}

struct DraftsDelete: CLICommand {
    static let path = "gmail.drafts.delete"
    static let configuration = CommandConfiguration(commandName: "delete",
                                                    abstract: "Delete an agent draft that is not approved. Needs --yes under --no-input.")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Draft id (local UUID or Gmail draft id).") var draftId: String
    @Flag(name: .long, help: "Confirm under --no-input.") var yes = false

    static let queuedNote = "Deleted here. Mail by OpenHuman removes it from your Gmail Drafts when it runs."

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let draft = try DraftSupport.find(draftId, ctx)
        try DraftSupport.requireAgentOwned(draft)
        guard draft.reviewState != .approved else {
            throw CLIError.policy("draft_approved", "You approved this draft in review; delete it in Mail by OpenHuman.")
        }
        guard draft.state == .editing || draft.state == .failed else {
            throw CLIError.usage("That draft can no longer be deleted here.", code: "draft_not_editing")
        }
        let account = try DraftSupport.account(of: draft, ctx)
        try ctx.requireWritable(account)
        let columns = ["status", "draftId", "operationIds"]
        if ctx.dryRun {
            let data = obj(["dryRun": .bool(true), "status": .string("dry_run"), "draftId": .string(draft.id.rawValue),
                            "account": .string(account.email), "operationIds": .array([]),
                            "wouldQueue": .strings(draft.gmailDraftID == nil ? [] : ["delete_draft"])])
            return CommandResult(data: data, table: Table(columns: columns, rows: [[.string("dry_run"), .string(draft.id.rawValue), .array([])]]))
        }
        let engine = try ctx.engine()
        try await engine.discardDraft(draft.id)
        let ops = try DraftSupport.deleteOps(try ctx.store(), draft)
        let (status, exit, notes) = await DraftSupport.settle(ctx, engine: engine, accounts: [account], ids: ops, wait: write.wait,
                                                              note: Self.queuedNote)
        let ids = OutValue.array(ops.map { .int(Int($0.rawValue)) })
        let data = obj(["deleted": .bool(true), "status": .string(status), "draftId": .string(draft.id.rawValue),
                        "account": .string(account.email), "operationIds": ids])
        return CommandResult(data: data, table: Table(columns: columns, rows: [[.string(status), .string(draft.id.rawValue), ids]]),
                             status: exit, notes: notes)
    }
}

struct DraftsSend: PlannedCommand {
    static let path = "gmail.drafts.send"
    static let configuration = CommandConfiguration(commandName: "send", abstract: "Reserved: the CLI never sends.", shouldDisplay: false)
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .allUnrecognized) var rest: [String] = []
}

struct ReviewGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review", abstract: "The agent draft review queue. Nothing here sends.",
        subcommands: [ReviewList.self, ReviewShow.self, ReviewApprove.self, ReviewReject.self, ReviewOpen.self])
}

struct ReviewList: CLICommand {
    static let path = "gmail.review.list"
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Agent drafts waiting for review.")
    @OptionGroup var global: GlobalOptions

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let store = try ctx.store()
        let accounts = try ctx.accounts(.oneOrAll)
        ctx.noteReauth(accounts)
        let mapper = try Mapper(store: store)
        var drafts: [DraftListItem] = []
        for account in accounts { drafts += try store.reviewQueue(account: account.id) }
        let values = drafts.map(mapper.draft)
        var warnings: [String] = []
        let linked = Array(drafts.prefix(LinkGrammar.maxReviewIDs))
        if drafts.count > linked.count { warnings.append("the review link covers the first \(linked.count) drafts") }
        return CommandResult(data: obj(["drafts": .array(values), "reviewLink": linked.isEmpty ? nil : .string(mapper.reviewLink(linked))]),
                             items: values, table: Table(columns: CommandCatalog.draftColumns, rows: drafts.map(mapper.draftRow)),
                             warnings: warnings)
    }
}

enum ReviewDiff {
    static let maxLines = 1500
    static let context = 2

    static func lines(_ content: DraftContent) -> [String] {
        HTMLText.extract(content.bodyHTML).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func value(_ draft: DraftListItem) -> OutValue {
        guard let agent = draft.agentSnapshot else { return obj(["available": .bool(false), "edited": .bool(false)]) }
        let current = draft.content
        var fields: [String: OutValue] = ["available": .bool(true)]
        var edited = false
        if agent.subject != current.subject {
            edited = true
            fields["subject"] = obj(["agent": .untrusted(agent.subject), "current": .untrusted(current.subject)])
        }
        for (name, before, after) in [("to", agent.to, current.to), ("cc", agent.cc, current.cc), ("bcc", agent.bcc, current.bcc)] {
            let old = before.map { $0.email.lowercased() }, new = after.map { $0.email.lowercased() }
            let added = new.filter { !old.contains($0) }, removed = old.filter { !new.contains($0) }
            if !added.isEmpty || !removed.isEmpty {
                edited = true
                fields[name] = obj(["added": .strings(added), "removed": .strings(removed)])
            }
        }
        var a = lines(agent), b = lines(current)
        let truncated = a.count > maxLines || b.count > maxLines
        a = Array(a.prefix(maxLines)); b = Array(b.prefix(maxLines))
        let changes = diff(a, b)
        if changes.contains(where: { $0.op != "same" }) { edited = true }
        fields["body"] = .array(hunks(changes))
        fields["edited"] = .bool(edited)
        fields["truncated"] = .bool(truncated)
        return .object(fields)
    }

    static func diff(_ a: [String], _ b: [String]) -> [(op: String, text: String)] {
        let n = a.count, m = b.count
        var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var out: [(op: String, text: String)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] { out.append(("same", a[i])); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { out.append(("removed", a[i])); i += 1 }
            else { out.append(("added", b[j])); j += 1 }
        }
        while i < n { out.append(("removed", a[i])); i += 1 }
        while j < m { out.append(("added", b[j])); j += 1 }
        return out
    }

    static func hunks(_ lines: [(op: String, text: String)]) -> [OutValue] {
        let changed = lines.indices.filter { lines[$0].op != "same" }
        var keep = Set<Int>()
        for index in changed { for k in max(0, index - context)...min(lines.count - 1, index + context) { keep.insert(k) } }
        var out: [OutValue] = []
        var skipped = 0
        for (index, line) in lines.enumerated() {
            if keep.contains(index) {
                if skipped > 0 { out.append(obj(["op": .string("skip"), "lines": .int(skipped)])); skipped = 0 }
                out.append(obj(["op": .string(line.op), "text": .body(line.text)]))
            } else {
                skipped += 1
            }
        }
        if skipped > 0 { out.append(obj(["op": .string("skip"), "lines": .int(skipped)])) }
        return out
    }
}

struct ReviewShow: CLICommand {
    static let path = "gmail.review.show"
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show a draft under review; --diff shows what changed since the agent wrote it.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Draft id (local UUID or Gmail draft id).") var draftId: String
    @Flag(name: .long, help: "Show the diff against what the agent wrote.") var diff = false

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let draft = try DraftSupport.find(draftId, ctx)
        let mapper = try Mapper(store: try ctx.store())
        var value = mapper.draft(draft)
        var warnings: [String] = []
        if diff, case .object(var fields) = value {
            fields["diff"] = ReviewDiff.value(draft)
            value = .object(fields)
            if draft.agentSnapshot == nil { warnings.append("no agent text is stored for this draft, so there is nothing to compare") }
        }
        return CommandResult(data: value, table: Table(columns: CommandCatalog.draftColumns, rows: [mapper.draftRow(draft)]), warnings: warnings)
    }
}

enum PersonGate {
    static func confirm(_ ctx: CLIContext, account: AccountItem, action: String) throws {
        guard ctx.env.stdinIsTTY, !ctx.global.noInput else {
            throw CLIError.policy("person_required",
                                  "Approving or rejecting a draft is your decision: run it on an interactive terminal or use the review queue in Mail by OpenHuman (never with --no-input or a piped stdin).")
        }
        ctx.env.stderr.write("\(action) for \(account.email). Type the account email to confirm: ")
        guard let typed = ctx.env.readLine(),
              typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == account.email.lowercased() else {
            throw CLIError.policy("confirmation_failed", "The email did not match. Nothing was changed.")
        }
    }
}

enum ReviewDecision {
    static let approvedNote = "Approved. Mail by OpenHuman uploads the draft to Gmail as yours when it runs. Nothing was sent: send it from the app."
    static let rejectedNote = "Rejected and deleted. Mail by OpenHuman removes any Gmail copy when it runs."

    static func run(_ ids: [String], state: DraftReviewState, wait: Bool, _ ctx: CLIContext) async throws -> CommandResult {
        guard !ids.isEmpty else { throw CLIError.usage("At least one draft id is required.", code: "ids_required") }
        guard ids.count <= LinkGrammar.maxReviewIDs else { throw CLIError.usage("At most 50 drafts at a time.", code: "too_many_ids") }
        var drafts: [DraftListItem] = []
        for id in ids {
            let draft = try DraftSupport.find(id, ctx)
            if !drafts.contains(where: { $0.id == draft.id }) { drafts.append(draft) }
        }
        for draft in drafts {
            try DraftSupport.requireAgentOwned(draft)
            guard draft.reviewState == .pending, draft.state == .editing || draft.state == .failed else {
                throw CLIError.usage("Only drafts waiting for review can be approved or rejected.", code: "not_pending",
                                     details: ["id": .string(draft.id.rawValue)])
            }
        }
        guard Set(drafts.map(\.accountID)).count == 1 else {
            throw CLIError.usage("Decide on the drafts of one account at a time.", code: "account_required")
        }
        let account = try DraftSupport.account(of: drafts[0], ctx)
        try ctx.requireWritable(account)
        let store = try ctx.store()
        let mapper = try Mapper(store: store)
        let verb = state == .approved ? "approve" : "reject"
        if ctx.dryRun {
            let data = obj(["dryRun": .bool(true), "status": .string("dry_run"), "review": .string(state.rawValue), "sent": .bool(false),
                            "drafts": .array(drafts.map(mapper.draft)), "operationIds": .array([])])
            return CommandResult(data: data, table: Table(columns: CommandCatalog.draftColumns, rows: drafts.map(mapper.draftRow)))
        }
        try PersonGate.confirm(ctx, account: account, action: state == .approved ? "Approve \(drafts.count) draft(s)" : "Reject and delete \(drafts.count) draft(s)")
        let engine = try ctx.engine()
        var ops: [OperationID] = []
        for draft in drafts {
            try await engine.setReviewState(draft.id, state)
            if state == .rejected {
                try await engine.discardDraft(draft.id)
                ops += try DraftSupport.deleteOps(try ctx.store(), draft)
            } else {
                ops += try DraftSupport.uploadOps(try ctx.store(), draft)
            }
        }
        let (status, exit, notes) = await DraftSupport.settle(ctx, engine: engine, accounts: [account], ids: ops, wait: wait,
                                                              note: state == .approved ? approvedNote : rejectedNote)
        let after = try drafts.map { try ctx.store().draft($0.id) ?? $0 }
        let data = obj(["review": .string(state.rawValue), "verb": .string(verb), "status": .string(status), "sent": .bool(false),
                        "drafts": .array(after.map(mapper.draft)), "operationIds": .array(ops.map { .int(Int($0.rawValue)) })])
        let done = status == "succeeded" || status == "queued"
        return CommandResult(data: data, items: after.map(mapper.draft),
                             table: Table(columns: CommandCatalog.draftColumns, rows: after.map(mapper.draftRow)), status: exit,
                             notes: notes + (done && notes.isEmpty ? [state == .approved ? approvedNote : rejectedNote] : []))
    }
}

struct ReviewApprove: CLICommand {
    static let path = "gmail.review.approve"
    static let configuration = CommandConfiguration(
        commandName: "approve",
        abstract: "Approve agent drafts (Review: keep). It never sends. A person's decision: interactive terminal only.")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Draft ids (local UUID or Gmail draft id).") var draftIds: [String] = []
    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        try await ReviewDecision.run(draftIds, state: .approved, wait: write.wait, ctx)
    }
}

struct ReviewReject: CLICommand {
    static let path = "gmail.review.reject"
    static let configuration = CommandConfiguration(
        commandName: "reject",
        abstract: "Reject agent drafts and delete them (Review: discard). A person's decision: interactive terminal only.")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Draft ids (local UUID or Gmail draft id).") var draftIds: [String] = []
    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        try await ReviewDecision.run(draftIds, state: .rejected, wait: write.wait, ctx)
    }
}

struct ReviewOpen: CLICommand {
    static let path = "gmail.review.open"
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open the review queue in Mail by OpenHuman (prints the link).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Draft ids (default: every draft waiting for review).") var draftIds: [String] = []
    @Flag(name: .long, help: "Print the link only; do not open the app.") var printOnly = false

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let store = try ctx.store()
        let mapper = try Mapper(store: store)
        var drafts: [DraftListItem] = []
        if draftIds.isEmpty {
            for account in try ctx.accounts(.oneOrAll) { drafts += try store.reviewQueue(account: account.id) }
        } else {
            guard draftIds.count <= LinkGrammar.maxReviewIDs else { throw CLIError.usage("At most 50 drafts per review link.", code: "too_many_ids") }
            for id in draftIds {
                let draft = try DraftSupport.find(id, ctx)
                if !drafts.contains(where: { $0.id == draft.id }) { drafts.append(draft) }
            }
        }
        let columns = ["link", "count", "opened"]
        guard !drafts.isEmpty else {
            return CommandResult(data: obj(["count": .int(0), "opened": .bool(false)]),
                                 table: Table(columns: columns, rows: [[.string(""), .int(0), .bool(false)]]),
                                 notes: ["No agent drafts are waiting for review."])
        }
        var warnings: [String] = []
        let linked = Array(drafts.prefix(LinkGrammar.maxReviewIDs))
        if drafts.count > linked.count { warnings.append("the review link covers the first \(linked.count) drafts") }
        let link = MailLink.review(linked.map { DraftRef(account: AccountRef(mapper.email($0.accountID)), draftID: $0.id.rawValue) })
        let url = MailLinkBuilder.url(for: link)
        guard case .success = MailLinkParser.parse(url) else { throw CLIError.usage("Those drafts cannot be put in a link.", code: "bad_link_input") }
        let opened = !printOnly && !ctx.dryRun
        if opened { try ctx.env.openURL(url) }
        return CommandResult(data: obj(["link": .string(url.absoluteString), "count": .int(linked.count), "opened": .bool(opened)]),
                             table: Table(columns: columns, rows: [[.string(url.absoluteString), .int(linked.count), .bool(opened)]]),
                             warnings: warnings)
    }
}
