import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization

struct HTTPRequest: Sendable {
    let method: String
    let path: [String]
    let query: [String: String]
    let headers: [String: String]
    let body: [UInt8]

    init(method: String, target: String, headers: [String: String], body: [UInt8]) {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        self.method = method
        path = parts[0].split(separator: "/").map(String.init)
        query = parts.count > 1 ? Self.parse(query: parts[1]) : [:]
        self.headers = headers
        self.body = body
    }

    private static func parse(query: Substring) -> [String: String] {
        var values: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let field = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            values[field[0].formDecoded()] = field.count > 1 ? field[1].formDecoded() : ""
        }
        return values
    }
}

struct HTTPResponse: Sendable {
    let status: Int
    let contentType: String
    let body: [UInt8]

    static let noContent = HTTPResponse(status: 204, contentType: "text/plain", body: [])
}

final class HTTPServer: Sendable {
    private let host: String
    private let port: Int
    private let maximumBodyBytes: Int
    private let shutdown: Shutdown
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private let inFlight = Atomic<Int>(0)

    init(host: String, port: Int, maximumBodyBytes: Int, shutdown: Shutdown,
         handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.host = host
        self.port = port
        self.maximumBodyBytes = maximumBodyBytes
        self.shutdown = shutdown
        self.handler = handler
    }

    func run(alongside work: @escaping @Sendable () async throws -> Void) async throws {
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers(IdleStateHandler(readTimeout: .seconds(30)), CloseWhenIdle())
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: true)
                    return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(wrappingChannelSynchronously: channel)
                }
            }
        try await withThrowingDiscardingTaskGroup { group in
            group.addTask { [shutdown] in
                try await work()
                shutdown.startClosing()
                try await server.channel.close()
            }
            try await withThrowingDiscardingTaskGroup { connections in
                do {
                    try await server.executeThenClose { accepted in
                        for try await connection in accepted {
                            connections.addTask { [self] in try? await serve(connection) }
                        }
                    }
                } catch {
                    guard shutdown.isRequested else { throw error }
                }
                guard shutdown.isRequested else { throw ListenerClosed() }
                let deadline = ContinuousClock.now + Shutdown.drainLimit
                while inFlight.load(ordering: .acquiring) > 0, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                connections.cancelAll()
            }
        }
    }

    private func serve(_ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>) async throws {
        try await connection.executeThenClose { inbound, outbound in
            var head: HTTPRequestHead?
            var body: [UInt8] = []
            var tooLarge = false
            for try await part in inbound {
                switch part {
                case let .head(value):
                    head = value
                    body = []
                    tooLarge = false
                case let .body(chunk):
                    tooLarge = tooLarge || body.count + chunk.readableBytes > maximumBodyBytes
                    if !tooLarge { body += chunk.readableBytesView }
                case .end:
                    guard let head else { return }
                    inFlight.add(1, ordering: .acquiringAndReleasing)
                    defer { inFlight.subtract(1, ordering: .acquiringAndReleasing) }
                    let headers = Dictionary(head.headers.map { ($0.name.lowercased(), $0.value) }) { _, last in last }
                    let response = tooLarge
                        ? HTTPResponse(status: 413, contentType: "text/plain", body: Array("Request body too large".utf8))
                        : await handler(HTTPRequest(method: head.method.rawValue, target: head.uri, headers: headers, body: body))
                    var responseHeaders = HTTPHeaders([("content-type", response.contentType), ("content-length", String(response.body.count))])
                    let closes = !head.isKeepAlive || shutdown.isRequested
                    if closes { responseHeaders.add(name: "connection", value: "close") }
                    try await outbound.write(.head(HTTPResponseHead(version: head.version, status: .init(statusCode: response.status), headers: responseHeaders)))
                    try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: response.body))))
                    try await outbound.write(.end(nil))
                    if closes { return }
                }
            }
        }
    }
}

private struct ListenerClosed: Error, CustomStringConvertible {
    var description: String { "The HTTP listener closed unexpectedly." }
}

private final class CloseWhenIdle: ChannelInboundHandler {
    typealias InboundIn = NIOAny

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}

private extension Substring {
    func formDecoded() -> String {
        var bytes: [UInt8] = []
        var iterator = utf8.makeIterator()
        while let byte = iterator.next() {
            if byte == UInt8(ascii: "%"), let high = iterator.next(), let low = iterator.next(),
               let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16) {
                bytes.append(value)
            } else {
                bytes.append(byte == UInt8(ascii: "+") ? UInt8(ascii: " ") : byte)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
