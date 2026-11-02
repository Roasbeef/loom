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
  Host as HostLine, OfferJob, PullRequestJob, StartJob, StopJob,
}
import core/json.{type JsonValue}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
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
  HumanTurn(session: String, entry: String, actor: String, text: String)
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
  )
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
    )
  use replayed <- result.try(replay(fresh, 0))
  Ok(perform_due(replayed))
}

// Replays a page at a time, because the ledger returns at most a page, and the
// engine judges each line against the state the earlier lines built.
fn replay(host: Host, after: Int) -> Result(Host, String) {
  use page <- result.try(
    project_ledger.replay(host.ledger, after, project_ledger.replay_page_limit)
    |> result.map_error(fn(error) {
      "the project ledger did not replay: " <> string.inspect(error)
    }),
  )

  case list.last(page) {
    Error(Nil) -> Ok(host)
    Ok(last) -> {
      use next <- result.try(list.try_fold(page, host, replay_line))
      replay(Host(..next, last_seq: last.seq), last.seq)
    }
  }
}

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

fn handle(host: Host, message: Message) -> actor.Next(Host, Message) {
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
    HumanTurn(session, entry, actor_name, text) ->
      actor.continue(
        perform_due(human_now(host, session, entry, actor_name, text)),
      )
    Tick -> actor.continue(tick(host))
  }
}

// A tick performs what is due and ends a router turn that has gone on too
// long. The engine returns unrouted candidates to the queue on
// `RouterTurnEnded`, and a router that left some unrouted would otherwise keep
// the project from ever offering another batch.
fn tick(host: Host) -> Host {
  let now = host.ports.now_ms()
  let stale =
    host.engine.router == state.RouterBusy
    && host.offered_at_ms > 0
    && now - host.offered_at_ms > host.config.router_turn_ms
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

// The engine judges first. Only an accepted event is appended, with the rows
// for its effects in the same transaction, and the new state is kept only when
// the append succeeded. A write that fails leaves the old state, so memory
// never runs ahead of the ledger.
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

// Records a host record in the ledger and in memory.
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
  }
}

// --- composer ----------------------------------------------------------------

fn post_now(
  host: Host,
  request: String,
  text: String,
) -> #(Host, Result(Posted, String)) {
  let id = model.TriggerId(request)
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
      case outcome {
        Ok(next) -> #(next, Ok(Posted(request)))
        Error(reason) -> #(host, Error(reason))
      }
    }
  }
}

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

fn route_now(
  host: Host,
  items: List(tools.Item),
) -> #(Host, List(tools.ItemOutcome)) {
  let #(after, outcomes) =
    list.fold(items, #(host, []), fn(acc, item) {
      let #(so_far, done) = acc
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

fn routed_event(item: tools.Item) -> Event {
  case item.action {
    tools.Accept(title:) -> event.Routed(routing(item, model.Accept(title)))
    tools.Attach(ticket:) -> event.Routed(routing(item, model.Attach(ticket)))
    tools.Resume(ticket:) -> event.Routed(routing(item, model.Resume(ticket)))
    tools.Stop(ticket:) -> event.RoutedStop(item.trigger, ticket)
    tools.Ignore -> event.RoutedIgnore(item.trigger)
  }
}

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

fn reply_now(
  host: Host,
  queued: tools.Reply,
) -> #(Host, Result(Nil, tools.Refusal)) {
  case dict.has_key(host.engine.triggers, queued.subject) {
    False -> #(
      host,
      Error(tools.NotFound(
        "there is no message " <> queued.subject.value <> " to answer",
      )),
    )
    True -> {
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

// The ticket and assignment a worker session serves, if the engine has bound
// that session to a live assignment.
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

fn report_now(
  host: Host,
  session: String,
  report: tools.WorkerReport,
) -> #(Host, Result(Nil, tools.Refusal)) {
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
      case outcome {
        Ok(next) -> #(next, Ok(Nil))
        Error(reason) -> #(host, Error(tools.NotPermitted(reason)))
      }
    }
  }
}

fn question_of(
  host: Host,
  ticket: String,
  report: tools.WorkerReport,
) -> Result(#(Host, model.Question), String) {
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

// A person's turn typed into a worker becomes an explicit trigger on the
// ticket's own thread, keyed by the entry that carried it. The key is what
// makes a scanner that reads the same entry twice record one turn.
fn human_now(
  host: Host,
  session: String,
  entry: String,
  actor_name: String,
  text: String,
) -> Host {
  let id = model.TriggerId("h-" <> entry)
  let located = assignment_of(host, session)
  case located, dict.has_key(host.engine.triggers, id) {
    Error(Nil), _ | _, True -> host
    Ok(#(ticket, _)), False -> {
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

// --- performing --------------------------------------------------------------

// Reads the rows whose time has come and performs each, a few rounds at most:
// a performed job can commit events whose effects are due at once, and the
// bound keeps one message from running unboundedly.
fn perform_due(host: Host) -> Host {
  perform_rounds(host, 8)
}

fn perform_rounds(host: Host, rounds: Int) -> Host {
  case rounds {
    0 -> host
    _ -> {
      let now = host.ports.now_ms()
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

fn perform_row(host: Host, row: project_ledger.Effect) -> Host {
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

// Pushes a row's time out by a delay that grows with its attempts. The ledger
// counts the attempt, so the delay survives a restart.
fn defer(host: Host, row: project_ledger.Effect) -> Host {
  let now = host.ports.now_ms()
  let delay = int.min(60_000, 1000 * int.bitwise_shift_left(1, row.attempts))
  let _deferred =
    project_ledger.defer(host.ledger, row.kind, row.key, now + delay)
  host
}

fn perform(host: Host, row: project_ledger.Effect, job: Job) -> Host {
  case job {
    StartJob(ticket:, seq:, key:) -> start_worker(host, row, ticket, seq, key)
    DeliverJob(ticket:, seq:, trigger:) ->
      deliver_to_worker(host, row, ticket, seq, trigger)
    OfferJob(triggers:) -> offer_to_router(host, row, triggers)
    StopJob(ticket:, seq:) -> stop_worker(host, row, ticket, seq)

    // These are recorded and settled. The host check, the pull request and
    // the relay of an answer belong to later slices, and a logged row is the
    // honest trace of a request that nothing yet serves.
    CheckJob(ticket:) -> not_served(host, row, "check", ticket)
    PullRequestJob(ticket:) -> not_served(host, row, "pull_request", ticket)
    AnswerJob(ticket:, seq: _) -> not_served(host, row, "answer", ticket)
  }
}

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

fn bound_session(ticket: Ticket, seq: Int) -> Option(String) {
  list.find(ticket.assignments, fn(assignment) { assignment.seq == seq })
  |> result.map(fn(assignment) {
    option.map(assignment.session, fn(session) { session.value })
  })
  |> result.unwrap(None)
}

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
          case host.ports.start_session(request) {
            Ok(session) -> started(host, row, found, seq, session)
            Error(reason) -> start_failed(host, row, found, seq, reason)
          }
        }
      }
  }
}

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

// Five failed starts give the assignment up, which frees its slot and puts the
// ticket where a person sees it. Fewer defer with backoff.
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

fn stop_worker(
  host: Host,
  row: project_ledger.Effect,
  ticket: String,
  seq: Int,
) -> Host {
  case state.ticket(host.engine, model.TicketId(ticket)) {
    Error(_) -> settle(host, row)
    Ok(found) -> {
      case bound_session(found, seq) {
        Some(session) -> {
          let _stopped = host.ports.stop_session(session)
          Nil
        }
        None -> Nil
      }
      settle(host, row)
    }
  }
}

fn deliver_to_worker(
  host: Host,
  row: project_ledger.Effect,
  ticket: String,
  seq: Int,
  trigger: String,
) -> Host {
  let found = state.ticket(host.engine, model.TicketId(ticket))
  let typed_here = is_human(trigger)
  case found, dict.get(host.texts, trigger) {
    Error(_), _ | _, Error(Nil) -> settle(host, row)

    // A turn the owner typed into this very worker needs no echo.
    Ok(_), Ok(_) if typed_here -> settle(host, row)
    Ok(current), Ok(text) ->
      case bound_session(current, seq) {
        None -> defer(host, row)
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

fn delivered(
  host: Host,
  row: project_ledger.Effect,
  ticket: String,
  trigger: String,
  admitted: Admitted,
) -> Host {
  let id = model.TicketId(ticket)
  case admitted {
    Admitted -> {
      let current = state.ticket(host.engine, id)
      let was_failed = case current {
        Ok(found) ->
          list.contains(found.failed_inputs, model.TriggerId(trigger))
        Error(_) -> False
      }
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

// Delivers one stored trigger to a session over its peer endpoint. A saved
// session is opened first, which is the owner's act on its own project's
// session and is allowed to reopen a closed one; a message from a peer is not,
// because the peer path never reaches this function. The message id joins the
// trigger and the target, so a repeat is an admission that already happened.
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
  let answered = case first {
    Error(peer_mail.NotOpen) ->
      case ports.open_session(session) {
        Ok(Nil) -> attempt()
        Error(reason) -> Error(peer_mail.Refused(reason))
      }
    other -> other
  }
  case answered {
    Ok(_) -> finish(Admitted)
    Error(failure) -> {
      log.warn(ports.logger, "project.delivery_failed", [
        field.ident(key: "session", value: session),
        field.text(key: "reason", value: peer_mail.reason(failure)),
      ])
      case row.attempts >= 4 {
        True -> finish(GaveUp)
        False -> finish(NotYet)
      }
    }
  }
}

// --- reading -----------------------------------------------------------------

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

// The bound sessions of assignments not yet done.
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

// Needs-a-person tickets first, each group newest first.
fn ordered_tickets(host: Host) -> List(Ticket) {
  let newest_first = list.reverse(state.tickets_oldest_first(host.engine))
  let #(needing, rest) =
    list.partition(newest_first, fn(ticket) {
      stage.needs_person(state.stage_of(ticket))
    })
  list.append(needing, rest)
}

fn stage_counts(host: Host) -> List(#(String, Int)) {
  state.tickets_oldest_first(host.engine)
  |> list.fold(dict.new(), fn(counts, ticket) {
    let word = stage.to_string(state.stage_of(ticket))
    dict.upsert(counts, word, fn(found) { option.unwrap(found, 0) + 1 })
  })
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

fn reply_json(entry: #(String, String, String)) -> JsonValue {
  json.Object([
    #("subject", json.String(entry.0)),
    #("purpose", json.String(entry.1)),
    #("text", json.String(entry.2)),
  ])
}

fn ticket_json(host: Host, ticket: Ticket) -> JsonValue {
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
    #("question", question_json(host, ticket)),
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

fn mandate_json(mandate: model.Mandate) -> JsonValue {
  let strength = case mandate.strength {
    model.Explicit -> "explicit"
    model.Inferred -> "inferred"
  }
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

fn serve_resource(
  host: Host,
  resource: tools.Resource,
) -> Result(JsonValue, tools.Refusal) {
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
      |> result.replace_error(tools.NotFound(
        "there is no ticket " <> ticket.value,
      ))
    tools.TriggerCard(trigger:) ->
      trigger_card(host, trigger)
      |> result.replace_error(tools.NotFound(
        "there is no message " <> trigger.value,
      ))
    tools.ThreadCard(thread:) ->
      dict.get(host.engine.threads, thread)
      |> result.map(thread_json)
      |> result.replace_error(tools.NotFound(
        "there is no thread " <> thread.value,
      ))
  }
}

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

fn trigger_card(host: Host, id: model.TriggerId) -> Result(JsonValue, Nil) {
  use stored <- result.try(dict.get(host.engine.triggers, id))
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
