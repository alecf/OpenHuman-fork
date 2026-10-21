import Foundation

public struct SettingsSearchEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable, Hashable { case page, section, row }

    public let page: String
    public let kind: Kind
    public let title: String
    public let section: String?
    public let tab: String?
    public let keywords: [String]
    public let developerOnly: Bool

    public init(page: String, kind: Kind, title: String, section: String? = nil, tab: String? = nil,
                keywords: [String] = [], developerOnly: Bool = false) {
        self.page = page
        self.kind = kind
        self.title = title
        self.section = section
        self.tab = tab
        self.keywords = keywords
        self.developerOnly = developerOnly
    }

    public var id: String { [page, tab ?? "", section ?? "", "\(kind)", title].joined(separator: "\u{1F}") }
}

public struct SettingsSearchResult: Identifiable, Hashable, Sendable {
    public let entry: SettingsSearchEntry
    public let pageTitle: String
    public let symbol: String

    public var id: String { entry.id }

    /// Where the hit lives, under its title: "Page" or "Page › Section".
    public var location: String? {
        switch entry.kind {
        case .page: nil
        case .section: pageTitle
        case .row: [pageTitle, entry.section].compactMap { $0 }.joined(separator: " › ")
        }
    }
}

/// A search result the Settings window has opened: its page is showing and the row or section is highlighted.
public struct SettingsReveal: Hashable, Sendable {
    public let entry: SettingsSearchEntry
    public let serial: Int

    public init(entry: SettingsSearchEntry, serial: Int) {
        self.entry = entry
        self.serial = serial
    }
}

public enum SettingsSearch {
    public static let maxResults = 40

    @MainActor
    public static func results(for query: String, pages: [SettingsPageEntry], includesDeveloperItems: Bool = false,
                               entries: [SettingsSearchEntry] = SettingsSearchCatalog.entries) -> [SettingsSearchResult] {
        let tokens = words(query)
        guard !tokens.isEmpty else { return [] }
        let whole = tokens.joined(separator: " ")
        let byID = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pageEntries = pages.map {
            SettingsSearchEntry(page: $0.id, kind: .page, title: $0.title, keywords: pageKeywords[$0.id] ?? [])
        }
        var scored: [(score: Int, order: Int, result: SettingsSearchResult)] = []
        for (order, entry) in (pageEntries + entries).enumerated() {
            guard let page = byID[entry.page], includesDeveloperItems || !entry.developerOnly,
                  let score = score(entry, pageTitle: page.title, tokens: tokens, whole: whole) else { continue }
            scored.append((score, order, SettingsSearchResult(entry: entry, pageTitle: page.title, symbol: page.symbol)))
        }
        var seen = Set<String>()
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .map(\.result)
            .filter { seen.insert($0.id).inserted }
            .prefix(maxResults)
            .map { $0 }
    }

    /// Every query word has to begin a word somewhere in the entry; words in the title count most, and a title that
    /// starts with the whole query comes first.
    static func score(_ entry: SettingsSearchEntry, pageTitle: String, tokens: [String], whole: String) -> Int? {
        let title = words(entry.title)
        let fields: [(words: [String], weight: Int)] = [
            (title, 4),
            (entry.keywords.flatMap(words), 3),
            (entry.section.map(words) ?? [], 2),
            (entry.kind == .page ? [] : words(pageTitle), 1),
        ]
        var total = 0
        var allInTitle = true
        for token in tokens {
            guard let best = fields.filter({ $0.words.contains { $0.hasPrefix(token) } }).map(\.weight).max() else { return nil }
            total += best
            allInTitle = allInTitle && best == fields[0].weight
        }
        let joined = title.joined(separator: " ")
        if joined.hasPrefix(whole) { total += 20 } else if joined.contains(whole) { total += 8 }
        if allInTitle { total += 6 }
        if entry.kind == .page { total += 2 }
        return total
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    static let pageKeywords: [String: [String]] = [
        "general": ["preferences", "options"],
        "accounts": ["gmail", "google", "sign in", "login", "alias"],
        "notifications": ["alerts", "banner", "sound"],
        "importance": ["important", "other", "labels", "categories", "rules", "vip"],
        "splitInbox": ["tabs", "splits"],
        "sidebar": ["folders", "labels"],
        "snippets": ["templates", "canned"],
        "search": ["ranking", "relevance"],
        "shortcuts": ["keyboard", "keys", "hotkeys", "keymap", "keybindings"],
        "ai": ["models", "llm", "openai", "claude", "prompts", "summaries"],
        "calendar": ["events", "meetings", "scheduling"],
        "appearance": ["theme", "dark mode", "light mode", "fonts", "colors"],
        "privacy": ["images", "tracking", "pixels"],
        "blocked": ["block", "spam", "senders"],
        "platform": ["macos", "spotlight", "siri", "services"],
        "advanced": ["export", "import", "diagnostics", "modules"],
    ]
}

/// Every setting the Settings search can find. A row's title here must be the title its SettingsRow or SettingsSection
/// shows, so opening a result can highlight it; Tools/ci/tests/test_settings_search_catalog.py checks the literal
/// titles in the settings pages against this list.
@MainActor
public enum SettingsSearchCatalog {
    public static let entries: [SettingsSearchEntry] = general + accounts + notifications + importance + splitInbox
        + sidebar + snippets + search + shortcuts + ai + calendar + appearance + privacy + blocked + platform + advanced

    private static func page(_ id: String, tab: String? = nil, developerOnly: Bool = false,
                             _ sections: [(String?, [(String, [String])])]) -> [SettingsSearchEntry] {
        sections.flatMap { section, rows in
            let header = section.map {
                [SettingsSearchEntry(page: id, kind: .section, title: $0, tab: tab, developerOnly: developerOnly)]
            } ?? []
            return header + rows.map { title, keywords in
                SettingsSearchEntry(page: id, kind: .row, title: title, section: section, tab: tab, keywords: keywords,
                                    developerOnly: developerOnly)
            }
        }
    }

    static let general = page("general", [
        ("Sending", [
            ("Undo send", ["unsend", "delay", "recall"]),
            ("Archive and go back after sending a reply", ["done", "send and archive"]),
            ("Include signature on replies and forwards", ["signature"]),
            (GeneralSettingsModel.confirmBeforeSendingTitle, ["ask", "warn"]),
        ]),
        ("Writing", [
            ("Correct spelling automatically", ["autocorrect", "typos"]),
            ("Check spelling while typing", ["spellcheck"]),
            ("Check grammar with spelling", ["grammar"]),
            ("Text replacements", ["substitutions", "autotext"]),
            ("Smart quotes and dashes", ["punctuation", "curly quotes"]),
            ("Automatic lists", ["bullets", "numbered"]),
        ]),
        ("Window", [
            ("Show shortcut hints", ["keyboard", "footer"]),
            ("Show sync progress in the footer", ["pending", "status"]),
            ("Tab counts", ["unread", "badge", "numbers"]),
            ("Account counts", ["unread", "badge", "numbers"]),
            ("Zoom", ["text size", "scale", "bigger", "smaller"]),
        ]),
        ("Learning the keys", [
            (GeneralSettingsModel.hintOnClickTitle, ["shortcut", "tip"]),
            (GeneralSettingsModel.resetHintsTitle, ["shortcut", "tips"]),
        ]),
        ("Move to", [("Show splits and places in Move to", ["folders", "labels"])]),
        ("Welcome tour", [("Run welcome tour again", ["onboarding", "tutorial", "intro"])]),
        ("Updates", [(UpdateCheckCenter.settingsTitle, ["version", "upgrade", "new version"])]),
        ("Inbox", [
            ("Suggest cleaning up the inbox", ["cleanup", "archive", "zero"]),
            ("Ask when the inbox holds more than", ["cleanup", "threshold"]),
            ("Suggest conversations older than", ["cleanup", "age"]),
        ]),
        (CleanupRulesModel.sectionTitle, [("Add a sender or domain", ["cleanup", "always", "never"])]),
        ("Follow-up reminders", [
            ("Remind me when nobody replies", ["follow up", "nudge", "no reply"]),
            ("Check sent mail from the last 7 days", ["follow up"]),
            ("Wait", ["follow up", "days"]),
            ("Remind me at", ["follow up", "time"]),
            ("Count weekdays only", ["follow up", "weekends", "business days"]),
        ]),
        (SuperhumanRemindersSettingsModel.sectionTitle, [
            (SuperhumanRemindersSettingsModel.hideTitle, ["superhuman"]),
            (SuperhumanRemindersSettingsModel.senderTitle, ["superhuman"]),
            (SuperhumanRemindersSettingsModel.archiveTitle, ["superhuman"]),
            (SuperhumanRemindersSettingsModel.importTitle, ["superhuman"]),
        ]),
        ("Auto labels", [
            ("Label new mail", ["categories", "classify", "tag"]),
            ("Also apply as Gmail labels", ["categories", "gmail"]),
            ("Show auto labels in Gmail", ["categories", "gmail"]),
            ("Recent mail", ["categories", "backfill", "label old mail"]),
            ("Start over", ["categories", "reset", "relabel"]),
        ]),
        ("Superhuman labels", [
            ("Hide Superhuman labels", ["superhuman"]),
            ("Import Superhuman labels", ["superhuman"]),
            ("Remove Superhuman labels", ["superhuman"]),
            ("How close are we to Superhuman?", ["superhuman", "compare"]),
        ]),
        ("Scheduling on this Mac", [
            ("Snoozing", ["snooze", "later"]),
            ("Mark snoozed threads unread when they wake", ["snooze", "unread"]),
            ("Send later", ["schedule send", "scheduled"]),
            ("Reminders", ["remind"]),
        ]),
        ("Reminders and snooze", [
            ("Default time", ["snooze", "remind", "morning"]),
            ("Weekdays only", ["snooze", "remind", "weekends"]),
        ]),
        ("Search", [
            ("Download message bodies for search", ["offline", "full text", "index"]),
            ("Keep at most", ["disk", "storage", "space", "bodies"]),
            ("Understand searches written as sentences", ["natural language", "smart search", "ai"]),
            ("Saved searches", ["saved", "filters"]),
        ]),
        ("Login, Dock and menu bar", [
            ("Open at login", ["startup", "launch", "login items"]),
            ("Dock badge", ["unread", "count", "icon"]),
            ("Show the open envelope in the Dock while Mail is running", ["icon", "dock"]),
            ("Show Mail in the menu bar", ["status bar", "menu extra", "tray"]),
            ("Number next to the menu bar icon", ["unread", "count", "status bar"]),
        ]),
    ])

    static let accounts = page("accounts", [
        (nil, [
            ("Add another account", ["sign in", "gmail", "new account"]),
            ("Sign in with", ["google client", "oauth"]),
            ("Google client file", ["oauth", "credentials", "client id"]),
        ]),
        ("Google clients", [("Signing in again with the new client", ["oauth"])]),
        ("Google sign-in", [("How to get a Google client", ["oauth", "credentials", "setup"])]),
        (nil, [
            ("Don't sync this sign-in", ["pause", "disable"]),
            ("Short name", ["alias", "nickname", "label"]),
            ("New mail is sent from", ["from address", "send as", "alias"]),
            ("Replies come from", ["from address", "send as", "alias"]),
        ]),
    ])

    static let notifications = page("notifications", [
        ("New mail", []),
        ("Also notify me", [
            ("Snoozed conversations come back", ["snooze", "alert"]),
            ("Drafts ready to review", ["ai", "auto-draft", "alert"]),
        ]),
        ("Previews", [
            ("Show previews (sender and subject)", ["privacy", "lock screen", "content"]),
            ("Test notification", ["try", "send a test"]),
        ]),
    ])

    static let importance = page("importance", tab: "rules", [
        ("How mail is sorted", []),
        ("Your rules", [("Add a rule", ["filter", "rule", "new rule"])]),
        ("Default rules", []),
        ("Importance", [
            ("Importance rules", ["important", "priority"]),
            (ImportanceSettingsModel.sendsToGmailTitle, ["gmail", "sync", "important mark"]),
        ]),
        (LearnedBehaviourCenter.switchTitle, [
            (LearnedBehaviourCenter.seedTitle, ["superhuman"]),
            ("Learn from Superhuman's categories", ["superhuman"]),
            (LearnedBehaviourCenter.resetTitle, ["forget", "clear"]),
        ]),
        ("VIPs", [
            (VIPSettingsModel.suggestTitle, ["vip", "important people"]),
            ("Reset suggestions", ["vip"]),
        ]),
    ]) + page("importance", tab: "categories", [
        ("Categories", []),
        ("Auto labels", [("Auto label settings", ["categories", "labels"])]),
    ]) + page("importance", tab: "tracking", [
        ("Tracking", [
            ("Keep a log of how each conversation was sorted", ["history", "log", "debug"]),
            ("Learn from my corrections", ["training", "feedback"]),
            ("Suggest rules when I correct", ["rules", "suggestions"]),
            ("Keep subject and preview text with corrections and the log", ["privacy"]),
        ]),
        ("Decision log", [("Clear decision log", ["history", "delete"])]),
        ("Corrections", [("Clear corrections", ["delete", "training"])]),
    ])

    static let splitInbox = page("splitInbox", [
        ("Splits", [("Hide this tab when it has no mail", ["empty", "split"]), ("Also show in Important/Other", ["split"])]),
        ("Events", [("Re-scan for invites", ["calendar", "invitations"])]),
    ])

    static let sidebar = page("sidebar", [
        (SidebarSettingsModel.accountsTitle, [(SidebarSettingsModel.allInboxesTitle, ["unified inbox", "combined"])]),
        (SidebarSettingsModel.foldersTitle, []),
    ])

    static let snippets = page("snippets", [
        (nil, [
            ("New snippet", ["template", "canned response", "text expansion"]),
            ("Export Snippets…", ["backup", "share"]),
            ("Import Snippets…", ["restore"]),
        ]),
    ])

    static let search = page("search", [
        ("Order", [("Sort results by", ["newest", "relevance", "date"])]),
        ("Most relevant", [("Ranking", ["balanced", "recent first", "weights", "classic"])]),
        ("Search learning", [
            ("Opened from search", ["learning", "history", "reset"]),
            ("All search settings", ["reset", "defaults"]),
        ]),
    ])

    static let shortcuts = page("shortcuts", [
        (nil, [("Print cheat sheet", ["print", "reference", "keys"])]),
        ("Your shortcuts", [("Keymap file", ["export", "import", "reset", "keybindings"])]),
        (ShortcutsSettingsModel.unassignedTitle, []),
    ])

    static let ai = page("ai", tab: "overview", [
        ("Models", []),
        ("Model for each feature", []),
        ("Features", [
            ("Use AI", ["enable", "disable", "turn off"]),
            ("Draft replies", ["suggested replies", "compose"]),
            (AISettingsPageModel.instantReplyStripTitle, ["quick replies", "suggestions", "tab"]),
            ("Summarize conversations when I open them", ["summary", "tldr"]),
            ("Summarize every conversation", ["summary", "background"]),
            (AISettingsPageModel.prepareTitle, ["background", "prefetch"]),
            (AISettingsPageModel.autoDraftTitle, ["drafts", "automatic"]),
            ("Allow Apple Writing Tools in the composer", ["apple intelligence", "rewrite", "proofread"]),
        ]),
        ("Personal writing instructions", [
            (AISettingsPageModel.aboutMeTitle, ["bio", "context", "personal"]),
            (AISettingsPageModel.writingInstructionsTitle, ["tone", "style", "voice"]),
        ]),
        ("On-device AI only", []),
        (ClassifierSettingsModel.title, [
            ("Model folder", ["classifier", "download"]),
            (ClassifierSettingsModel.lowPowerTitle, ["battery", "classifier"]),
        ]),
        ("Smart search", [
            ("Smart search index", ["semantic", "embeddings", "natural language"]),
            ("Index on this Mac", ["semantic", "embeddings", "local"]),
        ]),
    ]) + page("ai", tab: "activity", [
        ("Traces", [
            ("Keep a trace of each AI request", ["log", "history", "debug"]),
            ("Keep for", ["retention", "days"]),
            ("Per feature, keep the newest", ["retention", "limit"]),
            ("Use at most", ["disk", "storage", "space"]),
            ("Clear all traces", ["delete", "history"]),
        ]),
        (AIActivityModel.cacheTitle, [("Clear AI cache", ["delete", "saved answers", "cache"])]),
    ])

    static let calendar = page("calendar", [
        ("Calendar sidebar", [("Show all calendars", ["calendars", "sidebar"])]),
        ("Google clients", [
            ("Google client file", ["oauth", "credentials"]),
            ("How to get a Google client", ["oauth", "setup"]),
        ]),
        ("Connection", [("Connect Google Calendar", ["sign in", "link", "gcal"])]),
        ("Scheduling replies", [
            ("Suggest times when someone proposes one", ["meeting", "availability"]),
            ("Offer to move conflicting meetings", ["conflict", "reschedule"]),
            ("Working hours", ["availability", "office hours"]),
            ("Travel buffer", ["commute", "gap"]),
            ("Accepted times go on the calendar as", ["event", "hold", "busy"]),
            ("Scheduling link", ["calendly", "booking"]),
        ]),
        ("Time zones", [("Second time zone", ["timezone", "tz", "world clock"])]),
        ("Creating events", [
            ("Create event from email", ["invite", "new event"]),
            ("Add a Google Meet link", ["video", "conference", "meet"]),
            ("Confirm calendar moves in the edit pane", ["reschedule", "confirm"]),
        ]),
    ])

    static let appearance = page("appearance", [
        (nil, [("Appearance", ["dark mode", "light mode", "system", "auto"])]),
        ("Theme", [
            ("Theme when light", ["light mode", "colors"]),
            ("Theme when dark", ["dark mode", "colors"]),
        ]),
        ("Color, size and fonts", [
            ("Accent", ["color", "tint", "highlight"]),
            ("Density", ["compact", "spacing", "comfortable"]),
            ("UI font", ["typeface", "font"]),
            ("Reader font", ["typeface", "font", "message"]),
            ("Reader text", ["size", "font size", "message"]),
            ("Email colors", ["html", "dark mode", "invert"]),
        ]),
        ("Theme files", [
            ("Themes folder", ["custom themes", "folder"]),
            ("Import or export a theme", ["custom themes", "share"]),
            ("Reset", ["defaults", "appearance"]),
        ]),
    ])

    static let privacy = page("privacy", [
        ("Remote images", [("Account", ["images", "load images"])]),
        ("Always load images from", []),
    ])

    static let blocked = page("blocked", [
        ("New mail from a blocked sender", [("By default", ["spam", "trash", "archive"])]),
        ("Add", []),
    ])

    static let platform = page("platform", [
        ("Spotlight", [
            ("Index conversations in Spotlight", ["search", "macos"]),
            ("Include subjects and previews", ["spotlight", "privacy"]),
            ("Spotlight index", ["rebuild", "remove"]),
        ]),
        ("Global shortcut", [
            ("Open a new message with a global shortcut", ["hotkey", "compose", "keyboard"]),
            ("Keys", ["hotkey", "global shortcut"]),
        ]),
        ("Services menu", [
            ("Answer the Services menu", ["services", "macos"]),
            ("Hide an item or give it a key", ["services", "keyboard"]),
        ]),
        ("Shortcuts and Siri", [
            ("Let Shortcuts, Siri and Spotlight use Mail", ["app intents", "automation"]),
            ("Include subjects in results", ["shortcuts", "privacy"]),
            ("Let Shortcuts change mail", ["app intents", "automation"]),
            ("Ask before each change", ["shortcuts", "confirm"]),
        ]),
        ("Focus filters", [
            ("Let Focus filters change what Mail shows", ["focus", "do not disturb", "dnd"]),
            ("This Focus", ["focus", "ignore"]),
        ]),
        ("Also available", []),
    ])

    static let advanced = page("advanced", [
        ("Features (restart required)", []),
        ("Unsubscribing", [("Offer to clean up after unsubscribing", ["unsubscribe", "newsletters", "cleanup"])]),
        ("Move to another Mac", [("Settings file", ["export", "import", "backup", "migrate", "transfer"])]),
        ("Diagnostics", [("Export diagnostics", ["logs", "debug", "bug report"])]),
        ("Feedback", [(SendFeedbackCenter.settingsTitle, ["bug", "report"])]),
        ("Import from Superhuman labels", [
            ("Superhuman's Muted and Is Snoozed labels", ["superhuman", "mute", "snooze"]),
            ("Muted in Superhuman", ["superhuman", "mute"]),
            ("Snoozed in Superhuman", ["superhuman", "snooze"]),
        ]),
    ]) + page("advanced", developerOnly: true, [
        ("Developer options", [
            ("Show developer options", ["developer", "debug"]),
            ("Show debugging tools", ["developer", "debug"]),
            ("Send to another device via Tailscale", ["developer", "feedback", "tailscale"]),
        ]),
        ("Developer feedback (temporary)", [
            ("Developer feedback mode", ["developer", "checklist"]),
            ("Receiving device's Tailscale name", ["developer", "tailscale"]),
            ("Feedback folder", ["developer"]),
        ]),
    ])
}
