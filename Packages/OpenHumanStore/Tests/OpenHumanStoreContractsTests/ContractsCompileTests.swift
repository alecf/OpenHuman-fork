import Foundation
import Testing
import OpenHumanCore
import OpenHumanStore

enum Fixtures {
    static let account = AccountID(1)
    static let date = Date(timeIntervalSince1970: 1_791_795_600)
    static let ref = ThreadRef(accountID: account, rowID: ThreadRowID(rawValue: 7), gmailThreadID: GmailThreadID("t7"))
    static let address = EmailAddress(name: "Ana", email: "ana@example.com")
    static let content = DraftContent(from: address, to: [address], cc: [], bcc: [], subject: "Hi", bodyHTML: "<p>x</p>",
                                      bodyText: "x", attachments: [
                                          DraftAttachment(localPath: "Drafts/u/a.pdf", filename: "a.pdf",
                                                          mimeType: "application/pdf", size: 3, isInline: false),
                                      ])
    static let item = ThreadListItem(
        id: ThreadRowID(rawValue: 7), ref: ref, subject: "s", snippet: "p", participantsDisplay: "Ana",
        participants: [ParticipantSummary(name: "Ana", email: "ana@example.com", isMe: false, hasUnread: true)],
        messageCount: 2, unreadCount: 1, isUnread: true, draftCount: 0, attachmentCount: 0, isStarred: false,
        isImportant: true, userLabelIDs: [LabelRowID(rawValue: 3)], lastMessageAt: date, sortAt: date,
        snoozedUntil: nil, reminderAt: nil, scheduledSendAt: nil, hasPendingChanges: false)
    static let label = LabelItem(id: LabelRowID(rawValue: 3), accountID: account, key: "Label_1", kind: .user, name: "Work",
                                 displayName: "Work", isHidden: false, position: 0, totalThreads: 1, unreadThreads: 1)
    static let attachment = AttachmentItem(id: 1, messageRowID: MessageRowID(rawValue: 9), partID: "1", filename: "a.pdf",
                                           mimeType: "application/pdf", size: 3, isInline: false)
    static let message = MessageItem(
        id: MessageRowID(rawValue: 9), gmailMessageID: GmailMessageID("m9"), date: date, from: address, to: [address],
        cc: [], bcc: [], replyTo: [], subject: "s", snippet: "p", labelIDs: [GmailLabelID("INBOX")], isUnread: true,
        isStarred: false, isDraft: false, isFromMe: false, inTrash: false, inSpam: false, references: [],
        hasCalendarInvite: false, bodyState: .stored, attachments: [attachment])
    static let draft = DraftListItem(
        id: DraftID("d1"), accountID: account, thread: ref, composeMode: .reply, replyToMessageID: GmailMessageID("m9"),
        content: content, origin: .cli, reviewState: .pending, state: .editing, isDirty: true, hasRemoteConflict: false,
        agentNote: "note", agentSnapshot: content, updatedAt: date)
    static let operation = OperationItem(
        id: OperationID(rawValue: 5), accountID: account, kind: .modifyLabels,
        payload: .modifyLabels(ids: [GmailMessageID("m9")], add: [], remove: [GmailLabelID("INBOX")], addNames: []),
        status: .pending, attempts: 0, notBefore: date, nextRetryAt: date, origin: .app, createdAt: date, updatedAt: date)
    static let upsert = MessageUpsert(
        gmailMessageID: GmailMessageID("m9"), gmailThreadID: GmailThreadID("t7"), historyID: HistoryID(10),
        internalDate: date, labelIDs: [GmailLabelID("INBOX")], snippet: "p", sizeEstimate: 100,
        headers: MessageHeaderFields(subject: "s", from: address, to: [], cc: [], bcc: [], replyTo: [], references: []),
        body: MessageBodyUpsert(hasCalendarInvite: false, decodeWarnings: [], searchText: "x"),
        attachments: [AttachmentUpsert(partID: "1", filename: "a.pdf", mimeType: "application/pdf", size: 3, isInline: false)])
}

@Suite struct StoreContractsCompileTests {
    @Test func readModels() {
        let page = ThreadPage(items: [Fixtures.item], nextCursor: ThreadCursor(sortAt: 1, tid: 7))
        #expect(page.items.count == 1)
        let counts = MailboxCounts(accountID: Fixtures.account, byLabel: [LabelRowID(rawValue: 3): LabelCount(total: 1, unread: 1)],
                                   inboxUnread: 1, splitUnread: [SplitID("s"): 1], draftsCount: 0, pendingReviewCount: 1,
                                   failedOperationCount: 0)
        #expect(counts.inboxUnread == 1)
        let body = MessageBody(messageRowID: MessageRowID(rawValue: 9), html: "<p>", text: nil, hasRemoteContent: true,
                               inlineParts: ["cid": Fixtures.attachment], decodeWarnings: [])
        #expect(body.hasRemoteContent)
        let detail = ThreadDetail(thread: Fixtures.item, messages: [Fixtures.message], labels: [Fixtures.label],
                                  drafts: [Fixtures.draft],
                                  snooze: SnoozeInfo(wakeAt: Fixtures.date, labelName: "OpenHuman/Snoozed/20261012T0900Z",
                                                     stampLabelCount: 1),
                                  reminder: ReminderInfo(id: "r1", dueAt: Fixtures.date, condition: .ifNoReply))
        #expect(detail.messages.first?.attachments.count == 1)
        let accountItem = AccountItem(id: Fixtures.account, email: "me@example.com", position: 0, status: .active,
                                      sendAs: [SendAsIdentity(email: "me@example.com", isDefault: true, isPrimary: true)])
        #expect(accountItem.status == .active)
        _ = ContactSuggestion(name: nil, email: "a@b.c", score: 1)
        _ = SnippetItem(id: "s", name: "Thanks", bodyHTML: "Thanks {{name}}", variables: [SnippetVariable(name: "name")], useCount: 0)
        _ = SnippetItem(id: "s2", name: "Terms", bodyHTML: "See attached", variables: [], useCount: 0,
                        to: [EmailAddress(email: "a@example.com")], cc: [], bcc: [],
                        attachments: [SnippetAttachment(contentHash: String(repeating: "0", count: 64), filename: "t.pdf",
                                                        mimeType: "application/pdf", size: 1)])
        _ = SnippetAttachmentLimits.maxTotalBytes
        _ = SplitItem(id: SplitID("s"), accountID: Fixtures.account, labelRowID: LabelRowID(rawValue: 4), name: "VIP", position: 0,
                      ruleText: "from:@acme.example", rule: .or([.from("@acme.example"), .not(.isUnread)]), enabled: true,
                      unreadThreads: 0, totalThreads: 0)
        let status = SyncStatus(accountID: Fixtures.account, phase: .incremental, historyID: HistoryID(1), backfillComplete: false,
                                consecutiveFailures: 0,
                                owner: LeaseInfo(ownerID: "w", kind: "app", pid: 1, heartbeatAt: Fixtures.date, isLive: true),
                                pendingOperations: 0, failedOperations: 0)
        #expect(status.phase.rawValue == "incremental")
        #expect(StoreError.limitExceeded("labels") != StoreError.reservedLabel("x"))
        #expect(MailboxView.split(Fixtures.account, SplitID("s")) != MailboxView.splitOther(Fixtures.account))
        #expect(BodyState.metadataOnly.rawValue == 1)
        #expect(ComposeMode.replyAll.rawValue == "reply_all")
    }

    @Test func importanceTypes() throws {
        let definition = ImportanceRuleDefinition(accountID: Fixtures.account, kind: .sender, value: "ana@example.com",
                                                  effect: .exemptFromSplit, splitID: SplitID("s"), source: .ai)
        let rule = ImportanceRule(id: ImportanceRuleID(rawValue: 3), definition: definition, createdAt: Fixtures.date,
                                  updatedAt: Fixtures.date)
        let receipt = ImportanceRuleReceipt(ruleIDs: [rule.id], undo: ImportanceRuleEdit(insert: [], delete: [rule]))
        #expect(try JSONDecoder().decode(ImportanceRuleReceipt.self, from: JSONEncoder().encode(receipt)) == receipt)
        #expect(ImportanceRuleID(rawValue: 1) < rule.id)
        let reason = ImportanceReason(thread: Fixtures.ref, importance: .important, basis: .rule, rule: rule, isInInbox: true,
                                      placementSplitID: SplitID("s"), placementName: "Important", chipSplitIDs: [SplitID("p")],
                                      exemptions: [], sender: "ana@example.com")
        #expect(reason.line.hasPrefix("In Important: ") && ImportanceBasis.importanceSplit.rawValue == "importance_split")
        let counts = ImportanceCounts(accountID: Fixtures.account, important: 1, importantUnread: 1, normal: 2, suppressed: 0)
        #expect(counts.importantUnread == 1)
        let document = ImportanceRulesDocument(rules: [
            ExportedImportanceRule(account: "me@example.com", kind: .keyword, value: "contract", effect: .neverImportant,
                                   createdAt: Fixtures.date),
        ])
        #expect(try ImportanceRulesDocument(json: document.encodedJSON()) == document && document.version == 1)
        _ = ImportanceImportSummary(added: 1, replaced: 0, unchanged: 0, skipped: 0)
        let facts = ImportanceFacts(accountID: Fixtures.account, messages: [
            ImportanceMessageFacts(from: Fixtures.address, to: [], cc: [], date: Fixtures.date, isFromMe: false, isUnread: true,
                                   labelIDs: [GmailLabelID("INBOX")], subject: "Contract", text: "please sign"),
        ])
        #expect(KeywordImportanceMatcher().matches(facts, argument: "sign"))
        #expect(ImportanceMatchers.matcher(id: "keyword") != nil)
        #expect(ThreadImportance.allCases.count == 3 && ImportanceMatchKind.allCases.count == 5)
        #expect(ImportanceEffect.neverImportant.rawValue == "never_important" && ImportanceRuleSource.ai.rawValue == "ai")
        let item = ThreadListItem(
            id: ThreadRowID(rawValue: 7), ref: Fixtures.ref, subject: "s", snippet: "p", participantsDisplay: "Ana",
            participants: [], messageCount: 1, unreadCount: 0, isUnread: false, draftCount: 0, attachmentCount: 0,
            isStarred: false, isImportant: false, userLabelIDs: [], lastMessageAt: Fixtures.date, sortAt: Fixtures.date,
            hasPendingChanges: false, importance: .important, splitChipIDs: [LabelRowID(rawValue: 5)])
        #expect(item.importance == .important && Fixtures.item.importance == .normal && Fixtures.item.splitChipIDs.isEmpty)
        let split = SplitItem(id: SplitID("s"), accountID: Fixtures.account, labelRowID: LabelRowID(rawValue: 4), name: "Important",
                              position: 0, ruleText: "is:important", rule: .isImportant, enabled: true, unreadThreads: 0,
                              totalThreads: 0, isImportanceSplit: true)
        #expect(split.isImportanceSplit)
    }

    @Test func repositoryAndOptions() {
        let location = StoreLocation(directory: URL(fileURLWithPath: "/tmp/oh"))
        #expect(location.databaseURL.lastPathComponent == "mail.sqlite")
        let options = StoreOptions(location: location, processKind: .cli, appVersion: "0.1.0")
        #expect(!options.readOnly && !options.observeExternalChanges && !options.pollOnly)
    }

    @Test func syncWritingTypes() {
        _ = LabelUpsert(gmailLabelID: GmailLabelID("Label_1"), name: "Work", type: "user")
        let delta = LabelDelta(gmailMessageID: GmailMessageID("m9"), historyID: HistoryID(11), added: [], removed: [GmailLabelID("UNREAD")])
        #expect(delta.fullSetIfKnown == nil)
        _ = RemoteDraftUpsert(gmailDraftID: GmailDraftID("r1"), gmailMessageID: GmailMessageID("m1"), gmailThreadID: GmailThreadID("t1"),
                              content: Fixtures.content, extraHeaders: ["X-OpenHuman-Origin": "agent"])
        _ = UpsertResult(inserted: 1, updated: 0, skippedStale: 0, skippedTombstoned: 0, touchedThreads: [ThreadRowID(rawValue: 7)],
                         unknownLabelIDs: [])
        var update = SyncStateUpdate()
        update.phase = .inboxReady
        #expect(update.clearLastError == false && update.incrementFailures == false)
        update.incrementFailures = true
        let log = SyncLogEntry(accountID: Fixtures.account, startedAt: Fixtures.date, kind: "incremental")
        #expect(log.requests == 0)
        #expect(Fixtures.upsert.headers?.subject == "s")
    }

    @Test func mutationsQueueScheduling() throws {
        let action = MailAction.snooze([Fixtures.ref], until: Fixtures.date)
        let receipt = ActionReceipt(operationIDs: [OperationID(rawValue: 5)], undo: .unsnooze([Fixtures.ref]))
        let data = try JSONEncoder().encode(receipt)
        #expect(try JSONDecoder().decode(ActionReceipt.self, from: data) == receipt)
        #expect(action != .unsnooze([Fixtures.ref]))
        _ = SendReceipt(draftID: DraftID("d1"), sendOperationID: OperationID(rawValue: 6), sendAfter: Fixtures.date)
        #expect(DraftConflictChoice.keepLocal != .takeRemote)
        #expect(OperationOrigin.scheduler.rawValue == "scheduler")
        let outcomes: [OperationOutcome] = [.labelsApplied, .messagesReturned([Fixtures.upsert]),
                                            .draftSaved(gmailDraftID: GmailDraftID("r"), gmailMessageID: GmailMessageID("m"), version: 2),
                                            .draftDeleted, .sent(Fixtures.upsert), .labelCreated(LabelUpsert(gmailLabelID: GmailLabelID("L"), name: "n", type: "user"))]
        #expect(outcomes.count == 6)
        #expect(Fixtures.operation.kind == .modifyLabels)
        let due = DueItems(snoozesToWake: [(Fixtures.ref, SnoozeInfo(wakeAt: Fixtures.date, stampLabelCount: 1))],
                           snoozesWokenByMail: [], snoozesToNormalize: [],
                           remindersDue: [(Fixtures.ref, ReminderInfo(id: "r", dueAt: Fixtures.date, condition: .always))],
                           scheduledSendsDue: [Fixtures.draft], overdueUndoSends: [Fixtures.operation])
        #expect(due.snoozesToWake.count == 1)
        let summary = ReminderSummary(ref: Fixtures.ref, reminder: ReminderInfo(id: "r", dueAt: Fixtures.date, condition: .ifNoReply),
                                      subject: "s")
        #expect(summary.reminder.condition == .ifNoReply)
        #expect(Set(ScheduleKind.allCases.map(\.rawValue)) == ["snooze", "send_later", "reminder"])
    }

    @Test func settingsSearchObservation() async throws {
        let key = SettingKey(name: "undo_send_seconds", defaultValue: 10, isSafetyKey: false)
        #expect(key.defaultValue == 10)
        #expect(SettingScope.account(Fixtures.account) != .global)
        let query = SearchQuery(text: "from:ana is:unread", terms: [.address(.from, "ana"), .isFlag(.unread)])
        let hit = SearchHit(thread: Fixtures.item, matchedMessageIDs: [MessageRowID(rawValue: 9)], highlight: "\u{2}ana\u{3}")
        #expect(SearchPage(hits: [hit], nextCursor: nil).hits.count == 1)
        #expect(query.terms.count == 2)
        let window = ThreadWindow(items: [Fixtures.item], hasMore: false, totalCount: 1)

        let observation = StoreObservation<ThreadWindow>(values: {
            AsyncThrowingStream { continuation in
                continuation.yield(window)
                continuation.finish()
            }
        }, current: { window })
        var received: [ThreadWindow] = []
        for try await value in observation.values() { received.append(value) }
        #expect(received == [window])
    }

    @MainActor @Test func observationStartDeliversImmediatelyAndDropsDuplicates() async throws {
        let (stream, continuation) = AsyncThrowingStream<Int, Error>.makeStream()
        let observation = StoreObservation<Int>(values: { stream }, current: { 1 })
        var seen: [Int] = []
        let token = observation.start(onError: { _ in }, onChange: { seen.append($0) })
        #expect(seen == [1])
        continuation.yield(1)
        continuation.yield(2)
        continuation.finish()
        for _ in 0..<100 where seen.count < 2 { await Task.yield() }
        #expect(seen == [1, 2])
        token.cancel()
        token.cancel()
    }
}
