import Foundation
import OpenHumanCore

struct BatchCallItem: Sendable {
    var url: URL
    var resource: String
}

extension RequestExecutor {
    func executeBatch(method: GmailMethod, items: [BatchCallItem],
                      priority: RequestPriority) async throws -> [Result<HTTPResponse, GmailError>] {
        guard !items.isEmpty else { return [] }
        let policy = priority == .interactive ? config.retryInteractive : config.retryBackground
        let cost = QuotaCost.units(method)
        let started = clock.now
        var results = [Result<HTTPResponse, GmailError>?](repeating: nil, count: items.count)
        var attempts = [Int](repeating: 0, count: items.count)
        var unitsSpent = [Int](repeating: 0, count: items.count)
        var pending = Array(items.indices)
        var policyAttempts = 0
        var forceRefresh = false
        var refreshUsed = false

        func finalize(_ index: Int, _ result: Result<HTTPResponse, GmailError>, status: Int?) {
            results[index] = result
            let ms = Int((clock.now.timeIntervalSince(started) * 1000).rounded())
            metrics?.record(GmailCallMetric(method: method.rawValue, units: unitsSpent[index], status: status,
                                            attempts: max(attempts[index], 1), durationMs: max(0, ms)))
        }
        func abort(_ error: GmailError, status: Int?) -> GmailError {
            for index in pending where results[index] == nil { finalize(index, .failure(error), status: status) }
            return error
        }

        while true {
            if Task.isCancelled { throw abort(.cancelled, status: nil) }
            policyAttempts += 1
            for index in pending { attempts[index] += 1 }

            let boundary = BatchCodec.makeBoundary()
            let parts = pending.enumerated().map { BatchPartRequest(contentID: "item-\($0.offset)",
                                                                    target: BatchCodec.target(for: items[$0.element].url)) }
            let call = GmailCall(method: method, httpMethod: "POST", url: BatchCodec.endpoint,
                                 body: BatchCodec.body(parts: parts, boundary: boundary),
                                 contentType: BatchCodec.contentType(boundary: boundary), priority: priority,
                                 accept: "multipart/mixed", resource: "batch")
            let result = await attempt(call, cost: cost * pending.count, forceRefresh: forceRefresh)
            forceRefresh = false
            if result.units > 0 { for index in pending { unitsSpent[index] += cost } }

            var failures: [(index: Int, error: GmailError, status: Int?)] = []
            var outerFailure = false
            switch result.outcome {
            case .failure(let error):
                outerFailure = true
                for index in pending { failures.append((index, error, result.status)) }
            case .success(let response):
                let (done, bad) = Self.split(response, pending: pending, items: items, now: clock.now)
                for (index, inner) in done { finalize(index, .success(inner), status: inner.status) }
                failures = bad
            }
            if failures.isEmpty { return results.map { $0! } }

            var retry: [Int] = []
            var maxRetryAfter: Duration?
            var refreshing = false
            for failure in failures {
                var tooLong = false
                if case .rateLimited(let after) = failure.error {
                    await limiter.noteRateLimited(retryAfter: after)
                    if let after {
                        tooLong = after > policy.maxRetryAfter
                        maxRetryAfter = max(maxRetryAfter ?? after, after)
                    }
                }
                if failure.error == .unauthorized, failure.status == 401, !refreshUsed {
                    refreshing = true
                    retry.append(failure.index)
                } else if !tooLong, policyAttempts < policy.maxAttempts,
                          RetryRules.isRetryable(failure.error, idempotent: method.isIdempotent) {
                    retry.append(failure.index)
                }
            }
            let retrySet = Set(retry)
            if outerFailure, retry.isEmpty, let first = failures.first {
                throw abort(first.error, status: first.status)
            }
            for failure in failures where !retrySet.contains(failure.index) {
                finalize(failure.index, .failure(failure.error), status: failure.status)
            }
            if retry.isEmpty { return results.map { $0! } }
            pending = retry.sorted()
            if refreshing {
                refreshUsed = true
                forceRefresh = true
                policyAttempts -= 1
                continue
            }
            let wait = policy.delay(beforeRetry: policyAttempts, retryAfter: maxRetryAfter, jitter: jitter())
            let why = BatchRetryReason.summary(failures.filter { retrySet.contains($0.index) }.map { (error: $0.error, status: $0.status) },
                                               wholeBatch: outerFailure)
            Log(.gmail).info("\(method.rawValue) batch retrying \(pending.count) of \(items.count) items: \(why); "
                             + "attempt \(policyAttempts + 1) in \(BatchRetryReason.seconds(wait))")
            do {
                try await clock.sleep(for: wait)
            } catch {
                throw abort(.cancelled, status: nil)
            }
        }
    }

    private static func split(_ response: HTTPResponse, pending: [Int], items: [BatchCallItem], now: Date)
        -> (done: [(Int, HTTPResponse)], failures: [(index: Int, error: GmailError, status: Int?)]) {
        let parts = BatchCodec.parse(contentType: response.headers["content-type"], body: response.body)
        var byID: [String: BatchPartResponse] = [:]
        var ordered: [BatchPartResponse] = []
        for part in parts ?? [] {
            ordered.append(part)
            if let id = part.contentID { byID[id] = part }
        }
        let positional = byID.isEmpty && ordered.count == pending.count
        var done: [(Int, HTTPResponse)] = []
        var failures: [(index: Int, error: GmailError, status: Int?)] = []
        for (position, index) in pending.enumerated() {
            let part = byID["item-\(position)"] ?? (positional ? ordered[position] : nil)
            guard let part else {
                failures.append((index, .transport(.connectionLost(requestMayHaveBeenSent: true)), nil))
                continue
            }
            if (200..<300).contains(part.status) {
                done.append((index, HTTPResponse(status: part.status, headers: part.headers, body: part.body)))
            } else {
                let error = GmailErrorMapping.error(status: part.status, headers: part.headers, body: part.body,
                                                    resource: items[index].resource, now: now)
                failures.append((index, error, part.status))
            }
        }
        return (done, failures)
    }
}

enum BatchRetryReason: String, CaseIterable, Comparable {
    case rateLimit = "rate limit"
    case server
    case transport
    case missingPart = "missing part"
    case auth
    case other

    static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    static func classify(_ error: GmailError, status: Int?) -> BatchRetryReason {
        switch error {
        case .rateLimited: return .rateLimit
        case .server: return .server
        case .unauthorized: return .auth
        case .transport(.connectionLost) where status == nil: return .missingPart
        case .transport: return .transport
        default: return .other
        }
    }

    static func summary(_ failures: [(error: GmailError, status: Int?)], wholeBatch: Bool) -> String {
        var counts: [BatchRetryReason: Int] = [:]
        var statuses: [BatchRetryReason: [Int: Int]] = [:]
        for failure in failures {
            var reason = classify(failure.error, status: failure.status)
            if wholeBatch, reason == .missingPart { reason = .transport }
            counts[reason, default: 0] += 1
            if let status = failure.status { statuses[reason, default: [:]][status, default: 0] += 1 }
        }
        let parts = counts.keys.sorted().map { reason -> String in
            let codes = (statuses[reason] ?? [:]).sorted { $0.key < $1.key }
                .map { $0.value > 1 ? "\($0.key) x\($0.value)" : "\($0.key)" }
            return "\(reason.rawValue) \(counts[reason]!)" + (codes.isEmpty ? "" : " (\(codes.joined(separator: ", ")))")
        }
        return (parts.isEmpty ? "unknown" : parts.joined(separator: ", ")) + (wholeBatch ? ", whole batch" : "")
    }

    static func seconds(_ duration: Duration) -> String {
        String(format: "%.1f s", duration.timeInterval)
    }
}
