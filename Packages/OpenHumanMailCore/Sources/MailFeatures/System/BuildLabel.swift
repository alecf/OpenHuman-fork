import Foundation

public struct BuildLabel: Sendable, Equatable {
    public static let channelKey = "OHReleaseChannel"
    public static let earlyDevelopmentChannel = "early-development"
    public static let earlyDevelopmentNotice = "Early development build — expect rough edges. Please send feedback."

    public var version: String
    public var build: String
    public var channel: String

    public init(version: String, build: String, channel: String) {
        self.version = version
        self.build = build
        self.channel = channel
    }

    public init(infoDictionary: [String: Any]) {
        func value(_ key: String) -> String? {
            let text = (infoDictionary[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        self.init(version: value("CFBundleShortVersionString") ?? "0", build: value("CFBundleVersion") ?? "0",
                  channel: value(Self.channelKey) ?? "")
    }

    public static var main: BuildLabel { BuildLabel(infoDictionary: Bundle.main.infoDictionary ?? [:]) }

    public var isEarlyDevelopment: Bool { channel == Self.earlyDevelopmentChannel }

    public var versionLine: String { "Version \(version) (\(build))" }

    public var notice: String? { isEarlyDevelopment ? Self.earlyDevelopmentNotice : nil }
}
