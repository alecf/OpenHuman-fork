import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct ParticipantsTests {
    private let me: Set<String> = ["me@example.com", "alias@example.com"]

    private func sender(_ name: String?, _ email: String?, me: Bool = false, unread: Bool = false,
                        to: [(String?, String)] = [], cc: [(String?, String)] = []) -> Participants.Sender {
        Participants.Sender(name: name, email: email, isFromMe: me, isUnread: unread,
                            toJSON: WireAddress.encode(to.map { WireAddress(n: $0.0, e: $0.1) }),
                            ccJSON: WireAddress.encode(cc.map { WireAddress(n: $0.0, e: $0.1) }))
    }

    @Test func aLoneSenderKeepsTheFullNameAndDoesNotListRecipients() {
        let r = Participants.render([sender("Alice Smith", "alice@x.com", to: [(nil, "me@example.com")])], me: me)
        #expect(r.display == "Alice Smith")
    }

    @Test func authorStartedThreadShowsTheOtherPersonFirstWithCount() {
        let r = Participants.render([
            sender("Me", "me@example.com", me: true, to: [("Bob Jones", "bob@x.com")]),
            sender("Bob Jones", "bob@x.com"),
            sender("Me", "me@example.com", me: true),
            sender("Bob Jones", "bob@x.com"),
        ], me: me)
        #expect(r.display == "Bob Jones (4)")
    }

    @Test func authorRepliedToThreadLeadsWithTheNewestOther() {
        let r = Participants.render([
            sender("Ann Lee", "ann@x.com"), sender("Dee Fox", "dee@x.com"), sender("Me", "me@example.com", me: true),
        ], me: me)
        #expect(r.display == "Dee, Ann (3)")
    }

    @Test func selfNoteShowsMe() {
        let r = Participants.render([sender("Me", "ME@example.com", to: [(nil, "alias@example.com")])], me: me)
        #expect(r.display == "me")
        let r2 = Participants.render([sender("Me", "me@example.com", me: true), sender(nil, "alias@example.com")], me: me)
        #expect(r2.display == "me (2)")
    }

    @Test func authorOnlyWroteShowsToTheRecipients() {
        let one = Participants.render([sender("Me", "me@example.com", me: true, to: [("Bob Jones", "bob@x.com")])], me: me)
        #expect(one.display == "To: Bob Jones")
        let two = Participants.render([
            sender("Me", "me@example.com", me: true, to: [("Old Person", "old@x.com")]),
            sender("Me", "me@example.com", me: true, to: [("Bob Jones", "bob@x.com"), (nil, "me@example.com")],
                   cc: [(nil, "carol@x.com")]),
        ], me: me)
        #expect(two.display == "To: Bob, carol (2)")
    }

    @Test func aliasCountsAsMeAndAliasReplyDoesNotLead() {
        let r = Participants.render([
            sender("Ann Lee", "ann@x.com", to: [(nil, "alias@example.com")]),
            sender("Me Work", "Alias@Example.com"),
        ], me: me)
        #expect(r.display == "Ann Lee (2)")
        let only = Participants.render([sender("Me Work", "alias@example.com", to: [("List", "list@x.com")])], me: me)
        #expect(only.display == "To: List")
    }

    @Test func aMailingListThatContainsTheAuthorInToIsNotMe() {
        let r = Participants.render([sender("Team List", "team@x.com", to: [(nil, "me@example.com")])], me: me)
        #expect(r.display == "Team List")
    }

    @Test func groupOfThreeOthersAndTheMoreRule() throws {
        let three = Participants.render([sender("A One", "a@x.com"), sender("B Two", "b@x.com"), sender("C Three", "c@x.com")], me: me)
        #expect(three.display == "C, B, A (3)")
        let people = (0..<8).map { sender("P\($0) Last", "p\($0)@x.com", unread: $0 == 0) }
        let r = Participants.render(people, me: me)
        #expect(r.display == "P7, P6, P5 +5 (8)")
        let json = try JSONDecoder().decode([WirePerson].self, from: Data(r.json.utf8))
        #expect(json.count == 6 && json.first?.e == "p7@x.com" && json.allSatisfy { $0.me == 0 })
    }

    @Test func senderWithoutNameFallsBackToTheLocalPart() {
        #expect(Participants.render([sender(nil, "jane.doe@x.com")], me: me).display == "jane.doe")
        #expect(Participants.render([sender("  ", "jane@x.com"), sender("Ann Lee", "ann@x.com")], me: me).display == "Ann, jane (2)")
    }

    @Test func jsonListsOthersThenMeWithUnreadFlags() throws {
        let r = Participants.render([sender("Me", "me@example.com", me: true), sender(nil, "A@X.com"),
                                     sender("Ann", "a@x.com", unread: true)], me: me)
        #expect(r.display == "Ann (3)")
        let json = try JSONDecoder().decode([WirePerson].self, from: Data(r.json.utf8))
        #expect(json.count == 2 && json[0].u == 1 && json[0].n == "Ann" && json[0].me == 0 && json[1].me == 1)
    }

    @Test func messagesWithoutSenderAreSkipped() {
        #expect(Participants.render([sender(nil, nil)], me: me).display == "")
        #expect(Participants.render([], me: me).json == "[]")
    }

    @Test func reopeningAStoreRebuildsOldDisplayText() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oh-part-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let options = StoreOptions(location: StoreLocation(directory: dir), processKind: .test, appVersion: "test",
                                changeNotificationName: "oh.test.part.\(UUID().uuidString)")
        var store = try MailStore.open(options)
        let account = try store.addAccount(email: "me@example.com", displayName: "Me", scopes: ["gmail.readonly"])
        _ = try store.upsertMessages([
            .fixture("m1", thread: "t1", minutes: 0, from: "me@example.com", fromName: "Me", to: ["bob@example.com"]),
            .fixture("m2", thread: "t1", minutes: 1, from: "bob@example.com", fromName: "Bob Jones"),
        ], account: account, generation: 1)
        try store.write { db in
            try db.execute(sql: "UPDATE threads SET participants_display = 'me, Bob (2)'")
            try db.execute(sql: "DELETE FROM maintenance_tasks WHERE task = ?", arguments: [MailStore.participantsTask])
        }
        try store.close()
        store = try MailStore.open(options)
        let text = try store.read { try String.fetchOne($0, sql: "SELECT participants_display FROM threads") }
        #expect(text == "Bob Jones (2)")
        try store.close()
    }
}
