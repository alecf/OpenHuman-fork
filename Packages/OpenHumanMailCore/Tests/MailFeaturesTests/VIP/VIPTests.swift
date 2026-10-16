import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

private let day: TimeInterval = 86_400

private final class CountingImportance: ImportanceRulesPort {
    let fake: FakeImportanceRules
    private let counters = Mutex<[AccountID: [ContactReplyCounter]]>([:])

    init() { fake = FakeImportanceRules() }

    func setCounters(_ list: [ContactReplyCounter], for account: AccountID) { counters.withLock { $0[account] = list } }

    func replyCounters(_ account: AccountID, since: Date) async throws -> [ContactReplyCounter] {
        counters.withLock { $0[account] ?? [] }.map { counter in
            ContactReplyCounter(email: counter.email, name: counter.name, repliedAt: counter.repliedAt.filter { $0 >= since })
        }
    }

    func apply(_ change: ImportanceChange) async throws -> UndoToken { try await fake.apply(change) }
    func explain(_ thread: ThreadKey) async throws -> ImportanceExplanation { try await fake.explain(thread) }
    func rules(_ account: AccountID) -> AsyncThrowingStream<[ImportanceRuleInfo], Error> { fake.rules(account) }
    func update(_ id: String, to change: ImportanceChange) async throws -> UndoToken { try await fake.update(id, to: change) }
    func delete(_ ids: [String]) async throws -> UndoToken { try await fake.delete(ids) }
    func undo(_ token: UndoToken) async throws -> UndoToken? { try await fake.undo(token) }
}

private func replies(_ email: String, name: String? = nil, daysAgo: [Double]) -> ContactReplyCounter {
    ContactReplyCounter(email: email, name: name, repliedAt: daysAgo.map { fixedNow.addingTimeInterval(-$0 * day) })
}

private func row(_ account: AccountID, from email: String, isMe: Bool = false) -> ThreadRow {
    ThreadRow(id: ThreadKey(account: account, rowID: 1, gmailThreadID: GmailThreadID("t-vip")), subject: "Plans",
              snippet: "", participantsDisplay: "Dana, me",
              participants: [Participant(name: "Dana Ruiz", email: email, isMe: isMe, hasUnread: true),
                             Participant(name: nil, email: "me@example.com", isMe: true, hasUnread: false)],
              messageCount: 2, unreadCount: 1, draftCount: 0, attachmentCount: 0, isUnread: true, isStarred: false,
              isImportant: true, userLabelIDs: [], lastMessageAt: fixedNow, sortAt: fixedNow)
}

@Test func recencyWeightingHalvesEveryTwoWeeksAndTheWindowIsThirtyDays() {
    let now = fixedNow
    #expect(VIPSuggestionPolicy.weightedFrequency([now], now: now) == 1)
    #expect(abs(VIPSuggestionPolicy.weightedFrequency([now.addingTimeInterval(-14 * day)], now: now) - 0.5) < 1e-9)
    #expect(abs(VIPSuggestionPolicy.weightedFrequency([now.addingTimeInterval(-28 * day)], now: now) - 0.25) < 1e-9)
    #expect(VIPSuggestionPolicy.weightedFrequency([now.addingTimeInterval(3600)], now: now) == 1, "the future counts as now")
    #expect(VIPSuggestionPolicy.weightedFrequency([], now: now) == 0)
    let dates = [0, 29.9, 30, 30.1, 60].map { now.addingTimeInterval(-$0 * day) }
    #expect(VIPSuggestionPolicy.recentCount(dates, now: now) == 3, "30 days inclusive")
}

@Test func threeRepliesInThirtyDaysAreSuggestedStrongestFirst() {
    let account = AccountID(1)
    let counters = [
        replies("two@example.com", daysAgo: [1, 2]),
        replies("old@example.com", daysAgo: [31, 40, 50, 60]),
        replies("steady@example.com", name: "Steady Lee", daysAgo: [20, 25, 28]),
        replies("dana@example.com", name: "Dana Ruiz", daysAgo: [1, 2, 3, 45]),
        replies("noreply@example.com", daysAgo: [1, 2, 3, 4]),
    ]
    let found = VIPSuggestionPolicy.suggestions(counters, account: account, now: fixedNow, excludedSenders: [],
                                                excludedDomains: [])
    #expect(found.map(\.email) == ["dana@example.com", "steady@example.com"], "recent replies weigh more")
    #expect(found[0].recentReplies == 3 && found[0].score > found[1].score)
    #expect(found[0].question == "Mark Dana Ruiz as VIP?")
    #expect(found[0].reason == "You replied 3 times in the last 30 days.")
    #expect(VIPSuggestion(account: account, email: "x@example.com", name: " ", recentReplies: 1, score: 1).displayName
            == "x@example.com")
    #expect(VIPSuggestionPolicy.suggestions(counters, account: account, now: fixedNow, minimumReplies: 4,
                                            excludedSenders: [], excludedDomains: []).isEmpty)
    let many = (0..<14).map { replies("p\($0)@example.com", daysAgo: [1, 2, 3]) }
    #expect(VIPSuggestionPolicy.suggestions(many, account: account, now: fixedNow, excludedSenders: [],
                                            excludedDomains: []).count == 10)
}

@Test func peopleWithRulesVIPsAndDeclinedPeopleAreNeverSuggested() {
    let account = AccountID(1)
    let rules = [
        ImportanceRuleInfo(id: "r1", kind: .neverSender, account: account, value: "never@example.com", split: nil,
                           createdAt: fixedNow),
        ImportanceRuleInfo(id: "r2", kind: .alwaysDomain, account: account, value: "acme.example", split: nil,
                           createdAt: fixedNow),
        ImportanceRuleInfo(id: "r3", kind: .notPitch, account: account, value: "pitch@example.com", split: nil,
                           createdAt: fixedNow),
    ]
    let excluded = VIPSuggestionPolicy.exclusions(rules: rules, marked: ["vip@example.com"], declined: ["no@example.com"])
    #expect(excluded.senders == ["never@example.com", "pitch@example.com", "vip@example.com", "no@example.com"])
    #expect(excluded.domains == ["acme.example"])
    let counters = ["never@example.com", "pat@acme.example", "pitch@example.com", "vip@example.com", "no@example.com",
                    "ok@example.com"].map { replies($0, daysAgo: [1, 2, 3]) }
    let found = VIPSuggestionPolicy.suggestions(counters, account: account, now: fixedNow,
                                                excludedSenders: excluded.senders, excludedDomains: excluded.domains)
    #expect(found.map(\.email) == ["ok@example.com"])
}

@MainActor
private func startedCenter(_ importance: CountingImportance, undo: UndoCoordinator? = nil)
    async -> (VIPCenter, SettingsFixture) {
    let f = SettingsFixture()
    let center = VIPCenter(data: f.env.data, importance: importance, settings: f.env.settings, undo: undo,
                           now: { fixedNow })
    center.start()
    await untilObserved { _ = center.revision; return center.hasLoaded(f.work) && center.hasLoaded(f.personal) }
    return (center, f)
}

@MainActor
@Test func acceptingMakesAUserSenderRuleAndAVIPChipAndUndoTakesBothBack() async throws {
    let importance = CountingImportance()
    let (center, f) = await startedCenter(importance)
    importance.setCounters([replies("dana@example.com", name: "Dana Ruiz", daysAgo: [1, 5, 9])], for: f.work)
    let suggestion = try #require(await center.suggestions(for: f.work).first)
    #expect(suggestion.email == "dana@example.com")
    #expect(importance.fake.allRules.isEmpty, "a suggestion changes nothing by itself")
    #expect(!center.hasVIPSender(row(f.work, from: "dana@example.com")))

    try await center.accept(suggestion)
    let rule = try #require(importance.fake.allRules.first)
    #expect(rule.kind == .alwaysSender && rule.value == "dana@example.com" && rule.origin == .user && rule.match == .sender)
    #expect(try await f.env.settings!.get(VIPSettings.marked(f.work)) == ["dana@example.com"])
    await eventually { center.isVIP("Dana@Example.com", account: f.work) }
    #expect(center.hasVIPSender(row(f.work, from: "dana@example.com")))
    #expect(!center.hasVIPSender(row(f.work, from: "dana@example.com", isMe: true)), "never the user's own address")
    #expect(!center.isVIP("dana@example.com", account: f.personal), "per account")
    #expect(center.vips(for: f.work) == ["dana@example.com"])
    #expect(await center.suggestions(for: f.work).isEmpty, "a VIP is not suggested again")
    #expect(center.lastChange?.title == "Marked Dana Ruiz as VIP")

    try await center.undoLastChange()
    #expect(importance.fake.allRules.isEmpty)
    #expect(try await f.env.settings!.get(VIPSettings.marked(f.work)) == [])
    await eventually { !center.isVIP("dana@example.com", account: f.work) }

    try await center.accept(suggestion)
    await eventually { center.isVIP("dana@example.com", account: f.work) }
    _ = try await importance.delete(importance.fake.allRules.map(\.id))
    await eventually { !center.isVIP("dana@example.com", account: f.work) }
}

@MainActor
@Test func acceptOnTheWindowUndoStackIsOneEntry() async throws {
    let importance = CountingImportance()
    let undo = UndoCoordinator(commands: importance, notices: nil)
    let (center, f) = await startedCenter(importance, undo: undo)
    importance.setCounters([replies("dana@example.com", name: "Dana Ruiz", daysAgo: [1, 2, 3])], for: f.work)
    let suggestion = try #require(await center.suggestions(for: f.work).first)
    try await center.accept(suggestion)
    #expect(undo.stack.count == 1 && center.lastChange == nil)
    await undo.undoLast()
    #expect(importance.fake.allRules.isEmpty)
    #expect(try await f.env.settings!.get(VIPSettings.marked(f.work)) == [])
    await undo.redoLast()
    #expect(importance.fake.allRules.map(\.value) == ["dana@example.com"])
    #expect(try await f.env.settings!.get(VIPSettings.marked(f.work)) == ["dana@example.com"])
}

@MainActor
@Test func notNowIsRememberedUntilResetAndTheSwitchHidesSuggestions() async throws {
    let importance = CountingImportance()
    let (center, f) = await startedCenter(importance)
    importance.setCounters([replies("dana@example.com", daysAgo: [1, 2, 3]), replies("lee@example.com", daysAgo: [1, 2, 3])],
                           for: f.work)
    let dana = try #require(await center.suggestions(for: f.work).first { $0.email == "dana@example.com" })
    try await center.decline(dana)
    #expect(importance.fake.allRules.isEmpty, "Not now makes no rule")
    #expect(try await f.env.settings!.get(VIPSettings.declined(f.work)) == ["dana@example.com"])
    #expect(await center.suggestions(for: f.work).map(\.email) == ["lee@example.com"])
    try await center.undoLastChange()
    #expect(try await f.env.settings!.get(VIPSettings.declined(f.work)) == [])
    try await center.decline(dana)
    try await center.resetSuggestions(accounts: [f.work, f.personal])
    #expect(try await f.env.settings!.get(VIPSettings.declined(f.work)) == [])
    #expect(Set(await center.suggestions(for: f.work).map(\.email)) == ["dana@example.com", "lee@example.com"])

    try await center.setSuggestEnabled(false)
    #expect(await center.suggestions(for: f.work).isEmpty)
    #expect(try await f.env.settings!.get(VIPSettings.suggest) == false)
    try await center.setSuggestEnabled(true)
    #expect(await center.suggestions(for: f.work).count == 2)
}

@MainActor
@Test func aRefusedRuleMarksNothingAndDeclineStillWorks() async throws {
    let importance = CountingImportance()
    let (center, f) = await startedCenter(importance)
    importance.setCounters([replies("dana@example.com", daysAgo: [1, 2, 3])], for: f.work)
    let model = VIPSettingsModel(center: center, data: f.env.data, canMarkVIPs: true)
    model.start()
    await eventually { model.account != nil }
    model.account = f.work
    model.refresh()
    await model.settle()
    let suggestion = try #require(model.suggestions.first)
    importance.fake.failNext(.unavailable("importance rules"))
    await model.accept(suggestion)
    #expect(model.errorMessage == MailPortError.unavailable("importance rules").description)
    #expect(try await f.env.settings!.get(VIPSettings.marked(f.work)) == [])
    await model.decline(suggestion)
    #expect(model.errorMessage == nil && model.notice == "Mail won't suggest dana@example.com again.")
    await model.settle()
    #expect(model.suggestions.isEmpty)
}

@MainActor
@Test func theListShowsAStarredVIPChipFirst() async throws {
    let importance = CountingImportance()
    let (center, f) = await startedCenter(importance)
    importance.setCounters([replies("dana@example.com", daysAgo: [1, 2, 3])], for: f.work)
    try await center.accept(try #require(await center.suggestions(for: f.work).first))
    await eventually { center.isVIP("dana@example.com", account: f.work) }
    let list = ThreadListModel(data: f.env.data, location: .system(.inbox), account: f.work)
    list.attachVIPs(center)
    let chips = list.chips(for: row(f.work, from: "dana@example.com"))
    #expect(chips.first == ThreadRowChip(kind: .vip, title: "VIP"))
    #expect(!list.chips(for: row(f.work, from: "sam@example.com")).contains { $0.kind == .vip })
    let format = ThreadRowFormatting()
    #expect(format.accessibilityLabel(row(f.work, from: "dana@example.com"), chips: chips, location: .system(.inbox),
                                      now: fixedNow).contains("from a VIP"))
}

@MainActor
@Test(.timeLimit(.minutes(1))) func vipMailPassesAFocusHoldAndOtherMailStaysHeld() async throws {
    let store = FakeMailStore(corpus: .rich(threadCount: 40, now: fixedNow),
                              options: .init(remoteAck: .immediate, now: { fixedNow }))
    let importance = CountingImportance()
    let notifier = FakeSystemNotifier(authorization: .authorized)
    let env = AppEnvironment(data: store, commands: RecordingCommands(store), accounts: store, settings: store,
                             isFake: true, importance: importance)
    env.installPlatform(SystemPlatform(notifier: notifier, dock: FakeDockBadge(), loginItem: FakeLoginItem(),
                                       urlOpener: FakeURLOpener(), menuBarItem: FakeMenuBarItem(), isAppActive: { false }))
    env.system.coalesce = .milliseconds(20)
    env.router.start()
    await eventually { env.router.accounts.count == 2 && env.router.list?.state == .loaded }
    let work = AccountID(1), personal = AccountID(2)
    let vip = EmailAddress(name: "Val Ipson", email: "val@vip-sender.example")
    _ = try await importance.apply(ImportanceChange(kind: .alwaysSender, account: personal, value: vip.email))
    try await store.set(VIPSettings.marked(personal), [vip.email])
    await eventually { env.vips.isVIP(vip.email, account: personal) }

    env.system.startFocusFilters()
    let focus = try #require(env.system.focus)
    focus.sleep = { _ in }
    await focus.waitForLaunch()
    env.system.startNotifications()
    let service = try #require(env.system.notifications)
    await eventually { service.hasBaseline(for: work) && service.hasBaseline(for: personal) }
    await env.system.applyFocusFilter(FocusFilterState(accounts: [work], holdOtherNotifications: true))
    #expect(focus.holdsNewMail(for: personal))

    store.deliverMessage(account: personal, from: vip, subject: "VIPMARK plans", important: true)
    store.deliverMessage(account: personal, from: EmailAddress(name: "Ola Other", email: "ola@other-sender.example"),
                         subject: "OTHERMARK news", important: true)
    await eventually { focus.held.count == 1 }
    await service.flushNow()
    await eventually { notifier.delivered.count == 1 }
    #expect(focus.held.count == 1, "the other conversation waits for the Focus summary")
}
