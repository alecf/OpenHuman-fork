import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct OverlayFocusHandoffTests {
    final class Keeper: OverlayFocusKeeping {
        var calls: [Bool] = []
        func overlayChanged(showing: Bool) { calls.append(showing) }
    }

    @Test func theKeeperHearsEveryShowAndHideAtOnce() async throws {
        let f = OverlayFixture()
        await f.loaded(10)
        let keeper = Keeper()
        f.center.focusKeeper = keeper
        let shown = f.center.showing
        #expect(await f.run(.commandPalette))
        #expect(keeper.calls == [true], "told before anything is drawn")
        #expect(f.center.showing == shown + 1, "each overlay shown has an identity of its own")
        let palette = try #require(f.palette)
        palette.close()
        #expect(keeper.calls == [true, false])

        await f.run(.commandPalette)
        let again = try #require(f.palette)
        again.query = "snooze"
        let snooze = try #require(again.entries.first { $0.kind == .action(.snooze) })
        #expect(again.perform(snooze))
        await eventually { f.timePicker != nil }
        #expect(keeper.calls == [true, false, true, false, true])
        f.center.dismiss()
        #expect(keeper.calls.last == false)
        #expect(f.center.showing == shown + 3, "palette, palette, picker: three identities, never a model's address")

        await f.run(.commandPalette)
        await f.run(.commandPalette)
        #expect(!f.center.isShowing)
        #expect(keeper.calls.last == true)
    }

    @Test func rowsHaveOneIdEachAndTheCursorSitsOnARowThatRuns() async throws {
        let f = OverlayFixture(writePort: false)
        await f.loaded(10)
        await f.run(.commandPalette)
        let palette = try #require(f.palette)
        for query in ["", "d", "do", "done", "trash", "zzqqxx", "s", "snooze until", "go", "", "mark"] {
            palette.query = query
            let ids = palette.entries.map(\.id)
            #expect(Set(ids).count == ids.count, "one row per id for “\(query)”")
            if !palette.entries.isEmpty {
                #expect(palette.entries.indices.contains(palette.cursor))
                #expect(palette.entries[palette.cursor].isAvailable, "the cursor is on a row that runs for “\(query)”")
            }
        }
    }
}
