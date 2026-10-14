import MailFeatures
import MailTheme
import SwiftUI

struct SearchDropdownRequest {
    let field: Anchor<CGRect>
    let search: SearchModel
    let cursor: Int
}

struct SearchDropdownKey: PreferenceKey {
    static var defaultValue: SearchDropdownRequest? { nil }

    static func reduce(value: inout SearchDropdownRequest?, nextValue: () -> SearchDropdownRequest?) {
        if value == nil { value = nextValue() }
    }
}

struct SearchDropdownState: Equatable {
    private(set) var closed = false

    func shows(focused: Bool, hasContent: Bool) -> Bool { focused && !closed && hasContent }

    mutating func escape(showing: Bool) -> Bool {
        closed = true
        return showing
    }

    mutating func open() { closed = false }
}

enum SearchDropdownLayout {
    static let rowHeight: CGFloat = 32
    static let headerHeight: CGFloat = 28

    static func contentHeight(rows: Int, headers: Int, interpretation: Bool, padding: CGFloat) -> CGFloat {
        CGFloat(rows) * rowHeight + CGFloat(headers) * headerHeight + (interpretation ? rowHeight : 0) + padding * 2
    }

    static func frame(field: CGRect, container: CGSize, contentHeight: CGFloat, gap: CGFloat, margin: CGFloat) -> CGRect {
        let top = field.maxY + gap
        let available = max(rowHeight, container.height - top - margin)
        return CGRect(x: field.minX, y: top, width: field.width, height: min(contentHeight, available))
    }
}

struct SearchDropdownLayer: View {
    let request: SearchDropdownRequest
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { proxy in
            let field = proxy[request.field]
            let search = request.search
            let suggestions = search.suggestions
            let content = SearchDropdownLayout.contentHeight(
                rows: suggestions.count, headers: SearchDropdownView.headerCount(suggestions, grouped: search.smartSearchEnabled),
                interpretation: search.interpretation.state != .hidden, padding: theme.space2)
            let frame = SearchDropdownLayout.frame(field: field, container: proxy.size, contentHeight: content,
                                                   gap: theme.space2, margin: theme.space5)
            SearchDropdownView(search: search, suggestions: suggestions, cursor: request.cursor, height: frame.height,
                               scrolls: frame.height < content)
                .frame(width: frame.width, height: frame.height)
                .padding(.leading, frame.minX)
                .padding(.top, frame.minY)
        }
        .transaction { $0.disablesAnimations = true }
    }
}

struct SearchDropdownView: View {
    let search: SearchModel
    let suggestions: [SearchSuggestion]
    let cursor: Int
    let height: CGFloat
    let scrolls: Bool
    @Environment(\.theme) private var theme

    static func headerCount(_ suggestions: [SearchSuggestion], grouped: Bool) -> Int {
        guard grouped else { return 0 }
        return suggestions.indices.filter { $0 == 0 || suggestions[$0 - 1].group != suggestions[$0].group }.count
    }

    var body: some View {
        let popover = theme.component.popover
        let shape = RoundedRectangle(cornerRadius: popover.radius)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                rows
                    .padding(.vertical, theme.space2)
            }
            .scrollDisabled(!scrolls)
            .scrollIndicators(scrolls ? .automatic : .hidden)
            .frame(height: height)
            .onChange(of: cursor) { _, cursor in
                guard scrolls, suggestions.indices.contains(cursor) else { return }
                proxy.scrollTo(suggestions[cursor].id)
            }
        }
        .background(shape.fill(popover.bg.color))
        .clipShape(shape)
        .overlay(shape.strokeBorder(popover.border.color, lineWidth: theme.borderWidthHairline))
        .contentShape(shape)
        .themeShadow(popover.shadow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search suggestions")
    }

    private var rows: some View {
        let grouped = search.smartSearchEnabled
        return VStack(spacing: 0) {
            switch search.interpretation.state {
            case .hidden:
                EmptyView()
            case .waiting:
                InterpretationWaitingRow()
            case .ready(let plan):
                InterpretationRow(plan: plan) { _ = search.acceptInterpretation() }
            }
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                if grouped, index == 0 || suggestions[index - 1].group != suggestion.group {
                    groupHeader(suggestion.group)
                }
                row(suggestion, isCursor: index == cursor)
                    .id(suggestion.id)
            }
        }
    }

    private func row(_ suggestion: SearchSuggestion, isCursor: Bool) -> some View {
        Button { search.accept(suggestion) } label: {
            HStack(spacing: theme.space4) {
                Image(systemName: Self.symbol(suggestion.kind))
                    .frame(width: 18)
                    .foregroundStyle(theme.textSecondary.color)
                Text(suggestion.title).font(theme.typeBody.swiftUIFont).foregroundStyle(theme.textPrimary.color).lineLimit(1)
                if let detail = suggestion.detail {
                    Text(detail).font(theme.typeBody.swiftUIFont).foregroundStyle(theme.textTertiary.color)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if isCursor, let last = search.personDetail(suggestion) {
                    Text(last)
                        .font(theme.typeMeta.swiftUIFont)
                        .monospacedDigit()
                        .foregroundStyle(theme.textTertiary.color)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, theme.space4)
            .frame(height: SearchDropdownLayout.rowHeight)
            .background(CursorRowBackground(isCursor: isCursor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(suggestion.title)
        .accessibilityValue([suggestion.detail, isCursor ? search.personDetail(suggestion) : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isCursor ? .isSelected : [])
    }

    private func groupHeader(_ group: SearchSuggestion.Group) -> some View {
        Text(group.rawValue)
            .font(theme.typeLabel.swiftUIFont)
            .foregroundStyle(theme.textTertiary.color)
            .padding(.horizontal, theme.space4)
            .frame(height: SearchDropdownLayout.headerHeight, alignment: .bottomLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    static func symbol(_ kind: SearchSuggestion.Kind) -> String {
        switch kind {
        case .recent: "clock"
        case .saved: "bookmark"
        case .person: "person.crop.circle"
        case .label: "tag"
        case .operator: "text.magnifyingglass"
        }
    }
}
