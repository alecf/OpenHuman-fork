import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUIMac
import OpenHumanCore
import Synchronization

@MainActor
public final class ListPerfHarness {
    public struct Options: Sendable {
        public var threadCount = 50_000
        public var windowSize = CGSize(width: 1280, height: 800)
        public var onscreen = false
        public var pacedSweepRows = 10_000
        public var pacedRowsPerFrame = 4
        public var fullSweepRowsPerFrame = 16
        public var jumps = 20
        public var stormWrites = 300
        public var cursorMoves = 300
        public var markDones = 100
        public var smallWindowChanges = 50
        public var densityChanges = 6
        public var seed: UInt64 = 7
        public var only: Set<String>?

        public init() {}

        public static var smoke: Options {
            var o = Options()
            o.threadCount = 3_000
            o.pacedSweepRows = 400
            o.fullSweepRowsPerFrame = 40
            o.jumps = 4
            o.stormWrites = 30
            o.cursorMoves = 40
            o.markDones = 10
            o.smallWindowChanges = 6
            o.densityChanges = 2
            return o
        }
    }

    public enum Budgets {
        public static let frame = PerfBudget(p95: PerfBudget.frame, max: 2 * PerfBudget.frame)
        public static let sweep = PerfBudget(p95: PerfBudget.frame)
        public static let selection = PerfBudget(p95: PerfBudget.frame, max: PerfBudget.frame)
        public static let markDone = PerfBudget(p95: PerfBudget.frame, max: 2 * PerfBudget.frame)
        public static let smallApply = PerfBudget(p95: 2)
        public static let stormInstall = PerfBudget(p95: 4, max: PerfBudget.frame)
        public static let density = PerfBudget(max: 2 * PerfBudget.frame)
    }

    public private(set) var problems: [String] = []

    private let options: Options
    private let clock = ContinuousClock()
    private var installs: [(at: ContinuousClock.Instant, ms: Double)] = []
    private var store: FakeMailStore!
    private var model: ThreadListModel!
    private var controller: ThreadListViewController!
    private var window: NSWindow!
    private var progress: ((String) -> Void)?

    public init(options: Options = Options()) {
        self.options = options
    }

    private static func ms(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    private var table: NSTableView { controller.tableView }
    private var clip: NSClipView { table.enclosingScrollView!.contentView }
    private var rowHeight: CGFloat { table.rowHeight }
    private var maxY: CGFloat { max(0, CGFloat(table.numberOfRows) * rowHeight - clip.bounds.height) }

    public func run(progress: ((String) -> Void)? = nil) async throws -> PerfReport {
        self.progress = progress
        var report = PerfReport()
        report.header = try await setUp()
        defer { window.close() }

        func wants(_ name: String) -> Bool {
            guard options.only?.contains(name) ?? true else { return false }
            progress?(name)
            return true
        }
        if wants("paced") { report.results += try await pacedSweep() }
        if wants("selection") { report.results.append(cursorMoves()) }
        if wants("markdone") { report.results.append(try await markDone()) }
        if wants("jumps") { report.results += try await jumps() }
        if wants("sweep") { report.results.append(try await fullSweep()) }
        if wants("storm") { report.results += try await updateStorm() }
        if wants("small") { report.results.append(try await smallWindowChange()) }
        if wants("density") { report.results.append(densityChanges()) }
        if !problems.isEmpty { report.header.append("Problems: " + problems.joined(separator: "; ")) }
        return report
    }

    private func setUp() async throws -> [String] {
        _ = NSApplication.shared
        let fixedNow = Date(timeIntervalSince1970: 1_791_000_000)
        var start = clock.now
        let corpus = FakeCorpus.make(threadCount: options.threadCount, now: fixedNow)
        let corpusMs = Self.ms(clock.now - start)
        start = clock.now
        store = FakeMailStore(corpus: corpus, options: .init(remoteAck: .immediate))
        model = ThreadListModel(data: store, location: .system(.inbox), account: AccountID(1))
        model.onInstall = { [weak self] _, duration in
            guard let self else { return }
            self.installs.append((self.clock.now, Self.ms(duration)))
        }
        controller = ThreadListViewController(theme: .light)
        let frame = options.onscreen
            ? NSRect(origin: NSPoint(x: 80, y: 80), size: options.windowSize)
            : NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: options.windowSize)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Mail list perf harness (fake data)"
        window.contentView = controller.view
        window.orderFrontRegardless()
        controller.model = model
        model.start()
        try await until(seconds: 120) { self.model.rows.count >= min(self.options.threadCount, ThreadListModel.initialLimit) }
        let firstRowsMs = Self.ms(clock.now - start)
        layoutAndDraw()
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        return [
            "Thread list perf harness. Fake corpus \(options.threadCount) threads, one inbox.",
            "Build \(build); \(Self.hardware()); \(ProcessInfo.processInfo.activeProcessorCount) cores; macOS \(os).",
            "Window \(Int(options.windowSize.width))x\(Int(options.windowSize.height)) pt, "
                + (options.onscreen ? "on screen" : "off screen (backing store only: no compositor, no vsync)")
                + "; row height \(Int(rowHeight)) pt; \(table.numberOfRows) table rows (loaded + placeholders).",
            String(format: "Corpus generated in %.0f ms; store + first window on screen in %.0f ms.", corpusMs, firstRowsMs),
            String(format: "Load average at start %.1f %.1f %.1f (other processes share the cores: spikes are not all ours).",
                   load[0], load[1], load[2]),
        ]
    }

    private static func hardware() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func until(seconds: Double, _ condition: @MainActor () -> Bool) async throws {
        let deadline = clock.now + .seconds(seconds)
        while !condition() {
            if clock.now > deadline { throw HarnessError.timeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    enum HarnessError: Error { case timeout }

    private func layoutAndDraw() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    private func frame(to y: CGFloat) -> Double {
        autoreleasepool {
            let start = clock.now
            clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
            table.enclosingScrollView?.reflectScrolledClipView(clip)
            let scrolled = clock.now
            window.contentView?.layoutSubtreeIfNeeded()
            let laidOut = clock.now
            window.displayIfNeeded()
            let drawn = clock.now
            CATransaction.flush()
            let end = clock.now
            let total = Self.ms(end - start)
            if total > 2 * PerfBudget.frame, slowFrames.count < 12 {
                slowFrames.append(String(format: "%.1f ms = scroll+cells %.1f, layout %.1f, display %.1f, commit %.1f",
                                         total, Self.ms(scrolled - start), Self.ms(laidOut - scrolled),
                                         Self.ms(drawn - laidOut), Self.ms(end - drawn)))
            }
            return total
        }
    }

    private var slowFrames: [String] = []

    private func takeSlowFrames() -> [String] {
        defer { slowFrames = [] }
        return slowFrames.map { "slow frame: " + $0 }
    }

    private var placeholderVisible: Bool { controller.visibleRowRange.upperBound > model.rows.count }

    private func installsSince(_ instant: ContinuousClock.Instant) -> Double {
        installs.reversed().prefix { $0.at > instant }.reduce(0) { $0 + $1.ms }
    }

    private func pacedSweep() async throws -> [PerfResult] {
        clip.scroll(to: .zero)
        layoutAndDraw()
        let frames = max(1, min(options.pacedSweepRows, options.threadCount) / options.pacedRowsPerFrame)
        var work: [Double] = [], busy: [Double] = []
        var placeholderFrames = 0
        var deadline = clock.now
        var previous = clock.now
        for i in 1...frames {
            let w = frame(to: CGFloat(i * options.pacedRowsPerFrame) * rowHeight)
            work.append(w)
            busy.append(w + installsSince(previous))
            previous = clock.now
            if placeholderVisible { placeholderFrames += 1 }
            deadline = deadline.advanced(by: .microseconds(8_333))
            try await Task.sleep(until: deadline, clock: clock)
        }
        let rows = options.pacedRowsPerFrame * frames
        checkConsistency("paced sweep")
        return [
            PerfResult(name: "scroll frame, paced 120 Hz, \(rows) rows", samples: work, budget: Budgets.frame,
                       notes: ["frames showing a not-yet-loaded row: \(placeholderFrames) of \(frames)"] + takeSlowFrames()),
            PerfResult(name: "main busy per frame (frame + installs)", samples: busy, budget: Budgets.frame),
        ]
    }

    private func fullSweep() async throws -> PerfResult {
        clip.scroll(to: .zero)
        layoutAndDraw()
        var work: [Double] = []
        var placeholderFrames = 0
        let step = options.fullSweepRowsPerFrame
        var row = 0
        let start = clock.now
        while CGFloat(row) * rowHeight < maxY {
            row += step
            work.append(frame(to: CGFloat(row) * rowHeight))
            if placeholderVisible { placeholderFrames += 1 }
            await Task.yield()
        }
        let seconds = Self.ms(clock.now - start) / 1000
        try await until(seconds: 60) { !self.placeholderVisible }
        checkConsistency("full sweep")
        return PerfResult(name: "scroll frame, back to back, all \(options.threadCount) rows", samples: work,
                          budget: Budgets.sweep, notes: [
                              String(format: "%d frames in %.1f s; frames showing a not-yet-loaded row: %d", work.count,
                                     seconds, placeholderFrames),
                              "loaded rows at the end: \(model.rows.count) of \(model.totalCount)",
                          ] + takeSlowFrames())
    }

    private func jumps() async throws -> [PerfResult] {
        var rng = SplitMix(seed: options.seed)
        var frames: [Double] = [], fills: [Double] = []
        for _ in 0..<options.jumps {
            let target = CGFloat(rng.next() % UInt64(max(1, table.numberOfRows))) * rowHeight
            frames.append(frame(to: target))
            let start = clock.now
            try await until(seconds: 60) { !self.placeholderVisible }
            fills.append(Self.ms(clock.now - start))
            layoutAndDraw()
        }
        checkConsistency("jumps")
        return [
            PerfResult(name: "scroller jump frame", samples: frames, budget: Budgets.frame, notes: takeSlowFrames()),
            PerfResult(name: "jump until visible rows loaded (wall)", samples: fills, budget: nil,
                       notes: ["a first visit walks 500-row static pages from the top; loaded targets are ~0 ms"]),
        ]
    }

    private func cursorMoves() -> PerfResult {
        clip.scroll(to: .zero)
        layoutAndDraw()
        if let first = model.rows.first?.id { model.setCursor(first) }
        var samples: [Double] = []
        for i in 0..<options.cursorMoves {
            let start = clock.now
            model.moveCursor(by: i < options.cursorMoves / 2 ? 1 : -1)
            layoutAndDraw()
            samples.append(Self.ms(clock.now - start))
        }
        return PerfResult(name: "selection change (j/k) to drawn", samples: samples, budget: Budgets.selection)
    }

    private func markDone() async throws -> PerfResult {
        var samples: [Double] = []
        var hidden: Set<ThreadKey> = []
        for _ in 0..<options.markDones {
            guard let cursor = model.cursor else { break }
            let start = clock.now
            model.applyOptimistic(.markDone([cursor]))
            layoutAndDraw()
            samples.append(Self.ms(clock.now - start))
            hidden.insert(cursor)
            if model.index(of: cursor) != nil { problems.append("mark done left the row on screen") }
        }
        model.clearOptimistic(for: hidden)
        try await until(seconds: 30) { self.model.optimisticKeys.isEmpty && self.hiddenCount(hidden) == 0 }
        checkConsistency("mark done")
        return PerfResult(name: "mark done (overlay) to row gone, drawn", samples: samples, budget: Budgets.markDone)
    }

    private func hiddenCount(_ keys: Set<ThreadKey>) -> Int { keys.filter { model.index(of: $0) == nil }.count }

    private func updateStorm() async throws -> [PerfResult] {
        let target = 300
        _ = frame(to: CGFloat(target) * rowHeight)
        try await until(seconds: 30) { !self.placeholderVisible }
        let anchor = model.rows[Int((clip.bounds.origin.y / rowHeight).rounded(.down))].id
        let anchorOffset = clip.bounds.origin.y - CGFloat(model.index(of: anchor) ?? 0) * rowHeight
        let flips = Array(model.rows.prefix(600).map(\.id))
        let removals = Array(model.rows[700..<min(model.rows.count, 760)].map(\.id))
        installs.removeAll()
        let store = self.store!
        let writes = options.stormWrites
        let started = clock.now
        let done = DoneFlag()
        let writer = Task.detached {
            defer { done.set() }
            for i in 0..<writes {
                switch i % 6 {
                case 0:
                    store.deliverMessage(account: AccountID(1), from: EmailAddress(name: "Storm \(i)", email: "storm\(i)@example.org"),
                                         subject: "Storm message \(i)")
                case 1 where !removals.isEmpty:
                    store.removeThreads([removals[(i / 6) % removals.count]])
                default:
                    let key = flips[(i * 7) % flips.count]
                    _ = try? await store.apply(i % 2 == 0 ? .markRead([key]) : .markUnread([key]))
                }
            }
        }
        var busy: [Double] = []
        var deadline = clock.now
        var previous = clock.now
        while !done.isSet {
            let w = frame(to: clip.bounds.origin.y)
            busy.append(w + installsSince(previous))
            previous = clock.now
            deadline = deadline.advanced(by: .microseconds(8_333))
            try await Task.sleep(until: deadline, clock: clock)
        }
        await writer.value
        let seconds = Self.ms(clock.now - started) / 1000
        for _ in 0..<30 {
            deadline = deadline.advanced(by: .microseconds(8_333))
            try await Task.sleep(until: deadline, clock: clock)
            busy.append(frame(to: clip.bounds.origin.y) + installsSince(previous))
            previous = clock.now
        }
        let samples = installs.map(\.ms)
        var notes = [String(format: "%d writes in %.1f s from another task; %d snapshot installs on the main actor",
                            writes, seconds, samples.count)]
        if let index = model.index(of: anchor) {
            let moved = abs(clip.bounds.origin.y - (CGFloat(index) * rowHeight + anchorOffset)) > 0.5
            notes.append(moved ? "the first visible row moved" : "the first visible row stayed put (new mail inserted above)")
            if moved { problems.append("update storm moved the first visible row") }
        }
        checkConsistency("update storm")
        return [
            PerfResult(name: "update storm: snapshot install (main)", samples: samples, budget: Budgets.stormInstall, notes: notes),
            PerfResult(name: "update storm: main busy per frame", samples: busy, budget: Budgets.frame),
        ]
    }


    private func smallWindowChange() async throws -> PerfResult {
        let small = ThreadListModel(data: store, location: .system(.inbox), account: AccountID(1))
        var samples: [Double] = []
        small.onInstall = { [weak self] _, duration in samples.append(Self.ms(duration)); _ = self }
        let list = ThreadListViewController(theme: .light)
        let smallWindow = NSWindow(contentRect: NSRect(x: -20_000, y: -19_000, width: 1280, height: 800),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        smallWindow.isReleasedWhenClosed = false
        smallWindow.contentView = list.view
        smallWindow.orderFrontRegardless()
        defer { smallWindow.close() }
        list.model = small
        small.start()
        try await until(seconds: 30) { small.rows.count == 100 }
        small.visibleRangeDidChange(70..<80)
        try await until(seconds: 30) { small.rows.count == 300 }
        samples.removeAll()
        for i in 0..<options.smallWindowChanges {
            let key = small.rows[10].id
            let before = samples.count
            _ = try await store.apply(i % 2 == 0 ? .markRead([key]) : .markUnread([key]))
            try await until(seconds: 10) { samples.count > before }
        }
        return PerfResult(name: "snapshot install, 300-row window, 1 change", samples: samples, budget: Budgets.smallApply)
    }

    private func densityChanges() -> PerfResult {
        var samples: [Double] = []
        var compact = ThemeTokens.light
        compact.density = .compact
        for i in 0..<options.densityChanges {
            let start = clock.now
            controller.apply(theme: i % 2 == 0 ? compact : .light)
            layoutAndDraw()
            samples.append(Self.ms(clock.now - start))
        }
        controller.apply(theme: .light)
        return PerfResult(name: "density change, re-laid out and drawn", samples: samples, budget: Budgets.density)
    }

    private func checkConsistency(_ scenario: String) {
        layoutAndDraw()
        if table.numberOfRows != model.displayCount {
            problems.append("\(scenario): table has \(table.numberOfRows) rows, model \(model.displayCount)")
        }
        let format = ThreadRowFormatting()
        for index in controller.visibleRowRange where index < model.rows.count {
            guard let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ThreadRowView else { continue }
            let row = model.rows[index]
            if cell.isPlaceholder || cell.accessibilityLabel()?.contains(format.sender(row).name) != true {
                problems.append("\(scenario): row \(index) shows something else than the model")
                return
            }
        }
    }
}

final class DoneFlag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
