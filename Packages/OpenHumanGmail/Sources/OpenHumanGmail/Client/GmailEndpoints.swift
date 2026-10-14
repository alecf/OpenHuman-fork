import Foundation

struct GmailEndpoint: Sendable, Hashable {
    let httpMethod: String
    let template: String

    func matches(method: String, path: String) -> Bool {
        guard method == httpMethod else { return false }
        let want = template.split(separator: "/", omittingEmptySubsequences: false)
        let have = path.split(separator: "/", omittingEmptySubsequences: false)
        guard want.count == have.count else { return false }
        return zip(want, have).allSatisfy { $0 == "{id}" ? !$1.isEmpty : $0 == $1 }
    }
}

enum GmailEndpoints {
    static let api = "/gmail/v1/users/me/"
    static let upload = "/upload/gmail/v1/users/me/"

    static func endpoint(for method: GmailMethod) -> GmailEndpoint {
        switch method {
        case .getProfile: return GmailEndpoint(httpMethod: "GET", template: api + "profile")
        case .listSendAs: return GmailEndpoint(httpMethod: "GET", template: api + "settings/sendAs")
        case .listLabels: return GmailEndpoint(httpMethod: "GET", template: api + "labels")
        case .getLabel: return GmailEndpoint(httpMethod: "GET", template: api + "labels/{id}")
        case .createLabel: return GmailEndpoint(httpMethod: "POST", template: api + "labels")
        case .listThreads: return GmailEndpoint(httpMethod: "GET", template: api + "threads")
        case .getThread: return GmailEndpoint(httpMethod: "GET", template: api + "threads/{id}")
        case .trashThread: return GmailEndpoint(httpMethod: "POST", template: api + "threads/{id}/trash")
        case .untrashThread: return GmailEndpoint(httpMethod: "POST", template: api + "threads/{id}/untrash")
        case .listMessages: return GmailEndpoint(httpMethod: "GET", template: api + "messages")
        case .getMessage: return GmailEndpoint(httpMethod: "GET", template: api + "messages/{id}")
        case .getAttachment: return GmailEndpoint(httpMethod: "GET", template: api + "messages/{id}/attachments/{id}")
        case .batchModify: return GmailEndpoint(httpMethod: "POST", template: api + "messages/batchModify")
        case .modifyMessage: return GmailEndpoint(httpMethod: "POST", template: api + "messages/{id}/modify")
        case .trashMessage: return GmailEndpoint(httpMethod: "POST", template: api + "messages/{id}/trash")
        case .untrashMessage: return GmailEndpoint(httpMethod: "POST", template: api + "messages/{id}/untrash")
        case .sendMessage: return GmailEndpoint(httpMethod: "POST", template: upload + "messages/send")
        case .insertMessage: return GmailEndpoint(httpMethod: "POST", template: upload + "messages")
        case .listDrafts: return GmailEndpoint(httpMethod: "GET", template: api + "drafts")
        case .getDraft: return GmailEndpoint(httpMethod: "GET", template: api + "drafts/{id}")
        case .createDraft: return GmailEndpoint(httpMethod: "POST", template: upload + "drafts")
        case .updateDraft: return GmailEndpoint(httpMethod: "PUT", template: upload + "drafts/{id}")
        case .deleteDraft: return GmailEndpoint(httpMethod: "DELETE", template: api + "drafts/{id}")
        case .sendDraft: return GmailEndpoint(httpMethod: "POST", template: api + "drafts/send")
        case .listHistory: return GmailEndpoint(httpMethod: "GET", template: api + "history")
        }
    }

    static func isForbidden(method: String, path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        if parts.contains("settings"), !(method == "GET" && parts.suffix(2) == ["settings", "sendAs"]) { return true }
        if parts.contains(where: { ["filters", "forwardingAddresses", "autoForwarding", "delegates", "vacation",
                                    "imap", "pop", "language", "cse", "import"].contains($0) }) { return true }
        if method == "DELETE", !(parts.suffix(2).first == "drafts") { return true }
        if parts.last == "batchDelete" || parts.last == "delete" { return true }
        if parts.contains("labels"), method != "GET", !(method == "POST" && parts.last == "labels") { return true }
        if let me = parts.firstIndex(of: "me"), parts.count > me + 1, ["trash", "spam"].contains(parts[me + 1]) { return true }
        if parts.last == "empty" || parts.last == "emptyTrash" || parts.last == "emptySpam" { return true }
        if parts.contains("watch") || parts.last == "stop" { return true }
        return false
    }
}

enum GmailFields {
    static func fields(for method: GmailMethod) -> String? {
        switch method {
        case .listThreads: return "threads(id,snippet,historyId),nextPageToken,resultSizeEstimate"
        case .listMessages: return "messages(id,threadId),nextPageToken,resultSizeEstimate"
        case .listDrafts: return "drafts(id,message(id,threadId)),nextPageToken,resultSizeEstimate"
        case .listSendAs:
            return "sendAs(sendAsEmail,displayName,replyToAddress,signature,isPrimary,isDefault,verificationStatus)"
        case .getAttachment: return "size,data"
        default: return nil
        }
    }
}
