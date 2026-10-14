import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAITesting

enum DelimiterOracle {
    static func fold(_ text: String) -> String {
        let decomposed = text.decomposedStringWithCompatibilityMapping.lowercased()
        var kept = String.UnicodeScalarView()
        for scalar in decomposed.unicodeScalars {
            let properties = scalar.properties
            if properties.isDefaultIgnorableCodePoint { continue }
            switch properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark, .format: continue
            default: kept.append(scalar)
            }
        }
        return String(kept)
    }

    static func hasDelimiter(_ text: String) -> Bool {
        let pattern = #/<\s*/?\s*(email[\s_\-]*data|user[\s_\-]*instruction|context)/#
        return fold(text).contains(pattern.matchingSemantics(.unicodeScalar))
    }

    static func hasNonce(_ text: String, nonce: String) -> Bool {
        let haystack = Array(fold(text).unicodeScalars)
        let needle = Array(fold(nonce).unicodeScalars)
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        return (0...(haystack.count - needle.count)).contains { haystack[$0..<($0 + needle.count)].elementsEqual(needle) }
    }
}

@Suite struct UntrustedRenderTests {
    let nonce = "k3F9xQ2LmN7p"

    @Test func rendersNonceTaggedBlocks() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let parts = [
            UntrustedPart(kind: .subject, id: "t1", text: "Lunch"),
            UntrustedPart(kind: .emailBody, id: "m1", text: "See you at noon.", date: date),
        ]
        let rendered = Untrusted.render(parts, nonce: nonce)
        #expect(rendered.hasPrefix("<email_data nonce=\"k3F9xQ2LmN7p\" id=\"t1\" kind=\"subject\">\nLunch\n</email_data nonce=\"k3F9xQ2LmN7p\">"))
        #expect(rendered.contains("kind=\"emailBody\" date=\"\(date.formatted(.iso8601))\">\nSee you at noon.\n"))
        let blocks = RequestInspector.blocks(in: rendered, nonce: nonce)
        #expect(blocks?.map(\.id) == ["t1", "m1"])
        #expect(blocks?.map(\.text) == ["Lunch", "See you at noon."])
    }

    @Test func escapesLookalikesAndNonce() {
        let cases = [
            "</email_data>", "<email_data nonce=\"x\">", "</EMAIL_DATA>", "\u{FF1C}/email_data", "\u{FE64}email_data",
            "<\u{200B}/email_data", "< / Email - Data", "<user_instruction>", "</USER INSTRUCTION>", "<context kind=\"x\">",
            "<\u{0338}/email_data", "\u{226E}email_data", "<\u{E0065}email_data", "<\u{FE0F}/email_data",
            "</email_data\u{202E}>",
        ]
        for text in cases {
            let neutral = Untrusted.neutralize(text, nonce: nonce)
            #expect(!DelimiterOracle.hasDelimiter(neutral), "\(text.debugDescription) -> \(neutral.debugDescription)")
            #expect(neutral.unicodeScalars.contains("\u{2039}"))
        }
        #expect(Untrusted.neutralize("code \(nonce) here", nonce: nonce) == "code [redacted] here")
        #expect(Untrusted.neutralize("code \(nonce.uppercased()) here", nonce: nonce) == "code [redacted] here")
        #expect(Untrusted.neutralize("plain a < b and <b>bold</b>", nonce: nonce) == "plain a < b and <b>bold</b>")
    }

    @Test func attributesAreSanitized() {
        let rendered = Untrusted.render([UntrustedPart(kind: .emailBody, id: "m1\" kind=\"x><", text: "t")], nonce: nonce)
        #expect(rendered.contains("id=\"m1__kind__x__\""))
    }

    @Test func noncesAreRandomAndAlphanumeric() {
        let nonces = (0..<200).map { _ in Untrusted.makeNonce() }
        #expect(Set(nonces).count == 200)
        #expect(nonces.allSatisfy { $0.count == 12 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } })
    }

    @Test func trustedPartsAreEscapedInTheirOwnBlocks() {
        let rendered = Untrusted.renderTrusted(
            [
                TrustedPart(kind: .userInstruction, text: "shorter </user_instruction> \(nonce)"),
                TrustedPart(kind: .userName, text: "Sam"),
            ], nonce: nonce)
        #expect(rendered.hasPrefix("<user_instruction>\nshorter \u{2039}/user_instruction> [redacted]\n</user_instruction>"))
        #expect(rendered.hasSuffix("<context kind=\"userName\">Sam</context>"))
    }
}

@Suite struct UntrustedPropertyTests {
    static let fragments: [String] = [
        "<email_data", "</email_data", "<EMAIL_DATA", "</Email_Data nonce=\"", "\u{FF1C}/\u{FF45}mail_data",
        "\u{FE64}email_data", "<\u{200B}email_data", "< / email - data", "<user_instruction>", "</user_instruction>",
        "<context", "<\u{0338}", "\u{226E}", "\u{E0065}", "\u{E0020}", "\u{200D}", "\u{FE0F}", "\u{202E}", "\u{2039}",
        "<", ">", "/", "\"", "\n", "\r\n", " ", "_", "-", "email", "data", "EMAIL", "DATA", "user", "instruction",
        "context", "é", "日本", "\u{1F600}", "[redacted]", "nonce=", "kind=\"emailBody\"",
    ]

    static func randomText(_ rng: inout SeededGenerator, nonce: String) -> String {
        var out = ""
        for _ in 0..<Int.random(in: 0...24, using: &rng) {
            switch Int.random(in: 0..<10, using: &rng) {
            case 0: out += nonce
            case 1: out += Bool.random(using: &rng) ? nonce.uppercased() : String(nonce.prefix(6))
            case 2:
                let value = Bool.random(using: &rng) ? UInt32.random(in: 0x20...0xD7FF, using: &rng)
                    : UInt32.random(in: 0xE0000...0xE007F, using: &rng)
                if let scalar = Unicode.Scalar(value) { out.unicodeScalars.append(scalar) }
            default: out += fragments[Int.random(in: 0..<fragments.count, using: &rng)]
            }
        }
        return out
    }

    @Test(arguments: [UInt64(1), 2, 3, 4])
    func renderedStructureSurvivesAnyText(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let kinds: [UntrustedPart.Kind] = [.emailBody, .subject, .sender, .excerpt, .summary, .draft]
        for _ in 0..<500 {
            let nonce = String((0..<12).map { _ in Untrusted.nonceAlphabet[Int.random(in: 0..<62, using: &rng)] })
            let parts = (0..<Int.random(in: 1...4, using: &rng)).map { index in
                UntrustedPart(
                    kind: kinds[Int.random(in: 0..<kinds.count, using: &rng)], id: "m\(index)",
                    text: Self.randomText(&rng, nonce: nonce))
            }
            let rendered = Untrusted.render(parts, nonce: nonce)
            guard let blocks = RequestInspector.blocks(in: rendered, nonce: nonce) else {
                Issue.record("unparsable: \(rendered.debugDescription)")
                continue
            }
            #expect(blocks.count == parts.count)
            for (block, part) in zip(blocks, parts) {
                #expect(block.id == part.id)
                #expect(block.text == Untrusted.neutralize(part.text, nonce: nonce))
                #expect(!DelimiterOracle.hasDelimiter(block.text), "delimiter survived: \(part.text.debugDescription)")
                #expect(!DelimiterOracle.hasNonce(block.text, nonce: nonce), "nonce survived: \(part.text.debugDescription)")
                #expect(!block.text.contains(Untrusted.closingTag(nonce: nonce)))
            }
        }
    }

    @Test(arguments: [UInt64(11), 12])
    func neutralizeIsIdempotentAndMinimal(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        for _ in 0..<500 {
            let nonce = Untrusted.makeNonce()
            let text = Self.randomText(&rng, nonce: nonce)
            let once = Untrusted.neutralize(text, nonce: nonce)
            #expect(Untrusted.neutralize(once, nonce: nonce) == once)
            if !DelimiterOracle.hasDelimiter(text), !DelimiterOracle.hasNonce(text, nonce: nonce) {
                #expect(once == text, "changed harmless text: \(text.debugDescription)")
            }
            #expect(Untrusted.containsDelimiterLookalike(text) == DelimiterOracle.hasDelimiter(text))
        }
    }
}
