import Foundation
import GRDB
import OpenHumanCore
import Synchronization

enum ObservationRegistry {
    private static let counts = Mutex<[String: Int]>([:])

    static func opened(_ id: String) { counts.withLock { $0[id, default: 0] += 1 } }
    static func closed(_ id: String) {
        counts.withLock { counts in
            let n = (counts[id] ?? 1) - 1
            counts[id] = n > 0 ? n : nil
        }
    }
    static func active(_ id: String) -> Int { counts.withLock { $0[id] ?? 0 } }
}

extension MailStore {
    func pulseTracked<V: Sendable>(_ fetch: @escaping @Sendable (Database) throws -> V) -> @Sendable (Database) throws -> V {
        { db in
            _ = try Int.fetchOne(db, sql: "SELECT seq FROM observation_pulse WHERE id = 1")
            return try fetch(db)
        }
    }

    func observe<V: Sendable & Equatable>(_ fetch: @escaping @Sendable (Database) throws -> V) -> StoreObservation<V> {
        let writer = self.writer
        let id = writerID
        let tracked = pulseTracked(fetch)
        return StoreObservation<V>(
            values: {
                AsyncThrowingStream<V, Error>(V.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
                    ObservationRegistry.opened(id)
                    let task = Task {
                        do {
                            let observation = ValueObservation.tracking(tracked).removeDuplicates()
                            for try await value in observation.values(in: writer, bufferingPolicy: .bufferingNewest(1)) {
                                continuation.yield(value)
                            }
                            continuation.finish()
                        } catch is CancellationError {
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: MailStore.mapError(error))
                        }
                    }
                    continuation.onTermination = { _ in
                        task.cancel()
                        ObservationRegistry.closed(id)
                    }
                }
            },
            current: { do { return try writer.read(tracked) } catch { throw MailStore.mapError(error) } })
    }
}
