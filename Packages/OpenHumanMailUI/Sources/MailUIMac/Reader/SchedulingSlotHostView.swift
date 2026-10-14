import AppKit
import MailFeatures
import MailModel
import MailTheme
import MailUI
import SwiftUI

@MainActor
final class SchedulingSlotHostView: NSView {
    let hosting: NSHostingView<SchedulingSlotRoot>

    init(assistant: SchedulingAssistant?, quickReplies: QuickReplySlot?, thread: ThreadKey, theme: ThemeTokens) {
        let resolved = InlineComposerView.resolvedTheme(for: theme)
        hosting = NSHostingView(rootView: SchedulingSlotRoot(assistant: assistant, quickReplies: quickReplies,
                                                             thread: thread, theme: resolved))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.sizingOptions = [.intrinsicContentSize]
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        identifier = NSUserInterfaceItemIdentifier("reader.schedulingSlot")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

struct QuickReplySlot {
    let center: AICenter
    let environment: AppEnvironment
    let message: MessageKey
}

struct SchedulingSlotRoot: View {
    let assistant: SchedulingAssistant?
    let quickReplies: QuickReplySlot?
    let thread: ThreadKey
    let theme: ResolvedTheme

    var drawsCalendarChips: Bool { assistant != nil && quickReplies == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let quickReplies {
                QuickReplyMessageRow(center: quickReplies.center, environment: quickReplies.environment, thread: thread,
                                     message: quickReplies.message)
            }
            if let assistant {
                SchedulingSlotView(assistant: assistant, thread: thread, showsChips: drawsCalendarChips)
            }
        }
            .environment(\.theme, theme)
            .environment(\.colorScheme, theme.appearance == .dark ? .dark : .light)
            .tint(theme.accentFill.color)
    }
}
