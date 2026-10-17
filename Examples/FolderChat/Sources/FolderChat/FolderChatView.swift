import DSHSession
import SwiftUI

struct FolderChatView: View {
    @ObservedObject var chat: FolderChatModel

    var body: some View {
        VStack(spacing: 0) {
            folderBar
            Divider()
            conversation
            if let error = chat.errorMessage { errorBar(error) }
            ForEach(chat.approvals) { approval in approvalCard(approval) }
            Divider()
            composer
        }
        .background(.background)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Circle().fill(chat.isConnected ? .green : .secondary).frame(width: 6, height: 6)
                    Text("Folder Chat").font(.headline)
                }
            }
            ToolbarItem(placement: .automatic) {
                Button("New Chat", systemImage: "square.and.pencil", action: chat.newChat)
                    .disabled(!chat.canStartNewChat)
            }
        }
    }

    private var folderBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            TextField("Choose a folder on this Mac", text: $chat.folder)
                .textFieldStyle(.plain)
                .disabled(chat.sessionID != nil || chat.isConnecting || chat.isSubmitting)
            Button("Choose…", action: chat.chooseFolder)
                .disabled(chat.sessionID != nil || chat.isConnecting || chat.isSubmitting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(.bar)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if chat.timeline.items.isEmpty && chat.pendingPrompt == nil {
                        emptyState
                    }
                    ForEach(chat.timeline.items) { item in
                        TimelineRow(content: item.content)
                    }
                    if let pending = chat.pendingPrompt {
                        MessageRow(role: "You", symbol: "person.crop.circle", text: pending)
                            .opacity(0.65)
                    }
                    if let live = chat.timeline.live {
                        if !live.text.isEmpty {
                            MessageRow(role: "Assistant", symbol: "sparkles", text: live.text)
                        } else if chat.timeline.running {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(live.isCallingTool ? "Using a tool…" : "Thinking…").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: chat.timeline.items.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.timeline.live?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.pendingPrompt) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.gearshape").font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text("A companion for your folder").font(.title3.weight(.semibold))
            Text("Choose a folder, then ask DSH to explain, explore, or work on it.")
                .foregroundStyle(.secondary)
            Text("DSH must be running on this Mac. Your first message creates a session on the host.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 58)
    }

    private func errorBar(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            Button("Reconnect", action: chat.reconnect)
                .disabled(chat.isConnecting || chat.isSubmitting || chat.folder.isEmpty)
        }
        .padding(14)
        .background(.orange.opacity(0.08))
    }

    private func approvalCard(_ approval: FolderChatModel.Approval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Permission requested · \(approval.name)", systemImage: "hand.raised")
                .font(.callout.weight(.semibold))
            Text(approval.reason).font(.callout).textSelection(.enabled)
            DisclosureGroup("Tool details") {
                ScrollView {
                    Text(approval.request.compactDescription)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            HStack {
                Spacer()
                Button("Deny") { chat.answer(approval, outcome: .rejected) }
                Button("Allow Once") { chat.answer(approval, outcome: .allowedOnce) }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(chat.isAnswering || !chat.isConnected)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Ask about this folder…", text: $chat.draft, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .onSubmit { chat.send() }
            HStack {
                if chat.isConnecting || chat.isSubmitting { ProgressView().controlSize(.small) }
                Text(chat.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if chat.timeline.running || chat.isStopping {
                    Button(chat.isStopping ? "Stopping…" : "Stop", systemImage: "stop.fill", action: chat.stop)
                        .disabled(chat.isStopping || !chat.isConnected)
                }
                Button("Send", systemImage: "arrow.up", action: chat.send)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!chat.canSend)
            }
        }
        .padding(16)
    }
}

private struct TimelineRow: View {
    let content: TimelineContent

    @ViewBuilder var body: some View {
        switch content {
        case .user(let text, _):
            MessageRow(role: "You", symbol: "person.crop.circle", text: text)
        case .assistant(let markdown):
            MessageRow(role: "Assistant", symbol: "sparkles", text: markdown)
        case .reasoning(let text):
            DisclosureGroup("Reasoning") { Text(text).font(.callout).textSelection(.enabled) }
                .foregroundStyle(.secondary)
        case .tool(let tool):
            DisclosureGroup {
                Text(tool.arguments).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if let result = tool.result {
                    Text(result.text).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(result.isError ? .red : .secondary).textSelection(.enabled)
                }
            } label: {
                Label(tool.name + (tool.isRunning ? " · running" : ""), systemImage: "terminal")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .notice(let text, let isError):
            Text(text).font(.callout).foregroundStyle(isError ? .red : .secondary).textSelection(.enabled)
        case .command(let name, let output, let isError):
            DisclosureGroup(name) {
                Text(output ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }.foregroundStyle(isError ? .red : .secondary)
        case .subagent(let label, _):
            Label(label, systemImage: "person.2").font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct MessageRow: View {
    let role: String
    let symbol: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(role, systemImage: symbol).font(.callout.weight(.semibold))
            // Keep this example dependency-free. Production clients can replace
            // this native inline Markdown view with their preferred renderer.
            Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                 ?? AttributedString(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
