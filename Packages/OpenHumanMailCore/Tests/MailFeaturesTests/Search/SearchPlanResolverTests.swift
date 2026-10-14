import Foundation
import MailModel
import OpenHumanAI
import OpenHumanCore
import Testing
@testable import MailFeatures

private let account = AccountID(1)

private func calendar(_ zone: String, firstWeekday: Int = 1) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    calendar.firstWeekday = firstWeekday
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

private func resolver(_ zone: String, firstWeekday: Int = 1) -> SearchPlanResolver {
    SearchPlanResolver(calendar: calendar(zone, firstWeekday: firstWeekday), locale: Locale(identifier: "en_US_POSIX"))
}

private func sunday(_ zone: String) -> Date {
    calendar(zone).date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 10))!
}

private let people: [String: [EmailAddress]] = [
    "Sarah": [EmailAddress(name: "Sarah Chen", email: "sarah.chen@example.com")],
    "Sarah Chen": [EmailAddress(name: "Sarah Chen", email: "sarah.chen@example.com")],
    "Sam": [EmailAddress(name: "Sam Lee", email: "sam.lee@example.com"),
            EmailAddress(name: "Sam Ortiz", email: "sam.ortiz@example.net"),
            EmailAddress(name: "Samira Diaz", email: "samira@example.org")],
    "sarah": [EmailAddress(name: "S. Chen", email: "sarah.chen@example.com")],
]

private func contacts(_ prefix: String) async -> [EmailAddress] { people[prefix] ?? [] }

private let labels = [
    LabelInfo(id: 1, account: account, labelID: GmailLabelID("Label_1"), kind: .user, name: "Receipts", displayName: "Receipts",
              position: 0),
    LabelInfo(id: 2, account: account, labelID: GmailLabelID("Label_2"), kind: .user, name: "Projects/Atlas",
              displayName: "Atlas", position: 1),
    LabelInfo(id: 3, account: account, labelID: GmailLabelID("INBOX"), kind: .system, name: "INBOX", displayName: "Inbox",
              position: 2),
]

private func resolve(_ plan: SearchPlan, zone: String = "America/Los_Angeles", firstWeekday: Int = 1) async
    -> ResolvedSearchPlan?
{
    await resolver(zone, firstWeekday: firstWeekday).resolve(plan, account: account, today: sunday(zone),
                                                            contacts: contacts, labels: labels)
}

@Suite struct SearchPlanResolverTests {
    @Test func theSpecExampleResolvesToOperatorsAndChips() async throws {
        let plan = SearchPlan(keywords: ["invoice"], from: ["Sarah"], timeframe: .lastMonth, topic: "invoices from Sarah")
        let resolved = try #require(await resolve(plan))
        #expect(resolved.canonicalText == "invoice from:sarah.chen@example.com after:2026/09/01 before:2026/10/01")
        #expect(resolved.chips.map(\.title) == ["invoice", "from Sarah Chen", "Sep 1 to Sep 30"])
        #expect(resolved.chips.map(\.kind) == [.topic, .person, .dates])
        #expect(resolved.semanticText == "invoices from Sarah")
        #expect(resolved.spokenSummary
                == "Suggested search: invoice, from Sarah Chen, September 1 to September 30. Press Tab to use.")
    }

    static let table: [(SearchPlan, sundayFirst: String, mondayFirst: String)] = [
        (SearchPlan(timeframe: .today), "after:2026/10/11", "after:2026/10/11"),
        (SearchPlan(timeframe: .yesterday), "after:2026/10/10 before:2026/10/11", "after:2026/10/10 before:2026/10/11"),
        (SearchPlan(timeframe: .thisWeek), "after:2026/10/11", "after:2026/10/05"),
        (SearchPlan(timeframe: .lastWeek), "after:2026/10/04 before:2026/10/11", "after:2026/09/28 before:2026/10/05"),
        (SearchPlan(timeframe: .thisMonth), "after:2026/10/01", "after:2026/10/01"),
        (SearchPlan(timeframe: .lastMonth), "after:2026/09/01 before:2026/10/01", "after:2026/09/01 before:2026/10/01"),
        (SearchPlan(timeframe: .thisYear), "after:2026/01/01", "after:2026/01/01"),
        (SearchPlan(timeframe: .lastYear), "after:2025/01/01 before:2026/01/01", "after:2025/01/01 before:2026/01/01"),
        (SearchPlan(timeframe: .pastDays, count: 7), "after:2026/10/04", "after:2026/10/04"),
        (SearchPlan(timeframe: .pastWeeks, count: 2), "after:2026/09/27", "after:2026/09/27"),
        (SearchPlan(timeframe: .pastMonths, count: 3), "after:2026/07/11", "after:2026/07/11"),
        (SearchPlan(timeframe: .pastYears, count: 1), "after:2025/10/11", "after:2025/10/11"),
        (SearchPlan(timeframe: .month, month: 3), "after:2026/03/01 before:2026/04/01", "after:2026/03/01 before:2026/04/01"),
        (SearchPlan(timeframe: .month, month: 11), "after:2025/11/01 before:2025/12/01", "after:2025/11/01 before:2025/12/01"),
        (SearchPlan(timeframe: .month, month: 10), "after:2026/10/01 before:2026/11/01", "after:2026/10/01 before:2026/11/01"),
        (SearchPlan(timeframe: .month, month: 2, year: 2024), "after:2024/02/01 before:2024/03/01",
         "after:2024/02/01 before:2024/03/01"),
        (SearchPlan(timeframe: .year, year: 2025), "after:2025/01/01 before:2026/01/01", "after:2025/01/01 before:2026/01/01"),
        (SearchPlan(timeframe: .sinceMonth, month: 6), "after:2026/06/01", "after:2026/06/01"),
        (SearchPlan(timeframe: .beforeMonth, month: 6), "before:2026/06/01", "before:2026/06/01"),
    ]

    @Test(arguments: ["America/Los_Angeles", "Asia/Tokyo"])
    func everyTimeframeInBothWeekStarts(_ zone: String) async throws {
        for (plan, sundayFirst, mondayFirst) in Self.table {
            #expect(await resolve(plan, zone: zone, firstWeekday: 1)?.canonicalText == sundayFirst, "\(plan.timeframe) Sunday")
            #expect(await resolve(plan, zone: zone, firstWeekday: 2)?.canonicalText == mondayFirst, "\(plan.timeframe) Monday")
        }
    }

    @Test func dateChipsShowTheInclusiveRange() async throws {
        func chip(_ plan: SearchPlan) async -> String? { await resolve(plan)?.chips.first { $0.kind == .dates }?.title }
        #expect(await chip(SearchPlan(timeframe: .lastMonth)) == "Sep 1 to Sep 30")
        #expect(await chip(SearchPlan(timeframe: .today)) == "Today")
        #expect(await chip(SearchPlan(timeframe: .yesterday)) == "Oct 10")
        #expect(await chip(SearchPlan(timeframe: .thisMonth)) == "Since Oct 1")
        #expect(await chip(SearchPlan(timeframe: .beforeMonth, month: 6)) == "Before Jun 1")
        let lastYear = try #require(await chip(SearchPlan(timeframe: .month, month: 11)))
        #expect(lastYear.contains("2025"), "a range outside this year names its year")
    }

    @Test func peopleResolveToOneAddressSeveralOrNone() async throws {
        #expect(try #require(await resolve(SearchPlan(from: ["Sarah"]))).canonicalText == "from:sarah.chen@example.com")
        #expect(try #require(await resolve(SearchPlan(from: ["Sarah Chen"]))).canonicalText == "from:sarah.chen@example.com")
        let many = try #require(await resolve(SearchPlan(from: ["Sam"])))
        #expect(many.canonicalText == "from:Sam")
        #expect(many.chips.first?.title == "from Sam (3 people)")
        let none = try #require(await resolve(SearchPlan(to: ["Zed"])))
        #expect(none.canonicalText == "to:Zed")
        #expect(none.chips.first?.title == "to Zed")
        #expect(try #require(await resolve(SearchPlan(to: ["Ana Lopez"]))).canonicalText == #"to:"Ana Lopez""#)
        #expect(try #require(await resolve(SearchPlan(from: ["Billing@Example.com"]))).canonicalText == "from:billing@example.com")
        #expect(try #require(await resolve(SearchPlan(from: ["sarah"]))).canonicalText == "from:sarah")
    }

    @Test func labelsMatchExactlyThenByPrefixAndAMissingOneBecomesANote() async throws {
        let exact = try #require(await resolve(SearchPlan(keywords: ["paid"], label: "receipts")))
        #expect(exact.canonicalText == #"paid label:"Receipts""#)
        let prefix = try #require(await resolve(SearchPlan(label: "Atl")))
        #expect(prefix.canonicalText == #"label:"Projects/Atlas""#)
        #expect(prefix.chips.first?.title == "Atlas")
        let missing = try #require(await resolve(SearchPlan(keywords: ["taxes"], label: "Taxes")))
        #expect(missing.canonicalText == "taxes")
        #expect(missing.chips.last == .init(kind: .note, title: "No label named Taxes"))
        let system = try #require(await resolve(SearchPlan(keywords: ["x"], label: "INBOX")))
        #expect(!system.canonicalText.contains("label:"), "only user labels are matched")
        #expect(await resolve(SearchPlan(label: "Taxes")) == nil, "a plan left with nothing to search shows no row")
    }

    @Test func attachmentTypesFlagsAndMailboxes() async throws {
        let expected: [(SearchPlan.AttachmentType, String)] = [
            (.any, "has:attachment"), (.pdf, "has:attachment filename:pdf"),
            (.document, "has:attachment {filename:doc filename:docx}"),
            (.spreadsheet, "has:attachment {filename:xls filename:xlsx filename:csv}"),
            (.presentation, "has:attachment {filename:ppt filename:pptx filename:key}"),
            (.image, "has:attachment {filename:png filename:jpg filename:jpeg filename:heic}"), (.calendar, "has:invite"),
        ]
        for (type, text) in expected {
            #expect(await resolve(SearchPlan(attachment: type))?.canonicalText == text, "\(type)")
        }
        let flags = try #require(await resolve(SearchPlan(unread: true, starred: false, mailbox: .sent)))
        #expect(flags.canonicalText == "is:unread in:sent", "false flags are dropped: the model never produces -is:")
        #expect(await resolve(SearchPlan(mailbox: .anywhere))?.canonicalText == "in:anywhere")
        #expect(await resolve(SearchPlan(keywords: ["standing desk"]))?.canonicalText == #""standing desk""#)
        #expect(await resolve(SearchPlan()) == nil)
    }

    @Test func aTextTheValidatorRefusesShowsNoRow() async {
        let refusing = SearchPlanResolver(calendar: calendar("UTC"), locale: Locale(identifier: "en_US_POSIX"),
                                          isValidQuery: { _ in false })
        let resolved = await refusing.resolve(SearchPlan(keywords: ["invoice"]), account: account, today: sunday("UTC"),
                                              contacts: contacts, labels: labels)
        #expect(resolved == nil)
    }

    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test func everyResolvedTextPassesTheSyntaxCheck() async {
        var rng = Seeded(state: 20_261_011)
        let words = ["invoice", "standing desk", "q4: budget", "offsite", "re\"view", "a(b)", "naïve café", "x{y}"]
        let names = ["Sarah", "Sam", "Zed", "Ana Lopez", "billing@example.com", "sarah"]
        let labelNames = ["Receipts", "Atl", "Taxes", "INBOX"]
        for _ in 0..<300 {
            var plan = SearchPlan()
            plan.keywords = (0..<Int.random(in: 0...3, using: &rng)).map { _ in words.randomElement(using: &rng)! }
            plan.from = (0..<Int.random(in: 0...2, using: &rng)).map { _ in names.randomElement(using: &rng)! }
            plan.to = (0..<Int.random(in: 0...1, using: &rng)).map { _ in names.randomElement(using: &rng)! }
            plan.timeframe = SearchPlan.Timeframe.allCases.randomElement(using: &rng)!
            plan.count = plan.timeframe.needsCount ? Int.random(in: 1...36, using: &rng) : nil
            if [SearchPlan.Timeframe.month, .sinceMonth, .beforeMonth].contains(plan.timeframe) {
                plan.month = Int.random(in: 1...12, using: &rng)
            }
            if plan.timeframe == .year || Bool.random(using: &rng) && plan.month != nil {
                plan.year = Int.random(in: 2000...2100, using: &rng)
            }
            plan.attachment = Bool.random(using: &rng) ? SearchPlan.AttachmentType.allCases.randomElement(using: &rng) : nil
            plan.unread = Bool.random(using: &rng)
            plan.starred = Bool.random(using: &rng) ? true : nil
            plan.mailbox = SearchPlan.Mailbox.allCases.randomElement(using: &rng)!
            plan.label = Bool.random(using: &rng) ? labelNames.randomElement(using: &rng) : nil
            let zone = Bool.random(using: &rng) ? "Asia/Tokyo" : "America/Los_Angeles"
            guard let resolved = await resolve(plan, zone: zone, firstWeekday: Int.random(in: 1...2, using: &rng)) else {
                continue
            }
            #expect(SearchPlanResolver.syntaxIsValid(resolved.canonicalText), "\(resolved.canonicalText)")
            #expect(!resolved.canonicalText.contains("\n"))
            #expect(SearchSyntax.tokens(resolved.canonicalText).allSatisfy { $0.isValid })
        }
    }
}
