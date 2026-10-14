import Foundation
import Testing
@testable import MailTheme

struct CorpusCase: CustomTestStringConvertible, Sendable {
    let name: String
    let data: Data
    let refused: Bool
    let code: ThemeIssue.Code

    var testDescription: String { name }

    init(_ name: String, _ data: Data, refused: Bool, _ code: ThemeIssue.Code) {
        self.name = name
        self.data = data
        self.refused = refused
        self.code = code
    }

    init(_ name: String, _ object: [String: Any], refused: Bool, _ code: ThemeIssue.Code) {
        self.init(name, themeJSON(object), refused: refused, code)
    }

    init(_ name: String, text: String, refused: Bool, _ code: ThemeIssue.Code) {
        self.init(name, Data(text.utf8), refused: refused, code)
    }
}

private func semantic(_ name: String, _ value: Any) -> [String: Any] {
    userTheme(extra: ["semantic": ["color": [name: value]]])
}

private func nested(depth: Int) -> String {
    String(repeating: "{\"a\":", count: depth) + "1" + String(repeating: "}", count: depth)
}

let corpus: [CorpusCase] = {
    var cases: [CorpusCase] = []
    let big = userTheme(extra: ["padding": Array(repeating: 123_456_789, count: 7_000)])
    cases.append(CorpusCase("huge file (> 64 KB)", big, refused: true, .tooLarge))
    cases.append(CorpusCase("comments", text: "{ // theme\n \"format\": \"openhuman-theme\" }", refused: true, .invalidJSON))
    cases.append(CorpusCase("trailing comma", text: "{\"format\": \"openhuman-theme\", }", refused: true, .invalidJSON))
    cases.append(CorpusCase("not UTF-8", Data([0x7B, 0xFF, 0xFE, 0x7D]), refused: true, .invalidJSON))
    cases.append(CorpusCase("empty file", Data(), refused: true, .invalidJSON))
    cases.append(CorpusCase("top-level array", text: "[1, 2, 3]", refused: true, .notAnObject))
    cases.append(CorpusCase("top-level null", text: "null", refused: true, .invalidJSON))
    cases.append(CorpusCase("deep nesting (20)", text: nested(depth: 20), refused: true, .tooDeep))
    cases.append(CorpusCase("deep nesting (3,000)", text: nested(depth: 3_000), refused: true, .tooDeep))
    var manyKeys: [String: Any] = [:]
    for i in 0..<2_100 { manyKeys["k\(i)"] = 1 }
    cases.append(CorpusCase("too many keys", userTheme(extra: ["extra": manyKeys]), refused: true, .tooManyKeys))
    cases.append(CorpusCase("string too long", userTheme(name: String(repeating: "x", count: 201)), refused: true, .stringTooLong))
    cases.append(CorpusCase("unknown format", ["format": "openhuman-plugin", "formatVersion": 1, "id": "me.x"], refused: true, .unknownFormat))
    cases.append(CorpusCase("newer format version", userTheme().merging(["formatVersion": 2]) { _, n in n }, refused: true, .unsupportedVersion))
    cases.append(CorpusCase("version as string", userTheme().merging(["formatVersion": "1"]) { _, n in n }, refused: true, .missingField))
    cases.append(CorpusCase("reserved id", userTheme(id: "openhuman.light"), refused: true, .reservedID))
    cases.append(CorpusCase("confusable id (Cyrillic o)", userTheme(id: "me.s\u{043E}lar"), refused: true, .invalidID))
    cases.append(CorpusCase("id with uppercase", userTheme(id: "Me.Solar"), refused: true, .invalidID))
    cases.append(CorpusCase("id with five parts", userTheme(id: "a.b.c.d.e"), refused: true, .invalidID))
    cases.append(CorpusCase("CSS breakout in a color", semantic("bg.window", "#fff; } body { background: red }"), refused: true, .injection))
    cases.append(CorpusCase("url( in a color", semantic("bg.window", "url(https://tracker.example/p.png)"), refused: true, .injection))
    cases.append(CorpusCase("var( in a color", semantic("text.primary", "var(--evil)"), refused: true, .injection))
    cases.append(CorpusCase("expression( in a color", semantic("text.primary", "expression(alert(1))"), refused: true, .injection))
    cases.append(CorpusCase("markup in a shadow", semantic("shadow.1", "0 1 2 0 </style><script>x()</script>"), refused: true, .injection))
    cases.append(CorpusCase("data: URL in a color", semantic("bg.window", "data:image/png;base64,AAAA"), refused: true, .injection))
    cases.append(CorpusCase("injection in a primitive", userTheme(extra: ["primitives": ["color": ["evil.1": "#fff;}"]]]), refused: true, .injection))
    cases.append(CorpusCase("injection in an easing", userTheme(extra: ["motion": ["reveal": ["duration": 80, "easing": "cubic-bezier(0,0,1,1); x"]]]), refused: true, .injection))
    cases.append(CorpusCase("injection in a font name", userTheme(extra: ["typography": ["family": ["ui": "Inter\"; color: red"]]]), refused: true, .injection))
    cases.append(CorpusCase("escape sequence in a color", semantic("bg.window", "\\23 fff"), refused: true, .injection))
    cases.append(CorpusCase("injection in an accent file", ["format": "openhuman-accent", "formatVersion": 1, "id": "me.accent.bad",
                                                            "name": "Bad", "light": ["accent.ring": "url(x)"]], refused: true, .injection))
    cases.append(CorpusCase("self-reference", semantic("text.primary", "{text.primary}"), refused: true, .referenceCycle))
    cases.append(CorpusCase("number where a color goes", semantic("bg.window", 16_777_215), refused: false, .wrongType))
    cases.append(CorpusCase("boolean where a number goes", userTheme(extra: ["space": ["1": true]]), refused: false, .wrongType))
    cases.append(CorpusCase("string where a number goes", userTheme(extra: ["radius": ["md": "6"]]), refused: false, .wrongType))
    cases.append(CorpusCase("CSS color keyword", semantic("bg.window", "red"), refused: false, .invalidValue))
    cases.append(CorpusCase("rgba out of range", semantic("bg.window", "rgba(300,0,0,1)"), refused: false, .invalidValue))
    cases.append(CorpusCase("four shadow layers", semantic("shadow.2", "0 1 2 0 #000000, 0 1 2 0 #000000, 0 1 2 0 #000000, 0 1 2 0 #000000"), refused: false, .invalidValue))
    cases.append(CorpusCase("huge font size", userTheme(extra: ["typography": ["styles": ["body": ["size": 1e300]]]]), refused: false, .clamped))
    cases.append(CorpusCase("negative radius", userTheme(extra: ["radius": ["md": -50]]), refused: false, .clamped))
    cases.append(CorpusCase("long animation", userTheme(extra: ["motion": ["enter.fast": ["duration": 60_000]]]), refused: false, .clamped))
    cases.append(CorpusCase("non-ASCII font name", userTheme(extra: ["typography": ["family": ["reader": "Ünïcode Sans"]]]), refused: false, .invalidValue))
    cases.append(CorpusCase("incompatible reference", userTheme(extra: ["components": ["row": ["paddingX": "{bg.window}"]]]), refused: false, .incompatibleReference))
    cases.append(CorpusCase("malformed reference", semantic("bg.window", "{bg window}"), refused: false, .unknownReference))
    cases.append(CorpusCase("unknown keys", userTheme(extra: ["semantic": ["color": ["bg.evil": "#000000"]], "plugins": ["x": 1]]), refused: false, .unknownKey))
    cases.append(CorpusCase("direction override in name", userTheme(name: "\u{202E}emeht"), refused: false, .invalidName))
    cases.append(CorpusCase("bad default accent", userTheme(extra: ["defaultAccent": "Blue!"]), refused: false, .invalidAccentID))
    return cases
}()

@Suite struct ValidatorCorpusTests {
    @Test func corpusHasAtLeast25RefusedFiles() {
        #expect(corpus.filter(\.refused).count >= 25)
        #expect(corpus.count >= 40)
    }

    @Test(arguments: corpus)
    func corpusCase(_ c: CorpusCase) {
        let result = ThemeValidator.validate(data: c.data)
        #expect(result.isRefused == c.refused, "\(c.name): \(result.issues)")
        #expect(result.codes.contains(c.code), "\(c.name): expected \(c.code), got \(result.issues)")
        if c.refused {
            #expect(result.file == nil)
        }
        if let file = result.file {
            let dump = String(describing: file)
            for needle in ["url(", "var(", "<", "script", "expression", ";", "data:", "\u{202E}"] {
                #expect(!dump.contains(needle), "\(c.name): \(needle) survived")
            }
        }
    }

    @Test func refusalsHappenBeforeParsingLargeFiles() {
        let data = Data(repeating: 0x20, count: ThemeValidator.maxFileSize + 1)
        #expect(ThemeValidator.validate(data: data).codes == [.tooLarge])
    }

    @Test func newerVersionMessageSaysSo() {
        let result = validate(userTheme().merging(["formatVersion": 2]) { _, n in n })
        #expect(result.issues.first?.message.contains("newer version") == true)
    }

    @Test func referenceCycleAcrossTokensIsRefused() {
        let object = userTheme(id: "me.loop", extra: ["semantic": ["color": ["text.primary": "{text.secondary}",
                                                                              "text.secondary": "{text.primary}"]]])
        var library = ThemeLibrary.builtIn
        let summary = library.add(data: themeJSON(object), source: .user(URL(fileURLWithPath: "/tmp/loop.json")))
        #expect(!summary.isUsable)
        #expect(summary.issues.contains { $0.code == .referenceCycle && $0.severity == .refused })
    }

    @Test func referenceChainLongerThan8IsRefused() {
        let chain = ["text.primary", "text.secondary", "text.tertiary", "text.disabled", "text.onToast", "text.danger",
                     "text.success", "text.warning", "text.ai", "border.control"]
        var colors: [String: Any] = [:]
        for (a, b) in zip(chain, chain.dropFirst()) { colors[a] = "{\(b)}" }
        colors["border.control"] = "#111111"
        var library = ThemeLibrary.builtIn
        let summary = library.add(data: themeJSON(userTheme(id: "me.chain", extra: ["semantic": ["color": colors]])),
                                  source: .user(URL(fileURLWithPath: "/tmp/chain.json")))
        #expect(summary.issues.contains { $0.code == .referenceTooDeep && $0.severity == .refused })
        #expect(!summary.isUsable)
    }

    @Test func extendsCycleIsRefused() {
        var library = ThemeLibrary.builtIn
        library.add(data: themeJSON(userTheme(id: "me.a", extends: "me.b")), source: .user(URL(fileURLWithPath: "/tmp/a.json")))
        let b = library.add(data: themeJSON(userTheme(id: "me.b", extends: "me.a")), source: .user(URL(fileURLWithPath: "/tmp/b.json")))
        #expect(b.issues.contains { $0.code == .extendsCycle })
        #expect(library.summary(id: "me.a")?.isUsable == false)
    }

    @Test func extendsDeeperThan3IsRefused() {
        var library = ThemeLibrary.builtIn
        let one = library.add(data: themeJSON(userTheme(id: "me.one", extends: "openhuman.paper")), source: .user(URL(fileURLWithPath: "/tmp/one.json")))
        #expect(one.isUsable, "\(one.issues)")
        let two = library.add(data: themeJSON(userTheme(id: "me.two", extends: "me.one")), source: .user(URL(fileURLWithPath: "/tmp/two.json")))
        #expect(two.issues.contains { $0.code == .extendsTooDeep })
        #expect(!two.isUsable)
    }

    @Test func duplicateUserIDsKeepTheFirst() {
        var library = ThemeLibrary.builtIn
        library.replaceUserFiles([
            (URL(fileURLWithPath: "/tmp/a-first.json"), validate(userTheme(id: "me.same", name: "First"))),
            (URL(fileURLWithPath: "/tmp/b-second.json"), validate(userTheme(id: "me.same", name: "Second"))),
        ])
        let same = library.summaries.filter { $0.id == "me.same" }
        #expect(same.count == 2)
        #expect(same.first { $0.isUsable }?.name == "First")
        #expect(same.contains { $0.issues.contains { $0.code == .duplicateID } && !$0.isUsable })
    }

    @Test func userAccentCannotShadowABuiltIn() {
        var library = ThemeLibrary.builtIn
        let accent: [String: Any] = ["format": "openhuman-accent", "formatVersion": 1, "id": "me.accent.blue", "name": "My blue",
                                     "light": ["accent.ring": "#0000FF"], "dark": ["accent.ring": "#8888FF"]]
        let summary = library.add(data: themeJSON(accent), source: .user(URL(fileURLWithPath: "/tmp/accents/blue.json")))
        #expect(summary.issues.contains { $0.code == .accentShortIDConflict })
        #expect(!summary.isUsable)
        let resolved = library.resolve(ThemePreferences(accentID: "blue"), appearance: .light)
        let builtInBlue = ThemeLibrary.builtIn.resolve(ThemePreferences(accentID: "blue"), appearance: .light)
        #expect(builtInBlue.accentID == "blue")
        #expect(resolved.accentRing == builtInBlue.accentRing)
        #expect(resolved.accentRing != ThemeColor(hex: "#0000FF"))
    }

    @Test func goodValuesParse() throws {
        let result = validate(userTheme(extra: [
            "primitives": ["color": ["sun.700": "#F0A020", "sun.100": "rgba(240, 160, 32, 0.5)"]],
            "semantic": ["color": ["bg.window": "#FFFDF5", "text.secondary": "{sun.700}", "shadow.1": "0 1 2 0 rgba(0,0,0,0.1), 0 4 12 -2 #00000020"]],
            "typography": ["family": ["reader": "system-serif"], "styles": ["reader": ["size": 15]]],
            "motion": ["enter.fast": ["duration": 120, "easing": "cubic-bezier(0.3, -0.5, 0.2, 1.5)"]],
            "reader": ["emailColors": "alwaysOriginal", "maxImageWidth": "90%"],
        ]))
        #expect(result.issues.isEmpty, "\(result.issues)")
        let file = try #require(result.file)
        #expect(file.primitives["sun.100"] == ThemeColor(r8: 240, g8: 160, b8: 32, alpha: 0.5))
        #expect(file.tokens["semantic/color/text.secondary"] == .reference("sun.700"))
        #expect(file.tokens["semantic/color/shadow.1"]?.shadowLayers == 2)
        #expect(file.typography["typography/styles/reader"]?.size == 15)
        #expect(file.tokens["motion/enter.fast"] == .value(.motion(ThemeMotion(durationMs: 120, easing: .cubicBezier(0.3, -0.5, 0.2, 1.5)))))
        #expect(file.tokens["reader/maxImageWidth"] == .value(.percent(90)))
    }
}

private extension TokenSource {
    var shadowLayers: Int? { if case .value(.shadow(let s)) = self { s.layers.count } else { nil } }
}
