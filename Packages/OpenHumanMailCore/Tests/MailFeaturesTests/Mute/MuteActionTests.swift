import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct MuteActionTests {
    static let muted = OHGmailLabels.muted

    func inInbox(_ f: ActionFixture, _ key: ThreadKey) -> Bool {
        f.store.labelNames(of: key).contains { $0.uppercased() == "INBOX" }
    }

    func archived(_ f: ActionFixture, _ key: ThreadKey) -> Bool {
        f.store.isVisible(key) && !inInbox(f, key)
    }

    @Test func theFirstMuteCreatesTheLabelAndOneUndoTakesItAllBack() async throws {
        let f = ActionFixture()
        await f.loaded(10)
        let state = try #require(f.router.active)
        #expect(state.mutedLabel == nil, "nothing muted yet")
        let key = try #require(f.router.list?.cursor)
        #expect(ActionRules.title(for: try #require(f.registry.descriptor(.toggleMute)), in: f.router.actionContext())
                == "Mute")

        #expect(await f.run(.toggleMute))
        await f.toast("Muted")
        await f.loaded(9)
        await eventually { state.mutedLabel != nil }
        #expect(f.store.labelNames(of: key).contains(Self.muted))
        #expect(archived(f, key))
        #expect(f.env.undo?.stack.count == 1, "label creation and mark done are one entry")

        #expect(await f.run(.undo))
        await f.loaded(10)
        await eventually { !f.store.labelNames(of: key).contains(Self.muted) }
        #expect(inInbox(f, key))

        #expect(await f.run(.redo))
        await f.loaded(9)
        await eventually { f.store.labelNames(of: key).contains(Self.muted) }
        #expect(archived(f, key))
    }

    @Test func theMutedListUnmutesWithMAndShowsUnmuteInTheHintBar() async throws {
        let f = ActionFixture()
        await f.loaded(10)
        let state = try #require(f.router.active)
        let first = try #require(f.router.list?.cursor)
        #expect(await f.run(.toggleMute))
        await f.loaded(9)
        await eventually { state.mutedLabel != nil }
        let label = try #require(state.mutedLabel)
        let second = try #require(f.router.list?.cursor)
        #expect(await f.run(.toggleMute))
        await f.loaded(8)
        await eventually { f.store.labelNames(of: second).contains(Self.muted) }
        #expect(f.env.undo?.stack.count == 2)

        #expect(await f.run(.goMuted))
        await eventually { f.router.list?.location == .label(label.labelID) && f.router.list?.rows.count == 2 }
        await f.loaded(2)
        #expect(state.title(for: .label(label.labelID)) == "Muted")
        #expect(state.sidebarItems.contains { $0.location == .label(label.labelID) && $0.title == "Muted" })
        let hints = HintBarModel(router: f.router)
        #expect(hints.context == .muted)
        #expect(hints.hints.first.map { $0.keycaps.joined() + " " + $0.title } == "⇧M Unmute")

        let cursor = try #require(f.router.list?.cursor)
        #expect(Set([first, second]).contains(cursor))
        #expect(f.router.actionContext().targets.allMuted)
        #expect(await f.run(.toggleMute))
        await f.toast("Unmuted, moved to Inbox")
        await f.loaded(1)
        await eventually { inInbox(f, cursor) }
        #expect(!f.store.labelNames(of: cursor).contains(Self.muted))
        #expect(await f.run(.undo))
        await f.loaded(2)
    }

    @Test func aBatchIsOneEntryAndOneUndoRestoresIt() async throws {
        let f = ActionFixture()
        await f.loaded(10)
        let rows = f.rows.map(\.id)
        #expect(await f.run(.toggleCheck))
        #expect(await f.run(.extendSelectionDown))
        #expect(await f.run(.extendSelectionDown))
        #expect(await f.run(.toggleMute))
        await f.toast("Muted 3 conversations")
        await f.loaded(7)
        #expect(f.env.undo?.stack.count == 1)
        for key in rows[0...2] { #expect(f.store.labelNames(of: key).contains(Self.muted)) }
        #expect(await f.run(.undo))
        await f.loaded(10)
        for key in rows[0...2] {
            await eventually { !f.store.labelNames(of: key).contains(Self.muted) }
            #expect(inInbox(f, key))
        }
    }

    @Test func muteEndsASnoozeAndUndoPutsItBack() async throws {
        let f = ActionFixture()
        await f.loaded(10)
        #expect(await f.run(.toggleMute))
        await f.loaded(9)
        let key = try #require(f.router.list?.cursor)
        let wake = fixedNow.addingTimeInterval(3_600)
        let stamp = ScheduleLabel(kind: .snoozed, due: wake).name
        _ = try await f.store.apply(.snooze([key], until: wake))
        await f.loaded(8)
        #expect(await f.run(.goSnoozed))
        await eventually { f.router.list?.location == .system(.snoozed) && f.router.list?.rows.count == 1 }
        let entries = f.env.undo?.stack.count ?? 0

        #expect(await f.run(.toggleMute))
        await eventually { f.store.labelNames(of: key).contains(Self.muted) }
        await eventually { !f.store.labelNames(of: key).contains(stamp) }
        #expect(!f.store.labelNames(of: key).contains(OHGmailLabels.snoozed))
        #expect(f.env.undo?.stack.count == entries + 1, "ending the snooze and the mute are one entry")
        f.store.runSchedulers(now: wake.addingTimeInterval(60))
        #expect(archived(f, key), "no wake brings the muted conversation back")

        #expect(await f.run(.undo))
        await eventually { !f.store.labelNames(of: key).contains(Self.muted) }
        await eventually { f.store.labelNames(of: key).contains(stamp) }
        #expect(archived(f, key))

        #expect(await f.run(.redo))
        await eventually { f.store.labelNames(of: key).contains(Self.muted) }
        await eventually { !f.store.labelNames(of: key).contains(stamp) }
        #expect(archived(f, key))
    }

    @Test func readOnlyRefusesMuteBeforeThePortAndTheMutedListStillOpens() async throws {
        let f = ActionFixture(options: .init(safeMode: .readOnly))
        await f.loaded(10)
        #expect(f.registry.availability(.toggleMute, host: f.router) == .disabled(.safeMode))
        #expect(await f.run(.toggleMute), "consumed and refused out loud")
        #expect(f.store.pendingOperationCount == 0)
        #expect(f.toastMessages == ["Read-only: Mail can't change your mail"])
        #expect(f.env.undo?.stack.isEmpty != false)
        #expect(f.registry.availability(.goMuted, host: f.router) == .enabled)
        #expect(await f.run(.goMuted))
        await f.toast("Nothing is muted yet. Press ⇧M on a conversation to mute it.")
    }

    @Test func muteIsHiddenInTrashAndSpam() async throws {
        let f = ActionFixture()
        await f.loaded(10)
        #expect(f.registry.availability(.toggleMute, host: f.router) == .enabled)
        for folder in [SystemFolder.trash, .spam] {
            let c = ActionContext(scope: .list, location: .system(folder), selection: [try #require(f.router.list?.cursor)])
            #expect(ActionRules.availability(try #require(ActionCatalog.descriptor(.toggleMute)), in: c) == .hidden)
        }
    }
}
