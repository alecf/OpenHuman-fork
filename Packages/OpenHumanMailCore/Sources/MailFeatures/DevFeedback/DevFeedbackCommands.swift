import Foundation

public enum DevFeedbackCommands {
    public static let targetPlaceholder = "<device-name>"
    public static let inboxPath = "~/Downloads/OpenHuman-feedback/"

    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    public static func isValidTarget(_ target: String) -> Bool {
        guard (1...253).contains(target.count), target.first != "-" else { return false }
        return target.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0))
        }
    }

    public static func resolvedTarget(_ setting: String?) -> String? {
        let target = (setting ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidTarget(target) ? target : nil
    }

    public static func send(files: [URL], target: String?) -> String {
        let quoted = files.map { shellQuote($0.path) }.joined(separator: " ")
        return "tailscale file cp \(quoted) \(resolvedTarget(target) ?? targetPlaceholder):"
    }

    public static var receive: String {
        "mkdir -p \(inboxPath) && tailscale file get \(inboxPath)"
    }
}
