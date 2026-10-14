import MailActions
import MailFeatures
import MailTheme
import SwiftUI

struct ShortcutHelpView: View {
    let model: ShortcutHelpModel
    let dismiss: () -> Void
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        OverlayCard(width: 880, top: theme.space10, radius: theme.radiusXL, dismiss: dismiss) {
            VStack(spacing: 0) {
                HStack(spacing: theme.space4) {
                    Image(systemName: "keyboard")
                        .font(.system(size: OverlayMetrics.rowIconSize))
                        .foregroundStyle(theme.textTertiary.color)
                    TextField("Filter shortcuts", text: Binding(get: { model.filter }, set: { model.filter = $0 }),
                              prompt: Text("Filter shortcuts").foregroundStyle(theme.textTertiary.color))
                        .textFieldStyle(.plain)
                        .font(theme.typePaletteInput.swiftUIFont)
                        .overlayInputLine(theme.typePaletteInput)
                        .focused($focused)
                        .onKeyPress(.escape) { dismiss(); return .handled }
                        .accessibilityLabel("Filter shortcuts")
                    KeycapView(text: "esc")
                }
                .padding(.horizontal, OverlayMetrics.rowIconX)
                .frame(height: OverlayMetrics.pickerInputHeight)
                .layoutPriority(1)
                Divider().overlay(theme.borderHairline.color)
                ScrollView {
                    HStack(alignment: .top, spacing: theme.space9) {
                        ForEach(model.sections) { section in
                            VStack(alignment: .leading, spacing: theme.space2) {
                                Text(section.title)
                                    .font(theme.typeLabel.swiftUIFont)
                                    .foregroundStyle(theme.textTertiary.color)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(section.lines) { line in
                                    HStack(spacing: theme.space3) {
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(line.title)
                                                .font(theme.typeBody.swiftUIFont)
                                                .foregroundStyle(theme.textPrimary.color)
                                                .lineLimit(1)
                                            if let place = line.place {
                                                Text(place)
                                                    .font(theme.typeCaption.swiftUIFont)
                                                    .foregroundStyle(theme.textTertiary.color)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer(minLength: theme.space3)
                                        if let first = line.keys.first {
                                            Text(first)
                                                .font(theme.typeKeycap.swiftUIFont)
                                                .foregroundStyle(theme.component.keycap.text.color)
                                        }
                                    }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel(Self.accessibilityText(line))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    .padding(OverlayMetrics.rowIconX)
                }
                .frame(maxHeight: OverlayMetrics.paletteListMaxHeight + 120)
            }
        }
        .onAppear { focused = true }
    }

    static func accessibilityText(_ line: ShortcutLine) -> String {
        let keys = line.keys.enumerated().map { index, key in
            line.places.indices.contains(index) ? "\(key) in \(line.places[index].lowercased())" : key
        }
        return "\(line.title), \(keys.joined(separator: ", "))"
    }
}
