import DSHProtocol
import Foundation

/// The two primitives every DSH client needs. `LoopbackTransport` implements
/// them over the host's HTTP API and `/api/remote.mux` with cookie authentication.
/// Applications may supply another transport using the same wire envelopes.
public protocol DSHTransport: Sendable {
    /// Unary RPC. Returns the `value` of an ok result.
    func call(_ endpoint: String, args: RemoteArgs) async throws -> JSONValue?
    /// Open a logical stream. Terminating the consumer cancels the stream.
    func stream(_ endpoint: String, args: RemoteArgs) async throws -> AsyncThrowingStream<JSONValue, any Error>
}

public enum TransportError: Error, CustomStringConvertible, LocalizedError {
    case invalidRequest
    case http(status: Int, body: String)
    case unsupportedResponse(contentType: String)
    case disconnected(String)
    case authentication(String)

    public var description: String {
        switch self {
        case .invalidRequest: "The DSH request is invalid."
        case .http(let status, _): "DSH returned HTTP \(status)."
        case .unsupportedResponse: "DSH returned an unsupported response format."
        case .disconnected: "The DSH connection was interrupted."
        case .authentication: "DSH authentication failed. Obtain a fresh authenticated URL."
        }
    }

    public var errorDescription: String? { description }
}

/// Optional tap for wire frames. Recording is disabled unless explicitly supplied.
/// Frames can contain conversation text, tool arguments, and private file content.
public protocol FrameRecorder: Sendable {
    func record(direction: FrameDirection, channel: String, text: String) async
}

public enum FrameDirection: String, Sendable {
    case send
    case receive
}

/// Appends frames as JSON Lines: `{"t":…,"dir":"send","channel":"rpc:session/list","frame":{…}}`.
public actor JSONLinesRecorder: FrameRecorder {
    private let handle: FileHandle

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    public func record(direction: FrameDirection, channel: String, text: String) {
        let frame = (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
        let line: JSONValue = [
            "t": .number(Date().timeIntervalSince1970),
            "dir": .string(direction.rawValue),
            "channel": .string(channel),
            "frame": frame,
        ]
        handle.write(Data((line.compactDescription + "\n").utf8))
    }
}
