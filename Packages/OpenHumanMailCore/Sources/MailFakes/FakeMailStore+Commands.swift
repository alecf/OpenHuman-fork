import Foundation
import MailModel
import OpenHumanCore

extension FakeMailStore {
    public func apply(_ command: MailCommand) async throws -> UndoToken {
        let now = self.now
        let receipt = try mutate { s -> FakeReceipt in
            try checkWritable(&s)
            let receipt = try s.perform([command], now: now)
            if options.remoteAck == .immediate { s.acknowledge(receipt.operations, now: now) }
            return receipt
        }
        scheduleAcknowledgement(receipt.operations)
        return receipt.token
    }

    public func undo(_ token: UndoToken) async throws -> UndoToken? {
        let receipt = try FakeReceipt.decode(token)
        let now = self.now
        let result = try mutate { s -> FakeReceipt? in
            try checkWritable(&s)
            let result = try s.undo(receipt, now: now)
            if let result, options.remoteAck == .immediate { s.acknowledge(result.operations, now: now) }
            return result
        }
        if let result { scheduleAcknowledgement(result.operations) }
        return result?.token
    }

    func scheduleAcknowledgement(_ operations: [Int64]) {
        guard case .after(let delay) = options.remoteAck, !operations.isEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            let now = self.now
            self.mutate { $0.acknowledge(operations, now: now) }
        }
    }

    public func createDraft(_ input: DraftInput) async throws -> (key: DraftKey, version: Int) {
        let now = self.now
        return try mutate { s in
            try checkWritable(&s)
            var (fields, thread, replyTo) = try s.skeleton(input)
            if let content = input.content { fields = FakeReplySkeleton.overlay(content, on: fields) }
            let id = s.ids.nextDraft()
            s.drafts[id] = FakeDraft(id: id, account: input.account, thread: thread, mode: input.mode, replyTo: replyTo,
                                     fields: fields, source: .user, review: .none, status: .editing, version: 1,
                                     syncedVersion: 0, hasRemoteConflict: false, updatedAt: now)
            if let thread {
                s.draftsByThread[thread, default: []].insert(id)
                s.invalidate([thread])
            }
            return (id, 1)
        }
    }

    public func draftSkeleton(_ input: DraftInput) async throws -> DraftFields? {
        guard input.mode != .new else { return nil }
        return try state.withLock { s in try s.skeleton(input).fields }
    }

    public func updateDraft(_ key: DraftKey, _ fields: DraftFields, expectedVersion: Int?) async throws -> Int {
        let now = self.now
        return try mutate { s in
            try checkWritable(&s)
            guard var draft = s.drafts[key] else { throw MailPortError.notFound("draft") }
            guard draft.status != .sending else { throw MailPortError.conflict("the draft is being sent") }
            if let expectedVersion, expectedVersion != draft.version {
                throw MailPortError.conflict("draft version \(draft.version), expected \(expectedVersion)")
            }
            draft.fields = fields
            draft.version += 1
            draft.updatedAt = now
            s.drafts[key] = draft
            if let thread = draft.thread { s.invalidate([thread]) }
            return draft.version
        }
    }

    public func flushDraft(_ key: DraftKey) async throws {
        try mutate { s in
            try checkWritable(&s)
            guard var draft = s.drafts[key] else { throw MailPortError.notFound("draft") }
            draft.syncedVersion = draft.version
            if draft.gmailDraftID == nil { draft.gmailDraftID = s.nextGmailDraftID() }
            s.drafts[key] = draft
        }
    }

    public func discardDraft(_ key: DraftKey) async throws {
        try mutate { s in
            try checkWritable(&s)
            guard s.drafts[key] != nil else { throw MailPortError.notFound("draft") }
            s.removeDraft(key)
        }
    }

    public func setReviewState(_ key: DraftKey, _ state: DraftReview) async throws {
        let now = self.now
        try mutate { s in
            try checkWritable(&s)
            guard var draft = s.drafts[key] else { throw MailPortError.notFound("draft") }
            draft.review = state
            draft.updatedAt = now
            s.drafts[key] = draft
            if let thread = draft.thread { s.invalidate([thread]) }
        }
    }

    public func resolveDraftConflict(_ key: DraftKey, _ resolution: DraftConflictResolution) async throws {
        let now = self.now
        try mutate { s in
            try checkWritable(&s)
            guard var draft = s.drafts[key] else { throw MailPortError.notFound("draft") }
            guard draft.hasRemoteConflict else { return }
            draft.hasRemoteConflict = false
            if resolution == .takeRemote, let snapshot = draft.agentSnapshot {
                draft.fields = snapshot
                draft.version += 1
            }
            draft.updatedAt = now
            s.drafts[key] = draft
        }
    }

    public func send(_ key: DraftKey, undoWindow: Duration) async throws -> SendToken {
        let now = self.now
        let held = try mutate { s -> HeldSend in
            try checkWritable(&s, send: true)
            guard var draft = s.drafts[key] else { throw MailPortError.notFound("draft") }
            guard draft.status != .sending else { throw MailPortError.conflict("already sending") }
            guard !draft.fields.to.isEmpty || !draft.fields.cc.isEmpty || !draft.fields.bcc.isEmpty else {
                throw MailPortError.conflict("the draft has no recipients")
            }
            draft.status = .sending
            draft.sendStamp = nil
            draft.updatedAt = now
            s.drafts[key] = draft
            let held = HeldSend(id: s.nextHeld, draft: key, sendAfter: now.addingTimeInterval(undoWindow.seconds))
            s.nextHeld += 1
            s.held[held.id] = held
            if let thread = draft.thread { s.invalidate([thread]) }
            return held
        }
        if options.heldSends == .realTime {
            Task { [weak self] in
                try? await Task.sleep(for: undoWindow)
                guard let self else { return }
                let now = self.now
                self.mutate { $0.completeHeld(held.id, now: now, byOtherInstall: false) }
            }
        }
        let payload = (try? JSONEncoder().encode(held)) ?? Data()
        return SendToken(draft: key, sendAfter: held.sendAfter, payload: payload)
    }

    public func cancelSend(_ token: SendToken) async throws -> Bool {
        let held = try JSONDecoder().decode(HeldSend.self, from: token.payload)
        let now = self.now
        return mutate { s in
            guard s.held.removeValue(forKey: held.id) != nil, var draft = s.drafts[held.draft] else { return false }
            draft.status = .editing
            draft.updatedAt = now
            s.drafts[held.draft] = draft
            if let thread = draft.thread { s.invalidate([thread]) }
            return true
        }
    }

    public func sendNow(_ token: SendToken) async throws -> Bool {
        let held = try JSONDecoder().decode(HeldSend.self, from: token.payload)
        let now = self.now
        return mutate { $0.completeHeld(held.id, now: now, byOtherInstall: false) }
    }

    public func scheduleSend(_ key: DraftKey, at: Date) async throws {
        try await scheduleSend(key, at: at, condition: .always)
    }

    public func scheduleSend(_ key: DraftKey, at: Date, condition: SendLaterCondition) async throws {
        let now = self.now
        try mutate { s in
            try checkWritable(&s)
            guard var draft = s.drafts[key] else { throw MailPortError.notFound("draft") }
            guard draft.status != .sending else { throw MailPortError.conflict("already sending") }
            guard draft.source == .user || draft.review == .approved else {
                throw MailPortError.conflict("an agent draft needs your review before it can be scheduled")
            }
            guard condition == .always || draft.thread != nil else {
                throw MailPortError.conflict("only a reply can wait for no reply")
            }
            draft.status = .scheduled
            draft.sendStamp = ScheduleStamp.format(at)
            draft.sendCondition = condition
            draft.lastError = nil
            draft.version += 1
            draft.updatedAt = now
            s.drafts[key] = draft
            if let thread = draft.thread { s.invalidate([thread]) }
        }
    }

    public func sendCondition(_ key: DraftKey) -> SendLaterCondition? {
        state.withLock { s in s.drafts[key].flatMap { $0.status == .scheduled ? $0.sendCondition : nil } }
    }

    public func cancelScheduledSend(_ key: DraftKey) async throws {
        let now = self.now
        try mutate { s in
            try checkWritable(&s)
            guard var draft = s.drafts[key] else { throw MailPortError.notFound("draft") }
            guard draft.status == .scheduled else { return }
            draft.status = .editing
            draft.sendStamp = nil
            draft.sendCondition = .always
            draft.version += 1
            draft.updatedAt = now
            s.drafts[key] = draft
            if let thread = draft.thread { s.invalidate([thread]) }
        }
    }

    public func fetchDraftNow(_ account: AccountID, gmailDraftID: GmailDraftID) async throws -> DraftKey? {
        try state.withLock { s in
            guard !s.offline else { throw MailPortError.unavailable("offline") }
            return s.drafts.values.first { $0.account == account && $0.gmailDraftID == gmailDraftID }?.id
        }
    }

    public func fetchThreadNow(_ account: AccountID, gmailThreadID: GmailThreadID) async throws -> ThreadKey? {
        try state.withLock { s in
            guard !s.offline else { throw MailPortError.unavailable("offline") }
            return (s.threadOrder[account] ?? []).first { $0.gmailThreadID == gmailThreadID }
        }
    }

    public func createLabel(_ account: AccountID, name: String, applyTo: [ThreadKey]) async throws -> UndoToken {
        let now = self.now
        let receipt = try mutate { s -> FakeReceipt in
            try checkWritable(&s)
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { throw MailPortError.invalidQuery("a label needs a name") }
            if ScheduleLabel.parse(trimmed) != .notOurs { throw MailPortError.reservedLabel(trimmed) }
            guard s.accounts[account] != nil else { throw MailPortError.notFound("account") }
            let id = s.ensureLabel(trimmed, account: account)
            guard !applyTo.isEmpty else { return FakeReceipt(operations: [], undo: [], redo: []) }
            let receipt = try s.perform([.modifyLabels(applyTo, add: [id], remove: [])], now: now)
            if options.remoteAck == .immediate { s.acknowledge(receipt.operations, now: now) }
            return receipt
        }
        scheduleAcknowledgement(receipt.operations)
        return receipt.token
    }

    public func upsertSnippet(_ snippet: SnippetInfo) async throws -> SnippetInfo {
        try mutate { s in
            try checkWritable(&s)
            var stored = snippet
            if stored.isNew {
                stored.id = s.ids.nextSnippet()
            } else if let existing = s.snippets[stored.id] {
                stored.useCount = existing.useCount
            } else {
                throw MailPortError.notFound("snippet")
            }
            s.snippets[stored.id] = stored
            return stored
        }
    }

    public func deleteSnippet(_ id: SnippetInfo.ID) async throws {
        try mutate { s in
            try checkWritable(&s)
            guard s.snippets.removeValue(forKey: id) != nil else { throw MailPortError.notFound("snippet") }
        }
    }

    public func storeSnippetAttachment(_ file: URL, mimeType: String) async throws -> SnippetAttachmentInfo {
        try state.withLock { s in try checkWritable(&s) }
        guard let data = try? Data(contentsOf: file) else { throw MailPortError.notFound("snippet file") }
        guard data.count <= SnippetAttachmentRules.maxFileBytes else { throw MailPortError.limitExceeded("snippet file size") }
        return SnippetAttachmentInfo(contentHash: Self.fakeContentHash(data), filename: file.lastPathComponent,
                                     mimeType: mimeType, size: data.count, fileURL: file)
    }

    public func storeSnippetAttachment(data: Data, filename: String, mimeType: String) async throws -> SnippetAttachmentInfo {
        try state.withLock { s in try checkWritable(&s) }
        guard data.count <= SnippetAttachmentRules.maxFileBytes else { throw MailPortError.limitExceeded("snippet file size") }
        let hash = Self.fakeContentHash(data)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-snippet-files", isDirectory: true)
            .appendingPathComponent(hash, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = filename.replacingOccurrences(of: "/", with: "_")
        let url = dir.appendingPathComponent(name.isEmpty ? "attachment" : name)
        try? data.write(to: url)
        return SnippetAttachmentInfo(contentHash: hash, filename: url.lastPathComponent, mimeType: mimeType, size: data.count,
                                     fileURL: url)
    }

    static func fakeContentHash(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let part = String(hash, radix: 16)
        let padded = String(repeating: "0", count: 16 - part.count) + part
        return String(repeating: padded, count: 4)
    }

    public func recordSnippetUse(_ id: SnippetInfo.ID) async throws {
        try mutate { s in
            guard s.snippets[id] != nil else { throw MailPortError.notFound("snippet") }
            s.snippets[id]?.useCount += 1
        }
    }

    public func unsubscribe(_ key: MessageKey) async throws {
        try mutate { s in
            if let failure = s.failNextCommand {
                s.failNextCommand = nil
                throw failure
            }
            guard s.safeMode == .normal else { throw MailPortError.blockedBySafeMode }
            guard let threadKey = s.messageIndex[key],
                  let message = s.threads[threadKey]?.messages.first(where: { $0.summary.id == key }) else {
                throw MailPortError.notFound("message")
            }
            guard case .oneClick = message.unsubscribe else { throw MailPortError.notFound("one-click unsubscribe") }
            s.unsubscribeRequests.append(key)
        }
    }

    public func upsertSplit(_ split: SplitDefinition) async throws -> SplitKey {
        try mutate { s in
            try checkWritable(&s)
            guard var account = s.accounts[split.account] else { throw MailPortError.notFound("account") }
            let rule = try FakeQuery.parse(split.ruleText, mode: .split)
            let name = split.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw MailPortError.invalidQuery("a split needs a name") }
            if account.splits.contains(where: { $0.id != split.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw MailPortError.conflict("a split named \(name) exists")
            }
            let id: SplitKey
            var ordered = account.splits.sorted { $0.position < $1.position }
            if let existing = split.id {
                guard let index = ordered.firstIndex(where: { $0.id == existing }) else {
                    throw MailPortError.notFound("split")
                }
                id = existing
                ordered.remove(at: index)
                let target = min(max(split.position ?? index, 0), ordered.count)
                ordered.insert(SplitInfo(id: id, account: split.account, name: name, position: target,
                                         ruleText: split.ruleText, enabled: split.enabled), at: target)
            } else {
                id = s.ids.nextSplit()
                let target = min(max(split.position ?? ordered.count, 0), ordered.count)
                ordered.insert(SplitInfo(id: id, account: split.account, name: name, position: target,
                                         ruleText: split.ruleText, enabled: split.enabled), at: target)
            }
            account.splits = ordered.enumerated().map { index, info in
                SplitInfo(id: info.id, account: info.account, name: info.name, position: index, ruleText: info.ruleText,
                          enabled: info.enabled)
            }
            account.splitRules[id] = rule
            s.accounts[split.account] = account
            s.invalidateAccount(split.account)
            return id
        }
    }

    public func deleteSplit(_ account: AccountID, _ key: SplitKey) async throws {
        try mutate { s in
            try checkWritable(&s)
            guard var state = s.accounts[account], state.splits.contains(where: { $0.id == key }) else {
                throw MailPortError.notFound("split")
            }
            state.splits = state.splits.filter { $0.id != key }.sorted { $0.position < $1.position }.enumerated().map {
                SplitInfo(id: $1.id, account: $1.account, name: $1.name, position: $0, ruleText: $1.ruleText,
                          enabled: $1.enabled)
            }
            state.splitRules.removeValue(forKey: key)
            s.accounts[account] = state
            s.invalidateAccount(account)
        }
    }

    public func reorderSplits(_ account: AccountID, _ order: [SplitKey]) async throws {
        try mutate { s in
            try checkWritable(&s)
            guard var state = s.accounts[account] else { throw MailPortError.notFound("account") }
            guard Set(order) == Set(state.splits.map(\.id)), order.count == state.splits.count else {
                throw MailPortError.conflict("the order must list every split once")
            }
            let byID = Dictionary(uniqueKeysWithValues: state.splits.map { ($0.id, $0) })
            state.splits = order.enumerated().compactMap { index, id in
                byID[id].map { SplitInfo(id: $0.id, account: $0.account, name: $0.name, position: index,
                                         ruleText: $0.ruleText, enabled: $0.enabled) }
            }
            s.accounts[account] = state
            s.invalidateAccount(account)
        }
    }

    public func dismissFailedOperation(_ id: FailedOperationInfo.ID) async throws {
        mutate { s in s.failures.removeAll { $0.id == id } }
    }
}

extension State {
    func skeleton(_ input: DraftInput) throws -> (fields: DraftFields, thread: ThreadKey?, replyTo: GmailMessageID?) {
        guard let account = accounts[input.account] else { throw MailPortError.notFound("account") }
        let identity = account.account.sendAs.first(where: \.isDefault) ?? account.account.sendAs.first
        let from = EmailAddress(name: identity?.name ?? account.account.displayName,
                                email: identity?.email ?? account.account.email)
        guard input.mode != .new else { return (DraftFields(from: from), nil, nil) }
        guard let key = input.replyTo, let threadKey = messageIndex[key],
              let original = threads[threadKey]?.messages.first(where: { $0.summary.id == key }),
              let subject = threads[threadKey]?.subject else {
            throw MailPortError.notFound("the message to reply to")
        }
        let fields = FakeReplySkeleton.fields(mode: input.mode, original: original, subject: subject, from: from,
                                              me: account.me)
        return (fields, threadKey, key.gmailMessageID)
    }
}

extension Duration {
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

enum FakeReplySkeleton {
    static func fields(mode: DraftMode, original: FakeMessage, subject: String, from: EmailAddress,
                       me: Set<String>) -> DraftFields {
        let message = original.summary
        let sender = message.from
        var to: [EmailAddress] = []
        var cc: [EmailAddress] = []
        switch mode {
        case .reply:
            to = original.isFromMe ? message.to : [sender].compactMap { $0 }
        case .replyAll:
            let everyone = [sender].compactMap { $0 } + message.to
            to = dedupe(everyone.filter { !me.contains($0.email.lowercased()) })
            cc = dedupe(message.cc.filter { !me.contains($0.email.lowercased()) && !to.contains($0) })
        case .forward, .new:
            break
        }
        let prefix = mode == .forward ? "Fwd: " : "Re: "
        let hasPrefix = subject.lowercased().hasPrefix(prefix.lowercased())
        let newSubject = hasPrefix ? subject : prefix + subject
        let who = sender.map { "\(escape($0.name ?? $0.email)) &lt;\(escape($0.email))&gt;" } ?? "someone"
        let date = message.date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        let quoted = escape(original.content.text ?? message.snippet).replacingOccurrences(of: "\n", with: "<br>")
        let header = mode == .forward
            ? "---------- Forwarded message ---------<br>From: \(who)<br>Date: \(date)<br>Subject: \(escape(subject))<br><br>"
            : "On \(date), \(who) wrote:<br>"
        let html = """
        <div class="gmail_quote" data-oh-quote="1"><div dir="ltr" class="gmail_attr">\(header)</div>\
        <blockquote class="gmail_quote" style="margin:0 0 0 .8ex;border-left:1px #ccc solid;padding-left:1ex">\(quoted)</blockquote></div>
        """
        let plainWho = sender.map { "\($0.name ?? $0.email) <\($0.email)>" } ?? "someone"
        let text = "\n\n" + (mode == .forward ? "---------- Forwarded message ---------\n" : "On \(date), \(plainWho) wrote:\n")
            + (original.content.text ?? message.snippet).split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }.joined(separator: "\n")
        let attachments = mode == .forward
            ? message.attachments.filter { !$0.isInline }.map {
                DraftAttachmentInfo(sourceAttachmentID: $0.id, filename: $0.filename, mimeType: $0.mimeType, size: $0.size)
            }
            : []
        return DraftFields(from: from, to: to, cc: cc, subject: newSubject, bodyHTML: html, bodyText: text,
                           attachments: attachments)
    }

    static func overlay(_ content: DraftFields, on skeleton: DraftFields) -> DraftFields {
        var result = skeleton
        if let from = content.from { result.from = from }
        if !content.to.isEmpty { result.to = content.to }
        if !content.cc.isEmpty { result.cc = content.cc }
        if !content.bcc.isEmpty { result.bcc = content.bcc }
        if !content.subject.isEmpty { result.subject = content.subject }
        if !content.bodyHTML.isEmpty { result.bodyHTML = content.bodyHTML + skeleton.bodyHTML }
        if let text = content.bodyText { result.bodyText = text + (skeleton.bodyText ?? "") }
        if !content.attachments.isEmpty { result.attachments = content.attachments }
        return result
    }

    static func dedupe(_ addresses: [EmailAddress]) -> [EmailAddress] {
        var seen = Set<String>()
        return addresses.filter { seen.insert($0.email.lowercased()).inserted }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
