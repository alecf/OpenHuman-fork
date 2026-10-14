#if os(macOS)
import Foundation
import MailFakes
import MailFeatures
import Testing
@testable import MailUI

@MainActor
@Test func paletteSectionsKeepEveryEntryAtItsPositionInGroupRuns() async throws {
    let env = AppEnvironment.fake(corpus: .rich(threadCount: 40, now: Date(timeIntervalSince1970: 1_791_000_000)),
                                  options: .init(remoteAck: .immediate))
    let router = env.router
    let center = env.overlays
    router.start()
    while router.active?.list?.state != .loaded { await Task.yield() }
    router.perform(.commandPalette)
    guard case .palette(let palette) = center.overlay else {
        Issue.record("no palette")
        return
    }
    for query in ["", "a", "ar", "archive", "qzxqzx", "s", "snooze", "go to", "label", ""] {
        palette.query = query
        let sections = PaletteSections(palette.entries)
        #expect(sections.rows.map(\.index) == Array(palette.entries.indices), "positions for “\(query)”")
        #expect(sections.rows.map(\.id) == palette.entries.map(\.id))
        #expect(sections.groups.flatMap { $0.rows.map(\.id) } == palette.entries.map(\.id), "every row in one group")
        #expect(Set(sections.groups.map(\.id)).count == sections.groups.count, "group ids are unique")
        for group in sections.groups {
            #expect(group.rows.allSatisfy { $0.entry.group == group.group })
        }
        #expect(sections.id(at: palette.cursor) == (palette.entries.isEmpty ? nil : palette.entries[palette.cursor].id))
        #expect(sections.id(at: palette.entries.count) == nil && sections.id(at: -1) == nil)
    }
}
#endif
