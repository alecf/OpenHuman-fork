import MailTheme
import Testing
@testable import MailFeatures

@Suite struct ThreadRowChipHueTests {
    @Test func importanceVIPOverflowAndFallbackCategoriesAreNeutral() {
        #expect(ThreadRowChip(kind: .important, title: "Important").hue == .neutral)
        #expect(ThreadRowChip(kind: .vip, title: "VIP").hue == .neutral)
        #expect(ThreadRowChip(kind: .overflow, title: "+3").hue == .neutral)
        #expect(ThreadRowChip(kind: .category, title: "Marketing", isFallback: true).hue == .neutral,
                "a Superhuman category not imported yet stays muted grey")
    }

    @Test func categoriesGoByTheirTitle() {
        #expect(ThreadRowChip(kind: .category, title: "Marketing").hue == .coral)
        #expect(ThreadRowChip(kind: .category, title: "PROMOTIONS").hue == .coral)
        #expect(ThreadRowChip(kind: .category, title: "Waiting").hue == .neutral)
        #expect(ThreadRowChip(kind: .category, title: "Updates").hue == .teal)
        let unknown = ThreadRowChip(kind: .category, title: "Quarterly")
        #expect(unknown.hue == LabelChipHue.forName("Quarterly") && unknown.hue != .neutral)
    }

    @Test func labelsGoByGmailsColourElseTheirName() {
        #expect(ThreadRowChip(kind: .label, title: "Receipts", color: "#16a766").hue == .green)
        #expect(ThreadRowChip(kind: .label, title: "Clients", color: "#fb4c2f").hue == .coral)
        #expect(ThreadRowChip(kind: .label, title: "Archive", color: "#666666").hue == .neutral, "a grey stays grey")
        let plain = ThreadRowChip(kind: .label, title: "Travel")
        #expect(plain.hue == LabelChipHue.forName("Travel") && plain.hue != .neutral)
        #expect(ThreadRowChip(kind: .label, title: "Travel", color: "bogus").hue == LabelChipHue.forName("Travel"),
                "an unparsable colour falls back to the name")
    }
}
