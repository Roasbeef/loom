//// The web view's host for one session: a Lustre server component that
//// drives `session_view`'s lane and draws the session's transcript lines
//// as HTML.
////
//// The component is the lane's host in the sense ADR-014 gives the word. It
//// reads what the engine may not read (a clock, a mailbox) and delivers it as
//// messages, and it performs the lane's outputs. It holds no session logic of
//// its own: which frames to send, what a reply means, when to catch up,
//// which lines a capture becomes and what an operator's input becomes on the
//// wire are all `session_view`'s, exactly as they are for the terminal. What
//// is web-specific here is the delivery (a Lustre selector instead of an
//// etui tick) and the view (HTML elements instead of terminal cells).
////
//// Delivery is event-driven (ADR-013, the addendum on event-driven
//// delivery). The selector that reads the transport's inbox drains it in
//// the same breath: the frame it matched and up to `arrival_batch - 1` more
//// that are already waiting become one `Arrived`, with the clock reading
//// taken after the drain. `Arrived` files the batch into the engine's
//// `session_view/inbox` and reduces it at once: every filed frame goes to
//// the lane, oldest first, through `operator.drain`, the loop the terminal
//// runs too, followed by the lane's own `tick` at the batch's reading.
////
//// Batching is what keeps a burst cheap. Lustre 5.7.1 runs the view, diffs
//// it and broadcasts the patch for every message the runtime takes, with no
//// check for an empty patch, so one message per frame would be one render
//// per frame. One message per burst is one render per burst.
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
//// a subject the component selects. The interpreter for the lane's outputs
//// has the terminal's shape: `Transmit` writes a frame through the
//// transport and `Shut` closes it, in the order the lane decided them, in
//// one effect. The component has no recorder, so its recorder type is `Nil`
//// and it never queues a note.
////
//// This module is the observer's application, and its message type carries
//// no command: a browser has nothing it can send it, since its view attaches
//// no event handler. An operator's page is `web_view/operator_page`, which
//// wraps these messages with the two commands an operator may send and
//// reaches the lane through `submit` and `decide` here, which call the
//// engine's command arms.
////
//// The page holds a bounded number of transcript rows: the newest
//// `live_rows` of its strand, or `held_rows` once the reader has loaded
//// older ones. It keeps the strand's history window across captures
//// (`history_view`, the terminal's `scrollback`), projects the newest turns
//// that fit, and trims the window to what it draws. `older` pages further
//// back through the lane's `history` read, the read the terminal pages
//// with. The window is session state the shared step will hold for both
//// hosts; the limit and `Paging` are this page's view state.
////
//// The page's regions are drawn by the modules under `web_view/view`: the
//// heading, the agent strip and the transcript lane. This module derives
//// what they draw, when a message changes it, and `view` lays them out.

import core/message
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
import session_view/connection_event
import session_view/history_view
import session_view/inbox.{type Inbox}
import session_view/operator
import session_view/protocol
import session_view/reviewer_status
import session_view/session_channel
import session_view/snapshot
import session_view/snapshot_view
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
/// fifth more. 150 rows is also more than one capture brings, since a cut
/// holds at most a hundred records of the whole session, and several
/// screens of reading before the reader needs "Load older".
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
    /// A monotonic reading in milliseconds, for the lane's deadlines.
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

/// What the page last told an operator about their own input. Its text is
/// the component's own or the engine's, never the session's.
pub type Notice {
  /// Nothing to say.
  Quiet

  /// An outcome worth stating, such as a prompt that was sent.
  Said(text: String)

  /// A refusal or a loss the operator should read.
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

/// The component's state: the lane, the frames filed since the last tick,
/// the last completed capture and what was derived from it.
pub opaque type Model(socket) {
  Model(
    session_id: String,
    label: Option(Label),
    expected: snapshot.Expected,
    transport: Transport(socket),
    /// `None` until the transport has opened.
    lane: Option(session_channel.Channel(socket, Nil)),
    /// Frames filed since the last tick, oldest first. The component has
    /// one source, so its source is `Nil`.
    filed: Inbox(Nil, connection_event.Message),
    /// The last `Captured` update.
    shown: Option(#(snapshot.Captured, snapshot_view.View)),
    /// The page strand's history window: each capture folded in, and each
    /// older page the reader loaded. It is the terminal's `scrollback`,
    /// session state the shared step will hold for both hosts, and it is
    /// trimmed to the oldest row the page draws (`history_view.retain_from`).
    scrollback: history_view.State,
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
    /// Every strand's agent row from the last capture (`agent_view`), and
    /// the reviewer rows it is observed with.
    agents: List(agent_view.Row),
    reviewers: List(reviewer_status.Row),
    /// The roster's memory of glances, clocks and pushed context sizes.
    roster: agent_roster.Roster,
    /// The prompt-cache ledger the usage pushes are folded into.
    cache: cache_watch.Ledger,
    /// Cache-miss notices raised on this page for its strand, oldest first.
    /// Like the terminal's, they are transient and are not stored.
    notices: List(CacheNotice),
    /// The agent strip, derived when a capture, a usage push or a tick
    /// changed something it draws.
    strip: strip.Strip,
    /// The escalations of `shown`, and the settled ones kept beside them.
    approvals: List(approval.Review),
    status: Status,
    /// The latest clock reading: the one a message carried, or the one a
    /// command read for itself, which its deadline is measured from.
    clock: Int,
    /// The timer's subject, once the tick selector is armed.
    timer: Option(Subject(Nil)),
    /// The one timer armed for the lane's next due reading, kept so the
    /// next arming can cancel it.
    armed: Option(process.Timer),
    /// What the page last told the operator.
    notice: Notice,
    /// The command counter an operator's commands are encoded with.
    next_id: Int,
    /// How many drafts have been sent. The composer's editor is keyed by
    /// it, so a sent draft is replaced by an empty editor while a refused
    /// one stays as the operator left it.
    drafts: Int,
  )
}

/// Everything the component can be told.
pub type Msg(socket) {
  /// The transport opened, at this monotonic reading.
  Opened(socket: socket, at: Int)

  /// The transport refused to open.
  Refused(reason: String)

  /// The deadline timer's selector is armed on this subject.
  TimerArmed(timer: Subject(Nil))

  /// The frames the transport delivered, oldest first, and the monotonic
  /// reading taken after they were read. One message carries a whole burst,
  /// up to `arrival_batch` frames, and it is reduced at once.
  Arrived(messages: List(connection_event.Message), at: Int)

  /// The timer armed for the lane's next due reading fired, at this
  /// monotonic reading.
  Ticked(at: Int)
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
  Model(
    session_id: start.session_id,
    label: start.label,
    expected: start.expected,
    transport: start.transport,
    lane: None,
    filed: inbox.new(Nil),
    shown: None,
    scrollback: history_view.empty(),
    paging: Tail,
    earlier: Reached,
    blocks: [],
    pieces: [],
    agents: [],
    reviewers: [],
    roster: agent_roster.new(),
    cache: cache_watch.new(),
    notices: [],
    strip: strip.Strip(chips: [], advisor: None, settled: 0),
    approvals: [],
    status: Connecting,
    clock: 0,
    timer: None,
    armed: None,
    notice: Quiet,
    next_id: 1,
    drafts: 0,
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
  #(model, effect.batch([open(start.transport), arm(start.transport)]))
}

// Opens the transport inside the component's process, once. The inbox and
// the subject the outcome arrives on are both created here, in the
// component's process, so every frame and the open's answer are read by
// the process that owns them. `connect` returns at once; the answer is a
// message, so a slow gateway attach cannot hold the component's start.
// The clock is read when the answer is received, in the mapping, which is
// host code.
//
// A frame's mapping drains the inbox behind it, so a burst that is already
// waiting becomes one message and one render. The clock is read after the
// drain, so the batch's reading is no earlier than any frame in it.
fn open(transport: Transport(socket)) -> Effect(Msg(socket)) {
  use _dispatch, opened <- server_component.select
  let inbox = process.new_subject()
  transport.connect(inbox, opened)
  process.new_selector()
  |> process.select_map(opened, fn(outcome) {
    case outcome {
      Ok(socket) -> Opened(socket, transport.now())
      Error(reason) -> Refused(reason)
    }
  })
  |> process.select_map(inbox, fn(first) {
    let messages = [first, ..waiting(inbox, arrival_batch - 1, [])]
    Arrived(messages, transport.now())
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
// says when it is next due once it exists. The clock is read when the timer
// message is received, which is host code, so the reading `Ticked` carries
// is the instant the timer fired.
fn arm(transport: Transport(socket)) -> Effect(Msg(socket)) {
  use dispatch, timer <- server_component.select
  dispatch(TimerArmed(timer))
  process.new_selector()
  |> process.select_map(timer, fn(_) { Ticked(transport.now()) })
}

/// Applies one message.
///
/// ## Examples
///
/// ```gleam
/// // let #(model, effect) = component.update(model, component.Ticked(250))
/// ```
pub fn update(
  model: Model(socket),
  message: Msg(socket),
) -> #(Model(socket), Effect(Msg(socket))) {
  case message {
    // The lane starts with its subscribe in flight, and anything filed
    // before it existed is handed to it at once, in arrival order.
    Opened(socket:, at:) -> {
      let lane = session_channel.start(socket, model.expected, now: at)
      let #(lane, outputs) = session_channel.take_outputs(lane)
      let #(model, effects) =
        reduce(Model(..model, lane: Some(lane), clock: at), at)
      #(
        rearm(model, at),
        effect.batch([perform(model.transport, outputs), effects]),
      )
    }

    Refused(reason:) -> #(Model(..model, status: Ended(reason)), effect.none())

    // The timer's subject can be ready after the lane opened, since the
    // open's answer comes from another process, so the first arming may
    // happen here.
    TimerArmed(timer:) -> #(
      rearm(Model(..model, timer: Some(timer)), model.clock),
      effect.none(),
    )

    // A batch is filed behind anything still held and reduced now. One
    // message is one render, so the whole batch costs one.
    Arrived(messages:, at:) -> {
      let filed = list.fold(messages, model.filed, inbox.push)
      let #(model, effects) = reduce(Model(..model, filed:, clock: at), at)
      #(rearm(model, at), effects)
    }

    // The lane's due reading passed: its tick acts, and the strip's labels
    // are brought up to the same reading.
    Ticked(at:) -> {
      let #(model, effects) = reduce(Model(..model, clock: at), at)
      #(rearm(ticked(model, at), at), effects)
    }
  }
}

// Every filed frame goes to the lane in arrival order, then the lane's own
// tick runs, which is where its idle refresh and deadlines are checked. A
// reduction before the transport opens keeps what was filed for the next
// one.
//
// A read for older rows the lane was too busy to take is offered again
// last, once the lane has done everything the frames asked of it, as the
// terminal offers it after each of its drains. The lane's outputs are then
// one ordered effect.
fn reduce(
  model: Model(socket),
  at: Int,
) -> #(Model(socket), Effect(Msg(socket))) {
  case model.lane {
    None -> #(model, effect.none())
    Some(_) -> {
      let model = drained(model)
      case model.lane {
        None -> #(model, effect.none())
        Some(lane) -> {
          let #(lane, ticked) = session_channel.tick(lane, now: at)
          apply(Model(..model, lane: Some(lane)), ticked)
          |> serviced
          |> taken
        }
      }
    }
  }
}

// Sends the read `history_view` says is owed, when the lane can take it.
//
// The lane has one request out at a time. A busy lane refuses the read, and
// the demand stays `Wanted` in the history window until the next reduction
// offers it again; nothing else is needed to retry it, because every
// transition that frees the lane is a reduction. Only a read the lane
// accepted becomes `Pending`, which is what `accept` matches the reply
// against.
fn serviced(model: Model(socket)) -> Model(socket) {
  case history_view.range(model.scrollback), model.lane {
    Some(#(after, before)), Some(lane) ->
      case session_channel.history(lane, after, before, now: model.clock) {
        Error(_) -> model
        Ok(lane) ->
          Model(
            ..model,
            lane: Some(lane),
            scrollback: history_view.sent(model.scrollback, before),
          )
      }
    Some(_), None | None, _ -> model
  }
}

// Takes everything the lane queued, keeping the emptied lane so no output
// is performed twice, and performs it as one ordered effect.
fn taken(model: Model(socket)) -> #(Model(socket), Effect(Msg(socket))) {
  case model.lane {
    None -> #(model, effect.none())
    Some(lane) -> {
      let #(lane, outputs) = session_channel.take_outputs(lane)
      #(Model(..model, lane: Some(lane)), perform(model.transport, outputs))
    }
  }
}

// Hands every filed frame to the lane, oldest first, through the engine's
// drain. The lane's outputs stay queued on it until the caller takes them,
// so a command submitted after the drain leaves behind them, in order.
fn drained(model: Model(socket)) -> Model(socket) {
  operator.drain(model, inbox.held(model.filed), take_filed, received)
}

fn take_filed(
  model: Model(socket),
) -> #(Model(socket), Result(connection_event.Message, Nil)) {
  let #(filed, next) = inbox.take(model.filed)
  #(Model(..model, filed:), next)
}

fn received(
  model: Model(socket),
  message: connection_event.Message,
) -> Model(socket) {
  case model.lane {
    None -> model
    Some(lane) -> {
      let #(lane, updates) =
        session_channel.receive(lane, message, now: model.clock)
      apply(Model(..model, lane: Some(lane)), updates)
    }
  }
}

/// Folds the lane's updates into the component: a capture is projected
/// once, here, into the blocks and pieces the view draws, the agent rows
/// and strip, and the escalations it offers; a usage push is folded into
/// the cache ledger and the roster; a submission's outcome becomes the
/// notice; a failure ends the page.
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
    case update {
      session_channel.Captured(cut:, view:, ..) -> captured(model, cut, view)
      session_channel.Failed(reason:) -> Model(..model, status: Ended(reason))
      session_channel.Submission(disposition:) -> settled(model, disposition)
      session_channel.UnknownOutcome(..) ->
        Model(
          ..model,
          notice: Warned(
            "The daemon's reply to your last command was lost. It was not resent.",
          ),
        )

      // An older page of the strand's history, answering the read the page
      // sent for it.
      session_channel.HistoryPage(window:, before_seq:, after_seq:) ->
        paged(model, window, before_seq, after_seq)

      // The daemon refused the read for older rows. The demand is retired
      // and the page follows the session again, with the rows it held, so
      // the reader can ask once more.
      session_channel.RequestRefused(command: "history", code:, ..) ->
        Model(
          ..model,
          scrollback: history_view.cancel(model.scrollback),
          notice: Warned("Loading older rows was refused: " <> code),
        )
        |> resumed

      // The daemon's answer to the page's own command replaces whatever
      // the page said before, as the terminal's footer does, so the notice
      // always states the outcome of the latest command rather than an
      // earlier refusal or a "sent" the daemon has since answered. The only
      // read the page's lane sends that expects a reply is the history read
      // above, which is never acknowledged, so every other acknowledgement
      // and refusal it sees answers a command this page issued. A refusal
      // names its code, which the daemon chooses, and not its message.
      session_channel.Acknowledged(command:, status:) ->
        Model(..model, notice: Said(command <> " " <> status))
      session_channel.RequestRefused(command:, code:, ..) ->
        Model(..model, notice: Warned(command <> " refused: " <> code))

      session_channel.Auxiliary(protocol.UsageChanged(
        strand:,
        seq:,
        operation:,
        usage:,
      )) -> used(model, strand, seq, operation, usage)

      // The page sends no escalation lookup, so a `LookedUp` never answers
      // it, and it draws no live stream.
      session_channel.LookedUp(..)
      | session_channel.Auxiliary(..)
      | session_channel.Streamed(..)
      | session_channel.ToolStreamed(..)
      | session_channel.Noticed(..) -> model
    }
  })
}

// One capture, in the order the terminal takes it: the cache ledger is
// carried across the new configuration before anything is compared, the
// agent rows and the roster are observed, and only then are the pushed
// usage rows the capture covers settled, so a miss they reveal is anchored
// to the records this capture holds.
fn captured(
  model: Model(socket),
  cut: snapshot.Captured,
  view: snapshot_view.View,
) -> Model(socket) {
  case model.shown == Some(#(cut, view)) {
    True -> recaptured(model, cut.next_seq)
    False -> fresh(model, cut, view)
  }
}

// The lane refreshes an idle page every few seconds, and a refresh of a
// session where nothing moved brings back the capture already drawn. Comparing it
// with the one shown costs a walk of the two terms; projecting it again
// would cost the agent rows, the lane and the strip for nothing. Only the
// cache ledger can still move, since a held usage row may be covered now.
fn recaptured(model: Model(socket), next_seq: Int) -> Model(socket) {
  let settled = settle_cache(model, next_seq)
  case settled.notices == model.notices, settled.cache == model.cache {
    True, True -> settled
    True, False -> restripped(settled)
    False, _ -> relaned(settled)
  }
}

fn fresh(
  model: Model(socket),
  cut: snapshot.Captured,
  view: snapshot_view.View,
) -> Model(socket) {
  let previous = option.map(model.shown, fn(shown) { shown.1 })
  let reviewers = reviewer_status.observe(model.reviewers, cut.window, view)
  Model(
    ..model,
    shown: Some(#(cut, view)),
    scrollback: history_view.capture(model.scrollback, cut.window, view, strand),
    cache: cache_watch.capture(model.cache, previous, view),
    reviewers:,
    agents: agent_view.observe(model.agents, cut.window, view, reviewers),
    roster: agent_roster.observe(model.roster, view, model.clock),
    approvals: case approval.records(view.cells) {
      Ok(current) -> approval.project(model.approvals, current)
      Error(_) -> []
    },
    status: Following,
  )
  |> settle_cache(cut.next_seq)
  |> relaned
}

// A usage row the daemon pushed. One with a durable sequence is admitted
// once, becomes the strand's context size, and waits for a capture that
// covers it; one without is compared at once. Either way the strip is
// redrawn, since a context size or an outlook may have moved.
fn used(
  model: Model(socket),
  strand: String,
  seq: Option(Int),
  operation: Option(String),
  usage: message.Usage,
) -> Model(socket) {
  case seq {
    Some(seq) -> {
      let covered = option.map(model.shown, fn(shown) { { shown.0 }.next_seq })
      case
        cache_watch.admit(
          model.cache,
          strand,
          seq,
          operation,
          usage,
          model.clock,
          covered,
        )
      {
        Error(Nil) -> model
        Ok(cache) -> {
          let model =
            Model(
              ..model,
              cache:,
              roster: agent_roster.observe_usage(
                model.roster,
                strand,
                operation,
                agent_roster.context(usage),
              ),
            )
          case covered {
            Some(next_seq) -> settle_pushed(model, next_seq)
            None -> restripped(model)
          }
        }
      }
    }
    None -> {
      let #(cache, missed) =
        cache_watch.observe(
          model.cache,
          strand,
          usage,
          model.clock,
          cache_watch.Live,
        )
      case missed {
        None -> restripped(Model(..model, cache:))
        Some(found) -> noted(Model(..model, cache:), found) |> relaned
      }
    }
  }
}

// Settles the held usage rows a capture covers and files each miss they
// reveal.
fn settle_cache(model: Model(socket), next_seq: Int) -> Model(socket) {
  let #(cache, missed) =
    cache_watch.settle(model.cache, next_seq, cache_watch.Live)
  list.fold(missed, Model(..model, cache:), noted)
}

// A pushed row the last capture already covers is settled at once. A push
// usually runs ahead of the captures, so settling finds nothing and files
// no notice; the lane is projected again only when a miss was found, and
// otherwise only the strip, whose context size or outlook may have moved.
fn settle_pushed(model: Model(socket), next_seq: Int) -> Model(socket) {
  let settled = settle_cache(model, next_seq)
  case settled.notices == model.notices {
    True -> restripped(settled)
    False -> relaned(settled)
  }
}

// Files one miss as a notice after the newest entry its strand holds, as
// the terminal files one. The page draws one strand, so a miss on another
// strand has no row here; that strand's chip still shows its outlook.
fn noted(model: Model(socket), found: cache_watch.Missed) -> Model(socket) {
  case model.shown, found.strand == strand {
    Some(#(cut, view)), True ->
      case transcript.newest_entry(cut, view, strand) {
        None -> model
        Some(after_entry) ->
          Model(
            ..model,
            notices: list.append(model.notices, [
              transcript_line.CacheNotice(
                strand:,
                after_entry:,
                text: cache_watch.notice_text(found.miss),
              ),
            ]),
          )
      }
    _, _ -> model
  }
}

// An older page arrived for the read the page has out. It joins the history
// window, and the page follows the session again from the newest capture,
// which `capture` folds in on top of the pages read. A reply for any other
// read, which the lane's one reply slot should never deliver, is dropped.
fn paged(
  model: Model(socket),
  window: snapshot.Window,
  before: Int,
  after: Int,
) -> Model(socket) {
  case model.shown, model.scrollback.request == history_view.Pending(before) {
    Some(#(_, view)), True ->
      Model(
        ..model,
        scrollback: history_view.accept(
          model.scrollback,
          window,
          before,
          after,
          view,
        ),
      )
      |> resumed
    Some(_), False | None, _ -> model
  }
}

// Asking for older rows freezes the history window (`history_view.older`),
// so a capture that lands while the read is out cannot move the endpoint
// the reply will be placed against. Once the read is answered or refused,
// the window follows the session again and takes in the newest capture,
// which `shown` kept while the window was frozen.
fn resumed(model: Model(socket)) -> Model(socket) {
  case model.shown {
    None -> model
    Some(#(cut, view)) ->
      Model(
        ..model,
        scrollback: history_view.resume(model.scrollback)
          |> history_view.capture(cut.window, view, strand),
      )
      |> relaned
  }
}

// Projects the page strand's blocks and pieces from the history window and
// the notices, then the strip. This is the one place a projection runs.
//
// The page holds the newest turns whose rows fit its limit, and cuts the
// rest (`held`). Records older than the oldest row it keeps are then dropped
// from the history window, so the next capture projects only what the page
// draws and the records a capture adds. The window is trimmed only when
// rows were cut: a record at the start of the strand that draws no row
// would otherwise leave the page offering to load rows it will never draw.
fn relaned(model: Model(socket)) -> Model(socket) {
  case model.shown {
    None -> restripped(model)
    Some(#(cut, view)) -> {
      let branch = history_view.branch(model.scrollback, view)
      let all =
        transcript.branch_blocks(branch, cut, view, strand, model.notices)
      let #(lead, opened) = turns.grouped(all, view.strands)
      let #(blocks, fit) =
        held(lead, opened, branch.unloaded, limit(model.paging))
      let latest = turns.latest(view, model.agents, strand)
      let pieces = turns.pieces(blocks, view.strands, latest)
      let #(scrollback, earlier) = case fit, branch.unloaded {
        Whole, None -> #(model.scrollback, Reached)
        Whole, Some(_) -> #(model.scrollback, Unheld)
        AtInput, _ | Cut, _ -> #(trimmed(model.scrollback, blocks), Unheld)
      }

      // A paged page that had to cut a whole turn to stay within its
      // limit is full: loading more would only cut again.
      let paging = case fit, model.paging {
        Cut, Paged -> Full
        Cut, Tail | Cut, Full | Whole, _ | AtInput, _ -> model.paging
      }
      Model(..model, blocks:, pieces:, scrollback:, earlier:, paging:)
      |> restripped
    }
  }
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
// That turn is then keyed by the window's start, which stays the same while
// the window slides within it.
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
  case list.reverse(groups) {
    [] -> #([], fit)
    [newest, ..older] -> {
      let rows = row_count(newest)
      case rows > limit {
        True -> #(newest_blocks(list.reverse(newest), limit, 0, []), Cut)
        False -> older_turns(older, limit, rows, newest, fit)
      }
    }
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
// of the page's clock. Which strands are listed and what each line says is
// `agent_roster.chips`; which outlook may be shown is `cache_watch.shown`.
fn restripped(model: Model(socket)) -> Model(socket) {
  Model(..model, strip: strip_of(model))
}

fn strip_of(model: Model(socket)) -> strip.Strip {
  let strands = strands(model)
  let chips = agent_roster.chips(model.roster, model.agents, strand)
  let chip = fn(line: agent_roster.Line) {
    strip.Chip(
      line:,
      hue: turns.hue(strands, line.id),
      cache: outlook(model, strands, line.id),
      running_ms: running_ms(model, line.id),
    )
  }
  strip.Strip(
    chips: list.map(chips.listed, chip),
    advisor: option.map(chips.advisor, chip),
    settled: chips.settled,
  )
}

// How long a strand's current operation has run, on the roster's clock.
fn running_ms(model: Model(socket), id: String) -> Option(Int) {
  model.agents
  |> list.find(fn(row) { row.id == id })
  |> option.from_result
  |> option.then(agent_roster.running_ms(model.roster, _))
}

fn strands(model: Model(socket)) -> List(protocol.Strand) {
  case model.shown {
    Some(#(_, view)) -> view.strands
    None -> []
  }
}

// A strand the capture lists with a live phase is running, which is the
// terminal's test too, and `cache_watch.shown` says nothing for it.
fn outlook(
  model: Model(socket),
  strands: List(protocol.Strand),
  id: String,
) -> Option(#(cache_miss.Outlook, String)) {
  let activity = case list.find(strands, fn(listed) { listed.id == id }) {
    Ok(protocol.Strand(live_phase: Some(_), ..)) -> cache_watch.Running
    Ok(protocol.Strand(live_phase: None, ..)) | Error(Nil) ->
      cache_watch.Resting
  }
  cache_watch.shown(model.cache, id, activity, model.clock)
  |> option.map(fn(held) { #(held, cache_miss.outlook_label(held)) })
}

// The tick's part in the strip. The browser counts each chip's elapsed
// time, so a second passing redraws nothing; the strip is rebuilt only when
// a drawn cache label changed, which is once a minute at most until a
// countdown's last minute. An idle page's tick therefore leaves the strip
// as the same value and its memoized subtree is not diffed. The timer fires
// only when the lane is due, so a label can lag by up to one refresh
// interval. A countdown label is an upper bound on what remains, so a late
// one still states something true. The labels are
// compared chip by chip rather than by rebuilding the strip, which would
// redo every line's text on every tick.
fn ticked(model: Model(socket), at: Int) -> Model(socket) {
  let #(roster, _) = agent_roster.tick(model.roster, at)
  let model = Model(..model, roster:)
  let strands = strands(model)
  let moved =
    list.any(chips(model.strip), fn(chip) {
      option.map(chip.cache, fn(held) { held.1 })
      != option.map(outlook(model, strands, chip.line.id), fn(held) { held.1 })
    })
  case moved {
    False -> model
    True -> restripped(model)
  }
}

// Every chip of a strip, the advisor's included.
fn chips(strip: strip.Strip) -> List(strip.Chip) {
  case strip.advisor {
    Some(advisor) -> list.append(strip.chips, [advisor])
    None -> strip.chips
  }
}

// What the lane's answer to a submission means for the page. A sent draft
// leaves the composer, by a new key on its editor; a waiting one stays until
// the lane sends it after the next capture; a refused one stays where the
// operator can edit it.
fn settled(
  model: Model(socket),
  disposition: session_channel.Disposition,
) -> Model(socket) {
  case disposition {
    session_channel.Sent(command:, ..) ->
      Model(..model, drafts: model.drafts + 1, notice: Said(command <> " sent"))
    session_channel.Waiting(_) ->
      Model(
        ..model,
        notice: Said("Waiting for the session to synchronize before sending."),
      )
    session_channel.DefinitelyNotSent(reason:) ->
      Model(..model, notice: Warned("Not sent: " <> reason))
  }
}

/// Submits an operator's text to the page's strand through the engine's
/// command arm, after handing the lane what was already filed, as the
/// terminal drains before it acts on a key.
///
/// Empty text and text over `prompt_limit` are refused with a notice
/// before they become a command. What the lane decides is folded back as
/// its disposition.
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
    "", _ -> #(
      Model(..model, notice: Warned("Nothing to send.")),
      effect.none(),
    )
    _, True -> #(
      Model(
        ..model,
        notice: Warned(
          "The draft is longer than the page sends ("
          <> int.to_string(prompt_limit)
          <> " bytes).",
        ),
      ),
      effect.none(),
    )
    _, False ->
      commanded(model, fn(lane, id, now) {
        Ok(operator.submit(lane, id, strand, text, delivery, now))
      })
  }
}

/// Answers the escalation the page drew as `id` at `seq`, through the
/// engine's command arm.
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
  let model = drained(model)
  case operator.drawn(model.approvals, id, seq) {
    Error(Nil) ->
      Model(
        ..model,
        notice: Warned(
          "That approval changed after it was drawn, so nothing was decided.",
        ),
      )
      |> flushed
    Ok(record) -> {
      let choice = case answer {
        AllowOnce -> operator.AllowOnce
        Deny -> operator.Deny
      }
      commanded(model, fn(lane, id, now) {
        operator.decide(lane, id, record, choice, now)
      })
    }
  }
}

/// Asks for the rows older than the oldest one the page holds, when the
/// lane lists them as `lane.Earlier`, and does nothing otherwise.
///
/// The page's limit rises from `live_rows` to `held_rows`, and the history
/// window asks for the interval of at most a hundred sequences below its
/// oldest record (`history_view.older`), which the lane sends as a
/// `history` read as soon as it has no other request out. That is the
/// read the terminal pages with, and a read, not a mutation: the gateway
/// admits it for an observer's attachment as for an operator's. While it
/// is out the lane draws `lane.Loading`, and a second press asks nothing.
/// The reply is folded in by `apply`.
///
/// ## Examples
///
/// ```gleam
/// // component.older(model)
/// ```
pub fn older(model: Model(socket)) -> #(Model(socket), Effect(Msg(socket))) {
  let model = drained(Model(..model, clock: model.transport.now()))
  case top(model), model.shown, model.status {
    lane.Earlier, Some(#(_, view)), Following -> {
      let branch = history_view.branch(model.scrollback, view)
      Model(
        ..model,
        scrollback: history_view.older(model.scrollback, branch.unloaded),
        paging: Paged,
      )
      |> relaned
      |> serviced
      |> flushed
    }

    // Nothing older to load, a read already out, a page at its limit, or
    // a page that is not following a session.
    lane.Beginning, _, _
    | lane.Loading, _, _
    | lane.Full(_), _, _
    | lane.Earlier, None, _
    | lane.Earlier, Some(_), Connecting
    | lane.Earlier, Some(_), Ended(_)
    -> flushed(model)
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
  case model.scrollback.request, model.earlier, model.paging {
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
  model.paging
}

// One command through the lane: drain what was filed, run the arm, fold its
// disposition, and perform everything the lane queued in the order it
// queued it.
fn commanded(
  model: Model(socket),
  arm: fn(session_channel.Channel(socket, Nil), Int, Int) ->
    Result(
      #(session_channel.Channel(socket, Nil), session_channel.Disposition),
      String,
    ),
) -> #(Model(socket), Effect(Msg(socket))) {
  // A command reads the host's clock itself. The last message's reading can
  // be a whole idle refresh old, `pushing_refresh_ms` on a pushing lane, and the
  // request's deadline and the timer armed for it are measured from here.
  let model = drained(Model(..model, clock: model.transport.now()))
  case model.lane {
    None -> #(
      Model(..model, notice: Warned("The page is not connected yet.")),
      effect.none(),
    )
    Some(lane) ->
      case arm(lane, model.next_id, model.clock) {
        Error(reason) -> flushed(Model(..model, notice: Warned(reason)))
        Ok(#(lane, disposition)) ->
          Model(..model, lane: Some(lane), next_id: model.next_id + 1)
          |> settled(disposition)
          |> flushed
      }
  }
}

// Takes and performs everything the lane queued, as `taken` does. A command
// or a read moves the lane's next due reading, so the timer is armed again
// here too.
fn flushed(model: Model(socket)) -> #(Model(socket), Effect(Msg(socket))) {
  let #(model, effects) = taken(model)
  #(rearm(model, model.clock), effects)
}

// The lane's outputs, performed through the host's transport in the order
// the lane decided them, in one effect: Lustre does not order a batch.
// The shape is the terminal's `terminal_lane.perform`.
fn perform(
  transport: Transport(socket),
  outputs: List(session_channel.Out(socket, Nil)),
) -> Effect(Msg(socket)) {
  case outputs {
    [] -> effect.none()
    [_, ..] -> {
      use _dispatch <- effect.from
      list.each(outputs, fn(output) {
        case output {
          session_channel.Transmit(socket:, frame:) ->
            transport.transmit(socket, frame)
          session_channel.Shut(socket:) -> transport.shut(socket)

          // The lane holds no trace, so it never queues a note.
          session_channel.Note(..) -> Nil
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
  let _ = option.map(model.armed, process.cancel_timer)
  let due = option.then(model.lane, session_channel.next_due)
  case model.timer, due {
    Some(timer), Some(due) ->
      Model(
        ..model,
        armed: Some(process.send_after(timer, int.max(0, due - now), Nil)),
      )
    Some(_), None | None, _ -> Model(..model, armed: None)
  }
}

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
  list.flat_map(model.blocks, fn(block) {
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
  model.pieces
}

/// The agent strip as the page draws it.
///
/// ## Examples
///
/// ```gleam
/// // strip.view(component.strip(model))
/// ```
pub fn strip(model: Model(socket)) -> strip.Strip {
  model.strip
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
  list.find(model.strip.chips, fn(chip) { chip.line.id == strand })
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
  model.status
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
  list.filter(model.approvals, fn(record) { record.status == approval.Pending })
}

/// What the page last told the operator.
///
/// ## Examples
///
/// ```gleam
/// // component.notice(model) == component.Quiet
/// ```
pub fn notice(model: Model(socket)) -> Notice {
  model.notice
}

/// How many drafts have been sent, which keys the composer's editor.
///
/// ## Examples
///
/// ```gleam
/// // component.drafts(model)
/// ```
pub fn drafts(model: Model(socket)) -> Int {
  model.drafts
}

/// The attachment the last capture was taken for: who the page acts as.
///
/// ## Examples
///
/// ```gleam
/// // component.attachment(model)
/// ```
pub fn attachment(model: Model(socket)) -> Option(snapshot.Attachment) {
  option.map(model.shown, fn(shown) { { shown.0 }.attachment })
}

/// Whether the page's strand has an operation running, as the last
/// capture says, which decides whether the composer offers one Send or a
/// Queue and a Steer.
///
/// ## Examples
///
/// ```gleam
/// // component.activity(model) == component.Idle
/// ```
pub fn activity(model: Model(socket)) -> Activity {
  let running = case model.shown {
    None -> False
    Some(#(_, view)) ->
      list.any(view.strands, fn(listed) {
        listed.id == strand && listed.live_phase != None
      })
  }
  case running {
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
  list.flat_map(model.blocks, fn(block) {
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
  model.lane
}

/// The session identity the page was opened for.
///
/// ## Examples
///
/// ```gleam
/// // component.session_id(model)
/// ```
pub fn session_id(model: Model(socket)) -> String {
  model.session_id
}

/// The observer's page: the heading, the agent strip, the lane, and a fixed
/// line saying the page is read-only. It attaches no event handler, so the
/// lane says in words when older rows exist rather than offering a button
/// to load them.
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
    strip.view(model.strip),
    lane.view(model.pieces, top(model), None),
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
    session_id: model.session_id,
    name: option.map(model.label, fn(label) { label.name }),
    workspace: option.map(model.label, fn(label) { label.workspace }),
    status: status_text(model.status),
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
