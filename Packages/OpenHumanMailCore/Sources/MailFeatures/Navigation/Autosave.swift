import Foundation
import MailModel
import Synchronization

@MainActor
public final class PersistDebouncer {
    public static let standardDelay: Duration = .milliseconds(300)
    public static let standardMaxDelay: Duration = .seconds(2)

    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let delay: Duration
    private let maxDelay: Duration
    private let sleep: Sleep
    private let action: @MainActor () -> Void
    private var quietTask: Task<Void, Never>?
    private var ceilingTask: Task<Void, Never>?

    public init(delay: Duration = standardDelay, maxDelay: Duration = standardMaxDelay,
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) }, action: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.maxDelay = maxDelay
        self.sleep = sleep
        self.action = action
    }

    isolated deinit { cancel() }

    public var isPending: Bool { quietTask != nil }

    public func schedule() {
        quietTask?.cancel()
        let delay = delay, sleep = sleep
        quietTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            self?.fire()
        }
        if ceilingTask == nil {
            let maxDelay = maxDelay
            ceilingTask = Task { [weak self] in
                do { try await sleep(maxDelay) } catch { return }
                self?.fire()
            }
        }
    }

    public func flush() {
        guard isPending else { return }
        fire()
    }

    public func cancel() {
        quietTask?.cancel()
        ceilingTask?.cancel()
        quietTask = nil
        ceilingTask = nil
    }

    private func fire() {
        guard isPending else { return }
        cancel()
        action()
    }
}

@MainActor
public protocol ReaderStateRestorable: AnyObject {
    var restorableThread: ThreadKey { get }
    func captureReaderPlace() -> ReaderPlace
    func restoreReaderPlace(_ place: ReaderPlace)
}

@MainActor
public final class TerminationSignalHandler {
    private var sources: [any DispatchSourceSignal] = []
    private let flush: @MainActor () -> Void
    private let terminate: @MainActor (Int32) -> Void

    public init(signals: [Int32] = [SIGTERM, SIGINT], flush: @escaping @MainActor () -> Void,
                terminate: @escaping @MainActor (Int32) -> Void = { exit($0) }) {
        self.flush = flush
        self.terminate = terminate
        for number in signals {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.flush()
                    self.terminate(0)
                }
            }
            source.resume()
            sources.append(source)
        }
    }

    isolated deinit {
        for source in sources { source.cancel() }
    }
}
