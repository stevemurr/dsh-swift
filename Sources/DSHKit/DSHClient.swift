import DSHProtocol
import Foundation

/// Typed façade over the DSH host's remote API. Stateless: every view of
/// truth comes from the host's streams, so phone, desktop and web stay in sync.
public struct DSHClient: Sendable {
    public let transport: any DSHTransport

    public init(transport: any DSHTransport) {
        self.transport = transport
    }

    // MARK: Sessions

    public func listSessions(cursor: String? = nil) async throws -> [SessionSummary] {
        var request: [String: JSONValue] = [:]
        if let cursor { request["cursor"] = .string(cursor) }
        // Wire name is `_request` for this endpoint (protocol dump).
        let value = try await transport.call("session/list", args: ["_request": .object(request)])
        return try (value ?? .null).decode(SessionListValue.self).items
    }

    public func createSession(cwd: String? = nil, workspaceId: String? = nil, agentPreset: String? = nil) async throws -> String {
        var request: [String: JSONValue] = [:]
        if let cwd { request["cwd"] = .string(cwd) }
        if let workspaceId { request["workspaceId"] = .string(workspaceId) }
        if let agentPreset { request["agentPreset"] = .string(agentPreset) }
        let value = try await transport.call("session/create", args: ["request": .object(request)])
        guard let sessionId = value?["sessionId"]?.stringValue else {
            throw RemoteErrorPayload(message: "session/create returned no sessionId")
        }
        return sessionId
    }

    public func prompt(sessionId: String, content: [PromptContent], mode: PromptMode = .queue) async throws {
        let request: JSONValue = [
            "requestId": .string(UUID().uuidString.lowercased()),
            "sessionId": .string(sessionId),
            "mode": .string(mode.rawValue),
            "content": .array(content.map(\.json)),
            "clientTimeZone": .string(TimeZone.current.identifier),
        ]
        _ = try await transport.call("session/prompt", args: ["request": request])
    }

    public func cancel(sessionId: String) async throws {
        _ = try await transport.call("session/cancel", args: ["request": ["sessionId": .string(sessionId)]])
    }

    public func modelCatalog() async throws -> ModelCatalog {
        try (try await transport.call("session/modelCatalog", args: [:]) ?? .null).decode(ModelCatalog.self)
    }

    public func selectModel(sessionId: String, provider: String, model: String, reasoningEffort: String?) async throws {
        var request: [String: JSONValue] = ["sessionId": .string(sessionId), "provider": .string(provider), "model": .string(model)]
        if let reasoningEffort { request["reasoningEffort"] = .string(reasoningEffort) }
        _ = try await transport.call("session/selectModel", args: ["request": .object(request)])
    }

    // MARK: Goals

    public enum GoalAction: String, Sendable { case pause, resume, complete, clear }

    /// Pause / resume / complete / clear the session's goal (`ref` = id + revision).
    public func goal(_ action: GoalAction, sessionId: String, goalId: String, revision: Int) async throws {
        _ = try await transport.call("goals/\(action.rawValue)", args: [
            "agentId": .string(sessionId),
            "ref": ["id": .string(goalId), "revision": .number(Double(revision))],
        ])
    }

    // MARK: Workspaces & folders

    /// The default workspace (created on the host if it doesn't exist yet).
    public func defaultWorkspace() async throws -> Workspace? {
        try (try await transport.call("workspace/initializeDefault", args: [:]))?["workspace"].map { try $0.decode(Workspace.self) }
    }

    /// Register a folder on the host as a workspace (returns the existing one if already registered).
    public func createWorkspace(path: String) async throws -> Workspace {
        let value = try await transport.call("workspace/create", args: ["request": ["path": .string(path)]])
        return try (value?["workspace"] ?? .null).decode(Workspace.self)
    }

    /// Folders under `path` (nil: the picker's starting folder).
    public func listDirectory(_ path: String?) async throws -> DirectoryListing {
        // The starting folder is requested by omitting `path` (null is rejected).
        try (try await transport.call("directoryPicker/list", args: path.map { ["path": .string($0)] } ?? [:]) ?? .null).decode(DirectoryListing.self)
    }

    /// Create `name` inside `path`; returns the new folder's path.
    public func createDirectory(in path: String, name: String) async throws -> String {
        guard let created = try await transport.call("directoryPicker/createDirectory", args: ["path": .string(path), "name": .string(name)])?.stringValue else {
            throw RemoteErrorPayload(message: "the host did not return the new folder")
        }
        return created
    }

    /// Run a slash command in a session (e.g. "/permission read-only").
    public func executeCommand(sessionId: String, line: String) async throws -> JSONValue? {
        try await transport.call("commands/execute", args: ["agentId": .string(sessionId), "line": .string(line), "submittedAttachments": []])
    }

    /// Edit a queued (inbox) message: `steer` now, or `remove` it.
    public func updateQueue(sessionId: String, itemId: String, action: String) async throws {
        _ = try await transport.call("session/updateQueue", args: ["request": [
            "sessionId": .string(sessionId), "itemId": .string(itemId), "action": ["kind": .string(action)],
        ]])
    }

    public func rename(sessionId: String, title: String) async throws {
        _ = try await transport.call("session/rename", args: ["request": ["sessionId": .string(sessionId), "title": .string(title)]])
    }

    /// Older history: events strictly before `beforeSeq`, up to `throughSeq` (the follow cursor).
    public func page(sessionId: String, throughSeq: Int, beforeSeq: Int, maxMessages: Int = 40) async throws -> (events: [SessionEvent], hasMore: Bool) {
        let value = try await transport.call("session/page", args: ["request": [
            "address": ["kind": "session", "sessionId": .string(sessionId)],
            "throughSeq": .number(Double(throughSeq)),
            "beforeSeq": .number(Double(beforeSeq)),
            "maxMessages": .number(Double(maxMessages)),
        ]]) ?? .null
        let events = (value["records"]?.arrayValue ?? []).compactMap { try? ($0["event"] ?? .null).decode(SessionEvent.self) }
        return (events, value["hasMore"]?.boolValue ?? false)
    }

    /// Workspaces as the Desktop sidebar groups them (baseline, then upserts).
    public func workspaces() async throws -> AsyncThrowingStream<JSONValue, any Error> {
        try await transport.stream("workspace/follow", args: [:])
    }

    /// Live view of one session: snapshot, then durable events and token stream.
    public func follow(sessionId: String, maxMessages: Int? = nil) async throws -> AsyncThrowingStream<SessionFollowFrame, any Error> {
        var request: [String: JSONValue] = [
            "address": ["kind": "session", "sessionId": .string(sessionId)],
            "assistantStream": true,
        ]
        if let maxMessages { request["maxMessages"] = .number(Double(maxMessages)) }
        let raw = try await transport.stream("session/follow", args: ["request": .object(request)])
        return raw.mapFrames { SessionFollowFrame($0) }
    }

    /// Projections for every session (`baseline`, then `projection` updates).
    public func control() async throws -> AsyncThrowingStream<JSONValue, any Error> {
        try await transport.stream("session/control", args: [:])
    }

    // MARK: Forwarded host events (approvals, questions, status)

    /// Opens one `$events` client generation. Its first frame is `.ready(clientId:)`;
    /// pending waterfalls are re-delivered to every new generation.
    public func events() async throws -> AsyncThrowingStream<RemoteEventFrame, any Error> {
        try await transport.stream("$events", args: [:]).mapFrames { RemoteEventFrame($0) }
    }

    /// Answer a waterfall. `clientId` must be the *current* `$events` generation.
    public func resolveEvent(clientId: String, eventId: String, outcome: RemoteEventOutcome) async throws {
        _ = try await transport.call(
            "$events/result",
            args: ["clientId": .string(clientId), "eventId": .string(eventId), "outcome": outcome.json]
        )
    }

    public func answerApproval(clientId: String, eventId: String, _ outcome: ApprovalOutcome) async throws {
        try await resolveEvent(clientId: clientId, eventId: eventId, outcome: .result(.string(outcome.rawValue)))
    }
}

extension AsyncThrowingStream where Element == JSONValue, Failure == any Error {
    func mapFrames<T: Sendable>(_ transform: @escaping @Sendable (JSONValue) -> T) -> AsyncThrowingStream<T, any Error> {
        let (stream, continuation) = AsyncThrowingStream<T, any Error>.makeStream()
        let task = Task {
            do {
                for try await value in self { continuation.yield(transform(value)) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
