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
import lustre/element/keyed
import lustre/server_component
import session_view/agent_roster
import session_view/agent_view
import session_view/approval
import session_view/cache_miss
import session_view/cache_watch
import session_view/connection_event
import session_view/inbox.{type Inbox}
import session_view/markdown
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
import web_view/markdown_view
import web_view/view/heading
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
    /// The page strand's transcript blocks, projected once when a capture
    /// or a cache notice arrived, so a message which changed neither costs
    /// the view no projection.
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
// one. The lane's outputs are one ordered effect.
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
          let #(lane, outputs) = session_channel.take_outputs(lane)
          let model = apply(Model(..model, lane: Some(lane)), ticked)
          #(model, perform(model.transport, outputs))
        }
      }
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

      // The daemon's answer to the page's own command replaces whatever
      // the page said before, as the terminal's footer does, so the notice
      // always states the outcome of the latest command rather than an
      // earlier refusal or a "sent" the daemon has since answered. The
      // page's lane sends no read that expects a reply, so every
      // acknowledgement and every refusal it sees answers a command this
      // page issued. A refusal names its code, which the daemon chooses,
      // and not its message.
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
      session_channel.HistoryPage(..)
      | session_channel.LookedUp(..)
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

// Projects the page strand's blocks and pieces from the shown capture and
// the notices, then the strip. This is the one place a projection runs.
fn relaned(model: Model(socket)) -> Model(socket) {
  case model.shown {
    None -> restripped(model)
    Some(#(cut, view)) -> {
      let blocks = transcript.blocks(cut, view, strand, model.notices)
      let latest = turns.latest(view, model.agents, strand)
      let pieces = turns.pieces(blocks, view.strands, latest)
      Model(..model, blocks:, pieces:)
      |> restripped
    }
  }
}

// A card's body, parsed when it is first drawn and kept by its memo while
// it is unchanged, as a transcript line is (`lane_rows`).
fn card_body(body: String) -> Element(message) {
  use <- element.memo([element.ref(body)])
  html.div(
    [attribute.class("card-body"), attribute.class("markdown")],
    markdown_view.blocks(markdown.parse(body)),
  )
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

// Takes everything the lane queued and performs it, keeping the emptied
// lane, so no output is performed twice. A command moves the lane's next
// due reading, so the timer is armed again here too.
fn flushed(model: Model(socket)) -> #(Model(socket), Effect(Msg(socket))) {
  case model.lane {
    None -> #(model, effect.none())
    Some(lane) -> {
      let #(lane, outputs) = session_channel.take_outputs(lane)
      #(
        rearm(Model(..model, lane: Some(lane)), model.clock),
        perform(model.transport, outputs),
      )
    }
  }
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
/// // component.lane_view(component.pieces(model))
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
/// line saying the page is read-only. It attaches no event handler.
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
    lane_view(model.pieces),
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

/// The lane: the page strand's turns, keyed by the engine's identity for
/// each piece, with every transcript line and every card body drawn inside
/// a memo whose one dependency is that line or body. A capture draws only
/// what is new: a line equal to the one its memo drew from reuses the
/// element it drew, so its Markdown is not parsed again. The pieces, the
/// turns' folds and the blocks around the lines are rebuilt on each render,
/// which costs little. A window that drops its oldest rows removes them
/// rather than rewriting the rows after them.
///
/// The memos are the leaves, with no memo around them, and that is what
/// makes them hold. Lustre 5.7.1 keeps a render's memo elements in a table
/// it starts afresh on each render (`lustre/vdom/cache.tick`). A memo whose
/// dependencies are unchanged carries only its own element into the new
/// table (`cache.keep_memo`), not the memos nested inside that element. So
/// a render in which an enclosing memo hit would drop the entries of every
/// memo inside it, and the next render that changed the enclosing one would
/// draw and parse every line again. A turn's work is one piece that changes
/// whenever an answer moves into it, which is why the memos are per line and
/// not per piece. Every render visits each line's memo and carries each hit
/// forward, at the cost of comparing each line with the one it was drawn
/// from; Lustre compares dependencies with `==` on the BEAM.
///
/// The lane is drawn inside a `<loom-follow>` (`packages/web_client`),
/// which scrolls the page to a row that lands below the viewport while the
/// reader is at the bottom, and stops once they scroll up to read. Where
/// the reader has scrolled is the browser's to know: the server never
/// renders it, so scrolling costs no message here.
///
/// ## Examples
///
/// ```gleam
/// // component.lane_view(component.pieces(model))
/// ```
pub fn lane_view(pieces: List(turns.Piece)) -> Element(message) {
  lane_rows(pieces, line_element)
}

/// `lane_view` with the drawing of a transcript line supplied, so a test
/// can count the lines a render draws. `draw` must depend on nothing but
/// the line it is given, because the line's memo depends on the line alone.
///
/// ## Examples
///
/// ```gleam
/// // component.lane_rows(pieces, fn(line) { html.text(line.text) })
/// ```
@internal
pub fn lane_rows(
  pieces: List(turns.Piece),
  draw: fn(Line) -> Element(message),
) -> Element(message) {
  element.element("loom-follow", [attribute.class("follow")], [
    keyed.div(
      [attribute.class("transcript lane"), attribute.role("log")],
      list.map(pieces, fn(piece) {
        #(piece_key(piece), piece_element(piece, draw))
      }),
    ),
  ])
}

// One transcript line, drawn once and kept while the line is unchanged.
fn line_row(
  line: Line,
  draw: fn(Line) -> Element(message),
) -> Element(message) {
  element.memo([element.ref(line)], fn() { draw(line) })
}

fn piece_key(piece: turns.Piece) -> String {
  case piece {
    turns.Plain(block:) | turns.Commentary(block:) -> block.key
    turns.Work(key:, ..)
    | turns.Spawned(key:, ..)
    | turns.Returned(key:, ..)
    | turns.Nudged(key:, ..)
    | turns.Peer(key:, ..)
    | turns.Missed(key:, ..) -> key
  }
}

fn piece_element(
  piece: turns.Piece,
  draw: fn(Line) -> Element(message),
) -> Element(message) {
  case piece {
    turns.Plain(block:) -> block_element(block, draw)

    // A settled turn's work is a `<loom-fold>` (`packages/web_client`),
    // collapsed until the reader opens it. The fold opens and closes in the
    // browser, so it needs no handler here and works on an observer's page,
    // and the server never renders its state, so a later patch leaves the
    // reader's choice alone. Every word in it is a child the server renders
    // and escapes: the divider in the `summary` slot, the work in the
    // default one.
    turns.Work(worked:, items:, folding: turns.Folded, ..) ->
      element.element("loom-fold", [attribute.class("work")], [
        html.span(
          [
            attribute.attribute("slot", "summary"),
            attribute.class("work-divider"),
          ],
          [html.text(turns.divider(worked))],
        ),
        keyed.div([attribute.class("work-items")], work_items(items, draw)),
      ])

    // The turn still running is drawn open, with no divider to fold it.
    turns.Work(items:, folding: turns.Open, ..) ->
      keyed.div([attribute.class("work open")], work_items(items, draw))

    turns.Spawned(child:, purpose:, hue:, standing:, ..) ->
      html.div([attribute.class("spawn"), strip.hue_class(hue)], [
        html.span([attribute.class("spawn-head")], [
          html.text(
            "↳ agent_spawn · "
            <> case child {
              Some(child) -> "sub:" <> agent_roster.short_name(child)
              None -> standing_text(standing)
            },
          ),
        ]),
        html.span([attribute.class("spawn-purpose")], [html.text(purpose)]),
      ])

    turns.Returned(child:, outcome:, report:, hue:, ..) ->
      html.article([attribute.class("result-card"), strip.hue_class(hue)], [
        html.p([attribute.class("card-head")], [
          html.text(
            "from sub:"
            <> agent_roster.short_name(child)
            <> " · result · "
            <> outcome,
          ),
        ]),
        card_body(report),
      ])

    turns.Nudged(frame:, body:, ..) ->
      html.article([attribute.class("nudge")], [
        html.p([attribute.class("card-head")], [
          html.text(case frame {
            turns.Nudges -> "advisor · nudge · delivered"
            turns.Advice -> "advisor · advice · delivered"
          }),
        ]),
        card_body(body),
      ])

    // Another session's message. The daemon records that it was stored and
    // nothing about whether anyone read it, so the receipt says `stored`.
    turns.Peer(session:, strand:, text:, ..) ->
      html.article([attribute.class("peer-card")], [
        html.p([attribute.class("card-head")], [
          html.span([attribute.class("peer-from")], [
            html.text("peer · " <> session <> " · " <> strand),
          ]),
          html.span([attribute.class("receipt")], [html.text("stored")]),
        ]),
        card_body(text),
      ])

    turns.Missed(text:, ..) ->
      html.p([attribute.class("cache-miss")], [html.text(text)])

    // The advisor's own commentary, captured on its strand and not sent to
    // the primary: drawn as the transcript draws it, in the advisor's
    // colour, so it cannot pass for the primary's words.
    turns.Commentary(block:) ->
      html.div(
        [attribute.class("block"), attribute.class("commentary")],
        list.map(block.rows, fn(row) { line_row(row.1, draw) }),
      )
  }
}

// A turn's items, keyed by their blocks and calls. The window drops its
// oldest rows as new ones arrive, so a turn's first items leave while the
// rest stay; keyed, the items that stay are matched to themselves and their
// line memos hold, where unkeyed every item would be compared with its
// neighbour and every line drawn again.
fn work_items(
  items: List(turns.Item),
  draw: fn(Line) -> Element(message),
) -> List(#(String, Element(message))) {
  list.map(items, fn(item) {
    let key = case item {
      turns.Narrated(block:) -> block.key
      turns.Step(key:, ..) -> key
    }
    #(key, item_element(item, draw))
  })
}

fn item_element(
  item: turns.Item,
  draw: fn(Line) -> Element(message),
) -> Element(message) {
  case item {
    turns.Narrated(block:) -> block_element(block, draw)
    turns.Step(standing:, summary:, detail:, ..) ->
      html.div([attribute.class("step"), standing_class(standing)], [
        html.p([attribute.class("step-head")], [
          html.span([attribute.class("glyph"), attribute.aria_hidden(True)], [
            html.text(standing_glyph(standing)),
          ]),
          html.span([attribute.class("step-summary")], [html.text(summary)]),
          html.span([attribute.class("step-state")], [
            html.text(standing_text(standing)),
          ]),
        ]),
        ..list.map(detail, line_row(_, draw))
      ])
  }
}

fn standing_class(standing: turns.Standing) -> attribute.Attribute(message) {
  case standing {
    turns.Pending -> attribute.class("pending")
    turns.Done -> attribute.class("done")
    turns.Failed -> attribute.class("failed")
  }
}

fn standing_glyph(standing: turns.Standing) -> String {
  case standing {
    turns.Pending -> "●"
    turns.Done -> "✓"
    turns.Failed -> "✕"
  }
}

fn standing_text(standing: turns.Standing) -> String {
  case standing {
    turns.Pending -> "running"
    turns.Done -> "done"
    turns.Failed -> "failed"
  }
}

// A block drawn as the transcript draws it, one line per row. The blank a
// terminal places between tool groups is spacing here, so a spacer block
// never reaches the lane.
fn block_element(
  block: transcript_lines.Block,
  draw: fn(Line) -> Element(message),
) -> Element(message) {
  html.div(
    [attribute.class("block")],
    list.map(block.rows, fn(row) { line_row(row.1, draw) }),
  )
}

fn line_element(line: Line) -> Element(message) {
  case body_of(line.speaker) {
    Literal ->
      html.pre([attribute.class("line"), speaker_class(line.speaker)], [
        html.text(line.text),
      ])

    // The line is parsed here, when it is drawn. A line is drawn when it
    // first appears, and its memo keeps what it drew while it is unchanged
    // (`lane_rows`), so an answer is parsed about once. Each line is its
    // own tree, so an unclosed fence ends with its line.
    Markdown -> {
      let tree = markdown.parse(line.text)
      html.div(
        [
          attribute.class("line"),
          speaker_class(line.speaker),
          attribute.class("markdown"),
        ],
        markdown_view.blocks(tree),
      )
    }
  }
}

// How a line's text is drawn: as Markdown or as it is.
type Body {
  Markdown
  Literal
}

// The speakers whose text the terminal renders as Markdown
// (`tui/render.speaker_rows`), so both hosts agree on which rows are
// formatted. Everything else, tool output above all, stays preformatted.
fn body_of(speaker: transcript_line.Speaker) -> Body {
  case speaker {
    transcript_line.Assistant
    | transcript_line.Reasoning
    | transcript_line.ToolDetail -> Markdown
    transcript_line.System
    | transcript_line.User
    | transcript_line.ReasoningDigest
    | transcript_line.SummarizedReasoning
    | transcript_line.SummarizedAdvice
    | transcript_line.ToolCall
    | transcript_line.ToolResult
    | transcript_line.ToolPatch
    | transcript_line.ToolFailure
    | transcript_line.Failure
    | transcript_line.Spacer -> Literal
  }
}

// A class per speaker, which is the whole of a line's styling here as in the
// terminal. The stylesheet decides what each looks like.
fn speaker_class(
  speaker: transcript_line.Speaker,
) -> attribute.Attribute(message) {
  case speaker {
    transcript_line.System -> attribute.class("system")
    transcript_line.User -> attribute.class("user")
    transcript_line.Assistant -> attribute.class("assistant")
    transcript_line.Reasoning -> attribute.class("reasoning")
    transcript_line.ReasoningDigest -> attribute.class("reasoning-digest")
    transcript_line.SummarizedReasoning ->
      attribute.class("summarized-reasoning")
    transcript_line.SummarizedAdvice -> attribute.class("summarized-advice")
    transcript_line.ToolCall -> attribute.class("tool-call")
    transcript_line.ToolResult -> attribute.class("tool-result")
    transcript_line.ToolDetail -> attribute.class("tool-detail")
    transcript_line.ToolPatch -> attribute.class("tool-patch")
    transcript_line.ToolFailure -> attribute.class("tool-failure")
    transcript_line.Failure -> attribute.class("failure")
    transcript_line.Spacer -> attribute.class("spacer")
  }
}
