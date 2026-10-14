import MailFeatures
import MailTheme
import SwiftUI

public struct ToastHostView: View {
    let notices: NoticeCenter
    @Environment(\.theme) private var theme

    public init(notices: NoticeCenter) {
        self.notices = notices
    }

    public var body: some View {
        let tokens = theme.tokens
        let enter = tokens.motion(tokens.motionEnterBase), exit = tokens.motion(tokens.motionExitBase)
        VStack(spacing: tokens.component.toast.gap) {
            ForEach(notices.toasts) { toast in
                ToastView(toast: toast) {
                    Task { await notices.activate(toast.id) }
                } dismiss: {
                    notices.dismiss(toast.id)
                } activateSecondary: {
                    Task { await notices.activateSecondary(toast.id) }
                } hovering: { inside in
                    if inside {
                        notices.pause(toast.id)
                    } else {
                        notices.resume(toast.id, minimum: .milliseconds(Int(theme.motionToastResume)))
                    }
                }
                .transition(toast.animates ? .asymmetric(
                    insertion: AnyTransition.motion(enter, offset: tokens.component.toast.enterOffset).animation(enter.animation),
                    removal: AnyTransition.motion(exit, offset: tokens.component.toast.exitOffset).animation(exit.animation))
                    : .identity)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .animation(enter.allowsTransform ? enter.animation : nil, value: notices.toasts.map(\.id))
        .onAppear {
            notices.timing = ToastTiming(theme: tokens)
            notices.reduceMotion = tokens.reduceMotion
        }
        .onChange(of: ToastTiming(theme: tokens)) { _, timing in notices.timing = timing }
        .onChange(of: tokens.reduceMotion) { _, reduce in notices.reduceMotion = reduce }
        .onChange(of: notices.toasts.map(\.id)) { old, new in
            let added = Set(new).subtracting(old)
            for toast in notices.toasts where added.contains(toast.id) {
                AccessibilityNotification.Announcement(Self.spoken(toast)).post()
            }
        }
    }

    public static func spoken(_ toast: Toast) -> String {
        var text = toast.message + "."
        if let action = toast.actionTitle {
            text += " \(action)"
            if let shortcut = toast.shortcut { text += ", \(shortcut)" }
            text += "."
        }
        if let second = toast.secondaryActionTitle {
            text += " \(second)"
            if let shortcut = toast.secondaryShortcut { text += ", \(shortcut)" }
            text += "."
        }
        return text
    }
}

struct ToastView: View {
    let toast: Toast
    let activate: () -> Void
    let dismiss: () -> Void
    var activateSecondary: () -> Void = {}
    var hovering: (Bool) -> Void = { _ in }
    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @FocusState private var closeFocused: Bool

    var body: some View {
        let toastTokens = theme.component.toast
        HStack(spacing: theme.space5) {
            if toast.style == .error {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: ShellMetrics.rowIconSize, weight: .regular))
                    .foregroundStyle(toastTokens.danger.color)
                    .accessibilityHidden(true)
            }
            Text(toast.message)
                .font(theme.typeBody.swiftUIFont)
                .lineLimit(1)
                .truncationMode(.tail)
            if toast.holdsWindow, let end = toast.expiresAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let left = Self.countdown(until: end, now: context.date) {
                        Text(left)
                            .font(theme.typeBody.swiftUIFont.monospacedDigit())
                            .foregroundStyle(toastTokens.textSecondary.color)
                            .accessibilityHidden(true)
                    }
                }
            }
            Spacer(minLength: 0)
            if let title = toast.actionTitle {
                actionButton(title, shortcut: toast.shortcut, action: activate)
            }
            if let title = toast.secondaryActionTitle {
                actionButton(title, shortcut: toast.secondaryShortcut, action: activateSecondary)
            }
        }
        .foregroundStyle(toastTokens.text.color)
        .padding(.horizontal, theme.space5)
        .frame(minWidth: toastTokens.minWidth, maxWidth: toastTokens.maxWidth, minHeight: toastTokens.height,
               maxHeight: toastTokens.height)
        .background(RoundedRectangle(cornerRadius: toastTokens.radius).fill(toastTokens.bg.color))
        .themeShadow(theme.shadow2)
        .overlay(alignment: .topTrailing) { closeButton }
        .contentShape(Rectangle())
        .onHover { inside in
            isHovered = inside
            hovering(inside)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(toast.message)
        .accessibilityAction(named: "Dismiss", dismiss)
    }

    static func countdown(until end: Date, now: Date) -> String? {
        let left = Int(end.timeIntervalSince(now).rounded(.up))
        return left > 0 ? "\(left) s" : nil
    }

    private var closeButton: some View {
        let toastTokens = theme.component.toast
        let shown = isHovered || closeFocused
        return Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: ToastMetrics.closeGlyph, weight: .semibold))
                .foregroundStyle(toastTokens.text.color)
                .frame(width: toastTokens.closeSize, height: toastTokens.closeSize)
                .background(Circle().fill(toastTokens.bg.color))
                .overlay(Circle().strokeBorder(toastTokens.textSecondary.color, lineWidth: theme.borderWidthHairline))
                .frame(width: ToastMetrics.closeTarget, height: ToastMetrics.closeTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($closeFocused)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .offset(x: ToastMetrics.closeTarget / 2 - ToastMetrics.closeInset,
                y: -(ToastMetrics.closeTarget / 2 - ToastMetrics.closeInset))
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
    }

    private func actionButton(_ title: String, shortcut: String?, action: @escaping () -> Void) -> some View {
        let toastTokens = theme.component.toast
        return Button(action: action) {
            HStack(spacing: theme.space3) {
                Text(title).font(theme.typeBodyStrong.swiftUIFont)
                if let shortcut {
                    Text(shortcut)
                        .font(theme.typeKeycap.swiftUIFont)
                        .foregroundStyle(toastTokens.keycapText.color)
                        .padding(.horizontal, theme.space2)
                        .frame(minWidth: theme.component.keycap.minWidth, minHeight: theme.component.keycap.height)
                        .background(RoundedRectangle(cornerRadius: theme.component.keycap.radius)
                            .fill(toastTokens.keycapBg.color))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(shortcut.map { "Shortcut \($0)" } ?? "")
    }
}

enum ToastMetrics {
    static let closeTarget: CGFloat = 24
    static let closeGlyph: CGFloat = 9
    static let closeInset: CGFloat = 4
}
