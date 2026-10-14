import Foundation
import MailModel
import MailRender
import OpenHumanAI
import OpenHumanCore

public struct AIThreadContext: Sendable, Hashable {
    public var input: AIThreadInput
    public var lastIsFromMe: Bool
    public var messageKeys: [MessageKey]
    public var facts = QuickReplyExclusion.Facts()
    public var isNewest = true
    public var newestFrom: String?
}

struct AIThreadLoader: Sendable {
    let data: any MailDataSource
    let bodyTimeout: Duration
    static let maxMessages = 40
    static let maxBodyCharacters = 20_000

    static func threadKey(_ thread: ThreadKey) -> String {
        "\(thread.account.rawValue).\(thread.gmailThreadID.rawValue)"
    }

    static func messageKey(_ message: MessageKey) -> String {
        "\(message.account.rawValue).\(message.gmailMessageID.rawValue)"
    }

    enum Bodies: Sendable {
        case readerDefault
        case all
    }

    static func window(_ messages: [MessageSummary], upTo target: MessageKey?) -> [MessageSummary]? {
        var end = messages.endIndex
        if let target {
            guard let index = messages.firstIndex(where: { $0.id == target }) else { return nil }
            end = index + 1
        }
        return Array(messages[..<end].suffix(maxMessages))
    }

    func load(_ thread: ThreadKey, upTo target: MessageKey? = nil, account: Account?, accountKey: String?,
              trigger: AITrigger, bodies policy: Bodies) async -> AIThreadContext? {
        guard let detail = await Self.first(data.threadDetail(thread)) ?? nil, !detail.messages.isEmpty,
              let messages = Self.window(detail.messages, upTo: target), !messages.isEmpty else { return nil }
        let newest = messages.last?.id
        let wanted: (MessageSummary) -> Bool = { summary in
            policy == .all || summary.isUnread || summary.id == newest
        }
        let read = await withTaskGroup(of: (Int, String, Bool).self) { group in
            var next = 0
            var out = [(text: String, cut: Bool)](repeating: ("", false), count: messages.count)
            func add() {
                guard next < messages.count else { return }
                let index = next
                let summary = messages[index]
                let reads = wanted(summary)
                group.addTask {
                    guard reads else { return (index, summary.snippet, false) }
                    let (text, cut) = await self.text(of: summary)
                    return (index, text, cut)
                }
                next += 1
            }
            for _ in 0..<4 { add() }
            for await (index, text, cut) in group {
                out[index] = (text, cut)
                add()
            }
            return out
        }
        let inputs = zip(messages, read).map { summary, body in
            AIMessageInput(messageKey: Self.messageKey(summary.id), from: Self.sender(summary.from, account: account),
                           date: summary.date, bodyText: body.text, subject: detail.subject, accountKey: accountKey)
        }
        let lastFrom = messages.last?.from?.email ?? ""
        var context = AIThreadContext(
            input: AIThreadInput(threadKey: Self.threadKey(thread), subject: detail.subject, messages: inputs,
                                 accountKey: accountKey, trigger: trigger),
            lastIsFromMe: account.map { $0.isMe(lastFrom) } ?? false,
            messageKeys: messages.map(\.id))
        context.isNewest = newest == detail.messages.last?.id
        context.newestFrom = messages.last?.from.map { $0.email.lowercased() }
        context.facts.newestHasCalendarInvite = messages.last?.hasCalendarInvite ?? false
        context.facts.newestWasCut = read.last?.cut ?? false
        if let newest {
            do {
                context.facts.newestHasListUnsubscribe = try await data.unsubscribeInfo(newest) != nil
            } catch {
                context.facts.newestHasListUnsubscribe = nil
            }
        }
        return context
    }

    static func sender(_ address: EmailAddress?, account: Account?) -> String {
        guard let address else { return String(localized: "Unknown sender") }
        let base = address.name.map { "\($0) <\(address.email)>" } ?? address.email
        return account?.isMe(address.email) == true ? base + " (the user)" : base
    }

    private func text(of summary: MessageSummary) async -> (text: String, cut: Bool) {
        let stream = data.body(summary.id)
        let timeout = bodyTimeout
        let content: MessageContent? = await withTaskGroup(of: MessageContent?.self) { group in
            group.addTask {
                do {
                    for try await state in stream {
                        switch state {
                        case .available(let content): return content
                        case .failed: return nil
                        case .fetching: continue
                        }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let content else { return (summary.snippet, false) }
        let text = PlainTextExtractor.extract(content, format: Self.format(content.textFormat),
                                              maxCharacters: Self.maxBodyCharacters)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (summary.snippet, false) : (trimmed, text.count >= Self.maxBodyCharacters)
    }

    static func format(_ format: MessageTextFormat) -> PlainTextFormat {
        switch format {
        case .fixed: .fixed
        case .flowed(let delSp): .flowed(delSp: delSp)
        }
    }

    static func first<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async -> T? {
        do {
            for try await value in stream { return value }
        } catch {}
        return nil
    }
}
