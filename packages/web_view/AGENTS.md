# web_view

## Purpose

The web view's host and view for one session: two Lustre server components
that drive `session_view`'s lane and draw the session's transcript lines as
HTML, and the documents served around them (the page shell, the ticket
exchange's hand-off page and the content security policy). What the page
loads besides Lustre's server-component runtime is in `priv/static/`, which
a release carries like any application's `priv`: the client components'
bundle, the Tailwind stylesheet and the two bootstrap scripts, all built
from `packages/web_client` by `make gen-client` and gated by `make
client-check`. It is phase 4 of issue #530: the same engine the terminal
runs, under a second host, with only the view differing
([ADR-014](../../docs/adr/014-second-runtime.md)).

The daemon serves it only when started with `loomd --ui`
([protocol-change/051](../../protocol-change/051-web-view-route.md)). The
package knows nothing of the daemon: the transport the lane writes through
is handed in by `packages/client`, which owns the routes, the tickets, the
page keys and nonces, and the relay into the session's gateway.

## Key Types

- `component.Start(socket)`: what the daemon supplies when it starts a
  component: the session ID, the catalogue's `Label(name, workspace)` for
  the heading (or `None`, which only tests pass), the `snapshot.Expected` attachment every cut
  must match, and a `Transport(socket)`. The heading shows the name (or
  `Session` and the ID's first eight characters) with the whole ID in a
  `title`, and the workspace's last segment with the whole path in a
  `title`.
- `component.Transport(socket)`: `connect(inbox, opened)`, which returns at
  once and answers on `opened`; `transmit(socket, frame)`; `shut(socket)`;
  `now()`, and `sessions()`, the sidebar's read of the principal's sessions
  (the daemon's authorized catalogue read, `[]` on failure). All run in the
  component's process.
- `component.Msg(socket)`: `Opened`, `Refused`, `TimerArmed`, `Arrived`
  (a batch of up to `arrival_batch` frames, reduced at once), `Ticked`
  (the deadline timer fired), `OlderRequested` (the "Load older" button, a
  read), `FocusRequested(strand)` (a strip chip, a change of what the page
  shows) and `SessionsListed(entries)` (the sidebar read's own answer,
  dispatched by an effect and carried by no handler). It holds no command.
  `component.older_path` and `component.strip_path` are the Lustre event
  paths the socket admits an observer's click at: the button, and anything
  beneath the strip's chip list.
- **Strand focus.** `component.focus(model, strand)` (`FocusRequested`) is
  `step.focus`, the shared step's change of strand, plus what only this host
  holds: the history read owed for the strand being left is dropped
  (`history_view.resume`) before its window parks, and paging starts again
  at `Tail`. The strand must be listed, must not be the active one, and the
  page must be `Connected`; otherwise nothing changes. Every derived input
  (`Projected.strand`, `Stripped.followed`) includes the active strand, so
  the projection and the strip are rebuilt by `refreshed`. `component.strand(model)`
  is the active strand and `component.primary` (`"main"`) is where a page
  starts. Prompts, steers, queues, interrupts and commands address it because
  the shared step's commands read `active_strand`. A prompt the daemon hands
  back for any strand of the session is kept, and the notice names the
  strand it was held for when that is not the one on screen.
- **The session sidebar.** `web_view/sessions` holds `Entry`, `Residency`
  (`Live | Saved`), `Group` and `grouped(entries, current)` (the current
  session's workspace first, then by newest session, sessions newest first,
  ties by identity and path). `view/sidebar.view(groups, current)` draws it,
  read-only, as the frame's second child (`aside.sidebar`, the left column;
  `element.none()` where a page draws none), memoized. A workspace is a
  section whose label the stylesheet draws as a small uppercase eyebrow with
  the session count, and a hairline in the divider colour separates one
  section from the next (team feedback, 2026-09-29); the list's own heading
  is kept for assistive technology and not drawn. The
  component reads `Transport.sessions` on `Opened` and on a `Ticked` at
  least `sessions_refresh_ms` (30 s) after the last read, keeps at most
  `sessions.listed_limit` entries, and `component.session_groups(model)` is
  what the operator's page draws. The observer's page draws no sidebar:
  `ui_socket.listed_for` gives it an empty list without making the read
  (owner, 2026-09-29). The list cannot open a session (protocol-change/051, the
  addendum on strand focus and the session sidebar, has the proposal).
- `component.Model(socket)` (opaque): two records, as the terminal's is.
  `shared` is `session_view/model.Shared(socket, Nil, Nil, Nil)`, the
  session state the shared step reads and writes: the lane, the inbox, the
  last capture, the strand's history window (`scrollback`), the agent rows,
  roster, cache ledger and notices, the approvals, the notice and the
  drafts the lane sent. `view` is what only this host holds: the transport
  and its deadline timer, how much history the page holds (`Paging`), the
  transcript blocks it holds and the turns laid out from them
  (`turns.Piece`), the agent `Strip`, the inputs each was built from, the
  connection `Status` (`Connecting`, `Connected`, `Ended(ending)`; the
  heading says "connected", not "following", which read as the scroll state
  and is the browser's, and "disconnected" with a notice under it once the
  page ended), the page's own refusal, the outcome of the last
  command, the returned prompts and the count of drafts a command consumed.
  The component writes `shared` in four places only: it trims the history
  window to the rows the page draws, it marks the window as wanting older
  rows, it empties `returned_drafts` once it has taken them, and it empties
  the notice and `answer` before it runs a command.
- `component.live_rows` (150) and `component.held_rows` (300): the page
  holds the newest `live_rows` rows of `main`, cut between turns
  (`turns.grouped`); once the reader loads older rows its limit is
  `held_rows`. `component.Paging` is `Tail | Paged | Full`, and only moves
  forward; `Full` means a paged page had to cut a whole turn, so it loads
  no more. `component.older(model)` asks for the rows below the oldest one
  held, as a `history` read on the page's lane; `component.top(model)` is
  the `lane.Top` the lane draws above its oldest row (`Beginning`,
  `Earlier`, `Loading`, `Full(rows)`).
- The view, one module per screen region under `web_view/view/`, laid out
  by `component.view` and `operator_page.view`. None of them imports
  `component`, which imports them, so each takes what it draws as its own
  types or plain values. `heading.view(session_id, name, workspace,
  status, context, cost, notice)` draws the top bar (the brand, the
  workspace and name, the status, the `ctx ~41%` estimate and the session's
  `est $` cost, worded as the terminal's footer words them), with the ended
  page's notice as its last child; `component.heading(model)` reads those
  values from the model and stays the entry point both pages call.
  `shell.view(audience, bar, sidebar, centre, panel, needing)` draws the
  frame, the client element `<loom-shell sidebar="listed|none"
  needing="n">`, and is where its
  order is written: the bar (0, `slot="bar"`), the sidebar (1, `slot="left"`,
  or `element.none()` when `shell.Unlisted`), the centre `main` (2, the
  default slot: the transcript first, then the dock or the observer's bar)
  and the strand panel (3, last, `slot="right"`). Each region puts its own
  slot attribute on its element. The `sidebar` word comes from the
  `shell.Sidebar` type, `Listed(element)` or `Unlisted`, so the element draws
  no button for a column the page lacks; the operator's page is `Unlisted`
  when its catalogue read listed nothing. `needing` is the number of strands
  waiting on a decision (`component.needing`, `session_view/strand_card`),
  which the element draws as the badge on the Strands tab; it is an integer
  the component counted and never session text. The server never renders
  whether a column is open or which tab shows: those are the reader's, in
  the element.
  `panel.view(count, strands, changes, session)` is the panel's `aside`, a
  tabbed panel of three panes, always all drawn and always in this order: the
  Strands pane (a title, then the strip's list), `changes.view`'s pane and
  `session_tab.view`'s pane. `component.panel(model, focus, viewers)` builds
  it for both pages, the operator's passing `Some(viewers)` and the observer's
  `None`. The tab bar is not drawn here: `<loom-shell>` draws it, keeps which
  tab is chosen and hides the panes of the others with a custom state, so the
  server never learns which shows. The panel carries no decision control: its
  only handlers are the strand cards' focus clicks, a strand waiting on a
  decision reads `Needs approval` on its card, and the approval card that
  answers it stays in the dock, for the strand on screen only
  (`panel_test` pins all of it). `strip.view(strip, focus)` draws the cards
  (the agent strip, kept under its old name), memoized on the whole strip, and
  `strip.count` counts them;
  `lane.view(pieces, live, top, load, replies)` draws the transcript lane, memoized per
  line, followed by the live region, with the line above its oldest row: a "Load older" button sending
  `load` and carrying the fixed `data-loom-older` marker while older rows
  exist, and words otherwise.
- **Expanding a row.** The terminal's `Ctrl+g` shows a call's whole program
  and result and a reasoning block's whole text. The page holds the same
  records, and `component.relaned` asks `turns.pieces` for the expansions
  (`turns.Expand(expansion.capped)`) when it projects a capture, so they are
  built once per projection and never on a render. A `Step` carries its
  `full` rows and a `Plain` or `Narrated` piece carries `thoughts`, the full
  form of each reasoning row by the row's key, both already cut. `lane.view`
  draws a row that has more to show as one `<loom-expand>` (`web_client`): the
  compact rows in a child with `slot="compact"`, the full rows in one with
  `slot="full"`. For a call that is the rows under its summary; for a
  response it is only the reasoning row, so an answer beside the reasoning is
  drawn once. A row whose full form equals the compact one (a call whose
  result is already shown, a one-line reasoning block) has none. The rows are
  the terminal's own builders (`transcript_lines.expanded_call_lines`, and
  `assistant_block_lines` at expanded extent). No event, handler or socket
  read is involved: the text is already in the model, so choosing which form
  shows is the browser's, as a fold's open state is, and it works on an
  observer's page. Both forms are in every viewer's document, so
  `view/expansion.capped` cuts the full rows to `max_lines` (300) lines and
  `max_characters` (8,000) characters per row and ends a cut row with one
  line saying so. The rows are memoized per line as the compact ones are.
  Session text is drawn as text nodes: a program is a Markdown code block,
  so a `<pre><code>` holding text.
- **The live region.** `component.live(model)` turns the shared record's
  streams for the followed strand (`transcript_lines.display_streams`),
  `Shared.summaries` and the generation clock into `live.Row`s, and
  `lane.view(pieces, live, top, load, replies)` draws them through `view/live` as the
  lane's last keyed entry, keyed `live`. `live.Thinking(progress, elapsed_ms,
  headline)` is the reasoning row: `12 lines · <loom-elapsed offset> so far`,
  or with a headline the count and clock and the headline as text beneath
  it; the thinking is not drawn. `live.Answer(line)` is the answer so far,
  drawn by the lane's own assistant line. A tool call being composed is not
  drawn. `View.streams` holds what the page last drew and is maintained by
  `component.streamed`, which follows the record's streams and, when a
  pushed entry has cleared them, keeps the last ones while
  `transcript_lines.response_awaited` says their answer is still owed
  (entry not in the projected window, operation still running in the
  capture), so the committed row replaces the region in one patch. The
  page also drops a stream whose answer the projected window already holds (a capture before the push) and keeps a mid-answer attach's sampled preview until the pushed text is at least as long (`steadied`), where the terminal shrinks to the first fragment. The
  region opts out of the log's live announcement (`aria-live="off"`). No
  read or socket event is involved, and `page_events_test` and `older_path`
  are unchanged. `live_test` pins the rows, the hand-over and the patch
  size (107 to 268 bytes for a fragment on a page of 150 rows, the same
  within two bytes on a page of one; `delivery_test`: a burst is one patch
  of 576 to 668 bytes on the real runtime).
- `nudges.view(board)` draws the advisor's pending nudges
  (`Shared.nudges`, the terminal's "Advisor · pending, not delivered"), every
  body received oldest first as a text node and a `+n more waiting` line for the
  ones the server counted and did not send. It is read-only on both pages
  and holds no handler, because the queue has no accept or dismiss: the only
  operation on it is the `advisor_pending` read, and the primary's next run
  start drains it. It is the dock's second child on the operator's page and sits
  after the todo panel on the observer's.
- `controls.view(bar)` draws the operator's controls in the dock, above the
  approvals: Stop (always drawn, disabled while the strand is idle, so nothing
  moves when it is enabled), the goal row in the terminal's words
  (`goal_view.row`) with the buttons its status offers (Pause while active,
  Resume while held or limited, Clear always, nothing to steer once complete)
  in a `control-actions arming` row keyed by the status, and two `<details>`
  each holding a one-field form, Fork and Set goal. `controls.Bar` carries the
  messages each button sends and the forms' submit handlers, since
  `operator_page` owns the message type. The observer's page draws none of it.
- `lane.Replies(fn(key) -> message)` or `NoReplies`, the last argument of
  `lane.view`. A peer card draws a `Reply to
  this peer` button after its body when the lane has replies, and the button
  sends the piece's key, never the peer's session or strand.
- `todo_panel.view(board, reviewers)` draws the terminal's pinned todo
  board and reviewer band on both pages, from plain values;
  `component.plan(model)` reads them: `Shared.todo_boards` at
  `Shared.active_strand`, and `reviewer_status.lines` over
  `Shared.reviewer_rows`, the terminal's own lines. The board is one line
  until the reader opens it, `Todo · 3 of 5 done · <active task>`, the
  summary of a `<loom-fold>` (the browser keeps its open state, so a patch
  leaves it alone and an observer's page has it too); the line follows the
  strand the page shows because the board is that strand's. Opened, the phase holding the
  active task (`todo_list.focus`) is expanded with every task, each with the
  terminal's glyph (`✓ ▸ ○ ⊘ –`, hidden from assistive technology, with the
  status as a visually hidden word) and a blocked task's reason; the other
  phases are one row of `name ✓` or `name n/m`; the header carries the
  phase's count and `n/m done`; a board with every task closed is one row.
  The band's lines are drawn as they are, in a `pre-wrap` block under the
  board, and it is drawn without a board when a reviewer runs. The panel is
  memoized on the board and the lines, and is `element.none()` when there
  is neither. It is the dock's first child on the operator's page and sits
  between the lane and the bar on the observer's, so the lane's
  `older_path` is unchanged. The terminal's idle-advisor placeholder is not
  drawn.
- `changes.view(board)` draws the Changes pane, the panel's second, on both
  pages from `component.changes(model)`, the board `session_view/changes_view`
  folds from the records of the window the page projects (`relaned` builds it
  with the transcript, so a message that moved neither costs no fold). Its
  heading is `Changes · 2 files · +14 -2` with `from this session's edits`
  under it, then one `<details>` per file with the first open. Paths and diff
  rows are text nodes; a row's class is one of four literals chosen from the
  fold's `Kind`. It has no handler and is memoized on the board. With no edit
  it is the heading and one line saying so, so the pane is always drawn and
  the panes after it never move. It reads no worktree: the daemon serves
  worktree bytes to an Owner binding only.
- `session_tab.view(goal, cost, jobs, viewers)` draws the Session pane, the
  panel's third: the goal (the terminal's own row, `goal_view.row`, or
  `none`), the followed strand's live jobs, where the page shows them the
  attached viewers (`session_view/session_summary`) and the estimated cost the
  top bar shows. Schedules are not a row: the shared record keeps a schedule
  listing only as transcript lines the page does not draw. The component asks
  for the jobs on a `Ticked` when the page opened or last asked
  `jobs_refresh_ms` (10 s) ago and no answer is outstanding. The clock starts
  when the page opens, so the first tick-driven ask comes ten seconds later,
  after the startup reads, and the page's lane stays in the terminal's engine
  state through them. This is the tick-driven ask only: the lane also requests
  a read whenever a run's completion changes, `lane_fold`. The tick marks
  `Shared.jobs_refresh` as requested and
  the shared step sends the `live_jobs` read once the lane is ready
  (`surfaces.service_jobs_read`). The read is one of the gateway's
  `read_only` commands, every role may send it, and its answer is a snapshot
  the lane folds like any other, so it adds no event and no accepted page
  event. A refused read is not repeated before the interval passes
  (`View.jobs_asked_at`), and a board for another strand than the one shown
  reads as not read yet. Viewers are drawn on the operator's page and never on
  the observer's, which is handed `None` (a default the design note adopted,
  open to an owner override). Job commands, viewer names and the goal are
  text nodes.
- `strip.Strip` and `strip.Chip`: the listed agents (`line`,
  positional `hue`, the `cache` outlook `cache_watch.shown` allows with its
  label, and `running_ms`, how long its operation had run when the strip
  was built), the advisor's chip and the settled count. The component
  builds them and `strip.view` draws them. `strip.hue_class` and
  `strip.ring_class` map a hue and an outlook to literal classes.
  `Strip.followed` is the strand the strip marks as current
  (`component.strand(model)`). `strip.view(strip, focus)` draws each chip
  as `li > button.chip-hit` whose click is `focus(name)`, the name the strip
  was built with; the "settled" chip is not a control.
- `markdown_view.blocks(tree)`: the elements for an answer's Markdown,
  drawn from `session_view/markdown`'s tree, the tree the terminal's
  `tui/markdown` also draws. `view/lane` uses it for the speakers the
  terminal renders as Markdown (assistant, reasoning, tool detail) and for
  the bodies of the result, nudge and peer cards, which are agent prose
  the terminal draws as tool-detail rows; every other row stays a `pre`.
  The model holds no trees. `lane.view` draws every transcript line and
  card body inside its own `element.memo` keyed on that line or body, with
  no memo around them (`lane.rows`), so a line is parsed and drawn when it
  first appears and Lustre reuses its element after that. Lustre forgets
  memos nested inside a memo that hit and redraws a keyed subtree whose
  key changed, which is why the memos are leaves and why `turns` keys a
  turn's work by its input (`docs/lustre.md`, "A memo inside a memo that
  hit is forgotten"). `lane_memo_test` counts the lines a render draws.
- `component.{submit, decide}`: the two inputs, wrapped as the shared
  step's commands (`step.update` with `Acted`). `submit` checks the draft's
  emptiness and length, which are the page socket's limits, and then parses
  it with `command.parse_with_skills`. `component.page_command` is the one
  place that names what the page does not run: a `command.Surface` and
  `command.AddDirectory` (`/add-dir`, `/add-write-dir`, which name a path on
  the daemon's host) are refused with a `Warned` notice and never sent, and
  every other `command.Session` runs through `commands.act` as the terminal
  runs it, so `/compact` is a compaction and `/models` is refused. The page
  loads no skills catalogue, so a skill's slash command is refused as
  unknown. `Answer` is `AllowOnce | Deny`; a page never offers remembering
  a grant for the session. A decision takes `outbound.mutation_refusal`'s
  refusals like any mutation, and the card stays when it is refused.
- `component.control(model, Control)` and `component.reply(model, key)`:
  the page's session controls and its peer reply. A `component.Control` is
  `Stop`, `PauseGoal`, `ResumeGoal`, `ClearGoal`, `Fork(name)` or
  `PinGoal(objective)`. Stop is `msg.Interrupt`, the terminal's Escape: it
  aborts the strand's running operation, holds the input queued behind it, and
  leaves the session open (ending the session is daemon control, which stays in
  the terminal). The goal buttons and the two forms are `msg.Control(command)`
  (`session_view/commands.control`): the same dispatch as a typed draft, with
  no draft, so the composer's text and `component.drafts` are untouched. A
  form's text goes after `/fork ` or `/goal ` and through `command.parse`, and
  `forking` and `pinning` check what came back: the goal form accepts only a
  goal or the command's own complaint about it, so the word `clear` in its box
  never unpins the goal. `View.sent_forms` counts forms whose command the lane accepted
  (`outbound.mutation_refusal` said none and the command mutates, so it went out
  or was queued behind a read), and the forms are keyed by it, so an accepted
  form comes back closed and empty and a refused one keeps its text.
  `component.reply` finds the `turns.Peer` piece by the engine's key, drafts
  `Reply to the peer message from session S, strand T, with peer_send: `, and
  appends it to `View.returned` beside the daemon's returned prompts, so
  `<loom-composer>` puts it in an empty editor or after the draft and never over
  it. The terminal has no reply command: the model answers a peer under the
  owner's link with `peer_send`, at the operator's prompt. Nothing is sent by
  `reply`. `component.pending_nudges(model)` and `component.goal(model)` read
  `Shared.nudges` and `Shared.goal`.
- `operator_page.Msg(socket)`: `Observed(component.Msg)`, `Submitted(text,
  delivery)`, `Decided(id, seq, answer)`, `Controlled(component.Control)` and
  `Replying(key)`. The lane's "Load older"
  button sends `Observed(component.OlderRequested)`.
  `composition(fields)` is the total decoder of the composer form's
  fields, and `control_text(fields)` of a control form's: exactly one
  `text` field.
- `completion.rows()` and `completion.table()`: the slash commands the
  composer offers, built from `session_view/command.suggestions` (the
  one-word commands, and the argument rows of every word that has some once
  its space is typed) less the rows `component.page_command` refuses, as one
  JSON string for the composer element's `commands` attribute. The names and
  hints are the terminal's and no session text is in it.
- `component.Returned(number, text)`, `component.returns(model)` and
  `component.returned(model)`: a held prompt the daemon handed back for
  `main` (protocol-change/038), taken from `Shared.returned_drafts` at the
  end of every message (`taken`), numbered, and kept, the latest
  all of them, for the composer's element. `component.reply` adds the start
  of a peer reply to the same list, so the element treats a reply as a
  returned prompt (put in an empty editor, or after the draft, once, by
  number), and the notice about returned prompts is the daemon's alone.
  `step.update`
  leaves `returned_drafts` alone (`forget_surfaces` no longer clears it), so
  the page is the host that empties it. A prompt for another strand or
  session is named in the notice and not kept.
- `ending.Ending` (`PageEnded`, `AccessRevoked`, `SessionStopped`,
  `NotOpen`, `DaemonNotReady`, `LinkExpired`, `ConnectionFailed`): why a page
  has no session, as a closed type. `PageEnded` means eight hours ran out, the
  daemon restarted, or the page was the oldest of `ending.max_pages` (four)
  when a newer link opened; a newer link ends nothing below that bound. `headline` and `advice(ending,
  session_id)` are fixed strings, so no peer, session or error text reaches
  the page. `reason` and `from_reason(given, otherwise)` are the two halves
  of the hop through the reason string `connection_event.Closed` carries
  (`from_reason` is total: a string that names no ending gets the caller's
  fallback, which the component sets to `ConnectionFailed`, or `NotOpen` for
  a refused open). `close(ending)` is `Final` (close 1000, which Lustre's
  client runtime does not retry) or `Retry` (4000, which it does), read by
  `client/daemon/ui_socket`. `view/ended.view(option(ending), session_id)` draws
  the notice, a `section` with two paragraphs, or `element.none()`.
- `page`: the shell, whose `<lustre-server-component>` holds a fixed
  paragraph (`waiting_notice(session_id)`) as light-DOM content, which the
  client runtime hides when it mounts and which so shows exactly while the
  page has no session; `refusal(ending, session_id)`, the document a
  refused page request is answered with; the exchange page (`enter(next, nonce)`), the asset
  names (`stylesheet_asset`, `enter_asset`, `page_asset`, `client_asset`,
  `runtime_asset`) and where each is on disk (`static_file`,
  `runtime_file`), the keyed paths (`keyed_prefix`, `session_path`) and
  `content_security_policy(host)`.

## Relationships

- **Depends on**: `session_view` (the shared step and its record, the
  lane, the inbox, `commands`, `history_view`, `transcript.branch_blocks`,
  `turns`, `approval`, the line types), `core` (the
  origin label; JSON in tests), `lustre == 5.7.1`, `houdini == 1.2.1`,
  `gleam_erlang`.
- **Depended on by**: `client`, whose `client/daemon/ui_socket` starts one
  component per browser connection and whose router serves `page`'s
  documents.

## Traffic

- The component's mailbox receives the open's outcome (mapped to `Opened`
  or `Refused`), `connection_event.Message`s from the transport (the
  mapping drains up to `arrival_batch` waiting frames into one `Arrived`),
  and a `Nil` from its one deadline timer, armed for the lane's
  `session_channel.next_due` (mapped to `Ticked`). Each source is one
  `server_component.select` from `init`, so its subjects belong to the
  component's process. Every message reaches the shared step as
  `step.update`: `Arrived` is `msg.Arrived` then a tick, `Ticked` and
  `Opened` are a tick, and a command is `Acted`. The step folds each lane
  update into `shared` (captures, history pages, usage and the cache
  ledger, streams, refusals, acknowledgements), as it does for the
  terminal. The page then derives what it draws from `shared` (see the
  invariants). The notice is an outcome and never the shared record's `notice`, which any
  event replaces and which would say "advisor_pending sent" on every page
  load. `Said` is what the shared step worded when the page ran the
  operator's command (`View.outcome`, read at once, after the notice and
  `Shared.answer` were emptied so that a silent command leaves nothing) or
  the daemon's reply to it (`Shared.answer`, which only another reply
  writes); the page's own refusals are `Warned`.
- Out on the lane, besides the lane's own snapshot requests and the
  operator's commands: at most one request at a time. The shared step's
  reads go out as the terminal's do, one after another and each when the
  one before is answered: the strand's notes (a first capture, to seed a
  todo board, which the todo panel draws), the session's context (a first
  capture, a configuration change and the end of each operation), the
  advisor's pending nudges and the goal. Also the `history` read
  (`session_channel.history`) for at most 100 sequences below the oldest
  record the page holds. The summary labels' read is not sent.
- The page renders `web_client`'s custom elements by tag:
  `<loom-elapsed offset>` in each chip and in the live reasoning row, `<loom-fold>` around a settled
  turn's work, `<loom-expand>` around a row with more to show, and `<loom-follow>` around the lane and `<loom-shell>` around the page. The stylesheet pins the
  page's frame (`<loom-shell>`: the top bar across the full width, and under
  it the sessions' sidebar, the centre and the strand panel; the dock or the
  observer's bar at the bottom of the centre, the page itself never
  scrolling) and makes `<loom-follow>` the scroll container between them
  and the dock. The element's two buttons hide and show the sidebar and the
  panel (a hidden column is `inert`, so its content leaves the tab order),
  with nothing kept across a reload. The sidebar is dropped below 1212px, and below 980px the
  panel becomes a row of cards under the bar. It keeps the
  newest row in view while the reader is at the bottom, shows a "Jump to
  latest" button while they are not, and keeps the reader's place when a
  press of "Load older" brings rows in above them. They run in the browser
  and send the server nothing. The operator's editor is drawn inside
  `<loom-composer commands returned>`, which lists the slash commands as
  the draft grows, sends the draft on Command or Control with Enter (by
  submitting the composer form), and puts a returned prompt in the editor.
  Its inputs are the `commands` table, the `returned` count and the
  returned prompts as text-node children in a `returned` slot, numbered by
  `data-n`; the editor stays the uncontrolled textarea, and keeps its place
  when a return arrives.
- An operator's page also receives Lustre's `EventFired` for its handlers:
  a click on an approval button, on one of the controls or on a peer card's
  Reply, and the submit of the composer form or of one of the two control
  forms. They are the clicks and submits `ui_socket.operator_accepts` admits
  already, so the page adds no event.
  The composer element's keys and list add no event: the send key calls
  `requestSubmit`, which raises the same submit, and `page_events_test` pins
  that the operator's page registers only clicks and submits.
- Outputs leave through the transport only: `Transmit` and `Shut`, in the
  lane's order, inside one `effect.from`.

## Invariants

- **No session logic here.** What a frame means, when to catch up, which
  lines a capture becomes, how a lane folds into turns, which agents a strip
  lists, what the cache may claim and what an operator's input becomes on
  the wire are `session_view`'s.
- **Derive from inputs that moved, never per render or per tick.** The
  blocks and pieces are rebuilt only when the capture, the history window,
  the cache notices, the agent rows or the paging differ from what the last
  projection read (`Projected`), and the strip only when its inputs
  (`Stripped`, less the roster's clock) or a drawn cache label did. An idle
  refresh that brings back the capture already drawn projects nothing. The
  shared record's `render_revision` is not the signal: it moves for stream
  fragments (which change the live region below, not a projection) and
  tool tails the page does not draw, and a page that re-projected on each
  would project once per batch of a streaming answer.
  Logic that decides something about the session belongs to `session_view`,
  where the terminal uses it too.
- **Event-driven delivery, one render per burst.** `Arrived` files its
  batch and then ticks, which drains every filed frame in arrival order and
  runs the lane's tick; there is no periodic tick. Lustre renders once per
  message whatever it changed, so the batching has to happen in the
  selector's mapping, before `update`. `update` reads the transport's clock
  once, at its top, and the step reads none. After every transition `rearm`
  cancels the one timer and arms it for the lane's `next_due`; `update`
  performs that itself, because the `Timer` handle must stay in the model
  (ADR-013, the addendum on event-driven delivery). `component_test` pins
  the reduction; `delivery_test` counts the renders a burst costs on the
  real runtime and watches the timer fire.
- **The page's rows are bounded.** The page holds at most `live_rows`
  rows, or `held_rows` once paged, plus at most one block when the newest
  turn alone is longer than the limit; loading older rows past the limit
  is refused (`Full`), never allowed to grow the page. Once rows are cut,
  the history window is trimmed to the oldest record drawn
  (`history_view.retain_from`), so what a capture projects is in
  proportion to the page. The page starts at a turn's input whenever it
  can, so prepending older rows and sliding the window leave every held
  turn's key, and its lines' memos, as they were (`lane_memo_test`). The
  undrawn end of a turn whose input is older stays in the window so the
  next read goes below it, and counts as cut once it alone no longer fits.
- **One read at a time.** The history read goes out only when the lane has
  no request out (`session_channel.history` refuses a busy lane); until
  then the demand stays `Wanted` and every reduction offers it again. While
  a read is out the history window is frozen, and the reply, a refusal or
  the lane's failure is what ends it. The button is offered only while
  there are sequences below the window to read.
- **One ordered effect.** The lane's outputs are performed in one
  `effect.from`, never split across `effect.batch`, which does not order.
- **The page keeps no facts the step recorded for surfaces it lacks.** The
  step's tick drops them itself; the component drops the ones a command
  recorded (`step.forget_surfaces`) after it has read `DraftTaken`, the only
  one it reads, and the ones `apply` folds. A list that nothing empties
  would grow for the life of the page. `step.forget_surfaces` leaves
  `returned_drafts` alone, because a held prompt the daemon hands back is
  its last copy: the page takes it into `component.returned` and empties
  the list, and the composer's element puts it back in the editor.
- **Which application runs is which commands exist.** An observer's page is
  `component.app()`, whose message type holds no command and whose view
  attaches the lane's "Load older" click (`OlderRequested`, a read) and one
  click per strip chip (`FocusRequested`, a change of what the page shows,
  built from the name the strip was drawn with); its bar is a fixed text
  node. The page socket admits from an observer only a click at
  `component.older_path` or beneath `component.strip_path`
  (protocol-change/051, the addenda on history paging and strand focus), and
  `page_events_test` pins that the observer's handlers are exactly those.
  The sidebar and every other region add none. The strand panel is the
  frame's last child, so a region added after it does not move an admitted
  path; the redesign's shell moved both constants once (`older_path` is
  `0\t2\t0\t0\t0`, `strip_path` `0\t3\t1\t0`; the tabbed panel moved
  `strip_path` again, to `0\t3\t0\t1\t0`, because the Strands pane is the
  panel's first child), and `page_events_test` and `ui_socket_test` pin
  them. An operator's page is
  `operator_page.app()`. Since S5 the draft its composer carries is parsed
  as the terminal parses it, so the page sends any session command a draft
  names (`/fork`, `/model`, `/goal ...` and the rest of `command.Session`),
  not only a prompt, except adding a directory, which `page_command` refuses
  (protocol-change/051, the addendum "the operator page runs session
  commands"). Its controls (Stop, the goal's buttons, the Fork and Set goal
  forms) and its peer Reply button run the same commands, chosen by a click or
  a submit instead of typed (the addendum "the page's session controls, the
  pending nudges and the peer reply"), so the page's operations are still
  exactly `command.Session` less adding a directory, and its events are
  still the clicks and submits the socket admits. What bounds them is the
  attachment's role, capped at operator, which the gateway enforces. The
  daemon's gateway refuses an observer's mutation independently, and the
  engine refuses one on an observer's attachment as a third layer.
- **A control never takes the composer's draft, and a form is cleared only
  when it sent.** A control's command is `msg.Control`, which sets no
  submission marker and drops `DraftTaken`, so pressing Fork or Clear goal
  while the operator is typing leaves the composer as it was
  (`component.drafts` does not move). The two forms hold the command's own
  text, so they are keyed by `sent_forms`, which rises when the lane accepts
  the command (sent, or queued behind a read, whose frame moves the request
  identity only when the reply lands), and a refusal (no name, an observer's attachment, a busy
  lane) keeps what was typed.
- **The controls draw at fixed places.** Stop is always in the row and only
  its `disabled` changes, so a strand starting to run moves nothing under
  the pointer. The goal's row is keyed by the goal's status and carries
  `arming`, the 600 ms refusal of clicks the approval card uses, so a status
  change that swaps Pause for Resume cannot take a click aimed at the old
  button. The composer stays last in the dock, with the approvals directly
  above it.
- **No handler or attribute from session text.** Button messages carry the
  daemon's escalation identity and sequence; cards are keyed by sequence
  (every storage write takes its own), rows by the engine's `transcript.Row` key. Text is only ever
  `html.text`; nothing uses `unsafe_raw_html`. Rendered Markdown keeps the
  same rule: a link is its label and its destination as text, never an
  `href`; an image is text and is never loaded; an ordered list's numbers
  and a fence's language are text; classes come from closed types.
- **An approval card is drawn from the record alone** (`approval.presentation`),
  in its own region outside the transcript, directly above the composer in
  the dock, the footer at the bottom of the pinned frame. A card
  appearing grows the dock upward and never moves the composer, the
  transcript above it shrinks by as much, and the region's height is
  capped so it scrolls on its own. With nothing pending
  the region is `element.none()`, so the composer's path does not change
  when a card appears. The action row carries `arming`: for 600 ms after
  a card is inserted the stylesheet refuses clicks on it and dims the
  buttons, and cards keyed by sequence keep their node so a patch never
  restarts it; reduced motion drops only the dimming. Deny comes first; each button
  names the tool; nothing has `autofocus`; the composer's submit never
  decides an approval; a decision is sent only for the record still pending
  at the drawn sequence (`operator.drawn`).
- **The todo panel never covers the transcript and carries no handler.**
  It is in the flow of the pinned frame, so the transcript shrinks by its
  height; the stylesheet caps it (`max-height: 28vh`) and it scrolls
  inside. Its text is session text, drawn as text nodes; its classes are a
  closed set chosen from the status, never from a string.
- **The list offers only what Send would run.** `completion` drops a row
  exactly when `component.page_command` refuses the command it names, so
  there is no second list of what the page refuses; a row that takes an
  argument is judged with one, since the command alone is a usage message.
- **A returned prompt is never dropped and never replaces a draft.** The
  editor is not keyed by returns, so a return leaves what the operator is
  typing; the element decides whether the text is the draft or follows it.
- **The composer form is decoded totally.** One `draft`, at most one
  `delivery` of `prompt` or `steer`, nothing else; anything more refuses
  the event.
- **No inline script or style** in any served document, so the policy can
  refuse both.
- **Class names are complete literal strings.** Tailwind builds the
  stylesheet from the classes this package's source spells, read as text
  (`packages/web_client/src/web_client.css` names it with `@source`). A
  class built by concatenation is missing from the output. `priv/static` is
  generated: run `make gen-client` after changing a class.

## Deep Docs

- `docs/architecture/web-view.md`: the architecture map: the request path
  from `loom ui` to a live socket, the processes per page, the two
  components, and the security layers.
- `docs/design-notes/web-ui.md`: the working spec for where the page is
  going (an exploration, not a commitment).
- `docs/adr/014-second-runtime.md`: one engine, two views, and option C in
  the web host.
- `protocol-change/051-web-view-route.md`: the routes, authentication, the
  relay, and the operator addendum (page keys, nonces, ceilings, cards).
- `docs/lustre.md`: how Lustre 5.7.1 server components work, how they map
  onto this package, `ui_socket` and `ui_relay`, the view's security and
  accessibility rules, and the checklist for a change here.
