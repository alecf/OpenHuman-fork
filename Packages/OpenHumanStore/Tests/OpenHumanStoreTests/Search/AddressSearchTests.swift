import Foundation
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

struct AddressSearchFixture {
    let store: MailStore

    init() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount(email: "me@example.test")
        self.store = store
        func incoming(_ id: String, _ from: String, name: String? = nil, minutes: Int, labels: [String] = ["INBOX"],
                      subject: String = "Hello", listID: String? = nil) -> MessageUpsert {
            var m = MessageUpsert.fixture(id, minutes: minutes, labels: labels, from: from, fromName: name,
                                          to: ["me@example.test"], subject: subject)
            m.headers?.listID = listID
            return m
        }
        func outgoing(_ id: String, minutes: Int, to: [EmailAddress], cc: [EmailAddress], bcc: [EmailAddress]) -> MessageUpsert {
            var m = MessageUpsert.fixture(id, minutes: minutes, labels: ["SENT"], from: "me@example.test", fromName: "Me",
                                          to: [], subject: "Sent note")
            m.headers?.to = to
            m.headers?.cc = cc
            m.headers?.bcc = bcc
            return m
        }
        _ = try store.upsertMessages([
            incoming("bare", "ana@example.com", minutes: 0),
            incoming("named", "nia@example.com", name: "Nia Example", minutes: 1, subject: "Quarterly report"),
            incoming("sub", "bo@mail.example.com", minutes: 2, labels: ["INBOX", "UNREAD"]),
            incoming("upper", "Cy@News.Example.COM", name: "Cy", minutes: 3),
            incoming("prefixed", "dee@notexample.com", minutes: 4),
            incoming("suffixed", "eve@example.com.evil.test", minutes: 5),
            incoming("localpart", "example.com@evil.test", minutes: 6),
            incoming("spoofname", "fay@evil.test", name: "example.com Support", minutes: 7),
            incoming("other", "gus@example.test", name: "Gus", minutes: 8),
            outgoing("out1", minutes: 9, to: [EmailAddress(name: "Hal Example", email: "hal@example.com")],
                     cc: [EmailAddress(email: "ivy@ops.example.com")], bcc: [EmailAddress(email: "jo@notexample.com")]),
            outgoing("out2", minutes: 10, to: [EmailAddress(email: "kim@example.com.evil.test")],
                     cc: [EmailAddress(email: "lee@notexample.com")], bcc: [EmailAddress(email: "max@Archive.Example.com")]),
            incoming("list1", "digest@lists.example.test", minutes: 11, listID: "\"Weekly\" <weekly.lists.example.com>"),
            incoming("list2", "digest@lists.example.test", minutes: 12, listID: "<weekly.lists.notexample.com>"),
            incoming("list3", "digest@lists.example.test", minutes: 13, listID: "<weekly.example.com.evil.test>"),
        ], account: account, generation: 1)
    }

    static let shared: AddressSearchFixture = {
        do { return try AddressSearchFixture() } catch { fatalError("address corpus: \(error)") }
    }()

    func set(_ text: String) throws -> Set<String> {
        let page = try store.search(try parseSearchQuery(text), accounts: nil, after: nil, limit: 50,
                                    ranking: BM25RecencyRanking(), now: searchTestNow)
        return Set(page.hits.map { String($0.thread.ref.gmailThreadID.rawValue.dropFirst(2)) })
    }
}

@Suite struct AddressSearchTests {
    let f = AddressSearchFixture.shared
    static let exampleCom: Set<String> = ["bare", "named", "sub", "upper"]

    @Test(arguments: ["from:example.com", "from:EXAMPLE.COM", "from:Example.Com", "from:@example.com", "from:*@example.com",
                      "from:\"example.com\"", "from:\"@example.com\"", "from:(example.com)", "from:<example.com>"])
    func aDomainMatchesItsAddressesAndSubdomains(_ text: String) throws {
        #expect(try f.set(text) == Self.exampleCom, Comment(rawValue: text))
    }

    @Test func aSubdomainMatchesOnlyThatSubdomain() throws {
        #expect(try f.set("from:mail.example.com") == ["sub"])
        #expect(try f.set("from:NEWS.example.com") == ["upper"])
        #expect(try f.set("{from:mail.example.com from:news.example.com}") == ["sub", "upper"])
    }

    @Test func lookalikeDomainsDoNotMatch() throws {
        let found = try f.set("from:example.com")
        for lookalike in ["prefixed", "suffixed", "localpart", "spoofname"] {
            #expect(!found.contains(lookalike), Comment(rawValue: lookalike))
        }
        #expect(try f.set("from:notexample.com") == ["prefixed"])
        #expect(try f.set("from:example.com.evil.test") == ["suffixed"])
    }

    @Test func partialDomainsAreNotSubstrings() throws {
        #expect(try f.set("from:example.co") == [])
        #expect(try f.set("from:ample.com") == [])
        #expect(try f.set("from:example.org") == [])
    }

    @Test func fullAddressesMatchExactlyAndIgnoreCase() throws {
        #expect(try f.set("from:nia@example.com") == ["named"])
        #expect(try f.set("from:NIA@Example.COM") == ["named"])
        #expect(try f.set("from:cy@news.example.com") == ["upper"])
        #expect(try f.set("from:nia@example.co") == [])
        #expect(try f.set("from:eve@example.com") == [])
    }

    @Test func addressesWithDisplayNames() throws {
        #expect(try f.set("from:\"Nia Example <nia@example.com>\"") == ["named"])
        #expect(try f.set("from:<nia@example.com>") == ["named"])
        #expect(try f.set("from:\"Nia Example\"") == ["named"])
        #expect(try f.set("from:nia") == ["named"])
        #expect(try f.set("from:\"example.com Support\"") == ["spoofname"])
    }

    @Test func domainsCombineWithOtherTerms() throws {
        #expect(try f.set("from:example.com is:unread") == ["sub"])
        #expect(try f.set("from:example.com quarterly") == ["named"])
        #expect(try f.set("quarterly -from:example.com") == [])
        #expect(try f.set("from:example.com OR from:gus@example.test") == Self.exampleCom.union(["other"]))
        #expect(try f.set("from:(example.com OR gus@example.test)") == Self.exampleCom.union(["other"]))
        #expect(try f.set("-from:example.com in:inbox")
                == ["prefixed", "suffixed", "localpart", "spoofname", "other", "list1", "list2", "list3"])
        #expect(try f.set("from:example.com is:starred") == [])
        #expect(try f.set("from:example.com in:sent") == [])
    }

    @Test func recipientsUseTheSameDomainRules() throws {
        #expect(try f.set("to:example.com") == ["out1"])
        #expect(try f.set("deliveredto:example.com") == ["out1"])
        #expect(try f.set("to:example.com.evil.test") == ["out2"])
        #expect(try f.set("cc:example.com") == ["out1"])
        #expect(try f.set("cc:ops.example.com") == ["out1"])
        #expect(try f.set("cc:notexample.com") == ["out2"])
        #expect(try f.set("bcc:example.com") == ["out2"])
        #expect(try f.set("bcc:ARCHIVE.example.com") == ["out2"])
        #expect(try f.set("bcc:notexample.com") == ["out1"])
        #expect(try f.set("to:example.co") == [])
        #expect(try f.set("cc:ample.com") == [])
    }

    @Test func recipientAddressesAndNames() throws {
        #expect(try f.set("to:hal@example.com") == ["out1"])
        #expect(try f.set("to:HAL@EXAMPLE.COM") == ["out1"])
        #expect(try f.set("to:\"Hal Example\"") == ["out1"])
        #expect(try f.set("to:\"Hal Example <hal@example.com>\"") == ["out1"])
        #expect(try f.set("to:hal@example.co") == [])
        #expect(try f.set("to:kim@example.com") == [])
        #expect(try f.set("to:example.com cc:example.com") == ["out1"])
        #expect(try f.set("to:example.com -bcc:notexample.com") == [])
        #expect(try f.set("cc:example.com OR bcc:example.com") == ["out1", "out2"])
    }

    @Test func listIDsUseDomainRules() throws {
        #expect(try f.set("list:example.com") == ["list1"])
        #expect(try f.set("list:lists.example.com") == ["list1"])
        #expect(try f.set("list:weekly.lists.example.com") == ["list1"])
        #expect(try f.set("list:WEEKLY.Lists.Example.COM") == ["list1"])
        #expect(try f.set("list:\"<weekly.lists.example.com>\"") == ["list1"])
        #expect(try f.set("list:weekly@lists.example.com") == ["list1"])
        #expect(try f.set("list:notexample.com") == ["list2"])
        #expect(try f.set("list:example.co") == [])
        #expect(try f.set("list:weekly") == ["list1", "list2", "list3"])
        #expect(try f.set("list:example.com from:lists.example.test") == ["list1"])
    }

    @Test func domainValuesStayOutOfTheSQLText() throws {
        let c = SearchCompiler.compile(try parseSearchQuery("from:example.com to:@example.com cc:a@example.com list:example.com"),
                                       accounts: nil)
        #expect(!c.predicate.contains("example"))
        #expect(c.predicate.filter { $0 == "?" }.count == c.arguments.count)
    }
}

@Suite struct AddressPatternTests {
    @Test func displayNamesAndWildcardsNormalise() throws {
        let named = AddressPattern("Nia Example <NIA@example.com>")
        #expect(named.matches(email: "nia@example.com", name: nil))
        #expect(!named.matches(email: "nia@example.com.evil.test", name: nil))
        let wildcard = AddressPattern("*@example.com")
        #expect(wildcard.matches(email: "a@mail.example.com", name: nil))
        #expect(!wildcard.matches(email: "a@notexample.com", name: nil))
    }

    @Test func dottedNamesWithSpacesAreText() throws {
        let p = AddressPattern("Acme Inc.")
        #expect(p.matches(email: "billing@acme.example", name: "Acme Inc."))
        #expect(!p.matches(email: "billing@acme.example", name: "Acme"))
    }
}
