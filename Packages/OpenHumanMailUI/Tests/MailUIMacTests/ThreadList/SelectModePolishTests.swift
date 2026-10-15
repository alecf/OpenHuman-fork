import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI
@testable import MailUIMac

@MainActor
@Suite struct SelectModePolishTests {
    private static let now = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func checkedRowsDrawTheirOwnFillApartFromTheCursor() {
        for (label, t) in RowBandTests.everyTheme() {
            let style = ThreadRowStyle(theme: t)
            #expect(RenderReviewFixTests.same(style.checked, t.listCheckedFill.nsColor), "\(label)")
            #expect(!RenderReviewFixTests.same(style.checked, style.cursor), "\(label)")
            #expect(ThemeTokens.standApart(t.component.row.chipBg, t.listCheckedFill, luminance: 1.1),
                    "a neutral chip shows on a checked row: \(label)")
        }
    }

    @Test func checkedRowsDrawTheirLabelChipsNeutralWithoutMovingTheLine() {
        for theme in [ThemeTokens.light, ThemeTokens.dark] {
            let style = ThreadRowStyle(theme: theme)
            let row = RowActionsOverlapTests.shown(.long, style: style).row
            let chips = [ThreadRowChip(kind: .label, title: "Atlas", color: "#a479e2"),
                         ThreadRowChip(kind: .label, title: "Travel", color: "#16a766")]
            let line = style.texts(for: row, chips: chips, format: ThreadRowFormatting(), location: .system(.inbox)).line
            let shown = LabelChipRenderer.shown(chips, maximum: ThreadRowStyle.maximumFilledChips)
            #expect(shown.contains { $0.hue != .neutral && !$0.muted }, "the fixture has tinted chips")

            let checked = style.chips.onChecked(line)
            #expect(checked !== line)
            #expect(style.chips.onChecked(line) === checked, "one variant per line")
            #expect(checked.string == line.string)
            let before = Self.attachments(line), after = Self.attachments(checked)
            #expect(before.count == shown.count && after.count == shown.count)
            for (index, chip) in shown.enumerated() where index < before.count && index < after.count {
                #expect(before[index].image === style.chips.image(chip.title, hue: chip.hue, muted: chip.muted).image)
                #expect(after[index].image === style.chips.image(chip.title, hue: .neutral, muted: chip.muted).image)
                #expect(after[index].bounds == before[index].bounds, "same size and baseline: \(chip.title)")
                if theme.component.row.chipBg.alpha == 1, let image = after[index].image {
                    #expect(RowActionsOverlapTests.near(RowActionsOverlapTests.pixel(image), theme.component.row.chipBg),
                            "neutral fill: \(chip.title)")
                }
            }
            let neutral = style.chips.colors(hue: .neutral, muted: false)
            #expect(neutral.fill == theme.component.row.chipBg && neutral.ink == theme.component.row.chipText)

            let plain = style.texts(for: row, chips: [], format: ThreadRowFormatting(), location: .system(.inbox)).line
            #expect(style.chips.onChecked(plain) === plain, "a line without chips is drawn as it is")
        }
    }

    @Test func theHeaderBoxIsDrawnLikeTheRowBox() throws {
        #expect(ThreadRowView.checkboxSize == SelectCheckbox.side)
        let side = SelectCheckbox.side
        for resolved in [ResolvedTheme.light, ResolvedTheme.dark] {
            let t = resolved.tokens
            let style = ThreadRowStyle(theme: t)
            let colors = SelectCheckbox.colors(t)
            #expect(RenderReviewFixTests.same(style.accentFill, colors.fill.nsColor))
            #expect(RenderReviewFixTests.same(style.accentOnFill, colors.tick.nsColor))
            #expect(RenderReviewFixTests.same(style.tertiary, colors.outline.nsColor))
            for checked in [true, false] {
                let renderer = ImageRenderer(content: SelectCheckboxGlyph(checked: checked).environment(\.theme, resolved))
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                #expect(image.width == Int(side * 2) && image.height == Int(side * 2))
                let pixels = try #require(GlyphPixels(image))
                let topMiddle = pixels.at(Int(side), 3)
                let centre = pixels.at(Int(side), Int(side))
                if checked {
                    #expect(GlyphPixels.matches(topMiddle, colors.fill), "accent fill: \(resolved.themeID)")
                } else {
                    #expect(centre.alpha == 0, "an empty box is an outline: \(resolved.themeID)")
                    #expect(pixels.at(Int(side), 1).alpha > 0, "the outline is drawn: \(resolved.themeID)")
                }
            }
        }
    }

    @Test func theTickPointsTheSameWayInBothCoordinateSystems() {
        let box = CGRect(x: 10, y: 20, width: 14, height: 14)
        let up = SelectCheckbox.tick(in: box, yUp: true).boundingBox
        let down = SelectCheckbox.tick(in: box, yUp: false).boundingBox
        #expect(box.contains(up) && box.contains(down))
        #expect(abs(up.width - down.width) < 0.001 && abs(up.height - down.height) < 0.001)
        #expect(abs((up.minY - box.minY) - (box.maxY - down.maxY)) < 0.001, "mirrored, not moved")
        #expect(SelectCheckbox.outlineRect(box) == box.insetBy(dx: SelectCheckbox.lineWidth / 2, dy: SelectCheckbox.lineWidth / 2))
    }

    @Test func theHeaderCheckboxSlotKeepsItsWidthSoTheTabsNeverMove() {
        let store = FakeMailStore(corpus: .make(threadCount: 3, now: Self.now))
        let list = ThreadListModel(data: store, location: .system(.inbox), account: AccountID(1))
        func width() -> CGFloat {
            let host = NSHostingView(rootView: SelectAllCheckbox(list: list, descriptors: []).environment(\.theme, ResolvedTheme.light))
            return host.fittingSize.width
        }
        #expect(list.headerCheck == .hidden)
        let empty = width()
        list.selection.toggle(ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t1")))
        #expect(list.headerCheck == .some)
        let shown = width()
        #expect(empty > 0)
        #expect(empty == shown)
        #expect(empty == ShellMetrics.toolbarControlHeight + CGFloat(ThemeTokens.light.space3))
    }

    @Test func thePanelCloseGlyphReadsOnTheSidebarInEveryTheme() {
        for (label, t) in RowBandTests.everyTheme() {
            #expect(RightPaneTabs.closeTint(t).contrastRatio(on: t.bgSidebar) >= 3, "\(label)")
        }
    }

    private static func attachments(_ line: NSAttributedString) -> [NSTextAttachment] {
        var result: [NSTextAttachment] = []
        line.enumerateAttribute(.attachment, in: NSRange(location: 0, length: line.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { result.append(attachment) }
        }
        return result
    }
}

private struct GlyphPixels {
    let width: Int
    let bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        bytes = buffer
    }

    func at(_ x: Int, _ y: Int) -> (red: Int, green: Int, blue: Int, alpha: Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
    }

    static func matches(_ pixel: (red: Int, green: Int, blue: Int, alpha: Int), _ color: ThemeColor) -> Bool {
        pixel.alpha == 255 && abs(pixel.red - Int((color.red * 255).rounded())) <= 3
            && abs(pixel.green - Int((color.green * 255).rounded())) <= 3
            && abs(pixel.blue - Int((color.blue * 255).rounded())) <= 3
    }
}
