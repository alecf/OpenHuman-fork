import Foundation

public enum SecretScanner {
    public struct Finding: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable {
            case privateKey, awsKey, githubToken, slackToken, apiKey, googleKey, localPath, highEntropy
        }

        public let kind: Kind
        public let match: String
    }

    public static let highEntropyMinimumLength = 32
    public static let highEntropyMinimumBits = 4.0

    public static func scan(_ text: String, ignoringTextsIn sources: [String] = []) -> [Finding] {
        var findings: [Finding] = []
        func add(_ kind: Finding.Kind, _ match: Substring) {
            let value = String(match)
            if sources.contains(where: { $0.contains(value) }) { return }
            findings.append(Finding(kind: kind, match: value))
        }
        for match in text.matches(of: #/-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----/#) { add(.privateKey, match.output.0) }
        for match in text.matches(of: #/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/#) { add(.awsKey, match.output) }
        for match in text.matches(of: #/\bgh[pousr]_[A-Za-z0-9]{36,}\b|\bgithub_pat_[A-Za-z0-9_]{40,}\b/#) {
            add(.githubToken, match.output)
        }
        for match in text.matches(of: #/\bxox[abposr]-[A-Za-z0-9-]{10,}/#) { add(.slackToken, match.output) }
        for match in text.matches(of: #/\bsk-(?:ant-)?[A-Za-z0-9_-]{20,}/#) { add(.apiKey, match.output) }
        for match in text.matches(of: #/\bAIza[0-9A-Za-z_-]{35}\b/#) { add(.googleKey, match.output) }
        for match in text.matches(
            of: #/~/\.ssh\b|/Users/[^/\s]+/|/home/[^/\s]+/|\.aws/credentials|\bid_(?:rsa|ed25519|ecdsa)\b/#)
        {
            add(.localPath, match.output)
        }
        for match in text.matches(of: #/[A-Za-z0-9+/=_-]{32,}/#) {
            let token = match.output
            if token.count >= highEntropyMinimumLength, isHighEntropy(token) { add(.highEntropy, token) }
        }
        return findings
    }

    static func isHighEntropy(_ token: Substring) -> Bool {
        var counts: [Character: Int] = [:]
        for character in token { counts[character, default: 0] += 1 }
        let length = Double(token.count)
        let entropy = counts.values.reduce(0.0) { sum, count in
            let p = Double(count) / length
            return sum - p * log2(p)
        }
        let classes = [
            token.contains(where: \.isUppercase), token.contains(where: \.isLowercase),
            token.contains(where: \.isNumber),
        ].filter { $0 }.count
        return entropy > highEntropyMinimumBits && classes >= 2
    }
}
