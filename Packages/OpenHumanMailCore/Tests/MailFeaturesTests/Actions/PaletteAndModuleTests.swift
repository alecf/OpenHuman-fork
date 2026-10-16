import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct CommandPaletteTests {
    @Test func commandKOpensAndClosesThePaletteModel() async {
        let f = ActionFixture()
        await f.loaded(10)
        #expect(await f.run(.commandPalette))
        #expect(f.registry.palette.isOpen)
        #expect(f.presenter.lastKind == .palette)
        #expect(await f.run(.commandPalette))
        #expect(!f.registry.palette.isOpen, "⌘K again closes it")
    }

    @Test func queryRanksAvailableActionsWithTheirShortcuts() async throws {
        let f = ActionFixture()
        await f.loaded(10)
        let palette = f.registry.palette
        palette.open(host: f.router)
        palette.query = "done"
        let top = try #require(palette.rows.first)
        #expect(top.action == .markDone && top.group == .top)
        #expect(top.keycaps == ["E"])
        #expect(!top.matched.isEmpty, "matched characters are highlighted")
        palette.query = "archive"
        #expect(palette.rows.first?.action == .markDone, "keywords match (Gmail's word for done)")
        palette.query = "go inbox"
        #expect(palette.rows.first?.action == .goInbox)
        #expect(palette.rows.first?.keycaps == ["G", "I"])
        palette.query = "always important"
        #expect(palette.rows.map(\.action).contains(.alwaysImportantSender))
        palette.query = "zzzz"
        #expect(palette.rows.isEmpty)
        palette.query = "star"
        let star = try #require(palette.rows.first { $0.action == .toggleStar })
        let starred = f.router.list?.row(for: f.router.list!.cursor!)?.isStarred ?? false
        #expect(star.title == (starred ? "Unstar" : "Star"), "toggles name their direction")
        #expect(!palette.rows.contains { $0.action == .commandPalette }, "the palette does not list itself")
    }

    @Test func enterActsOnTheSelectionCapturedAtOpen() async throws {
        let f = ActionFixture()
        await f.loaded(10)
        f.router.perform(.nextThread)
        let captured = try #require(f.router.list?.cursor)
        let palette = f.registry.palette
        palette.open(host: f.router)
        f.router.perform(.nextThread)
        #expect(f.router.list?.cursor != captured)
        palette.query = "mark done"
        #expect(palette.performSelected())
        #expect(!palette.isOpen)
        await f.registry.lastTask?.value
        await eventually { f.router.list?.row(for: captured) == nil }
        #expect(f.rows.count == 9, "only the captured conversation was marked done")
    }

    @Test func emptyQueryShowsRecentThenSuggested() async throws {
        let recents = RecentActions()
        let f = ActionFixture()
        await f.loaded(10)
        let palette = f.registry.palette
        palette.open(host: f.router)
        #expect(palette.rows.allSatisfy { $0.group == .suggested })
        #expect(palette.rows.contains { $0.action == .markDone }, "thread actions are suggested for a focused thread")
        palette.query = "star"
        palette.performSelected()
        await f.registry.lastTask?.value
        palette.open(host: f.router)
        #expect(palette.rows.first?.group == .recent)
        #expect(palette.rows.first?.action == .toggleStar)
        #expect(f.registry.recents.boost(.toggleStar) > f.registry.recents.boost(.markDone))
        #expect(recents.recent().isEmpty, "each registry keeps its own recents")
        palette.moveCursor(by: -1)
        #expect(palette.cursor == palette.rows.count - 1, "the cursor wraps")
        palette.close()
        #expect(!palette.performSelected())
    }

    @Test func rankingFiveHundredEntriesStaysFast() {
        let descriptors = (0..<500).map { n in
            ActionDescriptor(ActionID("test.action\(n)"), "Action number \(n)", category: .thread,
                             keywords: ["entry \(n % 10)"])
        }
        let clock = ContinuousClock()
        var rows: [CommandPaletteModel.Row] = []
        let elapsed = clock.measure {
            rows = CommandPaletteModel.rank(query: "act 42", descriptors: descriptors, context: ActionContext(),
                                            recents: RecentActions(), isAvailable: { _ in true })
        }
        #expect(rows.first?.group == .top)
        #expect(rows.count <= 1 + CommandPaletteModel.maxActions)
        if ProcessInfo.processInfo.environment["OPENHUMAN_PERF"] == "1" {
            print("perf: palette ranking over 500 entries: \(elapsed)")
            #expect(elapsed < .milliseconds(2), "ranking 500 entries took \(elapsed)")
        }
    }
}

@MainActor
@Suite struct FeatureModuleTests {
    @Test(arguments: FeatureModuleID.mur1 + FeatureModuleID.mur2)
    func aModuleSwitchedOffLeavesNoTrace(_ module: FeatureModuleID) async throws {
        let f = ActionFixture(corpus: .rich(threadCount: 40, now: fixedNow), location: nil,
                              flags: FeatureFlags().with(module, false))
        #expect(!f.registry.enabledModules.contains(module))
        #expect(!f.env.modules.modules.contains(module))
        let leftovers = f.registry.descriptors.filter { $0.module == module }
        #expect(leftovers.isEmpty, "\(module): \(leftovers.map(\.id))")
        #expect(!f.env.modules.locations.contains { $0.module == module })
        for descriptor in ActionCatalog.descriptors(module: module) {
            #expect(f.registry.availability(descriptor.id, host: f.router) == .hidden)
            #expect(await f.run(descriptor.id) == false)
        }
        await eventually { f.router.accounts.count == 2 && f.router.list?.state == .loaded }
        #expect(f.registry.contains(.markDone))
        #expect(await f.run(.markDone))
    }

    @Test func everyModuleOnRegistersItsEntriesLocationsAndSchedulers() {
        let env = AppEnvironment.fake(corpus: .make(threadCount: 5, now: fixedNow), featureFlags: FeatureFlags())
        #expect(env.actions.enabledModules.count == FeatureModuleID.mur1.count + FeatureModuleID.mur2.count)
        #expect(Set(env.modules.modules) == Set(FeatureModuleID.mur1 + FeatureModuleID.mur2))
        for id in [ActionID.snooze, .unsnooze, .remind, .clearReminder, .unsubscribe, .goSnoozed, .goReminders,
                   .goScheduled, .goReview, .alwaysImportantSender, .explainPlacement, .toggleMute, .goMuted,
                   .blockSender, .blockDomain, .goBlocked] {
            #expect(env.actions.contains(id), "\(id)")
        }
        #expect(Set(env.modules.scheduleKinds) == [.snooze, .reminder, .sendLater])
        #expect(env.modules.locations.map(\.title) == ["Snoozed", "Scheduled", "Reminders", "Review queue"])
        #expect(env.modules.settingsPages.map(\.id)
            == ["importance", "notifications", "general.dockBadge", "general.loginItem", "blocked"])
        for id in ReviewActionHandler.ids { #expect(env.actions.contains(id), "\(id)") }
        #expect(env.actions.contains(.sendLater) && env.actions.contains(.cancelSendLater))
        #expect(env.actions.contains(.send), "core entries stay in the catalog; with no handler they are hidden")
    }

    @Test func flagsComeFromUserDefaults() throws {
        let defaults = ScopedDefaults("dev.openhuman.mail.tests.flags")
        defer { defaults.cleanup() }
        defaults.set(false, forKey: FeatureFlags.key(.snooze))
        defaults.set(true, forKey: FeatureFlags.key(.ai))
        let flags = FeatureFlags.load(from: defaults)
        #expect(FeatureFlags.key(.snooze) == "feature.snooze.enabled")
        #expect(flags.values == [.snooze: false, .ai: true])
        #expect(!flags.isEnabled(.snooze, default: true))
        #expect(flags.isEnabled(.reminders, default: true), "absent = the module's default")
    }

    @Test func aUserKeymapRebindsTheRegistry() async throws {
        let f = ActionFixture()
        await f.loaded(10)
        f.registry.applyKeymap(KeymapOverrides(bindings: ["thread.done": ["y"], "thread.trash": ["e"]]))
        #expect(f.registry.descriptor(.markDone)?.defaultBindings.map(\.description) == ["Y"])
        #expect(f.registry.keymap.issues.isEmpty)
        #expect(f.registry.descriptor(.trash)?.shortcutHint == "E")
        f.registry.applyKeymap(KeymapOverrides(bindings: ["thread.trash": ["e"]]))
        #expect(f.registry.keymap.issues.count == 1, "collides with Mark done's default")
        #expect(f.registry.descriptor(.trash)?.shortcutHint == "#")
    }
}
