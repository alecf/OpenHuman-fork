import Foundation
import MailModel
import MailTheme
import OpenHumanCore
import Testing
@testable import MailFeatures

@Suite struct GmailImportantChipTests {
    static let key = ThreadKey(account: AccountID(1), rowID: 7, gmailThreadID: GmailThreadID("t7"))
    static let now = Date(timeIntervalSince1970: 1_791_640_800)

    static func row(gmail: Bool, placed: Bool) -> ThreadRow {
        ThreadRow(id: key, subject: "Weekly digest", snippet: "This week", participantsDisplay: "Nia Letters",
                  participants: [], messageCount: 1, unreadCount: 0, draftCount: 0, attachmentCount: 0, isUnread: false,
                  isStarred: false, isImportant: gmail, userLabelIDs: [], lastMessageAt: now, sortAt: now,
                  isPlacedImportant: placed)
    }

    static func kinds(gmail: Bool, placed: Bool, in location: MailLocation, implies: Bool = false) -> [ThreadRowChip.Kind] {
        ThreadRowFormatting.chips(for: row(gmail: gmail, placed: placed),
                                  context: ThreadRowChipContext(location: location, impliesImportance: implies)).map(\.kind)
    }

    @Test func chipSaysGmailImportantOnlyWhenTheTabDisagrees() {
        #expect(Self.kinds(gmail: true, placed: false, in: .splitOther) == [.gmailImportant])
        #expect(Self.kinds(gmail: true, placed: false, in: .split(SplitKey("news"))) == [.gmailImportant])
        #expect(Self.kinds(gmail: true, placed: true, in: .split(SplitKey("calendar"))) == [.important],
                "both agree: the usual chip")
        #expect(Self.kinds(gmail: false, placed: true, in: .splitOther).isEmpty, "the chip is Gmail's mark, not placement")
        #expect(Self.kinds(gmail: true, placed: false, in: .split(SplitKey("important")), implies: true).isEmpty)
        let chip = ThreadRowFormatting.chips(for: Self.row(gmail: true, placed: false),
                                             context: ThreadRowChipContext(location: .splitOther)).first
        #expect(chip?.title == "Gmail important")
    }

    @Test func outsideTheInboxTheChipStaysImportant() {
        let elsewhere: [MailLocation] = [.system(.inbox), .system(.allMail), .system(.done), .search("digest"),
                                         .label(GmailLabelID("Label_1"))]
        for location in elsewhere {
            #expect(Self.kinds(gmail: true, placed: false, in: location) == [.important], "\(location)")
        }
        #expect(Self.kinds(gmail: true, placed: false, in: .system(.important), implies: true).isEmpty)
    }

    @Test func theGmailChipIsQuietAndSaysWhatItMeans() {
        let chip = ThreadRowChip(kind: .gmailImportant, title: ThreadRowFormatting.gmailImportantTitle)
        #expect(chip.isQuiet && chip.hue == .neutral)
        #expect(!ThreadRowChip(kind: .important, title: "Important").isQuiet)
        #expect(ThreadRowChip(kind: .category, title: "Meeting", isFallback: true).isQuiet)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let format = ThreadRowFormatting(calendar: utc, locale: Locale(identifier: "en_US"))
        let label = format.accessibilityLabel(Self.row(gmail: true, placed: false), chips: [chip], location: .splitOther,
                                              now: Self.now)
        #expect(label.contains("Gmail marks it important, kept out of Important"))
        #expect(!label.contains(", important,"))
        for text in [ThreadRowFormatting.gmailImportantTip, ImportanceSettingsModel.sendsToGmailDetail,
                     ImportanceSettingsModel.sendsToGmailTitle] {
            #expect(!text.lowercased().contains("learn"), "no claim that Gmail learns: \(text)")
        }
    }
}
