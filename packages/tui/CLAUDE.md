# tui

## Agent workspace

`F2` and `/agents` open `agents.Inspector`, whose selection is a strand ID.
Arrows inspect without changing `Model.active_strand`; Enter explicitly opens
the selected transcript and recipient. Missing selections stay visible as
unavailable until navigation chooses another row. `n` visits the next attention
state, `a` opens the existing exact-request approval panel, and PgUp/PgDn scroll
the selected detail. The real composer stays visible below the workspace. Tab
transfers keyboard ownership to it without changing the inspected ID or recipient;
Escape returns to the roster. Editing uses the existing submission and command
completion paths, including the visible command palette. The ordinary
`Shift+Tab` rail shares the same task summaries, with a reserved Advisor section
and a separately labelled worktree observation. A missing Git observation is
never a clean-worktree claim. A `sub:` prefix is an identity convention, not evidence of a parent relation.

`agent_view.Row` is projected from one coherent `snapshot_view.View` and window.
It reuses `reviewer_status` for accepted task excerpts and effect-pending tools,
then decodes `op.state` and `strand.last_result` for waits and terminal outcomes.
An idle strand with captured pending input is shown as halted; queued input on
a live operation is receipt evidence, never an operator question. Pending
approvals match both strand and a live current operation; stale journal records
cannot replace a terminal outcome. Update excerpts retain their
exact assistant entry ID as well as operation identity; successors and missing
newer answers cannot inherit a misleading old update. Disconnect makes current
state unavailable while leaving the previous observation readable.

`agent_activity` names dependency waits only from current effect-pending
`agent_wait` calls with valid run handles. Recent tool summaries join invocation
and result identity on the captured branch after the operation's accepted prompt.
An absent prompt boundary yields unavailable history rather than older-run tools.
Approval previews show the captured action before opening the exact decision
surface; they never choose a grant. General assistant questions remain in their
update and transcript because the protocol has no separate pending-question fact.

The inspector keeps Activity, Messages, Notes and Collaboration under
`agents.Detail`, switched with 1/2/3/4. `agent_messages` admits sends only after the sending strand's
accepted operation prompt. It joins results within that branch and before a
later reuse of the call ID. `Model.agent_messages` retains the latest twenty
verified sends across operation completion, with message bodies bounded to 4096
characters plus an excerpt marker; changing sessions releases this cache.
Acceptance means the tool accepted the send, not that the recipient read it.
Unobserved older history remains explicitly unavailable. The Messages tab
renders a selectable invocation-identity list. Wide rows use three lines for
direction, a short observed-result badge, and the body excerpt; the selected
body occupies the adjacent preview. Stacked layouts preserve the same facts and
PgDn pages by the visible body viewport without skipping wrapped lines; in the
40×12 fixture that viewport is one line. `[` and `]` select a message,
Up/Down select an agent, Enter opens the inspected agent, and `o` explicitly
opens the selected sender and changes the composer recipient. Tab transfers to
the composer. Captures preserve message identity and body scroll instead of
resetting either while the observation remains present.

The inspector and standalone `/notes` share one notes browser. It uses the
inspected strand in the Notes tab and the active strand when standalone.
`notes_requested` coalesces reads behind the existing session channel;
`NotesSnapshot` values from a different target cannot replace the visible board.
Entering another owner resets selection to that owner's first key. Refreshing
the same owner retains the stable key through reorder and clamps the note scroll
to the refreshed body. Note mode and scroll remain independent of transcript
detail mode and transcript scroll. Only the selected body is formatted, with
modifiers and links preserved. Compact layouts retain stale and omitted facts
and give the body the rows actually available. Up/Down or brackets select notes, Ctrl+g
switches readable/raw note mode, PgUp/PgDn scroll the body, and `r` refreshes.
The composer remains intact, and opening `/notes` clears the competing diff
surface.

`StrandWorkspace` parks the complete editor, attachments, command history,
submission mode and bounded reader under `(session, strand)`. Navigation restores
that owner before rendering. Retired strands and old sessions release history
buffers while retaining unsent drafts. A missing captured recipient cannot submit
and cannot silently fall back to another strand. Reading anchors are relocated
from the restored endpoint, never from the strand being left. A daemon-returned
held prompt appends only to its original strand's draft. Session replacement
clears advice and goal observations and their pending request identities, then
refreshes the new session, even when both primaries are already running.

`appearance.Palette` adapts semantic colors once per completed frame. Launch
reads `COLORTERM`, `TERM`, `COLORFGBG`, and `NO_COLOR`; rendering performs no I/O.
Truecolor uses the dark palette unless the background hint names ANSI 7 or 15;
limited-color terminals use their ANSI palette, and `NO_COLOR` uses terminal
defaults. Content, links, wide-cell markers and modifiers survive adaptation.
`theme.quiet_text` is readable secondary text without a dim modifier; structural
dividers have their own color. Status labels and selection marks carry meaning
without color. `gleam dev agents dark|light|ansi|plain` runs an illustrative,
provider-free native fixture through the capture decoder and the shipped loop.

## Todo panel

`todo_panel` draws the active strand's todo board between the conversation
and the composer. The board is the `details.todo` of the newest successful
`todo` result, decoded with `core/todo_list.decode`, so the panel and the tool
cannot disagree about a stored board. `Model.todo_boards` keeps each strand's
newest board across cuts, because a capture window that has moved past the
last `todo` call would otherwise blank the panel; session replacement releases
it. A strand whose capture reaches no board gets one ordinary `notes` read per
session (`Model.todo_seed`, `todo_asked`, sent by `surfaces.service_todo_seed`
from the tick once the read lane is free). Any `notes` reply seeds a missing
board from its complete `todo` row, and never replaces a transcript board or
parses an excerpt. The "notes refreshed" notice appears only while a notes
surface is open.

The panel's rows come out of the body inside `layout.queue_body_layout`, between
the conversation and the queue card, so every hit-test and scroll path sees the
smaller conversation without knowing about the panel; `layout.todo_area`
recomputes the same split for painting. It may take a third of the body and
always leaves the conversation four rows. Only the phase holding the active
task is expanded, other phases fold into one row, a long phase is windowed
around its active task with counts above and below, and a finished board is
one row. Each status has a glyph as well as a color (`✓ ▸ ○ ⊘ –`). A settled
`todo` call is one compact transcript row naming what it changed and the
progress it left, which keeps the compact height rule.

## Automatic permission dialog

A newly pending exact request opens `approval_panel` for an owner or operator.
The compact dialog is anchored to the bottom of the terminal, capped at eighteen
rows on an ordinary screen, and bounded by the available height on smaller ones.
Its readable view asks a tool-specific question, names the requester, shows the
captured action on a raised background, and lists the exact requested authority.
It also states whether session persistence is available. A known `fs_write`
shows `File` and `Content`; actual content newlines become preview rows, while
each row escapes control bytes, bidi marks, and literal backslash sequences
independently. Unknown fields and complete `fs_edit` payloads retain escaped JSON
fallback instead of dropping fields. `d` or Ctrl+g switches to the complete
escaped raw request, including the captured action digest and the exact owner
and operation. PgUp, PgDn, Home,
and End scroll request detail independently while the choices remain visible.

The dialog captures the record's sequence, action and grants. Its owner label
comes from the exact escalation ID and sequence in the captured register; absent
scope stays unavailable instead of borrowing the selected strand's identity.
Metadata refreshes cannot replace that question before a decision. The terminal
tracks presented questions by ID and sequence, so dismissal does not reopen the
same question and a reopened request with a new sequence is offered again.

The three choices remain vertical at every width, including the 40×12 fallback.
No action is selected on opening. Up/down, left/right, or Tab explicitly selects
Allow once, Allow for session, or Deny; Enter confirms and Escape defers. A
choice the captured request cannot encode stays visible as unavailable and
navigation skips it. Denial remains available. Session approval sends `approve`
with `scope: "session"` and is available only for complete filesystem or
full-network grant sets. The styled question, preview, and focus treatment do
not change consent: the panel never widens, substitutes, or invents authority,
and a decision echoes the exact captured action, grants and sequence. Legacy
`/approve` retains once-only behavior. The server commits the session authority
and exact decision atomically. See protocol 041.


## Session directory access

`/add-dir PATH` adds read access; `/add-write-dir PATH` (also `/add-dir --write PATH`) adds read and write
access. The parser preserves spaces in the remaining path. Both use the
session-scoped `set_config.add_directory` command, subject to the same mutable
attachment gate as approvals. The terminal displays canonical additions from
the server's committed config snapshot. Grants belong to the saved session
and survive reconnect or reopening; they affect subsequent invocations.


## Streamed response handoff

For generation and poll observations carrying a reserved response entry,
`stream_identity` validates the entry ID. An end marker closes fragment intake
while the already-bounded answer stays visible. The exact saved entry replaces
it during capture adoption; unrelated records and stale idle captures do not.
A successor request or exact operation result also retires it. Legacy and
summary observations retain their old completion behavior. See
`protocol-change/036-stream-response-handoff.md`.

## Build identity and daemon updates

`loom version` (also `loom --version`) reports the invoked client's launcher
metadata: release version, full build commit and platform. It does not inspect
a live daemon or the current directory, open a terminal, or create state.
Unstamped direct runs retain the honest `dev`/`unknown` defaults. Shipment and
bundled-release smoke checks exercise the command without a host daemon.

The authenticated control host owns the daemon build identity. `render_cut`
projects a mismatch into each transcript capture, so successful adoption and
later refreshes cannot erase it. Missing identity stays silent. Shipment and
release launchers export their own build metadata, replacing inherited values.

A local terminal makes one bounded reconnect attempt after conversation loss.
`bootstrap.reconnect_daemon` uses read-only control status and native endpoint
observations before selecting a host. It can reuse an accepting VM; a draining
or unreachable live VM remains fenced. Only positive native vacancy permits
one normal resolver launch. Polling and startup share the deadline, and session
open remains outside that polling loop. Held prompt returns restore text in the
composer; image bytes must be reattached by the operator.

## Purpose

The shipped native terminal client. It authenticates one daemon control
connection, lists session metadata, and explicitly selects a v2 conversation
connection. It renders completed coherent cuts and turns keyboard input into
slash commands. `make tui-shipment` exports its compiled
BEAM closure beside a thin `bin/loom` launcher, and `make dist` packages
that tree separately from the self-contained server.

Interactive launches require both terminal stdin and stdout before starting a
local daemon or entering terminal mode. Help, replay, session commands, and
extension passthrough retain their noninteractive paths. The etui backend owns
later input closure and terminates its reader and cleanup drain on EOF/error.

## Module layout

`tui.gleam` holds the entry points (`main` and the launch parsing,
`new_model`, `loop`, `run_script`, `replay_steps`, `connect_remote`) and the
event dispatch (`update`, `apply_input`, `settle_update`). Everything else
that used to share its 15,500 lines (issue #374) lives in modules under
`tui/`, listed here in import order. Gleam forbids import cycles and none of
them may import `tui`, so a module may import only those above it in the
list:

- `tui/model`: the `Model` record, the types it names, and the helpers every
  reducer shares (`append_system`, `append_error`, `invalidate_frame`,
  `invalidate_transcript`, `mark_activity`, `queue_owner`,
  `active_strand_phase`). Importers alias it as `tui_model`, because `model`
  is the local variable in nearly every function and would shadow the module
  name. Constructors stay unqualified.
- `tui/transcript_lines`: `Line`s from durable entries, streams and tool
  calls. A new kind of transcript row starts in `entry_lines`,
  `message_lines`, `assistant_block_lines`, `record_lines`,
  `activity_call_lines`, `tool_call_summary`, `tool_result_lines` or
  `stream_lines`.
- `tui/layout`: screen rectangles for painting and hit-testing, and the
  transcript width and height.
- `tui/render`: `view`, `cached_frame` and `render_frame`; a pure function of
  the model.
- `tui/outbound`: `send_frame`, `apply_submission` and `mutation_refusal`.
- `tui/surfaces`: the `service_*_read` functions, their reply handlers and the
  `sync_*` edge detectors for notes, the queue, the worktree diff, live jobs,
  context, advisor nudges and the goal.
- `tui/inbound`: `drain_connection`, `accept_connection_message`,
  `apply_channel_update`, `apply_event` and `render_cut`, with stream, tail,
  usage and cache accounting.
- `tui/session_control`: daemon control requests and reconnection.
- `tui/projection`: `refresh_render_cache`, `refresh_diff_cache` and the
  record row cache.
- `tui/submit`: composer submission, input history, interrupts and target
  switches.
- `tui/interaction`: key, paste, mouse and candidate-event handling.
- `tui/tick`: `update_tick`, `settle_tick`, the frame cache, viewport pacing
  and the Herdr reporter.

The module boundaries also bound compile time; see the two parameter
boundaries and the split's measurements under Invariants.

## Key Types

- `session_selector.Collection` distinguishes active and archived pages. Active
  `d` confirms archival; `a` switches collections. Archived Enter restores without
  opening, while archived `d` explicitly confirms permanent deletion. Page loads
  carry their collection so their response updates the matching picker. Archive
  and deletion share the existing bounded stop-and-retire path in
  `daemon/selection`; restoration sends one control request without admission.

- Reading mode remains frozen at offset zero until an explicit return to live
  output. Older-page demand starts two viewport heights before the loaded boundary,
  keeps one bounded page outstanding, and continues through pages
  containing only other strands. Expanded tool results reuse the compact
  invocation's source identity through `Call.result_source`.
- Bracketed inline paste inserts at the editor cursor, retaining both sides of
  an existing draft. Historical note digests and message bodies use readable
  nested text; Ctrl-G expands their complete content. Markdown wrapping keeps
  leading indentation on continuation rows.
- Successful `context_remaining` calls retain a compact measurement row. The
  remaining budget names the checkpoint when enabled and the context limit
  otherwise. Older results without structured details retain their text.
- Compaction entries show the pre-compaction token estimate and count of
  retained messages. Their checkpoint text remains in the durable entry for
  the model and exact history reads, but the transcript does not print it.

- Compact successful `fs_edit` rows include a 60-line inline patch preview;
  expanded history uses the same patch projection with the complete result.
  Failed edits and older results without a diff retain their summaries.
  Indented user-message rows preserve spacing and stanza breaks rather than
  passing through prose word wrapping; long source rows clip like code blocks.
- `ToolPatch` renders unified patches directly with addition/removal colors;
  unified hunk coordinates give removed rows their old-file number and added
  or context rows their new-file number. Hard-wrapped continuations repeat that
  source coordinate. Hunk counts bound numbering; metadata and patches without
  valid coordinates stay unnumbered. Filenames remain separate `PatchHeading` rows, and embedded fences cannot
  terminate a patch. The worktree navigator includes a separate committed view
  even when current status has no files. Its decoder accepts older hosts with
  an explicit unavailable notice and bounds new commit streams at four KiB.
- `notes_view.readable` unwraps one JSON document held inside a string value
  and projects objects as compact nested lists with readable field labels.
  Raw inspection pretty-prints complete JSON; excerpts remain literal.
  `session_selector.prioritize` sorts exact workspace matches first, related
  directories next, and preserves order within each group and selection by ID.
- `tui/transcript_lines.AdvisorMessage` names the advisor frames the transcript
  recognizes — `Advice`, `Nudges`, `Feed`, `GoalFeed`, and `Continuation` — each carrying the body left
  after its frame lines are stripped. `tui/transcript_lines.advisor_payload` extracts one from
  a durable message and `tui/transcript_lines.advisor_lines` renders delivered advice and nudges
  in full in both modes; feeds and continuations use `notes_view.Extent`.
  `composer.expand_hint` is the suffix every collapsed row ends with, shared with the `[loom] ` injection collapse so
  the two spellings cannot drift.
- `advisor_history.project` reads the bounded captured advisor ancestry and
  excludes entries inherited from main. The main transcript also shows each
  settled advisor text block in full under a separate "captured, not sent to
  primary" heading. A verdict annotation comes only from one valid `advise`
  request in the same assistant entry; it names a request, never its delivery.
  Missing older ancestry is labeled instead of implying complete history.
  Captured blocks join primary entries by durable sequence in the settled row
  cache, with entry-and-block anchors. The live primary tail stays last, and
  stream deltas do not rewrap settled advisor Markdown.

- `Model.reading_lines` retains one bounded transient projection when scrolling
  above the live tail. Incoming streams continue collecting without changing
  that projection; returning to the bottom releases it. Durable history keeps
  its existing frozen ancestry and row anchors. The composer border provides
  a clickable jump action that preserves an unsent draft; End also returns to
  the tail when the composer is empty.
- `tui/file_read_view` removes recognized edit digests and hashline anchors
  only from successful file-read presentation. Line numbers and source text
  remain; stored results and model-facing edit prerequisites are unchanged.
  `without_fresh_anchors` applies the same rule to a successful `fs_edit` or
  `fs_write`, dropping the `Fresh anchors:` block the result carries for the
  model — for an edit the patch preview beside the row shows what changed,
  and for a write the content came from the model already. Both go through
  the one pre-pass in `tool_result_lines` that already strips a read. A
  rejection's fresh anchors stay visible, being the reason it failed. The
  heading is produced in `tools`, which the terminal has no dependency edge
  to, so the literal is repeated there and a divergence draws the block
  rather than breaking anything.
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
  `history_view.resume` keeps the paged-in window on that return.
  `history_view.capture` merges a retained window with a cut only when the
  strand's leaf has not moved or the window's newest record reaches the
  cut's oldest sequence; otherwise the cut stands alone, because an interval
  between the two was never read and `before_seq` would sit beneath it. The
  same rule covers a parked strand's window and a reconnect's.
- A strand switch parks its editing and reading endpoint in
  `Model.strand_workspaces`, keyed by `(session, strand)`. It restores the
  incoming owner's complete editor and bounded ancestry before applying the
  current capture. `render_cut` releases parked reading buffers for retired
  strands and other sessions without evicting unsent drafts. The selected
  source anchor survives returning at a different terminal width.

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
- User messages have a warm shaded, labelled block. Assistant prose has a
  restrained cold background and the blue diamond mark; reasoning retains its
  explicit label. In compact mode a reasoning block is one `ReasoningDigest`
  row — the line count while it streams, its opening line and the expand hint
  once it settles — and `Ctrl+G` shows the block itself; a redacted block is
  its one-line marker in either mode.
  Compact tool rows retain every call while folding arguments and results.
  Unresolved code-mode calls retain a syntax-highlighted preview of six
  submitted source lines, with an omission marker. Confirmed success replaces
  source bulk with an activity/result summary; Ctrl+G shows the complete program
  and exact output. Failed diagnostics remain multiline in compact mode, bounded
  to eight lines and 1,600 characters with an explicit full-error expansion hint.
  Success marks derive from matched results rather than generic invocations.
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
  The bounded `ControlRequest` worker sends the mutation once and applies the
  acknowledged `SessionRenamed` row to the header and any open picker. It does
  not open the picker or reload its page. The owner and epoch checks remain
  server-side; a lost reply is not retried. `Model.session_label` pairs one
  name with its identity, so legacy switches cannot carry an old title.
  The name travels through `attachment.Target` and `Adopted` with the selected
  workspace and becomes visible only when that attachment is adopted.
  `workspace.session_name` uses cached workspace/branch context for new names,
  normalizes terminal text, and preserves graphemes within 256 UTF-8 bytes.
  [Protocol 019](../../protocol-change/019-session-display-names.md) describes
  the durable rename contract.

- `tui/model.Model` is the immutable presentation state. Durable entries,
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
  Top-level and subcommand help are also non-interactive: the `--help` and
  `-h` flags anywhere in argv, and the bare word `help` in first position,
  print usage before the logger is
  silenced — `loom --demo --help` describes the launch rather than failing
  on the flags before it, while `help` elsewhere stays a value, so the
  `ext` passthrough never intercepts a word that belongs to the server.
  Help does not create state, contact a daemon,
  or write terminal escape sequences. An
  `Invalid` launch writes its reason to stderr
  and exits nonzero instead of entering the alternate screen.
  `loom ext …` is a passthrough to `loomd`'s own `ext` subcommand: `main`
  answers it before it builds a model, so nothing draws a frame and no
  terminal state is installed on the way past. Its three help forms are
  local instead: the client-only shipment can print extension usage without
  locating `loomd`. The private copy is compared with `loomd ext --help` by
  the shipped acceptance, preserving the shared text without an inverted
  package dependency. The daemon is located by
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
- `tui/model.Peer` says where this client's commands go, and replaces the
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
- `tui/herdr` is the Herdr multiplexer integration, compiled in because this
  terminal is a single binary with no hook directory for Herdr's installer
  to drop a script into. `configure` gates on `HERDR_ENV=1` plus
  `HERDR_SOCKET_PATH` and `HERDR_PANE_ID`, the same three variables every
  scriptable-host adapter reads. `state_for` maps the model onto the pane's
  state over the three values Herdr's `PaneAgentState` lets an agent report:
  a pending approval is `blocked`, any live strand phase is `working`, and
  everything else — a settled operation included — is `idle`. There is no
  `done` to report: the reducer clears a strand's `live_phase` when its
  operation reaches the `done` phase, so a finished operation is already
  "no live strand", and Herdr derives its own `done` from an idle report on
  a tab nobody has looked at since. Reports are `pane.report_agent` and
  `pane.report_agent_session` over the pane's unix socket, sent only on
  change by a dedicated unlinked reporter process that delivers them in
  arrival order, each retried once and then dropped: the terminal's own
  session always wins over a pane report. Two rules decide what reaches the
  socket, and both are pure functions the tests pin. `announces` says the
  session identity is announced when it first becomes known and again on
  every switch, because `herdr session` resume keys off the announced id;
  nothing at all is published while no session is attached, which is the
  state the session picker is in. `config_for` refuses a `started_ms` below
  zero: the sequence is seeded from the wall clock, `seq` is an unsigned
  integer in Herdr's request schema, and the BEAM monotonic clock is an
  arbitrary-offset counter that is negative on macOS, so a monotonic seed
  would make the daemon reject every report. The
  one external is `tui/internal/ffi_herdr.exchange`, a deadline-bounded
  `gen_tcp` unix-domain round trip, because no stdlib or weft surface opens
  one.
- `tui/frame` renders a `Buffer` as rows of text, folding a wide glyph's
  continuation cell into the glyph and dropping the trailing blanks a
  full-rectangle paint always leaves. It is what a golden file holds and what
  `loom replay` prints, so the two cannot disagree about a frame.
- `tui/pacing` is the arithmetic of the terminal loop's two rates, with no
  model in sight: `FrameDebt`, `FrameBoundary`, `CacheFreshness` and
  `FrameDecision` with `frame_boundary` and `frame_decision` for frame
  pacing; `ViewportPacing`, `TickTraffic`, `ViewportAddress` and
  `PacePolicy` with `pace`, `policy`, `viewport_pacing`, `tick_traffic` and
  `viewport_address` for the viewport walk; and `poll_timeout_for`,
  `paced_poll_timeout` and `next_quiet_for` for the poll cadence. The
  functions in `tui/tick` and `tui/projection` that read and write the
  model call these and stay thin.
- `tui/selection.Selection` is a left-button drag in progress or settled:
  an anchor and a head in screen cells, clipped to the panel interior the
  press landed in (`tui/layout.hit_area`), so the transcript's border glyphs and
  the rail beside it are never part of a copy. `text` reads the covered
  rows back from the frame on display through `frame.row_text`, `highlight`
  adds the reverse modifier to those cells, and `clipboard_sequence` is the
  OSC 52 write. Transcript copies additionally remove only fixed speaker
  gutters recorded by the private row layout; authored indentation and
  screen-row boundaries remain unchanged. `FrameCache` owns the visible
  gutter map alongside its cells, so a paced scroll cannot pair old text with
  new metadata at mouse-down. Durable gutters follow the record-row cache;
  live fragments do not re-project retained history. Plain assistant spans
  share one shaded style per block to keep the live-stream memory bound. `tui/model.Clipboard` says whether that
  write reaches a terminal:
  only the interactive launch sets `TerminalClipboard`; a replay or a
  scripted test keeps `NoClipboard`, because their stdout is not one.
- `tui/protocol.Event` is the client-owned view of the frozen
  ClientGateway event union. Entry bodies cross the existing total
  `core/codec` decoder rather than growing a second durability codec.
  `ToolOutput(strand, operation, step, source_index, call_id, stream, text,
  total_bytes)` is the
  pushed rolling tail of a running tool call (`protocol-change/031`);
  `session_channel.ToolStreamed` carries it through the adopted lane and
  `tui/model.ToolTail` is what the model keeps — one per `{strand, operation,
  step, source_index, call_id, stream}`, replaced whole on every frame, drawn by
  `tui/transcript_lines.tool_tail_lines` as one `ToolResult` line under the live region:
  the stream's name and byte count so far, then the last
  `tail_lines_shown` lines of the window. That drawing happens only with
  details expanded; a compact transcript draws no window, because the row
  the settle replaces has to be the only row the call ever occupied.
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
  when it arrives. `tui/model.ControlRequest` is the one job slot the picker's
  paging, renames, and deletes share. `r` opens a bounded `Renaming` draft for
  the selected identity; Enter saves, Escape cancels, and Ctrl+U clears it.
  Pasted text belongs to that editor and leaves the hidden composer unchanged.
  `session_selector.renamed` applies only the acknowledged row, while
  `session_selector.without` drops the row on the daemon's
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
  `tui/approval_panel` presents a typed question, action preview and exact grant
  list, with the complete captured action, grants, tool and sequence available
  as escaped literal JSON. Its 16 KiB displayed-detail limit is a presentation
  bound: incomplete detail refuses approval, while denial remains available
  under the captured sequence.
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
  spans directly. `render(markdown, width)` takes the width the rows will
  occupy because a table is the one block whose shape must be settled before
  it is drawn: columns are measured in terminal cells with `etui/text`,
  narrowed by max-min fair share when the grid is wider than the width, and
  abandoned for one labelled record per source row only when no column can
  keep three cells. Callers subtract whatever prefix they will add, since a
  speaker mark or list marker is cells the grid does not have. Code rows
  carry a `▎ ` gutter rather than the block quote's `│ `, which is how
  `wrap_lines` recognises them without comparing styles, and they are
  hard-wrapped on cell boundaries so source indentation survives. GFM alerts
  are detected here, not by Mork, on the marker inlines of a quote's first
  paragraph. It never passes model text through HTML or an ANSI renderer.
- `tui/agents` projects the server's strand snapshot and `live_op`
  phase into a hidden-by-default rail and an inspector. It owns no second
  agent-lifecycle state.
- `tui/peer_links` owns the peer-grant inspector, exact target-strand draft,
  and review step. `tui.gleam` routes each inspected, linked, or revoked grant
  through a separate owner-authenticated daemon control request.
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
- `tui/advisor_pending.{Board, decode, lines, primary_strand,
  advisor_strand}` validates an observation of undelivered advice. The composer
  uses the count/recipient heading from `lines`; `pending_nudge_lines` exposes
  every received body in the scrollable transient tail, with a pending and
  not-delivered label. A server-omitted suffix is explicitly reported. The
  terminal neither drains this queue nor adds its observation to durable
  records. The primary/advisor constants remain copied from the server and
  pinned by gateway tests, because the terminal links no server package.

- `tui/goal_view.{Board, Status, PauseCause, LimitCause, CheckRun,
  check_output_limit, decode, lines, row, refusal}` is the session goal's
  surface (protocol 044). `Board` has
  two variants rather than one record of options, because "no goal is
  pinned" is a real state with nothing else to say about it: `NoGoal` is
  one stamp and `Pinned` is the whole goal. `Status` carries its cause for
  the two stopped statuses — `Paused(by:)` over four causes and
  `Limited(by:)` over two — since `paused` alone names an operator pause,
  an abort, zero-progress suppression and an unresponsive reviewer, which
  are four different things to do next. `decode` is total over a board this
  terminal did not write, with its own byte caps; an unknown *status* word
  is a worded refusal, while an unknown *reason* word becomes
  `UnknownPause`/`UnknownLimit` and the panel prints the server's `because`
  sentence, which is what `docs/client-protocol.md` §4.9.27 asks of a
  client. `CheckRun` is the operator's check as it last ran: the status is an
  option rather than a number with a sentinel, because a run the harness
  stopped has none and a printed `-1` would invent the command's verdict on
  the work, and a run carrying both a status and a reason is refused rather
  than resolved. `lines` is the block `/goal` prints into the transcript and `row`
  is the single line drawn beside the composer.
  `command.GoalStatus`, `GoalSet`, `GoalCheck`, `GoalClear`, `GoalPause`,
  `GoalResume`, `GoalBudgetInvalid` and `GoalCheckTooLong` are the parsed
  grammar; `command.goal_words` is
  what the palette completes past `/goal `, and
  `command.default_goal_budget` (200,000 tokens) is what a `/goal` with no
  `--budget` pins. `tui/model.GoalReport` says whether the next board is the
  operator's own question — printed — or an automatic refresh, which
  updates the row silently.

## Relationships

- **Depends on**: `host` for shared OS bootstrap and WebSocket transport;
  `core` and `machine` for pure total entry/register/state decoding; `weft` for guarded,
  deadline-bounded connection startup; `etui` at commit
  `22554e85ecb54e92d3c3afe734f42e0ed2eca5ec` with bounded input bursts,
  POSIX flow control disabled in raw mode, Unicode emoji widths, synchronized
  frames, and full-screen scroll-region presentation; Mork
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
  `catch_up`, `history`, `escalations_get`, `approve`, `deny`, and the six
  goal commands `goal_get`, `goal_set`, `goal_check`, `goal_clear`,
  `goal_pause` and `goal_resume`.
- **Live events in**: correlated `snapshot_begin`, `snapshot_chunk`,
  `snapshot_end`, `mutation_outcome` (`admitted`, `committed` or `queued`),
  bounded auxiliary snapshots, and errors. Unknown tags, wrong versions and
  wrong reply IDs fail closed. Raw entries, usage, configuration and pending
  approvals arrive through a completed cut, not unsolicited legacy events.
  Protocol 047 also permits a bounded pushed `usage_observation`. Its sequence
  deduplicates the row, while captured cumulative usage remains authoritative.
- **Pushed frames in**: an envelope with no `reply_to` is a push. `committed`
  (with its sequence in the envelope) is a notice that moves a catch-up
  earlier; `presence` and `attachment` are the same trigger; `stream_delta`
  is the live answer in order; `usage_observation` is a bounded per-operation reading;
  `tool_output` is a running command's tail,
  whole each time; a pushed `error` is a daemon-side failure
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
  `/sessions` opens the daemon's authorized metadata selector. `/peers` inspects
the active strand's owner-managed directional links; press `l` to choose a resident
session and enter its exact strand, `d` to revoke the selected direction, and `v`
to propose a separately confirmed reverse link. `busy_only` is the default wake
permission; Tab or the arrow keys select `may_wake`. Saved sessions remain
unavailable in the chooser and are never opened. Press `p` in `/agents` to manage
links for the selected strand. Press `n` to append a bounded inspect page; `r`
refreshes from the first page. Pages are fresh observations and the daemon checks
current authority again for each mutation. The peer view leaves composer text
untouched.
`/approve <id>`
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
  reuses an ID. Compact history retains every call and the group's failure
  count; Ctrl+g recovers the original entries. Code-mode source previews belong
  to their invocation, so pending, successful and failed calls keep the same
  bounded fenced-Gleam block instead of exposing the argument JSON. Captured
  `fs_edit` diffs remain the explicitly labelled fallback when a worktree observation is
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
  selection and patch scrolling use `diff_panel`'s rendered geometry. The shared
  layout gives the file list semantic status accents, a full-row text-marked
  selection, a sticky selected-file header, and explicit Navigator or Composer
  focus hints. PgUp/PgDn scroll the existing patch renderer and numbering.
  Focused navigation on a short terminal may borrow status-band rows only above
  the actual editor; it cannot cover the editor or footer. Compact mode retains
  the observation line and a readable Navigator help title. Focusing clamps the
  patch cache and scroll to the active geometry. Another overlay cannot borrow
  or receive mouse hits from the hidden diff. Refresh keeps
  the selected raw path when it still exists. A pending reply releases the
  command lane; the final push must match the actual sent request ID and
  attachment. Failed refresh retains the previous board with a stale label.
  Selection and received observations invalidate the render revision. The
  patch cache stores the board and selection that produced its rows, so a
  reply applied before a terminal tick still replaces the previous patch.
- **Queued-input editing**: the passive card above the composer shows up to
  three captured messages with queue/steer and editable/read-only badges.
  `Alt+q` or bare `/queue` focuses its inspector; `/queue text` still submits a
  queued turn. Opening the inspector preserves the transcript, ordinary draft,
  and attachments, even when a queue edit is retained. Up/Down changes the
  selected opaque identity, and PgUp/PgDn pages its captured excerpt. Enter
  fetches the complete revision only for an editable item; read-only items
  cannot request text the capture did not carry.
  `e` explicitly resumes the retained queue draft and cancels ownership of any
  pending full-text fetch, so a late response cannot replace the resumed edit.
  A clean editable draft permits fetching another item. Dirty, Saving, and
  Unknown drafts prevent a fetch from replacing them with another identity or
  namespace. Escape moves from Editor to Inspector, then to the composer.
  Ordinary Enter inserts a newline in the queue editor; Ctrl+s saves its exact
  revision. Images remain on the server. Ctrl+r explicitly reconciles the same
  item and queue namespace. A changed session, epoch, or incarnation cannot
  reconcile or save an old draft, even if its opaque item ID repeats; a new
  connection within that namespace may reconcile it.
  The queue reserves its rectangle before transcript rendering. Paging and
  capture refresh use that rectangle, and mouse hits exclude the inspector's
  controls and list heading. Compact cards share their excerpt width with the
  paging calculation and clamp retained offsets during rendering. At 40×12,
  the focused footer uses one row; a card with no inner row pages its excerpt
  in the title while preserving the composer and transcript row.
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
  `summary_panel` presents Completion, Usage, and Jobs as separate numbered
  sections. Completion renders captured terminal outcome and attributable
  ancestry, file-tool, and tool-result evidence. Usage separates cumulative
  all-strand accounting from the latest measured active request. Jobs remains a
  separately refreshed observation; brackets select a stable retained job and
  show only its captured owner, command excerpt, age, and deadline. `r` refreshes
  jobs and resets the section viewport. A roster for another strand is
  unavailable rather than borrowed. Job ages and deadlines are relative facts
  from one server observation; rendering does not read a clock. Section paging
  does not alter the composer draft.
- **Current context**: `/context` opens aggregate usage and `/context all`
  (also `/contextall`) adds bounded item estimates. `tui/context_view.State`
  retains one attachment and strand's request identity, board, and independent
  viewport. The automatic refresh fires on the first capture, a strand switch,
  a configuration change, and the settling of the active strand's operation,
  never on a leaf that moved mid-operation; `/context` always requests a fresh
  read. A refresh coalesces behind the outstanding read; late results cannot
  replace another request or attachment. The footer keeps
  `ctx ~N%` ahead of cumulative billing. Missing observations show `ctx —`.
  Context and worktree reads wait for each other's final push before borrowing
  the same server worker slot. An unsupported optional command stays unavailable
  until attachment replacement. `context_panel` renders estimated capacity,
  basis, durable sequence, aligned component estimates, compaction boundary, and
  optional bounded item inventory. It labels freshness and unavailable states,
  and states that component rows need not sum to the headline. Page movement is
  clamped to the current geometry. Preview refuses a live observation rather
  than presenting illustrative data as fetched state. Compact help retains the
  Escape control at 40 columns. Escape returns without discarding the composer.
- **Advisor pending-nudge panel**: `tui/surfaces.sync_advisor_nudges` issues an
  `advisor_pending` read itself, with no operator keystroke, when the
  primary settles, a review settles even while the primary is running,
  or the primary first appears in the roster. A session switch also
  requests a fresh read. Other movement is `HoldNudges` because it cannot
  have grown the queue. The primary starting a run is `DropNudges` — a local
  submission counts, so the operator's own send clears the panel before
  the server confirms the phase — because that run start is what drains
  the queue into the prompt. A compact heading stays beside the composer;
  complete bodies live in the explicitly pending transient tail. Neither
  presentation enters model context or claims that observing a nudge delivers it.
  On terminals at least 20 rows high, a known idle advisor retains a stable
  two-row composer slot when no reviewer rows are live. The empty task row keeps
  reviewer completion from moving the composer while still showing that the
  advisor is idle. Tiny terminals keep those rows for the transcript and editor.
- **Session goal panel**: `/goal` shows the status block, `/goal <objective>`
  pins one, and `/goal clear|pause|resume` are subcommands **only as the
  whole argument**, so `/goal clear the failing test` is an objective. The
  budget rides `--budget <tokens>` (or `--budget=<tokens>`) in the first
  position and nowhere else: a trailing integer stays part of the objective,
  because reading one as the budget fails silently on the common `fix issue
  468` shape. `check` is the one subcommand that takes an argument, so it is a
  whole-argument **prefix**: bare `/goal check` clears the check and `/goal
  check make check` pins it, which reads an objective beginning with the word
  "check" as the subcommand — and `--budget` is the escape, since it puts the
  objective past the first position. A `/goal` with
  no flag pins `command.default_goal_budget`, named in the row that confirms
  it. `tui/surfaces.goal_action` reads the board on the three edges
  `advisor_nudges_action` reads on plus one the queue does not have — the
  primary *starting* a run, which is what a goal continuation is, and the
  transition that moves `continuations`, the accounting and the bounds.
  Nothing clears the board: a goal is pinned until the operator unpins it.
  Every goal command is answered with the fresh board — a mutation included,
  the `schedule_cancel` shape — so `session_channel.matching_presentation`
  lists `goal_get` as a `Read` and the four mutations against
  `GoalSnapshot`, and no mutation needs a second read. A refusal is worded
  through `goal_view.refusal` and skips the generic error row, because the
  common one is an older daemon or a session with no advisor answering
  `code_unsupported`, and a panel that silently fails to appear looks
  exactly like a session with no goal. An automatic refresh refused stays
  silent; the operator's own `/goal` and every mutation do not. Captures preserve
  an existing operator-facing footer notice, and sending a background `goal_get`
  preserves it too. An explicit `/goal` still reports its own send while it waits
  for the board.
  The explicit observation opens `focused_goal_panel`, which groups the
  server-owned status and cause, objective, budget consumption, age, latest
  check and output, and reviewer feedback in one raised card. Its viewport owns
  PgUp, PgDn, Home and End; `r` requests the existing read, and Escape returns to
  the unchanged composer. An Active board offers `p` through the existing pause
  command. Paused and Limited boards offer `c` through the existing resume
  command. NoGoal and Complete offer neither. A pending correlated request
  disables actions until its board arrives. These controls add no authority or
  wire message, and budget consumption is never presented as completion. When
  status bands would leave no body at 40×12, the goal temporarily uses their
  area while preserving the actual editor and footer. Status, objective, and
  controls therefore remain inspectable in the compact busy layout.
- **A new observation command must be taught to every command-name table
  by hand — the compiler checks none of them.** `advisor_pending` needed
  three, and missing one is not cosmetic: `tui/session_channel`'s
  `matching_presentation` and `outbound` both switch on the literal
  command string, and an unlisted name in `outbound` defaults to the
  `Mutation` lane — which held the composer lane forever and hung every
  attachment, since an observation's own reply never arrives to release
  it — while `tui/attempt`'s `decode_selection` rejects an unlisted kind
  outright, which fails the recording replayer on any log carrying that
  command. Both have regression tests now
  (`the_observation_takes_the_read_lane_and_its_reply_settles_it_test`,
  `auxiliary_and_queued_edit_descriptors_round_trip_without_command_bodies_test`),
  but the tables themselves stay three separate lists a new read command
  must be added to, not one the type system enforces.
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
  in aggregate. A count row precedes one row per accepted image, with a
  terminal-sanitized filename, MIME, and size. The editor keeps its full width
  and at least one row when space is constrained. Rejecting a fifth image
  names the rejected file and confirms that four attachments remain.
  Unsupported files and multi-token paths stay text, while read errors preserve
  the editor and show a local error. The backend enables bracketed-paste mode
  so a real terminal paste arrives as one event. Backspace on an empty editor
  drops the newest attachment.
- **Prompt view**: the editor retains the exact source and cursor state used by
  history and submission. Rendering wraps that state by terminal cells into a
  bounded one-to-four-row viewport; it never inserts newlines into the prompt.
- **Conversation and footer**: the reading surface has a heading and gutter;
  horizontal rules separate the composer. Scrollback controls replace the
  transcript heading, so Enter's send mode remains visible and entering history
  does not change the viewport height. Compact mode shows model, context estimate,
  estimated session cost, notices and an attention summary in one row, or two
  below 100 columns. The attention summary reserves its own space. Ctrl+G exposes
  the complete input/output/cache/rate accounting in the existing adaptive footer.
  Coherent cuts supply usage and cost; model names never imply prices. Workspace
  and branch discovery still runs once before the event loop, through bounded
  regular-file reads, and the header shows the resulting workspace label.
  Pushed usage rows update the output rate, never cumulative usage. The latest
  row per strand waits for a capture covering its sequence before it updates
  the cache watch, so a remote model change can discard a stale comparison.
  The watch requires two rows on one strand, and a model switch fences every
  row from the first subsequently observed operation before starting a new
  baseline. An initially captured live strand is fenced because its operation
  may have started under an earlier model. The first row already covered by a
  cut is ignored for cache comparison if its push arrives later. A cache-write
  count of zero gives no one-hour TTL evidence.
- **Terminal hygiene**: server and tool text loses complete ANSI CSI and OSC
  formatting sequences before markdown creates spans. Lone or incomplete
  controls remain visibly inert rather than becoming terminal instructions.
  `main` also sets the OTP logger's primary level to `none` before anything
  else runs, because once etui owns the alternate screen a dependency's error
  report, such as a websocket refusal while `/sessions` probes a stale
  record, would print over the frame and stay until those cells repaint.

## Invariants

- **A successful settle never changes the transcript's height in compact
  mode.** A live region and the durable projection that replaces it occupy
  the same number of wrapped rows, so a reader following the tail sees text
  change and not the transcript grow and shrink under them. The two regions
  this covers are a running tool call — whose output window is detail, drawn
  only with details expanded, while code-mode source is already visible — and
  a reasoning block, whose live and settled forms are both one
  `ReasoningDigest` row when collapsed. A result the
  reader has to see still costs the rows it needs: a failure adds its result
  text under the failure summary, and `fs_edit` and `context_remaining` draw
  their own rows. What the rule removes is growth that carried no
  information.
- **A harness-authored user turn is drawn in the system voice, and only on
  both of its tokens.** `tui/transcript_lines.advisor_payload` recognizes advice, nudges, the
  feed, the goal feed (`goal_feed_header`/`goal_feed_footer`) and the goal
  continuation (`continuation_header`/`continuation_footer`) — copies of
  `client/advisorslice`'s literals, pinned against them by
  `goal_view_test` and `advisor_view_test`. The header alone is never
  enough: a model quoting a continuation header must not be able to promote
  its own output into the system voice, and an operator pasting one back
  keeps their own. The budget wrap-up rides the ordinary advice frame, so it
  needs nothing of its own.
- **A collapsed reasoning digest is one row at every width.** The row is
  clipped to the pane rather than wrapped, and `markdown.wrap_lines`
  recognises it by `markdown.digest_mark` and leaves it fixed. A character
  limit on the digest text alone would only move the width at which the mark
  and the expand hint pushed it onto a second row.
- **Reasoning is collapsed unless details are expanded.** A digest is drawn
  literally rather than through the Markdown renderer, so a fence or a list
  marker in the model's own prose cannot turn a one-row indicator into
  several. `Ctrl+G` renders the block in full, as it always did.
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
  input run can span etui batches. `pacing.frame_decision` therefore renders a stale
  cache at most once every 16 ms while paced events keep arriving and records
  the rest as `FrameDeferred`; the tick that follows the drained queue flushes
  it, and `pacing.paced_poll_timeout` shortens that tick's wait to 8 ms so the final
  position lands within a frame of the hand stopping. The pacing clock is the
  monotonic clock, seeded at startup because a fresh node's monotonic time is
  negative.
- **A tick is paced by what it carried.** A tick is both the idle event that
  flushes a deferred frame and the carrier for every stream delta, so
  `pacing.frame_boundary` classifies it by `TickTraffic` rather than by its
  constructor: a tick that moved the transcript is `Paced` and waits out the
  frame interval like any other streamed frame, while a tick that moved
  nothing is a `FlushPoint`, because a deferred frame has no other event
  waiting to pay it off. A resize always flushes.
- **The viewport is paced, not teleported.** A provider chunk lands as two to
  five rows at once. `Model.revealed_rows` is how many of `rendered_rows` the
  bottom-anchored viewport has shown, and `pacing.pace` advances it toward
  the tail one row per rendered frame, in proportion to the backlog once
  that passes the catch-up threshold `pacing.policy` fixes. Three growths bypass the walk
  and are adopted whole: a viewport that has revealed nothing has no position
  to stay continuous with, a shrink must not leave retired rows on screen, and
  a growth taller than the viewport replaced everything the reader could see.
  An idle strand holds nothing back, which is what makes a replayed or
  scripted run settle on the complete frame. `pacing.viewport_address` classifies an
  input event as `AddressesTranscript` or `AddressesElsewhere`, and only the
  former closes the backlog at once: a wheel, a click, a resize, and the keys
  that move, submit to, or reshape the transcript (page keys, Home, End,
  Escape, Enter, the details toggle) address it, while ordinary composition —
  typing or pasting into the draft, arrow-key editing — does not, because
  composing a prompt while an answer streams says nothing about where the
  transcript should be. A scroll gesture measures its motion from the row the
  reader is actually looking at, the stored offset plus whatever the walk is
  still holding back, not the bare stored offset alone — folding in anything
  less would answer a request for older text by jumping the backlog toward
  the tail instead. While rows remain, `viewport_pacing` reports
  `ViewportCatchingUp`, which makes the painted frame stale whatever the
  revision says and holds `terminal_poll_timeout` at the frame interval: the
  deltas that produced those rows are already drained, so nothing else would
  wake the loop to finish showing them. A full-width changes view is the one
  surface painted without the paced offset, so a backlog behind it answers
  `ViewportSettled` rather than holding the loop on a repaint nothing on
  screen would show.
- **`update` is a dispatch and a settle.** `update` records the event, calls
  `apply_input` to dispatch on it, and hands the result to `settle_update`
  for the worktree request, context sync, Herdr report, projection, viewport
  snap and frame decision. `settle_update` taking the dispatched model as a
  parameter is what keeps the module compiling in seconds; `apply_input` is
  a readability split. The Erlang inliner attempts every local call and, on
  abandoning an attempt for effort, restores the state it began from,
  including its cache of visited expressions; a settling step applied to the
  dispatched expression therefore re-visits the whole dispatch, every arm
  and the tick's drain chain beneath it, once per step, and six steps in one
  body cost about sixty-four visits and over a minute of compile time.
  Applied to a parameter, the same steps visit it a constant number of
  times. Folding the steps back into `update` restores the blow-up, and
  hiding the dispatch behind a call while the steps stay in `update`
  measures worse than the original; `erlc +time` on the generated `tui.erl`
  shows it as `core_inline_module`, and `docs/execution.md` has the
  measurement. Since the module split (#374) most settling steps are calls
  into `tui/surfaces`, `tui/inbound`, `tui/projection`, `tui/interaction`
  and `tui/tick`, which the inliner never attempts, but `snap_viewport_for`
  is still local and the boundary stays.
- **Tick settling has the same parameter boundary.** `update_tick` drains
  replay, control, reconnect and connection events before passing the result
  to `settle_tick`. The helper applies the existing read-service chain to its
  `drained` parameter and retains the original model for quiet-time and activity
  comparisons. Adding the notes read to the former single body exposed another
  inliner blow-up: `core_inline_module` took 51.445 seconds. The boundary reduced
  that phase to 1.632 seconds in the generated-code experiment; the actual Gleam
  package build took 7.80 seconds. Keep the service order and this boundary.
  Both functions now live in `tui/tick`; the services are cross-module calls
  into `tui/surfaces` and `tui/inbound`, but the drains and
  `advance_cache_outlook` are local.
- **Compile-time measurements for the split (#374).** On Gleam 1.18.1 and OTP
  29 on macOS, before the split a rebuild after a comment change to
  `tui.gleam` took 9.57 s and 9.83 s, and `erlc +time` on the generated `tui`
  module took 11.64 s (`beam_ssa_opt` 4.18 s, `core_inline_module` 2.66 s).
  After it, the same change to `tui.gleam` rebuilds in 1.4–1.7 s. A comment
  change to one of the large modules (`inbound`, `render`, `transcript_lines`,
  `interaction`) rebuilds in 2.3–3.6 s, and an interface change to
  `tui/model`, which recompiles every module and test that imports it, in
  2.7–3.6 s. `erlc +time` wall time per module is 0.54 s for `tui`, 2.49 s
  for `tui/inbound`, 0.87 s for `tui/render`, 0.44 s for
  `tui/transcript_lines` and 2.39 s for `tui/interaction`. These are
  measurements, not budgets.
- **Presentation uses one caller-owned clock.** `new_model` supplies the
  host's monotonic clock; `new_model_with_clock` lets a test supply its own.
  Frame pacing, generation throughput, and activity elapsed time all read
  `Model.monotonic_time_ms`, including the initial frame timestamp. This
  controls presentation only: socket deadlines, daemon bootstrap, and
  recording timestamps retain their real clocks. `test/clock_test.gleam`
  exercises the event handler at negative epochs and pins repeated scripted
  intermediate frames with a fixed clock.
- **Auxiliary panels draw borders, not interiors.** The ordinary conversation
  has no rectangle and the composer has horizontal rules. `render_panel_border` puts the same
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
  A tick exists only when a poll times out with no input, and a wheel flick
  delivers notches faster than any timeout, so a key, a wheel notch and a
  held drag each drain up to sixty-four queued socket messages before they are interpreted.
  Without that a history page waits for the hand to pause and then lands with
  every capture queued behind it.
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
  not bound the durable history itself.
- **A cache is invalidated by a changed input, not by an event.** A capture
  arrives four times a second throughout a turn, and most of them move only
  usage, a phase or a timestamp. `render_cut` therefore compares what the
  record projection actually reads — the records, the transcript header lines,
  the active strand and the solo-owner identity — and keeps
  `record_cache_valid` when all four are unchanged. In compact history a
  settled record can re-group a tool block, which is a rewrite of rows already
  projected rather than an append; `tool_activity.regroups` is where that
  question is answered, and only a record it names forces a rebuild. Prose, a
  user turn and structural history take the append path, which extends
  `record_rows` and merges its own hints into the three layout caches rather
  than replacing them. `dev/tui_replay_dev.gleam` validates
  admitted record counts and failure notices before reporting replay time.
- **History anchors share the durable row layout key.** While reading older
  output, metadata and live fragments may invalidate the outer render cache
  without changing durable rows. Reuse their source anchors while width,
  strand, detail mode and record validity match and no records are pending.
  Empty anchors, including those left by help, force a fresh projection.
- **Scroll presentation preserves the complete frame.** The etui full-screen
  renderer samples small vertical shifts, moves the selected terminal rows,
  and diffs every cell against the shifted previous frame. Fixed sidebar
  content is repaired inside the same synchronized update. Ordinary cell
  diffs remain the fallback when cheaper; fixed and inline viewports never
  issue scroll commands because DECSTBM spans the terminal width.
- **Model text never becomes terminal control traffic.** The text-hygiene
  pass replaces C0/C1, bidirectional, zero-width, variation-selector, and tag
  codepoints before data reaches etui spans. Newlines survive only where the
  markdown block parser needs them.
- **Markdown stays structured.** Mork parses CommonMark and the adapter emits
  etui styles and OSC 8 links. A table is drawn as a bordered grid measured
  against the caller's width, and becomes stacked labelled records only where
  even the minimum grid will not fit, so the relationships survive a narrow
  terminal either way. Fenced Gleam token styling preserves the exact
  model-authored text; it never acts as a formatter or compiler. No raw
  model-authored ANSI or HTML is executed.
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
- **Advisor traffic is not operator speech either.** Advice, queued nudges and
  the feed a review is made from are all stored as user messages.
  `tui/transcript_lines.advisor_payload` recognizes each by its whole frame — a header line
  with its footer, or the header with the `advisor-nudges` fence — and
  `tui/transcript_lines.advisor_lines` draws the row as `System` under the advisor's name:
  delivered advice and nudges retain their full body in both modes, with
  explicit delivery labels. Feeds and continuations collapse until expanded.
  Expanded bodies drop their frame lines,
  since those address the model rather than the operator. Both
  tokens are required, so an operator quoting a verdict back keeps their own
  attribution. The frame literals are copies of `client/advisorslice`'s,
  because this package links no server package; `advisor_view_test` pins all
  six against the strings the server writes and the server's own test should
  pin the same ones.
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
- **A tool tail is replaced, never appended.** A `tool_output` frame
  carries the whole bounded window of one stream, so the model keeps one
  `ToolTail` per `{strand, operation, step, source_index, call_id, stream}` and the newest frame
  is the only one worth drawing; the region is the size of the last frame
  however long the command runs, and a dropped frame costs nothing. Tails
  clear with the strand's streams — on an entry landing and on the
  operation reaching `done` — and a capture drops one once that exact
  `call_id` has a durable tool result in its strand. A global 128-tail cap
  bounds missed or evicted captures. Another strand's tail is kept but not drawn.
- **A live stream is bounded, and its text is owned.** `Stream` carries the
  bytes its fragments weigh, and past twice `tui/transcript_lines.live_stream_limit` — 24 KiB,
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

- [`docs/architecture/terminal.md`](../../docs/architecture/terminal.md)
  describes the terminal client as built: its loop, connections,
  reconnection, rendering and recording.
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

## Release update implementation

`tui/update` owns release selection, private staging, immutable publication and
post-install daemon lifecycle. `tui/update/options` represents intent with
`Selection`, `Action` and `Signature`; `source` resolves the full commit and
checks repository, platform and tag binding before any artifact is installed.
A supplied local keyring is the signature authority. An absent signature is
allowed in optional mode; an invalid present signature is always refused.

`manifest` uses the shared duplicate-key-refusing JSON decoder. `archive`
admits only the release writer's ustar subset: regular files, explicit
directories, and aliases of regular siblings. It validates the complete tree
before writes, caps inflated data at 512 MiB, and stages aliases last. Its
compressed archive SHA-256 and size are checked first. Extension archive
policy remains independent and continues to refuse every link.

`files.publish` invokes this running client's `priv/install.sh`, never an
installer from the incoming archive. The publisher copies fresh immutable
trees and switches links; old trees survive success and failure. Updates to
one prefix serialize on `lib/loom/update.lock`. Installed wrappers carry their
prefix and selected client shape for subsequent updates.

`lifecycle.capture` authenticates an existing daemon without starting one.
After installation, `lifecycle.restart` requests `protocol.Shutdown`, observes
the captured native fence for retirement, and uses ordinary reconnection to
start or adopt a replacement. An accepting daemon must report the manifest's
full commit. Socket loss alone never authorizes replacement; timeout never
escalates to forceful termination. `loom update` dispatches before terminal
setup; `--install-only` leaves daemon lifecycle to the operator.

`download` implements the injected fetch seam using Gun 2.6's native HTTPS
stream. `internal/ffi_download` only adapts Gun calls, system certificate roots,
hostname verification and typed events. Gun and its Cowlib parser are release
dependencies. Each request runs in a weft managed task with a five-minute total
deadline, a fifteen-second idle wait, at most five redirects, 64 headers and a
32 KiB header block. Only HTTPS URLs without credentials or fragments are
admitted, including redirect targets. One body-message credit is restored
after its fragment is written, and total bytes are checked before appending.
Gun does not automatically redirect or retry. A normal transport-owner stop is
the managed task's drain witness. Error bodies are never collected; only an
explicit HTTP 404 counts as absence.

The session connection adapter translates the transport's HTTP 503 startup
refusal into daemon admission guidance, naming the two `[daemon]` connection
settings. It retains other transport errors and performs no automatic retry.
The transport does not expose the refusal response body, so the terminal does
not claim which configured ceiling was exhausted.

## Peer attribution

Existing conversation rendering uses `core/origin.display_label` for both
human and peer sources. A `PeerOrigin` appears as `peer session/strand` and
survives the entry codec; it is not rendered as the local operator. This is
attribution within the existing conversation view.

The Collaboration tab projects a selected strand's background executions,
readiness, outgoing peer links, named workflow intents, and peer-authored
entries from one captured snapshot. The existing snapshot selects `client/`
facts; `tui/collaboration_view` reads only those facts and the loaded branch,
so opening this tab makes no extra request or starts no session. Live execution
records precede older terminal records. A `Running` record can still be
compiling. The separate readiness fact names published endpoints, including
after an execution has closed; the phase still governs whether input is open.
The peer message section says `stored`, never `read` or `completed`; inherited
branch entries may appear. Workflow counts are durable step intents, not child
outcomes. The source link fact lacks wake scope, so the tab labels that value
unavailable rather than inferring it.

`/sessions` selects the target session for a link with `l`, while Enter still
opens the row. The selected row must be resident; a saved row displays a refusal
in the selector. The attached session and exact strand remain the source.
`/peers` opens `PeerLinkManager` for the active strand, and `p` from `/agents`
uses that selected source strand. `tui/peer_links.State` owns the grant
inspection, target strand draft, selected target, catalogue revision and
continuation cursors. `ReturnTo` restores the original session selector, agent
inspector or conversation after close. `TargetEntry` sends Escape back to the
session selector for a direct link, or to the peer chooser for a later link.
The selected target survives a catalogue refresh, even when it came from a
later page. The overlay never changes the
composer recipient or opens a saved session. A link starts with `BusyOnly`; the
operator explicitly reviews its direction and wake permission before
`LinkPeers`. A successful mutation returns to browsing, and
`operation_result` keeps its acknowledgement visible through the inspection
refresh, including a partial unlink. The grant and session lists scroll with
selection while reserving rows for the result and controls. Target-session
pages retain the first catalogue revision, so a later page cannot silently
mix another catalogue snapshot. Control requests still carry the owner's epoch
and are checked by the daemon; TUI selection itself confers no peer authority.
