import Foundation
import Observation

public struct GoogleClientGuideLink: Hashable, Sendable {
    public let label: String
    public let url: URL
    public var domain: String { url.host ?? "" }
    public var accessibilityLabel: String { "\(label), opens \(domain) in your browser" }
}

public struct GoogleClientGuideStep: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let action: String
    public let why: String
    public let links: [GoogleClientGuideLink]
    public let copyValue: String?

    public var link: URL? { links.first?.url }
}

@MainActor @Observable
public final class GoogleClientGuide {
    public static let gmailPermission = "https://www.googleapis.com/auth/gmail.modify"

    public static let title = "Set up Google sign-in"
    public static let intro = "Mail signs in through a Google Cloud project that you own. It's free, and you only do it once."
    public static let reassurance = [
        "Your mail goes straight from Google to this Mac. Nothing goes through our servers.",
        "These steps don't touch your mail.",
        "Mail keeps the file on this Mac, readable only by you.",
    ]
        public static let haveFileTitle = "I have the file"
    public static let skipTitle = "Skip, I'll do this later"
    public static let laterNote = "Without the file Mail can't sign in yet. This screen shows the steps again whenever you "
        + "open Mail, and Settings › Accounts has them as text you can copy."

    public static let steps: [GoogleClientGuideStep] = [
        GoogleClientGuideStep(
            id: "project", title: "Create a project",
            action: "Create a new project; any name works, for example “OpenHuman Mail”.",
            why: "The project holds your own sign-in settings.",
            links: [GoogleClientGuideLink(label: "Open your projects", url: GoogleConsoleLinks.projects)], copyValue: nil),
        GoogleClientGuideStep(
            id: "gmail", title: "Turn on Gmail",
            action: "Enable the Gmail API, and the Calendar API too if you want your calendar in Mail.",
            why: "This lets your project read and organize your Gmail.",
            links: [GoogleClientGuideLink(label: "Enable Gmail API", url: GoogleConsoleLinks.enableGmail),
                    GoogleClientGuideLink(label: "Enable Calendar API", url: GoogleConsoleLinks.enableCalendar)],
            copyValue: nil),
        GoogleClientGuideStep(
            id: "branding", title: "Name your app",
            action: "Under Google Auth Platform › Branding, enter an app name and your support email, then save.",
            why: "Google shows this name when you sign in.",
            links: [GoogleClientGuideLink(label: "Open Google Auth Platform", url: GoogleConsoleLinks.authOverview)],
            copyValue: nil),
        GoogleClientGuideStep(
            id: "audience", title: "Choose who can sign in",
            action: "Choose External, then add yourself as a test user or publish the app.",
            why: "Publishing (“In production”) avoids Google asking you to sign in again every 7 days; Google warns the "
                + "app isn't verified, which is expected for your own project.",
            links: [GoogleClientGuideLink(label: "Open Audience", url: GoogleConsoleLinks.authAudience)], copyValue: nil),
        GoogleClientGuideStep(
            id: "access", title: "Allow Gmail access",
            action: "Under Data Access, add this Gmail permission (Google marks it restricted):",
            why: "It's the only Gmail permission Mail uses.",
            links: [GoogleClientGuideLink(label: "Open Google Auth Platform", url: GoogleConsoleLinks.authOverview)],
            copyValue: gmailPermission),
        GoogleClientGuideStep(
            id: "client", title: "Make the client file",
            action: "Choose Create client, pick Desktop app as the type, then choose Create.",
            why: "This makes the file Mail needs.",
            links: [GoogleClientGuideLink(label: "Open Clients", url: GoogleConsoleLinks.authClients)], copyValue: nil),
        GoogleClientGuideStep(
            id: "download", title: "Download it now",
            action: "Download the JSON right now. Google will not show the secret again; if you lose it, make a new secret.",
            why: "Mail reads this file to open Google's sign-in page for your project.",
            links: [GoogleClientGuideLink(label: "About the client secret", url: GoogleConsoleLinks.secretHelp)],
            copyValue: nil),
    ]

    public static let multiAccountHint = "Signed in to several Google accounts? Open the link in the browser profile for the right one."
    public static let copyLinkTitle = "Copy link"

    @discardableResult
    public static func open(_ link: GoogleClientGuideLink, using opener: (URL) -> Void) -> Bool {
        guard GoogleConsoleLinks.isAllowed(link.url) else { return false }
        opener(link.url)
        return true
    }

    @discardableResult
    public static func copyAddress(of link: GoogleClientGuideLink, using copier: (String) -> Void) -> Bool {
        guard GoogleConsoleLinks.isAllowed(link.url) else { return false }
        copier(link.url.absoluteString)
        return true
    }

    public private(set) var done: Set<String> = []

    public init() {}

    public func isDone(_ step: GoogleClientGuideStep) -> Bool { done.contains(step.id) }

    public func toggle(_ step: GoogleClientGuideStep) {
        if done.contains(step.id) { done.remove(step.id) } else { done.insert(step.id) }
    }

    public var progressText: String { "\(done.count) of \(Self.steps.count) done" }

    public func accessibilityLabel(_ step: GoogleClientGuideStep) -> String {
        let number = (Self.steps.firstIndex(of: step) ?? 0) + 1
        return "Step \(number), \(step.title), \(isDone(step) ? "done" : "not done")"
    }

    public static var plainText: String {
        var lines = ["How to get a Google client file for OpenHuman Mail", "", intro]
        lines += reassurance
        lines.append("")
        for (index, step) in steps.enumerated() {
            lines.append("\(index + 1). \(step.title). \(step.action)")
            if let value = step.copyValue { lines.append("   \(value)") }
            lines.append("   Why: \(step.why)")
            for link in step.links { lines.append("   Page: \(link.url.absoluteString)") }
        }
        lines.append("\(steps.count + 1). Import it. In Mail's sign-in screen choose “I have the file” (or “I already have "
            + "the file…”) and pick the file you downloaded.")
        lines += ["", multiAccountHint]
        return lines.joined(separator: "\n")
    }
}
