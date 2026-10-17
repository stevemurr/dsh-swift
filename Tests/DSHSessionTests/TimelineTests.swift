import DSHProtocol
import DSHSession
import Foundation
import XCTest

final class TimelineTests: XCTestCase {
    func testLiveTokensBecomeOneDurableAnswerAndReconnectDuplicatesAreIgnored() throws {
        var timeline = Timeline()
        timeline.apply(try event("turn/start", seq: 0, data: ["turn": 1]))
        timeline.apply(try user("Question", seq: 1))
        timeline.apply(.start(attemptId: "attempt-1", turn: 1, step: 0))
        timeline.apply(.chunk(attemptId: "attempt-1", index: 0, chunk: ["type": "text-delta", "index": 0, "text": "Hello "]))
        timeline.apply(.chunk(attemptId: "attempt-1", index: 1, chunk: ["type": "reasoning-delta", "index": 1, "text": "Thinking"]))
        timeline.apply(.chunk(attemptId: "attempt-1", index: 2, chunk: ["type": "text-delta", "index": 0, "text": "world"]))
        XCTAssertEqual(timeline.live?.text, "Hello world")
        XCTAssertEqual(timeline.live?.reasoning, "Thinking")
        let liveAnswerId = timeline.answerIds.live
        let committed = try event("assistant/message", seq: 2, data: ["message": ["content": [["type": "text", "text": "Hello world"]]]])
        timeline.apply(committed)
        timeline.apply(committed)
        timeline.apply(.end(attemptId: "attempt-1", committedSeq: 2))
        XCTAssertNil(timeline.live)
        XCTAssertEqual(timeline.items.count, 2)
        guard let answer = timeline.items.last, case .assistant(let markdown) = answer.content else {
            return XCTFail("Expected one committed assistant answer")
        }
        XCTAssertEqual(markdown, "Hello world")
        XCTAssertEqual(timeline.answerIds.committed[answer.id], liveAnswerId)
        timeline.apply(try event("turn/end", seq: 3, data: ["turn": 1]))
        XCTAssertFalse(timeline.running)
        XCTAssertEqual(timeline.cursor, 3)
        XCTAssertEqual(timeline.turns[1]?.outcome, .completed)
    }

    func testReconnectSnapshotReplacesOldStateAndRestoresActiveStreamAtItsCursor() throws {
        var timeline = Timeline()
        timeline.apply(try user("Old conversation", seq: 1))
        let started = try event("turn/start", seq: 10, data: ["turn": 2])
        let question = try user("Current question", seq: 11)
        let snapshot: JSONValue = [
            "type": "snapshot", "header": [:], "cursor": 15, "hasMore": false,
            "records": [["type": "event", "event": try .from(started)], ["type": "event", "event": try .from(question)]],
            "projections": ["values": ["title": "Restored conversation"]],
            "assistantStream": ["activeAttempt": ["attemptId": "attempt-2", "stream": [
                ["chunk": ["type": "text-delta", "index": 0, "text": "Resumed response"]],
            ]]],
        ]
        guard case .snapshot(let decoded) = SessionFollowFrame(snapshot) else { return XCTFail("Expected snapshot") }
        timeline.reset(with: decoded)
        XCTAssertEqual(timeline.title, "Restored conversation")
        XCTAssertEqual(timeline.userTexts, ["Current question"])
        XCTAssertEqual(timeline.live?.text, "Resumed response")
        XCTAssertEqual(timeline.cursor, 15)
        XCTAssertTrue(timeline.running)
        timeline.apply(try user("Already before the snapshot cursor", seq: 14))
        XCTAssertEqual(timeline.items.count, 1)
        timeline.apply(try event("assistant/message", seq: 16, data: ["message": ["content": [["type": "text", "text": "Completed response"]]]]))
        XCTAssertEqual(timeline.items.count, 2)
        XCTAssertNil(timeline.live)
    }

    func testToolApprovalAndResultStayAttachedToTheOriginalCall() throws {
        var timeline = Timeline()
        timeline.apply(try event("tool/call", seq: 1, data: ["callId": "call-1", "name": "write_file", "arguments": "{}"] ))
        timeline.apply(try event("approval/asked", seq: 2, data: ["id": "approval-1", "callId": "call-1", "reason": "Write a file"] ))
        timeline.apply(try event("approval/decided", seq: 3, data: ["id": "approval-1", "outcome": "allowed-once"] ))
        timeline.apply(try event("tool/result", seq: 4, data: ["message": ["source": ["callId": "call-1"],
            "content": [["type": "text", "text": "Saved"]], "isError": false]]))
        XCTAssertEqual(timeline.items.count, 1)
        guard case .tool(let tool) = timeline.items[0].content else { return XCTFail("Expected the original tool call") }
        XCTAssertEqual(tool.callId, "call-1")
        XCTAssertEqual(tool.approval, .decided(id: "approval-1", outcome: "allowed-once"))
        XCTAssertEqual(tool.result, ToolResult(text: "Saved", isError: false))
        XCTAssertFalse(tool.isRunning)
    }

    func testLoadingOlderHistoryPreservesCurrentPromptsAndLiveResponse() throws {
        var timeline = Timeline()
        timeline.apply(try user("Current question", seq: 10))
        timeline.apply(try event("turn/start", seq: 11, data: ["turn": 2]))
        timeline.apply(.start(attemptId: "current-attempt", turn: 2, step: 0))
        timeline.apply(.chunk(attemptId: "current-attempt", index: 0, chunk: ["type": "text-delta", "index": 0, "text": "Working"]))
        timeline.prepend([try user("Earlier question", seq: 1)])
        XCTAssertEqual(timeline.items.map(\.seq), [1, 10])
        XCTAssertEqual(timeline.userTexts, ["Earlier question", "Current question"])
        XCTAssertEqual(timeline.live?.text, "Working")
        XCTAssertEqual(timeline.live?.attemptId, "current-attempt")
        XCTAssertEqual(timeline.cursor, 11)
        XCTAssertEqual(timeline.firstSeq, 1)
        XCTAssertEqual(timeline.currentTurn, 2)
        XCTAssertTrue(timeline.running)
        timeline.apply(try user("Earlier question", seq: 1))
        XCTAssertEqual(timeline.items.count, 2)
    }

    private func event(_ type: String, seq: Int, data: JSONValue) throws -> SessionEvent {
        try JSONValue.object(["type": .string(type), "seq": .number(Double(seq)), "time": .number(Double(seq) * 1_000), "data": data])
            .decode(SessionEvent.self)
    }

    private func user(_ text: String, seq: Int) throws -> SessionEvent {
        try event("user/message", seq: seq, data: ["source": ["kind": "user"], "content": [["type": "text", "text": .string(text)]]])
    }
}
