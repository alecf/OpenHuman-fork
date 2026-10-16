import Foundation

struct PolicyInputs: Sendable {
    var readonly: Bool
    var allowedCommands: [String]?
    var noInput: Bool
    var yes: Bool
    var dryRun: Bool
}

enum Policy {
    static let mailChangesInApp = CLIError.policy("mail_changes_in_app", "Make mail changes in OpenHuman Mail.")

    static func evaluate(_ meta: CommandMeta, path: String, _ inputs: PolicyInputs) throws {
        switch meta.reserved {
        case .send(let hint):
            throw CLIError.policy("send_not_supported", "The CLI does not send mail. \(hint)")
        case .notSupported:
            throw CLIError.policy("not_supported", "Filters and Gmail settings edits are not supported.")
        case nil:
            break
        }
        if let allowed = inputs.allowedCommands, !allowed.contains(meta.path), !meta.aliases.contains(where: allowed.contains) {
            throw CLIError.policy("command_not_allowed", "This command is not in cli.allowed_commands.",
                                  details: ["command": .string(meta.path)])
        }
        if meta.network {
            throw CLIError.appRequired("This command needs Gmail access, which only OpenHuman Mail has in Phase 1. Use the app.")
        }
        if meta.writes != .none, inputs.readonly {
            throw CLIError.policy("readonly", "Blocked: this run is read-only (--readonly, OPENHUMAN_READONLY or cli.readonly_default).")
        }
        if meta.confirm, inputs.noInput, !inputs.yes, !inputs.dryRun {
            throw CLIError.usage("This action needs confirmation. Pass --yes under --no-input.", code: "confirmation_required")
        }
        if !meta.implemented {
            throw CLIError("not_implemented", "This command is planned but not built in this release.", .notImplemented,
                           details: ["command": .string(path), "stage": .string(meta.stage)])
        }
        if meta.writes == .mailChange, !inputs.dryRun { throw mailChangesInApp }
    }
}
