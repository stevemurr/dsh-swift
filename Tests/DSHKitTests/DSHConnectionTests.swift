import Foundation
import XCTest
@testable import DSHKit

final class DSHConnectionTests: XCTestCase {
    func testCanonicalIdentityPreservesHostPortAndExcludesToken() throws {
        XCTAssertEqual(try DSHConnection.validate(url("http://localhost:18765/?token=fake-secret")), "http://localhost:18765")
        XCTAssertEqual(try DSHConnection.validate(url("http://localhost/?token=fake-secret")), "http://localhost:80")
        XCTAssertEqual(try DSHConnection.validate(url("https://127.0.0.1/?token=fake-secret")), "https://127.0.0.1:443")
        XCTAssertEqual(try DSHConnection.validate(url("http://[::1]:18765/?token=fake-secret")), "http://[::1]:18765")
    }

    func testConnectionRejectsRemoteAndMalformedAuthenticatedURLs() {
        for raw in ["http://localhost.evil.invalid/?token=fake", "http://192.168.1.5/?token=fake", "https://example.invalid/?token=fake", "file:///tmp/?token=fake", "http://user:password@localhost/?token=fake", "http://localhost/", "http://localhost/?token="] {
            XCTAssertThrowsError(try DSHConnection.validate(url(raw)), raw)
        }
    }

    func testBridgeHandoffRequiresMatchingLocalOriginAndCurrentSchema() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "dev-auth.json")
        try Data(#"{"schemaVersion":1,"url":"http://127.0.0.1:18765/?token=fake","baseUrl":"http://127.0.0.1:18765","pid":1}"#.utf8).write(to: file)
        XCTAssertEqual(try DSHConnection.readHandoff(at: file).host, "127.0.0.1")
        for value in [
            #"{"schemaVersion":2,"url":"http://127.0.0.1:18765/?token=fake"}"#,
            #"{"schemaVersion":1,"url":"http://remote.invalid/?token=fake"}"#,
            #"{"schemaVersion":1,"url":"http://localhost:18765/?token=fake","baseUrl":"http://127.0.0.1:18765"}"#,
            #"{"schemaVersion":1,"url":"http://localhost:18765/?token=fake","baseUrl":"http://localhost:18766"}"#,
            "invalid JSON"
        ] {
            try Data(value.utf8).write(to: file)
            XCTAssertThrowsError(try DSHConnection.readHandoff(at: file))
        }
    }

    func testMissingHandoffGivesActionableRedactedError() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let connection = DSHConnection(environment: [:], homeDirectory: home)
        do {
            _ = try await connection.connected()
            XCTFail("Expected unavailable handoff")
        } catch {
            XCTAssertEqual(error as? DSHConnectionError, .handoffUnavailable)
            XCTAssertTrue(DSHConnectionError.message(for: error).contains("authenticated local connection URL"))
        }
        await connection.disconnect()
    }

    func testErrorMessagesNeverIncludeServerBodiesOrURLCredentials() {
        let secret = "fake-private-token"
        let errors: [any Error] = [
            TransportError.http(status: 403, body: secret),
            TransportError.authentication(secret),
            TransportError.disconnected("http://localhost/?token=\(secret)"),
            URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLStringErrorKey: "http://localhost/?token=\(secret)"])
        ]
        for error in errors {
            let message = DSHConnectionError.message(for: error)
            XCTAssertFalse(message.contains(secret))
            XCTAssertFalse(message.contains("?token="))
        }
    }

    /// Opt-in smoke: authenticates and reads the model catalog only. It never
    /// lists sessions, reads transcripts, creates a session or starts inference.
    func testLiveLocalConnectionWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["DSH_SWIFT_LIVE_CHECK"] == "1" else {
            throw XCTSkip("Set DSH_SWIFT_LIVE_CHECK=1 for the read-only local DSH check")
        }
        let connection = DSHConnection()
        do {
            let snapshot = try await connection.connected()
            let catalog = try await snapshot.client.modelCatalog()
            XCTAssertFalse(snapshot.identity.contains("token"))
            XCTAssertFalse(catalog.groups.isEmpty, "DSH should expose at least one model provider")
            await connection.disconnect()
        } catch {
            await connection.disconnect()
            XCTFail(DSHConnectionError.message(for: error))
        }
    }

    private func url(_ raw: String) -> URL { URL(string: raw)! }
}
