//// The project actor: one per active project, and the only writer of that
//// project's ledger (protocol-change/106, "Durable state").
////
//// The engine (`project/engine`) is a pure function from a state and an event
//// to a state and effects. This actor holds the state, gives the engine every
//// event, writes each accepted event and its effects to the ledger in one
//// transaction, and then performs the effects it wrote. A refusal writes
//// nothing. That ordering is the whole crash story: the event and the rows
//// that say what to do about it commit together, so a restart finds either
//// both or neither, and a row that was written and not yet settled is
//// performed again under the same key.
////
//// ## Flow
////
//// `start` → `boot` → `handle` → `commit` → `perform_due` → `perform`
////
//// 1. `start` links the actor to its caller and runs `boot` as the
////    initialiser: it opens the ledger, replays every line through the engine
////    and the host records, and performs whatever the last run left queued.
//// 2. `handle` takes one message at a time. A composer post, a router
////    decision, a worker report, a human turn and the periodic tick each
////    become engine events through `commit`.
//// 3. `commit` asks the engine first. On `Ok` it appends the event and its
////    effect rows together and only then keeps the new state.
//// 4. `perform_due` reads the rows whose time has come and runs `perform` on
////    each. A job that succeeds is settled, one that cannot yet succeed is
////    deferred with a growing delay, and one that has failed too often is
////    turned into the engine event that gives up on it.
////
//// ## Why the effects are idempotent
////
//// Creating a worker session uses the engine's request key, so a restart that
//// repeats the step finds the session the first attempt made
//// (`catalogue.by_request_key`) instead of making a second one. Delivering a
//// trigger uses an admission receipt keyed on the trigger and the target, so
//// a repeat admits nothing. Neither relies on the actor remembering anything
//// beyond the ledger.
////
//// ## Time
////
//// Every time is system time from `Ports.now_ms`. The monotonic clock is
//// meaningless after a restart and never reaches the ledger.

import broker/internal/call
import client/peer_mail
import client/project_records.{
  type Job, type Record, AnswerJob, CheckJob, DeliverJob, Engine as EngineLine,
  Host as HostLine, OfferJob, PullRequestJob, RecoverJob, StartJob, StopJob,
}
import core/json.{type JsonValue}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import project/engine
import project/event.{type Event, type Refusal}
import project/model
import project/stage
import project/state.{type State, type Ticket}
import storage/project_ledger.{type Ledger}
import telemetry/field
import telemetry/log.{type Logger}
import tools/project as tools
import weft/actor

/// What the actor needs from the daemon, as closures so it can be driven by a
/// test without one.
pub type Ports {
  Ports(
    /// The system clock in Unix milliseconds.
    now_ms: fn() -> Int,
    /// Creates or recovers the worker session for a request and returns its
    /// id. The same key always answers the same session.
    start_session: fn(StartRequest) -> Result(String, String),
    /// Opens a saved session of this project.
    open_session: fn(String) -> Result(Nil, String),
    /// Stops a resident session, leaving it saved.
    stop_session: fn(String) -> Result(Nil, String),
    /// Removes the worktree of an assignment whose ticket has ended, or keeps
    /// it because it holds commits its base lacks.
    release_worktree: fn(ReleaseRequest) -> Result(Released, String),
    /// The endpoint of a resident session, or why it has none.
    endpoint_of: fn(String) -> Result(peer_mail.Endpoint, peer_mail.Failure),
    /// Where the actor reports.
    logger: Logger,
  )
}

/// A request to create a worker session.
pub type StartRequest {
  StartRequest(
    /// The engine's request key.
    key: String,
    /// The ticket.
    ticket: String,
    /// The assignment.
    seq: Int,
    /// The ticket's capped title, for the session's name.
    title: String,
  )
}

/// Which worktree to release.
pub type ReleaseRequest {
  ReleaseRequest(
    /// The ticket.
    ticket: String,
    /// The assignment.
    seq: Int,
  )
}

/// What releasing a worktree came to.
pub type Released {
  /// The worktree is gone. Its branch remains.
  Removed

  /// The worktree stays, because it holds work that nothing records as pushed.
  Kept(
    /// Where it is, so a person can find it.
    path: String,
    /// Why it was kept.
    reason: String,
  )
}

/// A project's fixed settings.
pub type Config {
  Config(
    /// The project's id.
    project: String,
    /// The workspace the project is bound to.
    workspace: String,
    /// The router's registered session.
    router_session: String,
    /// The ledger file.
    ledger_path: String,
    /// General worker slots.
    max_workers: Int,
    /// Milliseconds between ticks.
    tick_ms: Int,
    /// Milliseconds a batch may stay with the router before its unrouted
    /// candidates go back to the queue.
    router_turn_ms: Int,
    /// Builds the daemon's side. It runs in the actor's own process, so what
    /// it starts is linked to the actor and ends with it.
    ports: fn() -> Ports,
  )
}

/// How a caller reaches the actor.
pub type Handle {
  Handle(
    /// The project's id.
    project: String,
    /// The router's session id.
    router_session: String,
    /// The workspace the project is bound to.
    workspace: String,
    /// The actor's mailbox.
    commands: Subject(Message),
  )
}

/// What `post` answered.
pub type Posted {
  /// The trigger was recorded and the engine took it.
  Posted(
    /// The trigger's id.
    trigger: String,
  )

  /// This request id was posted before, and nothing changed.
  Repeated(
    /// The trigger's id.
    trigger: String,
  )
}

/// A page of the board.
pub type Board {
  Board(
    /// The ledger's newest sequence number, which changes whenever anything
    /// on the board might have.
    revision: Int,
    /// The zero-based page.
    page: Int,
    /// All tickets.
    total: Int,
    /// The tickets on this page, needs-a-person first.
    tickets: List(JsonValue),
    /// The router's queued replies, shown on the first page.
    replies: List(JsonValue),
  )
}

/// The requests the actor serves.
pub opaque type Message {
  Post(request: String, text: String, reply: Subject(Result(Posted, String)))
  RouteItems(items: List(tools.Item), reply: Subject(List(tools.ItemOutcome)))
  ReadResource(
    resource: tools.Resource,
    reply: Subject(Result(JsonValue, tools.Refusal)),
  )
  QueueReply(queued: tools.Reply, reply: Subject(Result(Nil, tools.Refusal)))
  WorkerReported(
    session: String,
    report: tools.WorkerReport,
    reply: Subject(Result(Nil, tools.Refusal)),
  )
  WorkerHandedBack(
    session: String,
    handback: tools.Handback,
    reply: Subject(Result(Nil, tools.Refusal)),
  )
  ReadBoard(page: Int, reply: Subject(Board))
  ReadCounts(reply: Subject(List(#(String, Int))))
  ReadLive(reply: Subject(List(String)))
  StopTicket(ticket: String, by: String, reply: Subject(Result(Nil, String)))
  ReadTicket(ticket: String, reply: Subject(Result(JsonValue, Nil)))
  AnswerQuestion(
    ticket: String,
    seq: Int,
    text: String,
    by: String,
    reply: Subject(Result(Nil, AnswerFailure)),
  )
  RetryTicket(ticket: String, by: String, reply: Subject(Result(Nil, String)))
  RequeueTrigger(
    trigger: String,
    by: String,
    reply: Subject(Result(Nil, String)),
  )
  HumanTurn(session: String, entry: String, actor: String, text: String)
  ReplayReport(session: String, report: tools.WorkerReport)
  ReadScanCursor(
    session: String,
    reply: Subject(Result(Option(String), String)),
  )
  ScanCheckpoint(session: String, entry: String)
  Tick
}

type Host {
  Host(
    config: Config,
    ports: Ports,
    ledger: Ledger,
    engine: State,
    last_seq: Int,
    texts: Dict(String, Trigger),
    questions: Dict(#(String, Int), String),
    replies: List(#(String, String, String)),
    offered_at_ms: Int,
    recovered: Set(#(String, Int)),
    kept_trees: Dict(String, List(KeptTree)),
  )
}

// A worktree that outlived its ticket, with where it is and why it stayed.
type KeptTree {
  KeptTree(seq: Int, path: String, reason: String)
}

// The text and attribution of one stored trigger.
type Trigger {
  Trigger(source: String, actor: String, body: String)
}

// The strand a session's own conversation runs on.
const main_strand = "main"

const page_size = 20

/// Starts the actor for a project, linked to the caller.
///
/// The initialiser replays the ledger before this returns, so a caller that
/// holds a `Handle` talks to an actor whose state is already rebuilt. A ledger
/// the engine refuses on replay stops the start with the position and the
/// reason, because acting on a state that never formed would be worse than not
/// running.
///
/// ## Examples
///
/// ```gleam
/// // project_host.start(config)
/// ```
pub fn start(config: Config) -> Result(Handle, String) {
  actor.new_with_initialiser(10_000, fn(inbox) {
    use host <- result.try(boot(config))
    actor.initialised(host) |> actor.returning(inbox) |> Ok
  })
  |> actor.on_message(handle)
  |> actor.periodic(every: config.tick_ms, sending: Tick)
  |> actor.start
  |> result.map(fn(started) {
    Handle(
      project: config.project,
      router_session: config.router_session,
      workspace: config.workspace,
      commands: started.data,
    )
  })
  |> result.map_error(fn(error) {
    "the project actor did not start: " <> string.inspect(error)
  })
}

// --- calls -------------------------------------------------------------------

/// Posts the owner's text as an explicit trigger. The request id names the
/// trigger, so posting it again changes nothing.
///
/// ## Examples
///
/// ```gleam
/// // project_host.post(handle, "req-1", "fix the flaky test")
/// ```
pub fn post(
  handle: Handle,
  request: String,
  text: String,
) -> Result(Posted, String) {
  ask(handle, Post(request, text, _))
  |> result.flatten
}

/// Applies the router's routing items and answers each one's outcome.
///
/// ## Examples
///
/// ```gleam
/// // project_host.route(handle, items)
/// ```
pub fn route(
  handle: Handle,
  items: List(tools.Item),
) -> Result(List(tools.ItemOutcome), tools.Refusal) {
  ask(handle, RouteItems(items, _))
  |> result.map_error(tools.Unavailable)
}

/// Serves one resource of `project_read`.
///
/// ## Examples
///
/// ```gleam
/// // project_host.read(handle, tools.Candidates)
/// ```
pub fn read(
  handle: Handle,
  resource: tools.Resource,
) -> Result(JsonValue, tools.Refusal) {
  ask(handle, ReadResource(resource, _))
  |> result.map_error(tools.Unavailable)
  |> result.flatten
}

/// Records a reply the router queued.
///
/// ## Examples
///
/// ```gleam
/// // project_host.queue_reply(handle, reply)
/// ```
pub fn queue_reply(
  handle: Handle,
  queued: tools.Reply,
) -> Result(Nil, tools.Refusal) {
  ask(handle, QueueReply(queued, _))
  |> result.map_error(tools.Unavailable)
  |> result.flatten
}

/// Records a worker session's status report.
///
/// ## Examples
///
/// ```gleam
/// // project_host.report(handle, session_id, report)
/// ```
pub fn report(
  handle: Handle,
  session: String,
  report: tools.WorkerReport,
) -> Result(Nil, tools.Refusal) {
  ask(handle, WorkerReported(session, report, _))
  |> result.map_error(tools.Unavailable)
  |> result.flatten
}

/// Records a worker session's hand-back.
///
/// ## Examples
///
/// ```gleam
/// // project_host.hand_back(handle, session_id, handback)
/// ```
pub fn hand_back(
  handle: Handle,
  session: String,
  handback: tools.Handback,
) -> Result(Nil, tools.Refusal) {
  ask(handle, WorkerHandedBack(session, handback, _))
  |> result.map_error(tools.Unavailable)
  |> result.flatten
}

/// One page of the board.
///
/// ## Examples
///
/// ```gleam
/// // project_host.board(handle, 0)
/// ```
pub fn board(handle: Handle, page: Int) -> Result(Board, String) {
  ask(handle, ReadBoard(page, _))
}

/// The number of tickets at each stage, in stage order.
///
/// ## Examples
///
/// ```gleam
/// // project_host.counts(handle)
/// ```
pub fn counts(handle: Handle) -> Result(List(#(String, Int)), String) {
  ask(handle, ReadCounts)
}

/// The sessions of the assignments that are still live, oldest ticket first,
/// for the boot step that reopens them.
///
/// ## Examples
///
/// ```gleam
/// // project_host.live_sessions(handle)
/// ```
pub fn live_sessions(handle: Handle) -> Result(List(String), String) {
  ask(handle, ReadLive)
}

/// A person's stop of one ticket.
///
/// ## Examples
///
/// ```gleam
/// // project_host.stop_ticket(handle, "t-c1", "owner")
/// ```
pub fn stop_ticket(
  handle: Handle,
  ticket: String,
  by: String,
) -> Result(Nil, String) {
  ask(handle, StopTicket(ticket, by, _))
  |> result.flatten
}

/// Hands the actor a person's turn typed into a worker. It is a cast: the
/// scanner that reads the worker's log does not wait on the ledger, and the
/// entry id keeps a repeat from recording a second turn.
///
/// ## Examples
///
/// ```gleam
/// // project_host.human_turn(handle, session_id, entry_id, "owner", "use sqlite")
/// ```
pub fn human_turn(
  handle: Handle,
  session: String,
  entry: String,
  actor: String,
  text: String,
) -> Nil {
  process.send(handle.commands, HumanTurn(session, entry, actor, text))
}

/// Hands the actor a report that a worker's commit stream shows was made. The
/// scanner sends the last committed `project_report` result above its cursor,
/// in case the call that carried it never reached the ledger. The actor skips
/// a report that matches what the ticket already holds, so a report applied
/// live and then seen again by the scanner changes nothing.
///
/// ## Examples
///
/// ```gleam
/// // project_host.replay_report(handle, session_id, report)
/// ```
pub fn replay_report(
  handle: Handle,
  session: String,
  report: tools.WorkerReport,
) -> Nil {
  process.send(handle.commands, ReplayReport(session, report))
}

/// The id of the last entry of a worker's log that the scanner has taken in,
/// or `None` for a session not scanned yet.
///
/// ## Examples
///
/// ```gleam
/// // project_host.scan_cursor(handle, session_id)
/// ```
pub fn scan_cursor(
  handle: Handle,
  session: String,
) -> Result(Option(String), String) {
  ask(handle, ReadScanCursor(session, _))
  |> result.flatten
}

/// Moves a worker's scan cursor to an entry. It is a cast, sent after the
/// turns and reports the scan found, so the actor takes the cursor in only
/// after it has taken those in. The cursor is a checkpoint and not a record: a
/// restart that resumes behind it repeats entries that the entry-keyed
/// triggers and the report comparison already make harmless.
///
/// ## Examples
///
/// ```gleam
/// // project_host.checkpoint_scan(handle, session_id, entry_id)
/// ```
pub fn checkpoint_scan(handle: Handle, session: String, entry: String) -> Nil {
  process.send(handle.commands, ScanCheckpoint(session, entry))
}

fn ask(handle: Handle, make: fn(Subject(a)) -> Message) -> Result(a, String) {
  call.try_call(handle.commands, waiting: 10_000, sending: make)
  |> result.replace_error("the project is not answering")
}

// --- boot --------------------------------------------------------------------

/// Opens the ledger, rebuilds the state from it and performs what is queued.
fn boot(config: Config) -> Result(Host, String) {
  use ledger <- result.try(
    project_ledger.open(config.ledger_path)
    |> result.map_error(fn(error) {
      "the project ledger did not open: " <> string.inspect(error)
    }),
  )
  let fresh =
    Host(
      config:,
      ports: config.ports(),
      ledger:,
      engine: state.start(state.Config(
        project: model.ProjectId(config.project),
        workspace: config.workspace,
        max_workers: config.max_workers,
        queue_limit: 100,
        attention_limit: 5,
        policy_version: "v1",
      )),
      last_seq: 0,
      texts: dict.new(),
      questions: dict.new(),
      replies: [],
      offered_at_ms: 0,
      recovered: set.new(),
      kept_trees: dict.new(),
    )
  use replayed <- result.try(replay(fresh, 0))
  Ok(perform_due(recover_interrupted(replayed)))
}

/// Replays a page at a time, because the ledger returns at most a page, and the
/// engine judges each line against the state the earlier lines built.
fn replay(host: Host, after: Int) -> Result(Host, String) {
  use page <- result.try(
    project_ledger.replay(host.ledger, after, project_ledger.replay_page_limit)
    |> result.map_error(fn(error) {
      "the project ledger did not replay: " <> string.inspect(error)
    }),
  )

  // An empty page means the ledger is exhausted. Otherwise the next page
  // starts after this page's last sequence number.
  case list.last(page) {
    Error(Nil) -> Ok(host)
    Ok(last) -> {
      use next <- result.try(list.try_fold(page, host, replay_line))
      replay(Host(..next, last_seq: last.seq), last.seq)
    }
  }
}

/// Applies one stored line. A host record only updates the host's own tables.
/// An engine event must be accepted by the engine against the state built so
/// far, and a refusal means the ledger was not written by this engine, so the
/// replay stops there and names the line.
fn replay_line(
  host: Host,
  stored: project_ledger.StoredEvent,
) -> Result(Host, String) {
  case project_records.decode_line(stored.event_json) {
    Error(reason) ->
      Error("ledger line " <> int.to_string(stored.seq) <> ": " <> reason)
    Ok(HostLine(record)) -> Ok(keep_record(host, record))
    Ok(EngineLine(incoming)) ->
      case engine.apply(host.engine, incoming) {
        Ok(#(next, _)) -> Ok(Host(..host, engine: next))
        Error(refusal) ->
          Error(
            "ledger line "
            <> int.to_string(stored.seq)
            <> " is refused by the engine: "
            <> refusal_text(refusal),
          )
      }
  }
}

// --- messages ----------------------------------------------------------------

/// Takes one message and answers its sender, if it has a reply subject, before
/// performing the effects the message made due, so a caller never waits on a
/// slow session start.
fn handle(host: Host, message: Message) -> actor.Next(Host, Message) {
  // Writes that commit engine events end in `perform_due`. Reads, a queued
  // reply and a hand-back leave nothing due and skip it.
  case message {
    Post(request, text, reply) -> {
      let #(next, answer) = post_now(host, request, text)
      process.send(reply, answer)
      actor.continue(perform_due(next))
    }
    RouteItems(items, reply) -> {
      let #(next, outcomes) = route_now(host, items)
      process.send(reply, outcomes)
      actor.continue(perform_due(next))
    }
    ReadResource(resource, reply) -> {
      process.send(reply, serve_resource(host, resource))
      actor.continue(host)
    }
    QueueReply(queued, reply) -> {
      let #(next, answer) = reply_now(host, queued)
      process.send(reply, answer)
      actor.continue(next)
    }
    WorkerReported(session, report, reply) -> {
      let #(next, answer) = report_now(host, session, report)
      process.send(reply, answer)
      actor.continue(perform_due(next))
    }
    WorkerHandedBack(session, handback, reply) -> {
      let #(next, answer) = hand_back_now(host, session, handback)
      process.send(reply, answer)
      actor.continue(next)
    }
    ReadBoard(page, reply) -> {
      process.send(reply, board_page(host, page))
      actor.continue(host)
    }
    ReadCounts(reply) -> {
      process.send(reply, stage_counts(host))
      actor.continue(host)
    }
    ReadLive(reply) -> {
      process.send(reply, live_now(host))
      actor.continue(host)
    }
    StopTicket(ticket, by, reply) -> {
      let #(next, answer) = stop_now(host, ticket, by)
      process.send(reply, answer)
      actor.continue(perform_due(next))
    }
    ReadTicket(ticket, reply) -> {
      process.send(reply, ticket_detail(host, ticket))
      actor.continue(host)
    }
    AnswerQuestion(ticket, seq, text, by, reply) -> {
      let #(next, answer) = answer_now(host, ticket, seq, text, by)
      process.send(reply, answer)
      actor.continue(perform_due(next))
    }
    RetryTicket(ticket, by, reply) -> {
      let #(next, answer) = retry_now(host, ticket, by)
      process.send(reply, answer)
      actor.continue(perform_due(next))
    }
    RequeueTrigger(trigger, by, reply) -> {
      let #(next, answer) = requeue_now(host, trigger, by)
      process.send(reply, answer)
      actor.continue(perform_due(next))
    }
    HumanTurn(session, entry, actor_name, text) ->
      actor.continue(
        perform_due(human_now(host, session, entry, actor_name, text)),
      )
    ReplayReport(session, report) ->
      actor.continue(perform_due(replay_now(host, session, report)))
    ReadScanCursor(session, reply) -> {
      process.send(
        reply,
        project_ledger.cursor(host.ledger, session)
          |> result.map_error(string.inspect),
      )
      actor.continue(host)
    }
    ScanCheckpoint(session, entry) -> {
      checkpoint_now(host, session, entry)
      actor.continue(host)
    }
    Tick -> actor.continue(tick(host))
  }
}

/// A tick performs what is due and ends a router turn that has gone on too
/// long. The engine returns unrouted candidates to the queue on
/// `RouterTurnEnded`, and a router that left some unrouted would otherwise keep
/// the project from ever offering another batch.
fn tick(host: Host) -> Host {
  let now = host.ports.now_ms()
  let stale =
    host.engine.router == state.RouterBusy
    && host.offered_at_ms > 0
    && now - host.offered_at_ms > host.config.router_turn_ms

  // Ending the turn is how the engine returns the unrouted candidates to the
  // queue. A refusal, because the turn already ended, leaves the host as it is.
  let relieved = case stale {
    True -> committed_or_same(host, event.RouterTurnEnded)
    False -> host
  }

  perform_due(relieved)
}

fn committed_or_same(host: Host, incoming: Event) -> Host {
  case commit(host, incoming) {
    Ok(next) -> next
    Error(_) -> host
  }
}

// --- commit ------------------------------------------------------------------

/// Why an event did not become part of the history.
type NotCommitted {
  Refused(Refusal)
  WriteFailed(String)
}

/// The engine judges first. Only an accepted event is appended, with the rows
/// for its effects in the same transaction, and the new state is kept only when
/// the append succeeded. A write that fails leaves the old state, so memory
/// never runs ahead of the ledger.
fn commit(host: Host, incoming: Event) -> Result(Host, NotCommitted) {
  use #(next, effects) <- result.try(
    engine.apply(host.engine, incoming) |> result.map_error(Refused),
  )
  let now = host.ports.now_ms()
  let drafts = project_records.drafts(host.last_seq + 1, now, effects)
  use seq <- result.map(
    project_ledger.append_with_effects(
      host.ledger,
      project_records.encode_event(incoming),
      now,
      drafts,
    )
    |> result.map_error(fn(error) { WriteFailed(string.inspect(error)) }),
  )
  Host(..host, engine: next, last_seq: seq)
}

fn not_committed_text(failure: NotCommitted) -> String {
  case failure {
    Refused(refusal) -> refusal_text(refusal)
    WriteFailed(reason) -> "the ledger did not take it: " <> reason
  }
}

/// Records a host record in the ledger and in memory.
fn record(host: Host, written: Record) -> Result(Host, String) {
  use seq <- result.map(
    project_ledger.append(
      host.ledger,
      project_records.encode_record(written),
      host.ports.now_ms(),
    )
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  Host(..keep_record(host, written), last_seq: seq)
}

/// Folds one host record into the in-memory tables. Writing a record and
/// replaying it both come through here, so the tables after a restart match
/// the tables before it.
fn keep_record(host: Host, written: Record) -> Host {
  case written {
    project_records.TriggerText(trigger:, source:, actor:, body:) ->
      Host(
        ..host,
        texts: dict.insert(host.texts, trigger, Trigger(source:, actor:, body:)),
      )
    project_records.QuestionText(ticket:, question:, body:) ->
      Host(
        ..host,
        questions: dict.insert(host.questions, #(ticket, question), body),
      )
    project_records.ReplyQueued(subject:, purpose:, body:) ->
      Host(..host, replies: [#(subject, purpose, body), ..host.replies])
    project_records.HandedBack(..) -> host
    project_records.Recovered(ticket:, seq:) ->
      Host(..host, recovered: set.insert(host.recovered, #(ticket, seq)))
    project_records.TreeKept(ticket:, seq:, path:, reason:) ->
      Host(
        ..host,
        kept_trees: dict.upsert(host.kept_trees, ticket, fn(found) {
          [KeptTree(seq:, path:, reason:), ..option.unwrap(found, [])]
        }),
      )
  }
}

// --- composer ----------------------------------------------------------------

/// Records an owner's post. A request id that was posted before answers
/// `Repeated` and writes nothing, so a client may retry a post whose reply it
/// never saw.
fn post_now(
  host: Host,
  request: String,
  text: String,
) -> #(Host, Result(Posted, String)) {
  let id = model.TriggerId(request)

  // An invalid id is refused before anything is written. A known id is a
  // repeat. Anything else becomes an explicit trigger from the composer.
  case valid_request(request), dict.has_key(host.engine.triggers, id) {
    False, _ -> #(
      host,
      Error("the request id must be 1 to 64 plain characters"),
    )
    True, True -> #(host, Ok(Repeated(request)))
    True, False -> {
      let now = host.ports.now_ms()
      let arrived =
        model.Trigger(
          id:,
          source: model.SourceId("composer"),
          thread: model.ThreadId(request),
          actor: model.ActorId("owner"),
          inputs: model.Inputs(
            sender: model.Owner,
            addressing: model.Addressed,
            rule: None,
          ),
          generation: 0,
          at_ms: now,
        )

      // The text is written first: an orphaned text row is harmless, and a
      // trigger without its text would reach the router with nothing to read.
      let outcome = {
        use texted <- result.try(record(
          host,
          project_records.TriggerText(request, "composer", "owner", text),
        ))
        commit(texted, event.TriggerArrived(arrived, model.ActorId("loom")))
        |> result.map_error(not_committed_text)
      }

      // A failure returns the old host, so memory shows neither the text nor
      // the trigger. A text row that did reach the disk is harmless.
      case outcome {
        Ok(next) -> #(next, Ok(Posted(request)))
        Error(reason) -> #(host, Error(reason))
      }
    }
  }
}

/// A request id is 1 to 64 letters, digits, underscore, hyphen or dot. The
/// alphabet leaves out the colon, so the id can join a session id in a message
/// id and be split apart again without ambiguity.
fn valid_request(request: String) -> Bool {
  let size = string.length(request)
  size >= 1
  && size <= 64
  && list.all(string.to_graphemes(request), fn(each) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.",
      each,
    )
  })
}

// --- the router's decisions --------------------------------------------------

/// Applies the routing items in order, each as its own engine event, so one
/// refused item does not undo the others. The outcomes come back in item order.
fn route_now(
  host: Host,
  items: List(tools.Item),
) -> #(Host, List(tools.ItemOutcome)) {
  let #(after, outcomes) =
    list.fold(items, #(host, []), fn(acc, item) {
      let #(so_far, done) = acc

      // An accepted item advances the host. A refused one leaves it as it was
      // and reports the reason to the router.
      case commit(so_far, routed_event(item)) {
        Ok(next) -> #(next, [tools.Applied, ..done])
        Error(failure) -> #(so_far, [
          tools.Declined(not_committed_text(failure)),
          ..done
        ])
      }
    })

  // A batch with nothing left offered ends the router's turn at once, so the
  // next batch need not wait for the deadline.
  let settled = case after.engine.offered {
    [] ->
      case after.engine.router {
        state.RouterBusy -> committed_or_same(after, event.RouterTurnEnded)
        state.RouterIdle -> after
      }
    [_, ..] -> after
  }

  #(settled, list.reverse(outcomes))
}

/// The engine event one routing item asks for. Every field is an id or a kind,
/// and the only text is the capped title of an accept.
fn routed_event(item: tools.Item) -> Event {
  case item.action {
    tools.Accept(title:) -> event.Routed(routing(item, model.Accept(title)))
    tools.Attach(ticket:) -> event.Routed(routing(item, model.Attach(ticket)))
    tools.Resume(ticket:) -> event.Routed(routing(item, model.Resume(ticket)))
    tools.Stop(ticket:) -> event.RoutedStop(item.trigger, ticket)
    tools.Ignore -> event.RoutedIgnore(item.trigger)
  }
}

/// The engine's `Routing` for an accept, attach or resume. The type has no
/// place for text the router could address to a worker.
fn routing(item: tools.Item, kind: model.RouteKind) -> model.Routing {
  model.Routing(
    trigger: item.trigger,
    kind:,
    holds: item.holds,
    related: item.related,
    prior_hand_back: item.prior_hand_back,
  )
}

// --- replies, reports, hand-backs --------------------------------------------

/// Writes a router reply as a host record plus an outbox row in one
/// transaction. The subject must be a trigger the engine knows, so the router
/// cannot address a message that is not in this project.
fn reply_now(
  host: Host,
  queued: tools.Reply,
) -> #(Host, Result(Nil, tools.Refusal)) {
  // An unknown subject is refused before anything is written.
  case dict.has_key(host.engine.triggers, queued.subject) {
    False -> #(
      host,
      Error(tools.NotFound(
        "there is no message " <> queued.subject.value <> " to answer",
      )),
    )
    True -> {
      // The purpose is stored as its wire word.
      let purpose = case queued.purpose {
        tools.Acknowledge -> "acknowledge"
        tools.Clarify -> "clarify"
        tools.Decline -> "decline"
      }

      let written =
        project_records.ReplyQueued(queued.subject.value, purpose, queued.text)
      let key = queued.subject.value <> ":" <> int.to_string(host.last_seq + 1)
      let draft =
        project_ledger.EffectDraft(
          kind: "reply",
          key:,
          payload_json: project_records.encode_record(written),
          due_ms: project_records.never_ms,
        )

      // The row is the outbox entry; delivery to the source is a later slice,
      // so its time is one no scan reaches.
      case
        project_ledger.append_with_effects(
          host.ledger,
          project_records.encode_record(written),
          host.ports.now_ms(),
          [draft],
        )
      {
        Ok(seq) -> #(Host(..keep_record(host, written), last_seq: seq), Ok(Nil))
        Error(error) -> #(host, Error(tools.Unavailable(string.inspect(error))))
      }
    }
  }
}

/// The ticket and assignment a worker session serves, if the engine has bound
/// that session to a live assignment.
fn assignment_of(host: Host, session: String) -> Result(#(Ticket, Int), Nil) {
  state.tickets_oldest_first(host.engine)
  |> list.find_map(fn(ticket) {
    list.find_map(ticket.assignments, fn(assignment) {
      case assignment.session {
        Some(model.SessionId(bound)) if bound == session ->
          Ok(#(ticket, assignment.seq))
        Some(_) | None -> Error(Nil)
      }
    })
  })
}

/// Applies a worker's report to the ticket its session is bound to. The
/// session id comes from the calling session and not from the report, so a
/// worker can only report on its own assignment.
fn report_now(
  host: Host,
  session: String,
  report: tools.WorkerReport,
) -> #(Host, Result(Nil, tools.Refusal)) {
  // Only a session the engine has bound to an assignment may report.
  case assignment_of(host, session) {
    Error(Nil) -> #(
      host,
      Error(tools.NotPermitted(
        "this session is not bound to an assignment of the project",
      )),
    )
    Ok(#(ticket, seq)) -> {
      let outcome = {
        // A question gets its sequence number from the ledger position the
        // report will take, which is unique and rises, and its text is
        // written first.
        use #(texted, asked) <- result.try(question_of(
          host,
          ticket.id.value,
          report,
        ))

        // The tool's status words map one to one onto the engine's. Only a
        // waiting report carries the number of the question it asked.
        let engine_report = case report.status {
          tools.Progress -> model.Progress
          tools.Waiting -> model.Waiting(asked)
          tools.Blocked -> model.Blocked
          tools.Failed -> model.Failed
          tools.Dropped -> model.Dropped
        }

        commit(
          texted,
          event.Reported(ticket.id, seq, engine_report, model.NoHead),
        )
        |> result.map_error(not_committed_text)
      }

      // A refusal returns the old host, which also drops the question text
      // written ahead of the commit from memory.
      case outcome {
        Ok(next) -> #(next, Ok(Nil))
        Error(reason) -> #(host, Error(tools.NotPermitted(reason)))
      }
    }
  }
}

/// Writes a question's text ahead of the report and returns its number. The
/// number is the ledger position the report event will take, one past the text
/// row's own, so it is unique and rises.
fn question_of(
  host: Host,
  ticket: String,
  report: tools.WorkerReport,
) -> Result(#(Host, model.Question), String) {
  // A report with no question needs no text row.
  case report.question {
    None -> Ok(#(host, model.NoQuestion))
    Some(text) -> {
      let number = host.last_seq + 2
      use texted <- result.map(record(
        host,
        project_records.QuestionText(ticket, number, text),
      ))
      #(texted, model.Asking(number))
    }
  }
}

/// Records a worker's hand-back as a host record. It changes no engine state,
/// so it commits no event and queues no effect.
fn hand_back_now(
  host: Host,
  session: String,
  handback: tools.Handback,
) -> #(Host, Result(Nil, tools.Refusal)) {
  case assignment_of(host, session) {
    Error(Nil) -> #(
      host,
      Error(tools.NotPermitted(
        "this session is not bound to an assignment of the project",
      )),
    )
    Ok(#(ticket, _)) ->
      case
        record(
          host,
          project_records.HandedBack(
            ticket.id.value,
            handback.trigger.value,
            handback.reason,
          ),
        )
      {
        Ok(next) -> #(next, Ok(Nil))
        Error(reason) -> #(host, Error(tools.Unavailable(reason)))
      }
  }
}

/// Forwards a person's stop to the engine, which decides what it means. A
/// refusal comes back as text for the caller.
fn stop_now(
  host: Host,
  ticket: String,
  by: String,
) -> #(Host, Result(Nil, String)) {
  case
    commit(
      host,
      event.PersonStopped(model.TicketId(ticket), model.PrincipalId(by)),
    )
  {
    Ok(next) -> #(next, Ok(Nil))
    Error(failure) -> #(host, Error(not_committed_text(failure)))
  }
}

/// A person's turn typed into a worker becomes an explicit trigger on the
/// ticket's own thread, keyed by the entry that carried it. The key is what
/// makes a scanner that reads the same entry twice record one turn.
fn human_now(
  host: Host,
  session: String,
  entry: String,
  actor_name: String,
  text: String,
) -> Host {
  let id = model.TriggerId("h-" <> entry)
  let located = assignment_of(host, session)

  // A turn typed into a session the engine has not bound is ignored, and so
  // is an entry whose trigger already exists, which is the scanner repeating
  // itself.
  case located, dict.has_key(host.engine.triggers, id) {
    Error(Nil), _ | _, True -> host
    Ok(#(ticket, _)), False -> {
      // The turn joins the thread of the ticket's origin trigger, so it reads
      // as a follow-up on the same conversation.
      let thread = case dict.get(host.engine.triggers, ticket.origin) {
        Ok(origin) -> origin.trigger.thread
        Error(Nil) -> model.ThreadId(ticket.origin.value)
      }

      let arrived =
        model.Trigger(
          id:,
          source: model.SourceId("composer"),
          thread:,
          actor: model.ActorId(actor_name),
          inputs: model.Inputs(
            sender: model.Owner,
            addressing: model.Addressed,
            rule: None,
          ),
          generation: 0,
          at_ms: host.ports.now_ms(),
        )
      let outcome = {
        use texted <- result.try(record(
          host,
          project_records.TriggerText(id.value, "composer", actor_name, text),
        ))
        commit(texted, event.TriggerArrived(arrived, model.ActorId("loom")))
        |> result.map_error(not_committed_text)
      }

      // A turn that could not be written is logged, and the host stays as it
      // was.
      case outcome {
        Ok(next) -> next
        Error(reason) -> {
          log.warn(host.ports.logger, "project.human_turn_refused", [
            field.ident(key: "session", value: session),
            field.text(key: "reason", value: reason),
          ])
          host
        }
      }
    }
  }
}

/// Applies a report the scanner found in a worker's log. A report that matches
/// the one the ticket already holds is dropped, so the scanner seeing a report
/// that the live call already applied changes nothing. Without that check, a
/// replayed question would be asked a second time, with a new number, after a
/// person had answered the first.
fn replay_now(host: Host, session: String, report: tools.WorkerReport) -> Host {
  // A session the engine has not bound has no assignment to report on.
  case assignment_of(host, session) {
    Error(Nil) -> host
    Ok(#(ticket, _)) ->
      case already_holds(host, ticket, report) {
        True -> host
        False -> report_now(host, session, report).0
      }
  }
}

/// Whether the ticket's latest report is this one. A waiting report matches by
/// its question text, since the question's number is the ledger position the
/// live report took and the replay cannot know it.
fn already_holds(
  host: Host,
  ticket: Ticket,
  report: tools.WorkerReport,
) -> Bool {
  case ticket.latest {
    None -> False
    Some(latest) ->
      report_word(latest) == status_word(report.status)
      && asks_the_same(host, ticket, latest, report)
  }
}

/// The status word of an engine report, in the tool's spelling.
fn report_word(report: model.Report) -> String {
  case report {
    model.Progress -> "progress"
    model.Waiting(..) -> "waiting"
    model.Blocked -> "blocked"
    model.Failed -> "failed"
    model.Dropped -> "dropped"
  }
}

/// The status word of a tool report.
fn status_word(status: tools.Status) -> String {
  case status {
    tools.Progress -> "progress"
    tools.Waiting -> "waiting"
    tools.Blocked -> "blocked"
    tools.Failed -> "failed"
    tools.Dropped -> "dropped"
  }
}

/// For two waiting reports, whether they asked the same thing. Every other
/// status carries no question, so two reports of one such status are the same.
fn asks_the_same(
  host: Host,
  ticket: Ticket,
  latest: model.Report,
  report: tools.WorkerReport,
) -> Bool {
  case latest {
    model.Waiting(model.NoQuestion) -> report.question == None
    model.Waiting(model.Asking(number)) ->
      Ok(option.unwrap(report.question, ""))
      == dict.get(host.questions, #(ticket.id.value, number))
    model.Progress | model.Blocked | model.Failed | model.Dropped -> True
  }
}

/// Moves the cursor in the ledger. A write that fails is logged and dropped,
/// because the cursor is a checkpoint and the next one replaces it.
fn checkpoint_now(host: Host, session: String, entry: String) -> Nil {
  case project_ledger.set_cursor(host.ledger, session, entry) {
    Ok(Nil) -> Nil
    Error(error) ->
      log.warn(host.ports.logger, "project.scan_checkpoint_failed", [
        field.ident(key: "session", value: session),
        field.text(key: "reason", value: string.inspect(error)),
      ])
  }
}

// --- performing --------------------------------------------------------------

// Reads the rows whose time has come and performs each, a few rounds at most:
// a performed job can commit events whose effects are due at once, and the
// bound keeps one message from running unboundedly.
fn perform_due(host: Host) -> Host {
  perform_rounds(host, 8)
}

/// Runs due effects in rounds. A performed job can commit an event whose
/// effects are due at once, such as a start that lets a queued delivery go
/// out, so another round follows until nothing is due or the rounds run out.
fn perform_rounds(host: Host, rounds: Int) -> Host {
  // Spent rounds stop the pass. Rows still due are read again on the next
  // message or tick.
  case rounds {
    0 -> host
    _ -> {
      let now = host.ports.now_ms()

      // A failed read is treated as nothing due. The rows stay in the ledger
      // and the next tick reads them again.
      case project_ledger.effects_due(host.ledger, now, 50) {
        Error(_) | Ok([]) -> host
        Ok(rows) -> {
          let after = list.fold(rows, host, perform_row)
          perform_rounds(after, rounds - 1)
        }
      }
    }
  }
}

/// Decodes one effect row and performs it.
fn perform_row(host: Host, row: project_ledger.Effect) -> Host {
  // A row that does not decode is settled, because retrying a payload that
  // cannot be parsed never succeeds and would hold up every later round.
  case project_records.job(row) {
    Error(reason) -> {
      log.error(host.ports.logger, "project.job_unreadable", [
        field.ident(key: "kind", value: row.kind),
        field.text(key: "reason", value: reason),
      ])
      settle(host, row)
    }
    Ok(job) -> perform(host, row, job)
  }
}

fn settle(host: Host, row: project_ledger.Effect) -> Host {
  let _settled = project_ledger.settle(host.ledger, row.kind, row.key)
  host
}

/// Pushes a row's time out by a delay that grows with its attempts. The ledger
/// counts the attempt, so the delay survives a restart.
fn defer(host: Host, row: project_ledger.Effect) -> Host {
  let now = host.ports.now_ms()
  let delay = int.min(60_000, 1000 * int.bitwise_shift_left(1, row.attempts))
  let _deferred =
    project_ledger.defer(host.ledger, row.kind, row.key, now + delay)
  host
}

/// Performs one job. Each performer ends by settling the row, deferring it, or
/// committing the engine event that gives up on it, so no row is left due
/// without a reason.
fn perform(host: Host, row: project_ledger.Effect, job: Job) -> Host {
  case job {
    StartJob(ticket:, seq:, key:) -> start_worker(host, row, ticket, seq, key)
    DeliverJob(ticket:, seq:, trigger:) ->
      deliver_to_worker(host, row, ticket, seq, trigger)
    OfferJob(triggers:) -> offer_to_router(host, row, triggers)
    StopJob(ticket:, seq:) -> stop_worker(host, row, ticket, seq)
    RecoverJob(ticket:, seq:) -> recover_worker(host, row, ticket, seq)

    // These are recorded and settled. The host check, the pull request and
    // the relay of an answer belong to later slices, and a logged row is the
    // honest trace of a request that nothing yet serves.
    CheckJob(ticket:) -> not_served(host, row, "check", ticket)
    PullRequestJob(ticket:) -> not_served(host, row, "pull_request", ticket)
    AnswerJob(ticket:, seq: _) -> not_served(host, row, "answer", ticket)
  }
}

/// Logs and settles a job kind that has no performer in this slice, so its row
/// does not come due again on every scan.
fn not_served(
  host: Host,
  row: project_ledger.Effect,
  kind: String,
  ticket: String,
) -> Host {
  log.info(host.ports.logger, "project.effect_not_served", [
    field.ident(key: "kind", value: kind),
    field.ident(key: "ticket", value: ticket),
  ])
  settle(host, row)
}

/// The session bound to assignment `seq` of a ticket, or `None` while the
/// assignment has no session yet.
fn bound_session(ticket: Ticket, seq: Int) -> Option(String) {
  list.find(ticket.assignments, fn(assignment) { assignment.seq == seq })
  |> result.map(fn(assignment) {
    option.map(assignment.session, fn(session) { session.value })
  })
  |> result.unwrap(None)
}

/// Starts the worker session for an assignment. The request key is the
/// engine's, so a repeat after a crash finds the session the first attempt
/// made. A ticket the engine no longer has, or an assignment that already has
/// a session, needs no start.
fn start_worker(
  host: Host,
  row: project_ledger.Effect,
  ticket: String,
  seq: Int,
  key: String,
) -> Host {
  case state.ticket(host.engine, model.TicketId(ticket)) {
    Error(_) -> settle(host, row)
    Ok(found) ->
      case bound_session(found, seq) {
        Some(_) -> settle(host, row)
        None -> {
          let request =
            StartRequest(
              key:,
              ticket:,
              seq:,
              title: model.title_text(found.title),
            )

          // A started session is bound to the assignment. A failure counts as
          // an attempt against the row.
          case host.ports.start_session(request) {
            Ok(session) -> started(host, row, found, seq, session)
            Error(reason) -> start_failed(host, row, found, seq, reason)
          }
        }
      }
  }
}

/// Binds the new session to the assignment and marks it live, as two engine
/// events, and then settles the row. A refusal of either, such as a ticket a
/// person stopped meanwhile, leaves the host as it was.
fn started(
  host: Host,
  row: project_ledger.Effect,
  ticket: Ticket,
  seq: Int,
  session: String,
) -> Host {
  let bound =
    committed_or_same(
      host,
      event.SessionBound(ticket.id, seq, model.SessionId(session)),
    )
  let live = committed_or_same(bound, event.AssignmentLive(ticket.id, seq))
  settle(live, row)
}

/// Five failed starts give the assignment up, which frees its slot and puts the
/// ticket where a person sees it. Fewer defer with backoff.
fn start_failed(
  host: Host,
  row: project_ledger.Effect,
  ticket: Ticket,
  seq: Int,
  reason: String,
) -> Host {
  log.warn(host.ports.logger, "project.start_failed", [
    field.ident(key: "ticket", value: ticket.id.value),
    field.text(key: "reason", value: reason),
  ])

  // The ledger counts attempts from zero, so the fifth failure is the one
  // that gives up.
  case row.attempts >= 4 {
    True ->
      committed_or_same(
        host,
        event.AssignmentEnded(ticket.id, seq, model.SessionCrashed),
      )
      |> settle(row)
    False -> defer(host, row)
  }
}

/// Stops the session of an assignment, if it has one, and then releases its
/// worktree if the ticket has ended. The stop is best effort and its result is
/// ignored, because the session may already be closed.
fn stop_worker(
  host: Host,
  row: project_ledger.Effect,
  ticket: String,
  seq: Int,
) -> Host {
  // A ticket the engine does not have needs no stop.
  case state.ticket(host.engine, model.TicketId(ticket)) {
    Error(_) -> settle(host, row)
    Ok(found) -> {
      // An assignment that never received a session has nothing to stop.
      case bound_session(found, seq) {
        Some(session) -> {
          let _stopped = host.ports.stop_session(session)
          Nil
        }
        None -> Nil
      }

      release_tree(host, row, found, seq)
    }
  }
}

/// Releases the assignment's worktree once its ticket has ended. It runs after
/// the session was stopped, in the same job, so the tree is never removed from
/// under a session that is still writing to it. A stop that leaves the ticket
/// open, such as the end of one assignment before a retry, keeps the tree.
fn release_tree(
  host: Host,
  row: project_ledger.Effect,
  ticket: Ticket,
  seq: Int,
) -> Host {
  // Only a ticket that has ended releases its trees.
  case ticket.outcome {
    None -> settle(host, row)
    Some(_) ->
      case host.ports.release_worktree(ReleaseRequest(ticket.id.value, seq)) {
        Ok(Removed) -> settle(host, row)
        Ok(Kept(path:, reason:)) ->
          record_kept_tree(host, ticket.id.value, seq, path, reason)
          |> settle(row)
        Error(reason) -> release_failed(host, row, ticket, reason)
      }
  }
}

/// A release that failed is tried again under the row's backoff, and given up
/// on after the same five attempts a session start gets. The tree is then left
/// where it is, which is the safe side: nothing was removed.
fn release_failed(
  host: Host,
  row: project_ledger.Effect,
  ticket: Ticket,
  reason: String,
) -> Host {
  log.warn(host.ports.logger, "project.release_failed", [
    field.ident(key: "ticket", value: ticket.id.value),
    field.text(key: "reason", value: reason),
  ])

  // The ledger counts attempts from zero, so the fifth failure gives up.
  case row.attempts >= 4 {
    True -> settle(host, row)
    False -> defer(host, row)
  }
}

/// Writes down that a worktree stayed, so the board can name it after a
/// restart. A write that fails is logged: the tree is still on disk, and only
/// the board's mention of it is lost.
fn record_kept_tree(
  host: Host,
  ticket: String,
  seq: Int,
  path: String,
  reason: String,
) -> Host {
  // The record is what the board and a restart read the kept tree from.
  case record(host, project_records.TreeKept(ticket, seq, path, reason)) {
    Ok(next) -> next
    Error(failure) -> {
      log.warn(host.ports.logger, "project.tree_kept_unrecorded", [
        field.ident(key: "ticket", value: ticket),
        field.text(key: "reason", value: failure),
      ])
      host
    }
  }
}

// --- recovery ----------------------------------------------------------------

// What a worker is told when the harness restarted under it. The wording is
// the harness's own and carries nothing a person or a model chose.
const recovery_note =
  "The harness restarted while you were working on this ticket, and your last steps may not have finished. Before you repeat any action outside your worktree, such as a push, a message or a command with effects elsewhere, check your worktree and the source of the request to see what already happened. Then carry on."

/// Queues one recovery note for every assignment that was running when the
/// actor started and has not had one. The pair is written to the ledger with
/// its effect row, so a later restart finds it and queues nothing, and the
/// note's message id makes a repeated delivery admit nothing.
fn recover_interrupted(host: Host) -> Host {
  list.fold(state.tickets_oldest_first(host.engine), host, fn(so_far, ticket) {
    case state.active_assignment(ticket) {
      None -> so_far
      Some(assignment) -> recover_assignment(so_far, ticket, assignment)
    }
  })
}

/// Queues the note for one assignment if it was running with a session and has
/// not been told.
fn recover_assignment(
  host: Host,
  ticket: Ticket,
  assignment: state.Assignment,
) -> Host {
  let told = set.contains(host.recovered, #(ticket.id.value, assignment.seq))

  // An assignment that never ran has nothing to recover from, and one already
  // told is not told again.
  case assignment.status, assignment.session, told {
    state.AssignmentRunning, Some(_), False ->
      queue_recovery(host, ticket.id.value, assignment.seq)
    state.AssignmentRunning, _, _
    | state.AssignmentPending, _, _
    | state.AssignmentDone(_), _, _
    -> host
  }
}

/// Appends the record and its effect row in one transaction.
fn queue_recovery(host: Host, ticket: String, seq: Int) -> Host {
  let written = project_records.Recovered(ticket, seq)
  let now = host.ports.now_ms()

  // The record and the row commit together or not at all, so a restart sees
  // either both or neither and never a row that nothing remembers queueing.
  case
    project_ledger.append_with_effects(
      host.ledger,
      project_records.encode_record(written),
      now,
      [project_records.recovery_draft(ticket, seq, now)],
    )
  {
    Ok(last) -> Host(..keep_record(host, written), last_seq: last)
    Error(error) -> {
      log.warn(host.ports.logger, "project.recovery_unqueued", [
        field.ident(key: "ticket", value: ticket),
        field.text(key: "reason", value: string.inspect(error)),
      ])
      host
    }
  }
}

/// Delivers the recovery note to the assignment's worker through the same
/// admission as any trigger, so it arrives with the trigger origin and a
/// harness source. A worker that cannot be reached after the usual attempts is
/// left alone: the note is a courtesy to a model and nothing depends on it.
fn recover_worker(
  host: Host,
  row: project_ledger.Effect,
  ticket: String,
  seq: Int,
) -> Host {
  // A ticket the engine lost, or an assignment with no session, has nobody to
  // tell.
  case state.ticket(host.engine, model.TicketId(ticket)) {
    Error(_) -> settle(host, row)
    Ok(found) ->
      case bound_session(found, seq) {
        None -> settle(host, row)
        Some(session) -> {
          let id = "recovery-" <> ticket <> "-" <> int.to_string(seq)
          let note =
            Trigger(source: "harness", actor: "loom", body: recovery_note)
          admit(host, row, session, id, note, peer_mail.MayWake, fn(admitted) {
            recovery_delivered(host, row, admitted)
          })
        }
      }
  }
}

/// Settles a delivered note, backs off one that did not get through, and drops
/// one that never will.
fn recovery_delivered(
  host: Host,
  row: project_ledger.Effect,
  admitted: Admitted,
) -> Host {
  case admitted {
    Admitted | GaveUp -> settle(host, row)
    NotYet -> defer(host, row)
  }
}

/// Delivers a stored trigger to the worker bound to an assignment. A missing
/// ticket or text is settled, since neither comes back. A person's own turn is
/// settled without delivery, because they typed it into that very session.
fn deliver_to_worker(
  host: Host,
  row: project_ledger.Effect,
  ticket: String,
  seq: Int,
  trigger: String,
) -> Host {
  let found = state.ticket(host.engine, model.TicketId(ticket))
  let typed_here = is_human(trigger)

  // Delivery needs both the ticket and the trigger's text.
  case found, dict.get(host.texts, trigger) {
    Error(_), _ | _, Error(Nil) -> settle(host, row)

    // A turn the owner typed into this very worker needs no echo.
    Ok(_), Ok(_) if typed_here -> settle(host, row)
    Ok(current), Ok(text) ->
      case bound_session(current, seq) {
        // The assignment has no session yet. The row stays as it is, due now,
        // so the next round of this very pass delivers it once the start job
        // has bound the session; deferring it would cost a tick's wait.
        None -> host
        Some(session) ->
          admit(host, row, session, trigger, text, peer_mail.MayWake, fn(ok) {
            delivered(host, row, ticket, trigger, ok)
          })
      }
  }
}

fn is_human(trigger: String) -> Bool {
  string.starts_with(trigger, "h-")
}

/// Turns an admission result into the row's fate. A success settles the row.
/// A failure to admit backs off, and after enough attempts it is recorded as a
/// failed input, which is what puts the ticket in `person/delivery`.
fn delivered(
  host: Host,
  row: project_ledger.Effect,
  ticket: String,
  trigger: String,
  admitted: Admitted,
) -> Host {
  let id = model.TicketId(ticket)

  // Admitted settles the row, NotYet backs it off, and GaveUp records the
  // failure where a person will see it.
  case admitted {
    Admitted -> {
      let current = state.ticket(host.engine, id)

      // Whether an earlier attempt had already given up on this input.
      let was_failed = case current {
        Ok(found) ->
          list.contains(found.failed_inputs, model.TriggerId(trigger))
        Error(_) -> False
      }

      // A success after a recorded failure clears the failure, so the ticket
      // leaves `person/delivery`. A first-time success has nothing to clear.
      let next = case was_failed {
        True ->
          committed_or_same(
            host,
            event.InputDelivered(id, model.TriggerId(trigger)),
          )
        False -> host
      }

      settle(next, row)
    }
    NotYet -> defer(host, row)
    GaveUp ->
      committed_or_same(host, event.InputFailed(id, model.TriggerId(trigger)))
      |> settle(row)
  }
}

/// Delivers a batch of candidate triggers to the router. The row settles only
/// when every trigger was admitted, and that moment starts the router-turn
/// clock. After ten failed attempts the turn is ended, which returns the
/// candidates to the queue.
fn offer_to_router(
  host: Host,
  row: project_ledger.Effect,
  triggers: List(String),
) -> Host {
  let router = host.config.router_session
  let results =
    list.map(triggers, fn(trigger) {
      case dict.get(host.texts, trigger) {
        Error(Nil) -> Admitted
        Ok(text) ->
          admit(host, row, router, trigger, text, peer_mail.MayWake, fn(ok) {
            ok
          })
      }
    })

  // A partly delivered batch is retried whole. The message id of each trigger
  // and the router makes the repeats of the delivered ones admit nothing.
  case list.all(results, fn(each) { each == Admitted }) {
    True ->
      Host(..host, offered_at_ms: host.ports.now_ms())
      |> settle(row)
    False ->
      case row.attempts >= 9 {
        True ->
          committed_or_same(host, event.RouterTurnEnded)
          |> settle(row)
        False -> defer(host, row)
      }
  }
}

/// What a delivery attempt came to.
type Admitted {
  Admitted
  NotYet
  GaveUp
}

/// Delivers one stored trigger to a session over its peer endpoint. A saved
/// session is opened first, which is the owner's act on its own project's
/// session and is allowed to reopen a closed one; a message from a peer is not,
/// because the peer path never reaches this function. The message id joins the
/// trigger and the target, so a repeat is an admission that already happened.
fn admit(
  host: Host,
  row: project_ledger.Effect,
  session: String,
  trigger: String,
  text: Trigger,
  wake: peer_mail.Wake,
  finish: fn(Admitted) -> a,
) -> a {
  let command =
    peer_mail.Trigger(
      from: peer_mail.TriggerSource(
        source: text.source,
        trigger:,
        actor: text.actor,
      ),
      target: main_strand,
      message_id: trigger <> ":" <> session,
      text: text.body,
      wake:,
    )
  let ports = host.ports
  let attempt = fn() {
    use endpoint <- result.try(ports.endpoint_of(session))
    endpoint.call(command)
  }
  let first = attempt()

  // A session that is not resident is opened once and the call is repeated.
  // Any other failure goes to the caller as it is.
  let answered = case first {
    Error(peer_mail.NotOpen) ->
      case ports.open_session(session) {
        Ok(Nil) -> attempt()
        Error(reason) -> Error(peer_mail.Refused(reason))
      }
    other -> other
  }

  // An answer admits the message. A failure is logged and reported as not yet
  // or as given up, depending on how many attempts the row has had.
  case answered {
    Ok(_) -> finish(Admitted)
    Error(failure) -> {
      log.warn(ports.logger, "project.delivery_failed", [
        field.ident(key: "session", value: session),
        field.text(key: "reason", value: peer_mail.reason(failure)),
      ])

      // Five attempts, counted from zero, are all a delivery gets.
      case row.attempts >= 4 {
        True -> finish(GaveUp)
        False -> finish(NotYet)
      }
    }
  }
}

// --- reading -----------------------------------------------------------------

/// One page of the board, stamped with the revision it was read at. The queued
/// replies appear on the first page only.
fn board_page(host: Host, page: Int) -> Board {
  let all = ordered_tickets(host)
  let window = all |> list.drop(page * page_size) |> list.take(page_size)
  Board(
    revision: host.last_seq,
    page:,
    total: list.length(all),
    tickets: list.map(window, fn(ticket) { ticket_json(host, ticket) }),
    replies: case page {
      0 -> list.map(list.reverse(host.replies), reply_json)
      _ -> []
    },
  )
}

/// The bound sessions of assignments not yet done.
fn live_now(host: Host) -> List(String) {
  state.tickets_oldest_first(host.engine)
  |> list.filter_map(fn(ticket) {
    case state.active_assignment(ticket) {
      Some(assignment) ->
        option.map(assignment.session, fn(each) { each.value })
        |> option.to_result(Nil)
      None -> Error(Nil)
    }
  })
}

/// Needs-a-person tickets first, each group newest first.
fn ordered_tickets(host: Host) -> List(Ticket) {
  let newest_first = list.reverse(state.tickets_oldest_first(host.engine))
  let #(needing, rest) =
    list.partition(newest_first, fn(ticket) {
      stage.needs_person(state.stage_of(ticket))
    })
  list.append(needing, rest)
}

/// Counts tickets by stage word, sorted by word so the output is stable.
fn stage_counts(host: Host) -> List(#(String, Int)) {
  state.tickets_oldest_first(host.engine)
  |> list.fold(dict.new(), fn(counts, ticket) {
    let word = stage.to_string(state.stage_of(ticket))
    dict.upsert(counts, word, fn(found) { option.unwrap(found, 0) + 1 })
  })
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

/// The board's form of one queued reply.
fn reply_json(entry: #(String, String, String)) -> JsonValue {
  json.Object([
    #("subject", json.String(entry.0)),
    #("purpose", json.String(entry.1)),
    #("text", json.String(entry.2)),
  ])
}

/// A ticket's card, shared by the board and `project_read`. Its stage is the
/// engine's pure function of the ticket, so no client recomputes it.
fn ticket_json(host: Host, ticket: Ticket) -> JsonValue {
  // The session shown is the newest assignment's, if it has one yet.
  let session = case list.first(ticket.assignments) {
    Ok(latest) ->
      case latest.session {
        Some(bound) -> json.String(bound.value)
        None -> json.Null
      }
    Error(Nil) -> json.Null
  }

  json.Object([
    #("id", json.String(ticket.id.value)),
    #("project", json.String(host.config.project)),
    #("title", json.String(model.title_text(ticket.title))),
    #("stage", json.String(stage.to_string(state.stage_of(ticket)))),
    #("session", session),
    #("mandate", mandate_json(ticket.mandate)),
    #("check", json.Null),
    #("opened_ms", opened_json(host, ticket)),
    #("question", question_json(host, ticket)),
    #("kept_worktrees", kept_json(host, ticket)),
    #("pull_request", case ticket.pull_request {
      Some(request) -> json.String(request.url)
      None -> json.Null
    }),
    #("ended", case ticket.outcome {
      Some(outcome) -> json.String(stage.outcome_string(outcome))
      None -> json.Null
    }),
  ])
}

/// A mandate as the board shows it: strength, basis, source, actor and policy
/// version.
fn mandate_json(mandate: model.Mandate) -> JsonValue {
  // Strength goes on the wire as a word.
  let strength = case mandate.strength {
    model.Explicit -> "explicit"
    model.Inferred -> "inferred"
  }

  // The basis is shown without the rule behind a rule-based accept.
  let via = case mandate.basis {
    model.FromComposer -> "composer"
    model.FromAddressed -> "addressed"
    model.FromFollowUp -> "follow_up"
    model.FromOverheard -> "overheard"
    model.FromAutomation -> "automation"
    model.FromRule(..) -> "rule"
  }

  json.Object([
    #("strength", json.String(strength)),
    #("via", json.String(via)),
    #("source", json.String(mandate.source.value)),
    #("actor", json.String(mandate.actor.value)),
    #("policy_version", json.String(mandate.policy_version)),
  ])
}

/// The worktrees that stayed when the ticket ended, oldest assignment first,
/// each with where it is and why. An empty list is the ordinary case.
fn kept_json(host: Host, ticket: Ticket) -> JsonValue {
  dict.get(host.kept_trees, ticket.id.value)
  |> result.unwrap([])
  |> list.reverse
  |> list.map(fn(kept) {
    json.Object([
      #("seq", json.Int(kept.seq)),
      #("path", json.String(kept.path)),
      #("reason", json.String(kept.reason)),
    ])
  })
  |> json.Array
}

/// An open question with its text. The text lives in a host record keyed by
/// ticket and number, and a question whose record is missing shows empty text.
fn question_json(host: Host, ticket: Ticket) -> JsonValue {
  case ticket.question {
    model.NoQuestion -> json.Null
    model.Asking(seq:) ->
      json.Object([
        #("seq", json.Int(seq)),
        #(
          "text",
          json.String(
            dict.get(host.questions, #(ticket.id.value, seq))
            |> result.unwrap(""),
          ),
        ),
        #("options", json.Array([])),
      ])
  }
}

/// Serves one `project_read` resource. Candidates are the triggers now offered
/// to the router, and every other resource reads one node of the graph by id.
fn serve_resource(
  host: Host,
  resource: tools.Resource,
) -> Result(JsonValue, tools.Refusal) {
  // No resource serves a transcript or a file, so the private data the
  // router could leak stays out of its reach.
  case resource {
    tools.Candidates ->
      Ok(
        json.Object([
          #(
            "candidates",
            json.Array(
              list.filter_map(host.engine.offered, fn(id) {
                trigger_card(host, id)
              }),
            ),
          ),
        ]),
      )
    tools.Board(page:) -> {
      let shown = board_page(host, page)
      Ok(
        json.Object([
          #("revision", json.Int(shown.revision)),
          #("page", json.Int(shown.page)),
          #("total", json.Int(shown.total)),
          #("tickets", json.Array(shown.tickets)),
        ]),
      )
    }
    tools.TicketCard(ticket:) ->
      state.ticket(host.engine, ticket)
      |> result.map(fn(found) { ticket_json(host, found) })
      |> result.map_error(fn(_) {
        tools.NotFound("there is no ticket " <> ticket.value)
      })
    tools.TriggerCard(trigger:) ->
      trigger_card(host, trigger)
      |> result.map_error(fn(_) {
        tools.NotFound("there is no message " <> trigger.value)
      })
    tools.ThreadCard(thread:) ->
      dict.get(host.engine.threads, thread)
      |> result.map(thread_json)
      |> result.map_error(fn(_) {
        tools.NotFound("there is no thread " <> thread.value)
      })
  }
}

/// A thread's entries, oldest first, each with whether the trigger was
/// received or only recorded.
fn thread_json(thread: model.Thread) -> JsonValue {
  json.Object([
    #("id", json.String(thread.id.value)),
    #(
      "entries",
      json.Array(
        list.map(list.reverse(thread.entries), fn(entry) {
          json.Object([
            #("trigger", json.String(entry.trigger.value)),
            #("received", json.Bool(entry.reception == model.Received)),
          ])
        }),
      ),
    ),
  ])
}

/// A trigger's card with its stored text. The router reads hostile text
/// through this card, so it carries only the id, source, actor, thread and
/// text.
fn trigger_card(host: Host, id: model.TriggerId) -> Result(JsonValue, Nil) {
  use stored <- result.try(dict.get(host.engine.triggers, id))

  // A trigger with no stored text shows empty text and does not fail the read.
  let text = case dict.get(host.texts, id.value) {
    Ok(found) -> found.body
    Error(Nil) -> ""
  }

  Ok(
    json.Object([
      #("id", json.String(id.value)),
      #("source", json.String(stored.trigger.source.value)),
      #("actor", json.String(stored.trigger.actor.value)),
      #("thread", json.String(stored.trigger.thread.value)),
      #("text", json.String(text)),
    ]),
  )
}

// --- refusals ----------------------------------------------------------------

/// The sentence a refusal becomes for a caller. It names ids and never repeats
/// the text of a message.
fn refusal_text(refusal: Refusal) -> String {
  case refusal {
    event.UnknownTicket(ticket:) -> "there is no ticket " <> ticket.value
    event.UnknownTrigger(trigger:) -> "there is no message " <> trigger.value
    event.UnknownAssignment(ticket:, seq:) ->
      "ticket " <> ticket.value <> " has no assignment " <> int.to_string(seq)
    event.NotOffered(trigger:) ->
      "message " <> trigger.value <> " was not offered to you"
    event.TriggerNotAdmitted(trigger:) ->
      "message " <> trigger.value <> " was not admitted by the gate"
    event.AcceptRefused(..) -> "the gate refuses to accept that message"
    event.NotAPersonsMessage(trigger:) ->
      "message " <> trigger.value <> " is not a person's explicit message"
    event.TicketWithdrawn(ticket:) ->
      "ticket " <> ticket.value <> " was stopped by a person"
    event.TicketEnded(ticket:) -> "ticket " <> ticket.value <> " has ended"
    event.TicketNotEnded(ticket:) ->
      "ticket " <> ticket.value <> " is still open"
    event.Stale(ticket:) -> "that is out of date for ticket " <> ticket.value
    event.AssignmentActive(ticket:) ->
      "ticket " <> ticket.value <> " already has a worker"
    event.NotPublishable(ticket:) ->
      "ticket " <> ticket.value <> " cannot be published"
    event.VerdictRequired(..) -> "auto needs a current passing verdict"
    event.NotRequeueable(trigger:) ->
      "message " <> trigger.value <> " cannot be queued again"
    event.StaleAnswer(ticket:) ->
      "that answer does not match ticket " <> ticket.value <> "'s question"
    event.NotAConclusion(ticket:) ->
      "that is not a way for ticket " <> ticket.value <> " to conclude"
  }
}

// --- ticket detail and the board's controls ----------------------------------

/// Why an answer was not taken. A stale answer is its own case because a
/// client shows it in words of its own: the question changed while the person
/// was typing, and nothing was recorded.
pub type AnswerFailure {
  /// The project holds no such ticket.
  NoSuchTicket

  /// The answer's sequence number is not the ticket's open question, either
  /// because the question was answered already or because a newer one replaced
  /// it.
  StaleQuestion

  /// The engine or the ledger refused it for another reason.
  NotAccepted(
    /// The reason, in words.
    reason: String,
  )
}

/// One ticket with what a person needs to decide about it: the ticket record,
/// its assignments newest first, and its inputs oldest first. An error means
/// the project holds no such ticket.
///
/// ## Examples
///
/// ```gleam
/// // project_host.ticket(handle, "t-c1")
/// ```
pub fn ticket(handle: Handle, ticket: String) -> Result(JsonValue, Nil) {
  ask(handle, ReadTicket(ticket, _))
  |> result.replace_error(Nil)
  |> result.flatten
}

/// Records a person's answer to a ticket's open question. `seq` must be the
/// question's sequence number as the board showed it, and an answer to any
/// other is refused as `StaleQuestion` with nothing recorded.
///
/// ## Examples
///
/// ```gleam
/// // project_host.answer(handle, "t-c1", 7, "use sqlite", "owner")
/// ```
pub fn answer(
  handle: Handle,
  ticket: String,
  seq: Int,
  text: String,
  by: String,
) -> Result(Nil, AnswerFailure) {
  case ask(handle, AnswerQuestion(ticket, seq, text, by, _)) {
    Ok(settled) -> settled
    Error(reason) -> Error(NotAccepted(reason))
  }
}

/// A person's request for a new assignment on a stalled ticket.
///
/// ## Examples
///
/// ```gleam
/// // project_host.retry(handle, "t-c1", "owner")
/// ```
pub fn retry(
  handle: Handle,
  ticket: String,
  by: String,
) -> Result(Nil, String) {
  ask(handle, RetryTicket(ticket, by, _))
  |> result.flatten
}

/// A person's request that a stored trigger be evaluated afresh.
///
/// ## Examples
///
/// ```gleam
/// // project_host.requeue(handle, "tr-1", "owner")
/// ```
pub fn requeue(
  handle: Handle,
  trigger: String,
  by: String,
) -> Result(Nil, String) {
  ask(handle, RequeueTrigger(trigger, by, _))
  |> result.flatten
}

// The most inputs one ticket detail carries, the newest kept.
const input_limit = 20

// The most characters of one input's text a ticket detail carries. The text is
// external and may be long, and a client draws it as inert text.
const input_text_limit = 2000

/// The ticket detail step of this module.
fn ticket_detail(host: Host, ticket: String) -> Result(JsonValue, Nil) {
  use found <- result.map(
    state.ticket(host.engine, model.TicketId(ticket))
    |> result.replace_error(Nil),
  )

  json.Object([
    #("project", json.String(host.config.project)),
    #("revision", json.Int(host.last_seq)),
    #("ticket", ticket_json(host, found)),
    #("assignments", json.Array(list.map(found.assignments, assignment_json))),
    #("inputs", json.Array(inputs_json(host, found))),
  ])
}

/// One assignment as the detail shows it. The status is the engine's three
/// states, with how a finished session ended.
fn assignment_json(assignment: state.Assignment) -> JsonValue {
  // The wire spells a finished session by how it ended, so a client can tell a
  // crash from an exit without a second field.
  let status = case assignment.status {
    state.AssignmentPending -> "pending"
    state.AssignmentRunning -> "running"
    state.AssignmentDone(model.SessionExited) -> "done/exited"
    state.AssignmentDone(model.SessionCrashed) -> "done/crashed"
  }

  json.Object([
    #("seq", json.Int(assignment.seq)),
    #("session", case assignment.session {
      Some(bound) -> json.String(bound.value)
      None -> json.Null
    }),
    #("status", json.String(status)),
  ])
}

/// The ticket's inputs: the triggers on its opening thread, oldest first and
/// at most `input_limit` of the newest.
fn inputs_json(host: Host, ticket: Ticket) -> List(JsonValue) {
  // The inputs are the messages on the thread the ticket opened on. A ticket
  // whose opening message or thread the engine no longer holds has none.
  let entries = case dict.get(host.engine.triggers, ticket.origin) {
    Ok(origin) ->
      // The thread is looked up by the id the opening message carries.
      case dict.get(host.engine.threads, origin.trigger.thread) {
        Ok(thread) -> thread.entries
        Error(Nil) -> []
      }
    Error(Nil) -> []
  }

  // A thread keeps its entries newest first, so the limit takes the newest and
  // the reverse puts them back in the order they arrived.
  entries
  |> list.take(input_limit)
  |> list.reverse
  |> list.map(fn(entry) { input_json(host, ticket, entry) })
}

/// One input. A trigger whose text the ledger does not hold carries no text
/// field at all, so a client cannot mistake it for an empty message.
fn input_json(
  host: Host,
  ticket: Ticket,
  entry: model.ThreadEntry,
) -> JsonValue {
  // The gate's reception decides first, because a message it did not admit
  // was never queued for the worker. After that, a failed delivery outranks a
  // waiting one.
  let delivery = case
    entry.reception,
    list.contains(ticket.failed_inputs, entry.trigger),
    list.contains(ticket.inbox, entry.trigger)
  {
    model.Recorded, _, _ -> "recorded"
    model.Received, True, _ -> "failed"
    model.Received, False, True -> "waiting"
    model.Received, False, False -> "delivered"
  }

  // The source, actor and text come from the host's record of the message, and
  // are left out together when that record is missing.
  let described = case dict.get(host.texts, entry.trigger.value) {
    Ok(found) -> [
      #("source", json.String(found.source)),
      #("actor", json.String(found.actor)),
      #("text", json.String(string.slice(found.body, 0, input_text_limit))),
    ]
    Error(Nil) -> []
  }

  json.Object([
    #("trigger", json.String(entry.trigger.value)),
    #("delivery", json.String(delivery)),
    ..described
  ])
}

/// When the ticket's opening trigger arrived, in Unix milliseconds, or null
/// when the engine no longer holds that trigger. A client shows an age only
/// from this, and never from when it first saw the ticket.
fn opened_json(host: Host, ticket: Ticket) -> JsonValue {
  case dict.get(host.engine.triggers, ticket.origin) {
    Ok(origin) -> json.Int(origin.trigger.at_ms)
    Error(Nil) -> json.Null
  }
}

/// Takes an answer. The question is compared before the text is written, so a
/// stale answer leaves nothing in the ledger; the engine then checks it again
/// as the authority, and its refusal is the same case.
fn answer_now(
  host: Host,
  ticket: String,
  seq: Int,
  text: String,
  by: String,
) -> #(Host, Result(Nil, AnswerFailure)) {
  case state.ticket(host.engine, model.TicketId(ticket)) {
    Error(_) -> #(host, Error(NoSuchTicket))
    Ok(found) ->
      case found.question {
        model.Asking(seq: open) if open == seq ->
          case record_answer(host, ticket, seq, text, by) {
            Ok(next) -> #(next, Ok(Nil))
            Error(failure) -> #(host, Error(failure))
          }
        model.Asking(_) | model.NoQuestion -> #(host, Error(StaleQuestion))
      }
  }
}

/// Writes the answer's text and then the event that closes the question. The
/// text is keyed by ticket and question, so it is findable from the ledger.
fn record_answer(
  host: Host,
  ticket: String,
  seq: Int,
  text: String,
  by: String,
) -> Result(Host, AnswerFailure) {
  let id = "a-" <> ticket <> "-" <> int.to_string(seq)
  use texted <- result.try(
    record(host, project_records.TriggerText(id, "answer", by, text))
    |> result.map_error(NotAccepted),
  )

  commit(
    texted,
    event.Answered(model.TicketId(ticket), seq, model.PrincipalId(by)),
  )
  |> result.map_error(answer_failure)
}

/// The engine's refusals that mean "the question moved on" or "no such
/// ticket" keep their own cases, and every other refusal is words.
fn answer_failure(failure: NotCommitted) -> AnswerFailure {
  case failure {
    Refused(event.StaleAnswer(..)) -> StaleQuestion
    Refused(event.UnknownTicket(..)) -> NoSuchTicket
    Refused(other) -> NotAccepted(refusal_text(other))
    WriteFailed(reason) -> NotAccepted(reason)
  }
}

/// A person's retry: the engine decides whether the ticket may take a new
/// assignment.
fn retry_now(
  host: Host,
  ticket: String,
  by: String,
) -> #(Host, Result(Nil, String)) {
  case
    commit(
      host,
      event.RetryRequested(model.TicketId(ticket), model.PrincipalId(by)),
    )
  {
    Ok(next) -> #(next, Ok(Nil))
    Error(failure) -> #(host, Error(not_committed_text(failure)))
  }
}

/// A person's requeue: the engine decides whether the stored trigger may be
/// evaluated again.
fn requeue_now(
  host: Host,
  trigger: String,
  by: String,
) -> #(Host, Result(Nil, String)) {
  case
    commit(
      host,
      event.Requeued(model.TriggerId(trigger), model.PrincipalId(by)),
    )
  {
    Ok(next) -> #(next, Ok(Nil))
    Error(failure) -> #(host, Error(not_committed_text(failure)))
  }
}
