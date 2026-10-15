import Foundation
import MailFeatures
import MailModel
import OpenHumanCore
import OpenHumanStore
import Testing
@testable import OpenHumanMail

@Test(arguments: SplitPresets.all) func everyPresetParsesAndIsCanonical(preset: SplitPreset) throws {
    if preset.needsDomain {
        let done = preset.ruleText + "tool.example"
        #expect(try SplitRule.parse(done).canonicalText == done)
        return
    }
    let rule = try SplitRule.parse(preset.ruleText)
    #expect(rule.canonicalText == preset.ruleText, "stored in the Store's canonical form")
    #expect(try SplitRule.parse(rule.canonicalText) == rule)
}

@Test(.timeLimit(.minutes(2))) func presetsPlaceTheirThreadsAndNothingElse() throws {
    let store = try MailStore.openInMemoryForTesting()
    let account = try store.addAccount(email: "presets@example.com", displayName: nil, scopes: ["gmail.modify"])
    for split in try store.splits(account: account) where split.name == "Calendar" { try store.deleteSplit(split.id) }
    try store.upsertLabels(FixtureStoreSeeder.systemLabels, account: account, removeMissing: false)
    let rows: [(String, String, [String], Bool, String?)] = [
        ("invite", "Pat <pat@example.net>", [], true, nil),
        ("lookalike", "Spoof <x@nottool.example>", [], false, nil),
        ("tool", "Tool <no-reply@mail.tool.example>", [], false, nil),
        ("promo", "Shop <deals@shop.example>", ["CATEGORY_PROMOTIONS"], false, nil),
        ("list", "Weekly <hello@weekly.example>", [], false, "<weekly.weekly.example>"),
        ("plain", "Sam <sam@example.org>", [], false, nil),
    ]
    var upserts: [MessageUpsert] = []
    for (index, row) in rows.enumerated() {
        let (name, from, extra, invite, listID) = row
        let address = from.split(separator: "<").last.map { String($0.dropLast()) } ?? from
        let display = from.split(separator: "<").first.map { $0.trimmingCharacters(in: .whitespaces) }
        upserts.append(MessageUpsert(
            gmailMessageID: GmailMessageID("pm-\(name)"), gmailThreadID: GmailThreadID("pt-\(name)"),
            historyID: HistoryID(UInt64(100 + index)), internalDate: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)),
            labelIDs: (["INBOX"] + extra).map { GmailLabelID($0) }, snippet: name, sizeEstimate: 500,
            headers: MessageHeaderFields(subject: "Synthetic \(name)", from: EmailAddress(name: display, email: address),
                                         to: [EmailAddress(email: "presets@example.com")], cc: [], bcc: [], replyTo: [],
                                         date: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)),
                                         messageID: "<pm-\(name)@test.example>", references: [], listID: listID),
            body: MessageBodyUpsert(text: "x", hasCalendarInvite: invite, decodeWarnings: [], searchText: "x")))
    }
    _ = try store.upsertMessages(upserts, account: account, generation: 1)

    let expected: [String: Int] = ["events": 1, "newsletters": 2, "tool": 1, "github": 0, "linear": 0, "slack": 0]
    var ids: [String: SplitID] = [:]
    for preset in SplitPresets.all where !preset.needsDomain {
        ids[preset.id] = try store.upsertSplit(account: account, id: nil, name: preset.name, ruleText: preset.ruleText,
                                               position: nil, enabled: true)
    }
    let template = try #require(SplitPresets.all.first { $0.id == "asana" })
    ids["tool"] = try store.upsertSplit(account: account, id: nil, name: template.name,
                                        ruleText: template.ruleText + "tool.example", position: nil, enabled: true)
    let items = try store.splits(account: account)
    for (key, count) in expected {
        let item = try #require(items.first { $0.id == ids[key] })
        #expect(item.totalThreads == count, "\(key): placed \(item.totalThreads), a look-alike and a plain sender stay out")
    }
}
