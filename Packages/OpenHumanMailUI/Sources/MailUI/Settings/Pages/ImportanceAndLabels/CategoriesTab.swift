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
            SettingsSection("Categories", footnote: "Each conversation gets one label. In Gmail, Mail changes only its own "
                            + "OpenHuman labels, and it never renames or deletes them.") {
                ForEach(AutoLabelCategory.allCases, id: \.self) { category in
                    SettingsRow(category.title, detail: Self.meaning(category),
                                status: OHGmailLabels.autoLabel(category.title).map { "In Gmail: \($0)" })
                }
            }
            SettingsSection("Auto labels") {
                SettingsRow("Auto label settings",
                            detail: "Turn auto labels on or off, add them in Gmail and choose how each one affects Important. "
                                + "They're on the General page, with Superhuman labels.") {
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
