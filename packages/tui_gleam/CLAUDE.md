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
- `tui_gleam/protocol.Event` is the client-owned view of the frozen
  ClientGateway event union. Entry bodies cross the existing total
  `core/codec` decoder rather than growing a second durability codec.
- `tui_gleam/connection.Connection` is a websocket-owning Stratus actor. The
  etui loop drains its mailbox on ticks, keeping networking out of `view` and
  out of keyboard handling.
- `tui_gleam/model_selector.State` owns the searchable `/model` overlay. Its
  exact, prefix, substring, and initials matching is presentation state only;
  a selection returns the catalogue name for `set_config`.
- `tui_gleam/markdown` walks Mork's public CommonMark tree and emits etui
  spans directly. It never passes model text through HTML or an ANSI renderer.
- `tui_gleam/agents` projects the server's strand snapshot and `live_op`
  phase into a hidden-by-default rail and an inspector. It owns no second
  agent-lifecycle state.

## Relationships

- **Depends on**: `core` for total entry decoding; `etui` at commit
  `699d2c0a1e7f5d2ae109b00927bd5484a056517a`; Mork 1.12.x for CommonMark;
  Stratus for websockets; and small Gleam utility packages. Etui is pinned
  because its public API is still moving quickly.
- **Counterpart**: `packages/client` speaks the other side of ClientGateway.
  `packages/tui/internal/proto/protocol.md` remains the body-schema authority;
  this package does not change that wire.
- **Sibling, not replacement**: `packages/tui` remains the shipped Go client
  and the complete behavioral reference while this package is evaluated.

## Traffic

- **Commands out**: `subscribe`, `prompt`, `models`, `set_config`, `abort`,
  branch-scope `fork`, and standalone `compact`.
- **Events in**: full/strand/model/config snapshots, durable entries, stream
  deltas, operation transitions, usage, escalation notices, and server
  errors. Unknown event names are accepted and ignored for forward
  compatibility.
- **Keyboard**: ordinary text sends a prompt; slash commands own application
  actions. `/model` opens the selector, `/agents` opens the inspector, `Tab`
  toggles the compact agent rail, `Ctrl+G` toggles reasoning/tool detail, and
  Page Up/Page Down traverse transcript scrollback.

## Invariants

- **The server remains authoritative.** The client derives models, strands,
  operation phases, and entries from snapshots and events. It persists
  nothing and invents no lifecycle state.
- **Durable and transient output do not alias.** Stream fragments live in a
  strand-and-kind keyed list and disappear when that strand's settled entry
  arrives. This prevents the final assistant message from rendering twice.
- **Model text never becomes terminal control traffic.** The text-hygiene
  pass replaces C0/C1, bidirectional, zero-width, variation-selector, and tag
  codepoints before data reaches etui spans. Newlines survive only where the
  markdown block parser needs them.
- **Markdown stays structured.** Mork parses CommonMark and the adapter emits
  etui styles and OSC 8 links. No raw model-authored ANSI or HTML is executed.
- **Overlays own focus.** While a selector or inspector is open, ordinary
  prompt editing is inert. `Ctrl+C` remains global so every overlay can be
  escaped by terminating the client.
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
