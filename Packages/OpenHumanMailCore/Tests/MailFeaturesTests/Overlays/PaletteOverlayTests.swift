import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.timeLimit(.minutes(2))) struct PaletteOverlayTests {
    @Test func commandKOpensTheOverlayAndTogglesIt() async throws {
        let f = OverlayFixture()
        await f.loaded(10)
        #expect(await f.run(.commandPalette))
        #expect(f.palette != nil && f.center.isShowing)
        #expect(await f.run(.commandPalette))
        #expect(!f.center.isShowing, "⌘K again closes it")
    }

    @Test func anEmptyQueryShowsRecentThenSuggested() async throws {
        let f = OverlayFixture()
        await f.loaded(10)
        await f.run(.commandPalette)
        let palette = try #require(f.palette)
        #expect(palette.entries.allSatisfy { $0.group == .suggested })
        #expect(palette.entries.contains { $0.kind == .action(.markDone) })
        palette.perform(try #require(palette.entries.first { $0.kind == .action(.toggleStar) }))
        await f.registry.lastTask?.value
        await f.run(.commandPalette)
        let again = try #require(f.palette)
        #expect(again.entries.first?.group == .recent && again.entries.first?.kind == .action(.toggleStar))
    }

    @Test func presetsAreParameterizedActionsRankedWithTheActions() async throws {
        let f = OverlayFixture()
        await f.loaded(10)
        await f.run(.commandPalette)
        let palette = try #require(f.palette)
        palette.query = "snooze until"
        let presets = palette.entries.filter { if case .snooze = $0.kind { true } else { false } }
        #expect(presets.count >= 3)
        #expect(presets.contains { $0.title == "Snooze until tomorrow morning" })
        #expect(presets.allSatisfy { $0.detail != nil }, "each shows its resolved time")
        palette.query = "remind me in 2 days if"
        #expect(palette.entries.first?.title == "Remind me in 2 days if no reply")
        #expect(palette.entries.first?.group == .top)
        guard case .remind(_, let kind)? = palette.entries.first?.kind else {
            Issue.record("not a remind preset")
            return
        }
        #expect(kind == .ifNoReply)
    }

    @Test func enterRunsAPresetOnTheSelectionCapturedAtOpen() async throws {
        let f = OverlayFixture()
        await f.loaded(10)
        let target = try #require(f.router.list?.cursor)
        await f.run(.commandPalette)
        let palette = try #require(f.palette)
        f.router.perform(.nextThread)
        #expect(f.router.list?.cursor != target)
        palette.query = "snooze until tomorrow morning"
        #expect(palette.performSelected())
        #expect(!f.center.isShowing)
        await f.settled()
        #expect(f.hasToast("Snoozed until "))
        #expect(!f.rows.contains { $0.id == target })
        #expect(try await SchedulePickerTests.snooze(of: target, f) != nil, "the selection captured at open was snoozed")
        #expect(await f.run(.undo))
        #expect(try await SchedulePickerTests.snooze(of: target, f) == nil)
        await untilObserved { f.rows.contains { $0.id == target } }
    }

    @Test func remindPresetSetsAReminderOnTheFocusedThread() async throws {
        let f = OverlayFixture()
        await f.loaded(10)
        let target = try #require(f.router.list?.cursor)
        await f.run(.commandPalette)
        let palette = try #require(f.palette)
        palette.query = "remind me tomorrow morning"
        let entry = try #require(palette.entries.first { if case .remind(_, .always) = $0.kind { true } else { false } })
        palette.perform(entry)
        await f.settled()
        #expect(f.hasToast("Reminder set for "))
        #expect(try await SchedulePickerTests.reminders(f).map(\.thread) == [target])
        await untilObserved { f.rows.first { $0.id == target }?.reminderAt != nil }
    }

    @Test func clearReminderListsOnlyWhenTheThreadHasOne() async throws {
        let f = OverlayFixture()
        await f.loaded(10)
        let target = try #require(f.router.list?.cursor)
        await f.run(.commandPalette)
        var palette = try #require(f.palette)
        palette.query = "clear reminder"
        #expect(!palette.entries.contains { $0.kind == .action(.clearReminder) })
        palette.close()
        await f.registry.threadActions?.remind(target, at: fixedNow.addingTimeInterval(86_400), kind: .always, host: f.router)?.value
        await untilObserved { f.rows.first { $0.id == target }?.reminderAt != nil }
        await f.run(.commandPalette)
        palette = try #require(f.palette)
        palette.query = "clear reminder"
        #expect(palette.entries.first?.kind == .action(.clearReminder))
        #expect(palette.performSelected())
        await f.settled()
        #expect(f.hasToast("Reminder cleared"))
        #expect(try await SchedulePickerTests.reminders(f).isEmpty)
    }

    @Test func labelsAndNavigationTargets() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 60, now: fixedNow))
        await f.loaded()
        let state = try #require(f.router.active)
        await untilObserved { state.labels.contains { $0.displayName == "Clients" } }
        let target = try #require(f.router.list?.cursor)
        let before = f.store.labelNames(of: target)
        #expect(before.contains { $0.uppercased() == "INBOX" } && !before.contains("Clients"))
        await f.run(.commandPalette)
        let palette = try #require(f.palette)
        palette.query = "clients"
        let apply = try #require(palette.entries.first { if case .label = $0.kind { true } else { false } })
        #expect(apply.title == "Label: Clients")
        let goTo = try #require(palette.entries.first { if case .goTo(.label) = $0.kind { true } else { false } })
        #expect(goTo.title == "Go to Clients" && goTo.group == .goTo)
        palette.perform(goTo)
        #expect(state.location == .label(try #require(state.labels.first { $0.displayName == "Clients" }).labelID))

        f.router.go(to: .system(.inbox))
        await f.loaded()
        await f.run(.commandPalette)
        let second = try #require(f.palette)
        second.query = "label: clients"
        let entry = try #require(second.entries.first { if case .label = $0.kind { true } else { false } })
        second.perform(entry)
        await f.settled()
        #expect(f.hasToast("Labeled Clients"))
        #expect(f.store.labelNames(of: target) == before.union(["Clients"]))
    }

    @Test func otherAccountsAreGoToTargets() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 60, now: fixedNow))
        await f.loaded()
        await untilObserved { f.router.accounts.count == 2 }
        let other = try #require(f.router.accounts.first { $0.id != f.router.activeAccountID })
        await f.run(.commandPalette)
        let palette = try #require(f.palette)
        palette.query = "go to personal"
        let entry = try #require(palette.entries.first { if case .account = $0.kind { true } else { false } })
        #expect(entry.title.hasSuffix("› Inbox"))
        palette.perform(entry)
        #expect(f.router.activeAccountID == other.id)
    }

    @Test func mailResultsComeFromTheLocalSearchAndSeeAllRunsIt() async throws {
        let f = OverlayFixture()
        await f.loaded(10)
        let subject = try #require(f.rows.first?.subject)
        let word = try #require(subject.split(separator: " ").first { $0.count >= 4 }.map(String.init))
        await f.run(.commandPalette)
        let palette = try #require(f.palette)
        palette.query = word
        await palette.loadMail()
        let mail = palette.entries.filter { $0.group == .mail }
        #expect(!mail.isEmpty && mail.count <= PaletteController.maxMail + 1)
        let thread = try #require(mail.first { if case .mail = $0.kind { true } else { false } })
        palette.perform(thread)
        guard case .mail(let key) = thread.kind else { return }
        #expect(f.router.reader?.thread == key, "the result opens its conversation")
    }

    @Test func nothingMatchingOffersToSearchMail() async throws {
        let f = OverlayFixture()
        await f.loaded(10)
        await f.run(.commandPalette)
        let palette = try #require(f.palette)
        palette.query = "qzxqzx"
        #expect(palette.isEmptyResult)
        #expect(palette.entries.count == 1 && palette.entries[0].title == "Search mail for “qzxqzx”")
        #expect(palette.performSelected())
        #expect(f.router.active?.location == .search("qzxqzx"))
        #expect(f.router.active?.searchOpen == true)
    }

    @Test func theScopeSummaryNamesWhatThePaletteActsOn() async throws {
        let f = OverlayFixture()
        await f.loaded(10)
        let cursor = try #require(f.router.list?.cursor)
        let subject = try #require(f.router.list?.row(for: cursor)?.subject)
        await f.run(.commandPalette)
        let palette = try #require(f.palette)
        #expect(palette.scopeSummary == (subject.isEmpty ? "(no subject)" : subject))
        #expect(palette.selectionCount == 1)
        palette.close()
        let keys = f.rows.map(\.id)
        f.router.active?.selection.extend(to: keys[2], from: keys[0], in: keys)
        await f.run(.commandPalette)
        let checked = try #require(f.palette)
        #expect(checked.scopeSummary == "3 selected")
        #expect(checked.selectionCount == 3)
    }

    @Test func readOnlyListsMatchingActionsAsNotAvailableWithTheReason() async throws {
        var options = FakeMailStore.Options(remoteAck: .immediate)
        options.safeMode = .readOnly
        let f = OverlayFixture(options: options)
        await f.loaded(10)
        await f.run(.commandPalette)
        let palette = try #require(f.palette)
        palette.query = "done"
        let unavailable = palette.entries.filter { $0.group == .unavailable }
        let markDone = try #require(unavailable.first { $0.kind == .action(.markDone) })
        #expect(markDone.unavailableReason == "Off in read-only mode" && markDone.detail == "Off in read-only mode")
        #expect(markDone.keycaps.isEmpty && unavailable.count <= PaletteController.maxUnavailable)
        #expect(palette.entries.last?.group == .unavailable, "listed last")
        #expect(palette.entries[palette.cursor].isAvailable, "the cursor starts on a row that runs")
        for _ in 0..<(palette.entries.count * 2) {
            palette.moveCursor(by: 1)
            #expect(palette.entries[palette.cursor].isAvailable)
        }
        palette.moveCursor(to: try #require(palette.entries.firstIndex { $0.id == markDone.id }))
        #expect(palette.entries[palette.cursor].isAvailable, "a click cannot put the cursor there either")
        #expect(!palette.perform(markDone) && f.center.isShowing)
        #expect(PaletteController.unavailableText(.noSelection, safeMode: .readOnly) == "Select a conversation first")
        #expect(PaletteController.unavailableText(.safeMode, safeMode: .writeAllowlist) == "Off in safe mode")
    }

    @Test func aStaleMailAnswerIsDropped() async throws {
        let f = OverlayFixture()
        await f.loaded(10)
        let subject = try #require(f.rows.first?.subject)
        let word = try #require(subject.split(separator: " ").first { $0.count >= 4 }.map(String.init))
        await f.run(.commandPalette)
        let palette = try #require(f.palette)
        palette.query = word
        let load = Task { await palette.loadMail() }
        palette.query = "qzxqzx"
        await load.value
        #expect(!palette.entries.contains { $0.group == .mail && $0.title != "Search mail for “qzxqzx”" })
    }

    @Test func rankingStaysFastWithManyEntries() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 60, now: fixedNow))
        await f.loaded()
        let clock = ContinuousClock()
        let start = clock.now
        await f.run(.commandPalette)
        let palette = try #require(f.palette)
        palette.query = "a"
        let elapsed = clock.now - start
        #expect(!palette.entries.isEmpty)
        if ProcessInfo.processInfo.environment["OPENHUMAN_PERF"] == "1" {
            #expect(elapsed < .milliseconds(50), "opens in \(elapsed)")
        }
    }
}
