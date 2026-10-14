import Foundation

extension ThemeTokens {
    public static let minimumPerceptualDifference = 5.0

    public static func standApart(_ fill: ThemeColor, _ plate: ThemeColor, luminance: Double) -> Bool {
        let opaque = fill.composited(over: plate)
        return opaque.contrastRatio(on: plate) >= luminance
            || opaque.perceptualDifference(from: plate) >= minimumPerceptualDifference
    }

    public func listCursorFillReads(_ fill: ThemeColor) -> Bool {
        let row = component.row
        let plate = fill.composited(over: bgWindow)
        return textPrimary.contrastRatio(on: plate) >= 4.5 && textSecondary.contrastRatio(on: plate) >= 4.5
            && row.dateUnread.contrastRatio(on: plate) >= 4.5 && textTertiary.contrastRatio(on: plate) >= 3
            && row.cursorBar.contrastRatio(on: plate) >= 3
            && Self.standApart(row.bgHover.composited(over: bgWindow), plate, luminance: 1.06)
            && Self.standApart(row.chipBg, plate, luminance: increaseContrast ? 1.4 : 1.1)
    }

    public var listCursorFill: ThemeColor {
        let band = component.row.bgCursor.composited(over: bgWindow)
        return listCursorFillReads(band) ? band : bgRowSelected.composited(over: bgWindow)
    }

    private var listActionPlates: [ThemeColor] { [listCursorFill, component.row.bgHover.composited(over: bgWindow)] }

    public var listActionTint: ThemeColor {
        listActionPlates.allSatisfy { accentText.contrastRatio(on: $0) >= 3 } ? accentText : textSecondary
    }

    public var listActionPointerFill: ThemeColor { textPrimary.withAlpha(0.08) }

    public var listActionPressedFill: ThemeColor { textPrimary.withAlpha(0.14) }

    public var listActionTintUnderPointer: ThemeColor {
        let fills = listActionPlates.flatMap { plate in
            [listActionPointerFill.composited(over: plate), listActionPressedFill.composited(over: plate)]
        }
        return fills.allSatisfy { accentFillHover.contrastRatio(on: $0) >= 3 } ? accentFillHover : textPrimary
    }
}

extension ThemeColor {
    func withAlpha(_ alpha: Double) -> ThemeColor { ThemeColor(red: red, green: green, blue: blue, alpha: alpha) }
}
