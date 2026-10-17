import DSHProtocol
import Foundation

// Pure reduction of a DSH session log into what the phone renders. No I/O,
// no UI — unit-tested against recorded and synthetic logs.
//
// Shown: real user prompts, assistant text, reasoning (collapsed), tool calls
// with their results and approval state, subagents, command output, turn
// stops/errors. Hidden: plugin/runtime-injected "user" messages, system
// messages, request/step/inbox bookkeeping.

public struct ToolResult: Equatable, Sendable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }
}

public enum ApprovalState: Equatable, Sendable {
    case asked(id: String, reason: String?)
    case decided(id: String, outcome: String)
}

public struct FileDiff: Equatable, Sendable {
    public let path: String
    public let added: Int
    public let removed: Int
    /// Unified-ish lines: ("+"|"-"|" ", text), capped for display.
    public let lines: [DiffLine]
}

public struct DiffLine: Equatable, Sendable, Hashable {
    public let kind: Character  // "+", "-", " "
    public let text: String
}

public struct ToolCallItem: Equatable, Sendable {
    public let callId: String
    public let name: String
    /// Raw JSON arguments string as the model produced it.
    public let arguments: String
    public var result: ToolResult?
    public var approval: ApprovalState?
    /// From `tool/result` meta.diffs (edit/write tools).
    public var diffs: [FileDiff] = []
    /// GenUI `render_ui`: the (host-repaired) spec from `tool/result` meta, and
    /// the result's seq, which orders it among panel operations.
    public var uiSpec: JSONValue?
    public var resultSeq: Int?

    public init(callId: String, name: String, arguments: String, result: ToolResult? = nil, approval: ApprovalState? = nil) {
        self.callId = callId
        self.name = name
        self.arguments = arguments
        self.result = result
        self.approval = approval
    }

    public var addedLines: Int { diffs.reduce(0) { $0 + $1.added } }
    public var removedLines: Int { diffs.reduce(0) { $0 + $1.removed } }

    public var parsedArguments: JSONValue {
        guard let data = arguments.data(using: .utf8), let args = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
        return args
    }

    /// One-line human summary: the command for bash, the path for file tools, …
    public var summary: String {
        guard let data = arguments.data(using: .utf8), let args = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return arguments
        }
        for key in ["command", "path", "file_path", "url", "query", "pattern", "description", "job_id"] {
            if let value = args[key]?.stringValue, !value.isEmpty { return value }
        }
        if let first = args["questions"]?[0]?["question"]?.stringValue { return first }
        return args.compactDescription
    }

    public var isRunning: Bool { result == nil }
}

public enum TimelineContent: Equatable, Sendable {
    case user(text: String, imageCount: Int)
    case assistant(markdown: String)
    case reasoning(text: String)
    case tool(ToolCallItem)
    case subagent(label: String, childId: String)
    case command(name: String, output: String?, isError: Bool)
    case notice(String, isError: Bool)
}

public struct TimelineItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let seq: Int
    public let time: Date
    public var content: TimelineContent
    /// The turn this item belongs to (nil before the first turn/start).
    public var turn: Int?

    public init(id: String, seq: Int, time: Date, content: TimelineContent, turn: Int? = nil) {
        self.id = id
        self.seq = seq
        self.time = time
        self.content = content
        self.turn = turn
    }
}

public struct TurnInfo: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case running
        case completed
        case stopped
        case failed(String?)
    }

    public let turn: Int
    public let startedAt: Date
    public var endedAt: Date?
    public var outcome: Outcome = .running

    public var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}

/// The in-flight assistant attempt, built from `assistant-stream` chunks.
public struct LiveAssistant: Equatable, Sendable {
    public struct Block: Equatable, Sendable {
        public let type: String  // "text" | "reasoning" | "tool-call" | …
        public var text: String
    }

    public let attemptId: String
    public var blocks: [Int: Block] = [:]

    public var orderedBlocks: [Block] { blocks.keys.sorted().compactMap { blocks[$0] } }
    public var text: String { orderedBlocks.filter { $0.type == "text" }.map(\.text).joined() }
    public var reasoning: String { orderedBlocks.filter { $0.type == "reasoning" }.map(\.text).joined() }
    public var isCallingTool: Bool { orderedBlocks.last?.type == "tool-call" }
}

public struct Timeline: Equatable, Sendable {
    public private(set) var items: [TimelineItem] = []
    public private(set) var live: LiveAssistant?
    public private(set) var cursor = -1
    public private(set) var firstSeq: Int?
    public private(set) var running = false
    public private(set) var title: String?
    /// User prompts seen in the log (for reconciling optimistic bubbles).
    public private(set) var userTexts: [String] = []
    public private(set) var turns: [Int: TurnInfo] = [:]
    public private(set) var currentTurn: Int?

    private var toolIndex: [String: Int] = [:]  // callId → items index
    private var approvalCalls: [String: String] = [:]  // approval id → callId

    public init() {}

    // MARK: Inputs

    /// Replace everything with a `session/follow` snapshot.
    public mutating func reset(with snapshot: SessionSnapshot) {
        self = Timeline()
        title = snapshot.projections["values"]?["title"]?.stringValue
        for record in snapshot.records { apply(record.event) }
        cursor = max(cursor, snapshot.cursor)
        if let attempt = snapshot.assistantStream?["activeAttempt"], let attemptId = attempt["attemptId"]?.stringValue {
            live = LiveAssistant(attemptId: attemptId)
            for chunk in attempt["stream"]?.arrayValue ?? [] { applyChunk(chunk["chunk"] ?? chunk) }
        }
    }

    /// Prepend older history from `session/page`.
    public mutating func prepend(_ events: [SessionEvent]) {
        var older = Timeline()
        for event in events where event.seq < (firstSeq ?? .max) { older.apply(event) }
        guard !older.items.isEmpty else { return }
        let merged = older.items + items
        let keepLive = live
        let keepCursor = cursor
        let keepRunning = running
        let keepTitle = title
        let keepApprovals = approvalCalls.merging(older.approvalCalls) { current, _ in current }
        let keepTurns = turns.merging(older.turns) { current, _ in current }
        let keepCurrentTurn = currentTurn
        let keepUserTexts = userTexts
        self = Timeline()
        approvalCalls = keepApprovals
        turns = keepTurns
        currentTurn = keepCurrentTurn
        for item in merged { insert(item) }
        firstSeq = merged.first?.seq
        live = keepLive
        cursor = keepCursor
        running = keepRunning
        title = keepTitle
        userTexts = older.userTexts + keepUserTexts
    }

    public mutating func apply(_ event: SessionEvent) {
        guard event.seq > cursor || cursor < 0 else { return }  // duplicate after reconnect
        cursor = max(cursor, event.seq)
        if firstSeq == nil { firstSeq = event.seq }
        let data = event.data ?? .null
        let time = Date(timeIntervalSince1970: event.time / 1000)
        let turn = data["turn"]?.intValue ?? currentTurn
        func add(_ id: String, _ content: TimelineContent) {
            insert(TimelineItem(id: id, seq: event.seq, time: time, content: content, turn: turn))
        }

        switch event.type {
        case "user/message":
            guard data["source"]?["kind"]?.stringValue == "user" else { return }  // injected context
            let blocks = data["content"]?.arrayValue ?? []
            let text = blocks.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined(separator: "\n")
            let images = blocks.filter { $0["type"]?.stringValue == "image" }.count
            userTexts.append(text)
            add("u\(event.seq)", .user(text: text, imageCount: images))

        case "assistant/message":
            // The committed message supersedes the in-flight stream; dropping
            // `live` here (not at the later `end` frame) means the live row and
            // its committed replacement never coexist on screen.
            live = nil
            for (index, block) in (data["message"]?["content"]?.arrayValue ?? []).enumerated() {
                let text = block["text"]?.stringValue ?? ""
                switch block["type"]?.stringValue {
                case "text" where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    add("a\(event.seq).\(index)", .assistant(markdown: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                case "reasoning" where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    add("r\(event.seq).\(index)", .reasoning(text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                default:
                    break  // tool-call blocks are rendered from tool/call events
                }
            }

        case "tool/call":
            guard let callId = data["callId"]?.stringValue else { return }
            let item = ToolCallItem(callId: callId, name: data["name"]?.stringValue ?? "tool", arguments: data["arguments"]?.stringValue ?? "{}")
            add("t\(callId)", .tool(item))

        case "tool/result":
            let message = data["message"] ?? .null
            guard let callId = message["source"]?["callId"]?.stringValue ?? message["toolCallId"]?.stringValue else { return }
            let text = (message["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            let meta = message["meta"] ?? data["meta"]
            let diffs = (meta?["diffs"]?.arrayValue ?? []).compactMap(Self.fileDiff)
            updateTool(callId) {
                $0.result = ToolResult(text: text, isError: message["isError"]?.boolValue ?? false)
                if !diffs.isEmpty { $0.diffs = diffs }
                if $0.name == GenUI.renderTool, let meta, meta["items"]?.arrayValue?.isEmpty == false {
                    $0.uiSpec = meta
                    $0.resultSeq = event.seq
                }
            }

        case "approval/asked":
            guard let id = data["id"]?.stringValue, let callId = data["callId"]?.stringValue else { return }
            approvalCalls[id] = callId
            updateTool(callId) { $0.approval = .asked(id: id, reason: data["reason"]?.stringValue) }

        case "approval/decided":
            guard let id = data["id"]?.stringValue, let callId = approvalCalls[id] else { return }
            updateTool(callId) { $0.approval = .decided(id: id, outcome: data["outcome"]?.stringValue ?? "") }

        case "turn/start":
            running = true
            if let number = data["turn"]?.intValue {
                currentTurn = number
                turns[number] = TurnInfo(turn: number, startedAt: time)
            }

        case "turn/end":
            running = false
            live = nil
            let number = data["turn"]?.intValue ?? currentTurn
            var outcome = TurnInfo.Outcome.completed
            switch data["reason"]?["kind"]?.stringValue {
            case "aborted":
                outcome = .stopped
                add("n\(event.seq)", .notice("Stopped", isError: false))
            case "error", "failed":
                let message = data["reason"]?["message"]?.stringValue
                outcome = .failed(message)
                add("n\(event.seq)", .notice(message ?? "The turn failed", isError: true))
            default: break
            }
            if let number {
                var info = turns[number] ?? TurnInfo(turn: number, startedAt: time)
                info.endedAt = time
                info.outcome = outcome
                turns[number] = info
            }

        case "session/title":
            title = data["title"]?.stringValue ?? title

        case "subagent/catalog":
            guard let childId = data["childId"]?.stringValue else { return }
            if !items.contains(where: { $0.id == "s\(childId)" }) {
                add("s\(childId)", .subagent(label: data["label"]?.stringValue ?? "Subagent", childId: childId))
            }

        case "command/run":
            guard let commandId = data["commandId"]?.stringValue else { return }
            let name = data["name"]?.stringValue ?? "command"
            let args = data["args"]?.stringValue ?? ""
            add("c\(commandId)", .command(name: "/\(name)\(args.isEmpty ? "" : " \(args)")", output: nil, isError: false))

        case "command/done":
            guard let commandId = data["commandId"]?.stringValue, let index = items.firstIndex(where: { $0.id == "c\(commandId)" }),
                case .command(let name, _, _) = items[index].content
            else { return }
            items[index].content = .command(name: name, output: data["text"]?.stringValue, isError: data["kind"]?.stringValue == "error")

        case "compaction/done", "compaction/end":
            add("n\(event.seq)", .notice("Earlier conversation was compacted", isError: false))

        default:
            break
        }
    }

    /// Stable identity for each assistant answer: "answer-<turn>-<k>", where k
    /// counts the turn's committed answers. The live stream uses the id its
    /// committed message will get, so the view is updated in place rather than
    /// replaced (a replacement re-lays-out and briefly shrinks the transcript).
    public var answerIds: (committed: [String: String], live: String) {
        var counts: [Int: Int] = [:]
        var ids: [String: String] = [:]
        for item in items {
            guard case .assistant = item.content else { continue }
            let turn = item.turn ?? -1
            ids[item.id] = "answer-\(turn)-\(counts[turn, default: 0])"
            counts[turn, default: 0] += 1
        }
        let turn = currentTurn ?? -1
        return (ids, "answer-\(turn)-\(counts[turn, default: 0])")
    }

    /// One `assistant-stream` frame.
    public mutating func apply(_ frame: AssistantStreamFrame) {
        switch frame {
        case .start(let attemptId, _, _):
            live = LiveAssistant(attemptId: attemptId)
            running = true
        case .chunk(let attemptId, _, let chunk):
            if live?.attemptId != attemptId { live = LiveAssistant(attemptId: attemptId) }
            applyChunk(chunk)
        case .end(let attemptId, _):
            if live?.attemptId == attemptId { live = nil }
        case .unknown:
            break
        }
    }

    // MARK: Internals

    private mutating func applyChunk(_ chunk: JSONValue) {
        guard live != nil, let index = chunk["index"]?.intValue else { return }
        switch chunk["type"]?.stringValue {
        case "block-start":
            live!.blocks[index] = .init(type: chunk["blockType"]?.stringValue ?? "text", text: "")
        case "text-delta", "reasoning-delta":
            let type = chunk["type"]?.stringValue == "reasoning-delta" ? "reasoning" : "text"
            live!.blocks[index, default: .init(type: type, text: "")].text += chunk["text"]?.stringValue ?? ""
        default:
            break
        }
    }

    static func fileDiff(_ value: JSONValue) -> FileDiff? {
        guard let path = value["path"]?.stringValue else { return nil }
        let old = (value["oldText"]?.stringValue ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let new = (value["newText"]?.stringValue ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let difference = new.difference(from: old)
        var lines: [DiffLine] = []
        for change in difference {
            switch change {
            case .remove(_, let text, _): lines.append(DiffLine(kind: "-", text: text))
            case .insert(_, let text, _): lines.append(DiffLine(kind: "+", text: text))
            }
        }
        // Show removals before insertions, as a compact hunk.
        lines.sort { ($0.kind == "-" ? 0 : 1) < ($1.kind == "-" ? 0 : 1) }
        return FileDiff(
            path: path, added: difference.insertions.count, removed: difference.removals.count,
            lines: Array(lines.prefix(400)))
    }

    private mutating func insert(_ item: TimelineItem) {
        if case .tool(let tool) = item.content { toolIndex[tool.callId] = items.count }
        items.append(item)
    }

    private mutating func updateTool(_ callId: String, _ change: (inout ToolCallItem) -> Void) {
        guard let index = toolIndex[callId], case .tool(var tool) = items[index].content else { return }
        change(&tool)
        items[index].content = .tool(tool)
    }
}
