import Foundation

enum Participants {
    struct Sender {
        var name: String?
        var email: String?
        var isFromMe: Bool
        var isUnread: Bool
        var toJSON: String
        var ccJSON: String
    }

    private struct Person { var name: String?; var email: String; var isMe: Bool; var unread: Bool }

    static func render(_ scope: [Sender], me: Set<String>) -> (display: String, json: String) {
        func mine(_ m: Sender) -> Bool { m.isFromMe || (m.email.map { me.contains($0.lowercased()) } ?? false) }
        func clean(_ name: String?) -> String? {
            guard let t = name?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        var unreadByEmail = Set<String>()
        for m in scope where m.isUnread { if let e = m.email { unreadByEmail.insert(e.lowercased()) } }

        var others: [Person] = []
        var authorWrote = false
        for m in scope.reversed() {
            guard let email = m.email, !email.isEmpty else { continue }
            if mine(m) { authorWrote = true; continue }
            let key = email.lowercased()
            if let idx = others.firstIndex(where: { $0.email.lowercased() == key }) {
                if others[idx].name == nil { others[idx].name = clean(m.name) }
            } else {
                others.append(Person(name: clean(m.name), email: email, isMe: false, unread: unreadByEmail.contains(key)))
            }
        }

        var shown = others
        var toMode = false
        if shown.isEmpty, authorWrote, let last = scope.last(where: { mine($0) && ($0.email?.isEmpty == false) }) {
            var recipients: [Person] = []
            for r in WireAddress.decode(last.toJSON) + WireAddress.decode(last.ccJSON) where !r.e.isEmpty {
                let key = r.e.lowercased()
                if me.contains(key) || recipients.contains(where: { $0.email.lowercased() == key }) { continue }
                recipients.append(Person(name: clean(r.n), email: r.e, isMe: false, unread: false))
            }
            if !recipients.isEmpty { shown = recipients; toMode = true }
        }
        let myself = scope.first(where: { mine($0) && ($0.email?.isEmpty == false) })
            .map { Person(name: clean($0.name), email: $0.email ?? "", isMe: true,
                          unread: scope.contains { mine($0) && $0.isUnread }) }

        var display = ""
        if shown.isEmpty {
            if authorWrote { display = "me" }
        } else {
            let names: [String] = shown.map { p in
                if let n = p.name {
                    if shown.count > 1, let firstToken = n.split(separator: " ").first { return String(firstToken) }
                    return n
                }
                return String(p.email.split(separator: "@").first ?? Substring(p.email))
            }
            display = (toMode ? "To: " : "") + names.prefix(3).joined(separator: ", ")
            if names.count > 3 { display += " +\(names.count - 3)" }
        }
        if !display.isEmpty, scope.count > 1 { display += " (\(scope.count))" }

        var list = shown
        if authorWrote, let myself { list.append(myself) }
        let wire = list.prefix(6).map { WirePerson(n: $0.name, e: $0.email, me: $0.isMe ? 1 : 0, u: $0.unread ? 1 : 0) }
        let json = wire.isEmpty ? "[]"
            : (try? StoreJSON.encoder.encode(Array(wire))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return (display, json)
    }
}
