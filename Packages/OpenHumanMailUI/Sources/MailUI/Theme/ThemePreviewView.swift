import MailTheme
import SwiftUI

public struct ThemePreviewView: View {
    public static let baseSize = CGSize(width: 420, height: 270)

    public struct SampleRow: Hashable, Sendable {
        public let sender: String
        public let subject: String
        public let snippet: String
        public let date: String
        public let isUnread: Bool

        public init(sender: String, subject: String, snippet: String, date: String, isUnread: Bool) {
            self.sender = sender
            self.subject = subject
            self.snippet = snippet
            self.date = date
            self.isUnread = isUnread
        }
    }

    public static let sampleRows: [SampleRow] = [
        SampleRow(sender: "Rosa Lind", subject: "Venue shortlist", snippet: "Three options, all near the station", date: "9:41", isUnread: true),
        SampleRow(sender: "Build bot", subject: "Nightly passed", snippet: "412 tests, 0 failures", date: "8:02", isUnread: true),
        SampleRow(sender: "Theo Marsh", subject: "Re: Q3 plan", snippet: "Works for me if we keep Friday", date: "Tue", isUnread: false),
        SampleRow(sender: "Ana Ortiz", subject: "Photos from Sunday", snippet: "The ones by the lake came out well", date: "Mon", isUnread: false),
        SampleRow(sender: "Field Notes", subject: "Issue 48", snippet: "On slow software and fast habits", date: "Sun", isUnread: false),
        SampleRow(sender: "Kim Park", subject: "Invoice 2291", snippet: "Paid, thank you", date: "Oct 3", isUnread: false),
    ]

    let theme: ResolvedTheme
    let rows: [SampleRow]
    let scale: CGFloat

    public init(theme: ResolvedTheme, rows: [SampleRow] = ThemePreviewView.sampleRows, scale: CGFloat = 1) {
        self.theme = theme
        self.rows = Array(rows.prefix(6))
        self.scale = scale
    }

    private let k: CGFloat = 0.62

    public var body: some View {
        content
            .frame(width: Self.baseSize.width, height: Self.baseSize.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: Self.baseSize.width * scale, height: Self.baseSize.height * scale, alignment: .topLeading)
            .environment(\.theme, theme)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(theme.themeName) theme preview")
    }

    private func font(_ style: TypeStyle) -> Font {
        var scaled = style
        scaled.size = style.size * k
        return scaled.swiftUIFont
    }

    private var content: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(theme.borderHairline.color).frame(height: theme.borderWidthHairline)
            banner
            HStack(alignment: .top, spacing: 0) {
                list.frame(width: Self.baseSize.width * 0.52)
                Rectangle().fill(theme.borderHairline.color).frame(width: theme.borderWidthHairline)
                reader
            }
        }
        .background(theme.bgWindow.color)
        .overlay(alignment: .bottomLeading) { toast.padding(theme.space3) }
    }

    private var toolbar: some View {
        HStack(spacing: theme.space6 * k) {
            HStack(spacing: theme.component.tab.countGap * k) {
                Text("Important").font(font(theme.typeTabActive)).foregroundStyle(theme.component.tab.textActive.color)
                Text("2").font(font(theme.typeCaption)).foregroundStyle(theme.component.tab.count.color)
            }
            Text("Other").font(font(theme.typeTab)).foregroundStyle(theme.component.tab.text.color)
            Text("Calendar").font(font(theme.typeTab)).foregroundStyle(theme.component.tab.text.color)
            Spacer(minLength: 0)
            Circle().fill(ThemeTokens.avatarPalette[0].color).frame(width: 14, height: 14)
        }
        .padding(.horizontal, theme.component.toolbar.paddingX * k)
        .frame(height: theme.component.toolbar.height * k)
        .background(theme.component.toolbar.bg.color)
    }

    private var banner: some View {
        HStack(spacing: theme.space2) {
            Text("Offline. Changes are queued.").font(font(theme.typeMeta)).foregroundStyle(theme.textWarning.color)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.component.toolbar.paddingX * k)
        .frame(height: theme.component.banner.height * k)
        .background(theme.bgWarningSubtle.color)
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Today").font(font(theme.typeLabel)).foregroundStyle(theme.component.row.groupHeader.color)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.component.row.paddingX * k)
            .frame(height: theme.component.row.groupHeaderHeight * k * 0.8)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                rowView(row, isCursor: index == 1)
            }
            Spacer(minLength: 0)
        }
    }

    private func rowView(_ row: SampleRow, isCursor: Bool) -> some View {
        let r = theme.component.row
        let strong = row.isUnread ? theme.typeBodyStrong : theme.typeBody
        return HStack(spacing: r.columnGap * k * 0.5) {
            Circle().fill(row.isUnread ? r.unreadDot.color : Color.clear)
                .frame(width: r.unreadDotSize * k, height: r.unreadDotSize * k)
                .frame(width: r.dotGutter * k * 0.6)
            Text(row.sender).font(font(strong)).foregroundStyle(r.sender.color).lineLimit(1)
                .frame(width: 58, alignment: .leading)
            Text("\(Text(row.subject).font(font(strong)).foregroundStyle(r.subject.color))  \(Text(row.snippet).font(font(theme.typeBody)).foregroundStyle(r.snippet.color))")
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(row.date).font(font(theme.typeMeta)).foregroundStyle((row.isUnread ? r.dateUnread : r.date).color)
        }
        .padding(.leading, r.paddingX * k * 0.5)
        .padding(.trailing, r.paddingX * k * 0.5)
        .frame(height: theme.rowHeight * k)
        .background(isCursor ? r.bgCursor.color : Color.clear)
        .overlay(alignment: .leading) {
            if isCursor { Rectangle().fill(r.cursorBar.color).frame(width: theme.borderWidthCursorBar) }
        }
    }

    private var reader: some View {
        VStack(alignment: .leading, spacing: theme.space3 * k) {
            Text("Venue shortlist").font(font(theme.typeTitle)).foregroundStyle(theme.textPrimary.color)
            Text("Rosa Lind  ·  9:41").font(font(theme.typeMeta)).foregroundStyle(theme.textSecondary.color)
            Text("Three options near the station. The second has the \(Text("floor plan").foregroundStyle(theme.component.link.text.color)) attached.")
                .foregroundStyle(theme.textPrimary.color)
                .font(font(theme.typeReader))
                .fixedSize(horizontal: false, vertical: true)
            designedEmail
            composer
            Spacer(minLength: 0)
        }
        .padding(theme.space5 * k)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var designedEmail: some View {
        VStack(alignment: .leading, spacing: theme.space2 * k) {
            RoundedRectangle(cornerRadius: theme.radiusSM * k).fill(theme.bgSunken.color).frame(height: 14)
            RoundedRectangle(cornerRadius: theme.radiusSM * k).fill(theme.borderHairline.color).frame(width: 90, height: 5)
            RoundedRectangle(cornerRadius: theme.radiusSM * k).fill(theme.borderHairline.color).frame(width: 120, height: 5)
        }
        .padding(theme.space3 * k)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.readerDesignedEmailCardBg.color)
        .clipShape(RoundedRectangle(cornerRadius: theme.readerDesignedEmailCardRadius * k))
        .overlay(RoundedRectangle(cornerRadius: theme.readerDesignedEmailCardRadius * k)
            .stroke(theme.readerDesignedEmailCardBorder.color, lineWidth: theme.borderWidthHairline))
    }

    private var composer: some View {
        HStack {
            Text("Reply…").font(font(theme.typeBody)).foregroundStyle(theme.textTertiary.color)
            Spacer(minLength: 0)
            Text("Send").font(font(theme.typeLabel)).foregroundStyle(theme.accentOnFill.color)
                .padding(.horizontal, theme.space3 * k)
                .padding(.vertical, theme.space1)
                .background(theme.accentFill.color, in: RoundedRectangle(cornerRadius: theme.radiusMD * k))
        }
        .padding(theme.space2 * k)
        .background(theme.component.compose.bg.color, in: RoundedRectangle(cornerRadius: theme.component.compose.radius * k))
        .overlay(RoundedRectangle(cornerRadius: theme.component.compose.radius * k)
            .stroke(theme.borderControl.color, lineWidth: theme.borderWidthControl))
    }

    private var toast: some View {
        Text("Marked done  ⌘Z").font(font(theme.typeLabel)).foregroundStyle(theme.component.toast.text.color)
            .padding(.horizontal, theme.space4 * k)
            .frame(height: theme.component.toast.height * k)
            .background(theme.component.toast.bg.color, in: RoundedRectangle(cornerRadius: theme.component.toast.radius * k))
    }
}

@MainActor
public final class ThemeThumbnailCache {
    private var images: [ResolvedTheme: CGImage] = [:]
    public private(set) var renderCount = 0
    public let scale: CGFloat

    public init(scale: CGFloat = 0.4) { self.scale = scale }

    public func thumbnail(for theme: ResolvedTheme, displayScale: CGFloat = 2) -> CGImage? {
        if let cached = images[theme] { return cached }
        let renderer = ImageRenderer(content: ThemePreviewView(theme: theme, scale: scale))
        renderer.scale = displayScale
        guard let image = renderer.cgImage else { return nil }
        renderCount += 1
        images[theme] = image
        return image
    }

    public func removeAll() { images.removeAll() }
}
