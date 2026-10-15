import CoreGraphics
import MailTheme
import SwiftUI

public enum SelectCheckbox {
    public static let side: CGFloat = 14
    public static let lineWidth: CGFloat = 1.5

    public static func cornerRadius(_ theme: ThemeTokens, side: CGFloat = SelectCheckbox.side) -> CGFloat {
        min(CGFloat(theme.radiusXS), side / 4)
    }

    public static func outlineRect(_ box: CGRect) -> CGRect { box.insetBy(dx: lineWidth / 2, dy: lineWidth / 2) }

    public static func colors(_ theme: ThemeTokens) -> (fill: ThemeColor, tick: ThemeColor, outline: ThemeColor) {
        (theme.accentFill, theme.accentOnFill, theme.textTertiary)
    }

    public static func tick(in box: CGRect, yUp: Bool) -> CGPath {
        let points: [(x: CGFloat, y: CGFloat)] = [(0.26, 0.5), (0.43, 0.32), (0.75, 0.68)]
        let path = CGMutablePath()
        for (index, point) in points.enumerated() {
            let y = yUp ? box.minY + box.height * point.y : box.maxY - box.height * point.y
            let p = CGPoint(x: box.minX + box.width * point.x, y: y)
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

struct SelectCheckboxGlyph: View {
    let checked: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let colors = SelectCheckbox.colors(theme.tokens)
        let radius = SelectCheckbox.cornerRadius(theme.tokens)
        Group {
            if checked {
                ZStack {
                    RoundedRectangle(cornerRadius: radius).fill(colors.fill.color)
                    SelectCheckboxTick().stroke(colors.tick.color, style: StrokeStyle(lineWidth: SelectCheckbox.lineWidth,
                                                                                      lineCap: .round, lineJoin: .round))
                }
            } else {
                SelectCheckboxOutline(radius: radius).stroke(colors.outline.color, lineWidth: SelectCheckbox.lineWidth)
            }
        }
        .frame(width: SelectCheckbox.side, height: SelectCheckbox.side)
    }
}

struct SelectCheckboxTick: Shape {
    func path(in rect: CGRect) -> Path { Path(SelectCheckbox.tick(in: rect, yUp: false)) }
}

struct SelectCheckboxOutline: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: SelectCheckbox.outlineRect(rect), cornerRadius: radius)
    }
}
