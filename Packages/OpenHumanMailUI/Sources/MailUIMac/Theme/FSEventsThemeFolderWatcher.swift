import CoreServices
import Foundation
import MailTheme
import Synchronization

public final class FSEventsThemeFolderWatcher: ThemeFolderWatching {
    public let url: URL
    public let debounce: Duration
    public static let defaultDebounce: Duration = .milliseconds(200)
    static let streamLatency: CFTimeInterval = 0.05

    public init(url: URL, debounce: Duration = FSEventsThemeFolderWatcher.defaultDebounce) {
        self.url = url
        self.debounce = debounce
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let session = FSEventsSession(path: url.resolvingSymlinksInPath().path, debounce: debounce, continuation: continuation)
        session.start()
        continuation.onTermination = { _ in session.stop() }
        return stream
    }
}

final class FSEventsSession: Sendable {
    private struct State {
        var stream: FSEventStreamRef?
        var generation = 0
    }

    private let path: String
    private let debounce: Duration
    private let continuation: AsyncStream<Void>.Continuation
    private let queue = DispatchQueue(label: "dev.openhuman.mail.theme-folder-watcher", qos: .userInitiated)
    private let state = Mutex(State())

    init(path: String, debounce: Duration, continuation: AsyncStream<Void>.Continuation) {
        self.path = path
        self.debounce = debounce
        self.continuation = continuation
    }

    func start() {
        let started = state.withLock { [self] state -> Bool in
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<FSEventsSession>.fromOpaque(info).takeUnretainedValue().eventsArrived()
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [path] as CFArray,
                                                   FSEventStreamEventId(kFSEventStreamEventIdSinceNow), FSEventsThemeFolderWatcher.streamLatency, flags) else { return false }
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            state.stream = stream
            return true
        }
        if !started { continuation.finish() }
    }

    private func eventsArrived() {
        let generation = state.withLock { state -> Int in
            state.generation += 1
            return state.generation
        }
        let nanoseconds = debounce.components.seconds * 1_000_000_000 + debounce.components.attoseconds / 1_000_000_000
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) { [self] in
            guard state.withLock({ $0.generation == generation && $0.stream != nil }) else { return }
            continuation.yield()
        }
    }

    func stop() {
        queue.async { [self] in
            state.withLock { state in
                guard let stream = state.stream else { return }
                state.stream = nil
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
        }
    }
}
