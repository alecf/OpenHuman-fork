import Foundation
import MailFeatures
import MailModel
import MailUI
import OpenHumanMailLive
import OpenHumanSync
import SwiftUI
import Testing
@testable import OpenHumanMail

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PhoneMailTests {
    @Test func launchesOnSampleMailWithTheSplitStrip() async throws {
        let app = CompositionRoot.makeApp(arguments: ["-UseFakeData"],
                                          environment: ["XCTestConfigurationFilePath": "MailiOSTests"])
        guard case .mail(let environment) = app.screen else {
            Issue.record("expected the mail screen")
            return
        }
        #expect(environment.isFake)
        let phone = await loadedPhone(environment)
        #expect(phone.showsSplitStrip)
        #expect(!phone.tabs.isEmpty)
        #expect(phone.active?.location == phone.tabs.first?.location)
        #expect(phone.path.isEmpty)
    }

    @Test func withoutASampleModeThePhoneSaysSignInComesLater() {
        #expect(CompositionRoot.dataMode(arguments: [], environment: [:]) == .live)
        guard case .notice(let problem) = CompositionRoot.live().screen else {
            Issue.record("expected a notice")
            return
        }
        #expect(problem.title == CompositionRoot.signInLaterTitle)
    }

    @Test func opensAConversationAndGoesBack() async throws {
        let phone = await loadedPhone()
        let key = try #require(phone.list?.rows.first?.id)

        phone.open(key)
        #expect(phone.path == [.reader])
        #expect(phone.reader?.thread == key)
        await untilObserved { phone.reader?.state == .loaded }
        #expect(phone.reader?.messages.isEmpty == false)

        phone.path = []
        #expect(phone.reader == nil, "the system back swipe closes the reader")
        #expect(phone.router.mode == .list)

        phone.open(key)
        phone.back()
        #expect(phone.path.isEmpty)
        #expect(phone.list?.row(for: key) != nil)
    }

    @Test func swipeDoneTakesTheRowOutAndUndoBringsItBack() async throws {
        let phone = await loadedPhone()
        let key = try #require(phone.list?.rows.first?.id)

        #expect(phone.done(key))
        #expect(phone.list?.row(for: key) == nil, "the row leaves in the same turn")
        await untilObserved { phone.notices.toasts.contains { $0.actionTitle == "Undo" } }
        let toast = try #require(phone.notices.toasts.last { $0.actionTitle == "Undo" })

        phone.activate(toast)
        await untilObserved { phone.list?.rows.contains { $0.id == key } == true }
        #expect(!phone.notices.toasts.contains { $0.id == toast.id })
    }

    @Test func swipeChangesTheRowBeforeTheStoreWriteFinishes() async throws {
        let gate = Gate()
        let (environment, store) = heldEnvironment(gate)
        let phone = await loadedPhone(environment)
        let key = try #require(phone.list?.rows.first?.id)
        #expect(try await inInbox(store, key))

        #expect(phone.done(key))
        #expect(phone.list?.row(for: key) == nil, "changed before any write")
        let write = try #require(environment.actions.lastTask)
        await gate.arrived()
        #expect(!gate.isOpen)
        #expect(try await inInbox(store, key), "the store write is still held")
        #expect(phone.notices.toasts.contains { $0.actionTitle == "Undo" }, "the toast shows before the write finishes")
        #expect(phone.list?.row(for: key) == nil)

        gate.release()
        await write.value
        #expect(try await inInbox(store, key) == false)
        #expect(phone.list?.row(for: key) == nil)
    }

    @Test func composeThenDiscardClosesTheSheetWithUndo() async throws {
        let phone = await loadedPhone()
        phone.newMessage()
        let session = try #require(phone.composer)
        #expect(session.mode == .new)

        session.to.text = "dana@example.test"
        #expect(session.to.commitText())
        session.subject = "Lunch on Friday"
        session.updateBody(ComposeSheet.document("See you there."))

        phone.discard(session)
        #expect(phone.composer == nil)
        #expect(!session.isOpen)
        #expect(phone.notices.toasts.contains { $0.message == "Discarded draft" && $0.actionTitle == "Undo" })
        #expect(phone.compose.sending.isEmpty)
    }

    @Test func closingTheComposerKeepsTheDraftAndLeavesNothingOpen() async throws {
        let phone = await loadedPhone()
        phone.newMessage()
        let session = try #require(phone.composer)
        session.subject = "Notes"
        phone.closeComposer(session)
        #expect(phone.composer == nil)
        await phone.compose.settle()
        #expect(session.draftKey != nil)
    }

    @Test func scenePhasesBecomeEngineEvents() async {
        let relay = ScenePhaseRelay()
        let events = AppSystemEvents(scenes: relay, monitorsNetwork: false)
        relay.changed(to: .active)
        relay.changed(to: .inactive)
        relay.changed(to: .background)
        relay.changed(to: .active)
        events.stop()
        var seen: [String] = []
        for await event in events.events {
            switch event {
            case .didBecomeActive: seen.append("active")
            case .didResignActive: seen.append("resign")
            default: seen.append("other")
            }
        }
        #expect(seen == ["active", "resign", "active"])
    }
}
