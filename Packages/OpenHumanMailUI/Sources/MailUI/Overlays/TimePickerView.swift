import MailFeatures
import MailTheme
import SwiftUI

struct TimePickerView: View {
    let model: TimePickerModel
    let dismiss: () -> Void
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        OverlayCard(width: OverlayMetrics.timePickerWidth, top: OverlayMetrics.timePickerTop,
                    radius: theme.component.palette.radius, sheet: true, dismiss: dismiss) {
            VStack(spacing: 0) {
                OverlaySheetTitle(symbol: Self.symbol(model.kind), title: model.title)
                OverlaySheetDivider()
                input
                OverlaySheetDivider()
                if let line = model.currentLine {
                    Text(line)
                        .font(theme.typeBody.swiftUIFont)
                        .foregroundStyle(theme.textSecondary.color)
                        .padding(.horizontal, OverlayMetrics.rowIconX)
                        .frame(maxWidth: .infinity, minHeight: theme.component.picker.rowHeight, alignment: .leading)
                }
                if let hint = model.hint, model.datePick == nil {
                    Text(hint)
                        .font(theme.typeBody.swiftUIFont)
                        .foregroundStyle(theme.textTertiary.color)
                        .padding(.horizontal, OverlayMetrics.rowIconX)
                        .frame(maxWidth: .infinity, minHeight: theme.component.picker.rowHeight, alignment: .leading)
                }
                if model.datePick != nil {
                    datePicker
                } else {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, isCursor: index == model.cursor)
                    }
                    if model.offersOnlyIfNoReply { onlyIfNoReply }
                }
                OverlaySheetDivider()
                Text(model.footer)
                    .font(theme.typeCaption.swiftUIFont)
                    .foregroundStyle(theme.component.palette.text.color)
                    .padding(.horizontal, OverlayMetrics.rowIconX)
                    .padding(.vertical, theme.space3)
                    .frame(maxWidth: .infinity, minHeight: OverlayMetrics.footerHeight, alignment: .leading)
            }
        }
        .task { focused = true }
    }

    private var input: some View {
        HStack(spacing: theme.space4) {
            TextField(model.title, text: Binding(get: { model.text }, set: { model.text = $0 }),
                      prompt: Text(model.placeholder).foregroundStyle(theme.component.palette.text.color))
                .textFieldStyle(.plain)
                .font(theme.typePaletteInput.swiftUIFont)
                .foregroundStyle(theme.component.palette.textSelected.color)
                .overlayInputLine(theme.typePaletteInput)
                .focused($focused)
                .onSubmit { model.confirm() }
                .onKeyPress(.upArrow) { model.datePick == nil ? (model.moveCursor(by: -1), .handled).1 : (model.moveDay(by: -7), .handled).1 }
                .onKeyPress(.downArrow) { model.datePick == nil ? (model.moveCursor(by: 1), .handled).1 : (model.moveDay(by: 7), .handled).1 }
                .onKeyPress(.leftArrow) { model.datePick == nil ? .ignored : (model.moveDay(by: -1), .handled).1 }
                .onKeyPress(.rightArrow) { model.datePick == nil ? .ignored : (model.moveDay(by: 1), .handled).1 }
                .onKeyPress(.escape) {
                    if model.datePick != nil { model.closeDatePick() } else { dismiss() }
                    return .handled
                }
                .onKeyPress(characters: .decimalDigits, phases: .down) { press in
                    guard let digit = press.characters.first.flatMap({ Int(String($0)) }) else { return .ignored }
                    return model.chooseNumber(digit) ? .handled : .ignored
                }
                .accessibilityLabel(model.title)
        }
        .padding(.horizontal, OverlayMetrics.rowIconX)
        .frame(height: OverlayMetrics.pickerInputHeight)
        .overlay(alignment: .leading) { OverlayInputBar() }
        .layoutPriority(1)
    }

    static func symbol(_ kind: TimePickerKind) -> String {
        kind == .remind ? "bell" : kind == .sendLater ? "paperplane" : "clock"
    }

    private func rowFont(strong: Bool) -> TypeStyle {
        var style = theme.typePaletteRow
        if strong { style.weight = theme.typeBodyStrong.weight }
        return style
    }

    private func rowView(_ row: TimePickerModel.Row, isCursor: Bool) -> some View {
        Button { model.choose(row) } label: {
            HStack(spacing: 0) {
                if let number = row.number {
                    KeycapView(text: "\(number)").padding(.leading, OverlayMetrics.rowIconX)
                        .frame(width: 48 - 0, alignment: .leading)
                } else if row.kind == .clearReminder || row.kind == .someday {
                    Image(systemName: row.kind == .someday ? "infinity" : "bell.slash")
                        .font(.system(size: ShellMetrics.rowIconSize))
                        .foregroundStyle(theme.textSecondary.color)
                        .padding(.leading, OverlayMetrics.rowIconX)
                        .frame(width: 48, alignment: .leading)
                } else {
                    Color.clear.frame(width: 48, height: 1)
                }
                Text(row.title)
                    .font(rowFont(strong: isParsed(row)).swiftUIFont)
                    .foregroundStyle(isParsed(row) ? theme.accentText.color
                                     : (isCursor ? theme.component.palette.textSelected : theme.component.palette.text).color)
                    .lineLimit(1)
                Spacer(minLength: theme.space5)
                if let detail = row.detail {
                    Text(detail).font(theme.typeMeta.swiftUIFont).foregroundStyle(theme.textSecondary.color)
                } else if isParsed(row) {
                    KeycapView(text: "↵")
                }
            }
            .padding(.trailing, OverlayMetrics.rowIconX)
            .frame(height: theme.component.picker.rowHeight)
            .background(CursorRowBackground(isCursor: isCursor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.title)
        .accessibilityValue(row.detail ?? "")
        .accessibilityAddTraits(isCursor ? .isSelected : [])
    }

    private func isParsed(_ row: TimePickerModel.Row) -> Bool {
        if case .parsed = row.kind { true } else { false }
    }

    private var onlyIfNoReply: some View {
        OnlyIfNoReplyRow(isOn: Binding(get: { model.onlyIfNoReply }, set: { model.onlyIfNoReply = $0 }))
    }

    private var datePicker: some View { TimePickerDateGrid(model: model) }
}

// Uses palette colours only: the sheet is near-black in every theme and theme colours would resolve light-on-light
struct TimePickerDateGrid: View {
    let model: TimePickerModel
    @Environment(\.theme) private var theme
    @FocusState private var timeFocused: Bool

    private var primary: Color { theme.component.palette.textSelected.color }
    private var secondary: Color { theme.component.palette.text.color }

    var body: some View {
        VStack(spacing: theme.space3) {
            if let grid = model.monthGrid, let pick = model.datePick {
                monthHeader(grid)
                let columns = Array(repeating: GridItem(.fixed(OverlayMetrics.calendarCell), spacing: 0), count: 7)
                LazyVGrid(columns: columns, spacing: 0) {
                    ForEach(Array(model.weekdayInitials.enumerated()), id: \.offset) { _, initial in
                        weekdayCell(initial)
                    }
                    ForEach(grid.days) { day in
                        dayCell(day, selected: day.start == pick.day)
                    }
                }
                timeRow(pick)
            }
        }
        .padding(OverlayMetrics.rowIconX)
    }

    func monthHeader(_ grid: MonthGrid) -> some View {
        HStack {
            chevron("chevron.left", label: "Previous month") { model.moveMonth(by: -1) }
            Spacer()
            Text(model.monthTitle(grid.month))
                .font(theme.typeBodyStrong.swiftUIFont)
                .foregroundStyle(primary)
            Spacer()
            chevron("chevron.right", label: "Next month") { model.moveMonth(by: 1) }
        }
    }

    func weekdayCell(_ initial: String) -> some View {
        Text(initial)
            .font(theme.typeCaption.swiftUIFont)
            .foregroundStyle(secondary)
            .frame(width: OverlayMetrics.calendarCell, height: 22)
            .accessibilityHidden(true)
    }

    func timeRow(_ pick: TimePickerModel.DatePick) -> some View {
        HStack {
            Text("Time").font(theme.typeBody.swiftUIFont).foregroundStyle(secondary)
            TextField("", text: Binding(get: { pick.timeText }, set: { model.setTimeText($0) }),
                      prompt: Text("9:00").foregroundStyle(secondary))
                .textFieldStyle(.plain)
                .font(theme.typeBody.swiftUIFont)
                .foregroundStyle(primary)
                .tint(primary)
                .focused($timeFocused)
                .padding(.horizontal, theme.space3)
                .frame(width: 96, height: 28)
                .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.component.palette.band.color))
                .accessibilityLabel("Time")
                .onSubmit { model.confirm() }
            if let error = model.datePickError {
                Text(error).font(theme.typeCaption.swiftUIFont).foregroundStyle(theme.textWarning.color)
            }
            Spacer()
        }
    }

    private func chevron(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(primary).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    func dayColor(_ day: MonthGrid.Day, selected: Bool) -> Color {
        if selected { return theme.accentOnFill.color }
        if day.start < model.todayStart { return secondary.opacity(day.isInMonth ? 0.75 : 0.6) }
        return day.isInMonth ? primary : secondary.opacity(0.8)
    }

    func dayCell(_ day: MonthGrid.Day, selected: Bool) -> some View {
        let isToday = day.start == model.todayStart
        return Button { model.selectDay(day.start) } label: {
            Text("\(day.number)")
                .font(theme.typeBody.swiftUIFont)
                .foregroundStyle(dayColor(day, selected: selected))
                .frame(width: OverlayMetrics.calendarCell, height: OverlayMetrics.calendarCell)
                .background(Circle().fill(selected ? theme.accentFill.color : Color.clear))
                .overlay(Circle().strokeBorder(isToday && !selected ? theme.accentFill.color : Color.clear, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.start.formatted(Date.FormatStyle(date: .omitted, time: .omitted, locale: model.locale, timeZone: model.timeZone).weekday(.wide).month(.wide).day()))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct OnlyIfNoReplyRow: View {
    @Binding var isOn: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space3) {
            Toggle(isOn: $isOn) { EmptyView() }
                .ohCheckboxToggleStyle()
                .labelsHidden()
            Text(TimePickerModel.onlyIfNoReplyLabel)
                .font(theme.typeBody.swiftUIFont)
                .foregroundStyle(theme.component.palette.textSelected.color)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OverlayMetrics.rowIconX)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TimePickerModel.onlyIfNoReplyLabel)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { isOn.toggle() }
    }
}
