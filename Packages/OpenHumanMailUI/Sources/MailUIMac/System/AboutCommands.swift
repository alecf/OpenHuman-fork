import AppKit
import MailFeatures
import SwiftUI

public enum AboutPanel {
    public static func options(for label: BuildLabel) -> [NSApplication.AboutPanelOptionKey: Any] {
        guard let notice = label.notice else { return [:] }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return [.credits: NSAttributedString(string: notice, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])]
    }

    @MainActor
    public static func show(_ label: BuildLabel) {
        NSApplication.shared.orderFrontStandardAboutPanel(options: options(for: label))
    }
}

public struct AboutCommands: Commands {
    let label: BuildLabel

    public init(label: BuildLabel) {
        self.label = label
    }

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About OpenHuman Mail") { AboutPanel.show(label) }
        }
    }
}
