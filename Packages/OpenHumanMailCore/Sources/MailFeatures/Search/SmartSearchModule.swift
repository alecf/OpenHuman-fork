import Foundation
import MailActions
import MailModel

public struct SmartSearchModule: FeatureModule {
    public static let id = FeatureModuleID.smartSearch
    public static let defaultEnabled = true
    public init() {}

    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.actions(ActionCatalog.descriptors(module: Self.id), handler: SmartSearchActionHandler(environment: env))
    }
}

extension AppEnvironment {
    public var smartSearchEnabled: Bool { modules.modules.contains(.smartSearch) }
}

@MainActor
final class SmartSearchActionHandler: ActionHandler {
    private weak var environment: AppEnvironment?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    private var search: SearchModel? { (environment?.actions.presenter as? OverlayCenter)?.search }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        guard let search, search.saved.hasPort else { return .hidden }
        switch id {
        case .goSavedSearch:
            return .enabled
        case .saveSearch:
            guard search.saved.canSave, let query = search.shownQuery else { return .hidden }
            return search.saved.saved(forQuery: query) == nil ? .enabled : .hidden
        case .deleteSavedSearch:
            guard search.saved.canSave, let query = search.shownQuery, search.saved.saved(forQuery: query) != nil else {
                return .hidden
            }
            return .enabled
        default:
            return .hidden
        }
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let search = environment?.overlays.search else { return .notHandled }
        switch request.id {
        case .goSavedSearch:
            search.openSavedSearches()
            return .done
        case .saveSearch:
            return .started(Task { await search.saveShownSearch() })
        case .deleteSavedSearch:
            return .started(Task { await search.deleteShownSavedSearch() })
        default:
            return .notHandled
        }
    }
}
