import Foundation

public struct UpdateFeed: Sendable, Equatable {
    public static let openHuman = UpdateFeed(repository: "michaelmagan/OpenHuman")!

    public let repository: String
    public let releasesURL: URL
    public let releasesPage: URL

    public init?(repository: String) {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        func valid(_ part: Substring) -> Bool {
            guard let first = part.first, first.isLetter || first.isNumber else { return false }
            return part.count <= 100 && part.allSatisfy(allowed.contains)
        }
        guard parts.count == 2, parts.allSatisfy(valid),
              let api = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=10"),
              let page = URL(string: "https://github.com/\(repository)/releases")
        else { return nil }
        self.repository = repository
        self.releasesURL = api
        self.releasesPage = page
    }

    // Why: the page Download opens comes from the answer, so only this repository's own release pages are trusted
    public func downloadPage(for candidate: String?) -> URL {
        guard let candidate, let url = URL(string: candidate), url.scheme == "https", url.host() == "github.com",
              url.user() == nil, url.port == nil
        else { return releasesPage }
        let path = url.path(percentEncoded: false).lowercased()
        guard path.hasPrefix("/\(repository.lowercased())/releases/"), !path.contains("..") else { return releasesPage }
        return url
    }

    public static let maxRedirects = 3

    // Why: the check only ever talks to GitHub, so a hop anywhere else or a long chain ends it
    public static func allowsRedirect(from source: URL, to target: URL, count: Int) -> Bool {
        (1...maxRedirects).contains(count) && isGitHub(source) && isGitHub(target)
    }

    private static func isGitHub(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host(percentEncoded: true)?.lowercased() else { return false }
        return (host == "api.github.com" || host == "github.com") && url.port == nil && url.user(percentEncoded: true) == nil
    }
}

public struct UpdateFeedReply: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public enum UpdateFeedFailure: Error, Equatable, Sendable {
    case offline
    case timedOut
    case unreachable
    case redirectRefused
}

public typealias UpdateFeedFetch = @Sendable (URL) async throws -> UpdateFeedReply
