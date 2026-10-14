import Foundation
import MailActions
import MailModel
import OpenHumanCore

extension SuperhumanCoreActionHandler {
    func eventsOffer(_ context: ActionContext) -> EventsTabOffer? {
        guard let account = context.account,
              let state = environment?.router.accounts.first(where: { $0.id == account }), state.splitsLoaded
        else { return nil }
        return EventsTabOffer.offer(for: state.splits)
    }

    @discardableResult
    func acceptEventsOffer(_ offer: EventsTabOffer, account: AccountID) async -> Bool {
        switch offer {
        case .add(let name):
            let done = await createSplit(named: name, ruleText: EventsTabOffer.ruleText, account: account,
                                         title: "\(offer.doneTitle)")
            if done { await hideWhileEmpty(name, account: account) }
            return done
        case .upgrade(let split):
            let before = SplitEdit.rule(account: account, split: split.id, name: split.name, ruleText: split.ruleText,
                                        enabled: split.enabled)
            let definition = SplitDefinition(account: account, id: split.id, name: split.name,
                                             ruleText: EventsTabOffer.ruleText, enabled: split.enabled)
            return await editSplit(before, title: "\(offer.doneTitle)") { commands in
                _ = try await commands.upsertSplit(definition)
                return nil
            }
        }
    }

    private func hideWhileEmpty(_ name: String, account: AccountID) async {
        guard let settings = environment?.settings, let data = environment?.data else { return }
        do {
            var key: SplitKey?
            for try await list in data.splits(account) {
                key = list.first { $0.name == name }?.id
                break
            }
            guard let key else { return }
            let setting = AppSettings.hideSplitWhenEmpty(account)
            var hidden = Set(try await settings.get(setting))
            guard hidden.insert(key.rawValue).inserted else { return }
            try await settings.set(setting, hidden.sorted())
        } catch {}
    }

    func rescanEvents(account: AccountID, now: Date = Date()) async {
        guard let environment, let settings = environment.settings else { return }
        do {
            try await settings.set(AppSettings.eventsRescanAt(account), Int((now.timeIntervalSince1970 * 1000).rounded()))
        } catch {
            feedback.failed("Couldn't re-scan for invites")
            return
        }
        environment.notices.post("Re-scanning for invites. Invitations found by the next syncs appear on their own.",
                                 style: .info, duration: NoticeCenter.infoDuration)
        try? await environment.data.refresh(account)
    }
}
