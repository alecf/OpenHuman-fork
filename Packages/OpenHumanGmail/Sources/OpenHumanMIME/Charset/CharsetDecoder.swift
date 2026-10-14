import Foundation

public enum CharsetDecoder {
    public static func decode(_ data: Data, declaredCharset: String?) -> (text: String, warning: String?) {
        let name = normalize(declaredCharset)
        if let name {
            if name == "us-ascii", data.contains(where: { $0 >= 0x80 }) {
                if let text = String(data: data, encoding: .utf8) { return (text, nil) }
                return fallback(data, "charset:us-ascii with 8-bit bytes")
            }
            if let encoding = encoding(for: name) {
                if let text = String(data: data, encoding: encoding) { return (text, nil) }
                return fallback(data, "charset:\(name) did not decode")
            }
            if let text = String(data: data, encoding: .utf8) {
                return (text, "charset:unknown \(name); used utf-8")
            }
            return fallback(data, "charset:unknown \(name)")
        }
        if let text = String(data: data, encoding: .utf8) { return (text, nil) }
        return fallback(data, "charset:none declared")
    }

    private static func fallback(_ data: Data, _ reason: String) -> (String, String?) {
        if let text = String(data: data, encoding: .windowsCP1252) { return (text, "\(reason); used windows-1252") }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: data.map { Unicode.Scalar($0) })
        return (String(scalars), "\(reason); used iso-8859-1")
    }

    static func normalize(_ raw: String?) -> String? {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !name.isEmpty else { return nil }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if let star = name.firstIndex(of: "*") { name = String(name[..<star]) }
        let aliases = ["latin1": "iso-8859-1", "latin-1": "iso-8859-1", "iso8859-1": "iso-8859-1",
                       "cp1252": "windows-1252", "x-cp1252": "windows-1252", "utf8": "utf-8",
                       "ks_c_5601-1987": "euc-kr", "gb2312": "gb18030", "x-sjis": "shift_jis", "sjis": "shift_jis",
                       "ascii": "us-ascii", "ansi_x3.4-1968": "us-ascii", "mac-roman": "macintosh"]
        return aliases[name] ?? name
    }

    static func encoding(for name: String) -> String.Encoding? {
        let table: [String: String.Encoding] = [
            "utf-8": .utf8, "utf-16": .utf16, "utf-16le": .utf16LittleEndian, "utf-16be": .utf16BigEndian,
            "utf-32": .utf32, "us-ascii": .ascii, "iso-8859-1": .isoLatin1, "iso-8859-2": .isoLatin2,
            "windows-1250": .windowsCP1250, "windows-1251": .windowsCP1251, "windows-1252": .windowsCP1252,
            "windows-1253": .windowsCP1253, "windows-1254": .windowsCP1254, "shift_jis": .shiftJIS,
            "euc-jp": .japaneseEUC, "iso-2022-jp": .iso2022JP, "macintosh": .macOSRoman,
        ]
        if let known = table[name] { return known }
        #if canImport(Darwin)
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        #else
        return nil
        #endif
    }
}
