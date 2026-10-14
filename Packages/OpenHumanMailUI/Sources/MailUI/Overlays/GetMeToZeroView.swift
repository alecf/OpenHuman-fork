import MailFeatures
import SwiftUI

struct GetMeToZeroView: View {
    let model: GetMeToZeroModel
    let dismiss: () -> Void
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        OverlayCard(width: OverlayMetrics.timePickerWidth, top: OverlayMetrics.timePickerTop, radius: theme.radiusXL,
                    dismiss: dismiss) {
            VStack(spacing: 0) {
                header
                Divider().overlay(theme.borderHairline.color)
                ForEach(Array(GetMeToZeroModel.Age.allCases.enumerated()), id: \.element.id) { index, age in
                    ageRow(age, number: index + 1)
                }
                Divider().overlay(theme.borderHairline.color)
                toggle("Keep unread", key: "U", isOn: Binding(get: { model.keepUnread }, set: { model.keepUnread = $0 }))
                toggle("Keep starred", key: "S", isOn: Binding(get: { model.keepStarred }, set: { model.keepStarred = $0 }))
                Divider().overlay(theme.borderHairline.color)
                confirmRow
                Divider().overlay(theme.borderHairline.color)
                Text(model.footer)
                    .font(theme.typeCaption.swiftUIFont)
                    .foregroundStyle(theme.textTertiary.color)
                    .padding(.horizontal, OverlayMetrics.rowIconX)
                    .padding(.vertical, theme.space3)
                    .frame(maxWidth: .infinity, minHeight: OverlayMetrics.footerHeight, alignment: .leading)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.escape) { dismiss(); return .handled }
            .onKeyPress(.return, phases: .down) { _ in model.confirm(); return .handled }
            .onKeyPress(characters: .alphanumerics, phases: .down) { press in
                switch press.characters.lowercased() {
                case "u": model.keepUnread.toggle()
                case "s": model.keepStarred.toggle()
                default:
                    guard let digit = Int(press.characters) else { return .ignored }
                    return model.chooseNumber(digit) ? .handled : .ignored
                }
                return .handled
            }
        }
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(spacing: theme.space4) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: OverlayMetrics.rowIconSize))
                .foregroundStyle(theme.textTertiary.color)
            Text(model.title)
                .font(theme.typePaletteInput.swiftUIFont)
                .foregroundStyle(theme.textPrimary.color)
            Spacer()
        }
        .padding(.horizontal, OverlayMetrics.rowIconX)
        .frame(height: OverlayMetrics.pickerInputHeight)
        .accessibilityAddTraits(.isHeader)
    }

    private func ageRow(_ age: GetMeToZeroModel.Age, number: Int) -> some View {
        let isChosen = model.age == age
        return Button { model.age = age } label: {
            HStack(spacing: 0) {
                KeycapView(text: "\(number)").padding(.leading, OverlayMetrics.rowIconX).frame(width: 48, alignment: .leading)
                Text(age.title)
                    .font(isChosen ? theme.typeBodyStrong.swiftUIFont : theme.typeBody.swiftUIFont)
                    .foregroundStyle(isChosen ? theme.accentText.color : theme.textPrimary.color)
                Spacer(minLength: theme.space5)
            }
            .padding(.trailing, OverlayMetrics.rowIconX)
            .frame(height: theme.component.picker.rowHeight)
            .background(CursorRowBackground(isCursor: isChosen))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(age.title)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private func toggle(_ title: String, key: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Toggle(isOn: isOn) {
                Text(title).font(theme.typeBody.swiftUIFont).foregroundStyle(theme.textPrimary.color)
            }
            .ohCheckboxToggleStyle()
            Spacer()
            KeycapView(text: key)
        }
        .padding(.horizontal, OverlayMetrics.rowIconX)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }

    private var confirmRow: some View {
        Button { model.confirm() } label: {
            HStack {
                if model.isLoading {
                    Text("Counting…").font(theme.typeBody.swiftUIFont).foregroundStyle(theme.textSecondary.color)
                } else if let error = model.loadError {
                    Text(error).font(theme.typeBody.swiftUIFont).foregroundStyle(theme.textWarning.color)
                } else if model.matchCount == 0 {
                    Text("Nothing to archive with these choices")
                        .font(theme.typeBody.swiftUIFont).foregroundStyle(theme.textSecondary.color)
                } else {
                    Text(model.confirmTitle + (model.isPartial ? " (the newest part of a large inbox)" : ""))
                        .font(theme.typeBodyStrong.swiftUIFont).foregroundStyle(theme.accentText.color)
                }
                Spacer()
                KeycapView(text: "↵")
            }
            .padding(.horizontal, OverlayMetrics.rowIconX)
            .frame(height: theme.component.picker.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isLoading || model.matchCount == 0)
        .accessibilityLabel(model.isLoading ? "Counting" : model.confirmTitle)
    }
}
