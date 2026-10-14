import CryptoKit
import Foundation
import Testing

@testable import OpenHumanAIModelStore

final class FakeTransport: DownloadTransport, @unchecked Sendable {
    enum Behaviour: Sendable {
        case normal
        case dropAfter(Int64)
        case hang
    }

    private let lock = NSLock()
    private var bodies: [URL: Data] = [:]
    private var behaviours: [URL: Behaviour] = [:]
    private(set) var requests: [(url: URL, offset: Int64)] = []

    func serve(_ url: URL, _ body: Data, _ behaviour: Behaviour = .normal) {
        lock.withLock {
            bodies[url] = body
            behaviours[url] = behaviour
        }
    }

    func setBehaviour(_ url: URL, _ behaviour: Behaviour) { lock.withLock { behaviours[url] = behaviour } }

    var requestLog: [(url: URL, offset: Int64)] { lock.withLock { requests } }

    func fetch(
        url: URL, to destination: URL, resumeFrom offset: Int64, maxBytes: Int64, progress: @Sendable (Int64) -> Void
    ) async throws {
        let (body, behaviour) = lock.withLock { () -> (Data, Behaviour) in
            requests.append((url, offset))
            return (bodies[url] ?? Data(), behaviours[url] ?? .normal)
        }
        if case .hang = behaviour {
            while true {
                try await Task.sleep(for: .seconds(60))
            }
        }
        guard Int64(body.count) <= maxBytes else { throw ModelStoreError.tooLarge(bytes: Int64(body.count), cap: maxBytes) }
        if !FileManager.default.fileExists(atPath: destination.path) { FileManager.default.createFile(atPath: destination.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(offset))
        try handle.seek(toOffset: UInt64(offset))
        var end = Int64(body.count)
        if case .dropAfter(let limit) = behaviour { end = min(end, limit) }
        let chunk = 4
        var position = offset
        while position < end {
            let next = min(end, position + Int64(chunk))
            try handle.write(contentsOf: body[Int(position)..<Int(next)])
            position = next
            progress(position)
            try Task.checkCancellation()
        }
        if case .dropAfter = behaviour, end < Int64(body.count) { throw ModelStoreError.transport("connection dropped") }
    }
}

func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

struct Fixture {
    let manifest: ModelManifest
    let transport: FakeTransport
    let bodies: [String: Data]

    static func make(files: [String: String] = ["config.json": "{\"hidden\":64}", "weights/model.safetensors": "0123456789abcdefghij"]) -> Fixture {
        let transport = FakeTransport()
        var list: [ModelManifest.File] = []
        var bodies: [String: Data] = [:]
        for (path, text) in files.sorted(by: { $0.key < $1.key }) {
            let data = Data(text.utf8)
            let url = URL(string: "https://models.example.test/m/\(path)")!
            transport.serve(url, data)
            list.append(.init(path: path, url: url, sizeBytes: Int64(data.count), sha256: sha256(data)))
            bodies[path] = data
        }
        let manifest = ModelManifest(
            id: "test-model-1b", displayName: "Test model 1B", sourceURL: URL(string: "https://models.example.test/m")!,
            revision: "0123abcd", files: list, license: "test-license", format: .mlx, declaredContextTokens: 8192)
        return Fixture(manifest: manifest, transport: transport, bodies: bodies)
    }
}

func makeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("model-store-\(UUID().uuidString)", isDirectory: true)
}

func finalState(_ stream: AsyncStream<DownloadState>) async -> DownloadState {
    var last: DownloadState = .idle
    for await state in stream { last = state }
    return last
}

@Suite struct ModelStoreTests {
    @Test func downloadsVerifiesAndMarksReady() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture.make()
        let store = ModelStore(rootDirectory: root, transport: fixture.transport, freeSpace: { _ in 100 << 30 })

        var seen: [DownloadState] = []
        for await state in await store.download(fixture.manifest, confirmedSizeBytes: fixture.manifest.totalBytes) { seen.append(state) }
        guard case .ready(let directory)? = seen.last else {
            Issue.record("not ready: \(String(describing: seen.last))")
            return
        }
        #expect(seen.contains { if case .verifying = $0 { return true } else { return false } })
        #expect(seen.contains { if case .downloading = $0 { return true } else { return false } })
        #expect(directory.path.hasSuffix("test-model-1b/0123abcd"))
        for (path, body) in fixture.bodies {
            #expect(try Data(contentsOf: directory.appendingPathComponent(path)) == body)
        }
        #expect(await store.installedDirectory(for: fixture.manifest) == directory)
        #expect(await store.verifyInstalled(fixture.manifest))
        #expect(await store.state(for: fixture.manifest) == .ready(directory))
        let leftovers = FileManager.default.enumerator(atPath: root.path)?.allObjects.compactMap { $0 as? String }.filter { $0.hasSuffix(".partial") }
        #expect(leftovers?.isEmpty == true)
    }

    @Test func aSecondDownloadOfAnInstalledModelDoesNotFetchAgain() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture.make()
        let store = ModelStore(rootDirectory: root, transport: fixture.transport, freeSpace: { _ in 100 << 30 })
        _ = await finalState(await store.download(fixture.manifest, confirmedSizeBytes: fixture.manifest.totalBytes))
        let count = fixture.transport.requestLog.count
        let again = await finalState(await store.download(fixture.manifest, confirmedSizeBytes: fixture.manifest.totalBytes))
        guard case .ready = again else { Issue.record("not ready"); return }
        #expect(fixture.transport.requestLog.count == count)
    }

    @Test func aWrongHashFailsAndKeepsTheModelNotInstalled() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture.make()
        let file = fixture.manifest.files[1]
        fixture.transport.serve(file.url, Data(repeating: 0x41, count: Int(file.sizeBytes)))
        let store = ModelStore(rootDirectory: root, transport: fixture.transport, freeSpace: { _ in 100 << 30 })
        let state = await finalState(await store.download(fixture.manifest, confirmedSizeBytes: fixture.manifest.totalBytes))
        #expect(state == .failed(.checksumMismatch(file: file.path)))
        #expect(await store.installedDirectory(for: fixture.manifest) == nil)
        let partial = await store.modelDirectory(for: fixture.manifest).appendingPathComponent(file.path + ".partial")
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func aShortBodyIsASizeMismatch() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture.make()
        let file = fixture.manifest.files[0]
        fixture.transport.serve(file.url, Data(fixture.bodies[file.path]!.dropLast(2)))
        let store = ModelStore(rootDirectory: root, transport: fixture.transport, freeSpace: { _ in 100 << 30 })
        let state = await finalState(await store.download(fixture.manifest, confirmedSizeBytes: fixture.manifest.totalBytes))
        #expect(state == .failed(.sizeMismatch(file: file.path)))
    }

    @Test func aBodyLargerThanDeclaredIsRejected() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture.make()
        let file = fixture.manifest.files[0]
        fixture.transport.serve(file.url, Data(repeating: 0x42, count: Int(file.sizeBytes) + 50))
        let store = ModelStore(rootDirectory: root, transport: fixture.transport, freeSpace: { _ in 100 << 30 })
        let state = await finalState(await store.download(fixture.manifest, confirmedSizeBytes: fixture.manifest.totalBytes))
        guard case .failed(.tooLarge) = state else { Issue.record("got \(state)"); return }
    }

    @Test func aDroppedConnectionResumesFromThePartialFile() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture.make()
        let weights = fixture.manifest.files[1]
        fixture.transport.setBehaviour(weights.url, .dropAfter(8))
        let store = ModelStore(rootDirectory: root, transport: fixture.transport, freeSpace: { _ in 100 << 30 })
        let first = await finalState(await store.download(fixture.manifest, confirmedSizeBytes: fixture.manifest.totalBytes))
        guard case .failed(.transport) = first else { Issue.record("got \(first)"); return }
        #expect(await store.remainingBytes(for: fixture.manifest) == weights.sizeBytes - 8)

        fixture.transport.setBehaviour(weights.url, .normal)
        let second = await finalState(await store.download(fixture.manifest, confirmedSizeBytes: fixture.manifest.totalBytes))
        guard case .ready = second else { Issue.record("got \(second)"); return }
        let resumed = fixture.transport.requestLog.last { $0.url == weights.url }
        #expect(resumed?.offset == 8)
        #expect(await store.verifyInstalled(fixture.manifest))
    }

    @Test func notEnoughDiskSpaceFailsBeforeAnyDownload() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture.make()
        let store = ModelStore(rootDirectory: root, transport: fixture.transport, freeSpace: { _ in 10 }, reserveBytes: 0)
        let state = await finalState(await store.download(fixture.manifest, confirmedSizeBytes: fixture.manifest.totalBytes))
        #expect(state == .failed(.insufficientDiskSpace(needed: fixture.manifest.totalBytes, available: 10)))
        #expect(fixture.transport.requestLog.isEmpty)
    }

    @Test func theReserveCountsAsNeededSpace() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture.make()
        let total = fixture.manifest.totalBytes
        let store = ModelStore(rootDirectory: root, transport: fixture.transport, freeSpace: { _ in total + 99 }, reserveBytes: 100)
        let state = await finalState(await store.download(fixture.manifest, confirmedSizeBytes: total))
        #expect(state == .failed(.insufficientDiskSpace(needed: total + 100, available: total + 99)))
    }

    @Test func theSizeCapIsEnforced() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture.make()
        let store = ModelStore(
            rootDirectory: root, transport: fixture.transport, freeSpace: { _ in 100 << 30 }, maxModelBytes: 10)
        let state = await finalState(await store.download(fixture.manifest, confirmedSizeBytes: fixture.manifest.totalBytes))
        #expect(state == .failed(.tooLarge(bytes: fixture.manifest.totalBytes, cap: 10)))
        #expect(fixture.transport.requestLog.isEmpty)
    }

    @Test func nothingDownloadsWithoutTheConfirmedSize() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture.make()
        let store = ModelStore(rootDirectory: root, transport: fixture.transport, freeSpace: { _ in 100 << 30 })
        let state = await finalState(await store.download(fixture.manifest, confirmedSizeBytes: 0))
        #expect(state == .failed(.sizeNotConfirmed(expected: fixture.manifest.totalBytes, confirmed: 0)))
        #expect(fixture.transport.requestLog.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func cancelStopsTheDownloadAndKeepsPartialFiles() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture.make()
        fixture.transport.setBehaviour(fixture.manifest.files[0].url, .hang)
        let store = ModelStore(rootDirectory: root, transport: fixture.transport, freeSpace: { _ in 100 << 30 })
        let stream = await store.download(fixture.manifest, confirmedSizeBytes: fixture.manifest.totalBytes)
        for _ in 0..<500 where fixture.transport.requestLog.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!fixture.transport.requestLog.isEmpty)
        await store.cancel(fixture.manifest)
        #expect(await finalState(stream) == .cancelled)
        #expect(await store.installedDirectory(for: fixture.manifest) == nil)
        fixture.transport.setBehaviour(fixture.manifest.files[0].url, .normal)
        let again = await finalState(await store.download(fixture.manifest, confirmedSizeBytes: fixture.manifest.totalBytes))
        guard case .ready = again else { Issue.record("got \(again)"); return }
    }

    @Test func deleteRemovesTheModelAndItsPartialFiles() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture.make()
        let store = ModelStore(rootDirectory: root, transport: fixture.transport, freeSpace: { _ in 100 << 30 })
        _ = await finalState(await store.download(fixture.manifest, confirmedSizeBytes: fixture.manifest.totalBytes))
        try await store.delete(fixture.manifest)
        #expect(await store.installedDirectory(for: fixture.manifest) == nil)
        #expect(await store.state(for: fixture.manifest) == .idle)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("test-model-1b").path))
    }

    @Test func aTamperedInstalledFileIsDetected() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture.make()
        let store = ModelStore(rootDirectory: root, transport: fixture.transport, freeSpace: { _ in 100 << 30 })
        guard case .ready(let directory) = await finalState(await store.download(fixture.manifest, confirmedSizeBytes: fixture.manifest.totalBytes))
        else { Issue.record("not ready"); return }
        let weights = directory.appendingPathComponent("weights/model.safetensors")
        try Data(repeating: 0x7A, count: Int(fixture.manifest.files[1].sizeBytes)).write(to: weights)
        #expect(await store.installedDirectory(for: fixture.manifest) != nil)
        #expect(await store.verifyInstalled(fixture.manifest) == false)
    }

    @Test func updatesStreamReportsTheCurrentState() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture.make()
        let store = ModelStore(rootDirectory: root, transport: fixture.transport, freeSpace: { _ in 100 << 30 })
        var first: DownloadState?
        for await state in await store.updates(for: fixture.manifest) {
            first = state
            break
        }
        #expect(first == .idle)
    }
}

@Suite struct ModelManifestTests {
    private func manifest(id: String = "ok-model", revision: String = "abc123", path: String = "a.bin", url: String = "https://x.test/a",
                          size: Int64 = 4, sha: String = String(repeating: "a", count: 64)) -> ModelManifest {
        ModelManifest(
            id: id, displayName: "n", sourceURL: URL(string: "https://x.test")!, revision: revision,
            files: [.init(path: path, url: URL(string: url)!, sizeBytes: size, sha256: sha)], license: "l", format: .mlx)
    }

    @Test func validManifestPasses() throws { try manifest().validate() }

    @Test func unsafeIdentifiersPathsAndURLsAreRejected() {
        let bad: [ModelManifest] = [
            manifest(id: "../escape"), manifest(id: ""), manifest(id: ".hidden"), manifest(id: "a/b"),
            manifest(revision: "main/../x"), manifest(path: "../../etc/passwd"), manifest(path: "/etc/passwd"),
            manifest(path: "a//b"), manifest(path: "a/./b"), manifest(path: "x.partial"),
            manifest(path: ModelStore.readyMarkerName), manifest(url: "http://x.test/a"), manifest(url: "file:///etc/passwd"),
            manifest(size: 0), manifest(sha: "xyz"),
        ]
        for item in bad {
            #expect(throws: ModelStoreError.self, "accepted \(item.id) \(item.files[0].path) \(item.files[0].url)") { try item.validate() }
        }
    }

    @Test func manifestRoundTripsThroughJSON() throws {
        let original = manifest()
        let decoded = try JSONDecoder().decode(ModelManifest.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(original.totalBytes == 4)
    }
}
