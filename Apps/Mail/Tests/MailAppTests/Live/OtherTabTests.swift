import AppKit
import Foundation
import MailFeatures
import MailModel
import OpenHumanCore
import MailUI
import OpenHumanStore
import SwiftUI
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

private func removeSeededCalendarSplit(_ store: MailStore, _ account: AccountID) throws {
    for split in try store.splits(account: account) where split.name == "Calendar" { try store.deleteSplit(split.id) }
    try store.setSetting(.hideSplitWhenEmpty, [], scope: .account(account))
}

@MainActor
@Test(.timeLimit(.minutes(2))) func otherTabExistsForAnAccountWithOnlyTheImportantSplit() async throws {
    let store = try MailStore.openInMemoryForTesting()
    let account = try FixtureStoreSeeder.seedLargeInbox(store, count: 400, now: Date())
    try removeSeededCalendarSplit(store, account)
    var important: [MessageUpsert] = []
    for index in 0..<8 {
        var labels = ["INBOX", "IMPORTANT"]
        if index < 5 { labels.append("UNREAD") }
        important.append(MessageUpsert(
            gmailMessageID: GmailMessageID("im\(index)"), gmailThreadID: GmailThreadID("it\(index)"),
            historyID: HistoryID(UInt64(10_000 + index)), internalDate: Date(), labelIDs: labels.map { GmailLabelID($0) },
            snippet: "Important \(index)", sizeEstimate: 1_000,
            headers: MessageHeaderFields(subject: "Important \(index)", from: EmailAddress(email: "boss@example.com"),
                                         to: [EmailAddress(email: "large@example.com")], cc: [], bcc: [], replyTo: [],
                                         date: Date(), messageID: "<im\(index)@fake.example>", inReplyTo: nil, references: [])))
    }
    _ = try store.upsertMessages(important, account: account, generation: 1)

    let items = try store.splits(account: account)
    #expect(items.map(\.name) == ["Important"], "the splits table holds only the Important row")

    let environment = AppEnvironment(data: MailStoreAdapter(store: store), settings: MailStoreSettings(store: store), isFake: true)
    let router = environment.router
    router.start()
    defer { router.stop() }
    await eventually("tabs") { router.active?.tabs.count == 2 }
    let state = try #require(router.active)
    #expect(state.tabs.map(\.title) == ["Important", "Other"])
    let other = try #require(state.tabs.last)
    #expect(other.location == .splitOther)
    await eventually("other unread") { state.tabs.last?.unread == (0..<400).filter { $0 % 3 == 0 }.count }
    await eventually("other total") { state.tabs.last?.total == 400 }
    #expect(state.tabs.first?.total == 8 && state.tabs.first?.unread == 5)

    router.go(to: .splitOther)
    await eventually("other list") { router.list?.state == .loaded && router.list?.totalCount == 400 }
    #expect(router.list?.rows.allSatisfy { $0.subject.hasPrefix("Synthetic thread") } == true)
}

@MainActor
@Test(.timeLimit(.minutes(2))) func hideWhenEmptyHidesAnEmptyTabButNeverTheSelectedOne() async throws {
    let store = try MailStore.openInMemoryForTesting()
    let account = try FixtureStoreSeeder.seedLargeInbox(store, count: 30, now: Date())
    try removeSeededCalendarSplit(store, account)
    let settings = MailStoreSettings(store: store)
    let environment = AppEnvironment(data: MailStoreAdapter(store: store), settings: settings, isFake: true)
    let router = environment.router
    router.start()
    defer { router.stop() }
    await eventually("tabs") { router.active?.tabs.count == 2 }
    let state = try #require(router.active)
    let important = try #require(try store.splits(account: account).first)
    #expect(state.hiddenWhenEmpty.isEmpty, "off by default for Important and Other")

    router.go(to: .splitOther)
    try await settings.set(AppSettings.hideSplitWhenEmpty(account), [important.id.rawValue, AppSettings.otherSplitToken])
    await eventually("important hidden") { state.tabs.map(\.title) == ["Other"] }
    #expect(state.tabs.first?.total == 30, "Other is not empty, so it stays")

    router.go(to: .split(important.id))
    await eventually("shown tab kept") { state.tabs.map(\.title) == ["Important", "Other"] }
    router.go(to: .splitOther)
    await eventually("hidden again") { state.tabs.map(\.title) == ["Other"] }

    try await settings.set(AppSettings.hideSplitWhenEmpty(account), [])
    await eventually("shown again") { state.tabs.count == 2 }

    let model = SplitSettingsModel(environment: environment)
    model.start()
    await eventually("settings other row") { model.otherTotal == 30 && model.otherUnread == state.tabs.last?.unread }
    await model.setOtherHiddenWhenEmpty(true)
    #expect(try await settings.get(AppSettings.hideSplitWhenEmpty(account)) == [AppSettings.otherSplitToken])
    let split = try #require(model.splits.first)
    await model.setHiddenWhenEmpty(split, true)
    await eventually("both stored") { model.isHiddenWhenEmpty(split) && model.isOtherHiddenWhenEmpty }
}

@MainActor
@Test(.timeLimit(.minutes(2))) func bothTabsStayWhenHideWhenEmptyIsOnButNeitherIsEmpty() async throws {
    let store = try MailStore.openInMemoryForTesting()
    let account = try FixtureStoreSeeder.seedLargeInbox(store, count: 400, now: Date())
    try removeSeededCalendarSplit(store, account)
    var important: [MessageUpsert] = []
    for index in 0..<8 {
        important.append(MessageUpsert(
            gmailMessageID: GmailMessageID("im\(index)"), gmailThreadID: GmailThreadID("it\(index)"),
            historyID: HistoryID(UInt64(10_000 + index)), internalDate: Date(),
            labelIDs: ["INBOX", "IMPORTANT", "UNREAD"].map { GmailLabelID($0) },
            snippet: "Important \(index)", sizeEstimate: 1_000,
            headers: MessageHeaderFields(subject: "Important \(index)", from: EmailAddress(email: "boss@example.com"),
                                         to: [EmailAddress(email: "large@example.com")], cc: [], bcc: [], replyTo: [],
                                         date: Date(), messageID: "<im\(index)@fake.example>", inReplyTo: nil, references: [])))
    }
    _ = try store.upsertMessages(important, account: account, generation: 1)
    let importantID = try #require(try store.splits(account: account).first).id.rawValue
    let settings = MailStoreSettings(store: store)
    try await settings.set(AppSettings.hideSplitWhenEmpty(account), [importantID, AppSettings.otherSplitToken])

    let environment = AppEnvironment(data: MailStoreAdapter(store: store), settings: settings, isFake: true)
    let router = environment.router
    router.start()
    defer { router.stop() }

    var seen: [[String]] = []
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(15)
    var settled = false
    while clock.now < deadline {
        if let state = router.active {
            let titles = state.tabs.map(\.title)
            if seen.last != titles { seen.append(titles) }
            if !state.hiddenWhenEmpty.isEmpty, state.counts != nil, !state.labels.isEmpty, state.location != nil {
                #expect(state.isOnTab, "the toolbar keeps drawing the tab bar")
                settled = true
                break
            }
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(settled)
    #expect(seen.last == ["Important", "Other"])
    #expect(seen.allSatisfy { $0 == ["Important", "Other"] || $0 == ["Inbox"] || $0.isEmpty }, "tab states seen: \(seen)")
    router.go(to: .splitOther)
    router.go(to: .split(try #require(try store.splits(account: account).first).id))
    #expect(router.active?.tabs.map(\.title) == ["Important", "Other"])
}

@MainActor
@Test(.timeLimit(.minutes(2))) func aSavedPlainInboxPlaceOpensOnTheTabsNotTheBareInbox() async throws {
    let store = try MailStore.openInMemoryForTesting()
    let account = try FixtureStoreSeeder.seedLargeInbox(store, count: 120, now: Date())
    try removeSeededCalendarSplit(store, account)
    let saved = InMemoryNavigationStore(NavigationSnapshot(activeAccount: account, places: [
        AccountPlace(account: account, location: .system(.inbox))]))
    let environment = AppEnvironment(data: MailStoreAdapter(store: store), settings: MailStoreSettings(store: store),
                                     isFake: true, navigationStore: saved)
    let router = environment.router
    router.start()
    defer { router.stop() }
    await eventually("tabs") { router.active?.tabs.count == 2 }
    let state = try #require(router.active)
    await eventually("moved to a tab") { state.location == state.tabs.first?.location }
    #expect(state.isOnTab, "the toolbar draws SplitTabBar, not the location title")
    #expect(state.tabs.map(\.title) == ["Important", "Other"])
    await eventually("list") { router.list?.state == .loaded }
}

@MainActor
@Test(.timeLimit(.minutes(2)), arguments: [500.0, 800.0, 1_100.0, 1_500.0])
func theToolbarHoldsTheImportantAndOtherTabsAtEveryWidth(width: Double) async throws {
    let store = try MailStore.openInMemoryForTesting()
    let account = try FixtureStoreSeeder.seedLargeInbox(store, count: 60, now: Date())
    try removeSeededCalendarSplit(store, account)
    let environment = AppEnvironment(data: MailStoreAdapter(store: store), settings: MailStoreSettings(store: store), isFake: true)
    let router = environment.router
    router.start()
    defer { router.stop() }
    await eventually("tabs") { router.active?.tabs.count == 2 && router.active?.isOnTab == true }

    let hosting = NSHostingView(rootView: ShellToolbar(router: router))
    let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: width, height: 120), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(300))
    hosting.layoutSubtreeIfNeeded()
    let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let background = try #require(rep.colorAt(x: 2, y: 2))
    func inkColumns(_ range: Range<Int>) -> Int {
        range.filter { x in
            (0..<rep.pixelsHigh).contains { y in
                guard let c = rep.colorAt(x: x, y: y) else { return false }
                return abs(c.redComponent - background.redComponent) + abs(c.greenComponent - background.greenComponent)
                    + abs(c.blueComponent - background.blueComponent) > 0.25
            }
        }.count
    }
    let tabArea = 84..<min(Int(width) - 150, 700)
    let columns = inkColumns(tabArea)
    #expect(columns > 60, "width \(width): only \(columns) inked columns in the tab area")
}

@MainActor
@Test(.timeLimit(.minutes(2))) func aNewAccountsCalendarTabShowsOnlyOnceAnInviteArrives() async throws {
    let store = try MailStore.openInMemoryForTesting()
    let account = try FixtureStoreSeeder.seedLargeInbox(store, count: 20, now: Date())
    let seeded = try store.splits(account: account)
    #expect(seeded.map(\.name) == ["Important", "Calendar"])
    let calendar = try #require(seeded.last)
    #expect(try store.setting(.hideSplitWhenEmpty, scope: .account(account)) == [calendar.id.rawValue])

    let environment = AppEnvironment(data: MailStoreAdapter(store: store), settings: MailStoreSettings(store: store), isFake: true)
    let router = environment.router
    router.start()
    defer { router.stop() }
    await eventually("hidden while empty") {
        router.active?.hiddenWhenEmpty.isEmpty == false && router.active?.tabs.map(\.title) == ["Important", "Other"]
    }
    let state = try #require(router.active)

    let invite = MessageUpsert(
        gmailMessageID: GmailMessageID("invite1"), gmailThreadID: GmailThreadID("invite-thread"),
        historyID: HistoryID(20_000), internalDate: Date(), labelIDs: ["INBOX", "UNREAD"].map { GmailLabelID($0) },
        snippet: "Invitation", sizeEstimate: 1_000,
        headers: MessageHeaderFields(subject: "Invitation: planning", from: EmailAddress(email: "pat@example.net"),
                                     to: [EmailAddress(email: "large@example.com")], cc: [], bcc: [], replyTo: [],
                                     date: Date(), messageID: "<invite1@fake.example>", inReplyTo: nil, references: []),
        body: MessageBodyUpsert(text: "x", hasCalendarInvite: true, decodeWarnings: [], searchText: "x"))
    _ = try store.upsertMessages([invite], account: account, generation: 1)
    await eventually("calendar tab") { state.tabs.map(\.title) == ["Important", "Calendar", "Other"] }
    #expect(state.location == state.tabs.first?.location, "the window stays on Important")
}
