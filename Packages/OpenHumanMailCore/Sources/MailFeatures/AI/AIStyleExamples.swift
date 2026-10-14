import Foundation
import MailModel
import MailRender
import OpenHumanAI

enum AIStyleExamples {
    static let maxThreads = 12
    static let readCharacters = 2_000

    static func load(data: any MailDataSource, account: Account) async -> [String] {
        guard let page = try? await data.threadPage(.system(.sent), account: account.id, after: nil, limit: maxThreads)
        else { return [] }
        var out: [String] = []
        for row in page.rows where out.count < DefaultAIFeatures.maxStyleExamples {
            guard let detail = await AIThreadLoader.first(data.threadDetail(row.id)) ?? nil,
                  let mine = detail.messages.last(where: { account.isMe($0.from?.email ?? "") }),
                  let text = await storedText(of: mine.id, data: data) else { continue }
            out.append(String(text.prefix(DefaultAIFeatures.styleExampleCharacters)))
        }
        return out
    }

    static func storedText(of message: MessageKey, data: any MailDataSource) async -> String? {
        var content: MessageContent?
        do {
            for try await state in data.body(message) {
                if case .available(let found) = state { content = found }
                break
            }
        } catch {
            return nil
        }
        guard let content else { return nil }
        let text = PlainTextExtractor.extract(content, format: AIThreadLoader.format(content.textFormat),
                                              maxCharacters: readCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

extension AICenter {
    public func styleExamples(for account: Account) async -> [String] {
        if let cached = styleExampleCache[account.id] { return cached }
        guard let data = environment?.data else { return [] }
        let loaded = await AIStyleExamples.load(data: data, account: account)
        styleExampleCache[account.id] = loaded
        return loaded
    }
}
