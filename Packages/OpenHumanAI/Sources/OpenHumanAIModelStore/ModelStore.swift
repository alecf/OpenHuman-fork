import CryptoKit
import Foundation

public actor ModelStore {
    public static let readyMarkerName = ".openhuman-ready"
    public static let defaultMaxModelBytes: Int64 = 8 * 1024 * 1024 * 1024
    public static let defaultReserveBytes: Int64 = 1024 * 1024 * 1024

    public static var defaultRoot: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("OpenHuman/Models", isDirectory: true)
    }

    private let root: URL
    private let transport: any DownloadTransport
    private let freeSpace: @Sendable (URL) throws -> Int64
    private let maxModelBytes: Int64
    private let reserveBytes: Int64

    private var states: [String: DownloadState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var observers: [String: [UUID: AsyncStream<DownloadState>.Continuation]] = [:]

    public init(
        rootDirectory: URL = ModelStore.defaultRoot, transport: any DownloadTransport = URLSessionDownloadTransport(),
        freeSpace: @escaping @Sendable (URL) throws -> Int64 = ModelStore.systemFreeSpace,
        maxModelBytes: Int64 = ModelStore.defaultMaxModelBytes, reserveBytes: Int64 = ModelStore.defaultReserveBytes
    ) {
        self.root = rootDirectory
        self.transport = transport
        self.freeSpace = freeSpace
        self.maxModelBytes = maxModelBytes
        self.reserveBytes = reserveBytes
    }

    public static let systemFreeSpace: @Sendable (URL) throws -> Int64 = { url in
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    public func modelDirectory(for manifest: ModelManifest) -> URL {
        root.appendingPathComponent(manifest.id, isDirectory: true).appendingPathComponent(manifest.revision, isDirectory: true)
    }

    public func installedDirectory(for manifest: ModelManifest) -> URL? {
        let directory = modelDirectory(for: manifest)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.readyMarkerName)),
            let marker = try? JSONDecoder().decode(ModelManifest.self, from: data), marker == manifest
        else { return nil }
        for file in manifest.files {
            let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file.path).path))?[.size]
                as? Int64
            if size != file.sizeBytes { return nil }
        }
        return directory
    }

    public func verifyInstalled(_ manifest: ModelManifest) async -> Bool {
        guard let directory = installedDirectory(for: manifest) else { return false }
        for file in manifest.files {
            guard let digest = try? Self.sha256Hex(of: directory.appendingPathComponent(file.path)), digest == file.sha256 else {
                return false
            }
        }
        return true
    }

    public func state(for manifest: ModelManifest) -> DownloadState {
        if let state = states[manifest.id] { return state }
        if let directory = installedDirectory(for: manifest) { return .ready(directory) }
        return .idle
    }

    public func remainingBytes(for manifest: ModelManifest) -> Int64 {
        if installedDirectory(for: manifest) != nil { return 0 }
        let directory = modelDirectory(for: manifest)
        return manifest.files.reduce(0) { total, file in
            let dest = directory.appendingPathComponent(file.path)
            let have = Self.size(of: dest) == file.sizeBytes ? file.sizeBytes : min(file.sizeBytes, Self.size(of: Self.partialURL(dest)))
            return total + (file.sizeBytes - have)
        }
    }

    public func updates(for manifest: ModelManifest) -> AsyncStream<DownloadState> {
        let id = manifest.id
        let current = state(for: manifest)
        return AsyncStream { continuation in
            continuation.yield(current)
            if current.isTerminal {
                continuation.finish()
                return
            }
            let token = UUID()
            observers[id, default: [:]][token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id: id, token: token) }
            }
        }
    }

    public func download(_ manifest: ModelManifest, confirmedSizeBytes: Int64) -> AsyncStream<DownloadState> {
        let id = manifest.id
        do {
            try manifest.validate()
            guard confirmedSizeBytes == manifest.totalBytes else {
                throw ModelStoreError.sizeNotConfirmed(expected: manifest.totalBytes, confirmed: confirmedSizeBytes)
            }
            guard manifest.totalBytes <= maxModelBytes else {
                throw ModelStoreError.tooLarge(bytes: manifest.totalBytes, cap: maxModelBytes)
            }
            if tasks[id] != nil { throw ModelStoreError.alreadyDownloading }
        } catch {
            let failure = (error as? ModelStoreError) ?? .transport("unknown")
            if failure != .alreadyDownloading { set(.failed(failure), for: id) }
            return AsyncStream { continuation in
                continuation.yield(.failed(failure))
                continuation.finish()
            }
        }
        if let directory = installedDirectory(for: manifest) {
            set(.ready(directory), for: id)
            return AsyncStream { continuation in
                continuation.yield(.ready(directory))
                continuation.finish()
            }
        }
        set(.downloading(DownloadProgress(bytesDone: 0, bytesTotal: manifest.totalBytes)), for: id)
        let stream = updates(for: manifest)
        tasks[id] = Task { [self] in
            let outcome = await perform(manifest)
            finish(id: id, outcome: outcome)
        }
        return stream
    }

    public func cancel(_ manifest: ModelManifest) { tasks[manifest.id]?.cancel() }

    public func delete(_ manifest: ModelManifest) async throws {
        if let task = tasks[manifest.id] {
            task.cancel()
            await task.value
        }
        let modelRoot = root.appendingPathComponent(manifest.id, isDirectory: true)
        if FileManager.default.fileExists(atPath: modelRoot.path) { try FileManager.default.removeItem(at: modelRoot) }
        set(.idle, for: manifest.id)
    }

    private func perform(_ manifest: ModelManifest) async -> DownloadState {
        let id = manifest.id
        let directory = modelDirectory(for: manifest)
        do {
            let needed = remainingBytes(for: manifest)
            let available = try freeSpace(root)
            guard available - needed >= reserveBytes else {
                throw ModelStoreError.insufficientDiskSpace(needed: needed + reserveBytes, available: available)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var doneBefore: Int64 = 0
            for file in manifest.files {
                try Task.checkCancellation()
                let destination = directory.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if Self.size(of: destination) == file.sizeBytes, (try? Self.sha256Hex(of: destination)) == file.sha256 {
                    doneBefore += file.sizeBytes
                    continue
                }
                try? FileManager.default.removeItem(at: destination)
                let partial = Self.partialURL(destination)
                var offset = Self.size(of: partial)
                if offset > file.sizeBytes {
                    try? FileManager.default.removeItem(at: partial)
                    offset = 0
                }
                if offset < file.sizeBytes {
                    let base = doneBefore
                    let total = manifest.totalBytes
                    do {
                        try await transport.fetch(
                            url: file.url, to: partial, resumeFrom: offset, maxBytes: file.sizeBytes
                        ) { written in
                            Task { await self.publishProgress(id: id, done: base + written, total: total) }
                        }
                    } catch let error as ModelStoreError {
                        if case .tooLarge = error { try? FileManager.default.removeItem(at: partial) }
                        throw error
                    }
                }
                guard Self.size(of: partial) == file.sizeBytes else {
                    try? FileManager.default.removeItem(at: partial)
                    throw ModelStoreError.sizeMismatch(file: file.path)
                }
                set(.verifying(file: file.path), for: id)
                let digest = try Self.sha256Hex(of: partial)
                guard digest == file.sha256 else {
                    try? FileManager.default.removeItem(at: partial)
                    throw ModelStoreError.checksumMismatch(file: file.path)
                }
                try FileManager.default.moveItem(at: partial, to: destination)
                doneBefore += file.sizeBytes
                set(.downloading(DownloadProgress(bytesDone: doneBefore, bytesTotal: manifest.totalBytes)), for: id)
            }
            let marker = try JSONEncoder().encode(manifest)
            try marker.write(to: directory.appendingPathComponent(Self.readyMarkerName), options: .atomic)
            return .ready(directory)
        } catch is CancellationError {
            return .cancelled
        } catch let error as ModelStoreError {
            return .failed(error)
        } catch let error as URLError where error.code == .cancelled {
            return .cancelled
        } catch {
            return .failed(.transport("\(type(of: error))"))
        }
    }

    private func publishProgress(id: String, done: Int64, total: Int64) {
        guard case .downloading = states[id] else { return }
        set(.downloading(DownloadProgress(bytesDone: min(done, total), bytesTotal: total)), for: id)
    }

    private func finish(id: String, outcome: DownloadState) {
        tasks[id] = nil
        set(outcome, for: id)
    }

    private func set(_ state: DownloadState, for id: String) {
        states[id] = state
        for continuation in observers[id]?.values.map({ $0 }) ?? [] {
            continuation.yield(state)
            if state.isTerminal { continuation.finish() }
        }
        if state.isTerminal { observers[id] = nil }
    }

    private func removeObserver(id: String, token: UUID) { observers[id]?[token] = nil }

    static func partialURL(_ destination: URL) -> URL { destination.appendingPathExtension("partial") }

    static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
