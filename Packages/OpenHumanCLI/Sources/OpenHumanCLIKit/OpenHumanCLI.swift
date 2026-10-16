import ArgumentParser
import Foundation

public struct OpenHumanCLI: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "openhuman",
        abstract: "OpenHuman Mail on the command line: read the local cache, draft replies for review, never send.",
        discussion: """
            Reads come from the same SQLite store as the app. Drafts wait in the app's review queue; mail changes are made in the app.
            Default output is JSON when stdout is not a terminal. Run `openhuman schema` for every command as data.
            """,
        version: OpenHumanCLIVersion.current,
        subcommands: [
            Accounts.self, Auth.self, SyncGroup.self, Gmail.self, CalendarGroup.self, LinkGroup.self,
            SchemaCommand.self, DoctorCommand.self, ConfigGroup.self, Mcp.self,
        ])

    public init() {}

    // Why: `await OpenHumanCLI.main()` resolves to the synchronous ParsableCommand.main(), which refuses async commands
    public static func runMain(_ arguments: [String]? = nil) async {
        let code = await run(arguments ?? Array(CommandLine.arguments.dropFirst()), environment: .live)
        Foundation.exit(code)
    }

    public static func run(_ arguments: [String], environment: CLIEnvironment) async -> Int32 {
        await CLIEnvironment.$current.withValue(environment) {
            do {
                var command = try parseAsRoot(arguments)
                if var asyncCommand = command as? AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
                return 0
            } catch let exit as CLIExit {
                return exit.code
            } catch {
                return report(parseError: error, arguments: arguments, environment: environment)
            }
        }
    }

    private static func report(parseError error: Error, arguments: [String], environment: CLIEnvironment) -> Int32 {
        let status = exitCode(for: error)
        if status == .success {
            environment.stdout.write(fullMessage(for: error) + "\n")
            return 0
        }
        let text = message(for: error)
        let wantsJSON = arguments.contains("--json") || arguments.contains("--jsonl")
            || (!arguments.contains("--plain") && !arguments.contains("--human") && !environment.stdoutIsTTY
                && environment.variables["OPENHUMAN_OUTPUT"].map { $0 == "json" } ?? true)
        if wantsJSON {
            let body = obj(["code": .string("usage"), "message": .string(text), "exitCode": .int(2), "details": .object([:])])
            let envelope = obj(["schema": .string(OutputWriter.schemaVersion), "command": .string("openhuman"), "ok": .bool(false), "error": body])
            environment.stdout.write(envelope.json(pretty: true) + "\n")
        }
        environment.stderr.write("error: \(text) (usage)\n")
        return CLIStatus.usage.rawValue
    }
}
