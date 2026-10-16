import MailActions
import MailTheme
import SwiftUI
#if os(macOS)
import AppKit
#endif

extension EnvironmentValues {
    @Entry public var actionDescriptors: [ActionDescriptor] = ActionCatalog.all
    @Entry public var pinnedShortcutTip: ActionID? = nil
}

public enum ShortcutTipAlignment: Sendable, Equatable {
    case center
    case leading
}

extension View {
    public func shortcutTip(_ tip: ShortcutTip?, alignment: ShortcutTipAlignment = .center, pinned: Bool = false) -> some View {
        modifier(ShortcutTipModifier(tip: tip, alignment: alignment, pinned: pinned))
    }

    public func shortcutTip(_ action: ActionID, title: String? = nil, hint: String? = nil,
                            alignment: ShortcutTipAlignment = .center) -> some View {
        modifier(ActionShortcutTip(action: action, title: title, hint: hint, alignment: alignment))
    }

    public func shortcutTip(_ action: ActionID?, title: String? = nil, hint: String? = nil, orHelp help: String) -> some View {
        modifier(ShortcutTipOrHelp(action: action, title: title, hint: hint, help: help))
    }

    public func shortcutTipRoot() -> some View {
        modifier(ShortcutTipRoot())
    }
}

public struct ShortcutTipTiming: Equatable, Sendable {
    public let delay: Duration
    public let warm: Duration

    public init(delay: Duration, warm: Duration) {
        self.delay = delay
        self.warm = warm
    }

    public init(theme: ThemeTokens) {
        self.init(delay: .milliseconds(Int(theme.motionTooltipDelay.rounded())),
                  warm: .milliseconds(Int(theme.motionTooltipWarm.rounded())))
    }

    public func wait(sinceLastHidden: Duration?) -> Duration {
        guard let since = sinceLastHidden, since < warm else { return delay }
        return .zero
    }
}

enum ShortcutTipPlacement {
    static func frame(anchor: CGRect, size: CGSize, bounds: CGRect, gap: CGFloat, margin: CGFloat,
                      alignment: ShortcutTipAlignment = .center, rightToLeft: Bool = false) -> CGRect {
        let preferred = switch alignment {
        case .center: anchor.midX - size.width / 2
        case .leading: rightToLeft ? anchor.maxX - size.width : anchor.minX
        }
        let x = max(bounds.minX + margin, min(preferred, bounds.maxX - margin - size.width))
        let below = anchor.maxY + gap
        let above = anchor.minY - gap - size.height
        let fitsBelow = below + size.height <= bounds.maxY - margin
        let fitsAbove = above >= bounds.minY + margin
        return CGRect(x: x, y: fitsBelow || !fitsAbove ? below : above, width: size.width, height: size.height)
    }
}

@MainActor
enum ShortcutTipWarmth {
    static var lastHidden: ContinuousClock.Instant?

    static func sinceLastHidden() -> Duration? { lastHidden.map { ContinuousClock.now - $0 } }
}

struct ShortcutTipRequest {
    let anchor: Anchor<CGRect>
    let tip: ShortcutTip
    let alignment: ShortcutTipAlignment
}

struct ShortcutTipKey: PreferenceKey {
    static var defaultValue: ShortcutTipRequest? { nil }

    static func reduce(value: inout ShortcutTipRequest?, nextValue: () -> ShortcutTipRequest?) {
        if value == nil { value = nextValue() }
    }
}

struct ShortcutTipModifier: ViewModifier {
    let tip: ShortcutTip?
    let alignment: ShortcutTipAlignment
    let pinned: Bool
    @Environment(\.theme) private var theme
    #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
    #endif
    @State private var hovering = false
    @State private var shown = false
    @State private var dismissed = false
    @State private var dismissal = ShortcutTipDismissal()

    func body(content: Content) -> some View {
        let showing = shown && !dismissed
        content
            .onHover { hovering = $0 }
            .task(id: hovering) { await follow() }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { _ in
                if hovering { dismiss() }
            }
            .onChange(of: showing) { was, now in
                if was, !now { ShortcutTipWarmth.lastHidden = .now }
            }
            #if os(macOS)
            .onChange(of: appearsActive) { _, active in
                if !active { dismiss() }
            }
            #endif
            .onDisappear {
                hovering = false
                shown = false
                dismissal.stop()
            }
            .anchorPreference(key: ShortcutTipKey.self, value: .bounds) { anchor in
                guard let tip, pinned || showing else { return nil }
                return ShortcutTipRequest(anchor: anchor, tip: tip, alignment: alignment)
            }
    }

    private func follow() async {
        guard hovering, tip != nil else {
            shown = false
            dismissed = false
            dismissal.stop()
            return
        }
        dismissal.start { dismiss() }
        let wait = ShortcutTipTiming(theme: theme.tokens).wait(sinceLastHidden: ShortcutTipWarmth.sinceLastHidden())
        if wait > .zero { try? await Task.sleep(for: wait) }
        guard !Task.isCancelled, hovering, !dismissed else { return }
        shown = true
    }

    private func dismiss() {
        dismissed = true
        shown = false
    }
}

struct ActionShortcutTip: ViewModifier {
    let action: ActionID
    let title: String?
    let hint: String?
    let alignment: ShortcutTipAlignment
    @Environment(\.actionDescriptors) private var descriptors
    @Environment(\.pinnedShortcutTip) private var pinned

    func body(content: Content) -> some View {
        let tip = ShortcutTip.action(action, in: descriptors, title: title, hint: hint)
        content
            .shortcutTip(tip, alignment: alignment, pinned: pinned == action)
            .accessibilityHint(tip?.spokenDetail ?? "")
    }
}

struct ShortcutTipOrHelp: ViewModifier {
    let action: ActionID?
    let title: String?
    let hint: String?
    let help: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if let action {
            content.shortcutTip(action, title: title, hint: hint)
        } else {
            content.help(help)
        }
    }
}

struct ShortcutTipRoot: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(ShortcutTipKey.self, alignment: .topLeading) { request in
                if let request { ShortcutTipLayer(request: request) }
            }
            .transformPreference(ShortcutTipKey.self) { $0 = nil }
    }
}

struct ShortcutTipLayer: View {
    let request: ShortcutTipRequest
    @Environment(\.theme) private var theme
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        GeometryReader { proxy in
            ShortcutTipPlacementLayout(anchor: proxy[request.anchor], gap: theme.space2, margin: theme.space3,
                                       alignment: request.alignment, rightToLeft: direction == .rightToLeft) {
                ShortcutTipView(tip: request.tip)
                    .environment(\.layoutDirection, direction)
            }
        }
        // Why: place in screen order; the tip keeps the caller's direction and leading alignment mirrors explicitly
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transaction { $0.disablesAnimations = true }
    }
}

struct ShortcutTipPlacementLayout: Layout {
    let anchor: CGRect
    let gap: CGFloat
    let margin: CGFloat
    let alignment: ShortcutTipAlignment
    let rightToLeft: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let frame = ShortcutTipPlacement.frame(anchor: anchor, size: size, bounds: CGRect(origin: .zero, size: bounds.size),
                                                   gap: gap, margin: margin, alignment: alignment, rightToLeft: rightToLeft)
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(frame.size))
        }
    }
}

struct ShortcutTipView: View {
    let tip: ShortcutTip
    @Environment(\.theme) private var theme

    var body: some View {
        let toast = theme.component.toast
        VStack(alignment: .leading, spacing: theme.space2) {
            Grid(alignment: .leading, horizontalSpacing: theme.space6, verticalSpacing: theme.space3) {
                ForEach(tip.rows, id: \.title) { row in
                    GridRow {
                        Text(row.title).font(theme.typeBody.swiftUIFont)
                        if !row.keycaps.isEmpty {
                            ToastKeycapRow(keycaps: row.keycaps).gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
            if let hint = tip.hint {
                Text(hint)
                    .font(theme.typeLabel.swiftUIFont)
                    .foregroundStyle(toast.textSecondary.color)
            }
        }
        .foregroundStyle(toast.text.color)
        .padding(.horizontal, theme.space4)
        .padding(.vertical, theme.space3)
        .background(RoundedRectangle(cornerRadius: toast.radius).fill(toast.bg.color))
        .themeShadow(theme.shadow2)
        .accessibilityHidden(true)
    }
}

@MainActor
final class ShortcutTipDismissal {
    #if os(macOS)
    private var monitor: Any?
    #endif

    func start(_ dismiss: @escaping @MainActor () -> Void) {
        #if os(macOS)
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
                                                              .keyDown]) { event in
            MainActor.assumeIsolated { dismiss() }
            return event
        }
        #endif
    }

    func stop() {
        #if os(macOS)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        #endif
    }

    isolated deinit { stop() }
}
