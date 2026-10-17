import Foundation

/// One authenticated host snapshot. Session IDs are scoped to `identity`,
/// preventing a persisted conversation from reaching a different DSH server.
public struct DSHConnectedClient: Sendable {
    public let client: DSHClient
    public let identity: String

    public init(client: DSHClient, identity: String) {
        self.client = client
        self.identity = identity
    }
}

/// Supplies an atomic client/origin snapshot. Implement this protocol to inject
/// a custom connection or a test double into an application.
public protocol DSHConnecting: Sendable {
    func connected() async throws -> DSHConnectedClient
    func disconnect() async
}

public extension DSHConnecting {
    func client() async throws -> DSHClient { try await connected().client }
    func identity() async throws -> String { try await connected().identity }
}

public enum DSHConnectionError: Error, LocalizedError, Sendable, Equatable {
    case handoffUnavailable
    case invalidHandoff
    case invalidURL
    case nonLocalURL
    case authenticationFailed
    case unavailable
    case reconfigured

    public var userFacingMessage: String {
        switch self {
        case .handoffUnavailable:
            return "Automatic connection is unavailable. Start DSH Desktop, or provide its authenticated local connection URL."
        case .invalidHandoff:
            return "DSH’s local connection file is invalid. Restart DSH to refresh it, or enter a fresh authenticated local URL."
        case .invalidURL:
            return "Use the complete connection link provided by DSH Desktop."
        case .nonLocalURL:
            return "Automatic DSH connections are limited to this Mac. Use an HTTP or HTTPS URL on localhost, 127.0.0.1, or ::1."
        case .authenticationFailed:
            return "DSH rejected this connection. Obtain a fresh authenticated URL or restart DSH to refresh its local connection file."
        case .unavailable:
            return "Couldn’t reach DSH. Make sure it is running on this Mac, then reconnect."
        case .reconfigured:
            return "The DSH connection changed. Reconnect this conversation to continue."
        }
    }

    public var errorDescription: String? { userFacingMessage }

    /// Server bodies, token URLs, cookies and URLSession diagnostics can
    /// contain credentials or transcript data. Keep connection errors categorical.
    public static func message(for error: any Error) -> String {
        if let error = error as? Self { return error.userFacingMessage }
        if let error = error as? TransportError {
            switch error {
            case .authentication: return Self.authenticationFailed.userFacingMessage
            case .http(let status, _) where status == 401 || status == 403:
                return Self.authenticationFailed.userFacingMessage
            case .http(let status, _): return "DSH returned HTTP \(status). Check that DSH is up to date, then reconnect."
            case .unsupportedResponse: return "DSH returned an unsupported response. Check that DSH is up to date, then reconnect."
            case .invalidRequest: return "This DSH request isn’t supported. Check that DSH is up to date."
            case .disconnected: return Self.unavailable.userFacingMessage
            }
        }
        if error is CancellationError { return "The DSH operation was cancelled." }
        return Self.unavailable.userFacingMessage
    }
}

/// Discovers the existing bridge handoff or accepts a token URL held only in
/// memory. A single ephemeral transport can serve multiple independent sessions.
/// Call `disconnect()` when the owning application no longer needs the connection.
public actor DSHConnection: DSHConnecting {
    private struct Resolved: Sendable {
        let transport: LoopbackTransport
        let identity: String
        var snapshot: DSHConnectedClient {
            DSHConnectedClient(client: DSHClient(transport: transport), identity: identity)
        }
    }

    private struct Pending {
        let id: UUID
        let task: Task<Resolved, any Error>
    }

    private let handoffURL: URL
    private let exchange: @Sendable (URL) async throws -> HostCredentials
    private var explicitURL: URL?
    private var resolved: Resolved?
    private var pending: Pending?
    private var generation = UUID()

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let configuredHome = environment["DSH_HOME"].flatMap { value -> URL? in
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        handoffURL = (configuredHome ?? homeDirectory.appending(path: ".dsh", directoryHint: .isDirectory))
            .appending(path: "mobile/dev-auth.json")
        exchange = { try await HostCredentials.exchange(authenticatedURL: $0) }
    }

    // Dependency seam for deterministic authentication/lifecycle tests.
    init(handoffURL: URL, exchange: @escaping @Sendable (URL) async throws -> HostCredentials) {
        self.handoffURL = handoffURL
        self.exchange = exchange
    }

    /// Passing nil restores automatic bridge discovery. No token or cookie is
    /// written to preferences, the app’s database, or logs.
    public func configure(authenticatedURL: URL?) async throws {
        if let authenticatedURL { _ = try Self.validate(authenticatedURL) }
        explicitURL = authenticatedURL
        await disconnect()
    }

    public func client() async throws -> DSHClient { try await connected().client }
    public func identity() async throws -> String { try await connected().identity }

    public func connected() async throws -> DSHConnectedClient {
        if let resolved { return resolved.snapshot }
        let currentGeneration = generation
        let attempt: Pending
        if let pending {
            attempt = pending
        } else {
            let handoffURL = self.handoffURL
            let explicitURL = self.explicitURL
            let exchange = self.exchange
            let task = Task {
                let authenticatedURL = try explicitURL ?? Self.readHandoff(at: handoffURL)
                let identity = try Self.validate(authenticatedURL)
                let credentials: HostCredentials
                do {
                    credentials = try await exchange(authenticatedURL)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as TransportError {
                    if case .authentication = error { throw DSHConnectionError.authenticationFailed }
                    throw DSHConnectionError.unavailable
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    throw DSHConnectionError.unavailable
                }
                try Task.checkCancellation()
                return Resolved(transport: LoopbackTransport(credentials: credentials), identity: identity)
            }
            attempt = Pending(id: UUID(), task: task)
            pending = attempt
        }
        do {
            let value = try await attempt.task.value
            guard currentGeneration == generation else {
                await value.transport.disconnect()
                throw DSHConnectionError.reconfigured
            }
            if pending?.id == attempt.id { pending = nil }
            resolved = value
            return value.snapshot
        } catch {
            if currentGeneration == generation, pending?.id == attempt.id { pending = nil }
            throw error
        }
    }

    public func disconnect() async {
        generation = UUID()
        pending?.task.cancel()
        pending = nil
        let transport = resolved?.transport
        resolved = nil
        await transport?.disconnect()
    }

    /// Canonical origin, including the effective port. Deliberately excludes
    /// token, path, user info and fragments, and does not resolve hostnames.
    static func validate(_ url: URL) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased(),
              components.queryItems?.contains(where: { $0.name == "token" && !($0.value ?? "").isEmpty }) == true else {
            throw DSHConnectionError.invalidURL
        }
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard ["localhost", "127.0.0.1", "::1"].contains(normalizedHost) else {
            throw DSHConnectionError.nonLocalURL
        }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { throw DSHConnectionError.invalidURL }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = normalizedHost == "::1" ? "[::1]" : normalizedHost
        origin.port = port
        guard let identity = origin.url?.absoluteString else { throw DSHConnectionError.invalidURL }
        return identity
    }

    static func readHandoff(at url: URL) throws -> URL {
        struct Handoff: Decodable { let schemaVersion: Int; let url: String; let baseUrl: String? }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= 65_536,
              let data = try? Data(contentsOf: url), data.count <= 65_536 else {
            throw DSHConnectionError.handoffUnavailable
        }
        guard let handoff = try? JSONDecoder().decode(Handoff.self, from: data),
              handoff.schemaVersion == 1, let authenticatedURL = URL(string: handoff.url) else {
            throw DSHConnectionError.invalidHandoff
        }
        do {
            let identity = try validate(authenticatedURL)
            if let rawBase = handoff.baseUrl {
                guard var base = URLComponents(string: rawBase) else { throw DSHConnectionError.invalidHandoff }
                base.queryItems = [URLQueryItem(name: "token", value: "validation-only")]
                guard let baseURL = base.url, try validate(baseURL) == identity else {
                    throw DSHConnectionError.invalidHandoff
                }
            }
        } catch {
            throw DSHConnectionError.invalidHandoff
        }
        return authenticatedURL
    }
}
