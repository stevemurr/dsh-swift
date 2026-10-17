import DSHProtocol
import Foundation
import XCTest
@testable import DSHKit

final class LoopbackTransportTests: XCTestCase {
    func testAuthenticationExchangesWithoutPersistingOrFollowingRedirect() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.respond = { request in
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.url?.host, "localhost")
            return (303, ["Set-Cookie": "dsh=fake-test-cookie; Path=/; HttpOnly", "Location": "http://example.invalid/"], Data())
        }
        let credentials = try await HostCredentials.exchange(
            authenticatedURL: URL(string: "http://localhost:18765/?token=fake-test-token#fragment")!, configuration: configuration
        )
        XCTAssertEqual(credentials.baseURL.absoluteString, "http://localhost:18765/")
        XCTAssertEqual(credentials.cookie, "dsh=fake-test-cookie")
    }

    func testRPCUsesExactHostPortCookieAndWireEnvelope() async throws {
        let session = makeSession()
        let credentials = HostCredentials(baseURL: URL(string: "http://localhost:18765/")!, cookie: "dsh=fake-cookie")
        StubURLProtocol.respond = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:18765/api/session/modelCatalog")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "dsh=fake-cookie")
            XCTAssertFalse(request.httpShouldHandleCookies)
            let body = try JSONDecoder().decode(JSONValue.self, from: Self.requestBody(request))
            XCTAssertEqual(body["method"]?.stringValue, "session/modelCatalog")
            XCTAssertNotNil(body["payload"]?["args"])
            return (200, ["Content-Type": "application/json; charset=utf-8"], Data(#"{"type":"server-response","rpcId":"test","result":{"ok":true,"value":{"found":true}}}"#.utf8))
        }
        let transport = LoopbackTransport(credentials: credentials, session: session) { _ in FakeMuxWebSocket() }
        let value = try await transport.call("session/modelCatalog", args: [:])
        XCTAssertEqual(value?["found"]?.boolValue, true)
        await transport.disconnect()
    }

    func testHTTPFailureDescriptionDoesNotExposeResponseBody() async throws {
        StubURLProtocol.respond = { _ in (403, ["Content-Type": "text/plain"], Data("private-test-token".utf8)) }
        let transport = LoopbackTransport(credentials: credentials, session: makeSession()) { _ in FakeMuxWebSocket() }
        do {
            _ = try await transport.call("session/modelCatalog", args: [:])
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertFalse(String(describing: error).contains("private-test-token"))
            guard case TransportError.http(let status, let body) = error else { return XCTFail("Unexpected failure") }
            XCTAssertEqual(status, 403)
            XCTAssertTrue(body.isEmpty)
        }
        await transport.disconnect()
    }

    func testMuxRoutesIndependentStreamsAndCancelsOnlyConsumer() async throws {
        let socket = FakeMuxWebSocket()
        let mux = MuxSocket(credentials: credentials) { _ in socket }
        let first = try await mux.open(endpoint: "session/follow", args: [:])
        let second = try await mux.open(endpoint: "$events", args: [:])
        let firstID = try socket.openID(at: 0)
        let secondID = try socket.openID(at: 1)
        let firstConsumer = Task { () throws -> [JSONValue] in
            var values: [JSONValue] = []
            for try await value in first { values.append(value) }
            return values
        }
        firstConsumer.cancel()
        _ = await firstConsumer.result
        try await eventually { socket.sentFrames.contains(where: { $0["type"]?.stringValue == "cancel" && $0["streamId"]?.stringValue == firstID }) }
        socket.push(#"{"type":"item","streamId":"\#(secondID)","value":{"ready":true}}"#)
        socket.push(#"{"type":"end","streamId":"\#(secondID)"}"#)
        var values: [JSONValue] = []
        for try await value in second { values.append(value) }
        XCTAssertEqual(values.first?["ready"]?.boolValue, true)
        XCTAssertFalse(socket.wasCancelled)
        await mux.close()
    }

    func testSocketFailureFinishesStreamsAndNextOpenReconnects() async throws {
        let first = FakeMuxWebSocket()
        let second = FakeMuxWebSocket()
        let factory = SocketQueue([first, second])
        let mux = MuxSocket(credentials: credentials) { _ in factory.next() }
        let stream = try await mux.open(endpoint: "session/follow", args: [:])
        first.fail()
        do {
            for try await _ in stream {}
            XCTFail("Expected interrupted stream")
        } catch {}
        let reconnected = try await mux.open(endpoint: "$events", args: [:])
        let id = try second.openID(at: 0)
        second.push(#"{"type":"item","streamId":"\#(id)","value":{"connected":true}}"#)
        second.push(#"{"type":"end","streamId":"\#(id)"}"#)
        var values: [JSONValue] = []
        for try await value in reconnected { values.append(value) }
        XCTAssertEqual(values.first?["connected"]?.boolValue, true)
        XCTAssertTrue(first.wasCancelled)
        await mux.close()
    }

    func testFailedOpenCleansSocketAndDisconnectFinishesAllPendingStreams() async throws {
        let failed = FakeMuxWebSocket(failSend: true)
        let live = FakeMuxWebSocket()
        let queue = SocketQueue([failed, live])
        let mux = MuxSocket(credentials: credentials) { _ in queue.next() }
        do {
            _ = try await mux.open(endpoint: "session/follow", args: [:])
            XCTFail("Expected failed open")
        } catch {}
        XCTAssertTrue(failed.wasCancelled)
        let first = try await mux.open(endpoint: "session/follow", args: [:])
        let second = try await mux.open(endpoint: "$events", args: [:])
        await mux.close()
        for stream in [first, second] {
            do {
                for try await _ in stream {}
                XCTFail("Disconnect should finish with an error")
            } catch {}
        }
        XCTAssertTrue(live.wasCancelled)
        do {
            _ = try await mux.open(endpoint: "session/follow", args: [:])
            XCTFail("Closed connection must not reconnect")
        } catch {}
    }

    private static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(buffer, count: count)
        }
        return body
    }

    private var credentials: HostCredentials {
        HostCredentials(baseURL: URL(string: "http://127.0.0.1:18765/")!, cookie: "dsh=fake-cookie")
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for stream cancellation")
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static var respond: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.respond!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class FakeMuxWebSocket: MuxWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [String] = []
    private var incoming: [Result<String, any Error>] = []
    private var waiter: CheckedContinuation<String, any Error>?
    private var cancelled = false
    private let failSend: Bool

    init(failSend: Bool = false) { self.failSend = failSend }
    func resume() {}
    var wasCancelled: Bool { lock.withLock { cancelled } }
    var sentFrames: [JSONValue] {
        lock.withLock { sent.compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } }
    }
    func openID(at index: Int) throws -> String {
        try XCTUnwrap(sentFrames.filter { $0["type"]?.stringValue == "open" }[index]["streamId"]?.stringValue)
    }
    func cancel() {
        let waiter = lock.withLock { () -> CheckedContinuation<String, any Error>? in
            cancelled = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(throwing: CancellationError())
    }
    func send(_ text: String) async throws {
        if failSend { throw URLError(.networkConnectionLost) }
        lock.withLock { sent.append(text) }
    }
    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<String, any Error>? = lock.withLock {
                if cancelled { return .failure(CancellationError()) }
                if !incoming.isEmpty { return incoming.removeFirst() }
                waiter = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }
    func push(_ value: String) { deliver(.success(value)) }
    func fail() { deliver(.failure(URLError(.networkConnectionLost))) }
    private func deliver(_ result: Result<String, any Error>) {
        let waiter = lock.withLock { () -> CheckedContinuation<String, any Error>? in
            if let waiter = self.waiter { self.waiter = nil; return waiter }
            incoming.append(result)
            return nil
        }
        waiter?.resume(with: result)
    }
}

private final class SocketQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [FakeMuxWebSocket]
    init(_ sockets: [FakeMuxWebSocket]) { self.sockets = sockets }
    func next() -> FakeMuxWebSocket { lock.withLock { sockets.removeFirst() } }
}
