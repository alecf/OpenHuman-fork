import Foundation
import MailActions
import MailModel

@MainActor
final class ReviewActionHandler: ActionHandler {
    static let ids: [ActionID] = [.reviewSend, .reviewKeep, .reviewDiscard, .reviewSkip, .reviewNext, .reviewPrevious,
                                  .reviewEdit]

    private weak var environment: AppEnvironment?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        guard let model = environment?.review, model.isOpen else { return .hidden }
        switch id {
        case .reviewNext: return model.cursor + 1 < model.rows.count ? .enabled : .disabled(.other(String(localized: "Last draft")))
        case .reviewPrevious: return model.cursor > 0 ? .enabled : .disabled(.other(String(localized: "First draft")))
        case .reviewSkip: return model.current != nil ? .enabled : .hidden
        default: return model.current?.isActionable == true ? .enabled : .disabled(.other(String(localized: "Nothing to review")))
        }
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let model = environment?.review, model.isOpen else { return .notHandled }
        switch request.id {
        case .reviewNext: return model.next() ? .done : .notHandled
        case .reviewPrevious: return model.previous() ? .done : .notHandled
        case .reviewSkip: return model.skip() ? .done : .notHandled
        case .reviewKeep: return model.keep().map { .started($0) } ?? .notHandled
        case .reviewDiscard: return model.discard().map { .started($0) } ?? .notHandled
        case .reviewEdit: return model.edit().map { .started($0) } ?? .notHandled
        case .reviewSend: return model.send().map { .started($0) } ?? .notHandled
        default: return .notHandled
        }
    }
}

public struct ReviewModule: FeatureModule {
    public static let id = FeatureModuleID.review
    public static let defaultEnabled = true
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.catalogActions(Self.id, env: env)
        registry.actions(ReviewActionHandler.ids.compactMap(ActionCatalog.descriptor),
                         handler: ReviewActionHandler(environment: env))
        registry.location(.reviewQueue(nil), title: "Review queue", chord: .sequence("g", "r"))
    }
}
