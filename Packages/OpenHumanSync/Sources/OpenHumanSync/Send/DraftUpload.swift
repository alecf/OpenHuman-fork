import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

struct DraftUpload: Sendable {
    let context: DrainContext

    func run(_ op: OperationItem, draftID: DraftID, report: inout OperationDrainer.PassReport) async
        -> OperationDrainer.Decision {
        let now = context.clock.now
        let draft: DraftListItem
        do {
            guard let row = try context.store.draft(draftID) else {
                return .init(.fail(code: "draft_missing", message: "the draft no longer exists locally"))
            }
            draft = row
        } catch {
            return OperationDrainer.classify(error, now: now)
        }
        switch draft.state {
        case .sent:
            return .init(.cancel(code: "target_gone", message: "the draft was already sent"))
        case .discarded:
            if op.attempts > 0, draft.gmailDraftID == nil {
                do {
                    let account = try context.store.accounts().first { $0.id == context.account }
                    let messageID = DraftMessage.messageID(for: draft.id, from: DraftMessage.sender(draft, account: account))
                    if let orphan = try await findOrphan(messageID: messageID, report: &report) {
                        report.gmailCalls += 1
                        do { try await context.api.deleteDraft(id: orphan) } catch GmailError.notFound {}
                    }
                } catch {
                    return OperationDrainer.classify(error, now: now)
                }
            }
            return .init(.cancel(code: "target_gone", message: "the draft was discarded"))
        case .editing, .scheduled, .sending, .failed:
            break
        }
        do {
            let message = try await context.message(for: draft)
            let raw = try message.raw(forSend: false)
            let thread = draft.gmailThreadID?.rawValue
            var saved: GmailDraft
            if let existing = draft.gmailDraftID {
                do {
                    report.gmailCalls += 1
                    saved = try await context.api.updateDraft(id: existing.rawValue, rawRFC822: raw, threadID: thread)
                } catch GmailError.notFound {
                    context.log.notice("draft \(draft.id.rawValue): Gmail draft gone, creating it again")
                    saved = try await create(raw, draft: draft, attempts: op.attempts, messageID: message.messageID,
                                             report: &report)
                }
            } else {
                saved = try await create(raw, draft: draft, attempts: op.attempts, messageID: message.messageID,
                                         report: &report)
            }
            guard let returned = saved.message else { throw GmailError.decoding("drafts: message missing") }
            await applyMarkers(message.markerLabels, to: returned, draft: draft, report: &report)
            return .init(.complete(.draftSaved(gmailDraftID: GmailDraftID(saved.id), gmailMessageID: GmailMessageID(returned.id),
                                               version: draft.localVersion)))
        } catch {
            return OperationDrainer.classify(error, now: now)
        }
    }

    private func create(_ raw: Data, draft: DraftListItem, attempts: Int, messageID: String,
                        report: inout OperationDrainer.PassReport) async throws -> GmailDraft {
        let thread = draft.gmailThreadID?.rawValue
        if attempts > 0, let orphan = try await findOrphan(messageID: messageID, report: &report) {
            context.log.notice("draft \(draft.id.rawValue): adopting the Gmail draft an earlier attempt created")
            report.gmailCalls += 1
            return try await context.api.updateDraft(id: orphan, rawRFC822: raw, threadID: thread)
        }
        report.gmailCalls += 1
        return try await context.api.createDraft(rawRFC822: raw, threadID: thread)
    }

    func findOrphan(messageID: String, report: inout OperationDrainer.PassReport) async throws -> String? {
        let bare = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        report.gmailCalls += 1
        let page = try await context.api.listDrafts(pageToken: nil, q: "rfc822msgid:\(bare)", maxResults: 10)
        for candidate in page.drafts ?? [] {
            report.gmailCalls += 1
            let draft: GmailDraft
            do { draft = try await context.api.getDraft(id: candidate.id, format: .metadata) } catch GmailError.notFound { continue }
            let header = draft.message?.payload?.headers?.first { $0.name.caseInsensitiveCompare("Message-ID") == .orderedSame }
            if header?.value.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) == bare { return candidate.id }
        }
        return nil
    }

    private func applyMarkers(_ wanted: [String], to message: GmailMessage, draft: DraftListItem,
                              report: inout OperationDrainer.PassReport) async {
        do {
            var current = message.labelIds
            let mayHaveMarkers = !wanted.isEmpty || DraftMessage.needsMarkerStrip(draft, currentLabelNames: [])
            if current == nil {
                guard mayHaveMarkers else { return }
                report.gmailCalls += 1
                current = try await context.api.getMessage(id: message.id, format: .minimal, metadataHeaders: [],
                                                           priority: .queue).labelIds
            }
            let currentByName = try context.labels.names(of: current ?? [])
            let missing = wanted.filter { currentByName[$0] == nil }
            let stale = currentByName.filter { DraftMessage.isMarkerLabel($0.key) && !wanted.contains($0.key) }
                .sorted { $0.key < $1.key }.map(\.value)
            guard !missing.isEmpty || !stale.isEmpty else { return }
            let add = try await context.labels.ensure(missing, report: &report)
            report.gmailCalls += 1
            _ = try await context.api.modifyMessage(id: message.id, add: add, remove: stale)
        } catch {
            context.log.notice("draft \(draft.id.rawValue): marker labels not applied (\(OperationDrainer.code(error)))")
        }
    }
}
