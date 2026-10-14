import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import Testing

@Suite struct FakeGmailTests {
    @Test func listsThreadsNewestFirstWithPageTokens() async throws {
        let gmail = FakeGmail()
        let threads = await gmail.seedInbox(count: 7)
        var seen: [String] = []
        var token: String?
        repeat {
            let page = try await gmail.listThreads(ListQuery(labelIDs: ["INBOX"], pageToken: token, maxResults: 3),
                                                   priority: .sync)
            seen += page.threads?.map(\.id) ?? []
            #expect(page.resultSizeEstimate == 7)
            token = page.nextPageToken
        } while token != nil
        #expect(seen == threads.reversed())
        await gmail.deliver(subject: "Re", threadID: threads[0])
        let top = try await gmail.listThreads(ListQuery(labelIDs: ["INBOX"], maxResults: 1), priority: .sync)
        #expect(top.threads?.first?.id == threads[0])
    }

    @Test func historyRecordsEveryChangeInOrderAfterTheStartID() async throws {
        let gmail = FakeGmail()
        let start = try await gmail.getProfile(priority: .sync).historyId
        let (m1, t1) = await gmail.deliver(subject: "One")
        await gmail.simulateWebArchive(threadID: t1)
        await gmail.modifyLabels(messageID: m1, add: ["STARRED"])
        await gmail.deleteMessagePermanently(m1)
        let all = try await gmail.listHistory(startHistoryID: HistoryID(UInt64(start)!), pageToken: nil, types: [],
                                              labelID: nil, maxResults: 500, priority: .sync)
        let records = all.history ?? []
        #expect(records.count == 4)
        #expect(records.map(\.id) == records.map(\.id).sorted { UInt64($0)! < UInt64($1)! })
        #expect(records[0].messagesAdded?.first?.message.labelIds == ["INBOX", "UNREAD"])
        #expect(records[1].labelsRemoved?.first?.labelIds == ["INBOX"])
        #expect(records[1].labelsRemoved?.first?.message.labelIds == ["UNREAD"])
        #expect(records[2].labelsAdded?.first?.labelIds == ["STARRED"])
        #expect(records[3].messagesDeleted?.first?.message.id == m1)
        #expect(all.historyId == records[3].id)
        let added = try await gmail.listHistory(startHistoryID: HistoryID(UInt64(start)!), pageToken: nil,
                                                types: [.messageAdded], labelID: nil, maxResults: 500, priority: .sync)
        #expect(added.history?.count == 1)
        let page1 = try await gmail.listHistory(startHistoryID: HistoryID(UInt64(start)!), pageToken: nil, types: [],
                                                labelID: nil, maxResults: 3, priority: .sync)
        #expect(page1.history?.count == 3 && page1.nextPageToken != nil)
        let page2 = try await gmail.listHistory(startHistoryID: HistoryID(UInt64(start)!), pageToken: page1.nextPageToken,
                                                types: [], labelID: nil, maxResults: 3, priority: .sync)
        #expect(page2.history?.count == 1 && page2.nextPageToken == nil)
        let none = try await gmail.listHistory(startHistoryID: HistoryID(UInt64(all.historyId)!), pageToken: nil,
                                               types: [], labelID: nil, maxResults: 500, priority: .sync)
        #expect(none.history == nil)
    }

    @Test func expiredHistoryThrowsHistoryExpired() async throws {
        let gmail = FakeGmail()
        await gmail.deliver()
        let current = await gmail.currentHistoryID
        await gmail.expireHistory(before: current)
        await #expect(throws: GmailError.historyExpired) {
            _ = try await gmail.listHistory(startHistoryID: HistoryID(current.rawValue - 1), pageToken: nil, types: [],
                                            labelID: nil, maxResults: 500, priority: .sync)
        }
        _ = try await gmail.listHistory(startHistoryID: current, pageToken: nil, types: [], labelID: nil,
                                        maxResults: 500, priority: .sync)
    }

    @Test func formatsAndThreadContents() async throws {
        let gmail = FakeGmail()
        let (m1, t1) = await gmail.deliver(subject: "Hi", body: "plain", html: "<b>html</b>")
        await gmail.deliver(subject: "Re: Hi", threadID: t1)
        let minimal = try await gmail.getThread(id: t1, format: .minimal, metadataHeaders: [], priority: .sync)
        #expect(minimal.messages?.count == 2 && minimal.messages?.first?.id == m1 && minimal.messages?.first?.payload == nil)
        let meta = try await gmail.getThread(id: t1, format: .metadata, metadataHeaders: ["Subject", "In-Reply-To"],
                                             priority: .sync)
        #expect(meta.messages?.last?.payload?.headers?.map(\.name) == ["Subject", "In-Reply-To"])
        #expect(meta.historyId == meta.messages?.compactMap(\.historyId).max { UInt64($0)! < UInt64($1)! })
        let full = try await gmail.getMessage(id: m1, format: .full, metadataHeaders: [], priority: .sync)
        #expect(full.payload?.mimeType == "multipart/alternative" && full.payload?.parts?.count == 2)
        await #expect(throws: GmailError.notFound("threads/nope")) {
            _ = try await gmail.getThread(id: "nope", format: .minimal, metadataHeaders: [], priority: .sync)
        }
    }

    @Test func querySubsetAndSpamTrashExclusion() async throws {
        let gmail = FakeGmail()
        let label = await gmail.addUserLabel("Clients/Acme")
        let early = Date(timeIntervalSince1970: 1_700_000_000), late = Date(timeIntervalSince1970: 1_700_100_000)
        let (_, a) = await gmail.deliver(labels: ["INBOX", label], date: early)
        let (_, b) = await gmail.deliver(labels: ["INBOX", "UNREAD"], date: late)
        let (_, c) = await gmail.deliver(labels: ["SPAM"], date: late)
        func ids(_ q: String?, labels: [String] = [], spam: Bool = false) async throws -> Set<String> {
            Set(try await gmail.listThreads(ListQuery(labelIDs: labels, q: q, includeSpamTrash: spam), priority: .sync)
                .threads?.map(\.id) ?? [])
        }
        #expect(try await ids(nil) == [a, b])
        #expect(try await ids(nil, spam: true) == [a, b, c])
        #expect(try await ids("in:spam") == [c])
        #expect(try await ids("label:Clients/Acme") == [a])
        #expect(try await ids("before:1700050000") == [a])
        #expect(try await ids("after:1700050000") == [b])
        #expect(try await ids("in:inbox is:unread") == [b])
        await #expect(throws: GmailError.self) { _ = try await ids("hello") }
    }

    @Test func faultInjectionIsDeterministicAndQuotaIsCounted() async throws {
        let gmail = FakeGmail()
        let (_, t) = await gmail.deliver()
        await gmail.failNext(.getThread, with: .server(status: 503, message: nil), count: 2)
        for expected in [true, true, false] {
            do {
                _ = try await gmail.getThread(id: t, format: .minimal, metadataHeaders: [], priority: .sync)
                #expect(!expected)
            } catch {
                #expect(expected && error as? GmailError == .server(status: 503, message: nil))
            }
        }
        _ = try await gmail.getProfile(priority: .sync)
        #expect(await gmail.callCount(.getThread) == 3)
        let getThreadUnits = await gmail.units(for: .getThread), total = await gmail.unitsUsed
        #expect(getThreadUnits == 120 && total == 121)
    }

    @Test func draftsLifecycleAndAmbiguousSend() async throws {
        let gmail = FakeGmail()
        let raw = Data("From: me@example.com\r\nTo: bob@example.com\r\nSubject: Draft\r\n\r\nBody".utf8)
        let draft = try await gmail.createDraft(rawRFC822: raw, threadID: nil)
        #expect(try await gmail.listDrafts(pageToken: nil, q: nil, maxResults: 10).drafts?.map(\.id) == [draft.id])
        await gmail.ambiguousFailureAfterCommit(.sendDraft)
        await #expect(throws: GmailError.transport(.timedOut)) { _ = try await gmail.sendDraft(id: draft.id) }
        let sent = try await gmail.listMessages(ListQuery(labelIDs: ["SENT"]), priority: .sync)
        #expect(sent.messages?.count == 1 && sent.messages?.first?.id != draft.message?.id)
        await #expect(throws: GmailError.notFound("drafts/\(draft.id)")) { _ = try await gmail.sendDraft(id: draft.id) }
        await #expect(throws: GmailError.badRequest(reason: "conflict", message: "Label name exists or conflicts")) {
            _ = try await gmail.createLabel(name: "inbox", labelListVisibility: nil, messageListVisibility: nil)
        }
    }

    @Test func metricsSinkGetsOneMetricPerCall() async throws {
        let sink = RecordingMetricsSink()
        let gmail = FakeGmail(metrics: sink)
        _ = try await gmail.getProfile(priority: .sync)
        _ = try await gmail.listLabels()
        #expect(sink.metrics.map(\.method) == ["getProfile", "labels.list"] && sink.totalUnits == 2)
    }
}
