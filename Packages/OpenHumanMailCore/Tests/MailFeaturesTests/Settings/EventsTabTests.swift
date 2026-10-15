import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
struct EventsTabTests {
    private static let invitation = EmailAddress(name: "Sam Rivera (via Google Calendar)",
                                                 email: "calendar-notification@google.com")

    private func info(_ name: String, _ rule: String, _ position: Int) -> SplitInfo {
        SplitInfo(id: SplitKey("s\(position)"), account: AccountID(1), name: name, position: position, ruleText: rule)
    }

    private func model(_ f: SettingsFixture) async -> SplitSettingsModel {
        let model = SplitSettingsModel(environment: f.env)
        model.start()
        await eventually { model.account != nil && model.splitsLoaded && !model.splits.isEmpty }
        return model
    }

    @Test func theOfferAddsUpgradesOrStaysQuiet() {
        let important = info("Important", "is:important", 0)
        #expect(EventsTabOffer.offer(for: [important]) == .add(name: "Events"))
        let old = info("Calendar", "has:invite", 1)
        #expect(EventsTabOffer.offer(for: [important, old]) == .upgrade(old))
        #expect(EventsTabOffer.offer(for: [important, info("Calendar", "is:event", 1)]) == nil)
        #expect(EventsTabOffer.offer(for: [important, info("Calendar", " IS:EVENT ", 1)]) == nil, "case and spaces")
        #expect(EventsTabOffer.offer(for: [important, info("Events", "label:Events", 1)]) == .add(name: "Event mail"))
        #expect(EventsTabOffer.offer(for: [important, info("Invites", "has:invite -is:important", 1)])
                == .add(name: "Events"))
        #expect(EventsTabOffer.offer(for: [important, old]).map(\.buttonTitle) == "Update Calendar")
    }

    @Test func acceptingAddsTheEventsSplitAtTheEndHiddenWhileEmptyAndOnlyOnce() async throws {
        let f = SettingsFixture()
        let model = await model(f)
        let before = model.splits
        #expect(model.eventsOffer == .add(name: "Events"))
        await model.acceptEventsOffer()
        await eventually { model.splits.contains { $0.name == "Events" } }
        let events = try #require(model.splits.first { $0.name == "Events" })
        #expect(events.ruleText == "is:event")
        #expect(Array(model.splits.prefix(before.count)).map(\.id) == before.map(\.id), "nothing reordered or removed")
        #expect(events.position > (before.map(\.position).max() ?? 0), "at the end of the tabs")
        await eventually { model.isHiddenWhenEmpty(events) }
        #expect(model.eventsOffer == nil, "idempotent: no second offer")
        #expect(model.eventsNote == "Added the Events tab")
        await model.acceptEventsOffer()
        #expect(try await f.splits(f.work).filter { $0.ruleText == "is:event" }.count == 1)

        await model.undoEventsChange()
        await eventually { !model.splits.contains { $0.name == "Events" } }
        #expect(model.splits.map(\.id) == before.map(\.id))
        await eventually { !model.hiddenWhenEmpty.contains(events.id.rawValue) }
        #expect(model.eventsOffer == .add(name: "Events"), "offered again after the undo")
    }

    @Test func anOldCalendarSplitIsUpgradedInPlaceAndTheUndoPutsItsRuleBack() async throws {
        let f = SettingsFixture()
        let model = await model(f)
        let key = try await f.store.upsertSplit(SplitDefinition(account: f.work, name: "Calendar", ruleText: "has:invite"))
        await eventually { model.eventsOffer.map { if case .upgrade = $0 { true } else { false } } ?? false }
        let order = model.splits.map(\.id)
        await model.acceptEventsOffer()
        await eventually { model.splits.first { $0.id == key }?.ruleText == "is:event" }
        #expect(model.splits.map(\.id) == order, "same tab, same place")
        #expect(model.splits.first { $0.id == key }?.name == "Calendar")
        #expect(model.eventsOffer == nil)
        await model.undoEventsChange()
        await eventually { model.splits.first { $0.id == key }?.ruleText == "has:invite" }
    }

    @Test func withoutAWritePortThereIsNoOfferButRescanStillWorks() async throws {
        let f = SettingsFixture(writePort: false)
        let model = await model(f)
        #expect(model.eventsOffer == nil)
        let before = try await f.splits(f.work)
        await model.acceptEventsOffer()
        #expect(try await f.splits(f.work) == before)
        #expect(model.canRescanEvents)
        await model.rescanEvents(now: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(try await f.store.get(AppSettings.eventsRescanAt(f.work)) == 1_790_000_000_000)
        #expect(model.errorMessage == nil && model.eventsNote?.hasPrefix("Re-scanned") == true)
    }

    @Test func thePaletteAddsTheEventsTabWithOneUndoAndThenHidesTheEntry() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let state = try #require(f.router.active)
        await eventually { state.splitsLoaded }
        #expect(f.registry.availability(.addEventsTab, host: f.router, context: f.router.actionContext()) == .enabled)
        #expect(await f.run(.addEventsTab, source: .palette))
        await eventually { state.splits.contains { $0.ruleText == "is:event" } }
        await eventually {
            f.registry.availability(.addEventsTab, host: f.router, context: f.router.actionContext()) == .hidden
        }
        #expect(await f.run(.undo))
        await eventually { !state.splits.contains { $0.ruleText == "is:event" } }
    }

    @Test func theEventsTabHidesWhileEmptyAndShowsForAnInvitation() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let state = try #require(f.router.active)
        await eventually { state.splitsLoaded }
        #expect(await f.run(.addEventsTab, source: .palette))
        await eventually { state.splits.contains { $0.ruleText == "is:event" } }
        let events = try #require(state.splits.first { $0.ruleText == "is:event" })
        await eventually { state.hidesWhenEmpty(.split(events.id)) == true }
        f.router.go(to: state.allTabs[0].location)
        await eventually { state.allTabs.first { $0.location == .split(events.id) }?.total == 0 }
        await eventually { !state.tabs.contains { $0.location == .split(events.id) } }

        f.store.deliverMessage(account: state.id, from: Self.invitation,
                               subject: "Invitation: Design review @ Mon Oct 19, 2026 10am - 11am (UTC)")
        await eventually { state.tabs.contains { $0.location == .split(events.id) } }
        #expect(state.allTabs.first { $0.location == .split(events.id) }?.total == 1)
    }

    @Test func isEventOnTheFakeMatchesInvitationsAndPlatformsButNotOrdinaryMail() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let account = try #require(f.router.active?.id)
        f.store.deliverMessage(account: account, from: Self.invitation, subject: "Updated invitation: Retro")
        f.store.deliverMessage(account: account, from: EmailAddress(email: "hello@lu.ma"), subject: "Your ticket")
        f.store.deliverMessage(account: account, from: EmailAddress(email: "pat@example.com"), subject: "Lunch?")
        var subjects: [String] = []
        for try await page in f.store.search("is:event", accounts: [account], limit: 50) {
            subjects = page.hits.map(\.row.subject)
            break
        }
        #expect(subjects.contains("Updated invitation: Retro") && subjects.contains("Your ticket"))
        #expect(!subjects.contains("Lunch?"))
    }

    @Test func theSearchFieldOffersIsEvent() {
        let rows = SearchSuggestions.make(text: "is:ev", recents: [], labels: [], people: [])
        #expect(rows.map(\.title) == ["is:event"])
        #expect(rows.first?.replacement == "is:event ")
        #expect(rows.first?.detail == "Calendar invitations, calendar notices and event mail")
        let all = SearchSuggestions.make(text: "-is:", recents: [], labels: [], people: [])
        #expect(all.map(\.title).contains("is:event") && all.first?.replacement.hasPrefix("-is:") == true)
    }
}
