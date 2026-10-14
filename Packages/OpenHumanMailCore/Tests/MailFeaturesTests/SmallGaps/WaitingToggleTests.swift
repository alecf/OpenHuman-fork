import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct WaitingToggleTests {
    private func fixture(_ location: MailLocation, options: FakeMailStore.Options = .init(remoteAck: .immediate)) async -> ActionFixture {
        let f = ActionFixture(corpus: .rich(threadCount: 40, now: fixedNow), options: options, location: location)
        await f.loaded()
        return f
    }

    private func port(_ f: ActionFixture) -> FakeWaitingRules { f.env.waiting as! FakeWaitingRules }

    @Test func theEntryHasAPaletteMenuAndKeyFollowingTheOtherThreadActions() throws {
        let d = try #require(ActionCatalog.descriptor(.toggleWaiting))
        #expect(d.id.rawValue == "waiting.toggle" && d.category == .thread && d.appearsInPalette && d.appearsInMenu)
        #expect(d.scopes == [.list, .reader] && d.target == .focusedThread && d.changesMail)
        #expect(d.defaultBindings == [.key("W")])
        #expect(KeyBindingConflicts.find(in: ActionCatalog.all).isEmpty, "W is free")
        #expect(MailActions.ActionCatalog.all.filter { $0.defaultBindings.contains(.key("W")) }.map(\.id) == [.toggleWaiting])
    }

    @Test func itIsOfferedOnlyInTheWaitingAndSentLists() async throws {
        let inbox = await fixture(.system(.inbox))
        #expect(inbox.registry.availability(.toggleWaiting, host: inbox.router) == .hidden)
        let waiting = await fixture(.system(.waiting))
        #expect(waiting.registry.availability(.toggleWaiting, host: waiting.router) == .enabled)
        let context = waiting.router.actionContext()
        let descriptor = try #require(waiting.registry.descriptor(.toggleWaiting))
        #expect(ActionRules.title(for: descriptor, in: context) == "Not waiting")
        let sent = await fixture(.system(.sent))
        #expect(sent.registry.availability(.toggleWaiting, host: sent.router) == .enabled)
        #expect(ActionRules.title(for: descriptor, in: sent.router.actionContext()) == "Wait for reply")
    }

    @Test func notWaitingInTheWaitingListSetsTheChoiceWithOneUndoEntry() async throws {
        let f = await fixture(.system(.waiting))
        let thread = try #require(f.router.actionContext().focusedThread)
        #expect(await f.run(.toggleWaiting))
        await f.toast("Not waiting")
        #expect(port(f).choices == [thread: .notWaiting])
        #expect(f.env.undo?.stack.last?.undoer != nil, "undone through the waiting port")
        #expect(await f.run(.undo))
        #expect(port(f).choices.isEmpty, "no choice again: the rule decides")
        #expect(await f.run(.redo))
        #expect(port(f).choices == [thread: .notWaiting])
    }

    @Test func waitForReplyInSentSetsWaiting() async throws {
        let f = await fixture(.system(.sent))
        let thread = try #require(f.router.actionContext().focusedThread)
        #expect(await f.run(.toggleWaiting))
        await f.toast("Waiting for a reply")
        #expect(port(f).choices == [thread: .waiting])
        #expect(await f.run(.undo))
        #expect(port(f).choices.isEmpty)
    }

    @Test func aChoiceChangedTwiceUndoesBackToTheEarlierOne() async throws {
        let receiptPort = FakeWaitingRules()
        let thread = ThreadKey(account: AccountID(1), rowID: 7, gmailThreadID: GmailThreadID("t7"))
        let first = try await receiptPort.setChoice(.waiting, for: thread)
        let second = try await receiptPort.setChoice(.notWaiting, for: thread)
        #expect(receiptPort.choices[thread] == .notWaiting)
        let redo = try #require(try await receiptPort.undo(second))
        #expect(receiptPort.choices[thread] == .waiting)
        _ = try await receiptPort.undo(redo)
        #expect(receiptPort.choices[thread] == .notWaiting)
        _ = try await receiptPort.undo(first)
        #expect(receiptPort.choices[thread] == nil)
    }

    @Test func readOnlySafeModeRefusesItBeforeThePort() async throws {
        let f = await fixture(.system(.waiting), options: .init(remoteAck: .immediate, safeMode: .readOnly))
        #expect(f.registry.availability(.toggleWaiting, host: f.router) == .disabled(.safeMode))
        _ = await f.run(.toggleWaiting)
        #expect(port(f).choices.isEmpty)
    }

    @Test func aFailureIsToldAndLeavesNothingChanged() async throws {
        let f = await fixture(.system(.waiting))
        port(f).failNext(.notFound("thread"))
        #expect(await f.run(.toggleWaiting))
        await f.toast("Couldn't mark the conversation as not waiting")
        #expect(port(f).choices.isEmpty)
    }

    @Test func theReceiptRoundTripsAndRefusesForeignTokens() throws {
        let thread = ThreadKey(account: AccountID(2), rowID: 3, gmailThreadID: GmailThreadID("t3"))
        let receipt = WaitingReceipt(thread: thread, restore: .waiting)
        #expect(try WaitingReceipt(token: receipt.token()) == receipt)
        #expect(throws: MailPortError.self) { try WaitingReceipt(token: UndoToken(payload: Data("x".utf8))) }
    }
}
