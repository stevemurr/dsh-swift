import DSHProtocol
import Foundation
import XCTest
@testable import DSHKit

final class DSHConnectionLifecycleTests: XCTestCase {
    func testConcurrentCallersShareOneAuthenticationAndTransport() async throws {
        let gate = AuthenticationGate()
        let connection = makeConnection(gate)
        try await connection.configure(authenticatedURL: localURL(port: 18765))
        let callers = (0..<20).map { _ in Task { try await connection.connected() } }
        try await gate.waitForRequests(1)
        await gate.succeed(0)
        var snapshots: [DSHConnectedClient] = []
        for caller in callers { snapshots.append(try await caller.value) }
        let first = try XCTUnwrap(snapshots.first?.client.transport as? LoopbackTransport)
        for snapshot in snapshots {
            XCTAssertEqual(snapshot.identity, "http://localhost:18765")
            XCTAssertTrue((snapshot.client.transport as? LoopbackTransport) === first)
        }
        let count = await gate.requestCount
        XCTAssertEqual(count, 1)
        await connection.disconnect()
    }

    func testReconfigurationCannotRestoreAnObsoletePendingConnection() async throws {
        let gate = AuthenticationGate()
        let connection = makeConnection(gate)
        try await connection.configure(authenticatedURL: localURL(port: 18765))
        let obsolete = Task { try await connection.connected() }
        try await gate.waitForRequests(1)
        try await connection.configure(authenticatedURL: localURL(port: 18766))
        let current = Task { try await connection.connected() }
        try await gate.waitForRequests(2)
        await gate.succeed(1)
        let snapshot = try await current.value
        await gate.succeed(0)
        do {
            _ = try await obsolete.value
            XCTFail("A connection from the previous generation must not be returned")
        } catch {
            XCTAssertTrue(error is CancellationError || error as? DSHConnectionError == .reconfigured)
        }
        let cached = try await connection.connected()
        XCTAssertEqual(cached.identity, "http://localhost:18766")
        XCTAssertTrue((cached.client.transport as? LoopbackTransport) === (snapshot.client.transport as? LoopbackTransport))
        await connection.disconnect()
    }

    func testDisconnectClosesExistingClientsAndAllowsFreshAuthentication() async throws {
        let gate = AuthenticationGate()
        let connection = makeConnection(gate)
        try await connection.configure(authenticatedURL: localURL(port: 18765))
        let first = Task { try await connection.connected() }
        try await gate.waitForRequests(1)
        await gate.succeed(0)
        let old = try await first.value
        await connection.disconnect()
        do {
            // This invalid endpoint never performs I/O, even if lifecycle checking regresses.
            _ = try await old.client.transport.call("invalid?endpoint", args: [:])
            XCTFail("Disconnected clients must reject requests")
        } catch {
            guard case TransportError.disconnected = error else { return XCTFail("Expected closed transport") }
        }
        let second = Task { try await connection.connected() }
        try await gate.waitForRequests(2)
        await gate.succeed(1)
        let fresh = try await second.value
        XCTAssertFalse((old.client.transport as? LoopbackTransport) === (fresh.client.transport as? LoopbackTransport))
        await connection.disconnect()
    }

    func testAuthenticationFailureIsRedactedAndCanBeRetried() async throws {
        let gate = AuthenticationGate()
        let connection = makeConnection(gate)
        try await connection.configure(authenticatedURL: localURL(port: 18765))
        let failed = Task { try await connection.connected() }
        try await gate.waitForRequests(1)
        await gate.fail(0)
        do {
            _ = try await failed.value
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertEqual(error as? DSHConnectionError, .authenticationFailed)
            XCTAssertFalse(String(describing: error).contains("synthetic-secret"))
        }
        let retry = Task { try await connection.connected() }
        try await gate.waitForRequests(2)
        await gate.succeed(1)
        _ = try await retry.value
        await connection.disconnect()
    }

    private func makeConnection(_ gate: AuthenticationGate) -> DSHConnection {
        DSHConnection(handoffURL: URL(fileURLWithPath: "/nonexistent/synthetic-handoff.json")) {
            try await gate.exchange($0)
        }
    }

    private func localURL(port: Int) -> URL { URL(string: "http://localhost:\(port)/?token=synthetic-secret")! }
}

private actor AuthenticationGate {
    private var urls: [URL] = []
    private var pending: [Int: CheckedContinuation<HostCredentials, any Error>] = [:]
    var requestCount: Int { urls.count }

    func exchange(_ url: URL) async throws -> HostCredentials {
        let index = urls.count
        urls.append(url)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func succeed(_ index: Int) {
        var components = URLComponents(url: urls[index], resolvingAgainstBaseURL: false)!
        components.query = nil
        pending.removeValue(forKey: index)?.resume(returning: HostCredentials(baseURL: components.url!, cookie: "dsh=synthetic-cookie"))
    }

    func fail(_ index: Int) {
        pending.removeValue(forKey: index)?.resume(throwing: TransportError.authentication("synthetic-secret"))
    }

    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<200 {
            if requestCount >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw GateTimeout()
    }
}

private struct GateTimeout: Error {}
