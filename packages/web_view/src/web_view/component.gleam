//// The web view's host for one session: a Lustre server component that
//// drives `session_view`'s shared step and draws the session's transcript
//// lines as HTML.
////
//// The component is the step's host in the sense ADR-014 gives the word. It
//// reads what the engine may not read (a clock, a mailbox) and delivers it as
//// messages, and it performs the step's effects. It holds no session logic of
//// its own: which frames to send, what a reply means, when to catch up,
//// which lines a capture becomes and what an operator's input becomes on
//// the wire are all `session_view`'s, exactly as they are for the terminal.
//// What is web-specific here is the delivery (a Lustre selector instead of an
//// etui tick) and the view (HTML elements instead of terminal cells).
////
//// The model is two records, as the terminal's is (`docs/design-notes/
//// step-extraction.md`, section 1). `shared` is the session state the step
//// reads and writes, and this module never writes it except in two places
//// that are the page's own: the history window is trimmed to the rows the
//// page draws, and asked for older rows when the reader presses "Load
//// older". `view` is what only this host holds: the transport and its
//// deadline timer, the transcript blocks the page draws, the agent strip,
//// how many rows the page holds and the connection's status.
////
//// `update` reads the transport's clock once, at its top, and hands the step
//// that reading as its stamp. Every message then reaches the step as the
//// entry a host with no surfaces of its own uses, `step.update`: an arriving
//// batch is filed and reduced in one Lustre message (`Arrived` and then a
//// tick), the deadline timer's message is a tick, and an operator's input is
//// a command. The step returns the effects it decided, and this module
//// performs them.
////
//// Delivery is event-driven (ADR-013, the addendum on event-driven
//// delivery). The selector that reads the transport's inbox drains it in
//// the same breath: the frame it matched and up to `arrival_batch - 1` more
//// that are already waiting become one `Arrived`. Batching is what keeps a
//// burst cheap. Lustre 5.7.1 runs the view, diffs it and broadcasts the
//// patch for every message the runtime takes, with no check for an empty
//// patch, so one message per frame would be one render per frame. One
//// message per burst is one render per burst.
////
//// There is no periodic tick. After every transition the component asks
//// the lane when it next has something to do (`session_channel.next_due`:
//// the in-flight deadline, or the idle refresh) and arms one timer for that
//// reading, cancelling the one it armed before. When it fires, `Ticked`
//// runs the same reduction at the reading taken when the timer message was
//// received. An idle page therefore wakes once per refresh interval, five
//// seconds once the daemon has pushed, and not four times a second.
////
//// The transport is supplied by the host that starts the component, because
//// what a socket is belongs to that host. In the daemon it is a relay into
//// the session's gateway (`client/daemon/ui_relay`); in a test it is
//// whatever the test hands in. Opening it may take as long as the gateway's
//// attach, which is longer than Lustre's one-second start budget, so the
//// transport opens asynchronously: `connect` returns at once and answers on
//// a subject the component selects. The interpreter for the step's effects
//// has the terminal's shape: `Transmit` writes a frame through the
//// transport and `Shut` closes it, in the order the step decided them, in
//// one effect. The component has no recorder, so its recorder type is `Nil`
//// and it never queues a note.
////
//// This module is the observer's application, and its message type carries
//// no command. Its view attaches one event handler, the lane's "Load older"
//// button, whose message asks for a read of older history and nothing else
//// (protocol-change/051, the addendum on history paging). An operator's page
//// is `web_view/operator_page`, which wraps these messages with the two
//// commands an operator may send and reaches the step through `submit` and
//// `decide` here, which wrap them as the step's commands.
////
//// The page holds a bounded number of transcript rows: the newest
//// `live_rows` of its strand, or `held_rows` once the reader has loaded
//// older ones. It keeps the strand's history window across captures
//// (`history_view`, the shared record's `scrollback`) and closes a turn into
//// a summary (`turn_ledger`) when every record of it is in the window and
//// nothing will be added, so the window holds the running turn and the page
//// holds the closed turns as the pieces it draws, not as records
//// (protocol-change/071). `older` pages further back by turns, and opening a
//// closed turn's fold reads that turn's newest steps the same way: both walk
//// the strand's own parent links through the lane's lineage read
//// (`history_lineage`, protocol-change/072), so what other strands wrote in
//// between costs the page nothing. The limit and `Paging` are this page's view
//// state.
////
//// What the page draws is derived from the shared record by `refreshed`, which
//// runs at the end of every message and rebuilds a projection only when the
//// inputs it reads moved. The shared record's own `render_revision` is not
//// that signal. It moves for everything the terminal's rows are built from,
//// including stream fragments, which change the live region (`live`) and
//// nothing a capture projects, and a page that re-projected on each of them
//// would project once per batch of a streaming answer. The projection's
//// inputs are compared instead, and an unchanged input is the same term,
//// which costs a pointer comparison.
////
//// The response the provider is still writing is drawn from the shared
//// record's streams, as the terminal draws it, in a region of its own at the
//// lane's end (`view/live`). The page keeps the streams it last drew
//// (`View.streams`) beyond the moment the shared record drops them, because
//// a pushed entry clears a strand's streams and a page that draws only
//// captures has no row for the answer until its next capture: `streamed`
//// keeps the last streams while their answer is still owed and lets go once
//// a capture holds it, so the answer is replaced by its record and does not
//// leave the page and come back.
////
//// The page's regions are drawn by the modules under `web_view/view`: the
//// heading, the agent strip and the transcript lane. This module derives
//// what they draw, when a message changes it, and `view` lays them out.
////
//// ## Flow
////
//// `init` → `update` → `stepping` → `finished` → `refreshed` → `view`
////
//// 1. `app` names the Lustre application; `init` builds the model with `new`,
////    then `open` starts the transport and `arm` the deadline timer.
//// 2. `update` receives one `Msg`. `Opened` starts the lane through
////    `session_channel.start`, `Arrived` and `Ticked` run the shared step, and
////    `OlderRequested` and `FocusRequested` go to `older_at` and `focus_at`.
//// 3. `stepping` folds the messages through `step.update` and collects the
////    effects each decided, then calls `finished`.
//// 4. `finished` ends every message: `settled` takes what the step left,
////    `refreshed` derives what the page draws, `rearm` sets the deadline timer
////    for the lane's next due reading, and `perform` runs the effects.
//// 5. `refreshed` rebuilds a projection only when its inputs moved: `relaned`
////    projects the transcript window, `restripped` the agent strip, and
////    `streamed` and `statused` follow the live answer and the connection.
//// 6. `submit` and `decide` are the operator page's way in; `submitting` and
////    `commanded` wrap a command as the step's message. `switch_to` asks the
////    daemon to open another session.
//// 7. `older`, `focus` and `invite` are the other public entries that change
////    what the page shows; `going_home` asks the daemon for a ticket to the
////    home page; `apply` folds lane updates a caller took from the lane itself.
//// 8. `view` lays the derived pieces out, through `heading`, `panel`, `live`
////    and the `web_view/view` modules, and reads nothing the model does not hold.

import core/ids
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/server_component
import session_view/advisor_history
import session_view/advisor_pending
import session_view/agent_roster
import session_view/agent_view
import session_view/approval
import session_view/block_summary
import session_view/cache_miss
import session_view/cache_watch
import session_view/changes_view
import session_view/command
import session_view/composer
import session_view/connection_event
import session_view/context_view
import session_view/decisions
import session_view/fold_budget
import session_view/goal_view
import session_view/history_view
import session_view/inbox
import session_view/lane_fold
import session_view/model.{type Shared, Shared} as session_model
import session_view/msg
import session_view/notice_words
import session_view/operator
import session_view/outbound
import session_view/pasted_image
import session_view/protocol
import session_view/remembered as kept
import session_view/reviewer_status
import session_view/session_channel
import session_view/session_summary
import session_view/snapshot
import session_view/snapshot_view
import session_view/step
import session_view/step_effect
import session_view/step_words
import session_view/strand_card
import session_view/surfaces
import session_view/text_hygiene
import session_view/trace_view
import session_view/transcript
import session_view/transcript_image.{type Image}
import session_view/transcript_line.{
  type CacheNotice, type Line, type Stream, Assistant, Line,
}
import session_view/transcript_lines
import session_view/turn_labels
import session_view/turn_ledger
import session_view/turns
import session_view/worktree_view
import web_view/actions
import web_view/creations
import web_view/ending.{type Ending}
import web_view/grants
import web_view/image as web_image
import web_view/invites
import web_view/remembered as holding
import web_view/renames
import web_view/sessions
import web_view/shareables
import web_view/view/archiving
import web_view/view/changes
import web_view/view/commentary
import web_view/view/context_breakdown
import web_view/view/crumb
import web_view/view/ended
import web_view/view/expansion
import web_view/view/heading
import web_view/view/lane
import web_view/view/live
import web_view/view/nudges
import web_view/view/panel
import web_view/view/rename as rename_view
import web_view/view/session_tab
import web_view/view/shell
import web_view/view/strand_detail
import web_view/view/strip
import web_view/view/switch
import web_view/view/todo_panel
import web_view/view/trace
import web_view/worktrees

/// The most frames one `Arrived` carries: the frame the selector matched
/// and up to this many less one already waiting behind it.
///
/// It is the terminal's `connection_batch`, the most frames one of its
/// steps reduces, so a burst costs the two hosts the same number of
/// reductions. A burst longer than this is several batches, each taken as
/// soon as the one before it is reduced.
pub const arrival_batch = 64

/// The strand a page starts on, and the only one a fresh page can be
/// showing: the session's primary strand. The reader moves off it by
/// focusing another chip of the agent strip (`focus`), after which
/// `strand(model)` names the one the page shows and addresses.
pub const primary = "main"

/// How many transcript rows the page holds while it follows the session:
/// the newest rows of the strand, cut between turns
/// (`turns.grouped`). Older rows leave the page as new ones arrive.
///
/// The number bounds what the page retains. Lustre's server runtime keeps
/// every element it rendered, to diff the next render against, and a row
/// of rendered Markdown retains several times what a plain row does (#587).
/// Measured with #587's page of short Markdown answers, 150 rows retain
/// less than 600 plain rows did before Markdown was drawn, which is the
/// footprint the page had to stay within, and `held_rows` retains about a
/// fifth more. It is also several screens of reading before the reader
/// needs "Load older". A cut holds at most a hundred records of the whole
/// session, so on a session of one-row answers the page gathers its rows
/// over several captures; records that draw several rows each fill it from
/// one.
pub const live_rows = 150

// Open folds have a reserve of their own beyond `live_rows` and `held_rows`,
// `fold_budget.fold_rows` (100), so what a page draws is bounded by its limit
// plus that constant, and a page full of closed turns can still show an open
// fold's newest steps. The reserve is not part of which turns are held.

/// The most transcript rows the page holds once its reader has loaded
/// older ones: twice `live_rows`.
///
/// Loading older rows raises the page's limit from `live_rows` to this.
/// The page still holds the newest rows, so new ones keep arriving at the
/// bottom, and once the page is at this limit it loads no more
/// (`lane.Full`). Refusing at the limit, rather than dropping the newest
/// rows to make room, keeps the page live without a second mode that
/// stops following the session.
pub const held_rows = 300

/// The Lustre event path of the lane's "Load older" button, on both pages:
/// the lane is the second child of the centre column, which is the third
/// child of the page's frame (`view/shell`), after the breadcrumb or the empty
/// node in its place; the line above its oldest row is the lane's first
/// child, and the button that line's first child. The page socket admits a
/// `click` from an observer at this path and no other event
/// (`client/daemon/ui_socket.observer_accepts`, protocol-change/051, the
/// addendum on history paging). `page_events_test` fails if the view moves
/// the button, so the two cannot drift apart.
pub const older_path = "0\t2\t1\t0\t0"

/// The Lustre event path of the strand panel's card list, on both pages: the
/// panel is the fourth and last child of the page's frame (`view/shell`); its
/// first child is the Strands pane, whose title is the pane's first child, the
/// strip's `nav` its second, and the `ul` of cards the `nav`'s first child.
/// The Changes and Session panes come after the Strands pane and hold no
/// handler. Every handler under the list is one card's button, which focuses
/// that card's strand, so the page socket admits a `click` from an observer at
/// any path beneath it and no other path but `older_path`
/// (`client/daemon/ui_socket.observer_accepts`, protocol-change/051, the
/// addendum on strand focus). A path beneath the list that names no button
/// finds no handler in the runtime and does nothing. `page_events_test` fails
/// if the view moves the panel or the buttons leave the list.
pub const strip_path = "0\t3\t0\t1\t0"

/// The Lustre event path of the sidebar, on the operator's page: the sidebar
/// is the second child of the page's frame (`view/shell`). Every handler
/// beneath it is one session row's button, which asks the daemon for a ticket
/// to open that session (protocol-change/051, the addendum on switching
/// sessions). Only the operator's page draws the sidebar, and the observer's
/// socket admits no click beneath this path
/// (`client/daemon/ui_socket.observer_accepts`), so an observer's browser
/// cannot ask for a switch even by forging the path. `session_switch_test`
/// and `sidebar_test` fail if the view moves the sidebar or a button leaves it.
pub const sidebar_path = "0\t1"

/// The Lustre event path of the invitation control, on an owner's page: it is
/// the third child of the Session pane (`view/session_tab`), after the pane's
/// title and its list, and the Session pane is the third child of the strand
/// panel, which is the fourth child of the page's frame (`view/shell`). Every
/// handler beneath it is one of the control's three buttons (protocol-change/051,
/// the addendum on inviting from the session page). The page socket admits a
/// `click` at or beneath this path only on a page whose principal is the
/// daemon's owner (`client/daemon/ui_socket.operator_accepts`), so a member
/// operator's browser and an observer's cannot press the control even by
/// forging the path, and the daemon refuses the request a third time
/// (`client/daemon/ui_socket.invite_for`). `invite_test` fails if the view
/// moves the control or a handler leaves the region.
pub const invite_path = "0\t3\t2\t2"

/// The Lustre event path of the rename control, on an owner's page: it is the
/// fifth child of the Session pane (`view/session_tab`), after the pane's
/// title, its list, the invitation control (`invite_path`) and the session
/// controls (`session_controls_path`), so that placing it there moved no path
/// the socket admits. The one handler beneath it is the form's submit
/// (protocol-change/067). The page socket admits a `submit` at or beneath this
/// path only on a page whose principal is the daemon's owner
/// (`client/daemon/ui_socket.operator_accepts`), as it does for the invitation
/// control, so a member operator's browser and an observer's cannot send one
/// even by forging the path, and the daemon refuses the request a third time
/// (`client/daemon/ui_socket.rename_for`). `rename_test` fails if the view
/// moves the control or a handler leaves the region.
pub const rename_path = "0\t3\t2\t4"

/// The Lustre event path of the operator's list of remembered permissions: the
/// sixth and last child of the Session pane (`view/session_tab`), after the
/// rename control (`rename_path`), so that placing it there moved no path the
/// socket admits. Every handler beneath it is one of the list's Forget buttons
/// or its question's two (`view/remembered`, protocol-change/073). The
/// operator's socket admits them like any click that is not an owner's control,
/// and an observer's socket admits none, the page drawing nothing there and
/// the daemon refusing a forget from an observer's attachment on its own.
/// `page_events_test` fails if the view moves the list.
pub const remembered_path = "0\t3\t2\t5"

/// The Lustre event path of the "Home" button, on both pages: it is the
/// second child of the top bar (`view/heading`), after the brand, and the top
/// bar is the first child of the page's frame (`view/shell`). The button is
/// drawn only on a page opened from a home, and its one handler asks the
/// daemon for a ticket to that home (protocol-change/065, the second pull
/// request). The observer's socket admits a `click` at exactly this path and
/// nowhere else beyond the two it always admitted
/// (`client/daemon/ui_socket.observer_accepts`), and the daemon decides again
/// whether the page's principal and ceiling may have a ticket
/// (`client/daemon/ui_socket.home_ticket_for`). `page_events_test` fails if
/// the view moves the button.
pub const home_path = "0\t0\t1"

/// The Lustre event path of the Refresh button in the context breakdown, on
/// both pages: the top bar's figures are its sixth child, the context figure
/// is the figures' first child (a `<details>`), its panel (`view/context_breakdown`)
/// the figure's second child, the panel's row of buttons the panel's first
/// child, and Refresh the row's first. The observer's socket admits a `click` at
/// exactly this path (`client/daemon/ui_socket.observer_accepts`), since the
/// button asks only for a fresh read of the board the page already draws, the
/// read its own lane makes at the end of every turn. The Compact now button is
/// the row's second child and is drawn only on the operator's page, where the
/// socket admits it like any click. `page_events_test` fails if the view moves
/// the button.
pub const context_refresh_path = "0\t0\t5\t0\t1\t0\t0"

/// The Lustre event path of the operator's session controls, the goal's
/// buttons and the Fork form: the fourth child of the Session pane, after the
/// invitation control (`invite_path`), so that placing it there moved no path
/// the socket admits. Every handler beneath it is a click or a submit of a
/// control (protocol-change/051, the addendum on the session controls'
/// placement). The operator's socket admits them like any click or submit
/// that is not the invitation's, and an observer's socket admits none, the
/// page drawing no control there. `page_events_test` fails if the view moves
/// the controls.
pub const session_controls_path = "0\t3\t2\t3"

/// How long the sidebar's list stands before the page reads it again, in
/// milliseconds of the transport's clock. The list changes when a session is
/// created, renamed, archived or opened, which is rare, and a read is a
/// catalogue query, so a page asks once when it opens and then no more than
/// once in this long. The read is made on a timer message the lane already
/// raises (`Ticked`), not on a timer of its own.
pub const sessions_refresh_ms = 30_000

/// How long the sidebar's activity words stand before the page reads them
/// again, in milliseconds of the transport's clock. The list changes rarely,
/// but a running session's state (working, idle, waiting on its owner) changes
/// within a turn, so the page asks for the activity of the rows it lists on
/// its own, faster cadence, and no more often than this. Like the list's read
/// it is made on a `Ticked` the lane already raises, so the interval is a
/// lower bound, and it runs in the daemon's own task and is bounded by
/// `sessions.activity_limit`. The page on screen needs none of it: its own row
/// is read from its lane (`session_activity`).
pub const activity_refresh_ms = 5000

/// How long a page waits between asks for the strand's live jobs, on the
/// transport's clock. An ask is made only when the page ticks, so the
/// interval is a lower bound and an idle page's ticks (five seconds apart)
/// set the real one.
pub const jobs_refresh_ms = 10_000

/// The most bytes of prompt text the page submits. The page socket's frame
/// limit bounds a whole message; this bounds the field inside it, so a
/// draft over it is refused with a notice before it becomes a command.
pub const prompt_limit = 262_144

/// What the host that starts the component supplies: the session it is
/// for, and the transport the lane's frames travel over.
pub type Start(socket) {
  Start(
    /// The canonical session identity. The heading carries it whole in a
    /// `title` and shows it shortened when the session has no name.
    session_id: String,
    /// What the daemon's catalogue says about the session, or `None` when
    /// the host could not read it.
    label: Option(Label),
    /// A digest of the canonical workspace path, which the daemon computes:
    /// the lower-case SHA-256 in hex, 64 digits. It is the page's storage
    /// identity. (Fixtures pass an empty string, which the frame leaves
    /// out.) The frame carries it
    /// as an attribute (`web_view/view/shell`) and `<loom-shell>` keeps the
    /// reader's layout under it, so two workspaces do not share a layout and
    /// a path is never an attribute or a storage key. It is an identity, not
    /// session text, and the page never draws it.
    workspace_digest: String,
    /// The attachment the lane must see on every captured cut. A cut for
    /// another session, epoch or incarnation fails the lane rather than
    /// being drawn.
    expected: snapshot.Expected,
    /// What the daemon knows about the page's principal and session that the
    /// capture does not carry.
    standing: Standing,
    /// The host's transport.
    transport: Transport(socket),
  )
}

/// What the host knows when it starts a page, beyond what the lane's capture
/// says: whether the page's principal is the daemon's owner, and whether the
/// session may be shared. Neither is session text, and the page draws only
/// fixed words from them.
pub type Standing {
  Standing(
    /// Who the page's principal is to the daemon. An observer-ceiling page
    /// opened by the owner is still the owner's, and its footer says so.
    reader: Reader,
    /// Whether the session was created to be shared, read from the catalogue
    /// for an owner's page and `None` where the page draws no invitation
    /// control or the host could not read it. A session known to be private
    /// draws no invitation buttons (`invites.Unshareable`).
    sharing: Option(creations.Sharing),
    /// How an owner's page was opened. A page a bookmark opened cannot mint
    /// access, so it is handed neither the invitation nor the make-shareable
    /// capability and draws a sentence in their place (`invites.Bookmarked`).
    opening: Opening,
  )
}

/// How the page was opened, for an owner's page that would otherwise draw the
/// invitation control.
pub type Opening {
  /// A `loom ui` exchange, a claim or a device link opened it, or it is not an
  /// owner's page. The capabilities, where the principal has them, are handed
  /// out.
  FromLink

  /// The page's principal is the owner and a bookmark opened the page, or a page
  /// a bookmark's home opened. Nothing that mints access is offered.
  FromBookmark
}

/// Who the page's principal is to the daemon.
pub type Reader {
  /// The daemon's owner.
  DaemonOwner

  /// Anyone else: a member the owner invited.
  Participant
}

/// A standing that says nothing: a member, and a session whose sharing was not
/// read. Fixtures and hosts with no catalogue start from it.
pub const unplaced =
  Standing(reader: Participant, sharing: None, opening: FromLink)

/// What the daemon's catalogue says about a session, for the page's
/// heading. Neither field comes from the session's transcript: the name is
/// the label the owner gave the session, and the workspace is the working
/// directory the host validated when the session was created.
pub type Label {
  Label(
    /// The session's display name, which may be empty.
    name: String,
    /// The canonical working directory the session runs in.
    workspace: String,
  )
}

/// The host's transport and clock.
///
/// Every function runs in the component's own process, which owns the
/// subjects `connect` is handed, so a reply is always read by the process
/// that created the subject it arrives on.
pub type Transport(socket) {
  Transport(
    /// Starts opening the connection and returns at once. Frames go to
    /// `inbox` as `connection_event.Message`s, and the outcome of the open
    /// is sent to `opened`, once: the handle the lane writes to, or why the
    /// connection was refused. It must not block, because it runs inside
    /// the component's start, which Lustre bounds at one second.
    connect: fn(
      Subject(connection_event.Message),
      Subject(Result(socket, String)),
    ) -> Nil,
    /// Writes one frame. It must not block on the peer.
    transmit: fn(socket, String) -> Nil,
    /// Closes the connection.
    shut: fn(socket) -> Nil,
    /// A monotonic reading in milliseconds, for the lane's deadlines. The
    /// component reads it once at the top of each message.
    now: fn() -> Int,
    /// Starts the read of the sessions the page's principal may see, for the
    /// sidebar, and returns at once: the daemon's authorized catalogue read
    /// for an operator's page, or an empty list when it fails or the page is
    /// an observer's. It is asked when the page opens and every
    /// `sessions_refresh_ms` after. The read runs in the daemon's own task,
    /// which calls the function it is given with the list, and that call is
    /// dispatched as `SessionsListed`; the page's runtime never waits for
    /// it, because the catalogue read is a registry call that can wait on a
    /// busy daemon for seconds, and a runtime that waited would hold every
    /// click and every patch behind it (protocol-change/051: the runtime
    /// never blocks).
    sessions: fn(fn(List(sessions.Entry)) -> Nil) -> Nil,
    /// Asks the daemon what the named running sessions are doing, for the
    /// sidebar's words and dots: the same read the home makes
    /// (`home.Start.activity`, protocol-change/050), for at most
    /// `sessions.activity_limit` identities the page's own list holds, and the
    /// daemon keeps only those the page's credential holds. It returns at
    /// once: the daemon asks from a task of its own and `deliver` is called
    /// from there with one state for each session that answered, so the page's
    /// runtime never waits for it. An observer's page lists nothing and asks
    /// nothing.
    activity: fn(List(String), fn(List(#(String, sessions.Activity))) -> Nil) ->
      Nil,
    /// Asks the daemon for a ticket to open the named session, for an
    /// operator's page that pressed its row: the daemon checks that the page's
    /// principal holds that session and that a process runs it, and mints a
    /// ticket with the page's own ceiling. It answers `Declined` for an
    /// observer's page without asking. It runs in the component's process
    /// when the operator presses a row, and it must not run long: the page's
    /// runtime waits for it.
    open: fn(String) -> sessions.Answer,
    /// Asks the daemon to resume the named saved session and mint a ticket for
    /// it, for an operator's page that pressed a saved row
    /// (protocol-change/065, the third pull request). The daemon checks the
    /// page's ceiling and the principal's role in that session, opens it, waits
    /// for it to become resident and mints a ticket with the page's own ceiling
    /// and deadline. It must return at once: the wait runs in the daemon's own
    /// task, which calls the function it is given with the answer, and that
    /// call is dispatched as `Linked`. It answers `Declined` for an observer's
    /// page without asking.
    resume: fn(String, fn(sessions.Answer) -> Nil) -> Nil,
    /// Asks the daemon to invite a person to this page's session, in a role
    /// the owner chose, for an owner's page that pressed one of the control's
    /// buttons: the daemon mints the same claim `loomd access invite` mints
    /// and answers with the command and the token, or the reason it did not.
    /// It is `None` unless the page's principal is the daemon's owner, and
    /// the daemon checks that again when it is called, so a page that has no
    /// capability draws no control and a page that has one cannot use it once
    /// its principal or its own standing has changed. It runs in the
    /// component's process, and it must not run long: the page's runtime
    /// waits for it.
    invite: Option(fn(invites.Role) -> invites.Answer),
    /// Asks the daemon for a ticket to the principal's home page, for a page
    /// that was opened from a home (protocol-change/065): the daemon mints it
    /// for the page's own principal, with the page's own ceiling and deadline,
    /// and answers with the exchange address or the reason it did not. It is
    /// `None` on a page a link for one session opened, which draws no way home
    /// and so offers no capability. The daemon checks the page again when this
    /// is called. It runs in the component's process, and it must not run
    /// long: the page's runtime waits for it.
    home: Option(fn() -> sessions.Answer),
    /// Asks the daemon to rename this page's own session, for an owner's page
    /// that submitted the rename control (protocol-change/067): the daemon
    /// checks that the page is open, that its credential still authenticates as
    /// the daemon's owner and that the name is one a display name may be, and
    /// then makes the registry's owner-checked rename. It must return at once:
    /// the daemon runs the request in a task of its own, which calls the
    /// function it is given with the answer, and that call is dispatched as
    /// `Renamed`. It is `None` unless the page's principal is the daemon's
    /// owner, and the daemon checks that again when it runs, so a page with no
    /// capability draws no control and a page that has one cannot use it once
    /// its principal or its own standing has changed.
    rename: Option(fn(String, fn(renames.Answer) -> Nil) -> Nil),
    /// Asks the daemon to make this page's session shareable, for an owner's
    /// page that confirmed the question its control asked (protocol-change/065,
    /// the addendum on making a session shareable): the daemon checks that the
    /// page is open and its principal is the owner, stops the session, moves it
    /// to its own history and resumes it, as one task that no page owns. It
    /// must return at once, because the task waits for a stop and a resume: the
    /// daemon calls the function it is given with the answer, and that call is
    /// dispatched as `MadeShareable`. It is `None` unless the page's principal is the
    /// daemon's owner, so a page with no capability draws no button and a page
    /// that has one cannot use it once its standing has changed. The session
    /// stopping ends this page, so the answer reaches it only when the task
    /// refused before the stop.
    shareable: Option(fn(fn(grants.Answer) -> Nil) -> Nil),
    /// Asks the daemon to observe the session's Git working tree for the
    /// Changes tab (protocol-change/051, the addendum on the worktree read). It
    /// must return at once: the daemon runs the observation in a task of its
    /// own, which calls the function it is given with the answer, and that call
    /// is dispatched as `Worktreed`. It is `None` for an observer's page, which
    /// is never shown worktree bytes. The daemon takes the session, the
    /// workspace and every bound from its own records and checks the page's
    /// standing again each time it is called, so a page whose grant was
    /// revoked is answered `Declined`.
    worktree: Option(fn(fn(worktrees.Read) -> Nil) -> Nil),
    /// Asks the daemon to stop, archive or stop-and-archive a session the
    /// sidebar lists, for an owner's page that confirmed the question the
    /// sidebar asked (protocol-change/065, the addendum on archiving from the
    /// sidebar). It is the home's capability (`Start.manage` there): `Some` only
    /// on an owner's operating page that a fresh `loom ui` exchange opened and
    /// that was minted for the whole workspace, and the daemon checks all of
    /// that again when it runs. It must return at once: the daemon runs the
    /// request in a task of its own, which calls the function it is given with
    /// the answer, and that call is dispatched as `ManageAnswered`.
    manage: Option(fn(actions.Action, String, fn(actions.Answer) -> Nil) -> Nil),
    /// Asks the daemon which of the browser sign-ins a remembered permission
    /// was allowed from have ended, for an operator's page that lists what the
    /// session remembers (protocol-change/073). It returns at once: the daemon
    /// asks the registry in a task of its own, which calls the function it is
    /// given with the logins that have ended, and that call is dispatched as
    /// `LoginsJudged`. A login the daemon could not judge, because the page's
    /// principal may not ask about another's or the registry did not answer, is
    /// not among them. It is `None` for an observer's page, which draws no list.
    logins: Option(
      fn(List(holding.Login), fn(List(holding.Login)) -> Nil) -> Nil,
    ),
  )
}

/// What the page says about the connection.
pub type Status {
  /// The transport is opening, or the first cut has not arrived.
  Connecting

  /// At least one validated cut has been drawn. This is the connection's
  /// state, and the heading words it "connected". It says nothing about
  /// where the reader is reading: whether the transcript follows its tail
  /// is known only in the browser (`<loom-follow>`), and the heading once
  /// said "following" for this, which read as the scroll state.
  Connected

  /// The connection ended, and the last drawn cut stays on the page. The
  /// page draws `ending`'s notice (`web_view/view/ended`) in its heading:
  /// the closed reason class, never the reason string a peer or a lane
  /// reported.
  Ended(ending: Ending)
}

/// What the page last told an operator about their own input.
///
/// The page draws outcomes only: what the session said when it ran the
/// operator's command, the daemon's reply to it, a prompt the daemon handed
/// back, and the page's own refusals. It does not draw the shared record's
/// `notice`, which the terminal shows in its footer and which any event
/// replaces, so a background read ("notes sent") or a stream ("streaming
/// text") would have spoken over the operator's own command. The words
/// stay until the operator's next input.
pub type Notice {
  /// Nothing to say.
  Quiet

  /// The outcome of the operator's last command, or of what became of it.
  Said(text: String)

  /// The page refused an input before it reached the session.
  Warned(text: String)
}

/// A prompt the daemon handed back unsent (protocol-change/038), which the
/// composer puts back in its editor.
pub type Returned {
  Returned(
    /// Its place in the order the daemon handed prompts back, from one.
    number: Int,
    /// What the operator had sent. Attachments do not come back with it.
    text: String,
  )
}

/// Whether the page's strand is running an operation.
pub type Activity {
  /// Nothing is running: a draft is sent as a prompt.
  Idle

  /// An operation is running: a draft is queued behind it or steers it.
  Busy
}

/// An operator's answer that the page offers.
///
/// Remembering a grant for the session was left out of the first operator page
/// (protocol-change/051, the operator addendum) because a remembered grant
/// outlives the page that gave it. protocol-change/073 offers it, with the
/// list of what is remembered and who allowed it beside it, so an owner can
/// see and forget what a page left behind.
pub type Answer {
  /// Grant the displayed authority for this one request.
  AllowOnce

  /// Grant it and remember it for the session. The card offers it only where
  /// the whole request is eligible (`approval.rememberable`), and `decide`
  /// asks again at the click.
  AllowForSession

  /// Refuse the request.
  Deny
}

/// What a control on an operator's page asks for: a command the terminal
/// runs from a typed draft, chosen by a button or a small form instead.
///
/// The controls act on the page's strand. Each is the same command a draft
/// names, run through the same shared step, so what the page may do here is
/// what a draft may do (`page_command`), and no control adds an operation.
/// Stop and pinning a goal were once here too, and left with their buttons:
/// the operator stops a strand from the terminal, and pins a goal by typing
/// `/goal ...` in the composer, which the page parses as a command.
pub type Control {

  /// `/goal pause`.
  PauseGoal

  /// `/goal resume`.
  ResumeGoal

  /// `/goal clear`.
  ClearGoal

  /// `/fork <name>`, with the name as the operator typed it.
  Fork(name: String)

  /// `/compact`, from the context breakdown's Compact now button.
  CompactStrand
}

/// How much of the strand's history the page holds. It only moves forward:
/// a page that has loaded older rows keeps the larger limit, and a page
/// that reached it stays full, unless the running turn alone crowded it.
pub type Paging {
  /// The newest `live_rows` rows; the reader has not asked for older ones.
  Tail

  /// The newest `held_rows` rows, since the reader asked for older ones.
  Paged

  /// The page held more than `held_rows` rows while paged, so it keeps the
  /// newest `held_rows` and loads no more.
  Full

  /// The running turn, drawn open with every row, took the room that older
  /// turns held, so the page keeps the newest `held_rows` and loads no more for
  /// now. The turn settles into one divider, and the page is `Paged` again.
  Crowded
}

// Whether rows older than the oldest one the page holds exist.
type Earlier {
  // The page holds the strand's first row.
  Reached

  // Older rows exist: the page cut them to its limit, or its history window
  // never held them.
  Unheld
}

// Whether the reader has asked for the turns older than the oldest the page
// holds and has not been given them yet.
type Asking {
  // Nothing was asked.
  Unasked

  // The reader pressed "Load older". The press is a want and not a command:
  // the page reads when it has no other read out, and asks nothing of the
  // browser's event beyond that it happened.
  Pressed
}

// What the history window's transient read is for. The page has one at a time,
// and the lane reads one thing at a time, so what the page wants next waits
// for the read that is out.
type Purpose {
  // No read is out.
  Resting

  // The turns below the oldest the page holds, after a press of "Load older".
  ForOlder

  // The start of the turn the window began inside, which the page needs
  // before it can draw that turn's divider with the right figures.
  ForLead

  // The strand's newest turn, when the window holds none of the strand's
  // records. A gateway's cut is the newest records of the whole session, so a
  // strand that another strand wrote past (the advisor reviewing a turn that
  // just settled) has its leaf below the cut, and there is nothing yet to draw
  // or to complete. The read starts at the leaf and walks down.
  ForTail

  // The newest steps of the fold with this number, which the reader opened.
  ForSteps(fold: Int)
}

// Whether a read for what the page lacks of the strand's newest turn may still
// be tried: the start of the window's first turn or, when the window holds none
// of the strand's records, the turn itself.
type Completion {
  // The read has not failed.
  Untried

  // The read failed, so the blocks are drawn as far as they are known, and a
  // window that holds none stays empty until the reader presses "Load older".
  Spent
}

// Whether the page has sent its one read of the session's decided approvals.
type Decided {
  // The read is owed: the lane has no cut yet, or the lane was busy.
  Owed

  // The read was sent, and its answer joins the approval ledger like a lookup.
  Asked
}

// The shared record with the web's handles bound: the component has no
// recorder and its two inboxes have no sources to tell apart, so all three
// are `Nil`.
type Session(socket) =
  Shared(socket, Nil, Nil, Nil)

// What the blocks and pieces were built from. `refreshed` builds them again
// only when one of these differs from what the session holds now.
type Projected {
  Projected(
    strand: String,
    captured: Option(#(snapshot.Captured, snapshot_view.View)),
    scrollback: history_view.State,
    notices: List(CacheNotice),
    agents: List(agent_view.Row),
    paging: Paging,
    folds: List(Int),
    older: Asking,
  )
}

// What the strip was built from. The roster's clock is left out: it moves on
// every tick, and the strip's elapsed figures are counted by the browser
// from the reading the strip was built at.
type Stripped {
  Stripped(
    followed: String,
    roster: agent_roster.Roster,
    cache: cache_watch.Ledger,
    agents: List(agent_view.Row),
    strands: List(protocol.Strand),
  )
}

// What only this host holds.
type View(socket) {
  View(
    label: Option(Label),
    workspace_digest: String,
    expected: snapshot.Expected,
    reader: Reader,
    transport: Transport(socket),
    /// How many rows the page holds. This is the page's own view state.
    paging: Paging,
    /// The folds the reader has open, as `turns.Work.id` numbers, the most
    /// recently opened first. A fold is open only on this page and only
    /// while its turn is held: `relaned` drops the numbers of turns that
    /// left the page, and the oldest-opened fold when opening another would
    /// push the page past its row limit (`fold_budget`). The steps of an
    /// open fold of a closed turn are in `steps` once they have been read.
    folds: List(Int),
    /// The block keys of the shortened messages the reader has open, the most
    /// recently opened first and at most `open_messages`. A message is open
    /// only on this page, and the text is drawn only while it is: the lane
    /// reads the whole text from the entry its block holds. A strand the
    /// reader leaves forgets them.
    said: List(String),
    /// The `paging` of each strand the reader left, keyed by strand name,
    /// for the life of the page. `focus` parks the departing strand's here
    /// and restores the arriving strand's, so a strand whose older rows the
    /// reader loaded is still held at that depth when they come back. The
    /// key is a name the session lists and is never drawn.
    parked_paging: Dict(String, Paging),
    /// The number the page gave each strand it has shown, from 1, in the order
    /// it first showed them. The lane draws it as `data-strand-key`, which
    /// `<loom-follow>` keeps the reader's scroll place under. A counter and
    /// not a digest of the name: it cannot collide, and a name a peer chose
    /// never reaches the attribute.
    strand_keys: Dict(String, Int),
    /// Whether older rows than the page holds exist, derived with `pieces`.
    earlier: Earlier,
    /// The turns the page has closed, newest first. Each is what the page
    /// draws of a settled turn and where to find its records again, and the
    /// records themselves are not held (`session_view/turn_ledger`). They are
    /// older than every record of the history window, and the newest one's
    /// last record is where the window starts.
    sealed: List(turn_ledger.Sealed),
    /// The steps of each open fold of a closed turn, by the fold's number,
    /// read when the fold was opened and dropped when it closes.
    steps: Dict(Int, turn_ledger.Steps),
    /// What the window's transient read is for, if one is out.
    purpose: Purpose,
    /// Whether the reader has asked for turns the page has not read yet.
    older: Asking,
    /// Whether the read for the start of the window's first turn may still be
    /// tried.
    completion: Completion,
    /// `Reached` once a read found nothing below the page's oldest turn, which
    /// says the strand has no more even where its last record names a parent.
    floor: Earlier,
    /// The closed turns of each strand the reader left, by the strand's name,
    /// for the life of the page, as `parked_paging` is kept: the history
    /// window of a parked strand has been trimmed to what the closed turns do
    /// not hold, so returning to it restores both together.
    parked_sealed: Dict(String, List(turn_ledger.Sealed)),
    /// The page strand's transcript blocks of the window that the page draws,
    /// the turns still moving, projected once when a capture, a page of
    /// history or a cache notice arrived, so a message which changed none of
    /// them costs the view no projection. The closed turns' blocks are not
    /// held.
    blocks: List(transcript_lines.Block),
    /// The turns the page draws (`session_view/turns`): the closed turns, from
    /// their summaries, and then the window's blocks laid out, derived
    /// with them.
    pieces: List(turns.Piece),
    /// The inputs `blocks` and `pieces` were derived from.
    projected: Projected,
    /// The edits the held window carries (`session_view/changes_view`),
    /// folded when the projection is built, so a message that changed none
    /// of its inputs costs the Changes section no fold.
    changes: changes_view.Board,
    /// What the page knows of the workspace's Git tree, for the Changes tab,
    /// whether a read is out, when the last one was asked on the transport's
    /// clock, and the sequence of the newest tool result the page had seen when
    /// it asked (`worktrees`). A newer one in the records is the reason to
    /// ask again.
    worktree: worktrees.Read,
    asking: worktrees.Asking,
    worktree_asked_at: Option(Int),
    worktree_seen: Int,
    /// The sequence of the newest tool result the held records carry, derived
    /// with `changes`.
    latest_result: Int,
    /// The `code_mode` programs the held window carries
    /// (`session_view/trace_view`), folded with `changes` for the same
    /// reason.
    trace: trace_view.Trace,
    /// The live answers the page draws (`live`): the shared record's
    /// streams for the followed strand, and after a pushed entry clears
    /// them, the last ones until a capture holds the entry
    /// (`streamed`).
    streams: List(Stream),
    /// The agent strip, derived when a capture, a usage push or a tick
    /// changed something it draws.
    strip: strip.Strip,
    /// The inputs `strip` was derived from.
    stripped: Stripped,
    status: Status,
    /// The sidebar's groups, from the last read of the principal's
    /// sessions, and when that read was asked for on the transport's clock,
    /// so the next one waits `sessions_refresh_ms`.
    groups: List(sessions.Group),
    listed_at: Option(Int),
    /// What the sidebar's running sessions were last said to be doing, by
    /// identity. It is asked for after each read of the list and again every
    /// `activity_refresh_ms`, and a session with no answer says "running".
    /// The page's own session is never read from here (`session_activity`).
    activity: dict.Dict(String, sessions.Activity),
    /// When the activity was last asked for on the transport's clock, so the
    /// next ask on a `Ticked` waits `activity_refresh_ms`.
    activity_asked_at: Option(Int),
    /// The ticket exchange the daemon minted for the session the operator
    /// chose, which `<loom-switch>` navigates to. It stays until the next
    /// switch replaces it: the ticket is single use and lives 60 seconds, so
    /// a value left behind is spent.
    departure: Option(String),
    /// The saved session whose resume is out, if one is. It is set when a press
    /// asks the daemon and cleared by the answer, so a second press while it is
    /// set asks nothing and the sidebar draws that row as opening.
    resuming: Option(String),
    /// What the invitation control is doing. It is the one place the page
    /// holds a claim token, only while the invitation is on screen, and the
    /// state is replaced when the owner dismisses it.
    share: invites.Share,
    /// What the control that makes a private session shareable is doing. The
    /// question it asks before it starts lives here and nowhere else.
    moving: shareables.Move,
    /// Where the sidebar's archive action stands: the one row that is asking
    /// or waiting on the daemon (`view/archiving`).
    archiving: actions.Stage,
    /// What the rename control is doing, and how many renames have succeeded,
    /// which keys the control's form so a successful one is replaced by an empty
    /// form.
    renaming: renames.Control,
    renamed: Int,
    /// When the page opened or last asked for the strand's live jobs, on the
    /// transport's clock, so the next ask waits `jobs_refresh_ms` whether or
    /// not the daemon answered. A refused read is therefore not repeated on
    /// every tick.
    jobs_asked_at: Option(Int),
    /// Whether the page has asked for the session's decided approvals. A page
    /// that opens after a decision never saw the request pending, so it reads
    /// the decisions once its first cut is adopted and seeds the approval
    /// ledger the transcript's decision rows come from.
    decided: Decided,
    /// What the page holds about the list of remembered permissions beyond the
    /// board itself: when it last wanted it, the question that is open and the
    /// sign-ins the daemon said have ended (`web_view/remembered`).
    holding: holding.State,
    /// What the page refused to send, until the operator's next input.
    refusal: Option(String),
    /// How many composer submits were refused with the draft kept, by the
    /// page (`refused_draft`) or by the lane's admission check
    /// (`submitting`); a refusal of anything but the composer's draft is
    /// not counted. The
    /// composer's element reads it as the `refused` attribute, so a pending
    /// line it drew for a press can be taken down and the draft put back
    /// (`web_client/pending_rule`); a taken draft replaces the editor instead.
    refusals: Int,
    /// What the session said when the page ran the operator's last command:
    /// the notice the shared step left, read at once because any later event
    /// may write it over. Empty when the command said nothing. The daemon's
    /// later reply to that command is `Shared.answer`, and the two are what
    /// `notice` draws.
    outcome: String,
    /// How many entries the composer's element has been offered since the
    /// page opened, and all of them, oldest first. An entry is a prompt the
    /// daemon handed back to this page's strand, or the start of a reply the
    /// operator asked for (`reply`). None is dropped: a returned prompt is its
    /// last copy, and the element takes entries in a frame that does not run
    /// in a background tab, so any cap could lose one before it is read. The
    /// list is bounded by the daemon's held queue and by how often the
    /// operator presses a Reply button. The composer's element puts each in the editor once, by its
    /// number. The shared record holds a returned prompt only until the next
    /// step forgets it (`step.forget_surfaces`), so it is taken here at the
    /// end of every message.
    returns: Int,
    returned: List(Returned),
    /// How many drafts a command consumed at dispatch. A draft a prompt
    /// carries is consumed when the lane sends it, which the shared record
    /// counts as `drafts_sent`; the composer's editor is keyed by the sum,
    /// so a consumed draft is replaced by an empty editor while a refused
    /// one stays as the operator left it.
    consumed: Int,
    /// How many times the composer's notice has changed. The notice is keyed
    /// by it, so each new notice is a new element and the stylesheet's fade
    /// starts afresh for it, while a refresh that leaves the words alone does
    /// not restart the fade of the ones on screen.
    noticed: Int,
    /// The strand each approval request was raised on, by the request's
    /// identity, as the captures saw it while the request was pending. The
    /// approval ledger's summary of a decided request keeps no scope, so the
    /// decision's line (`decisions.from_ledger`) reads the strand from here.
    /// It holds the newest sixty-four.
    raised: List(#(String, String)),
    /// How many of the controls' forms have sent a command. The forms are
    /// keyed by it, so a form that sent is replaced by a closed, empty one
    /// while a refused one keeps what the operator typed.
    sent_forms: Int,
    /// The timer's subject, once the tick selector is armed.
    timer: Option(Subject(Nil)),
    /// The one timer armed for the lane's next due reading, kept so the
    /// next arming can cancel it.
    armed: Option(process.Timer),
  )
}

/// The component's state: the shared session record and what only this host
/// holds.
pub opaque type Model(socket) {
  Model(shared: Session(socket), view: View(socket))
}

/// Everything the component can be told.
pub type Msg(socket) {
  /// The transport opened.
  Opened(socket: socket)

  /// The transport refused to open.
  Refused(reason: String)

  /// The deadline timer's selector is armed on this subject.
  TimerArmed(timer: Subject(Nil))

  /// The frames the transport delivered, oldest first. One message carries a
  /// whole burst, up to `arrival_batch` frames, and it is reduced at once.
  Arrived(messages: List(connection_event.Message))

  /// The timer armed for the lane's next due reading fired.
  Ticked

  /// The lane's "Load older" button was pressed. It asks for a read of
  /// older history and nothing else (`older`), which is why an observer's
  /// page may carry it (protocol-change/051, the addendum on history
  /// paging). It is the one message a browser can send an observer's page.
  OlderRequested

  /// The divider of a settled turn's work was pressed: open the fold if it
  /// is closed, close it if it is open. The fold is named by the number the
  /// view drew the handler with (`turns.Work.id`), never by anything the
  /// browser sent, because a handler's message is fixed when the tree is
  /// drawn and the event names only the path it fired at. A number that
  /// names no fold the page holds changes nothing. Like `OlderRequested` it
  /// may start a read of the turn's steps on the page's own lane and sends no
  /// command, so an observer's page may carry it (protocol-change/070 and
  /// 071).
  FoldToggled(fold: Int)

  /// The button after a shortened message was pressed: open the message to its
  /// whole text if it is shortened, shorten it again if it is open. The
  /// message is named by its block's key, which the engine gave it and the view
  /// drew into the handler (`turns.Piece`'s block), never by anything the
  /// browser sent. A key that names no shortened message the page holds
  /// changes nothing. The text is read from the entry the block was drawn
  /// from, so the press reads nothing and sends no command, and an observer's
  /// page may carry it (`message_click`, protocol-change/070, the addendum on
  /// messages).
  MessageToggled(key: String)

  /// A chip of the agent strip was pressed: show this strand and address it.
  /// The strand is the name the strip was drawn with, never text the browser
  /// sent, because a handler's message is fixed when the tree is drawn and
  /// the event names only the path it fired at. It changes which strand the
  /// page reads and draws, and sends no command, so an observer's page may
  /// carry it (protocol-change/051, the addendum on strand focus).
  FocusRequested(strand: String)

  /// The context breakdown's Refresh button was pressed: read the board again.
  /// It carries nothing and sends no command, only the read the page makes at
  /// the end of every turn, so an observer's page may carry it
  /// (protocol-change/075).
  ContextRefreshRequested

  /// The "Home" button was pressed. It carries nothing: the daemon mints a
  /// ticket for this page's own principal, so the press cannot name a place
  /// to go. It is the second message a browser can send an observer's page,
  /// and the button exists only on a page opened from a home
  /// (protocol-change/065).
  GoingHome

  /// The sidebar's read of the principal's sessions answered. It is the
  /// effect's own message, dispatched from the component's process, and no
  /// handler carries it, so a browser cannot send one.
  SessionsListed(entries: List(sessions.Entry))

  /// The daemon's answer to the activity read a list started: one state for
  /// each running session that answered. Like `SessionsListed` it is the
  /// effect's own message, dispatched from the daemon's task, and no handler
  /// carries it.
  ActivityObserved(rows: List(#(String, sessions.Activity)))

  /// The daemon judged which browser sign-ins a remembered permission came
  /// from have ended. It is the effect's own message, dispatched from the
  /// daemon's task, and no handler carries it, so a browser cannot send one
  /// and cannot mark a sign-in ended or standing.
  LoginsJudged(ended: List(holding.Login))

  /// The daemon asks for one of the images the page draws, to answer a
  /// request for its address (protocol-change/051, the addendum on images).
  /// `ref` and `position` are the name and place the page drew the image
  /// at, and the reply is the image if the lane holds one there and
  /// `Error(Nil)` if it does not. It reads the lane and changes nothing, so
  /// an observer's page has it. It is sent from the daemon's side of the
  /// socket with `lustre.dispatch`, and no handler carries it, so no browser
  /// frame can produce one.
  ImageRequested(ref: String, position: Int, reply: Subject(Result(Image, Nil)))

  /// The daemon answered a request to open another session. It is the
  /// effect's own message, dispatched from the component's process, and no
  /// handler carries it, so a browser cannot send one.
  Linked(answer: sessions.Answer)

  /// The daemon answered a request to go home. Like `Linked` it is the
  /// effect's own message and no handler carries it.
  Homed(answer: sessions.Answer)

  /// The daemon answered a request to invite. It is the effect's own
  /// message, dispatched from the component's process, and no handler
  /// carries it, so a browser cannot send one and cannot put a token in the
  /// page.
  Invited(answer: invites.Answer)

  /// The daemon answered a request to rename the page's session. It is the
  /// effect's own message, dispatched from the daemon's task, and no handler
  /// carries it, so a browser cannot send one and cannot put a name in the page
  /// that the daemon did not store.
  Renamed(answer: renames.Answer)

  /// The daemon answered a request to make the page's session shareable. It is
  /// the effect's own message, dispatched from the daemon's task, and no handler
  /// carries it, so a browser cannot send one and cannot make the page believe
  /// the session can be shared when the daemon did not say so.
  MadeShareable(answer: grants.Answer)

  /// The daemon answered a request to observe the workspace. It is the
  /// effect's own message, dispatched from the daemon's task, and no handler
  /// carries it, so a browser cannot send one and cannot put a diff in the
  /// page that the daemon did not observe. The read is `Seen`, `Declined` or
  /// `Unreadable`.
  Worktreed(read: worktrees.Read)

  /// The daemon answered a request to archive a sidebar row. It is the
  /// effect's own message, dispatched from the daemon's task, and no handler
  /// carries it, so a browser cannot send one and cannot make the page believe
  /// a session was archived when the daemon did not say so.
  ManageAnswered(answer: actions.Answer)
}

/// The Lustre application for one session's observer page.
///
/// ## Examples
///
/// ```gleam
/// // lustre.start_server_component(component.app(), start)
/// ```
pub fn app() -> lustre.App(Start(socket), Model(socket), Msg(socket)) {
  lustre.application(init, update, view)
}

/// A component for `start`, before the transport opens: `init` without its
/// effects, for a test that drives the component through `simulate`.
///
/// ## Examples
///
/// ```gleam
/// // simulate.application(fn(s) { #(component.new(s), effect.none()) }, ..)
/// ```
pub fn new(start: Start(socket)) -> Model(socket) {
  let shared =
    step.new(
      primary,
      start.session_id,
      msg.Stamp(now_ms: 0, transport_ms: 0),
      inbox.new(Nil),
      inbox.new(Nil),
    )
  Model(
    shared:,
    view: View(
      label: start.label,
      workspace_digest: start.workspace_digest,
      expected: start.expected,
      reader: start.standing.reader,
      transport: start.transport,
      paging: Tail,
      folds: [],
      said: [],
      parked_paging: dict.new(),
      strand_keys: dict.from_list([#(shared.active_strand, 1)]),
      earlier: Reached,
      sealed: [],
      steps: dict.new(),
      purpose: Resting,
      older: Unasked,
      completion: Untried,
      floor: Unheld,
      parked_sealed: dict.new(),
      blocks: [],
      pieces: [],
      projected: projected_of(shared, Tail, [], Unasked),
      changes: changes_view.empty(),
      worktree: case start.transport.worktree {
        Some(_) -> worktrees.Unread
        None -> worktrees.Withheld
      },
      asking: worktrees.Idle,
      worktree_asked_at: None,
      worktree_seen: -1,
      latest_result: 0,
      trace: trace_view.empty(),
      streams: [],
      strip: strip.Strip(
        chips: [],
        advisor: None,
        settled: [],
        earlier: 0,
        followed: primary,
      ),
      stripped: stripped_of(shared),
      status: Connecting,
      groups: [],
      listed_at: None,
      activity_asked_at: None,
      activity: dict.new(),
      departure: None,
      resuming: None,
      share: case
        start.transport.invite,
        start.standing.sharing,
        start.standing.opening
      {
        None, Some(creations.Private), FromBookmark -> invites.BookmarkedPrivate
        None, Some(creations.Shareable), FromBookmark
        | None, None, FromBookmark
        -> invites.Bookmarked
        Some(_), Some(creations.Private), _ -> invites.Unshareable
        Some(_), Some(creations.Shareable), _ | Some(_), None, _ ->
          invites.Ready
        None, _, FromLink -> invites.Withheld
      },
      moving: case start.transport.shareable, start.standing.sharing {
        Some(_), Some(creations.Private) -> shareables.Idle
        Some(_), Some(creations.Shareable) | Some(_), None | None, _ ->
          shareables.Withheld
      },
      archiving: actions.Calm,
      renaming: case start.transport.rename {
        Some(_) -> renames.Ready
        None -> renames.Withheld
      },
      renamed: 0,
      jobs_asked_at: None,
      decided: Owed,
      holding: holding.new(),
      refusal: None,
      refusals: 0,
      outcome: "",
      returns: 0,
      returned: [],
      consumed: 0,
      noticed: 0,
      raised: [],
      sent_forms: 0,
      timer: None,
      armed: None,
    ),
  )
}

/// The component's first state and the two subscriptions it runs for its
/// life: the connection, and the deadline timer.
///
/// ## Examples
///
/// ```gleam
/// // lustre.application(component.init, component.update, component.view)
/// ```
pub fn init(start: Start(socket)) -> #(Model(socket), Effect(Msg(socket))) {
  let model = new(start)
  #(model, effect.batch([open(start.transport), arm()]))
}

// Opens the transport inside the component's process, once. The inbox and
// the subject the outcome arrives on are both created here, in the
// component's process, so every frame and the open's answer are read by
// the process that owns them. `connect` returns at once; the answer is a
// message, so a slow gateway attach cannot hold the component's start.
//
// A frame's mapping drains the inbox behind it, so a burst that is already
// waiting becomes one message and one render. Neither mapping reads the
// clock: `update` does, once, when it takes the message.
fn open(transport: Transport(socket)) -> Effect(Msg(socket)) {
  use _dispatch, opened <- server_component.select
  let inbox = process.new_subject()
  transport.connect(inbox, opened)
  process.new_selector()
  |> process.select_map(opened, fn(outcome) {
    case outcome {
      Ok(socket) -> Opened(socket)
      Error(reason) -> Refused(reason)
    }
  })
  |> process.select_map(inbox, fn(first) {
    Arrived([first, ..waiting(inbox, arrival_batch - 1, [])])
  })
}

// Up to `room` messages already in the inbox, oldest first, without waiting
// for any.
fn waiting(
  inbox: Subject(connection_event.Message),
  room: Int,
  taken: List(connection_event.Message),
) -> List(connection_event.Message) {
  case room > 0 {
    False -> list.reverse(taken)
    True ->
      case process.receive(inbox, 0) {
        Ok(message) -> waiting(inbox, room - 1, [message, ..taken])
        Error(Nil) -> list.reverse(taken)
      }
  }
}

// Creates the deadline timer's subject. Nothing is armed here: the lane
// says when it is next due once it exists.
fn arm() -> Effect(Msg(socket)) {
  use dispatch, timer <- server_component.select
  dispatch(TimerArmed(timer))
  process.new_selector()
  |> process.select_map(timer, fn(_) { Ticked })
}

/// Applies one message.
///
/// The transport's clock is read here, once, and every step the message
/// takes runs at that reading. An operator's command arrives through
/// `submit` and `decide` instead, which read the clock the same way.
///
/// ## Examples
///
/// ```gleam
/// // let #(model, effect) = component.update(model, component.Ticked)
/// ```
pub fn update(
  model: Model(socket),
  message: Msg(socket),
) -> #(Model(socket), Effect(Msg(socket))) {
  let at = model.view.transport.now()
  case message {
    // The lane starts with its subscribe in flight, and anything filed
    // before it existed is handed to it at once, in arrival order, by the
    // tick that follows.
    Opened(socket:) -> {
      let lane = session_channel.start(socket, model.view.expected, now: at)
      let shared =
        Shared(..model.shared, peer: session_model.Attached)
        |> session_model.hold_channel(lane)

      // The jobs clock starts here, so the first tick-driven ask comes one
      // `jobs_refresh_ms` after the page opens, behind the reads a first
      // capture starts. The terminal asks for jobs only when a jobs surface
      // opens, and the two hosts' lanes must stay in one engine state
      // through the startup reads.
      let view = View(..model.view, jobs_asked_at: Some(at))
      stepping(Model(shared:, view:), [tick_at(at)], at)
      |> relisted(at)
    }

    // The relay could not attach. Whatever the gateway said is not drawn:
    // a reason that names no ending stands for a session that is not open.
    Refused(reason:) -> #(
      Model(
        ..model,
        view: View(
          ..model.view,
          status: Ended(ending.from_reason(reason, otherwise: ending.NotOpen)),
        ),
      ),
      effect.none(),
    )

    // The timer's subject can be ready after the lane opened, since the
    // open's answer comes from another process, so the first arming may
    // happen here.
    TimerArmed(timer:) -> #(
      rearm(Model(..model, view: View(..model.view, timer: Some(timer))), at),
      effect.none(),
    )

    // A batch is filed behind anything still held and reduced now. One
    // message is one render, so the whole batch costs one.
    Arrived(messages:) ->
      stepping(
        model,
        [
          msg.Arrived(list.map(messages, msg.Frame(Nil, _))),
          tick_at(at),
        ],
        at,
      )

    // The lane's due reading passed: its tick acts.
    Ticked ->
      stepping(jobs_wanted(model, at), [tick_at(at)], at)
      |> relisted(at)
      |> reobserved(at)

    OlderRequested -> older_at(model, at)

    ContextRefreshRequested -> context_refresh_at(model, at)

    FoldToggled(fold:) -> folded_at(model, fold, at)

    MessageToggled(key:) -> #(messaged(model, key), effect.none())

    FocusRequested(strand:) -> focus_at(model, strand, at)

    GoingHome -> going_home(model)

    // The sidebar's list is the catalogue's own order and the page groups it,
    // at most `listed_limit` sessions. Nothing about the lane moved. The read
    // that follows counts as the activity's latest ask, so the next `Ticked`
    // does not ask a second time.
    SessionsListed(entries:) -> {
      let groups = sessions.grouped(list.take(entries, sessions.listed_limit))
      #(
        Model(
          ..model,
          view: View(..model.view, groups:, activity_asked_at: Some(at)),
        ),
        observing(model.view.transport, groups),
      )
    }

    // What the running sessions are doing replaces the last answer. The page
    // draws a word and a dot from it and nothing else moves.
    ActivityObserved(rows:) -> #(
      Model(..model, view: View(..model.view, activity: dict.from_list(rows))),
      effect.none(),
    )

    // Which sign-ins have ended is the page's own state, drawn as a note under
    // the permissions that came from them, and it changes nothing the lane
    // holds.
    LoginsJudged(ended:) -> #(
      Model(
        ..model,
        view: View(
          ..model.view,
          holding: holding.judged(model.view.holding, ended),
        ),
      ),
      effect.none(),
    )

    // The answer is read from the pieces the page draws, so an image is
    // served only where the page shows one, and it is sent from an effect so
    // that the update stays a function of the model.
    ImageRequested(ref:, position:, reply:) -> #(
      model,
      answering(reply, turns.picture(model.view.pieces, ref, position)),
    )

    Linked(answer:) -> #(
      linked(model, answer, saying: "Opening that session."),
      effect.none(),
    )

    Homed(answer:) -> #(
      linked(model, answer, saying: "Going to the home page."),
      effect.none(),
    )

    Invited(answer:) -> #(invited(model, answer), effect.none())

    Renamed(answer:) -> #(renamed(model, answer), effect.none())

    MadeShareable(answer:) -> #(made_shareable(model, answer), effect.none())

    ManageAnswered(answer:) -> archive_answered(model, answer)

    // The observation is the page's own state and changes nothing the lane
    // holds. The next read waits for a newer tool result, so this asks for
    // nothing.
    //
    // A throttled read keeps the last answer on the page and forgets which
    // tool result it covered, so the next ask comes after the usual interval.
    // Any other answer, a refusal included, replaces what is drawn.
    Worktreed(read: worktrees.Throttled) -> #(
      Model(
        ..model,
        view: View(..model.view, asking: worktrees.Idle, worktree_seen: -1),
      ),
      effect.none(),
    )

    Worktreed(read:) -> #(
      Model(
        ..model,
        view: View(..model.view, worktree: read, asking: worktrees.Idle),
      ),
      effect.none(),
    )
  }
}

// Hands the daemon's request for an image the answer the lane gave.
fn answering(
  reply: Subject(Result(Image, Nil)),
  found: Result(Image, Nil),
) -> Effect(Msg(socket)) {
  use _ <- effect.from
  process.send(reply, found)
}

// The daemon's answer to a request to open another session. A ticket becomes
// the address `<loom-switch>` navigates to. A refusal is shown in the
// composer's notice in the fixed words for its reason, and a switch that
// succeeded says `saying` in the same place until the browser has left. The
// answer to a request to go home is folded in the same way as the answer to
// a request to open a session: both end in one navigation.
fn linked(
  model: Model(socket),
  answer: sessions.Answer,
  saying saying: String,
) -> Model(socket) {
  case answer {
    sessions.Ticketed(path:) ->
      Model(
        ..model,
        view: View(
          ..model.view,
          departure: Some(path),
          resuming: None,
          refusal: None,
          outcome: saying,
        ),
      )
    sessions.Declined(reason:) ->
      Model(
        ..model,
        view: View(
          ..model.view,
          resuming: None,
          refusal: Some(sessions.reason_words(reason)),
          outcome: "",
        ),
      )
  }
}

// Asks for the sidebar's list when the page has never asked, or last asked
// `sessions_refresh_ms` or more ago, and otherwise leaves the message's result
// as it is. The answer arrives as `SessionsListed`. Only `Opened` and
// `Ticked` come here: a batch of frames is the busiest message a page takes
// and has no reason to read the catalogue.
fn relisted(
  done: #(Model(socket), Effect(Msg(socket))),
  at: Int,
) -> #(Model(socket), Effect(Msg(socket))) {
  let #(model, effects) = done
  case model.view.listed_at {
    Some(before) if at - before < sessions_refresh_ms -> done
    Some(_) | None -> #(
      Model(..model, view: View(..model.view, listed_at: Some(at))),
      effect.batch([effects, listing(model.view.transport)]),
    )
  }
}

// Asks for the activity of the sidebar's running sessions again when the last
// ask was `activity_refresh_ms` or more ago, so a row's word follows its
// session within seconds and not on the list's thirty. A page that has no
// list asks nothing. Only `Ticked` comes here, and the answer arrives as
// `ActivityObserved` from the daemon's task, so the runtime waits on nothing.
fn reobserved(
  done: #(Model(socket), Effect(Msg(socket))),
  at: Int,
) -> #(Model(socket), Effect(Msg(socket))) {
  let #(model, effects) = done
  let due = case model.view.activity_asked_at {
    Some(before) -> at - before >= activity_refresh_ms
    None -> True
  }
  case due, model.view.groups {
    True, [_, ..] -> #(
      Model(..model, view: View(..model.view, activity_asked_at: Some(at))),
      effect.batch([effects, observing(model.view.transport, model.view.groups)]),
    )
    True, [] | False, _ -> done
  }
}

// Marks the strand's live jobs as wanted when the page opened or last asked
// `jobs_refresh_ms` or more ago, and no answer is outstanding. The
// shared step sends the read once the lane is ready for it
// (`surfaces.service_jobs_read`), so this only says that one is owed. The
// read is `live_jobs`, a read the gateway allows every role, and its answer
// is a snapshot the lane folds like any other, so it adds no event.
fn jobs_wanted(model: Model(socket), at: Int) -> Model(socket) {
  let due = case model.view.jobs_asked_at {
    Some(before) -> at - before >= jobs_refresh_ms
    None -> True
  }
  case due, model.shared.jobs_awaiting {
    True, None ->
      Model(
        shared: Shared(..model.shared, jobs_refresh: worktree_view.Requested),
        view: View(..model.view, jobs_asked_at: Some(at)),
      )
    True, Some(_) | False, _ -> model
  }
}

// Starts the activity read for the running sessions the sidebar lists, in the
// order it draws them and no more than the home's bound, and returns at once;
// the answer arrives later as `ActivityObserved`, dispatched from the daemon's
// task. A list with no running session asks nothing.
fn observing(
  transport: Transport(socket),
  groups: List(sessions.Group),
) -> Effect(Msg(socket)) {
  let running =
    list.flat_map(groups, fn(group) { group.entries })
    |> list.filter(fn(entry) { entry.residency == sessions.Live })
    |> list.take(sessions.activity_limit)
    |> list.map(fn(entry) { entry.id })
  case running {
    [] -> effect.none()
    [_, ..] -> {
      use dispatch <- effect.from
      transport.activity(running, fn(rows) { dispatch(ActivityObserved(rows)) })
    }
  }
}

// Starts the read and returns. The transport's task hands the list back
// through `dispatch`, which sends the runtime a message from whichever
// process the task runs in, so the effect holds the runtime for no longer
// than the start of a task.
fn listing(transport: Transport(socket)) -> Effect(Msg(socket)) {
  use dispatch <- effect.from
  transport.sessions(fn(entries) { dispatch(SessionsListed(entries)) })
}

// The step's tick at `at`. The two readings are the same one because the
// component has one clock, for the lane's deadlines and for the shared
// record's elapsed times alike.
fn tick_at(at: Int) -> msg.Msg(Nil) {
  msg.Input(at: stamp(at), event: msg.Ticked)
}

fn stamp(at: Int) -> msg.Stamp {
  msg.Stamp(now_ms: at, transport_ms: at)
}

// Runs `messages` through the shared step in order, collecting the effects
// each decided, and finishes the message.
fn stepping(
  model: Model(socket),
  messages: List(msg.Msg(Nil)),
  at: Int,
) -> #(Model(socket), Effect(Msg(socket))) {
  let #(shared, effects) =
    list.fold(messages, #(model.shared, []), fn(done, message) {
      let #(shared, effects) = step.update(done.0, message)
      #(shared, list.append(done.1, effects))
    })

  // The decided-approvals read is asked once the messages have left the lane
  // idle, and the tick that follows it carries the frame out, so the read
  // leaves in the message that freed the lane and not in some later one.
  let owed = model.view.decided
  let model = decisions_read(Model(..model, shared:), at)
  let #(shared, effects) = case owed, model.view.decided {
    Owed, Asked -> {
      let #(shared, sent) = step.update(model.shared, tick_at(at))
      #(shared, list.append(effects, sent))
    }
    Owed, Owed | Asked, _ -> #(model.shared, effects)
  }
  finished(Model(..model, shared:), effects, at)
}

// Sends the one read of the session's decided approvals, once the lane has
// adopted a cut and has no request out. A busy lane refuses it, and the read
// stays owed for the next message to ask again; only a sent read is spent.
// The read never waits in the lane's queue, which would hold the slot an
// operator's first command needs. The frame leaves with the step the message
// is about to run.
fn decisions_read(model: Model(socket), at: Int) -> Model(socket) {
  case model.view.decided, model.shared.channel {
    Owed, Some(lane) ->
      case session_channel.decided(lane, now: at) {
        Ok(lane) ->
          Model(
            shared: session_model.hold_channel(model.shared, lane),
            view: View(..model.view, decided: Asked),
          )
        Error(_) -> model
      }
    Owed, None | Asked, _ -> model
  }
}

// The end of every message: what the page draws is derived from the record
// the step left, the page's own read is sent if it wants one, the deadline
// timer is armed for the lane's next due reading, and the effects the step
// decided are performed as one.
fn finished(
  model: Model(socket),
  effects: List(step_effect.Effect(socket, Nil)),
  at: Int,
) -> #(Model(socket), Effect(Msg(socket))) {
  let model = settled(model) |> refreshed
  let #(model, effects) = serviced(model, effects, at)
  let model = rearm(model, at)
  let #(model, observing) = observed(model, at)
  #(model, effect.batch([perform(model.view.transport, effects), observing]))
}

// Sends the page's own read when `refreshed` has decided it wants one. The
// read is the window's scan, owed from the moment the page chose it, and the
// frame leaves in the step's tick, the reduction that sends any read, so it
// goes out in the message that wanted it and not in some later one. A busy lane
// refuses it and it stays owed for the next message to send. The tick changes
// the scan's own demand and nothing the page draws, so the projection is
// recorded again rather than rebuilt by the next message.
fn serviced(
  model: Model(socket),
  effects: List(step_effect.Effect(socket, Nil)),
  at: Int,
) -> #(Model(socket), List(step_effect.Effect(socket, Nil))) {
  case
    history_view.range(model.shared.scrollback),
    history_view.lineage(model.shared.scrollback),
    block_summary.next_read(model.shared.summaries)
  {
    None, None, None -> #(model, effects)
    Some(_), _, _ | None, Some(_), _ | None, None, Some(_) -> {
      let #(shared, sent) = step.update(model.shared, tick_at(at))
      let model = settled(Model(..model, shared:)) |> settled_projection
      #(model, list.append(effects, sent))
    }
  }
}

// Asks the daemon to observe the workspace when the page may, no read is out,
// the transcript shows a tool result the last read did not see (the page's
// first read is owed from the start), and `worktrees.refresh_ms` have passed
// since the last ask. A burst of tool calls therefore asks once, and a page
// with nothing happening asks nothing. The answer arrives as `Worktreed`.
fn observed(
  model: Model(socket),
  at: Int,
) -> #(Model(socket), Effect(Msg(socket))) {
  let view = model.view
  let since = case view.worktree_asked_at {
    Some(before) -> at - before
    None -> worktrees.lost_ms
  }

  // A read that never answered is lost after `lost_ms`, and is asked again.
  let free = case view.asking {
    worktrees.Idle -> since >= worktrees.refresh_ms
    worktrees.Out -> since >= worktrees.lost_ms
  }
  case view.transport.worktree, free, view.worktree_seen {
    Some(ask), True, seen if seen != view.latest_result -> #(
      Model(
        ..model,
        view: View(
          ..view,
          asking: worktrees.Out,
          worktree_asked_at: Some(at),
          worktree_seen: view.latest_result,
        ),
      ),
      asking_worktree(ask),
    )
    _, _, _ -> #(model, effect.none())
  }
}

// Starts the daemon's task and returns at once. Its answer arrives later as
// `Worktreed`, dispatched from the task's own process.
fn asking_worktree(
  ask: fn(fn(worktrees.Read) -> Nil) -> Nil,
) -> Effect(Msg(socket)) {
  use dispatch <- effect.from
  ask(fn(read) { dispatch(Worktreed(read)) })
}

// Takes the prompts the daemon handed back out of the shared record, which
// keeps them only until a step forgets them. The daemon held each prompt
// only in memory, so this is its last copy (protocol-change/038); the page
// keeps it for the composer's element to put in the editor, and says what
// came back. A prompt for a strand the page does not compose for, or for
// another session, has no editor here, and the notice says so instead of
// pretending it was restored.
fn taken(model: Model(socket)) -> Model(socket) {
  case model.shared.returned_drafts {
    [] -> model
    drafts -> {
      let mine =
        list.filter(drafts, fn(draft) { draft.session == model.shared.session })
      let numbered =
        list.index_map(mine, fn(draft, index) {
          Returned(number: model.view.returns + index + 1, text: draft.text)
        })
      let returned = list.append(model.view.returned, numbered)
      Model(
        shared: Shared(..model.shared, returned_drafts: [], answer: ""),
        view: View(
          ..model.view,
          refusal: None,
          outcome: returned_words(drafts, mine, model.shared.active_strand),
          returns: model.view.returns + list.length(mine),
          returned:,
        ),
      )
    }
  }
}

// The end of every step over the record: the returned prompts are taken
// first, since forgetting the step's leftovers would not drop them but a host
// must not leave them behind, and then the facts a host has no surface for
// are forgotten.
fn settled(model: Model(socket)) -> Model(socket) {
  let held = taken(model)
  Model(
    shared: step.forget_surfaces(held.shared),
    view: View(..held.view, strand_keys: numbered(held)),
  )
}

// The strand keys with the strand on screen numbered, if the page has not
// shown it before. The next number is one past the count, since numbers are
// never taken back.
fn numbered(model: Model(socket)) -> Dict(String, Int) {
  let keys = model.view.strand_keys
  case dict.has_key(keys, model.shared.active_strand) {
    True -> keys
    False -> dict.insert(keys, model.shared.active_strand, dict.size(keys) + 1)
  }
}

// What the page says when prompts come back: how many, for which strand, and
// whether they are in the composer.
fn returned_words(
  drafts: List(session_model.ReturnedDraft),
  mine: List(session_model.ReturnedDraft),
  focused: String,
) -> String {
  let elsewhere = list.length(drafts) - list.length(mine)
  let here = case mine {
    [] -> []
    [_, ..] -> [
      counted(list.length(mine))
      <> " held for "
      <> held_for(mine, focused)
      <> ", put back in the composer",
    ]
  }
  let there = case elsewhere {
    0 -> []
    count -> [
      counted(count) <> " held for another session, which the page cannot show",
    ]
  }
  "The daemon handed back "
  <> string.join(list.append(here, there), "; ")
  <> "."
}

// Whom the returned prompts were held for. A prompt returned for the strand
// the page shows is named by that strand alone. One held for another strand
// of the session is put back in the same editor, which addresses the strand
// on screen, so the words name the strand it was held for and the reader can
// see that the composer's addressee differs from it before pressing Send.
fn held_for(
  drafts: List(session_model.ReturnedDraft),
  focused: String,
) -> String {
  let named =
    drafts
    |> list.map(fn(draft) { draft.strand })
    |> list.unique
  case named {
    [only] if only == focused -> focused
    _ -> string.join(named, ", ") <> " (you are addressing " <> focused <> ")"
  }
}

fn counted(count: Int) -> String {
  case count {
    1 -> "1 prompt"
    _ -> int.to_string(count) <> " prompts"
  }
}

/// Folds lane updates into the component as the shared step's lane fold
/// does, and derives what the page draws from the result.
///
/// It is the boundary a test drives to deliver a daemon reply without
/// standing up a socket, and the terminal has the same one
/// (`tui/inbound.apply_channel_update`). Each update is applied on its own,
/// as the step applies them, and the effects the fold queued stay in the
/// shared record's outbox for the next step to return.
///
/// ## Examples
///
/// ```gleam
/// // component.apply(model, updates)
/// ```
@internal
pub fn apply(
  model: Model(socket),
  updates: List(session_channel.Update),
) -> Model(socket) {
  list.fold(updates, model, fn(model, update) {
    let shared =
      lane_fold.apply_channel_update(
        model.shared,
        update,
        lane_fold.nothing_shown(),
      )
    settled(Model(..model, shared:))
  })
  |> refreshed
}

// --- what the page draws ---------------------------------------------------

// Brings everything the page draws up to the shared record, and builds
// nothing that did not move: the history window follows the session again
// once its read is answered, the transcript is projected when its inputs
// moved, the strip when its inputs or a drawn cache label did, and the
// status follows the lane.
fn refreshed(model: Model(socket)) -> Model(socket) {
  let model = resumed(model)
  let model = case
    projected_of(
      model.shared,
      model.view.paging,
      model.view.folds,
      model.view.older,
    )
    == model.view.projected
  {
    True -> model
    False -> relaned(model)
  }
  let model = case stripped_of(model.shared) == model.view.stripped {
    False -> restripped(model)
    True ->
      case label_moved(model) {
        True -> restripped(model)
        False -> model
      }
  }
  model |> clocked |> streamed |> statused
}

// Starts and stops the generation clock from the phase the page can see.
//
// A page draws captures, and the strand's `assistant` phase reaches it in
// the capture; the shared record's own start (`event_fold`, on the
// operation's phase event) runs only where that event is delivered, which is
// the terminal. Without this the opened row has a phase and no clock and
// says `Thinking` alone until a fragment starts one, which a model that
// streams nothing for ten seconds never does. The clock starts the first
// time the page sees the phase, which is the turn's open for a page that
// was watching, and a later reading than that for one that attached mid
// generation; it never runs backwards, because a fragment finding the clock
// set leaves it alone.
//
// Any other phase ends the generation, so the next one starts from its own
// open, unless a stream is still being drawn: a capture that lags a fragment
// must not stop the reasoning row's clock under it.
fn clocked(model: Model(socket)) -> Model(socket) {
  let shared = model.shared
  let started = case
    session_model.active_strand_phase(shared),
    shared.generation_started_ms
  {
    Some("assistant"), None -> Some(shared.stamp.now_ms)
    Some("assistant"), kept -> kept
    _, kept ->
      case shared.streams {
        [] -> None
        _ -> kept
      }
  }
  case started == shared.generation_started_ms {
    True -> model
    False ->
      Model(..model, shared: Shared(..shared, generation_started_ms: started))
  }
}

// Follows the shared record's live streams for the followed strand, which
// `transcript_lines.display_streams` picks as the terminal does: the pushed
// fragments, or the capture's sampled preview of an answer already running
// when the page attached, and neither once the terminal's own records hold
// the answer.
//
// Three things are added for a page that draws only captures.
//
// - A stream whose answer the projected window already holds is dropped, so
//   a capture that lands before the entry's push cannot draw the answer
//   twice.
// - The record drops a strand's streams when the entry lands, ahead of the
//   capture that gives this page the row. So when the record has no stream,
//   the streams the page last drew stay while their answer is still owed
//   (`response_awaited`): its entry is not in the window the page projects
//   and the capture still shows the operation running. Once the entry is
//   drawn as a row, or the capture says the operation ended without one,
//   they go. A stream that reserved no entry (an older daemon) is never kept.
// - A page that attached mid-answer draws the capture's sampled preview
//   until the first pushed fragment, which the shared record then puts in
//   its place, so the answer would shrink to that fragment and grow again.
//   The page keeps what it drew of a request while the pushed text is
//   shorter than that (`steadied`); the terminal, which has the same
//   source, still shows the shorter text.
//
// This runs after the projection, so it reads the window that was just
// built.
fn streamed(model: Model(socket)) -> Model(socket) {
  let shown =
    session_model.presentation(model.shared)
    |> transcript_lines.display_streams
    |> list.filter(fn(stream) { stream.kind != "end" })
  case shown, model.view.streams {
    [], [] -> model
    [_, ..], last -> {
      let records = projected_records(model)
      let held =
        list.filter(shown, fn(stream) {
          !transcript_lines.response_recorded(records, stream.generation)
        })
      Model(..model, view: View(..model.view, streams: steadied(held, last)))
    }
    [], last ->
      case list.any(last, awaited(model, _)) {
        True -> model
        False -> Model(..model, view: View(..model.view, streams: []))
      }
  }
}

// The pushed streams, except that a stream keeps the text drawn last time
// for its request and kind while that is longer: only a sampled preview is
// ever longer than the pushed text that replaces it.
fn steadied(pushed: List(Stream), last: List(Stream)) -> List(Stream) {
  list.map(pushed, fn(stream) {
    let earlier =
      list.find(last, fn(before) {
        before.generation == stream.generation
        && before.kind == stream.kind
        && before.bytes > stream.bytes
      })
    result.unwrap(earlier, stream)
  })
}

// The records of the window the page projects, newest first.
fn projected_records(model: Model(socket)) -> List(protocol.EntryRecord) {
  case model.shared.captured {
    None -> []
    Some(#(_, view)) ->
      history_view.branch(model.shared.scrollback, view).records
  }
}

// Whether the answer this stream is writing is still to come as a row. A
// stream for another strand than the one the page follows is never drawn.
fn awaited(model: Model(socket), stream: Stream) -> Bool {
  case model.shared.captured, stream.strand == model.shared.active_strand {
    _, False -> False
    None, True -> True
    Some(#(_, view)), True ->
      transcript_lines.response_awaited(
        projected_records(model),
        view.operations,
        stream,
      )
  }
}

fn projected_of(
  shared: Session(socket),
  paging: Paging,
  folds: List(Int),
  older: Asking,
) -> Projected {
  Projected(
    strand: shared.active_strand,
    captured: shared.captured,
    scrollback: shared.scrollback,
    notices: shared.cache_notices,
    agents: shared.agent_rows,
    paging:,
    folds:,
    older:,
  )
}

fn stripped_of(shared: Session(socket)) -> Stripped {
  Stripped(
    followed: shared.active_strand,
    roster: agent_roster.Roster(..shared.roster, now_ms: 0),
    cache: shared.cache,
    agents: shared.agent_rows,
    strands: shared.strands,
  )
}

// Asking for older rows freezes the history window (`history_view.older`),
// so a capture that lands while the read is out cannot move the endpoint
// the reply will be placed against. Once the read is answered or refused, or
// the lane has failed, no read is owed and the window follows the session
// again, taking in the newest capture, which `captured` kept while the
// window was frozen. The terminal leaves the window frozen until its reader
// scrolls back to the tail; this page never scrolls, so it resumes here.
fn resumed(model: Model(socket)) -> Model(socket) {
  let shared = model.shared
  case shared.scrollback.mode, shared.scrollback.request, shared.captured {
    history_view.Reading, history_view.Quiet, Some(#(cut, view)) ->
      Model(
        ..model,
        shared: Shared(
          ..shared,
          scrollback: history_view.resume(shared.scrollback)
            |> history_view.capture(cut.window, view, shared.active_strand),
        ),
      )
    history_view.Reading, history_view.Quiet, None
    | history_view.Reading, history_view.Wanted, _
    | history_view.Reading, history_view.Pending(_), _
    | history_view.Live, _, _
    -> model
  }
}

// Projects what the page draws of the strand from the history window, the
// turns it has closed and the notices. This is the one place a projection
// runs.
//
// A turn that has closed is not kept as records. When its records are all in
// the window and nothing more will be added to it, the page keeps a summary
// of it (`turn_ledger.Sealed`: its prompt, its answer and its divider) and
// drops its records from the window, so a turn of a thousand calls costs the
// page what a turn of two does and the turns around it stay reachable. The
// window holds only what is still moving, the running turn, and the page
// draws the closed turns from their summaries. A closed turn's steps are read
// when the reader opens its fold and dropped when the fold closes.
//
// The order of one projection is the order of the questions it answers.
// `scanned` takes what the page's transient read found, if a read has
// answered, and closes the turns it found. `trimmed` drops the window's
// records older than the newest closed turn's end, since those are the
// summary's. `laid_out` then asks which turns of the window are closed, closes
// them, decides how many turns fit the page's limit (`fold_budget`), and draws
// the closed turns from their summaries and the rest from the window.
// `begun` last starts the one read the page wants next, if it wants one and
// has none out.
//
// The window is written in the two places this module has always written it:
// it is trimmed, and it is asked for a read. The read is the window's own scan
// (`history_view.scan`), which walks the strand's ancestry a page at a time and
// keeps what it reads apart from the window, so a read through a turn of
// thousands of records never evicts the live end.
fn relaned(model: Model(socket)) -> Model(socket) {
  let laid = case model.shared.captured {
    None -> settled_projection(model)
    Some(#(cut, view)) -> relaid(model, cut, view, 4) |> settled_projection
  }
  labels_wanted(laid)
}

// Marks the reasoning blocks the page now draws as wanted, so the lane reads
// the stored summarizer labels the page lacks for them (`block_summary.want`;
// the shared step sends the read once the lane is free). This is the one place
// the page learns which blocks it draws, and it runs when a projection was
// rebuilt: the window's turns, the closed turns the page holds, the steps of
// a fold the reader opened and a page of older history all end up in `pieces`,
// so a block that arrived through a lineage read or an opened fold is asked
// about like one in the window. A block already labelled, already asked about
// or already waiting is not added again, and the read names at most
// `block_summary.max_blocks` of them.
fn labels_wanted(model: Model(socket)) -> Model(socket) {
  let summaries =
    block_summary.want(
      model.shared.summaries,
      turn_labels.keys(model.view.pieces),
    )
  Model(..model, shared: Shared(..model.shared, summaries:))
}

// One pass of the projection, and another when the read the pass chose was
// answered from what the page already held. A read starts from the records of
// the capture, and a turn closed a moment ago is still among them, so the
// answer can be there at once and the page draws what it found in the same
// message. `fuel` bounds the passes: each answered read spends one want, and a
// page wants at most a few things at a time.
fn relaid(
  model: Model(socket),
  cut: snapshot.Captured,
  view: snapshot_view.View,
  fuel: Int,
) -> Model(socket) {
  let model = scanned(model, cut, view) |> trimmed
  let #(model, window) = laid_out(model, view, cut)
  case begun(model, window, cut, view) {
    Began(model) -> model
    Answered(model) if fuel > 0 -> relaid(model, cut, view, fuel - 1)
    Answered(model) -> model
  }
}

// Records what the projection was built from, after the trim and the paging
// it may have written, so the next `refreshed` compares against what the record
// holds now and not against what the projection started from.
fn settled_projection(model: Model(socket)) -> Model(socket) {
  Model(
    ..model,
    view: View(
      ..model.view,
      projected: projected_of(
        model.shared,
        model.view.paging,
        model.view.folds,
        model.view.older,
      ),
    ),
  )
}

// How many complete turns a read for the turns below the page's oldest looks
// for before it stops. It is about what one press of "Load older" shows, and
// the read stops at the first page that holds that many.
const older_turns = 10

// The sequence the window must start at: the one after the newest closed
// turn's last record. Nothing is closed, and nothing is dropped, before the
// first turn closes.
fn frontier(sealed: List(turn_ledger.Sealed)) -> Int {
  case sealed {
    [newest, ..] -> newest.end.seq + 1
    [] -> 0
  }
}

// Drops the records of the window that belong to closed turns. A capture holds
// the newest hundred records of the whole session, so each one brings back the
// records of turns already closed, and this drops them again.
fn trimmed(model: Model(socket)) -> Model(socket) {
  case frontier(model.view.sealed) {
    0 -> model
    seq ->
      Model(
        ..model,
        shared: Shared(
          ..model.shared,
          scrollback: history_view.retain_from(model.shared.scrollback, seq),
        ),
      )
  }
}

// Takes what the page's read found once a read has answered. The read is the
// window's scan; while one is owed or out there is nothing to take, and one
// that was refused or lost is given up.
fn scanned(
  model: Model(socket),
  cut: snapshot.Captured,
  view: snapshot_view.View,
) -> Model(socket) {
  case model.view.purpose, model.shared.scrollback.scan {
    Resting, history_view.Unscanned -> model
    Resting, history_view.Scanning(..) | Resting, history_view.Abandoned ->
      ended(model)
    _, history_view.Abandoned | _, history_view.Unscanned -> abandoned(model)
    purpose, history_view.Scanning(request: history_view.Idle, ..) ->
      read(model, purpose, cut, view)
    _, history_view.Scanning(..) -> model
  }
}

// What a read found, taken when it is enough, and otherwise the next read.
//
// The scan holds a stretch of the strand's ancestry newest first, and it is
// drawn as the window is, so a closed turn has the same pieces whichever of
// the two it came from. The cache notices are the window's and name records
// the scan did not read, so none is passed.
fn read(
  model: Model(socket),
  purpose: Purpose,
  cut: snapshot.Captured,
  view: snapshot_view.View,
) -> Model(socket) {
  let shared = model.shared
  case history_view.scanned(shared.scrollback, view) {
    None -> abandoned(model)
    Some(branch) -> {
      let blocks =
        transcript.branch_blocks(branch, cut, view, shared.active_strand, [])
      let source = source_of(shared.scrollback, branch)
      case found(model, purpose, blocks, branch, view, source) {
        Ok(taken) -> ended(taken)
        Error(Nil) ->
          Model(
            ..model,
            shared: Shared(
              ..shared,
              scrollback: history_view.scan_older(
                shared.scrollback,
                branch.unloaded,
              ),
            ),
          )
      }
    }
  }
}

// Whether the scan can be asked for more: it can not once it holds the
// strand's first record, and not once it can no longer be read
// (`history_view.scan_readable`: a read found nothing below what it holds, its
// bound was reached, or the parent it is missing is a record over the
// presentation limit, which it holds as a descriptor and no read will load).
fn source_of(
  scrollback: history_view.State,
  branch: snapshot_view.Branch,
) -> turn_ledger.Source {
  case
    branch.unloaded,
    history_view.scan_readable(scrollback, branch.unloaded)
  {
    Some(_), True -> turn_ledger.Readable
    None, _ | Some(_), False -> turn_ledger.Exhausted
  }
}

// What the read was for, done with what it found.
fn found(
  model: Model(socket),
  purpose: Purpose,
  blocks: List(transcript_lines.Block),
  branch: snapshot_view.Branch,
  view: snapshot_view.View,
  source: turn_ledger.Source,
) -> Result(Model(socket), Nil) {
  case purpose {
    ForOlder ->
      turn_ledger.older(
        blocks,
        branch.records,
        view.strands,
        older_turns,
        source,
      )
      |> result.map(fn(sealed) { below(model, sealed, source) })
    ForLead ->
      turn_ledger.completed(blocks, branch.records, view.strands, source)
      |> result.map(fn(completion) {
        case completion {
          turn_ledger.Whole(sealed) -> beside(model, sealed)

          // The scan could not reach the turn's input. What the page has of
          // the turn is drawn as it stands, in place, and the older turns it
          // holds are left alone.
          turn_ledger.Partial ->
            Model(..model, view: View(..model.view, completion: Spent))
        }
      })
    ForTail ->
      turn_ledger.older(blocks, branch.records, view.strands, 1, source)
      |> result.map(fn(sealed) { first_turns(model, sealed, source) })
    ForSteps(fold:) ->
      turn_ledger.steps(
        blocks,
        view.strands,
        turns.Expand(expansion.capped),
        worked_steps(model, fold),
        source,
      )
      |> result.map(fn(steps) { opened(model, fold, steps) })
    Resting -> Ok(model)
  }
}

// The turns found below the page's oldest, which are older than every turn it
// holds and so go last. A read that was exhausted and found nothing says the
// strand has no more.
fn below(
  model: Model(socket),
  found: List(turn_ledger.Sealed),
  source: turn_ledger.Source,
) -> Model(socket) {
  let bottom = case found, source {
    [], turn_ledger.Exhausted -> Reached
    _, _ -> model.view.floor
  }
  Model(
    ..model,
    view: View(
      ..model.view,
      sealed: list.append(model.view.sealed, list.reverse(found)),
      older: Unasked,
      floor: bottom,
    ),
  )
}

// The strand's newest turns, read from its leaf because the window held none of
// its records. They are the first turns the page closes, so they are taken as
// the turns below the window are. A read that found nothing to draw (a strand
// whose records draw no row) marks the floor reached, which is what keeps the
// page from asking for them on every layout.
fn first_turns(
  model: Model(socket),
  found: List(turn_ledger.Sealed),
  source: turn_ledger.Source,
) -> Model(socket) {
  below(model, found, source)
}

// The turn the window held only the end of, whole at last. It is the newest
// of the turns the page holds. It replaces any turn the page closed from the
// end of it alone, which is what a turn is when records arrive after it was
// sealed, and it replaces what the page held below when it does not follow on
// from it, which only a window that lost records to its bound can bring about.
fn beside(
  model: Model(socket),
  found: List(turn_ledger.Sealed),
) -> Model(socket) {
  let sealed = case found {
    [turn, ..] -> {
      let older =
        list.filter(model.view.sealed, fn(held) {
          held.first_seq < turn.first_seq
        })
      case older {
        [newest, ..] ->
          case turn.parent == Some(newest.end.id) {
            True -> list.append(found, older)
            False -> found
          }
        [] -> found
      }
    }
    [] -> model.view.sealed
  }
  Model(..model, view: View(..model.view, sealed:, completion: Untried))
}

// The steps of a fold, read, kept while the fold stays open. A fold the reader
// closed while the read was out keeps nothing.
fn opened(
  model: Model(socket),
  fold: Int,
  steps: turn_ledger.Steps,
) -> Model(socket) {
  case list.contains(model.view.folds, fold) {
    True ->
      Model(
        ..model,
        view: View(
          ..model.view,
          steps: dict.insert(model.view.steps, fold, steps),
        ),
      )
    False -> model
  }
}

// The divider's count of a closed turn's steps, by the number of its fold.
fn worked_steps(model: Model(socket), fold: Int) -> Int {
  case sealed_of(model.view.sealed, fold) {
    Ok(turn) -> turn_ledger.worked_steps(turn)
    Error(Nil) -> 0
  }
}

// The closed turn whose fold has this number.
fn sealed_of(
  sealed: List(turn_ledger.Sealed),
  fold: Int,
) -> Result(turn_ledger.Sealed, Nil) {
  list.find(sealed, fn(turn) { turn_ledger.fold_id(turn) == Some(fold) })
}

// Ends the page's read: what it read is dropped and the page wants nothing.
fn ended(model: Model(socket)) -> Model(socket) {
  Model(
    shared: Shared(
      ..model.shared,
      scrollback: history_view.scan_end(model.shared.scrollback),
    ),
    view: View(..model.view, purpose: Resting),
  )
}

// A read that was refused or lost is given up, and the page does not ask for
// the same thing again until the reader does. The turns below the page are
// offered again, a turn whose start could not be read is drawn as far as it is
// known, and a fold whose steps could not be read says how many it did not
// show.
fn abandoned(model: Model(socket)) -> Model(socket) {
  let view = model.view
  let given = case view.purpose {
    ForOlder -> View(..view, older: Unasked)
    ForLead | ForTail -> View(..view, completion: Spent)
    ForSteps(fold:) ->
      View(
        ..view,
        steps: dict.insert(
          view.steps,
          fold,
          turn_ledger.Steps(items: [], unread: worked_steps(model, fold)),
        ),
      )
    Resting -> view
  }
  ended(Model(..model, view: given))
}

// What the window holds of the turn that comes first in it.
type Lead {
  // The window starts at a turn's input.
  NoLead

  // The blocks before the first input are the whole of a turn, or the tail of
  // the newest closed turn: nothing older is waited for.
  Whole

  // The blocks before the first input are the end of a turn whose start the
  // window does not hold, and the page has not read it.
  Unfinished
}

// What the blocks before the window's first input are.
//
// They are the end of a turn that began before the window only when the
// record before them is unknown to the page. Where the page holds a closed
// turn the window starts right after it, so blocks before the first input are
// records that arrived after that turn closed, unless the record before them is
// not the turn's last, which happens only to a turn the window lost the start
// of to its bound. A strand's own first records are whole. Records after a
// closed turn that have no input of their own belong to that turn, and are
// read with it again (`turn_ledger`, "When a turn is sealed"), so they are
// unfinished like any end of a turn whose start is not held. When they are the
// running turn itself, with no turn after them, they are drawn as far as they
// are known, as a running turn always is, and read once it settles. A read that
// could not complete them leaves the page to draw what it has.
fn lead_of(
  model: Model(socket),
  lead: List(transcript_lines.Block),
  unloaded: Option(String),
  opened: List(List(transcript_lines.Block)),
  latest: turns.Latest,
) -> Lead {
  case
    lead,
    unloaded,
    model.view.sealed,
    model.view.completion,
    opened,
    latest
  {
    [], _, _, _, _, _ -> NoLead
    [_, ..], None, _, _, _, _ -> Whole
    [_, ..], Some(_), _, Spent, _, _ -> Whole
    [_, ..], Some(_), _, Untried, [], turns.Running -> Whole
    [_, ..], Some(_), _, Untried, [], turns.Settled
    | [_, ..], Some(_), _, Untried, [_, ..], _
    -> Unfinished
  }
}

// Whether the page still gives up on completing a lead after the window was
// laid out.
//
// `Spent` records that a read for the lead of the window was refused or could not
// reach the turn's input, so the lead is drawn as it stands and not asked for
// again. That holds of one lead only. Once it has been closed, the frontier has
// moved past it, and the next records that arrive with no input of their own (a
// resume, an input that landed before its operation) are another lead, which has
// not been tried. Keeping `Spent` would close each of them as a turn of its
// own, and the turn would be drawn as two dividers where a reload draws one.
fn completion_after(
  standing: Lead,
  completion: Completion,
  fresh: List(turn_ledger.Sealed),
) -> Completion {
  case standing, completion, fresh {
    Whole, Spent, [_, ..] -> Untried
    Whole, Spent, [] | Whole, Untried, _ | NoLead, _, _ | Unfinished, _, _ ->
      completion
  }
}

// Whether a turn's first block was drawn from a record the closed turns do not
// already cover. The window is trimmed to the records after them, so this holds
// of every turn the window shows, and it is what keeps a turn from being closed
// twice if a trim ever could not be made.
fn starts_after(group: List(transcript_lines.Block), frontier: Int) -> Bool {
  case group {
    [first, ..] ->
      case transcript_lines.block_seq(first) {
        Ok(seq) -> seq >= frontier
        Error(Nil) -> False
      }
    [] -> False
  }
}

// The turns of the window, oldest first, that are closed: all of them unless
// the strand is running, when the newest is the running turn.
fn closing(
  groups: List(List(transcript_lines.Block)),
  latest: turns.Latest,
) -> List(List(transcript_lines.Block)) {
  case latest {
    turns.Settled -> groups
    turns.Running -> list.take(groups, int.max(list.length(groups) - 1, 0))
  }
}

// What the window leaves to draw once its closed turns are closed.
type Window {
  Window(
    // The window's records still in play, newest first.
    records: List(protocol.EntryRecord),
    // The turns drawn from records, oldest first.
    groups: List(List(transcript_lines.Block)),
    // The unread start of the oldest turn, which `begun` asks for.
    lead: Lead,
    // Where that turn's records end, to start the read from.
    reach: Result(turn_ledger.Anchor, Nil),
    // Whether the strand is running its newest turn.
    latest: turns.Latest,
    // The blocks and records of the whole window, before any closing, which a
    // page that is only running keeps whole.
    unloaded: Option(String),
  )
}

// Closes the turns of the window that are closed, and lays the page out.
fn laid_out(
  model: Model(socket),
  view: snapshot_view.View,
  cut: snapshot.Captured,
) -> #(Model(socket), Window) {
  let shared = model.shared

  // A parked strand's closed turns are dropped when its window is, which the
  // shared record does when the capture no longer lists the strand
  // (`lane_fold.prune_parked_scrollback`), so a summary is never kept beside no
  // window.
  let model =
    Model(
      ..model,
      view: View(
        ..model.view,
        parked_sealed: dict.filter(model.view.parked_sealed, fn(name, _) {
          session_model.is_known_strand(view.strands, name)
        }),
      ),
    )
  let branch = history_view.branch(shared.scrollback, view)
  let all =
    transcript.branch_blocks(
      branch,
      cut,
      view,
      shared.active_strand,
      shared.cache_notices,
    )
  let #(lead, opened) = turns.grouped(all, view.strands)
  let latest = turns.latest(view, shared.agent_rows, shared.active_strand)
  let standing = lead_of(model, lead, branch.unloaded, opened, latest)
  let groups = case standing {
    Whole -> [lead, ..opened]
    NoLead | Unfinished -> opened
  }

  // Nothing is closed while the oldest turn is unread: the closed turns would
  // be newer than a turn the page does not hold, and the summaries are kept
  // oldest to newest without a gap. They are drawn from the window meanwhile.
  let closed = case standing {
    Unfinished -> []
    NoLead | Whole ->
      closing(groups, latest)
      |> list.filter(starts_after(_, frontier(model.view.sealed)))
  }
  let fresh =
    turn_ledger.seal_all(
      closed,
      list.drop(groups, list.length(closed)),
      branch.records,
      view.strands,
    )
  let model =
    Model(
      ..model,
      view: View(
        ..model.view,
        sealed: list.append(list.reverse(fresh), model.view.sealed),
        completion: completion_after(standing, model.view.completion, fresh),
      ),
    )
  let model = trimmed(model)
  let window =
    Window(
      records: list.filter(branch.records, fn(record) {
        record.entry.seq >= frontier(model.view.sealed)
      }),
      groups: list.drop(groups, list.length(closed)),
      lead: standing,
      reach: case standing {
        Unfinished -> turn_ledger.lead_end(lead, opened, branch.records)
        NoLead | Whole -> Error(Nil)
      },
      latest:,
      unloaded: branch.unloaded,
    )
  #(drawn(model, window, view), window)
}

// The turn weights, newest first, for the window's turns and then the closed
// turns, and which of them fit the page's limit.
//
// A turn costs what it draws (`fold_budget.weigh`): its prompt, its answer and
// its divider, plus the steps of its fold while the reader has it open. Which
// turns the page holds never depends on the open folds (`fold_budget.fit`):
// the turns are chosen as if every fold were closed, and the rows they leave
// over go to the open folds, most recently opened first. A fold that does not
// fit whole draws its newest steps that do, if it is the most recent that did
// not fit, and an older one is closed. So pressing a divider cannot move where
// the page is cut or fill it.
//
// The newest turn is always held. A running turn is drawn open, so it costs
// every row of its blocks. When it alone is over the limit, which a long run of
// work can be, the page holds its newest blocks that fit, and at least its
// newest block, so a page mid-turn still shows the turn's end. That turn is
// then keyed by the window's start, which moves each time the turn grows by a
// block, so its held rows, at most the limit, are drawn again on that capture.
// Only a turn longer than the whole limit pays this, and only while it runs.
fn drawn(
  model: Model(socket),
  window: Window,
  view: snapshot_view.View,
) -> Model(socket) {
  let limit = limit(model.view.paging)
  let weights = weights(model, window, view.strands)
  case weights.window {
    [head, ..] if head.base > limit ->
      overrun(model, window, view, weights.group_blocks)
    _ -> {
      let fitted =
        fold_budget.fit(
          list.append(weights.window, weights.sealed),
          model.view.folds,
          limit,
        )
      fitted_page(model, window, view, fitted, weights)
    }
  }
}

// The weights of the page's turns, newest first.
type Weights {
  Weights(
    // The window's turns, newest first.
    window: List(fold_budget.Weight),
    // The closed turns, newest first, with a fold whose steps are held weighed
    // by them.
    sealed: List(fold_budget.Weight),
    // The window's blocks by turn, newest first, the same length as `window`.
    group_blocks: List(List(transcript_lines.Block)),
  )
}

fn weights(
  model: Model(socket),
  window: Window,
  strands: List(protocol.Strand),
) -> Weights {
  let newest_first = list.reverse(window.groups)
  let held = case newest_first {
    [] -> []
    [newest, ..older] -> [
      newest_weight(newest, strands, window.latest),
      ..list.map(older, fold_budget.weigh(_, strands))
    ]
  }
  Weights(
    window: held,
    sealed: list.map(model.view.sealed, closed_weight(_, model.view.steps)),
    group_blocks: newest_first,
  )
}

// A closed turn's weight, with the rows its fold adds taken from the steps the
// page holds for it when it holds them.
fn closed_weight(
  turn: turn_ledger.Sealed,
  steps: Dict(Int, turn_ledger.Steps),
) -> fold_budget.Weight {
  case turn.weight.fold {
    Some(fold) ->
      case dict.get(steps, fold.id) {
        Ok(held) ->
          fold_budget.Weight(
            ..turn.weight,
            fold: Some(
              fold_budget.Fold(..fold, rows: fold_budget.item_rows(held.items)),
            ),
          )
        Error(Nil) -> turn.weight
      }
    None -> turn.weight
  }
}

// The weight of the newest turn. A running turn is drawn open, with every
// block's rows, so it costs them all; a settled one costs its divider.
fn newest_weight(
  turn: List(transcript_lines.Block),
  strands: List(protocol.Strand),
  latest: turns.Latest,
) -> fold_budget.Weight {
  case latest {
    turns.Running -> fold_budget.Weight(base: row_count(turn), fold: None)
    turns.Settled -> fold_budget.weigh(turn, strands)
  }
}

// A running turn that alone is over the page's limit: the page draws its
// newest blocks and nothing before it, and keeps what it holds untouched, so
// the turns below it are drawn again once it settles.
fn overrun(
  model: Model(socket),
  window: Window,
  view: snapshot_view.View,
  newest_first: List(List(transcript_lines.Block)),
) -> Model(socket) {
  let newest = case newest_first {
    [turn, ..] -> turn
    [] -> []
  }
  let blocks =
    newest_blocks(list.reverse(newest), limit(model.view.paging), 0, [])
  let pieces =
    turns.pieces(
      blocks,
      view.strands,
      window.latest,
      turns.Expand(expansion.capped),
    )
    |> turns.attributed(turns.authors(view.peers))
  Model(
    ..model,
    view: View(
      ..model.view,
      blocks:,
      pieces:,
      folds: [],
      steps: dict.new(),
      earlier: Unheld,
      changes: changes_view.fold(window.records),
      latest_result: turn_ledger.latest_result(window.records),
      trace: trace_view.fold(window.records),
      raised: remembered(model.view.raised, view.cells),
    ),
  )
}

// The page's turns once the limit is applied: the window's turns that fit,
// then the closed turns that fit, drawn.
fn fitted_page(
  model: Model(socket),
  window: Window,
  view: snapshot_view.View,
  fitted: fold_budget.Fitted,
  weights: Weights,
) -> Model(socket) {
  let held = list.length(weights.window)
  let kept_window = int.min(fitted.kept, held)
  let by_rows = list.take(model.view.sealed, int.max(fitted.kept - held, 0))
  let kept_sealed = within_bytes(by_rows, fold_budget.sealed_bytes)
  let blocks =
    weights.group_blocks
    |> list.take(kept_window)
    |> list.reverse
    |> list.flatten
  let closed_pieces =
    kept_sealed
    |> list.reverse
    |> list.flat_map(fn(turn) {
      list.append(
        opened_pieces(turn, fitted, model.view.steps),
        late_misses(
          turn,
          model.shared.cache_notices,
          model.shared.active_strand,
        ),
      )
    })
  let window_pieces =
    turns.pieces(
      blocks,
      view.strands,
      window.latest,
      turns.Expand(expansion.capped),
    )
    |> fold_budget.draw(fitted.folds, fitted.allowance)
  let rows = case fitted.kept < held + list.length(model.view.sealed) {
    True -> Beyond
    False -> Within
  }
  let bytes = case list.length(kept_sealed) < list.length(by_rows) {
    True -> Beyond
    False -> Within
  }
  let paging = paged(model.view.paging, rows, bytes, window.latest)
  Model(
    ..model,
    view: View(
      ..model.view,
      sealed: kept_sealed,
      steps: dict.filter(model.view.steps, fn(fold, _) {
        list.contains(fitted.folds, fold)
      }),
      blocks:,
      pieces: list.append(closed_pieces, window_pieces)
        |> turns.attributed(turns.authors(view.peers)),
      folds: fitted.folds,
      raised: remembered(model.view.raised, view.cells),
      earlier: earlier_of(model, kept_sealed, window),
      paging:,
      changes: joined_changes(kept_sealed, window.records),
      latest_result: joined_result(kept_sealed, window.records),
      trace: joined_trace(kept_sealed, window.records),
    ),
  )
}

/// Whether the turns the page held fit one of its limits.
pub type Reach {
  /// Everything the page held fit.
  Within

  /// A turn had to be cut to stay within the limit.
  Beyond
}

/// How the page's paging stands once its limits were applied: `rows` says
/// whether the turns fit the row limit, `bytes` whether the closed turns fit
/// their budget of text, and `latest` whether the newest turn is still running.
///
/// A paged page that had to cut a whole turn to stay within its limit is full:
/// loading more would only cut again. What cut it decides how long that holds.
/// The bytes of the closed turns only grow, since a summary never shrinks, so a
/// cut by bytes is `Full` for good. A cut by rows may be the running turn's own,
/// which is drawn open with every row, and that turn settles into one divider: the
/// page is then `Crowded` while the turn runs and `Paged` again when it
/// settles, with the room its divider gave back. A rows cut that outlives the
/// running turn is `Full` as before. The turns a cut dropped are gone from the
/// page, so a page that found nothing to cut on a later capture could not tell
/// the two apart, which is why the running turn's cut is a state of its own.
///
/// ## Examples
///
/// ```gleam
/// assert component.paged(component.Crowded, component.Within, component.Within, turns.Settled)
///   == component.Paged
/// ```
@internal
pub fn paged(
  paging: Paging,
  rows: Reach,
  bytes: Reach,
  latest: turns.Latest,
) -> Paging {
  case bytes, rows {
    Beyond, _ ->
      case paging {
        Paged | Crowded -> Full
        Tail | Full -> paging
      }
    Within, Beyond ->
      case paging, latest {
        Paged, turns.Running | Crowded, turns.Running -> Crowded
        Paged, turns.Settled | Crowded, turns.Settled -> Full
        Tail, _ | Full, _ -> paging
      }
    Within, Within ->
      case paging, latest {
        Crowded, turns.Settled -> Paged
        Crowded, turns.Running | Tail, _ | Paged, _ | Full, _ -> paging
      }
  }
}

// The newest closed turns, given newest first, whose summaries fit `budget`
// bytes of text, and at least the newest. Rows bound what the runtime retains of
// a turn drawn; this bounds what the page retains of the text, which one row can
// make large.
fn within_bytes(
  newest_first: List(turn_ledger.Sealed),
  budget: Int,
) -> List(turn_ledger.Sealed) {
  case newest_first {
    [] -> []
    [newest, ..older] -> [newest, ..fitting(older, budget - newest.bytes)]
  }
}

fn fitting(
  older: List(turn_ledger.Sealed),
  room: Int,
) -> List(turn_ledger.Sealed) {
  case older {
    [turn, ..rest] if turn.bytes <= room -> [
      turn,
      ..fitting(rest, room - turn.bytes)
    ]
    _ -> []
  }
}

// A closed turn's pieces as the page draws them: its divider is open, with the
// steps the page holds for it and the earlier ones it does not, when the reader
// has its fold open, and reads "reading" until the steps arrive. A fold that
// fits only in part draws the newest steps its room allows.
fn opened_pieces(
  turn: turn_ledger.Sealed,
  fitted: fold_budget.Fitted,
  steps: Dict(Int, turn_ledger.Steps),
) -> List(turns.Piece) {
  list.map(turn.pieces, fn(piece) {
    case piece {
      turns.Work(key:, worked:, id: Some(fold), folding: turns.Folded, ..) ->
        case list.contains(fitted.folds, fold), dict.get(steps, fold) {
          False, _ ->
            turns.Work(
              key:,
              worked:,
              items: [],
              folding: turns.Folded,
              id: Some(fold),
            )
          True, Error(Nil) ->
            turns.Work(
              key:,
              worked:,
              items: [],
              folding: turns.Reading,
              id: Some(fold),
            )
          True, Ok(held) -> {
            let #(items, hidden) = case dict.get(fitted.allowance, fold) {
              Ok(allowed) -> fold_budget.newest(held.items, allowed)
              Error(Nil) -> #(held.items, 0)
            }
            turns.Work(
              key:,
              worked:,
              items:,
              folding: turns.Unfolded(hidden: hidden + held.unread),
              id: Some(fold),
            )
          }
        }
      turns.Work(..)
      | turns.Plain(..)
      | turns.Prompt(..)
      | turns.Spawned(..)
      | turns.Returned(..)
      | turns.Nudged(..)
      | turns.Commentary(..)
      | turns.Peer(..)
      | turns.Sibling(..)
      | turns.Missed(..)
      | turns.Decided(..) -> piece
    }
  })
}

// The cache misses noticed after a closed turn's records were dropped.
//
// A miss is noticed from the next turn's usage, after the turn that paid for
// it settled, and the notice names the last entry the strand held then. When
// that entry is the closed turn's last record the window holds nothing to splice
// the row in beside, so the row is drawn after the turn's own pieces. A miss
// the turn already holds, because the notice came before the turn closed, is
// not drawn twice. The row's key is the last record's sequence and an
// occurrence past any a block of that record has, as a block's key is built, so
// a keyed lane keeps it across captures.
fn late_misses(
  turn: turn_ledger.Sealed,
  notices: List(CacheNotice),
  strand: String,
) -> List(turns.Piece) {
  notices
  |> list.filter(fn(notice) {
    notice.strand == strand
    && ids.entry_id_to_string(notice.after_entry) == turn.end.id
    && !list.any(turn.pieces, fn(piece) {
      case piece {
        turns.Missed(text:, ..) -> text == notice.text
        turns.Work(..)
        | turns.Plain(..)
        | turns.Prompt(..)
        | turns.Spawned(..)
        | turns.Returned(..)
        | turns.Nudged(..)
        | turns.Commentary(..)
        | turns.Peer(..)
        | turns.Sibling(..)
        | turns.Decided(..) -> False
      }
    })
  })
  |> list.index_map(fn(notice, index) {
    turns.Missed(
      key: int.to_string(turn.end.seq) <> "." <> int.to_string(100 + index),
      text: notice.text,
    )
  })
}

// Whether the strand has turns older than the oldest the page holds. The
// oldest closed turn knows whether anything lies before it; with none closed
// the window does. A read that reached the strand's first record says there is
// nothing more, whatever the last turn's parent was.
fn earlier_of(
  model: Model(socket),
  kept_sealed: List(turn_ledger.Sealed),
  window: Window,
) -> Earlier {
  case
    model.view.floor,
    list.last(kept_sealed),
    window.records,
    window.unloaded
  {
    Reached, _, _, _ -> Reached
    Unheld, Ok(oldest), _, _ ->
      case oldest.parent {
        None -> Reached
        Some(_) -> Unheld
      }
    Unheld, Error(Nil), [], None | Unheld, Error(Nil), [_, ..], None -> Reached
    Unheld, Error(Nil), [], Some(leaf) -> unread_before(leaf)
    Unheld, Error(Nil), [_, ..], Some(_) -> Unheld
  }
}

// Whether a strand whose window is empty has anything to read: its leaf names a
// record the window does not hold, and the page has not read it. A cut that
// does not list the strand says so in words, not with an identity, and then
// there is nothing.
fn unread_before(leaf: String) -> Earlier {
  case ids.parse_entry_id(leaf) {
    Ok(_) -> Unheld
    Error(_) -> Reached
  }
}

// The Changes board of the closed turns and the window, joined oldest first.
fn joined_changes(
  kept_sealed: List(turn_ledger.Sealed),
  records: List(protocol.EntryRecord),
) -> changes_view.Board {
  kept_sealed
  |> list.reverse
  |> list.fold(changes_view.empty(), fn(board, turn) {
    changes_view.append(board, turn.changes)
  })
  |> changes_view.append(changes_view.fold(records))
}

// The Trace of the closed turns and the window, joined oldest first.
fn joined_trace(
  kept_sealed: List(turn_ledger.Sealed),
  records: List(protocol.EntryRecord),
) -> trace_view.Trace {
  kept_sealed
  |> list.reverse
  |> list.fold(trace_view.empty(), fn(trace, turn) {
    trace_view.append(trace, turn.trace)
  })
  |> trace_view.append(trace_view.fold(records))
}

// The newest tool result of the closed turns and the window. The workspace is
// read again when a newer one appears, and a window emptied by closing its turns
// must not look like one.
fn joined_result(
  kept_sealed: List(turn_ledger.Sealed),
  records: List(protocol.EntryRecord),
) -> Int {
  list.fold(kept_sealed, turn_ledger.latest_result(records), fn(newest, turn) {
    int.max(newest, turn.latest_result)
  })
}

// What `begun` did.
type Began(socket) {
  // Nothing was wanted, or a read is out and the page waits for its reply.
  Began(Model(socket))

  // A read was wanted and the page held the answer, so the page has taken it
  // and the pieces drawn before it are out of date.
  Answered(Model(socket))
}

// Starts the one read the page wants next, when it wants one and has none out.
//
// What it wants, in order: the start of the turn the window began inside,
// since a turn drawn from half its records would show the wrong figures; the
// steps of a fold the reader opened that the page does not hold; and the turns
// below the oldest the page holds, when the reader asked for them. Each read
// starts at one record of the strand's ancestry and walks down. The records it
// starts from are the ones the page holds of that turn, never the event's. It
// begins with the records the page already has, and only what those do not
// settle goes to the daemon. A press for turns there are none of ends there.
fn begun(
  model: Model(socket),
  window: Window,
  cut: snapshot.Captured,
  view: snapshot_view.View,
) -> Began(socket) {
  case model.view.purpose, wanted(model, window, cut) {
    ForOlder, _ | ForLead, _ | ForTail, _ | ForSteps(_), _ -> Began(model)
    Resting, Some(#(purpose, leaf, before)) -> {
      let scrollback =
        history_view.scan(
          model.shared.scrollback,
          leaf,
          before,
          cut.window,
          view,
        )
      let started =
        Model(
          shared: Shared(..model.shared, scrollback:),
          view: View(..model.view, purpose:),
        )
      let read = read(started, purpose, cut, view)
      case read.view.purpose {
        Resting -> Answered(read)
        ForOlder | ForLead | ForTail | ForSteps(_) -> Began(read)
      }
    }
    Resting, None ->
      case window.lead, window.reach, model.view.older {
        Unfinished, Error(Nil), _ ->
          Answered(Model(..model, view: View(..model.view, completion: Spent)))
        _, _, Pressed ->
          Answered(
            Model(
              ..model,
              view: View(..model.view, older: Unasked, floor: Reached),
            ),
          )
        _, _, Unasked -> Began(model)
      }
  }
}

// What the page reads next, and the record the read starts from and the
// sequence it stays below.
//
// A window that holds none of the strand's records is read before anything
// else, once: with nothing to draw there is no turn to complete, no fold to
// open, and the page would say the conversation begins where it has not
// started to read.
fn wanted(
  model: Model(socket),
  window: Window,
  cut: snapshot.Captured,
) -> Option(#(Purpose, String, Int)) {
  let view = model.view
  case window.lead, window.reach, unread_tail(model, window, cut) {
    Unfinished, Ok(end), _ -> Some(#(ForLead, end.id, end.seq + 1))
    _, _, Some(#(leaf, before)) ->
      case view.completion {
        Untried -> Some(#(ForTail, leaf, before))
        Spent -> reader_asked(model, window, cut)
      }
    _, _, None -> reader_asked(model, window, cut)
  }
}

// The read of an open fold's steps, or of the turns below the page when the
// reader pressed "Load older".
fn reader_asked(
  model: Model(socket),
  window: Window,
  cut: snapshot.Captured,
) -> Option(#(Purpose, String, Int)) {
  case missing_steps(model) {
    Some(turn) -> Some(#(ForSteps(turn.0), turn.1.end.id, turn.1.end.seq + 1))
    None ->
      case model.view.older, below_origin(model, window, cut) {
        Pressed, Some(#(leaf, before)) -> Some(#(ForOlder, leaf, before))
        Pressed, None | Unasked, _ -> None
      }
  }
}

// The lowest sequence the cut holds, or the cursor when it holds nothing. A
// strand the cut holds none of is below it, so the cut is not read again.
fn below_cut(cut: snapshot.Captured) -> Int {
  case list.last(cut.window.items) {
    Ok(oldest) -> snapshot.sequence(oldest)
    Error(Nil) -> cut.next_seq
  }
}

// The strand's newest record, and the sequence to read below, when the page
// holds nothing of the strand: no closed turn, and none of its records in the
// window, though its leaf names one. The leaf is below the cut, which is the
// newest records of the whole session. A leaf is the identity of a record; the
// note a cut gives for a strand it does not list is not one, and names nothing to
// read.
fn unread_tail(
  model: Model(socket),
  window: Window,
  cut: snapshot.Captured,
) -> Option(#(String, Int)) {
  case model.view.floor, model.view.sealed, window.records, window.unloaded {
    Unheld, [], [], Some(leaf) ->
      case ids.parse_entry_id(leaf) {
        Ok(_) -> Some(#(leaf, below_cut(cut)))
        Error(_) -> None
      }
    Unheld, [], [], None
    | Unheld, [], [_, ..], _
    | Unheld, [_, ..], _, _
    | Reached, _, _, _
    -> None
  }
}

// The first open fold of a closed turn whose steps the page does not hold.
fn missing_steps(model: Model(socket)) -> Option(#(Int, turn_ledger.Sealed)) {
  list.find_map(model.view.folds, fn(fold) {
    case
      dict.has_key(model.view.steps, fold),
      sealed_of(model.view.sealed, fold)
    {
      False, Ok(turn) -> Ok(#(fold, turn))
      True, _ | False, Error(Nil) -> Error(Nil)
    }
  })
  |> option.from_result
}

// Where a read for the turns below the page starts: the parent of the oldest
// turn the page holds, which is a closed turn's first record's parent, or the
// window's own when nothing is closed. A page that holds nothing starts at the
// strand's leaf.
fn below_origin(
  model: Model(socket),
  window: Window,
  cut: snapshot.Captured,
) -> Option(#(String, Int)) {
  case
    list.last(model.view.sealed),
    window.unloaded,
    list.last(window.records)
  {
    Ok(oldest), _, _ ->
      option.map(oldest.parent, fn(parent) { #(parent, oldest.first_seq) })
    Error(Nil), Some(parent), Ok(first) -> Some(#(parent, first.entry.seq))
    Error(Nil), Some(_), Error(Nil) -> unread_tail(model, window, cut)
    Error(Nil), None, _ -> None
  }
}

// The row limit for how much history the page holds.
fn limit(paging: Paging) -> Int {
  case paging {
    Tail -> live_rows
    Paged | Full | Crowded -> held_rows
  }
}

// The newest blocks of one turn, given newest first, that fit `limit`, and
// at least one.
fn newest_blocks(
  newest_first: List(transcript_lines.Block),
  limit: Int,
  rows: Int,
  kept: List(transcript_lines.Block),
) -> List(transcript_lines.Block) {
  case newest_first {
    [] -> kept
    [block, ..rest] -> {
      let rows = rows + list.length(block.rows)
      case rows > limit, kept {
        True, [_, ..] -> kept
        True, [] | False, _ -> newest_blocks(rest, limit, rows, [block, ..kept])
      }
    }
  }
}

fn row_count(blocks: List(transcript_lines.Block)) -> Int {
  list.fold(blocks, 0, fn(sum, block) { sum + list.length(block.rows) })
}

// The agent strip from the roster, the agent rows and the cache ledger, as
// of the shared record's clock. Which strands are listed and what each line
// says is `agent_roster.chips`; which outlook may be shown is
// `cache_watch.shown`.
fn restripped(model: Model(socket)) -> Model(socket) {
  Model(
    ..model,
    view: View(
      ..model.view,
      strip: strip_of(model.shared),
      stripped: stripped_of(model.shared),
    ),
  )
}

fn strip_of(shared: Session(socket)) -> strip.Strip {
  let chips =
    agent_roster.chips(shared.roster, shared.agent_rows, shared.active_strand)
  let chip = fn(line: agent_roster.Line) {
    let row = agent_row(shared, line.id)
    strip.Chip(
      line:,
      hue: turns.hue(shared.strands, line.id),
      cache: outlook(shared, line.id),
      running_ms: running_ms(shared, line.id),
      model: option.map(row, fn(row) { row.model }) |> option.unwrap(""),
      own_model: apart_from_main(shared, line.id),
      recent: option.map(row, fn(row) { row.recent }) |> option.unwrap([]),
      answer: row |> option.then(answer_line),
    )
  }
  let #(drawn, older) = list.split(chips.settled, strip.settled_limit)
  strip.Strip(
    chips: list.map(chips.listed, chip),
    advisor: option.map(chips.advisor, chip),
    settled: list.map(drawn, settled_chip(shared, _)),
    earlier: list.length(older),
    followed: shared.active_strand,
  )
}

// A settled strand's card. It says how the strand ended and nothing that
// changes: the roster's clock for a finished operation keeps counting, so its
// elapsed figure would grow after the strand stopped, and no capture records
// when an operation ended. The line's elapsed time is therefore dropped, and
// the figures only a live strand has (cache outlook, running time) are left
// out with it.
fn settled_chip(
  shared: Session(socket),
  line: agent_roster.Line,
) -> strip.Chip {
  strip.Chip(
    line: agent_roster.Line(..line, elapsed_s: None),
    hue: turns.hue(shared.strands, line.id),
    cache: None,
    running_ms: None,
    model: "",
    own_model: None,
    recent: [],
    answer: None,
  )
}

// The catalogue's name for a strand's model, read from the capture the page
// draws (`agent_view.catalogue_name`), or nothing before the first capture.
fn model_of(shared: Session(socket), strand: String) -> Option(String) {
  option.then(shared.captured, fn(shown) {
    agent_view.catalogue_name(shown.1, strand)
  })
}

// The strand's model name when it is not the main strand's. A strand with no
// configuration in the capture, or a capture with none for `main`, has no
// difference to report, since an unknown model is not evidence of another one.
fn apart_from_main(shared: Session(socket), strand: String) -> Option(String) {
  case model_of(shared, agent_roster.primary), model_of(shared, strand) {
    Some(main), Some(own) if own != main -> Some(own)
    _, _ -> None
  }
}

// The first line of a strand's latest answer, or nothing while it has given
// none: the row's excerpt is only an answer when it names the entry it came
// from, and `agent_view` words the excerpt of an entry outside the loaded
// history as unavailable, which is not an answer either.
fn answer_line(row: agent_view.Row) -> Option(String) {
  case row.update_entry, row.update {
    None, _ -> None
    Some(_), update if update == agent_view.update_unavailable -> None
    Some(_), update -> Some(text_hygiene.single_line(update))
  }
}

// A strand's agent row, which carries what its own view shows beyond the
// roster's line: the model it runs on and the tools it ran lately.
fn agent_row(shared: Session(socket), id: String) -> Option(agent_view.Row) {
  shared.agent_rows
  |> list.find(fn(row) { row.id == id })
  |> option.from_result
}

// How long a strand's current operation has run, on the roster's clock.
fn running_ms(shared: Session(socket), id: String) -> Option(Int) {
  shared.agent_rows
  |> list.find(fn(row) { row.id == id })
  |> option.from_result
  |> option.then(agent_roster.running_ms(shared.roster, _))
}

// A strand the capture lists with a live phase is running, which is the
// terminal's test too, and `cache_watch.shown` says nothing for it.
fn outlook(
  shared: Session(socket),
  id: String,
) -> Option(#(cache_miss.Outlook, String)) {
  let activity = case
    list.find(shared.strands, fn(listed) { listed.id == id })
  {
    Ok(protocol.Strand(live_phase: Some(_), ..)) -> cache_watch.Running
    Ok(protocol.Strand(live_phase: None, ..)) | Error(Nil) ->
      cache_watch.Resting
  }
  cache_watch.shown(shared.cache, id, activity, shared.stamp.now_ms)
  |> option.map(fn(held) { #(held, cache_miss.outlook_label(held)) })
}

// A tick's part in the strip. The browser counts each chip's elapsed time,
// so a second passing redraws nothing; the strip is rebuilt only when a
// drawn cache label changed, which is once a minute at most until a
// countdown's last minute. An idle page's tick therefore leaves the strip
// as the same value and its memoized subtree is not diffed. The timer fires
// only when the lane is due, so a label can lag by up to one refresh
// interval. A countdown label is an upper bound on what remains, so a late
// one still states something true. The labels are compared chip by chip
// rather than by rebuilding the strip, which would redo every line's text
// on every tick.
fn label_moved(model: Model(socket)) -> Bool {
  let shared = model.shared
  list.any(chips(model.view.strip), fn(chip) {
    option.map(chip.cache, fn(held) { held.1 })
    != option.map(outlook(shared, chip.line.id), fn(held) { held.1 })
  })
}

// Every chip of a strip, the advisor's included.
fn chips(strip: strip.Strip) -> List(strip.Chip) {
  case strip.advisor {
    Some(advisor) -> list.append(strip.chips, [advisor])
    None -> strip.chips
  }
}

// The connection's status follows the lane. A cut makes a connecting page
// follow, a lane that ended makes it disconnected, and a disconnected page
// stays so: the last drawn cut is what it keeps showing.
fn statused(model: Model(socket)) -> Model(socket) {
  let status = case
    model.view.status,
    model.shared.ended,
    model.shared.captured
  {
    Ended(_), _, _ -> model.view.status
    _, Some(reason), _ ->
      Ended(ending.from_reason(reason, otherwise: ending.ConnectionFailed))
    Connecting, None, Some(_) -> Connected
    Connecting, None, None | Connected, None, _ -> model.view.status
  }
  Model(..model, view: View(..model.view, status:))
}

// --- what the operator does ------------------------------------------------

/// Submits an operator's text to the page's strand through the shared
/// step's command arm.
///
/// Empty text and text over `prompt_limit` are refused with a notice
/// before they become a command, because they are the page socket's limits
/// and not the session's. Empty text is a prompt when it carries images. The
/// images are the browser's claim, each the base64 text `<loom-attach>`
/// submitted: `web_view/image.admit` decodes and bounds them and reads each
/// one's type from its bytes, and one that fails refuses the whole prompt with
/// a notice, so nothing is sent that the operator did not see accepted. A
/// steer carries no images, as in the terminal, where an image is new prompt
/// content and never live-turn steering. The draft is then parsed as the
/// terminal parses it (`command.parse_with_skills`). A session command, which includes an
/// ordinary prompt, goes to the step (`commands.act`) and what the step
/// decides is folded back as its notice. A command that names a terminal
/// surface (`/help`, `/models`, `/sessions` and the rest) is refused with a
/// notice: the page has no such surface, and sending it to the model as a
/// prompt would run the words as an instruction.
///
/// ## Examples
///
/// ```gleam
/// // component.submit(model, "inspect the tree", operator.Prompt, [])
/// ```
pub fn submit(
  model: Model(socket),
  text: String,
  delivery: operator.Delivery,
  images: List(String),
) -> #(Model(socket), Effect(Msg(socket))) {
  case string.trim(text), images, string.byte_size(text) > prompt_limit {
    "", [], _ -> refused_draft(model, "Nothing to send.")
    _, _, True ->
      refused_draft(
        model,
        "The draft is longer than the page sends ("
          <> int.to_string(prompt_limit)
          <> " bytes).",
      )
    _, _, False ->
      case web_image.admit(images) {
        Error(notice) -> refused_draft(model, notice)
        Ok(attached) -> submitting(model, text, delivery, attached)
      }
  }
}

// A composer submit the page refused with the draft kept: the refusal, and
// the count the composer's element reads to take its pending line down
// (`refusals`). Only the composer's paths count, since the element's line is
// the composer's draft: a stale approval, a reply that found no message or a
// control form refused are told in the notice and must leave a steer the
// lane holds in flight, or a second press would send it twice.
fn refused_draft(
  model: Model(socket),
  text: String,
) -> #(Model(socket), Effect(Msg(socket))) {
  let #(after, effects) = refused(model, text)
  #(
    Model(..after, view: View(..after.view, refusals: after.view.refusals + 1)),
    effects,
  )
}

// A draft that passed the page's own limits, with the images that passed
// `web_image.admit`, parsed and handed to the shared step.
//
// The step sends an image prompt from the composer's attachments, which are
// the terminal's state for images not yet sent. The page keeps none between
// submits: each submit's images are set here as the whole of them and cleared
// after, whatever the step decided, so a refused submit whose element still
// holds its images sends them once, on the next submit, and never twice.
fn submitting(
  model: Model(socket),
  text: String,
  delivery: operator.Delivery,
  attached: List(pasted_image.Image),
) -> #(Model(socket), Effect(Msg(socket))) {
  case attached, delivery {
    [_, ..], operator.Steer ->
      refused_draft(
        model,
        "Images go with Send or Queue, not Steer. Nothing was sent.",
      )
    _, _ ->
      case page_command(command.parse_with_skills(text, model.shared.skills)) {
        Error(notice) -> refused_draft(model, notice)
        Ok(session) -> {
          let attaching =
            Shared(
              ..model.shared,
              attachments: list.map(attached, composer.ImageAttachment),
            )

          // The lane's admission check is read before the command runs, as
          // `sent_from_form` reads it: a draft the check refuses stays in
          // the editor, and the composer's element is told so by the count.
          // A draft the lane admits but holds behind a read is not refused.
          let kept = case outbound.mutation_refusal(model.shared, session) {
            Some(_) -> 1
            None -> 0
          }
          let #(next, effects) =
            commanded(
              Model(..model, shared: attaching),
              msg.Submit(draft: text, command: session, delivery:),
            )
          #(
            Model(
              shared: Shared(..next.shared, attachments: []),
              view: View(..next.view, refusals: next.view.refusals + kept),
            ),
            effects,
          )
        }
      }
  }
}

/// The session command a parsed draft is on the page, or the notice saying
/// why the page does not carry it out.
///
/// This is the one place that names what the page does not run. A terminal
/// surface (`/help`, `/models`, `/sessions` and the rest) has no surface
/// here. `/add-dir` and `/add-write-dir` name a path on the daemon's host,
/// which a browser reader, who may be on another machine, can neither see
/// nor pick, and they are the only commands that widen the session's
/// filesystem scope. Every other session command runs as it does in the
/// terminal.
///
/// ## Examples
///
/// ```gleam
/// assert result.is_error(component.page_command(command.parse("/models")))
/// ```
pub fn page_command(
  parsed: command.Command,
) -> Result(command.Session, String) {
  case parsed {
    command.Surface(_) ->
      Error(
        "That command opens a terminal surface, which the page does not have. Nothing was sent.",
      )

    command.Session(command.AddDirectory(..)) ->
      Error(
        "Add directories from a terminal on the daemon's host. Nothing was sent.",
      )

    command.Session(session) -> Ok(session)
  }
}

/// Answers the escalation the page drew as `id` at `seq`, through the
/// shared step's command arm.
///
/// The answer is sent only for the record with exactly that identity and
/// sequence, still pending (`operator.drawn`); a record that moved after
/// the card was drawn is not decided, and the page says so.
///
/// ## Examples
///
/// ```gleam
/// // component.decide(model, "esc-1", 12, component.Deny)
/// ```
pub fn decide(
  model: Model(socket),
  id: String,
  seq: Int,
  answer: Answer,
) -> #(Model(socket), Effect(Msg(socket))) {
  case operator.drawn(model.shared.approvals, id, seq) {
    Error(Nil) ->
      refused(
        model,
        "That approval changed after it was drawn, so nothing was decided.",
      )
    Ok(record) -> {
      case answer, may_remember(model) {
        AllowForSession, False ->
          refused(
            model,
            "Only the session owner can allow for the session, so nothing was decided.",
          )
        _, _ -> decided(model, record, answer)
      }
    }
  }
}

// The decision on a record the page drew, now that the answer is one this
// page may give.
fn decided(
  model: Model(socket),
  record: approval.Review,
  answer: Answer,
) -> #(Model(socket), Effect(Msg(socket))) {
  {
    {
      let choice = case answer {
        AllowOnce -> operator.AllowOnce
        AllowForSession -> operator.AllowForSession
        Deny -> operator.Deny
      }
      let #(model, effects) =
        commanded(model, msg.Decide(review: record, choice:))

      // An approval that remembers something changes the list, so the page
      // reads it again once the lane has answered the approval.
      #(owing_permissions(model, answer), effects)
    }
  }
}

// The list is owed a fresh read after an approval for the session. A refused
// approval changed nothing, and the read it earns is harmless.
fn owing_permissions(model: Model(socket), answer: Answer) -> Model(socket) {
  case answer {
    AllowForSession ->
      Model(
        ..model,
        shared: Shared(
          ..model.shared,
          remembered_refresh: worktree_view.Requested,
        ),
      )
    AllowOnce | Deny -> model
  }
}

/// Marks the list of remembered permissions as wanted when the page has never
/// read it, or last wanted it `holding.refresh_ms` or more ago.
///
/// The operator's page calls this after every message it takes. It is the
/// operator's page alone that does, because the gateway admits the read to an
/// attachment that may approve and refuses it to an observer's; the observer's
/// component never calls it. The shared step sends the read once the lane is
/// ready for it (`surfaces.service_remembered_read`), so this only says that
/// one is owed.
///
/// ## Examples
///
/// ```gleam
/// // component.want_permissions(model)
/// ```
pub fn want_permissions(model: Model(socket)) -> Model(socket) {
  let at = model.view.transport.now()
  case
    may_remember(model),
    holding.due(model.view.holding, at),
    model.shared.remembered_refresh
  {
    False, _, _ -> model
    True, True, worktree_view.Settled ->
      Model(
        shared: Shared(
          ..model.shared,
          remembered_refresh: worktree_view.Requested,
        ),
        view: View(
          ..model.view,
          holding: holding.wanted(model.view.holding, at),
        ),
      )
    True, True, worktree_view.Requested | True, False, _ -> model
  }
}

/// Whether this page may remember permissions for the session, list what is
/// remembered and forget it: only the daemon's owner's page may
/// (protocol-change/073). Members keep allow once and deny. The page reads it
/// from the standing the daemon derived from the authenticated principal when
/// the page opened, and the gateway refuses the same commands from a member
/// whatever a page sends, so this is the offer and not the gate.
///
/// ## Examples
///
/// ```gleam
/// // component.may_remember(model)
/// ```
pub fn may_remember(model: Model(socket)) -> Bool {
  case model.view.reader {
    DaemonOwner -> True
    Participant -> False
  }
}

/// The list of remembered permissions as the daemon last gave it, or `None`
/// while the page has not read it.
///
/// ## Examples
///
/// ```gleam
/// // component.permissions_kept(model)
/// ```
pub fn permissions_kept(model: Model(socket)) -> Option(kept.Board) {
  model.shared.remembered
}

/// What the page holds about the list: the open question and the sign-ins the
/// daemon said have ended.
///
/// ## Examples
///
/// ```gleam
/// // component.permissions_state(model)
/// ```
pub fn permissions_state(model: Model(socket)) -> holding.State {
  model.view.holding
}

/// Asks the daemon which sign-ins the list's permissions came from have ended,
/// when the list changed from `before` and names any, and keeps the answer the
/// last one gave until then.
///
/// The ask is the daemon's task and its answer arrives as `LoginsJudged`, so
/// the page's runtime never waits for the registry. An observer's page has no
/// capability and asks nothing.
///
/// ## Examples
///
/// ```gleam
/// // component.judge_logins(before, after)
/// ```
pub fn judge_logins(
  before: Model(socket),
  after: Model(socket),
) -> #(Model(socket), Effect(Msg(socket))) {
  case
    after.shared.remembered == before.shared.remembered,
    after.view.transport.logins,
    after.shared.remembered
  {
    True, _, _ | False, None, _ | False, _, None -> #(after, effect.none())
    False, Some(ask), Some(board) ->
      case holding.logins(board) {
        [] -> #(
          Model(
            ..after,
            view: View(
              ..after.view,
              holding: holding.judged(after.view.holding, []),
            ),
          ),
          effect.none(),
        )
        logins -> #(after, judging(ask, logins))
      }
  }
}

fn judging(
  ask: fn(List(holding.Login), fn(List(holding.Login)) -> Nil) -> Nil,
  logins: List(holding.Login),
) -> Effect(Msg(socket)) {
  use dispatch <- effect.from
  ask(logins, fn(ended) { dispatch(LoginsJudged(ended)) })
}

/// Opens the question for one forget, which sends nothing. Only one question
/// is open at a time, so asking another replaces it.
///
/// The question is the request as the list looked when its button was drawn,
/// with the sequence that list carried. Confirming sends that and nothing the
/// browser chose, and a list that moved in between makes the daemon refuse it
/// rather than forget what the operator never saw.
///
/// ## Examples
///
/// ```gleam
/// // component.ask_forget(model, armed)
/// ```
pub fn ask_forget(model: Model(socket), armed: holding.Armed) -> Model(socket) {
  case may_remember(model) {
    True ->
      Model(
        ..model,
        view: View(
          ..model.view,
          holding: holding.arm(model.view.holding, armed),
        ),
      )
    False -> model
  }
}

/// Closes the question without sending anything.
///
/// ## Examples
///
/// ```gleam
/// // component.cancel_forget(model)
/// ```
pub fn cancel_forget(model: Model(socket)) -> Model(socket) {
  Model(
    ..model,
    view: View(..model.view, holding: holding.disarm(model.view.holding)),
  )
}

/// Sends the forget the open question armed, through the shared step like any
/// other command, and closes the question. With no question open it does
/// nothing, so a confirm the page did not draw changes nothing.
///
/// ## Examples
///
/// ```gleam
/// // component.confirm_forget(model)
/// ```
pub fn confirm_forget(
  model: Model(socket),
) -> #(Model(socket), Effect(Msg(socket))) {
  case model.view.holding.armed, may_remember(model) {
    None, _ | _, False -> #(model, effect.none())
    Some(open), True ->
      commanded(cancel_forget(model), msg.Forget(forget: open.forget))
  }
}

/// Runs one of the page's controls through the shared step's command arm.
///
/// The goal's three buttons are `/goal pause`, `/goal resume` and
/// `/goal clear`. The fork form holds text the operator typed, and that
/// text becomes the command exactly as it would in the composer: it is put
/// after `/fork ` and parsed with `command.parse`, so the name and every
/// limit are the command's own and the page holds no second list of them.
/// What the parse returns is checked against what the form is for. A fork
/// form yields a fork or the command's own complaint that a name is missing.
///
/// A control's command has no draft (`msg.Control`), so it leaves whatever
/// the operator is typing in the composer where it is. The forms are a
/// different matter, since the text in them is the command: they are cleared
/// once the lane accepts the command (sent, or queued behind a read) and kept
/// when the command was refused, so a refusal costs the operator nothing to
/// retry. A command queued behind a read shows the shared step's waiting
/// notice, which is the terminal's wording.
///
/// ## Examples
///
/// ```gleam
/// // component.control(model, component.Fork("try-a-cache"))
/// ```
pub fn control(
  model: Model(socket),
  control: Control,
) -> #(Model(socket), Effect(Msg(socket))) {
  case control {
    PauseGoal -> commanded(model, msg.Control(command: command.GoalPause))
    ResumeGoal -> commanded(model, msg.Control(command: command.GoalResume))
    ClearGoal -> commanded(model, msg.Control(command: command.GoalClear))

    // A new press forgets the last refusal, which the panel keeps drawn until
    // then; a fresh one comes back if the daemon refuses again.
    CompactStrand ->
      commanded(
        Model(
          ..model,
          shared: Shared(
            ..model.shared,
            context: context_view.compact_asked(model.shared.context),
          ),
        ),
        msg.Control(command: command.Compact),
      )
    Fork(name:) -> written(model, "/fork ", name, forking)
  }
}

// A form's text as the command it is for, or the notice saying it is not
// one. Text over the page's limit is refused as a draft is.
fn written(
  model: Model(socket),
  verb: String,
  text: String,
  accept: fn(command.Command) -> Result(command.Session, String),
) -> #(Model(socket), Effect(Msg(socket))) {
  case string.byte_size(text) > prompt_limit {
    True ->
      refused(
        model,
        "The text is longer than the page sends ("
          <> int.to_string(prompt_limit)
          <> " bytes).",
      )
    False ->
      case accept(command.parse(verb <> text)) {
        Error(notice) -> refused(model, notice)
        Ok(session) -> sent_from_form(model, session)
      }
  }
}

// Runs a form's command, and counts the form as sent once the lane accepts
// the command, whether it went out at once or was queued behind a read.
//
// Acceptance is decided by the step's own admission check, before the command
// runs (`outbound.mutation_refusal`), and not by whether a frame has left. A
// lane that is waiting for a read's reply admits a mutation and queues it, so
// its request identity does not move until the reply lands and the queued
// frame is sent. Reading that as a refusal would keep the text in the form
// after the command was accepted, and the operator would send it again. A
// command that is not a mutation (the complaint that a name is missing) is
// never accepted, and neither is one the check refuses, so those keep the
// text and the notice says why.
fn sent_from_form(
  model: Model(socket),
  session: command.Session,
) -> #(Model(socket), Effect(Msg(socket))) {
  let accepted = case
    outbound.mutation_refusal(model.shared, session),
    outbound.mutating_submission(model.shared, session)
  {
    None, True -> True
    Some(_), _ | None, False -> False
  }
  let #(after, effects) = commanded(model, msg.Control(command: session))
  case accepted {
    True -> #(
      Model(
        ..after,
        view: View(..after.view, sent_forms: after.view.sent_forms + 1),
      ),
      effects,
    )
    False -> #(after, effects)
  }
}

// The fork form's words: a fork, or the command's complaint that the name is
// missing. Nothing else can follow `/fork `.
fn forking(parsed: command.Command) -> Result(command.Session, String) {
  case parsed {
    command.Session(command.Fork(_) as fork) -> Ok(fork)
    command.Session(command.MissingArgument(_) as missing) -> Ok(missing)
    command.Session(_) | command.Surface(_) ->
      Error("Type a name for the fork.")
  }
}

/// Puts a reply to the peer message drawn under `key` in the composer.
///
/// The terminal has no command that answers a peer. A peer's message is
/// stored in this session's transcript, and the model answers it by calling
/// its `peer_send` tool under the owner's grant of a link (protocol 048), so
/// the operator's part is an ordinary prompt asking for the reply. This
/// drafts the start of that prompt, naming the peer, and leaves the rest to
/// the operator, who reads it and sends it with Send or Steer like any other
/// draft. It goes into the composer the way a returned prompt does
/// (`Returned`): put in an empty editor, or after what the operator has
/// already typed, and never over it. Nothing is sent by this call.
///
/// The peer's identity is read from the page's own piece for `key`, which is
/// the daemon's host-bound origin, and the page holds no other copy. A key
/// no piece has (the message was cut from the window) is refused with a
/// notice.
///
/// Each call adds one small entry to the list the composer's element reads,
/// which is a click's worth of text and is bounded by how often an operator
/// presses a button.
///
/// ## Examples
///
/// ```gleam
/// // component.reply(model, "0000000000000012")
/// ```
pub fn reply(
  model: Model(socket),
  key: String,
) -> #(Model(socket), Effect(Msg(socket))) {
  case list.find_map(model.view.pieces, peer_named(_, key)) {
    Error(Nil) ->
      refused(
        model,
        "That message is no longer on the page, so no reply was started.",
      )
    Ok(draft) -> {
      let number = model.view.returns + 1
      #(
        Model(
          shared: Shared(..model.shared, answer: ""),
          view: View(
            ..model.view,
            refusal: None,
            outcome: "A reply is in the composer. Add your words and send it.",
            returns: number,
            returned: list.append(model.view.returned, [
              Returned(number:, text: draft),
            ]),
          ),
        ),
        effect.none(),
      )
    }
  }
}

// The start of a prompt asking for a reply, when `piece` is the peer message
// drawn under `key`. The identity is the daemon's, and goes through the
// terminal's hygiene because the operator sends it on as text.
fn peer_named(piece: turns.Piece, key: String) -> Result(String, Nil) {
  case piece {
    turns.Peer(key: found, session:, strand:, ..) if found == key ->
      Ok(
        "Reply to the peer message from session "
        <> text_hygiene.single_line(session)
        <> ", strand "
        <> text_hygiene.single_line(strand)
        <> ", with peer_send: ",
      )
    turns.Peer(..)
    | turns.Sibling(..)
    | turns.Plain(..)
    | turns.Prompt(..)
    | turns.Work(..)
    | turns.Spawned(..)
    | turns.Returned(..)
    | turns.Nudged(..)
    | turns.Missed(..)
    | turns.Decided(..)
    | turns.Commentary(..) -> Error(Nil)
  }
}

// An input the page refused before it became a command. The refusal stays
// until the operator's next input.
fn refused(
  model: Model(socket),
  text: String,
) -> #(Model(socket), Effect(Msg(socket))) {
  #(
    Model(..model, view: View(..model.view, refusal: Some(text))),
    effect.none(),
  )
}

// One command through the step at the transport's own reading, which the
// request's deadline and the timer armed for it are measured from. What the
// step decided is folded back as its notice, and the composer's draft is
// counted as consumed when the command took it at dispatch. The facts the
// command recorded are the only ones this host reads, and it empties them
// after.
fn commanded(
  model: Model(socket),
  command: msg.Command,
) -> #(Model(socket), Effect(Msg(socket))) {
  let at = model.view.transport.now()

  // The step words the outcome into the shared notice, and any later event
  // may replace it, so it is read at once. The notice and the last reply are
  // emptied first so that a command which says nothing leaves nothing to
  // read, and not the words of whatever the session said before it.
  let #(shared, effects) =
    step.update(
      Shared(..model.shared, notice: "", answer: ""),
      msg.Input(at: stamp(at), event: msg.Acted(command)),
    )
  let consumed = case list.any(shared.surface_facts, took_draft) {
    True -> model.view.consumed + 1
    False -> model.view.consumed
  }

  finished(
    Model(
      shared:,
      view: View(..model.view, refusal: None, outcome: shared.notice, consumed:),
    ),
    effects,
    at,
  )
}

fn took_draft(fact: session_model.SurfaceFact) -> Bool {
  case fact {
    session_model.DraftTaken(..) -> True
    _ -> False
  }
}

/// Asks the daemon to open another session for this page's operator, when a
/// sidebar row or a peer message's "Open" button was pressed.
///
/// A switch is a navigation, not a change of this page. The page asks the
/// daemon for a ticket for the session `target` names, and the answer
/// arrives as `Linked`: a ticket becomes the address `<loom-switch>` moves
/// the browser to, and a refusal is worded in the composer's notice. This
/// page's lane, draft and record are not touched, so the page left behind is
/// as it was and stays open until its own deadline. The session named is the
/// message's, drawn from the catalogue's list and never from the browser or
/// from a peer's text, and the daemon checks it again against the
/// principal's memberships, so a stale row asks for nothing it may not have.
///
/// Pressing the row of the session already on screen asks for nothing.
///
/// This is an operator's message. The observer's page draws no sidebar and
/// carries no handler that reaches it, and the daemon's answer for an
/// observer's page is a refusal all the same
/// (`client/daemon/ui_socket.opened_for`).
///
/// ## Examples
///
/// ```gleam
/// // component.switch_to(model, "0198a2f4-7c3b-7e10-8d5a-3f9b2c4e6a71")
/// ```
pub fn switch_to(
  model: Model(socket),
  target: String,
) -> #(Model(socket), Effect(Msg(socket))) {
  case target == model.shared.session {
    True -> #(model, effect.none())
    False -> #(
      Model(
        ..model,
        view: View(..model.view, refusal: None, outcome: "Asking to open it."),
      ),
      asking(model.view.transport, target),
    )
  }
}

// The daemon's answer, in the component's process, as a message.
fn asking(transport: Transport(socket), target: String) -> Effect(Msg(socket)) {
  use dispatch <- effect.from
  dispatch(Linked(transport.open(target)))
}

/// Asks the daemon to resume a saved session for this page's operator, when a
/// saved sidebar row was pressed (protocol-change/065, the third pull request).
///
/// The daemon starts a task that opens the session and waits for it, so this
/// returns at once and the page keeps drawing; the answer arrives as `Linked`,
/// which departs for the session's page or words why it could not. The row
/// reads "opening" until then, and a second press while one is out asks
/// nothing, so one press opens at most one session. The session named is the
/// message's, drawn from the catalogue's list, and the daemon checks the
/// principal's role in it again, so a stale row, or a row of a session the
/// principal observes, resumes nothing. A press for the session on screen, or
/// for a session the page's list does not show as saved, asks nothing.
///
/// ## Examples
///
/// ```gleam
/// // component.resume(model, "0198a2f4-7c3b-7e10-8d5a-3f9b2c4e6a71")
/// ```
pub fn resume(
  model: Model(socket),
  target: String,
) -> #(Model(socket), Effect(Msg(socket))) {
  case model.view.resuming, resumable(model, target) {
    None, True -> #(
      Model(
        ..model,
        view: View(
          ..model.view,
          resuming: Some(target),
          refusal: None,
          outcome: "Opening that session. It may take a moment.",
        ),
      ),
      resuming(model.view.transport, target),
    )
    Some(_), _ | None, False -> #(model, effect.none())
  }
}

// Whether the page's list shows `target` as a saved session that may be
// resumed. The daemon decides again; this keeps a frame that named a row the
// page never drew from reaching it.
fn resumable(model: Model(socket), target: String) -> Bool {
  list.any(model.view.groups, fn(group) {
    list.any(group.entries, fn(entry) {
      entry.id == target && entry.residency == sessions.Saved
    })
  })
}

// Starts the daemon's task and returns at once. The task's answer arrives
// later as `Linked`, dispatched from the task's own process.
fn resuming(
  transport: Transport(socket),
  target: String,
) -> Effect(Msg(socket)) {
  use dispatch <- effect.from
  transport.resume(target, fn(answer) { dispatch(Linked(answer)) })
}

/// The saved session whose resume is out, if one is, which the sidebar draws
/// as opening.
///
/// ## Examples
///
/// ```gleam
/// assert component.resuming_session(model) == None
/// ```
pub fn resuming_session(model: Model(socket)) -> Option(String) {
  model.view.resuming
}

/// Asks the daemon for a ticket to the principal's home page, when the "Home"
/// button was pressed.
///
/// The page sends nothing but the press. The daemon mints the ticket for this
/// page's own principal, with this page's ceiling and deadline, so the home it
/// opens can do no more than this page could, and the answer arrives as
/// `Homed`. A page with no capability to go home (`Transport.home` is `None`)
/// ignores the message: it draws no button, and a frame that named the path
/// anyway finds no handler. This page's lane and record are not touched, so
/// the page left behind stays open until its own deadline, as after a switch.
///
/// ## Examples
///
/// ```gleam
/// // component.going_home(model)
/// ```
pub fn going_home(
  model: Model(socket),
) -> #(Model(socket), Effect(Msg(socket))) {
  case model.view.transport.home {
    None -> #(model, effect.none())
    Some(ask) -> #(
      Model(
        ..model,
        view: View(
          ..model.view,
          refusal: None,
          outcome: "Asking for the home page.",
        ),
      ),
      homing(ask),
    )
  }
}

// The daemon's answer, in the component's process, as a message.
fn homing(ask: fn() -> sessions.Answer) -> Effect(Msg(socket)) {
  use dispatch <- effect.from
  dispatch(Homed(ask()))
}

/// The address `<loom-switch>` is to move the browser to, once the daemon has
/// minted a ticket for the session the operator chose, or for the home page.
/// `None` until then.
///
/// ## Examples
///
/// ```gleam
/// // component.departure(model) == None
/// ```
pub fn departure(model: Model(socket)) -> Option(String) {
  model.view.departure
}

/// Asks the daemon to invite a person to this page's session, when an owner
/// pressed one of the invitation control's buttons.
///
/// The page sends the role and nothing else. The daemon makes the invitation
/// as `loomd access invite` makes it, for this page's session, and its answer
/// arrives as `Invited`. The control is `Asking` until then, so a second press
/// while a request is with the daemon is ignored and one press mints at most
/// one invitation, and a control that is showing an invitation ignores a
/// press too: the owner hides the token first, so at most one is on screen.
/// A page that has no capability to invite (`Transport.invite` is `None`)
/// ignores the message, so a member's page is unchanged if one arrives, and
/// the observer's page, which draws no control, has no message that reaches
/// here at all.
///
/// ## Examples
///
/// ```gleam
/// // component.invite(model, invites.Observer)
/// ```
pub fn invite(
  model: Model(socket),
  role: invites.Role,
) -> #(Model(socket), Effect(Msg(socket))) {
  case model.view.transport.invite, model.view.share {
    Some(ask), invites.Ready | Some(ask), invites.Refused(..) -> #(
      Model(..model, view: View(..model.view, share: invites.Asking)),
      inviting(ask, role),
    )
    Some(_), invites.Asking
    | Some(_), invites.Showing(..)
    | Some(_), invites.Withheld
    | Some(_), invites.Unshareable
    | Some(_), invites.Bookmarked
    | Some(_), invites.BookmarkedPrivate
    | None, _
    -> #(model, effect.none())
  }
}

// The daemon's answer, in the component's process, as a message.
fn inviting(
  ask: fn(invites.Role) -> invites.Answer,
  role: invites.Role,
) -> Effect(Msg(socket)) {
  use dispatch <- effect.from
  dispatch(Invited(ask(role)))
}

// The daemon's answer to a request to invite. An invitation becomes what the
// control shows, and a refusal is worded in the control's own status line. An
// answer that arrives when no request is out was not asked for and is
// dropped, so the token is never taken into a state that is not waiting for
// it.
fn invited(model: Model(socket), answer: invites.Answer) -> Model(socket) {
  case model.view.share, answer {
    invites.Asking, invites.Minted(invitation:) ->
      Model(
        ..model,
        view: View(..model.view, share: invites.Showing(invitation)),
      )
    invites.Asking, invites.Declined(reason:) ->
      Model(..model, view: View(..model.view, share: invites.Refused(reason)))
    invites.Withheld, _
    | invites.Unshareable, _
    | invites.Bookmarked, _
    | invites.BookmarkedPrivate, _
    | invites.Ready, _
    | invites.Showing(..), _
    | invites.Refused(..), _
    -> model
  }
}

/// Hides an invitation once the owner has copied it, and clears a refusal's
/// words. The state that held the token is replaced, so nothing on the page
/// or in the component keeps it, and the buttons come back.
///
/// ## Examples
///
/// ```gleam
/// // component.dismiss_invitation(model)
/// ```
pub fn dismiss_invitation(model: Model(socket)) -> Model(socket) {
  case model.view.share {
    invites.Showing(..) | invites.Refused(..) ->
      Model(..model, view: View(..model.view, share: invites.Ready))
    invites.Withheld
    | invites.Unshareable
    | invites.Bookmarked
    | invites.BookmarkedPrivate
    | invites.Ready
    | invites.Asking -> model
  }
}

/// The owner's first press on "Make shareable": the page asks the question in
/// the button's place and changes nothing else. Only a page that drew the button
/// (`Idle`, or `Refused` after an earlier try) arms, so a frame that names the
/// press on any other page asks nothing.
///
/// ## Examples
///
/// ```gleam
/// // component.arm_shareable(model)
/// ```
pub fn arm_shareable(model: Model(socket)) -> Model(socket) {
  case model.view.moving {
    shareables.Idle | shareables.Refused(..) ->
      Model(..model, view: View(..model.view, moving: shareables.Confirming))
    shareables.Withheld | shareables.Confirming | shareables.Making -> model
  }
}

/// The question's Cancel: the button comes back and nothing was asked.
///
/// ## Examples
///
/// ```gleam
/// // component.disarm_shareable(model)
/// ```
pub fn disarm_shareable(model: Model(socket)) -> Model(socket) {
  case model.view.moving {
    shareables.Confirming | shareables.Refused(..) ->
      Model(..model, view: View(..model.view, moving: shareables.Idle))
    shareables.Withheld | shareables.Idle | shareables.Making -> model
  }
}

/// The question's confirm: asks the daemon to make the page's session
/// shareable, and only from the question. A press that arrives in any other
/// state, or on a page with no capability, asks nothing, so one confirm starts
/// at most one task and a page that never asked the question cannot start one.
///
/// The task stops the session, which ends this page as any stop does, so the
/// answer is for the page that outlives the stop: a refusal before it. The page
/// that does not reaches the ended notice the session's stop has always drawn.
///
/// ## Examples
///
/// ```gleam
/// // component.make_shareable(model)
/// ```
pub fn make_shareable(
  model: Model(socket),
) -> #(Model(socket), Effect(Msg(socket))) {
  case model.view.moving, model.view.transport.shareable {
    shareables.Confirming, Some(ask) -> #(
      Model(..model, view: View(..model.view, moving: shareables.Making)),
      sharing(ask),
    )
    shareables.Withheld, _
    | shareables.Idle, _
    | shareables.Making, _
    | shareables.Refused(..), _
    | shareables.Confirming, None
    -> #(model, effect.none())
  }
}

// Starts the daemon's task and returns at once. The answer arrives later as
// `MadeShareable`, dispatched from the task's own process.
fn sharing(ask: fn(fn(grants.Answer) -> Nil) -> Nil) -> Effect(Msg(socket)) {
  use dispatch <- effect.from
  ask(fn(answer) { dispatch(MadeShareable(answer)) })
}

// The daemon's answer to the task. A session made shareable draws the
// invitation buttons in the sentence's place; a refusal is worded in the
// control's own status line, in the reason's fixed words. An answer that arrives
// when no task is out was not asked for and is dropped.
fn made_shareable(
  model: Model(socket),
  answer: grants.Answer,
) -> Model(socket) {
  case model.view.moving, answer {
    shareables.Making, grants.Changed ->
      Model(
        ..model,
        view: View(
          ..model.view,
          moving: shareables.Withheld,
          share: invites.Ready,
        ),
      )
    shareables.Making, grants.Declined(reason:) ->
      Model(
        ..model,
        view: View(..model.view, moving: shareables.Refused(reason)),
      )
    shareables.Making, grants.Claimed(..)
    | shareables.Withheld, _
    | shareables.Idle, _
    | shareables.Confirming, _
    | shareables.Refused(..), _
    -> model
  }
}

/// A sidebar row's archive button: the page opens that row's question and
/// sends nothing (protocol-change/065, the addendum on archiving from the
/// sidebar). Which action the question is for is read from the row's residency
/// in the page's own list, so the message names nothing but the session.
///
/// A press asks nothing, and opens no question, when the page has no
/// capability, is not connected, names the session on screen (stopping it would
/// end the page that asked), names a session the list does not show, or while a
/// request is out.
///
/// ## Examples
///
/// ```gleam
/// // component.ask_archive(model, "0198a2f4-7c3b-7e10-8d5a-3f9b2c4e6a71")
/// ```
pub fn ask_archive(model: Model(socket), target: String) -> Model(socket) {
  case archivable(model, target), model.view.archiving {
    Ok(action), actions.Calm | Ok(action), actions.Confirming(..) ->
      Model(
        ..model,
        view: View(
          ..model.view,
          archiving: actions.Confirming(target, action),
          refusal: None,
        ),
      )
    Ok(_), actions.Working(..) | Error(Nil), _ -> model
  }
}

// The action a press on `target` means, when this page may ask it at all.
fn archivable(
  model: Model(socket),
  target: String,
) -> Result(actions.Action, Nil) {
  use _ <- result.try(option.to_result(model.view.transport.manage, Nil))
  use _ <- result.try(case model.view.status {
    Connected -> Ok(Nil)
    Connecting | Ended(_) -> Error(Nil)
  })
  use <- bool.guard(target == model.shared.session, Error(Nil))
  list.find_map(model.view.groups, fn(group) {
    list.find(group.entries, fn(entry) { entry.id == target })
  })
  |> result.map(archiving.action)
}

/// The sidebar question's confirm button: the page asks the daemon, and only
/// for the row that is asking and the action its question was opened for. Any
/// other press asks nothing, which is what makes a stale or forged
/// confirmation harmless. The request is the daemon's task, so this returns at
/// once and the answer arrives as `ManageAnswered`.
///
/// ## Examples
///
/// ```gleam
/// // component.confirm_archive(model, "0198a2f4-7c3b-7e10-8d5a-3f9b2c4e6a71")
/// ```
pub fn confirm_archive(
  model: Model(socket),
  target: String,
) -> #(Model(socket), Effect(Msg(socket))) {
  case
    archiving.confirmed(model.view.archiving, target),
    model.view.transport.manage,
    model.view.status
  {
    Ok(action), Some(ask), Connected -> #(
      Model(
        ..model,
        view: View(
          ..model.view,
          archiving: actions.Working(target, action),
          refusal: None,
          outcome: working_words(action),
        ),
      ),
      managing(ask, action, target),
    )
    Ok(_), _, _ | Error(Nil), _, _ -> #(model, effect.none())
  }
}

// What the notice says while the request is out: a running row is stopped
// first, so only that action says so.
fn working_words(action: actions.Action) -> String {
  case action {
    actions.StopArchive -> "Working on it. A running session is stopped first."
    actions.Archive | actions.Stop | actions.Delete -> "Working on it."
  }
}

/// The sidebar question's Cancel: the row is as it was.
///
/// ## Examples
///
/// ```gleam
/// // component.cancel_archive(model)
/// ```
pub fn cancel_archive(model: Model(socket)) -> Model(socket) {
  case model.view.archiving {
    actions.Confirming(..) ->
      Model(..model, view: View(..model.view, archiving: actions.Calm))
    actions.Calm | actions.Working(..) -> model
  }
}

// Starts the daemon's task and returns at once. The answer arrives later as
// `ManageAnswered`, dispatched from the task's own process.
fn managing(
  ask: fn(actions.Action, String, fn(actions.Answer) -> Nil) -> Nil,
  action: actions.Action,
  target: String,
) -> Effect(Msg(socket)) {
  use dispatch <- effect.from
  ask(action, target, fn(answer) { dispatch(ManageAnswered(answer)) })
}

// The daemon's answer ends the request, says what happened in the composer's
// notice in fixed words, and reads the list again, so the row is gone or
// changed in what the page draws. An answer that arrives when no request is
// out was not asked for and is dropped.
fn archive_answered(
  model: Model(socket),
  answer: actions.Answer,
) -> #(Model(socket), Effect(Msg(socket))) {
  let relist = listing(model.view.transport)
  case model.view.archiving, answer {
    actions.Working(..), actions.Done(action:) -> #(
      Model(
        ..model,
        view: View(
          ..model.view,
          archiving: actions.Calm,
          refusal: None,
          outcome: actions.done_words(action),
        ),
      ),
      relist,
    )
    actions.Working(..), actions.Declined(reason:) -> #(
      Model(
        ..model,
        view: View(
          ..model.view,
          archiving: actions.Calm,
          refusal: Some(actions.reason_words(reason)),
          outcome: "",
        ),
      ),
      relist,
    )
    actions.Calm, _ | actions.Confirming(..), _ -> #(model, effect.none())
  }
}

/// Where the sidebar's archive action stands, for the operator's view to draw.
///
/// ## Examples
///
/// ```gleam
/// assert component.archive_stage(model) == actions.Calm
/// ```
pub fn archive_stage(model: Model(socket)) -> actions.Stage {
  model.view.archiving
}

/// Whether the daemon handed this page the capability to archive, which is the
/// whole of whether its sidebar draws the action.
///
/// ## Examples
///
/// ```gleam
/// // component.may_archive(model) == False
/// ```
pub fn may_archive(model: Model(socket)) -> Bool {
  option.is_some(model.view.transport.manage)
}

/// What the make-shareable control is doing, for the operator's view to draw.
///
/// ## Examples
///
/// ```gleam
/// assert component.moving(model) == shareables.Withheld
/// ```
pub fn moving(model: Model(socket)) -> shareables.Move {
  model.view.moving
}

/// What the invitation control is doing, for the operator's view to draw.
///
/// ## Examples
///
/// ```gleam
/// // component.share(model) == invites.Withheld
/// ```
pub fn share(model: Model(socket)) -> invites.Share {
  model.view.share
}

/// Asks the daemon to rename this page's session, when an owner submitted the
/// rename control.
///
/// The page sends the text of the field and nothing else. The daemon names the
/// session, the principal and the right to ask itself, and its answer arrives as
/// `Renamed`. The control is `Asking` until then, so a second submit while a
/// request is with the daemon is ignored and one submit renames at most once. A
/// page that has no capability to rename (`Transport.rename` is `None`) ignores
/// the message, so a member's page is unchanged if one arrives, and the
/// observer's page, which draws no control, has no message that reaches here at
/// all. The request goes to a task of the daemon's own and this returns at
/// once, so the page keeps drawing while the registry answers.
///
/// ## Examples
///
/// ```gleam
/// // component.renaming(model, "review auth")
/// ```
pub fn renaming(
  model: Model(socket),
  name: String,
) -> #(Model(socket), Effect(Msg(socket))) {
  case model.view.transport.rename, model.view.renaming {
    Some(ask), renames.Ready
    | Some(ask), renames.Done
    | Some(ask), renames.Refused(..)
    -> #(
      Model(..model, view: View(..model.view, renaming: renames.Asking)),
      asking_rename(ask, name),
    )
    Some(_), renames.Asking | Some(_), renames.Withheld | None, _ -> #(
      model,
      effect.none(),
    )
  }
}

// Starts the daemon's task and returns at once. The task's answer arrives later
// as `Renamed`, dispatched from the task's own process.
fn asking_rename(
  ask: fn(String, fn(renames.Answer) -> Nil) -> Nil,
  name: String,
) -> Effect(Msg(socket)) {
  use dispatch <- effect.from
  ask(name, fn(answer) { dispatch(Renamed(answer)) })
}

// The daemon's answer to a request to rename. A stored name becomes the
// heading's and the sidebar's at once, in the page's own state, rather than
// waiting for the next read of the catalogue; the name is the one the daemon
// reports, never the one the browser sent. A refusal is worded in the
// control's own status line. An answer that arrives when no request is out was
// not asked for and is dropped.
fn renamed(model: Model(socket), answer: renames.Answer) -> Model(socket) {
  case model.view.renaming, answer {
    renames.Asking, renames.Renamed(name:) ->
      Model(
        ..model,
        view: View(
          ..model.view,
          renaming: renames.Done,
          renamed: model.view.renamed + 1,
          label: option.map(model.view.label, fn(label) {
            Label(..label, name:)
          }),
          groups: list.map(model.view.groups, fn(group) {
            sessions.Group(
              ..group,
              entries: list.map(group.entries, fn(entry) {
                case entry.id == model.shared.session {
                  True -> sessions.Entry(..entry, name:)
                  False -> entry
                }
              }),
            )
          }),
        ),
      )
    renames.Asking, renames.Declined(reason:) ->
      Model(
        ..model,
        view: View(..model.view, renaming: renames.Refused(reason)),
      )
    renames.Withheld, _
    | renames.Ready, _
    | renames.Done, _
    | renames.Refused(..), _
    -> model
  }
}

/// What the rename control is doing, for the operator's view to draw.
///
/// ## Examples
///
/// ```gleam
/// // component.rename_control(model) == renames.Withheld
/// ```
pub fn rename_control(model: Model(socket)) -> renames.Control {
  model.view.renaming
}

/// The rename control, drawn for the model's state: nothing for a page that
/// cannot rename, and otherwise the form, with the session's current name as
/// text in its lead. `submit` is the form's submit handler, which the operator's
/// page builds because it owns the message type.
///
/// ## Examples
///
/// ```gleam
/// // component.rename_form(model, submit)
/// ```
pub fn rename_form(
  model: Model(socket),
  submit: attribute.Attribute(message),
) -> Element(message) {
  let current = case option.map(model.view.label, fn(label) { label.name }) {
    Some("") | None -> None
    named -> named
  }
  rename_view.view(model.view.renaming, current, model.view.renamed, submit)
}

/// The listed session `id` names, when the page may offer to open it: another
/// session than this one, that a process runs. A peer's message names its
/// source session, which is the peer's text and never becomes an
/// attribute or a handler; the page offers "Open" only when that identity is
/// one of the principal's own listed sessions, and then the button's
/// message carries the catalogue's identity and the catalogue's name.
///
/// ## Examples
///
/// ```gleam
/// // component.openable(model, "0198a2f4-7c3b-7e10-8d5a-3f9b2c4e6a71")
/// ```
pub fn openable(model: Model(socket), id: String) -> Option(sessions.Entry) {
  case id == model.shared.session {
    True -> None
    False ->
      model.view.groups
      |> list.flat_map(fn(group) { group.entries })
      |> list.find(fn(entry) {
        entry.id == id && entry.residency == sessions.Live
      })
      |> option.from_result
  }
}

/// Shows `strand`, and addresses the operator's input to it.
///
/// The change is the shared step's (`step.focus`), which is the terminal's
/// change of strand less the terminal's surfaces: the lane's unsent frames
/// are cancelled, the record moves to the strand, and the captured cut is
/// projected for it. This host adds what only it holds. The history read owed
/// for the strand being left is dropped before the record parks its window
/// (`history_view.resume`), because the reply to it could not be placed and a
/// parked window stuck at "Pending" would leave the strand's lane reading
/// "Loading" for good when the reader came back. The row limit is
/// parked beside the window under the strand's name and restored with it, so a
/// strand the reader paged back keeps its depth when they return, and a strand
/// not yet left starts at `Tail`, as a page's first strand does. The projection
/// and the strip are rebuilt by `refreshed`, since the strand is one of their
/// inputs.
///
/// Focusing cancels the lane's unsent frames, as the terminal's
/// `cancel_pending` does, so a submit or a decision still queued behind the
/// lane is not sent to the new strand. Its draft stays in the composer, which
/// now addresses the new strand, and the shared record's "Not sent" line goes
/// to the transcript, which the page does not draw; the operator sees the
/// draft again and presses Send if they still want it.
///
/// Focusing the strand already shown, a strand the capture does not list,
/// or a page that is not yet showing a capture changes nothing. The check is
/// the caller's in the sense `step.focus` says, and it is made here because a
/// chip may name a strand that settled and left the capture between two
/// draws.
///
/// The change sends no command. What it may queue is a read, the strand's
/// configuration when no cut is captured, which the gateway admits from an
/// observer's attachment, so an observer's page carries it.
///
/// ## Examples
///
/// ```gleam
/// // component.focus(model, "advisor")
/// ```
pub fn focus(
  model: Model(socket),
  strand: String,
) -> #(Model(socket), Effect(Msg(socket))) {
  focus_at(model, strand, model.view.transport.now())
}

// `focus` at the reading `update` took at its top.
fn focus_at(
  model: Model(socket),
  strand: String,
  at: Int,
) -> #(Model(socket), Effect(Msg(socket))) {
  let shared = model.shared
  case
    strand == shared.active_strand,
    session_model.is_known_strand(shared.strands, strand),
    model.view.status
  {
    False, True, Connected -> {
      let parked =
        Shared(
          ..shared,
          scrollback: history_view.resume(shared.scrollback),
          notice: "",
          answer: "",
        )
      let #(focused, effects) = step.focus(parked, strand, stamp(at))

      // The row limit and the closed turns are parked with the history window
      // under the strand's name. Restoring the window without them would let the
      // next projection trim the older rows the reader loaded back down to
      // `live_rows`, which is the history this keeps, and a window parked beside
      // no summaries would draw the strand's newest turn alone.
      let remembered =
        dict.insert(
          model.view.parked_paging,
          shared.active_strand,
          model.view.paging,
        )
      let held_turns =
        dict.insert(
          model.view.parked_sealed,
          shared.active_strand,
          model.view.sealed,
        )

      // The depth is used only over a window that still holds rows. The
      // record empties a parked window when its strand leaves the capture
      // (`lane_fold.prune_parked_scrollback`), and a strand that later
      // returns under the same name must open at `Tail`: `Full` over an empty
      // window draws no Load older, so the reader could not page. The closed
      // turns follow the same rule, since they are only valid beside the
      // window they were closed from.
      let #(arriving, arriving_turns) = case
        dict.get(remembered, strand),
        dict.get(shared.parked_scrollback, #(shared.session, strand))
      {
        Ok(depth), Ok(window) if window.strand != "" -> #(
          depth,
          result.unwrap(dict.get(held_turns, strand), []),
        )
        _, _ -> #(Tail, [])
      }
      finished(
        Model(
          shared: focused,
          view: View(
            ..model.view,
            paging: arriving,
            sealed: arriving_turns,
            parked_sealed: dict.delete(held_turns, strand),
            steps: dict.new(),
            purpose: Resting,
            older: Unasked,
            completion: Untried,
            floor: Unheld,
            folds: [],
            said: [],
            parked_paging: dict.delete(remembered, strand),
            refusal: None,
            outcome: "",
          ),
        ),
        effects,
        at,
      )
    }

    // Already shown, no longer listed, or nothing captured to show.
    True, _, _
    | False, False, _
    | False, True, Connecting
    | False, True, Ended(_)
    -> #(model, effect.none())
  }
}

/// Asks for the rows older than the oldest one the page holds, when the
/// lane lists them as `lane.Earlier`, and does nothing otherwise.
///
/// The page's limit rises from `live_rows` to `held_rows`, and the page wants
/// the turns below its oldest. They are read from the parent of the oldest turn
/// the page holds, down the strand's own parent links (`history_lineage`), which
/// the step's tick sends as soon as the lane has no other request out. It is a
/// read and not a mutation: the gateway admits it for an observer's attachment
/// as for an operator's, and it names no strand's records but the ones on the
/// path it starts at. While it is out the lane draws `lane.Loading`, and a
/// second press asks nothing. The reply is folded in by the step.
///
/// ## Examples
///
/// ```gleam
/// // component.older(model)
/// ```
pub fn older(model: Model(socket)) -> #(Model(socket), Effect(Msg(socket))) {
  older_at(model, model.view.transport.now())
}

// `older` at the reading `update` took at its top.
//
// The press is a want. It raises the page's limit and asks the page to read
// the turns below its oldest, and the read itself starts in `refreshed`, from
// the oldest closed turn's parent, when the page has no other read out.
fn older_at(
  model: Model(socket),
  at: Int,
) -> #(Model(socket), Effect(Msg(socket))) {
  case top(model), model.shared.captured, model.view.status {
    lane.Earlier, Some(_), Connected ->
      stepping(
        Model(
          ..model,
          view: View(..model.view, paging: Paged, older: Pressed, refusal: None),
        ),
        [tick_at(at)],
        at,
      )

    // Nothing older to load, a read already out, a page at its limit, or
    // a page that is not following a session.
    lane.Beginning, _, _
    | lane.Loading, _, _
    | lane.Full(_), _, _
    | lane.Crowded, _, _
    | lane.Earlier, None, _
    | lane.Earlier, Some(_), Connecting
    | lane.Earlier, Some(_), Ended(_)
    -> #(model, effect.none())
  }
}

// The press is a want for a fresh board. The state is marked stale, which a
// read already out coalesces into one more, and the tick that follows is the
// shared step's own, where the read is sent when the lane is free. A page that
// is not following a session has no lane to ask.
fn context_refresh_at(
  model: Model(socket),
  at: Int,
) -> #(Model(socket), Effect(Msg(socket))) {
  case model.view.status {
    Connected ->
      stepping(
        Model(
          ..model,
          shared: Shared(
            ..model.shared,
            context: context_view.invalidate(model.shared.context),
          ),
        ),
        [tick_at(at)],
        at,
      )
    Connecting | Ended(_) -> #(model, effect.none())
  }
}

/// Whether a Lustre event path is a settled turn's divider: the button that
/// opens and closes a fold of work. The lane's rows are keyed, and a keyed
/// child's path segment is its key, so a divider is at the lane's list (the
/// second child of `<loom-follow>`, which is the lane's second child of the
/// centre column), then the piece's key, then the row's body (`tl-body`, its
/// second child), the work's own element and the divider, its first child.
/// The piece's key is the one the engine gives a turn's work: `work:` and the
/// sequence and index of the input that opened it, or `work:window-start`.
/// Both numbers are checked, so a path naming any other key, or any other
/// place beneath a row, is not a divider. The page socket admits a `click` from
/// an observer at such a path and no other event beyond `older_path`'s and
/// the strand panel's (`client/daemon/ui_socket.observer_accepts`,
/// protocol-change/070). `page_events_test` fails if the view moves the button,
/// so the two cannot drift apart.
///
/// ## Examples
///
/// ```gleam
/// assert component.fold_click("0\t2\t1\t1\twork:12.0\t1\t0\t0")
/// assert !component.fold_click("0\t2\t1\t1\twork:12.0\t1\t0")
/// ```
pub fn fold_click(path: String) -> Bool {
  case string.split(path, "\t") {
    ["0", "2", "1", "1", key, "1", "0", "0"] -> is_work_key(key)
    _ -> False
  }
}

// A turn's work key, as `turns` builds it: `work:` then the input block's
// key, a sequence and an index with a dot between them, or the window's start.
fn is_work_key(key: String) -> Bool {
  case string.split(key, ":") {
    ["work", "window-start"] -> True
    ["work", block] ->
      case string.split(block, ".") {
        [seq, index] -> is_counter(seq) && is_counter(index)
        _ -> False
      }
    _ -> False
  }
}

// Whether the text is a whole number as `int.to_string` writes it, so a sign,
// a space or a leading zero is refused.
fn is_counter(text: String) -> Bool {
  case int.parse(text) {
    Ok(number) -> number >= 0 && int.to_string(number) == text
    Error(Nil) -> False
  }
}

// Opens a closed fold, or closes an open one, and draws the page again.
//
// The fold is named by the number the divider's handler was drawn with, and a
// number that is not the id of a fold the page holds, because its turn left
// the page or never had work, changes nothing. The page must still be reading
// a session, which is the condition "Load older" needs: a page whose transport
// ended draws its last cut and stays still, so its steps are not drawn after
// the session closed to it. The newest fold opened goes first in the list, so
// the budget can close the oldest ones first when they do not all fit.
//
// Opening a fold of a closed turn asks the page for that turn's newest steps,
// which it does not hold, and the divider reads "reading" until they arrive.
// The read starts at the turn's last record, which the page holds in the
// turn's summary and which nothing in the event chose, so a press can ask for
// the steps of a turn the page draws and no other. Closing the fold drops its
// steps.
fn folded_at(
  model: Model(socket),
  fold: Int,
  at: Int,
) -> #(Model(socket), Effect(Msg(socket))) {
  case
    model.view.status,
    model.shared.captured,
    list.any(model.view.pieces, is_fold(_, fold))
  {
    Connected, Some(_), True -> {
      let folds = case list.contains(model.view.folds, fold) {
        True -> list.filter(model.view.folds, fn(open) { open != fold })
        False -> [fold, ..model.view.folds]
      }
      finished(Model(..model, view: View(..model.view, folds:)), [], at)
    }

    // Nothing to read from, a page that is not following a session, or a
    // number that names no fold the page holds.
    Connected, None, _
    | Connected, Some(_), False
    | Connecting, _, _
    | Ended(_), _, _
    -> #(model, effect.none())
  }
}

/// How many shortened messages a page keeps open at once. Opening another
/// closes the one opened longest ago, which bounds what the lane draws for
/// messages as `fold_budget` bounds it for folds: each is cut to
/// `expansion.max_characters`, so the page holds at most this many of those.
pub const open_messages = 8

// Opens a shortened message, or shortens an open one.
//
// The message is named by the block key the button's handler was drawn with. A
// key that names no shortened message in the lane, because its turn left the
// page or the message was never shortened, changes nothing, and neither does a
// press on a page that is not following a session, as with a fold. The newest
// message opened goes first, so the oldest is the one a ninth press closes.
fn messaged(model: Model(socket), key: String) -> Model(socket) {
  case model.view.status, turns.abridges(model.view.pieces, key) {
    Connected, True -> {
      let said = case list.contains(model.view.said, key) {
        True -> list.filter(model.view.said, fn(open) { open != key })
        False -> list.take([key, ..model.view.said], open_messages)
      }
      Model(..model, view: View(..model.view, said:))
    }
    Connected, False | Connecting, _ | Ended(_), _ -> model
  }
}

/// The block keys of the messages the reader has open, which the lane draws
/// whole (`lane.Folds`).
///
/// ## Examples
///
/// ```gleam
/// // lane.Folds(FoldToggled, MessageToggled, component.expanded(model))
/// ```
pub fn expanded(model: Model(socket)) -> List(String) {
  model.view.said
}

/// Whether a Lustre event path is the button after a shortened message. The
/// lane's rows are keyed, so a path names the lane's list (the second child of
/// `<loom-follow>`, which is the lane's second child of the centre column), the
/// piece's key, which for a message is its block's key (`seq.index`, two whole
/// numbers), the row's body (`tl-body`, its second child), and then the
/// message's own element. A person's own message is the block, which is the
/// body's first child, whose first child is the message (`div.message`), whose
/// second child is the button after its text. A message from another operator
/// is a `div.prompt` holding the sender's line and then the block, so the
/// message is one level deeper. The page socket admits a `click` from an
/// observer at either path and no other event there
/// (`client/daemon/ui_socket.observer_accepts`, protocol-change/070, the
/// addendum on messages). `page_events_test` fails if the view moves the
/// button, so the two cannot drift apart.
///
/// ## Examples
///
/// ```gleam
/// assert component.message_click("0\t2\t1\t1\t7.0\t1\t0\t0\t1")
/// assert !component.message_click("0\t2\t1\t1\twork:7.0\t1\t0\t0\t1")
/// ```
pub fn message_click(path: String) -> Bool {
  case string.split(path, "\t") {
    ["0", "2", "1", "1", key, "1", "0", "0", "1"]
    | ["0", "2", "1", "1", key, "1", "0", "1", "0", "1"] -> is_block_key(key)
    _ -> False
  }
}

// A message block's key, as `transcript_lines` builds it: a sequence and an
// index with a dot between them, which is also the tail of a work's key.
fn is_block_key(key: String) -> Bool {
  case string.split(key, ".") {
    [seq, index] -> is_counter(seq) && is_counter(index)
    _ -> False
  }
}

// Whether a piece is the settled work with this number.
fn is_fold(piece: turns.Piece, fold: Int) -> Bool {
  case piece {
    turns.Work(id: Some(found), folding: turns.Folded, ..)
    | turns.Work(id: Some(found), folding: turns.Reading, ..)
    | turns.Work(id: Some(found), folding: turns.Unfolded(_), ..) ->
      found == fold
    turns.Work(..)
    | turns.Plain(..)
    | turns.Prompt(..)
    | turns.Spawned(..)
    | turns.Returned(..)
    | turns.Nudged(..)
    | turns.Peer(..)
    | turns.Sibling(..)
    | turns.Missed(..)
    | turns.Decided(..)
    | turns.Commentary(..) -> False
  }
}

/// What the lane draws above the oldest row the page holds: that the page is
/// loading, until the first cut has arrived and while it reads turns below the
/// ones it holds, and otherwise whether older turns exist.
///
/// ## Examples
///
/// ```gleam
/// // component.top(model) == lane.Earlier
/// ```
pub fn top(model: Model(socket)) -> lane.Top {
  case model.view.status {
    // Until the first cut arrives the page knows nothing of the strand, and
    // saying the conversation begins would be a statement about a session it
    // has not read.
    Connecting -> lane.Loading
    Connected | Ended(_) ->
      case reading_older(model), model.view.earlier, model.view.paging {
        True, _, _ -> lane.Loading
        False, Reached, _ -> lane.Beginning
        False, Unheld, Full -> lane.Full(held_rows)
        False, Unheld, Crowded -> lane.Crowded
        False, Unheld, Tail | False, Unheld, Paged -> lane.Earlier
      }
  }
}

// Whether the page is reading the turns older than the ones it holds: the
// reader asked for them and has not been given them, or the page is reading the
// start of the turn its window began inside.
fn reading_older(model: Model(socket)) -> Bool {
  case model.view.purpose, model.view.older {
    ForOlder, _
    | ForLead, _
    | ForTail, _
    | ForSteps(_), Pressed
    | Resting, Pressed
    -> True
    ForSteps(_), Unasked | Resting, Unasked -> False
  }
}

/// How many rows the page holds (`Paging`).
///
/// ## Examples
///
/// ```gleam
/// // component.paging(model) == component.Tail
/// ```
pub fn paging(model: Model(socket)) -> Paging {
  model.view.paging
}

// The step's effects, performed through the host's transport in the order
// the step decided them, in one effect: Lustre does not order a batch. The
// shape is the terminal's `terminal_lane.perform`.
fn perform(
  transport: Transport(socket),
  effects: List(step_effect.Effect(socket, Nil)),
) -> Effect(Msg(socket)) {
  case effects {
    [] -> effect.none()
    [_, ..] -> {
      use _dispatch <- effect.from
      list.each(effects, fn(decided) {
        case decided {
          step_effect.Lane(session_channel.Transmit(socket:, frame:)) ->
            transport.transmit(socket, frame)
          step_effect.Lane(session_channel.Shut(socket:)) ->
            transport.shut(socket)

          // The lane holds no trace and the record no recorder, so the step
          // never queues a note or a recording line.
          step_effect.Lane(session_channel.Note(..))
          | step_effect.Recorded(..) -> Nil
        }
      })
    }
  }
}

// Arms the one timer for the lane's next due reading, measured from `now`,
// the reading the transition that moved it ran at, after cancelling the
// timer armed before. A lane with nothing due, or no lane, arms nothing.
//
// This is the one action `update` performs itself rather than returning as
// an effect. The `Timer` handle has to be in the model for the next arming
// to cancel it, and an effect could only hand it back as a second message,
// which Lustre would render a second time. `send_after` and `cancel_timer`
// do not block, and a test driving `update` through the simulator has no
// timer subject, so it arms nothing.
//
// A timer that fired before the cancel reached it leaves one `Ticked`
// behind. The tick it runs is harmless: `next_due` is exact, so a lane that
// is not yet due does nothing.
fn rearm(model: Model(socket), now: Int) -> Model(socket) {
  let _ = option.map(model.view.armed, process.cancel_timer)
  let due =
    earliest(
      option.then(model.shared.channel, session_channel.next_due),
      surfaces.context_deferred_until(model.shared),
    )
  let armed = case model.view.timer, due {
    Some(timer), Some(due) ->
      Some(process.send_after(timer, int.max(0, due - now), Nil))
    Some(_), None | None, _ -> None
  }
  Model(..model, view: View(..model.view, armed:))
}

// The sooner of two optional instants. The lane's reading and the context
// board's deferred read are separate reasons to wake, and one timer serves
// both because the tick that runs for either reduces the whole record.
fn earliest(first: Option(Int), second: Option(Int)) -> Option(Int) {
  case first, second {
    Some(a), Some(b) -> Some(int.min(a, b))
    Some(_), None -> first
    None, _ -> second
  }
}

// --- what the page reads ---------------------------------------------------

/// The transcript lines the page draws, oldest first: the lines of its rows.
///
/// A closed turn is drawn as its prompt, its answer and one divider, so its
/// steps are lines of the page only while the reader has its fold open.
///
/// ## Examples
///
/// ```gleam
/// // component.lines(model)
/// ```
pub fn lines(model: Model(socket)) -> List(Line) {
  list.map(rows(model), fn(row) { row.line })
}

/// The lane's pieces, in order (`session_view/turns`).
///
/// A reasoning block the summarizer has labelled is drawn as a summarized row.
/// The label is read from the shared record when the pieces are read, and is
/// never kept in the pieces the page holds, so a label that arrives after a
/// turn was sealed, or after a fold's steps were read, shows on the next draw
/// (`session_view/turn_labels`).
///
/// ## Examples
///
/// ```gleam
/// // lane.view(component.pieces(model))
/// ```
pub fn pieces(model: Model(socket)) -> List(turns.Piece) {
  model.view.pieces
  |> turn_labels.apply(model.shared.summaries)
  |> turns.with_decisions(decisions.from_ledger(
    model.shared.approvals,
    model.view.raised,
    model.shared.active_strand,
  ))
}

/// The live region's rows: the reasoning the provider is writing, with how
/// much of it has arrived, how long the generation has run and the
/// summarizer's headline when one was pushed, the answer as it stands, and
/// after them the inputs the daemon holds for the strand (a steer waiting
/// for the next boundary, the prompts queued behind the turn), as the
/// terminal draws them. All of it is the terminal's own state
/// (`Shared.streams`, `Shared.summaries`, the generation clock and the
/// capture's `pending_inputs`), and the page reads no extra frame for it.
///
/// The elapsed time is a reading, not a running clock: the browser counts
/// on from it (`<loom-elapsed>`), so the server draws again when a fragment
/// arrives and not to move a second. A turn that has opened and streamed
/// nothing yet is one `Opened` row, drawn from the phase change with the
/// generation clock's reading when that clock has started and no time before
/// it. A tool call the model is composing is not drawn; the capture draws it
/// as a running call as soon as it commits.
///
/// ## Examples
///
/// ```gleam
/// // lane.view(component.pieces(model), component.live(model), ..)
/// ```
pub fn live(model: Model(socket)) -> List(live.Row) {
  let shared = model.shared
  let elapsed_ms =
    option.map(shared.generation_started_ms, fn(started) {
      int.max(0, shared.stamp.now_ms - started)
    })
  let streamed =
    list.filter_map(model.view.streams, fn(stream) {
      let text = stream.fragments |> list.reverse |> string.concat
      case stream.kind {
        "thinking" ->
          Ok(live.Thinking(
            progress: transcript_lines.line_count(text),
            text:,
            elapsed_ms:,
            headline: block_summary.live(shared.summaries, stream.generation),
          ))
        "tool_call" -> Error(Nil)
        _ -> Ok(live.Answer(Line(Assistant, text)))
      }
    })

  // A strand in its `assistant` phase with nothing streamed yet is a turn
  // that has opened: the request is out and the model has said nothing. The
  // row stands from the phase change and not from the first fragment, which
  // a model that streams no reasoning text never sends before its answer.
  //
  // Only the generation clock is ever drawn. Until it starts, on an operation
  // event or a first fragment, the row says `Thinking` with no time: the
  // operation's own clock also counts earlier generations of the turn, so it
  // would read minutes under an answer that just landed.
  let streamed = case streamed, session_model.active_strand_phase(shared) {
    [], Some("assistant") -> [live.Opened(elapsed_ms:)]
    _, _ -> streamed
  }

  // The held inputs are the newest thing on the page: typed after the run
  // above them started, and run after it. The capture lists them, so a
  // message the daemon took but has not run is drawn from the capture that
  // first lists it until the one that no longer does, when its own row has
  // landed above (`transcript_lines.held_inputs` is the terminal's rule).
  let held =
    session_model.presentation(shared)
    |> transcript_lines.held_inputs
    |> option.unwrap([])
    |> list.map(fn(input) {
      live.Held(
        text: input.text,
        words: transcript_lines.held_words(input.kind),
      )
    })
  list.append(streamed, held)
}

/// The sidebar's groups: the principal's sessions by workspace, newest
/// first, as last read. Only the operator's page draws them; the observer's
/// page has none to draw, because the daemon supplies an observer's page an
/// empty list (`ui_socket.listed_for`) and the observer's view has no
/// sidebar.
///
/// ## Examples
///
/// ```gleam
/// // sidebar.view(component.session_groups(model), component.session_id(model))
/// ```
pub fn session_groups(model: Model(socket)) -> List(sessions.Group) {
  model.view.groups
}

/// What the sidebar's running sessions are doing, by identity. The other
/// rows carry what the daemon's activity read last said, a few seconds old at
/// most. The page's own session is the exception: the page is its lane, so the
/// row is read from the strands' statuses it already holds (`live_activity`)
/// and never lags the Strands panel beside it. Before the first capture the
/// page knows nothing of its own session and the read's answer stands.
///
/// ## Examples
///
/// ```gleam
/// // sidebar.view(groups, id, component.session_activity(model), Opening, resume)
/// ```
pub fn session_activity(
  model: Model(socket),
) -> dict.Dict(String, sessions.Activity) {
  case live_activity(model) {
    Some(own) -> dict.insert(model.view.activity, model.shared.session, own)
    None -> model.view.activity
  }
}

// What the page's own session is doing, from the strip it draws. The rule is
// the daemon's activity read's, so the page's row and the home's row for the
// same session say the same word: a strand waiting on a decision needs the
// person; otherwise a strand with an operation (working, or waiting on a
// provider retry) is working; otherwise a main strand whose last run failed
// with nothing else running has failed, and nothing waits on the operator;
// otherwise idle. A page whose strip lists no strand has
// no capture yet and says nothing.
fn live_activity(model: Model(socket)) -> Option(sessions.Activity) {
  let listed = chips(model.view.strip)
  let statuses = list.map(listed, fn(chip) { chip.line.status })
  let working =
    list.any(statuses, fn(status) {
      status == agent_view.Working || status == agent_view.Waiting
    })
  let main_failed = case model.view.strip.chips {
    [main, ..] -> main.line.status == agent_view.Failed
    [] -> False
  }
  case listed {
    [] -> None
    [_, ..] ->
      case needing(model) > 0, working, main_failed {
        True, _, _ -> Some(sessions.NeedsYou)
        False, True, _ -> Some(sessions.Working)
        False, False, True -> Some(sessions.Failed)
        False, False, False -> Some(sessions.Idle)
      }
  }
}

/// The agent strip as the page draws it.
///
/// ## Examples
///
/// ```gleam
/// // strip.view(component.strip(model))
/// ```
pub fn strip(model: Model(socket)) -> strip.Strip {
  model.view.strip
}

/// The chip of the strand the page addresses, whose cache outlook the
/// operator's composer shows.
///
/// ## Examples
///
/// ```gleam
/// // component.addressed(model)
/// ```
pub fn addressed(model: Model(socket)) -> Option(strip.Chip) {
  list.find(chips(model.view.strip), fn(chip) {
    chip.line.id == model.shared.active_strand
  })
  |> option.from_result
}

/// The strand the page shows and addresses: the one the reader focused on
/// the agent strip, or `primary` until they focus another. Every prompt,
/// steer, queue, interrupt and command the operator's page sends goes to it.
///
/// ## Examples
///
/// ```gleam
/// // component.strand(model) == component.primary
/// ```
pub fn strand(model: Model(socket)) -> String {
  model.shared.active_strand
}

/// The connection's status.
///
/// ## Examples
///
/// ```gleam
/// // component.status(model) == component.Connected
/// ```
pub fn status(model: Model(socket)) -> Status {
  model.view.status
}

/// The escalations still waiting for a decision, in the order the capture
/// held them.
///
/// ## Examples
///
/// ```gleam
/// // component.pending(model)
/// ```
pub fn pending(model: Model(socket)) -> List(approval.Review) {
  list.filter(model.shared.approvals, fn(record) {
    record.status == approval.Pending
  })
}

/// The advisor's nudges that have not reached the primary, as the last read
/// of the queue found them (`session_view/advisor_pending`), or `None`
/// before any read. The shared step keeps it as the terminal does: it reads
/// again when the primary settles and drops it when the primary starts a
/// run, since that run's prompt takes the queue.
///
/// ## Examples
///
/// ```gleam
/// // nudges.view(component.pending_nudges(model))
/// ```
pub fn pending_nudges(model: Model(socket)) -> Option(advisor_pending.Board) {
  model.shared.nudges
}

/// The session goal as the server last rendered it, or `None` before any
/// read. `None` is not "no goal is pinned": that is `goal_view.NoGoal`.
///
/// ## Examples
///
/// ```gleam
/// // component.goal(model)
/// ```
pub fn goal(model: Model(socket)) -> Option(goal_view.Board) {
  model.shared.goal
}

/// How many of the controls' forms have sent a command, which keys them.
///
/// ## Examples
///
/// ```gleam
/// // component.sent_forms(model)
/// ```
pub fn sent_forms(model: Model(socket)) -> Int {
  model.view.sent_forms
}

/// The advisor's settled commentary on the strand on screen, as the last
/// capture projected it (`session_view/advisor_history`), already narrowed
/// by the shared visibility rule: a board for `main` only. The advisor's own
/// transcript holds the same text as its ordinary entries, so the focused
/// advisor draws no section and the lane marks nothing.
///
/// ## Examples
///
/// ```gleam
/// // commentary.view(component.advisor_commentary(model))
/// ```
pub fn advisor_commentary(model: Model(socket)) -> advisor_history.Board {
  advisor_history.visible(
    model.shared.advisor_history,
    model.shared.active_strand,
  )
}

/// What the page last told the operator: its own refusal of an input if
/// there is one, otherwise the daemon's reply to the last command, otherwise
/// what the session said when that command ran.
///
/// ## Examples
///
/// ```gleam
/// // component.notice(model) == component.Quiet
/// ```
pub fn notice(model: Model(socket)) -> Notice {
  case model.view.refusal, model.shared.answer, model.view.outcome {
    Some(text), _, _ -> Warned(text)
    None, "", "" -> Quiet
    None, "", text -> said(text)
    None, text, _ -> said(text)
  }
}

// The words of an outcome as a notice. An outcome that only says the daemon
// holds the input is left out: the lane draws the held row with how it will
// run, and a footer word beside it repeated that and outlived the row once
// it settled.
fn said(text: String) -> Notice {
  case notice_words.holds(text) {
    True -> Quiet
    False -> Said(text)
  }
}

/// How many times the composer's notice has changed, which keys the notice
/// element so that a new notice fades from the start.
///
/// ## Examples
///
/// ```gleam
/// // component.notice_serial(model) == 0
/// ```
pub fn notice_serial(model: Model(socket)) -> Int {
  model.view.noticed
}

/// How many composer submits were refused with the draft kept, by the page
/// or by the lane's admission check; a stale approval, a reply with no
/// message or a refused control form do not count. The operator page writes
/// it as the composer element's `refused` attribute.
///
/// ## Examples
///
/// ```gleam
/// // component.refusals(model) == 0
/// ```
pub fn refusals(model: Model(socket)) -> Int {
  model.view.refusals
}

/// The model with its notice counted as changed. The operator page calls it
/// after a message that left a different notice than it found
/// (`operator_page.update`); this module cannot see the message as one change
/// because the notice is read from three places.
///
/// ## Examples
///
/// ```gleam
/// // component.renew_notice(model)
/// ```
pub fn renew_notice(model: Model(socket)) -> Model(socket) {
  Model(..model, view: View(..model.view, noticed: model.view.noticed + 1))
}

/// The strand each approval request was raised on, by the request's identity,
/// as the captures saw it while the request was pending. A request no capture
/// named a strand for is absent.
///
/// ## Examples
///
/// ```gleam
/// // component.raised_on(model)
/// ```
pub fn raised_on(model: Model(socket)) -> List(#(String, String)) {
  model.view.raised
}

// The strands requests were raised on: the capture's pending cells first,
// then what was remembered, one entry for each request, the newest sixty-four.
fn remembered(
  known: List(#(String, String)),
  cells: List(snapshot_view.Cell),
) -> List(#(String, String)) {
  list.append(decisions.strands(cells), known)
  |> list.unique
  |> list.take(64)
}

/// How many drafts have left the composer, which keys the composer's
/// editor: the ones the lane sent and the ones a command consumed.
///
/// ## Examples
///
/// ```gleam
/// // component.drafts(model)
/// ```
pub fn drafts(model: Model(socket)) -> Int {
  model.shared.drafts_sent + model.view.consumed
}

/// How many prompts the daemon has handed back to the page's strand since
/// the page opened. The composer's element compares it with the count it
/// last saw, so a number that rises is a return to put in the editor.
///
/// ## Examples
///
/// ```gleam
/// // component.returns(model)
/// ```
pub fn returns(model: Model(socket)) -> Int {
  model.view.returns
}

/// The latest prompts the daemon handed back, oldest first, each numbered
/// by its place in `returns`.
///
/// ## Examples
///
/// ```gleam
/// // component.returned(model)
/// ```
pub fn returned(model: Model(socket)) -> List(Returned) {
  model.view.returned
}

/// The attachment the last capture was taken for: who the page acts as.
///
/// ## Examples
///
/// ```gleam
/// // component.attachment(model)
/// ```
pub fn attachment(model: Model(socket)) -> Option(snapshot.Attachment) {
  option.map(model.shared.captured, fn(shown) { { shown.0 }.attachment })
}

/// Whether the page's strand has an operation running, which decides
/// whether the composer offers one Send or a Queue and a Steer.
///
/// ## Examples
///
/// ```gleam
/// // component.activity(model) == component.Idle
/// ```
pub fn activity(model: Model(socket)) -> Activity {
  case session_model.active_strand_live(model.shared) {
    True -> Busy
    False -> Idle
  }
}

/// The transcript rows the page draws, keyed, oldest first: a person's words
/// and an answer as the transcript draws them, a settled turn's work as one
/// divider row (`Worked 52s · 80 steps`), and the steps of a fold only while it
/// is open. It is what the page counts against its row limit
/// (`fold_budget`), so a turn costs the same here as there.
///
/// ## Examples
///
/// ```gleam
/// // component.rows(model)
/// ```
pub fn rows(model: Model(socket)) -> List(transcript.Row) {
  list.flat_map(model.view.pieces, piece_rows)
}

// The rows one piece draws, as `fold_budget` counts them: the rows of a block,
// one for a divider, and for each step of an open fold its line and its
// result's rows. Pieces drawn as cards (a spawn, a peer's message) hold no
// block and are not rows here.
fn piece_rows(piece: turns.Piece) -> List(transcript.Row) {
  case piece {
    turns.Plain(block:, ..) | turns.Prompt(block:, ..) -> block_rows(block)
    turns.Work(key:, worked:, items:, folding:, ..) ->
      case folding {
        turns.Open -> list.flat_map(items, item_rows)
        turns.Folded | turns.Reading -> [divider_row(key, worked)]
        turns.Unfolded(_) -> [
          divider_row(key, worked),
          ..list.flat_map(items, item_rows)
        ]
      }
    turns.Spawned(..)
    | turns.Returned(..)
    | turns.Nudged(..)
    | turns.Commentary(..)
    | turns.Peer(..)
    | turns.Sibling(..)
    | turns.Missed(..)
    | turns.Decided(..) -> []
  }
}

fn block_rows(block: transcript_lines.Block) -> List(transcript.Row) {
  list.map(block.rows, fn(row) { transcript.Row(key: row.0, line: row.1) })
}

fn divider_row(key: String, worked: turns.Worked) -> transcript.Row {
  transcript.Row(
    key: key <> ":divider",
    line: Line(transcript_line.System, turns.divider(worked)),
  )
}

fn item_rows(item: turns.Item) -> List(transcript.Row) {
  case item {
    turns.Narrated(block:, ..) -> block_rows(block)
    turns.Memory(key:, ..) -> [
      transcript.Row(key:, line: Line(transcript_line.System, "memory context")),
    ]
    turns.Step(key:, words:, detail:, ..) -> [
      transcript.Row(
        key:,
        line: Line(transcript_line.ToolGroup, step_words.text(words)),
      ),
      ..list.index_map(detail, fn(line, index) {
        transcript.Row(key: key <> ":" <> int.to_string(index), line:)
      })
    ]
  }
}

/// The page's lane, for the parity test that compares it with the
/// terminal's through `session_channel.state`.
///
/// ## Examples
///
/// ```gleam
/// // option.map(component.lane(model), session_channel.state)
/// ```
@internal
pub fn lane(
  model: Model(socket),
) -> Option(session_channel.Channel(socket, Nil)) {
  model.shared.channel
}

/// The session identity the page was opened for.
///
/// ## Examples
///
/// ```gleam
/// // component.session_id(model)
/// ```
pub fn session_id(model: Model(socket)) -> String {
  model.shared.session
}

/// The observer's page: the top bar, no sidebar, a centre column holding the
/// breadcrumb while another strand is in focus, the lane, the todo panel when
/// the strand has a board or a reviewer is running, a fixed line saying the
/// page is read-only, and the strand panel, which carries the advisor's
/// pending nudges when any are queued. Its event handlers are
/// the lane's "Load older" button, whose message asks for a read and nothing
/// else, one focus click per card of the strand panel, the "Home" button on a
/// page opened from a home, and one click per settled turn's divider, which
/// draws or drops steps of records the page already holds; the page socket
/// admits those from an observer and drops every other frame
/// (protocol-change/051, the addenda on history paging and strand focus, 065
/// for Home, and 070 for the dividers).
///
/// Each region is drawn by its own module under `web_view/view` (`heading`,
/// `lane`, `panel` and `strip`); this function only lays them out through
/// `view/shell`, as `operator_page.view` does for the operator's page.
///
/// ## Examples
///
/// ```gleam
/// // element.to_string(component.view(model))
/// ```
pub fn view(model: Model(socket)) -> Element(Msg(socket)) {
  shell.view(
    shell.Observer,
    heading(
      model,
      GoingHome,
      context_breakdown.Actions(refresh: ContextRefreshRequested, compact: None),
    ),
    shell.Unlisted,
    [
      crumb(model),
      lane.view(
        pieces(model),
        live(model),
        top(model),
        OlderRequested,
        lane.NoReplies,
        marks(model),
        lane.Folds(FoldToggled, MessageToggled, expanded(model)),
        session_id(model),
      ),
      plan(model),
      html.p([attribute.class("observer-bar")], [
        html.span([attribute.class("pill")], [
          html.text("Observer · read-only"),
        ]),
        html.span([attribute.class("observer-note")], [
          html.text(observer_words(model)),
        ]),
      ]),
      case model.view.transport.home {
        Some(_) -> switch(model)
        None -> element.none()
      },
    ],
    panel(
      model,
      FocusRequested,
      None,
      element.none(),
      element.none(),
      element.none(),
      element.none(),
    ),
    needing(model),
    workspace_digest(model),
  )
}

// The observer bar's note beside the "Observer · read-only" pill: the fixed
// words that say how to get operator access, or, after a press of "Home" that the daemon refused, the reason in its fixed
// words. The observer's page has no composer to hold a notice, and it is the
// only refusal the page can have.
fn observer_words(model: Model(socket)) -> String {
  case notice(model) {
    Warned(text) | Said(text) -> text

    // The owner who opened a read-only link has no one to ask: the same
    // command mints a page that can send.
    Quiet ->
      case model.view.reader {
        DaemonOwner ->
          "This link is read-only. Run loom ui for a page that can send."
        Participant ->
          "You can follow this session. Ask the owner for operator access."
      }
  }
}

/// The element that moves the browser to another page. It is hidden, holds
/// nothing the reader sees, and carries an address in its `to` attribute only
/// after the daemon has minted a ticket for one (`web_client/switch`, which
/// checks the address again before it navigates). Each page draws it as the
/// centre column's last child, so no admitted path moves with it: the
/// operator's page always, and an observer's only when it was opened from a
/// home and so may go back to it.
///
/// ## Examples
///
/// ```gleam
/// // component.switch(model)
/// ```
pub fn switch(model: Model(socket)) -> Element(message) {
  switch.view(departure(model))
}

/// The strand panel both pages draw: the Strands pane with a card for each
/// strand the page lists, each a button whose click is `focus` applied to the
/// strand's name, then the Changes and Session panes, and under them the
/// advisor's pending nudges, on every tab. A page's message type
/// decides what a press means, so the operator's page passes its own wrapper.
///
/// `viewers` is the attached viewers the Session pane draws, or `None` on a
/// page that does not show them: the observer's, on the ruling that a link
/// handed to someone who may only watch does not tell them who else is
/// watching. `share` is the invitation control the Session pane ends with:
/// the operator page passes an owner's control (`view/share`), and every other
/// page passes `element.none()`. `controls` is the operator's goal buttons and
/// fork form, and `rename` the owner's rename control (`rename_form`), which
/// every other page passes as `element.none()`, and `remembered` the operator's
/// list of remembered permissions (`view/remembered`), likewise.
///
/// ## Examples
///
/// ```gleam
/// // component.panel(model, FocusRequested, None, element.none(), element.none(), element.none(), element.none())
/// ```
pub fn panel(
  model: Model(socket),
  focus: fn(String) -> message,
  viewers: Option(session_summary.Viewers),
  share: Element(message),
  controls: Element(message),
  rename: Element(message),
  remembered: Element(message),
) -> Element(message) {
  panel.view(
    strip.count(model.view.strip),
    strip.view(model.view.strip, focus),
    detail(model),
    changes.view(
      model.view.changes,
      case model.view.earlier {
        Reached -> changes.Whole
        Unheld -> changes.Partial
      },
      model.view.worktree,
      option.map(model.view.label, fn(label) { label.workspace }),
    ),
    session_tab.view(
      option.map(goal(model), goal_view.row) |> option.unwrap([]),
      cost_figure(model),
      jobs(model),
      viewers,
      option.map(model.view.label, fn(label) { label.workspace }),
      share,
      controls,
      rename,
      remembered,
    ),
    trace.view(trace(model)),
    nudges.view(pending_nudges(model)),
    commentary.view(advisor_commentary(model)),
  )
}

/// The strand on screen's own view for the Strands tab, when there is one: a
/// strand other than `main`, which has none, since focusing `main` is `All
/// strands` and shows the list.
///
/// ## Examples
///
/// ```gleam
/// // component.detail(model) == None
/// ```
pub fn detail(model: Model(socket)) -> Option(Element(message)) {
  case model.shared.active_strand == primary {
    True -> None
    False ->
      strip.followed_card(model.view.strip)
      |> option.map(strand_detail.view)
  }
}

/// The breadcrumb above the transcript while a strand other than `main` is in
/// focus, or the empty node that keeps its place otherwise, so the
/// transcript's path is the same in both.
///
/// ## Examples
///
/// ```gleam
/// // component.crumb(model)
/// ```
pub fn crumb(model: Model(socket)) -> Element(message) {
  case model.shared.active_strand == primary {
    True -> element.none()
    False ->
      case strip.followed_card(model.view.strip) {
        Some(card) ->
          crumb.view(
            heading.session_name(
              model.shared.session,
              option.map(model.view.label, fn(label) { label.name }),
            ),
            card.line.name,
          )
        None -> element.none()
      }
  }
}

/// What the lane needs to mark its rows as belonging to a strand: the strand
/// on screen and its hue, and the position of each strand the panel lists.
///
/// ## Examples
///
/// ```gleam
/// // component.marks(model).active == "main"
/// ```
pub fn marks(model: Model(socket)) -> lane.Marks {
  lane.Marks(
    active: model.shared.active_strand,
    hue: turns.hue(model.shared.strands, model.shared.active_strand),
    positions: strip.positions(model.view.strip),
    key: dict.get(model.view.strand_keys, model.shared.active_strand)
      |> result.unwrap(0),
  )
}

/// How many strands are waiting on a decision, the number on the Strands tab's
/// badge. It counts the strip's cards, so a strand the page does not list is
/// not counted, and `session_view/strand_card` is what decides which state
/// counts.
///
/// ## Examples
///
/// ```gleam
/// // component.needing(model) == 0
/// ```
pub fn needing(model: Model(socket)) -> Int {
  chips(model.view.strip)
  |> list.map(fn(chip) { chip.line })
  |> strand_card.needing
}

/// The workspace digest the host handed the component, for the frame's
/// `workspace` attribute: 64 hex digits, or an empty string when the host had
/// none.
///
/// ## Examples
///
/// ```gleam
/// // component.workspace_digest(model) == ""
/// ```
pub fn workspace_digest(model: Model(socket)) -> String {
  model.view.workspace_digest
}

/// The todo panel both pages draw above their bottom bar: the followed
/// strand's newest board and the reviewer band, from the same shared state
/// the terminal draws them from.
///
/// The board is `Shared.todo_boards` at the strand the page follows
/// (`Shared.active_strand`), which the shared step keeps from the transcript
/// and a notes read. The band's lines are `reviewer_status.lines`, the
/// terminal's, for the reviewers other than that strand. The terminal's
/// idle-advisor placeholder is not drawn: it exists to hold a row's place
/// under a cursor, and the page has no cursor to keep still. Nothing is
/// drawn when there is neither a board nor a reviewer line.
///
/// ## Examples
///
/// ```gleam
/// // component.plan(model)
/// ```
pub fn plan(model: Model(socket)) -> Element(message) {
  let strand = model.shared.active_strand

  todo_panel.view(
    option.from_result(dict.get(model.shared.todo_boards, strand)),
    reviewer_status.lines(
      reviewer_status.without_idle_advisor(model.shared.reviewer_rows),
      strand,
    ),
  )
}

/// The edits of the session the page holds, from the records the page
/// projects, for the Changes section.
///
/// It is derived with the transcript, not read from the worktree, so it is
/// what the agent wrote in this window and not the state of the tree.
///
/// ## Examples
///
/// ```gleam
/// // component.changes(model)
/// ```
pub fn changes(model: Model(socket)) -> changes_view.Board {
  model.view.changes
}

/// The `code_mode` programs of the session the page holds, from the records
/// the page projects, for the Trace pane.
///
/// ## Examples
///
/// ```gleam
/// // component.trace(model)
/// ```
pub fn trace(model: Model(socket)) -> trace_view.Trace {
  model.view.trace
}

/// The followed strand's live jobs, as the last read of them answered.
///
/// ## Examples
///
/// ```gleam
/// // component.jobs(model)
/// ```
pub fn jobs(model: Model(socket)) -> session_summary.Jobs {
  session_summary.jobs(model.shared.jobs, model.shared.active_strand)
}

/// The session's attached viewers, from the presence rows of the last
/// coherent capture. Only a page that may show them draws them; an
/// observer's page does not (`web_view/view/session_tab`).
///
/// ## Examples
///
/// ```gleam
/// // component.viewers(model)
/// ```
pub fn viewers(model: Model(socket)) -> session_summary.Viewers {
  session_summary.viewers(model.shared.captured)
}

/// The page's top bar, drawn by `web_view/view/heading` from the session's
/// identity, the catalogue's label, the connection's status and the two
/// estimates the terminal's footer shows.
///
/// The context figure is the engine's estimate for the strand on screen
/// (`context_view.footer`, which words it `ctx ~41%`), and the cost is the
/// session's running total across strands (`Shared.usage`, which every
/// `UsageChanged` event folds into whatever strand it names), worded as the
/// terminal words it. The heading module takes the label's two fields and
/// the words as plain values, because it cannot import the types this module
/// defines.
///
/// `context_actions` are the two messages the context breakdown's buttons
/// send (`view/context_breakdown`): the observer's page offers Refresh alone,
/// and the operator's page adds Compact now, since only it may run `/compact`.
///
/// `going_home` is the message the bar's "Home" button sends, which the page's
/// own message type wraps. The button is drawn only when the transport has the
/// capability to go home, and otherwise the bar's second child is an empty
/// node.
///
/// ## Examples
///
/// ```gleam
/// // component.heading(model, GoingHome, context_breakdown.Actions(Refresh, None))
/// ```
pub fn heading(
  model: Model(socket),
  going_home: message,
  context_actions: context_breakdown.Actions(message),
) -> Element(message) {
  heading.view(
    session_id: model.shared.session,
    home: case model.view.transport.home {
      Some(_) -> heading.home_link(going_home)
      None -> element.none()
    },
    name: option.map(model.view.label, fn(label) { label.name }),
    workspace: option.map(model.view.label, fn(label) { label.workspace }),
    model: model_of(model.shared, agent_roster.primary),
    status: status_text(model.view.status),
    tone: status_tone(model.view.status),
    context: context_figure(model),
    breakdown: context_breakdown.panel(model.shared.context, context_actions),
    cost: cost_text(model),
    notice: ended.view(ended_ending(model.view.status), model.shared.session),
  )
}

// The top bar's context figure. The primary strand's has no value until its
// first turn commits, and the bar draws nothing for that, since a dash there
// reads as missing data. A strand the reader has focused keeps its dash,
// which the bar's title explains: that strand has had no turn yet.
fn context_figure(model: Model(socket)) -> String {
  let words = context_view.footer(model.shared.context)
  case
    string.ends_with(words, " —")
    && model.shared.active_strand == agent_roster.primary
  {
    True -> ""
    False -> words
  }
}

// The session's running cost as the top bar and the Session tab word it,
// which is the terminal's footer's own words.
fn cost_text(model: Model(socket)) -> String {
  transcript_lines.cost_words(model.shared.usage)
}

// The session's cost as a figure alone, for a row whose label says estimate:
// the same words as `cost_text` without their leading "est", so an unpriced
// session still reads "—" rather than a misleading "$0.00".
fn cost_figure(model: Model(socket)) -> String {
  case cost_text(model) {
    "est " <> figure -> figure
    words -> words
  }
}

// The ending a page that has ended draws a notice for.
fn ended_ending(status: Status) -> Option(Ending) {
  case status {
    Connecting | Connected -> None
    Ended(ending:) -> Some(ending)
  }
}

// The tone the heading's status pill takes.
fn status_tone(status: Status) -> heading.Tone {
  case status {
    Connecting -> heading.Pending
    Connected -> heading.Live
    Ended(_) -> heading.Closed
  }
}

// The connection's status as the heading words it.
fn status_text(status: Status) -> String {
  case status {
    Connecting -> "connecting"
    Connected -> "connected"
    Ended(_) -> "disconnected"
  }
}
