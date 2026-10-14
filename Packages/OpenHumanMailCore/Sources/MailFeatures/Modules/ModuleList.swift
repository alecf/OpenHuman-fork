import MailActions

public enum ModuleList {
    @MainActor public static let all: [any FeatureModule] = [
        SnoozeModule(),
        SendLaterModule(),
        RemindersModule(),
        ImportanceModule(),
        NotificationsModule(),
        DockBadgeModule(),
        UnsubscribeModule(),
        LaunchAtLoginModule(),
        DiagnosticsModule(),
        ReviewModule(),
        AIModule(),
        MuteModule(),
        BlockModule(),
        InstantReplyModule(),
        HygieneModule(),
        ServicesModule(),
        AttachmentDragModule(),
        SpotlightModule(),
        MenuBarExtraModule(),
        GlobalHotkeyModule(),
        AppIntentsModule(),
        FocusFiltersModule(),
        SmartSearchModule(),
    ]
}
