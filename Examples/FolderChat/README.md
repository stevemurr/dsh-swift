# Folder Chat

A small native macOS app that uses only the public DSH Swift SDK. Choose a folder, send a message, and watch the agent's response stream into the conversation. Tool approvals offer **Allow Once** and **Deny**; **Stop** cancels agent activity on the host.

## Run

Requires macOS 15 or later, Swift 6, and a running local DSH host with its mobile bridge enabled. From the SDK repository root:

```sh
swift run --package-path Examples/FolderChat FolderChat
```

The app discovers the same authenticated local handoff as `DSHConnection()` (including `DSH_HOME` when set). It never asks for a model API key or implements an agent loop. If the connection is unavailable, start DSH and click **Reconnect**.

Choose a folder before sending the first message. The first **Send** creates a real session with that folder as its working directory; subsequent messages use the same session. **New Chat** starts another session lazily. Sending prompts can use the host's configured model and tools.

## How it works

- `FolderChatModel` owns one `DSHConnection`, a session ID, and cancellable observation tasks.
- `DSHClient.follow` feeds snapshots, durable events, and live assistant chunks into `Timeline`.
- `DSHClient.events` supplies approval requests. Decisions are scoped to the current event client ID and this app's session.
- Reconnect reopens both streams and restores the conversation from the host snapshot.
- `FolderChatView` renders the resulting items with SwiftUI. Native inline Markdown keeps the example free of third-party dependencies; a richer chat renderer can be substituted.

This is a deliberately small example: the session ID and drafts live in memory, and DSH continues owning session history after the window closes. Closing the app ends observation; use **Stop** first to stop an active turn. User-question forms, older-history paging, model selection, attachments, and automatic reconnection are left for a larger application.

To check the example without launching it or connecting to DSH:

```sh
swift build --package-path Examples/FolderChat
```
