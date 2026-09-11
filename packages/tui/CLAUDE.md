# tui

## Purpose

The shipped native terminal client. It authenticates one daemon control
connection, lists session metadata, and explicitly selects a v2 conversation
connection. It renders completed coherent cuts and turns keyboard input into
slash commands. `make tui-shipment` exports its compiled
BEAM closure beside a thin `bin/loom` launcher, and `make dist` packages
that tree separately from the self-contained server.

## Key Types

- `Model.reading_lines` retains one bounded transient projection when scrolling
  above the live tail. Incoming streams continue collecting without changing
  that projection; returning to the bottom releases it. Durable history keeps
  its existing frozen ancestry and row anchors. The composer border provides
  a clickable jump action that preserves an unsent draft; End also returns to
  the tail when the composer is empty.
- `tui/file_read_view` removes recognized edit digests and hashline anchors
  only from successful file-read presentation. Line numbers and source text
  remain; stored results and model-facing edit prerequisites are unchanged.
  Terminal hygiene expands tabs to four spaces while keeping other controls
  inert. Markdown equality operators remain visible instead of coloring the
  prose between two comparisons. Completion details remain in `/summary`,
  without automatic operation and edit-total rows beneath the transcript.

- Completion patch totals are accumulated before the 32-result/path display
  limit, using the complete already-bounded fs_edit patch. `edit_count` and
  `edit_delta` therefore survive display truncation and later history eviction.
  They remain captured file-tool mutation counts, not workspace Git totals.
- A valid history transfer may exceed its local eight-MiB retention budget.
  Its retained suffix is accepted, and `evicted_through` supplies the next older
  interval so evicted ancestors are revisited. Read replies never adopt metadata.
  One prompt may wait behind an authenticated read; a sent mutation still blocks
  another mutation until its reply. Neither path resends an uncertain command.

- `tui/history_view.State` owns bounded presentation history separately from
  the latest authoritative cut. Live captures retain at most 600 descriptors
  and 16 MiB. Scrolling freezes the selected ancestry endpoint; `history` reads
  exclusive intervals of at most 100 sequence positions on the existing channel.
  Older replies cannot replace metadata or advance the catch-up cursor. Paging
  retains proved ancestry so unrelated reviewer traffic cannot evict a missing
  parent's endpoint. The newer end is evicted when paging backward past the
  cache bound. End with an empty composer returns to the latest captured leaf.
- `tui/transcript_anchor.Row` identifies a durable entry and its source block
  or tool call. Wrapped row offsets relocate the reading position through
  incoming output, older pages, detail changes and width changes. Equal text
  never substitutes for identity. A mouse selection retains one bounded frame
  and holds its pane on the original cells until dismissal or resize.
- `session_channel.HistoryPage` has an independent projection lane; exact
  bounds and attachment identity are checked before presentation. The recorded
  `attempt.HistoryRange` restores request ownership during replay. Attachment
  replacement clears a different session's history; same-session reconnect
  preserves the reading endpoint without reusing mutation authority.
- User messages have a shaded, labelled block. Agent prose and reasoning have
  explicit labels; non-redacted reasoning remains visible in compact mode.
  Compact tool rows retain every call while folding arguments and results.
  The wide changes pane opens automatically, leaves the composer focused, and
  remembers explicit dismissal. One requested refresh survives an in-flight
  worktree observation.
- Confirmed session deletion sends `StopSession` once, waits through `weft/poll`
  for the daemon's saved/reserved observation, then sends `DeleteSession` once.
  Unconfirmed cleanup, a replacement incarnation, or an uncertain reply keeps
  the registration. The picker runs this within its existing managed job.
- Usage labels distinguish cumulative totals from input context at the latest
  measured request. Reasoning is a subset of output. Job ages and remaining
  deadlines use the server's shared clock domain; refresh age uses only the
  terminal's local receipt clock.

- `tui/skills.Page` decodes the attached daemon's paged skill commands.
  `Model.skills` is presentation metadata, cleared with attachment replacement.
  `command.suggestions_with_skills` keeps built-ins authoritative and completes
  loaded names; `parse_with_skills` classifies them as prompts before mutation
  admission, including draft retention on observer or unavailable attachments.

- `command.Rename` sends control `RenameSession` for the attached identity.
  The existing `CatalogueRequest` worker sends the mutation once, then reloads
  the first page and opens the selector with the current ID highlighted. The
  owner and epoch checks remain server-side; a lost reply is not retried.
  `workspace.session_name` uses cached workspace/branch context for new names,
  normalizes terminal text, and preserves graphemes within 256 UTF-8 bytes.
  [Protocol 019](../../protocol-change/019-session-display-names.md) describes
  the durable rename contract.

- `tui.Model` is the immutable presentation state. Durable entries,
  transient stream fragments, local notices, overlays, and scroll position
  remain distinct so a settled entry cannot duplicate its streamed answer.
  Wrapped durable rows are cached by strand, width, and detail mode. Expanded
  history appends pending records; compact groups rebuild their projection
  and reuse wrapped rows keyed by the complete speaker/text line. Compact
  presentation caches the complete call/outcome and narrative/owner values,
  avoiding repeated sanitization before the wrapping cache can be consulted.
  Width changes discard layout hints; each rebuild retains only current calls
  and entries. Scroll anchors are created when reading older output begins,
  then relocated across changes; following live output does no anchor work.
- `tui.Launch` says what an invocation is: `Demo`, `Local`, `Remote`,
  `Invalid` — and three that are not terminal applications at all,
  `Forward`, `Replay` and `Sessions`.
  `loom ext …` is a passthrough to `loomd`'s own `ext` subcommand: `main`
  answers it before it builds a model, so nothing draws a frame and no
  terminal state is installed on the way past. The daemon is located by
  `tui/bootstrap.server_executable`, the same ladder an implicit local
  session uses — two ladders would mean installing an extension into one
  server's world and then starting another — and the launcher exits with
  the child's own status. `Replay` is the same shape for a different
  reason: `loom replay <path>` drives a recording through the virtual
  backend and prints frames, so it installs no terminal state and opens no
  socket either. `Sessions` is `loom sessions list` and `loom sessions rm
  <id>`: it reaches the control endpoint as the owner over the same
  bootstrap ladder the picker uses, prints one line per row or one line of
  outcome, and exits with a status. `rm` asks at the terminal before it
  sends and refuses outright when standard input is not a terminal, unless
  `--yes` was given.
- `tui.Peer` says where this client's commands go, and replaces the
  optional socket the model used to carry. An absent socket meant two
  opposite things — a `--demo` `Preview`, which answers a submitted prompt
  itself so the layout can be seen, and a `Replaying` run, which must
  invent nothing because the server's own reply is already in the
  recording. `Attached` carries the websocket. `Disconnected` retains the last
  view but cannot fabricate preview responses or send commands.
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
- `tui/connection.Connection` is a thin typed adapter over `host/websocket`.
  The shared host transport owns Stratus and deadline-bounded handshake
  startup. The terminal owns the destination inbox. After handshake, the
  shared Weft lifetime actor owns the Stratus link and
  monitors both the connection attempt and the terminal-owned inbox. Network
  failure becomes a `Closed` notice instead of killing the terminal. Terminal
  death, including normal exit, or attempt cancellation closes the socket;
  normal attempt completion leaves it available to the terminal.
- `tui/daemon.Connection` owns a separate `/v2/control` connection and its
  authenticated `Hello`. Its Weft state machine keeps the socket inbox through
  `AwaitHello`, `Idle`, and `Waiting`; the terminal PID, not a short-lived
  bootstrap worker, bounds its lifetime. One outstanding request has a deadline
  and a monotonically increasing ID. An in-flight timeout closes control so a
  stalled writer cannot accumulate requests after repeated timeouts. An explicit
  replacement owns a new inbox; old replies cannot reach it. A lost mutation
  reply returns `UnknownOutcome(command)` without resending it.
  A retired owner is not a dead daemon. The route — address and credential —
  outlives it, so `tui/daemon/selection.reconnect` mints a second owner on the
  same route with a new inbox. `/sessions`, open and create borrow live control
  or reconnect inside their existing managed worker, never in the frame loop.
  A replacement monitors that worker and closes on cancellation or ordinary
  completion; the model retains only the original host and its route. Once
  that original owner retires, each explicit action pays another handshake.
  Control has no background catalogue subscription to preserve, and nothing
  is automatically resent. A borrowed control still has one outstanding slot:
  concurrent requests can return `Busy` rather than queueing. Recovered actions
  use separate temporary owners and their own authenticated hello epochs.
  `tui/daemon/protocol` is the independent, total control codec:
  `Page` is bounded to 100 authorized records, lifecycle requests use the hello
  epoch, and `GetOperation` refuses an operation from another epoch locally.
  Metadata/default reads never imply an open. Cleartext credentials are allowed
  only for literal loopback endpoints — `127.0.0.1` and `[::1]`, bracketed
  because that is the form `uri.parse` leaves in a parsed URI's host; remote
  control requires `wss`. The codec
  caps a complete frame before JSON parsing, but does not claim a preallocation
  bound in the inherited Stratus parser.
- `tui/bootstrap.Options` describes local-launch inputs, while
  `tui/bootstrap.Target` is the authenticated endpoint handed to the ordinary
  connection path. `tui/bootstrap.SessionChoice` is the canonical workspace
  and database identity recovered from one statically validated launcher
  record. Bootstrap policy, record validation, retry timing, executable
  discovery order, and lifecycle decisions remain in Gleam.
- `tui/bootstrap.resolve_daemon` returns a `tui/daemon/bootstrap.Connected`
  independent of workspace selection. It uses the shared `host/endpoint`
  record, releases the launch lock before the child adopts its native fence,
  and checks v2 control hello against the published epoch. Existing live
  daemons bypass executable/config discovery. Default startup highlights a
  catalogue row and waits for Enter; an explicit `--session` selects it.
- `tui/session_selector.State` retains one authorized, revision-fenced page.
  `/sessions` does not scan workspace launch records. `tui/daemon/selection`
  resolves the selected row and canonical workspace, attaches directly when
  resident, or explicitly opens and observes the returned operation.
  `session_selector.Prompt` is the picker's other state: `d` opens a
  `ConfirmingDelete` for the highlighted identity, and only `y` answers it,
  so no single keystroke can destroy a conversation. The answer names the
  identity the question was asked about rather than whatever is highlighted
  when it arrives. `tui.ControlRequest` is the one job slot the picker's
  paging and its deletes share — the picker can do one or the other, never
  both — and `session_selector.without` drops the row on the daemon's
  confirmation rather than re-listing, which would move every other row
  under the cursor. A refusal reaches the footer as an error and the page is
  left alone. The confirmation explicitly includes stopping the selected session
  before deletion; the job remains asynchronous while cleanup settles.
- `tui/attachment.Status` owns one provisional replacement. A deadline-bounded
  Weft task publishes its socket to terminal-owned subjects. The terminal
  validates the initial cut, acknowledges it, observes task completion and
  checks adoption before replacing the old socket. `start_relayed` lets the
  native driver select the same outcomes as the interactive loop.
- `tui/session_channel.Channel` is terminal-owned state, not another actor.
  It admits one request at a time, grants one snapshot fragment per reply, and
  reconciles at 250ms while idle. `Update.Captured` carries a `Capture` saying
  what asked for the cut — `Notified`, `Refreshed` or `Requested` — which
  names the path a particular cut took. Which of them wins is a race with the
  250ms refresh, so a fixture that must know whether pushes arrived counts
  `Update.Noticed` instead: the lane emits one per `committed` frame before
  deciding whether to capture, and `Model.notices` accumulates them. Its existing outgoing slot can retain one
  immutable unsent mutation behind a capture of an already adopted session.
  `Disposition` distinguishes `Waiting`, `Sent`, and `DefinitelyNotSent`;
  waiting allocates no mutation ID or response deadline. A valid completed cut
  refreshes authority before the retained command is sent exactly once.
  `Model.pending_submission` stores only composer-versus-overlay ownership:
  the visible text, attachments and mode stay in their original fields and
  remain locked until sending or cancellation. Escape cancels unsent work
  before abort handling; replacement cancels it on the original attachment.
  Overlay sends never clear unrelated composer text. A sent request whose
  reply is lost still becomes `UnknownOutcome`, never an automatic retry.
  Explicit replacement uses `retire` before changing the visible session, so
  a sent request keeps its original identity. Replay derives that same outcome
  from the existing `Closed` marker for the current lane, not a candidate.
  [ADR-010](../../docs/adr/010-retain-one-unsent-terminal-command.md) records
  the waiting-state and cancellation rules.
- `tui/snapshot` validates attachment identity, exact credits, fragment
  offsets, immutable entry identity and payload limits. `tui/snapshot_view`
  projects captured leaf ancestry with pure `core` and `machine` codecs.
  Missing parents remain unloaded rather than being assigned to main.
- `tui/approval.Review` binds the displayed action, requested grants and
  register seq. Exact resolution lookups have their own channel lane; sparse
  lookup metadata cannot replace conversation history or configuration.
  `tui/approval_panel` displays the exact captured action, grants, tool and
  sequence as escaped literal JSON in a scrollable panel. Its 16 KiB displayed
  detail limit is a presentation bound: incomplete detail refuses approval,
  while denial remains available under the captured sequence.
  `tui/sessions` and workspace-record bootstrap remain historical host-test
  seams, not the live default selector.
- `host/bootstrap` is called directly, with no shim between. Shared
  operating-system facts and actions — private and bounded file operations,
  process identity and launch, a kernel lock, loopback port reservation, time,
  and SHA-256 — live there because the daemon needs the same ones, and a
  forwarding module over them was one more place for three copies of the same
  doc comment to drift. `tui/internal/ffi_terminal` is what is left: the three
  actions only a program that owns a terminal wants — `silence_logger`,
  `run_forwarding` and `halt` — and `tui_ffi.erl` holds exactly those three.
  `tui/internal/ffi_file` adds a weft deadline to `host/bootstrap`'s own
  bounded reads rather than declaring externals of its own.
  The shared Erlang implementation must not acquire bootstrap policy. Every
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

- **Depends on**: `host` for shared OS bootstrap and WebSocket transport;
  `core` and `machine` for pure total entry/register/state decoding; `weft` for guarded,
  deadline-bounded connection startup; `etui` at commit
  `ff80e0e21580a4b0077cc6989b6dc551af320505` with bounded input bursts and POSIX flow control disabled in raw mode; Mork
  1.12.x for CommonMark;
  and small Gleam utility packages. Stratus is a host dependency, not a direct
  TUI dependency. Etui is pinned
  because its public API is still moving quickly. Loom issue #345 tracks
  upstreaming the complete remaining fork stack, including the earlier polling,
  frame-diff, and input-batching commits retained by this pin.
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

- After model discovery, the terminal requests `skills` metadata pages through
  the normal correlated read slot. Bodies stay server-owned. Tab or Enter
  completes a selected skill name with argument space; submission sends the
  existing prompt command and the daemon expands the selected instructions.

- **Commands out**: `subscribe`, `prompt`, `prompt_content`, `models`,
  `set_config`, `abort`, `steer`, `follow_up`, branch-scope `fork`,
  standalone `compact`, `schedules`, `schedule_cancel`, `snapshot_next`,
  `catch_up`, `history`, `escalations_get`, `approve`, and `deny`.
- **Live events in**: correlated `snapshot_begin`, `snapshot_chunk`,
  `snapshot_end`, `mutation_outcome` (`admitted`, `committed` or `queued`),
  bounded auxiliary snapshots, and errors. Unknown tags, wrong versions and
  wrong reply IDs fail closed. Raw entries, usage, configuration and pending
  approvals arrive through a completed cut, not unsolicited legacy events.
- **Pushed frames in**: an envelope with no `reply_to` is a push. `committed`
  (with its sequence in the envelope) is a notice that moves a catch-up
  earlier; `presence` and `attachment` are the same trigger; `stream_delta`
  is the live answer in order; a pushed `error` is a daemon-side failure
  reported without closing the socket. An event name this client does not
  know is dropped. A daemon that predates live delivery pushes none of
  these, and the terminal behaves exactly as it did.
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
  `/sessions` opens the daemon's authorized metadata selector. `/approve <id>`
  and `/deny <id>` answer the captured request; `/approvals <id>` loads an exact
  decision. `/notes` opens the
  current note values with their revisions, `Shift+Tab` toggles the compact rail,
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
- **Live submission**: Enter queues a prompt behind current work. Tab selects
  one steering draft; submitting it puts the message at the front of the host
  queue and stops the observed operation. Escape stops current work while the
  host retains all queued turns. `pending_inputs` supplies queue identity and
  order, including repeated text and other peers; the terminal replaces rows
  from each cut instead of guessing which user entry consumed an echo. The
  interrupt marker carries the stopped operation and clears when a cut shows
  idle or a successor. Older recordings retain their local echo semantics.
- **Compact tools and changes**: `tui/tool_activity` groups consecutive tool
  calls, joining results by call ID and ending a group when a later response
  reuses an ID. Compact history shows the latest three calls and the group's
  failure count; Ctrl+g recovers the original entries. Captured `fs_edit` diffs
  remain the explicitly labelled fallback when a worktree observation is
  unavailable. Current-action labels use the captured operation's
  effect-pending batch indices rather than unmatched transcript calls.
- **Responsive changes pane**: `/diff` toggles a persistent right-hand pane at
  140 columns or wider and a single-panel changes view below that width. The
  pane temporarily occupies the agent rail's space without changing its saved
  visibility. Conversation and changes retain separate scroll offsets; wheel
  input follows the pointer, while PgUp/PgDn scroll the open changes view.
  Layout, wrapping, and selection use the same body geometry. Captured diff
  rows reuse unchanged line layouts at the same width and discard old keys
  when the captured projection changes. Closing the pane releases its cache
  and restores the conversation's scroll position.
- **Worktree navigation**: `tui/worktree_view` validates a bounded Git board
  from the attached session. `/diff` requests an observation; Up/Down selects
  all changes or a raw file identity, Enter returns to the composer, Ctrl+d
  changes focus, and `r` refreshes while the navigator has focus. Mouse file
  selection and patch scrolling use the rendered pane geometry. Refresh keeps
  the selected raw path when it still exists. A pending reply releases the
  command lane; the final push must match the actual sent request ID and
  attachment. Failed refresh retains the previous board with a stale label.
  Selection and received observations invalidate the render revision. The
  patch cache stores the board and selection that produced its rows, so a
  reply applied before a terminal tick still replaces the previous patch.
- **Queued-input editing**: bare `/queue` opens `tui/queue_editor`; `/queue text`
  still submits a queued turn. Enter fetches the complete selected item,
  ordinary Enter inserts a newline in its editor, and Ctrl+s saves its exact
  revision. Images remain on the server. The draft is separate from the
  ordinary composer and survives Escape, conflict, or an uncertain save.
  Ctrl+r explicitly reconciles the same item and queue namespace. A changed
  session, epoch, or incarnation cannot adopt an old draft, even if the opaque
  item ID repeats; a new connection within that namespace may reconcile it.
- **Completion and live jobs**: `tui/completion_summary` retains observed
  operation start boundaries and processes a result before a successor in the
  same cut. It attributes captured edits and paired tool outcomes only within
  that ancestry interval. Missing ancestry is partial; a missed start is
  unavailable. The latest card and `/summary` show actual command exit codes,
  queued work, and a separately timestamped `tui/live_jobs` roster. Completion,
  opening the summary, or explicit `r` requests the roster once when the lane
  is free. Ordinary transcript refreshes do not query job history or run Git.
  `session_channel.RequestRefused` carries the command and actual request ID,
  so an unrelated refusal cannot settle a queue, worktree, or jobs request.
- **Current notes**: `/notes` requests a separate bounded `notes` observation.
  `tui/notes_view` validates values, last-write revisions, capture revision,
  excerpt markers and omitted counts. `r` refreshes the panel without a new
  model turn. Historical run-start digests remain explicitly historical.
- **Paste**: small pastes retain the ordinary editor path. A paste estimated
  at 400 tokens or spanning eight lines becomes a compact attachment in the
  input row; the full bytes are appended to the editable instruction only
  when the prompt is sent. A single pasted local path becomes an image
  attachment only when it is a regular PNG/JPEG/GIF/WebP file no larger than
  20 MiB; one prompt retains at most four images and 20 MiB of raw image data
  in aggregate. The chip shows a terminal-sanitized filename, MIME, and size,
  on its own row above the editor: beside the editor it took its width from
  that summary and left the editor a column or two, so the row costs one line
  of prompt height and the editor keeps the full interior width.
  Unsupported files and multi-token paths stay text, while read errors preserve
  the editor and show a local error. The backend enables bracketed-paste mode
  so a real terminal paste arrives as one event. Backspace on an empty editor
  drops the newest attachment.
- **Prompt view**: the editor retains the exact source and cursor state used by
  history and submission. Rendering wraps that state by terminal cells into a
  bounded one-to-four-row viewport; it never inserts newlines into the prompt.
- **Footer**: completed coherent cuts establish cumulative input, output,
  cache-read, cache-write, and cost fields. The
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

- **The global endpoint fences the native VM.** Shared `host/endpoint` paths
  retain one Starting/Ready record, native PID and birth identity. A live or
  unknown identity is never replaced after a failed probe; killing a BEAM root
  while its VM survives does not permit another daemon. Malformed records and
  an existing catalogue without a record fail closed. Reuse requires an
  authenticated v2 control hello with the same epoch.
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
  says `responding`. The same title states whether Enter queues or steers. Its
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
- **Layout hints belong to the current projection.** Compact outcomes can
  change when a tool result arrives, so record identity alone is not a valid
  key. `record_line_cache` keys the complete `Line`, including its speaker,
  and only reuses rows at the same width. Each rebuild starts a fresh map:
  discarded branches and superseded outcome text leave the cache. Session
  adoption, full snapshots and `/clear` empty it. This saves repeated Markdown
  parsing, sanitizing, span tokenization and cell-width calculation; it does
  not bound the durable history itself. `dev/tui_replay_dev.gleam` validates
  admitted record counts and failure notices before reporting replay time.
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
- **Injected notes are not operator speech.** The server's run-start digest is
  a user message. Human authorship does not identify host-injected notes, so the
  client recognizes only the exact server-owned preamble and `agent-notes`
  fence, hides that envelope from conversation, and exposes it through
  historical fallback of `/notes`. Do not broaden this into heuristic filtering.
- **Large context stays bounded without data loss.** Compact paste indicators
  are presentation state only. Submission expands the original bytes, and a
  durable large user turn stays previewed until detail mode asks for it.
- **Image turns never become live-operation steering.** The client submits one
  non-empty text block first, when present, then image blocks in drop order.
  `prompt_content` is the only frame that carries an image, so a slash command
  is refused before the editor is cleared and both the instruction and the
  attachments survive. Liveness is not a local question: the daemon queues a
  prompt aimed at a busy strand. Only the file bytes and magic-derived MIME
  reach the wire; local paths remain presentation state.
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
- **Session replacement is fail-preserving.** Explicit control selection,
  WebSocket startup and initial capture share one 90-second Weft deadline.
  Each attempt owns distinct terminal-created subjects. The old socket keeps
  progressing until the terminal validates the new session/epoch/incarnation
  and complete initial cut, observes original worker completion, and adopts
  the socket. Failure closes only the provisional connection. Late packets
  from old subjects cannot repaint the adopted view; a task outcome alone is
  not a socket-drain proof.
- **Every inbox the terminal reads is created by the terminal.** A `Subject`
  delivers to the process that created it, and receiving on one owned by
  another process panics. `attachment.start` creates frames, preparation and
  outcome subjects in the terminal before the worker starts. The worker owns
  only its acknowledgement subject. The shared socket guardian monitors the
  terminal owner through cancellation and adoption. Actor-backed native tests
  reduce already selected messages directly rather than requeueing them.
- **Approval is an exact captured decision.** Approve echoes the displayed
  action, requested grant set and register seq; deny echoes the same seq. An
  observer cannot activate mutation controls. Disappearance triggers at most
  eight exact lookups, never an inferred author or status. Sixteen resolved
  summaries retain no grant payload; excess resolutions are explicitly not
  loaded and can be requested by ID.
- **Payload limits are not heap measurements.** Transfer validation permits
  records through 32MiB, but decoded presentation is at most 4MiB per entry and
  8MiB/100 entries in the retained window. Larger records are drained through
  bounded fragments and leave an explicit immutable-ID/seq placeholder.
  Metadata is at most 2MiB. Decoding a 4MiB record measured about 0.3 seconds;
  these limits do not establish a 16ms frame budget or exact BEAM RSS.
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
  the conversation channel writes each tagged message before decoding it, so a
  recording reproduces a decoding bug rather than hiding it. A gateway frame
  is stored as the gateway's own bytes because the protocol has one wire
  form and a second encoding of it could only ever disagree. A failed append
  is silent: etui owns the screen, so there is nowhere to print, and a
  recording that stops recording is not a reason to end a live session.
  New logs begin with local format 2 and tag request credits, raw frames,
  and adoption with a terminal-local attempt identity. Replay uses the same
  channel reducer without a socket or transport clock, retaining only the
  current and provisional protocol state. Only an explicit adoption marker
  changes the visible session. Mixed formats are rejected; historical
  untagged logs remain replay-only. [ADR-009](../../docs/adr/009-record-terminal-attempt-custody.md)
  records the ordering and the bounded nonsecret request selectors. These
  are protocol-buffer limits, not a total replay-memory claim: the file
  decoder still reads a complete local log before running its script.
- **Manual replacement is not catch-up.** `/sessions` validates a provisional
  attachment while preserving the old projection. The adopted channel runs
  credited `catch_up` at 250ms and includes metadata-only changes. Equal cuts
  do not restart animation or invalidate the transcript, and a replay goes
  through that same reconciliation rather than repainting every recorded cut,
  because a replay that draws frames the live client did not is not
  reproducing the session; its outbound half, the decision lookup, is inert
  while the peer is `Replaying`. Disconnect closes the channel without
  automatic reconnect or mutation resend.
- **A pushed frame never owns the wire.** Frames the daemon volunteers are
  read in every phase but `Closed`, and they allocate no request identity,
  spend no snapshot credit and cannot fail the lane. Correlation is unchanged
  for anything carrying `reply_to`: a stale or mismatched identity still
  closes the socket, in `Ready` as everywhere else.
- **A commit notice is idempotent and order-free.** It carries the sequence,
  never the record, so what it does is move the catch-up earlier — issued at
  once in `Ready`, remembered as due and spent at the next ready transition
  otherwise. A sequence the lane already holds, or one arriving before any cut
  exists, is dropped, and any number of deferred notices collapse into one
  capture. The 250ms idle refresh is the recovery path for a lost notice and
  the only path on a daemon that pushes nothing.
- **Provider requests own live fragments.** Modern streams carry operation
  and generation identity. A new generation replaces every prior kind on its
  strand; `end` replaces only its own generation with an empty marker. A late
  cut cannot erase a newer pushed request, and a late terminal cannot erase
  its successor. The marker suppresses every older captured preview. A
  captured last result for the exact operation also retires its fragments,
  covering relay failure paths which omit the optional observer's end event.
  An absent or unrelated latest result is not retirement evidence.
  Captured previews are rendered from the current cut and never appended to
  pushed history. Older recordings retain operation-only reconciliation.
- **A live stream is bounded, and its text is owned.** `Stream` carries the
  bytes its fragments weigh, and past twice `tui.live_stream_limit` — 24 KiB,
  the same clip the snapshot preview takes — the fragments collapse into one
  holding the newest limit's worth. The headroom is what makes the collapse
  amortised: coming back to exactly the limit would put the next token over it
  again and charge the copy per token. Every fragment is rebuilt on the way in
  rather than kept as it arrived, because a delta's `text` is a slice of the
  whole received frame and keeping the slice keeps the frame.

  Both halves are load-bearing and both were measured. Pushed delivery makes
  one frame per provider token, and before this the region grew without limit:
  each paint reflowed the whole accumulated answer, so the drain rate fell as
  the turn ran on, the socket stopped being drained, and the mailbox — every
  message a whole frame — became the leak. Two terminals were resident at
  32 GB and 26 GB beside daemons at 3.5 GB and 1.6 GB. `stream_bounds_test` is
  that measurement kept as a bound: over 40,000 deltas the model holds flat at
  a few hundred KB and drains above 3,500 deltas a second, against growth in
  every one of memory, pinned bytes and pinned binary count before.
- **Attachment identity is not a transient notice.** The committed cut supplies
  the visible author name, role and presence count alongside configuration.
  Model-list replies and other notices cannot replace that identity. A pending
  candidate cannot repaint it; after disconnection it describes the retained
  last view, while the closed channel refuses further mutation.
- **Uncertainty survives attachment replacement.** The terminal retains one
  bounded notice labelled `Last unconfirmed submission`, including the session,
  command and request identity. Ordinary transcript updates do not clear it or
  imply that the request failed. A newer unknown outcome may replace this last
  notice without claiming that earlier uncertainty has been resolved.

- **A passthrough forwards output, it does not interpret it.**
  `ffi_terminal.run_forwarding` opens a port with `exit_status` and
  `stderr_to_stdout` and writes every chunk to this process's stdout as
  it arrives. It is a new FFI rather than a reuse of `spawn_server`,
  which exists to start a *detached, paused* daemon and hand back its
  birth identity: nothing about a passthrough wants any of that.
  `stderr_to_stdout` because a passthrough that reordered the two streams
  would be worse than one that interleaves them as the child did.

## V2 integration evidence

The legacy recording decoder and golden replay tests remain available.
Attempt replay tests cover failed replacements, equal socket-local IDs,
missing credits and mixed logs; the real fast-start driver records and
replays initial adoption, a committed turn and terminal closure. The client
PTY fixture exports the native TUI, drives a real daemon through v2, and checks
a provider-conditioned reply, durable fork and detach. Its independent credited
subscriber checks SQLite content without using the TUI decoder. The persisted
driver fixture additionally uses real shared history and lazy restart, with
maintenance explicitly disabled. These deterministic transports do not prove
external provider-network behavior or replace the manual Herdr multiplayer gate.
The opt-in real-shipment bootstrap fixture also checks concurrent launch,
cross-workspace daemon reuse, unadopted socket cancellation, stable credentials,
native restart and metadata-only restoration before explicit reopening. Its
existing hostile-shell lock and launcher checks remain separate target steps.

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

### Reviewer and completion evidence

`reviewer_status` projects current operation phases and pending-input receipts
from the authoritative cut. It retains only a 160-character task excerpt per
captured live operation, keyed by operation and strand; a successor cannot
inherit the old task. Up to three reviewers stay visible above the composer,
including beside the automatic wide diff, with an overflow count directing the
operator to `/agents`. Missing prompt history and missing queue metadata remain
explicitly unavailable. Receipt never claims incorporation into reviewer work.

Notes distinguish a session advancing after their last read from a value
written before the current operation's acceptance. Neither fact proves a plan
is wrong; the panel labels the observation and offers a refresh. Completion
shows the designated final answer and captured file-tool paths. Successful
`fs_edit` patches supply recorded added/removed line counts for that operation,
separate from the worktree's Git totals; repeated edits count each mutation,
and shell-only changes have no fabricated file-tool attribution. The summary
also separates cumulative uncached/cache/output counts from the latest measured
request's input context. Reasoning remains a subset of output.
