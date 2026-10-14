import ArgumentParser
import Foundation
import OpenHumanCore
import OpenHumanStore

enum AccountOutput {
    static func account(_ a: AccountItem, status: SyncStatus?, isDefault: Bool, scopes: Bool = true) -> OutValue {
        obj([
            "email": .string(a.email),
            "alias": OutValue.optString(a.alias),
            "status": .string(a.status.rawValue),
            "default": .bool(isDefault),
            "scopes": scopes ? .strings(a.grantedScopes) : nil,
            "syncPhase": OutValue.optString(status?.phase.rawValue),
            "syncedAt": OutValue.optDate(status?.lastSuccessAt),
            "backfillComplete": OutValue.optBool(status?.backfillComplete),
        ])
    }

    static func defaultEmail(_ store: MailStore, _ all: [AccountItem]) -> String? {
        if let name = (try? store.setting(.defaultAccount, scope: .global)) ?? nil,
           let found = try? store.account(matching: name) { return found.email }
        return all.count == 1 ? all[0].email : nil
    }

    static func listing(_ ctx: CLIContext, scopes: Bool, columns: [String]) throws -> CommandResult {
        let store = try ctx.store()
        let all = try store.accounts().filter { $0.status != .removing }
        let chosen: [AccountItem]
        if let selector = ctx.global.account, !selector.isEmpty, selector.lowercased() != "all" {
            guard let one = try store.account(matching: selector) else { throw CLIError.notFound("The account") }
            chosen = [one]
        } else { chosen = all }
        let def = defaultEmail(store, all)
        let rows = try chosen.map { a -> (OutValue, [OutValue]) in
            let status = try? store.syncStatus(account: a.id)
            let value = account(a, status: status, isDefault: a.email == def, scopes: scopes)
            let row: [OutValue] = columns.map { column in
                switch column {
                case "email": return .string(a.email)
                case "alias": return .string(a.alias ?? "")
                case "status": return .string(a.status.rawValue)
                case "default": return .bool(a.email == def)
                case "scopes": return .strings(a.grantedScopes)
                case "syncPhase": return .string(status?.phase.rawValue ?? "")
                default: return .string(status?.lastSuccessAt.map { OutValue.iso($0) } ?? "")
                }
            }
            return (value, row)
        }
        ctx.noteReauth(chosen)
        return CommandResult(data: obj(["accounts": .array(rows.map(\.0))]), items: rows.map(\.0),
                             table: Table(columns: columns, rows: rows.map(\.1)))
    }
}

struct Accounts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Accounts in the local store.",
        subcommands: [AccountsList.self, AccountsAdd.self, AccountsRemove.self, AccountsAlias.self, AccountsDefault.self])
}

struct AccountsList: CLICommand {
    static let path = "accounts.list"
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List accounts with their sync state.")
    @OptionGroup var global: GlobalOptions
    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        try AccountOutput.listing(ctx, scopes: true, columns: ["email", "alias", "status", "default", "syncedAt"])
    }
}

struct AccountsAdd: PlannedCommand {
    static let path = "accounts.add"
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add an account (needs the app in Phase 1).")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .long, help: "Paste flow instead of the loopback browser flow.") var manual = false
    @Option(name: .long, help: "Alias for the account.") var alias: String?
}

struct AccountsRemove: PlannedCommand {
    static let path = "accounts.remove"
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove an account (needs the app in Phase 1).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Account email or alias.") var account: String
    @Flag(name: .long, help: "Confirm under --no-input.") var yes = false
}

struct AccountsAlias: CLICommand {
    static let path = "accounts.alias"
    static let configuration = CommandConfiguration(commandName: "alias", abstract: "Give an account a short local alias.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Account email or alias.") var target: String
    @Argument(help: "New alias.") var alias: String

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let clean = alias.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean.count <= 32, !clean.contains("@"), clean.allSatisfy({ !$0.isWhitespace && !$0.isNewline }) else {
            throw CLIError.usage("An alias is 1 to 32 characters without spaces or @.", code: "bad_alias")
        }
        let reader = try ctx.store()
        guard let account = try reader.account(matching: target) else { throw CLIError.notFound("The account") }
        if let other = try reader.account(matching: clean), other.id != account.id {
            throw CLIError.usage("That alias is already in use.", code: "alias_taken")
        }
        if !ctx.dryRun { try ctx.writableStore().updateAccount(account.id, alias: clean, color: nil, position: nil, displayName: nil) }
        return CommandResult(data: obj(["email": .string(account.email), "alias": .string(clean), "dryRun": ctx.dryRun ? .bool(true) : nil]),
                             table: Table(columns: ["email", "alias"], rows: [[.string(account.email), .string(clean)]]))
    }
}

struct AccountsDefault: CLICommand {
    static let path = "accounts.default"
    static let configuration = CommandConfiguration(commandName: "default", abstract: "Set the default account.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Account email or alias.") var target: String

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        guard let account = try ctx.store().account(matching: target) else { throw CLIError.notFound("The account") }
        if !ctx.dryRun { try ctx.writableStore().setSetting(.defaultAccount, account.email, scope: .global) }
        return CommandResult(data: obj(["email": .string(account.email), "default": .bool(true), "dryRun": ctx.dryRun ? .bool(true) : nil]),
                             table: Table(columns: ["email", "default"], rows: [[.string(account.email), .bool(true)]]))
    }
}

struct Auth: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Account status (gog parity).", subcommands: [AuthStatus.self, AuthLogin.self, AuthLogout.self])
}

struct AuthStatus: CLICommand {
    static let path = "auth.status"
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Accounts with status and granted scopes (the CLI never reads tokens).")
    @OptionGroup var global: GlobalOptions
    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        try AccountOutput.listing(ctx, scopes: true, columns: ["email", "status", "scopes", "syncPhase", "syncedAt"])
    }
}

struct AuthLogin: PlannedCommand {
    static let path = "auth.login"
    static let configuration = CommandConfiguration(commandName: "login", abstract: "Sign in (needs the app in Phase 1).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Account email.") var email: String?
    @Flag(name: .long, help: "Paste flow.") var manual = false
}

struct AuthLogout: PlannedCommand {
    static let path = "auth.logout"
    static let configuration = CommandConfiguration(commandName: "logout", abstract: "Sign out (needs the app in Phase 1).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Account email or alias.") var account: String
    @Flag(name: .long, help: "Also delete the cached mail.") var purge = false
    @Flag(name: .long, help: "Confirm under --no-input.") var yes = false
}

struct SyncGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync", abstract: "Sync state; sync itself runs in the app.",
        subcommands: [SyncRun.self, SyncStatusCommand.self, SyncWatch.self])
}

struct SyncRun: CLICommand {
    static let path = "sync.run"
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Ask the running app to sync now.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .long, help: "Full resync (not available through the app request).") var full = false
    @Option(name: .long, help: "Initial sync wait.") var initialTimeout: String?

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let store = try ctx.store()
        let accounts = try store.accounts().filter { $0.status == .active || $0.status == .needsReauth }
        guard !accounts.isEmpty else { throw CLIError.noAccount }
        let leases = accounts.compactMap { try? store.lease(account: $0.id) }.filter(\.isLive)
        let newest = try accounts.compactMap { try store.syncStatus(account: $0.id).lastSuccessAt }.max()
        guard let owner = leases.first else {
            let age = newest.map { OutputWriter.age($0, now: ctx.now) + " old" } ?? "never synced"
            throw CLIError.appRequired("Sync runs in OpenHuman Mail. Open the app; cached data is \(age).")
        }
        var warnings: [String] = []
        if full { warnings.append("--full is not available through the app request; a normal sync was requested.") }
        let ageSeconds = newest.map { max(0, Int(ctx.now.timeIntervalSince($0))) }
        if !ctx.dryRun {
            try ctx.writableStore().setSetting(.syncRequestAt, Int(ctx.now.timeIntervalSince1970 * 1000), scope: .global)
        }
        let data = obj(["requested": .bool(!ctx.dryRun), "dryRun": ctx.dryRun ? .bool(true) : nil,
                        "ownerPid": .int(Int(owner.pid)), "dataAgeSeconds": OutValue.optInt(ageSeconds)])
        return CommandResult(
            data: data,
            table: Table(columns: ["requested", "ownerPid", "dataAgeSeconds"],
                         rows: [[.bool(!ctx.dryRun), .int(Int(owner.pid)), .int(ageSeconds ?? -1)]]),
            warnings: warnings,
            notes: ["sync is owned by the app (pid \(owner.pid)); data is \(ageSeconds.map { "\($0)" } ?? "?") s fresh"])
    }
}

struct SyncStatusCommand: CLICommand {
    static let path = "sync.status"
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Sync state, queue depth and the app's lease.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Include the last N sync log rows per account.") var log: Int?

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let store = try ctx.store()
        let accounts = try ctx.accounts(.oneOrAll)
        var values: [OutValue] = []
        var rows: [[OutValue]] = []
        for a in accounts {
            let s = try store.syncStatus(account: a.id)
            var logValue: OutValue?
            if let n = log, n > 0 {
                logValue = .array(try store.syncLog(account: a.id, limit: n).map { e in
                    obj(["kind": .string(e.kind), "startedAt": OutValue.date(e.startedAt), "finishedAt": OutValue.optDate(e.finishedAt),
                         "outcome": OutValue.optString(e.outcome), "quotaUnits": .int(e.quotaUnits), "requests": .int(e.requests),
                         "added": .int(e.added), "changed": .int(e.changed), "deleted": .int(e.deleted),
                         "errorCode": OutValue.optString(e.errorCode)])
                })
            }
            values.append(obj([
                "email": .string(a.email), "phase": .string(s.phase.rawValue),
                "lastSuccessAt": OutValue.optDate(s.lastSuccessAt), "lastAttemptAt": OutValue.optDate(s.lastAttemptAt),
                "backfillOldest": OutValue.optDate(s.backfillOldest), "backfillComplete": .bool(s.backfillComplete),
                "consecutiveFailures": .int(s.consecutiveFailures), "lastError": OutValue.optUntrusted(s.lastError),
                "pendingOperations": .int(s.pendingOperations), "failedOperations": .int(s.failedOperations),
                "appRunning": .bool(s.owner?.isLive == true),
                "owner": s.owner.map { o in obj(["kind": .string(o.kind), "pid": .int(Int(o.pid)), "live": .bool(o.isLive),
                                                  "heartbeatAt": OutValue.date(o.heartbeatAt)]) },
                "log": logValue,
            ]))
            rows.append([.string(a.email), .string(s.phase.rawValue), .string(s.lastSuccessAt.map { OutValue.iso($0) } ?? ""),
                         .int(s.pendingOperations), .int(s.failedOperations)])
        }
        ctx.noteReauth(accounts)
        return CommandResult(data: obj(["accounts": .array(values)]), items: values,
                             table: Table(columns: ["email", "phase", "lastSuccessAt", "pendingOperations", "failedOperations"], rows: rows))
    }
}

struct SyncWatch: PlannedCommand {
    static let path = "sync.watch"
    static let configuration = CommandConfiguration(commandName: "watch", abstract: "Keep syncing (needs network access: deferred).")
    @OptionGroup var global: GlobalOptions
}
