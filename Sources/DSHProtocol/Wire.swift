import Foundation

// Wire envelopes of the DSH host (verified against DSH 0.2.0-rc.2:
// dsh-client-connection, dsh-api-gateway `stream-protocol`).
//
// Every endpoint takes `payload: { args: { <wireName>: value } }` — wire names
// per endpoint are in protocol/dsh-<version>.json (`parameters[].wire`).

public typealias RemoteArgs = [String: JSONValue]

// MARK: Unary RPC — POST /api/<endpoint>

public struct ClientRequest: Encodable, Sendable {
    public let type = "client-request"
    public let rpcId: String
    public let method: String
    public let payload: Payload

    public struct Payload: Encodable, Sendable {
        public let args: RemoteArgs
    }

    public init(rpcId: String = UUID().uuidString.lowercased(), method: String, args: RemoteArgs) {
        self.rpcId = rpcId
        self.method = method
        self.payload = Payload(args: args)
    }
}

public struct ServerResponse: Decodable, Sendable {
    public let type: String
    public let rpcId: String
    public let result: RPCResult
}

public enum RPCResult: Decodable, Sendable {
    case ok(JSONValue?)
    case failure(RemoteErrorPayload)

    private enum CodingKeys: String, CodingKey { case ok, value, error }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .ok) {
            self = .ok(try container.decodeIfPresent(JSONValue.self, forKey: .value))
        } else {
            self = .failure(try container.decode(RemoteErrorPayload.self, forKey: .error))
        }
    }
}

public struct RemoteErrorPayload: Codable, Sendable, Error, CustomStringConvertible {
    public let code: String?
    public let name: String?
    public let message: String
    public let details: JSONValue?

    public init(code: String? = nil, name: String? = nil, message: String, details: JSONValue? = nil) {
        self.code = code
        self.name = name
        self.message = message
        self.details = details
    }

    public var description: String {
        "\(code ?? name ?? "error"): \(message)"
    }
}

// MARK: Logical streams — WebSocket /api/remote.mux

public enum MuxClientFrame: Encodable, Sendable {
    case open(streamId: String, endpoint: String, args: RemoteArgs)
    case item(streamId: String, value: JSONValue?)
    case end(streamId: String)
    case cancel(streamId: String)

    private enum CodingKeys: String, CodingKey { case type, streamId, endpoint, payload, value }
    private struct Payload: Encodable { let args: RemoteArgs }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .open(let streamId, let endpoint, let args):
            try container.encode("open", forKey: .type)
            try container.encode(streamId, forKey: .streamId)
            try container.encode(endpoint, forKey: .endpoint)
            try container.encode(Payload(args: args), forKey: .payload)
        case .item(let streamId, let value):
            try container.encode("item", forKey: .type)
            try container.encode(streamId, forKey: .streamId)
            try container.encodeIfPresent(value, forKey: .value)
        case .end(let streamId):
            try container.encode("end", forKey: .type)
            try container.encode(streamId, forKey: .streamId)
        case .cancel(let streamId):
            try container.encode("cancel", forKey: .type)
            try container.encode(streamId, forKey: .streamId)
        }
    }
}

public enum MuxServerFrame: Decodable, Sendable {
    case item(streamId: String, value: JSONValue?)
    case error(streamId: String, error: RemoteErrorPayload)
    case end(streamId: String)

    private enum CodingKeys: String, CodingKey { case type, streamId, value, error }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let streamId = try container.decode(String.self, forKey: .streamId)
        switch try container.decode(String.self, forKey: .type) {
        case "item": self = .item(streamId: streamId, value: try container.decodeIfPresent(JSONValue.self, forKey: .value))
        case "error": self = .error(streamId: streamId, error: try container.decode(RemoteErrorPayload.self, forKey: .error))
        case "end": self = .end(streamId: streamId)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown mux frame \(other)")
        }
    }

    public var streamId: String {
        switch self {
        case .item(let id, _), .error(let id, _), .end(let id): id
        }
    }
}

// MARK: Forwarded host events — the `$events` logical stream

public enum RemoteEventFrame: Sendable {
    /// First item of every `$events` generation. `clientId` scopes all results.
    case ready(clientId: String, home: String?)
    /// Fire-and-forget host event (`api-session/status`, …).
    case emit(event: String, args: [JSONValue])
    /// Pending host decision (`approval/request`, `user-questions/request`).
    /// Delivered to every client; the first `result` wins.
    case waterfall(event: String, eventId: String, agentId: String, request: JSONValue)
    /// The waterfall was settled (possibly by another client) or withdrawn.
    case cancel(eventId: String)
    case unknown(JSONValue)

    public init(_ value: JSONValue) {
        switch value["type"]?.stringValue {
        case "ready":
            self = .ready(clientId: value["clientId"]?.stringValue ?? "", home: value["host"]?["home"]?.stringValue)
        case "emit":
            self = .emit(event: value["event"]?.stringValue ?? "", args: value["args"]?.arrayValue ?? [])
        case "waterfall":
            self = .waterfall(
                event: value["event"]?.stringValue ?? "",
                eventId: value["eventId"]?.stringValue ?? "",
                agentId: value["agentId"]?.stringValue ?? "",
                request: value["request"] ?? .null
            )
        case "cancel":
            self = .cancel(eventId: value["eventId"]?.stringValue ?? "")
        default:
            self = .unknown(value)
        }
    }
}

/// Outcome sent through `POST /api/$events/result`.
public enum RemoteEventOutcome: Sendable {
    /// Settle the waterfall with this value (first result wins everywhere).
    case result(JSONValue?)
    /// Decline; falls through to the host's next handler only once every
    /// client has declined.
    case next
    /// Fail the waterfall with an error.
    case rejected(name: String, message: String)

    public var json: JSONValue {
        switch self {
        case .result(let value?): ["kind": "result", "value": value]
        case .result(nil): ["kind": "result"]
        case .next: ["kind": "next"]
        case .rejected(let name, let message): ["kind": "rejected", "error": ["name": .string(name), "message": .string(message)]]
        }
    }
}

public enum ApprovalOutcome: String, Sendable, CaseIterable {
    case allowedOnce = "allowed-once"
    case rejected
    case cancelled
    case unavailable
}
