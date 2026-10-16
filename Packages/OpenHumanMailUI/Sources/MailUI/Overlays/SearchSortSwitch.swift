import MailFeatures
import MailModel
import SwiftUI

struct SearchSortSwitch: View {
    let query: String
    let model: SearchRankingModel
    @Environment(\.theme) private var theme

    var body: some View {
        let current = model.sort(for: query)
        HStack(spacing: theme.space3) {
            ForEach(SearchSortOrder.allCases, id: \.self) { order in
                Button(order.title) { model.setSort(order, for: query) }
                    .buttonStyle(.plain)
                    .font(theme.typeLabel.swiftUIFont)
                    .foregroundStyle((order == current ? theme.textPrimary : theme.textTertiary).color)
                    .accessibilityAddTraits(order == current ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sort search results")
        .help("Most relevant or most recent first, for this search")
    }
}
