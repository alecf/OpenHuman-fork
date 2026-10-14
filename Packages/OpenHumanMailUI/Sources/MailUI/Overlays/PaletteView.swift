import MailFeatures
import MailTheme
import SwiftUI

struct PaletteView: View {
    let palette: PaletteController
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        let tokens = theme.component.palette
        OverlayCard(width: tokens.width, top: tokens.top, radius: tokens.radius, sheet: true, topRatio: tokens.topRatio,
                    dismiss: close) {
            VStack(spacing: 0) {
                OverlaySheetTitle(symbol: "command", title: "Commands") {
                    if let scope = palette.scopeSummary { scopeChip(scope) }
                }
                OverlaySheetDivider()
                input(height: tokens.inputHeight)
                OverlaySheetDivider()
                results(tokens)
                OverlaySheetDivider()
                footer(height: tokens.footerHeight)
            }
        }
        .task(id: palette.query) { await palette.loadMail() }
        .task { focused = true }
    }

    private func close() { palette.close() }

    private func input(height: Double) -> some View {
        let scope = palette.scopeSummary
        let tokens = theme.component.palette
        return HStack(spacing: theme.space4) {
            TextField("Command palette", text: Binding(get: { palette.query }, set: { palette.query = $0 }),
                      prompt: Text("Type a command or search…").foregroundStyle(tokens.text.color))
                .textFieldStyle(.plain)
                .font(theme.typePaletteInput.swiftUIFont)
                .foregroundStyle(tokens.textSelected.color)
                .overlayInputLine(theme.typePaletteInput)
                .focused($focused)
                .onSubmit { palette.performSelected() }
                .overlayKeys(up: { palette.moveCursor(by: -1) }, down: { palette.moveCursor(by: 1) }, escape: close)
                .accessibilityLabel(scope.map { "Command palette, acts on \($0)" } ?? "Command palette")
            KeycapView(text: "esc")
        }
        .padding(.horizontal, OverlayMetrics.rowIconX)
        .frame(height: height)
        .overlay(alignment: .leading) { OverlayInputBar() }
        .layoutPriority(1)
    }

    private func scopeChip(_ text: String) -> some View {
        let tokens = theme.component.palette
        return Text(text)
            .font(theme.typeCaption.swiftUIFont)
            .foregroundStyle(tokens.scopeText.color)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, theme.space3)
            .frame(height: tokens.scopeHeight)
            .background(RoundedRectangle(cornerRadius: min(tokens.scopeRadius, tokens.scopeHeight / 2)).fill(tokens.scopeBg.color))
            .frame(maxWidth: tokens.scopeMaxWidth, alignment: .trailing)
            .help(text)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func results(_ tokens: ThemeTokens.Components.Palette) -> some View {
        let sections = PaletteSections(palette.entries)
        if palette.isEmptyResult {
            VStack(spacing: theme.space3) {
                Text("Nothing matches “\(palette.query)”")
                    .font(theme.typeBody.swiftUIFont)
                    .foregroundStyle(tokens.text.color)
                    .padding(.top, theme.space6)
                if let first = sections.rows.first {
                    row(first, cursor: palette.cursor, rowHeight: tokens.rowHeight)
                }
            }
            .frame(height: 120, alignment: .top)
        } else if sections.rows.isEmpty {
            Color.clear.frame(height: theme.space3)
        } else {
            let cursor = palette.cursor
            let height = listHeight(sections, tokens)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sections.groups) { section in
                            OverlayGroupHeader(title: section.group.rawValue, height: tokens.groupHeight)
                            ForEach(section.rows) { item in
                                row(item, cursor: cursor, rowHeight: tokens.rowHeight)
                            }
                        }
                    }
                    .padding(.vertical, theme.space2)
                }
                .frame(minHeight: min(height, tokens.rowHeight * 2 + tokens.groupHeight), maxHeight: height)
                .onChange(of: sections.id(at: cursor)) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func listHeight(_ sections: PaletteSections, _ tokens: ThemeTokens.Components.Palette) -> CGFloat {
        let content = CGFloat(sections.rows.count) * tokens.rowHeight + CGFloat(sections.groups.count) * tokens.groupHeight
            + theme.space2 * 2
        return min(content, OverlayMetrics.paletteListMaxHeight)
    }

    @ViewBuilder
    private func row(_ item: PaletteSections.Row, cursor: Int, rowHeight: Double) -> some View {
        if let reason = item.entry.unavailableReason {
            unavailableRow(item.entry, reason: reason, rowHeight: rowHeight)
        } else {
            availableRow(item.entry, index: item.index, isCursor: item.index == cursor, rowHeight: rowHeight)
        }
    }

    private func unavailableRow(_ entry: PaletteEntry, reason: String, rowHeight: Double) -> some View {
        let dimmed = theme.component.palette.rowDisabled
        return HStack(spacing: 0) {
            rowIcon(entry.symbol, color: dimmed)
            HighlightedText(text: entry.title, matched: entry.matched, color: dimmed, style: theme.typePaletteRow)
            Text(reason)
                .font(theme.typeBody.swiftUIFont)
                .foregroundStyle(dimmed.color)
                .lineLimit(1)
                .padding(.leading, theme.space3)
            Spacer(minLength: theme.space5)
        }
        .padding(.trailing, OverlayMetrics.rowIconX)
        .frame(height: rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.title), unavailable, \(reason)")
    }

    private func availableRow(_ entry: PaletteEntry, index: Int, isCursor: Bool, rowHeight: Double) -> some View {
        let tokens = theme.component.palette
        return Button {
            palette.moveCursor(to: index)
            palette.perform(entry)
        } label: {
            HStack(spacing: 0) {
                rowIcon(entry.symbol, color: entry.isDestructive ? theme.textDanger : tokens.icon)
                HighlightedText(text: entry.title, matched: entry.matched,
                                color: isCursor ? tokens.textSelected : tokens.text, style: theme.typePaletteRow)
                if let detail = entry.detail {
                    Text(detail)
                        .font(theme.typePaletteRow.swiftUIFont)
                        .foregroundStyle(tokens.text.color)
                        .lineLimit(1)
                        .padding(.leading, theme.space3)
                }
                Spacer(minLength: theme.space5)
                if !entry.keycaps.isEmpty { KeycapRow(keycaps: entry.keycaps) }
            }
            .padding(.trailing, OverlayMetrics.rowIconX)
            .frame(height: rowHeight)
            .background(CursorRowBackground(isCursor: isCursor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.title)
        .accessibilityValue(entry.keycaps.joined(separator: " then "))
        .accessibilityAddTraits(isCursor ? .isSelected : [])
    }

    private func rowIcon(_ symbol: String, color: ThemeColor) -> some View {
        CircledSymbol(symbol: symbol, color: color)
            .frame(width: OverlayMetrics.rowLabelX - OverlayMetrics.rowIconX + theme.space3, alignment: .leading)
            .padding(.leading, OverlayMetrics.rowIconX)
    }

    private func footer(height: Double) -> some View {
        HStack(spacing: theme.space7) {
            hint("↑↓", "move")
            hint("↵", palette.selectionCount > 1 ? "run on \(palette.selectionCount) selected" : "run")
            hint("esc", "close")
            Spacer()
        }
        .padding(.horizontal, OverlayMetrics.rowIconX)
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: theme.space2) {
            Text(key).font(theme.typeKeycap.swiftUIFont)
            Text(text).font(theme.typeCaption.swiftUIFont)
        }
        .foregroundStyle(theme.component.palette.text.color)
    }
}

struct PaletteSections {
    struct Row: Identifiable {
        let index: Int
        let entry: PaletteEntry
        var id: String { entry.id }
    }

    struct Group: Identifiable {
        let group: PaletteGroup
        let id: String
        var rows: [Row]
    }

    let rows: [Row]
    let groups: [Group]

    init(_ entries: [PaletteEntry]) {
        let rows = entries.enumerated().map { Row(index: $0.offset, entry: $0.element) }
        var groups: [Group] = []
        var runs: [PaletteGroup: Int] = [:]
        for row in rows {
            if let last = groups.indices.last, groups[last].group == row.entry.group {
                groups[last].rows.append(row)
            } else {
                let run = runs[row.entry.group, default: 0]
                runs[row.entry.group] = run + 1
                groups.append(Group(group: row.entry.group, id: row.entry.group.rawValue + (run > 0 ? "#\(run)" : ""),
                                    rows: [row]))
            }
        }
        self.rows = rows
        self.groups = groups
    }

    func id(at index: Int) -> String? {
        rows.indices.contains(index) ? rows[index].id : nil
    }
}
