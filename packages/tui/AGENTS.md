# tui (Go)

## Purpose

`loom-tui`, the terminal client for a Loom session: a bubbletea program
over the ClientGateway websocket protocol (spec Part 1.6). It owns the
Go side of the protocol types and their golden fixtures, the connection
actor that dials/reconnects/catches up, the bubbletea model that turns
key presses into commands and events into a transcript, and an in-memory
fake gateway so all of it is testable without a Gleam runtime. WP-L. One
of the tree's two Go modules, alongside `sandbox`.

## Key Types

- `cmd/loom-tui` — the binary. `--addr ws://host:port/v1/ws --session id`
  dials a real gateway; `--demo` runs the in-process fake with a canned
  session.
- `internal/proto` — the hand-written protocol types: `Command` and
  `Event` envelopes, `DecodeCommand`/`DecodeEvent`, the frozen `Cmd*` and
  `Event*` name constants, one body struct per command and event
  (`SubscribeBody`, `PromptBody`, `ForkBody`, `ModelsBody`, ...,
  `SnapshotBody`, `EntryBody`, `OpTransitionBody`, `StreamDeltaBody`,
  `UsageBody`, `EscalationBody`, `StrandResultBody`, `ErrorBody`), the
  entry/message parse tree, `ModelInfo` for the model-catalogue
  snapshot, and `Denial`/`Grant`/`Network`/`Scratch` for the escalation
  vocabulary. `protocol.md` beside it is the normative body document; the
  Gleam gateway builds to it and to `testdata/`.
- `internal/client.Client` — the connection actor: `New`, `Run`,
  `Messages()`, `Send`, `Request`. It decodes events into typed `Msg`
  values (`StateMsg`, `SnapshotMsg`, `EntryMsg`, `OpTransitionMsg`,
  `StreamDeltaMsg`, `UsageMsg`, `EscalationMsg`, `StrandResultMsg`,
  `ServerErrorMsg`, `UnknownEventMsg`, `DecodeErrorMsg`) and correlates
  request/reply by command id.
- `internal/ui.{Model, Config, Sender}` — the bubbletea program. `Update`
  is pure: sends are returned as `tea.Cmd` closures, so the whole
  interaction surface is table-testable without a terminal. The
  `:models` palette command opens a modal picker over the catalogue
  (the `models` snapshot); picking a row sends `set_config` with
  `model_name` for the active strand, and the config ack pins the name
  into the status bar.
- `internal/fake.{Server, Session, OnCommand}` — a gateway that speaks
  the same protocol backed by in-memory state: snapshot on subscribe,
  resume-with-replay by seq, `catch_up`, per-command replies with
  `reply_to`, the escalation lifecycle, and in-band errors.

## Relationships

- **Depends on**: the Go standard library plus `charmbracelet/bubbletea`
  (+ `bubbles`, `lipgloss`, `glamour` for rendering) and
  `coder/websocket`. It depends on no Loom package — the protocol and the
  golden fixtures are the entire coupling.
- **Counterpart**: `packages/client` speaks the other end. Its
  conformance test decodes and re-encodes this module's
  `internal/proto/testdata/` fixtures byte for byte, which is what pins
  the two implementations together.
- **Websocket library choice**: `coder/websocket` (the maintained home of
  `nhooyr.io/websocket`) over `gorilla/websocket` — its API is
  context-aware end to end, and its one-reader/serialized-writes
  concurrency rules fit the single pump here without extra locking.

## Traffic

- **Wire (websocket)** — commands out: `subscribe`, `catch_up`,
  `prompt`, `steer`, `follow_up`, `abort`, `approve`, `deny`, `fork`,
  `navigate`, `compact`, `create_strand`, `models`, `set_config`
  (including the `model_name` key behind the `:models` picker). Events
  in:
  `snapshot`, `entry`, `op_transition`, `stream_delta`, `usage`,
  `escalation`, `strand_result`, `error`. Auth is
  `Authorization: Bearer <token>` on the upgrade.
- **Channels** — `Client.Messages()` is the single typed stream the
  bubbletea program consumes; an outbound queue carries commands to the
  writer side of the pump. A full outbound queue drops a speculative
  `catch_up` rather than blocking, because the reconnect path converges
  anyway.
- **Commits / registers / actors**: none. The TUI holds no durable state
  and persists nothing; every fact it displays came from a snapshot or an
  event.

## Invariants

- **Strict on the envelope, tolerant on names.** `v` must be `1` and the
  discriminator must be present; an unknown `cmd`/`event` name is carried
  as its raw body so an old client survives a new server, and unknown
  fields inside known bodies are ignored.
- **Seq is the only stream position.** An event at or below the last seq
  is a duplicate from catch-up overlap and is dropped; an event more than
  one past it (once a snapshot has been applied) triggers exactly one
  `catch_up` from `last+1` and is not applied. Events with no seq —
  snapshots, stream deltas, errors — never move the position.
- **A full snapshot resets the position** to `next_seq - 1`: everything
  below it is already reflected in the snapshot body. A resume snapshot
  resets nothing, because its replay carries the original seqs.
- **Reconnects resume, they do not restart** — but only once a full
  snapshot has been applied; before that a reconnect re-subscribes from
  zero. Backoff is bounded (100ms to 5s by default).
- **In-flight requests fail loudly on disconnect** (`ErrDisconnected`)
  rather than hanging; sends after close fail with `ErrClosed`.
- **`Update` is pure.** No I/O happens inside the bubbletea update
  function; every send leaves as a `tea.Cmd` closure, which is what keeps
  the interaction surface table-testable.
- **The fake implements the contract precisely, not loosely.** It is the
  substrate for the TUI's tests and `--demo`, so where it diverges from
  `protocol.md` the tests are testing fiction.

## Deep Docs

- [internal/proto/protocol.md](internal/proto/protocol.md) — the
  normative body schemas for every command and event.
- [packages/client/CLAUDE.md](../client/CLAUDE.md) — the Gleam gateway on
  the other end of the wire.
- [docs/architecture/orchestration.md](../../docs/architecture/orchestration.md)
  — the session surface the protocol exposes.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
