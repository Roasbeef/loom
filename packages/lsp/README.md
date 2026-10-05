# lsp

`lsp` is Loom's client for the Language Server Protocol: it exchanges
JSON-RPC messages with a language server, decodes its answers, synchronizes
document text and collects diagnostics. A client actor owns one server
connection. Definitions, references, hover, outlines, rename edits and one
level of call hierarchy share that actor and its advertised capabilities.

The package owns the protocol, not server startup or filesystem authority.
[`codemode/lsp_host`](../codemode/src/codemode/lsp_host/manager.gleam) owns
project roots, document reads, server leases and the production transport over
the Broker's jailed execution. `client/lsp` loads and checks operator profiles.
Code-mode capabilities and filesystem diagnostics use the same manager;
the default tool registry exposes no separate `lsp_*` tools.

## How a request moves

The host supplies a `transport.ChannelTransport` and `client.Options` to
`client.start`. Startup sends `initialize`, checks the server's advertised
capabilities and position encoding, then sends `initialized`. The handshake
has a finite deadline. Only UTF-16 position encoding is accepted.

The host supplies document text through `client.sync`; the actor never reads
files. A semantic request first checks its advertised capability, then sends
one framed message and records its pending reply. `framing.push` reconstructs
whole UTF-8 bodies from arbitrary byte chunks before JSON-RPC decoding.
Protocol decoders convert the server's answer into the method's typed result.
`range.Position` remains in the server's zero-based UTF-16 coordinates;
`text` converts positions against the exact document text.

A request deadline removes its pending entry, sends `$/cancelRequest` and
drops a late answer. The client also withdraws a semantic request when its
reply owner dies. Protocol cancellation does not prove that a server stopped
computing. A framing fault, invalid JSON-RPC body or transport close settles
pending callers as unavailable and retires the connection.

`client.stop` sends `shutdown`, then `exit`, closes the transport and waits
within its retirement bound. Its `StopReport` distinguishes graceful exit,
forced exit, an already gone actor and unconfirmed retirement. The host owns
restart and the native process custody behind that transport.

## The APIs and modules

| Boundary | Main API |
|---|---|
| Client lifecycle | `client.options`, `start`, `capabilities`, `pid`, `stop`. |
| Semantic requests | `definition`, `references`, `hover`, `document_symbol`, `prepare_rename`, `rename` and call-hierarchy requests. |
| Document state | `sync`, `synced_text`, `open_paths`, `observation_state`. |
| Analysis state | `ready`, `settle`, `diagnostics`. |
| Host contracts | `query.Door` for interactive operations; `observation.Door` for finite collections. |

[`query`](src/lsp/query.gleam) defines the vocabulary used above the protocol:
symbol queries, sites, diagnostics and edit landing reports.
[`observation`](src/lsp/observation.gleam) separately describes a finite
collection under one configured server and root, with explicit outline files
and reference targets. An outline does not imply that references were collected
for its symbols. SQL over those collected facts runs in the code-mode satellite.

[`jsonrpc`](src/lsp/jsonrpc.gleam), [`framing`](src/lsp/framing.gleam) and
[`protocol`](src/lsp/protocol.gleam) are pure codecs. Framing refuses headers
over 8 KiB and declared bodies over 16 MiB before buffering the body.
[`text`](src/lsp/text.gleam) converts coordinates and applies text edits as
pure transformations. [`client`](src/lsp/client.gleam) is the
`weft/state_machine` actor over [`transport`](src/lsp/transport.gleam).
This package imports neither the Broker nor the MCP client library and adds
no foreign-function implementation.

## Diagnostics and edit authority

Readiness and diagnostic settlement answer different questions.
`client.ready` waits for a continuous window without active work-done progress
tokens, or returns `StillBusy` at its deadline. `client.settle` waits for the
document-symbol barrier where supported and, once a server has published
versioned diagnostics, publications at the changed documents' synced versions.
The host reports a lapsed settlement as `Unsettled`, never as clean code.
Retained server-reported project failures also remain visible when a semantic
reply is empty.

The client bounds its open documents at 64, stored publication URIs at 512 and
diagnostics per publication at 200. Language-server support still depends on
the selected server's advertised capabilities and behavior; a quiet server
with no progress reports is not a universal proof that indexing finished.

The protocol refuses `workspace/applyEdit` and resource operations in rename
edits. The host applies admitted text edits through Loom's hashline write path,
against the text used to compute them. Server installation, language profiles
and jail enforcement belong to host setup, described in the
[language-server guide](../../docs/language-servers.md).

## Testing

From the repository root:

```sh
make check-lsp
make lint-lsp
```

The package gate checks formatting, warning-free compilation and its tests.
The lint command runs the house rules. Codec tests cover split frames,
malformed envelopes, protocol answer variants, URI checks and UTF-16 edits.
Client tests use a scripted channel peer to exercise capability gating,
deadlines, server death, document versions, settlement, progress and shutdown.
These tests do not start a real language server in a jail; host and code-mode
integration checks cover that assembly.

## Reading further

- [`CLAUDE.md`](CLAUDE.md): package types, traffic and invariants.
- [Language-server architecture](../../docs/architecture/lsp.md): host admission,
  server leases, symbol resolution and edit landing.
- [ADR-015](../../docs/adr/015-language-servers-as-jailed-leases.md): jailed servers,
  measured settlement and the package boundary.
- [Finite LSP observations](../../docs/architecture/lsp-sql.md): collection bounds
  and satellite-local SQL.
- [Protocol 061](../../protocol-change/061-watch-and-lsp-reliability.md): readiness
  and reliability rules.
