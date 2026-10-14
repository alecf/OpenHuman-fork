import Foundation

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        var s = String(string.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s = String(s.prefix { $0 != "=" })
        switch s.count % 4 {
        case 1: return nil
        case 2: s += "=="
        case 3: s += "="
        default: break
        }
        return Data(base64Encoded: s)
    }
}
