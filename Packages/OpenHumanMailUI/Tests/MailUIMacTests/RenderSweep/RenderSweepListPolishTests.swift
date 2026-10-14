import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import Testing
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.builtIns)
    func listChipPalette(_ theme: SweepTheme) async throws {
        let labels: [(String, String)] = [
            ("Family", "#f691b3"), ("Clients", "#fb4c2f"), ("Orders", "#ffad47"), ("Notes", "#fad165"),
            ("Receipts", "#16a766"), ("Ops", "#2da2bb"), ("Hiring", "#4a86e8"), ("Atlas", "#a479e2"),
        ]
        var rows: [ListPolishRow] = labels.enumerated().map { index, label in
            ListPolishRow(subject: "Sample \(label.0.lowercased()) subject", unread: index.isMultiple(of: 3),
                          chips: [ThreadRowChip(kind: .label, title: label.0, color: label.1),
                                  ThreadRowChip(kind: .category, title: ["Marketing", "News", "Updates", "Pitch"][index % 4])])
        }
        rows.append(ListPolishRow(subject: "Neutral chips", unread: false,
                                  chips: [ThreadRowChip(kind: .vip, title: "VIP"), ThreadRowChip(kind: .important, title: "Important"),
                                          ThreadRowChip(kind: .label, title: "Travel"), ThreadRowChip(kind: .overflow, title: "+2")]))
        rows.append(ListPolishRow(subject: "Muted fallback category", unread: false,
                                  chips: [ThreadRowChip(kind: .category, title: "Meeting", isFallback: true)]))
        let window = ListPolishWindow(rows: rows, theme: theme)
        defer { window.close() }
        try await sweepShoot(window.window, screen: "list-chip-palette", theme: theme)
    }

    @Test(arguments: SweepTheme.builtInsAndIncreaseContrast)
    func listRowStates(_ theme: SweepTheme) async throws {
        let chips = [ThreadRowChip(kind: .label, title: "Clients", color: "#fb4c2f"), ThreadRowChip(kind: .category, title: "Updates")]
        let states: [ListPolishRow.State] = [.idle, .hover, .cursor, .cursorHover, .checked, .cursorChecked, .unread, .muted]
        let rows = states.map { ListPolishRow(subject: "Row state: \($0)", unread: $0 == .unread, chips: chips, state: $0) }
        let window = ListPolishWindow(rows: rows, theme: theme)
        defer { window.close() }
        try await sweepShoot(window.window, screen: "list-row-states", theme: theme)
    }

    @Test(arguments: SweepTheme.builtIns)
    func searchResults(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        #expect(w.router.perform(.search))
        try await until { OverlayFocusKeeper.control(of: w.window.firstResponder) is NSTextField }
        let editor = try #require(w.window.firstResponder as? NSTextView)
        editor.insertText("e", replacementRange: editor.selectedRange())
        let model = w.environment.overlays.search
        try await until { model.shownQuery == "e" && w.router.list?.state == .loaded && w.router.list?.rows.isEmpty == false }
        try await until {
            if w.window.firstResponder === w.content.tableView { return true }
            _ = model.focusResults()
            return false
        }
        for _ in 0..<2 { w.router.perform(.nextThread) }
        try await sweepShoot(w.window, screen: "search-results", theme: theme)
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func listTailEnd(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        let root = try #require(w.window.contentView)
        let table = try #require(subviews(of: ThreadTableView.self, in: root).first)
        table.scrollRowToVisible(table.numberOfRows - 1)
        try await sweepShoot(w.window, screen: "list-tail-end", theme: theme)
    }
}

extension SweepTheme {
    static var builtInsAndIncreaseContrast: [SweepTheme] {
        builtIns + accessibility.filter { $0.increaseContrast }
    }
}

struct ListPolishRow {
    enum State: String, CustomStringConvertible {
        case idle, hover, cursor, cursorHover, checked, cursorChecked, unread, muted
        var description: String { rawValue }
    }

    var subject: String
    var unread: Bool
    var chips: [ThreadRowChip]
    var state: State = .idle
}

@MainActor
struct ListPolishWindow {
    let window: NSWindow

    init(rows: [ListPolishRow], theme: SweepTheme, width: CGFloat = 1000) {
        let tokens = theme.makeStore().resolved.tokens
        let style = ThreadRowStyle(theme: tokens)
        let height = style.rowHeight * CGFloat(rows.count) + 2 * style.rowHeight
        let size = NSSize(width: width, height: height)
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = tokens.bgWindow.nsColor.cgColor
        window.contentView = root
        window.orderFrontRegardless()
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let actions: [ThreadRowView.HoverAction] = [
            .init(action: .markDone, symbol: "checkmark", title: "Mark done"),
            .init(action: ThreadListActionIDs.snooze, symbol: "clock", title: "Snooze"),
            .init(action: .remind, symbol: "bell", title: "Remind me"),
        ]
        for (index, item) in rows.enumerated() {
            let rowView = ThreadRowBackgroundView(style: style)
            rowView.frame = NSRect(x: 0, y: height - style.rowHeight * CGFloat(index + 2), width: width, height: style.rowHeight)
            let cell = ThreadRowView(style: style)
            cell.frame = rowView.bounds
            cell.hoverActions = { actions }
            let row = ThreadRow(id: ThreadKey(account: AccountID(1), rowID: Int64(index + 1), gmailThreadID: GmailThreadID("p\(index)")),
                                subject: item.subject, snippet: "A short invented snippet for the polish render",
                                participantsDisplay: ["Dana Ruiz", "Sam Lee", "Robin Example"][index % 3], participants: [],
                                messageCount: 1, unreadCount: item.unread ? 1 : 0, draftCount: 0, attachmentCount: 0,
                                isUnread: item.unread, isStarred: false, isImportant: false, userLabelIDs: [],
                                lastMessageAt: now, sortAt: now)
            let muted = item.state == .muted
            let texts = style.texts(for: row, chips: item.chips, format: ThreadRowFormatting(), location: .system(.inbox),
                                    muted: muted)
            let checked = item.state == .checked || item.state == .cursorChecked
            cell.configure(row, texts: texts, date: style.date("OCT 8", unread: item.unread && !muted, upcoming: false),
                           indicators: muted ? [.muted] : [], isChecked: checked, isMuted: muted)
            rowView.isChecked = checked
            rowView.addSubview(cell)
            root.addSubview(rowView)
            if [.cursor, .cursorHover, .cursorChecked].contains(item.state) { rowView.isSelected = true }
            if [.hover, .cursorHover].contains(item.state) { cell.setHovering(true) }
            cell.layoutSubtreeIfNeeded()
        }
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}
