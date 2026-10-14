import MailTheme
import SwiftUI

public struct StartupProblem {
    public var title: String
    public var message: String
    public var details: String?
    public var action: (title: String, run: @MainActor () -> Void)?

    public init(title: String, message: String, details: String? = nil,
                action: (title: String, run: @MainActor () -> Void)? = nil) {
        self.title = title
        self.message = message
        self.details = details
        self.action = action
    }
}

public struct StartupProblemView: View {
    let problem: StartupProblem
    let quit: @MainActor () -> Void
    let copy: @MainActor (String) -> Void
    @Environment(\.theme) private var theme
    @State private var showsDetails = false

    public init(problem: StartupProblem, quit: @escaping @MainActor () -> Void,
                copy: @escaping @MainActor (String) -> Void) {
        self.problem = problem
        self.quit = quit
        self.copy = copy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.space4) {
            Text(problem.title)
                .font(theme.typeTitle.swiftUIFont)
                .foregroundStyle(theme.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
            Text(problem.message)
                .font(theme.typeReader.swiftUIFont)
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            if let details = problem.details {
                DisclosureGroup("Details", isExpanded: $showsDetails) {
                    ScrollView {
                        Text(details)
                            .font(theme.typeMono.swiftUIFont)
                            .foregroundStyle(theme.textSecondary.color)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(theme.space4)
                    }
                    .frame(maxHeight: StartupMetrics.detailsMaxHeight)
                    .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgSunken.color))
                }
                .font(theme.typeBody.swiftUIFont)
                .foregroundStyle(theme.textSecondary.color)
                .disclosureGroupStyle(StartupDetailsStyle(theme: theme))
            }
            HStack(spacing: theme.space4) {
                if let details = problem.details {
                    Button("Copy details") { copy(details) }
                        .ohLinkButtonStyle()
                }
                Spacer(minLength: theme.space4)
                Button("Quit Mail") { quit() }
                    .keyboardShortcut(problem.action == nil ? KeyboardShortcut.defaultAction : KeyboardShortcut.cancelAction)
                if let action = problem.action {
                    Button(action.title) { action.run() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, theme.space4)
        }
        .frame(width: StartupMetrics.columnWidth, alignment: .leading)
        .padding(theme.space8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bgWindow.color)
        .environment(\.colorScheme, theme.appearance == .dark ? .dark : .light)
    }
}

public struct LaunchingView: View {
    @Environment(\.theme) private var theme
    @State private var showsText = false

    public init() {}

    public var body: some View {
        VStack(spacing: theme.space4) {
            if showsText {
                LaunchSpinner()
                Text("Opening your mail…")
                    .font(theme.typeBody.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bgWindow.color)
        .environment(\.colorScheme, theme.appearance == .dark ? .dark : .light)
        .task {
            try? await Task.sleep(for: .milliseconds(Int(theme.motionLaunchQuiet)))
            showsText = true
        }
    }
}

private struct LaunchSpinner: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
            let turn = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(theme.textSecondary.color, style: StrokeStyle(lineWidth: StartupMetrics.spinnerLine, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
        }
        .frame(width: StartupMetrics.spinnerSize, height: StartupMetrics.spinnerSize)
        .accessibilityHidden(true)
    }
}

private struct StartupDetailsStyle: DisclosureGroupStyle {
    let theme: ResolvedTheme

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: theme.space2) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: StartupMetrics.chevronSize, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: StartupMetrics.chevronSize + 4)
                        .accessibilityHidden(true)
                    configuration.label
                }
                .foregroundStyle(theme.textSecondary.color)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

enum StartupMetrics {
    static let chevronSize: CGFloat = 10
    static let spinnerSize: CGFloat = 16
    static let spinnerLine: CGFloat = 2
    static let columnWidth: CGFloat = 440
    static let detailsMaxHeight: CGFloat = 160
}
