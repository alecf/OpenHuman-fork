import AppKit
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI

struct CalendarDayView: View {
    @Bindable var model: CalendarSidebarModel
    let day: CalendarSidebarModel.Day
    var strikesConflicts = false
    var showsHeader = true
    var takeKeys: () -> Void = {}
    var compact = false
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    static let hourHeight: CGFloat = 44
    static let axisWidth: CGFloat = 46
    static let focusAnchor = "calendar.day.focus"
    static let labelRoom: CGFloat = 8

    var body: some View {
        let timeline = model.timeline(for: day)
        VStack(alignment: .leading, spacing: theme.space2) {
            if showsHeader { header }
            if let progress = model.progress {
                Text(progress.text).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                    .accessibilityIdentifier("calendar.day.updating")
            }
            if let note = model.refreshNote {
                Text(note).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                    .accessibilityIdentifier("calendar.day.couldNotRefresh")
            }
            if !timeline.allDay.isEmpty { allDayBars(timeline.allDay) }
            axis(timeline)
            if let note = day.note {
                Text(note).themeFont(theme.typeMeta).foregroundStyle(theme.textWarning.color)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.dayHeader(day))
        .accessibilityIdentifier("calendar.dayView")
    }

    private var header: some View {
        HStack(spacing: theme.space2) {
            Button { takeKeys(); model.moveDayInstantly(by: -1) } label: {
                Image(systemName: "chevron.left").frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(theme.textSecondary.color)
            .help("Previous day  −").accessibilityLabel("Previous day")
            Text(model.dayHeader(day)).themeFont(theme.typeBodyStrong).foregroundStyle(theme.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
            Button { takeKeys(); model.moveDayInstantly(by: 1) } label: {
                Image(systemName: "chevron.right").frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(theme.textSecondary.color)
            .help("Next day  =").accessibilityLabel("Next day")
            if day.isMentioned {
                Image(systemName: "text.bubble").font(.system(size: 11)).foregroundStyle(theme.textTertiary.color)
                    .help("Mentioned in this conversation").accessibilityLabel("Mentioned in this conversation")
            }
            Spacer(minLength: 0)
            Button("Today") { takeKeys(); model.goToTodayInstantly() }
                .buttonStyle(.borderless).themeFont(theme.typeMeta).help("Today  T")
        }
        .accessibilityIdentifier("calendar.dayView.header")
    }

    private func allDayBars(_ events: [CalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(events) { event in
                let color = Self.calendarColor(CalendarDayTimeline.colorIndex(for: event), theme: theme)
                Text(event.title).themeFont(theme.typeCaption).foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, theme.space2).padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.22)))
                    .accessibilityLabel("\(event.title), all day")
            }
        }
        .padding(.leading, Self.axisWidth)
        .accessibilityIdentifier("calendar.dayView.allDay")
    }

    private func axis(_ timeline: CalendarDayTimeline) -> some View {
        let height = Self.hourHeight * CGFloat(CalendarDayTimeline.hours.count)
        return VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: timeline.zoneLabel)
                .themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                .frame(width: Self.axisWidth - theme.space2, alignment: .trailing)
                .help(model.zonesText)
                .accessibilityLabel(model.zonesText)
                .accessibilityIdentifier("calendar.dayView.zone")
            axisScroll(timeline, height: height)
        }
        .accessibilityIdentifier("calendar.dayView.axis")
    }

    private func axisScroll(_ timeline: CalendarDayTimeline, height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    scrollMarker(timeline, height: height)
                    hourLabels(timeline, height: height)
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        ZStack(alignment: .topLeading) {
                            hourLines(timeline, width: width, height: height)
                            if let focus = timeline.focus { focusSlot(focus, width: width, height: height) }
                            ForEach(timeline.blocks) { block in eventBlock(block, width: width, height: height) }
                            if let now = timeline.now { nowLine(at: now, width: width, height: height) }
                        }
                    }
                    .frame(height: height)
                }
                .padding(.top, Self.labelRoom)
                .padding(.bottom, theme.space2)
            }
            .frame(minHeight: compact ? 132 : 220, idealHeight: compact ? 176 : 360, maxHeight: compact ? 176 : 420)
            .onAppear { scrollToFocus(timeline, proxy) }
            .onChange(of: timeline.focus) { scrollToFocus(timeline, proxy) }
            .onChange(of: day.start) { scrollToFocus(timeline, proxy) }
        }
    }

    private func scrollMarker(_ timeline: CalendarDayTimeline, height: CGFloat) -> some View {
        let span: (top: Double, height: Double)? = timeline.focus.map { ($0.top, $0.height) } ?? timeline.now.map { ($0, 0) }
        return VStack(spacing: 0) {
            if let span {
                Color.clear.frame(width: 1, height: CGFloat(span.top) * height)
                Color.clear.frame(width: 1, height: max(CGFloat(span.height) * height, 1)).id(Self.focusAnchor)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 1, height: height, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func scrollToFocus(_ timeline: CalendarDayTimeline, _ proxy: ScrollViewProxy) {
        guard timeline.focus != nil || timeline.now != nil else { return }
        DispatchQueue.main.async { proxy.scrollTo(Self.focusAnchor, anchor: .center) }
    }

    private func hourLabels(_ timeline: CalendarDayTimeline, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(timeline.hourMarks, id: \.date) { mark in
                Text(mark.date.formatted(Date.FormatStyle(timeZone: model.timeZone).hour()))
                    .themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                    .frame(width: Self.axisWidth - theme.space2, alignment: .trailing)
                    .offset(y: CGFloat(mark.offset) * height - 7)
            }
        }
        .frame(width: Self.axisWidth, height: height, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func hourLines(_ timeline: CalendarDayTimeline, width: CGFloat, height: CGFloat) -> some View {
        ForEach(timeline.hourMarks, id: \.date) { mark in
            Rectangle().fill(theme.borderHairline.color)
                .frame(width: width, height: theme.borderWidthHairline)
                .offset(y: CGFloat(mark.offset) * height)
        }
    }

    private func focusSlot(_ focus: CalendarDayTimeline.Span, width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(theme.accentSubtle.color)
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(theme.accentFill.color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            .frame(width: width, height: max(CGFloat(focus.height) * height, 12))
            .offset(y: CGFloat(focus.top) * height)
            .help(model.timeText(focus.start, focus.end))
            .accessibilityLabel("Proposed time, \(model.timeText(focus.start, focus.end))")
            .accessibilityIdentifier("calendar.dayView.focus")
    }

    private func eventBlock(_ block: CalendarDayTimeline.Block, width: CGFloat, height: CGFloat) -> some View {
        let gap: CGFloat = 2
        let columnWidth = (width - gap * CGFloat(block.columns - 1)) / CGFloat(max(block.columns, 1))
        let color = Self.calendarColor(block.colorIndex, theme: theme)
        let struck = strikesConflicts && block.isConflict
        let blockHeight = max(CGFloat(block.height) * height - 1, 14)
        return HStack(alignment: .top, spacing: theme.space1) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 0) {
                Text(block.event.title)
                    .themeFont(theme.typeCaption).fontWeight(.medium)
                    .foregroundStyle((struck ? theme.textTertiary : theme.textPrimary).color)
                    .strikethrough(struck)
                    .lineLimit(blockHeight > 30 ? 2 : 1)
                if blockHeight > 26 {
                    Text(model.timeText(block.event.start, block.event.end))
                        .themeFont(theme.typeCaption).foregroundStyle(theme.textSecondary.color)
                        .strikethrough(struck)
                        .lineLimit(1)
                }
                if let account = block.event.account, blockHeight > 40 {
                    Text(verbatim: account).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityLabel("Calendar of \(account)")
                }
            }
            Spacer(minLength: 0)
            if let link = block.event.meetLink, blockHeight > 18 {
                Button { openURL(link) } label: { Image(systemName: "video").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(theme.textSecondary.color)
                    .help("Join Google Meet").accessibilityLabel("Join Google Meet")
                    .accessibilityIdentifier("calendar.event.meet")
            }
        }
        .padding(.trailing, theme.space1)
        .frame(width: max(columnWidth, 8), height: blockHeight, alignment: .topLeading)
        .clipped()
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(block.isConflict ? 0.28 : 0.18)))
        .overlay {
            if block.isConflict {
                RoundedRectangle(cornerRadius: 4).strokeBorder(theme.textDanger.color, lineWidth: 1.5)
            }
        }
        .offset(x: CGFloat(block.column) * (columnWidth + gap), y: CGFloat(block.top) * height)
        .help(block.event.title + "\n" + model.timeText(block.event.start, block.event.end)
              + (block.event.account.map { "\n" + $0 } ?? ""))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(block.isConflict
            ? "\(block.event.title), \(model.timeText(block.event.start, block.event.end)), conflicts with the proposed time"
            : "\(block.event.title), \(model.timeText(block.event.start, block.event.end))")
        .accessibilityIdentifier(block.isConflict ? "calendar.dayView.conflict" : "calendar.dayView.event")
    }

    private func nowLine(at offset: Double, width: CGFloat, height: CGFloat) -> some View {
        let y = CGFloat(offset) * height
        return ZStack(alignment: .leading) {
            Rectangle().fill(theme.textDanger.color).frame(width: width, height: 1.5)
            Circle().fill(theme.textDanger.color).frame(width: 8, height: 8).offset(x: -4)
        }
        .frame(width: width, height: 8)
        .offset(y: y - 4)
        .accessibilityLabel("Now")
        .accessibilityIdentifier("calendar.dayView.now")
    }

    static func calendarColor(_ index: Int, theme: ResolvedTheme) -> Color {
        let palette: [ThemeColor] = [theme.accentFill, theme.textAI, theme.textSuccess, theme.textWarning, theme.textLink,
                                     theme.textSecondary]
        return palette[((index % palette.count) + palette.count) % palette.count].color
    }
}

struct CalendarSidebarBottomBar: View {
    let model: CalendarSidebarModel
    let router: AppRouter
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space3) {
            Image(systemName: "person.crop.circle").foregroundStyle(theme.textSecondary.color)
                .help(model.calendarLine)
                .accessibilityLabel(model.calendarLine)
            Text(model.calendarLine).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button {
                _ = router.environment.actions.perform(.settingsPage("calendar"), source: .toolbar, host: router)
            } label: {
                Image(systemName: "gearshape").foregroundStyle(theme.textSecondary.color).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Calendar settings")
            .accessibilityLabel("Calendar settings")
            .accessibilityIdentifier("calendar.settings")
        }
        .padding(.horizontal, theme.space5)
        .padding(.vertical, theme.space3)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.borderHairline.color).frame(height: theme.borderWidthHairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.bottomBar")
    }
}
