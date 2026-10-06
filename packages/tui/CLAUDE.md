# tui

## Operator startup diagnostics

Protocol 055 uses the existing daemon error envelope and credited snapshot.
`daemon/protocol.decode` accepts at most 2048 UTF-8 bytes of error text;
`daemon/selection.failure` displays the `start_failed` reason after the
opening operation's owner has retired. `inbound.configuration_lines` renders
`snapshot_view.ToolAvailability.extension_refusals` as ordinary startup lines
on each adopted capture, including reconnects. It carries the installed name,
refusal reason and existing remove-then-install guidance. The shared decoder
owns the list and byte bounds; the terminal adds no diagnostic authority.


## Agent workspace

`Ctrl+O`, `F2` and `/agents` open `agents.Inspector`, whose selection is a strand ID.
Arrows inspect without changing `Model.shared.active_strand`; Enter explicitly opens
the selected transcript and recipient. Missing selections stay visible as
unavailable until navigation chooses another row. `n` visits the next attention
state, `a` opens the existing exact-request approval panel, and PgUp/PgDn scroll
the selected detail. The real composer stays visible below the workspace. `w`
transfers keyboard ownership to it without changing the inspected ID or recipient;
Escape returns to the list. Tab and Shift+Tab cycle `agents.Filter` (All, Need
you, Working, Settled), as the session picker's tabs do; a filter that hides the
selection selects its own first row.

The list draws each agent as one `agent_row.TableRow` row (glyph, name, action,
elapsed, context) in attention order after `main`: needs input, failed, halted,
working, idle, finished, unavailable, and the advisor last. `agents.listed` is
that order and the filter, and `navigate` and `next_attention` read it, so Up
and Down always move to the row drawn next. The Activity detail is labelled
sections, each said once: Task (cut at a word, with a line saying where the
rest is), Now (a pending approval's request and the `a` key, or a failure's
error with "the error is not repeated here"), Latest messages from
`agent_messages`, Inbox and Tools, and the identity dimmest. The figures come
from `agents.Facts`, the strip's `agent_roster.Roster` and the captured sends,
through `agent_roster.describe`, which also describes the settled agents a
strip does not list. At an inside width of 96 or more the detail sits beside a
69-cell list; narrower, it stacks under a rule and keeps only Task and Now.
While browsing, the workspace owns the screen below the identity line
(`layout.workspace_area`), covering the strip and the composer, and is as tall
as its content, anchored at the top; while writing (`w`) it takes the body
above the composer. A list cut by its room ends in `↓ N more below`, a
section label whose body was cut is not drawn, the latest messages read
oldest first (a captured send has no time, so there is no age), and the
footer names the recipient quietly with the recipient in bold paper. Editing uses the existing submission and command
completion paths, including the visible command palette. The ordinary
`Shift+Tab` rail shares the same task summaries, with a reserved Advisor section
and a separately labelled worktree observation. A missing Git observation is
never a clean-worktree claim. A `sub:` prefix is an identity convention, not evidence of a parent relation.

`agent_view.Row` (`session_view/agent_view`, shared with the web view) is
projected from one coherent `snapshot_view.View` and window.
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
`agents.Detail`, switched with 1/2/3/4. `session_view/agent_messages` admits sends only after the sending strand's
accepted operation prompt. It joins results within that branch and before a
later reuse of the call ID. `Model.shared.agent_messages` retains the latest twenty
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
held prompt appends only to its original strand's draft; it passes through
`Shared.returned_drafts` on the way. Session replacement
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

## Agent strip

`agent_strip` pins one row per live agent beneath the footer, so an operator
running several strands can see what each is doing without opening `/agents`.
`main` always leads; after it come the active strand and every strand that is
working, waiting, needs input or is halted. Settled strands leave the strip,
and the advisor, which has its own band, is listed only while it is active.
The strip appears once a second agent is listed and the terminal is at least
`min_screen_height` rows. It grows a row per agent, up to a fifth of the
screen plus one (five rows at 24, eight at 40) and never more than `max_rows`; any further rows fold into a
`+N more · Down enters the strip · F2 opens the list` row. Its rows are
`agent_row.StripRow` rows, the shape the workspace list draws: the cursor's
row is the raised bar marked `❯`, the viewed strand is marked `›`, and the
name and figure columns are as wide as the widest the strip shows, so the
`·` between time and context lines up at the right edge. Two agents whose
slugs match keep the head of their digest (`agent_row.labels`), and a name too
long for its column is cut in the middle so that suffix survives. `layout.layout` includes it in the footer
rectangle and `layout.footer_split` divides the two, so no other hit-test
or scroll path sees it. While it is drawn, the reviewer band above the
composer steps aside.

Which strands are listed, in what order, and what each row's words and
figures are is `session_view/agent_roster`, which the web view's agent chips
read too; `agent_strip` keeps the rows it paints and the keyboard focus.
Each row joins the existing `agent_view.Row` with the daemon's glance
(`core/glance`, `client/glance/{strand}`), decoded once per capture by
`agent_strip.observe` (`agent_roster.observe`). A glance is shown only while its `operation` is the
strand's current one. An empty or absent summary falls back to the row's
deterministic activity, and an absent title to the accepted task excerpt.
Elapsed time never subtracts a server timestamp from the terminal clock. A
`Clock` starts on the terminal's clock when an operation is first seen, and a
new glance re-anchors it to the daemon's own `glance.at - started_at` plus
local time since the terminal observed that glance. Context size is the newest
generation's `input + cache_read + cache_write + output`: from a live
`usage_observation` push when this terminal has one for the operation (behind
the existing sequence guard), otherwise from the glance. `inbound.tick_strip`
advances the clock on the tick and invalidates the frame only when a drawn
second moves.

Down from the composer, when prompt history is not being walked, moves the
keyboard into the strip with the cursor on the row after the viewed strand.
Up and Down move the cursor, Up from the top row or Escape hands the keyboard
back, and any other key is returned to the composer, which handles it. Enter
opens the selected strand through `submit.switch_active_strand`, the same path
the workspace's Enter takes, so drafts are parked per strand and the
transcript, recipient and badge change together. `x` sends `abort` for the
selected strand (`submit.stop_strand`); on the active strand it is the
ordinary interrupt. Moving the cursor never retargets the composer. The
cursor is a strand ID, and a cursor whose strand has left the strip is
re-seated on the first row. The composer's top rule carries the viewed
sub-agent's title as a badge on the right; `main` has none. The cursor row
is marked `❯` and the viewed row `›`, so both read without color.

## Todo panel

`todo_panel` draws the active strand's todo board between the conversation
and the composer. The board is the `details.todo` of the newest successful
`todo` result, decoded with `core/todo_list.decode`, so the panel and the tool
cannot disagree about a stored board. `Model.shared.todo_boards` keeps each strand's
newest board across cuts, because a capture window that has moved past the
last `todo` call would otherwise blank the panel; session replacement releases
it. A strand whose capture reaches no board gets one ordinary `notes` read per
session (`Model.shared.todo_seed`, `todo_asked`, sent by `session_view/surfaces.service_todo_seed`
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

The notes browser (`/notes` and the inspector's Notes tab) draws the same
cell. `notes_view.todo_board` is the one reading of a note as a board: the
key is `notes_view.todo_key` (which `todo_board.note_key` names), the extent
is complete, and the value passes `todo_list.decode`; `todo_board.seed` uses
it too. A note that passes renders in readable mode through
`notes_view.readable_note` as a Markdown checklist, one `### Phase · n/m`
heading per phase and the panel's glyphs per task, with task text escaped so
model-written Markdown stays literal. `notes_view.summary` gives its list row
`n/m done · active: Task`. Raw mode keeps the stored JSON, and an excerpt or an
undecodable board keeps the generic projection.

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

Another attached client, such as the web view, can answer the question first.
When a cut holds no pending record with the panel's ID, the panel closes, a
system line says the request was settled elsewhere (naming the decider when the
resolved register carries one), and the next unseen pending question opens in
the same step. A panel opened on an already resolved record through
`/approvals <id>` is a deliberate inspection and stays open until the operator
closes it.

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

The authenticated control host owns the daemon build identity, and
`tui_model.adopt_daemon` compares it with `View.client_build` when a control
connection is adopted and stores the mismatch lines (`daemon_build_lines`) in
`Shared.build_notice`. `render_cut` projects those lines into each transcript
capture, so successful adoption and later refreshes cannot erase it. The
comparison stays in the terminal because `host/build_identity`, which reads
the environment, is not a module `session_view` may import. Missing identity stays silent. Shipment and
release launchers export their own build metadata, replacing inherited values.

A local terminal makes one bounded reconnect attempt after conversation loss.
`bootstrap.reconnect_daemon` uses read-only control status and native endpoint
observations before selecting a host. It can reuse an accepting VM; a draining
or unreachable live VM remains fenced. Only positive native vacancy permits
one normal resolver launch. Polling and startup share the deadline, and session
open remains outside that polling loop. Held prompt returns restore text in the
composer; image bytes must be reattached by the operator.

## Web view link (`loom ui`)

`loom ui [--session <id>] [--operate | --observe] [--no-remember] [--open]` (`tui.run_view`) resolves the daemon through
`bootstrap.resolve_viewing_daemon`, which adds `--ui` to the launch
arguments only when it starts one. A running daemon whose `hello` has
`view: NoWebView` is refused by `view_served` with status 1 and never
stopped or relaunched. Otherwise the session is opened through
`daemon_selection.open` and the path `UiLink` returns is printed joined to
the listener's http origin. `UiLink(session_id, page)` carries a
`WebPage`: `ObserverPage` by default, which names no `page` field on the
wire, and `OperatorPage` with `--operate`, which sends `page:"operator"`.
The page is a ceiling the daemon caps the principal's membership with; it
never grants a role (protocol-change/051, the operator addendum).
`parse_launch` routes `ui` in first position, or `--ui` anywhere in argv
(the older spelling, taken out with `take_switch`), to the one parser
`tui.view_request`; `tui.launch_view` is the test seam over that routing.
`tui.view_request` parses the remaining words into a `ViewRequest`
carrying that `page`, a `remember` (`control_protocol.Remember | Forget`:
`--no-remember` opens the home and signs the browser in for nothing, and is
refused with `--session`, since only the home's exchange sets a browser login,
protocol-change/065, PR 8) and a `delivery`, which is `view_link.PrintLink` or,
with `--open`, `view_link.OpenInBrowser`. `view_link.deliver` always emits
the link first, then runs the opener when asked; a failed opener is a
`Note` on stderr and the command still exits 0. `view_link.opener_for`
maps `LOOM_BUILD_PLATFORM` (`macos-*` to `open`, `linux-*` to `xdg-open`,
anything else or absent to a note), `platform_opener` builds the opener
from injected find and launch functions, and `launch_within` runs it
through `ffi_terminal.run_forwarding` inside a five-second weft deadline;
an opener still running then counts as a started browser. A note is built
only from the opener's name and status, so it never carries the ticket
(051 addendum "opening the browser"). `daemon/protocol.Hello.view` is `NoWebView`
or `WebViewAt(path)` from the optional `ui` field
(`protocol-change/051`). `projection.record_projection` names the call the
record cache makes for durable lines, so the web view's parity test can
compare against it.

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
event dispatch (`update`, `step`, `apply_input`, `settle_update`). Everything else
that used to share its 15,500 lines (issue #374) lives in modules under
`tui/`, listed here in import order, or in `packages/session_view`.

`session_view` holds the part of the client that no host owns (ADR-013,
phase 4): the session lane (`session_view/session_channel`, generic over
its socket and recorder), the protocol and wire decoders, the snapshot
types and `snapshot_view`, the history window, the attempt vocabulary and
`connection_event`, the approval decisions, the board decoders the
protocol names, and the transcript's line builders (`transcript_lines`,
which read a `transcript_lines.Presentation` rather than the model), their
line types (`transcript_line`), and `transcript.project`. Since S4 of
`docs/design-notes/step-extraction.md` it also holds the shared step: the
session state `session_view/model` (`Shared` and the types it names), the
effects the session decides (`session_view/step_effect`), the session's half
of a message (`session_view/msg`: `Stamp` and `Command`), the frame and replay
filing (`session_view/admission`), the send path (`session_view/outbound`),
the side-surface reads and edges (`session_view/surfaces`), the event fold
and the lane fold (`session_view/event_fold`, `session_view/lane_fold`), the
commands (`session_view/commands`), the step's settle (`session_view/step`),
and the modules they fold through (`queue_request`, `agent_messages`,
`attempt_replay`, `completion_summary`). The terminal imports
`session_view/model` as `session_model` and `session_view/step` as
`session_step`, the names they had here. It imports only `core`, `machine`
and the standard library, R6 holds it there, and nothing in it imports
`tui`. Its `CLAUDE.md` describes each module.

Gleam forbids import cycles and none of the `tui/` modules may import
`tui`, so a module may import only those above it in the list:

- `tui/terminal_lane`: `Lane` and `Output`, the session lane with the
  terminal's connection and recorder as its handle types, and `perform`,
  the only place a lane's outputs touch the websocket or the recording.
- `tui/image_support`, `tui/image_box`, `tui/image_shown`: drawn images,
  described under "Drawn images" below. They import etui, `session_view`
  and `theme`, and nothing that imports the model; `effect` carries
  `image_shown.Command`.
- `tui/layout_memory`: the layout file, its digest key and its total decoder,
  described under "Layout memory" below. It imports `host/bootstrap` and
  `core/json`; `effect` carries its `Layout`.
- `tui/effect`: `Effect`, the closed vocabulary of fire-and-forget effects a
  step decides on, input recording lines among them (`Record`). The session
  reducers' effects arrive as `Step(step_effect.Effect(Connection,
  Recorder))`, `session_view/step_effect`'s type bound to the terminal's
  handles. It imports the modules whose handles its variants carry
  (`attachment`, `connection`, `herdr`, `image_shown`, `job`, `recording`)
  and nothing that imports the model. `DrawImages(commands)` and
  `WakeLoop` are the image effects.
- `tui/view_set`: one setter per `View` field that three or more sites set,
  and `toggle_repaint`. It exists so that the record is expanded once per
  field rather than once per call site; see the compile-time invariant below.
- `tui/model`: the `Model` record, `Model(shared: TerminalShared, view:
  View)`. `TerminalShared` binds `Shared`'s four parameters to
  `connection.Connection`, `recording.Recorder`,
  `Subject(connection_event.Message)` and `Subject(attempt.Event)`. The
  session's reducers are in `session_view` over `Shared` alone; the
  terminal's take `Model` and call them through the functions below.
  `hold_shared(model, shared)` is how a terminal reducer stores the result
  of any function over `Shared`: it moves `Shared.outbox` into
  `View.outbox`, wrapped as `effect.Step`, at the point of the call, so
  lane effects keep their order with the terminal's own, and it applies
  the terminal's consequences of what the call recorded, at the point of
  the call: it resets `View.quiet_for_ms` when `activity_revision` moved,
  empties the composer (`clear_composer`) when `drafts_sent` moved, hands
  each queue notice to `queue_editor.show`, and applies each goal
  observation to an open goal inspector. `run_shared(model, reducer)` is
  `hold_shared(model, reducer(model.shared))`, for a pipeline of shared
  calls such as the tick's reads. The writers above keep terminal forms
  here of the same names, each a `hold_shared` of the shared call, and so
  do `session_view/outbound`'s `send_frame`, `send_via` and
  `apply_submission`; the
  readers have none, so a caller passes `model.shared` to the shared
  function. `clear_composer` and `clear_composer_text` are the terminal's
  and live here.
  `View` is the terminal's own state (screen size, composer, panels,
  overlays, the row projection's outputs, pacing, clocks and
  `View.wall_ms`, the repository context `View.workspace`, the client's
  build `View.client_build`, the daemon-control and attachment job slots,
  the step's
  outbox, the job table) and holds the
  etui render caches, `Caches`, as `View.caches`: the rendered, record and
  diff rows, their line caches, the frame cache and the selection's frame;
  a reducer that empties the transcript bumps `Shared.record_cache_epoch`
  and the projection drops the record rows. This is slice S1 of
  `docs/design-notes/step-extraction.md`: a reducer reads
  `model.shared.x` or `model.view.x` and writes by updating that half, both
  halves in one expression from the same `model` when it writes both. The
  agent strip is split into `Shared.roster` and `View.strip_focus`
  (`tui_model.strip` and `store_strip` rebuild and store an
  `agent_strip.State`), a parked strand's history window is
  `Shared.parked_scrollback` beside its editor in `View.strand_workspaces`,
  and the queue editor's requests on the lane are `Shared.queue_request`
  (`session_view/queue_request`) beside the editor in `View.queue_editor`.
  Two more fields are shared data beside terminal state:
  `Shared.build_notice` is the mismatch between the daemon in
  `View.daemon_host` and `View.client_build`, written with the daemon by
  `adopt_daemon`, the one writer of either (`daemon_build_lines` draws
  it); and `Shared.returned_drafts`
  holds a held prompt the daemon handed back until
  `inbound.restore_returned_drafts` moves it into the composer or a parked
  editor. The footer's agent count is not stored: `render` derives it from
  `layout.displayed_agents`. The module also holds the
  terminal's types the record names. Importers alias it as `tui_model`,
  because `model` is the local variable in nearly every function and would
  shadow the module name. Constructors stay unqualified. It also owns the
  effect outbox, `View.outbox`, the step's one queue: `emit` queues an
  effect, `record` queues an input's recording line when the terminal is
  recording, `start_step` stores an input's stamp and wall clock reading
  and queues its recording line before the reducer runs, and
  `hold_shared` moves in what a function over `Shared` queued, such as the
  `Step(Lane(..))` outputs `hold_channel` takes from a transitioned lane
  and the `Step(Recorded(..))` line `record_arrival` queues for a
  channelless arrival. `start_job` allocates a job key from
  `Model.view.next_job` and queues its `StartJob`; `allocate_job` only
  allocates, for a test that stands a slot in for a running job.
- `tui/runtime`: `take`, `perform`, `settle` and `flush`, which empty a
  step's outbox and perform what it held, in the order it was decided,
  threading the job table through and storing it back on the model;
  `message`, which builds the step's `msg.Input` from an etui event,
  reading the clocks and a pasted file into it; `stamp`, which writes the
  clocks onto the model for a caller that runs a reducer outside the step;
  `receive`, which reads every running job's replies and each inbox's
  mailbox up to the room its buffer has (`arrivals`) and has admission
  file them; and `hold`, which does the host's bookkeeping for one job
  message (forgetting a finished job, and turning an attachment job's end
  into `job.Finished` with the adopted socket's liveness read) and has
  admission file it. `tui.gleam` and test drivers import it; no reducer
  module does.
- `tui/msg`: what the step is given. `Msg` is `Input(at, wall_ms, event)`,
  one event with its `session_view/msg.Stamp` (the presentation and
  transport clocks) and
  the wall clock reading, which the step reduces, or `Arrived(arrivals)`,
  traffic the host received, which the step only files. `Event` is in the
  client's terms (`KeyPressed(text, key)`, `Pasted(text, image)`,
  `Resized`, `Scrolled`, `Pressed`, `Dragged`, `Released`, `Moved`,
  `Ticked`); `Arrival` is `Frame(source, message)` tagged with the inbox
  subject it was read from, `Replayed(event)` or `JobReplied(arrival)`.
  `recorded` gives the recording line an event is written as. It imports
  nothing of the model. `Command`, what an operator does to the session,
  is `session_view/msg.Command`, which `session_view/commands.act` carries
  out; the terminal's key and slash-command handlers build one. This `Msg`
  is not `session_view/msg.Msg`, which the web view hands `step.update`; the
  terminal's carries etui's keys and job replies and a wall clock, and its
  `Arrival` is tagged with the `Subject` it was read from.
- `tui/keymap`: `translate`, etui's input event to a `msg.Event`. It only
  parses; what a key means stays in the reducer.
- `tui/admission`: `admit`, the pure filing of arrivals that the step runs
  for `msg.Arrived` and the terminal's host calls directly. A frame goes to
  the adopted inbox or the waiting attempt whose subject it names and is
  otherwise not filed; a job reply goes to the slot that holds its key or
  is dropped with its resource released through `tui_model.release`.
  It never drops a frame for capacity. The session half is
  `session_view/admission`, over `Shared` alone: `file_frame` files a frame
  into the adopted inbox when its source matches and refuses it otherwise,
  and `file_replayed` files a replayed event. A refused frame is then
  offered to the attempt, which is terminal state, over the whole model.
- `tui/job`: background jobs as data, and pure. `Key` is allocated from
  `Model.view.next_job` and never reused; `Awaiting(reply)` is a slot's key and
  the replies received for it, and `admit` accepts a reply only under that
  key; `Spec` is `Control(control, ControlJob)`, `Reconnect(options)`,
  `Activity(control, ids)`, `Attach(route, within_ms)` or
  `Configure(options)`, which resolves a new session's configuration from
  the local launch options; `Arrival(control)` is one
  job message tagged with its key. A daemon control connection is named by
  a `ControlKey` the runtime allocates, and the step holds it as `Daemon`,
  the key with the build the daemon's `hello` named (`Model.view.daemon_host`,
  and the mismatch with the client's build as `Model.shared.build_notice`,
  which a cut reads);
  a relaunch's reply arrives as `Arrival(daemon_selection.Host)` and is
  filed as `Arrival(Daemon)`. An attachment job's messages are
  `Published(Prepared)`, the worker's socket together with the frames
  subject it delivers to, `Settled(reply)`, the relay's account, and
  `Finished(SocketLiveness)`, the relay's end with the host's read of
  whether the socket the attempt would adopt is alive.
  `ControlOutcome` and `Removal` live here.
- `tui/job_runner`: the impure half of jobs, called only by the runtime.
  `Running`, the opaque table on `Model.view.running`, maps each key to its
  cancel signal and a selector over its reply subject, and each
  `ControlKey` to its control connection: `adopt_control` adds one,
  `file` adds a relaunch's as it files the reply, `close_control` closes
  and forgets one, and `start` resolves a spec's key when it starts the
  job. `start` turns a
  spec into a one-task weft run (`start_task` takes the work as a
  function, for tests), `cancel` cancels by key, `receive` reads every
  running job's messages, `observed` drops a job after its last message,
  and `selector` lets an actor-hosted test driver select every job's
  replies. `start_attach` creates an attachment job's frames subject and
  its `Prepared` subject in the terminal's process; `cancel` closes the
  socket of a `Prepared` it finds waiting when it cancels an attachment
  job, through `dropped`, which also closes a drained relaunch outcome's
  control. The control, relaunch, activity and
  attachment worker bodies live here.
- `tui/buffered`: `Inbox(a)`, `session_view/inbox`'s buffer with a
  terminal-owned subject as its source: the subject and the messages
  already received from it, oldest first. `discard` empties a subject the
  model has stopped reading, as the `Discard` effect and an abandoned
  attempt's cleanup. `waiting` is the only read of the mailbox for a
  step, reading up to the room the host gives it; `push` files a message
  behind the held ones and `take` is pure; `top_up` is `waiting` then
  `push`; `receive` is the held-first read for code outside the step; and
  `sender` is the send side, whose direct reads bypass the buffer.
- `tui/layout`: screen rectangles for painting and hit-testing, and the
  transcript width and height.
- `tui/render`: `view`, `cached_frame` and `render_frame`; a pure function of
  the model.
- `tui/side_surfaces`: the terminal's half of the side surfaces, over the
  whole model because each reads the overlay or a panel: `notes_target`,
  `notes_surface`, `refresh_notes`, `select_note`, `open_summary`,
  `request_goal_status` and `open_context`. The reads, receivers and edges
  they call are `session_view/surfaces`, over `Shared` alone.
- `tui/inbound`: the terminal's loop over the lane fold.
  `drain_connection` takes messages from the inbox, `tick_channel`,
  `accept_connection_message` and `cancel_pending` take a lane's updates,
  and `apply_channel_update(model, update)` applies one: it reads
  `surroundings(model)`, runs `lane_fold.apply_channel_update` through
  `run_shared`, and calls `settle_surfaces(before, held)`, which applies the
  surface facts the call recorded (the event fold's, and the lane fold's:
  `inspect_looked_up`, the dialog's close, `present_pending_approval`,
  `follow_queue_selection`, the parked editors' pruning,
  `reconcile_agent_message_selection`, the goal inspector's close,
  `begin_reconnect`, the replay adoption's resets, and the commands'
  composer reset and dialog close) and moves returned drafts into the
  editors (`restore_returned_drafts`). `run_settled(model, reducer)` holds
  a shared call and settles its facts in one call; every call that can
  record a fact goes through it. `select_workspace`, `apply_cut`,
  `request_decisions`, `service_history`, `request_visible_worktree`,
  `refresh_worktree` and `decide_captured_approval` are terminal forms of
  the folds' and the commands' functions.
- `tui/session_control`: daemon control requests and reconnection. It
  describes each request as a `job.Spec`, and `drain_control`,
  `drain_reconnect`, `drain_activity` and `drain_configuration` take their
  replies from the slots the runtime admitted them into. `create_session`
  starts a `job.Configure` job when the terminal has local launch options,
  and `drain_configuration` continues the creation with its answer.
- `tui/projection`: `refresh_render_cache`, `refresh_diff_cache` and the
  record row cache.
- `tui/live_tail`: the rows of a streaming answer, rebuilt each frame from
  what changed. `Cache` lives on the render caches as `Caches.live_tail`,
  written only by the projection; a projection brackets
  its live lines with `begin` and `finish` and draws each through `rows`,
  which gives exactly `render.render_line`'s rows. Closed Markdown blocks
  settle once, the hygiene pass runs only over text
  `text_hygiene.unchanged_prefix` has not vouched for, the open tail's
  growing paragraph re-wraps from its last row (`markdown.rewrap`), and a
  long paragraph is parsed only after a checkpoint past its plain leading
  lines (`markdown.join_soft_break`).
- `tui/submit`: the shell's half of a submission, input history, and the
  terminal forms of the commands. `submit` parses the draft and routes on
  the outer variant: a `command.Session` goes to `commands.act` as
  `msg.Submit(draft, command, delivery)`, with the composer's mode as the
  delivery; a `command.Surface` is carried out here (`surface_command`:
  panels, the model selector with its `models` read, daemon control, a
  change of strand and the quit), after the terminal consumes the draft
  itself, and then `commands.release_submission`. Also `interrupt_active`,
  `stop_strand`, `quit` (the session's half through `act(Quit)`, then the
  terminal's cancellations) and `switch_active_strand` (`cancel_pending`,
  `commands.focus`, the overlay and outlook reset, then
  `commands.load_strand`, each settled before the next).
- `tui/interaction`: key, paste, mouse and candidate-event handling.
- `tui/tick`: `update_tick`, `settle_tick`, the frame cache, viewport pacing
  and the Herdr reporter. The tick's session units, the side-surface reads
  and the activity and generation clocks, are `session_view/step`'s
  `service_reads` and `advance_activity_clocks`; the activity glyph's frame
  is the terminal's and advances here.

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
  `notes_view.readable_note` and `notes_view.summary` are what the browser
  calls, so a decodable `todo` cell reads as a checklist instead.
  Raw inspection pretty-prints complete JSON; excerpts remain literal.
  `session_selector.prioritize` sorts exact workspace matches first, related
  directories next, and preserves order within each group and selection by ID.
- `session_view/transcript_lines.AdvisorMessage` names the advisor frames the transcript
  recognizes — `Advice`, `Nudges`, `Feed`, `GoalFeed`, and `Continuation` — each carrying the body left
  after its frame lines are stripped. `session_view/transcript_lines.advisor_payload` extracts one from
  a durable message and `session_view/transcript_lines.advisor_lines` renders delivered advice and nudges
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

- `Model.view.reading_lines` retains one bounded transient projection when scrolling
  above the live tail. Incoming streams continue collecting without changing
  that projection; returning to the bottom releases it. Durable history keeps
  its existing frozen ancestry and row anchors. The composer border provides
  a clickable jump action that preserves an unsent draft; End also returns to
  the tail when the composer is empty.
- `session_view/file_read_view` removes recognized edit digests and hashline anchors
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

- `session_view/history_view.State` owns bounded presentation history separately from
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
  `Model.view.strand_workspaces` and its history window in
  `Model.shared.parked_scrollback`, both keyed by `(session, strand)`. It
  restores the incoming owner's complete editor and bounded ancestry before
  applying the current capture. `render_cut` releases parked reading buffers for retired
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
  row — the line count and the generation's elapsed time while it streams,
  its opening line and the expand hint once it settles — and `Ctrl+G` shows
  the block itself; a redacted block is its one-line marker in either mode.
  A block of at least 512 bytes may carry a summarizer label (protocol 050):
  it then renders as a `SummarizedReasoning` header row, `∴ Reasoning
  (summarized)` with the hint or with its line count and elapsed time
  while live, and the label beneath as dim text of at most three rows.
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

- `session_view/skills.Page` decodes the attached daemon's paged skill commands.
  `Model.shared.skills` is presentation metadata, cleared with attachment replacement.
  `command.suggestions_with_skills` keeps built-ins authoritative and completes
  loaded names; `parse_with_skills` classifies them as prompts before mutation
  admission, including draft retention on observer or unavailable attachments.

- `command.Rename` sends control `RenameSession` for the attached identity.
  The bounded `ControlRequest` worker sends the mutation once and applies the
  acknowledged `SessionRenamed` row to the header and any open picker. It does
  not open the picker or reload its page. The owner and epoch checks remain
  server-side; a lost reply is not retried. `Model.shared.session_label` pairs one
  name with its identity, so legacy switches cannot carry an old title.
  The name travels through `daemon_selection.Target`, the job's `Prepared`
  and `Adopted` with the selected
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
  bootstrap ladder the picker uses, prints a styled table on a terminal and
  one line per row otherwise, or one line of outcome, and exits with a
  status. `list` shows the resident track by default — every lifecycle but
  a saved registration and a bare reservation, which `session_table.resident_track`
  tells apart from the rest — and prints one trailing line on a terminal
  naming each hidden lifecycle by its own count, `"4 saved, 1 reserved not
  shown (use --all)"`, when it held any back; `--all` (`tui.Showing`'s
  `Every`) widens either format to the whole catalogue, and off a terminal
  that trailing line never prints, since a parser was not expecting it.
  `tui.format_listing` is the pure seam behind both formats, taking the
  daemon's full page, a `Showing`, and a stand-in for
  `ffi_terminal.require_terminal`, which is what lets `sessions_list_test`
  exercise every case with no daemon and no real terminal. `rm` asks at the
  terminal before it
  sends and refuses outright when standard input is not a terminal, unless
  `--yes` was given. `ClaimAccess` and `Enroll` are `loom claim` and `loom
  enroll` (protocol-change/053), which hand their arguments to `tui/claim`
  and install no terminal state. `Access` is `loom access`
  (protocol-change/053 phase 2): `tui/access` hands its arguments to
  `host/access`, which `loomd access` runs too, so both print the same lines.
  It also installs no terminal state; it is the owner's command, run against
  the local daemon or, with `--addr` and `--token-file`, a remote one, and its
  `--help` is answered only when `access` is the first word (it is also a
  plausible session or display name). `Remote`'s bearer comes from
  `launch_token`: `--token-file` is read through
  `host/bootstrap.read_private_bounded`, which refuses a link, another user's
  file and a group- or world-readable file, and both `--token-file` and
  `--token` refuse a claim-shaped value without repeating it.
- `tui/claim.{Remote, Options, Claimed, Failure}` is the invitee's half of an
  invitation. `remote` checks the address with `host/claim.remote_address` and
  forces `<state-dir>`, `remotes/` and `remotes/<label>/` to private `0700`
  directories (label: the host, with a non-443 port). `redeem` refuses a
  token that is not exactly `loomclaim_` and 64 lowercase hex and a label that
  already holds `remote.json`; `prepare` then writes `credential` and `claim`
  (the token's digest) at `0600` before any connection, reusing a stored
  credential only when `claim` names this same token. The exchange sends only
  the credential's digest, and the optional `--name` (`Options.name`, empty for
  none), on `/v2/claim`, checks the reply's fingerprint against that digest,
  and writes `remote.json`. A `not_found`, `expired` or `conflict` deletes
  `credential` and `claim`; `invalid_name` is `Invalid` and keeps them, since
  nothing was bound; anything else is `Unknown` and keeps them for a rerun. `enroll` stores a credential, removes a stale
  `claim`, and prints only its digest and fingerprint. The token arrives on
  standard input through `ffi_terminal.read_standard_line`, which prompts
  only on a terminal.
- `session_view/model.Peer` says where this client's commands go, and replaces the
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
  a handle on the open `--record` file, held in the `Model` so the reducers
  can name it in the effects they queue; `recording.append` is the only
  write after `start`, and the runtime calls it. `recording.Trace` binds a
  recorder to an attempt identity, and a lane that holds one queues
  `session_channel.Note` outputs. `recording.observed` is a test-only
  recorder that delivers each event to a subject.
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
  session always wins over a pane report, and `pane.release_agent` is
  sent on quit through a bounded synchronous exchange, so the pane is
  clear of this terminal before the VM halts. The integration reports
  under the third-party source `loom:terminal` — Herdr reserves the
  `herdr:` prefix for the integrations it ships itself, and a source it
  does not know earns none of its built-in session restore: the
  `agent_session_id` Loom sends is discarded there, and the
  `resume_argv` the report carries (`["loom", "--session", <id>]`) is
  what actually reopens the conversation after a Herdr server restart,
  from Herdr 0.9.2 on. A blocked report names the pending approval in
  its `message`, the field Herdr shows beside a pane that is waiting on
  the operator. Two rules decide what reaches the
  socket, and both are pure functions the tests pin. `announces` says the
  session identity is announced when it first becomes known and again on
  every switch, so the identity a resume command names is the one the
  pane is showing; nothing at all is published while no session is
  attached, which is the state the session picker is in. `config_for`
  refuses a `started_ms` below zero: the sequence is seeded from the wall
  clock, `seq` is an unsigned integer in Herdr's request schema, and the
  BEAM monotonic clock is an arbitrary-offset counter that is negative on
  macOS, so a monotonic seed would make the daemon reject every report. The
  one external is `tui/internal/ffi_herdr.exchange`, a deadline-bounded
  `gen_tcp` unix-domain round trip, because no stdlib or weft surface opens
  one.
- `tui/frame` renders a `Buffer` as rows of text, folding a wide glyph's
  continuation cell into the glyph and dropping the trailing blanks a
  full-rectangle paint always leaves. It is what a golden file holds and what
  `loom replay` prints off a terminal, so the two cannot disagree about a
  frame. `buffer_to_styled` is the coloured counterpart for a terminal: it
  goes through etui's `buffer.to_ansi_lines`, so no row carries a cursor
  move, each line closes the style it opened, and the output lands in the
  scrollback like any command's.
- `tui/session_table.render` draws `loom sessions list` for a terminal as an
  etui buffer sized to its content: aligned columns measured in cells, the
  lifecycle coloured by `session_table.state`. Off a terminal the launcher
  keeps the old one-line-per-row format byte for byte, because scripts parse
  it. `session_table.resident_track` is the filter behind the default view:
  a saved registration and a bare reservation answer `False`, and every
  other lifecycle — a transition or a blocked recovery included — answers
  `True`, so both formats draw the same reduced row set before `--all`
  widens either back to the whole catalogue.
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
- `session_view/protocol.Event` is the client-owned view of the frozen
  ClientGateway event union. Entry bodies cross the existing total
  `core/codec` decoder rather than growing a second durability codec.
  `ToolOutput(strand, operation, step, source_index, call_id, stream, text,
  total_bytes)` is the
  pushed rolling tail of a running tool call (`protocol-change/031`);
  `session_channel.ToolStreamed` carries it through the adopted lane and
  `tui/model.ToolTail` is what the model keeps — one per `{strand, operation,
  step, source_index, call_id, stream}`, replaced whole on every frame, drawn by
  `session_view/transcript_lines.tool_tail_lines` as one `ToolResult` line under the live region:
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
  `selection.open`'s startup wait and the stop path's retirement wait each
  hold one deadline for the whole wait, and every `GetOperation` or
  `GetSession` read inside it is given what is left of that deadline, never
  a fixed budget: a timed-out read retires the control owner, so one slow
  reply under a fixed budget ended a wait that still had most of its time.
  `tui/daemon/protocol` is the independent, total control codec:
  `Page` is bounded to 100 authorized records, lifecycle requests use the hello
  epoch, and `GetOperation` refuses an operation from another epoch locally.
  `SessionActivity(sessions)` encodes `sessions.activity` (a member is answered only for its own sessions)
  (`protocol-change/050`), refusing locally an empty, duplicated, or
  over-24 list; its `ActivityReply` holds one `Activity` row per resident, in
  request order, and a requested id missing from it is not resident. The row
  decoder requires only `session_id`: an unrecognized `state` reads as
  `Unknown`, and a missing or malformed optional field as `None`, `0`, or `[]`.
  `Session.subtitle` (`protocol-change/067`) is the first line of the session's
  first prompt, at most 60 characters: a missing member, `null`, a non-string,
  an empty string, and one over the bound all read as `None`, so an older
  daemon's frame decodes and a malformed value never fails a page. The
  terminal's picker does not draw it yet.
  Metadata/default reads never imply an open. Cleartext credentials are allowed
  only for literal loopback endpoints — `127.0.0.1` and `[::1]`, bracketed
  because that is the form `uri.parse` leaves in a parsed URI's host; remote
  control requires `wss`. The codec
  caps a complete frame before JSON parsing, but does not claim a preallocation
  bound in the inherited Stratus parser.
- `tui/bootstrap.Options` describes local-launch inputs, while
  `tui/bootstrap.Target` is the authenticated endpoint handed to the ordinary
  connection path. Bootstrap policy, record validation, retry timing,
  executable discovery order, and lifecycle decisions remain in Gleam.
- `tui/bootstrap.resolve_daemon` returns a `tui/daemon/bootstrap.Connected`
  independent of workspace selection. It uses the shared `host/endpoint`
  record, releases the launch lock before the child adopts its native fence,
  and checks v2 control hello against the published epoch. Existing live
  daemons bypass executable/config discovery. Default startup highlights a
  catalogue row and waits for Enter; an explicit `--session` selects it.
- `tui/session_selector.State` retains one authorized, revision-fenced page.
  It is also the cross-session view: rows are grouped by workspace in page
  order, each carries a `Presence` glyph (`!` needs you, `●` working, `○`
  idle, `◌` resident but unobserved, `×` recovery blocked, `·` other
  inactive), and Tab/Shift+Tab cycle
  a `Filter` over All, Needs you, Working, Idle and Inactive whose counts are
  of the page on screen. `presence` joins the row's lifecycle with
  `State.activity`, the latest `sessions.activity` answer per resident
  identity; only a resident row can be anything but `Inactive`, whatever an
  older answer said. `selected` indexes `visible` (grouped, filtered order),
  never the raw page, and `with_filter`, `observe` and `carry` keep the
  highlighted identity when it is still drawn. `observe` treats an asked
  identity absent from the reply as no longer resident. `carry` keeps the
  tab and the answers for rows still on a reloaded page of the same
  collection. `render` takes the host's wall clock (`Model.view.wall_ms`)
  for one column, the creation age, because the page has no last-activity
  time. A row is one line of fixed columns (marker, glyph, name, state word,
  short reason, age), so the state words and ages line up down the list;
  workspace headings shorten a home path to `~/…` and count their rows;
  rows sharing a name carry their short identity so twins stay apart; the
  `current` session is marked `›`. At an inner width of 96 or more a
  details pane shows the highlighted row's state and reason, last message,
  strands from the glances, and a model, workspace and identity table;
  narrower pickers give only the highlighted row a second line with its
  reason and last message, and a list taller than the frame says how many
  sessions it hides (`↓ 3 more below`). Hints are two rows (movement and
  opening, then the rarer keys); an open question takes the first and its
  answer keys the second. The picker is at most 116 cells wide. `Model.view.activity_poll` fills
  `State.activity`: while the picker is open on the active collection with
  resident rows, `session_control.service_activity` (from the tick) asks
  `sessions.activity` for at most `protocol.activity_limit` of them, on a
  control connection the worker opens and closes itself so the borrowed
  control's single slot stays free for paging, renames and opens.
  `drain_activity` applies an answer only to a still-open picker and rests
  the poll three seconds after each delivery; a page load makes it due at
  once. A refusal changes nothing on screen.
  `/sessions` does not scan workspace launch records. `tui/daemon/selection`
  resolves the selected row and canonical workspace, attaches directly when
  resident, or explicitly opens and observes the returned operation.
  `session_selector.Prompt` is the picker's other state: `d` opens a
  `ConfirmingDelete` for the highlighted identity, and only `y` answers it,
  so no single keystroke can destroy a conversation. The answer names the
  identity the question was asked about rather than whatever is highlighted
  when it arrives. `tui/model.ControlRequest` is the one job slot the picker's
  paging, renames, and deletes share: its `job` is the key and the replies
  received for it, and its `result` holds the outcome until the relay's
  `AllDelivered`. `r` opens a bounded `Renaming` draft for
  the selected identity; Enter saves, Escape cancels, and Ctrl+U clears it.
  Pasted text belongs to that editor and leaves the hidden composer unchanged.
  `session_selector.renamed` applies only the acknowledged row, while
  `session_selector.without` drops the row on the daemon's
  confirmation rather than re-listing, which would move every other row
  under the cursor. A refusal reaches the footer as an error and the page is
  left alone. The confirmation explicitly includes stopping the selected session
  before deletion; the job remains asynchronous while cleanup settles.
- `tui/effect.Effect` is what a step asks the runtime to do, as data:
  `Step(step_effect.Lane(session_channel.Out))` and
  `Attachment(attachment.Out)` wrap the two channels' queued outputs,
  `Step(step_effect.Recorded(..))` is a channelless arrival's recording
  line, and the rest name a socket write or close, a
  control close, a job start or cancel, an attachment cancel, an inbox
  discard, an input's recording line, the OSC 52 clipboard write,
  or a Herdr announcement or report. Every variant carries the handle it
  acts on, because an adoption can replace the model's socket later in the
  same step and the effect must still reach the handle it was decided for.
  `StartJob(key, spec)` and `CancelJob(key)` carry a job key, which is
  never reused and is looked up in the runtime's own table, so it names
  the same job at perform time that it named when the reducer decided. `session_channel.Out` is
  `Transmit(socket, frame)` or `Shut(socket)`; `attachment.Out` is a
  candidate channel output, `Acknowledge(to)` or `Abandon(status)`, and
  `tui_model.emit_attachment` queues an `Abandon` behind a `CancelJob` for
  the attempt's key. `Model.view.outbox` holds
  pending effects newest first and is empty between steps. ADR-013 records
  the design (issue #530, phase 1).
- `tui/attachment.Status` owns one provisional replacement: the key of its
  `job.Attach` job and what the runtime admitted for it, in a stage that is
  `Resolving` until the job's `Prepared` is admitted, `Published` until the
  next poll starts the candidate lane on its socket, and `Connecting` while
  that lane captures. `opening(key, trace)` builds one and starts nothing;
  `admit` takes the job's messages under its key, and one `Prepared` only;
  `accept` takes a frame an actor-hosted driver selected through `select`.
  The terminal validates the initial cut, acknowledges it, observes task
  completion and checks adoption before replacing the old socket.
- `session_view/session_channel.Channel` is terminal-owned state, not another actor.
  It admits one request at a time, grants one snapshot fragment per reply, and
  reconciles while idle every 250 ms until a frame has been pushed to it and
  every `pushing_refresh_ms` after (`Delivery`: `Polling` then `Pushing`;
  5 s, and the first push is the roster at subscribe, protocol-change/054); `next_due` names
  the reading the next `tick` can act at, which is what the poll timeout
  sleeps until. It holds no clock: `tick`, `receive`,
  `submit`, `lookup`, `history`, `replay_issued` and the `start`
  constructors take `now`, which the terminal takes from
  `Model.shared.stamp.transport_ms` and a replay lane holds at zero. `Update.Captured` carries a `Capture` saying
  what asked for the cut — `Notified`, `Refreshed` or `Requested` — which
  names the path a particular cut took. Which of them wins is a race with the
  idle refresh, so a fixture that must know whether pushes arrived counts
  `Update.Noticed` instead: the lane emits one per `committed` frame before
  deciding whether to capture, and `Model.shared.notices` accumulates them. Its existing outgoing slot can retain one
  immutable unsent mutation behind a capture of an already adopted session.
  `Disposition` distinguishes `Waiting`, `Sent`, and `DefinitelyNotSent`;
  waiting allocates no mutation ID or response deadline. A valid completed cut
  refreshes authority before the retained command is sent exactly once.
  `Model.shared.pending_submission` stores only composer-versus-overlay ownership:
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
- `test/session_channel_property_test.gleam` drives the real channel over 500
  seeded schedules of submissions, well-formed and faulty replies, pushes,
  ticks, retirement and close, built on `start` and a stand-in socket, with
  time passed to every transition from the oracle's own `now`. After every step an oracle rebuilt from the written frames checks
  one request in flight, increasing identities, credits, no mutation resend,
  exactly-once `UnknownOutcome` and `DefinitelyNotSent`, fail-closed stale
  replies, inert pushes, deadlines, the idle refresh at the interval the
  lane's pushes select, and that `next_due` names exactly the first reading
  a tick acts at (N1). A failure prints
  its seed and a shrunk event list. Its first run found that `close` and a
  transport `Closed` on an already closed lane each queued a second `Shut`
  (and the transport case a second `Failed`); both now leave a `Closed`
  lane untouched, and the property holds every event on a closed lane to
  inertness.
- `session_view/snapshot` validates attachment identity, exact credits, fragment
  offsets, immutable entry identity and payload limits. `session_view/snapshot_view`
  projects captured leaf ancestry with pure `core` and `machine` codecs.
  Missing parents remain unloaded rather than being assigned to main.
- `session_view/approval.Review` binds the displayed action, requested grants and
  register seq. Exact resolution lookups have their own channel lane; sparse
  lookup metadata cannot replace conversation history or configuration.
  `tui/approval_panel` presents a typed question, action preview and exact grant
  list, with the complete captured action, grants, tool and sequence available
  as escaped literal JSON. Its 16 KiB displayed-detail limit is a presentation
  bound: incomplete detail refuses approval, while denial remains available
  under the captured sequence.
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
- `tui/markdown` takes a code fence's token classes from
  `session_view/code_tokens`, the scanner the web view also draws, and keeps
  only the style for each class (`code_span`).
- `tui/markdown` walks `session_view/markdown`'s closed tree, the one the
  web view also draws, and emits etui spans directly. `render_detail` is
  `render` for a tool's detail rows (`ToolDetail`): the harness's fences
  name a language only so the source is highlighted, so the label row an
  answer's code block opens with is dropped. The parser is linear
  in its input and bounds the tree's depth; mork, which this module walked
  before, took time exponential in a run of unclosed `[` and hung the
  terminal, since the live tail parses an answer again on every delta. `render(markdown, width)` takes the width the rows will
  occupy because a table is the one block whose shape must be settled before
  it is drawn: columns are measured in terminal cells with `etui/text`,
  narrowed by max-min fair share when the grid is wider than the width, and
  abandoned for one labelled record per source row only when no column can
  keep three cells. Callers subtract whatever prefix they will add, since a
  speaker mark or list marker is cells the grid does not have. Code rows
  carry a `▎ ` gutter rather than the block quote's `│ `, which is how
  `wrap_lines` recognises them without comparing styles, and they are
  hard-wrapped on cell boundaries so source indentation survives. GFM
  alerts, task boxes, footnotes, reference links and bare links arrive as
  nodes of the tree. The parser folds a soft line break into the text
  around it, so `join_soft_break` joins the space into the plain span on
  either side exactly as a whole-paragraph parse does. It never passes
  model text through HTML or an ANSI renderer.
- `tui/agents` projects the server's strand snapshot and `live_op`
  phase into a hidden-by-default rail and an inspector. It owns no second
  agent-lifecycle state.
- `tui/peer_links` owns the peer-grant inspector, exact target-strand draft,
  and review step. `tui/interaction` routes the selected key to
  `tui/session_control`, which sends each inspection, link, or revocation over
  the owner-authenticated daemon control socket. `tui/model` holds the modal
  and its pending control outcome; `tui/render` paints the resulting state.
- `tui/access_overlay` owns the owner's `/access` overlay (see "Access
  overlay"): the principal and membership lists, their paging, the y/N
  review of each change, and the pure `update` that returns an `Action`.
  `tui/session_control` runs its requests and `tui/render` paints it.
- `tui/agent_row.{Shape, Mark}` draws one agent as one row for both the
  strip (`StripRow`) and the workspace list (`TableRow`): `rows` labels the
  list together (`labels`, twins keep a digest head), sizes its columns and
  marks the cursor and the viewed strand. `status_mark`, `status_style` and
  `glyph` are the status vocabulary every agent surface draws; `cut_middle`
  and `cut` are its two truncations.
- `tui/agent_strip.{State, Focus, Line, Outcome, StripKey}` is the pinned
  per-agent strip under the footer (see "Agent strip"). `State` holds
  keyboard focus beside an `agent_roster.Roster` (decoded glances,
  per-operation clocks and pushed context sizes); `Line` is
  `agent_roster.Line`. The model holds the two halves apart, the roster in
  `Model.shared.roster` and the focus in `Model.view.strip_focus`;
  `tui_model.strip` rebuilds the `State` and `tui_model.store_strip` stores
  one back. Session replacement resets both.
  `layout.strip_height` uses `agent_roster.listed_count` and
  `agent_strip.height_for_count`, so geometry never formats task text or
  elapsed figures. Painting still obtains the same membership through `lines`.
- The prompt cache: `Model.shared.cache` is a `session_view/cache_watch.Ledger`
  (each strand's watch, the pushed-row cursor, held rows and model-switch
  fences), which the reducer feeds through `admit`, `settle`, `capture`,
  `observe` and `forget`; `session_view/cache_miss` detects a miss and
  computes the outlook, and `cache_watch.shown` decides whether the footer
  shows one. Both are shared with the web view.
- `session_view/composer` separates editable prompt text from large pasted-text
  and validated image attachments. It owns the approximate token indicator,
  expands exact pasted text only at the gateway boundary, and keeps local
  image paths out of typed prompt blocks.
- `tui/image_drop` parses only terminal quote and backslash-space path
  forms, sniffs PNG/JPEG/GIF/WebP magic, and enforces the 20 MiB limit before
  reading a whole image. Its small Erlang helper reads only the classification
  prefix or bounded body; a one-task `weft` run with a deadline bounds
  descriptor opens and reads to one second, and its cancellation kills and
  joins the worker before the caller sees the timeout. It performs no path
  expansion or shell evaluation. The host reads, the step does not:
  `runtime.message` calls `load_paste` for a paste and carries what it
  found in `msg.Pasted`, and the composer's paste handler attaches that.
- `session_view/block_summary.{Key, Subject, Reads, Labels, floor_bytes, max_blocks,
  new, stored, live, carried, receive, receive_board, want,
  next_read, refused, retain_live, decode_board}` — summarizer labels for
  long blocks (protocol 050), held per attachment in `Model.shared.summaries`:
  stored labels by `Key(entry, block)`, live labels by stream
  `generation` (with the response entry `stream_identity.response_entry`
  names, so `carried` can lend a live label to the committed block until
  its own arrives), and the exact-key reads still owed. `want` marks keys
  not held, asked or waiting; `next_read` hands out at most `max_blocks`
  and records them asked, so each block is read once per attachment;
  `refused` ends the reads for the attachment. `floor_bytes` (512) and
  `max_blocks` (32) are copies of the server's constants, pinned by the
  gateway's `the_terminal_copies_the_summary_bounds_test`.
  `transcript_lines.{summarizable_blocks, labels_for, summary_keys,
  live_summary_digest, live_summary_header, summarized_reasoning_line,
  summary_rows, labelled_advisor_lines}` and `render.summarized_mark`
  draw them: `labels_for` resolves one entry's
  labels by block index and is part of the compact entry cache's key, so
  a label arriving re-projects only its own entry. A long advice or
  nudges message collapses in compact mode to a `SummarizedAdvice` line:
  its heading and, beneath it, the label or its first line while none
  exists; a short one keeps its full body in
  both modes, and advisor commentary rows (`session_view/advisor_history`) are
  never summarized.
- `session_view/advisor_pending.{Board, decode, lines, primary_strand,
  advisor_strand}` validates an observation of undelivered advice. The composer
  uses the count/recipient heading from `lines`; `pending_nudge_lines` exposes
  every received body in the scrollable transient tail, with a pending and
  not-delivered label. A server-omitted suffix is explicitly reported. The
  terminal neither drains this queue nor adds its observation to durable
  records. The primary/advisor constants remain copied from the server and
  pinned by gateway tests, because the terminal links no server package.

- `session_view/goal_view.{Board, Status, PauseCause, LimitCause, CheckRun,
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

- **Depends on**: `session_view` for the session lane, the protocol and
  snapshot decoders, the transcript's line builders and the shared step
  (`model.Shared`, the folds, the commands, the reads and the settle), which
  the terminal drives and the web view drives as well; `host` for shared OS
  bootstrap and WebSocket transport;
  `core` and `machine` for pure total entry/register/state decoding; `weft` for guarded,
  deadline-bounded connection startup; `etui` at commit
  `4d5e466cf433c322012cb874f147be4d6a400eef` (the fork's stack pinned in
  `gleam.toml`, whose last commit is etui#6, inline images: the terminal
  graphics probe, kitty placeholders and OSC 1337; etui#5, a linear wrap for
  a word wider than the row, is below it) with bounded
  input bursts,
  POSIX flow control disabled in raw mode, Unicode emoji widths, synchronized
  frames, full-screen scroll-region presentation, closed-input EOF,
  scrollback-safe styled lines (`buffer.to_ansi_lines`), and the
  `{etui_wake}` message that ends the loop's input wait with a `Tick`
  (`etui_terminal_ffi:wake/1`), and a 40 ms bound on a lone escape byte's
  wait, so Escape does not wait for the idle poll, and a styled wrap that
  gives a grapheme wider than the row a row of its own rather than looping;
  and small Gleam utility packages. Markdown parsing is `session_view`'s,
  not a dependency's. Stratus is a host dependency, not a direct
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
  `goal_pause` and `goal_resume`, and the automatic `block_summaries` read
  (protocol 050), at most 32 exact keys, once per block per attachment.
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
  whole each time; `block_summary` is a summarizer label for a committed
  block or a live reasoning stream, and an unknown `subject` is dropped;
  a pushed `error` is a daemon-side failure
  reported without closing the socket. An event name this client does not
  know is dropped. A daemon that predates live delivery pushes none of
  these, and the terminal behaves exactly as it did.
- **Launch flags**: `--record <path>` qualifies any interactive launch and
  writes the session as a recording. `loom replay <path> [--at <frame>]
  [--all] [--width <w>] [--height <h>] [--plain]` replays one and prints
  frames, defaulting to the last. Frames keep their colour when stdin and
  stdout are a terminal and are plain text otherwise or under `--plain`; `--width`/`--height` hold only until
  the recording's own first resize supersedes them. It exits non-zero with a
  worded error for an unreadable or undecodable recording, or a frame index
  the recording does not reach.
- **Keyboard**: ordinary text sends a prompt; slash commands own application
  actions. `/model` opens the model selector, `/agents` opens the inspector,
  `/schedules` lists every schedule the session holds and `/unschedule
  <name> [target]` retires one a strand created (the target defaults to
  the active strand, and an operator `[[schedule]]` comes back as a
  `conflict` naming the configuration file),
  `/sessions`, or Left from an empty composer with no pending paste, opens
  the daemon's authorized metadata selector; the footer's `← sessions` hint
  is shown exactly while Left would do so. `/peers` inspects
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
- **Compact tools and changes**: `session_view/tool_activity` groups consecutive tool
  calls, joining results by call ID and ending a group when a later response
  reuses an ID. Compact history retains every call and the group's failure
  count; Ctrl+g recovers the original entries. Code-mode source previews belong
  to their invocation, so pending, successful and failed calls keep the same
  bounded fenced-Gleam block instead of exposing the argument JSON. Captured
  `fs_edit` diffs remain the explicitly labelled fallback when a worktree observation is
  unavailable. Current-action labels use the captured operation's
  effect-pending batch indices rather than unmatched transcript calls.
- **Responsive changes pane**: `/diff` opens the changes on the docked rail's
  Changes tab at 120 columns or wider and as a single-panel changes view below
  that width. Opening them docks the rail without changing the operator's
  saved choice. Conversation and changes retain separate scroll offsets; wheel
  input follows the pointer, while PgUp/PgDn scroll the open changes view.
  Layout, wrapping, and selection use the same body geometry. Captured diff
  rows reuse unchanged line layouts at the same width and discard old keys
  when the captured projection changes. Closing the pane releases its cache
  and restores the conversation's scroll position.
- **Worktree navigation**: `session_view/worktree_view` validates a bounded Git board
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
- **Completion and live jobs**: `session_view/completion_summary` retains observed
  operation start boundaries and processes a result before a successor in the
  same cut. It attributes captured edits and paired tool outcomes only within
  that ancestry interval. Missing ancestry is partial; a missed start is
  unavailable. The latest card and `/summary` show actual command exit codes,
  queued work, and a separately timestamped `session_view/live_jobs` roster. Completion,
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
  (also `/contextall`) adds bounded item estimates. `session_view/context_view.State`
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
- **Advisor pending-nudge panel**: `session_view/surfaces.sync_advisor_nudges` issues an
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
  it. `session_view/surfaces.goal_action` reads the board on the three edges
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
  three (and `block_summaries` needed the same three), and missing one is
  not cosmetic: `session_view/session_channel`'s
  `matching_presentation` and `outbound` both switch on the literal
  command string, and an unlisted name in `outbound` defaults to the
  `Mutation` lane — which held the composer lane forever and hung every
  attachment, since an observation's own reply never arrives to release
  it — while `session_view/attempt`'s `decode_selection` rejects an unlisted kind
  outright, which fails the recording replayer on any log carrying that
  command. Both have regression tests now
  (`the_observation_takes_the_read_lane_and_its_reply_settles_it_test`,
  `auxiliary_and_queued_edit_descriptors_round_trip_without_command_bodies_test`),
  but the tables themselves stay three separate lists a new read command
  must be added to, not one the type system enforces.
- **Current notes**: `/notes` requests a separate bounded `notes` observation.
  `session_view/notes_view` validates values, last-write revisions, capture revision,
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
- **Identity line and input frame** (`tui/input_frame`): the top row is the
  identity line on the raised background, the workspace's last segment, the
  session's name (left out when it repeats the workspace), `strand <id>`, the
  viewed sub-agent's task, and on the right the model's last segment and the
  strand's effort. Nothing on it changes while a turn runs. The composer is a
  rounded frame whose rules carry everything live: top-left `To <strand> ·`
  and what Enter does, in keys (`layout.input_keys`), top-right what the
  strand is doing with its elapsed time, queue count and `Esc interrupts` (or
  `○ <strand> · idle`), bottom-left only model, effort, `ctx ~N%` and
  `est $N`, bottom-right `N need you` from `strand_card.needing`, drawn only
  while it is above zero. A notice, the cache outlook and the reason behind
  an unusual key (`Stopped · …`, `Disconnected · …`) are rows of the status
  band inside the frame (`layout.composer_status_lines`), never the rules. When the two labels of
  a rule do not fit, the top rule keeps its left and the bottom rule its right.
  Below 72 columns the top rule carries no activity and the status band above
  the editor shows it, as it did before. An open approval locks the frame
  (`locked while deciding`). The editor sits two cells in from the left side,
  behind a `›` prompt; an empty draft shows the live key hints as placeholder
  text. `input_frame.prompt_margin` is the editor's wrap allowance.
- **Conversation and footer**: the reading surface has a gutter and no
  heading row (`layout.transcript_inner`); the identity line names the
  strand. Its bottom row is the reading row: while the reader is above the
  tail it reads `↑ reading · N rows below · End jumps to latest` and a
  click on it jumps; while help, notes or a diff borrow the area it names
  them. Neither changes the viewport height.
- **Approval block** (`approval_panel.render`): a full-width block under a
  rule directly above the input frame, headed `? <strand> · <question>`
  from the escalation's scope (`approval.Review.strand`) with `1 of N` at
  the right while N questions wait, then the request, its action, the
  grant and whether session approval exists, then `1`, `2`, `3` choices
  that select and never confirm, Enter to confirm, `d` for the raw request
  and Escape to defer; the input frame says it is locked meanwhile. An open
  question counts in the bottom rule's `N need you`, beside the agents
  whose rows need input (`render.needs_you`). The status band's rows sit
  one cell in from the frame's side, and the interrupt's own notice is not
  drawn while the held key's reason says the same.
  The compact footer is gone; its facts are on the input frame. Ctrl+G exposes
  the complete input/output/cache/rate accounting in the existing adaptive footer.
  Both footers fit whole pieces (`render.fit_pieces`): a piece that does not
  fit is dropped from the right, never cut through a figure. The detailed row
  leads with the cache read/write pair carrying the outlook (`cache 1.2m/40k,
  idle 3m`), so a narrow row keeps the warning, then context, cost, input,
  output and rate. Millions keep one decimal.
  Coherent cuts supply usage and cost; model names never imply prices. Workspace
  and branch discovery still runs once before the event loop, through bounded
  regular-file reads, and the identity line shows the workspace's last segment.
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

- **Speaker padding preserves cells.** Transcript rows paint their content
  before writing the speaker-colored padding directly to the buffer. Padding
  has a known cell width and does not pass through span width measurement.
  `transcript_padding_test` compares the previous padded-paragraph output by
  complete cells, including links, continuation cells and both repaint phases.

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
  both of its tokens.** `session_view/transcript_lines.advisor_payload` recognizes advice, nudges, the
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
  and the expand hint pushed it onto a second row. The rule holds for a
  block without a summary. A summarized block (`SummarizedReasoning`) is
  deliberately taller: a clipped header row plus at most
  `transcript_lines.summary_rows` (3) dim rows, laid out by
  `render.summarized_rows` and exempt from the outer wrap. A settled block
  borrows its stream's live label until its own arrives, so a block that
  showed a summary while live settles into the same rows; a label arriving
  later adds rows once, and the anchor projection is built from the same
  lines, so it stays parallel and the reading view relocates the reader
  (`a_summarized_block_keeps_anchors_parallel_to_rows_test`,
  `a_summary_off_screen_leaves_the_reader_in_place_test`). The live
  row's elapsed time is `Model.shared.generation_elapsed_s`, read from
  `generation_started_ms` on the tick (`tick.advance_generation_clock`); a
  change repaints only while a reasoning row is on screen and leaves the
  record cache valid.
- **A summary never re-attributes text.** The header above a label names
  it as summarized (`∴ Reasoning (summarized)`, or an advice heading marked
  `(summarized)`), so a reader can tell the summarizer's words from the
  agent's and the advisor's. A label arriving clears `record_cache_valid`
  when it rewrites a cached row (a settled label, or a live one whose
  response is already recorded); other live labels touch only the
  transient tail. A refused `block_summaries` read is silent and ends the
  reads for the attachment.
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
- **The live tail draws what a full render draws.** `live_tail.rows` must
  return exactly `render.render_line` for the whole answer on every frame,
  since replay goldens compare frames byte for byte;
  `test/live_tail_test.gleam` checks it over generated streams, resizes and
  resets. It settles a block only at a blank line followed by a line
  starting with a letter, and only after rendering the halves and the whole
  to confirm the cut; a paragraph checkpoint sits only after lines free of
  Markdown punctuation, `&`, hard breaks and blank lines, before a line
  starting with a letter, and is dropped when a later line could be a
  setext underline or table row; it renders whole any text holding a reference
  definition or footnote; and it keeps no copy of the answer: the stream is
  recognised by its fragment list, which the projection checks against
  the stream on every frame (`live_tail.extends`), so a reset or collapse
  starts the slot over and no reducer touches the cache; a stale cache
  lives only until the next projection that draws the live lines, and a
  tool call delta, whose list is replaced every time, is not a cached
  source. `live_tail.shortcuts` is how tests show a shortcut was
  actually taken rather than every frame falling back to a full render.
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
  five rows at once. `Model.view.revealed_rows` is how many of `rendered_rows` the
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
  for the worktree request, the shared step's settle
  (`session_step.settle`: the context, pending-nudge and goal edges), Herdr
  report, projection, viewport snap and frame decision. `settle_update` taking the dispatched model as a
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
  into `session_view/surfaces`, `tui/inbound`, `tui/projection`, `tui/interaction`
  and `tui/tick`, which the inliner never attempts, but `snap_viewport_for`
  is still local and the boundary stays.
- **The terminal calls the shared units, not `session_step.update`.**
  `session_view/step.update` composes the same units for a whole event in a
  host with no surfaces of its own, and only the web view calls it. The
  terminal cannot: a tick is not one shared call, since `update_tick` places
  its replay, control, candidate, reconnect and activity drains among the
  shared drains and `inbound.settle_surfaces` applies each update's facts
  before the next update reads the state they change, and a key handler that
  runs a command writes its own state after the command while the settle runs
  once, in `settle_update`. The two compositions are held to one order by
  `packages/session_view/test/step_test.gleam`, which spells this tick over
  the shared record and compares. A change to the order `update_tick` and
  `settle_tick` run the shared units in (the activity and roster clocks, the
  connection drain, `session_step.service_reads`, the lane's tick) must be
  made in `step.update` and that test as well, or the web view drifts from
  the terminal without a failure here. `Shared.ended` is written by the lane
  fold for the web view's heading; the terminal never reads it, and
  `tui.new_model_with_clock` and `interaction.candidate_outcome`, the adoption, set it to `None`.
- **Tick settling has the same parameter boundary.** `update_tick` drains
  the replay, control, the candidate, reconnect, the activity poll and the
  connection, in that order, before passing the result to `settle_tick`.
  Every drain takes from what admission filed before the step, so none of them adds a mailbox read
  to the step. The helper applies the existing read-service chain to its
  `drained` parameter and retains the original model for quiet-time and activity
  comparisons. Adding the notes read to the former single body exposed another
  inliner blow-up: `core_inline_module` took 51.445 seconds. The boundary reduced
  that phase to 1.632 seconds in the generated-code experiment; the actual Gleam
  package build took 7.80 seconds. Keep the service order and this boundary.
  Both functions now live in `tui/tick`; the services are cross-module calls
  into `session_view/surfaces` and `tui/inbound`, but the drains and
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
  `session_view/transcript_lines` and 2.39 s for `tui/interaction`. These are
  measurements, not budgets.
- **A one-field update of `View` or `Shared` goes through a setter.**
  `View` has about eighty fields and `Shared` about ninety, and Gleam compiles
  `View(..view, f: x)` to a tuple with one `element/2` read per untouched
  field. Each such expression cost erlc roughly 10 ms, and the terminal's
  handlers and tests held about 800 of them: `tui/interaction` took 1.67 s of
  erlc CPU, spread over every key handler (stubbing the ten largest functions
  removed 0.1 to 0.6 s each), and the test modules were more than half of a dev
  build. `tui/view_set` and `session_view/shared_set` hold one setter per field
  that three or more sites set; a handler pipes the record through them
  (`model.view |> view_set.input(x) |> view_set.history_index(0)`) and keeps a
  record update only for a rarer field. Erlc CPU summed over a clean build,
  measured by compiling each module's abstract format in one VM: `tui` sources
  5.9 s to 3.2 s, `tui` test modules 8.6 s to 3.9 s, `session_view` 3.1 s to
  2.5 s. A new field that a handler sets from three places wants a setter;
  `tui/model` cannot import `view_set` (it would be a cycle), so its own
  `View` updates stay record updates.
- **Presentation uses one caller-owned clock, read once per event.**
  `new_model` supplies the host's monotonic clock; `new_model_with_clock`
  lets a test supply its own. `tui.update` calls `runtime.message`, which
  reads `Model.view.monotonic_time_ms` and `Model.view.transport_time_ms`
  once each into the input's `msg.Stamp`, and the wall clock once into its
  `wall_ms`; the step stores them as `Model.shared.stamp` and
  `Model.view.wall_ms` before any reducer runs (`tui_model.start_step`) and
  reads no clock: frame pacing, generation throughput, activity elapsed time, the
  cache outlook, the jobs and activity-poll ages and the strip all read
  `stamp.now_ms`, the session lanes read `stamp.transport_ms`, and the
  creation key reads `Model.view.wall_ms` with `Model.view.terminal`, the OS and BEAM
  process identity read once when the model is created. The build the
  mismatch notice compares with the daemon's is read once too, into
  `Model.view.client_build`. The message is a cross-module call on `update`'s
  parameter, never a local step in `tui.gleam`, for the inliner reason
  above. The two monotonic readings are
  separate because a test may fix the presentation clock to pin frames
  while its live socket still needs real deadlines; in the shipped client
  both are the host's monotonic clock. The transport clock is injected
  like the presentation clock: a fixture that puts a socketless replay lane
  on a model freezes it at zero, so that lane's refresh and deadline cannot
  depend on where the host's arbitrary monotonic origin sits. A test steps
  through `tui_test/stepping`, which builds the input at the stamp the
  model carries (the creation-time reading for a fresh model), and sets
  `stamp` to choose another; a driver that runs a reducer outside the step
  calls `runtime.stamp` first. Daemon bootstrap
  and recording timestamps are outside the step and keep their real
  clocks. `test/clock_test.gleam` exercises the event handler at negative
  epochs, pins repeated scripted intermediate frames with a fixed clock,
  runs a step under a clock that panics when called, counts one reading
  per `update`, and fires a lane's refresh and deadline from the `now` it
  is passed.
- **Traffic is filed before the step and reduced in it.**
  `tui.update` is `settle(step(message(event, model), receive(model)))`.
  `runtime.receive` hands every job message over first (`hold`), so a
  `Prepared` admitted in that receive has its first frames read with it,
  then reads each inbox's mailbox up to the room its buffer has left
  (`arrivals`): `Model.shared.inbox` to `connection_batch` (64),
  `Model.shared.replay_inbox` to one event, and only while the peer is
  `Replaying`, and the candidate's frames to forty until capture
  (`attachment.frame_room`). `tui/admission` files what it
  read, the same function the step runs for `msg.Arrived`, and reduces
  nothing. `inbound.drain_connection`, `tick.drain_replay` and the
  attachment's `prepare`, `drain` and `settle` take from those buffers and
  read no mailbox; traffic that arrives during the step waits for the next
  one. The orderings stay in the step: Escape with a waiting command
  cancels before any traffic is reduced and leaves the batch held, the
  tick settles the candidate before it drains the connection, and a drain
  after a mid-tick adoption reads the adopted inbox. The bound is the
  host's, kept by reading no more than there is room for; admission never
  drops a frame for capacity, since that would be a gap in the lane's
  sequence. A frame is tagged with the inbox subject it was read from, and
  admission files it only into the adopted inbox or the waiting attempt
  with that subject; the buffer is inside the inbox value, so the adoption
  swap is one assignment and the old socket's held messages leave the
  model with it. That is the rule the terminal-attachment P model checks
  as S2. A host that wakes on arrival delivers `Arrived` and then an input
  with `Ticked`, and never reduces on an arrival alone. Anything that
  reads an inbox outside the step keeps held messages first:
  `attachment.accept` appends a selected frame behind the held ones with
  `buffered.push` and then advances as the poll does, and the client test
  driver reduces held connection messages before a selected one. A test
  that calls `step` directly and wants it to see queued traffic calls
  `runtime.receive` first or steps a `msg.Arrived`, and a test injects
  traffic through `buffered.sender`. `test/runtime_receive_test.gleam`
  pins the bound, the Escape exception, the held-first read, the swap and
  the candidate-first tick, and `test/admission_test.gleam` the filing,
  the stale-subject refusal, the room the host reads and generated runs
  against phase 2's receive (ADR-013, phase 3 addendum).
- **Jobs start after the step and answer by key.** A reducer allocates a
  key and queues `StartJob(key, spec)` through `tui_model.start_job`; the
  slot that waits for the job (`ControlRequest.job`,
  `ReconnectAttempting`, `ActivityAsking`, `Model.view.candidate`,
  `Model.view.configuring`) holds the key
  and the messages received for it. The step creates no subject, no cancel
  signal and no process. `runtime.perform` starts and cancels jobs in `Model.view.running`,
  which no reducer reads, and `runtime.settle` stores the table back, so
  `tui.update` is `settle(step(message(event, model), receive(model)))`.
  `runtime.receive` reads every running job's messages, at most two per
  one-task relay and a `Prepared` besides, in one pass over the mailbox
  through the merged `job_runner.selector` (none when no job runs), and
  `runtime.hold` has
  admission file each into the slot of its kind only when the slot holds
  the same key; any other message is dropped there. An attachment job's
  end is handed over as `job.Finished` with the host's read of whether the
  adopted socket's actor is alive, and the attempt adopts or fails on
  that answer, so the step reads no process
  (`test/socket_liveness_test.gleam`). A dropped `Prepared` has its socket
  closed and its frames subject emptied, and a dropped relaunch
  `Completed` its control closed, by `CloseSocket`, `Discard` and
  `CloseControl` effects `hold` queues, so `receive` and `hold` only read
  mailboxes; `job_runner.dropped` does the same closes directly for what a
  cancel drains. A reducer that clears a relaunch slot, an adoption or a
  quit, first releases what it holds through the same
  `tui_model.release` (`release_reconnect`).
  Clearing a slot drops its held replies with it, so a reducer that stops
  waiting for a job never sees its replies again. The runner keeps a job
  until its relay's last message is read, whatever its slot holds, so no
  job's messages stay in the mailbox. Quit clears each slot as it queues
  the lane close, then `CancelJob` for the attempt ahead of its `Abandon`,
  then `CancelJob` for the control job, the relaunch, the activity poll and
  a session creation's configuration job, in that order. A failed attempt queues the same `CancelJob` and
  `Abandon` pair, through `tui_model.emit_attachment`. The launch
  paths flush their first catalogue load so it starts before the loop.
  A test allocates a key with `tui_model.allocate_job`, hands a slot a
  reply with `runtime.hold`, and calls the drain or `step`; a test that
  needs a real worker uses `job_runner.start_task`. The client test driver
  selects `job_runner.selector(model.running)` and hands what it selects
  to `runtime.hold`. `test/jobs_test.gleam` pins the start, the key fence,
  distinct keys, the cancel, the read to a relay's last message and the
  drain order, and `test/attachment_jobs_test.gleam` the attachment's
  start, its frames inbox coming only from `Prepared`, the close of a
  dropped `Prepared` and the cancel of a failed attempt (ADR-013, S4 and S5
  addenda).
- **The step reads no file.** A terminal delivers a dragged file as a paste
  of its path. `runtime.message` reads the file when a paste names exactly
  one path and carries what it found in `msg.Pasted`, so a read travels
  inside its own paste's message and cannot outlive it or be attached to
  another paste. The read is before the step rather than a job because a
  job answers a step later, and a key typed in between would be applied
  first: an Enter could submit without the image. A new session's
  configuration, which reads `HOME` and asks the file system about
  `--config` or `<state-root>/loom.toml`, is resolved by a `job.Configure`
  job instead. The picker stays open until the reply, and the creation's
  checks, the pending-submission cancel and the creation key all happen in
  the tick that takes it, in the order the step used to make them, so a
  local failure still sends nothing and retains no key. A
  terminal without local launch options has nothing to resolve and creates
  in the step. A test that needs a paste's read builds the input with
  `runtime.message`, or a `msg.Pasted` itself; a test that presses `n` with
  local options ticks until `Model.view.configuring` is `None` before it looks
  for the creation key. `test/file_reads_test.gleam` pins both moves
  (ADR-013, S6 addendum).
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
- **Markdown stays structured.** `session_view/markdown` parses it, in
  time linear in the text, and the adapter emits etui styles and OSC 8
  links. A parser that backtracks on hostile input hangs the terminal,
  because the live tail parses an answer again on every delta;
  `markdown_parity_test` holds 50,000-character runs of `[`, `![` and
  `[a](` to EUnit's limit through both render entry points. A table is drawn as a bordered grid measured
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
  `session_view/transcript_lines.advisor_payload` recognizes each by its whole frame — a header line
  with its footer, or the header with the `advisor-nudges` fence — and
  `session_view/transcript_lines.advisor_lines` draws the row as `System` under the advisor's name:
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
  another process panics. `job_runner.start_attach` creates the frames and
  `Prepared` subjects and the relay's subject in the terminal, when the
  runtime performs the attachment's `StartJob`, before the worker starts; the
  step creates none. The worker owns only its acknowledgement subject. The shared socket guardian monitors the
  terminal owner through cancellation and adoption. Actor-backed native tests
  reduce already selected messages directly rather than requeueing them.
  Because `update` tops up the model's inboxes on every event, even a
  resize, it must run in the process that created the model; a test that
  hands a model to an actor builds it in the actor's initialiser.
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
- **A step performs no fire-and-forget I/O.** `tui.step` returns the next
  model and a `List(Effect)`; `tui.update` performs that list through
  `runtime.perform` after the step, and nothing in a reducer writes to a
  socket, closes a connection, cancels a worker, discards an inbox, prints
  the clipboard sequence, reports to Herdr or appends to the recording.
  `session_channel` queues its writes, closes and recording notes as
  outputs; every reducer that transitions the adopted lane stores it through
  `hold_channel`, whose outputs reach the outbox at that point: the shared
  form queues them on `Shared.outbox`, and `tui_model.hold_shared`, which
  stores the result of every call into a function over `Shared`, moves them
  into `View.outbox` before anything else is queued. `attachment.poll` and
  `accept` return everything the
  candidate's lane queued with the rest of what they decided. The outbox is
  therefore the step's one queue, in the order the step decided things, and
  a lane stored any other way keeps outputs nothing collects: a later
  replacement loses its writes and its recorded close. A caller that runs a
  reducer outside `update` flushes it with `runtime.flush`, after storing
  any lane it built through `hold_channel`; a bare channel is drained with
  `take_outputs` then `perform`. The next `update` also performs anything
  left in the outbox. One consequence is that a send leaves at the end of
  its step, so a zero-timeout drain later in that step cannot see its
  reply. Clock reads left the step in phase 2's first slice, the
  connection, replay and attachment drains in its second, recording writes
  in its third, the control, reconnect and activity jobs in its fourth, the
  attachment job in its fifth, and file reads in its sixth; phase 3 took
  the adopted socket's liveness read into `runtime.hold` and the client
  build identity to model creation (`Model.view.client_build`). The step now
  reads no clock, file, mailbox, process or environment variable: see the
  clock, traffic, job and file invariants above and the recording
  invariant below.
- **An attached peer always has its lane.** `Peer.Attached` carries no
  socket. The adoption in `interaction.candidate_outcome` is its only
  constructor and sets `Model.shared.channel` in the same update, and nothing
  clears the channel again, so every write and close goes through the
  lane. The arms that closed or wrote to a peer's socket with no lane were
  unreachable and are gone with `effect.Send` (ADR-013, phase 3 addendum).
  The remaining `Peer` branches change state or rendering, not only
  effects, and a replay's writes are stopped by its having no lane.
- **The recording is written in the order its causes were decided.**
  `tui.step` queues the input's own line first, before the reducer runs,
  and every attempt note is queued where its cause was decided, in the
  same queue as the lane's writes: a request's `Issued` before its frame, a
  frame's `Received` before anything it made the lane send. Event N's lines
  therefore all precede event N+1's (ADR-009). Offsets are read when the
  runtime appends, not from `Model.shared.stamp`. An attempt's failure note is
  queued ahead of its `Abandon`, and the `Closed` that `attachment.cancel`
  decides is written when the runtime performs the `Abandon`, at its place
  in the queue. An advance that fails part way through a poll keeps its
  notes and loses its writes, as it did when notes were synchronous.
- **A shared call's editor consequences land at its hold.** A function
  over `Shared` cannot write the composer, the queue editor or the goal
  inspector, so it records what they must show: `drafts_sent` moves on a
  sent composer draft, `queue_notices` and `goal_observations` gain an
  entry. `tui_model.hold_shared` applies and empties them before it
  returns, which is where the send or receiver used to write the editor
  itself, so the terminal's state after each call is what it was before
  the cut. A result stored without `hold_shared` leaves them behind;
  `tui_test/stepping.step` asserts both lists are empty after every step,
  as it does for `Shared.outbox`.
- **An update's surface facts are settled after that update.** The event
  fold, the lane fold and the commands record a `SurfaceFact` where an
  update or a command used to write the terminal's editor, overlays or
  footer, and `inbound.settle_surfaces` applies them after each call into a
  fold or a command (`inbound.apply_channel_update` per update, the tick's
  `apply_replay_change` per replay change, the channelless message, and
  the terminal forms), not at the end of the step. One step applies many
  updates, and a later update reads or overwrites what an earlier one
  wrote: a cut presents a question the next cut may show settled
  elsewhere, a stream fragment replaces the notice a notes board set, and a
  returned draft must reach the composer before a later switch parks it.
  The terminal state a decision inside an update reads comes from the
  `lane_fold.Surroundings` the host passes in, which no update changes. A workspace switch parks the viewport height measured on the
  model before the call, because layout reads shared state the rest of the
  event changes. `tui_test/stepping.step` asserts `surface_facts` is empty
  after every step.
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
  credited `catch_up` on its idle refresh and includes metadata-only
  changes. Equal cuts
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
  capture. The idle refresh is the recovery path for a lost notice and
  the only path on a daemon that pushes nothing; it runs every 250 ms until
  the lane has been pushed to and every `pushing_refresh_ms` after, because
  a lost notice is repaired by any later one and only a lost final notice
  waits for it (a join is pushed; protocol-change/054).
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
  bytes its fragments weigh, and past twice `session_view/transcript_lines.live_stream_limit` — 24 KiB,
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

`test/frame_scene.gleam` builds whole frames from durable entries: `attach`
runs a scene's entries (`user`, `assistant`, `call`, `result`,
`provider_error`) through the shipped capture decoder and the `Captured`
update, `screen` paints the full frame at a size through
`render.render_frame`, and `write_styled` writes it with its colour for a
review render. Layout tests that need the screen in context use it rather
than painting one widget onto a blank buffer.

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

The composer and queue panel derive held input from
`model.active_queue_halted`, using `snapshot_view.queue_halted` on the current
cut and excluding a submission already in flight. This outlives local interrupt
retirement and works on a second attachment that never sent Escape. The agent
rail's terminal outcome remains separate from composer acceptance. The small
queue hint preserves the existing preview width and paging; it labels held
rows while the composer explains that Enter sends them with the next message.

Goal write invalidations are read by the shared lane, not by a terminal poll.
`surfaces.receive_goal` retains these correlated boards without opening an
inspector or printing a command confirmation. Explicit operator reads retain
their attachment-owner check. An invalidation arriving during an older goal
read survives that reply in the lane and requests a newer board.

The goal report and its issued request identity live in
`session_view/model` and `session_view/outbound`. The terminal applies their
observations through its existing shared-state wrapper.


## Reading held input and goal observations

The scoped module `## Flow` comments connect shared decisions to terminal
presentation. `model.hold_shared` consumes goal observations in order through
`show_goal_observations` and `observe_goal`. `render.input_behavior` and
`render_inline_queue` both use `model.active_queue_halted`; they do not infer
held input from the last operation's terminal outcome or interrupt notice.
A correlated refusal clears `Shared.goal`, while an open inspector can keep
its old board with the failed refresh label. The
[delivery reading guide](../../docs/architecture/delivery.md#reading-the-held-input-and-goal-paths-in-gleam)
shows the source paths, actual state constructors and request-ID traces.

## Deep Docs

- [`docs/architecture/terminal.md`](../../docs/architecture/terminal.md)
  describes the terminal client as built: its loop, connections,
  reconnection, rendering and recording.
- [`docs/design-notes/etui-client.md`](../../docs/design-notes/etui-client.md)
  records the measured evaluation and the later adoption decision.
- [`docs/design-notes/step-extraction.md`](../../docs/design-notes/step-extraction.md)
  records how the session's half of the step moved into `session_view`: the
  field split, the facts, the rulings on the host's loop, and the slices.
  [ADR-014](../../docs/adr/014-second-runtime.md), with its addendum on the
  step, is the decision.
- [`docs/architecture/delivery.md`](../../docs/architecture/delivery.md)
  traces a frame from the socket to the screen in both hosts.
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
trees and switches links, then prunes superseded trees that no link selects,
that are not the repointed links' previous trees, and that no live process
uses (docs/updating.md). A failed install prunes nothing. Updates to
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

Existing conversation rendering uses `core/origin.display_label` for human
sources. Agent traffic has three speakers of its own, which
`session_view/transcript_lines` chooses from the call or the stored origin
and never from the text, and `tui/message_rows` draws: a `SentMessage`
(`→ to sub:tests · agent_send · admitted to its queue`), a `StrandMessage`
(`← from sub:docs · strand message`, the Agency's framing removed and a
brief's result contract after the body) and a `PeerMessage`, a band reading
`⇄ peer session 01a07d74 · strand main · ✓ origin checked by the daemon`.
A line's text is its heading, a newline and its body; only the heading is
drawn as a heading, so body text that reads like one stays body text
(`test/message_rows_test.gleam` pins it). A body is drawn as text, each
line the agent wrote a row of its own. A heading ends in the local clock
time the message was admitted (`· 14:02`) when the terminal knows its zone:
`tui.new_model` reads the offset once at start into
`Shared.clock_offset`, and a model built for a test keeps none and draws no
time. The first two kinds hang from a bar in the other strand's hue, one of
cyan, violet and green (`message_rows.strand_hue`), which `render` paints in
the margin column left of the transcript (`message_rows.margin_bar`), so the
row's own cells and copy gutter are where any row has them.

Every narrative block opens bare and closes with a blank row: a turn, an
answer, a message, a notice. The tool family opens and closes bare, and the
fold places a spacer between a block that closed bare and one that opens
bare, so there is one blank row between any two blocks. A call keeps the
gutter with its glyph (`× ` for a failure) and only its result hangs under it,
`  └ `; a tool group's heading is its own speaker, `ToolGroup`, drawn `▸`.

A call's settled row needs its result. A response holding prose draws its
calls inside itself, so `transcript_lines.joined` joins every result to its
call across the compact window: the call is drawn as a tool group draws it,
the result entry draws no rows, and the response is projected afresh rather
than from the entry cache.
`record_anchors_for` mirrors both halves, an empty block for the absorbed
result and `joined_block_lines` for the response's blocks, since a program's
block and its settled row differ in height. The separation fold passes over
an empty block to the last block that drew a row.

A code-mode program that is running, one that settled and one that failed
are titled blocks drawn by `tui/program_rows`: a rule carrying the title, a
box holding the body, and a rule carrying the foot, two cells in and one
short of the pane's right edge, the border in `theme.current` while it waits,
`theme.added` when it settled and `theme.danger` when it failed. A running block shows `PROGRAM · N lines,
M shown`, the program's first non-blank lines under their numbers, and
`RESULT · none yet`; its foot names the `within_ms` budget the call asked
for. A failure block shows the error; a compiler's diagnostic is cut to its
heading with `· line N` and the source it quotes, and the foot says how
many lines the whole error has. The key that expands a response is named
once, on its heading; the feet carry only facts. Body rows holding a number
and a `│` gutter are drawn as source on the raised ground. A settled block keeps the
running block's title and program rows, so they stay put when the result
arrives, and it grows below them with a `RESULT · object · 3 keys` preview with a type or size
hint per key in place of the value's JSON. A result that
carries the call record of protocol-change 060 adds to both: the settled title
says `4 calls` (or the record's whole summary when any call did not settle),
and a settled or failure block lists the calls under `CALLS · 7 calls · 1 failed`,
consecutive calls with one capability and ending grouped as `✓ fs.read ×3
a.gleam · b.gleam`, and drawn in the success or danger colour by that
leading glyph. The record is written on a result only, so a block still
awaiting its result has no call list.

An image a tool returned, or a person attached, is a placeholder row under
the row that carries it, `▣ image 1 · image/png · 1200×700 · 84 KB   o opens
externally`, built by `session_view/image_header`, which reads the pixel
size from a PNG, JPEG or GIF header in the data's first 64 KiB. Inside
Herdr (`herdr_reporter` set) a second row says pane graphics are not passed
through; `projection.noted_images` adds it to the line before rows and
anchors are built from it, so the two agree. While the reader is above the
tail with nothing typed, `o` opens the strand's newest image outside the
terminal: `image_drain.open_newest` starts `job.OpenImage`, whose worker
(`image_open.open`) writes the bytes to a file in a `0700` directory under
`TMPDIR` and hands the path to the platform opener with its output dropped
(`view_link.quiet_opener`: `/bin/sh -c 'exec "$0" "$1" >/dev/null 2>&1'` with
the opener and the path as positional arguments, over the same
`run_forwarding` launch `loom ui --open` uses), and
`image_drain.drain` turns the reply into the notice. The newest image is
chosen rather than the one on screen, since a row does not name its image
without the anchors.

## The docked rail

The rail is one column of the terminal, beside the transcript, replacing the
34-cell agent rail and the 72-cell changes pane that used to borrow the same
place. `tui/rail` decides it over plain values (`rail.columns`) and
`tui/layout` takes it from the screen before the body is cut: the identity
line spans the screen, the rail runs from the row under it to the last row, and
the input frame and the footer span the transcript's column only, so every
width they read is `layout.column_width` and not the terminal's. It docks only
where the transcript keeps 75 cells: 44 cells and a separator from 120
columns, 56 from 160. From 160 it is docked by default; narrower, Shift+Tab
docks it. A remembered choice (`View.rail`, the field `layout_memory` keeps)
wins either way, and below 120 columns it does not dock whatever was chosen
(the sheet is its form there, below). Opening the changes (`/diff`)
docks it wherever it fits, on its Changes tab, and closing them puts it back
as chosen; while they are open Shift+Tab closes them. Below 120 columns
Shift+Tab opens and closes the sheet and records nothing. While an approval is
open the rail steps aside in painting only (`layout.rail_area` is zero and
`rail_view.render` draws nothing; `layout.rail_columns` is unchanged), because
the approval block spans the screen, and the columns stay reserved so opening
or closing an approval never re-wraps the transcript or re-places an image. The input frame's top rule cuts the recipient and the
keys before it drops the activity, and the Ctrl+g footer is compacted to the
transcript's column (`layout.column_width`), not the terminal's. The changes
panel in the rail has no border of its own: its rectangle is the rail's
content grown by the cell a border would take (`layout.changes_panel_area`), so
`panel_inner` of it is the content, and it never borrows rows above the
composer. `View.diff_view` has two values now, `DiffHidden` and `DiffVisible`;
the automatic side pane it once named is gone.

The rail has four tabs, in the web view's order: Strands, Changes, Trace,
Session. The tab is a preference, except Changes. `View.rail_tab` is the tab
the operator left the rail on (none is Strands), the layout memory keeps it
(`tab`: `strands`, `trace` or `session`), and `rail.tab` takes it with the
changes setting: while the changes are open the rail shows Changes, and
closing them shows the remembered tab again. Changes is never remembered,
because it opens an observation of the worktree that a launch has not made; a
file that names it is read as no choice. The digits `1` to `4` choose a tab
while the rail has the keyboard. The strip under the input stays visible off
Strands, so with two or more agents `down` from the composer enters the strip,
and a digit pressed there chooses a tab (`update_strip_key`), landing on
Trace or Session with the keyboard on the tab (`keep_tab_keyboard`); with one
agent `down` gives the tab the keyboard directly (`View.rail_focus`). On a tab
with the keyboard the digits choose a tab, `up`/`down` and `pageup`/`pagedown`
scroll it (`View.rail_scroll`, cut to `rail_tabs.scroll_limit`), `Esc` hands
the keyboard back, and any other key is the composer's and takes it back. At
the composer the digits are ordinary characters. `/diff` opens Changes and
`/trace` opens Trace, on the docked rail or below 120 columns on the sheet
(`submit.select_rail_tab` docks it where it can; it records a rail choice only when the
choice is what docked it, not on a rail docked by default). Session is reached
by its digit: `/summary` is the full-screen summary at every width, which has
the completion evidence the tab does not carry. Choosing Session asks for a
fresh read of the live jobs. A code-mode program's end is worded as the
transcript words it (`transcript_lines.status_title`), not as the raw status.

Below 120 columns the rail's tabs are the sheet (`View.sheet`, `SheetClosed`
or `SheetOpen`; `layout.sheet_shown`). It is drawn by `rail_view` into the
conversation's rectangle, which it replaces, with no separator
(`layout.rail_lead` is 0 there and 1 when docked). It is shown when it was
opened or when the changes are open, since the Changes tab lives there too.
`layout.rail_present` is the question "is the rail on screen in either form"
that key routing and tab content ask; `rail_columns` stays the geometry of the
docked column. `layout.diff_covers_transcript` is true for the Changes tab in the sheet,
which is when the transcript has nothing to scroll, select or catch up to;
there is no separate main-surface diff, because where the rail cannot dock the
sheet is the rail. `Shift+Tab`, `/trace` and `/diff`
open it (`submit.open_sheet`, `select_rail_tab`), `Esc`, `Shift+Tab` or
leaving the Strands list closes it (`submit.close_sheet`), and choosing an
agent closes it after the switch. Opening it records no rail choice
(`View.rail` is untouched) and the launch never opens it. A resize to 120
columns or wider closes an open sheet (`submit.hand_off_sheet`, in the Resized
step, through `close_sheet`, so the strip cursor and the rail focus are reset
too), keeping `View.rail_tab`, and says `sheet closed · Shift+Tab docks the rail
on <Tab>`; narrowing never opens one. While a sheet is on screen `Esc` closes it
and the changes with it and never interrupts the strand
(`update_main_key_without_palette`), a digit chooses a tab while the rail holds
the keyboard including on Changes (`chosen_tab`), and the wheel and page keys
scroll the Trace and Session tabs rather than the hidden transcript
(`sheet_text_tab`). The Changes panel is inset one cell on each side
(`layout.changes_panel_area`), as the Trace and Session rows are, and the hint
row says "closes" for the sheet where the docked rail's says "hides".

Trace and Session are text, in `tui/rail_tabs`. Trace is
`session_view/trace_view.newest` of the strand on screen, the same module the
web view's Trace pane folds: the newest code-mode program by entry sequence,
running until its result arrives, then how it ended
(`trace_view.state_title`) with the result's excerpt and its calls under
`CALLS · …` as the transcript's failure block groups them
(`transcript_lines.call_section`, carried on `Program.calls`). It draws the
program's opening twelve lines numbered and no timing, because per-call timing
is its own piece of work. Session is the goal row, `session_summary`'s jobs and
viewers, and the cost, the web view's Session tab's rows.

`tui/rail_view` paints it: a separator, a tab bar (`Strands ●n  Changes`, the
count being agents that need the operator) and its rule, the tab's content, and
one row of key hints. Strands draws every agent in the workspace's attention
order, the advisor and the settled ones included, through `agent_row.rows`
with the strip's `StripRow` shape, so there is no second row renderer and a
long name is cut in the middle, keeping the suffix that tells twin sub-agents
apart (the `TableRow` shape's 8-cell name column would cut it at its tail). The rail's rows are `layout.strip_lines` while it lists Strands, and
the strip under the input is hidden then (`strip_height` is zero), so the
strip's one cursor and its keys (`down` from the composer, `up`/`down`,
`Enter`, `Esc`) move through the rail: `layout.strands_listed` is what
`down_from_composer` and the strip's key handler ask. The Changes tab is the
changes panel, painted by `render` into `layout.changes_panel_area`, the rail's
content rectangle. The `PEERS` section the design draws is not built: nothing
in the terminal's model says what another session asked.

## Layout memory

The terminal remembers the person's layout choices per workspace in one file,
`<state-dir>/tui/layout.json` (`~/.loom/tui/layout.json` unless `--state-dir`
says otherwise), the way the web view remembers its layout in the browser. The
key is the lower-case SHA-256 of the workspace path in hex, the same
construction as the daemon's web digest but over the terminal's own discovered
workspace root made absolute, so the two stores do not share keys, and a path
never reaches the file. The file holds
`{"version":1,"workspaces":[{"key":"<digest>","rail":"shown","tab":"trace"}]}`, most
recently changed first, at most 64 entries. `rail` is `shown` or `hidden` and
is absent for a workspace whose rail was never toggled, so a remembered choice
is told from the default. Nothing from a session is stored: not the
transcript, the focused strand, the session, a path or a name. `tab` is
`strands`, `trace` or `session` and is absent the same way. A later slice adds
the todo line as a further optional word, which an older terminal ignores.

`layout_memory` is the file over plain values and `layout_save` is the join to
the model. `layout_save.remember_launch` runs once in `interactive`, for a
local launch (its `--state-dir`) or a remote one (the default root), and
applies the workspace's rail choice; a replay, the demo and every printing
subcommand call nothing, so their models have no `View.layout_target` and
neither read nor write. `layout_save.settle` runs at the end of each step and
queues `effect.SaveLayout` only when the layout differs from the last one
saved, so a tick, a keystroke or a scroll writes nothing and a toggle writes
once. The runtime performs it with `layout_memory.save` and drops a failure,
since the alternate screen has nowhere to show it.

Reading is total (`layout_memory.load`). A file that is missing, a link, a
directory, owned by another user, readable by group or world, over 64 KiB, not
JSON, not an object, or of another `version` is the empty memory and every
workspace gets the default. Within a readable file an entry whose key is not a
digest is dropped, a repeated key keeps its first, an unknown word is that
field's default, and the list is cut at 64. The next change rewrites the whole
file, which repairs a corrupt one and replaces another version's.

Writing is read-modify-write. `layout_memory.save` reads the file again,
puts this workspace's entry first, and replaces the file with
`atomic_write_private` (mode 0600, in a 0700 directory made with
`ensure_private_directory`), so a reader sees the whole old file or the whole
new one. Two terminals on different workspaces therefore keep each other's
entries, because each writes only its own into whatever the file holds now.
Two terminals on the same workspace share one entry and the later change wins;
neither sees the other's change until it next launches. There is no lock: a
write that lands between another terminal's read and its rename can cost that
terminal's entry for a different workspace, and a layout preference is not
worth more than that. It needs no new FFI: the file helpers are the launcher's
own (`host/bootstrap`) and the JSON is `core/json`'s total parser.

## Drawn images

On a terminal that can draw them, an image's placeholder row grows into a
labelled box and the terminal draws the picture into it. The placeholder row
is still the answer everywhere else (scrollback, `loom replay`, a terminal
that did not answer the probe, a Herdr pane, a plain palette).

**The probe.** `interactive` calls `image_support.probe_terminal(palette,
getenv)` once, in the process that runs the loop and immediately before
`app.run_buffered_cursor_adaptive`, so nothing printed earlier can be taken
for a reply and the raw mode `probe.run` leaves on is the one the backend
inherits. `image_support.detect` applies Loom's plain-palette rule first (a
plain palette is never probed), then etui's `graphics.decide` (Herdr and
`NO_COLOR` skip the probe), then runs `probe.run(200)` and maps the answer
with `from_capabilities`: `KittyPlaceholders(cell)` for kitty and Ghostty,
`Iterm2Inline(cell)` for iTerm2, `TextOnly(why)` otherwise, with the cell
size guessed at 8 by 16 pixels if the terminal did not give one. A probe that
times out is `TextOnly(NotAnswered)`. The answer lives in
`View.image_support` for the whole process, and `new_model` starts it at
`TextOnly(NotProbed)`, which is what every replay and test sees.

**The box.** `session_view/image_header.picture` gives an `ImageRow` its
`Picture` (fingerprint, media type, pixel size, byte count), so a `Line`, a
cache key, never holds the data. `image_box.verdict` decides what an image
row becomes: a `Drawing` (id and box), `Keep` (the placeholder row stands) or
`Refuse(note)`. The note appears under the placeholder row for two reasons
only: kitty and Ghostty carry a PNG as it is and cannot carry a JPEG or GIF
(`this terminal draws PNG images only`), and an image over
`image_box.max_bytes`, 4 MiB decoded, is never sent (`too large to draw in
the terminal (limit 4.0 MB)`). The box is `graphics.fit` of the header's
size into the cell size, at most 60 columns and at most the pane's width less
the indent and frame, and at most `image_box.picture_rows(height)` rows: about
half the transcript the terminal leaves, between 3 and 12, so a short terminal
keeps the text around the image. The number comes from the terminal's own
height (`model.view.height`), which moves only on a resize, never from the
transcript's height, which moves as the composer wraps; the record cache and
`image_shown`'s fits are keyed on it (`projection.same_image_height`), so
typing never rebuilds them. The frame is as wide as
the picture or the label needs, and the picture is centred in it. Two images
in a row get one blank row between them (`projection.noted_images`). `projection.line_rows_for` builds the rows
(`image_box.rows`: a top border that carries the image's words, one row per
box row, a foot that carries `o opens externally`), and the anchors and the
row cache use the same function, so rows and anchors agree. On kitty and
Ghostty each cell is a Unicode placeholder (U+10EEEE and three combining
marks) in a true-colour foreground that is the low 24 bits of the image id,
which is ordinary text that scrolls and clips with the rows. On iTerm2 each
cell is a no-break space in that colour, and the picture is drawn over it.
The id is `image_box.id_of` the fingerprint, a stateless 24-bit hash,
because a row is built before anything is sent and must already carry its
colour; two images in one transcript collide with probability about
n squared over 2 to the 25th, and the later one sent would show in both
boxes.

**Not recoloured.** `appearance.apply` leaves any cell whose symbol begins
with the placeholder character exactly as it is, on every palette: the
colour is the address, and a remap to a theme colour would show another image
or none. The test is a prefix test on the cell's symbol, made only on the
palettes that remap.

**What the terminal is told.** `image_plan.settle` runs at the end of each
step, after `refresh_frame_cache`. On a `TextOnly` terminal it returns at
once. Otherwise it reads `render.transcript_window` (the rows the frame is
about to show, through the same `window` function `render_rows` uses) with
`image_box.found`, which reads boxes back out of the rows by their marked
cells and says whether each is whole or clipped by the window. It finds each
image's data again from the strand's entries by hashing each entry's
fingerprint to its id (`find`); that scan runs only the first time an image
is fitted, uploaded or drawn, and `image_shown.Shown.fits` remembers the
fit. `image_shown.reconcile` is pure: given what the terminal was last told
and what the next frame shows, it answers with commands. They leave as
`effect.DrawImages`, which `runtime.perform_io` writes with `io.print`,
the way the OSC 52 clipboard sequence is written, so they land between
frames in the order decided.

- Nothing is decided before the alternate screen is open. `Shown.screen`
  is `BeforeScreen` until the first `msg.Resized`, which the backend sends
  only after it has entered the alternate screen, and kitty and Ghostty keep
  each screen's images apart.
- kitty and Ghostty: an image entering view is `Upload` (transmit, then
  its virtual placement), one whose box changed size is `Place` again, and
  one that left view is `Remove`. The upload checks the PNG signature first.
  The order against the frame does not matter, since the cells are text.
- iTerm2: the picture is not text and anything the frame writes over a
  drawn cell erases it, so it is only drawn after the frame that laid its
  box out. A box seen for the first time is only owed (`Shown.owed`) and the
  step queues `WakeLoop`, so the next step runs after that frame is drawn
  and not at the next tick; that step draws it if it is still wanted. A box
  that moved or left view is erased at once (`Erase`). A resize repaints
  every cell, so `image_plan.resized` forgets what was drawn and owed
  without erasing it, and the pictures are drawn again after the next frame.
  Only a whole box is drawn: one clipped by the window's edge, or whose cells
  are not intact on the cached frame (`image_plan.showing`, which is how a
  surface drawn over the transcript is noticed), is not.
- A marked span is a box only if the whole span is made of the placeholder
  character or of no-break spaces. Text that merely starts with one, such as
  a pasted line indented with no-break spaces, is not a box. An image that
  cannot be found when it is fitted is dropped without a notice: a row the
  projection built carries an image it read from the transcript, so a miss
  means the cells were never a box.
- The step that sets `quit` deletes every uploaded kitty image
  (`image_shown.release`), while the alternate screen is still open.
- An image whose data is missing, is not valid base64, or is not a PNG
  where kitty needs one is put in `Shown.failed` and never tried again. The
  step sets the notice `could not draw an image: ...` once, and the box
  stays as an empty frame.

The terminal's own memory is bounded by the viewport, because an image is
held only while its box is in view and each is at most `max_bytes`. When the
alternate screen is left the terminal drops the screen's images with it.

`tui/demo_image` seeds the `--demo` launch with a prompt, an `fs_read` call
and a result carrying a real 480 by 280 PNG, so `bin/loom --demo` in a
terminal that draws shows the box end to end.

`image_draw_test` covers the probed-yes and probed-no frames, the recolour
exemption, the effect order, and the error paths. `LOOM_IMAGE_ANSI=<path>`
makes `the_inline_frame_can_be_written_for_a_terminal_test` write the raw
bytes of one inline frame (the image uploaded, then the frame with its
placeholder cells) to `<path>`, for `cat` in Ghostty or kitty. `string.contains`
cannot find a placeholder in a row, because it matches whole graphemes and a
placeholder is the base of one; the tests count codepoints.

An operator's turn is one band, `› text`, wrapped under its own first word,
with no title row. An answer opens with a heading naming the strand,
`◆ main`, and its body sits under it at the gutter with no band; the
heading is why `render.render_line` and `render.finish_markdown_rows` take
the strand.

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

## Access overlay

`/access` opens `AccessManager(access_overlay.State)`, the owner's view of who
can reach the daemon (protocol-change/053, phase 3). `tui/access_overlay` is
pure: `update(key, state)` returns an `Action` carrying the next state
(`Continue`, `Close`, `ReadPrincipals`, `ReadMemberships`, `Apply`), and
`session_control.update_access_overlay` turns a read into `job.ReadAccess` and
a change into `job.ChangeAccess` over the borrowed control connection. The
replies come back as `AccessListed`, `MembershipsListed` and `AccessChanged`
and are filed by `listed`, `memberships_listed` and `changed`; a refusal goes
through `failed`, which turns `forbidden` into one line saying the overlay is
for the owner. The daemon decides who the owner is; the terminal does not read
the hello's principal for it.

Rows are decoded only after `host/access.principal_lines` or
`membership_lines`, the checks `loom access list` and `show` print through, so
a credential is a 16-character fingerprint and nothing longer. The overlay sets
a member's role in one session (`o`, `b`), revokes a membership (`d`) and
revokes a member's credentials (`c`), each after a y/N review in which only a
lowercase `y` sends. While a change is outstanding (`State.sending`) no other
can be proposed, and its acknowledgement is checked against the reviewed
change. It never grants: `i` and `t` show the `loom access invite` and `rotate`
lines from `host/access` and send nothing, because `--record` writes every key
and socket message and a claim must not pass through the terminal. The overlay
takes no text, a paste is ignored, and the owner's own credential is never
offered for revocation or rotation. `tui/daemon/protocol` carries the five
commands (`ListPrincipals`, `PrincipalMemberships`, `SetMemberRole`,
`RevokeMembership`, `RevokeCredentials`); the reads add no epoch and the three
changes add the hello's. The page refuses `/access` with every surface
command, since `Surface(Access)` never reaches `page_command`'s `Ok`.

## Session watcher consent

The approval panel uses `session_view/approval.remembered_authority` to explain
that a wall-zero session decision covers the exact action on its requesting
strand. The shared projection enables the session choice only for eligible
grants. The panel does not broaden a request or parse shell commands.
