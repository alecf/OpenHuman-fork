import Foundation
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct SearchHeaderMatchTests {
    private let terms = SearchHeaderTerms(words: ["quince", "developer"])

    @Test func senderNameAddressSubjectAndWordLevels() {
        #expect(terms.match(subject: "Membership renewal", fromName: "Quince Developer",
                            fromEmail: "developer@email.quince.example") == .senderName)
        #expect(terms.match(subject: "Membership renewal", fromName: "Q Team",
                            fromEmail: "developer@email.quince.example") == .senderAddress)
        #expect(terms.match(subject: nil, fromName: "Quince", fromEmail: "developer-news@orchard.example") == .senderAddress)
        #expect(terms.match(subject: "Notes from the Quince Developer meetup", fromName: "Rowan Field",
                            fromEmail: "rowan@field.example") == .subjectPhrase)
        #expect(terms.match(subject: "Developer notes about quince", fromName: "Rowan Field",
                            fromEmail: "rowan@field.example") == .allWords)
        #expect(terms.match(subject: "Your receipt", fromName: "Quince", fromEmail: "no_reply@email.quince.example")
                == .someWords(fraction: 0.5))
        #expect(terms.match(subject: "Weekly digest", fromName: "The Weekly Byte", fromEmail: "news@byte.example") == .none)
    }

    @Test func wordsMatchAtWordStartsCaseAndAccentsFolded() {
        let mail = SearchHeaderTerms(words: ["mail"])
        #expect(mail.match(subject: "Hello", fromName: "Ops", fromEmail: "ops@gmail.example") == .none)
        #expect(mail.match(subject: "Hello", fromName: "Mail Team", fromEmail: "ops@example.com") == .senderName)
        #expect(SearchHeaderTerms(words: ["dev"]).match(subject: nil, fromName: "Quince Developer", fromEmail: nil) == .senderName)
        #expect(SearchHeaderTerms(words: ["CAFE"]).match(subject: nil, fromName: "Café Owners", fromEmail: nil) == .senderName)
    }

    @Test func unspacedScriptsMatchAsSubstrings() {
        #expect(SearchHeaderTerms(words: ["会議"]).match(subject: "明日の会議について", fromName: "田中", fromEmail: nil)
                == .subjectPhrase)
    }

    @Test func aQuotedTermIsOneRunOfWords() {
        let quoted = SearchHeaderTerms(words: ["quince developer"])
        #expect(quoted.match(subject: nil, fromName: "Quince Developer Relations", fromEmail: nil) == .senderName)
        #expect(quoted.match(subject: nil, fromName: "Developer at Quince", fromEmail: nil) == .none)
    }

    @Test func onlyPositiveTopLevelTextTermsCount() throws {
        let query = try parseSearchQuery("quince -developer filename:orchard subject:notes from:rowan")
        #expect(SearchHeaderTerms(query: query).words == ["quince", "notes"])
        #expect(SearchHeaderTerms(query: try parseSearchQuery("quince developer")).ftsPhrase == "quince developer")
        #expect(SearchHeaderTerms(query: try parseSearchQuery("quince")).ftsPhrase == nil)
    }

    @Test func levelsAreOrderedAndQuarterSpaced() {
        let levels: [SearchHeaderMatch] = [.none, .someWords(fraction: 0.5), .allWords, .subjectPhrase, .senderAddress,
                                           .senderName]
        #expect(levels == levels.sorted())
        #expect(levels.map(\.value) == [0, 0.125, 0.5, 0.75, 1, 1])
        #expect(SearchHeaderMatch.senderName.label == "sender name match")
    }
}

@Suite struct BlendedSearchRankingTests {
    private let now = searchTestNow
    private let query = SearchQuery(text: "quince developer", terms: [])

    private func candidate(_ tid: Int64, header: SearchHeaderMatch = .none, bm25: Double? = -1, ageDays: Double = 0,
                           sent: Int = 0, together: Bool = false, external: Double? = nil) -> SearchCandidate {
        let at = now.addingTimeInterval(-ageDays * 86_400)
        return SearchCandidate(threadID: ThreadRowID(rawValue: tid), bestMessageID: MessageRowID(rawValue: tid),
                               matchedMessageIDs: [MessageRowID(rawValue: tid)], bestAt: at, newestAt: at, bm25: bm25,
                               externalScore: external, headerMatch: header, sentToCorrespondent: sent,
                               wordsTogether: together)
    }

    @Test func balancedLetsEachSenderSubjectLevelOutrankTheNext() {
        #expect(BlendedSearchRanking.Weights.balanced.headerLevelsDominate)
        let pairs: [(strong: SearchHeaderMatch, weak: SearchHeaderMatch)] = [
            (.senderName, .subjectPhrase), (.senderAddress, .subjectPhrase), (.subjectPhrase, .allWords),
            (.allWords, .someWords(fraction: 0.99)), (.senderName, .none),
        ]
        let opens = SearchClickHistory(score: 1_000, at: now)
        for pair in pairs {
            let strong = candidate(1, header: pair.strong, bm25: -0.0001, ageDays: 3_650, sent: 0, together: false)
            let weak = candidate(2, header: pair.weak, bm25: -50, ageDays: 0, sent: 10_000, together: true, external: 1)
            let ranking = BlendedSearchRanking(weights: .balanced, clicks: [ThreadRowID(rawValue: 2): opens])
            let scores = ranking.scores(for: [strong, weak], query: query, now: now)
            #expect(scores[0] > scores[1], "\(pair.strong) must outrank \(pair.weak)")
        }
    }

    @Test func recencyAndClicksReorderWithinALevel() {
        let older = candidate(1, header: .senderName, bm25: -2, ageDays: 60)
        let newer = candidate(2, header: .senderName, bm25: -2, ageDays: 3)
        let plain = BlendedSearchRanking().scores(for: [older, newer], query: query, now: now)
        #expect(plain[1] > plain[0])
        let opened = BlendedSearchRanking(clicks: [ThreadRowID(rawValue: 1): SearchClickHistory(score: 6, at: now)])
            .scores(for: [older, newer], query: query, now: now)
        #expect(opened[0] > opened[1])
    }

    @Test func aClearlyBetterTextMatchBeatsOneHalfLifeOfRecency() {
        let strong = candidate(1, bm25: -4, ageDays: 120)
        let weak = candidate(2, bm25: -2, ageDays: 0)
        let scores = BlendedSearchRanking().scores(for: [strong, weak], query: query, now: now)
        #expect(scores[0] > scores[1])
    }

    @Test func breakdownExplainsWithNumbersOnly() throws {
        let parts = BlendedSearchRanking().breakdowns(for: [candidate(1, header: .senderName, bm25: -3, ageDays: 120, sent: 5,
                                                                      together: true)], now: now)
        let only = try #require(parts.first)
        #expect(only.match == .senderName)
        #expect(only.wordsTogether == true)
        #expect(only.parts.map(\.signal) == SearchScoreBreakdown.Signal.allCases)
        #expect(only.part(.fields)?.points == 4)
        #expect(only.part(.text)?.value == 1)
        #expect(abs((only.part(.recency)?.value ?? 0) - 0.5) < 1e-9)
        #expect(only.part(.contacts)?.value == 0.5)
        #expect(abs(only.total - (4 + 0.45 + 0 + 0.075 + 0 + 0.05)) < 1e-9)
    }

    @Test func sameInputSameScores() {
        let candidates = (1...20).map { candidate(Int64($0), header: $0 % 3 == 0 ? .subjectPhrase : .none,
                                                   bm25: -Double($0 % 7 + 1), ageDays: Double($0 * 11), sent: $0 % 4) }
        let ranking = BlendedSearchRanking(clicks: [ThreadRowID(rawValue: 4): SearchClickHistory(score: 2, at: now)])
        #expect(ranking.scores(for: candidates, query: query, now: now) == ranking.scores(for: candidates, query: query, now: now))
    }

    @Test func clickHistoryHalvesPerHalfLife() {
        let history = SearchClickHistory(score: 4, at: now)
        #expect(history.decayed(at: now.addingTimeInterval(30 * 86_400), halfLifeDays: 30) == 2)
        let again = history.adding(at: now.addingTimeInterval(60 * 86_400), halfLifeDays: 30)
        #expect(again.score == 2)
        #expect(again.at == now.addingTimeInterval(60 * 86_400))
    }

    @Test func inputsFollowTheWeightsAndNewestFirstOrdersByDate() {
        #expect(BlendedSearchRanking().inputs == [.fields, .contacts, .phrase])
        var weights = BlendedSearchRanking.Weights.balanced
        weights.fields = 0
        weights.contacts = 0
        #expect(BlendedSearchRanking(weights: weights).inputs == [.phrase])
        #expect(BM25RecencyRanking().inputs == [])
        #expect(NewestFirstSearchRanking().ordersByDate)
        #expect(!BlendedSearchRanking().ordersByDate)
    }
}

struct QuinceCorpus {
    let store: MailStore
    let account: AccountID
    static let senderThreads = (1...6).map { "T-dev\($0)" }
    static let subjectThread = "T-meetup"

    init() throws {
        (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        func body(_ text: String) -> MessageBodyUpsert { .fixture(html: nil, text: text) }
        let day = 24 * 60
        var messages: [MessageUpsert] = []
        let programSubjects = ["Your Quince Developer Program membership", "Quince Developer Program: renewal reminder",
                               "Welcome to the Quince Developer Program", "Quince Developer Program agreement update",
                               "Your Quince Developer Program enrollment", "Quince Developer Program: account details"]
        for (i, subject) in programSubjects.enumerated() {
            messages.append(.fixture("dev\(i + 1)", thread: Self.senderThreads[i], minutes: -(420 + i * 45) * day,
                                     from: "developer@email.quince.example", fromName: "Quince Developer",
                                     subject: subject, snippet: "Thank you",
                                     body: body("Thank you for your membership. Your account is in good standing.")))
        }
        messages.append(.fixture("meetup", thread: Self.subjectThread, minutes: -200 * day, from: "rowan@field.example",
                                 fromName: "Rowan Field", subject: "Notes from the Quince Developer meetup",
                                 snippet: "Notes", body: body("Here are my notes from Thursday.")))
        messages.append(.fixture("to-rowan", thread: "T-other-rowan", minutes: -300 * day, labels: ["SENT"],
                                 from: "me@example.com", fromName: "Me", to: ["rowan@field.example"],
                                 subject: "Lunch", snippet: "Lunch", body: body("Lunch on Friday?")))
        let filler = (0..<40).map { "Stories about gardens, tools and travel number \($0)." }.joined(separator: " ")
        for i in 0..<30 {
            let mention = String(repeating: "Quince shipped new developer tools. Every developer should try Quince. ",
                                 count: 3 + i % 4)
            switch i % 3 {
            case 0:
                messages.append(.fixture("news\(i)", minutes: -(1 + i) * day, labels: ["INBOX", "CATEGORY_UPDATES"],
                                         from: "news@byte.example", fromName: "The Weekly Byte", subject: "This week in tech \(i)",
                                         snippet: "This week", body: body(filler + " " + mention + " " + filler)))
            case 1:
                messages.append(.fixture("receipt\(i)", minutes: -(2 + i) * day, labels: ["INBOX"],
                                         from: "no_reply@email.quince.example", fromName: "Quince",
                                         subject: "Your receipt from the store", snippet: "Receipt",
                                         body: body("Order details. Developer: Example Games. " + mention + filler)))
            default:
                messages.append(.fixture("promo\(i)", minutes: -(3 + i) * day, labels: ["INBOX", "CATEGORY_PROMOTIONS"],
                                         from: "offers@shop.example", fromName: "Shop Offers", subject: "Deals for you \(i)",
                                         snippet: "Deals", body: body(filler + " " + mention)))
            }
        }
        for i in 0..<120 {
            messages.append(.fixture("other\(i)", minutes: -(i * 3) * day, from: "friend\(i % 9)@example.com",
                                     subject: "Plans \(i)", snippet: "Plans",
                                     body: body("Let us meet for coffee and talk about the garden \(i).")))
        }
        _ = try store.upsertMessages(messages, account: account, generation: 1)
        try store.write { db in
            try db.execute(sql: "UPDATE sync_state SET backfill_complete = 1 WHERE account_id = ?", arguments: [account.rawValue])
        }
    }

    static let shared: QuinceCorpus = {
        do { return try QuinceCorpus() } catch { fatalError("quince corpus: \(error)") }
    }()

    func page(_ text: String, _ ranking: any SearchRanking, limit: Int = 100, candidateLimit: Int? = nil) throws -> SearchPage {
        let query = try parseSearchQuery(text)
        guard let candidateLimit else {
            return try store.search(query, accounts: nil, after: nil, limit: limit, ranking: ranking, now: searchTestNow)
        }
        return try store.read { db in
            try MailStore.searchPage(query, accounts: nil, after: nil, limit: limit, ranking: ranking, now: searchTestNow,
                                     candidateLimit: candidateLimit, in: db)
        }
    }

    static func threads(_ page: SearchPage) -> [String] { page.hits.map { $0.thread.ref.gmailThreadID.rawValue } }
}

@Suite struct SearchRankingReproTests {
    private let corpus = QuinceCorpus.shared

    @Test func senderMatchesComeFirstUnderBalancedAndNothingIsHidden() throws {
        let page = try corpus.page("quince developer", BlendedSearchRanking())
        let threads = QuinceCorpus.threads(page)
        #expect(Set(threads.prefix(6)) == Set(QuinceCorpus.senderThreads))
        #expect(threads.dropFirst(6).first == QuinceCorpus.subjectThread)
        #expect(threads.count == 6 + 1 + 30)
        #expect(page.ordering == .relevance)
        let top = try #require(page.hits.first?.scoreBreakdown)
        #expect(top.match == .senderName)
        #expect(top.match?.label == "sender name match")
    }

    @Test func classicShowsTheReportedProblem() throws {
        let threads = QuinceCorpus.threads(try corpus.page("quince developer", BM25RecencyRanking()))
        #expect(!QuinceCorpus.senderThreads.contains(try #require(threads.first)))
        #expect(Set(threads.prefix(6)) != Set(QuinceCorpus.senderThreads))
    }

    @Test func mostRecentIsByTheNewestMatchAndSaysSo() throws {
        let page = try corpus.page("quince developer", NewestFirstSearchRanking())
        let dates = page.hits.map(\.thread.sortAt)
        #expect(dates == dates.sorted(by: >))
        #expect(page.ordering == .date)
        #expect(page.hits.allSatisfy { $0.scoreBreakdown == nil })
        #expect(try corpus.page("from:rowan", BlendedSearchRanking()).ordering == .date)
    }

    @Test func oldSenderMatchesPastTheCandidateLimitAreStillRanked() throws {
        let balanced = try corpus.page("quince developer", BlendedSearchRanking(), candidateLimit: 5)
        #expect(Set(QuinceCorpus.threads(balanced).prefix(6)) == Set(QuinceCorpus.senderThreads))
        #expect(balanced.completeness.reasons.contains(.candidateLimitReached(limit: 5)))
        let classic = QuinceCorpus.threads(try corpus.page("quince developer", BM25RecencyRanking(), candidateLimit: 5))
        #expect(Set(classic).isDisjoint(with: QuinceCorpus.senderThreads))
    }

    @Test func contactsCountTheCorrespondent() throws {
        let page = try corpus.page("quince developer", BlendedSearchRanking())
        let meetup = try #require(page.hits.first { $0.thread.ref.gmailThreadID.rawValue == QuinceCorpus.subjectThread })
        #expect(meetup.scoreBreakdown?.part(.contacts)?.value ?? 0 > 0)
        #expect(meetup.scoreBreakdown?.match == .subjectPhrase)
    }
}
