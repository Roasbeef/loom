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
- `tui.Launch` says what an invocation is: `Demo`, `Local`, `Remote`,
  `Invalid` — and two that are not terminal applications at all, `Forward`
  and `Replay`.
  `loom ext …` is a passthrough to `loomd`'s own `ext` subcommand: `main`
  answers it before it builds a model, so nothing draws a frame and no
  terminal state is installed on the way past. The daemon is located by
  `tui/bootstrap.server_executable`, the same ladder an implicit local
  session uses — two ladders would mean installing an extension into one
  server's world and then starting another — and the launcher exits with
  the child's own status. `Replay` is the same shape for a different
  reason: `loom replay <path>` drives a recording through the virtual
  backend and prints frames, so it installs no terminal state and opens no
  socket either.
- `tui.Peer` says where this client's commands go, and replaces the
  optional socket the model used to carry. An absent socket meant two
  opposite things — a `--demo` `Preview`, which answers a submitted prompt
  itself so the layout can be seen, and a `Replaying` run, which must
  invent nothing because the server's own reply is already in the
  recording. `Attached` carries the websocket. Every submit and command
  site enumerates the three.
- `tui/virtual_backend.Backend` is an `etui/backend.Backend` whose `poll`
  answers a scripted list instead of a file descriptor, and whose
  `run_script` drives an application's own `update`/`view` under it and
  returns every frame. It is generic over the application state and takes
  the four loop functions as arguments, which is what lets `tui` import it:
  the replay command lives in `tui`, and a `virtual_backend` that imported
  `tui` would close a cycle.
- `tui/recording.Recorded` is the closed set of events worth replaying —
  keys, pastes, resizes, wheel notches, button presses, drags, releases and
  inbox messages — and
  `tui/recording.Moment` pairs one with its monotonic offset. `Recorder` is
  the open `--record` file, held in the `Model` because the inbox is drained
  inside `update_tick` and there is no other point at which both a websocket
  message and the recording are in scope.
- `tui/frame` renders a `Buffer` as rows of text, folding a wide glyph's
  continuation cell into the glyph and dropping the trailing blanks a
  full-rectangle paint always leaves. It is what a golden file holds and what
  `loom replay` prints, so the two cannot disagree about a frame.
- `tui/selection.Selection` is a left-button drag in progress or settled:
  an anchor and a head in screen cells, clipped to the panel interior the
  press landed in (`tui.hit_area`), so the transcript's border glyphs and
  the rail beside it are never part of a copy. `text` reads the covered
  rows back from the frame on display through `frame.row_text`, `highlight`
  adds the reverse modifier to those cells, and `clipboard_sequence` is the
  OSC 52 write. `tui.Clipboard` says whether that write reaches a terminal:
  only the interactive launch sets `TerminalClipboard`; a replay or a
  scripted test keeps `NoClipboard`, because their stdout is not one.
- `tui/protocol.Event` is the client-owned view of the frozen
  ClientGateway event union. Entry bodies cross the existing total
  `core/codec` decoder rather than growing a second durability codec.
- `tui/connection.Connection` is a websocket-owning Stratus actor. The
  etui loop drains its mailbox on ticks, keeping networking out of `view` and
  out of keyboard handling. Startup runs as a one-task `weft` run with a
  deadline. After handshake, a Weft lifetime actor owns the Stratus link and
  monitors both the connection attempt and the terminal-owned inbox. Network
  failure becomes a `Closed` notice instead of killing the terminal. Terminal
  death, including normal exit, or attempt cancellation closes the socket;
  normal attempt completion leaves it available to the terminal.
- `tui/bootstrap.Options` describes local-launch inputs, while
  `tui/bootstrap.Target` is the authenticated endpoint handed to the ordinary
  connection path. `tui/bootstrap.SessionChoice` is the canonical workspace
  and database identity recovered from one statically validated launcher
  record. Bootstrap policy, record validation, retry timing, executable
  discovery order, and lifecycle decisions remain in Gleam.
- `tui/sessions.State` owns the `/sessions` selection cursor, while
  `tui/sessions.SwitchStatus` holds the detached `weft` run whose one task
  resolves and connects one replacement attachment, and the terminal-owned
  frame inbox its socket delivers to. The run's deadline is the whole timeout
  story, and the old connection remains authoritative until the terminal
  pulls the outcome and adopts the socket.
- `tui/internal/ffi_bootstrap` exposes only operating-system facts and actions
  unavailable in pure Gleam: private and bounded file operations, process
  identity and launch, a kernel lock, loopback port reservation, time, and
  SHA-256. Its Erlang implementations must not acquire bootstrap policy. Every
  path or name crossing into Erlang is converted with
  `unicode:characters_to_list/1`, never `binary_to_list/1`, which would split a
  UTF-8 binary into bytes and send an accented path to a directory nobody
  created.
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
  prefix or bounded body; a one-task `weft` run with a deadline bounds
  descriptor opens and reads to one second, and its cancellation kills and
  joins the worker before the caller sees the timeout. It performs no path
  expansion or shell evaluation.

## Relationships

- **Depends on**: `core` for total entry decoding; `weft` for guarded,
  deadline-bounded connection startup; `etui` at commit
  `702a88415d66acab7c977da41850a7e02cc2ebed` with bounded input bursts; Mork
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
  `set_config`, `abort`, `steer`, `follow_up`, branch-scope `fork`,
  standalone `compact`, `schedules`, and `schedule_cancel`.
- **Events in**: full/strand/model/config/schedules snapshots, durable
  entries, stream deltas, operation transitions, usage, escalation
  notices, and server errors. Unknown event names are accepted and
  ignored for forward compatibility.
- **Launch flags**: `--record <path>` qualifies any interactive launch and
  writes the session as a recording. `loom replay <path> [--at <frame>]
  [--all] [--width <w>] [--height <h>]` replays one and prints frames as
  plain text, defaulting to the last; `--width`/`--height` hold only until
  the recording's own first resize supersedes them. It exits non-zero with a
  worded error for an unreadable or undecodable recording, or a frame index
  the recording does not reach.
- **Keyboard**: ordinary text sends a prompt; slash commands own application
  actions. `/model` opens the model selector, `/agents` opens the inspector,
  `/schedules` lists every schedule the session holds and `/unschedule
  <name> [target]` retires one a strand created (the target defaults to
  the active strand, and an operator `[[schedule]]` comes back as a
  `conflict` naming the configuration file),
  `/sessions` opens the locally managed session selector, `/notes` opens the
  latest durable agent-note digest, `Shift+Tab` toggles the compact rail,
  `Ctrl+G` toggles reasoning/tool detail, and Page Up/Page Down traverse
  transcript scrollback. Escape closes an open surface before it requests an
  active-operation interrupt. Mouse-wheel events share that same tail-relative
  scroll law.
- **Mouse selection**: the backend reports the mouse so the wheel can scroll,
  which stops the terminal selecting text for us, so the client does it. A
  left-button drag highlights the cells it covers within the panel the press
  landed in; the release copies exactly the highlighted text to the system
  clipboard with OSC 52 and the footer says `copied N lines`. The highlight
  stays up as confirmation until the next key, paste, wheel notch or click;
  Escape clears it without reaching the interrupt. Whether the write lands is
  the terminal's policy — Herdr, kitty, WezTerm, Ghostty and Alacritty honour
  it by default, iTerm2 behind a preference, Terminal.app not at all — and
  the client cannot tell, so the notice reports what was sent.
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
  collide, status takes a third row so the usage tail remains visible. The
  row count comes from fixed caps so it cannot flap with the notice text,
  but the status section grows into every column a wider terminal has past
  the single-row threshold (`footer_status_limit`), and on the stacked
  layouts the workspace label grows into the primary row it shares with
  the model alone (`footer_project_limit`), so a long notice or path is cut
  only when the screen is actually short of room.
- **Terminal hygiene**: server and tool text loses complete ANSI CSI and OSC
  formatting sequences before markdown creates spans. Lone or incomplete
  controls remain visibly inert rather than becoming terminal instructions.
  `main` also sets the OTP logger's primary level to `none` before anything
  else runs, because once etui owns the alternate screen a dependency's error
  report, such as a websocket refusal while `/sessions` probes a stale
  record, would print over the frame and stay until those cells repaint.

## Invariants

- **Bootstrap records are hints, never authority.** A record must match the
  canonical workspace, session path and name, loopback address, and protocol
  version. Its private token must then authenticate a real `subscribe` whose
  full snapshot names the expected session before the endpoint is reusable.
  `/sessions` reads at most 1024 record names and omits malformed, misplaced,
  incompatible, and duplicate records before presenting a choice. Selection
  still runs the complete bootstrap resolution and authenticated probe.
- **A cold start is single-winner.** Launchers serialize on a kernel lock and
  re-check state after taking it. A live birth-qualified process is preserved
  through transient probe failure; stale identities and abandoned starting
  records can be replaced without treating a reused pid as the old server.
  The lock holder's privileged shell mode prevents inherited functions from
  releasing the kernel lock after the launcher observes acquisition, and it
  uses only shell builtins so an inherited `PATH` cannot replace its hold loop.
- **Publication precedes execution.** A new daemon begins as a wrapper blocked
  on its launcher port. Gleam records that wrapper's stable pid and birth
  identity before releasing it to `exec` `loomd`. The wrapper's privileged
  shell mode ignores inherited shell functions; launcher death before release
  closes the port and makes the wrapper exit. Once released, bootstrap never
  signals a numeric pid because reuse cannot be excluded atomically on every
  supported platform. Linux reports a missing target as dead only after proving
  procfs itself is observable.
- **Repositories do not choose host processes.** Automatic startup neither
  loads a workspace `loom.toml` nor uses the workspace as its working
  directory. Implicit daemon lookup accepts only a sibling install or absolute
  `PATH` entries, and it pins an executable sibling `loom-exec` when available.
- **Launcher secrets stay under launcher authority.** Session and state paths
  are canonical before their endpoint key and kernel lock are chosen. The
  bearer token always lives under the private state root, even when an explicit
  session database lives in the workspace.
- **Launcher waits are monotonic.** The lock, live probe, starting record
  adoption and cold-start polls run on `weft/poll`, which measures the
  monotonic clock; the cold start's outer budget and the gateway snapshot
  receive, which are not polls, take their deadline from `monotonic_time_ms`.
  A wall-clock step therefore cannot stretch or cut any of them. Only the
  reads that compare against a persisted `started_at_ms` use the wall clock,
  and a starting record's remaining budget is computed there once and handed
  to the poll as a duration.
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
  event boundary; no complete Model comparison sits on the idle path. The view
  never re-renders on its own: it returns whatever frame the event handler
  last cached for this screen, so a stale frame on screen is always a
  deliberate one.
- **Bursts are paced as well as batched.** Etui applies up to sixty-four queued
  events before drawing, but every event still advances the immutable model
  through `update`, where Loom maintains its completed-frame cache, and a long
  input run can span etui batches. `frame_decision` therefore renders a stale
  cache at most once every 16 ms while paced events keep arriving and records
  the rest as `FrameDeferred`; the tick that follows the drained queue flushes
  it, and `paced_poll_timeout` shortens that tick's wait to 8 ms so the final
  position lands within a frame of the hand stopping. Ticks and resizes always
  render. The pacing clock is the monotonic clock, seeded at startup because a
  fresh node's monotonic time is negative.
- **Presentation uses one caller-owned clock.** `new_model` supplies the
  host's monotonic clock; `new_model_with_clock` lets a test supply its own.
  Frame pacing, generation throughput, and activity elapsed time all read
  `Model.monotonic_time_ms`, including the initial frame timestamp. This
  controls presentation only: socket deadlines, daemon bootstrap, and
  recording timestamps retain their real clocks. `test/clock_test.gleam`
  exercises the event handler at negative epochs and pins repeated scripted
  intermediate frames with a fixed clock.
- **Panels draw borders, not interiors.** `render_panel_border` puts the same
  bytes on the wire as etui's `block.render` over a blank canvas, and the test
  pins that, but it skips the block's area-dependent interior clear over cells
  the canvas already painted. `make bench-tui` compares both paths over the
  same immutable buffer. Interior cells therefore keep the canvas's repaint
  phase, which is what lets a detail-mode toggle rewrite vacated positions.
- **Polling follows recent activity, not liveness.** Keyboard, paste, resize,
  scroll, and decoded websocket events reset the quiet timer. The loop polls at
  40 ms until 320 ms have passed without one, then at 400 ms, and at 8 ms
  while a deferred frame is waiting for its flush. A live operation
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
- **Overlay rows never wrap.** The model, agent, and session overlays compute
  their visible window as a fixed number of rows per entry, so they render by
  rows and cut each row to the width with `text_hygiene.fit_tail` first. A
  wrapped row would spend the next entry's rows and push the selection or the
  footer past the clip.
- **Session replacement is fail-preserving.** Resolution, optional daemon
  startup, and websocket startup run as one `weft` task under
  `weft.start_detached` with a 90-second deadline; the terminal pulls its
  outcome with a zero wait once per tick. Weft's deadline kills the task and
  joins it before the outcome is delivered. Its socket guardian then closes
  the cancelled attempt's socket; task exit alone is not a socket-drain proof.
  Each attempt is its own
  run, so a stale outcome has no later attempt to land on. Failure leaves the
  old socket and model intact and discards any frames the attempt already
  queued. Success gives the replacement a fresh
  connection inbox. The terminal checks socket liveness before closing the
  prior socket and awaiting the new authoritative full
  snapshot. Late frames and close notices from the abandoned inbox cannot
  mutate the replacement session.
- **Every inbox the terminal reads is created by the terminal.** A `Subject`
  delivers to the process that created it, and receiving on one owned by
  another process panics. `sessions.start` therefore creates the replacement
  frame inbox in the terminal before starting the run; the task returns an
  outcome that names no inbox, and `sessions.receive` attaches the terminal's
  own. The real-server lifecycle test drains the full snapshot from that inbox
  in the adopting process, which is the only check that catches a task-created
  inbox. The socket guardian monitors that inbox's owner before returning the
  socket, so terminal death during handoff still triggers cleanup.
- **Approval is not implied by visibility.** A pending escalation is rendered
  as a notice only. Until the exact action/grant echo contract is implemented,
  this client cannot approve or deny an action. The server still enforces the
  same frozen approval contract, and the client must not synthesize a weaker
  approval from the visible policy diff.
- **A frame leaves the loop by message, not by return.** Etui owns the
  backend state and hands a backend the *diff* between two frames rather
  than the grid, so a rendered `Buffer` is reachable in exactly one place:
  the render callback, which is pure. `virtual_backend.run_script` wraps
  that callback and sends each frame to a `Subject` it creates itself. Loop,
  callback and receive all run in one process, so the send is a mailbox
  append rather than traffic, and a `Subject` created by anyone else would
  deliver frames to a process that cannot receive them.
- **A scripted run delivers one event per iteration.** A zero-timeout poll
  is etui draining a burst, never a wait the client asked for —
  `paced_poll_timeout` returns 8, 40 or 400 — so the virtual backend answers
  a zero timeout with `Tick`, which ends the burst without being delivered.
  One frame is therefore drawn per scripted event, including the frames the
  client deliberately left stale to pace a burst. When the script runs out
  the backend emits its settling ticks, which flush a deferred frame and
  drain the inbox, and then reports `Interrupted`; that is how the loop ends
  without a quit key.
- **A replay reproduces inbound traffic and rendering, never an outbound
  effect.** No websocket write, no daemon start, no local catalogue read,
  and no line the live client would have been *sent*. Submitting under
  `Replaying` does only the local half of the live path — clear the draft,
  mark the strand submitting, set the notice — and the turn the server
  echoed arrives from the recording as an entry, so the operator's line is
  drawn once. The footer's tokens-per-second follows the same rule: the
  window it reports is this client's own clock from a request going out to
  its settlement, and a replay spends that window reading a file, so a
  replay leaves it unset rather than reporting its own speed. A recorded
  `Closed` leaves a replay replaying rather than falling back to the
  preview, which would fabricate echoes for the rest of the file.
- **Only a replay's last frame is reproducible.** Whether a paced event
  draws a fresh frame or leaves the previous one on screen depends on how
  long ago the client last drew, so `--at` and `--all` may differ between
  machines; the settling tick that ends a replay is a flush point, so that
  frame is always current. A golden pins the last frame for that reason.
  Tests can now inject a presentation clock with `new_model_with_clock`.
  The replay command still uses `new_model`; mapping recorded offsets onto
  that clock remains separate work.
- **A copy reads the frame on display, not a fresh render.** The release
  takes its text from the cached frame, stale or not, because that is what
  the hand highlighted; a fresh render could differ by a stream fragment
  that arrived during the drag. The highlight itself is the last paint of
  `render_frame`, over overlays, and the selection is screen cells: it is
  dropped by the next input rather than tracked through a reflow, so a
  settled highlight under moving transcript is decoration, never authority.
- **A recording is what the client was given, not what it made of it.**
  `update` writes the input event before interpreting it, and
  `handle_connection_message` writes the message before decoding it, so a
  recording reproduces a decoding bug rather than hiding it. A gateway frame
  is stored as the gateway's own bytes because the protocol has one wire
  form and a second encoding of it could only ever disagree. A failed append
  is silent: etui owns the screen, so there is nowhere to print, and a
  recording that stops recording is not a reason to end a live session.
- **Manual replacement is not catch-up.** `/sessions` deliberately opens a
  fresh authenticated subscription and clears the prior projection while it
  waits for the new full snapshot. A dropped websocket still ends the current
  native connection. Automatic reconnect and sequence-based catch-up remain
  follow-up work; the client never pretends a disconnected view is current.

- **A passthrough forwards output, it does not interpret it.**
  `ffi_bootstrap.run_forwarding` opens a port with `exit_status` and
  `stderr_to_stdout` and writes every chunk to this process's stdout as
  it arrives. It is a new FFI rather than a reuse of `spawn_server`,
  which exists to start a *detached, paused* daemon and hand back its
  birth identity: nothing about a passthrough wants any of that.
  `stderr_to_stdout` because a passthrough that reordered the two streams
  would be worse than one that interleaves them as the child did.

## Toolchain Boundary

This package requires Gleam 1.18+ and Erlang/OTP 29, the repository-wide
toolchain floor. It is part of root `PACKAGES`, so `make check` includes its
format, warning-free build, tests, and house-rule census. The separate client
archive does not bundle ERTS; a compatible `erl` must be on the client host's
`PATH`. The `dev/tui_dev.gleam` benchmark and its `gleamy_bench` dependency are
development-only and do not enter that archive.

## Snapshot tests

The server package's `test/support/tui_driver` runs independent real TUI
clients with `new_model_with_clock`, `connect_remote`, and `run_script`.
The handshake is the same internal function an interactive launch uses.
Each driver's socket ingress is separate from its model inbox so forwarding
a selected frame through the virtual loop cannot reorder it behind newer
socket traffic. These tests complement the scripted snapshots here; they
exercise actual server commands and durable replies.

`test/snapshots/*.txt` hold rendered frames as plain text, compared by
`test/snapshot_test.gleam`. Each snapshot drives the shipped loop under the
virtual backend with scripted keys and gateway frames and pins the last
frame; `test/tui_test/gateway.gleam` builds the wire frames from
`core/codec`'s own encoders, so a fixture cannot drift into an `Ignored`
event and quietly render nothing.

`test/recordings/gemini-flash-reply.jsonl` is a real `loom --record` of one
Gemini turn against a live server — the attach, the catalogue snapshots, one
prompt, and its stream, usage and settlement. It stops at the settled turn
and its golden pins the *last* frame, because that is the only frame a
replay reproduces across machines. Regenerating it means recording a fresh
session, not editing the file.

A golden is written with exactly one trailing newline and read back with
exactly one removed. The two must stay symmetric: stripping every trailing
newline on read would make a frame whose last row is blank permanently
unmatchable against its own freshly written golden, which `blank-rows.txt`
now pins.

`LOOM_UPDATE_SNAPSHOTS=1 make check-tui` rewrites every golden the run
touches instead of failing, and the resulting diff is the thing to review;
the flag spares the typing, not the judgement. A *missing* golden is still a
failure, because a snapshot that writes itself on first sight always passes.
A mismatch prints a unified-diff-shaped report aligned by row index rather
than by a longest-common-subsequence walk: two renderings of one screen have
the same rows, and row *n* means the same thing in both.

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
