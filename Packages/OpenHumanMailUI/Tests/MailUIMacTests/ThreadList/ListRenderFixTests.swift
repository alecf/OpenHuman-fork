import AppKit
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import Testing
@testable import MailUIMac

@MainActor
struct ListRenderFixTests {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    private func row(unread: Bool = true) -> ThreadRow {
        ThreadRow(id: ThreadKey(account: AccountID(1), rowID: 9, gmailThreadID: GmailThreadID("t9")),
                  subject: String(repeating: "Quarterly planning notes ", count: 8),
                  snippet: String(repeating: "Agenda and the room list ", count: 8), participantsDisplay: "Robin",
                  participants: [], messageCount: 1, unreadCount: unread ? 1 : 0, draftCount: 0, attachmentCount: 0,
                  isUnread: unread, isStarred: false, isImportant: false, userLabelIDs: [], lastMessageAt: now,
                  sortAt: now)
    }

    private static let actions: [ThreadRowView.HoverAction] = [
        .init(action: .markDone, symbol: "checkmark", title: "Mark done"),
        .init(action: ThreadListActionIDs.snooze, symbol: "clock", title: "Snooze"),
        .init(action: .remind, symbol: "bell", title: "Remind me"),
        .init(action: ThreadListActionIDs.label, symbol: "tag", title: "Label"),
        .init(action: .trash, symbol: "trash", title: "Trash"),
    ]

    private func cell(_ style: ThreadRowStyle, width: CGFloat = 1000, muted: Bool = false,
                      unread: Bool = true) -> ThreadRowView {
        let cell = ThreadRowView(style: style)
        cell.frame = NSRect(x: 0, y: 0, width: width, height: style.rowHeight)
        cell.hoverActions = { Self.actions }
        let r = row(unread: unread)
        let texts = style.texts(for: r, chips: [], format: ThreadRowFormatting(), location: .system(.inbox), muted: muted)
        let date = style.date("OCT 8", unread: r.isUnread, upcoming: false)
        cell.configure(r, texts: texts, date: date, indicators: muted ? [.muted] : [], isChecked: false, isMuted: muted)
        return cell
    }

    @Test func reusedGroupHeaderLaysOutForItsNewTitle() {
        for theme in [ThemeTokens.light, ThemeTokens.dark] {
            let style = ThreadRowStyle(theme: theme)
            let header = ThreadGroupHeaderView(style: style)
            header.frame = NSRect(x: 0, y: 0, width: 900, height: style.rowHeight)
            header.configure(title: "Today")
            header.layoutSubtreeIfNeeded()
            let short = header.labelFrame.width
            header.configure(title: "Last 7 days")
            #expect(header.needsLayout, "a new title asks for layout")
            header.layoutSubtreeIfNeeded()
            let leading = style.metrics.leading, trailing = style.metrics.trailing
            #expect(leading == style.columns(width: 900).sender.lowerBound, "the header lines up with the sender column")
            #expect(header.labelFrame.width == 900 - leading - trailing + 2 * ThreadGroupHeaderView.textInset)
            #expect(header.labelFrame.width >= short)
            #expect(header.title == "Last 7 days")
            #expect(header.labelFrame.minX == leading - ThreadGroupHeaderView.textInset)
            #expect(header.accessibilityLabel() == "Last 7 days")
        }
    }

    @Test func subjectLineStopsBeforeTheActionButtons() throws {
        for theme in [ThemeTokens.light, ThemeTokens.dark] {
            let style = ThreadRowStyle(theme: theme)
            for width in [CGFloat(700), 1000, 1400] {
                let cell = cell(style, width: width)
                let full = cell.subjectLineWidth
                cell.setHovering(true)
                cell.layoutSubtreeIfNeeded()
                let group = try #require(cell.actionGroupFrame, "the hover row shows its actions")
                let c = style.columns(width: width)
                let lineEnd = c.subject.lowerBound + cell.subjectLineWidth
                #expect(lineEnd <= group.minX - CGFloat(style.row.columnGap), "width \(width)")
                #expect(cell.subjectLineWidth < full)
                cell.setHovering(false)
                #expect(cell.actionGroupFrame == nil)
                #expect(cell.subjectLineWidth == full, "without the buttons the line has its full column")
            }
        }
    }

    @Test func mutedRowsAreQuiet() {
        for theme in [ThemeTokens.light, ThemeTokens.dark] {
            let style = ThreadRowStyle(theme: theme)
            let format = ThreadRowFormatting()
            let muted = style.texts(for: row(), chips: [], format: format, location: .system(.inbox), muted: true)
            let plain = style.texts(for: row(), chips: [], format: format, location: .system(.inbox))
            func attributes(_ text: NSAttributedString) -> (NSFont?, NSColor?) {
                (text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                 text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            }
            #expect(attributes(muted.sender).0 == style.bodyFont && attributes(muted.sender).1 == style.secondary)
            #expect(attributes(muted.line).0 == style.bodyFont && attributes(muted.line).1 == style.secondary)
            #expect(attributes(plain.sender).0 == style.strongFont && attributes(plain.sender).1 == style.senderColor,
                    "the cache keys on the muted flag")
            #expect(!cell(style, muted: true).showsUnreadDot, "a muted row never shows the unread dot")
            #expect(cell(style).showsUnreadDot)
        }
    }

    @Test func scheduleViewsKeepTheDateOnTheCursorRow() {
        for location in [MailLocation.system(.snoozed), .system(.reminders), .system(.scheduled)] {
            #expect(!ThreadListViewController.cursorRowShowsActions(in: location), "\(location)")
        }
        #expect(ThreadListViewController.cursorRowShowsActions(in: .system(.inbox)))
        let style = ThreadRowStyle(theme: .light)
        let snoozed = cell(style)
        snoozed.cursorRowShowsActions = false
        snoozed.setCursor(true)
        #expect(!snoozed.showsActions, "the cursor row keeps its wake time")
        snoozed.setHovering(true)
        #expect(snoozed.showsActions, "the pointer still brings the actions")
        let inbox = cell(style)
        inbox.setCursor(true)
        #expect(inbox.showsActions, "elsewhere the cursor row shows its actions (V16)")
    }

    @Test func wideComingTimesAreNotClipped() {
        for theme in [ThemeTokens.light, ThemeTokens.dark] {
            let style = ThreadRowStyle(theme: theme)
            let cell = ThreadRowView(style: style)
            cell.frame = NSRect(x: 0, y: 0, width: 1000, height: style.rowHeight)
            let r = row()
            let date = style.date("THU 12:46 AM", unread: false, upcoming: true)
            let texts = style.texts(for: r, chips: [], format: ThreadRowFormatting(), location: .system(.snoozed))
            cell.configure(r, texts: texts, date: date, indicators: [], isChecked: false)
            let c = style.columns(width: 1000)
            #expect(cell.dateRange.upperBound - cell.dateRange.lowerBound >= ceil(date.size().width))
            #expect(cell.dateRange.upperBound == c.date.upperBound, "still right-aligned on the column's edge")
            let short = style.date("OCT 8", unread: false, upcoming: false)
            cell.configure(r, texts: texts, date: short, indicators: [], isChecked: false)
            #expect(cell.dateRange == c.date, "a date that fits keeps its column")
        }
    }

    @Test func chipsAreNeverSmallerThanElevenPoints() {
        let library = ThemeLibrary.builtIn
        for (id, appearance) in [(BuiltinThemeID.systemLight, ThemeAppearance.light), (BuiltinThemeID.systemDark, .dark),
                                 (BuiltinThemeID.light, .light), (BuiltinThemeID.midnight, .dark)] {
            let theme = library.resolve(themeID: id, appearance: appearance).tokens
            let style = ThreadRowStyle(theme: theme)
            #expect(style.chipType.size >= ThreadRowStyle.minimumChipTextSize, "\(id)")
            #expect(style.chipType.weight == theme.typeCaption.weight, "\(id)")
            #expect(style.chipFont.pointSize == CGFloat(style.chipType.size), "\(id)")
        }
    }

    @Test func loadingTitleIsQuieterThanTheList() {
        let theme = ThemeTokens.light
        let view = ThreadListEmptyView(style: ThreadRowStyle(theme: theme))
        view.show(ThreadListEmptyState(style: .progress, title: "Loading…"), now: now)
        #expect(view.titleAppearance.font?.pointSize == CGFloat(theme.typeBody.size))
        #expect(view.titleAppearance.color == theme.textTertiary.nsColor)
        view.show(ThreadListEmptyState(style: .inboxClear, title: "Inbox zero"), now: now)
        #expect(view.titleAppearance.font?.pointSize == CGFloat(theme.typeTitle.size))
        #expect(view.titleAppearance.color == theme.textPrimary.nsColor)
    }

    @Test(arguments: [
        MailLocation.system(.inbox), .split(SplitKey("github")), .splitOther, .system(.drafts), .system(.trash),
        .system(.starred), .search("zz"),
    ])
    func everyEmptyStateIsPlainTextWithANeutralSymbol(_ location: MailLocation) {
        let theme = ThemeTokens.light
        for width in [260.0, 340.0, 520.0, 900.0] {
            let view = ThreadListEmptyView(style: ThreadRowStyle(theme: theme))
            view.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            let state = ThreadListEmptyState.make(location: location, locationTitle: "GitHub", state: .loaded, hasRows: false,
                                                  loadingShown: false, connectivity: nil, day: 1)
            view.show(state, now: now)
            view.layoutSubtreeIfNeeded()
            let symbol = view.symbolAppearance
            #expect(symbol.shown && symbol.tint == theme.textSecondary.nsColor)
            let frames = view.textFrames
            #expect(!frames.isEmpty)
            var previousMaxY = symbol.frame.maxY
            for frame in frames {
                #expect(frame.minY >= previousMaxY, "no overlap at width \(width)")
                #expect(frame.minX >= 0 && frame.maxX <= width, "no clipping at width \(width)")
                previousMaxY = frame.maxY
            }
            #expect(view.accessibilityLabel() == [state?.title, state?.subtitle, state?.detail].compactMap { $0 }.joined(separator: ". "))
            #expect(view.accessibilityLabel()?.contains("Go do something") == false)
        }
    }

    @Test func nothingInATabIsOneSentenceWithNoSecondLine() {
        let state = ThreadListEmptyState.make(location: .split(SplitKey("github")), locationTitle: "GitHub", state: .loaded,
                                              hasRows: false, loadingShown: false, connectivity: nil, day: 0)
        #expect(state?.title == "Nothing in GitHub." && state?.subtitle == nil)
    }

    @Test func loadingAndFailureShowNoSymbol() {
        let view = ThreadListEmptyView(style: ThreadRowStyle(theme: .light))
        view.show(ThreadListEmptyState(style: .progress, title: "Loading…"), now: now)
        #expect(!view.symbolAppearance.shown)
    }
}
