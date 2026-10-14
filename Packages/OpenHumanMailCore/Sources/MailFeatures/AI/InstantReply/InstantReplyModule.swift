import Foundation
import MailActions
import MailModel
import OpenHumanAI
import OpenHumanCore

public struct InstantReplyModule: FeatureModule {
    public static let id = FeatureModuleID.instantReply
    public static let defaultEnabled = true
    public init() {}

    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.actions(ActionCatalog.descriptors(module: Self.id), handler: InstantReplyActionHandler(environment: env))
    }
}

@MainActor
final class InstantReplyActionHandler: ActionHandler {
    private weak var environment: AppEnvironment?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    private var center: AICenter? {
        guard let environment, environment.actions.contains(.aiRewrite) else { return nil }
        return environment.ai
    }

    private func strip(_ context: ActionContext) -> InstantReplyModel? {
        guard let session = environment?.composeIfStarted?.session(id: context.composer), session.isOpen else { return nil }
        return session.instantReply
    }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        guard let center else { return .hidden }
        switch id {
        case .aiToggleInstantReply:
            return center.settings.enabled && center.settings.draftReplies == .onDeviceAuto ? .enabled : .hidden
        case .aiHideInstantReply:
            return strip(context)?.showsRow == true ? .enabled : .hidden
        default:
            return .hidden
        }
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let center else { return .notHandled }
        switch request.id {
        case .aiToggleInstantReply:
            do {
                try center.update { $0.instantReplyStrip.toggle() }
            } catch {
                environment?.notices.post(String(localized: "Couldn't save the AI setting"), style: .error)
            }
            return .done
        case .aiHideInstantReply:
            guard let model = strip(request.context) else { return .notHandled }
            model.hideForConversation()
            return .done
        default:
            return .notHandled
        }
    }
}

extension ComposeManager {
    var offersInstantReply: Bool { aiCenter != nil && environment.actions.contains(.aiToggleInstantReply) }

    public func instantReply(for session: ComposeSession) -> InstantReplyModel? {
        offersInstantReply ? session.instantReply : nil
    }

    public func attachInstantReply(_ session: ComposeSession) {
        guard session.isOpen, session.instantReply == nil, !session.instantReplyDecided else { return }
        session.instantReplyDecided = true
        guard offersInstantReply, let center = aiCenter, let thread = session.thread else { return }
        let target = session.replyTo ?? center.replyTarget(in: thread)
        let context = center.loadedContext(thread, upTo: target)
        let replies = center.quickReplies(for: thread, replyingTo: target ?? context?.messageKeys.last)
        switch eligibility(session, center: center, replies: replies, context: context) {
        case .eligible:
            install(session, center: center, replies: replies)
        case .ineligible(.decidedTooLate):
            if replies.phase == .idle { replies.request(trigger: .automatic) }
            let timing = center.instantReplyTiming
            track(Task { [weak self, weak session, weak center] in
                guard let center else { return }
                let context = await ComposeManager.context(of: thread, upTo: target, center: center,
                                                           within: InstantReplyPolicy.lateEligibility, timing: timing)
                guard let self, let session, session.isOpen, session.instantReply == nil else { return }
                let answered = context?.messageKeys.last.map { center.quickReplies(for: thread, replyingTo: $0) } ?? replies
                let decided = self.eligibility(session, center: center, replies: answered, context: context)
                if decided == .eligible {
                    self.install(session, center: center, replies: answered)
                } else {
                    InstantReplyModel.log("instantReply absent reason=\(decided.reasonName)")
                }
            })
        case .ineligible(let reason):
            InstantReplyModel.log("instantReply absent reason=\(InstantReplyEligibility.ineligible(reason).reasonName)")
        }
    }

    private func eligibility(_ session: ComposeSession, center: AICenter, replies: QuickRepliesModel,
                             context: AIThreadContext?) -> InstantReplyEligibility {
        let excluded = session.thread.flatMap { thread in context.flatMap { center.exclusion(for: thread, context: $0) } }
        return InstantReplyEligibility.evaluate(settings: center.settings, moduleOn: offersInstantReply,
                                                mode: session.mode, source: session.source,
                                                bodyIsEmpty: InstantReplyModel.bodyIsEmpty(session),
                                                replyTo: session.replyTo, answered: context?.messageKeys.last,
                                                answeredIsMine: context?.lastIsFromMe, hidden: replies.hiddenInComposer,
                                                threadPhase: replies.phase, excluded: excluded)
    }

    private func install(_ session: ComposeSession, center: AICenter, replies: QuickRepliesModel) {
        let model = InstantReplyModel(session: session, center: center, replies: replies)
        session.instantReply = model
        model.shown()
    }

    @MainActor private static func context(of thread: ThreadKey, upTo target: MessageKey?, center: AICenter,
                                           within limit: Duration, timing: InstantReplyTiming) async -> AIThreadContext? {
        await withTaskGroup(of: AIThreadContext?.self) { group in
            group.addTask { await center.context(for: thread, upTo: target, trigger: .automatic) }
            group.addTask {
                try? await timing.sleep(limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
