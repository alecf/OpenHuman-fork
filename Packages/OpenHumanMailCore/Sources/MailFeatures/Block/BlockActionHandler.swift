import Foundation
import MailActions
import MailModel
import OpenHumanCore

@MainActor
final class BlockActionHandler: ActionHandler {
    static let ids: [ActionID] = [.blockSender, .blockDomain, .goBlocked]

    private weak var environment: AppEnvironment?
    private let feedback: ActionFeedback
    private let center: BlockCenter?
    private let undoer: BlockUndoer?

    init(environment: AppEnvironment) {
        self.environment = environment
        feedback = ActionFeedback(environment: environment)
        if let settings = environment.settings, let commands = environment.commands {
            let center = BlockCenter(settings: settings, data: environment.data)
            self.center = center
            undoer = BlockUndoer(rules: center.ruleUndoer, mail: commands)
        } else {
            center = nil
            undoer = nil
        }
    }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        guard let environment else { return .hidden }
        if id == .goBlocked { return environment.settingsNavigator.canOpen ? .enabled : .hidden }
        return center == nil ? .hidden : .enabled
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let environment else { return .notHandled }
        if request.id == .goBlocked {
            environment.settingsNavigator.open(BlockedSettingsModel.pageID)
            return .done
        }
        let c = request.context
        guard center != nil, let thread = c.focusedThread else { return .notHandled }
        let account = c.account ?? thread.account
        let rule: BlockRule?
        switch request.id {
        case .blockSender: rule = c.sender.flatMap { BlockRule(kind: .sender, value: $0, createdAt: Date()) }
        case .blockDomain: rule = c.senderDomain.flatMap { BlockRule(kind: .domain, value: $0, createdAt: Date()) }
        default: return .notHandled
        }
        guard let rule else { return .notHandled }
        let id = request.id
        return .started(Task { [weak self] in
            await self?.begin(rule, account: account, thread: thread, id: id)
        })
    }


    func begin(_ rule: BlockRule, account: AccountID, thread: ThreadKey?, id: ActionID) async {
        guard let environment, let center else { return }
        guard environment.status.safeMode.allowsMailChanges else {
            feedback.refuse(id, .safeMode)
            return
        }
        if await center.rules(account).contains(where: { $0.id == rule.id }) {
            environment.notices.post("Already blocked: \(rule.value)", style: .info, duration: NoticeCenter.infoDuration)
            return
        }
        if await center.hasSentTo(rule, account: account) {
            environment.notices.postChoice(
                "You've written to \(rule.value). Block it anyway?",
                NoticeCenter.Choice("Block anyway") { [weak self] in
                    await self?.commit(rule, account: account, thread: thread)
                },
                NoticeCenter.Choice("Cancel") {},
                duration: nil)
            return
        }
        await commit(rule, account: account, thread: thread)
    }

    func commit(_ rule: BlockRule, account: AccountID, thread: ThreadKey?) async {
        guard let environment, let center, let undoer, let undo = environment.undo else { return }
        let token: UndoToken
        do {
            let ruleToken = try await center.add(rule, account: account)
            token = undoer.begin(rule: ruleToken)
        } catch {
            feedback.failed("Couldn't block \(rule.value)")
            return
        }
        undo.push(UndoCoordinator.Entry(title: "Blocked \(rule.value)", token: token, threads: thread.map { [$0] } ?? [],
                                        undoer: undoer))
        await offerCleanup(rule, account: account, thread: thread, token: token)
    }


    static let cleanupLimit = ThreadActionHandler.sweepLimit

    func cleanupTargets(_ rule: BlockRule, account: AccountID, thread: ThreadKey?) async -> [ThreadKey] {
        guard let environment else { return [] }
        var targets: [ThreadKey] = []
        if let query = BlockMatcher.cleanupQuery(kind: rule.kind, value: rule.value) {
            do {
                for try await page in environment.data.search(query, accounts: [account], limit: Self.cleanupLimit) {
                    targets = page.hits.map(\.row).filter { row in
                        BlockMatcher.coversAny(rule, senders: row.participants.filter { !$0.isMe }.map(\.email))
                    }.map(\.id)
                    break
                }
            } catch {
                targets = []
            }
        }
        if let thread, !targets.contains(thread) { targets.append(thread) }
        return targets
    }

    private func offerCleanup(_ rule: BlockRule, account: AccountID, thread: ThreadKey?, token: UndoToken) async {
        guard let environment, let center else { return }
        let targets = await cleanupTargets(rule, account: account, thread: thread)
        guard !targets.isEmpty else { return }
        let archive = NoticeCenter.Choice("Archive all") { [weak self] in
            await self?.cleanUp(.markDone(targets), token: token, who: rule.value)
        }
        let trash = NoticeCenter.Choice("Move to Trash") { [weak self] in
            await self?.cleanUp(.trash(targets), token: token, who: rule.value)
        }
        let fallback = await center.defaultDisposition()
        let trashFirst = (rule.disposition ?? fallback) == .trash
        let count = targets.count == 1 ? "1 conversation" : "\(targets.count) conversations"
        environment.notices.postChoice("Blocked \(rule.value). Clean up \(count) from them?",
                                       trashFirst ? trash : archive, trashFirst ? archive : trash)
    }

    func cleanUp(_ command: MailCommand, token: UndoToken, who: String) async {
        guard let environment, let commands = environment.commands, let undoer else { return }
        guard undoer.isApplied(token) else {
            environment.notices.post("The block was undone, so nothing was cleaned up.", style: .info,
                                     duration: NoticeCenter.infoDuration)
            return
        }
        do {
            let cleanup = try await commands.apply(command)
            if !undoer.attach(cleanup: cleanup, to: token) { _ = try? await commands.undo(cleanup) }
        } catch MailPortError.blockedBySafeMode {
            feedback.refuse(.blockSender, .safeMode)
            return
        } catch {
            feedback.failed("Couldn't clean up the mail from \(who)")
            return
        }
        let n = command.threads.count
        let what = n == 1 ? "1 conversation" : "\(n) conversations"
        var verb = "Archived \(what)"
        if case .trash = command { verb = "Moved \(what) to Trash" }
        environment.notices.post("\(verb). ⌘Z takes this back along with the block.", style: .info,
                                 duration: NoticeCenter.infoDuration)
    }
}

public struct BlockModule: FeatureModule {
    public static let id = FeatureModuleID.block
    public static let defaultEnabled = true
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.actions(ActionCatalog.descriptors(module: Self.id), handler: BlockActionHandler(environment: env))
        registry.settingsPage(SettingsPageDescriptor(id: BlockedSettingsModel.pageID, title: "Blocked", symbol: "nosign"))
    }
}
