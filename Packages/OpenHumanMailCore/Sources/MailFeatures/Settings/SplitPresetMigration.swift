import Foundation
import MailModel
import OpenHumanCore

public enum SplitPresetMigration {
    @discardableResult
    static func upgrade(_ splits: [SplitInfo], account: AccountID, commands: any MailCommanding) async -> Int {
        var count = 0
        for split in splits {
            guard let text = SplitPresets.upgradedRuleText(for: split.ruleText) else { continue }
            if (try? await commands.upsertSplit(SplitDefinition(account: account, id: split.id, name: split.name,
                                                                ruleText: text, enabled: split.enabled))) != nil { count += 1 }
        }
        return count
    }

    @discardableResult
    public static func runAtLaunch(data: any MailDataSource, commands: (any MailCommanding)?,
                                   availability: SettingsAvailability) async -> Int {
        guard availability.canEditStoredItems, let commands else { return 0 }
        var accounts: [Account] = []
        do { for try await list in data.accounts() { accounts = list; break } } catch { return 0 }
        var total = 0
        for account in accounts {
            var splits: [SplitInfo] = []
            do { for try await list in data.splits(account.id) { splits = list; break } } catch { continue }
            total += await upgrade(splits, account: account.id, commands: commands)
        }
        return total
    }
}
