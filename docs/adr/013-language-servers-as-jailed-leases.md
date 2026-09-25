# ADR-013: language servers run as jailed session leases behind a shared peer seam

**Status**: proposed · **Date**: 2026-09-25 · **Supersedes**: nothing ·
**Spec ref**: Part 2 WP-I ("Later in M5: `lsp_*` — client over stdio port,
per-project supervised, sandboxed"), Part 1.4 (data-plane framing) ·
**Issue**: #25

## The question

The agent edits by hashline anchor and finds symbols by grep. It has no
semantic view of the code: no definition, no references, no rename, no
compiler diagnostics after an edit. `cap/lsp` has shipped in the prelude
since WP-J with nothing behind it, and the router refuses all four of its
names as `unsupported_cap`.

A language server is not a command. It is a long-lived process that speaks
JSON-RPC over its stdin and stdout, keeps a model of every open document,
sends requests of its own that must be answered, and publishes diagnostics
whenever it likes. `proc.run` cannot carry it. The real questions are six,
and they are not independent:

1. Where does the server process run, and under what policy?
2. Where does the protocol code live, given that MCP already carries a
   JSON-RPC client and DAP (#26) will want the same transport?
3. How does the server learn about edits the agent makes?
4. How does a rename land, given that `fs_edit` is the only write path with
   a concurrency check?
5. What does the model actually address — a position, or a symbol?
6. How does the model reach it: a tool, a capability, or both?

## Measured before deciding

`gleam lsp` 1.18.1, driven over stdio against a two-module project
(2026-09-25):

- **Advertised**: definition, typeDefinition, references, hover,
  documentSymbol, documentHighlight, rename (with prepare), formatting,
  code actions, completion, signature help, folding. Full-text sync
  (`change: 1`), open/close, save without text.
- **Not advertised**: `workspace/symbol`, call hierarchy, and no
  `positionEncoding` in the result, so UTF-16 applies.
- **An unadvertised request is never answered.** `workspace/symbol` sat
  unanswered past a 30-second wait. The client must gate every request on
  the server's advertised capabilities, and every request carries a
  deadline regardless.
- **Latency**: references, documentSymbol, hover and rename each answered
  in under 30 ms on a warm project.
- **Diagnostics carry no `version`** even when the client advertises
  `versionSupport`. "Diagnostics for document version N" cannot be waited
  for; only "the next publication for this URI after my change" can.
- **Rename answers with `changes`**, not `documentChanges`, and never with a
  file operation.
- **The server writes into the project**: `manifest.toml` at the root and
  lock files and caches under `build/`. It announced "Downloading Gleam
  dependencies" through `window/workDoneProgress/create` and `$/progress`.
  The project root must be writable, and a server with network access off
  needs `build/packages` already present.

## Decision

### 1. The server is a jailed exec, cleared like an extension host

A language server runs arbitrary project code in effect: build scripts,
macros, proc-macros, a toolchain the model can edit. Rule Zero puts it in the
jail. The MCP port transport (unjailed `open_port`) is not the model; it is
the open decision recorded against #109.

The broker's ordinary jailed exec already fits, and needs no new frame, no
helper change and no protocol change. `broker.clear_call` streams stdout and
stderr as `CallOutput` chunks and accepts stdin through `broker.stdin`. It is
exactly as long-lived as its budget allows. Extension hosts are the
precedent: one jailed node per extension, cleared once, living for the
session.

- **Policy.** Requirements: the project root writable (the server writes
  there — measured above); the located toolchain's install prefix mounted
  read-only, found the way code mode finds it (`client/codemode.locate`,
  `install_prefix`); network off, with `RefuseNarrowed`; `env_allow` PATH,
  HOME and TMPDIR, with TMPDIR pinned under the writable root because the
  jail replaces `/tmp`. **The base policy has `wall_s`, `cpu_s` and
  `output_bytes` set to zero**, the `session_lived` shape extensions use,
  extended by `output_bytes`. Limits compose by meet, where zero is
  unlimited and otherwise the smaller wins, so zeroing only the requirements
  would leave a server that goes mute after 4 MiB of output or is killed
  after five CPU-minutes.
- **Identity.** One session-scoped attribution operation for language
  servers, and a step per server, `lsp/<server>/<root-digest>`. Nothing about
  a model operation's abort reaches it. Stopping a server is `shutdown` →
  `exit` → stdin EOF, then `broker.cancel` as the backstop, and the
  `exec_exit` settlement is the retirement witness.
- **Lifetime.** The budget deadline is a lease: twelve hours, like extension
  hosts. The effects plane deliberately offers no renewal. A settled server
  is restarted on next use, and its open documents are re-sent.
- **Demand.** `exec.PlatformEnforcement`. Full enforcement always fails on
  Darwin.
- **Pool pressure.** Each live server holds one exec helper for its whole
  life, and the pool is sized for bash and code mode. At most **two**
  language servers run concurrently per session. A third project evicts the
  least recently used. That is a documented bound with a test, not a knob.
- **`truncated: True` on an output chunk is transport-fatal.** With
  `output_bytes` zeroed it should never happen. If it does, the stream is
  no longer a JSON-RPC stream.

Known hazard, not fixed here: the helper writes stdin synchronously inside
its frame loop, so a server that stops reading while its stdin pipe is full
blocks cancel until the broker's three-second helper kill. That recovers, it
is bounded, and it is recorded for the helper's owners rather than widened
into this change.

### 2. `packages/peer` holds the shared seam; `packages/lsp` holds the protocol

The JSON-RPC envelope, the transport seam, the port FFI and the monitored
call helper in `packages/mcp` know nothing about MCP. LSP needs all of them.
DAP needs the transport and a Content-Length framer but not JSON-RPC, because
DAP's envelope is its own. Three consumers of one seam is the argument for a
package:

- **`packages/peer`**: `peer/jsonrpc` (moved from `mcp/jsonrpc`, gaining
  `response` and `error_response` encoders, which the MCP client currently
  builds by hand), `peer/transport` plus `peer/internal/ffi_port` and
  `peer_ffi.erl` (moved; error text names the peer through a label instead of
  saying "mcp server"), `peer/call.exchange` (the monitored try-call `mcp/client`
  copies), and `peer/content_length`, a new pure framer shared by LSP and DAP.
  `mcp/stdio`'s newline framing stays in `mcp`, because MCP alone uses it.
- **`packages/lsp`**: the protocol, meaning total decoders and encoders for
  every LSP structure consumed, position-encoding conversion and text-edit
  application, all pure. It also holds the client actor, a weft state machine
  over `peer/transport.Transport`. It never imports `broker`. The production
  transport, a `ChannelTransport` over `clear_call`, is built in `client`,
  which already depends on the broker. `mcp` gets the same adapter for #109
  if that decision goes the jail's way.

The move is a separate, behaviour-preserving commit, with `make check-mcp`
and `make check-client` green on it before any LSP code lands.

### 3. The server's view is kept honest on two paths

- **Push**: `fs_write`, `fs_edit`, code mode's `fs.write`/`fs.edit`, and
  rename each report a successful write to an observer. That observer sends a
  full-text `didChange`, or `didOpen` if the document is not yet open, to
  the server owning that file.
- **Pull**: before every query, the client re-reads every document it holds
  open and sends a `didChange` for each whose digest moved. This catches
  `bash`, jobs and anything else that writes behind the harness's back. A
  document the server never opened is read from disk by the server itself.

Open documents are bounded (64 per server, LRU `didClose`), so the pull costs
at most 64 reads, each against the large-file guard.

### 4. Rename lands through the hashline path, or not at all

The server computes a `WorkspaceEdit`. It never writes, and a
`workspace/applyEdit` request from the server is answered `applied: false`.
For each file, the harness takes the text the server's answer was computed
against. It applies the edits in pure code (converting UTF-16 positions), and
turns the result into a hashline `Plan` whose digest is that base text's.
Every file's digest is checked before any file is written. The writes then go
through the same resolve, `hashline.apply` and write path `fs_edit` uses,
factored out of `run_edit` as a shared helper. A concurrent modification
between the server's view and the write therefore rejects as `StaleContent`,
exactly as a stale `fs_edit` does. Resource operations (create, rename,
delete a file) are refused. Across files the landing is not atomic, and the
result says per file what landed.

`lsp_rename` is `Never`/`Exclusive`. The read-only tools are
`Safe`/`Concurrent`.

### 5. The model addresses symbols, not positions

LSP is built around documents and positions, because an editor always knows
its cursor. An agent does not, and asking it for a zero-based UTF-16
character offset is asking it to be wrong. So every tool and capability takes
a **symbol name**, plus optionally a `path` and a 1-based `line` as
`fs_read` shows them, and resolves the position itself:

- `path` + `line` + `symbol`: the symbol's first occurrence on that line.
- `path` + `symbol`: `documentSymbol` over that file, by name.
- `symbol` alone: candidate files by a bounded ripgrep over the project,
  then `documentSymbol` over each, stopping at a small cap. `workspace/symbol`
  is used instead when the server advertises it; `gleam lsp` does not.

An ambiguous name answers with the candidates, never a guess. Results print
as `path:line` with the line's text, in the same 1-based form `fs_read` and
`grep` print, so a result can be fed straight back into an edit.

### 6. Both surfaces, one door

- **Tools**: `lsp_definition`, `lsp_references`, `lsp_hover`,
  `lsp_symbols`, `lsp_diagnostics`, `lsp_rename`. Each is registered only
  when at least one `[lsp.<name>]` server is configured, because the tool
  array is the cached prefix. A tool whose request the owning server does not
  advertise answers that plainly, rather than sending it.
- **Post-edit diagnostics**: `fs_edit` and `fs_write` results gain a
  diagnostics block after the fresh-anchor block, and never reorder the fixed
  first two lines. The observer waits for the next publication for that URI
  after the change, bounded at 1.5 s. If none arrives, the result says that
  no diagnostics were received.
- **Code mode**: `codemode/lsp.routing` serves `lsp.*` as `ServedHere`,
  the way `client/mcp.routing` serves `mcp.<server>`, over the same client
  door. `cap/lsp` is reshaped to the symbol addressing above, and its
  `rename` applies through the hashline path and reports per file. The
  current `rename` returned `TextEdit`s with no end position, which no
  program could apply correctly. Because the surface changes, `make
  gen-prelude` and a re-seed follow, in their own commits. Composition is
  where code mode earns its place. "Every public function in this module
  with a reference outside it" is a loop a program writes in six lines and
  no single tool offers.
- **Configuration**: `[lsp.<name>]` tables in `loom.toml`: `command` (argv,
  never a shell string), `extensions`, `root_markers`. There is no built-in
  default server: an unconfigured workspace gets no `lsp_*` tools and pays
  nothing.

## What it costs

- **A package split touching `mcp` and `client` imports.** It is mechanical,
  and it is isolated in its own commit.
- **One exec helper per live language server**, bounded at two per session.
- **A 1.5-second worst case added to an `fs_edit`** whose file belongs to a
  configured server that publishes nothing for it.
- **Configured servers only.** Loom does not discover or install language
  servers.
- **Not built**: call hierarchy, which `gleam lsp` does not advertise; the
  protocol types admit it later. Also not built: code actions, formatting,
  completion, a program database, and DAP. DAP (#26) now has its transport
  and framer, and nothing more.

## What would prove this wrong

A language server that needs network at query time (dependency resolution
on open), or one that writes outside its project root. Either would fail
under the policy above in a way the agent sees as `no_server`, and the fix
would be a per-server policy widening in `[lsp.<name>]`, not a change to the
mechanism.
