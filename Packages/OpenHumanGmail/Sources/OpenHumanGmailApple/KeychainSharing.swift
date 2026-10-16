import Foundation

public enum KeychainSharing {
    public static let infoKey = "OHKeychainAccessGroup"
    public static let groupName = "dev.openhuman.shared"

    // Why: a build without the setting, or with it unexpanded, keeps the default group instead of failing every write
    public static func configuredAccessGroup(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        guard let raw = info?[infoKey] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return isAccessGroup(value) ? value : nil
    }

    static func isAccessGroup(_ value: String) -> Bool {
        guard value.count <= 128, let dot = value.firstIndex(of: ".") else { return false }
        let team = value[..<dot]
        let name = value[value.index(after: dot)...]
        guard team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
              !name.isEmpty, name.first != ".", name.last != "." else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
}
