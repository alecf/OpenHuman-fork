import Foundation
import MailActions
import MailModel
import OpenHumanCore
import OpenHumanLinks

public enum IntentError: Error, Equatable, Sendable, CustomStringConvertible, CustomLocalizedStringResourceConvertible {
    case turnedOff
    case notReady
    case noAccount
    case unknownAccount
    case moduleOff(String)
    case changesOff
    case declined
    case nothingGiven
    case tooMany
    case rateLimited
    case notLocal
    case pastDate
    case emptyQuery
    case unavailable(String)
    case refused(String)
    case notChanged

    public var message: String {
        switch self {
        case .turnedOff: "Shortcuts are off in Mail. Turn them on in Settings › Platform features."
        case .notReady: "Mail is still starting. Try again in a moment."
        case .noAccount: "No account is open in Mail."
        case .unknownAccount: "That account isn't signed in to Mail. Nothing was changed."
        case .moduleOff(let what): "\(what) isn't turned on in Mail."
        case .changesOff: "Shortcuts can't change mail. Turn on “Let Shortcuts change mail” in Settings › Platform features."
        case .declined: "Nothing was changed."
        case .nothingGiven: "No conversations were given. Nothing was changed."
        case .tooMany: "Shortcuts can change at most 50 conversations at a time. Nothing was changed."
        case .rateLimited: "Too many changes from Shortcuts at once. Nothing was changed; try again in a moment."
        case .notLocal: "That conversation isn't on this Mac. Nothing was changed."
        case .pastDate: "Pick a time in the future. Nothing was changed."
        case .emptyQuery: "Type something to search for."
        case .unavailable(let what): "\(what) isn't available with this mail source yet."
        case .refused(let text): text
        case .notChanged: "Mail couldn't make that change. Nothing was changed; Mail's window says why."
        }
    }

    var code: String {
        switch self {
        case .turnedOff: "turned off"
        case .notReady: "not ready"
        case .noAccount: "no account"
        case .unknownAccount: "unknown account"
        case .moduleOff: "module off"
        case .changesOff: "changes off"
        case .declined: "declined"
        case .nothingGiven: "nothing given"
        case .tooMany: "too many"
        case .rateLimited: "rate limited"
        case .notLocal: "not local"
        case .pastDate: "past date"
        case .emptyQuery: "empty query"
        case .unavailable: "unavailable"
        case .refused: "refused"
        case .notChanged: "not changed"
        }
    }

    public var description: String { message }
    public var localizedStringResource: LocalizedStringResource { "\(message)" }
}

public typealias IntentConfirmation = @MainActor (String) async -> Bool

@MainActor
public protocol IntentPerforming: AnyObject, Sendable {
    func countUnread(account: String?, kind: IntentUnreadKind) async throws -> Int
    func findConversations(_ query: String, account: String?, limit: Int, importantOnly: Bool) async throws -> [IntentThread]
    func openMailbox(_ mailbox: IntentMailbox, account: String?) async throws
    func openThread(_ id: String) async throws
    func searchMail(_ query: String, account: String?) async throws
    func newMessage(account: String?, to: [String], subject: String?, body: String?) async throws
    func openReviewQueue(account: String?) async throws
    func markDone(_ ids: [String], confirm: IntentConfirmation) async throws -> String
    func snooze(_ ids: [String], until date: Date, confirm: IntentConfirmation) async throws -> String
    func remind(_ id: String, at date: Date, onlyIfNoReply: Bool, confirm: IntentConfirmation) async throws -> String
    func accounts() async throws -> [IntentAccount]
    func threads(for ids: [String]) async throws -> [IntentThread]
    func suggestedThreads() async throws -> [IntentThread]
    func threads(matching text: String) async throws -> [IntentThread]
    func applyFocusFilter(_ state: FocusFilterState?) async
    func focusAccounts() async -> [IntentAccount]
}

@MainActor
public final class IntentActions: IntentPerforming {
    public struct Limits: Sendable {
        public var readyTimeout: Duration = .seconds(10)
        public var readyPoll: Duration = .milliseconds(100)
        public var maxConversations = 50
        public var maxRuns = 5
        public var runWindow: TimeInterval = 10
        public var maxResults = 20
        public var lookupResults = 10

        public init() {}
    }

    public let limits: Limits
    private let routerProvider: @MainActor () -> AppRouter?
    private let links: DeepLinkRouter
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var now: @Sendable () -> Date = { Date() }
    private var runs: [Date] = []
    private let log = Log(.app)

    public init(limits: Limits = Limits(), router: @escaping @MainActor () -> AppRouter?, links: DeepLinkRouter) {
        self.limits = limits
        self.routerProvider = router
        self.links = links
    }

    public func countUnread(account: String?, kind: IntentUnreadKind) async throws -> Int {
        try await logged("CountUnread") {
            let router = try await started()
            var total = 0
            for id in try accountIDs(account, in: router) {
                guard let counts = await Self.firstValue(router.environment.data.counts(id)) else { continue }
                total += kind == .important ? (counts.importantUnread ?? 0) : counts.inboxUnread
            }
            return total
        }
    }

    public func findConversations(_ query: String, account: String?, limit: Int,
                                  importantOnly: Bool) async throws -> [IntentThread] {
        try await logged("FindConversations") {
            let router = try await started()
            return try await find(query, account: account, limit: limit, importantOnly: importantOnly, router: router)
        }
    }

    public func openMailbox(_ mailbox: IntentMailbox, account: String?) async throws {
        try await logged("OpenMailbox") {
            let router = try await started()
            if let module = mailbox.module, !router.environment.modules.modules.contains(module) {
                throw IntentError.moduleOff(mailbox.title)
            }
            if let account { router.switchAccount(to: try accountState(account, in: router).id) }
            guard let active = router.active else { throw IntentError.noAccount }
            if mailbox == .muted, active.mutedLabel == nil {
                throw IntentError.refused("Nothing is muted yet. Press M on a conversation to mute it.")
            }
            router.environment.system.platform.showMainWindow()
            switch mailbox {
            case .important: router.goToImportant()
            case .inbox: router.goToInbox()
            case .muted:
                if let label = active.mutedLabel { router.go(to: .label(label.labelID)) }
            default:
                if let action = mailbox.action, let location = AppRouter.goLocation(action) { router.go(to: location) }
            }
        }
    }

    public func openReviewQueue(account: String?) async throws {
        try await openMailbox(.reviewQueue, account: account)
    }

    public func openThread(_ id: String) async throws {
        try await logged("OpenThread") {
            let router = try await started()
            guard SpotlightIdentifier.parse(id) != nil else { throw IntentError.notLocal }
            guard let url = SpotlightIdentifier.deepLink(for: id, accounts: router.accounts.map(\.account)) else {
                throw IntentError.unknownAccount
            }
            try follow(url, router: router)
        }
    }

    public func searchMail(_ query: String, account: String?) async throws {
        try await logged("SearchMail") {
            let router = try await started()
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw IntentError.emptyQuery }
            let ref = try account.map { AccountRef(try accountState($0, in: router).account.email) }
            try follow(MailLinkBuilder.url(for: .search(query: text, account: ref)), router: router)
        }
    }

    public func newMessage(account: String?, to: [String], subject: String?, body: String?) async throws {
        try await logged("NewMessage") {
            let router = try await started()
            let ref = try account.map { AccountRef(try accountState($0, in: router).account.email) }
            let recipients = to.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard recipients.count <= LinkGrammar.maxRecipients else {
                throw IntentError.refused("A new message from Shortcuts can have at most \(LinkGrammar.maxRecipients) recipients.")
            }
            let prefill = ComposePrefill(account: ref, to: recipients, subject: Self.nonEmpty(subject),
                                         body: Self.nonEmpty(body))
            let url = MailLinkBuilder.url(for: .compose(prefill))
            if case .failure(let error) = MailLinkParser.parse(url) { throw IntentError.refused(Self.composeProblem(error)) }
            try follow(url, router: router)
        }
    }

    public func markDone(_ ids: [String], confirm: IntentConfirmation) async throws -> String {
        try await logged("MarkDone") {
            let (router, groups) = try await prepareChange(.markDone, ids: ids, date: nil, confirm: confirm) { groups in
                "Mark \(Self.counted(groups, verbAfterFirst: " done"))?"
            }
            var changed = 0
            var unchanged: [String] = []
            for group in groups {
                let before = router.environment.undo?.stack.last?.id
                await router.environment.actions.run(.markDone, source: .intent, host: router,
                                                     context: changeContext(group, router: router))
                if Self.recorded(router, after: before) { changed += group.keys.count } else { unchanged.append(group.name) }
            }
            return try Self.outcome(changed: changed, unchanged: unchanged,
                                    done: changed == 1 ? "Marked 1 conversation done" : "Marked \(changed) conversations done")
        }
    }

    public func snooze(_ ids: [String], until date: Date, confirm: IntentConfirmation) async throws -> String {
        try await logged("Snooze") {
            let (router, groups) = try await prepareChange(.snooze, ids: ids, date: date, confirm: confirm) { groups in
                "Snooze \(Self.counted(groups)) until \(self.time(date))?"
            }
            guard let handler = router.environment.actions.threadActions else { throw IntentError.notChanged }
            var changed = 0
            var unchanged: [String] = []
            for group in groups {
                let before = router.environment.undo?.stack.last?.id
                await handler.snooze(group.keys, until: date, host: router, source: .intent)?.value
                if Self.recorded(router, after: before) { changed += group.keys.count } else { unchanged.append(group.name) }
            }
            let when = handler.time(date)
            return try Self.outcome(changed: changed, unchanged: unchanged,
                                    done: changed == 1 ? "Snoozed 1 conversation until \(when)"
                                                       : "Snoozed \(changed) conversations until \(when)")
        }
    }

    public func remind(_ id: String, at date: Date, onlyIfNoReply: Bool,
                       confirm: IntentConfirmation) async throws -> String {
        try await logged("RemindMe") {
            let (router, groups) = try await prepareChange(.remind, ids: [id], date: date, confirm: confirm) { groups in
                "Remind you about \(Self.counted(groups)) at \(self.time(date))"
                    + (onlyIfNoReply ? " if nobody replies?" : "?")
            }
            guard let handler = router.environment.actions.threadActions, let group = groups.first,
                  let key = group.keys.first else { throw IntentError.notChanged }
            let before = router.environment.undo?.stack.last?.id
            await handler.remind(key, at: date, kind: onlyIfNoReply ? .ifNoReply : .always, host: router,
                                 source: .intent)?.value
            guard Self.recorded(router, after: before) else { throw IntentError.notChanged }
            return String(localized: Titles.reminderSet(handler.time(date), ifNoReply: onlyIfNoReply)) + "."
        }
    }

    public func accounts() async throws -> [IntentAccount] {
        try await logged("Accounts") {
            let router = try await readyRouter()
            guard preferences(router).isEnabled || router.environment.system.focus != nil else {
                throw IntentError.turnedOff
            }
            return router.accounts.map { IntentEntityBuilder.account($0.account) }
        }
    }

    public func threads(for ids: [String]) async throws -> [IntentThread] {
        try await logged("ThreadLookup") {
            let router = try await started()
            let include = preferences(router).shareSubjects
            var found: [IntentThread] = []
            for id in ids {
                guard let parsed = SpotlightIdentifier.parse(id),
                      let account = router.accounts.first(where: { $0.id == parsed.account })?.account,
                      let row = try? await router.environment.data.localThread(parsed.account,
                                                                              gmailThreadID: parsed.thread) else { continue }
                found.append(IntentEntityBuilder.thread(IntentRowFacts(row), account: account, includeSubjects: include))
            }
            return found
        }
    }

    public func suggestedThreads() async throws -> [IntentThread] {
        try await logged("ThreadSuggestions") {
            let router = try await started()
            guard let active = router.active else { return [] }
            let window = await Self.firstValue(router.environment.data.threadWindow(.system(.inbox), account: active.id,
                                                                                    limit: 100))
            let include = preferences(router).shareSubjects
            return (window?.rows ?? []).filter { $0.isUnread && $0.isImportant }.prefix(limits.lookupResults).map {
                IntentEntityBuilder.thread(IntentRowFacts($0), account: active.account, includeSubjects: include)
            }
        }
    }

    public func threads(matching text: String) async throws -> [IntentThread] {
        try await logged("ThreadSearch") {
            let router = try await started()
            return try await find(text, account: nil, limit: limits.lookupResults, importantOnly: false, router: router)
        }
    }

    public func applyFocusFilter(_ state: FocusFilterState?) async {
        guard let router = try? await readyRouter() else {
            log.info("intent FocusFilter: not ready")
            return
        }
        await router.environment.system.applyFocusFilter(state)
        log.info("intent FocusFilter: ok")
    }

    public func focusAccounts() async -> [IntentAccount] {
        guard let router = try? await readyRouter(), router.environment.system.focus != nil else { return [] }
        return router.accounts.map { IntentEntityBuilder.account($0.account) }
    }

    private func readyRouter() async throws -> AppRouter {
        var waited: Duration = .zero
        while true {
            if let router = routerProvider(), router.accountsLoaded { return router }
            guard waited < limits.readyTimeout else { throw IntentError.notReady }
            try? await sleep(limits.readyPoll)
            waited += limits.readyPoll
        }
    }

    private func started() async throws -> AppRouter {
        let router = try await readyRouter()
        guard preferences(router).isEnabled else { throw IntentError.turnedOff }
        return router
    }

    private func preferences(_ router: AppRouter) -> IntentPreferences {
        IntentPreferences(defaults: router.environment.system.preferences.defaults)
    }

    private func accountIDs(_ raw: String?, in router: AppRouter) throws -> [AccountID] {
        guard let raw else { return router.accounts.map(\.id) }
        return [try accountState(raw, in: router).id]
    }

    private func accountState(_ raw: String, in router: AppRouter) throws -> AccountState {
        guard let value = Int64(raw), let state = router.accounts.first(where: { $0.id == AccountID(value) }) else {
            throw IntentError.unknownAccount
        }
        return state
    }

    private func find(_ query: String, account: String?, limit: Int, importantOnly: Bool,
                      router: AppRouter) async throws -> [IntentThread] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw IntentError.emptyQuery }
        let scope = try account.map { try accountIDs($0, in: router) }
        let count = min(max(limit, 1), limits.maxResults)
        let results: SearchResultsInfo?
        do {
            let asked = importantOnly ? limits.maxResults * 5 : count
            results = try await Self.firstThrowing(router.environment.data.search(text, accounts: scope, limit: asked))
        } catch MailPortError.unsupported {
            throw IntentError.unavailable("Search")
        } catch MailPortError.invalidQuery {
            throw IntentError.refused("Mail couldn't read that search.")
        }
        let include = preferences(router).shareSubjects
        let rows = (results?.hits ?? []).map(\.row).filter { !importantOnly || $0.isImportant }.prefix(count)
        return rows.compactMap { row in
            guard let account = router.accounts.first(where: { $0.id == row.id.account })?.account else { return nil }
            return IntentEntityBuilder.thread(IntentRowFacts(row), account: account, includeSubjects: include)
        }
    }

    private func follow(_ url: URL, router: AppRouter) throws {
        router.environment.system.platform.showMainWindow()
        switch links.handle(url, receivedAt: now()) {
        case .followed(let outcome):
            guard outcome.handled else { throw IntentError.refused(outcome.message) }
        case .queued: throw IntentError.notReady
        case .dropped: throw IntentError.refused(DeepLinkRouter.rateLimitedText)
        case .invalid: throw IntentError.refused(DeepLinkRouter.invalidText)
        }
    }

    private struct ChangeGroup {
        let state: AccountState
        let name: String
        let keys: [ThreadKey]
    }

    private func prepareChange(_ id: ActionID, ids: [String], date: Date?, confirm: IntentConfirmation,
                               prompt: ([ChangeGroup]) -> String) async throws -> (AppRouter, [ChangeGroup]) {
        let router = try await started()
        guard preferences(router).allowMailChanges else { throw IntentError.changesOff }
        guard !ids.isEmpty else { throw IntentError.nothingGiven }
        guard ids.count <= limits.maxConversations else { throw IntentError.tooMany }
        if let date, date <= now() { throw IntentError.pastDate }
        try countRun()
        let groups = try await changeGroups(ids, router: router)
        for group in groups {
            switch availability(id, changeContext(group, router: router), router: router) {
            case .enabled:
                break
            case .hidden:
                throw IntentError.moduleOff(ActionCatalog.descriptor(id)?.title.replacingOccurrences(of: "…", with: "")
                                            ?? "This action")
            case .disabled(.unavailable(let what)):
                throw IntentError.unavailable(what.replacingOccurrences(of: "…", with: ""))
            case .disabled(let reason):
                throw IntentError.refused("\(reason.description). Nothing was changed.")
            }
        }
        if preferences(router).askBeforeChanges, await !confirm(prompt(groups)) { throw IntentError.declined }
        return (router, groups)
    }

    private func countRun() throws {
        let current = now()
        runs.removeAll { current.timeIntervalSince($0) >= limits.runWindow }
        guard runs.count < limits.maxRuns else { throw IntentError.rateLimited }
        runs.append(current)
    }

    private func changeGroups(_ ids: [String], router: AppRouter) async throws -> [ChangeGroup] {
        var order: [AccountID] = []
        var keys: [AccountID: [ThreadKey]] = [:]
        for id in ids {
            guard let parsed = SpotlightIdentifier.parse(id) else { throw IntentError.notLocal }
            guard router.accounts.contains(where: { $0.id == parsed.account }) else { throw IntentError.unknownAccount }
            let row: ThreadRow?
            do {
                row = try await router.environment.data.localThread(parsed.account, gmailThreadID: parsed.thread)
            } catch MailPortError.unsupported {
                throw IntentError.unavailable("Finding a conversation for Shortcuts")
            } catch {
                row = nil
            }
            guard let key = row?.id else { throw IntentError.notLocal }
            if keys[parsed.account] == nil { order.append(parsed.account) }
            if keys[parsed.account]?.contains(key) != true { keys[parsed.account, default: []].append(key) }
        }
        return order.compactMap { account in
            guard let state = router.accounts.first(where: { $0.id == account }) else { return nil }
            return ChangeGroup(state: state, name: IntentEntityBuilder.accountTitle(state.account), keys: keys[account] ?? [])
        }
    }

    private func changeContext(_ group: ChangeGroup, router: AppRouter) -> ActionContext {
        let environment = router.environment
        return ActionContext(scope: .list, account: group.state.id, accountCount: router.accounts.count,
                             location: group.state.location, selection: group.keys, focusedThread: group.keys.first,
                             hasRows: true, canWrite: environment.commands != nil,
                             canUndo: environment.undo?.canUndo ?? false, canRedo: environment.undo?.canRedo ?? false)
    }

    private func availability(_ id: ActionID, _ context: ActionContext, router: AppRouter) -> ActionAvailability {
        guard let descriptor = router.environment.actions.descriptor(id) else { return .hidden }
        return ActionRules.availability(descriptor, in: context)
    }

    private static func recorded(_ router: AppRouter, after previous: UUID?) -> Bool {
        guard let last = router.environment.undo?.stack.last?.id else { return false }
        return last != previous
    }

    private static func outcome(changed: Int, unchanged: [String], done: String) throws -> String {
        guard changed > 0 else { throw IntentError.notChanged }
        guard !unchanged.isEmpty else { return done + "." }
        return done + ". Nothing changed in " + unchanged.joined(separator: ", ") + "."
    }

    private static func counted(_ groups: [ChangeGroup], verbAfterFirst: String = "") -> String {
        groups.enumerated().map { index, group in
            let n = group.keys.count
            if index > 0 { return "\(n) in \(group.name)" }
            return "\(n) \(n == 1 ? "conversation" : "conversations")\(verbAfterFirst) in \(group.name)"
        }
        .joined(separator: " and ")
    }

    private func time(_ date: Date) -> String {
        routerProvider()?.environment.actions.threadActions?.time(date)
            ?? date.formatted(date: .abbreviated, time: .shortened)
    }

    private func logged<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            log.info("intent \(name): ok")
            return value
        } catch let error as IntentError {
            log.info("intent \(name): \(error.code)")
            throw error
        }
    }

    private static func firstValue<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async -> T? {
        do {
            for try await value in stream { return value }
        } catch {}
        return nil
    }

    private static func firstThrowing<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async throws -> T? {
        for try await value in stream { return value }
        return nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func composeProblem(_ error: MailLinkError) -> String {
        switch error {
        case .invalidAddress: "One of the recipients isn't an email address Mail can use."
        case .tooManyItems: "A new message from Shortcuts can have at most \(LinkGrammar.maxRecipients) recipients."
        case .tooLong: "The subject or the text is too long for a new message."
        default: DeepLinkRouter.invalidText
        }
    }
}
