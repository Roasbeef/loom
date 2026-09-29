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
//// (`history_view`, the shared record's `scrollback`), projects the newest
//// turns that fit, and trims the window to what it draws. `older` pages
//// further back through the lane's `history` read, the read the terminal
//// pages with. The limit and `Paging` are this page's view state.
////
//// What the page draws is derived from the shared record by `refreshed`, which
//// runs at the end of every message and rebuilds a projection only when the
//// inputs it reads moved. The shared record's own `render_revision` is not
//// that signal. It moves for everything the terminal's rows are built from,
//// including stream fragments and tool output tails that the page does not
//// draw, and a page that re-projected on each of them would project once per
//// batch of a streaming answer. The projection's inputs are compared
//// instead, and an unchanged input is the same term, which costs a pointer
//// comparison.
////
//// The page's regions are drawn by the modules under `web_view/view`: the
//// heading, the agent strip and the transcript lane. This module derives
//// what they draw, when a message changes it, and `view` lays them out.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/server_component
import session_view/agent_roster
import session_view/agent_view
import session_view/approval
import session_view/cache_miss
import session_view/cache_watch
import session_view/command
import session_view/connection_event
import session_view/history_view
import session_view/inbox
import session_view/lane_fold
import session_view/model.{type Shared, Shared} as session_model
import session_view/msg
import session_view/operator
import session_view/protocol
import session_view/session_channel
import session_view/snapshot
import session_view/snapshot_view
import session_view/step
import session_view/step_effect
import session_view/transcript
import session_view/transcript_line.{type CacheNotice, type Line}
import session_view/transcript_lines
import session_view/turns
import web_view/view/heading
import web_view/view/lane
import web_view/view/strip

/// The most frames one `Arrived` carries: the frame the selector matched
/// and up to this many less one already waiting behind it.
///
/// It is the terminal's `connection_batch`, the most frames one of its
/// steps reduces, so a burst costs the two hosts the same number of
/// reductions. A burst longer than this is several batches, each taken as
/// soon as the one before it is reduced.
pub const arrival_batch = 64

/// The strand the page shows and addresses, which the agent strip marks
/// as the one the page follows (`strip.followed`).
pub const strand = strip.followed

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
/// the lane is the third child of the page's `main`, the line above its
/// oldest row the lane's first child, and the button that line's first
/// child. The page socket admits a `click` from an observer at this path and
/// no other event (`client/daemon/ui_socket.observer_accepts`,
/// protocol-change/051, the addendum on history paging). `page_events_test`
/// fails if the view moves the button, so the two cannot drift apart.
pub const older_path = "0\t2\t0\t0"

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
    /// The attachment the lane must see on every captured cut. A cut for
    /// another session, epoch or incarnation fails the lane rather than
    /// being drawn.
    expected: snapshot.Expected,
    /// The host's transport.
    transport: Transport(socket),
  )
}

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
  )
}

/// What the page says about the connection.
pub type Status {
  /// The transport is opening, or the first cut has not arrived.
  Connecting

  /// At least one validated cut has been drawn.
  Following

  /// The connection ended, and the last drawn cut stays on the page.
  Ended(reason: String)
}

/// What the page last told an operator about their own input.
///
/// The text is the component's own or the engine's, never the session's.
/// The engine's is the shared record's `notice`, which the terminal shows in
/// its footer and which any event can replace, so it states the latest thing
/// the session did as often as the outcome of a command. The component's own
/// is a refusal of an input before it became a command, and it stays until
/// the operator's next input.
pub type Notice {
  /// Nothing to say.
  Quiet

  /// What the session last said.
  Said(text: String)

  /// The page refused an input before it reached the session.
  Warned(text: String)
}

/// Whether the page's strand is running an operation.
pub type Activity {
  /// Nothing is running: a draft is sent as a prompt.
  Idle

  /// An operation is running: a draft is queued behind it or steers it.
  Busy
}

/// An operator's answer that the page offers. Remembering a grant for the
/// session is not offered from a page (protocol-change/051, the operator
/// addendum), so it is not a value this type can hold.
pub type Answer {
  /// Grant the displayed authority for this one request.
  AllowOnce

  /// Refuse the request.
  Deny
}

/// How much of the strand's history the page holds. It only moves forward:
/// a page that has loaded older rows keeps the larger limit, and a page
/// that reached it stays full.
pub type Paging {
  /// The newest `live_rows` rows; the reader has not asked for older ones.
  Tail

  /// The newest `held_rows` rows, since the reader asked for older ones.
  Paged

  /// The page held more than `held_rows` rows while paged, so it keeps the
  /// newest `held_rows` and loads no more.
  Full
}

// Whether rows older than the oldest one the page holds exist.
type Earlier {
  // The page holds the strand's first row.
  Reached

  // Older rows exist: the page cut them to its limit, or its history window
  // never held them.
  Unheld
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
    captured: Option(#(snapshot.Captured, snapshot_view.View)),
    scrollback: history_view.State,
    notices: List(CacheNotice),
    agents: List(agent_view.Row),
    paging: Paging,
  )
}

// What the strip was built from. The roster's clock is left out: it moves on
// every tick, and the strip's elapsed figures are counted by the browser
// from the reading the strip was built at.
type Stripped {
  Stripped(
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
    expected: snapshot.Expected,
    transport: Transport(socket),
    /// How many rows the page holds. This is the page's own view state.
    paging: Paging,
    /// Whether older rows than the page holds exist, derived with `blocks`.
    earlier: Earlier,
    /// The page strand's transcript blocks that the page holds, the newest
    /// turns within its row limit, projected once when a capture, a page
    /// of history or a cache notice arrived, so a message which changed
    /// none of them costs the view no projection.
    blocks: List(transcript_lines.Block),
    /// The same blocks laid out as turns (`session_view/turns`), derived
    /// with them.
    pieces: List(turns.Piece),
    /// The inputs `blocks` and `pieces` were derived from.
    projected: Projected,
    /// The agent strip, derived when a capture, a usage push or a tick
    /// changed something it draws.
    strip: strip.Strip,
    /// The inputs `strip` was derived from.
    stripped: Stripped,
    status: Status,
    /// What the page refused to send, until the operator's next input.
    refusal: Option(String),
    /// How many drafts a command consumed at dispatch. A draft a prompt
    /// carries is consumed when the lane sends it, which the shared record
    /// counts as `drafts_sent`; the composer's editor is keyed by the sum,
    /// so a consumed draft is replaced by an empty editor while a refused
    /// one stays as the operator left it.
    consumed: Int,
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
      strand,
      start.session_id,
      msg.Stamp(now_ms: 0, transport_ms: 0),
      inbox.new(Nil),
      inbox.new(Nil),
    )
  Model(
    shared:,
    view: View(
      label: start.label,
      expected: start.expected,
      transport: start.transport,
      paging: Tail,
      earlier: Reached,
      blocks: [],
      pieces: [],
      projected: projected_of(shared, Tail),
      strip: strip.Strip(chips: [], advisor: None, settled: 0),
      stripped: stripped_of(shared),
      status: Connecting,
      refusal: None,
      consumed: 0,
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
      stepping(Model(..model, shared:), [tick_at(at)], at)
    }

    Refused(reason:) -> #(
      Model(..model, view: View(..model.view, status: Ended(reason))),
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
    Ticked -> stepping(model, [tick_at(at)], at)

    OlderRequested -> older_at(model, at)
  }
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
  finished(Model(..model, shared:), effects, at)
}

// The end of every message: what the page draws is derived from the record
// the step left, the deadline timer is armed for the lane's next due
// reading, and the effects the step decided are performed as one.
fn finished(
  model: Model(socket),
  effects: List(step_effect.Effect(socket, Nil)),
  at: Int,
) -> #(Model(socket), Effect(Msg(socket))) {
  let model = refreshed(model) |> rearm(at)
  #(model, perform(model.view.transport, effects))
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
  let shared =
    list.fold(updates, model.shared, fn(shared, update) {
      lane_fold.apply_channel_update(shared, update, lane_fold.nothing_shown())
      |> step.forget_surfaces
    })
  refreshed(Model(..model, shared:))
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
    projected_of(model.shared, model.view.paging) == model.view.projected
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
  statused(model)
}

fn projected_of(shared: Session(socket), paging: Paging) -> Projected {
  Projected(
    captured: shared.captured,
    scrollback: shared.scrollback,
    notices: shared.cache_notices,
    agents: shared.agent_rows,
    paging:,
  )
}

fn stripped_of(shared: Session(socket)) -> Stripped {
  Stripped(
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
            |> history_view.capture(cut.window, view, strand),
        ),
      )
    history_view.Reading, history_view.Quiet, None
    | history_view.Reading, history_view.Wanted, _
    | history_view.Reading, history_view.Pending(_), _
    | history_view.Live, _, _
    -> model
  }
}

// Projects the page strand's blocks and pieces from the history window and
// the notices. This is the one place a projection runs.
//
// The page holds the newest turns whose rows fit its limit, and cuts the
// rest (`held`). Records older than the oldest row it keeps are then dropped
// from the history window, so the next capture projects only what the page
// draws and the records a capture adds. The window is trimmed only when
// rows were cut: a record at the start of the strand that draws no row
// would otherwise leave the page offering to load rows it will never draw.
// The trim is a write to the shared record, and one of the two this module
// makes.
//
// The end of a turn whose input is older than the window is not drawn, but
// its records stay in the window (`AtInput`), so the next read asks for the
// sequences below them. Trimming them too would make every read ask for
// the same interval again, and a turn longer than one read could never be
// loaded whole.
//
// Older rows can be loaded only while there are sequences below the window
// to read (`history_view.older` asks for none below the first). A branch
// whose oldest parent is missing with nothing below to read offers no
// button that would do nothing.
fn relaned(model: Model(socket)) -> Model(socket) {
  let shared = model.shared
  case shared.captured {
    None -> settled_projection(model)
    Some(#(cut, view)) -> {
      let branch = history_view.branch(shared.scrollback, view)
      let all =
        transcript.branch_blocks(
          branch,
          cut,
          view,
          strand,
          shared.cache_notices,
        )
      let #(lead, opened) = turns.grouped(all, view.strands)
      let #(blocks, fit) =
        held(lead, opened, branch.unloaded, limit(model.view.paging))
      let latest = turns.latest(view, shared.agent_rows, strand)
      let pieces = turns.pieces(blocks, view.strands, latest)
      let #(scrollback, earlier) = case fit, branch.unloaded {
        Whole, None -> #(shared.scrollback, Reached)
        Whole, Some(_) ->
          case shared.scrollback.before_seq > 1 {
            True -> #(shared.scrollback, Unheld)
            False -> #(shared.scrollback, Reached)
          }
        AtInput, _ -> #(trimmed(shared.scrollback, lead), Unheld)
        Cut, _ -> #(trimmed(shared.scrollback, blocks), Unheld)
      }

      // A paged page that had to cut a whole turn to stay within its
      // limit is full: loading more would only cut again.
      let paging = case fit, model.view.paging {
        Cut, Paged -> Full
        Cut, Tail | Cut, Full | Whole, _ | AtInput, _ -> model.view.paging
      }
      settled_projection(Model(
        shared: Shared(..shared, scrollback:),
        view: View(..model.view, blocks:, pieces:, earlier:, paging:),
      ))
    }
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
      projected: projected_of(model.shared, model.view.paging),
    ),
  )
}

// How much of what the history window projects the page holds.
type Fit {
  // Every block.
  Whole

  // Every turn that opens at an input. The blocks before the first input
  // were left out, because they are the end of a turn whose input is older
  // than the window and older rows can still be loaded; the page starts at
  // an input instead.
  AtInput

  // The newest turns that fit the page's limit; an older turn did not.
  Cut
}

// The row limit for how much history the page holds.
fn limit(paging: Paging) -> Int {
  case paging {
    Tail -> live_rows
    Paged | Full -> held_rows
  }
}

// The newest turns whose rows, together, fit `limit`, oldest first.
//
// The page starts at a turn's input whenever it can, so that no turn it
// holds is keyed by the window's start (`turns.grouped` says why). The
// blocks before the first input are held only when nothing older exists,
// which makes them the start of the strand, or when they are all there is.
//
// The newest turn is always held. When it alone is over the limit, which a
// long run of work can be, the page holds its newest blocks that fit, and
// at least its newest block, so a page mid-turn still shows the turn's end.
// That turn is then keyed by the window's start. The window's start moves
// each time the turn grows by a block, since the window is trimmed to its
// oldest held block, so the key changes and the turn's held rows, at most
// the limit, are drawn again on that capture. Only a turn longer than the
// whole limit pays this.
fn held(
  lead: List(transcript_lines.Block),
  opened: List(List(transcript_lines.Block)),
  unloaded: Option(String),
  limit: Int,
) -> #(List(transcript_lines.Block), Fit) {
  let #(groups, fit) = case lead, opened, unloaded {
    [], _, _ -> #(opened, Whole)
    [_, ..], [], _ | [_, ..], _, None -> #([lead, ..opened], Whole)
    [_, ..], [_, ..], Some(_) -> #(opened, AtInput)
  }
  let #(blocks, fit) = case list.reverse(groups) {
    [] -> #([], fit)
    [newest, ..older] -> {
      let rows = row_count(newest)
      case rows > limit {
        True -> #(newest_blocks(list.reverse(newest), limit, 0, []), Cut)
        False -> older_turns(older, limit, rows, newest, fit)
      }
    }
  }

  // The end of a turn left out above the held turns can only grow as older
  // pages bring the rest of it. Once it alone no longer fits in the room
  // left, the whole turn never will, so the page is as full as that turn
  // lets it be. Calling it cut stops the page reading ever further down a
  // turn it cannot draw, and keeps the window from filling with its records.
  case fit {
    AtInput ->
      case row_count(blocks) + row_count(lead) > limit {
        True -> #(blocks, Cut)
        False -> #(blocks, AtInput)
      }
    Whole | Cut -> #(blocks, fit)
  }
}

// Adds older turns, newest first, in front of what is held while they fit.
fn older_turns(
  older: List(List(transcript_lines.Block)),
  limit: Int,
  rows: Int,
  kept: List(transcript_lines.Block),
  fit: Fit,
) -> #(List(transcript_lines.Block), Fit) {
  case older {
    [] -> #(kept, fit)
    [turn, ..rest] -> {
      let rows = rows + row_count(turn)
      case rows > limit {
        True -> #(kept, Cut)
        False -> older_turns(rest, limit, rows, list.append(turn, kept), fit)
      }
    }
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

// Drops the records older than the oldest block the page holds.
fn trimmed(
  scrollback: history_view.State,
  blocks: List(transcript_lines.Block),
) -> history_view.State {
  case blocks {
    [] -> scrollback
    [oldest, ..] ->
      case transcript_lines.block_seq(oldest) {
        Ok(seq) -> history_view.retain_from(scrollback, seq)
        Error(Nil) -> scrollback
      }
  }
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
  let chips = agent_roster.chips(shared.roster, shared.agent_rows, strand)
  let chip = fn(line: agent_roster.Line) {
    strip.Chip(
      line:,
      hue: turns.hue(shared.strands, line.id),
      cache: outlook(shared, line.id),
      running_ms: running_ms(shared, line.id),
    )
  }
  strip.Strip(
    chips: list.map(chips.listed, chip),
    advisor: option.map(chips.advisor, chip),
    settled: chips.settled,
  )
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
    _, Some(reason), _ -> Ended(reason)
    Connecting, None, Some(_) -> Following
    Connecting, None, None | Following, None, _ -> model.view.status
  }
  Model(..model, view: View(..model.view, status:))
}

// --- what the operator does ------------------------------------------------

/// Submits an operator's text to the page's strand through the shared
/// step's command arm.
///
/// Empty text and text over `prompt_limit` are refused with a notice
/// before they become a command, because they are the page socket's limits
/// and not the session's. The draft is then parsed as the terminal parses
/// it (`command.parse_with_skills`). A session command, which includes an
/// ordinary prompt, goes to the step (`commands.act`) and what the step
/// decides is folded back as its notice. A command that names a terminal
/// surface (`/help`, `/models`, `/sessions` and the rest) is refused with a
/// notice: the page has no such surface, and sending it to the model as a
/// prompt would run the words as an instruction.
///
/// ## Examples
///
/// ```gleam
/// // component.submit(model, "inspect the tree", operator.Prompt)
/// ```
pub fn submit(
  model: Model(socket),
  text: String,
  delivery: operator.Delivery,
) -> #(Model(socket), Effect(Msg(socket))) {
  case string.trim(text), string.byte_size(text) > prompt_limit {
    "", _ -> refused(model, "Nothing to send.")
    _, True ->
      refused(
        model,
        "The draft is longer than the page sends ("
          <> int.to_string(prompt_limit)
          <> " bytes).",
      )
    _, False ->
      case page_command(command.parse_with_skills(text, model.shared.skills)) {
        Ok(session) ->
          commanded(model, msg.Submit(draft: text, command: session, delivery:))
        Error(notice) -> refused(model, notice)
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
      let choice = case answer {
        AllowOnce -> operator.AllowOnce
        Deny -> operator.Deny
      }
      commanded(model, msg.Decide(review: record, choice:))
    }
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
  let #(shared, effects) =
    step.update(
      model.shared,
      msg.Input(at: stamp(at), event: msg.Acted(command)),
    )
  let consumed = case list.any(shared.surface_facts, took_draft) {
    True -> model.view.consumed + 1
    False -> model.view.consumed
  }
  finished(
    Model(
      shared: step.forget_surfaces(shared),
      view: View(..model.view, refusal: None, consumed:),
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

/// Asks for the rows older than the oldest one the page holds, when the
/// lane lists them as `lane.Earlier`, and does nothing otherwise.
///
/// The page's limit rises from `live_rows` to `held_rows`, and the history
/// window asks for the interval of at most a hundred sequences below its
/// oldest record (`history_view.older`), which the step's tick sends as a
/// `history` read as soon as the lane has no other request out. That is the
/// read the terminal pages with, and a read, not a mutation: the gateway
/// admits it for an observer's attachment as for an operator's. While it
/// is out the lane draws `lane.Loading`, and a second press asks nothing.
/// The reply is folded in by the step.
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
fn older_at(
  model: Model(socket),
  at: Int,
) -> #(Model(socket), Effect(Msg(socket))) {
  let shared = model.shared
  case top(model), shared.captured, model.view.status {
    lane.Earlier, Some(#(_, view)), Following -> {
      let branch = history_view.branch(shared.scrollback, view)
      let asked =
        Shared(
          ..shared,
          scrollback: history_view.older(shared.scrollback, branch.unloaded),
        )
      stepping(
        Model(
          shared: asked,
          view: View(..model.view, paging: Paged, refusal: None),
        ),
        [tick_at(at)],
        at,
      )
    }

    // Nothing older to load, a read already out, a page at its limit, or
    // a page that is not following a session.
    lane.Beginning, _, _
    | lane.Loading, _, _
    | lane.Full(_), _, _
    | lane.Earlier, None, _
    | lane.Earlier, Some(_), Connecting
    | lane.Earlier, Some(_), Ended(_)
    -> #(model, effect.none())
  }
}

/// What the lane draws above the oldest row the page holds.
///
/// ## Examples
///
/// ```gleam
/// // component.top(model) == lane.Earlier
/// ```
pub fn top(model: Model(socket)) -> lane.Top {
  case model.shared.scrollback.request, model.view.earlier, model.view.paging {
    history_view.Wanted, _, _ | history_view.Pending(_), _, _ -> lane.Loading
    history_view.Quiet, Reached, _ -> lane.Beginning
    history_view.Quiet, Unheld, Full -> lane.Full(held_rows)
    history_view.Quiet, Unheld, Tail | history_view.Quiet, Unheld, Paged ->
      lane.Earlier
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
  let due = option.then(model.shared.channel, session_channel.next_due)
  let armed = case model.view.timer, due {
    Some(timer), Some(due) ->
      Some(process.send_after(timer, int.max(0, due - now), Nil))
    Some(_), None | None, _ -> None
  }
  Model(..model, view: View(..model.view, armed:))
}

// --- what the page reads ---------------------------------------------------

/// The transcript lines of the page strand's blocks, oldest first: the
/// lines the terminal draws for the same capture, which the lane lays out
/// as turns.
///
/// ## Examples
///
/// ```gleam
/// // component.lines(model)
/// ```
pub fn lines(model: Model(socket)) -> List(Line) {
  list.flat_map(model.view.blocks, fn(block) {
    list.map(block.rows, fn(row) { row.1 })
  })
}

/// The lane's pieces, in order (`session_view/turns`).
///
/// ## Examples
///
/// ```gleam
/// // lane.view(component.pieces(model))
/// ```
pub fn pieces(model: Model(socket)) -> List(turns.Piece) {
  model.view.pieces
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
  list.find(model.view.strip.chips, fn(chip) { chip.line.id == strand })
  |> option.from_result
}

/// The connection's status.
///
/// ## Examples
///
/// ```gleam
/// // component.status(model) == component.Following
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

/// What the page last told the operator: its own refusal of an input if
/// there is one, otherwise what the session last said.
///
/// ## Examples
///
/// ```gleam
/// // component.notice(model) == component.Quiet
/// ```
pub fn notice(model: Model(socket)) -> Notice {
  case model.view.refusal, model.shared.notice {
    Some(text), _ -> Warned(text)
    None, "" -> Quiet
    None, text -> Said(text)
  }
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

/// The transcript rows the page draws, keyed, oldest first.
///
/// ## Examples
///
/// ```gleam
/// // component.rows(model)
/// ```
pub fn rows(model: Model(socket)) -> List(transcript.Row) {
  list.flat_map(model.view.blocks, fn(block) {
    list.map(block.rows, fn(row) { transcript.Row(key: row.0, line: row.1) })
  })
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

/// The observer's page: the heading, the agent strip, the lane, and a fixed
/// line saying the page is read-only. Its one event handler is the lane's
/// "Load older" button, whose message asks for a read and nothing else; the
/// page socket admits that one event from an observer and drops every other
/// frame (protocol-change/051, the addendum on history paging).
///
/// Each region is drawn by its own module under `web_view/view`
/// (`heading`, `strip` and `lane`); this function only lays them out, as
/// `operator_page.view` does for the operator's page.
///
/// ## Examples
///
/// ```gleam
/// // element.to_string(component.view(model))
/// ```
pub fn view(model: Model(socket)) -> Element(Msg(socket)) {
  html.main([attribute.class("loom-session")], [
    heading(model),
    strip.view(model.view.strip),
    lane.view(model.view.pieces, top(model), OlderRequested),
    html.p([attribute.class("observer-bar")], [
      html.text(
        "Observer · read-only · you can follow this session; ask the owner for operator access",
      ),
    ]),
  ])
}

/// The page's heading, drawn by `web_view/view/heading` from the session's
/// identity, the catalogue's label and the connection's status.
///
/// The heading module takes the label's two fields and the status's words
/// as plain values, because it cannot import the types this module defines.
///
/// ## Examples
///
/// ```gleam
/// // component.heading(model)
/// ```
pub fn heading(model: Model(socket)) -> Element(message) {
  heading.view(
    session_id: model.shared.session,
    name: option.map(model.view.label, fn(label) { label.name }),
    workspace: option.map(model.view.label, fn(label) { label.workspace }),
    status: status_text(model.view.status),
  )
}

// The connection's status as the heading words it.
fn status_text(status: Status) -> String {
  case status {
    Connecting -> "connecting"
    Following -> "following"
    Ended(reason:) -> "disconnected: " <> reason
  }
}
