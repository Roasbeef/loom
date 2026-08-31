# tui_gleam

## Purpose

The opt-in pure-Gleam terminal client used to evaluate `etui` for issue
#114. It attaches to the frozen ClientGateway websocket, renders the durable
conversation and live strands, and turns keyboard input into slash commands.
It does not replace `packages/tui` or enter the release artifact yet: the
evaluation has a higher toolchain floor and has not closed the approval and
reconnect portions of the existing client's contract.

## Key Types

- `tui_gleam.Model` is the immutable presentation state. Durable entries,
  transient stream fragments, local notices, overlays, and scroll position
  remain distinct so a settled entry cannot duplicate its streamed answer.
  Wrapped durable rows are cached by strand, width, and detail mode; pending
  records extend that cache without reparsing older markdown.
- `tui_gleam/protocol.Event` is the client-owned view of the frozen
  ClientGateway event union. Entry bodies cross the existing total
  `core/codec` decoder rather than growing a second durability codec.
- `tui_gleam/connection.Connection` is a websocket-owning Stratus actor. The
  etui loop drains its mailbox on ticks, keeping networking out of `view` and
  out of keyboard handling. Startup occurs in a monitored, unlinked helper
  with a bounded deadline; a successful connection restores the runtime link.
- `tui_gleam/model_selector.State` owns the searchable `/model` overlay. Its
  exact, prefix, substring, and initials matching is presentation state only;
  a selection returns the catalogue name for `set_config`.
- `tui_gleam/markdown` walks Mork's public CommonMark tree and emits etui
  spans directly. Preformatted rows bypass prose wrapping so source
  indentation remains visible. It never passes model text through HTML or an
  ANSI renderer.
- `tui_gleam/agents` projects the server's strand snapshot and `live_op`
  phase into a hidden-by-default rail and an inspector. It owns no second
  agent-lifecycle state.
- `tui_gleam/composer` separates editable prompt text from large pasted-text
  attachments. It owns the approximate token indicator and expands the exact
  pasted bytes only when a prompt crosses the gateway boundary.

## Relationships

- **Depends on**: `core` for total entry decoding; `etui` at commit
  `fd1ff36cf167e3657a1727508aa602b8cf799422` from upstream PR #8; Mork
  1.12.x for CommonMark;
  Stratus for websockets; and small Gleam utility packages. Etui is pinned
  because its public API is still moving quickly.
- **Counterpart**: `packages/client` speaks the other side of ClientGateway.
  `packages/tui/internal/proto/protocol.md` remains the body-schema authority;
  this package does not change that wire.
- **Sibling, not replacement**: `packages/tui` remains the shipped Go client
  and the complete behavioral reference while this package is evaluated.

## Traffic

- **Commands out**: `subscribe`, `prompt`, `models`, `set_config`, `abort`,
  `steer`, `follow_up`, branch-scope `fork`, and standalone `compact`.
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
  when the prompt is sent. The backend enables bracketed-paste mode so a real
  terminal paste arrives as one event. Backspace on an empty editor drops the
  newest attachment.
- **Prompt view**: the editor retains the exact source and cursor state used by
  history and submission. Rendering wraps that state by terminal cells into a
  bounded one-to-four-row viewport; it never inserts newlines into the prompt.
- **Usage**: full snapshots establish the authoritative ledger and deltas add
  input, output, cache-read, cache-write, and cost fields independently. The
  footer never infers a price from a model name. When shortcuts, usage, and
  status cannot share one row, usage moves to a second row instead of
  disappearing between the other sections.

## Invariants

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
- **Overlays own focus.** While a selector or inspector is open, ordinary
  prompt editing is inert. Each modal explicitly paints the background of all
  its styled spans so transcript attributes cannot bleed into the overlay.
  `Ctrl+C` remains global so every overlay can be escaped by terminating the
  client.
- **Approval is not implied by visibility.** A pending escalation is rendered
  as a notice only. Until the exact action/grant echo contract is implemented,
  this client cannot approve or deny an action and is not a production
  replacement for the Go client.

## Toolchain Boundary

This package requires Gleam 1.16+ through etui. The Mork Erlang path requires
OTP 28+ because it uses PCRE2. Loom still advertises OTP 27+, so the package is
intentionally absent from the root `PACKAGES` and release targets. Run its
gate explicitly with `make check-tui_gleam` and its house-rule census with
`make lint-tui_gleam` until an adoption decision changes the repository-wide
floor.

## Deep Docs

- [`docs/design-notes/etui-client.md`](../../docs/design-notes/etui-client.md)
  records the measured evaluation and remaining adoption gates.
- [`packages/tui/internal/proto/protocol.md`](../tui/internal/proto/protocol.md)
  is the normative ClientGateway body document.
- [`packages/client/CLAUDE.md`](../client/CLAUDE.md) describes the gateway on
  the other side of the websocket.
- [`docs/architecture/models.md`](../../docs/architecture/models.md) explains
  the catalogue and role-routing state shown by `/model`.
- [`docs/performance.md`](../../docs/performance.md) defines the measurement
  workloads, BEAM tools, and optimization evidence standard.
