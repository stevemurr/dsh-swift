import DSHProtocol
import Foundation

/// Cookie credentials are used only for this exact origin. The token URL and
/// cookie never enter URLSession's shared cookie storage or disk cache.
public struct HostCredentials: Sendable {
    public let baseURL: URL
    public let cookie: String

    public init(baseURL: URL, cookie: String) {
        self.baseURL = baseURL
        self.cookie = cookie
    }

    public static func exchange(
        authenticatedURL: URL,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> HostCredentials {
        guard var components = URLComponents(url: authenticatedURL, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil, components.user == nil, components.password == nil else {
            throw TransportError.authentication("Use an HTTP or HTTPS DSH connection URL.")
        }
        let isolated = configuration.copy() as! URLSessionConfiguration
        isolated.httpCookieStorage = nil
        isolated.urlCache = nil
        isolated.httpShouldSetCookies = false
        isolated.requestCachePolicy = .reloadIgnoringLocalCacheData
        isolated.timeoutIntervalForRequest = 15
        isolated.timeoutIntervalForResource = 30
        isolated.httpAdditionalHeaders = nil
        let session = URLSession(configuration: isolated, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: authenticatedURL)
        request.httpShouldHandleCookies = false
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.authentication("DSH did not return an HTTP response.")
        }
        guard [301, 302, 303, 307, 308].contains(http.statusCode),
              let header = http.value(forHTTPHeaderField: "Set-Cookie"),
              let cookie = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: authenticatedURL).first,
              !cookie.name.isEmpty, !cookie.value.isEmpty,
              !cookie.name.contains(where: { $0.isNewline }), !cookie.value.contains(where: { $0.isNewline }) else {
            throw TransportError.authentication("DSH rejected the connection URL. Obtain a fresh authenticated URL.")
        }
        components.query = nil
        components.fragment = nil
        components.path = "/"
        guard let baseURL = components.url else {
            throw TransportError.authentication("The DSH server address is invalid.")
        }
        return HostCredentials(baseURL: baseURL, cookie: "\(cookie.name)=\(cookie.value)")
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}

/// Authenticated HTTP RPCs and multiplexed WebSocket streams. Disconnect is
/// explicit; reconnecting a failed socket only happens when a new stream opens.
public final class LoopbackTransport: DSHTransport, @unchecked Sendable {
    public let credentials: HostCredentials
    private let session: URLSession
    private let mux: MuxSocket
    private let recorder: (any FrameRecorder)?
    private let lifecycle = TransportLifecycle()

    public convenience init(credentials: HostCredentials, recorder: (any FrameRecorder)? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        self.init(credentials: credentials, session: session, recorder: recorder) { request in
            URLSessionMuxWebSocket(session.webSocketTask(with: request))
        }
    }

    init(
        credentials: HostCredentials, session: URLSession, recorder: (any FrameRecorder)? = nil,
        socketFactory: @escaping @Sendable (URLRequest) -> any MuxWebSocket
    ) {
        self.credentials = credentials
        self.session = session
        self.recorder = recorder
        mux = MuxSocket(credentials: credentials, recorder: recorder, socketFactory: socketFactory)
    }

    deinit { session.invalidateAndCancel() }

    public func call(_ endpoint: String, args: RemoteArgs) async throws -> JSONValue? {
        try await lifecycle.check()
        guard !endpoint.isEmpty, !endpoint.contains(where: { "?#\\".contains($0) }),
              endpoint.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw TransportError.invalidRequest
        }
        let body = try JSONEncoder().encode(ClientRequest(method: endpoint, args: args))
        var request = URLRequest(url: credentials.baseURL.appending(path: "api/\(endpoint)"))
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.cookie, forHTTPHeaderField: "Cookie")
        request.httpBody = body
        await recorder?.record(direction: .send, channel: "rpc:\(endpoint)", text: String(decoding: body, as: UTF8.self))
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.disconnected("DSH did not return an HTTP response.")
        }
        let text = String(decoding: data, as: UTF8.self)
        await recorder?.record(direction: .receive, channel: "rpc:\(endpoint)", text: text)
        guard http.statusCode == 200 else { throw TransportError.http(status: http.statusCode, body: "") }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard contentType.lowercased().hasPrefix("application/json") else {
            throw TransportError.unsupportedResponse(contentType: contentType)
        }
        switch try JSONDecoder().decode(ServerResponse.self, from: data).result {
        case .ok(let value): return value
        case .failure(let error): throw error
        }
    }

    public func stream(_ endpoint: String, args: RemoteArgs) async throws -> AsyncThrowingStream<JSONValue, any Error> {
        try await lifecycle.check()
        return try await mux.open(endpoint: endpoint, args: args)
    }

    public func disconnect() async {
        await lifecycle.close()
        await mux.close()
        session.invalidateAndCancel()
    }
}

private actor TransportLifecycle {
    private var closed = false
    func check() throws { if closed { throw TransportError.disconnected("The DSH connection was closed.") } }
    func close() { closed = true }
}

/// Small seam for exercising multiplex cleanup without opening a real socket.
protocol MuxWebSocket: Sendable {
    func resume()
    func cancel()
    func send(_ text: String) async throws
    func receive() async throws -> String
}

private final class URLSessionMuxWebSocket: MuxWebSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    init(_ task: URLSessionWebSocketTask) { self.task = task }
    func resume() { task.resume() }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
    func send(_ text: String) async throws { try await task.send(.string(text)) }
    func receive() async throws -> String {
        let message = try await task.receive()
        switch message {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: throw TransportError.disconnected("DSH sent an unsupported socket message.")
        }
    }
}

actor MuxSocket {
    private let credentials: HostCredentials
    private let recorder: (any FrameRecorder)?
    private let socketFactory: @Sendable (URLRequest) -> any MuxWebSocket
    private var socket: (any MuxWebSocket)?
    private var generation = UUID()
    private var receiver: Task<Void, Never>?
    private var streams: [String: AsyncThrowingStream<JSONValue, any Error>.Continuation] = [:]
    private var endpoints: [String: String] = [:]
    private var closed = false

    init(
        credentials: HostCredentials, recorder: (any FrameRecorder)? = nil,
        socketFactory: @escaping @Sendable (URLRequest) -> any MuxWebSocket
    ) {
        self.credentials = credentials
        self.recorder = recorder
        self.socketFactory = socketFactory
    }

    func open(endpoint: String, args: RemoteArgs) async throws -> AsyncThrowingStream<JSONValue, any Error> {
        guard !closed else { throw TransportError.disconnected("The DSH connection was closed.") }
        try Task.checkCancellation()
        let socket = try connectIfNeeded()
        let currentGeneration = generation
        let streamId = UUID().uuidString.lowercased()
        let (stream, continuation) = AsyncThrowingStream<JSONValue, any Error>.makeStream()
        streams[streamId] = continuation
        endpoints[streamId] = endpoint
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.cancel(streamId: streamId, generation: currentGeneration) }
        }
        do {
            try await send(.open(streamId: streamId, endpoint: endpoint, args: args), on: socket)
            try Task.checkCancellation()
            guard currentGeneration == generation else {
                throw TransportError.disconnected("The DSH stream connection was interrupted.")
            }
        } catch {
            // A cancelled opener must not interrupt unrelated logical streams.
            if error is CancellationError || Task.isCancelled {
                finish(streamId, throwing: CancellationError())
                if currentGeneration == generation {
                    try? await send(.cancel(streamId: streamId), on: socket)
                }
                throw CancellationError()
            }
            // Failed opens never leave a continuation retained by the mux.
            finish(streamId, throwing: error)
            failAll(TransportError.disconnected("The DSH stream connection was interrupted."), generation: currentGeneration)
            throw error
        }
        return stream
    }

    private func connectIfNeeded() throws -> any MuxWebSocket {
        if let socket { return socket }
        guard var components = URLComponents(url: credentials.baseURL, resolvingAgainstBaseURL: false) else {
            throw TransportError.invalidRequest
        }
        components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
        components.path = "/api/remote.mux"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw TransportError.invalidRequest }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue(credentials.cookie, forHTTPHeaderField: "Cookie")
        let socket = socketFactory(request)
        generation = UUID()
        let currentGeneration = generation
        self.socket = socket
        socket.resume()
        receiver = Task { [weak self] in
            await self?.receiveLoop(socket, generation: currentGeneration)
        }
        return socket
    }

    private func receiveLoop(_ socket: any MuxWebSocket, generation currentGeneration: UUID) async {
        while !Task.isCancelled {
            do {
                let text = try await socket.receive()
                guard currentGeneration == generation else { return }
                await handle(text)
            } catch {
                failAll(TransportError.disconnected("The DSH stream connection was interrupted."), generation: currentGeneration)
                return
            }
        }
    }

    private func handle(_ text: String) async {
        guard let frame = try? JSONDecoder().decode(MuxServerFrame.self, from: Data(text.utf8)) else { return }
        await recorder?.record(direction: .receive, channel: "mux:\(endpoints[frame.streamId] ?? "?")", text: text)
        switch frame {
        case .item(let id, let value): streams[id]?.yield(value ?? .null)
        case .error(let id, let error): finish(id, throwing: error)
        case .end(let id): finish(id, throwing: nil)
        }
    }

    private func cancel(streamId: String, generation currentGeneration: UUID) async {
        guard currentGeneration == generation,
              streams.removeValue(forKey: streamId) != nil else { return }
        endpoints.removeValue(forKey: streamId)
        if let socket { try? await send(.cancel(streamId: streamId), on: socket) }
    }

    private func finish(_ id: String, throwing error: (any Error)?) {
        endpoints.removeValue(forKey: id)
        streams.removeValue(forKey: id)?.finish(throwing: error)
    }

    private func failAll(_ error: any Error, generation currentGeneration: UUID) {
        guard currentGeneration == generation else { return }
        let oldSocket = socket
        socket = nil
        generation = UUID()
        receiver?.cancel()
        receiver = nil
        oldSocket?.cancel()
        let pending = streams
        streams.removeAll()
        endpoints.removeAll()
        for continuation in pending.values { continuation.finish(throwing: error) }
    }

    func close() {
        guard !closed else { return }
        closed = true
        failAll(TransportError.disconnected("The DSH connection was closed."), generation: generation)
    }

    private func send(_ frame: MuxClientFrame, on socket: any MuxWebSocket) async throws {
        let text = String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
        let channel: String
        switch frame {
        case .open(_, let endpoint, _): channel = "mux:\(endpoint)"
        case .item(let id, _), .end(let id), .cancel(let id): channel = "mux:\(endpoints[id] ?? "?")"
        }
        await recorder?.record(direction: .send, channel: channel, text: text)
        try await socket.send(text)
    }
}
