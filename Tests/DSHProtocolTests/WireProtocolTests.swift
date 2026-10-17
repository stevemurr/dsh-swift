import DSHProtocol
import Foundation
import XCTest

final class WireProtocolTests: XCTestCase {
    func testClientRequestUsesHostWireEnvelope() throws {
        let request = ClientRequest(rpcId: "request-1", method: "session/create", args: ["request": ["cwd": "/tmp/example"]])
        let wire = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(wire["type"], "client-request")
        XCTAssertEqual(wire["rpcId"], "request-1")
        XCTAssertEqual(wire["method"], "session/create")
        XCTAssertEqual(wire["payload"]?["args"]?["request"]?["cwd"], "/tmp/example")
    }

    func testApprovalWaterfallRetainsHostRoutingAndRequestDetails() {
        let request: JSONValue = ["toolName": "write_file", "path": "/tmp/example.txt", "futureField": ["nested": true]]
        let value: JSONValue = ["type": "waterfall", "event": "approval/request", "eventId": "event-1",
                                "agentId": "session-1", "request": request]
        guard case .waterfall(let event, let eventId, let agentId, let decodedRequest) = RemoteEventFrame(value) else {
            return XCTFail("Expected a pending approval")
        }
        XCTAssertEqual(event, "approval/request")
        XCTAssertEqual(eventId, "event-1")
        XCTAssertEqual(agentId, "session-1")
        XCTAssertEqual(decodedRequest, request)
        XCTAssertEqual(RemoteEventOutcome.result(.string(ApprovalOutcome.allowedOnce.rawValue)).json,
                       ["kind": "result", "value": "allowed-once"])
    }

    func testEventGenerationAndWithdrawalDecodeIndependently() {
        guard case .ready(let clientId, let home) = RemoteEventFrame(["type": "ready", "clientId": "generation-2", "host": ["home": "/tmp/home"]]) else {
            return XCTFail("Expected a host event generation")
        }
        XCTAssertEqual(clientId, "generation-2")
        XCTAssertEqual(home, "/tmp/home")
        guard case .cancel(let eventId) = RemoteEventFrame(["type": "cancel", "eventId": "event-1"]) else {
            return XCTFail("Expected withdrawal")
        }
        XCTAssertEqual(eventId, "event-1")
    }

    func testFutureAndMalformedFollowFramesRemainAvailableToConsumers() {
        let future: JSONValue = ["type": "future-frame", "data": ["value": 7]]
        for input: JSONValue in [future, ["type": "snapshot", "cursor": "invalid"]] {
            guard case .unknown(let retained) = SessionFollowFrame(input) else {
                return XCTFail("Unknown or malformed frames must remain inspectable")
            }
            XCTAssertEqual(retained, input)
        }
    }
}
