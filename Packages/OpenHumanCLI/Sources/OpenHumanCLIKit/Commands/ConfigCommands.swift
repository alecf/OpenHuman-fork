import ArgumentParser
import Foundation
import OpenHumanCore
import OpenHumanStore

struct ConfigKey: Sendable {
    var name: String
    var safety: Bool
    var mail = false
    var get: @Sendable (MailStore) throws -> OutValue
    var set: @Sendable (MailStore, String) throws -> Void
    var abstract: String
}

enum ConfigKeys {
    static func integer(_ text: String, _ range: ClosedRange<Int>) throws -> Int {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)), range.contains(n) else {
            throw CLIError.usage("That value must be a whole number from \(range.lowerBound) to \(range.upperBound).", code: "bad_value")
        }
        return n
    }

    static func bool(_ text: String) throws -> Bool {
        switch text.lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: throw CLIError.usage("That value must be true or false.", code: "bad_value")
        }
    }

    static func intKey(_ key: SettingKey<Int>, _ range: ClosedRange<Int>, _ abstract: String, mail: Bool = false) -> ConfigKey {
        ConfigKey(name: key.name, safety: key.isSafetyKey || mail, mail: mail,
                  get: { .int(try $0.setting(key, scope: .global)) },
                  set: { try $0.setSetting(key, try integer($1, range), scope: .global) }, abstract: abstract)
    }

    static func boolKey(_ key: SettingKey<Bool>, _ abstract: String, mail: Bool = false) -> ConfigKey {
        ConfigKey(name: key.name, safety: key.isSafetyKey || mail, mail: mail,
                  get: { .bool(try $0.setting(key, scope: .global)) },
                  set: { try $0.setSetting(key, try bool($1), scope: .global) }, abstract: abstract)
    }

    static let all: [ConfigKey] = [
        ConfigKey(name: SettingKey<String?>.defaultAccount.name, safety: false,
                  get: { OutValue.optString(try $0.setting(.defaultAccount, scope: .global)) ?? .string("") },
                  set: { store, text in
                      if ["", "none"].contains(text.lowercased()) { try store.setSetting(.defaultAccount, nil, scope: .global); return }
                      guard let account = try store.account(matching: text) else { throw CLIError.notFound("The account") }
                      try store.setSetting(.defaultAccount, account.email, scope: .global)
                  }, abstract: "Account used when --account is not given."),
        intKey(.undoSendSeconds, SettingKey<Int>.undoSendSecondsRange, "Undo-send window in the app, seconds (safety key).", mail: true),
        intKey(.pollIntervalSeconds, 15...3600, "Sync poll interval in the app, seconds."),
        intKey(.bodyHorizonDays, 1...3650, "How far back the app downloads message bodies, days."),
        boolKey(.downloadBodies, "The app downloads message bodies in the background so search sees inside mail."),
        ConfigKey(name: SettingKey<Int?>.bodyMaxMessages.name, safety: false,
                  get: { OutValue.optString(try $0.setting(.bodyMaxMessages, scope: .global).map { String($0) }) ?? .string("") },
                  set: { store, text in
                      if ["", "none", "all"].contains(text.lowercased()) { try store.setSetting(.bodyMaxMessages, nil, scope: .global); return }
                      try store.setSetting(.bodyMaxMessages, try integer(text, 0...10_000_000), scope: .global)
                  }, abstract: "Most message bodies the background download keeps per account; `none` for no cap."),
        boolKey(.snoozeMarkUnread, "Snoozed threads come back unread."),
        boolKey(.schedulerSnoozeEnabled, "The app wakes snoozed threads (safety key).", mail: true),
        boolKey(.schedulerSendLaterEnabled, "The app sends scheduled messages (safety key).", mail: true),
        boolKey(.schedulerRemindersEnabled, "The app fires reminders (safety key).", mail: true),
        boolKey(.cliReadonlyDefault, "The CLI is read-only unless a command opts out (safety key)."),
        ConfigKey(name: SettingKey<[String]?>.cliAllowedCommands.name, safety: true,
                  get: { OutValue.optString(try $0.setting(.cliAllowedCommands, scope: .global)?.joined(separator: ",")) ?? .string("") },
                  set: { store, text in
                      if ["", "none"].contains(text.lowercased()) { try store.setSetting(.cliAllowedCommands, nil, scope: .global); return }
                      let paths = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                      for path in paths where CommandCatalog.meta(for: path) == nil {
                          throw CLIError.usage("Unknown command path in the allowlist.", code: "unknown_command", details: ["path": .string(path)])
                      }
                      try store.setSetting(.cliAllowedCommands, paths, scope: .global)
                  }, abstract: "Allowlist of command paths; others exit 5 (safety key). `none` clears it."),
    ]

    static func find(_ name: String) throws -> ConfigKey {
        guard let key = all.first(where: { $0.name == name }) else {
            throw CLIError.usage("Unknown setting. Run `openhuman config list`.", code: "unknown_key", details: ["key": .string(name)])
        }
        return key
    }
}

struct ConfigGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config", abstract: "Settings the CLI may read and change.",
        subcommands: [ConfigGet.self, ConfigList.self, ConfigSet.self])
}

struct ConfigGet: CLICommand {
    static let path = "config.get"
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Read one setting.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Setting name.") var key: String
    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let entry = try ConfigKeys.find(key)
        let value = try entry.get(try ctx.store())
        return CommandResult(data: obj(["key": .string(entry.name), "value": value, "safety": .bool(entry.safety)]),
                             table: Table(columns: ["key", "value"], rows: [[.string(entry.name), value]]))
    }
}

struct ConfigList: CLICommand {
    static let path = "config.list"
    static let configuration = CommandConfiguration(commandName: "list", abstract: "All settings.")
    @OptionGroup var global: GlobalOptions
    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let store = try ctx.store()
        let rows = try ConfigKeys.all.map { ($0, try $0.get(store)) }
        let values = rows.map { entry, value in
            obj(["key": .string(entry.name), "value": value, "safety": .bool(entry.safety), "description": .string(entry.abstract)])
        }
        return CommandResult(data: obj(["settings": .array(values)]), items: values,
                             table: Table(columns: ["key", "value", "safety"], rows: rows.map { [.string($0.0.name), $0.1, .bool($0.0.safety)] }))
    }
}

struct ConfigSet: CLICommand {
    static let path = "config.set"
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Change a setting. Safety keys need a terminal and the account email.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Setting name.") var key: String
    @Argument(help: "New value.") var value: String

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let entry = try ConfigKeys.find(key)
        if !entry.safety, ctx.readonlyByDefault {
            throw CLIError.policy("readonly", "Blocked: the CLI is in read-only mode (cli.readonly_default).")
        }
        if entry.mail, ctx.safeMode == .readOnly {
            throw CLIError.policy("blocked_by_safe_mode",
                                  "Blocked: read-only safe mode. \(entry.name) changes how OpenHuman Mail sends or writes mail; change it in the app's Settings.")
        }
        if entry.safety {
            guard ctx.env.stdinIsTTY, !ctx.global.noInput, !ctx.global.readonly else {
                throw CLIError.policy("safety_key_gated",
                                      "\(entry.name) can only be changed on an interactive terminal (or in the app's Settings), never with --no-input or a piped stdin.")
            }
            let accounts = try ctx.store().accounts().filter { $0.status != .removing }
            guard !accounts.isEmpty else { throw CLIError.noAccount }
            let expected = try ctx.accounts(.one)[0].email
            let effect = entry.mail ? "changes a guard rail of how the app sends or writes mail" : "widens or narrows what agents may do"
            ctx.env.stderr.write("Changing \(entry.name) \(effect). Type the account email (\(expected)) to confirm: ")
            guard let typed = ctx.env.readLine(), typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expected.lowercased() else {
                throw CLIError.policy("confirmation_failed", "The email did not match. Nothing was changed.")
            }
        }
        if ctx.dryRun {
            return CommandResult(data: obj(["key": .string(entry.name), "dryRun": .bool(true)]),
                                 table: Table(columns: ["key", "value"], rows: [[.string(entry.name), .string(value)]]))
        }
        let store = try ctx.writableStore()
        try entry.set(store, value)
        let now = try entry.get(store)
        return CommandResult(data: obj(["key": .string(entry.name), "value": now, "safety": .bool(entry.safety)]),
                             table: Table(columns: ["key", "value"], rows: [[.string(entry.name), now]]))
    }
}
