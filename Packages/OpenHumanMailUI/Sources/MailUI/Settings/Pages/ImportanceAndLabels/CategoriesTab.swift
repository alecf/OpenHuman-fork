import MailFeatures
import MailModel
import MailTheme
import OpenHumanAI
import OpenHumanCore
import SwiftUI

struct CategoriesTab: View {
    let environment: AppEnvironment?

    var body: some View {
        SettingsSectionStack {
            SettingsSection("Categories", footnote: "One label per conversation. Mail only ever touches its own "
                            + "OpenHuman labels in Gmail; it never renames or deletes one.") {
                ForEach(AutoLabelCategory.allCases, id: \.self) { category in
                    SettingsRow(category.title, detail: Self.meaning(category),
                                status: OHGmailLabels.autoLabel(category.title).map { "In Gmail: \($0)" })
                }
            }
            SettingsSection("Auto labels") {
                SettingsRow("Switches and placement",
                            detail: "Auto labels on or off, Also apply as Gmail labels, Show in Gmail, Classify recent mail, "
                                + "placement in Important, and Superhuman labels.") {
                    Button("Open General") { environment?.settingsNavigator.open(SettingsPageID.general.rawValue) }
                        .disabled(environment == nil)
                }
            }
        }
    }

    static func meaning(_ category: AutoLabelCategory) -> String {
        switch category {
        case .respond: "A real person writes to you and asks for an answer."
        case .waiting: "You wrote last; the other side owes the reply. Never the model's choice."
        case .meeting: "An invitation or a message about a meeting."
        case .invoice: "A bill, a receipt or a payment."
        case .travel: "Flights, hotels, trains and bookings."
        case .pitch: "Unsolicited sales, hiring, partnership or sponsorship outreach."
        case .social: "Notifications from social networks."
        case .news: "A newsletter or news digest."
        case .marketing: "Promotions and marketing from companies."
        }
    }
}
