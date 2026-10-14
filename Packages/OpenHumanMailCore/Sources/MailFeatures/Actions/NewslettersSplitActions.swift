import Foundation
import MailActions
import MailModel
import OpenHumanCore

extension SuperhumanCoreActionHandler {
    func newslettersTabName(_ context: ActionContext) -> String? {
        guard let account = context.account,
              let state = environment?.router.accounts.first(where: { $0.id == account }), state.splitsLoaded
        else { return nil }
        return SplitPresets.newslettersTabName(for: state.splits)
    }

    @discardableResult
    func addNewslettersSplit(named name: String, account: AccountID) async -> Bool {
        await createSplit(named: name, ruleText: SplitPresets.newsletters.ruleText, account: account,
                          title: "Added the \(name) split")
    }
}
