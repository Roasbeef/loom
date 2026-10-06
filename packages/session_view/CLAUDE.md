# session_view

## Operator diagnostic metadata

Protocol 055 adds optional `tool_availability.extension_refusals` to credited
snapshot metadata. `snapshot_view.ToolAvailability` retains at most 32
strings of at most 2048 UTF-8 bytes each. An omitted field decodes to an
empty list for old-daemon compatibility; wrong types, excess count or excess
bytes refuse the entire capture before a host adopts it. The strings are
server-owned startup observations, with no mutation or execution authority.


## Purpose

The part of a Loom client that no host owns: the session lane that speaks
the v2 conversation protocol, the decoders for what the daemon sends, the
projection of a completed capture into a view, and the line builders that
turn that view into transcript lines. It was extracted from `packages/tui`
in phase 4 of issue #530 (ADR-013) so that a second host, the daemon's
web view, can drive the same code the terminal does instead of a
copy of it.

"No host owns it" is literal. The package imports `core`, `machine` and
the standard library and nothing else, and lint R6 holds it there
(`packages/lint/src/lint/portable.gleam` says why it is on the list). A
socket, a recording file, a terminal, a clock and a mailbox all belong to
the host. Where the lane has to name one of them, it takes it as a type
parameter: `session_channel.Channel(socket, recorder)` carries the host's
handles to the outputs that act on them and never uses them itself.

The package holds no process and performs no effect. A host drains its own
inbox, hands each `connection_event.Message` to the lane with the time it
read, takes the lane's outputs and performs them.

Since S4 of `docs/design-notes/step-extraction.md` it also holds the shared
step: the session state every host of a session keeps (`model.Shared`), and
the reducers that take and return it alone, which the S3 slices cut out of
the terminal's step. The terminal runs them over its own binding of the
record's handles and applies what each call records for its surfaces; the
web view runs them through `step.update`, one call per message, and drops
the facts it has no surface for. The terminal keeps its own loop: which
event it is, which command a key means, when to drain the inbox, and the
loop over a drain's updates, one update per call (question 11 of the note).
The web view has no such loop of its own, since `step.update` is that loop
for a host with no surfaces.

## Key Types

- `strand_card.status_line(line)`, `status_title(line)`, `glyph(status)`,
  `model_name(model)`, `task_words(title)` (a task, or nothing for the
  roster's placeholders and the advisor's feed prompt; a brief is cut to its
  first sentence and `task_limit` characters), `needing(lines)` and `context_words(tokens)`: the one
  status line under a strand's name on its card (`Needs approval` for a
  strand that waits on a decision, whatever the request was; the state word
  and what the strand is doing after ` · ` for a working one, where the
  engine's phase `assistant` reads `thinking`, a tool is named without its
  command and a state word the activity already says is not said twice;
  `Finished` and how long it ran), the whole activity text for a tooltip
  (`status_title`, cut to `title_limit`), the state's one-character glyph,
  a model's last path segment, how many strands wait on a decision (the count
  on the web view's Strands tab), and the words for a strand's context size
  in its own view. Both hosts can read them so the terminal can word a card
  the same way.
- `command.Command`: a parsed draft, `Surface(command.Surface)` for a
  command the host carries out with its own machinery (a panel, the model
  selector, daemon control, a change of strand, the host's exit) or
  `Session(command.Session)` for one the session carries out (a prompt, a
  steer or a follow-up, the goal, schedule, approval and configuration
  commands, `/clear`, and the parse errors). A host routes on the outer
  variant, and the shared dispatch (`commands.submit`) is exhaustive over
  `Session`.
- `session_channel.Channel(socket, recorder)` (opaque): one credited
  conversation lane. `start`, `start_recorded`, `start_resumed` and
  `replay` create one; `receive(channel, message, now:)`,
  `tick(channel, now:)`, `submit`, `close` and `retire` transition it and
  return `Update`s; `take_outputs` hands over the queued `Out`s oldest
  first. `socket` returns the host's handle for liveness checks.
  `next_due` names the earliest reading at which `tick` would act (the
  in-flight deadline, or the idle refresh of a ready lane with a cut), and
  both hosts arm one wake-up for it instead of ticking on a cadence. The
  idle refresh is `polling_refresh_ms` (250) until the lane receives its
  first pushed frame and `pushing_refresh_ms` (5000) after, and the daemon
  pushes the roster at subscribe (protocol-change/054); the private
  `Delivery` field (`Polling`, `Pushing`) records which.
- `session_channel.Out(socket, recorder)`: `Transmit(socket, frame)`,
  `Shut(socket)`, `Note(recorder, attempt.Event)`. The terminal performs
  these in `tui/terminal_lane.perform`.
- `session_channel.Update`: what a transition tells the host. `Captured(cut,
  view, trigger)` is the only update that replaces the visible projection;
  the others are submissions, history pages, lookups, refusals, pushed
  stream fragments and tool tails, commit notices, acknowledgements, lost
  replies and failure.
- `inbox.Inbox(source, a)` (opaque): what a host received from one
  source and has not reduced, oldest first, with the host's name for the
  source. `push` files behind the held messages and `take` returns the
  oldest; reading a mailbox stays with the host (`tui/buffered` over an
  Erlang subject). An adoption replaces the whole value, so a replaced
  source's held messages cannot reach a reducer.
- `connection_event.Message`: `Connected`, `Incoming(text)`,
  `Closed(reason)`, `NetworkFault(reason)`. The host's transport maps its
  own events into these.
- `attempt.Event`, `attempt.Request`, `attempt.Id` and
  `attempt.Trace(recorder)`: the recording vocabulary of one attachment
  attempt, and the recorder and identity a lane records under.
- `snapshot.Captured`, `snapshot.Window`, `snapshot.Item`,
  `snapshot.Attachment`, `snapshot.Expected`: one validated cut and the
  bounded window of records it holds. `snapshot.Transfer` (opaque) is a
  cut still being received.
- `snapshot_view.View`: the presentation decoded from a cut's metadata
  (`snapshot_view.decode`), and `snapshot_view.Branch`, one strand's
  records.
- `history_view.State`: the bounded, pageable window of a strand's
  ancestry; `capture` folds a cut in and `branch` gives its records.
  `older`, `range`, `sent`, `accept`, `cancel`, `freeze` and `resume` page
  it through the lane's `history` read, for the terminal and the web view
  alike. `retain_from(state, seq)` drops the records older than `seq` from
  a live window with no read owed, for a host that draws only the newest
  rows (the web view). A `capture` into a window that joins it keeps the
  lower `before_seq` an earlier `accept` reached, so a read that found none
  of the strand's records is not asked again. The state also holds a `Scan`
  (`Unscanned | Scanning | Abandoned`), a transient read of one stretch of the
  strand's ancestry beside the window, for a host that draws summaries and
  looks at records without keeping them (protocol-change/071). `scan(state,
  leaf, before_seq, known, view)` starts it at the record `leaf`, seeded with
  the part of `known` and the window that is the leaf's ancestry below
  `before_seq`; `scanned` gives what it holds as a `Branch`, `scan_older` asks
  for the interval below it (a read the host's step sends through the same
  `range`/`sent`/`accept` as the window's, the window's demand served first, a
  reply going to whichever asked for it), `scan_readable(state, missing)` says
  whether it can go on (a sequence is left, it has neither reached its
  bound nor been cut, and the parent it is missing, `missing`, is not a record
  over the presentation limit that it already holds as a descriptor: no read
  below such a record proves it), and `scan_end` drops it. It is bounded at 4,096 records
  and 32 MiB, private to the module, and a page that would take it past the
  bound is cut at the oldest end, so it still ends at its leaf, and the scan is
  unreadable afterwards. A `cancel` abandons it. The window is the same value after a scan as before it.
- `protocol.Event`, `protocol.EntryRecord` and the board types, and
  `session_wire.Reply`: total decoders for the daemon's frames.
- `transcript_line.Line(speaker, text)` and `Speaker`, with the live
  observations that become lines: `Stream`, `ToolTail`, `CacheNotice`,
  `Submission`. Agent traffic has three speakers, `SentMessage`,
  `StrandMessage` and `PeerMessage`, chosen from the `agent_send` call or
  the stored origin and never from the text; the text is a heading, a
  newline and the body. A peer heading ends in
  `transcript_lines.origin_checked`, and every heading in the local clock
  time when `Presentation.clock` (from `Shared.clock_offset`) knows the
  zone. `agent_messages.Item.ts` keeps the send's time for the workspace.
- `transcript_lines.joined` joins every tool result in a compact window to
  its call, for responses whose calls are drawn as narrative: the call is
  drawn with the rows a tool group draws for it (`call_rows`), settled,
  failed with its reason, a send with its admission, a program with its
  value, an image result with its image's row, `absorbed` says which result entries draw nothing,
  `reads_joined` names the responses that bypass the entry cache, and
  `joined_entry_lines`/`joined_block_lines` draw a response with the
  results joined. A compact `code_mode` call is a
  `ProgramRunning`, `ProgramSettled` or `ProgramFailure` block, whose text
  is a title, a foot and a body: the program's opening lines under their
  numbers (`program_body`, shared by running and settled), or the error,
  with a compiler diagnostic cut to its heading (`· line N`) and the
  source it quotes. A settled block's title counts the calls
  (`✓ code_mode · completed · 5 calls`), its foot says how long the program
  ran, and it ends in the `CALLS · …` section a failure shows and a
  `RESULT · …` preview from `value_preview`: an object's first three keys
  with a type or size hint, a list's length and first element, a scalar as
  it is. A result with no record has no calls section or foot, and one with
  no `details` keeps the generic rows. All three block speakers open and
  close bare, like a call.
- `call_tree.{read, summary, CallLog, Call, Status}` (protocol 060): the
  total decoder for the `calls` key of a `code_mode` result's `details` and
  the one-line summary (`7 calls · 1 failed`). An absent key and a
  malformed one both read as `None`, and `transcript_lines` then renders the
  result exactly as it did before the record existed. A `code_mode` failure
  with a readable record shows the summary and rows under the failure text.
  The golden JSON in `call_tree_test` is the same literal `tools` asserts
  its encoder writes.
- `ImageRow` is an image's placeholder row under the call or turn that
  carries it, worded by `image_header.describe` (`image 1 · image/png ·
  1200×700 · 84 KB`); `image_header.dimensions` reads the pixel size from a
  PNG, JPEG or GIF header totally, and answers `None` for anything else.
  `ImageRow` carries `image_header.picture`, which is `None` when the header
  cannot be read: a fingerprint (byte count and three 32-byte samples of the
  base64 text, cheap on a large image), the media type, the pixel size and
  the byte count. A line is a cache key, so it never holds the data; a host
  that draws the image finds the data again from its entry by fingerprint.
- `transcript_lines.Presentation`: everything the line builders read of a
  client's state. A host fills it; the terminal does so in
  `tui_model.presentation`.
- `transcript_lines.assistant_terminal_lines` draws an aborted response as
  `Stopped`, with its diagnostic beneath it as dim detail unless it says only
  that the provider's request was cancelled, which is what a Stop or a steer
  does and which the records do not tell apart (F153, protocol-change/071).
- `transcript_lines.collapse_repeats` folds a run of identical consecutive
  items into the newest of them with `×N` on its first row, in compact
  history only. Two predicates say what may fold: `repeated_call` (a call
  that settled successfully on one row, such as an `agent_wait` poll) inside
  a tool group, and `repeated_failure` (an entry that draws only a provider
  error) between items. The terminal's anchor fold in `tui/projection`
  applies the same fold over the same items, so rows and anchors stay
  paired; a folded run anchors to its newest call. A failure row opens bare,
  so it gets a gap under a call's bare last row.
- `transcript_lines.response_awaited(records, operations, stream)` says
  whether a live response is still owed to a host that draws only captures:
  its request's identity names an entry that `records` do not hold and the
  capture still shows its operation running. The web view keeps drawing the
  stream it last saw while this holds (`web_view/component.streamed`), since
  a pushed entry clears the record's streams before the capture that holds
  the row. `transcript_lines.line_count(text)` is the `2 lines` a live
  reasoning row says, for a host that draws the elapsed time itself.
- `transcript.project(cut, view, strand)`: one strand's lines from one
  capture, for a host that keeps no presentation state between cuts.
  `transcript.project_rows` gives the same lines as `Row(key, line)`, each
  keyed by the durable sequence it was drawn from
  (`transcript_lines.keyed_record_lines`), so a view that keys its list
  drops the rows a moving window loses instead of rewriting the rest.
  `transcript.branch_blocks(branch, cut, view, strand, notices)` draws the
  same blocks from a branch a host keeps across captures, and
  `transcript_lines.block_seq(block)` reads a block's sequence back from
  its key.
- `operator`: what an operator's input becomes on the wire, shared by the
  terminal and the web view. `submit(lane, id, strand, text, Delivery,
  now)` sends a `Prompt` or a `Steer`; `decision` and `decide` encode an
  answer (`Choice`: `AllowOnce`, `AllowForSession`, `Deny`) that echoes
  the drawn escalation exactly; `drawn` finds a pending record only by its
  identity and the sequence it was drawn at; `drain(state, budget, take,
  handle)` is the bounded, oldest-first loop both hosts feed the lane
  with.
- `text_hygiene.multiline` and `single_line`: the terminal-safety pass
  every untrusted string goes through. `unchanged_prefix` is how many
  leading bytes the pass leaves as they are, with the guarantee that the
  pass over the whole is that prefix followed by the pass over the rest;
  the terminal's live tail uses it to sanitize a growing answer once
  rather than on every frame.
- `code_tokens.line(language, text) -> List(CodePart)`: the token classes of
  one line of a code fence (`CodeKeyword`, `CodeType`, `CodeString`,
  `CodeNumber`, `CodeComment`, `CodePunctuation`, and a diff's `CodeAdded`,
  `CodeRemoved`, `CodeDiffMeta`). A `gleam` tag is scanned, a `diff` tag
  classifies the whole line, any other tag is one plain run. Total, per line
  (no state across a line break), and the tokens joined are the line
  unchanged. The terminal maps each kind to a style in `tui/markdown`, the
  web view to a `tok-` class in `web_view/code_view`; it holds no
  `@external`, so R6 stays clean.
- `markdown.parse(text) -> List(Block)`: an answer's Markdown as a closed
  tree (`Block`, `Inline`, `Cell`, `Level`, `Align`, `AlertKind`,
  `TaskState`) whose every string is text to show. Both hosts draw it: the
  terminal's `tui/markdown` as etui spans and the web view's
  `markdown_view` as elements. HTML in the source is text and a link keeps
  its destination as a string. Besides CommonMark's core it recognises
  GitHub alerts, task boxes, pipe tables, footnotes, reference links and
  bare `http`/`https`/`www.` links; emoji shortcodes, entities and inline
  footnotes stay text. It is Loom's own parser because mork, which the
  terminal used before, backtracks exponentially on a run of `[`. This one
  is linear in the input and caps nesting at `max_depth` containers and
  `max_emphasis` open delimiters. Reference and footnote definitions are
  collected in a first pass over the lines, into a map, before any block
  is parsed.

- `turns.pieces(blocks, strands, latest)`: one strand's lane as turns for a
  host that draws more than rows (the web view): `Plain` blocks, `Prompt` for a
  person's message (the sender is a field, not a `name:` line of the text;
  `turns.authors` reads each principal's role from the presence rows and
  `turns.attributed` sets it on that principal's messages, never the reader's), one
  `Work` divider per turn (`Folded`, or `Open` while the strand runs or waits
  on an approval; a host that lets the reader open a fold sets `Unfolded(hidden)`
  through `fold_budget.draw`, and `Work.id` is the sequence of the first record
  the work folds, the number the host names the fold by; its `Worked` figures come from the records, failed calls included, which
  `turns.divider` prints as `· 1 failed`, and `Worked.ending` is `Interrupted` when a response of the turn was aborted (its row leads with `transcript_lines.stopped_words`) or when a command it ran says the broker stopped it on request (`cancelled` without `timed_out` in a tool result's details, which `bash` records), which the divider prints as `· interrupted`; a result whose call lies outside the
  window counts as one step, so a turn cut inside a long run of calls shows a
  figure that grows as older rows load). A fold's steps read by `turn_ledger.steps`
  never hold a result without its call: a read that stopped between a batch's
  calls and its results leaves those results out, and the count of steps not shown
  is the divider's less the steps drawn. A stop's diagnostic is worded for the
  reader (`transcript_lines.assistant_terminal_lines`): nothing beneath `Stopped`
  for a stop the provider confirmed, one plain sentence for a stop it could not
  confirm, and never the harness's note of where it observed the stop. A response that failed says why on a
  `Plain` row beside the divider, never inside the fold. The fold's
  items are `Narrated` blocks (each with `took`, the response's time, which a
  reasoning row reads), `Step`s (`words` from `step_words.of_call`) and
  `Memory`, the memory context the daemon recorded ahead of a prompt: it is no
  input, `split` and `grouped` hold it for the next input, and it is the first
  item of that turn's fold. `Spawned` and
  `Returned` rows for sub-agents, `Nudged` for a delivered advisor frame,
  `Peer` for another session's message, `Sibling` for a message a strand of
  the same session sent (stored origin `StrandOrigin`, framing removed by
  `strand_framing.strip`, a brief's result-contract trailer kept apart),
  `Missed` for a cache notice and `Commentary` for the advisor's board (reviews that
  stand next to each other are one piece with a `reviews` count). A feed or goal
  feed sent to the advisor is an input, since the advisor's strand has no other:
  with none its whole history would be one turn with no start, and a host that
  completes a turn by reading back to its input would read all of it. It reads
  `transcript_lines.keyed_record_blocks` (`transcript.blocks`), which tags
  each block with its `Source`. `turns.grouped(blocks, strands)` splits
  the same blocks at their inputs, the lead before the first input and
  then each turn, so a host that holds only the newest turns cuts between
  them. `turns.hue` is a strand's colour from its position, never its
  name. `turns.pieces` takes an `Expansion`: `Skip`, or `Expand(cap)`, where
  the host's `cap` cuts what a reader who expands a row sees, the rows the
  terminal's `Ctrl+g` draws (`transcript_lines.expanded_call_lines`, and
  `assistant_block_lines` at expanded extent for a reasoning row). A `Step`
  carries the cut rows as `full`, and a `Plain` or `Narrated` piece carries
  `thoughts` by row key; both are empty when the expansion equals the compact
  rows, so no piece holds uncapped text. `grouped` skips them. The terminal
  does not call `turns`.
- `step_words`: how one step of a turn reads, shared by every host that
  draws a step. `of_call(call)` turns a tool's name, arguments and (for an
  edit) its diff into `Words(verb, subject, change)`: `Read calc.py`,
  `Edit calc.py +3 −1`, `Ran python3 -m unittest`, `Spawned scan`. A subject
  is tagged `Mono` (a path or command), `Prose` (a name or purpose), `Figure`
  (a count or a time) or `Unnamed`, which only says which face a host uses;
  every subject is session text and is drawn as a text node. A tool the table
  does not list keeps its own name. `failure_sentence(words, engine)` is the
  one plain sentence a failed step opens on (`The edit was rejected: "from" is
  required for this hunk op.`) and `spoken_breaks(report)` reads the two
  characters `\n` of a double-escaped report as line breaks. `memory`, `reasoning`, `worked`,
  `returned` and `duration` word the rows that are not tool calls, `text`
  flattens any `Words` to one line, and `first_call(program)` names the first
  capability a `code_mode` program calls (`fs.read calc.py`) by reading its
  text. That reader stands in for the trace view's fold of a program's calls.
- `diff_view`: a unified diff read into lines a host can colour. `parse(diff)`
  splits on newlines (a CRLF's `\r` is dropped), keeps at most `max_lines`
  (400) and returns `Diff(lines, cut)`; `of_lines` reads lines a host already
  bounded. Each `Line(kind, old, new, text)` has a closed `Kind` (`FileHeader`
  before the first hunk only, `Hunk`, `Added`, `Removed`, `Context`,
  `NoNewline`) and, inside a hunk, the line numbers the header's counters give.
  An added, removed or context line's text has its marker removed. The text is
  session text; the web view draws it as a text node.
- `transcript_image`: the images a lane row carries, which the rows draw as
  `[image <type>]` text. `Image(mime_type, data)` holds the entry's own base64
  text (nothing is copied). `of_entry`, `of_message`, `of_outcome` and
  `of_block` read a user message's `UserImage` blocks or a tool result's
  `ToolResultImage` blocks, and `ref(key)` names a row as one path segment (a
  step key's `/` becomes `-`). `turns.Step` carries `images`, `turns.pictured`
  lists the rows that carry any by name and `turns.picture(pieces, ref,
  position)` finds one, so a host that serves an image serves only one the lane
  draws. `pasted_image.media_type` (PNG, JPEG, GIF or WebP by magic number, the
  terminal's own sniff, which `tui/image_drop` delegates to) and
  `pasted_image.is_raster` are the allowlist both hosts share.
- `agent_view.Row`, `agent_activity` and `reviewer_status`: each strand's
  status, task, activity and approvals from one capture, shared by the
  terminal's agent rail and strip and the web view's chips.
  `agent_roster.{Roster, Line, Chips}` is which strands a strip lists, in
  what order, with elapsed time and context size (`lines`, `chips`,
  `running_ms`, `context`). A strand that is idle and has no operation has
  never run (a fresh fork waiting for its first prompt), and it is listed
  among the live cards rather than settled; one that ran and is idle again
  has an operation and is settled. `describe` gives any row the same line
  whether or not a strip would list it; the terminal's workspace list uses it.
  Its internal `listed_count` uses the same membership predicate without
  constructing display lines, for hosts measuring geometry. The roster test
  compares that count with `lines` across every status and active-strand choice.
- `notice_words` (`sent`, `outcome`, `done`): the closed table that words a
  command's outcome for the footer, `Goal pinned`, `Denied`, `Queued for the
  next turn`, so no wire name is a notice. `reviewer_status.lines` words the
  advisor row `watching <strand>` and cuts a sub-agent's brief to its first
  sentence; `without_idle_advisor` is the page's filter.
- `decisions` (`from_ledger`, `strands`, `words`): the approval decisions the
  approval ledger holds, with the author, the verdict and the strand the
  request was raised on (from the pending cell the capture held, or the
  record's own scope when the page read `escalations_decided`, whose answer
  arrives as `LookedUp(records, [])`). `turns.with_decisions` places each as a
  `turns.Decided` piece by the register sequence that committed it, which
  storage numbers from the same counter as transcript entries.
- `approval.wants(tool)`: the fixed words for what a request asks to do
  (`run a command`), shared by the cards.
- `cache_miss` (a miss reconstructed from two usage rows, and the TTL
  outlook the rows prove) and `cache_watch.Ledger` (which rows may be
  compared: `admit`, `settle`, `capture`, `observe`, `forget`, and `shown`,
  which suppresses the outlook while a strand runs): the prompt-cache rules
  both hosts draw.

`shared_set`: one setter per `Shared` field that three or more sites set. A
reducer that changes one field pipes the record through the setter instead of
writing `Shared(..shared, f: x)`: `Shared` has about ninety fields, and each
record update cost erlc roughly 10 ms (`tui/CLAUDE.md` has the measurements).

The shared step. Every function here takes and returns `model.Shared` alone
and reads no host state; a host stores each result and applies what it
recorded (the terminal through `tui_model.hold_shared`, `run_shared` and
`inbound.run_settled`).

- `model.Shared(socket, recorder, source, replay_source)`: the session
  state, what a host needs to show a session and act on it (what the daemon
  said, what was sent and not yet committed, the reads in flight, the
  presentation revisions), and four host handles typed by its parameters:
  `channel` is `Option(session_channel.Channel(socket, recorder))`,
  `replay_state` is `attempt_replay.State(socket, recorder)`, `inbox` and
  `replay_inbox` are `inbox.Inbox` values keyed by `source` and
  `replay_source`, and `recorder` is `Option(recorder)`. The inboxes have
  separate source parameters because the terminal reads them from
  differently typed subjects. The terminal binds the four in
  `tui/model.TerminalShared`. Its types are `Peer`, `Interrupt`,
  `SubmissionSource`, `UnconfirmedSubmission`, `ConnectionBacklog`,
  `GoalReport`, `ReturnedDraft`, `GoalObservation` and `SurfaceFact`.
  `Shared.outbox` holds the `step_effect.Effect` values a call decided,
  newest first, and is empty between calls. Four fields record what a call
  means for a host's editors and surfaces, so that the call need not write
  them: `drafts_sent` counts the composer drafts the lane has sent,
  `queue_notices` holds `queue_request.Notice` values (`Refused(reason)`,
  `Dropped(message)`, `Received(owner, namespace, document)`, `Saved`,
  `Unknown`), `goal_observations` holds `GoalObserved(board)` and
  `GoalUnavailable(reason)`, and `surface_facts` holds the `SurfaceFact`
  values the folds and the commands recorded (`WorkspaceSwitched`,
  `SessionSynchronized`, `ModelsListed`, `OutlookCleared`, `NotesArrived`,
  `JobsReplaced`, `LookupAnswered`, `ApprovalSettled`, `ApprovalsPresented`,
  `QueueRowsCaptured`, `HistoryReleased`, `AgentMessagesCaptured`,
  `GoalReleased`, `ConnectionLost`, `ReplayAdopted`, `InterruptRequested`,
  `ReviewAnswered`, `DraftTaken`, `TranscriptCleared`, `LookupRequested`).
  The three lists are empty between calls. `Shared.answer` is the words of
  the daemon's latest reply to a command the lane sent (an acknowledgement,
  a refusal, a lost reply), which `lane_fold.apply_channel_update` writes
  beside `notice`; `notice` is replaced by any event and `answer` only by
  another reply, and a refusal of a read the host issued itself (`session_channel.is_read`,
  `history`, `escalations_get`) is not one. The terminal reads `notice`; the web page reads `answer`.
  `build_notice` is the
  build-mismatch lines the host computed when it adopted a daemon, which a
  cut splices in; the builds themselves are the host's, because
  `host/build_identity` reads the environment. The writers are
  `append_system`, `append_error`, `append_notice`, `invalidate_transcript`,
  `invalidate_frame`, `mark_activity` (bumps `activity_revision` only),
  `hold_channel` (stores the lane, queues its outputs as `Lane(..)`),
  `record_arrival` (queues `Recorded(..)`) and `record_surface`; the
  readers are `queue_owner`, `queue_namespace`, `active_strand_live`,
  `active_strand_phase`, `active_interrupt`, `is_known_strand`,
  `strand_running` and `presentation`, which builds the
  `transcript_lines.Presentation` the line builders read.
- `step_effect.Effect(socket, recorder)`: the two effects the session
  decides, `Lane(output)`, an output of the adopted lane, and
  `Recorded(recorder, message)`, the recording line for a message that
  arrived with no lane. It is a module of its own rather than part of
  `step` because the record holds a queue of these and `step` imports the
  record.
- `msg.Stamp(now_ms, transport_ms)`: the instant an input is applied at,
  stored as `Shared.stamp`. `msg.Command` is what an operator does to a
  session from any host: `Submit(draft, command, delivery)`,
  `Control(command)` (a session command chosen by a button, which has no
  draft), `Interrupt`, `Stop(strand)`, `Decide(review, choice)`,
  `SelectModel(name)`, `Quit`.
  `msg.Msg(source)` is what a host with no surfaces hands `step.update`:
  `Arrived(List(Arrival))`, traffic to file (`Arrival` is `Frame(source,
  message)` or `Replayed(event)`), or `Input(at: Stamp, event: Event)`,
  one event to reduce (`Event` is `Ticked` or `Acted(Command)`).
- `admission.file_frame` and `file_replayed`: a frame is filed into the
  adopted inbox when its source is that inbox's and refused otherwise, and
  a replayed event is always filed. What a refused frame is, the host
  decides; the terminal offers it to its waiting attempt.
- `outbound`: `send_frame`, `send_via`, `apply_submission`,
  `discard_own_turn`, `waiting_notice`, `mutation_refusal` and
  `mutating_submission`. A sent `ComposerSubmission` empties `attachments`
  and bumps `drafts_sent`; a frame the lane did not send appends
  `queue_request.Refused(reason)`.
- `surfaces`: the `service_*` reads (todo seed, notes, queue, worktree,
  jobs, advisor nudges, block summaries, goal, context), the receivers
  (`receive_jobs`, `receive_goal`, `receive_advisor_nudges`,
  `retire_delivered_nudges` for a pushed entry,
  `retire_nudges_delivered_since_board` for a captured cut, `refuse_goal`),
  the `sync_*` edges with
  `context_refresh_due`, `advisor_nudges_action` and `goal_action`, which
  compare two records, and the goal commands `submit_goal_action` and
  `confirming`. A dropped queue read appends `queue_request.Dropped`, and a
  goal board or failed goal read appends a `GoalObservation`. The functions
  that open a surface or read its target are the host's
  (`tui/side_surfaces`).
- `event_fold.apply_event`: one pushed event (streams, tool tails, entries,
  phases, usage and the cache watch, the side-surface replies, schedules,
  skills, models, a returned draft), with the functions it reaches:
  `select_workspace` (the session half of a switch, with `leave_session`),
  `select_model`, `settle_pending_cache`, `send_prompt_to`,
  `expect_own_turn`, `settle_own_turn` and `abandon_interjections`.
- `lane_fold`: `apply_channel_update(shared, update, around)` folds one
  `session_channel.Update` (`reconcile_cut`, `render_cut`,
  `receive_history`, the approval lookup, `apply_request_refused`, the
  acknowledgements, a lost lane); `receive_unlaned` applies a channelless
  message; `apply_replay_change` applies one change of a replayed attempt
  event. `tick`, `receive` and `cancel_unsent` hold the lane and return its
  updates, and `take_replayed` returns a replay event's changes, so the host
  keeps the loop. `Surroundings(worktree, notes, reviewing, wanted)` is what
  the host shows that a decision inside an update reads; `nothing_shown()`
  is a host that shows none of it. Also `request_decisions`, `apply_cut`,
  `service_history`, `request_visible_worktree`, `refresh_worktree`,
  `approval_lines` and `retains_history`.
- `commands.act(shared, msg.Command)`: `Submit` runs `submit`, the refusal
  before encoding, the `ComposerSubmission` marker, the image prompt and
  the dispatch exhaustive over `command.Session`, then
  `release_submission`; `Control` runs `control`, the same refusal and the
  same dispatch with no marker and no `DraftTaken`, so a lane that sends
  its frame moves no `drafts_sent` and a host has no editor to empty, which
  is what a button that fires while the operator is typing needs; the others run
  `interrupt_active`, `stop_strand`,
  `decide_review`, `select_model` and `quit`. `decide` (by ID) is the
  `/approve` and `/deny` arm, and `focus` and `load_strand` are the second
  and third units of a strand switch, after the lane's `cancel_unsent`.
- `step.settle(before, after)`: the shared step's own settle after every
  event, `sync_context`, `sync_advisor_nudges` and `sync_goal` in that
  order. Beside it are a tick's two session units besides the lane's:
  `service_reads`, the eight side-surface reads in the order they share the
  lane's command slot, and `advance_activity_clocks`, which moves the
  activity and generation clocks to the stamp. The terminal imports the
  module as `session_step`.
- `step.update(shared, msg.Msg(source))`: the whole-event entry for a host
  with no surfaces of its own, which is the web view (S5, question 12 of the
  design note). `msg.Arrived([Frame(source, message) | Replayed(event)])`
  files through `admission` and reduces nothing. `msg.Input(stamp, Ticked)`
  runs the terminal's tick less its surfaces, in its order: the activity and
  roster clocks, the drain of every held frame (each lane update applied on
  its own with `nothing_shown()`), `service_reads`, and the lane's tick with
  its history read; it then settles against the record it started from and
  drops the facts such a host has no surface for (`forget_surfaces`: the
  surface facts, queue notices and goal observations; a returned prompt is
  the prompt's last copy, so it stays in `returned_drafts` for the host to
  take and empty, as the web view does for the composer's element). The
  terminal's block-summary read is left out, because the daemon may run a
  summarizer for a label. `Input(stamp, Acted(command))` runs `commands.act`
  and settles, and leaves the command's facts for the host to read
  (`DraftTaken`) before it calls `forget_surfaces`. A tick with no lane
  drains nothing. The result is the record and the effects, oldest first.
  The terminal does not call it; `step_test` holds it to the terminal's
  order. `step.new(strand, session, stamp, inbox, replay_inbox)` builds the
  record such a host starts from, with no lane and `peer: Disconnected`;
  the host adopts a lane with `hold_channel` and sets `peer` to `Attached`.
  `step.focus(shared, strand, stamp)` is the same host's change of strand:
  the terminal's `switch_active_strand` less its surfaces (`cancel_unsent`
  with each update applied, `commands.focus`, `commands.load_strand` with
  `nothing_shown()`), settled against the record it started from and with
  the surface facts dropped, returning the effects. The caller checks that
  the strand is listed and not already active.
  `Shared.ended` is why the adopted lane failed, set by the lane fold; the
  terminal never reads it and clears it when it adopts a lane. The step's
  functions are `@internal`, so they are not in `gleam export
  package-interface`; the hosts in this repository call them, and R6's check
  of the imports is what covers them.
- `queue_request.State` (the queue editor's lane correlation),
  `agent_messages` (provenance-checked inter-agent sends),
  `attempt_replay.State(socket, recorder)` (the two-slot replay of recorded
  lane updates) and `completion_summary.State` (an operation's completion
  evidence) are the pieces the record holds that came with it from the
  terminal.

- `trace_view.fold(records)` folds a strand's records, as a branch holds
  them newest first, into the session's `code_mode` programs, oldest first:
  each with a closed `State` read from the result's `status` word (`Running`
  while it has no result), a label (the `program_path`, else the text of the
  program's leading `//` comment after any imports, else `Program N`), a result
  excerpt, the `within_ms` the call named, a closed `Vetting`, `detail` (the
  result's own `detail`, the compiler's diagnostics or a run's reason, kept
  apart from the excerpt, which for a failed build is the sentence written for
  the model; the web Trace tab draws `detail` and `budget_words`, the terminal
  keeps `excerpt` and `budget_line`), and `calls`, the
  rows of the protocol-change/060 call record the result carries (`CALLS · …`
  and one row per call, from `transcript_lines.call_section`; nothing for a
  running call or a result with no readable record). `newest(records, strand)`
  is the terminal's form: one strand's newest program from a window that holds
  several strands, in entry order whatever order the records arrive in, with
  `source`, the program's opening twelve lines numbered. `state_title` words a
  state as the transcript's failure block does (`compile error`, `refused by
  vetting`), and `state_word` is the web's. `first_call` is a program's first
  call row, else its label. Bounded: `max_programs` 12 (older ones counted in
  `omitted`) and `max_characters` 160 per label and excerpt, both single-line
  and free of control characters. Both hosts draw it: the web view's Trace pane
  from `fold`, the terminal's Trace tab from `newest`. Portable, no externals.
- `changes_view.fold(records)` folds a strand's records, as a branch holds
  them newest first, into the board of the session's own edits: the files
  the successful `fs_edit` results named, each with the diff the result
  reported as rows of a closed `Kind` (`Hunk`, `Added`, `Removed`,
  `Context`) and the `+` and `-` totals, and the successful `fs_write` calls:
  a write reports no diff, so its file is one hunk whose every line is added,
  from the call's `content` argument, with `origin: Written` and the words
  `written · 23 lines` (`counts_words`) in place of counts. A file that was
  also edited is `Edited` and counts both. It reads no worktree, so it is what
  the agent wrote in the window and not the state of the tree, and it says so
  (`label`). It is bounded (`max_files` 24, `max_file_rows` 200, `max_rows`
  600, `max_row_characters` 240) and every cut is counted. The web page's
  Changes section draws it; the terminal's `/diff` still reads the worktree.

- `session_summary.jobs(board, strand)` and `session_summary.viewers(captured)`
  are the Session summary's two rows that a read or the presence roster
  supplies. Jobs are the `live_jobs` board for the strand asked about, its
  lines cut to `max_job_rows` with the rest counted, or `Unread` when there is
  no board or it names another strand (never a count of zero). Viewers are the
  cut's presence rows grouped by principal, at most `max_viewer_rows`, each
  with its role words, how many pages (attachments) it holds and whether one is
  the host's own; `total` still counts attachments. Whether a host shows the
  viewers is the host's choice: the web page shows them on an operator's page
  only.

`turn_ledger` keeps a closed turn as what a page draws of it instead of its
records (protocol-change/071). `seal_all(groups, after, records, strands)`
closes the turns a host holds whole into `Sealed`: the pieces with the fold
closed, the `fold_budget.Weight` (the fold's rows capped at `fold_rows`), the
first record's sequence and parent, the last record (`end`, an `Anchor` of
identity and sequence, which is the next turn's first record's parent, or the
newest record when no open turn follows, so `after` names the turns that stay
open) and the `changes_view`, `trace_view` and newest tool result the turn's
records carried, and `bytes`, about how many bytes of text the summary holds
(`fold_budget.sealed_bytes`, 16 MiB, is the budget a host holds closed turns to
beside its rows). A lead's divider is keyed `work:<first seq>.0`, not by the
window's start. A turn is sealed once nothing more will be added, which the
records cannot always say (an operation can lag the record that opens its turn,
and a turn can go on with no new input); records that arrive after a sealed turn
with no input of their own are read as the end of a turn whose start the host
does not hold and the whole turn is sealed again in place of the partial one
(module doc, "When a turn is sealed"). `older`, `completed` and `steps` take what a scan has read so
far and a `Source` (`Readable | Exhausted`) and say whether it is enough:
`older` for ten whole turns below the host's oldest, `completed` for the turn a
window began inside (`Whole(sealed)`, or `Partial` when the scan ended before the
turn's input, which closes nothing), `steps` for the newest `fold_rows` rows of one turn's
steps (`Steps(items, unread)`; `unread` is the cut's and, when the read stopped
before the turn's input, the divider's count less the steps shown). `lead_end`
is where the blocks before a window's first input end, which a read of the rest
of that turn starts from. `changes_view.append` and `trace_view.append` join the
boards of two stretches so a host can fold each turn once. `turns.Reading` is a
fold the reader opened whose steps are not here yet.

`fold_budget` decides how many rows a host that retains what it draws spends on
turns: `weigh` costs one turn's blocks (its closed rows, and the rows its fold
would add), `fit` takes the weights newest first with the open folds and the
limit and says how many turns fit and which open fold must draw fewer steps, and
`draw` empties a closed fold's items and cuts an open one's to the newest that
fit. It is pure and portable, and the web view's `component.held` is its one
caller (protocol-change/070); `newest` and `item_rows` are public so a host that
reads a fold's steps keeps no more than a page draws.

The remaining modules are the pieces those decode or fold through:
`approval` (exact escalation decisions), `advisor_history` and
`advisor_pending`, `block_summary` (summarizer labels), `command` and
`skills`, `composer` (the rules for showing pasted text, and the composer's
attachment list; it also recognises the memory context the daemon attaches to
a run, `memory_context_lines`, and folds it in `transcript_text` to `memory
context (n lines)` beside the `[loom]` injection collapse, and owns the
attribution lead and fence `client/memory` builds its text from), `context_view`, `file_read_view`, `goal_view`,
`live_jobs`, `notes_view`, `pasted_image`, `queued_input`,
`stream_identity`, `text_hygiene`, `todo_board` and `tool_activity`, and
`worktree_view`.

## Relationships

- **Depends on**: `core` (json, codec, entries, messages, ids, todo_list),
  `machine` (`codec`, `operation`, `strand` for decoding register cells),
  `gleam_stdlib`. Nothing else, by R6.
- **Depended on by**: `tui`, the terminal host, and `web_view`, the second
  host: the Lustre server components the daemon serves with `loomd --ui`,
  which run the shared step (`step.update`, `commands`, `model.Shared`) and
  draw from its record with `transcript.branch_blocks`, `turns` and
  `agent_roster` (ADR-014 and its addendum). `client` depends on it at
  runtime too, for the
  `connection_event.Message` its web-view relay sends and the
  `snapshot.Expected` its page socket builds, and its tests drive both
  hosts' lanes.
- **No module here imports `tui`**, and none may: the package is below the
  terminal in the dependency graph. A terminal type the shared step would
  need is cut at a type parameter (the four handles) or left in the
  terminal, with the step receiving it as data (`Shared.build_notice`) or
  from the host at the call (`lane_fold.Surroundings`).

## Traffic

None of its own. The package defines no actor, message or register. It
decodes the ClientGateway protocol (spec Part 1.6, `docs/client-protocol.md`)
frames a host hands it, and the frames it asks the host to write are
`subscribe`, `snapshot_next`, `catch_up`, `history`, `escalations_get`,
`escalations_decided` (`session_channel.decided`, sent only to an idle lane) and,
through `submit`, the session's mutations. A read-only host never calls
`submit`; the web view's operator page reaches it through `commands.act`,
with any session command a draft names except adding a directory, and its
observer's page holds no command.

## Invariants

- **No host in the package.** No `@external`, no `gleam_erlang`, no
  `gleam_otp`, no transport, file or terminal. R6 gates it at error level.
- **A shared call writes no host state.** Where a fold or a command used
  to write a host's editor, overlay or footer, it records a fact
  (`surface_facts`, `queue_notices`, `goal_observations`, `drafts_sent`,
  `returned_drafts`), and the host applies the facts after the call, in the
  order recorded, before the next update. A host that holds a result
  without applying its facts leaves them for a later call to apply against
  the wrong earlier state; the terminal's `tui_test/stepping.step` checks
  that every list and `Shared.outbox` are empty after each step.
- **Every output names the handle it acts on.** A frame decided against
  one socket is written to that socket even if the host has replaced the
  lane since; a note goes to the recorder it was decided under (ADR-013,
  phase 1 and phase 2 S3).
- **The lane reads no clock.** Every transition that sets or checks a
  deadline takes `now` from its caller.
- **One request owns the wire.** A mutation is issued at most once and a
  lost reply becomes `UnknownOutcome`, never a retry (the protocol model in
  `protocol/models/terminal-attachment/` checks this).
- **`step.update` runs the terminal's units in the terminal's order.** The
  terminal does not call it, so nothing in the terminal's tests would fail
  if the two compositions drifted; `test/step_test.gleam` spells the
  terminal's tick over the shared record (the activity and roster clocks,
  the drain with each update applied on its own, `service_reads`, the lane's
  tick with its history read) and holds `update` to the same record and the
  same effects, and pins the drain before the reads. A change to the
  terminal's tick order (`tui/tick`) is a change to `update` and its test.
  Its tick leaves out the block-summary read, and a tick with no adopted
  lane drains nothing and keeps the frames, because the terminal's tick
  would read them as the preview peer's traffic.
- **`next_due` is exact.** A `tick` before the reading it names changes
  nothing and a `tick` at it acts; a host that sleeps until it can never
  miss a refresh or a deadline. The property test in
  `packages/tui/test/session_channel_property_test.gleam` checks it after
  every generated step (N1).
- **`Captured` is the only update that replaces the projection.** A host
  that draws anything else from a partial transfer is drawing a cut that
  was never validated.
- **The line builders read a `Presentation`, never a host's model.** A
  new input to a line builder is a new field on `Presentation`, filled by
  every host.
- **`markdown.parse` is total, linear and shallow.** Every input yields a
  tree, no character is scanned more than a fixed number of times, and
  the tree's depth is bounded, because both hosts parse every answer the
  agent writes and the terminal parses a live answer again on every delta.
  A new lookahead scan must say why the text it reads is text no other
  scan reads, as the label, reference and bare-link scans do in their
  comments. `markdown_test` holds hostile inputs sized so that a quadratic
  parser would miss EUnit's time limit.
- **Agent prose renders as Markdown in both hosts.** An answer, reasoning,
  a `ToolDetail` row, a sub-agent's report, an advisor's body and a peer's
  message are Markdown wherever their body is shown; prompts, tool calls,
  results and patches are not. The line builders put agent prose in
  `ToolDetail` rows (a peer message, an expanded `agent_wait` report) so
  the terminal's rule is one speaker set; the web view's result, nudge
  and peer cards draw their bodies as Markdown too.
- **`strand_framing` owns the Agency's framing strings, and `strip` runs only
  for a stored `StrandOrigin`.** `client/agency` builds `frame_message`,
  `frame_brief` and `child_notice` from them, because `client` depends on
  `session_view`. `strip` compares exact strings built from the origin's own
  strand, anchors a brief's trailer on the last foot plus opening line and the
  closing marker at the end, and returns any text that is not exactly the
  framing whole. Text never selects the strand rendering: a framed text under
  origin `None` or in a tool result stays ordinary input.
- **`turns` keys a turn's work by its input.** `Work.key` is
  `work:<input key>`, or `work:window-start` for the turn the window opens
  inside, never the key of the work's first item. The window drops its
  oldest records as new ones arrive, and a key naming the first item would
  change on each such capture, which makes a keyed host replace and redraw
  the whole turn (`web_view`'s `lane_memo_test`).

`protocol.GoalChanged` invalidates the goal's auxiliary observation
(protocol-change/056). `session_channel` retains one owed goal read separately
from transcript capture debt and queued operator intent. It clears the debt
when it issues `goal_get`, so a change received during an older read survives
that reply and causes a subsequent read. Both hosts use this lane, and the
result is a correlated `Auxiliary(GoalSnapshot)`; it requires no host timer.
An automatic read also emits `Submission(Sent)` after the older reply's
updates. The shared surface records its request ID so a correlated refusal
clears the retained goal and marks an open inspector's board as stale, while
the automatic read stays silent in the transcript.

`snapshot_view.queue_halted(view, strand)` derives a known idle strand with
pending rows from one authoritative cut. Ordinary input drains before the
idle cut is exposed (protocol 033), so retained rows wait for an explicit
submission. The helper says nothing about whether a composer may submit.

`GoalReport.ConfirmGoal` carries the mutation's issued request ID, absent
while the command waits behind a read. `outbound.record_sent` binds it
only on the mutation's `Sent` disposition. A board or refusal from an older
background or explicit goal read can update the observation and retire that
read's slot, but cannot consume the queued mutation's report. Success and
refusal settle that report only on its own correlated command reply.

`model.active_queue_halted` derives held input for the active composer while
excluding a prompt already submitting or a running strand. The terminal
wrapper calls this shared decision.

## Goal and held-input source navigation

The scoped modules' `## Flow` comments name the local entrypoints and helper
order. `surfaces` declares `NudgeAction` and `GoalAction` before the reads and
reducers that return them. `session_channel` places `flush_queued` before
`read_changed_goal`, matching their priority in `send_queued`, and documents
the actual private `Phase` constructors and guards beside that type.

Keep the field owners explicit: `Channel.goal_refresh` is `Idle | Due`
invalidation debt; `Shared.goal_refresh` is `worktree_view.Requested | Settled`
surface scheduling. `Shared.goal_request` names an issued command, while
`ConfirmGoal.request` names the mutation that may settle the pending report.
The [delivery reading guide](../../docs/architecture/delivery.md#reading-the-held-input-and-goal-paths-in-gleam)
explains the relevant Gleam idioms and traces an older reply, a later notice,
a queued mutation and a correlated automatic read refusal in both hosts.

## Deep Docs

- `docs/adr/013-tui-effects-as-values.md`: why the lane's effects are
  values; its phase 3 addendum, "What phase 4 extracts", set this
  package's scope.
- `docs/adr/014-second-runtime.md`: one engine, two views, and why
  session logic lives here rather than in a host; its addendum on the step
  says how the four blockers to moving it were closed.
- `docs/architecture/client.md`, "The client engine and its hosts": the
  layering this package sits in, and where each host performs effects.
- `docs/architecture/terminal.md`: the terminal host that drives it.
- `docs/architecture/web-view.md`: the web host that drives it.
- `docs/design-notes/step-extraction.md`: how the step moved here, the
  field split, the facts, and the rulings on the host's loop.
- `docs/architecture/delivery.md`: how both hosts deliver traffic to the
  lane and wake for `next_due`, traced from the socket to the screen.
- `docs/client-protocol.md`: the protocol the lane speaks.
- `protocol/models/terminal-attachment/`: the P model of the lane, the
  attachment worker and the gateway.

## Exact-action watcher approval

`approval.rememberable` admits a singleton public wall-seconds-zero grant for
session consent, in addition to the existing filesystem/full-network forms.
Other limits and mixed requests remain unavailable. `remembered_authority`
states that this consent permits only the captured action on its strand; the
wire still echoes the exact action, grant subset, and displayed sequence.
The client gateway owns persistence and matching; this pure UI grants nothing.
