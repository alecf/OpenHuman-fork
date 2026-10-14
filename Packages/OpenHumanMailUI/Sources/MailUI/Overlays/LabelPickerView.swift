import MailFeatures
import MailModel
import MailTheme
import SwiftUI

struct LabelPickerView: View {
    let model: LabelPickerModel
    let dismiss: () -> Void
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        OverlayCard(width: OverlayMetrics.labelPickerWidth, top: OverlayMetrics.timePickerTop,
                    radius: theme.component.palette.radius, sheet: true, dismiss: dismiss) {
            VStack(spacing: 0) {
                OverlaySheetTitle(symbol: model.mode == .move ? "folder" : "tag", title: model.title)
                OverlaySheetDivider()
                HStack(spacing: theme.space4) {
                    TextField(model.title, text: Binding(get: { model.query }, set: { model.query = $0 }),
                              prompt: Text(model.placeholder).foregroundStyle(theme.component.palette.text.color))
                        .textFieldStyle(.plain)
                        .font(theme.typePaletteInput.swiftUIFont)
                        .foregroundStyle(theme.component.palette.textSelected.color)
                        .overlayInputLine(theme.typePaletteInput)
                        .focused($focused)
                        .onSubmit { model.confirm() }
                        .overlayKeys(up: { model.moveCursor(by: -1) }, down: { model.moveCursor(by: 1) }, escape: dismiss)
                        .onKeyPress(.space) {
                            guard model.query.isEmpty, model.mode == .label else { return .ignored }
                            model.toggleCursor()
                            return .handled
                        }
                        .accessibilityLabel(model.title)
                }
                .padding(.horizontal, OverlayMetrics.rowIconX)
                .frame(height: OverlayMetrics.pickerInputHeight)
                .overlay(alignment: .leading) { OverlayInputBar() }
                .layoutPriority(1)
                OverlaySheetDivider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                            if let header = model.header(before: index) {
                                OverlayGroupHeader(title: header, height: theme.component.palette.groupHeight)
                            }
                            if row.isEnabled {
                                rowView(row, isCursor: index == model.cursor)
                            } else {
                                disabledRowView(row)
                            }
                        }
                    }
                    .padding(.vertical, theme.space2)
                }
                .frame(minHeight: min(listHeight, theme.component.picker.rowHeight * 2), maxHeight: listHeight)
                if model.rows.isEmpty {
                    Text("No labels").font(theme.typeBody.swiftUIFont).foregroundStyle(theme.component.palette.text.color)
                        .frame(height: 64)
                }
            }
        }
        .task { focused = true }
    }

    private var listHeight: CGFloat {
        min(CGFloat(model.rows.count) * theme.component.picker.rowHeight
            + CGFloat(Self.headerCount(model)) * theme.component.palette.groupHeight + theme.space2 * 2,
            OverlayMetrics.paletteListMaxHeight)
    }

    static func headerCount(_ model: LabelPickerModel) -> Int {
        model.rows.indices.filter { model.header(before: $0) != nil }.count
    }

    private func disabledRowView(_ row: LabelPickerModel.Row) -> some View {
        let dimmed = theme.component.palette.rowDisabled
        return HStack(spacing: theme.space4) {
            leading(row, color: dimmed)
            HighlightedText(text: row.title, matched: row.matched, color: dimmed, style: theme.typePaletteRow)
                .layoutPriority(1)
            if let tag = row.tag { tagView(tag, color: dimmed) }
            if let reason = row.disabledReason {
                Text(reason)
                    .font(theme.typeBody.swiftUIFont)
                    .foregroundStyle(dimmed.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OverlayMetrics.rowIconX)
        .frame(height: theme.component.picker.rowHeight)
        .help(row.disabledReason ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), unavailable, \(row.disabledReason ?? "")")
    }

    @ViewBuilder
    private func leading(_ row: LabelPickerModel.Row, color: ThemeColor) -> some View {
        switch row.kind {
        case .create:
            symbol("plus", color: color)
        case .label(let label):
            if let check = row.check { checkbox(check) }
            Circle().fill(self.color(of: label)).frame(width: OverlayMetrics.colorDot, height: OverlayMetrics.colorDot)
        case .place(let place):
            symbol(Self.symbol(of: place), color: color)
        case .split:
            symbol("rectangle.split.3x1", color: color)
        case .addSender:
            symbol("person.crop.circle.badge.plus", color: color)
        }
    }

    private func symbol(_ name: String, color: ThemeColor) -> some View {
        Image(systemName: name).frame(width: OverlayMetrics.checkboxSize).foregroundStyle(color.color)
    }

    static func symbol(of place: MovePlace) -> String {
        switch place {
        case .inbox: "tray.and.arrow.down"
        case .important: "exclamationmark.circle"
        case .other: "tray"
        }
    }

    private func tagView(_ tag: String, color: ThemeColor) -> some View {
        Text(tag)
            .font(theme.typeLabel.swiftUIFont)
            .foregroundStyle(color.color)
            .lineLimit(1)
            .fixedSize()
    }

    private func rowView(_ row: LabelPickerModel.Row, isCursor: Bool) -> some View {
        Button { model.choose(row) } label: {
            HStack(spacing: theme.space4) {
                leading(row, color: theme.textSecondary)
                HStack(spacing: 0) {
                    if let path = row.parentPath {
                        Text(path).font(theme.typePaletteRow.swiftUIFont).foregroundStyle(theme.component.palette.text.color)
                    }
                    HighlightedText(text: row.title, matched: row.matched,
                                    color: isCursor ? theme.component.palette.textSelected : theme.component.palette.text,
                                    style: theme.typePaletteRow)
                }
                if let tag = row.tag { tagView(tag, color: theme.component.palette.text) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, OverlayMetrics.rowIconX)
            .frame(height: theme.component.picker.rowHeight)
            .background(CursorRowBackground(isCursor: isCursor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.title)
        .accessibilityValue(accessibilityValue(row.check))
        .accessibilityAddTraits(isCursor ? .isSelected : [])
    }

    private func accessibilityValue(_ check: LabelPickerModel.CheckState?) -> String {
        switch check {
        case .on?: "applied"
        case .mixed?: "applied to some"
        default: ""
        }
    }

    private func checkbox(_ state: LabelPickerModel.CheckState) -> some View {
        let size = OverlayMetrics.checkboxSize
        return ZStack {
            RoundedRectangle(cornerRadius: theme.radiusSM)
                .fill(state == .off ? Color.clear : theme.accentFill.color)
            RoundedRectangle(cornerRadius: theme.radiusSM).strokeBorder(theme.borderControl.color, lineWidth: theme.borderWidthControl)
            if state == .on {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.accentOnFill.color)
            } else if state == .mixed {
                Image(systemName: "minus").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.accentOnFill.color)
            }
        }
        .frame(width: size, height: size)
    }

    private func color(of label: LabelInfo) -> Color {
        guard let hex = label.colorBackground, hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else {
            return theme.textTertiary.color
        }
        return Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255, opacity: 1)
    }
}
