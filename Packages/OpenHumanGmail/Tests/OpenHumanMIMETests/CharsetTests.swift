import Foundation
import Testing
@testable import OpenHumanMIME

@Suite struct CharsetTests {
    private func roundTrip(_ text: String, _ encoding: String.Encoding, label: String,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        guard let data = text.data(using: encoding) else { Issue.record("cannot encode \(label)", sourceLocation: sourceLocation); return }
        let r = CharsetDecoder.decode(data, declaredCharset: label)
        #expect(r.text == text && r.warning == nil, "\(label): \(r)", sourceLocation: sourceLocation)
    }

    @Test func vectors() {
        roundTrip("Grüße café", .utf8, label: "UTF-8")
        roundTrip("Grüße café", .isoLatin1, label: "iso-8859-1")
        roundTrip("Grüße café", .isoLatin1, label: "latin1")
        roundTrip("zażółć gęślą", .isoLatin2, label: "ISO-8859-2")
        roundTrip("zażółć gęślą", .windowsCP1250, label: "windows-1250")
        roundTrip("Привет мир", .windowsCP1251, label: "windows-1251")
        roundTrip("Γειά σου", .windowsCP1253, label: "windows-1253")
        roundTrip("İstanbul ğış", .windowsCP1254, label: "windows-1254")
        roundTrip("“quoted” – €", .windowsCP1252, label: "cp1252")
        roundTrip("こんにちは世界", .shiftJIS, label: "Shift_JIS")
        roundTrip("こんにちは世界", .shiftJIS, label: "x-sjis")
        roundTrip("こんにちは世界", .japaneseEUC, label: "EUC-JP")
        roundTrip("こんにちは世界", .iso2022JP, label: "ISO-2022-JP")
        roundTrip("héllo wörld", .utf16, label: "utf-16")
        roundTrip("héllo wörld", .utf16LittleEndian, label: "utf-16le")
        roundTrip("héllo wörld", .utf16BigEndian, label: "utf-16be")
        roundTrip("héllo", .macOSRoman, label: "macintosh")
        roundTrip("plain ascii", .ascii, label: "us-ascii")
        #if canImport(Darwin)
        roundTrip("你好，世界", CharsetDecoder.encoding(for: "gb18030")!, label: "gb2312")
        roundTrip("你好，世界", CharsetDecoder.encoding(for: "gb18030")!, label: "GB18030")
        roundTrip("你好，世界", CharsetDecoder.encoding(for: "big5")!, label: "big5")
        roundTrip("안녕하세요", CharsetDecoder.encoding(for: "euc-kr")!, label: "euc-kr")
        roundTrip("안녕하세요", CharsetDecoder.encoding(for: "euc-kr")!, label: "ks_c_5601-1987")
        roundTrip("Привет мир", CharsetDecoder.encoding(for: "koi8-r")!, label: "koi8-r")
        #endif
    }

    @Test func literalBytes() {
        #expect(CharsetDecoder.decode(Data([0x80, 0x93, 0x94]), declaredCharset: "windows-1252").text == "€“”")
        #expect(CharsetDecoder.decode(Data([0xE9]), declaredCharset: "ISO-8859-1").text == "é")
        #expect(CharsetDecoder.decode(Data([0xC3, 0xA9]), declaredCharset: "'utf-8'").text == "é")
    }

    @Test func mislabeledInput() {
        #expect(CharsetDecoder.decode(Data("é".utf8), declaredCharset: "us-ascii").text == "é")
        let r = CharsetDecoder.decode(Data([0x63, 0x61, 0x66, 0xE9]), declaredCharset: "utf-8")
        #expect(r.text == "café" && r.warning?.contains("windows-1252") == true)
        #expect(CharsetDecoder.decode(Data("é".utf8), declaredCharset: "klingon").text == "é")
        #expect(CharsetDecoder.decode(Data([0xE9]), declaredCharset: "klingon").text == "é")
        #expect(!CharsetDecoder.decode(Data([0x81, 0x8D, 0x8F, 0x90, 0x9D]), declaredCharset: nil).text.isEmpty)
        #expect(CharsetDecoder.decode(Data([0x61, 0xE2, 0x82]), declaredCharset: "utf-8").warning != nil)
    }

    @Test func hostileLabelsAndBytes() {
        var rng = SeededGenerator(seed: 7)
        let labels: [String?] = [nil, "", " ", "*", "utf-8*en", String(repeating: "x", count: 100_000), "\u{0}", "utf\u{0}8",
                                 "utf-16", "utf-32", "iso-2022-jp", "windows-31j", "ibm037", "x-mac-japanese"]
        for label in labels {
            for _ in 0..<20 {
                let n = Int.random(in: 0..<300, using: &rng)
                let data = Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
                _ = CharsetDecoder.decode(data, declaredCharset: label)
            }
        }
    }

    @Test func encodedWordCharsets() {
        let jp = "日本語".data(using: .shiftJIS)!.base64EncodedString()
        #expect(HeaderDecoder.decode("=?Shift_JIS?B?\(jp)?=") == "日本語")
        #expect(HeaderDecoder.decode("=?utf-8?q?a_b?= =?utf-8?q?=C3=A9?=") == "a bé")
        #expect(HeaderDecoder.decode("=?bogus?B?!!!?=") == "=?bogus?B?!!!?=")
    }
}
