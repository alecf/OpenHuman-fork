import Foundation
import MailActions
import MailModel
import Observation

@MainActor @Observable
public final class SidebarSettingsModel {
    public struct FolderRow: Identifiable, Hashable, Sendable {
        public let folder: SidebarFolder
        public let route: String?
        public let keycaps: [String]
        public var id: String { folder.token }

        public var spokenHint: String {
            let hides = "Off hides \(folder.title) from the sidebar."
            guard let route else { return hides }
            return route == folder.searchTerm ? "\(hides) Searching \(route) still finds it." : "\(hides) \(route) still opens it."
        }
    }

    public static let foldersTitle = "Folders"
    public static let foldersNote = "Hidden folders stay one key away: G and the folder's letter, or ⌘K. Spam and Trash "
        + "open with a search for in:spam or in:trash."
    public static let accountsTitle = "Accounts"
    public static let allInboxesTitle = "Show All Inboxes"
    public static let allInboxesNote = "Every account's inbox in one list: the tray button before the account pictures, "
        + "the sidebar row, ⌃0 and G U."

    public nonisolated static func allInboxesStatus(accountCount: Int) -> String? {
        accountCount >= 2 ? nil : "Appears once a second account is signed in."
    }

    public nonisolated static func folderRows(descriptor: (ActionID) -> ActionDescriptor?) -> [FolderRow] {
        SidebarFolder.all.map { folder in
            let found = folder.goAction.flatMap(descriptor)
            return FolderRow(folder: folder, route: SidebarFolder.route(of: folder, descriptor: found),
                             keycaps: found?.defaultBindings.first?.keycaps ?? [])
        }
    }

    public let hidden: StoredSetting<[String]>
    public let allInboxes: StoredSetting<Bool>
    public let rows: [FolderRow]
    public let availability: SettingsAvailability

    public init(settings: (any SettingsPort)?, availability: SettingsAvailability,
                rows: [FolderRow] = SidebarSettingsModel.folderRows(descriptor: ActionCatalog.descriptor)) {
        hidden = StoredSetting(AppSettings.sidebarHidden, port: settings)
        allInboxes = StoredSetting(AppSettings.allInboxesShown, port: settings)
        self.rows = rows
        self.availability = availability
    }

    public convenience init(environment: AppEnvironment) {
        let registry = environment.actions
        self.init(settings: environment.settings, availability: SettingsAvailability(environment: environment),
                  rows: Self.folderRows { registry.descriptor($0) ?? ActionCatalog.descriptor($0) })
    }

    public func start() {
        hidden.start()
        allInboxes.start()
    }

    public var canEdit: Bool { availability.canEditSettings }

    public func isShown(_ folder: SidebarFolder) -> Bool {
        !SidebarFolder.hiddenTokens(hidden.value).contains(folder.token)
    }

    public func setShown(_ folder: SidebarFolder, _ on: Bool) async {
        await hidden.update { $0 = SidebarFolder.hiddenList($0, setting: folder.token, hidden: !on) }
    }

    public var errorMessage: String? { hidden.errorMessage ?? allInboxes.errorMessage }
}
