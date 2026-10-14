import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanMIME
import OpenHumanStore

struct SendPipeline: Sendable {
    typealias Decision = OperationDrainer.Decision

    let context: DrainContext

    enum Presence { case exists, gone, unknown(Error) }

    func run(_ op: OperationItem, draftID: DraftID, report: inout OperationDrainer.PassReport) async -> Decision {
        let now = context.clock.now
        let draft: DraftListItem
        do {
            guard let row = try context.store.draft(draftID) else {
                return .init(.fail(code: "draft_missing", message: "the draft no longer exists locally"))
            }
            draft = row
        } catch {
            return OperationDrainer.classify(error, now: now, limit: OperationDrainer.maxSendAttempts)
        }
        guard draft.state == .sending else {
            return .init(.fail(code: "draft_state", message: "the draft is \(draft.state.rawValue), not sending"))
        }
        guard let gmailDraftID = draft.gmailDraftID else {
            return .init(.fail(code: "not_uploaded", message: "the draft was never saved to Gmail"))
        }
        guard !draft.isDirty else {
            return .init(.fail(code: "draft_changed", message: "the draft changed after it was saved for sending"))
        }
        let message: DraftMessage
        do {
            message = try await context.message(for: draft)
        } catch {
            return OperationDrainer.classify(error, now: now, limit: OperationDrainer.maxSendAttempts)
        }

        if op.attempts > 0 {
            switch await presence(gmailDraftID, report: &report) {
            case .gone: return await consumed(op, draft: draft, message: message, report: &report)
            case .exists: break
            case .unknown(let error): return lookAgainLater(error)
            }
        }

        var wroteToGmail = false
        do {
            if DraftMessage.needsMarkerStrip(draft, currentLabelNames: try context.labelNames(ofMessage: draft.gmailMessageID)) {
                try await prepareForSend(draft, message: message, gmailDraftID: gmailDraftID, wrote: &wroteToGmail,
                                         report: &report)
            }
        } catch GmailError.notFound {
            return await draftVanished(op, draft: draft, message: message, report: &report)
        } catch {
            return afterWrite(OperationDrainer.classify(error, now: now, limit: OperationDrainer.maxSendAttempts),
                              op: op, wroteToGmail: wroteToGmail)
        }

        let sent: GmailMessage
        do {
            report.gmailCalls += 1
            sent = try await context.api.sendDraft(id: gmailDraftID.rawValue)
        } catch {
            return await sendFailed(error, op: op, draft: draft, message: message, gmailDraftID: gmailDraftID,
                                    wroteToGmail: wroteToGmail, report: &report)
        }
        context.log.notice("draft \(draft.id.rawValue): sent as message \(sent.id)")
        return await delivered(sent, draft: draft, message: message, report: &report)
    }

    func prepareForSend(_ draft: DraftListItem, message: DraftMessage, gmailDraftID: GmailDraftID, wrote: inout Bool,
                        report: inout OperationDrainer.PassReport) async throws {
        let raw = try message.raw(forSend: true)
        let updated: GmailDraft
        do {
            report.gmailCalls += 1
            updated = try await context.api.updateDraft(id: gmailDraftID.rawValue, rawRFC822: raw,
                                                        threadID: draft.gmailThreadID?.rawValue)
            wrote = true
        } catch {
            if !OperationDrainer.neverReachedGmail(error) { wrote = true }
            throw error
        }
        guard let returned = updated.message else { return }
        let markers = try markerIDs(on: returned.labelIds)
        guard !markers.isEmpty else { return }
        do {
            report.gmailCalls += 1
            _ = try await context.api.modifyMessage(id: returned.id, add: [], remove: markers)
        } catch GmailError.notFound {
        } catch GmailError.badRequest {
            context.log.notice("draft \(draft.id.rawValue): marker label removal refused (treated as done)")
        }
    }

    func markerIDs(on labelIds: [String]?) throws -> [String] {
        if let labelIds {
            return try context.labels.names(of: labelIds).filter { DraftMessage.isMarkerLabel($0.key) }.map(\.value).sorted()
        }
        return try context.labels.knownIDs().filter { DraftMessage.isMarkerLabel($0.key) }.map(\.value).sorted()
    }

    private func sendFailed(_ error: Error, op: OperationItem, draft: DraftListItem, message: DraftMessage,
                            gmailDraftID: GmailDraftID, wroteToGmail: Bool,
                            report: inout OperationDrainer.PassReport) async -> Decision {
        let now = context.clock.now
        if OperationDrainer.neverReachedGmail(error) {
            return afterWrite(OperationDrainer.classify(error, now: now, limit: OperationDrainer.maxSendAttempts),
                              op: op, wroteToGmail: wroteToGmail)
        }
        switch error as? GmailError {
        case .notFound?:
            return await draftVanished(op, draft: draft, message: message, report: &report)
        case .badRequest?, .forbidden?, .payloadTooLarge?, .preconditionFailed?:
            return OperationDrainer.classify(error, now: now)
        default:
            break
        }
        // The request may have reached Gmail: never resend blindly
        let code = OperationDrainer.code(error)
        context.log.notice("draft \(draft.id.rawValue): send outcome unknown (\(code)), checking the draft")
        if Task.isCancelled {
            return .init(.retry(code: "send_interrupted", message: "the send was interrupted", at: now, limit: .max),
                         stopPass: true)
        }
        switch await presence(gmailDraftID, report: &report) {
        case .gone:
            return await consumed(op, draft: draft, message: message, report: &report)
        case .exists:
            return .init(.retry(code: code, message: "not sent: the Gmail draft is still there", at: nil,
                                limit: OperationDrainer.maxSendAttempts))
        case .unknown(let checkError):
            return .init(.retry(code: "send_unconfirmed", message: "the send may have reached Gmail; checking again",
                                at: now.addingTimeInterval(OperationDrainer.unconfirmedRetry.timeInterval), limit: .max),
                         stopPass: OperationDrainer.classify(checkError, now: now).stopPass)
        }
    }

    func consumed(_ op: OperationItem, draft: DraftListItem, message: DraftMessage,
                  report: inout OperationDrainer.PassReport) async -> Decision {
        do {
            if let stub = try await sentCopy(of: message, report: &report) {
                context.log.notice("draft \(draft.id.rawValue): found the sent copy \(stub.id) after an unclear send")
                return await delivered(stub, draft: draft, message: message, report: &report)
            }
        } catch {
            return lookAgainLater(error)
        }
        if op.attempts + 1 < OperationDrainer.maxSendAttempts {
            return .init(.retry(code: "sent_unconfirmed", message: "the draft is gone; looking for the sent copy",
                                at: context.clock.now.addingTimeInterval(OperationDrainer.unconfirmedRetry.timeInterval),
                                limit: .max))
        }
        context.log.notice("draft \(draft.id.rawValue): sent copy not found; taking the consumed draft as sent")
        return .init(.cancel(code: "target_gone", message: "sent; the sent copy arrives with the next sync"),
                     event: .sent(draft.id, nil))
    }

    func draftVanished(_ op: OperationItem, draft: DraftListItem, message: DraftMessage,
                       report: inout OperationDrainer.PassReport) async -> Decision {
        if op.attempts > 0 { return await consumed(op, draft: draft, message: message, report: &report) }
        if op.origin != .scheduler, let stub = try? await sentCopy(of: message, report: &report) {
            context.log.notice("draft \(draft.id.rawValue): sent elsewhere before our send; found the sent copy \(stub.id)")
            return await delivered(stub, draft: draft, message: message, report: &report)
        }
        return draftGone(op, draft: draft)
    }

    func sentCopy(of message: DraftMessage, report: inout OperationDrainer.PassReport) async throws -> GmailMessage? {
        let bare = message.messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        report.gmailCalls += 1
        let found = try await context.api.listMessages(ListQuery(labelIDs: ["SENT"], q: "rfc822msgid:\(bare)", maxResults: 5),
                                                       priority: .queue)
        return found.messages?.first
    }

    func draftGone(_ op: OperationItem, draft: DraftListItem) -> Decision {
        if op.origin == .scheduler {
            return .init(.cancel(code: "target_gone", message: "the Gmail draft was sent or deleted elsewhere"))
        }
        return .init(.fail(code: "draft_gone", message: "the Gmail draft was deleted or sent elsewhere"))
    }

    private func delivered(_ sent: GmailMessage, draft: DraftListItem, message: DraftMessage,
                           report: inout OperationDrainer.PassReport) async -> Decision {
        var stub = sent
        do {
            let markers = try markerIDs(on: sent.labelIds ?? [])
            if !markers.isEmpty {
                report.gmailCalls += 1
                let cleaned = try await context.api.modifyMessage(id: sent.id, add: [], remove: markers)
                stub.labelIds = cleaned.labelIds ?? sent.labelIds?.filter { !markers.contains($0) }
            }
        } catch {
            context.log.notice("draft \(draft.id.rawValue): marker labels left on the sent copy (\(OperationDrainer.code(error)))")
        }
        let upsert = await sentUpsert(stub, draft: draft, message: message, report: &report)
        return .init(.complete(.sent(upsert)), event: .sent(draft.id, GmailMessageID(sent.id)))
    }

    func sentUpsert(_ stub: GmailMessage, draft: DraftListItem, message: DraftMessage,
                    report: inout OperationDrainer.PassReport) async -> MessageUpsert {
        do {
            report.gmailCalls += 1
            let full = try await context.api.getMessage(id: stub.id, format: .full, metadataHeaders: [], priority: .queue)
            return try GmailMapper.messageUpsert(full, includeBody: true)
        } catch {
            context.log.notice("draft \(draft.id.rawValue): sent copy not read (\(OperationDrainer.code(error))); using our own")
        }
        let raw = (try? message.raw(forSend: true)) ?? Data()
        var upsert = MessageUpsert(
            gmailMessageID: GmailMessageID(stub.id),
            gmailThreadID: GmailThreadID(stub.threadId ?? draft.gmailThreadID?.rawValue ?? stub.id),
            historyID: stub.historyIDValue ?? HistoryID(0), internalDate: stub.internalDateValue ?? context.clock.now,
            labelIDs: (stub.labelIds ?? ["SENT"]).map { GmailLabelID($0) }, snippet: stub.snippet ?? "",
            sizeEstimate: stub.sizeEstimate ?? raw.count)
        if let parsed = try? MIMEParser.parse(rfc822: raw) {
            let (body, _) = GmailMapper.bodyUpsert(parsed)
            upsert.headers = GmailMapper.headers(parsed)
            upsert.body = body
            if upsert.snippet.isEmpty { upsert.snippet = String(body.searchText.prefix(100)) }
        }
        return upsert
    }

    func presence(_ id: GmailDraftID, report: inout OperationDrainer.PassReport) async -> Presence {
        do {
            report.gmailCalls += 1
            _ = try await context.api.getDraft(id: id.rawValue, format: .minimal)
            return .exists
        } catch GmailError.notFound {
            return .gone
        } catch {
            return .unknown(error)
        }
    }

    // Fate of the earlier attempt is unknown and the check failed: release, never end the op or count a failure
    func lookAgainLater(_ error: Error) -> Decision {
        let now = context.clock.now
        var decision = OperationDrainer.classify(error, now: now, limit: .max)
        switch decision.disposition {
        case .fail, .retry, .complete, .cancel:
            decision.disposition = .release(at: now.addingTimeInterval(OperationDrainer.unconfirmedRetry.timeInterval))
        case .release:
            break
        }
        return decision
    }

    func afterWrite(_ decision: Decision, op: OperationItem, wroteToGmail: Bool) -> Decision {
        guard wroteToGmail, op.origin == .scheduler, case let .release(at) = decision.disposition else { return decision }
        var adjusted = decision
        adjusted.disposition = .retry(code: "released_after_strip", message: "markers already removed; sending later",
                                      at: at, limit: .max)
        return adjusted
    }
}
