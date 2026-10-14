import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanMIME
import OpenHumanStore

struct DraftMessage: Sendable {
    enum Failure: Error, Equatable, Sendable {
        case attachmentMissing(String)
    }

    static let originHeader = "X-OpenHuman-Origin"
    static let threadingHeaders: Set<String> = ["in-reply-to", "references"]

    let draft: DraftListItem
    let outgoing: OutgoingMessage

    func raw(forSend: Bool) throws -> Data {
        try MIMEBuilder.build(forSend ? outgoing.removingAgentMarkers() : outgoing, bcc: .includeForGmailSubmission)
    }

    var messageID: String { outgoing.messageID }

    var markerLabels: [String] { Self.markerLabels(for: draft) }

    static func make(_ draft: DraftListItem, account: AccountItem?, date: Date,
                     attachmentData: (DraftAttachment) async throws -> Data) async throws -> DraftMessage {
        let from = sender(draft, account: account)
        var attachments: [OutgoingAttachment] = []
        for a in draft.content.attachments {
            attachments.append(OutgoingAttachment(filename: a.filename, mimeType: a.mimeType, data: try await attachmentData(a),
                                                  contentID: a.contentID, isInline: a.isInline))
        }
        let html = draft.content.bodyHTML.isEmpty ? nil : draft.content.bodyHTML
        let text = draft.content.bodyText ?? (html == nil ? "" : nil)
        let outgoing = OutgoingMessage(
            from: from, to: draft.content.to, cc: draft.content.cc, bcc: draft.content.bcc, replyTo: [],
            subject: draft.content.subject, htmlBody: html, textBody: text, attachments: attachments,
            inReplyTo: header("In-Reply-To", in: draft.extraHeaders).flatMap(messageIDs).flatMap(\.first),
            references: header("References", in: draft.extraHeaders).flatMap(messageIDs) ?? [],
            messageID: messageID(for: draft.id, from: from), date: date, extraHeaders: extraHeaders(for: draft),
            textFormat: html == nil ? .flowed(delSp: false) : .fixed)
        return DraftMessage(draft: draft, outgoing: outgoing)
    }

    static func sender(_ draft: DraftListItem, account: AccountItem?) -> EmailAddress {
        let identities = account?.sendAs ?? []
        let email = draft.content.from?.email
            ?? identities.first(where: \.isDefault)?.email
            ?? account?.email
            ?? ""
        let name = identities.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }?.name
            ?? (account?.email.caseInsensitiveCompare(email) == .orderedSame ? account?.displayName : nil)
        return EmailAddress(name: name.flatMap { $0.isEmpty ? nil : $0 }, email: email)
    }

    static func messageID(for id: DraftID, from: EmailAddress) -> String {
        ReplyComposer.makeMessageID(from: from, uuid: UUID(uuidString: id.rawValue) ?? stableUUID(id.rawValue))
    }

    static func extraHeaders(for draft: DraftListItem) -> [MIMEHeaderField] {
        var fields: [MIMEHeaderField] = []
        if wantsOriginMarker(draft) {
            let value = header(originHeader, in: draft.extraHeaders).flatMap { $0.isEmpty ? nil : $0 } ?? draft.origin.rawValue
            fields.append(MIMEHeaderField(name: originHeader, value: value))
        }
        if let stamp = header(OHGmailLabels.sendAtHeader, in: draft.extraHeaders) {
            fields.append(MIMEHeaderField(name: OHGmailLabels.sendAtHeader, value: stamp))
        }
        let handled: Set<String> = threadingHeaders.union([originHeader.lowercased(), OHGmailLabels.sendAtHeader.lowercased()])
        for (name, value) in draft.extraHeaders.sorted(by: { $0.key < $1.key }) where !handled.contains(name.lowercased()) {
            guard isPassable(name: name, value: value) else { continue }
            fields.append(MIMEHeaderField(name: name, value: value))
        }
        return fields
    }

    static func wantsOriginMarker(_ draft: DraftListItem) -> Bool {
        draft.reviewState == .pending && draft.origin != .user
    }

    static func markerLabels(for draft: DraftListItem) -> [String] {
        var names: [String] = []
        if wantsOriginMarker(draft) { names.append(OHGmailLabels.agent) }
        if let stamp = header(OHGmailLabels.sendAtHeader, in: draft.extraHeaders), let due = ScheduleStamp.parse(stamp) {
            names += [OHGmailLabels.scheduled, ScheduleLabel(kind: .scheduled, due: due).name]
        }
        return names
    }

    static func isMarkerLabel(_ name: String) -> Bool {
        if name == OHGmailLabels.agent { return true }
        switch ScheduleLabel.parse(name) {
        case .schedule(let label): return label.kind == .scheduled
        case .marker(let kind), .malformed(let kind): return kind == .scheduled
        case .notOurs: return false
        }
    }

    static func needsMarkerStrip(_ draft: DraftListItem, currentLabelNames: [String]) -> Bool {
        draft.origin != .user
            || draft.extraHeaders.keys.contains { $0.lowercased().hasPrefix("x-openhuman-") }
            || currentLabelNames.contains(where: isMarkerLabel)
    }

    static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func messageIDs(_ value: String) -> [String]? {
        let ids = value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }).map(String.init)
            .filter { id in !id.isEmpty && id.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F } }
        return ids.isEmpty ? nil : ids
    }

    static func isPassable(name: String, value: String) -> Bool {
        let nameOK = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let reserved: Set<String> = ["from", "to", "cc", "bcc", "resent-bcc", "reply-to", "subject", "date", "message-id",
                                     "mime-version", "content-type", "content-transfer-encoding", "content-disposition",
                                     "content-id"]
        return !name.isEmpty && name.unicodeScalars.allSatisfy(nameOK.contains) && !reserved.contains(name.lowercased())
            && !value.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\0" }
    }

    static func stableUUID(_ text: String) -> UUID {
        func fnv(_ seed: UInt64) -> UInt64 {
            var hash = seed
            for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
            return hash
        }
        var bytes = withUnsafeBytes(of: fnv(0xcbf2_9ce4_8422_2325).bigEndian) { Array($0) }
            + withUnsafeBytes(of: fnv(0x8422_2325_cbf2_9ce4).bigEndian) { Array($0) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
