import Foundation
import MailActions
import MailFakes
import MailModel
import Observation
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct RecipientHistoryTests {
    @Test func startingAReadRedrawsTheFieldAtOnceSoItsRoomIsKeptBeforeTheAnswer() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let history = RecipientHistory(lookup: { _ in
            for await _ in gate.stream { break }
            return 3
        })
        let address = EmailAddress(name: "Dana Reyes", email: "dana@example.org")
        final class Count: @unchecked Sendable { var value = 0 }
        let redraws = Count()
        withObservationTracking { _ = history.isPending(in: [address]) } onChange: { redraws.value += 1 }
        #expect(!history.isPending(in: [address]))
        history.load(address.email)
        #expect(redraws.value == 1, "starting the read is a change the field sees")
        #expect(history.isPending(in: [address]), "the room is kept while the read is on its way")
        #expect(history.line(for: address) == nil)
        gate.continuation.yield()
        await eventually { history.line(for: address) != nil }
        #expect(!history.isPending(in: [address]))
        #expect(history.line(for: address) == "3 conversations with Dana Reyes")
    }

    @Test func aToTokenWithHistoryCountsItsConversationsAndOpensThemAsASearch() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let session = try #require(f.env.compose.openNew(placement: .modal))
        let lookup = try #require(f.env.compose.recipientHistoryLookup(for: session))
        let contact = try #require(try await f.store.contactSuggestions(session.account.id, prefix: "", limit: 1).first)
        let rows = try await f.store.recentThreads(involving: contact.email, account: session.account.id,
                                                   limit: RecipientHistory.limit + 1)
        #expect(await lookup(contact.email) == rows.count)

        let history = RecipientHistory(lookup: lookup)
        history.load(contact.email)
        history.load(contact.email.uppercased())
        await eventually { history.counts[contact.email.lowercased()] != nil }
        #expect(history.lookups == 1)
        if !rows.isEmpty {
            #expect(history.line(for: contact)?.hasSuffix("with \(RecipientParser.displayName(contact))") == true)
            #expect(history.shown(in: [contact]) == contact)
        }

        f.env.compose.searchConversations(with: contact, from: session)
        let query = RecipientHistory.query(for: contact.email)
        #expect(query == "from:\"\(contact.email.lowercased())\" OR to:\"\(contact.email.lowercased())\"")
        #expect(f.router.active?.location == .search(query) && f.router.active?.searchOpen == true)
        #expect(session.isOpen, "the draft stays as it is")
    }

    @Test func theLineSaysHowManyAndNothingForNone() async throws {
        let counts = ["one@example.com": 1, "few@example.com": 12, "many@example.com": 101, "none@example.com": 0]
        let history = RecipientHistory(lookup: { email in counts[email] })
        let people = [EmailAddress(name: "Ann One", email: "one@example.com"), EmailAddress(email: "few@example.com"),
                      EmailAddress(name: "Max", email: "many@example.com"), EmailAddress(name: "Nobody", email: "none@example.com")]
        for person in people { history.load(person.email) }
        history.load("not an address")
        await eventually { history.counts.count == 4 }
        #expect(history.line(for: people[0]) == "1 conversation with Ann One")
        #expect(history.line(for: people[1]) == "12 conversations with few@example.com")
        #expect(history.line(for: people[2]) == "100+ conversations with Max")
        #expect(history.line(for: people[3]) == nil, "no history: no line")
        #expect(history.shown(in: people) == people[2], "the newest token with history")
        #expect(history.lookups == 4, "an invalid address is never looked up")
    }

    @Test func theModuleOffLeavesTheComposerAsItWas() async throws {
        let off = OverlayFixture(flags: FeatureFlags().with(.smartSearch, false))
        await off.loaded()
        let session = try #require(off.env.compose.openNew(placement: .modal))
        #expect(off.env.compose.recipientHistoryLookup(for: session) == nil)
    }
}
