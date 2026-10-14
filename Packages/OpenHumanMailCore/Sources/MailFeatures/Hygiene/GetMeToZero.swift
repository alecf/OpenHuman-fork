import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class GetMeToZeroModel {
    public enum Age: Int, CaseIterable, Identifiable, Sendable {
        case day = 1, week = 7, month = 30, everything = 0
        public var id: Int { rawValue }
        public var title: String {
            switch self {
            case .day: "Older than a day"
            case .week: "Older than a week"
            case .month: "Older than a month"
            case .everything: "Everything in the inbox"
            }
        }
    }

    struct Candidate: Sendable {
        let key: ThreadKey
        let lastMessageAt: Date
        let isUnread: Bool
        let isStarred: Bool
    }

    public static let maxConversations = 10_000

    public let account: AccountID
    public var age: Age = .week { didSet { recount() } }
    public var keepUnread = true { didSet { recount() } }
    public var keepStarred = true { didSet { recount() } }
    public private(set) var isLoading = true
    public private(set) var isPartial = false
    public private(set) var matchCount = 0
    public private(set) var loadError: String?
    public private(set) var isClosed = false

    @ObservationIgnored private var candidates: [Candidate] = []
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let onConfirm: @MainActor ([ThreadKey]) -> Void

    public init(account: AccountID, now: @escaping @Sendable () -> Date = { Date() },
                confirm: @escaping @MainActor ([ThreadKey]) -> Void) {
        self.account = account
        self.now = now
        self.onConfirm = confirm
    }

    public var title: String { "Get me to zero" }
    public var footer: String { "Archived mail stays in Done and search. Undo with ⌘Z, or Bulk actions for 7 days." }

    public var confirmTitle: String {
        matchCount == 1 ? "Archive 1 conversation" : "Archive \(matchCount.formatted()) conversations"
    }

    public func load(from data: any MailDataSource) async {
        var found: [Candidate] = []
        var cursor: PageCursor?
        do {
            repeat {
                let page = try await data.threadPage(.system(.inbox), account: account, after: cursor, limit: 500)
                found += page.rows.map {
                    Candidate(key: $0.id, lastMessageAt: $0.lastMessageAt, isUnread: $0.isUnread, isStarred: $0.isStarred)
                }
                cursor = page.next
            } while cursor != nil && found.count < Self.maxConversations && !Task.isCancelled
        } catch {
            loadError = "Couldn't read the inbox"
        }
        isPartial = cursor != nil
        candidates = found
        isLoading = false
        recount()
    }

    func setCandidates(_ values: [Candidate]) {
        candidates = values
        isLoading = false
        recount()
    }

    public func matches() -> [ThreadKey] {
        let cutoff = age == .everything ? nil : now().addingTimeInterval(-Double(age.rawValue) * 86_400)
        return candidates.filter { c in
            if let cutoff, c.lastMessageAt >= cutoff { return false }
            if keepUnread && c.isUnread { return false }
            if keepStarred && c.isStarred { return false }
            return true
        }.map(\.key)
    }

    private func recount() { matchCount = matches().count }

    @discardableResult
    public func chooseNumber(_ n: Int) -> Bool {
        let all = Age.allCases
        guard (1...all.count).contains(n) else { return false }
        age = all[n - 1]
        return true
    }

    public func confirm() {
        guard !isClosed, !isLoading, matchCount > 0 else { return }
        let keys = matches()
        isClosed = true
        onConfirm(keys)
    }

    public func close() { isClosed = true }
}

@MainActor
enum BulkArchive {
    static func archive(_ keys: [ThreadKey], account: AccountID, environment: AppEnvironment,
                        now: Date = Date()) async {
        guard !keys.isEmpty else { return }
        let router = environment.router
        var context = router.actionContext()
        context.account = account
        context.selection = keys
        context.focusedThread = nil
        guard await environment.actions.run(.markDone, source: .palette, host: router, context: context) else { return }
        try? await environment.settings?.set(AppSettings.lastBulkArchive,
                                             BulkArchiveReceipt(account: account, threads: keys, archivedAt: now))
    }

    static func revert(environment: AppEnvironment, now: Date = Date()) async {
        let notices = environment.notices
        let receipt = try? await environment.settings?.get(AppSettings.lastBulkArchive)
        guard let receipt = receipt ?? nil, receipt.isReversible(at: now), !receipt.threads.isEmpty else {
            notices.post("No bulk archive to undo. Get me to zero can be undone for 7 days.", style: .info,
                         duration: NoticeCenter.infoDuration)
            return
        }
        let router = environment.router
        var context = router.actionContext()
        context.account = receipt.account
        context.selection = receipt.threads
        context.focusedThread = nil
        context.location = .system(.done)
        guard await environment.actions.run(.moveToInbox, source: .palette, host: router, context: context) else { return }
        try? await environment.settings?.set(AppSettings.lastBulkArchive, nil)
    }
}

@MainActor
final class HygieneActionHandler: ActionHandler {
    static let ids: [ActionID] = [.getMeToZero, .undoBulkArchive, .suggestCleanup, .archiveSuggested]
    private weak var environment: AppEnvironment?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        switch id {
        case .suggestCleanup:
            return context.account != nil && environment?.archiveSuggestion != nil ? .enabled : .hidden
        case .archiveSuggested:
            guard let suggestion = environment?.archiveSuggestion?.suggestion,
                  context.account == nil || context.account == suggestion.account else { return .hidden }
            return .enabled
        default:
            break
        }
        guard let presenter = environment?.actions.presenter else { return .hidden }
        switch id {
        case .getMeToZero: return presenter.canPresent(.getMeToZero) && context.account != nil ? .enabled : .hidden
        default: return .enabled
        }
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let environment else { return .notHandled }
        switch request.id {
        case .getMeToZero:
            guard let account = request.context.account, let presenter = environment.actions.presenter,
                  presenter.canPresent(.getMeToZero) else { return .notHandled }
            presenter.present(.getMeToZero(account: account))
            return .done
        case .undoBulkArchive:
            return .started(Task { await BulkArchive.revert(environment: environment) })
        case .suggestCleanup:
            guard let model = environment.archiveSuggestion else { return .notHandled }
            return .started(Task { await model.checkNow() })
        case .archiveSuggested:
            guard let model = environment.archiveSuggestion, model.suggestion != nil else { return .notHandled }
            return .started(Task { await model.confirm() })
        default:
            return .notHandled
        }
    }
}

public struct HygieneModule: FeatureModule {
    public static let id = FeatureModuleID.hygiene
    public static let defaultEnabled = true
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.actions(ActionCatalog.descriptors(module: Self.id), handler: HygieneActionHandler(environment: env))
        registry.onLaunch { [weak env] in env?.archiveSuggestion?.startSchedule() }
    }
}
