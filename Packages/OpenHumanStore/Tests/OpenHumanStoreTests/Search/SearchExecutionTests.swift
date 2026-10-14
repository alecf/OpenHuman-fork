import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

struct SearchFixture {
    let store: MailStore
    let account: AccountID
    static let t0: Double = 1_790_000_000

    init(complete: Bool = true) throws {
        (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        try store.upsertLabels([LabelUpsert(gmailLabelID: GmailLabelID("Label_1"), name: "Clients/Acme", type: "user")],
                               account: account, removeMissing: false)
        func body(_ text: String) -> MessageBodyUpsert { .fixture(html: nil, text: text) }
        var m1 = MessageUpsert.fixture("inv1", thread: "T-inv", minutes: 0, labels: ["INBOX", "UNREAD", "Label_1"],
                                       from: "billing@acme.example", fromName: "Acme Billing",
                                       subject: "Quarterly invoice from Acme", snippet: "Please find the invoice",
                                       body: body("Please find the invoice attached. Payment due in thirty days. Zeppelin ok"))
        m1.attachments = [AttachmentUpsert(partID: "2", filename: "invoice-2026.pdf", mimeType: "application/pdf", size: 5000, isInline: false)]
        m1.sizeEstimate = 300_000
        m1.headers?.cc = [EmailAddress(name: "Carol Ng", email: "carol@example.com")]
        var m2 = MessageUpsert.fixture("inv2", thread: "T-inv", minutes: 10, labels: ["SENT"], from: "me@example.com",
                                       fromName: "Me", to: ["billing@acme.example"], subject: "Re: Quarterly invoice from Acme",
                                       snippet: "Thanks, paying", body: body("Thanks, paying on Friday."))
        m2.sizeEstimate = 2_000
        let lunch = MessageUpsert.fixture("lunch", minutes: 20, labels: ["INBOX", "UNREAD", "STARRED"], from: "alice@example.com",
                                          subject: "Lunch tomorrow?", snippet: "Want sushi?", body: body("Want to grab sushi at noon? Reply ok."))
        var news = MessageUpsert.fixture("news", minutes: 30, labels: ["INBOX", "CATEGORY_PROMOTIONS"], from: "news@list.example.com",
                                         fromName: "The Newsletter", subject: "Weekly newsletter", snippet: "This week", body: body("Top stories this week."))
        news.headers?.listID = "<weekly.list.example.com>"
        let spam = MessageUpsert.fixture("spam", minutes: 40, labels: ["SPAM"], from: "x@spam.test", subject: "Cheap invoice offer",
                                         snippet: "buy", body: body("Cheap invoices for you"))
        let trash = MessageUpsert.fixture("trash", minutes: 50, labels: ["TRASH"], from: "old@example.com", subject: "Old invoice",
                                          snippet: "old", body: body("Old invoice body"))
        let cjk = MessageUpsert.fixture("cjk", minutes: 60, labels: ["INBOX"], from: "tanaka@example.jp", fromName: "田中",
                                        subject: "会議の議事録", snippet: "明日", body: body("明日の会議について共有します。"))
        let short = MessageUpsert.fixture("short", minutes: 70, labels: ["INBOX"], from: "ops@example.com", subject: "Go to AI summit",
                                          snippet: "ai", body: body("See you there"))
        let ancient = MessageUpsert.fixture("ancient", minutes: -60 * 24 * 400, labels: ["INBOX"], from: "archive@example.com",
                                            subject: "Ancient invoice archive", snippet: "old", body: body("Archive of invoices"))
        let draft = MessageUpsert.fixture("draft", minutes: 80, labels: ["DRAFT"], from: "me@example.com", subject: "Draft invoice note",
                                          snippet: "draft", body: body("draft invoice"))
        _ = try store.upsertMessages([m1, m2, lunch, news, spam, trash, cjk, short, ancient, draft], account: account, generation: 1)
        if complete { try markBackfillComplete() }
    }

    static let shared: SearchFixture = {
        do { return try SearchFixture() } catch { fatalError("search corpus: \(error)") }
    }()

    func markBackfillComplete() throws {
        try store.write { db in
            try db.execute(sql: "UPDATE sync_state SET backfill_complete = 1 WHERE account_id = ?", arguments: [account.rawValue])
        }
    }

    func search(_ text: String, limit: Int = 50, after: ThreadCursor? = nil, now: Date = searchTestNow) throws -> SearchPage {
        try store.search(try parseSearchQuery(text), accounts: nil, after: after, limit: limit, ranking: BM25RecencyRanking(), now: now)
    }

    func threads(_ text: String) throws -> [String] {
        try search(text).hits.map { $0.thread.ref.gmailThreadID.rawValue }
    }

    func set(_ text: String) throws -> Set<String> { Set(try threads(text)) }
}

@Suite struct SearchOperatorTests {
    let f = SearchFixture.shared

    @Test func freeTextIsASubstringMatchAcrossFieldsAndCaseInsensitive() throws {
        #expect(try f.set("oice") == ["T-inv", "t-ancient"])
        #expect(try f.set("INVOICE") == ["T-inv", "t-ancient"])
        #expect(try f.set("zeppelin") == ["T-inv"])
        #expect(try f.set("acme billing") == ["T-inv"])
        #expect(try f.set("invoice-2026") == ["T-inv"])
        #expect(try f.set("nonexistentword") == [])
    }

    @Test func phrasesAreSubstrings() throws {
        #expect(try f.set("\"payment due in thirty\"") == ["T-inv"])
        #expect(try f.set("\"due payment\"") == [])
    }

    @Test func addressOperators() throws {
        #expect(try f.set("from:billing@acme.example") == ["T-inv"])
        #expect(try f.set("from:acme") == ["T-inv"])
        #expect(try f.set("from:\"acme billing\"") == ["T-inv"])
        #expect(try f.set("to:billing@acme.example") == ["T-inv"])
        #expect(try f.set("cc:carol") == ["T-inv"])
        #expect(try f.set("from:me") == ["T-inv"])
        #expect(try f.set("to:me").contains("t-lunch"))
        #expect(try f.set("from:nobody") == [])
        #expect(try f.set("from:\(String(repeating: "x", count: 5))%") == [])
    }

    @Test func flagsMailboxesLabelsAndHas() throws {
        #expect(try f.set("is:unread") == ["T-inv", "t-lunch"])
        #expect(try f.set("is:read in:inbox") == ["t-news", "t-cjk", "t-short", "t-ancient"])
        #expect(try f.set("is:starred") == ["t-lunch"])
        #expect(try f.set("in:sent") == ["T-inv"])
        #expect(try f.set("in:inbox") == ["T-inv", "t-lunch", "t-news", "t-cjk", "t-short", "t-ancient"])
        #expect(try f.set("in:spam") == ["t-spam"])
        #expect(try f.set("in:trash") == ["t-trash"])
        #expect(try f.set("in:drafts") == ["t-draft"])
        #expect(try f.set("label:Label_1") == ["T-inv"])
        #expect(try f.set("label:clients") == ["T-inv"])
        #expect(try f.set("label:Clients/Acme") == ["T-inv"])
        #expect(try f.set("label:clients-acme") == ["T-inv"])
        #expect(try f.set("category:promotions") == ["t-news"])
        #expect(try f.set("has:attachment") == ["T-inv"])
        #expect(try f.set("has:userlabels") == ["T-inv"])
        #expect(try f.set("has:nouserlabels in:inbox") == ["t-lunch", "t-news", "t-cjk", "t-short", "t-ancient"])
        #expect(try f.set("filename:pdf") == ["T-inv"])
        #expect(try f.set("filename:2026") == ["T-inv"])
        #expect(try f.set("list:weekly") == ["t-news"])
    }

    @Test func subjectDatesAndSizes() throws {
        #expect(try f.set("subject:invoice") == ["T-inv", "t-ancient"])
        #expect(try f.set("subject:zeppelin") == [])
        #expect(try f.set("invoice before:2026/01/01") == ["t-ancient"])
        #expect(try f.set("invoice after:2026/01/01") == ["T-inv"])
        #expect(try f.set("older_than:1y") == ["t-ancient"])
        #expect(try f.set("newer_than:1y invoice") == ["T-inv"])
        #expect(try f.set("larger:100k") == ["T-inv"])
        #expect(try f.set("smaller:3k in:sent") == ["T-inv"])
        #expect(try f.set("larger:100k smaller:200k") == [])
    }

    @Test func booleanStructure() throws {
        #expect(try f.set("invoice -from:billing@acme.example") == ["T-inv", "t-ancient"])
        #expect(try f.set("sushi OR zeppelin") == ["t-lunch", "T-inv"])
        #expect(try f.set("{sushi zeppelin} is:unread") == ["t-lunch", "T-inv"])
        let got = try f.set("from:alice@example.com OR from:billing@acme.example -is:starred")
        #expect(got == ["T-inv"], "\(got)")
        #expect(try f.set("(sushi OR newsletter) -in:inbox") == [])
        #expect(try f.set("-invoice in:inbox") == ["t-lunch", "t-news", "t-cjk", "t-short"])
        #expect(try f.set("NOT is:unread in:inbox sushi") == [])
    }

    @Test func scopeExcludesTrashSpamAndDraftsUnlessAsked() throws {
        #expect(try f.set("invoice") == ["T-inv", "t-ancient"])
        #expect(try f.set("invoice in:trash") == ["t-trash"])
        #expect(try f.set("invoice in:spam") == ["t-spam"])
        #expect(try f.set("invoice in:drafts") == ["t-draft"])
        #expect(try f.set("invoice in:anywhere") == ["T-inv", "t-ancient", "t-spam", "t-trash", "t-draft"])
        #expect(try f.set("invoice -in:trash") == ["T-inv", "t-ancient"])
    }

    @Test func accountScoping() throws {
        let f = try SearchFixture()
        let other = try f.store.addAccount(email: "other@example.com", displayName: "Other", scopes: ["gmail.readonly"])
        let q = try parseSearchQuery("invoice")
        #expect(try f.store.search(q, accounts: [other], after: nil, limit: 10).hits.isEmpty)
        #expect(try f.store.search(q, accounts: [f.account], after: nil, limit: 10).hits.count == 2)
    }

    @Test func hitsCarryTheMatchingMessages() throws {
        let hit = try #require(try f.search("invoice thanks").hits.first)
        #expect(hit.thread.ref.gmailThreadID.rawValue == "T-inv" || hit.matchedMessageIDs.count >= 1)
        let all = try #require(try f.search("quarterly").hits.first)
        #expect(all.matchedMessageIDs.count == 2)
    }
}

@Suite struct SearchTrigramTests {
    let f = SearchFixture.shared

    @Test func cjkSubstrings() throws {
        #expect(try f.set("議事録") == ["t-cjk"])
        #expect(try f.set("会議の議事") == ["t-cjk"])
        #expect(try f.set("共有します") == ["t-cjk"])
        #expect(try f.set("田中") == ["t-cjk"])
        #expect(try f.set("会議") == ["t-cjk"])
        #expect(try f.set("議事") == ["t-cjk"])
    }

    @Test func shortTermsAreFoundByTheScanNeverSilentlyMissed() throws {
        #expect(try f.set("AI") == ["t-short"])
        #expect(try f.set("ai") == ["t-short"])
        #expect(try f.set("ok") == ["T-inv", "t-lunch"])
        #expect(try f.set("a") .count >= 5)
        #expect(try f.set("subject:ai") == ["t-short"])
        #expect(try f.set("ok sushi") == ["t-lunch"])
        #expect(try f.set("ok -sushi") == ["T-inv"])
        #expect(try f.set("\"a b\"") == [])
        #expect(try f.set("zz") == [])
        #expect(try f.set("%") == [])
        #expect(try f.set("_") == [])
        #expect(try f.set("filename:pd") == ["T-inv"])
    }

    @Test func compilerChoosesTheIndexOnlyForThreeOrMoreCharacters() throws {
        let long = SearchCompiler.compile(try parseSearchQuery("invoice"), accounts: nil)
        #expect(long.ftsMatch == "\"invoice\"" && !long.usesShortTermScan)
        let short = SearchCompiler.compile(try parseSearchQuery("ai"), accounts: nil)
        #expect(short.ftsMatch == nil && short.usesShortTermScan)
        let mixed = SearchCompiler.compile(try parseSearchQuery("ai invoice from:x"), accounts: nil)
        #expect(mixed.ftsMatch == "\"invoice\"" && mixed.usesShortTermScan)
        #expect(SearchCompiler.ftsExpression(.text("subject", field: .subject)) == "subject : \"subject\"")
        #expect(SearchCompiler.ftsExpression(.text("日本", field: nil)) == nil)
        #expect(SearchCompiler.ftsExpression(.text("日本語", field: nil)) == "\"日本語\"")
    }
}

@Suite struct SearchInjectionTests {
    let f = SearchFixture.shared

    static let hostile: [String] = [
        "\"", "\"\"", "\"\"\"", "a\"b", "invoice\"", "\"invoice", "*", "invoice*", "inv*", "\"inv\"*", "^invoice", "NEAR(invoice acme)",
        "NEAR(invoice acme, 2)", "invoice NEAR acme", "subject:invoice", "subject : invoice", "{subject}:invoice", "body:invoice",
        "participants:acme", "attachment_names:pdf", "invoice AND NOT acme", "invoice OR", "(invoice", "invoice)", ")", "(", "{", "}", ":",
        "::", "a:", ":a", "-", "--", "OR", "AND", "NOT", "AROUND", "'", "''", "'; DROP TABLE messages; --", "\" OR 1=1 --",
        "invoice' OR '1'='1", "%", "_", "\\", "\\%", "\u{0}", "invoice\u{0}acme", "\u{2}invoice\u{3}", "from:%", "from:'", "from:\"",
        "label:'", "label:%", "to:\\", "filename:*", "has:", "in:", "is:", "before:", "larger:\"", "list:%", "rfc822msgid:'", "\u{FFFD}",
        String(repeating: "(", count: 100), String(repeating: "\"", count: 99), String(repeating: "invoice ", count: 300),
    ]

    @Test(arguments: hostile) func hostileQueriesNeverBreakSQLOrFTS(_ text: String) throws {
        let query: SearchQuery
        do { query = try parseSearchQuery(text) } catch is StoreError { return }
        let page = try f.store.search(query, accounts: nil, after: nil, limit: 50, ranking: BM25RecencyRanking(), now: searchTestNow)
        #expect(page.hits.count <= 9)
        _ = page.completeness.gmailQuery
        let count = try f.store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM messages") ?? 0 }
        #expect(count == 10)
    }

    @Test func fullTextSyntaxInsideValuesIsLiteral() throws {
        #expect(try f.set("NEAR(invoice acme)") == [])
        #expect(try f.set("inv*") == [])
        #expect(try f.set("\"invoice\" \"acme\"") == ["T-inv"])
        #expect(try f.set("body:invoice") == [])
        #expect(try f.set("participants:acme") == [])
        #expect(try f.set("subject:\"x\" OR invoice") == ["T-inv", "t-ancient"])
        #expect(try f.set("invoice\" OR 1=1") == [])
    }

    @Test func highlightMarkersInQueryTextAreStripped() throws {
        let q = try parseSearchQuery("\u{2}invoice\u{3}")
        #expect(q.terms == [.text("invoice", field: nil)])
    }

    @Test func compiledSQLNeverContainsUserText() throws {
        let c = SearchCompiler.compile(try parseSearchQuery("from:'; DROP TABLE x; -- label:\"a'b\" \"q\"\"r\" subject:%"), accounts: [AccountID(1)])
        #expect(!c.predicate.contains("DROP") && !c.predicate.contains("a'b"))
        #expect(c.predicate.filter { $0 == "?" }.count == c.arguments.count)
    }
}
