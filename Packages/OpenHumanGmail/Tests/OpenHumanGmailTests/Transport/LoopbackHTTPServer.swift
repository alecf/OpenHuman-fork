#if canImport(Network)
import Compression
import Foundation
import Network
import Synchronization

struct LoopbackRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

enum LoopbackReply: Sendable {
    case response(status: Int, headers: [String: String] = [:], body: Data = Data())
    case hang
    case close
    case trickle(interval: Double)
}

final class LoopbackHTTPServer: Sendable {
    typealias Handler = @Sendable (LoopbackRequest) async -> LoopbackReply
    private struct State {
        var port: UInt16 = 0
        var connections = 0
        var requests: [LoopbackRequest] = []
        var live: [NWConnection] = []
        var tasks: [Task<Void, Never>] = []
    }
    private let listener: NWListener
    private let state = Mutex(State())
    private let handler: Handler

    private init(handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        self.handler = handler
    }

    static func start(_ handler: @escaping Handler) async throws -> LoopbackHTTPServer {
        let server = try LoopbackHTTPServer(handler: handler)
        let ready = AsyncStream<UInt16?>.makeStream()
        server.listener.stateUpdateHandler = { [listener = server.listener] state in
            switch state {
            case .ready: ready.continuation.yield(listener.port?.rawValue)
            case .failed: ready.continuation.yield(nil)
            default: break
            }
        }
        server.listener.newConnectionHandler = { [server] connection in server.accept(connection) }
        server.listener.start(queue: .global())
        for await port in ready.stream {
            guard let port else { throw URLError(.cannotConnectToHost) }
            server.state.withLock { $0.port = port }
            return server
        }
        throw URLError(.cannotConnectToHost)
    }

    var port: UInt16 { state.withLock { $0.port } }
    var url: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var connectionCount: Int { state.withLock { $0.connections } }
    var requests: [LoopbackRequest] { state.withLock { $0.requests } }

    func stop() {
        listener.cancel()
        let (live, tasks) = state.withLock { s -> ([NWConnection], [Task<Void, Never>]) in
            defer { s.live = []; s.tasks = [] }
            return (s.live, s.tasks)
        }
        for task in tasks { task.cancel() }
        for connection in live { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let task = Task { await self.serve(connection) }
        state.withLock { $0.connections += 1; $0.live.append(connection); $0.tasks.append(task) }
        connection.start(queue: .global())
    }

    private func serve(_ connection: NWConnection) async {
        var buffer = Data()
        while !Task.isCancelled {
            guard let request = await readRequest(connection, &buffer) else { break }
            state.withLock { $0.requests.append(request) }
            switch await handler(request) {
            case .response(let status, let headers, let body):
                var head = "HTTP/1.1 \(status) X\r\nContent-Length: \(body.count)\r\n"
                for (name, value) in headers { head += "\(name): \(value)\r\n" }
                await write(connection, Data((head + "\r\n").utf8) + body)
            case .hang:
                try? await Task.sleep(for: .seconds(3600))
                connection.cancel()
                return
            case .close:
                connection.cancel()
                return
            case .trickle(let interval):
                await write(connection, Data("HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n".utf8))
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    await write(connection, Data("x".utf8))
                }
                return
            }
        }
        connection.cancel()
    }

    private func readRequest(_ connection: NWConnection, _ buffer: inout Data) async -> LoopbackRequest? {
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.range(of: terminator) == nil {
            guard let more = await receive(connection) else { return nil }
            buffer.append(more)
        }
        let headEnd = buffer.range(of: terminator)!
        let lines = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ").map(String.init)
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        var body = Data(buffer[headEnd.upperBound...])
        while body.count < length {
            guard let more = await receive(connection) else { return nil }
            body.append(more)
        }
        buffer = Data(body.dropFirst(length))
        return LoopbackRequest(method: first[0], path: first[1], headers: headers, body: Data(body.prefix(length)))
    }

    private func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                continuation.resume(returning: data?.isEmpty == false ? data : nil)
            }
        }
    }

    private func write(_ connection: NWConnection, _ data: Data) async {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }
}

func gzipped(_ data: Data) -> Data {
    var crcTable = [UInt32](repeating: 0, count: 256)
    for n in 0..<256 {
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        crcTable[n] = c
    }
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    crc ^= 0xFFFF_FFFF
    let deflated = (try? (data as NSData).compressed(using: .zlib) as Data) ?? Data()
    var out = Data([0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0xFF])
    out.append(deflated)
    for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8((crc >> UInt32(shift)) & 0xFF)) }
    let size = UInt32(truncatingIfNeeded: data.count)
    for shift in stride(from: 0, to: 32, by: 8) { out.append(UInt8((size >> UInt32(shift)) & 0xFF)) }
    return out
}
#endif
