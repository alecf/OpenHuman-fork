import ArgumentParser
import Foundation
import OpenHumanGmail
import OpenHumanStore

public protocol CLICommand: AsyncParsableCommand {
    static var path: String { get }
    var global: GlobalOptions { get }
    var yes: Bool { get }
    func handle(_ ctx: CLIContext) async throws -> CommandResult
}

extension CLICommand {
    public var yes: Bool { false }
    public func run() async throws { try await CLIRunner.execute(self) }
}

public protocol PlannedCommand: CLICommand {}
extension PlannedCommand {
    public func handle(_ ctx: CLIContext) async throws -> CommandResult {
        throw CLIError("not_implemented", "This command is planned but not built in this release.", .notImplemented)
    }
}

enum CLIRunner {
    static func resolveFormat(_ global: GlobalOptions, _ env: CLIEnvironment) throws -> OutputFormat {
        let flags: [OutputFormat] = [global.json ? .json : nil, global.jsonl ? .jsonl : nil, global.plain ? .plain : nil,
                                     global.human ? .human : nil].compactMap { $0 }
        if flags.count > 1 { throw CLIError.usage("Pass only one of --json, --jsonl, --plain, --human.") }
        if let flag = flags.first { return flag }
        if let fromEnv = env.variables["OPENHUMAN_OUTPUT"], !fromEnv.isEmpty {
            guard let format = OutputFormat(rawValue: fromEnv), format != .jsonl else {
                throw CLIError.usage("OPENHUMAN_OUTPUT must be json, plain or human.")
            }
            return format
        }
        return env.stdoutIsTTY ? .human : .json
    }

    static func execute<C: CLICommand>(_ command: C) async throws {
        let env = CLIEnvironment.current
        let global = command.global
        let path = C.path
        guard let meta = CommandCatalog.meta(for: path) else {
            preconditionFailure("\(path) has no row in CommandCatalog")
        }
        let format = (try? resolveFormat(global, env)) ?? .json
        let writer = OutputWriter(
            env: env, format: format, command: path,
            content: ContentPolicy(wrapper: global.wrapUntrusted ? UntrustedWrapper(nonce: env.nonce()) : nil,
                                   sanitize: global.sanitizeContent, maxBodyBytes: global.maxBodyBytes),
            header: global.header, quiet: global.quiet)

        var context: CLIContext?
        defer { context?.close() }
        do {
            _ = try resolveFormat(global, env)
            if global.timeout != nil, parseDuration(global.timeout!) == nil {
                throw CLIError.usage("--timeout must look like 30s, 500ms or 2m, and be at most 1h.")
            }
            let mode = Policy.safeMode(environment: env.variables)
            let ctx = try CLIContext(env: env, global: global, path: path, meta: meta, safeMode: mode)
            context = ctx
            let inputs = try policyInputs(ctx, command: command, mode: mode)
            try Policy.evaluate(meta, path: path, inputs)
            if global.sync { throw CLIError.appRequired("--sync needs Gmail access, which only OpenHuman Mail has in Phase 1.") }

            let result = try await command.handle(ctx)
            let freshness = ctx.accountsUsed.map { ctx.freshness($0) }
            var finished = result
            finished.warnings = ctx.warnings + result.warnings
            writer.success(finished, accounts: freshness)
            if result.status != .ok { throw CLIExit(result.status.rawValue) }
        } catch let exit as CLIExit {
            throw exit
        } catch {
            let mapped = CLIError.map(error)
            writer.failure(mapped)
            throw CLIExit(mapped.status.rawValue)
        }
    }

    private static func policyInputs<C: CLICommand>(_ ctx: CLIContext, command: C, mode: SafeMode) throws -> PolicyInputs {
        let env = ctx.env
        var readonly = ctx.global.readonly || env.variables["OPENHUMAN_READONLY"] == "1"
        var allowed: [String]?
        let storedDefaultExempt = C.path == "config.set"
        if env.storeProvider != nil || FileManager.default.fileExists(atPath: ctx.location.databaseURL.path),
           let store = try? ctx.store() {
            if try store.setting(.cliReadonlyDefault, scope: .global) {
                ctx.readonlyByDefault = true
                if !storedDefaultExempt { readonly = true }
            }
            allowed = try store.setting(.cliAllowedCommands, scope: .global)
        }
        return PolicyInputs(readonly: readonly, safeMode: mode, allowedCommands: allowed, noInput: ctx.global.noInput || !env.stdinIsTTY,
                            yes: command.yes, dryRun: ctx.global.dryRun)
    }
}
