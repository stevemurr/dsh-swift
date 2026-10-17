import AppKit
import DSHKit
import DSHProtocol
import DSHSession
import Foundation

/// Application state intentionally lives outside the SDK: a consumer chooses
/// its own persistence, reconnection policy and presentation.
@MainActor
final class FolderChatModel: ObservableObject {
    struct Approval: Identifiable {
        let id: String
        let request: JSONValue
        let clientID: String
        let generation: UUID
        var name: String { request["toolName"]?.stringValue ?? "Tool" }
        var reason: String {
            request["displayReason"]?["en"]?.stringValue
                ?? request["reason"]?.stringValue
                ?? "DSH would like permission to run this tool."
        }
    }

    @Published var folder = ""
    @Published var draft = ""
    @Published private(set) var timeline = Timeline()
    @Published private(set) var approvals: [Approval] = []
    @Published private(set) var status = "Choose a folder to get started"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSubmitting = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isStopping = false
    @Published private(set) var isAnswering = false
    @Published private(set) var isConnected = false
    @Published private(set) var pendingPrompt: String?
    @Published private(set) var sessionID: String?

    private let connection = DSHConnection()
    private var client: DSHClient?
    private var hostIdentity: String?
    private var generation = UUID()
    private var eventsClientID: String?
    private var pendingThroughSeq = -1
    private var followTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?

    var canSend: Bool {
        !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSubmitting && !isConnecting && !timeline.running && pendingPrompt == nil
    }

    var canStartNewChat: Bool {
        !isSubmitting && !isConnecting && !timeline.running && !isStopping && !isAnswering && approvals.isEmpty && pendingPrompt == nil
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        errorMessage = nil
        isSubmitting = true
        pendingPrompt = text
        pendingThroughSeq = timeline.cursor
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isSubmitting = false }
            do {
                if !self.isConnected { try await self.connect() }
                try Task.checkCancellation()
                guard let client = self.client, let sessionID = self.sessionID else { return }
                self.pendingThroughSeq = self.timeline.cursor
                try await client.prompt(sessionId: sessionID, content: [.text(text)])
                self.status = "Working in \(self.folderName)"
            } catch is CancellationError {
            } catch {
                self.pendingPrompt = nil
                // Keep the unsent prompt available even if a new draft was typed.
                self.draft = self.draft.isEmpty ? text : text + "\n\n" + self.draft
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    func reconnect() {
        guard !isConnecting, !isSubmitting else { return }
        errorMessage = nil
        actionTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.connect() }
            catch is CancellationError {}
            catch { self.errorMessage = Self.message(for: error) }
        }
    }

    private func connect() async throws {
        isConnecting = true
        defer { isConnecting = false }
        status = "Connecting to DSH…"
        endObservation()
        let epoch = generation
        do {
            try await establishObservation(generation: epoch)
        } catch {
            if generation == epoch {
                endObservation()
                await connection.disconnect()
            }
            throw error
        }
    }

    private func establishObservation(generation epoch: UUID) async throws {
        await connection.disconnect() // Refresh a stale handoff or expired authentication on reconnect.
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
        let connected = try await connection.connected()
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
        if let previous = hostIdentity, previous != connected.identity {
            sessionID = nil
            timeline = Timeline()
            pendingThroughSeq = -1
        }
        client = connected.client
        hostIdentity = connected.identity
        if sessionID == nil {
            let path = (folder.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
                throw ExampleError.invalidFolder
            }
            folder = url.path
            let createdID = try await connected.client.createSession(cwd: url.path)
            try Task.checkCancellation()
            guard generation == epoch else { throw CancellationError() }
            sessionID = createdID
        }
        guard let sessionID else { throw CancellationError() }

        // Wait for the baseline and the current event generation before sending
        // a prompt, so fast responses and approvals cannot beat subscription.
        var follow = try await connected.client.follow(sessionId: sessionID).makeAsyncIterator()
        guard let baseline = try await follow.next() else { throw ExampleError.streamEnded }
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
        apply(baseline)
        var events = try await connected.client.events().makeAsyncIterator()
        var ready = false
        while let frame = try await events.next() {
            try Task.checkCancellation()
            guard generation == epoch else { throw CancellationError() }
            handle(frame, generation: epoch)
            if eventsClientID != nil { ready = true; break }
        }
        guard ready else { throw ExampleError.streamEnded }
        isConnected = true
        status = "Connected · \(folderName)"

        followTask = Task { [weak self] in
            do {
                while let frame = try await follow.next() {
                    try Task.checkCancellation()
                    guard let self, self.generation == epoch else { return }
                    self.apply(frame)
                }
                throw ExampleError.streamEnded
            } catch is CancellationError {
            } catch {
                self?.streamFailed(error, generation: epoch)
            }
        }
        eventsTask = Task { [weak self] in
            do {
                while let frame = try await events.next() {
                    try Task.checkCancellation()
                    guard let self, self.generation == epoch else { return }
                    self.handle(frame, generation: epoch)
                }
                throw ExampleError.streamEnded
            } catch is CancellationError {
            } catch {
                self?.streamFailed(error, generation: epoch)
            }
        }
    }

    private func apply(_ frame: SessionFollowFrame) {
        switch frame {
        case .snapshot(let value): timeline.reset(with: value)
        case .event(let value): timeline.apply(value)
        case .assistantStream(let value): timeline.apply(value)
        case .unknown: break
        }
        if (!isConnecting || !isSubmitting), let pendingPrompt, timeline.items.contains(where: { item in
            guard item.seq > pendingThroughSeq, case .user(let text, _) = item.content else { return false }
            return text == pendingPrompt
        }) {
            self.pendingPrompt = nil
        }
        if !isSubmitting { status = timeline.running ? "Working in \(folderName)" : "Connected · \(folderName)" }
    }

    private func handle(_ frame: RemoteEventFrame, generation epoch: UUID) {
        switch frame {
        case .ready(let clientID, _):
            eventsClientID = clientID.isEmpty ? nil : clientID
            approvals.removeAll()
        case .waterfall(let event, let eventID, let agentID, let request)
            where agentID == sessionID && event == "approval/request":
            guard let eventsClientID else { return }
            approvals.removeAll { $0.id == eventID }
            approvals.append(Approval(id: eventID, request: request, clientID: eventsClientID, generation: epoch))
        case .cancel(let eventID): approvals.removeAll { $0.id == eventID }
        default: break
        }
    }

    func answer(_ approval: Approval, outcome: ApprovalOutcome) {
        guard !isAnswering, approval.generation == generation,
              approval.clientID == eventsClientID,
              approvals.contains(where: { $0.id == approval.id }), let client else { return }
        isAnswering = true
        Task { [weak self] in
            defer { self?.isAnswering = false }
            do {
                try await client.answerApproval(clientId: approval.clientID, eventId: approval.id, outcome)
                guard let self, self.generation == approval.generation else { return }
                self.approvals.removeAll { $0.id == approval.id }
            } catch {
                guard let self, self.generation == approval.generation else { return }
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    func stop() {
        guard !isStopping, let client, let sessionID else { return }
        isStopping = true
        Task { [weak self] in
            defer { self?.isStopping = false }
            do { try await client.cancel(sessionId: sessionID) }
            catch { self?.errorMessage = Self.message(for: error) }
        }
    }

    func newChat() {
        guard canStartNewChat else { return }
        endObservation()
        sessionID = nil
        timeline = Timeline()
        pendingPrompt = nil
        errorMessage = nil
        status = "Ready for a new conversation"
    }

    func close() {
        actionTask?.cancel()
        endObservation()
        Task { await connection.disconnect() }
    }

    private func streamFailed(_ error: any Error, generation epoch: UUID) {
        guard generation == epoch else { return }
        endObservation()
        status = "Disconnected"
        errorMessage = Self.message(for: error)
    }

    private func endObservation() {
        generation = UUID()
        followTask?.cancel()
        eventsTask?.cancel()
        followTask = nil
        eventsTask = nil
        eventsClientID = nil
        approvals.removeAll()
        isConnected = false
    }

    private var folderName: String { URL(fileURLWithPath: folder).lastPathComponent }

    private static func message(for error: any Error) -> String {
        if let error = error as? ExampleError { return error.localizedDescription }
        return DSHConnectionError.message(for: error)
    }

    private enum ExampleError: LocalizedError {
        case invalidFolder, streamEnded
        var errorDescription: String? {
            switch self {
            case .invalidFolder: "Choose an existing folder on this Mac."
            case .streamEnded: "The DSH stream closed. Reconnect to resume this conversation."
            }
        }
    }
}
