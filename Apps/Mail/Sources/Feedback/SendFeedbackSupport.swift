import AppKit
import MailFeatures
import MailTheme
import MailUI
import SwiftUI

@MainActor
enum SendFeedbackSupport {
    static func install(in environment: AppEnvironment, window: MailWindowModel?,
                        options: DeveloperOptions = AppDeveloperOptions.shared(MailApp.devFeedback.availability)) {
        let center = environment.system.sendFeedback
        center.window = window
        center.isOffered = { options.offersSendToDevice }
        center.makeModel = { [weak environment] in
            guard let environment else { return SendFeedbackModel(SendFeedbackDependencies(runner: nil, appInfo: { fallbackInfo })) }
            return environment.system.makeSendFeedbackModel(io: makeIO())
        }
    }

    static func makeIO() -> SendFeedbackHostIO {
        SendFeedbackHostIO(
            runner: TailscaleLocator.find().map { TailscaleProcessRunner(executable: $0) },
            screenshot: { MailApp.devFeedback.host?.captureScreenshot() },
            chooseSaveLocation: { name in
                let panel = NSSavePanel()
                panel.nameFieldStringValue = name
                panel.allowedContentTypes = [.zip]
                panel.canCreateDirectories = true
                panel.title = "Save Feedback"
                panel.message = "The file has what you ticked in the sheet: your note, scrubbed diagnostics, and nothing else."
                return panel.runModal() == .OK ? panel.url : nil
            },
            share: { url in
                let anchor = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView
                guard let anchor else { return }
                let picker = NSSharingServicePicker(items: [url])
                picker.show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
            },
            defaults: .standard)
    }

    static func feedbackSheetAction(_ center: DevFeedbackCenter,
                                    send: SendFeedbackCenter? = MailApp.app.router?.environment.system.sendFeedback) -> (() -> Void)? {
        guard send?.canBegin == true else { return nil }
        return { openFromFeedbackSheet(center) }
    }

    static func openFromFeedbackSheet(_ center: DevFeedbackCenter) {
        center.isFeedbackSheetPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MailApp.app.router?.environment.system.sendFeedback.begin()
        }
    }

    private nonisolated static let fallbackInfo = DiagnosticsAppInfo(version: "0", build: "0", gitCommit: "unknown", os: "unknown", dataMode: "unknown")
}

struct SendFeedbackSheetHost: ViewModifier {
    let center: SendFeedbackCenter
    let themes: ThemeStore

    func body(content: Content) -> some View {
        let presented = center.isPresented
        content.sheet(isPresented: Binding(get: { presented }, set: { center.isPresented = $0 })) {
            if let model = center.model {
                SendFeedbackSheet(model: model, onClose: { center.isPresented = false })
                    .themed(by: themes)
            }
        }
    }
}
