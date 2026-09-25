# ADR-013: language servers run as jailed session leases, addressed by symbol

**Status**: accepted · **Date**: 2026-09-25 · **Supersedes**: nothing ·
**Spec ref**: Part 2 WP-I ("Later in M5: `lsp_*` — client over stdio port,
per-project supervised, sandboxed"), Part 1.4 (data-plane framing) ·
**Issue**: #25

## The question

The agent edits by hashline anchor and finds symbols by grep. It has no
semantic view of the code. It cannot ask for a definition, references or a
rename, and it gets no compiler diagnostics after an edit. `cap/lsp` has
shipped in the prelude since WP-J with nothing behind it, and the router
refuses all four of its names as `unsupported_cap`.

A language server is not a command. It is a long-lived process that speaks
JSON-RPC over its stdin and stdout, and keeps a model of every open
document. It sends requests of its own that must be answered, and it
publishes diagnostics whenever it likes. `proc.run` cannot carry it.

Loom is not a Gleam tool that happens to be written in Gleam. Its agent
works on Go, Rust and anything else a workspace holds. Whatever this
decision builds must therefore be language-neutral. The compiler's own
package-interface export, the `glance` walker in `packages/lint` and the
search index know Gleam and nothing else. They cannot be the semantic
channel. The language server is the one channel every language already
ships, and each server is its language's only oracle for types.

The questions are six, and they are not independent:

1. Where does the server process run, and under what policy?
2. Where does the protocol code live?
3. How does the server learn about edits the agent makes?
4. How does a rename land, given that `fs_edit` is the only write path with
   a concurrency check?
5. What does the model actually address: a position, or a symbol?
6. How does the model reach it?

## Measured before deciding

Two servers were driven over stdio on 2026-09-25: `gleam lsp` 1.18.1
against a two-module Gleam project, and `gopls` (current, from the module
proxy) against a two-package Go module.

| | `gleam lsp` | `gopls` |
|---|---|---|
| definition, references, hover, documentSymbol, rename | yes | yes |
| call hierarchy, implementation | no | yes |
| `positionEncoding` in the result | absent (UTF-16) | absent (UTF-16) |
| an unadvertised request (`workspace/symbol`) | **never answered** (30 s) | — |
| warm query latency | < 30 ms | < 5 ms; first query 1.8 s cold |
| `publishDiagnostics` carries `version` | **no** | yes |
| a clean → clean edit publishes | **nothing** | a versioned empty list |
| publications relative to the reply of a request sent after `didChange` | **before** it, for every affected URI | **after** it |
| a refused rename | — | a JSON-RPC error with a precise reason ("would make it unexported") |
| writes into the project | `manifest.toml`, `build/` | nothing; its caches go to `GOCACHE`/`GOMODCACHE` |

Four facts shape the client:

- **Gate every request on advertised capabilities.** A server may leave an
  unadvertised request hanging forever. Every request also carries a
  deadline.
- **"Diagnostics for version N" is not universally waitable.** `gleam lsp`
  versions nothing and publishes nothing for a file that stays clean.
- **A request is a barrier for one server and not for the other.**
  "Diagnostics have settled" therefore takes two rules (§3).
- **Per-server policy is required.** Gleam's server must write its project.
  `gopls` must read a module cache and write a build cache outside it.

## Decision

### 1. The server is a jailed exec, cleared like an extension host

A language server runs project code in effect: build scripts, macros, and a
toolchain the model can edit. Rule Zero puts it in the jail. The MCP port
transport (unjailed `open_port`) is not the model. That transport is the
open decision recorded against #109.

The broker's ordinary jailed exec already fits. It needs no new frame, no
helper change and no protocol change. `broker.clear_call` streams stdout
and stderr as `CallOutput` chunks, and `broker.stdin` feeds the child.
The JSON-RPC bytes ride inside `exec_stdin`/`exec_out`, which is what Part
1.4 asks of an LSP adapter. Extension hosts are the precedent: one jailed
node per extension, cleared once, living for the session.

- **Policy.** Requirements:
  - the project root is readable. It is writable only when the server's
    configuration says so, which Gleam's must;
  - the located toolchain prefix is mounted read-only;
  - the server's configured extra roots are mounted: `readable`, and
    `writable` for `GOCACHE`. These come from `loom.toml`, never from the
    model;
  - network is off, with `RefuseNarrowed`;
  - `env_allow` covers PATH, HOME, TMPDIR and the server's configured
    `env` names.

  TMPDIR is pinned under a writable root, because the jail replaces `/tmp`.
  **The base policy has `wall_s`, `cpu_s` and `output_bytes` at zero.**
  Limits meet with zero as "unlimited" (`policy.meet_limit`). A zero in the
  requirements against a non-zero base is a narrowing that `RefuseNarrowed`
  refuses, so the zeros must sit on the base. This is the shape extension
  hosts already used, extended by `output_bytes`, now **hoisted into
  `broker/policy.session_lease`** with a two-variant `LeaseOutput`
  (`OutputIsLog` for an extension host, `OutputIsWire` for a language
  server) rather than a `Bool`. `extension/dispatch` calls it instead of
  keeping a private copy.
- **The lease is the pooled budget deadline**, twelve hours as for
  extension hosts. The zero wall only stops the helper from killing the
  server earlier. The effects plane deliberately offers no renewal. A
  settled server is restarted on next use, and its open documents are
  re-sent. The result that pays for the restart says so ("server
  restarted; this query waited for it"), because a restart costs a
  handshake and a full compile.
- **Identity.** Language servers get their own session-scoped attribution
  operation, and each server gets a step, `lsp/<server>/<root-digest>`.
  A model operation's abort does not reach it. Stopping a server is
  `shutdown`, then `exit`, then stdin EOF, with `broker.abort_step` as the
  backstop. The `exec_exit` settlement is the retirement witness. **Session
  end aborts the language-server operation from the same place
  `extension/hosts.stop_all` stops extension hosts.** Daemon restart is
  covered by pool close and bwrap's `--die-with-parent`.
- **Demand.** The server clears under the session's own
  `EnforcementDemand`, the one `bash` clears under. That is
  `PlatformEnforcement` by default (full enforcement always fails on
  Darwin), and `BestEffort` only where the operator opted a development
  container into it. A language server is no more trusted than the
  shell beside it, and no less.
- **Pool pressure.** Each assembled session starts its own helper pool
  and broker (`serve.assemble_in` → `start_effect_plane_in`); the pool
  clamps to 4–16 helpers. Code mode is a nested borrower: its satellite
  holds one helper and each capability call borrows another. So: **one
  language server per session**, with a new project evicting the old
  server, and **session-lived leases capped per session at
  `pool_size − 3`** (`client/lsp/leases`). The three are for bash, a
  satellite, and its nested effect. At the cap a new server is refused as
  `no_server`, naming the cap. With one server and a pool of at least
  four the cap cannot bind today. It is the guard that stops a second
  server, or extension hosts counted against it later, from starving
  code mode, and it is tested at the minimum pool size. Extension hosts
  already hold session-lived helpers with no ceiling. Counting them
  against the same cap is a follow-up. (The review that shaped this
  paragraph assumed a daemon-wide pool. Measuring the boot path showed
  the pool is per session, so the cap is too.)
- **Enforcement is proven before a server starts.** Under
  `PlatformEnforcement` the helper reports what it enforced only in the
  exit report. For a one-shot command that arrives before its output is
  trusted, but a server lives for hours and answers queries all the
  while. So the manager first clears a trivial probe under the identical
  policy and demand, and starts the server only if the probe settles
  undegraded. A probe that degrades refuses the server as `no_server`,
  naming what the helper could not enforce. That costs one short exec per
  server start.
- **Truncation.** A truncated *stdout* chunk is transport-fatal: the stream
  is no longer JSON-RPC. Stderr is drained into a bounded ring for the
  restart message and is never fatal. With `output_bytes` at zero, neither
  should happen.
- **No backpressure exists on this path.** The relay forwards every chunk
  as a message, and `broker.stdin` is a cast. The client actor therefore
  never reads disk and never waits inside a handler. The resync reads of §3
  happen in the caller and reach the actor as one message. A resync sends
  at most 64 documents, each under the large-file guard.

Known hazard, not fixed here: the helper writes stdin synchronously while
holding the execution's mutex, and `Cancel` takes that mutex too. So a
server that stops reading while its stdin pipe is full blocks cancel as
well as frame processing, until the broker's three-second helper kill
collapses the namespace. That is bounded and costs one helper. It is
recorded for the helper's owners.

Nothing here needs new FFI.

### 2. `packages/lsp` holds the protocol and depends on `mcp` for the seam

The JSON-RPC envelope (`mcp/jsonrpc`) and the transport seam
(`mcp/transport.{Transport, ChannelTransport, TransportEvent,
Connection}`) know nothing about MCP. `Connection.send` takes a
pre-framed string, and `TransportData` carries bytes. LSP uses both,
unchanged apart from two additive encoders, `response` and
`error_response`, which the MCP client currently builds by hand. LSP never
touches `mcp`'s port FFI, because its production transport is a
`ChannelTransport` over `clear_call`.

`packages/lsp` holds:

- `lsp/framing`, a pure Content-Length framer: a bounded buffer, bytes
  rather than strings, and total decoding;
- `lsp/protocol`: total decoders and encoders for every structure
  consumed, advertised-capability gating, UTF-16 position conversion, and
  pure text-edit application;
- `lsp/client`: the client actor, a `weft/state_machine` over
  `mcp/transport.Transport`.

It never imports `broker`. The production transport is built in `client`,
which already does. `mcp` could use the same adapter for #109 if that
decision goes the jail's way.

A shared `packages/peer` was considered and **not built**. It would move
the one impure thing, the port FFI, for a consumer that does not use it,
to serve DAP, which does not exist. When DAP lands as a real third
consumer, the extraction is a single move commit and this paragraph is its
argument. The monitored try-call that `broker` and `mcp` each copy is a
gap `docs/weft.md` already names. LSP does not add a third copy: it reuses
the `mcp` one, made public.

### 3. The server's view is kept honest, and "settled" is two rules

- **Push.** A successful write through `fs_write`, `fs_edit`, or a rename
  is reported to an observer. The observer sends a full-text `didChange`
  (or `didOpen`) to the server owning that file.
- **Pull.** Before every query, the caller re-reads every document the
  server holds open. It sends a `didChange` for each document whose digest
  moved, and a `didClose` for each that vanished. This catches `bash`,
  jobs and code mode's writes. A document the server never opened is read
  from disk by the server itself. Open documents are bounded at 64, with
  LRU `didClose`. The pull is not a lock. Its race with a concurrent write
  is the same race `fs_edit` already has with `bash`, and tool concurrency
  (`Exclusive` on `lsp_rename`) closes it for tools.
- **Containment.** A path whose real path is not under the server's root
  is refused as `no_server` before any request is sent. bwrap binds the
  root at its own path, so a symlink leading out of it names a file the
  server cannot read.
- **Settled diagnostics.** After a change, the client sends a barrier
  request (`documentSymbol` on the changed URI). Diagnostics have settled
  when both of these hold:
  - the barrier has answered;
  - if this server has ever published a `version`, a publication for the
    changed URI at a version at least the change's has arrived.

  Both are bounded at 1.5 s. Every URI published between the change and
  settlement is collected, since breaking `a.gleam` breaks `b.gleam`, and
  the block is capped. This is the measured behaviour of both servers, not
  a guess about either. If the bound expires, the result says the
  diagnostics did not settle. It never says the code is clean.

### 4. Rename lands through the hashline path, or not at all

The server computes a `WorkspaceEdit` and never writes. A
`workspace/applyEdit` from the server is answered `applied: false`.

- **Base text.** For an open document, the base is the last text sent to
  the server, which the pull just made the disk text. Full-text sync makes
  that the server's exact view. For a URI in the edit that is not open,
  the base is read now. **Every edit's range must select exactly the old
  identifier** in its base. A stale position fails that check, and costs
  nothing.
- **Conversion.** UTF-16 positions are converted by walking codepoints,
  counting anything above U+FFFF as two units. A position between the
  halves of a surrogate pair is `MalformedEdit` and is never rounded. A
  `character` past the end of the line clamps. Line = line-count with
  character 0 is a legal end-of-file insert. Lines split on `\n`, `\r\n`
  and a lone `\r`, and each file's terminator is preserved. Several edits
  on one line merge into one `Replace`, because `hashline.apply` rejects
  overlapping hunks.
- **Order.** First, every file is converted and its `Plan` built. Then
  every digest is checked. Only then is anything written, file by file,
  through the resolve / `hashline.apply` / write path that `fs_edit` uses,
  factored out of `run_edit` as one shared helper. A concurrent
  modification rejects as `StaleContent`, exactly as a stale `fs_edit`
  does. Resource operations are refused. The landing across files is not
  atomic. Every pre-check happens before the first write, the result
  reports per file what landed, each landed file is pushed to the server,
  and the settled diagnostics expose a half-landed rename immediately.
- **Refusals.** A server's rename refusal (an error response) reaches the
  model in the server's own words.

`lsp_rename` is `Never`/`Exclusive`. The read-only tools are
`Safe`/`Concurrent`.

### 5. The model addresses symbols, not positions

LSP is built around documents and positions because an editor always
knows its cursor. An agent does not, and asking it for a zero-based UTF-16
offset is asking it to be wrong. Every tool and capability therefore takes
a **symbol name**, plus optionally a `path` and a 1-based `line` as
`fs_read` shows them, and resolves the position itself:

- `path` + `line` + `symbol`: the symbol's first occurrence on that line,
  matched on identifier boundaries (`foo` does not match inside `foo_bar`).
- `path` + `symbol`: `documentSymbol` over that file, by name.
- `symbol` alone: a bounded, word-matched ripgrep over the server's root
  (the existing jailed `rg`), then `definition` at each hit, deduplicated
  by definition site. Hits inside strings and comments resolve to nothing
  and fall out. `workspace/symbol` is not used. Neither measured server
  needs it, and one never answers it.

The symbol may be qualified the way code reads it (`probe.greet`,
`util.Greet`): the last segment is the identifier, and the qualifier
narrows candidates to definitions whose module path or directory ends
with it.

An ambiguous name (more than one distinct definition) answers with the
candidates, never a guess. Results print as `path:line` plus the line's
text, in the same 1-based form `fs_read` and `grep` use, so a result feeds
straight back into an edit.

Answers are shaped to be the agent's next step rather than a report
to read:

- **Anchors.** Every rendered site carries its hashline anchor, so a
  result feeds `fs_edit` directly without an `fs_read` round trip.
- **Containers.** References carry the symbol that contains them
  (`other.twice`). That answers "who depends on this?", and it gives a
  one-level caller view on servers with no call hierarchy.
- **Preview first.** Rename takes an explicit `preview` or `apply` mode.
  Preview writes nothing and shows every changed line.
- **Counts first.** Lists count before they list ("37 references in 9
  files; showing 20"), so the model knows when to narrow a query or move
  it into code mode.

### 6. Tools, code mode and post-edit diagnostics share one door

- **Tools**: `lsp_definition`, `lsp_references`, `lsp_hover`,
  `lsp_symbols` (a file's outline), `lsp_calls` (incoming or outgoing, for
  servers that advertise call hierarchy), `lsp_diagnostics` and
  `lsp_rename`. They are registered only when an `[lsp.<name>]` server is
  configured, because the tool array is the cached prefix. A request the
  owning server does not advertise is answered plainly and never sent.
- **Post-edit diagnostics.** `fs_edit` and `fs_write` results gain a
  settled-diagnostics block after the fresh-anchor block, and never reorder
  the fixed first two lines.
- **Code mode.** `codemode/lsp.routing` serves `lsp.*` as `ServedHere`,
  as `client/mcp.routing` serves `mcp.<server>`, over the same door.
  `cap/lsp` is reshaped to symbol addressing. Its `rename` applies through
  the hashline path and reports per file. The old `rename` returned
  `TextEdit`s with no end position, which no program could apply.
  `make gen-prelude` and a re-seed follow in their own commits. This is
  where code mode earns its place: "every public function here with a
  reference from outside this module" is a six-line loop, and no single
  tool offers it.
- **Configuration.** Each server is an `[lsp.<name>]` table in `loom.toml`:
  - `command`: an argv, never a shell string;
  - `extensions`;
  - `root_markers`;
  - `project`: `read-only` or `writable`, as a string enum;
  - `readable` and `writable`: extra roots;
  - `env`: the names passed through.

  There is no built-in default server. An unconfigured workspace gets no
  `lsp_*` tools and pays nothing.

## Review and disposition

An adversarial design review was run before any code (2026-09-25). It
traced the limits composition, the relay's missing backpressure and the
helper's stdin mutex, and each finding above cites what it found.

It proposed two cuts, which are **not taken**. The first was to defer the
`cap/lsp` reshape, keeping the router refusing. The second was to defer
post-edit diagnostics. Both are in scope: exposure through code mode and
the edit loop is what this work was asked to deliver. The review's
disproving experiment was run instead of the deferral. It found the URI
wait unsound for `gleam lsp` and the plain barrier unsound for `gopls`,
which is what the two-rule settlement in §3 answers.

It also proposed dropping `workspace/symbol` and the `peer` package; both
are dropped. It proposed one server per session and a daemon-wide cap;
both are taken.

## What it costs

- One exec helper per live language server: one per session, under a
  daemon-wide cap.
- Up to 1.5 s added to an `fs_edit` whose server never settles. The
  measured servers settle in milliseconds.
- Configured servers only. Loom does not discover or install them.
- Not built: code actions, formatting, completion, `workspace/symbol`, a
  per-language program database, and DAP.

## What would prove this wrong

A server that needs the network at query time, one that writes outside
the roots its configuration declares, or one that publishes neither
before a barrier nor with versions. Each fails visibly: as `no_server`,
or as diagnostics that did not settle. The first two are fixed by the
server's `[lsp.<name>]` table, the third by a quiet window. None of the
three is a change to the mechanism.
