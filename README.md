# dsh-swift

A Swift SDK for building macOS apps powered by a local DSH agent host. Use typed
requests, live session streams, approvals, and a UI-independent conversation
reducer while DSH runs the agent, tools, and models.

The package builds independently, has no external dependencies, and contains no
Finder Drawer code. This first release supports **macOS 15+** with **Swift 6.0+**
tooling (Swift 5 language mode). iOS, Linux, remote relay, and secure pairing are
not supported by this release.

## Install

Add the package to your app's `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/stevemurr/dsh-swift.git", from: "0.1.0")
]
```

Add the products your target uses:

```swift
dependencies: [
    .product(name: "DSHKit", package: "dsh-swift"),
    .product(name: "DSHProtocol", package: "dsh-swift"),
    .product(name: "DSHSession", package: "dsh-swift")
]
```

| Module | Purpose |
| --- | --- |
| `DSHKit` | Connection discovery, authentication, typed RPCs, multiplexed WebSocket streams |
| `DSHProtocol` | Wire envelopes, JSON values, session models, approval outcomes |
| `DSHSession` | Pure conversation reducer, tool/diff presentation models, GenUI data models |

## Connect

Start your local DSH host with its local bridge enabled. The default connection
reads `~/.dsh/mobile/dev-auth.json`, or `$DSH_HOME/mobile/dev-auth.json` when
`DSH_HOME` is set. It exchanges the handoff token for an isolated session cookie.
The SDK does not install or start DSH.

```swift
import DSHKit

let connection = DSHConnection()
let connected = try await connection.connected()
let client = connected.client
let catalog = try await client.modelCatalog()

// Keep the connection for the lifetime of the app's DSH work.
// Disconnect when finished; this closes streams, not host sessions.
await connection.disconnect()
```

For an app-provided authenticated URL, call
`try await connection.configure(authenticatedURL: url)` before connecting. The
connection accepts HTTP(S) URLs for `localhost`, `127.0.0.1`, or `::1` with a
nonempty `token` query value. Explicit URLs stay in memory. Passing `nil` returns
to handoff-file discovery. A reconnect re-reads the handoff file.

`connected.identity` is a token-free origin identifier for distinguishing hosts.
Persist session IDs with that identity and your app's folder/workspace key. The
SDK does not choose session lifetimes or store app preferences.

For UI errors, prefer `DSHConnectionError.message(for: error)` to printing raw
host errors. Authenticated URLs, raw RPC payloads, and conversation recordings
can contain sensitive data. Optional `JSONLinesRecorder` captures wire content;
leave it disabled unless deliberately recording to a protected location.

A sandboxed app must arrange access to the handoff file or obtain an explicit
URL from the user, and enable outgoing network access. App sandbox entitlements
and file access remain the app's responsibility.

## Sessions, streaming, and Stop

Create a session with a host-side working directory, then retain its ID. A folder
companion can map each normalized folder to a session ID; a Quick Chat surface
can retain a separate ID.

```swift
let sessionID = try await client.createSession(cwd: "/path/to/project")
try await client.prompt(
    sessionId: sessionID,
    content: [.text("Explain the structure of this project.")]
)

// A Stop button cancels agent activity on the host.
try await client.cancel(sessionId: sessionID)
```

Open `follow` before prompting so the UI can render both committed messages and
in-flight text. Each follow stream begins with a snapshot; subsequent frames
update the same reducer:

```swift
import DSHSession

var timeline = Timeline()
let frames = try await client.follow(sessionId: sessionID, maxMessages: 40)
for try await frame in frames {
    switch frame {
    case .snapshot(let snapshot): timeline.reset(with: snapshot)
    case .event(let event): timeline.apply(event)
    case .assistantStream(let stream): timeline.apply(stream)
    case .unknown: break
    }
    // Publish timeline.items and timeline.live?.text to your UI.
}
```

The reducer keeps Markdown as text and separates reasoning, tools, approvals,
and notices. Choose a Markdown renderer in your app; the SDK has no UI or
Markdown-rendering dependency. `page` and `Timeline.prepend` support older history.

Cancel your observation tasks when a surface closes. This cancels their logical
streams; it does not stop an agent turn. On a connection failure, reconnect with
backoff and open fresh follow/events streams. The snapshot rebuilds the current
view. The SDK does not automatically retry prompts or other mutations.

## Approvals and questions

Maintain one `client.events()` subscription for the connection. Its `.ready`
frame supplies a `clientId` for that events generation. Route `.waterfall` frames
by `agentId` (the session ID), present `approval/request` to the user, and send
that user's choice with the **current** generation:

```swift
import DSHProtocol

// These values come from the active events stream and the user's choice.
try await client.answerApproval(
    clientId: currentClientID,
    eventId: pendingEventID,
    .allowedOnce  // or .rejected
)
```

Invalidate pending UI when the events stream ends or its generation changes,
and remove a request when `.cancel(eventId:)` arrives. Another connected client
may settle the same request; the first result wins. Never reuse a cached
`clientId` after reconnecting or automatically approve on receipt.

For `user-questions/request`, collect the user's answers and use
`resolveEvent(clientId:eventId:outcome:)` with the host's expected JSON result
shape. Other forwarded host requests are exposed as `JSONValue`; the SDK does
not invent or fill answers.

The [compiled SessionController example](Examples/ModelCatalog/Sources/ModelCatalog/SessionController.swift)
shows prompt/Stop, timeline reduction, task cleanup, and stale-approval guards.
It handles one session. An app with several sessions should share an events
subscription and route pending requests to the corresponding surface.

## Example macOS app

[Folder Chat](Examples/FolderChat) is a small SwiftUI app using the public SDK.
Choose a folder, send a message, watch the response stream, stop a turn, and
answer approvals. It creates a session on the first Send; sending prompts uses
your local host's configured agent and model.

From a checkout, with a local DSH host running:

```sh
swift run --package-path Examples/FolderChat FolderChat
```

See the [example README](Examples/FolderChat/README.md) for its behavior and scope.

## Read-only command-line example

To test connection setup without running an agent:

```sh
swift run --package-path Examples/ModelCatalog ModelCatalog
```

This reads the model catalog and disconnects. It creates no session and invokes
no model. The example uses a local package dependency so it can also verify
changes before release. Its separate manifest demonstrates that the library
builds without Finder Drawer.

## Development

```sh
swift test
swift build --package-path Examples/ModelCatalog
swift build --package-path Examples/FolderChat
```

CI tests the SDK and builds both independent consumers on macOS. Tests use synthetic payloads and local transports;
no DSH installation, credentials, model usage, or external service is required.
The wire model baseline is DSH `0.2.0-rc.2`, using the host's local HTTP API
and `/api/remote.mux` protocol. Pre-1.0 host changes may require an SDK update;
this is not a promise of compatibility with every host version.

See [source provenance](docs/PROVENANCE.md) for the original DSHKit source and
changes made for this standalone package. Licensed under [MIT](LICENSE).
