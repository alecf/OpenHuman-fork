import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct WriteModeTests {
    private func fixture() -> ComposeFixture { ComposeFixture(writeMode: WriteModeSession()) }

    @Test func writeModeHasNoIndicator() async throws {
        let f = fixture()
        await f.loaded()
        #expect(f.env.writeMode != nil && f.env.status.isWriteMode)
        #expect(f.env.status.safeModeText == nil && f.env.status.safeModeDetail == nil && f.env.status.safeModeHelp == nil)
        #expect(!f.router.windowTitle.contains("Write mode"))
        #expect(GeneralSettingsModel(environment: f.env).showsWriteModeSending)

        let plain = ComposeFixture()
        await plain.loaded()
        #expect(plain.env.writeMode == nil && !plain.env.status.isWriteMode && plain.env.status.safeModeText == nil)
        #expect(plain.router.windowTitle == f.router.windowTitle, "write mode and normal look the same")
        #expect(!GeneralSettingsModel(environment: plain.env).showsWriteModeSending)
        let readOnly = StatusModel(data: FakeMailStore(corpus: .make(), options: .init(safeMode: .readOnly)), isWriteMode: true)
        #expect(!readOnly.isWriteMode && readOnly.safeModeText == "Read-only")
    }

    @Test func sendIsHiddenByDefaultAndConfirmBeforeSendingShowsTheCard() async throws {
        let f = fixture()
        await f.loaded()
        #expect(WriteModeSession.confirmEverySend.defaultValue == false)
        let settings = GeneralSettingsModel(environment: f.env)
        settings.start()
        #expect(settings.showsWriteModeSending && GeneralSettingsModel.confirmBeforeSendingTitle == "Confirm before sending")
        await soon { !settings.confirmEverySend.value }
        #expect(settings.confirmEverySend.value == false, "off by default")

        let quiet = try #require(f.compose.openNew(placement: .modal))
        quiet.to.text = "dana@acme.example,"
        quiet.subject = "Synthetic"
        quiet.updateBody(doc("Hello"))
        #expect(await f.run(.send, in: quiet))
        await soon { f.recorder.calls.contains("send") }
        #expect(quiet.sendConfirmation == nil, "no card by default")
        await f.toast("Sending to ")

        await settings.confirmEverySend.set(true)
        #expect(try await f.store.get(WriteModeSession.confirmEverySend) == true)
        let asked = try #require(f.compose.openNew(placement: .modal))
        asked.to.text = "sam@acme.example,"
        asked.subject = "Synthetic"
        asked.updateBody(doc("Hello again"))
        let sends = f.recorder.calls.filter { $0 == "send" }.count
        #expect(await f.run(.send, in: asked))
        let card = try #require(asked.sendConfirmation, "the switch on shows the card")
        #expect(card.title == "Send this message?")
        #expect(f.recorder.calls.filter { $0 == "send" }.count == sends, "nothing sent before the user confirms")
        asked.cancelSendConfirmation()
    }

    @Test func aSendOfAnySizeGoesStraightToItsUndoWindow() async throws {
        let f = fixture()
        await f.loaded()
        #expect(try await f.store.get(WriteModeSession.confirmEverySend) == false, "off by default")
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = (1...25).map { "person\($0)@acme.example" }.joined(separator: ", ") + ","
        session.subject = "Synthetic"
        session.updateBody(doc("Hello"))
        #expect(await f.run(.send, in: session))
        await soon { f.recorder.calls.contains("send") }
        #expect(session.sendConfirmation == nil, "no card")
        await f.toast("Sending to ")
        let toast = try #require(f.env.notices.toasts.first { $0.message.hasPrefix("Sending to ") })
        #expect(toast.style == .undo && toast.actionTitle == "Undo" && toast.shortcut == "⌘Z")
        #expect(await f.run(.undo))
        await soon { f.recorder.calls.contains("cancelSend") && session.isOpen }
        #expect(f.store.heldSendCount == 0 && f.store.sentMessages.isEmpty, "nothing reached Gmail")
    }

    @Test func confirmEverySendIsTheUsersChoice() async throws {
        let f = fixture()
        await f.loaded()
        try await f.store.set(WriteModeSession.confirmEverySend, true)
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = "Dana Ruiz <dana@acme.example>,"
        session.subject = "Synthetic"
        session.updateBody(doc("Hello"))
        #expect(await f.run(.send, in: session))
        let card = try #require(session.sendConfirmation)
        #expect(card.kind == .send && card.title == "Send this message?" && card.confirmTitle == "Send")
        #expect(card.message == "It goes to Dana Ruiz.")
        #expect(!f.recorder.calls.contains("send"), "nothing reaches the port before the user confirms")
        session.cancelSendConfirmation()
        #expect(session.sendConfirmation == nil && !f.recorder.calls.contains("send"))
        #expect(await f.run(.send, in: session))
        f.compose.confirmSend(in: session, stopAsking: true)
        await soon { f.recorder.calls.filter { $0 == "send" }.count == 1 }
        f.store.completeHeldSends()
        f.heldGate.release()
        await f.compose.settle()
        #expect(try await f.store.get(WriteModeSession.confirmEverySend) == false, "Don't ask again turned it off")
    }

    @Test func sendLaterAsksOnlyWhenConfirmEverySendIsOn() async throws {
        let f = fixture()
        await f.loaded()
        let at = fixedNow.addingTimeInterval(3_600)
        let quiet = try #require(f.compose.openNew(placement: .modal))
        quiet.to.text = "dana@acme.example,"
        quiet.updateBody(doc("Later"))
        await f.compose.schedule(quiet, at: at)
        #expect(quiet.sendConfirmation == nil && f.recorder.calls.contains("scheduleSend"))
        await f.toast("Scheduled for ")

        try await f.store.set(WriteModeSession.confirmEverySend, true)
        let asked = try #require(f.compose.openNew(placement: .modal))
        asked.to.text = "sam@acme.example,"
        asked.updateBody(doc("Later too"))
        let schedules = f.recorder.calls.filter { $0 == "scheduleSend" }.count
        await f.compose.schedule(asked, at: at)
        let card = try #require(asked.sendConfirmation)
        #expect(card.kind == .schedule(at) && card.title == "Schedule this message?" && card.confirmTitle == "Schedule")
        #expect(card.message.hasPrefix("It goes out at ") && !card.message.contains("real"))
        #expect(f.recorder.calls.filter { $0 == "scheduleSend" }.count == schedules)
        f.compose.confirmSend(in: asked)
        await soon { f.recorder.calls.filter { $0 == "scheduleSend" }.count == schedules + 1 }
    }

    @Test func aBulkChangeOfAnySizeGoesAtOnceAndOneUndoReversesIt() async throws {
        let f = fixture()
        await f.loaded()
        f.router.go(to: .system(.inbox))
        await soon { (f.router.list?.rows.count ?? 0) >= 3 }
        let rows = try #require(f.router.list?.rows.map(\.id))
        let before = Dictionary(uniqueKeysWithValues: rows.map { ($0, f.store.labelNames(of: $0)) })
        #expect(await f.run(.checkAll))
        let checked = f.router.active?.selection.checked.count ?? 0
        #expect(checked == rows.count && checked >= 3)
        let starred = rows.filter { f.router.list?.row(for: $0)?.isStarred == true }.count
        let changed = starred == rows.count ? rows.count : rows.count - starred
        #expect(await f.run(.toggleStar))
        await soon { f.recorder.calls.filter { $0 == "apply" }.count == 1 }
        let entry = try #require(f.env.undo?.stack.last)
        #expect(f.env.undo?.stack.count == 1 && entry.threads.count == changed, "one entry for the whole batch")
        let verb = starred == rows.count ? "Unstarred" : "Starred"
        let title = changed == 1 ? verb : "\(verb) \(changed) conversations"
        #expect(String(localized: entry.title) == title)
        let toast = try #require(f.env.notices.toasts.first { $0.style == .undo })
        #expect(toast.message == title && toast.actionTitle == "Undo" && toast.shortcut == "⌘Z")
        #expect(await f.run(.undo))
        await soon { f.recorder.calls.filter { $0 == "undo" }.count == 1 }
        await soon { rows.allSatisfy { f.store.labelNames(of: $0) == before[$0] } }
    }

    @Test func theSignInScreenOffersOpenReadOnlyOnlyWhenTheAppSetsIt() async {
        let store = FakeMailStore(corpus: .make())
        let model = SignInModel(accounts: store, safeMode: .normal, loginHint: "robin@example.com",
                                notice: "Sign in again to allow changes.")
        #expect(!model.offersReadOnly)
        model.openReadOnly()
        var opened = 0
        model.onOpenReadOnly = { opened += 1 }
        #expect(model.offersReadOnly)
        model.openReadOnly()
        #expect(opened == 1)
    }
}
