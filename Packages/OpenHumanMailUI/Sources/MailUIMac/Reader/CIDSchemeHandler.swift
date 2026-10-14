import AppKit
import MailModel
import MailRender
import WebKit

struct InlinePartSource: Sendable {
    let attachments: [AttachmentInfo]
    let file: @Sendable (AttachmentInfo) async throws -> URL

    func attachment(forContentID id: String) -> AttachmentInfo? {
        attachments.first { $0.contentID.map { InlineParts.matches($0, id) } ?? false }
    }
}

@MainActor
final class CIDSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let maxBytes = 25 * 1024 * 1024
    private var active: Set<ObjectIdentifier> = []
    private(set) var served = 0

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        guard let url = task.request.url, let contentID = InlineParts.contentID(from: url),
              let source = (webView as? ReaderWebView)?.inlineParts,
              let attachment = source.attachment(forContentID: contentID) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        active.insert(id)
        Task { [weak self] in
            let data: Data? = await Task.detached(priority: .userInitiated) {
                guard let file = try? await source.file(attachment) else { return nil }
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count <= Self.maxBytes else { return nil }
                return data
            }.value
            guard let self, self.active.remove(id) != nil else { return }
            guard let data, let mime = Self.imageType(of: data) else {
                task.didFailWithError(URLError(.cannotDecodeContentData))
                return
            }
            task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data)
            task.didFinish()
            self.served += 1
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }

    nonisolated static func imageType(of data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        if b.count >= 8, b[0..<8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b.count >= 6, b[0..<6].elementsEqual(Array("GIF87a".utf8)) || b[0..<6].elementsEqual(Array("GIF89a".utf8)) {
            return "image/gif"
        }
        if b.count >= 12, b[0..<4].elementsEqual(Array("RIFF".utf8)), b[8..<12].elementsEqual(Array("WEBP".utf8)) {
            return "image/webp"
        }
        return nil
    }
}
