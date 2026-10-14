import Foundation
import MailModel
import MailRender

public enum ComposeFormatCommand: String, CaseIterable, Hashable, Sendable, Identifiable {
    case bold, italic, underline, strikethrough, link, bulletList, numberedList, quote, clearFormatting

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bold: String(localized: "Bold")
        case .italic: String(localized: "Italic")
        case .underline: String(localized: "Underline")
        case .strikethrough: String(localized: "Strikethrough")
        case .link: String(localized: "Link")
        case .bulletList: String(localized: "Bulleted list")
        case .numberedList: String(localized: "Numbered list")
        case .quote: String(localized: "Quote")
        case .clearFormatting: String(localized: "Clear formatting")
        }
    }

    public var shortcut: String {
        switch self {
        case .bold: "⌘B"
        case .italic: "⌘I"
        case .underline: "⌘U"
        case .strikethrough: "⇧⌘X"
        case .link: "⇧⌘K"
        case .bulletList: "⇧⌘8"
        case .numberedList: "⇧⌘7"
        case .quote: "⇧⌘9"
        case .clearFormatting: "⌘\\"
        }
    }

    public var help: String { title + "  " + shortcut }

    public static let groups: [[ComposeFormatCommand]] = [
        [.bold, .italic, .underline, .strikethrough], [.link], [.bulletList, .numberedList, .quote], [.clearFormatting],
    ]
}

public struct ComposeFormatState: Equatable, Sendable {
    public enum ListKind: Equatable, Sendable { case bullet, numbered }

    public var marks: RichTextDocument.Marks
    public var isLink: Bool
    public var list: ListKind?
    public var isQuote: Bool
    public var hasSelection: Bool

    public init(marks: RichTextDocument.Marks = [], isLink: Bool = false, list: ListKind? = nil, isQuote: Bool = false,
                hasSelection: Bool = false) {
        self.marks = marks
        self.isLink = isLink
        self.list = list
        self.isQuote = isQuote
        self.hasSelection = hasSelection
    }

    public func isActive(_ command: ComposeFormatCommand) -> Bool {
        switch command {
        case .bold: marks.contains(.bold)
        case .italic: marks.contains(.italic)
        case .underline: marks.contains(.underline)
        case .strikethrough: marks.contains(.strikethrough)
        case .link: isLink
        case .bulletList: list == .bullet
        case .numberedList: list == .numbered
        case .quote: isQuote
        case .clearFormatting: false
        }
    }
}

@MainActor
public protocol ComposeFormatEditing: AnyObject {
    func applyFormat(_ command: ComposeFormatCommand)
}

public enum InlineImages {
    public static let fileExtensions: Set<String> = ["png", "jpg", "jpeg", "gif"]

    public static func canInline(_ url: URL) -> Bool {
        url.isFileURL && fileExtensions.contains(url.pathExtension.lowercased())
    }

    public static func newContentID() -> String {
        UUID().uuidString.lowercased() + "@openhuman"
    }

    public static func altText(forFilename filename: String) -> String? {
        let name = (filename as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

extension ComposeSettings {
    public static let showFormatBar = AppSettingKey(name: "compose.show_format_bar", defaultValue: false)
}

extension ComposeSession {
    public func applyFormat(_ command: ComposeFormatCommand) {
        guard !isPlainText else { return }
        formatter?.applyFormat(command)
    }

    public func updateFormatState(_ state: ComposeFormatState) {
        if formatState != state { formatState = state }
    }

    public var fileAttachments: [DraftAttachmentInfo] {
        attachments.filter { !$0.isInline }
    }

    public func addInlineImage(file: URL) -> InlineImageRef? {
        let folder = draftKey?.rawValue ?? id.uuidString
        guard var staged = try? services.staging.stage(file, draft: folder) else {
            notice = Notice(.error, String(localized: "Couldn't add the image."))
            return nil
        }
        let contentID = InlineImages.newContentID()
        staged.contentID = contentID
        staged.isInline = true
        attachments.append(staged)
        if attachmentBytes + staged.size > AttachmentLimits.maxTotalBytes { notice = Self.tooLargeNotice }
        return InlineImageRef(contentID: contentID, alt: InlineImages.altText(forFilename: staged.filename))
    }

    public func addInlineImage(data: Data, fileExtension: String) -> InlineImageRef? {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("OpenHumanMailPaste-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        let file = folder.appendingPathComponent(String(localized: "Pasted image") + "." + fileExtension)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file)
        } catch {
            notice = Notice(.error, String(localized: "Couldn't add the image."))
            return nil
        }
        return addInlineImage(file: file)
    }

    public func hasInlineImage(_ contentID: String) -> Bool {
        attachments.contains { $0.isInline && $0.contentID == contentID }
    }

    public func inlineImageFile(_ contentID: String) -> URL? {
        guard let attachment = attachments.first(where: { $0.isInline && $0.contentID == contentID }),
              let path = attachment.localPath else { return nil }
        return services.staging.fileURL(forLocalPath: path)
    }

    public func didPaste(_ report: ComposePaste.Report) {
        guard report.isWorthTelling else { return }
        notice = Notice(.info, report.droppedImages == 1
            ? String(localized: "An image was left out of the paste; drag its file in to add it.")
            : String(localized: "\(report.droppedImages) images were left out of the paste; drag their files in to add them."))
    }
}

extension ComposeManager {
    public func toggleFormatBar() {
        showsFormatBar.toggle()
        let shown = showsFormatBar
        guard let settings = environment.settings else { return }
        track(Task { try? await settings.set(ComposeSettings.showFormatBar, shown) })
    }
}
