import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
struct NewslettersSplitTests {
    private func info(_ name: String, _ rule: String, _ position: Int) -> SplitInfo {
        SplitInfo(id: SplitKey("s\(position)"), account: AccountID(1), name: name, position: position, ruleText: rule)
    }

    @Test func thePresetReadsListHeadersAndPromotions() {
        let preset = SplitPresets.newsletters
        #expect(preset.id == "newsletters" && !preset.needsDomain)
        #expect(preset.ruleText == "list:. OR category:promotions")
        #expect(SplitPresets.all.last == preset, "still offered in Settings › Split inbox › Add preset…")
    }

    @Test func theTabIsNamedNewslettersUnlessTheAccountHasOneAlready() {
        let important = info("Important", "is:important", 0)
        #expect(SplitPresets.newslettersTabName(for: [important]) == "Newsletters")
        #expect(SplitPresets.newslettersTabName(for: [important, info("Calendar", "is:event", 1)]) == "Newsletters")
        #expect(SplitPresets.newslettersTabName(for: [important, info("Lists", " LIST:. or CATEGORY:promotions ", 1)])
                == nil)
        #expect(SplitPresets.newslettersTabName(for: [important, info("newsletters", "category:updates", 1)]) == nil)
    }

    @Test func thePaletteAddsTheNewslettersTabWithOneUndoAndThenHidesTheEntry() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 160, now: fixedNow))
        await f.loaded()
        let work = try #require(f.router.active)
        await eventually { work.splitsLoaded }
        #expect(f.registry.availability(.addNewslettersSplit, host: f.router, context: f.router.actionContext())
                == .hidden, "Work already has a Newsletters tab")

        #expect(f.router.perform(.switchToAccount(2)))
        let personal = try #require(f.router.active)
        await eventually { personal.splitsLoaded && f.router.list?.state == .loaded }
        let before = personal.splits.map(\.id)
        #expect(f.registry.availability(.addNewslettersSplit, host: f.router, context: f.router.actionContext())
                == .enabled)
        let entries = f.env.undo?.stack.count ?? 0
        #expect(await f.run(.addNewslettersSplit, source: .palette))
        await eventually { personal.splits.contains { $0.name == "Newsletters" } }
        let added = try #require(personal.splits.first { $0.name == "Newsletters" })
        #expect(added.ruleText == SplitPresets.newsletters.ruleText)
        #expect(Array(personal.splits.map(\.id).prefix(before.count)) == before, "nothing reordered or removed")
        #expect(f.env.undo?.stack.count == entries + 1, "one undo entry")
        await eventually { f.router.location == .split(added.id) && f.router.list?.state == .loaded }
        #expect(f.rows.contains { $0.subject.hasSuffix("weekly") })
        await eventually {
            f.registry.availability(.addNewslettersSplit, host: f.router, context: f.router.actionContext()) == .hidden
        }

        #expect(await f.run(.undo))
        await eventually { !personal.splits.contains { $0.name == "Newsletters" } }
        #expect(personal.splits.map(\.id) == before)
    }

    @Test func readOnlySafeModeNeverAddsTheTab() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 160, now: fixedNow),
                               options: .init(remoteAck: .immediate, safeMode: .readOnly))
        await f.loaded()
        #expect(f.router.perform(.switchToAccount(2)))
        let personal = try #require(f.router.active)
        await eventually { personal.splitsLoaded }
        let before = personal.splits
        let availability = f.registry.availability(.addNewslettersSplit, host: f.router,
                                                   context: f.router.actionContext())
        #expect(availability != .enabled, "a split edit is refused in read-only")
        _ = await f.run(.addNewslettersSplit, source: .palette)
        #expect(personal.splits == before)
    }

    @Test func thePaletteFindsItByNewsletterWords() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 160, now: fixedNow))
        await f.loaded()
        #expect(f.router.perform(.switchToAccount(2)))
        let personal = try #require(f.router.active)
        await eventually { personal.splitsLoaded }
        let palette = f.registry.palette
        palette.open(host: f.router)
        for query in ["newsletters", "bundle newsletters", "add newsletters split"] {
            palette.query = query
            #expect(palette.rows.contains { $0.action == .addNewslettersSplit }, Comment(rawValue: query))
        }
        palette.close()
    }
}
