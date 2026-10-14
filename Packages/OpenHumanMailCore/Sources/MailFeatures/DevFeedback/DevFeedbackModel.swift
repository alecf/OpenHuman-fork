import Foundation
import Observation

@MainActor
@Observable
public final class DevFeedbackModel {
    public struct Saved: Equatable, Sendable {
        public let bundlePath: String
        public let screenshotPath: String?
        public let sendCommand: String
        public let receiveCommand: String
        public let needsTarget: Bool
        public let answersIncluded: Int
    }

    public enum State: Equatable, Sendable {
        case editing
        case saving
        case saved(Saved)
        case failed(String)
    }

    public var category: DevFeedbackCategory = .bug
    public var text = ""
    public var includeSnapshot = true
    public var includeLogs = true
    public var includeThreadContent = false
    public var includeScreenshot = false
    public private(set) var state: State = .editing

    public var threadContentAvailable: Bool { threadContent != nil }
    public var screenshotAvailable: Bool { screenshot != nil }
    public var pendingAnswerCount: Int { center?.checklist.answersToExport().count ?? 0 }

    @ObservationIgnored public private(set) var id = DevFeedbackExporter.makeID()
    @ObservationIgnored private weak var center: DevFeedbackCenter?
    @ObservationIgnored private let threadContent: DevFeedbackBundle.ThreadContent?
    @ObservationIgnored private let screenshot: Data?
    @ObservationIgnored private let denylist: [String]
    @ObservationIgnored private var snapshotTask: Task<DevFeedbackSnapshot?, Never>?

    init(center: DevFeedbackCenter, threadContent: DevFeedbackBundle.ThreadContent?, screenshot: Data?, denylist: [String]) {
        self.center = center
        self.threadContent = threadContent
        self.screenshot = screenshot
        self.denylist = denylist
    }

    isolated deinit {
        snapshotTask?.cancel()
    }

    func captureSnapshot(_ make: @escaping @MainActor () async -> DevFeedbackSnapshot?) {
        snapshotTask = Task { await make() }
    }

    public func makeBundle() async -> (bundle: DevFeedbackBundle, screenshot: Data?) {
        let createdAt = center?.currentDate ?? Date()
        let snapshot = includeSnapshot ? await snapshotTask?.value : nil
        var logs: [DevFeedbackLogBuffer.Line]?
        if includeLogs, let center {
            let scrubber = DevFeedbackRedactor(denylist: denylist)
            logs = center.logs.lines(now: createdAt).map { line in
                var line = line
                line.message = scrubber.scrub(line.message)
                return line
            }
        }
        let checklist = center?.checklist
        let items = Dictionary((checklist?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let answers = (checklist?.answersToExport() ?? []).map { answer in
            DevFeedbackBundle.ChecklistAnswer(itemID: answer.itemID, area: items[answer.itemID]?.area,
                                              title: items[answer.itemID]?.title, result: answer.result?.rawValue,
                                              note: answer.note, answeredAt: answer.answeredAt)
        }
        let content = includeThreadContent ? threadContent : nil
        let image = includeScreenshot ? screenshot : nil
        let bundle = DevFeedbackBundle(
            id: id, createdAt: createdAt, category: category,
            text: String(text.prefix(DevFeedbackExporter.maxTextLength)),
            attachments: .init(snapshot: snapshot != nil, logs: logs != nil, threadSubjectAndSender: content != nil,
                               screenshot: image != nil),
            snapshot: snapshot, logs: logs, content: content, screenshotFile: nil,
            checklist: .init(source: checklist?.checklist.source.rawValue ?? "none", itemCount: checklist?.items.count ?? 0,
                             testedCount: checklist?.testedCount ?? 0, answers: answers))
        return (bundle, image)
    }

    public func submit() async {
        guard state == .editing || isFailed else { return }
        guard let center else { state = .failed("The feedback mode is not running."); return }
        state = .saving
        let (bundle, image) = await makeBundle()
        do {
            let export = try DevFeedbackExporter.write(bundle, screenshot: image, to: center.paths.feedbackDirectory)
            id = String(export.bundleURL.deletingPathExtension().lastPathComponent.suffix(6))
            center.checklist.markExported(bundle.checklist.answers.map(\.itemID), at: bundle.createdAt)
            center.history.record("menu:dev.feedbackSaved")
            let target = center.settings.taildropTarget
            state = .saved(Saved(bundlePath: export.bundleURL.path, screenshotPath: export.screenshotURL?.path,
                                 sendCommand: DevFeedbackCommands.send(files: export.files, target: target),
                                 receiveCommand: DevFeedbackCommands.receive,
                                 needsTarget: DevFeedbackCommands.resolvedTarget(target) == nil,
                                 answersIncluded: bundle.checklist.answers.count))
        } catch {
            state = .failed("Couldn't write the feedback file in \(center.paths.feedbackDirectory.path).")
        }
    }

    var isSaved: Bool {
        if case .saved = state { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}
