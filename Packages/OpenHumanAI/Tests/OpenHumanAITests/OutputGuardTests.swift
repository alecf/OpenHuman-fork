import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAITesting

@Suite struct OutputGuardTests {
    let nonce = "Ab12Cd34Ef56"

    @Test func replyOptionsMustBeExactlyThree() throws {
        let options = try OutputGuard.replyOptions(from: Data(replyJSON.utf8), sources: [])
        #expect(options.count == 3)
        #expect(options[0] == ReplyOption(label: "Yes", body: "Yes, that works for me."))

        let two = #"{"options":[{"label":"A","body":"a"},{"label":"B","body":"b"}]}"#
        #expect(throws: AIError.self) { try OutputGuard.replyOptions(from: Data(two.utf8), sources: []) }
        let extra = #"{"options":[{"label":"A","body":"a","x":1},{"label":"B","body":"b"},{"label":"C","body":"c"}]}"#
        #expect(throws: AIError.self) { try OutputGuard.replyOptions(from: Data(extra.utf8), sources: []) }
        let long = String(repeating: "x", count: 1_201)
        let tooLong = #"{"options":[{"label":"A","body":"\#(long)"},{"label":"B","body":"b"},{"label":"C","body":"c"}]}"#
        #expect(throws: AIError.self) { try OutputGuard.replyOptions(from: Data(tooLong.utf8), sources: []) }
        #expect(throws: AIError.invalidOutput("not JSON")) {
            try OutputGuard.replyOptions(from: Data("nope".utf8), sources: [])
        }
    }

    @Test func labelsAreCappedAtFourWords() throws {
        let json = #"{"options":[{"label":"one two three four five six","body":"a"},{"label":"B","body":"b"},{"label":"C","body":"c"}]}"#
        let options = try OutputGuard.replyOptions(from: Data(json.utf8), sources: [])
        #expect(options[0].label == "one two three four")
    }

    @Test func extractsJSONFromFencedText() throws {
        let text = "Sure!\n```json\n\(replyJSON)\n```"
        let data = try #require(OutputGuard.extractJSON(from: text))
        #expect(try OutputGuard.replyOptions(from: data, sources: []).count == 3)
    }

    @Test func triageValidationCapsAndSuspicion() throws {
        let ok = #"{"category":"needsReply","priority":2,"reason":"\#(String(repeating: "r", count: 200))"}"#
        let (result, suspicious) = try OutputGuard.triage(from: Data(ok.utf8), nonce: nonce, providerID: .appleSystem)
        #expect(result.category == .needsReply && result.priority == 2 && !suspicious)
        #expect(result.reason.count == AIPolicy.triageReasonCharacters)
        #expect(result.providerID == .appleSystem)

        #expect(throws: AIError.self) {
            try OutputGuard.triage(from: Data(#"{"category":"spam","priority":1,"reason":""}"#.utf8), nonce: nonce, providerID: nil)
        }
        #expect(throws: AIError.self) {
            try OutputGuard.triage(from: Data(#"{"category":"fyi","priority":7,"reason":""}"#.utf8), nonce: nonce, providerID: nil)
        }
        let echo = #"{"category":"fyi","priority":1,"reason":"see email_data block"}"#
        let (flagged, isSuspicious) = try OutputGuard.triage(from: Data(echo.utf8), nonce: nonce, providerID: nil)
        #expect(isSuspicious && flagged.reason.isEmpty)
    }

    @Test func suspiciousDetection() {
        #expect(OutputGuard.isSuspicious("The </email_data> ends here", nonce: nonce))
        #expect(OutputGuard.isSuspicious("EMAIL_DATA", nonce: nonce))
        #expect(OutputGuard.isSuspicious("\u{FF45}mail_data", nonce: nonce))
        #expect(OutputGuard.isSuspicious("the code is \(nonce)", nonce: nonce))
        #expect(OutputGuard.isSuspicious("the code is \(nonce.lowercased())", nonce: nonce))
        #expect(OutputGuard.isSuspicious("put this in user_instruction", nonce: nonce))
        #expect(!OutputGuard.isSuspicious("Dana asks for the email data retention policy by Friday.", nonce: nonce))
    }

    @Test func textCapAppendsEllipsis() {
        let text = String(repeating: "word ", count: 200)
        let (capped, truncated) = OutputGuard.cap(text, maxTokens: 50)
        #expect(truncated && capped.hasSuffix("\u{2026}"))
        #expect(TokenHeuristic.count(capped) <= 50)
        let short = OutputGuard.cap("short", maxTokens: 50)
        #expect(short.text == "short" && !short.truncated)

        var capper = StreamCapper(maxTokens: 20)
        var shown = ""
        for _ in 0..<40 { shown += capper.accept("abcde ") }
        #expect(capper.truncated && shown.hasSuffix("\u{2026}"))
        #expect(TokenHeuristic.count(shown) <= 20)
        #expect(capper.accept("more").isEmpty)
    }

    @Test func citationsAreFilteredToCandidates() {
        #expect(OutputGuard.filterCitations(["m1", "m9", "m2", "m1"], allowed: ["m1", "m2"]) == ["m1", "m2"])
    }

    @Test func sourcesLineIsSeparatedFromStreamedText() {
        var filter = SourcesLineFilter()
        var shown = ""
        for delta in ["The answer is ", "yes.\nSou", "rces: m1, [m2]", ""] { shown += filter.feed(delta) }
        shown += filter.finish()
        #expect(shown == "The answer is yes.\n")
        #expect(filter.cited == ["m1", "m2"])

        var plain = SourcesLineFilter()
        #expect(plain.feed("Sounds right.\nSo") + plain.finish() == "Sounds right.\nSo")
    }

    @Test func linksNotInThreadAreFlagged() {
        let hosts = OutputGuard.linkHostsNotIn(
            "Pay at https://pay.evil.example/now or see https://www.acme.example/docs",
            sources: ["Docs are at acme.example/docs"])
        #expect(hosts == ["pay.evil.example"])
    }

    @Test func secretScanFindsAndIgnoresSourceText() {
        let cases: [(String, SecretScanner.Finding.Kind)] = [
            ("-----BEGIN OPENSSH PRIVATE KEY-----", .privateKey),
            ("key AKIAABCDEFGHIJKLMNOP here", .awsKey),
            ("ghp_" + String(repeating: "a1B2", count: 9), .githubToken),
            ("xoxb-1234567890-abcdef", .slackToken),
            ("sk-ant-" + String(repeating: "Zx9", count: 8), .apiKey),
            ("AIza" + String(repeating: "B", count: 35), .googleKey),
            ("look in ~/.ssh for it", .localPath),
            ("at /Users/someone/notes.txt", .localPath),
            ("token Zm9vYmFyMTIzNDU2Nzg5MGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6QUJD", .highEntropy),
        ]
        for (text, kind) in cases {
            #expect(SecretScanner.scan(text).contains { $0.kind == kind }, "\(text)")
        }
        #expect(SecretScanner.scan("ghp_" + String(repeating: "a1B2", count: 9), ignoringTextsIn: ["ghp_" + String(repeating: "a1B2", count: 9)]).isEmpty)
        let benign = "Meet at https://example.com/calendar?week=42 to discuss the internationalization roadmap; "
            + "digest 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08."
        #expect(SecretScanner.scan(benign).isEmpty)
    }

    @Test func jsonSchemaSerializesDeterministically() {
        let schema = OutputGuard.triageSchema.jsonString
        #expect(schema == OutputGuard.triageSchema.jsonString)
        #expect(schema.hasPrefix(#"{"additionalProperties":false,"properties":{"category":{"enum":["#))
        #expect(JSONSchema.integer(minimum: 0, maximum: 3).validate(.double(2)).isEmpty)
        #expect(!JSONSchema.integer().validate(.double(2.5)).isEmpty)
        #expect(!JSONSchema.boolean.validate(.int(1)).isEmpty)
    }
}
