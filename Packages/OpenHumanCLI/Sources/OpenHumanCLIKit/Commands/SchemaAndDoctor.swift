import ArgumentParser
import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

enum SchemaBuilder {
    static func build() throws -> [(meta: CommandMeta, value: OutValue)] {
        guard let data = OpenHumanCLI._dumpHelp().data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tree = root["command"] as? [String: Any] else {
            throw CLIError("failure", "Could not read the command tree.", .failure)
        }
        var leaves: [(path: String, node: [String: Any])] = []
        func walk(_ node: [String: Any], _ names: [String]) {
            let subs = node["subcommands"] as? [[String: Any]] ?? []
            if subs.isEmpty { leaves.append((names.joined(separator: "."), node)); return }
            for sub in subs { walk(sub, names + [sub["commandName"] as? String ?? ""]) }
        }
        walk(tree, [])
        let globals = globalOptionNames(leaves)
        var out: [(CommandMeta, OutValue)] = []
        for (path, node) in leaves {
            guard let meta = CommandCatalog.meta(for: path), meta.path == path else { continue }
            out.append((meta, entry(meta, node: node, globals: globals)))
        }
        return out.sorted { $0.0.path < $1.0.path }
    }

    private static func names(_ arg: [String: Any]) -> [String] {
        (arg["names"] as? [[String: Any]] ?? []).compactMap { n in
            guard let name = n["name"] as? String, let kind = n["kind"] as? String else { return nil }
            return (kind == "short" ? "-" : "--") + name
        }
    }

    static func globalOptionNames(_ leaves: [(path: String, node: [String: Any])]) -> Set<String> {
        guard let probe = leaves.first(where: { $0.path == "accounts.list" }) else { return [] }
        var set: Set<String> = ["--help", "-h", "--version"]
        for arg in probe.node["arguments"] as? [[String: Any]] ?? [] { set.formUnion(names(arg)) }
        return set
    }

    static func describe(_ arg: [String: Any]) -> (kind: String, value: OutValue) {
        let kind = arg["kind"] as? String ?? "option"
        var fields: [String: OutValue] = [
            "kind": .string(kind), "optional": .bool(arg["isOptional"] as? Bool ?? true), "repeatable": .bool(arg["isRepeating"] as? Bool ?? false),
        ]
        if kind != "positional" { fields["names"] = .strings(names(arg)) }
        if kind != "flag", let valueName = arg["valueName"] as? String { fields["valueName"] = .string(valueName) }
        if let def = arg["defaultValue"] as? String { fields["default"] = .string(def) }
        if let values = arg["allValueStrings"] as? [String] ?? arg["allValues"] as? [String], !values.isEmpty { fields["values"] = .strings(values) }
        if let abstract = arg["abstract"] as? String { fields["summary"] = .string(abstract) }
        return (kind, .object(fields))
    }

    static func entry(_ meta: CommandMeta, node: [String: Any], globals: Set<String>) -> OutValue {
        var arguments: [OutValue] = []
        var options: [OutValue] = []
        for arg in node["arguments"] as? [[String: Any]] ?? [] {
            if arg["shouldDisplay"] as? Bool == false, (arg["kind"] as? String) != "positional" { continue }
            let own = Set(names(arg))
            if !own.isEmpty, !own.isDisjoint(with: globals) { continue }
            let (kind, value) = describe(arg)
            if kind == "positional" {
                var v = value
                if case .object(var f) = v { f["name"] = .string(arg["valueName"] as? String ?? "value"); v = .object(f) }
                arguments.append(v)
            } else { options.append(value) }
        }
        let reserved: String?
        switch meta.reserved {
        case .send: reserved = "send_not_supported"
        case .notSupported: reserved = "not_supported"
        case nil: reserved = nil
        }
        return obj([
            "path": .string(meta.path),
            "aliases": .strings(meta.aliases + ((node["aliases"] as? [String]) ?? []).map { alias in
                (meta.path.split(separator: ".").dropLast() + [Substring(alias)]).joined(separator: ".")
            }.filter { !meta.aliases.contains($0) }),
            "summary": OutValue.optString(node["abstract"] as? String),
            "priority": .string(meta.priority),
            "stage": .string(meta.stage),
            "implemented": .bool(meta.implemented),
            "writes": .bool(meta.writes != .none),
            "writeScope": .string(meta.writes.rawValue),
            "network": .bool(meta.network),
            "confirmation": .bool(meta.confirm),
            "reserved": OutValue.optString(reserved),
            "output": .string(meta.output),
            "plainColumns": .strings(meta.plain),
            "arguments": .array(arguments),
            "options": .array(options),
        ])
    }

    static func globalOptions() throws -> OutValue {
        guard let data = OpenHumanCLI._dumpHelp().data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tree = root["command"] as? [String: Any] else { return .array([]) }
        var leaves: [(path: String, node: [String: Any])] = []
        func walk(_ node: [String: Any], _ names: [String]) {
            let subs = node["subcommands"] as? [[String: Any]] ?? []
            if subs.isEmpty { leaves.append((names.joined(separator: "."), node)); return }
            for sub in subs { walk(sub, names + [sub["commandName"] as? String ?? ""]) }
        }
        walk(tree, [])
        guard let probe = leaves.first(where: { $0.path == "accounts.list" }) else { return .array([]) }
        let list = (probe.node["arguments"] as? [[String: Any]] ?? []).compactMap { arg -> OutValue? in
            if names(arg).contains(where: { ["--help", "-h", "--version"].contains($0) }) { return nil }
            return describe(arg).value
        }
        return .array(list)
    }
}

struct SchemaCommand: CLICommand {
    static let path = "schema"
    static let configuration = CommandConfiguration(commandName: "schema", abstract: "Every command, option, output type and exit code, as data.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Command path, e.g. gmail.search or `gmail search`. Default: all.") var command: [String] = []

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        var entries = try SchemaBuilder.build()
        if !command.isEmpty {
            let wanted = command.joined(separator: ".")
            entries = entries.filter { $0.meta.path == wanted || $0.meta.aliases.contains(wanted) }
            guard !entries.isEmpty else { throw CLIError.notFound("The command", id: wanted) }
        }
        let codes = CLIStatus.allCases.map { obj(["code": .int(Int($0.rawValue)), "name": .string($0.label), "meaning": .string($0.meaning)]) }
        let commands = entries.map(\.value)
        let data = obj([
            "version": .string(OutputWriter.schemaVersion),
            "cliVersion": .string(OpenHumanCLIVersion.current),
            "exitCodes": .array(codes),
            "globalOptions": try SchemaBuilder.globalOptions(),
            "commands": .array(commands),
        ])
        let rows = entries.map { e in
            [OutValue.string(e.meta.path), .string(e.meta.stage), .bool(e.meta.implemented), .string(e.meta.writes.rawValue),
             .string(e.meta.output)]
        }
        return CommandResult(data: data, items: commands, table: Table(columns: ["path", "stage", "implemented", "writes", "output"], rows: rows))
    }
}

struct DoctorCommand: CLICommand {
    static let path = "doctor"
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Check the store, schema, FTS5, accounts and the app. Prints no mail content.")
    @OptionGroup var global: GlobalOptions

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        var checks: [(name: String, status: String, detail: String)] = []
        var exit: CLIStatus = .ok
        func add(_ name: String, _ status: String, _ detail: String) { checks.append((name, status, detail)) }

        add("cli", "ok", "openhuman \(OpenHumanCLIVersion.current)")
        add("safe-mode", ctx.safeMode == .readOnly ? "ok" : "warn",
            "\(ctx.safeMode.rawValue) (OPENHUMAN_SAFE_MODE; unset or unrecognised means read-only)")
        add("store.location", "ok", ctx.location.directory.path)
        do {
            let store = try ctx.store()
            let report = try store.doctor()
            add("store.open", "ok", "opened read-only; schema compat level \(report.compatLevel), created by \(report.createdByVersion)")
            add("sqlite", report.fts5Available ? "ok" : "fail", "SQLite \(report.sqliteVersion), FTS5 \(report.fts5Available ? "yes" : "no"), trigram \(report.trigramAvailable ? "yes" : "no"), journal \(report.journalMode)")
            if !report.fts5Available { exit = .incompatible }
            add("store.integrity", report.isCorrupt ? "fail" : "ok", report.isCorrupt ? "the store reported corruption" : "no problem reported")
            if report.isCorrupt, exit == .ok { exit = .failure }
            let accounts = try store.accounts()
            let byStatus = Dictionary(grouping: accounts, by: { $0.status.rawValue }).mapValues(\.count)
            add("accounts", accounts.isEmpty ? "warn" : "ok",
                "\(accounts.count) account(s)" + (byStatus.isEmpty ? "" : " (" + byStatus.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ") + ")"))
            if accounts.contains(where: { $0.status == .needsReauth }) { add("auth", "warn", "an account needs to be reauthorized in OpenHuman Mail") }
            var pending = 0, failed = 0
            var owner: Int32?
            for a in accounts {
                let s = try store.syncStatus(account: a.id)
                pending += s.pendingOperations; failed += s.failedOperations
                if s.owner?.isLive == true { owner = s.owner?.pid }
            }
            add("app", owner == nil ? "warn" : "ok", owner.map { "OpenHuman Mail is running (pid \($0))" } ?? "OpenHuman Mail is not running; queued changes wait for it")
            add("queue", failed > 0 ? "warn" : "ok", "\(pending) pending, \(failed) failed operation(s)")
            let readonly = try store.setting(.cliReadonlyDefault, scope: .global)
            let allowed = try store.setting(.cliAllowedCommands, scope: .global)
            add("policy", "ok", "cli.readonly_default=\(readonly), cli.allowed_commands=\(allowed.map { $0.joined(separator: ",") } ?? "unset")")
        } catch {
            let mapped = CLIError.map(error)
            add("store.open", "fail", "\(mapped.code): \(mapped.message)")
            exit = mapped.status == .authRequired ? .authRequired : mapped.status
        }
        let values = checks.map { obj(["name": .string($0.name), "status": .string($0.status), "detail": .string($0.detail)]) }
        return CommandResult(data: obj(["ok": .bool(!checks.contains { $0.status == "fail" }), "checks": .array(values)]), items: values,
                             table: Table(columns: ["name", "status", "detail"], rows: checks.map { [.string($0.name), .string($0.status), .string($0.detail)] }),
                             status: exit)
    }
}
