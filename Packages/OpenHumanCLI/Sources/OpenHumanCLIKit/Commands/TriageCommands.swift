import ArgumentParser
import Foundation
import OpenHumanCore
import OpenHumanStore
import OpenHumanSync

enum WriteSupport {
    static let queuedNote = "Queued locally. OpenHuman Mail applies changes queued by the CLI to Gmail only in a guarded test run; otherwise it refuses them and reverts the local change. Queued changes expire after 24 hours."

    static func resolveThreads(_ ctx: CLIContext, ids: [String]) throws -> (accounts: [AccountItem], refs: [ThreadRef]) {
        let clean = ids.map { $0.trimmingCharacters(in: .whitespaces) }
        guard !clean.isEmpty else { throw CLIError.usage("At least one thread id is required.", code: "ids_required") }
        guard clean.count <= 100 else { throw CLIError.usage("At most 100 ids per command.", code: "too_many_ids") }
        for id in clean where id.isEmpty || id.count > 64 || !id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) {
            throw CLIError.usage("That is not a Gmail thread id.", code: "bad_id")
        }
        let store = try ctx.store()
        let candidates = try ctx.lookupAccounts()
        var refs: [ThreadRef] = []
        var missing: [String] = []
        var used: [AccountItem] = []
        for id in clean {
            let hits = try candidates.compactMap { a in try store.thread(account: a.id, gmailThreadID: GmailThreadID(id)).map { (a, $0) } }
            if hits.count > 1 { throw CLIError.usage("That id exists in several accounts. Pass --account <email>.", code: "ambiguous_account") }
            guard let (account, ref) = hits.first else { missing.append(id); continue }
            if !refs.contains(ref) { refs.append(ref) }
            if !used.contains(where: { $0.id == account.id }) { used.append(account) }
        }
        if !missing.isEmpty {
            throw CLIError("not_found", "Some threads were not found in the local cache. Nothing was changed.", .notFound,
                           details: ["ids": .strings(missing)])
        }
        for account in used { try ctx.requireWritable(account) }
        return (used, refs)
    }

    static func settle(_ ctx: CLIContext, engine: MailEngine, accounts: [AccountItem], ids: [OperationID], wait: Bool,
                       note: String = queuedNote) async -> (status: String, exit: CLIStatus, notes: [String]) {
        if ids.isEmpty { return ("succeeded", .ok, []) }
        guard ctx.appIsRunning(accounts), wait else { return ("queued", .queued, [note]) }
        let statuses = await engine.waitForOperations(ids, timeout: ctx.timeout)
        if statuses.values.contains(where: { $0 == .failed || $0 == .cancelled }) {
            let store = try? ctx.store()
            if ids.contains(where: { ((try? store?.operation($0)) ?? nil)?.lastErrorCode == "safe_mode_blocked" }) {
                return ("refused", .policyBlocked, ["OpenHuman Mail did not send this to Gmail: it applies changes queued by the CLI only in a guarded test run."])
            }
            return ("failed", .failure, ["The app could not apply the change. Run `openhuman sync status` for details."])
        }
        if statuses.values.allSatisfy({ $0 == .succeeded }) { return ("succeeded", .ok, []) }
        return ("queued", .queued, ["Queued; the app has not confirmed it within the timeout."])
    }

    static func undoToken(_ receipt: ActionReceipt) -> String? {
        guard receipt.undo != nil, let data = try? JSONEncoder().encode(receipt) else { return nil }
        return data.base64EncodedString()
    }
}

protocol TriageCommand: CLICommand {
    static var verb: String { get }
    var write: WriteOptions { get }
    var threadIds: [String] { get }
    func action(_ refs: [ThreadRef], _ ctx: CLIContext) throws -> MailAction
    static var dataNote: String? { get }
}

extension TriageCommand {
    static var dataNote: String? { nil }

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let (accounts, refs) = try WriteSupport.resolveThreads(ctx, ids: threadIds)
        let mapper = try Mapper(store: ctx.store())
        let mailAction = try action(refs, ctx)
        let threads = refs.map { r in
            obj(["threadId": .string(r.gmailThreadID.rawValue), "account": .string(mapper.email(r.accountID)),
                 "link": .string(mapper.threadLink(r.accountID, r.gmailThreadID))])
        }
        let columns = CommandCatalog.opColumns
        if ctx.dryRun {
            let data = obj(["verb": .string(Self.verb), "dryRun": .bool(true), "status": .string("dry_run"), "threads": .array(threads),
                            "operationIds": .array([]), "note": OutValue.optString(Self.dataNote)])
            return CommandResult(data: data, table: Table(columns: columns, rows: [[.string("dry_run"), .array([]), .strings(refs.map(\.gmailThreadID.rawValue))]]))
        }
        let engine = try ctx.engine()
        let receipt = try await engine.perform(mailAction, origin: .cli)
        let (status, exit, notes) = await WriteSupport.settle(ctx, engine: engine, accounts: accounts, ids: receipt.operationIDs, wait: write.wait)
        let data = obj([
            "verb": .string(Self.verb), "status": .string(status), "threads": .array(threads),
            "operationIds": .array(receipt.operationIDs.map { .int(Int($0.rawValue)) }),
            "undo": OutValue.optString(WriteSupport.undoToken(receipt)), "note": OutValue.optString(Self.dataNote),
        ])
        return CommandResult(data: data, table: Table(columns: columns, rows: [[.string(status), .array(receipt.operationIDs.map { .int(Int($0.rawValue)) }),
                                                                              .strings(refs.map(\.gmailThreadID.rawValue))]]),
                             status: exit, notes: notes)
    }
}

struct GmailDone: TriageCommand {
    static let path = "gmail.done"
    static let verb = "done"
    static let configuration = CommandConfiguration(commandName: "done", abstract: "Mark done (removes INBOX).", aliases: ["archive"])
    @OptionGroup var global: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Gmail thread ids.") var threadIds: [String]
    func action(_ refs: [ThreadRef], _ ctx: CLIContext) throws -> MailAction { .archive(refs) }
}

struct GmailMoveToInbox: TriageCommand {
    static let path = "gmail.move-to-inbox"
    static let verb = "move-to-inbox"
    static let configuration = CommandConfiguration(commandName: "move-to-inbox", abstract: "Back to the inbox.", aliases: ["unarchive"])
    @OptionGroup var global: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Gmail thread ids.") var threadIds: [String]
    func action(_ refs: [ThreadRef], _ ctx: CLIContext) throws -> MailAction { .moveToInbox(refs) }
}

struct GmailRead: TriageCommand {
    static let path = "gmail.read"
    static let verb = "read"
    static let configuration = CommandConfiguration(commandName: "read", abstract: "Mark read.")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Gmail thread ids.") var threadIds: [String]
    func action(_ refs: [ThreadRef], _ ctx: CLIContext) throws -> MailAction { .markRead(refs) }
}

struct GmailUnread: TriageCommand {
    static let path = "gmail.unread"
    static let verb = "unread"
    static let configuration = CommandConfiguration(commandName: "unread", abstract: "Mark unread.")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Gmail thread ids.") var threadIds: [String]
    func action(_ refs: [ThreadRef], _ ctx: CLIContext) throws -> MailAction { .markUnread(refs) }
}

struct GmailStar: TriageCommand {
    static let path = "gmail.star"
    static let verb = "star"
    static let configuration = CommandConfiguration(commandName: "star", abstract: "Star.")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Gmail thread ids.") var threadIds: [String]
    func action(_ refs: [ThreadRef], _ ctx: CLIContext) throws -> MailAction { .star(refs) }
}

struct GmailUnstar: TriageCommand {
    static let path = "gmail.unstar"
    static let verb = "unstar"
    static let configuration = CommandConfiguration(commandName: "unstar", abstract: "Remove the star.")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Gmail thread ids.") var threadIds: [String]
    func action(_ refs: [ThreadRef], _ ctx: CLIContext) throws -> MailAction { .unstar(refs) }
}

func parseFuture(_ text: String, _ ctx: CLIContext) throws -> Date {
    let parsed = try WhenParser(timeZone: ctx.env.timeZone).parse(text, now: ctx.now)
    guard ScheduleStamp.floorToMinute(parsed) > ctx.now else {
        throw CLIError.usage("That time is in the past.", code: "time_in_past")
    }
    return parsed
}

struct GmailSnooze: TriageCommand {
    static let path = "gmail.snooze"
    static let verb = "snooze"
    static let configuration = CommandConfiguration(commandName: "snooze", abstract: "Snooze until a time (writes Gmail schedule labels via the queue).")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Gmail thread ids.") var threadIds: [String]
    @Option(name: .long, help: "ISO 8601, `tomorrow 8am`, `+2h`, `monday`.") var until: String
    func action(_ refs: [ThreadRef], _ ctx: CLIContext) throws -> MailAction { .snooze(refs, until: try parseFuture(until, ctx)) }
}

struct GmailUnsnooze: TriageCommand {
    static let path = "gmail.unsnooze"
    static let verb = "unsnooze"
    static let configuration = CommandConfiguration(commandName: "unsnooze", abstract: "Wake a snoozed thread now.")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Gmail thread ids.") var threadIds: [String]
    func action(_ refs: [ThreadRef], _ ctx: CLIContext) throws -> MailAction { .unsnooze(refs) }
}

struct GmailRemind: TriageCommand {
    static let path = "gmail.remind"
    static let verb = "remind"
    static let dataNote: String? = "Reminders are kept on this Mac only."
    static let configuration = CommandConfiguration(commandName: "remind", abstract: "Remind me about a thread. Reminders are kept on this Mac only.")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Gmail thread id.") var threadId: String
    @Option(name: .long, help: "ISO 8601, `tomorrow 8am`, `+2h`, `monday`.") var at: String
    @Flag(name: .long, help: "Only remind when nobody has replied.") var ifNoReply = false
    var threadIds: [String] { [threadId] }
    func action(_ refs: [ThreadRef], _ ctx: CLIContext) throws -> MailAction {
        .setReminder(refs[0], dueAt: try parseFuture(at, ctx), condition: ifNoReply ? .ifNoReply : .always)
    }
}

struct GmailUnremind: TriageCommand {
    static let path = "gmail.unremind"
    static let verb = "unremind"
    static let dataNote: String? = "Reminders are kept on this Mac only."
    static let configuration = CommandConfiguration(commandName: "unremind", abstract: "Cancel the thread's reminder.")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "Gmail thread id.") var threadId: String
    var threadIds: [String] { [threadId] }
    func action(_ refs: [ThreadRef], _ ctx: CLIContext) throws -> MailAction { .cancelReminder(refs[0]) }
}

enum UndoToken {
    static let maxBytes = 64 * 1024
    static let triageLabels: Set<String> = ["INBOX", "UNREAD", "STARRED"]

    static func decode(_ text: String) throws -> ActionReceipt {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= maxBytes, let data = Data(base64Encoded: trimmed),
              let receipt = try? JSONDecoder().decode(ActionReceipt.self, from: data), receipt.undo != nil else {
            throw CLIError.usage("That is not an undo token from this CLI.", code: "bad_undo_token")
        }
        return receipt
    }

    static let notAllowed = CLIError.policy("undo_not_allowed", "That token would make a change the CLI does not make. Undo it in Mail by OpenHuman.")
    static let stale = CLIError.usage("That undo token no longer matches the cache.", code: "bad_undo_token")

    static func validate(_ receipt: ActionReceipt, _ ctx: CLIContext) throws -> (accounts: [AccountItem], threads: [String]) {
        let store = try ctx.store()
        var accountIDs: [AccountID] = []
        var threads: [String] = []
        func note(_ account: AccountID) { if !accountIDs.contains(account) { accountIDs.append(account) } }
        func check(_ refs: [ThreadRef]) throws {
            for ref in refs {
                guard try store.thread(account: ref.accountID, gmailThreadID: ref.gmailThreadID) == ref else { throw stale }
                note(ref.accountID)
                if !threads.contains(ref.gmailThreadID.rawValue) { threads.append(ref.gmailThreadID.rawValue) }
            }
        }
        for action in [receipt.undo, receipt.exactUndo].compactMap({ $0 }) {
            switch action {
            case let .archive(refs), let .moveToInbox(refs), let .markRead(refs), let .markUnread(refs), let .star(refs),
                 let .unstar(refs), let .unsnooze(refs), let .clearSnooze(refs), let .snooze(refs, _):
                try check(refs)
            case let .setReminder(ref, _, _), let .cancelReminder(ref):
                try check([ref])
            case let .modifyMessageLabels(account, ids, add, remove):
                guard Set((add + remove).map(\.rawValue)).isSubset(of: triageLabels), ids.count <= 1000 else { throw notAllowed }
                for id in ids where try store.message(account: account, gmailMessageID: id) == nil { throw stale }
                note(account)
            default:
                throw notAllowed
            }
        }
        guard threads.count <= 100 else { throw CLIError.usage("At most 100 threads per command.", code: "too_many_ids") }
        for id in receipt.operationIDs {
            guard let op = try store.operation(id) else { continue }
            guard op.origin == .cli, op.kind == .modifyLabels || op.kind == .createLabel else { throw notAllowed }
            note(op.accountID)
        }
        let accounts = try store.accounts().filter { accountIDs.contains($0.id) }
        guard accounts.count == accountIDs.count else { throw CLIError.notFound("The account") }
        return (accounts, threads)
    }
}

struct GmailUndo: CLICommand {
    static let path = "gmail.undo"
    static let configuration = CommandConfiguration(commandName: "undo",
                                                    abstract: "Take back a triage change by the undo token it printed (data.undo).")
    @OptionGroup var global: GlobalOptions
    @OptionGroup var write: WriteOptions
    @Argument(help: "The undo token from a triage command's output (data.undo).") var token: String

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let receipt = try UndoToken.decode(token)
        let (accounts, threads) = try UndoToken.validate(receipt, ctx)
        for account in accounts { try ctx.requireWritable(account) }
        let columns = CommandCatalog.opColumns
        if ctx.dryRun {
            let data = obj(["verb": .string("undo"), "dryRun": .bool(true), "status": .string("dry_run"), "threadIds": .strings(threads),
                            "operationIds": .array([])])
            return CommandResult(data: data, table: Table(columns: columns, rows: [[.string("dry_run"), .array([]), .strings(threads)]]))
        }
        let engine = try ctx.engine()
        let redo = try await engine.undo(receipt)
        let ops = redo?.operationIDs ?? []
        let (status, exit, notes) = await WriteSupport.settle(ctx, engine: engine, accounts: accounts, ids: ops, wait: write.wait)
        let ids = OutValue.array(ops.map { .int(Int($0.rawValue)) })
        let data = obj(["verb": .string("undo"), "status": .string(status), "threadIds": .strings(threads), "operationIds": ids,
                        "undo": OutValue.optString(redo.flatMap(WriteSupport.undoToken))])
        return CommandResult(data: data, table: Table(columns: columns, rows: [[.string(status), ids, .strings(threads)]]), status: exit, notes: notes)
    }
}
