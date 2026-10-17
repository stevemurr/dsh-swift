import Foundation

// Session API models (dsh-api-session-controller). Only the fields the app
// renders are typed; everything else stays `JSONValue`.

public struct SessionListValue: Decodable, Sendable {
    public let items: [SessionSummary]
}

public struct SessionSummary: Decodable, Sendable, Identifiable {
    public let sessionId: String
    public let updatedAt: Double
    public let running: Bool
    public let blank: Bool
    public let agentAvailable: Bool?
    public let parentSessionId: String?
    public let origin: String?
    public let cwd: String?
    public let projections: Projections?

    public var id: String { sessionId }
    public var title: String? { projections?.values["title"]?.stringValue }

    public struct Projections: Decodable, Sendable {
        public let kind: String?
        public let asOfSeq: Double
        public let values: JSONValue
    }
}

/// One durable session-log record (`user/message`, `tool/call`, `approval/decided`, …).
public struct SessionEvent: Codable, Sendable {
    public let type: String
    public let seq: Int
    public let time: Double
    public let data: JSONValue?
}

/// Frames of the `session/follow` stream.
public enum SessionFollowFrame: Sendable {
    case snapshot(SessionSnapshot)
    case event(SessionEvent)
    case assistantStream(AssistantStreamFrame)
    case unknown(JSONValue)

    public init(_ value: JSONValue) {
        do {
            switch value["type"]?.stringValue {
            case "snapshot": self = .snapshot(try value.decode(SessionSnapshot.self))
            case "event": self = .event(try (value["event"] ?? .null).decode(SessionEvent.self))
            case "assistant-stream": self = .assistantStream(AssistantStreamFrame(value["frame"] ?? .null))
            default: self = .unknown(value)
            }
        } catch {
            self = .unknown(value)
        }
    }
}

public struct SessionSnapshot: Decodable, Sendable {
    public let header: JSONValue
    public let cursor: Int
    public let records: [Record]
    public let hasMore: Bool
    public let projections: JSONValue
    public let assistantStream: JSONValue?

    public struct Record: Decodable, Sendable {
        public let type: String
        public let event: SessionEvent
    }
}

public enum AssistantStreamFrame: Sendable {
    case start(attemptId: String, turn: Int, step: Int)
    case chunk(attemptId: String, index: Int, chunk: JSONValue)
    /// `committedSeq` is the durable `assistant/message` seq replacing the live stream.
    case end(attemptId: String, committedSeq: Int?)
    case unknown(JSONValue)

    public init(_ value: JSONValue) {
        let attemptId = value["attemptId"]?.stringValue ?? ""
        switch value["type"]?.stringValue {
        case "start": self = .start(attemptId: attemptId, turn: value["turn"]?.intValue ?? 0, step: value["step"]?.intValue ?? 0)
        case "chunk": self = .chunk(attemptId: attemptId, index: value["index"]?.intValue ?? 0, chunk: value["chunk"] ?? .null)
        case "end": self = .end(attemptId: attemptId, committedSeq: value["outcome"]?["seq"]?.intValue)
        default: self = .unknown(value)
        }
    }
}

// MARK: Requests

public enum PromptMode: String, Sendable {
    case queue
    case steer
}

public enum PromptContent: Sendable {
    case text(String)
    case image(mediaType: String, base64: String, name: String?)
    case file(receiptId: String)

    public var json: JSONValue {
        switch self {
        case .text(let text): ["type": "text", "text": .string(text)]
        case .image(let mediaType, let data, let name?):
            ["type": "image", "mediaType": .string(mediaType), "data": .string(data), "name": .string(name)]
        case .image(let mediaType, let data, nil):
            ["type": "image", "mediaType": .string(mediaType), "data": .string(data)]
        case .file(let receiptId): ["type": "file", "receiptId": .string(receiptId)]
        }
    }
}

// MARK: Models

public struct ModelCatalog: Decodable, Sendable, Equatable {
    public struct Selection: Codable, Sendable, Equatable, Hashable {
        public let provider: String
        public let model: String
        public let reasoningEffort: String?

        public init(provider: String, model: String, reasoningEffort: String?) {
            self.provider = provider
            self.model = model
            self.reasoningEffort = reasoningEffort
        }
    }

    public struct Group: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let models: [Model]
    }

    public struct Model: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let reasoning: Reasoning?
    }

    public struct Reasoning: Decodable, Sendable, Equatable {
        public let defaultEffort: String?
        public let efforts: [Effort]
    }

    public struct Effort: Decodable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let description: String?
    }

    public let `default`: Selection?
    public let groups: [Group]

    public func model(_ selection: Selection) -> Model? {
        groups.first { $0.id == selection.provider }?.models.first { $0.id == selection.model }
    }
}

public struct Workspace: Decodable, Sendable, Equatable, Identifiable {
    public let workspaceId: String
    public let path: String
    public let title: String
    public let sessionIds: [String]
    public var id: String { workspaceId }
}

/// `directoryPicker/list` — folders on the host, for choosing a workspace.
public struct DirectoryListing: Decodable, Sendable, Equatable {
    public struct Entry: Decodable, Sendable, Equatable, Identifiable, Hashable {
        public let name: String
        public let path: String
        public let hidden: Bool
        public var id: String { path }
    }

    public let path: String
    public let home: String
    public let crumbs: [Entry]
    public let entries: [Entry]
    public let truncated: Bool
}

/// A session goal (`goal` projection): an objective the agent works toward
/// over multiple rounds.
public struct SessionGoal: Decodable, Sendable, Equatable {
    public enum Phase: String, Decodable, Sendable { case active, paused, blocked, complete }

    public struct Goal: Decodable, Sendable, Equatable {
        public let id: String
        public let revision: Int
        public let objective: String
        public let phase: Phase
        public let maxGoalRounds: Int
        public let blockedReason: BlockedReason?
    }

    public struct BlockedReason: Decodable, Sendable, Equatable {
        public let code: String
        public let message: String
    }

    public let goal: Goal
    public let roundsStarted: Int
    public let createdAt: Double
    public let updatedAt: Double
}
