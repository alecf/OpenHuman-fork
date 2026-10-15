import AppKit
import MailActions
import MailFakes
@testable import MailFeatures
import MailModel
import MailTheme
@testable import MailUI
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

@MainActor
enum InviteFixtures {
    static func invitation(_ environment: AppEnvironment, corpus: FakeCorpus) async throws -> (ThreadKey, MessageSummary) {
        let account = try #require(corpus.accounts.first).id
        let rows = try await environment.data.threadPage(.system(.inbox), account: account, after: nil, limit: 500).rows
        for row in rows {
            for try await detail in environment.data.threadDetail(row.id) {
                if let message = detail?.messages.first(where: \.hasCalendarInvite) { return (row.id, message) }
                break
            }
        }
        throw CancellationError()
    }

    static func loadCard(_ environment: AppEnvironment, _ thread: ThreadKey, _ message: MessageSummary) async {
        environment.invites.load(message, in: thread, force: true)
        await environment.invites.pendingLoad(message.id)?.value
    }
}

@MainActor
@Suite(.serialized) struct InviteCardWindowTests {
    private let corpus = FakeCorpus.small

    private func environment() -> AppEnvironment {
        AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate))
    }

    @Test func theHostShowsTheCardOnceReadAndTheHTMLAfterShowOriginal() async throws {
        for tokens in [ThemeTokens.light, ThemeTokens.dark] {
            let env = environment()
            let (thread, message) = try await InviteFixtures.invitation(env, corpus: corpus)
            await InviteFixtures.loadCard(env, thread, message)
            #expect(env.invites.showsCard(message.id))
            let host = InviteCardHostView(center: env.invites, message: message.id, theme: tokens) { _ in }
            #expect(host.showsCard, "built after the read: the card stands in for the HTML")
            host.frame = NSRect(x: 0, y: 0, width: 640, height: 10)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height > 150, "the card has its rows")

            env.invites.toggleOriginal(message.id)
            let original = InviteCardHostView(center: env.invites, message: message.id, theme: tokens) { _ in }
            #expect(!original.showsCard, "Show original: the sender's HTML")
        }
    }

    @Test func aPartThatIsNotACalendarKeepsTheHTML() async throws {
        let env = environment()
        let (thread, message) = try await InviteFixtures.invitation(env, corpus: corpus)
        env.invites.readFile = { _ in "<html>not a calendar</html>" }
        await InviteFixtures.loadCard(env, thread, message)
        let host = InviteCardHostView(center: env.invites, message: message.id, theme: .light) { _ in }
        #expect(!host.showsCard && env.invites.entries[message.id] == .unavailable)
    }

    @Test func theButtonsSayWhatTheyDo() {
        #expect(InviteCardView.rsvpText(.accepted) == ("YES", "⇧A", "Yes, I'll attend"))
        #expect(InviteCardView.rsvpText(.tentative) == ("MAYBE", "⇧T", "Maybe"))
        #expect(InviteCardView.rsvpText(.declined) == ("NO", "⇧D", "No, I won't attend"))
        #expect(ActionCatalog.descriptor(.inviteYes)?.shortcutHint == "⇧A")
        #expect(ActionCatalog.descriptor(.inviteMaybe)?.shortcutHint == "⇧T")
        #expect(ActionCatalog.descriptor(.inviteNo)?.shortcutHint == "⇧D")
        let me = InviteCard.Guest(title: "Me", email: "robin@example.com", isOrganizer: false, isMe: true, response: nil,
                                  isOptional: false)
        let host = InviteCard.Guest(title: "Dana Ruiz", email: "dana@example.com", isOrganizer: true, isMe: false,
                                    response: .accepted, isOptional: false)
        #expect(InviteCardView.spoken(me) == "You, no answer yet")
        #expect(InviteCardView.spoken(host) == "Dana Ruiz, organizer, accepted")
    }
}
