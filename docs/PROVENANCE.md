# Source provenance

The initial wire models, session reducer, and HTTP/WebSocket client were adapted
from [stevemurr/dsh-ios](https://github.com/stevemurr/dsh-ios),
`ios/Packages/DSHKit`, at revision
`b1ab4932151b2091c2b526d3aae5dd7ff11496fb` (October 17, 2026), under the MIT license.
The copyright notice is preserved in [LICENSE](../LICENSE).

The standalone package targets macOS 15 and Swift 6 tooling. It includes
authentication isolation, stream cancellation and cleanup, safe connection setup,
and tests developed while integrating the client into Finder Drawer.

Relay transport, secure pairing, iOS UI, and the upstream recording executable
are outside this package. The DSH host supplies the agent harness and model
execution; this repository supplies client APIs and session presentation models.
