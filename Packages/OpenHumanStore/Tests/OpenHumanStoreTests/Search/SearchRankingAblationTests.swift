import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENHUMAN_SEARCH_EVAL"] == "1"))
struct SearchRankingAblationTests {
    struct Judged {
        let kind: String
        let text: String
        let grades: [String: Int]
        let opened: [String: Double]
    }

    struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    static let syllables = ["ka", "lo", "mi", "ru", "ten", "vo", "sa", "ber", "quil", "dor", "fen", "gar", "hal", "jun",
                            "pex", "zor", "wim", "tal", "nex", "ori"]

    static func word(_ g: inout Generator) -> String {
        (0..<3).map { _ in syllables[g.next(syllables.count)] }.joined()
    }

    static func corpus() throws -> (MailStore, AccountID, [Judged]) {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        var g = Generator(state: 20_261_014)
        var messages: [MessageUpsert] = []
        var judged: [Judged] = []
        let day = 24 * 60
        func body(_ text: String) -> MessageBodyUpsert { .fixture(html: nil, text: text) }
        func filler(_ n: Int) -> String {
            (0..<n).map { _ in ["garden", "travel", "coffee", "tools", "report", "weekend", "music", "river"][g.next(8)] }
                .joined(separator: " ")
        }
        var serial = 0
        func add(_ thread: String, minutesAgo: Int, from: String, name: String, to: [String] = ["me@example.com"],
                 subject: String, text: String, labels: [String] = ["INBOX"]) {
            serial += 1
            messages.append(.fixture("m\(serial)", thread: thread, minutes: -minutesAgo, labels: labels, from: from,
                                     fromName: name, to: to, subject: subject, snippet: "s", body: body(text)))
        }
        func noise(_ words: [String], count: Int, tag: String, newest: Int = 1, spread: Int = 60) {
            for i in 0..<count {
                let mention = Array(repeating: words.joined(separator: " and more ") + ".", count: 2 + g.next(4))
                    .joined(separator: " ")
                add("\(tag)-noise\(i)", minutesAgo: (newest + g.next(spread)) * day, from: "news\(g.next(30))@list.example",
                    name: "Digest \(g.next(30))", subject: "Weekly digest \(i)", text: filler(80) + " " + mention + " " + filler(80))
            }
        }

        for n in 0..<8 {
            let brand = word(&g), role = word(&g)
            var gradesA: [String: Int] = [:]
            for k in 0..<4 {
                let t = "A\(n)-sender\(k)"
                add(t, minutesAgo: (200 + 90 * k + g.next(60)) * day, from: "\(role)@mail.\(brand).example",
                    name: "\(brand.capitalized) \(role.capitalized)", subject: "\(brand.capitalized) \(role.capitalized) account \(k)",
                    text: "Your account notice. " + filler(20))
                gradesA[t] = 2
            }
            noise([brand, role], count: 15, tag: "A\(n)")
            for i in 0..<5 {
                add("A\(n)-phrase\(i)", minutesAgo: (1 + g.next(20)) * day, from: "letters\(i)@press.example",
                    name: "Press \(i)", subject: "Industry news \(i)",
                    text: filler(60) + " Read more on the \(brand) \(role) site. " + filler(60))
            }
            judged.append(Judged(kind: "re-find a sender", text: "\(brand) \(role)", grades: gradesA, opened: [:]))

            let vendor = word(&g)
            var gradesB: [String: Int] = [:]
            for k in 0..<5 {
                let t = "B\(n)-invoice\(k)"
                add(t, minutesAgo: (3 + 30 * k) * day, from: "billing@\(vendor).example", name: "\(vendor.capitalized) Billing",
                    subject: "\(vendor.capitalized) invoice for month \(k)", text: "Invoice attached. Amount due. " + filler(15))
                gradesB[t] = k == 0 ? 2 : 1
            }
            noise([vendor, "invoice"], count: 10, tag: "B\(n)")
            judged.append(Judged(kind: "latest of a series", text: "\(vendor) invoice", grades: gradesB, opened: [:]))

            let place = word(&g), topic = word(&g)
            let c = "C\(n)-subject"
            add(c, minutesAgo: (250 + g.next(200)) * day, from: "colleague\(n)@work.example", name: "Colleague \(n)",
                subject: "\(place.capitalized) \(topic) review", text: "Notes attached. " + filler(25))
            for i in 0..<12 {
                add("C\(n)-apart\(i)", minutesAgo: (1 + g.next(40)) * day, from: "team\(g.next(9))@work.example",
                    name: "Team \(i)", subject: "Update \(i)",
                    text: filler(40) + " \(topic) " + filler(30) + " \(place) " + filler(40) + " \(topic) \(place)")
            }
            judged.append(Judged(kind: "old subject phrase", text: "\(place) \(topic)", grades: [c: 2], opened: [:]))

            let thing = word(&g)
            let friend = "friend\(n)@people.example"
            for k in 0..<6 {
                add("D\(n)-sent\(k)", minutesAgo: (40 + 10 * k) * day, from: "me@example.com", name: "Me", to: [friend],
                    subject: "Catching up \(k)", text: filler(10), labels: ["SENT"])
            }
            let d = "D\(n)-friend"
            add(d, minutesAgo: 20 * day, from: friend, name: "Friend \(n)", subject: "Saturday",
                text: "Bring the \(thing) on Saturday. " + filler(10))
            noise([thing], count: 10, tag: "D\(n)", newest: 1, spread: 15)
            judged.append(Judged(kind: "person you write to", text: thing, grades: [d: 2], opened: [:]))

            let fresh = word(&g)
            var gradesE: [String: Int] = [:]
            for k in 0..<6 {
                let t = "E\(n)-subject\(k)"
                add(t, minutesAgo: (1 + 25 * k) * day, from: "ops\(k)@service.example", name: "Ops \(k)",
                    subject: "\(fresh.capitalized) status \(k)", text: filler(20))
                gradesE[t] = k == 0 ? 2 : 0
            }
            noise([fresh], count: 6, tag: "E\(n)")
            judged.append(Judged(kind: "the newest of many", text: fresh, grades: gradesE, opened: [:]))

            let w1 = word(&g), w2 = word(&g), w3 = word(&g)
            let f = "F\(n)-together"
            add(f, minutesAgo: (180 + g.next(120)) * day, from: "partner\(n)@firm.example", name: "Partner \(n)",
                subject: "Follow-up", text: filler(30) + " the \(w1) \(w2) \(w3) plan " + filler(30))
            for i in 0..<10 {
                add("F\(n)-scattered\(i)", minutesAgo: (1 + g.next(30)) * day, from: "info\(i)@firm.example",
                    name: "Info \(i)", subject: "Notes \(i)",
                    text: "\(w3) " + filler(30) + " \(w1) " + filler(30) + " \(w2) " + filler(20))
            }
            judged.append(Judged(kind: "words together", text: "\(w1) \(w2) \(w3)", grades: [f: 2], opened: [:]))

            let item = word(&g)
            var gradesG: [String: Int] = [:]
            for k in 0..<8 {
                let t = "G\(n)-doc\(k)"
                add(t, minutesAgo: (5 + 12 * k) * day, from: "docs\(k)@share.example", name: "Docs \(k)",
                    subject: "Shared file \(k)", text: "The \(item) document is shared with you. " + filler(15))
                gradesG[t] = k == 5 ? 2 : 0
            }
            judged.append(Judged(kind: "opened before", text: item, grades: gradesG, opened: ["G\(n)-doc5": 3]))

            let topic2 = word(&g)
            let h = "H\(n)-recent"
            add(h, minutesAgo: 2 * day, from: "lead\(n)@team.example", name: "Lead \(n)", subject: "Today",
                text: "About the \(topic2) work. " + filler(30))
            var gradesH: [String: Int] = [h: 2]
            for k in 0..<4 {
                let t = "H\(n)-older\(k)"
                add(t, minutesAgo: (60 + 60 * k) * day, from: "lead\(n)@team.example", name: "Lead \(n)",
                    subject: "Earlier \(k)", text: "About the \(topic2) work and the \(topic2) plan. " + filler(30))
                gradesH[t] = 1
            }
            judged.append(Judged(kind: "comparable, recent wanted", text: topic2, grades: gradesH, opened: [:]))
        }
        for i in 0..<600 {
            add("filler\(i)", minutesAgo: (i % 700) * day, from: "person\(i % 40)@example.org", name: "Person \(i % 40)",
                subject: "Plans \(i)", text: filler(40))
        }
        for chunk in stride(from: 0, to: messages.count, by: 500) {
            _ = try store.upsertMessages(Array(messages[chunk..<min(chunk + 500, messages.count)]), account: account,
                                         generation: 1)
        }
        return (store, account, judged)
    }

    struct Metrics { var mrr = 0.0, ndcg = 0.0, count = 0 }

    static func score(_ ranked: [String], _ grades: [String: Int]) -> (mrr: Double, ndcg: Double) {
        let first = ranked.firstIndex { grades[$0] == 2 }
        let mrr = first.map { 1 / Double($0 + 1) } ?? 0
        func dcg(_ gains: [Int]) -> Double {
            gains.prefix(10).enumerated().reduce(0) { $0 + (pow(2, Double($1.element)) - 1) / log2(Double($1.offset + 2)) }
        }
        let ideal = dcg(grades.values.sorted(by: >))
        return (mrr, ideal > 0 ? dcg(ranked.map { grades[$0] ?? 0 }) / ideal : 0)
    }

    @Test func ablation() throws {
        let (store, account, judged) = try Self.corpus()
        func clicks(_ opened: [String: Double]) throws -> [ThreadRowID: SearchClickHistory] {
            var out: [ThreadRowID: SearchClickHistory] = [:]
            for (thread, opens) in opened {
                if let ref = try store.thread(account: account, gmailThreadID: GmailThreadID(thread)) {
                    out[ref.rowID] = SearchClickHistory(score: opens, at: searchTestNow)
                }
            }
            return out
        }
        let balanced = BlendedSearchRanking.Weights.balanced
        func variant(_ change: (inout BlendedSearchRanking.Weights) -> Void) -> BlendedSearchRanking.Weights {
            var w = balanced
            change(&w)
            return w
        }
        let variants: [(String, BlendedSearchRanking.Weights?)] = [
            ("Classic (0.65 bm25 / 0.35 recency, 90 d)", nil),
            ("Balanced (default)", balanced),
            ("Relevance", variant { $0.text = 0.6; $0.meaning = 0.15; $0.recency = 0.05; $0.clicks = 0.1; $0.contacts = 0.05
                $0.halfLifeDays = 365 }),
            ("Recent first", variant { $0.fields = 1; $0.text = 0.25; $0.recency = 1; $0.clicks = 0.1; $0.contacts = 0.05
                $0.halfLifeDays = 30 }),
            ("First draft (0.4 / 0.15 / 0.2 r / 0.15 / 0.05 c, 90 d)", variant { $0.text = 0.4; $0.meaning = 0.15
                $0.recency = 0.2; $0.contacts = 0.05; $0.halfLifeDays = 90 }),
            ("Balanced, no sender/subject", variant { $0.fields = 0 }),
            ("Balanced, no text", variant { $0.text = 0 }),
            ("Balanced, no recency", variant { $0.recency = 0 }),
            ("Balanced, no clicks", variant { $0.clicks = 0 }),
            ("Balanced, no contacts", variant { $0.contacts = 0 }),
            ("Balanced, recency 0.35 (Classic's weight)", variant { $0.recency = 0.35 }),
            ("Balanced, half-life 30 d", variant { $0.halfLifeDays = 30 }),
            ("Balanced, half-life 90 d", variant { $0.halfLifeDays = 90 }),
            ("Balanced, half-life 180 d", variant { $0.halfLifeDays = 180 }),
            ("Balanced, half-life 365 d", variant { $0.halfLifeDays = 365 }),
        ]
        var lines = ["| Ranker | MRR | NDCG@10 | " + Set(judged.map(\.kind)).sorted().joined(separator: " | ") + " |"]
        for (name, weights) in variants {
            var all = Metrics()
            var byKind: [String: Metrics] = [:]
            for item in judged {
                let ranking: any SearchRanking = weights.map { BlendedSearchRanking(weights: $0, clicks: (try? clicks(item.opened)) ?? [:]) }
                    ?? BM25RecencyRanking()
                let page = try store.search(try parseSearchQuery(item.text), accounts: [account], after: nil, limit: 50,
                                            ranking: ranking, now: searchTestNow)
                let s = Self.score(page.hits.map { $0.thread.ref.gmailThreadID.rawValue }, item.grades)
                all.mrr += s.mrr; all.ndcg += s.ndcg; all.count += 1
                byKind[item.kind, default: Metrics()].mrr += s.mrr
                byKind[item.kind, default: Metrics()].count += 1
            }
            let kinds = byKind.keys.sorted().map { String(format: "%.2f", byKind[$0]!.mrr / Double(byKind[$0]!.count)) }
            lines.append("| \(name) | " + String(format: "%.3f | %.3f", all.mrr / Double(all.count), all.ndcg / Double(all.count))
                         + " | " + kinds.joined(separator: " | ") + " |")
        }
        print("SEARCH-RANKING-ABLATION (\(judged.count) queries; per-kind columns are MRR)\n" + lines.joined(separator: "\n"))
    }

    @Test func classicDiagnostic() throws {
        let corpus = try QuinceCorpus()
        let query = try parseSearchQuery("quince developer")
        var rows: [String] = ["| Thread | bm25 | relevance (÷ best) | recency (90 d) | Classic score | header match |"]
        let page = try corpus.store.search(query, accounts: nil, after: nil, limit: 40, ranking: BlendedSearchRanking(),
                                           now: searchTestNow)
        let classic = try corpus.store.search(query, accounts: nil, after: nil, limit: 40, ranking: BM25RecencyRanking(),
                                              now: searchTestNow)
        try corpus.store.read { db in
            let rowsSQL = try Row.fetchAll(db, sql: """
                SELECT m.tid, m.internal_date, bm25(messages_fts, 5.0, 2.0, 1.0, 3.0) AS rank FROM messages_fts
                JOIN messages m ON m.mid = messages_fts.rowid WHERE messages_fts MATCH '"quince" AND "developer"'
                """)
            var best: [Int64: (rank: Double, at: Int64)] = [:]
            for row in rowsSQL {
                let tid: Int64 = row["tid"], rank: Double = row["rank"], at: Int64 = row["internal_date"]
                let known = best[tid]
                best[tid] = (min(rank, known?.rank ?? .infinity), max(at, known?.at ?? 0))
            }
            let top = best.values.map { -$0.rank }.max() ?? 1
            for hit in classic.hits.prefix(10) {
                guard let b = best[hit.thread.id.rawValue] else { continue }
                let age = searchTestNow.timeIntervalSince1970 - Double(b.at) / 1000
                let recency = pow(0.5, age / 86_400 / 90)
                let relevance = -b.rank / top
                let header = page.hits.first { $0.thread.id == hit.thread.id }?.scoreBreakdown?.match?.label ?? "-"
                rows.append(String(format: "| %@ | %.3f | %.2f | %.2f | %.3f | %@ |", hit.thread.ref.gmailThreadID.rawValue,
                                   b.rank, relevance, recency, 0.65 * relevance + 0.35 * recency, header))
            }
        }
        print("SEARCH-RANKING-CLASSIC-DIAGNOSTIC\n" + rows.joined(separator: "\n"))
    }
}
