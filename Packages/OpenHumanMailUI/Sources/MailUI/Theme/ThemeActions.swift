import Foundation
import MailActions
import MailFeatures
import MailTheme

@MainActor
public final class ThemeActionHandler: ActionHandler {
    private let store: ThemeStore

    public init(store: ThemeStore) {
        self.store = store
    }

    public static func install(in registry: ActionRegistry, store: ThemeStore) {
        let handler = ThemeActionHandler(store: store)
        let catalog = ActionCatalog.descriptors(in: .view).filter { $0.id.rawValue.hasPrefix("theme.") }
        registry.register(handler, for: catalog.map(\.id))
        let extra = store.library.accentIDs.filter { !ActionCatalog.builtInAccents.contains($0) }
        registry.register(extra.map(ActionCatalog.accentDescriptor), handler: handler, module: nil)
    }

    public func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        if let name = id.themeAccentName, !store.library.accentIDs.contains(name) { return .hidden }
        return .enabled
    }

    public func perform(_ request: ActionRequest) -> ActionPerformance {
        switch request.id {
        case .themeLight: store.preferences.mode = .light
        case .themeDark: store.preferences.mode = .dark
        case .themeSystem: store.preferences.mode = .system
        default:
            guard let name = request.id.themeAccentName, store.library.accentIDs.contains(name) else { return .notHandled }
            store.preferences.accentID = name
        }
        return .done
    }

    public static func action(for mode: AppearanceMode) -> ActionID {
        switch mode {
        case .light: .themeLight
        case .dark: .themeDark
        case .system: .themeSystem
        }
    }
}
