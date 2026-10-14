import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@Test func headerAndStatusBarWording() {
    #expect(SmartSearchStatusText.header(.off) == nil)
    #expect(SmartSearchStatusText.header(.ready) == nil)
    let indexing = SmartSearchStatus(phase: .indexing, fraction: 0.427)
    #expect(SmartSearchStatusText.header(indexing)
            == SmartSearchHeaderStatus(text: "Smart search: 42% of your mail",
                                       help: "Related results cover the mail indexed so far."))
    #expect(SmartSearchStatusText.statusBar(indexing) == "Preparing smart search: 42%")
    let paused = SmartSearchStatus(phase: .paused(.lowPower), fraction: 0.5)
    #expect(SmartSearchStatusText.header(paused)?.text == "Smart search paused")
    #expect(SmartSearchStatusText.header(paused)?.help == "Paused: Low Power Mode is on. Related results cover 50% of your mail.")
    #expect(SmartSearchStatusText.statusBar(paused) == nil, "a pause is told in the header and Settings")
    #expect(SmartSearchStatusText.statusBar(.ready) == nil)
    #expect(SmartSearchStatusText.percent(0.999) == 99)
    #expect(SmartSearchStatus(phase: .indexing, fraction: 1.7).fraction == 1)
    #expect(!SmartSearchStatus.off.addsRelatedResults && indexing.addsRelatedResults && SmartSearchStatus.ready.addsRelatedResults)
}

@Test func relatedRowsAreSpokenAsRelated() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let format = ThreadRowFormatting(calendar: utc, locale: Locale(identifier: "en_US"))
    let key = ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t"))
    let row = ThreadRow(id: key, subject: "Offsite planning", snippet: "Agenda attached", participantsDisplay: "Dana",
                        participants: [], messageCount: 1, unreadCount: 0, draftCount: 0, attachmentCount: 0,
                        isUnread: false, isStarred: false, isImportant: false, userLabelIDs: [], lastMessageAt: fixedNow,
                        sortAt: fixedNow)
    let plain = format.accessibilityLabel(row, chips: [], location: .search("retreat"), now: fixedNow)
    #expect(!plain.contains("related match"))
    #expect(row.with(searchMatch: .lexical).searchMatch == .lexical)
    #expect(format.accessibilityLabel(row.with(searchMatch: .lexical), chips: [], location: .search("retreat"), now: fixedNow)
            == plain, "a word match reads as before")
    let related = format.accessibilityLabel(row.with(searchMatch: .related), chips: [], location: .search("retreat"),
                                            now: fixedNow)
    #expect(related == plain + ", related match")
    #expect(row.with(searchMatch: nil) == row)
}

@Test func emptySearchOffersDescribingItFirstWhenRelatedResultsExist() {
    func make(_ related: Bool) -> ThreadListEmptyState? {
        ThreadListEmptyState.make(location: .search("retreat"), locationTitle: "", state: .loaded, hasRows: false,
                                  loadingShown: false, connectivity: nil, day: 0, relatedResults: related)
    }
    #expect(make(false)?.subtitle == "Check the spelling, or try fewer words.")
    #expect(make(true)?.subtitle == "Try describing it in other words. Check the spelling, or try fewer words.")
    let inbox = ThreadListEmptyState.make(location: .system(.starred), locationTitle: "", state: .loaded, hasRows: false,
                                          loadingShown: false, connectivity: nil, day: 0, relatedResults: true)
    #expect(inbox?.subtitle == nil)
}

@MainActor
@Test func statusBarLineFollowsTheIndexAndNeverReplacesSync() async {
    let store = FakeMailStore(corpus: .make(), options: .init(remoteAck: .manual, heldSends: .manual, liveConnectivity: true))
    let model = StatusModel(data: store)
    let run = Task { await model.run() }
    defer { run.cancel() }
    await eventually { !model.connectivity.isEmpty }
    #expect(model.smartSearchLine == nil, "off: nothing")
    store.setSmartSearchStatus(SmartSearchStatus(phase: .indexing, fraction: 0.42))
    await eventually { model.smartSearch.phase == .indexing }
    #expect(model.smartSearchLine == "Preparing smart search: 42%")
    #expect(model.isVisible)
    let account = model.connectivity.keys.sorted { $0.rawValue < $1.rawValue }[0]
    store.setConnectivity(.online(syncing: true, lastSyncAt: nil), for: account)
    await eventually { model.smartSearchLine == nil }
    #expect(model.syncText(now: fixedNow) == "Syncing your inbox…")
    store.setSmartSearchStatus(.ready)
    await eventually { model.smartSearch == .ready }
    #expect(model.smartSearchLine == nil)
}

@MainActor
@Test func resultsHeaderShowsCoverageOnlyWhileASearchIsShown() async {
    let f = OverlayFixture(options: .init(remoteAck: .immediate, relatedSearchMatches: true))
    let run = Task { await f.env.status.run() }
    defer { run.cancel() }
    await f.loaded()
    let search = f.center.search
    await eventually { f.env.status.smartSearch == SmartSearchStatus.ready }
    #expect(search.addsRelatedResults)
    #expect(search.smartSearchHeader == nil, "no search shown, and a ready index says nothing")
    search.open()
    search.text = "retreat"
    search.submit()
    await eventually { search.shownQuery == "retreat" && f.router.list?.state == .loaded }
    #expect(search.smartSearchHeader == nil)
    #expect(!f.rows.isEmpty && f.rows.allSatisfy { $0.searchMatch == .related })
    f.store.setSmartSearchStatus(SmartSearchStatus(phase: .indexing, fraction: 0.3))
    await eventually { search.smartSearchHeader?.text == "Smart search: 30% of your mail" }
    f.store.setSmartSearchStatus(SmartSearchStatus(phase: .paused(.hot), fraction: 0.3))
    await eventually { search.smartSearchHeader?.text == "Smart search paused" }
}

@MainActor
@Test func moduleOffMeansNoRelatedRowsAndNoMarkers() async {
    let f = OverlayFixture(options: .init(remoteAck: .immediate, relatedSearchMatches: true),
                           flags: FeatureFlags().with(.smartSearch, false))
    await f.loaded()
    #expect(!f.center.search.addsRelatedResults)
    f.router.go(to: .search("retreat"))
    await eventually { f.router.list?.location == .search("retreat") && f.router.list?.state == .loaded }
    #expect(f.rows.isEmpty, "with the module off search is the plain local search: no related rows")
    #expect(f.center.search.smartSearchHeader == nil)
}
