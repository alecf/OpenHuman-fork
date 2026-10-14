import Foundation
import MailModel
import Observation
import OpenHumanCore

public struct AIChoiceOption: Identifiable, Hashable, Sendable {
    public let choice: DraftRepliesChoice
    public let title: String
    public let detail: String
    public let isEnabled: Bool
    public let disabledReason: String?
    public var id: DraftRepliesChoice { choice }
}

public struct SampleSummary: Hashable, Sendable {
    public let text: String
    public let badge: String
}

@MainActor @Observable
public final class AIStepModel {
    public static let explanation = "On-device models draft replies without your email leaving this Mac; Claude Code and "
        + "Codex send it to another company, so they are never turned on unless you do it yourself in Settings."
    public static let footnote = "You can change this any time in Settings › AI. Agent CLIs (Claude Code, Codex) are off, and "
        + "quick replies are never auto-generated with them unless you opt in."
    public static let badge = "On this Mac"

    public private(set) var status: OnDeviceAIStatus = .unavailable(hint: "Checking this Mac…")
    public private(set) var options: [AIChoiceOption] = []
    public var selected: DraftRepliesChoice?
    public private(set) var isSaving = false
    public private(set) var saved: DraftRepliesChoice?
    public private(set) var sample: SampleSummary?
    public private(set) var sampleNote: String?
    public private(set) var errorMessage: String?

    @ObservationIgnored private let port: any AIOnboardingPort
    @ObservationIgnored private let sampleThread: @MainActor () async -> ThreadKey?

    public init(port: any AIOnboardingPort, sampleThread: @escaping @MainActor () async -> ThreadKey? = { nil }) {
        self.port = port
        self.sampleThread = sampleThread
    }

    public func load(previous: DraftRepliesChoice? = nil) async {
        status = await port.onDeviceStatus()
        let available = status.isAvailable
        var reason: String?
        if case .unavailable(let hint) = status { reason = hint }
        options = [
            AIChoiceOption(choice: .onDeviceAuto, title: "Yes, draft replies on this Mac",
                           detail: "Quick replies are written automatically when you open a conversation, on this Mac only.",
                           isEnabled: available, disabledReason: reason),
            AIChoiceOption(choice: .onDemand, title: "Only when I ask (⌘J / quick replies on demand)",
                           detail: "Nothing is written until you ask.", isEnabled: true, disabledReason: nil),
            AIChoiceOption(choice: .off, title: "Not at all", detail: "Reply drafting is off.", isEnabled: true,
                           disabledReason: nil),
        ]
        if let previous, options.first(where: { $0.choice == previous })?.isEnabled == true {
            selected = previous
        } else {
            selected = available ? .onDeviceAuto : .onDemand
        }
    }

    public func confirm() async {
        guard let selected, !isSaving, options.first(where: { $0.choice == selected })?.isEnabled == true else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await port.setDraftReplies(selected)
            saved = selected
        } catch {
            errorMessage = "Couldn't save that choice. You can set it in Settings › AI."
            return
        }
        guard selected != .off else {
            sampleNote = nil
            return
        }
        await runSample()
    }

    private func runSample() async {
        sample = nil
        sampleNote = nil
        guard status.isAvailable else {
            sampleNote = "This Mac's model isn't available yet, so no sample was written. Replies are on when you ask."
            return
        }
        guard let thread = await sampleThread() else {
            sampleNote = "There is no conversation to summarize yet."
            return
        }
        do {
            if let text = try await port.summarizeOnDevice(thread) {
                sample = SampleSummary(text: text, badge: Self.badge)
            } else {
                sampleNote = "Summaries on this Mac arrive in a later version."
            }
        } catch {
            sampleNote = "The model on this Mac couldn't write a sample just now."
        }
    }
}
