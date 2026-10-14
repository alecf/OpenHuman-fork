import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized)
struct DesignCoreRestTests {
    @Test func dateHeadersAreRowsTheCursorAndClicksSkip() async throws {
        let (controller, model, _, window) = try await ThreadListViewTests.list(threads: 60)
        defer { window.close() }
        let table = controller.tableView
        #expect(model.groups.isEmpty && table.numberOfRows == model.displayCount, "off for a list built on its own")

        controller.showsDateGroups = true
        try await until { !model.groups.isEmpty && table.numberOfRows == model.displayCount }
        window.contentView?.layoutSubtreeIfNeeded()
        let headers = model.groups.headers
        for (index, header) in headers.enumerated() {
            let display = model.groups.displayIndex(ofHeader: index)
            #expect(!controller.tableView(table, shouldSelectRow: display), "\(header.title)")
            if let view = table.view(atColumn: 0, row: display, makeIfNecessary: true) as? ThreadGroupHeaderView {
                #expect(view.title == header.title)
            } else {
                Issue.record("row \(display) is not a header view")
            }
        }
        for _ in 0..<12 { model.moveCursor(by: 1) }
        let cursor = try #require(model.cursor)
        #expect(table.selectedRow == model.displayIndex(of: cursor))
        #expect(model.header(atDisplay: table.selectedRow) == nil)
        let firstHeader = model.groups.displayIndex(ofHeader: 0)
        controller.handleClick(row: firstHeader, extending: false, toggling: false)
        #expect(model.cursor == cursor)

        controller.showsDateGroups = false
        try await until { model.groups.isEmpty && table.numberOfRows == model.rows.count + model.placeholderCount }
    }

    @Test func aRowLeavingKeepsHeadersAndRowsInStep() async throws {
        let host = StubListHost()
        let (controller, model, _, window) = try await ThreadListViewTests.list(threads: 40, host: host)
        defer { window.close() }
        controller.showsDateGroups = true
        let table = controller.tableView
        try await until { !model.groups.isEmpty && table.numberOfRows == model.displayCount }
        let header = try #require(model.groups.headers.dropFirst().first ?? model.groups.headers.first)
        let target = model.rows[header.row].id
        #expect(controller.performRowAction(.markDone, key: target))
        #expect(table.numberOfRows == model.displayCount)
        #expect(model.index(of: target) == nil)
        if let cursor = model.cursor { #expect(table.selectedRow == model.displayIndex(of: cursor)) }
    }


    @Test func aRunOfCollapsedMessagesIsOneFlatRun() async throws {
        let detail = UIFixtures.conversation(4, count: 6)
        var bodies: [MessageKey: MessageContent] = [:]
        for message in detail.messages { bodies[message.id] = MessageContent(html: nil, text: "Hi") }
        let h = try await ReaderHarness.make(UITestSource(details: [detail], bodies: bodies), thread: detail.id)
        defer { h.close() }
        try await until { h.model.messages.count == 6 }
        let items = h.model.items
        let expected = ReaderCardGroups.segments(items) { key in h.model.message(key)?.isExpanded == false }
        try await until { h.controller.cardSegments == expected }
        #expect(expected.contains(.first) && expected.contains(.last), "older collapsed messages share a card")
        for (item, segment) in zip(items, expected) {
            guard case .message(let key) = item else { continue }
            #expect(h.controller.messageViews[key]?.cardSegment == segment)
            #expect(h.controller.messageViews[key]?.card.segment == segment)
            if let view = h.controller.messageViews[key], !view.isExpanded, !view.isFocused {
                #expect(view.cardAppearance == .flat, "an idle collapsed row is flat on the canvas")
            }
        }
        h.model.showAllMessages()
        try await until { !h.controller.cardSegments.isEmpty && h.controller.cardSegments.count == h.model.items.count }
        #expect(h.controller.cardSegments.filter { $0 == .middle }.count >= 1)
    }

    @Test func theListAndTheReaderFollowTheDensity() {
        for density in ThemeDensity.allCases {
            var theme = ThemeTokens.light
            theme.density = density
            let style = ThreadRowStyle(theme: theme)
            #expect(style.plateInsetY == CGFloat(theme.listPlateInsetY) && style.hoverTarget == CGFloat(theme.listHoverTarget))
            let pill = OlderMessagesPillView(count: 3, theme: theme)
            pill.layoutSubtreeIfNeeded()
            #expect(pill.fittingSize.height == CGFloat(theme.collapsedMessageRow + theme.space2), "\(density)")
        }
    }
}
