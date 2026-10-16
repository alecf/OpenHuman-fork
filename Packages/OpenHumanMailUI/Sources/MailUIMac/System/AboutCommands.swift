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
    let updates: UpdateCheckCenter?

    public init(label: BuildLabel, updates: UpdateCheckCenter? = nil) {
        self.label = label
        self.updates = updates
    }

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About OpenHuman Mail") { AboutPanel.show(label) }
            if let updates {
                Button(UpdateCheckCenter.menuTitle) { updates.begin() }
            }
        }
    }
}
