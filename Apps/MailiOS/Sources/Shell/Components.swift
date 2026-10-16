import MailUI
import SwiftUI

struct CircleIconButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 48
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    @Environment(\.touch) private var theme

    var body: some View {
        let side = min(size * scale, size * 1.5)
        Button(action: action) {
            Image(systemName: systemImage)
                .font(theme.icon)
                .foregroundStyle(theme.textPrimary)
                .frame(width: side, height: side)
                .background(Circle().fill(theme.pill))
                .overlay(Circle().strokeBorder(theme.elevatedBorder, lineWidth: theme.tokens.borderWidthHairline))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct PillGroup<Content: View>: View {
    var height: CGFloat = 48
    @ViewBuilder let content: Content
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    @Environment(\.touch) private var theme

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(.horizontal, theme.tokens.space2)
            .frame(height: min(height * scale, height * 1.5))
            .background(Capsule().fill(theme.pill))
            .overlay(Capsule().strokeBorder(theme.elevatedBorder, lineWidth: theme.tokens.borderWidthHairline))
    }
}

struct PillIconButton: View {
    let systemImage: String
    let label: String
    var isOn = false
    var tint: Color?
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 46
    @Environment(\.touch) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(theme.icon)
                .foregroundStyle(tint ?? (isOn ? theme.textWarning : theme.textPrimary))
                .frame(minWidth: min(width, 66), minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct AvatarView: View {
    let name: String?
    let email: String
    var size: CGFloat = 40
    @Environment(\.touch) private var theme

    var body: some View {
        Text(Self.initials(name: name, email: email))
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(theme.window)
            .frame(width: size, height: size)
            .background(Circle().fill(Self.color(for: email, theme: theme)))
            .accessibilityHidden(true)
    }

    static func initials(name: String?, email: String) -> String {
        let source = name.flatMap { $0.isEmpty ? nil : $0 } ?? email
        return source.first.map { String($0).uppercased() } ?? "?"
    }

    static func color(for email: String, theme: TouchTheme) -> Color {
        let palette = [theme.textLink, theme.textSuccess, theme.textAI, theme.textWarning, theme.textDanger,
                       theme.textSecondary]
        let sum = email.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return palette[sum % palette.count]
    }
}

struct SampleBadge: View {
    @Environment(\.touch) private var theme

    var body: some View {
        Text("SAMPLE")
            .font(theme.badge)
            .tracking(0.8)
            .foregroundStyle(theme.textWarning)
            .padding(.horizontal, theme.tokens.space3)
            .padding(.vertical, theme.tokens.space1)
            .background(Capsule().fill(theme.warningSubtle))
            .accessibilityLabel("Sample mail, not a real account")
    }
}

struct CardSurface: ViewModifier {
    @Environment(\.touch) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.radiusCard)
        content
            .background(shape.fill(theme.card))
            .overlay(shape.strokeBorder(theme.hairline, lineWidth: theme.tokens.borderWidthHairline))
            .themeShadow(theme.tokens.component.thread.cardShadow)
    }
}

extension View {
    func cardSurface() -> some View { modifier(CardSurface()) }

    func topBarBackground(_ color: Color) -> some View {
        background {
            VStack(spacing: 0) {
                color
                LinearGradient(colors: [color, color.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 18)
            }
            .padding(.bottom, -18)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }

    func bottomBarBackground(_ color: Color) -> some View {
        background {
            VStack(spacing: 0) {
                LinearGradient(colors: [color.opacity(0), color], startPoint: .top, endPoint: .bottom)
                    .frame(height: 30)
                color
            }
            .padding(.top, -30)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }
}
