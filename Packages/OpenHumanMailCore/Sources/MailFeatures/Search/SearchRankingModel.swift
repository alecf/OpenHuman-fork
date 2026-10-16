import Foundation
import MailActions
import MailModel
import Observation
import Synchronization

@MainActor @Observable
public final class SearchRankingModel {
    public static let resetMessage = "Search learning reset"

    public private(set) var settings: SearchRankingSettings
    public private(set) var sortOverride: SearchSortOverride?
    public private(set) var rememberedConversations = 0

    @ObservationIgnored private let port: any SearchRankingPort
    @ObservationIgnored private let notices: NoticeCenter?

    public init(port: any SearchRankingPort, notices: NoticeCenter? = nil) {
        self.port = port
        self.notices = notices
        self.settings = port.settings()
        self.sortOverride = port.sortOverride()
    }

    public var shownWeights: SearchRankingWeights { settings.weights ?? .balanced }

    public func setDefaultSort(_ sort: SearchSortOrder) { update { $0.sort = sort } }

    public func setPreset(_ preset: SearchRankingPreset) {
        update { s in
            if preset == .custom, s.preset != .custom { s.custom = s.weights ?? .balanced }
            s.preset = preset
        }
    }

    public func setWeight(_ field: SearchRankingWeights.Field, _ value: Double) {
        update { s in
            var weights = s.weights ?? .balanced
            weights[field] = value
            s.custom = weights
            s.preset = .custom
        }
    }

    public func resetWeight(_ field: SearchRankingWeights.Field) {
        setWeight(field, SearchRankingWeights.balanced[field])
        if settings.custom == .balanced { update { $0.preset = .balanced } }
    }

    public func isChanged(_ field: SearchRankingWeights.Field) -> Bool {
        shownWeights[field] != SearchRankingWeights.balanced[field]
    }

    public func resetAll() { update { $0 = .defaults } }

    private func update(_ change: (inout SearchRankingSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        port.save(next)
    }

    public func sort(for query: String?) -> SearchSortOrder {
        if let query, let sortOverride, sortOverride.query == query { return sortOverride.sort }
        return settings.sort
    }

    public func toggleSort(for query: String) {
        setSort(sort(for: query).other, for: query)
    }

    public func setSort(_ sort: SearchSortOrder, for query: String) {
        let next = sort == settings.sort ? nil : SearchSortOverride(query: query, sort: sort)
        guard next != sortOverride else { return }
        sortOverride = next
        port.setSortOverride(next)
    }

    @ObservationIgnored private(set) var lastOpenRecord: Task<Void, Never>?

    public func noteOpened(_ thread: ThreadKey, from location: MailLocation?) {
        guard case .search? = location else { return }
        let port = self.port
        lastOpenRecord = Task { await port.recordOpen(thread) }
    }

    public func refresh() async {
        rememberedConversations = await port.rememberedConversations()
    }

    public func resetLearning() async {
        await port.resetLearning()
        rememberedConversations = await port.rememberedConversations()
        notices?.post(Self.resetMessage, style: .info, duration: NoticeCenter.infoDuration)
    }
}

public final class InMemorySearchRankingPort: SearchRankingPort {
    private struct State {
        var settings: SearchRankingSettings
        var override: SearchSortOverride?
        var opens: [ThreadKey: Int] = [:]
    }
    private let state: Mutex<State>

    public init(settings: SearchRankingSettings = .defaults) {
        state = Mutex(State(settings: settings))
    }

    public func settings() -> SearchRankingSettings { state.withLock { $0.settings } }
    public func save(_ settings: SearchRankingSettings) { state.withLock { $0.settings = settings } }
    public func sortOverride() -> SearchSortOverride? { state.withLock { $0.override } }
    public func setSortOverride(_ override: SearchSortOverride?) { state.withLock { $0.override = override } }
    public func recordOpen(_ thread: ThreadKey) async { state.withLock { $0.opens[thread, default: 0] += 1 } }
    public func rememberedConversations() async -> Int { state.withLock { $0.opens.count } }
    public func resetLearning() async { state.withLock { $0.opens = [:] } }

    public func opens(_ thread: ThreadKey) -> Int { state.withLock { $0.opens[thread] ?? 0 } }
}

@MainActor
final class SearchRankingActionHandler: ActionHandler {
    static let ids: [ActionID] = [.resetSearchLearning, .toggleSearchSort, .copySearchRanking]
    private weak var environment: AppEnvironment?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        guard environment != nil else { return .hidden }
        switch id {
        case .toggleSearchSort:
            guard case .search? = context.location else { return .hidden }
            return .enabled
        case .copySearchRanking:
            guard case .search? = context.location, context.focusedThread != nil else { return .hidden }
            return .enabled
        default:
            return .enabled
        }
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let environment else { return .notHandled }
        let model = environment.searchRanking
        switch request.id {
        case .resetSearchLearning:
            return .started(Task { await model.resetLearning() })
        case .toggleSearchSort:
            guard case .search(let query)? = request.context.location else { return .notHandled }
            model.toggleSort(for: query)
            let order = model.sort(for: query).title
            environment.notices.post("Sorted by \(order.lowercased())", style: .info, duration: NoticeCenter.infoDuration)
            return .done
        case .copySearchRanking:
            guard let thread = request.context.focusedThread,
                  let explanation = request.router?.active?.list?.searchStatus?.explanations[thread.rowID] else {
                environment.notices.post("No ranking details for this conversation", style: .info,
                                         duration: NoticeCenter.infoDuration)
                return .done
            }
            environment.system.platform.copyToClipboard(explanation.text)
            environment.notices.post("Ranking details copied", style: .info, duration: NoticeCenter.infoDuration)
            return .done
        default:
            return .notHandled
        }
    }
}
