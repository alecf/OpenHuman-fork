import Foundation
import MailActions
import MailModel
import OpenHumanCore

extension ThreadActionHandler {
    func toggleMute(_ request: ActionRequest) -> ActionPerformance {
        let c = request.context
        let targets = c.selection
        guard let account = targets.first?.account, targets.allSatisfy({ $0.account == account }) else { return .notHandled }
        let label = request.router?.accounts.first { $0.id == account }?.mutedLabel
        let inbox = GmailLabelID("INBOX")
        if c.targets.allMuted, let label {
            return apply(.modifyLabels(targets, add: [inbox], remove: [label.labelID]), request,
                         title: Titles.unmuted(targets.count), advances: c.location == .label(label.labelID),
                         failure: Titles.muteFailure(targets.count, unmute: true))
        }
        if let label {
            let changing = Self.changing(targets, request) { $0.userLabelIDs.contains(label.id) }
            let mute = MailCommand.modifyLabels(changing, add: [label.labelID], remove: [inbox])
            let snoozed = Self.snoozeGroups(changing, request)
            let steps = snoozed.isEmpty ? nil : MailSteps.muting(endingSnoozes: snoozed) { [try await $0.apply(mute)] }
            return apply(mute, request, title: Titles.muted(changing.count), advances: true,
                         failure: Titles.muteFailure(changing.count, unmute: false), steps: steps)
        }
        let steps = MailSteps.muting(endingSnoozes: Self.snoozeGroups(targets, request)) { commands in
            let labeled = try await commands.createLabel(account, name: OHGmailLabels.muted, applyTo: targets)
            do {
                return [labeled, try await commands.apply(.markDone(targets))]
            } catch {
                _ = try? await commands.undo(labeled)
                throw error
            }
        }
        return apply(.markDone(targets), request, title: Titles.muted(targets.count), advances: true,
                     failure: Titles.muteFailure(targets.count, unmute: false), steps: steps)
    }

    static func snoozeGroups(_ targets: [ThreadKey], _ request: ActionRequest) -> [[ThreadKey]] {
        let router = request.router
        let list = (router?.accounts.first { $0.id == request.context.account } ?? router?.active)?.list
        var byWake: [Date: [ThreadKey]] = [:]
        var wakes: [Date] = []
        var unknown: [[ThreadKey]] = []
        for key in targets {
            guard let row = list?.row(for: key) else {
                unknown.append([key])
                continue
            }
            guard let wake = row.snoozedUntil else { continue }
            if byWake[wake] == nil { wakes.append(wake) }
            byWake[wake, default: []].append(key)
        }
        return wakes.compactMap { byWake[$0] } + unknown
    }
}

struct MailSteps: Sendable {
    let perform: @Sendable (any MailCommanding) async throws -> UndoToken
    let undoer: @Sendable (any MailCommanding) -> any MailUndoing

    static func muting(endingSnoozes snoozed: [[ThreadKey]],
                       _ mute: @escaping @Sendable (any MailCommanding) async throws -> [UndoToken]) -> MailSteps {
        MailSteps(perform: { commands in
            var done: [UndoToken] = []
            do {
                for group in snoozed { done.append(try await commands.apply(.clearSnooze(group))) }
                done += try await mute(commands)
                return try UndoSequence.token(done)
            } catch {
                for token in done.reversed() { _ = try? await commands.undo(token) }
                throw error
            }
        }, undoer: { UndoSequence(port: $0) })
    }
}

struct UndoSequence: MailUndoing {
    let port: any MailUndoing

    static func token(_ steps: [UndoToken]) throws -> UndoToken {
        let changing = steps.filter { !$0.changesNothing }
        return UndoToken(payload: try JSONEncoder().encode(changing.map(\.payload)), changesNothing: changing.isEmpty)
    }

    func undo(_ token: UndoToken) async throws -> UndoToken? {
        let steps = try JSONDecoder().decode([Data].self, from: token.payload)
        var redo: [UndoToken] = []
        for payload in steps.reversed() {
            if let back = try await port.undo(UndoToken(payload: payload)) { redo.insert(back, at: 0) }
        }
        return redo.isEmpty ? nil : try Self.token(redo)
    }
}

extension Titles {
    static func muted(_ n: Int) -> LocalizedStringResource { n == 1 ? "Muted" : "Muted \(n) conversations" }
    static func unmuted(_ n: Int) -> LocalizedStringResource {
        n == 1 ? "Unmuted, moved to Inbox" : "Unmuted \(n) conversations, moved to Inbox"
    }

    static func muteFailure(_ n: Int, unmute: Bool) -> String {
        "Couldn't \(unmute ? "unmute" : "mute") \(n == 1 ? "1 conversation" : "\(n) conversations")"
    }
}

public struct MuteModule: FeatureModule {
    public static let id = FeatureModuleID.mute
    public static let defaultEnabled = true
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.catalogActions(Self.id, env: env)
    }
}
