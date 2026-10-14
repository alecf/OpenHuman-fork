import Foundation
import MailModel
import MailRender
import OpenHumanAI
import OpenHumanCore

public struct MailAskRetriever: AskRetrieving {
    public static let maxKeywords = 6
    public static let searchLimit = 20
    public static let maxConversations = 12
    // Why: one long thread must not crowd out the rest, and an injected email brings at most one neighbour
    public static let maxPerConversation = 2
    public static let conversationMessages = 20
    public static let olderMailResults = 20
    public static let olderMailBodies = 10

    let data: any MailDataSource
    let clock: any OHClock
    let bodyBudget: Duration
    let conversationBodyTimeout: Duration

    public init(data: any MailDataSource, clock: any OHClock = SystemClock(), bodyBudget: Duration = .milliseconds(1_500),
                conversationBodyTimeout: Duration = .seconds(20)) {
        self.data = data
        self.clock = clock
        self.bodyBudget = bodyBudget
        self.conversationBodyTimeout = conversationBodyTimeout
    }

    public func retrieve(_ question: String, scope: AskModel.Scope, plan: AskPlan?) async throws -> AskRetrieval {
        let accounts = try await Self.firstValue(data.accounts()) ?? []
        switch scope {
        case .conversation(let thread):
            return try await conversation(thread, accounts: accounts)
        case .account(let account):
            return try await search(question, plan: plan, in: [account], accounts: accounts)
        case .allAccounts:
            return try await search(question, plan: plan, in: nil, accounts: accounts)
        }
    }

    public func retrieveOlderMail(_ question: String, gmailQuery: String, account: AccountID) async throws -> AskRetrieval {
        let accounts = try await Self.firstValue(data.accounts()) ?? []
        let found = try await data.remoteSearch(gmailQuery: gmailQuery, account: account, maxResults: Self.olderMailResults)
        var seen = Set<ThreadKey>()
        let conversations = found.filter { seen.insert($0).inserted }.prefix(Self.maxConversations)
            .map { Conversation(thread: $0, matched: []) }
        let assembled = await assemble(Array(conversations), accounts: accounts, fetchLimit: Self.olderMailBodies)
        let planLine = AskWording.searchedGmail(for: gmailQuery, conversations: assembled.otherThreads.count)
            + (assembled.previews > 0 ? AskWording.fromPreviews(assembled.previews) : "")
        return AskRetrieval(candidates: assembled.candidates, keys: assembled.keys, sources: assembled.sources,
                            otherThreads: assembled.otherThreads, queryText: nil, queryAccount: account, gmailQuery: nil,
                            searched: gmailQuery, planLine: planLine, completeness: nil)
    }

    struct Conversation: Sendable {
        let thread: ThreadKey
        let matched: [Int64]
    }

    func search(_ question: String, plan: AskPlan?, in selected: [AccountID]?,
                accounts: [Account]) async throws -> AskRetrieval {
        let keywords = Array(ExcerptWindow.keywords(in: question).prefix(Self.maxKeywords))
        guard !keywords.isEmpty || plan != nil else { throw AskRetrievalError.noUsableWords }
        let everyWord = keywords.joined(separator: " ")
        let anyWord = keywords.joined(separator: " OR ")
        let semantic = plan?.semanticText ?? (keywords.isEmpty ? nil : everyWord)
        var queries: [String] = []
        if let plan { queries.append(plan.query) }
        if !keywords.isEmpty { queries.append(everyWord) }
        if keywords.count > 1 { queries.append(anyWord) }

        var conversations: [Conversation] = []
        var seen = Set<ThreadKey>()
        var completeness: AskCompleteness?
        var plannedHits = false
        var firstError: (any Error)?
        var answered = false
        for (index, query) in queries.enumerated() {
            try Task.checkCancellation()
            if plan != nil, index > 0, plannedHits { break }
            let results: SearchResultsInfo
            do {
                results = try await data.searchOnce(query, semanticText: semantic, accounts: selected,
                                                    limit: Self.searchLimit)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
                continue
            }
            answered = true
            if completeness == nil { completeness = Self.olderMail(results.completeness) }
            if plan != nil, index == 0 { plannedHits = !results.hits.isEmpty }
            for hit in results.hits where seen.insert(hit.row.id).inserted {
                conversations.append(Conversation(thread: hit.row.id, matched: hit.matchedMessageRowIDs))
            }
            if conversations.count >= Self.maxConversations { break }
        }
        if !answered, let firstError { throw firstError }
        conversations = Array(conversations.prefix(Self.maxConversations))

        let assembled = await assemble(conversations, accounts: accounts, fetchLimit: nil)
        let place = Self.place(selected, accounts: accounts)
        let count = conversations.count
        let searched = keywords.isEmpty ? (plan?.chips.joined(separator: " ") ?? "") : everyWord
        var planLine: String
        let listQuery: String
        if let plan, plannedHits {
            planLine = AskWording.searched(place, chips: plan.chips, conversations: count)
            listQuery = plan.query
        } else {
            planLine = AskWording.searched(place, for: searched, conversations: count)
            listQuery = keywords.count > 1 ? anyWord : everyWord
        }
        if assembled.previews > 0 { planLine += AskWording.fromPreviews(assembled.previews) }
        return AskRetrieval(
            candidates: assembled.candidates, keys: assembled.keys, sources: assembled.sources,
            otherThreads: assembled.otherThreads, queryText: listQuery.isEmpty ? nil : listQuery,
            queryAccount: selected?.count == 1 ? selected?.first : nil,
            gmailQuery: everyWord.isEmpty ? nil : everyWord,
            searched: searched, planLine: planLine, completeness: completeness)
    }

    static func place(_ selected: [AccountID]?, accounts: [Account]) -> String {
        guard let selected, selected.count == 1, let account = accounts.first(where: { $0.id == selected[0] }) else {
            return AskWording.allAccountsPlace
        }
        return account.alias ?? account.displayName ?? account.email
    }

    static func olderMail(_ completeness: SearchCompletenessInfo) -> AskCompleteness? {
        for reason in completeness.reasons {
            if case .olderMailNotLocal(let searchedBack) = reason { return AskCompleteness(searchedBack: searchedBack) }
        }
        return nil
    }

    struct Assembled: Sendable {
        var candidates: [AIMessageInput] = []
        var keys: [String: MessageKey] = [:]
        var sources: [String: AskSource] = [:]
        var otherThreads: [AskSource] = []
        var previews = 0
    }

    func assemble(_ conversations: [Conversation], accounts: [Account], fetchLimit: Int?) async -> Assembled {
        let data = self.data
        let details: [ConversationDetail?] = await withTaskGroup(of: (Int, ConversationDetail?).self) { group in
            for (index, conversation) in conversations.enumerated() {
                let thread = conversation.thread
                group.addTask { (index, (try? await Self.firstValue(data.threadDetail(thread))) ?? nil) }
            }
            var out = [ConversationDetail?](repeating: nil, count: conversations.count)
            for await (index, detail) in group { out[index] = detail }
            return out
        }
        var assembled = Assembled()
        var picked: [(detail: ConversationDetail, message: MessageSummary)] = []
        for (conversation, detail) in zip(conversations, details) {
            guard let detail, !detail.messages.isEmpty else { continue }
            let matched = Set(conversation.matched)
            var ranked = detail.messages.filter { matched.contains($0.id.rowID) }
            if ranked.isEmpty { ranked = detail.messages }
            ranked.reverse()
            assembled.otherThreads.append(Self.source(ranked[0], in: detail))
            let room = AIPolicy.askInboxMaxCandidates - picked.count
            for message in ranked.prefix(min(Self.maxPerConversation, max(room, 0))) { picked.append((detail, message)) }
        }
        let readable = min(fetchLimit ?? picked.count, picked.count)
        let texts = await bodies(picked.prefix(readable).map { $0.message.id })
        for (index, pick) in picked.enumerated() {
            let account = accounts.first { $0.id == pick.message.id.account }
            let key = AIThreadLoader.messageKey(pick.message.id)
            let body = texts[index] ?? pick.message.snippet
            if texts[index] == nil { assembled.previews += 1 }
            assembled.candidates.append(
                AIMessageInput(messageKey: key, from: AIThreadLoader.sender(pick.message.from, account: account),
                               date: pick.message.date, bodyText: body, subject: pick.detail.subject,
                               accountKey: account.map { AICenter.policyKey(email: $0.email) }))
            assembled.keys[key] = pick.message.id
            assembled.sources[key] = Self.source(pick.message, in: pick.detail)
        }
        return assembled
    }

    func bodies(_ messages: [MessageKey]) async -> [Int: String] {
        guard !messages.isEmpty else { return [:] }
        let data = self.data
        let clock = self.clock
        let budget = bodyBudget
        return await withTaskGroup(of: (Int, String?).self) { group in
            for (index, key) in messages.enumerated() {
                group.addTask { (index, await Self.text(of: key, data: data)) }
            }
            group.addTask {
                try? await clock.sleep(for: budget)
                return (-1, nil)
            }
            var out: [Int: String] = [:]
            var pending = messages.count
            for await (index, text) in group {
                guard index >= 0 else { break }
                if let text { out[index] = text }
                pending -= 1
                if pending == 0 { break }
            }
            group.cancelAll()
            return out
        }
    }

    static func text(of key: MessageKey, data: any MailDataSource) async -> String? {
        do {
            for try await state in data.body(key) {
                switch state {
                case .available(let content):
                    let text = PlainTextExtractor.extract(content, format: AIThreadLoader.format(content.textFormat),
                                                          maxCharacters: AIThreadLoader.maxBodyCharacters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : text
                case .failed:
                    return nil
                case .fetching:
                    continue
                }
            }
        } catch {}
        return nil
    }

    static func source(_ message: MessageSummary, in detail: ConversationDetail) -> AskSource {
        let sender: String
        if let from = message.from {
            let name = from.name?.trimmingCharacters(in: .whitespaces) ?? ""
            sender = name.isEmpty ? from.email : name
        } else {
            sender = AskWording.unknownSender
        }
        return AskSource(id: message.id, thread: detail.id, sender: sender, subject: detail.subject, date: message.date)
    }

    func conversation(_ thread: ThreadKey, accounts: [Account]) async throws -> AskRetrieval {
        let account = accounts.first { $0.id == thread.account }
        let policyKey = account.map { AICenter.policyKey(email: $0.email) }
        guard let detail = try await Self.firstValue(data.threadDetail(thread)) ?? nil, !detail.messages.isEmpty else {
            throw AskRetrievalError.conversationGone
        }
        let loader = AIThreadLoader(data: data, bodyTimeout: conversationBodyTimeout)
        guard let context = await loader.load(thread, account: account, accountKey: policyKey, trigger: .user,
                                              bodies: .all) else {
            throw AskRetrievalError.conversationGone
        }
        let inputs = Array(context.input.messages.suffix(Self.conversationMessages))
        let messageKeys = Array(context.messageKeys.suffix(Self.conversationMessages))
        let summaries = Dictionary(detail.messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var keys: [String: MessageKey] = [:]
        var sources: [String: AskSource] = [:]
        for (input, key) in zip(inputs, messageKeys) {
            keys[input.messageKey] = key
            if let summary = summaries[key] { sources[input.messageKey] = Self.source(summary, in: detail) }
        }
        return AskRetrieval(candidates: inputs, keys: keys, sources: sources, otherThreads: [], queryText: nil,
                            queryAccount: thread.account, gmailQuery: nil, searched: detail.subject,
                            planLine: AskWording.read(subject: detail.subject, messages: inputs.count),
                            completeness: nil)
    }

    static func firstValue<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async throws -> T? {
        for try await value in stream { return value }
        return nil
    }
}
