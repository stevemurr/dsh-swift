import DSHKit
import DSHProtocol
import DSHSession
import Foundation

/// Compiled integration sample. The command-line entry point does not run it.
/// A UI can observe this model and present each pending approval to the user.
@MainActor
final class SessionController {
    struct PendingApproval: Identifiable {
        let id: String
        let request: JSONValue
        fileprivate let clientID: String
        fileprivate let generation: UUID
    }

    private(set) var timeline = Timeline()
    private(set) var approvals: [String: PendingApproval] = [:]
    private(set) var lastError: String?

    let sessionID: String
    private let client: DSHClient
    private var generation = UUID()
    private var eventsClientID: String?
    private var followTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?

    init(client: DSHClient, sessionID: String) {
        self.client = client
        self.sessionID = sessionID
    }

    /// Re-establish both streams after a reconnect. The host supplies a fresh snapshot.
    func start() {
        close()
        let epoch = generation
        followTask = Task { [weak self, client, sessionID] in
            do {
                let frames = try await client.follow(sessionId: sessionID, maxMessages: 40)
                for try await frame in frames {
                    try Task.checkCancellation()
                    guard let self, self.generation == epoch else { return }
                    switch frame {
                    case .snapshot(let snapshot): self.timeline.reset(with: snapshot)
                    case .event(let event): self.timeline.apply(event)
                    case .assistantStream(let stream): self.timeline.apply(stream)
                    case .unknown: break
                    }
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == epoch else { return }
                self.lastError = DSHConnectionError.message(for: error)
            }
        }
        eventsTask = Task { [weak self, client, sessionID] in
            defer {
                if let self, self.generation == epoch {
                    self.eventsClientID = nil
                    self.approvals.removeAll()
                }
            }
            do {
                let frames = try await client.events()
                for try await frame in frames {
                    try Task.checkCancellation()
                    guard let self, self.generation == epoch else { return }
                    switch frame {
                    case .ready(let clientID, _):
                        self.eventsClientID = clientID.isEmpty ? nil : clientID
                        self.approvals.removeAll()
                    case .waterfall(let event, let eventID, let agentID, let request)
                        where event == "approval/request" && agentID == sessionID:
                        guard let clientID = self.eventsClientID else { continue }
                        self.approvals[eventID] = PendingApproval(
                            id: eventID, request: request, clientID: clientID, generation: epoch
                        )
                    case .cancel(let eventID): self.approvals.removeValue(forKey: eventID)
                    default: break
                    }
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == epoch else { return }
                self.lastError = DSHConnectionError.message(for: error)
            }
        }
    }

    func send(_ text: String) async throws {
        try await client.prompt(sessionId: sessionID, content: [.text(text)])
    }

    /// Stops agent activity on the host. Canceling a follow task alone does not.
    func stop() async throws {
        try await client.cancel(sessionId: sessionID)
    }

    /// Call only after the user has explicitly chosen an outcome.
    func answer(_ approval: PendingApproval, outcome: ApprovalOutcome) async throws {
        guard approval.generation == generation,
              approval.clientID == eventsClientID,
              approvals[approval.id]?.generation == approval.generation else { return }
        try await client.answerApproval(
            clientId: approval.clientID, eventId: approval.id, outcome
        )
        if approval.generation == generation { approvals.removeValue(forKey: approval.id) }
    }

    /// Ends observation, invalidates approval UI, and leaves the host session intact.
    /// Disconnect the owning DSHConnection when the app no longer needs its transport.
    func close() {
        generation = UUID()
        followTask?.cancel()
        eventsTask?.cancel()
        followTask = nil
        eventsTask = nil
        eventsClientID = nil
        approvals.removeAll()
    }
}
