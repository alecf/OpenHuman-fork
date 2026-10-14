import AppKit
import MailTheme
import Testing
@testable import MailUIMac

@MainActor
@Suite struct ListSkeletonRowTests {
    @Test func aPlaceholderDrawsTheSkeletonOnlyWhenAsked() {
        let cell = ThreadRowView(style: ThreadRowStyle(theme: .light))
        cell.frame = NSRect(x: 0, y: 0, width: 900, height: 36)
        cell.configurePlaceholder(showsSkeleton: false)
        #expect(cell.isPlaceholder && !cell.drawsSkeleton && !cell.isShimmering, "blank and still")
        cell.configurePlaceholder(showsSkeleton: true)
        #expect(cell.drawsSkeleton)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { #expect(cell.isShimmering) }
        cell.configurePlaceholder(showsSkeleton: false)
        #expect(!cell.drawsSkeleton && !cell.isShimmering)
    }
}
