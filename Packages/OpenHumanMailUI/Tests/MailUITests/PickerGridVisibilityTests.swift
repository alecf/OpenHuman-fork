#if os(macOS)
import AppKit
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI

@MainActor
@Suite struct PickerGridVisibilityTests {
    nonisolated static let now = Date(timeIntervalSince1970: 1_791_000_000 + 10 * 86_400)

    private func model() -> TimePickerModel {
        let m = TimePickerModel(kind: .remind, targets: [], presets: TimePresets(timeZone: TimeZone(identifier: "UTC")!),
                                locale: Locale(identifier: "en_US_POSIX"), now: { Self.now }) { _ in }
        m.openDatePick()
        return m
    }

    private func ink<V: View>(_ view: V, theme: ResolvedTheme, size: NSSize, delta: CGFloat = 0.2) throws -> (count: Int, peak: CGFloat) {
        let bg = theme.tokens.component.palette.bg.color
        let hosting = NSHostingView(rootView: view.environment(\.theme, theme)
            .environment(\.colorScheme, theme.appearance == .dark ? .dark : .light)
            .frame(width: size.width, height: size.height).background(bg))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: theme.appearance == .dark ? .darkAqua : .aqua)
        hosting.layoutSubtreeIfNeeded()
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        func luma(_ c: NSColor) -> CGFloat { 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent }
        let ref = luma(try #require(rep.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB)))
        var count = 0
        var peak: CGFloat = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let d = abs(luma(c) - ref)
                peak = max(peak, d)
                if d > delta { count += 1 }
            }
        }
        if let dir = ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] {
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("grid-\(theme.appearance)-\(size.width)x\(size.height)-\(count).png"))
        }
        return (count, peak)
    }

    @Test(arguments: [ResolvedTheme.light, ResolvedTheme.dark])
    func theWholeGridDraws(theme: ResolvedTheme) throws {
        let m = model()
        let r = try ink(TimePickerDateGrid(model: m), theme: theme, size: NSSize(width: 420, height: 340), delta: 0.2)
        #expect(r.count > 2500, "ink \(r.count) in \(theme.appearance)")
    }

    static let themes: [ResolvedTheme] = [.light, .dark]

    @Test(arguments: [ResolvedTheme.light, ResolvedTheme.dark])
    func everyDayCellIsVisible(theme: ResolvedTheme) throws {
        let m = model()
        let grid = TimePickerDateGrid(model: m)
        let days = try #require(m.monthGrid).days
        #expect(days.count == 42)
        for (i, day) in days.enumerated() {
            let selected = i == 20
            let result = try ink(grid.dayCell(day, selected: selected), theme: theme, size: NSSize(width: 32, height: 32), delta: 0.12)
            #expect(result.count >= 12, "day \(day.number) (in month \(day.isInMonth), selected \(selected)) draws its digits in \(theme.appearance)")
        }
    }

    @Test(arguments: [ResolvedTheme.light, ResolvedTheme.dark])
    func headerWeekdaysAndTimeFieldAreVisible(theme: ResolvedTheme) throws {
        let m = model()
        let grid = TimePickerDateGrid(model: m)
        let month = try #require(m.monthGrid)
        let header = try ink(grid.monthHeader(month), theme: theme, size: NSSize(width: 388, height: 28), delta: 0.2)
        #expect(header.count > 150, "month title and chevrons in \(theme.appearance)")
        #expect(m.weekdayInitials.count == 7)
        for initial in m.weekdayInitials {
            let r = try ink(grid.weekdayCell(initial), theme: theme, size: NSSize(width: 32, height: 22), delta: 0.12)
            #expect(r.count >= 8, "weekday \(initial) in \(theme.appearance)")
        }
        let time = try ink(grid.timeRow(try #require(m.datePick)), theme: theme, size: NSSize(width: 388, height: 36), delta: 0.2)
        #expect(time.count > 100, "the Time label and 09:00 in \(theme.appearance)")
        let band = theme.tokens.component.palette.band
        #expect(band.contrastRatio(on: theme.tokens.component.palette.bg) < 3, "the field is a dark chip, not white")
    }

    @Test(arguments: [ResolvedTheme.light, ResolvedTheme.dark])
    func colourContrastOnTheSheet(theme: ResolvedTheme) {
        let p = theme.tokens.component.palette
        #expect(p.textSelected.contrastRatio(on: p.bg) >= 4.5)
        #expect(p.text.contrastRatio(on: p.bg) >= 4.5)
    }
}
#endif
