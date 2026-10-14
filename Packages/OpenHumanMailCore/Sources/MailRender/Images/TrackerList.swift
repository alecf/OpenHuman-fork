import Foundation

public enum TrackerList {
    public static let version = 1

    public static let hosts: Set<String> = [
        "list-manage.com",
        "mandrillapp.com",
        "sendgrid.net",
        "exct.net",
        "rs6.net",
        "sparkpostmail.com",
        "mjt.lu",
        "sendibt3.com",
        "klclick.com",
        "createsend1.com",
        "icptrack.com",
        "bmetrack.com",
        "pstmrk.it",
        "awstrack.me",
        "emltrk.com",
        "t.eloqua.com",
        "pi.pardot.com",
        "track.hubspot.com",
        "mailtrack.io",
        "mailfoogae.appspot.com",
        "t.yesware.com",
        "bananatag.com",
        "getnotify.com",
        "r.superhuman.com",
        "google-analytics.com",
        "doubleclick.net",
        "pixel.wp.com",
        "api.mixpanel.com",
    ]

    public static let pathMarkers: [String] = ["/track/open", "/wf/open", "/open.php", "/open.aspx", "/e/o/"]

    public static func isTracker(host: String, in list: Set<String> = hosts) -> Bool {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty else { return false }
        if list.contains(h) { return true }
        for t in list where h.utf8.count > t.utf8.count && h.hasSuffix(t) {
            let dot = h.utf8[h.utf8.index(h.utf8.endIndex, offsetBy: -t.utf8.count - 1)]
            if dot == 46 { return true }
        }
        return false
    }

    public static func isTracker(url: String, in list: Set<String> = hosts) -> Bool {
        guard let parts = URLPolicy.httpParts(url) else { return false }
        if isTracker(host: parts.host, in: list) { return true }
        guard parts.path.utf8.count >= 5 else { return false }
        let path = parts.path.lowercased()
        return pathMarkers.contains { path.contains($0) }
    }

    // Why: content-blocker regexes have no `|`, so the subdomain part `(.*\.)?` can over-block inside a path, never under-block
    public static func contentRuleListJSON(hosts list: Set<String> = hosts) -> String {
        let rules = list.sorted().map { host -> String in
            let escaped = host.replacingOccurrences(of: ".", with: "\\\\.")
            return "{\"trigger\":{\"url-filter\":\"^https?://(.*\\\\.)?\(escaped)[/:]\"},\"action\":{\"type\":\"block\"}}"
        }
        return "[" + rules.joined(separator: ",") + "]"
    }
}
