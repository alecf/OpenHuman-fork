import Foundation

public enum GoogleConsoleLinks {
    public static let allowedHosts: Set<String> = [
        "console.cloud.google.com", "console.developers.google.com", "support.google.com",
    ]

    public static let projects = URL(string: "https://console.cloud.google.com/cloud-resource-manager")!
    public static let enableGmail = URL(string: "https://console.cloud.google.com/apis/enableflow;apiid=gmail.googleapis.com")!
    public static let enableCalendar = URL(string: "https://console.cloud.google.com/apis/enableflow;apiid=calendar-json.googleapis.com")!
    public static let authOverview = URL(string: "https://console.developers.google.com/auth/overview")!
    public static let authAudience = URL(string: "https://console.developers.google.com/auth/audience")!
    public static let authClients = URL(string: "https://console.developers.google.com/auth/clients")!
    public static let secretHelp = URL(string: "https://support.google.com/cloud/answer/15549257")!

    public static let all: [URL] = [projects, enableGmail, enableCalendar, authOverview, authAudience, authClients, secretHelp]

    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host, allowedHosts.contains(host) else { return false }
        return url.query == nil && url.fragment == nil && url.user == nil && url.password == nil && url.port == nil
    }
}
