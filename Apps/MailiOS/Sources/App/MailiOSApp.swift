import MailFeatures
import MailTheme
import MailUI
import OpenHumanMailLive
import SwiftUI
import UIKit

@main
struct MailiOSApp: App {
    @MainActor static let app = CompositionRoot.makeApp()
    @MainActor static let themes = ThemeStore(preferencesStore: PhoneThemes.preferencesStore())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneRootView(app: Self.app)
                .phoneThemed(by: Self.themes)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            ScenePhaseRelay.shared.changed(to: phase)
        }
    }
}

enum PhoneThemes {
    static func preferencesStore(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> any ThemePreferencesStoring {
        environment["XCTestConfigurationFilePath"] == nil ? UserDefaultsThemePreferencesStore() : MemoryThemePreferencesStore()
    }
}

struct PhoneRootView: View {
    let app: AppModel
    @Environment(\.touch) private var theme

    var body: some View {
        switch app.screen {
        case .launching:
            theme.window.ignoresSafeArea()
        case .mail(let environment):
            PhoneShell(environment: environment)
                .id(ObjectIdentifier(environment))
        case .signIn:
            PhoneNoticeView(title: CompositionRoot.signInLaterTitle, message: CompositionRoot.signInLaterMessage,
                            details: nil, action: nil)
        case .notice(let problem):
            PhoneNoticeView(title: problem.title, message: problem.message, details: problem.details,
                            action: problem.action)
        }
    }
}

struct PhoneNoticeView: View {
    let title: String
    let message: String
    let details: String?
    let action: (title: String, run: @MainActor () -> Void)?
    @Environment(\.touch) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.tokens.space5) {
                Image(systemName: "envelope")
                    .font(.system(.largeTitle, weight: .semibold))
                    .foregroundStyle(theme.onAccent)
                    .frame(width: 64, height: 64)
                    .background(RoundedRectangle(cornerRadius: theme.tokens.radiusLG).fill(theme.accent))
                    .accessibilityHidden(true)
                Text(title)
                    .font(theme.title)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(theme.body)
                    .foregroundStyle(theme.textSecondary)
                if let details {
                    Text(details)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .textSelection(.enabled)
                        .padding(theme.tokens.space4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: theme.tokens.radiusMD).fill(theme.sunken))
                }
                if let action {
                    Button(action.title) { action.run() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, theme.tokens.space8)
            .padding(.top, 120)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.window.ignoresSafeArea())
    }
}

// Why: hiding the navigation bar turns off the edge swipe back; this keeps it
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
