import Foundation
import OpenHumanCore

extension RetryPolicy {
    public static let maximumJitter: Duration = .seconds(1)

    public func delay(beforeRetry n: Int, retryAfter: Duration?, jitter: Double) -> Duration {
        let exponent = max(0, min(n - 1, 30))
        let backoff = baseDelay.timeInterval * pow(2, Double(exponent))
        let jittered = min(maxDelay.timeInterval, backoff + Self.maximumJitter.timeInterval * min(max(jitter, 0), 1))
        let floor = retryAfter?.timeInterval ?? 0
        return .milliseconds(Int64((max(jittered, floor) * 1000).rounded()))
    }
}

enum RetryRules {
    static func isRetryable(_ error: GmailError, idempotent: Bool) -> Bool {
        switch error {
        case .rateLimited:
            return true
        case .server:
            return idempotent
        case .transport(let t):
            switch t {
            case .timedOut, .connectionLost: return idempotent
            case .cannotConnect, .notConnected: return true
            case .refusedByGuard, .cancelled, .tls, .other: return false
            }
        default:
            return false
        }
    }
}

public enum RetryAfter {
    public static func parse(_ value: String, now: Date) -> Duration? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return nil }
        if text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) {
            guard let seconds = Int64(text) else { return nil }
            return .seconds(seconds)
        }
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: text.replacingOccurrences(of: "  ", with: " ")) {
                let seconds = max(0, date.timeIntervalSince(now))
                return .milliseconds(Int64((seconds * 1000).rounded()))
            }
        }
        return nil
    }
}
