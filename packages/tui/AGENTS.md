# tui

## Purpose

The shipped native terminal client. It attaches to the frozen ClientGateway
websocket, renders the durable conversation and live strands, and turns
keyboard input into slash commands. `make tui-shipment` exports its compiled
BEAM closure beside a thin `bin/loom` launcher, and `make dist` packages
that tree separately from the self-contained server.

## Key Types

- `tui.Model` is the immutable presentation state. Durable entries,
  transient stream fragments, local notices, overlays, and scroll position
  remain distinct so a settled entry cannot duplicate its streamed answer.
  Wrapped durable rows are cached by strand, width, and detail mode; pending
  records extend that cache without reparsing older markdown.
- `tui/protocol.Event` is the client-owned view of the frozen
  ClientGateway event union. Entry bodies cross the existing total
  `core/codec` decoder rather than growing a second durability codec.
- `tui/connection.Connection` is a websocket-owning Stratus actor. The
  etui loop drains its mailbox on ticks, keeping networking out of `view` and
  out of keyboard handling. Startup occurs in a monitored, unlinked helper
  with a bounded deadline; a successful connection restores the runtime link.
- `tui/bootstrap.Options` describes local-launch inputs, while
  `tui/bootstrap.Target` is the authenticated endpoint handed to the ordinary
  connection path. Bootstrap policy, record validation, retry timing,
  executable discovery order, and lifecycle decisions remain in Gleam.
- `tui/internal/ffi_bootstrap` exposes only operating-system facts and actions
  unavailable in pure Gleam: private and bounded file operations, process
  identity and launch, a kernel lock, loopback port reservation, time, and
  SHA-256. Its Erlang implementations must not acquire bootstrap policy.
- `tui/model_selector.State` owns the searchable `/model` overlay. Its
  exact, prefix, substring, and initials matching is presentation state only;
  a selection returns the catalogue name for `set_config`.
- `tui/markdown` walks Mork's public CommonMark tree and emits etui
  spans directly. Preformatted rows bypass prose wrapping so source
  indentation remains visible. It never passes model text through HTML or an
  ANSI renderer.
- `tui/agents` projects the server's strand snapshot and `live_op`
  phase into a hidden-by-default rail and an inspector. It owns no second
  agent-lifecycle state.
- `tui/composer` separates editable prompt text from large pasted-text
  and validated image attachments. It owns the approximate token indicator,
  expands exact pasted text only at the gateway boundary, and keeps local
  image paths out of typed prompt blocks.
- `tui/image_drop` parses only terminal quote and backslash-space path
  forms, sniffs PNG/JPEG/GIF/WebP magic, and enforces the 20 MiB limit before
  reading a whole image. Its small Erlang helper reads only the classification
  prefix or bounded body; a monitored Gleam worker limits descriptor opens and
  reads to one second. It performs no path expansion or shell evaluation.

## Relationships

- **Depends on**: `core` for total entry decoding; `etui` at commit
  `fd1ff36cf167e3657a1727508aa602b8cf799422` from upstream PR #8; Mork
  1.12.x for CommonMark;
  Stratus for websockets; and small Gleam utility packages. Etui is pinned
  because its public API is still moving quickly.
- **Counterpart**: `packages/client` speaks the other side of ClientGateway.
  `packages/client/protocol.md` remains the body-schema authority;
  this package does not change that wire.
- **Distribution boundary**: this shipment includes BEAM files but no ERTS.
  The client host needs compatible Erlang/OTP 29; the server release still
  bundles its own runtime and has no host OTP dependency.
- **Local launch boundary**: `tui/bootstrap` may start a separate
  `loomd`, but it still attaches through ClientGateway and does not move
  server state or authority into the terminal process.

## Traffic

- **Commands out**: `subscribe`, `prompt`, `prompt_content`, `models`,
  `set_config`, `abort`, `steer`, `follow_up`, branch-scope `fork`, and
  standalone `compact`.
- **Events in**: full/strand/model/config snapshots, durable entries, stream
  deltas, operation transitions, usage, escalation notices, and server
  errors. Unknown event names are accepted and ignored for forward
  compatibility.
- **Keyboard**: ordinary text sends a prompt; slash commands own application
  actions. `/model` opens the selector, `/agents` opens the inspector,
  `/notes` opens the latest durable agent-note digest, `Shift+Tab` toggles the
  compact rail, `Ctrl+G` toggles reasoning/tool detail, and Page Up/Page Down
  traverse transcript scrollback. Escape closes an open surface before it
  requests an active-operation interrupt. Mouse-wheel events share that same
  tail-relative scroll law.
- **Command and agent selection**: typing `/` opens the prefix-filtered command
  palette. Up and Down move palette or inspector selection, Tab completes a
  command, and Enter on an agent opens its strand transcript. A strand switch
  requests its effective config so the header never attributes the previous
  strand's model to it.
- **Live submission**: Enter steers the current live operation by default.
  Tab changes one draft to a `follow_up` queued after that operation, then
  resets to steer mode. `/steer` and `/queue` expose both paths explicitly.
- **Paste**: small pastes retain the ordinary editor path. A paste estimated
  at 400 tokens or spanning eight lines becomes a compact attachment in the
  input row; the full bytes are appended to the editable instruction only
  when the prompt is sent. A single pasted local path becomes an image
  attachment only when it is a regular PNG/JPEG/GIF/WebP file no larger than
  20 MiB; one prompt retains at most four images and 20 MiB of raw image data
  in aggregate. The chip shows a terminal-sanitized filename, MIME, and size.
  Unsupported files and multi-token paths stay text, while read errors preserve
  the editor and show a local error. The backend enables bracketed-paste mode
  so a real terminal paste arrives as one event. Backspace on an empty editor
  drops the newest attachment.
- **Prompt view**: the editor retains the exact source and cursor state used by
  history and submission. Rendering wraps that state by terminal cells into a
  bounded one-to-four-row viewport; it never inserts newlines into the prompt.
- **Footer**: full snapshots establish the authoritative ledger and deltas add
  input, output, cache-read, cache-write, and cost fields independently. The
  footer never infers a price from a model name. It discovers the surrounding
  repository once before the event loop, then shows workspace and branch beside
  the model. Repository marker and HEAD reads validate and read one descriptor,
  accept only regular files up to 4 KiB, and keep displayed refs shape- and
  length-bounded. When all sections
  cannot share one row, usage and agent status move to a second row; if those
  collide, status takes a third row so the usage tail remains visible.
- **Terminal hygiene**: server and tool text loses complete ANSI CSI and OSC
  formatting sequences before markdown creates spans. Lone or incomplete
  controls remain visibly inert rather than becoming terminal instructions.

## Invariants

- **Bootstrap records are hints, never authority.** A record must match the
  canonical workspace, session path and name, loopback address, and protocol
  version. Its private token must then authenticate a real `subscribe` whose
  full snapshot names the expected session before the endpoint is reusable.
- **A cold start is single-winner.** Launchers serialize on a kernel lock and
  re-check state after taking it. A live birth-qualified process is preserved
  through transient probe failure; stale identities and abandoned starting
  records can be replaced without treating a reused pid as the old server.
- **Repositories do not choose host processes.** Automatic startup neither
  loads a workspace `loom.toml` nor uses the workspace as its working
  directory. Implicit daemon lookup accepts only a sibling install or absolute
  `PATH` entries, and it pins an executable sibling `loom-exec` when available.
- **Launcher secrets stay under launcher authority.** Session and state paths
  are canonical before their endpoint key and kernel lock are chosen. The
  bearer token always lives under the private state root, even when an explicit
  session database lives in the workspace.
- **FFI stays mechanical.** The Erlang shim may expose platform primitives,
  but branching policy and state transitions belong in readable, testable
  Gleam. New compound behavior should first be decomposed into the smallest
  useful fact or action.
- **The server remains authoritative.** The client derives models, strands,
  operation phases, and entries from snapshots and events. It persists
  nothing and invents no lifecycle state.
- **Live intent stays visible.** The composer title derives liveness from the
  active strand's operation phase and refines `assistant` with its latest
  stream kind. Before text arrives it says `thinking`; once text arrives it
  says `responding`. The same title states whether Enter steers or queues. Its
  low-motion glyph advances at the active or quiet poll cadence without holding
  the whole terminal loop at the active cadence.
- **Unchanged frames preserve identity.** Visible mutations advance one scalar
  frame revision. The next immutable model caches the completed Buffer and
  cursor tuple by that revision and screen rectangle, so an unchanged view
  returns the exact prior Buffer term. Transcript, input, overlay, resize,
  cursor, status, and activity-indicator changes invalidate that cache at their
  event boundary; no complete Model comparison sits on the idle path.
- **Polling follows recent activity, not liveness.** Keyboard, paste, resize,
  scroll, and decoded websocket events reset the quiet timer. The loop polls at
  40 ms until 320 ms have passed without one, then at 400 ms. A live operation
  alone does not keep fast polling active. Because the websocket actor cannot
  wake etui's terminal poll, the first external event after quiet may wait up to
  the 400 ms quiet timeout before the client drains it and returns to 40 ms.
- **Durable and transient output do not alias.** Stream fragments live
  newest-first in a strand-and-kind keyed list and disappear when that strand's
  settled entry arrives. The historical row cache contains durable records
  only; a stream fragment cannot make it reparse the settled transcript. This
  prevents both duplicate output and history-sized work per fragment.
- **Model text never becomes terminal control traffic.** The text-hygiene
  pass replaces C0/C1, bidirectional, zero-width, variation-selector, and tag
  codepoints before data reaches etui spans. Newlines survive only where the
  markdown block parser needs them.
- **Markdown stays structured.** Mork parses CommonMark and the adapter emits
  etui styles and OSC 8 links. Tables become stacked labelled records so their
  relationships survive narrow terminals. Fenced Gleam token styling
  preserves the exact model-authored text; it never acts as a formatter or
  compiler. No raw model-authored ANSI or HTML is executed.
- **Executed programs stay inspectable.** A structured `code_mode.program`
  renders through the fenced Gleam path instead of appearing as escaped JSON.
  The normal view bounds long programs to twelve rows; detail mode reveals the
  whole source. Results label the returned report separately from the sandbox
  enforcement summary.
- **Injected notes are not operator speech.** The frozen entry schema records
  the server's run-start digest as a user message without a provenance bit. The
  client recognizes only the exact server-owned preamble and `agent-notes`
  fence, hides that envelope from conversation, and exposes it through
  `/notes`. Do not broaden this into heuristic filtering.
- **Large context stays bounded without data loss.** Compact paste indicators
  are presentation state only. Submission expands the original bytes, and a
  durable large user turn stays previewed until detail mode asks for it.
- **Image turns never become live-operation steering.** The client submits one
  non-empty text block first, when present, then image blocks in drop order.
  It refuses locally while the active strand is live and preserves the editor
  and attachments. Only the file bytes and magic-derived MIME reach the wire;
  local paths remain presentation state.
- **Overlays own focus.** While a selector or inspector is open, ordinary
  prompt editing is inert. Each modal explicitly paints the background of all
  its styled spans so transcript attributes cannot bleed into the overlay.
  `Ctrl+C` remains global so every overlay can be escaped by terminating the
  client.
- **Approval is not implied by visibility.** A pending escalation is rendered
  as a notice only. Until the exact action/grant echo contract is implemented,
  this client cannot approve or deny an action. The server still enforces the
  same frozen approval contract, and the client must not synthesize a weaker
  approval from the visible policy diff.
- **Reconnect is not catch-up.** A dropped websocket ends the current native
  connection. Automatic reconnect and sequence-based catch-up remain follow-up
  work; the client never pretends a disconnected view is current.

## Toolchain Boundary

This package requires Gleam 1.18+ and Erlang/OTP 29, the repository-wide
toolchain floor. It is part of root `PACKAGES`, so `make check` includes its
format, warning-free build, tests, and house-rule census. The separate client
archive does not bundle ERTS; a compatible `erl` must be on the client host's
`PATH`.

## Deep Docs

- [`docs/design-notes/etui-client.md`](../../docs/design-notes/etui-client.md)
  records the measured evaluation and the later adoption decision.
- [`packages/client/protocol.md`](../client/protocol.md)
  is the normative ClientGateway body document.
- [`packages/client/CLAUDE.md`](../client/CLAUDE.md) describes the gateway on
  the other side of the websocket.
- [`docs/architecture/models.md`](../../docs/architecture/models.md) explains
  the catalogue and role-routing state shown by `/model`.
- [`docs/performance.md`](../../docs/performance.md) defines the measurement
  workloads, BEAM tools, and optimization evidence standard.
