import Foundation
import OpenHumanCore
import OpenHumanLinks
import Testing
@testable import MailFeatures

private func item(_ id: String, area: String = "Inbox", link: Any? = nil, extra: [String: Any] = [:]) -> [String: Any] {
    var fields: [String: Any] = ["id": id, "area": area, "title": "Title \(id)", "steps": ["Press j"],
                                 "expected": "It moves.", "requires": "fake", "addedIn": "2026-10-10"]
    if let link { fields["deepLink"] = link }
    for (key, value) in extra { fields[key] = value }
    return fields
}

private func json(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

private func decode(_ object: Any) throws -> (items: [DevChecklistItem], issues: [String]) {
    try DevChecklistLoader.decode(try json(object)).get()
}

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("oh-devfeedback-tests-\(UUID().uuidString)", isDirectory: true)
}

@Suite struct DevChecklistDecodingTests {
    @Test func decodesAWellFormedFile() throws {
        let result = try decode(["format": "openhuman-dev-checklist", "formatVersion": 1,
                                 "items": [item("a.one"), item("b.two", area: "Reader", link: "openhuman://thread/robin@example.com/fake-t3")]])
        #expect(result.issues.isEmpty)
        #expect(result.items.map(\.id) == ["a.one", "b.two"])
        #expect(result.items[1].deepLink == "openhuman://thread/robin@example.com/fake-t3")
        #expect(result.items[0].requires == .fake)
    }

    @Test func requiresIsFakeOrRealAndNothingElse() throws {
        var real = item("r.one"); real["requires"] = "real"
        let result = try decode([real, item("f.one")])
        #expect(result.issues.isEmpty && result.items.map(\.requires) == [.real, .fake])
        #expect(DevChecklistItem.Requirement.allCases == [.fake, .real])
        for value in ["real-readonly", "real-write", "live", "Real"] {
            var entry = item("o.one"); entry["requires"] = value
            let refused = try decode([entry])
            #expect(refused.items.isEmpty, "\(value)")
            #expect(refused.issues.count == 1 && refused.issues[0].contains("requires must be \"fake\" or \"real\""), "\(value)")
        }
    }

    @Test func acceptsABareArrayAndIgnoresUnknownKeys() throws {
        let result = try decode([item("x", extra: ["futureKey": ["nested": true], "priority": 3])])
        #expect(result.items.count == 1)
        #expect(result.issues.isEmpty)
    }

    @Test func skipsBadItemsWithAReason() throws {
        var missingTitle = item("no-title"); missingTitle["title"] = nil
        var badRequires = item("bad-req"); badRequires["requires"] = "real-everything"
        var noSteps = item("no-steps"); noSteps["steps"] = []
        var stepNotText = item("step-num"); stepNotText["steps"] = ["ok", 42]
        let result = try decode(["items": [item("good"), "not an object", item("bad id!"), missingTitle, badRequires,
                                           noSteps, stepNotText, item("good")]])
        #expect(result.items.map(\.id) == ["good"])
        #expect(result.issues.count == 7)
        #expect(result.issues.contains { $0.contains("duplicate id") })
    }

    @Test(arguments: ["https://evil.example/x", "javascript:alert(1)", "openhuman://unknown/x", "openhuman://thread/a",
                      "file:///etc/passwd", "openhuman://thread/me@example.com/bad id"])
    func dropsLinksThatAreNotValidOpenHumanLinks(_ link: String) throws {
        let result = try decode([item("x", link: link)])
        #expect(result.items.count == 1)
        #expect(result.items[0].deepLink == nil)
        #expect(result.issues.contains { $0.contains("deep link dropped") })
    }

    @Test func nullDeepLinkIsFine() throws {
        let result = try decode([item("x", link: NSNull())])
        #expect(result.items[0].deepLink == nil)
        #expect(result.issues.isEmpty)
    }

    @Test func cleansControlAndBidiCharactersAndCapsLengths() throws {
        let hostile = "Safe\u{202E}txt.exe\u{0000}\u{0007}\nnext\u{200B}line"
        let result = try decode([item("x", extra: ["title": hostile, "expected": String(repeating: "x", count: 5_000),
                                                   "area": "  Spaces   everywhere  "])])
        let parsed = try #require(result.items.first)
        #expect(parsed.title == "Safetxt.exe nextline")
        #expect(parsed.expected.count == DevChecklistLoader.maxExpected)
        #expect(parsed.area == "Spaces everywhere")
    }

    @Test func markdownAndScriptTextStayPlainText() throws {
        let title = "**bold** [click](https://evil.example) <script>alert(1)</script> $(rm -rf ~)"
        let result = try decode([item("x", extra: ["title": title])])
        #expect(result.items.first?.title == title)
    }

    @Test func capsArePinned() {
        #expect(DevChecklistLoader.maxFileBytes == 524_288)
        #expect(DevChecklistLoader.maxItems == 700)
    }

    @Test func refusesHostileFiles() {
        let deep = Data((String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)).utf8)
        #expect(throws: DevChecklistLoader.Problem.self) { try DevChecklistLoader.decode(deep).get() }
        let big = Data(repeating: UInt8(ascii: " "), count: DevChecklistLoader.maxFileBytes + 1)
        #expect(throws: DevChecklistLoader.Problem.self) { try DevChecklistLoader.decode(big).get() }
        #expect(throws: DevChecklistLoader.Problem.self) { try DevChecklistLoader.decode(Data("{not json".utf8)).get() }
        #expect(throws: DevChecklistLoader.Problem.self) { try DevChecklistLoader.decode(Data("\"just a string\"".utf8)).get() }
        #expect(throws: DevChecklistLoader.Problem.self) {
            try DevChecklistLoader.decode(try json(["format": "something-else", "items": []])).get()
        }
        #expect(throws: DevChecklistLoader.Problem.self) { try DevChecklistLoader.decode(try json(["items": "nope"])).get() }
    }

    @Test func bracketsInsideStringsDoNotCountAsNesting() throws {
        let result = try decode([item("x", extra: ["title": String(repeating: "[{", count: 50)])])
        #expect(result.items.count == 1)
    }

    @Test func capsTheNumberOfItems() throws {
        let many = (0..<(DevChecklistLoader.maxItems + 5)).map { item("i\($0)") }
        let result = try decode(many)
        #expect(result.items.count == DevChecklistLoader.maxItems)
        #expect(result.issues.contains { $0.contains("first \(DevChecklistLoader.maxItems)") })
    }

    @Test func overrideReplacesTheBundledFileAndABrokenOverrideFallsBack() throws {
        let dir = tempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundled = dir.appendingPathComponent("bundled.json")
        let override = dir.appendingPathComponent("override.json")
        try json([item("bundled.item")]).write(to: bundled)

        #expect(DevChecklistLoader.load(bundled: bundled, override: override).source == .bundled)
        try json([item("override.item")]).write(to: override)
        let replaced = DevChecklistLoader.load(bundled: bundled, override: override)
        #expect(replaced.source == .override)
        #expect(replaced.items.map(\.id) == ["override.item"])

        try Data("[[[[[[[[[[[[".utf8).write(to: override)
        let fallback = DevChecklistLoader.load(bundled: bundled, override: override)
        #expect(fallback.source == .bundled)
        #expect(fallback.items.map(\.id) == ["bundled.item"])
        #expect(fallback.issues.first?.hasPrefix("Override checklist ignored") == true)

        #expect(DevChecklistLoader.load(bundled: nil, override: nil).items.isEmpty)
    }
}

@MainActor
@Suite struct DevChecklistModelTests {
    let temp = TemporaryDirectory("oh-devfeedback-tests", isDirectory: true)
    var dir: URL { temp.url }
    let checklist: DevChecklist

    init() throws {
        let decoded = try decode([item("a", area: "Inbox"), item("b", area: "Reader"), item("c", area: "Inbox"),
                                  item("d", area: "Reader", link: "openhuman://thread/robin@example.com/fake-t3")])
        checklist = DevChecklist(items: decoded.items, source: .bundled)
    }

    func makeModel(now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_791_000_000) }) -> DevChecklistModel {
        DevChecklistModel(checklist: checklist, store: DevChecklistAnswerStore(url: dir.appendingPathComponent("answers.json")), now: now)
    }

    @Test func groupsByAreaInFileOrder() {
        let model = makeModel()
        #expect(model.sections.map(\.area) == ["Inbox", "Reader"])
        #expect(model.sections[0].items.map(\.id) == ["a", "c"])
    }

    @Test func answersPersistWithTimestampsAndReload() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let t0 = Date(timeIntervalSince1970: 1_791_000_000)
        let model = makeModel(now: { t0 })
        model.record(.worked, for: "a")
        model.record(.didNotWork, for: "b")
        model.setNote("Cursor jumped twice", for: "b")
        model.record(.skipped, for: "unknown-id")

        let reloaded = makeModel()
        #expect(reloaded.answer(for: "a")?.result == .worked)
        #expect(reloaded.answer(for: "b")?.result == .didNotWork)
        #expect(reloaded.answer(for: "b")?.note == "Cursor jumped twice")
        #expect(reloaded.answer(for: "a")?.answeredAt == t0)
        #expect(reloaded.answer(for: "unknown-id") == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("answers.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func notYetTestedFilterHidesAnsweredItemsAndEmptyAreas() {
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel()
        model.record(.worked, for: "b")
        model.record(.skipped, for: "d")
        model.setNote("only a note", for: "a")
        model.showOnlyUntested = true
        #expect(model.sections.map(\.area) == ["Inbox"])
        #expect(model.sections[0].items.map(\.id) == ["a", "c"])
        #expect(model.testedCount == 2)
        model.record(nil, for: "b")
        #expect(model.sections.map(\.area) == ["Inbox", "Reader"])
        #expect(model.sections.flatMap(\.items).map(\.id) == ["a", "c", "b"])
        #expect(model.testedCount == 1)
    }

    @Test func exportTracksWhatAnEarlierBundleCarried() {
        defer { try? FileManager.default.removeItem(at: dir) }
        var now = Date(timeIntervalSince1970: 1_791_000_000)
        let model = makeModel(now: { now })
        model.record(.worked, for: "c")
        model.record(.didNotWork, for: "a")
        #expect(model.answersToExport().map(\.itemID) == ["a", "c"])
        now += 10
        model.markExported(["a", "c"], at: now)
        #expect(model.answersToExport().isEmpty)
        now += 10
        model.setNote("more detail", for: "a")
        #expect(model.answersToExport().map(\.itemID) == ["a"])
        #expect(makeModel().answersToExport().map(\.itemID) == ["a"])
    }

    @Test func openFollowsTheDeepLinkThroughTheHandlerOrShowsTheKeys() {
        let model = makeModel()
        var followed: [MailLink] = []
        model.linkHandler = { link in
            followed.append(link)
            return "Opened"
        }
        let withLink = model.open(checklist.items[3])
        #expect(followed == [.thread(account: AccountRef("robin@example.com"), threadID: "fake-t3")])
        #expect(withLink == .followed(followed[0], message: "Opened"))
        #expect(model.viewingItemID == "d")
        #expect(model.open(checklist.items[0]) == .showKeys(["Press j"]))
        #expect(model.openOutcomes["a"] == .showKeys(["Press j"]))
    }

    @Test func aBrokenAnswersFileIsAnEmptySet() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{\"format\":\"openhuman-dev-checklist-answers\",\"answers\":[[[".utf8)
            .write(to: dir.appendingPathComponent("answers.json"))
        #expect(makeModel().answers.isEmpty)
    }
}
