import Foundation

@MainActor
enum QuickReplyInsertion {
    static func target(in editor: any ComposeTextEditing) -> Range<Int> {
        editor.text(in: editor.fullRange)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            ? editor.fullRange : editor.editorSelection
    }

    @discardableResult
    static func insert(_ reply: QuickReply, over target: Range<Int>, expected: String?, editor: any ComposeTextEditing,
                       session: ComposeSession, center: AICenter, warnsSuspicious: Bool = false) -> Bool {
        let stale: Bool
        if let expected, editor.text(in: target) != expected {
            stale = true
        } else {
            stale = target.lowerBound < 0 || target.upperBound > editor.fullRange.upperBound
        }
        guard !stale, editor.replaceText(in: target, with: reply.body) else {
            center.copyInstead(reply.body, session: session,
                               reason: String(localized: "The draft changed while the AI was writing, so the text wasn't put in."))
            return false
        }
        if let notice = notice(for: reply, suspicious: warnsSuspicious) { session.notice = notice }
        return true
    }

    static func notice(for reply: QuickReply, suspicious: Bool) -> ComposeSession.Notice? {
        var lines: [String] = []
        if suspicious { lines.append(AIWording.suspicious) }
        if !reply.linkHostsAddedByAI.isEmpty {
            let hosts = reply.linkHostsAddedByAI.joined(separator: ", ")
            lines.append(String(localized: "Link added by AI: \(hosts). Check it before sending."))
        }
        guard !lines.isEmpty else { return nil }
        return ComposeSession.Notice(suspicious ? .warning : .info, lines.joined(separator: " "))
    }
}
