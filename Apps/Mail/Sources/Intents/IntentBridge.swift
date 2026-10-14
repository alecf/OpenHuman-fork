import MailFeatures

@MainActor
enum IntentBridge {
    static var override: (any IntentPerforming)?

    static var current: any IntentPerforming {
        if let override { return override }
        return MailApp.app.intents
    }
}
