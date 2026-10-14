import Testing
@testable import MailTheme

@Suite struct LabelChipHueTests {
    @Test func gmailColoursMapToTheNearestPastel() {
        #expect(LabelChipHue.nearest(toHex: "#fb4c2f") == .coral)
        #expect(LabelChipHue.nearest(toHex: "#16a766") == .green)
        #expect(LabelChipHue.nearest(toHex: "#4a86e8") == .sky)
        #expect(LabelChipHue.nearest(toHex: "#a479e2") == .lavender)
        #expect(LabelChipHue.nearest(toHex: "#f691b3") == .rose)
        #expect(LabelChipHue.nearest(toHex: "#FB4C2F") == .coral, "either case")
    }

    @Test func greysBlackAndWhiteStayNeutralAndNonColoursAreNil() {
        for grey in ["#000000", "#666666", "#ffffff", "#434343", "#efefef"] {
            #expect(LabelChipHue.nearest(toHex: grey) == .neutral, "\(grey)")
        }
        #expect(LabelChipHue.nearest(toHex: "nope") == nil)
        #expect(LabelChipHue.nearest(toHex: "") == nil)
        #expect(LabelChipHue.nearest(toHex: "#12345") == nil)
    }

    @Test func boundariesGoToTheUpperRange() {
        let expected: [(Double, LabelChipHue)] = [
            (20, .tangerine), (40, .amber), (65, .green), (160, .teal), (195, .sky), (250, .lavender), (300, .rose),
            (345, .coral), (0, .coral), (19.9, .coral), (344.9, .rose),
        ]
        for (degrees, hue) in expected {
            #expect(LabelChipHue.nearest(toHue: degrees) == hue, "\(degrees)°")
        }
        #expect(LabelChipHue.nearest(toHue: 360) == .coral && LabelChipHue.nearest(toHue: -10) == .coral, "wraps")
        #expect(LabelChipHue.nearest(toHex: "#ff5500") == .tangerine)
        #expect(LabelChipHue.nearest(toHex: "#ffaa00") == .amber)
    }

    @Test func theNameHashIsStableCaseInsensitiveAndSpreads() {
        #expect(LabelChipHue.forName("Travel") == LabelChipHue.forName("travel"))
        #expect(LabelChipHue.forName("TRAVEL") == LabelChipHue.forName("Travel"))
        #expect(LabelChipHue.forName("Projects") == LabelChipHue.forName("Projects"))
        #expect(LabelChipHue.forName("Beacon") != .neutral)
        let names = ["Respond", "Waiting", "Meeting", "Invoice", "Travel", "Pitch", "Social", "News", "Marketing"]
        #expect(Set(names.map(LabelChipHue.forName)).count >= 5)
        #expect(names.allSatisfy { LabelChipHue.forName($0) != .neutral })
        #expect(LabelChipHue.forName("Travel") == .coral)
        #expect(LabelChipHue.forName("Projects") == .lavender)
        #expect(LabelChipHue.forName("Bills") == .teal)
    }

    @Test func categoriesUseTheirTable() {
        let table: [(String, LabelChipHue)] = [
            ("Marketing", .coral), ("Promotions", .coral), ("News", .amber), ("Forums", .amber), ("Pitch", .lavender),
            ("Social", .sky), ("Invoice", .green), ("Travel", .tangerine), ("Meeting", .teal), ("Updates", .teal),
            ("Respond", .rose), ("Personal", .rose), ("Waiting", .neutral),
        ]
        for (title, hue) in table {
            #expect(LabelChipHue.category(title) == hue, "\(title)")
            #expect(LabelChipHue.category(title.uppercased()) == hue, "\(title) in capitals")
        }
        #expect(LabelChipHue.category("Receipts") == LabelChipHue.forName("Receipts"), "unknown: the name hash")
    }
}
