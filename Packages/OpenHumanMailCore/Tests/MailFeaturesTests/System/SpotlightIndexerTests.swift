import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import OpenHumanLinks
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized)
struct SpotlightIndexerTests {
    private let sender = EmailAddress(name: "Ada Sender", email: "ada@sender.example")

    private func make(_ f: SystemFixture, batch: Int = SpotlightIndexer.defaultBatchSize) -> SpotlightIndexer {
        let defaults = UserDefaults(suiteName: "openhuman.test.spotlight.\(UUID().uuidString)")!
        let indexer = SpotlightIndexer(data: f.store, settings: f.store, index: f.spotlight, defaults: defaults)
        indexer.debounce = .zero
        indexer.pauseInterval = .milliseconds(5)
        indexer.batchSize = batch
        return indexer
    }

    private func inboxCount(_ f: SystemFixture) async throws -> Int {
        try #require(await first(f.store.threadWindow(.system(.inbox), account: f.account, limit: 500))).rows.count
    }

    private func started(_ f: SystemFixture, batch: Int = SpotlightIndexer.defaultBatchSize) async throws -> SpotlightIndexer {
        let indexer = make(f, batch: batch)
        indexer.start()
        let count = try await inboxCount(f)
        await eventually { f.spotlight.items.count == count }
        return indexer
    }

    @Test func theDefaultIsMetadataOnlyAndNeverCarriesSubjectSnippetOrBody() async throws {
        let f = SystemFixture()
        f.store.deliverMessage(account: f.account, from: sender, subject: "ZZSUBJECT quarterly", text: "ZZBODY secret numbers", important: true)
        _ = try await started(f)
        let item = try #require(f.spotlight.items.values.first { $0.authorName == "Ada Sender" })
        #expect(item.title == "Mail from Ada Sender")
        #expect(item.keywords.contains("Important") && item.isImportant)
        for item in f.spotlight.items.values {
            for text in [item.title, item.summary, item.authorName] + item.keywords {
                #expect(!text.contains("ZZSUBJECT") && !text.contains("ZZBODY"))
            }
            #expect(!item.identifier.contains("@"), "an identifier holds ids only")
            #expect(item.domain == SpotlightIdentifier.domain(f.account))
        }
    }

    @Test func labelsAndCategoryArePartOfTheMetadata() async throws {
        let f = SystemFixture(corpus: .rich(threadCount: 60, now: fixedNow))
        let indexer = make(f)
        indexer.start()
        await eventually { f.spotlight.items.values.contains { $0.keywords.contains { $0 != "Important" } } }
        await eventually { f.spotlight.items.values.contains { $0.keywords.contains { $0 != "Important" } && $0.summary.contains($0.keywords.last ?? "?") } }
    }

    @Test func subjectsAndSnippetsGoInOnlyWhenTheUserOptsInAndLeaveWhenTheyOptOut() async throws {
        let f = SystemFixture()
        f.store.deliverMessage(account: f.account, from: sender, subject: "ZZSUBJECT quarterly", text: "ZZBODY secret numbers")
        let indexer = try await started(f)
        let id = try #require(f.spotlight.items.values.first { $0.authorName == "Ada Sender" }?.identifier)
        try await f.store.set(AppSettings.spotlightIndexSubjects, true)
        await eventually { f.spotlight.items[id]?.title == "ZZSUBJECT quarterly" }
        #expect(indexer.includesSubjects)
        let opted = try #require(f.spotlight.items[id])
        let row = try #require(await first(f.store.threadWindow(.system(.inbox), account: f.account, limit: 500))?.rows
            .first { SpotlightIdentifier.make($0.id) == id })
        #expect(opted.summary == row.snippet)
        try await f.store.set(AppSettings.spotlightIndexSubjects, false)
        await eventually { f.spotlight.items[id]?.title == "Mail from Ada Sender" }
    }

    @Test func newChangedAndGoneThreadsFollowTheStore() async throws {
        let f = SystemFixture()
        let indexer = try await started(f)
        let before = f.spotlight.items.count
        f.store.deliverMessage(account: f.account, from: sender, subject: "New one", important: false)
        await eventually { f.spotlight.items.count == before + 1 }
        let added = try #require(f.spotlight.items.values.first { $0.authorName == "Ada Sender" })
        let row = try #require(await first(f.store.threadWindow(.system(.inbox), account: f.account, limit: 500))?.rows
            .first { SpotlightIdentifier.make($0.id) == added.identifier })
        f.store.deliverMessage(account: f.account, to: row.id, from: sender, subject: "New one", at: Date().addingTimeInterval(60), important: true)
        await eventually { f.spotlight.items[added.identifier]?.isImportant == true }
        _ = try await f.store.apply(.markDone([row.id]))
        await eventually { f.spotlight.items[added.identifier] == nil }
        #expect(f.spotlight.items.count == before)
        #expect(indexer.indexedCount == before)
    }

    @Test func removingAnAccountDeletesItsWholeDomain() async throws {
        let f = SystemFixture(corpus: .rich(threadCount: 30, now: fixedNow))
        let indexer = make(f)
        indexer.start()
        let accounts = try #require(await first(f.store.accounts()))
        #expect(accounts.count == 2)
        await eventually { Set(f.spotlight.items.values.map(\.domain)).count == 2 }
        let gone = try #require(accounts.last).id
        try await f.store.remove(gone)
        await eventually { !f.spotlight.items.values.contains { $0.domain == SpotlightIdentifier.domain(gone) } }
        #expect(f.spotlight.calls.contains("deleteDomains"))
        #expect(!f.spotlight.items.isEmpty, "the other account stays")
    }

    @Test func batchesAreBounded() async throws {
        let f = SystemFixture(corpus: .make(threadCount: 25, now: fixedNow))
        _ = try await started(f, batch: 4)
        #expect(f.spotlight.batchSizes.allSatisfy { $0 <= 4 })
        #expect(f.spotlight.batchSizes.count >= 7)
        #expect(SpotlightIndexer.maxThreadsPerAccount == 500)
    }

    @Test func theWorkerWaitsWhileTheFirstBackfillIsHeavyThenCatchesUp() async throws {
        let f = SystemFixture()
        let indexer = make(f)
        indexer.setBackfillBusy(true)
        indexer.start()
        await eventually { indexer.pendingOperations > 0 || indexer.isPaused }
        await eventually { indexer.isPaused }
        #expect(f.spotlight.items.isEmpty && f.spotlight.calls.isEmpty, "nothing is indexed while paused")
        indexer.setBackfillBusy(false)
        let count = try await inboxCount(f)
        await eventually { f.spotlight.items.count == count }
        #expect(!indexer.isPaused)
    }

    @Test func itWorksInReadOnlySafeModeBecauseItNeverWritesToGmail() async throws {
        let f = SystemFixture(options: .init(remoteAck: .immediate, safeMode: .readOnly))
        _ = try await started(f)
        #expect(!f.spotlight.items.isEmpty)
        #expect(f.store.safeMode() == .readOnly)
    }

    @Test func rebuildDeletesEverythingAndIndexesAgainWhileRemoveAllEmptiesAndStops() async throws {
        let f = SystemFixture()
        let indexer = try await started(f)
        let count = f.spotlight.items.count
        await indexer.rebuild()
        #expect(f.spotlight.calls.contains("deleteAll"))
        await eventually { f.spotlight.items.count == count }
        await indexer.removeAll()
        #expect(f.spotlight.items.isEmpty && indexer.indexedCount == 0)
        f.store.deliverMessage(account: f.account, from: sender, subject: "After", important: true)
        await indexer.settle()
        #expect(f.spotlight.items.isEmpty, "removing all also stops indexing")
    }

    @Test func aThreadThatLeftWhileMailWasClosedIsRemovedOnTheNextLaunch() async throws {
        let f = SystemFixture()
        let defaults = UserDefaults(suiteName: "openhuman.test.spotlight.\(UUID().uuidString)")!
        let ghost = ThreadKey(account: f.account, rowID: 9999, gmailThreadID: GmailThreadID("ghost"))
        try await f.spotlight.index([SpotlightItem(identifier: SpotlightIdentifier.make(ghost), domain: SpotlightIdentifier.domain(f.account),
                                                   title: "Mail from Old", summary: "Mail", authorName: "Old", date: fixedNow,
                                                   keywords: [], isImportant: false)])
        defaults.set([SpotlightIdentifier.make(ghost)], forKey: SpotlightIndexer.ledgerKey(f.account))
        let indexer = SpotlightIndexer(data: f.store, settings: f.store, index: f.spotlight, defaults: defaults)
        indexer.debounce = .zero
        indexer.start()
        await eventually { f.spotlight.items[SpotlightIdentifier.make(ghost)] == nil && f.spotlight.items.count > 0 }
    }

    @Test func aFailingIndexIsReportedAndTriedAgainOnTheNextChange() async throws {
        let f = SystemFixture()
        f.spotlight.failing = true
        let indexer = make(f)
        indexer.start()
        await eventually { indexer.lastFailed }
        #expect(f.spotlight.items.isEmpty)
        f.spotlight.failing = false
        f.store.deliverMessage(account: f.account, from: sender, subject: "Retry", important: true)
        let count = try await inboxCount(f)
        await eventually { f.spotlight.items.count == count && !indexer.lastFailed }
    }

    @Test func identifiersRoundTripAndOpenTheThreadDeepLink() throws {
        let key = ThreadKey(account: AccountID(7), rowID: 3, gmailThreadID: GmailThreadID("18c0ffee"))
        let id = SpotlightIdentifier.make(key)
        let parsed = try #require(SpotlightIdentifier.parse(id))
        #expect(parsed.account == AccountID(7) && parsed.thread == GmailThreadID("18c0ffee"))
        #expect(SpotlightIdentifier.parse("other.7.x") == nil && SpotlightIdentifier.parse("oh.thread.x.y") == nil)
        let account = Account(id: AccountID(7), email: "me@work.example", displayName: nil, alias: nil, health: .active)
        let url = try #require(SpotlightIdentifier.deepLink(for: id, accounts: [account]))
        #expect(url.absoluteString == "openhuman://thread/me@work.example/18c0ffee")
        #expect(MailLinkParser.parse(url) == .success(.thread(account: AccountRef("me@work.example"), threadID: "18c0ffee")))
        #expect(SpotlightIdentifier.deepLink(for: id, accounts: []) == nil, "a signed-out account's result opens nothing")
    }
}

@MainActor
@Suite(.serialized)
struct SpotlightModuleTests {
    @Test func offByDefaultNothingStartsAndNothingIsIndexed() async throws {
        let f = SystemFixture()
        f.env.runLaunchTasks()
        await eventually { f.env.system.notifications != nil }
        #expect(f.env.system.spotlight == nil)
        #expect(f.spotlight.calls.isEmpty)
        #expect(!f.env.system.preferences.spotlightEnabled)
    }

    @Test func theFlagStartsTheIndexerAtLaunch() async throws {
        let f = SystemFixture(flags: FeatureFlags().with(.spotlight, true))
        f.env.runLaunchTasks()
        await eventually { f.env.system.spotlight != nil }
        await eventually { !f.spotlight.items.isEmpty }
    }

    @Test func theSettingsSwitchStartsAndStopsIndexingAndOffEmptiesTheIndex() async throws {
        let f = SystemFixture()
        let model = SpotlightSettingsModel(environment: f.env)
        #expect(!model.isOn && model.status == "Off. Nothing is indexed.")
        await model.setOn(true)
        #expect(model.isOn && f.env.system.preferences.spotlightEnabled)
        await eventually { !f.spotlight.items.isEmpty }
        await eventually { model.status.hasSuffix("conversations indexed.") }
        await model.rebuild()
        await eventually { !f.spotlight.items.isEmpty }
        await model.setOn(false)
        #expect(!model.isOn && f.spotlight.items.isEmpty && !f.env.system.preferences.spotlightEnabled)
    }

    @Test func removeAllWorksEvenWithTheModuleOff() async throws {
        let f = SystemFixture()
        let leftover = SpotlightItem(identifier: "oh.thread.1.x", domain: "oh.account.1", title: "Mail from A", summary: "Mail",
                                     authorName: "A", date: fixedNow, keywords: [], isImportant: false)
        try await f.spotlight.index([leftover])
        await SpotlightSettingsModel(environment: f.env).removeAll()
        #expect(f.spotlight.items.isEmpty)
    }

    @Test func thePlatformPageOffersSpotlightWithItsControls() {
        let f = SystemFixture()
        let model = PlatformFeaturesModel(environment: f.env)
        #expect(model.rows.first { $0.id == "spotlight" }?.isAvailable == true)
        #expect(Set(model.rows.filter(\.isAvailable).map(\.id)) == ["spotlight", "menuBarExtra", "globalHotkey", "services", "appIntents", "focusFilters", "writingTools"])
        #expect(model.spotlight != nil)
        #expect(SpotlightSettingsModel.unconfirmedNote.contains("not confirmed"))
        #expect(model.intro == PlatformFeaturesModel.intro && model.intro.hasPrefix("Extras that work with the rest of your Mac.")
            && !model.intro.contains("notarized"))
        #expect(model.rows.first { $0.id == "menuBarExtra" }?.feature.title == "Menu bar item")
    }

    @Test func theSubjectOptInDefaultsOffAndIsTheStoreSetting() async throws {
        let f = SystemFixture()
        #expect(AppSettings.spotlightIndexSubjects.name == "spotlight.index_subjects")
        let model = SpotlightSettingsModel(environment: f.env)
        model.start()
        #expect(model.subjects.value == false)
        await model.setSubjects(true)
        #expect(try await f.store.get(AppSettings.spotlightIndexSubjects) == true)
    }
}
