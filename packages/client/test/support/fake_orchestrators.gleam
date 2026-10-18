//// Other orchestrators for a parent session's tests, played by processes that
//// keep the one promise `client/remote_child` and the drainer rely on.
////
//// The promise is the receiver's adoption (protocol-change/084): a `Spawn`
//// from a call site that already made a child answers that child, so a resend
//// never makes a second one. Everything else a real orchestrator does, the
//// policy, the delegate session and the Agency behind it, is S2's and has its
//// own tests; here the other orchestrator is a table from call site to child,
//// and what a test scripts is the network in front of it.
////
//// | Mode | What a call does |
//// | --- | --- |
//// | `Up` | The orchestrator acts and answers. |
//// | `Down` | Nobody answers, and the orchestrator does nothing. |
//// | `LosesReplies` | The orchestrator acts, and its answer is lost. |
//// | `Refuses` | The orchestrator looks and says no. |
//// | `DownFirst`, `LosesFirst` | `Down` or `LosesReplies` for a number of calls, then `Up`. |
////
//// A `Reach` is built over several of these by name, as the daemon's is over its
//// configured orchestrators, and every call is recorded so a test can say how
//// many attempts it took and what each orchestrator was told.
////
//// The other direction, a child's mail to its parent, is not a call into the fake:
//// a real orchestrator originates it. `deliver_to_laptop` plays that: it hands a
//// message to a parent session's inbox the way the port would, as if it came from
//// the named box, so a test drives the parent from the box side.

import client/agency
import client/peer_mail
import client/remote_escalation
import client/remote_mail
import client/remote_reach.{type Reach}
import client/remote_spawn.{
  type CallSite, type Joined, type Request, type Spawned,
}
import core/clock
import core/ids
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/string
import tools/agent.{type Handle}
import weft/actor

/// How the network in front of an orchestrator behaves.
pub type Mode {
  Up
  Down
  LosesReplies
  Refuses(reason: String)

  /// Nobody answers the next `n` spawns, then the orchestrator is up.
  DownFirst(n: Int)

  /// The next `n` spawns are acted on and their answers lost, then the
  /// orchestrator is up.
  LosesFirst(n: Int)
}

/// One orchestrator, reached by its name.
pub type Box {
  Box(name: String, inbox: Subject(Call))
}

/// What a test can read of an orchestrator afterwards.
pub type Report {
  Report(
    /// Every `Spawn` sent to it, in order, including resends and the ones the
    /// network lost.
    spawns: List(CallSite),
    /// The most each of those `Spawn`s was told it may wait for an answer, in
    /// milliseconds, in the same order.
    windows: List(Int),
    /// The children it holds, one per call site.
    children: List(Spawned),
    /// The number of `Join` calls sent to it.
    joins: Int,
    /// The window each of those `Join`s asked it to wait, in milliseconds, in
    /// the same order.
    join_windows: List(Int),
    /// The parent of every `Release` sent to it, in order, including resends
    /// and the ones the network lost.
    releases: List(remote_spawn.Parent),
    /// Every send into a child, as the message id and the text, in order,
    /// including resends and the ones the network lost.
    sends: List(#(String, String)),
    /// Every decision sent to it, as the request's identity and the `seq` the
    /// operator was shown, in order.
    resolves: List(#(String, Int)),
  )
}

/// A message to an orchestrator.
pub opaque type Call {
  Asked(Ask)
  Set(Mode)
  Settle(Handle)
  Owing(Int)
  Look(reply: Subject(Report))
}

type Ask {
  AskSpawn(
    parent: remote_spawn.Parent,
    site: CallSite,
    request: Request,
    within_ms: Int,
    reply: Subject(Result(Spawned, peer_mail.Failure)),
  )
  AskJoin(
    handles: List(Handle),
    window_ms: Int,
    reply: Subject(Result(List(Joined), peer_mail.Failure)),
  )
  AskRelease(
    parent: remote_spawn.Parent,
    reply: Subject(Result(Int, peer_mail.Failure)),
  )
  AskSend(
    message_id: String,
    text: String,
    reply: Subject(Result(remote_mail.Landing, peer_mail.Failure)),
  )
  AskResolve(
    escalation_id: String,
    expected_seq: Int,
    reply: Subject(Result(remote_escalation.Answer, peer_mail.Failure)),
  )
}

type State {
  State(
    mode: Mode,
    spawns: List(CallSite),
    windows: List(Int),
    children: Dict(String, Spawned),
    joins: Int,
    join_windows: List(Int),
    settled: List(Handle),
    owed: Int,
    releases: List(remote_spawn.Parent),
    sends: List(#(String, String)),
    resolves: List(#(String, Int)),
    delivered: Dict(String, String),
  )
}

/// Starts an orchestrator in `mode`.
///
/// ## Examples
///
/// ```gleam
/// let box = fake_orchestrators.start("box", fake_orchestrators.Up)
/// ```
pub fn start(name: String, mode: Mode) -> Box {
  let assert Ok(started) =
    actor.new(State(
      mode:,
      spawns: [],
      windows: [],
      children: dict.new(),
      joins: 0,
      join_windows: [],
      settled: [],
      owed: 0,
      releases: [],
      sends: [],
      resolves: [],
      delivered: dict.new(),
    ))
    |> actor.on_message(handle)
    |> actor.start
    as "the fake orchestrator starts"
  Box(name:, inbox: started.data)
}

/// Changes how the network in front of the orchestrator behaves.
pub fn set_mode(box: Box, mode: Mode) -> Nil {
  process.send(box.inbox, Set(mode))
}

/// Makes the orchestrator report the child as finished from the next join on.
pub fn settle(box: Box, handle: Handle) -> Nil {
  process.send(box.inbox, Settle(handle))
}

/// Makes the orchestrator report `count` undelivered messages from every child it
/// reports as finished, from the next join on.
pub fn set_owed(box: Box, count: Int) -> Nil {
  process.send(box.inbox, Owing(count))
}

/// What the orchestrator has seen so far.
pub fn report(box: Box) -> Report {
  process.call(box.inbox, 1000, fn(reply) { Look(reply:) })
}

/// A reach over these orchestrators, for the session `session`, offered
/// whenever `offered` says so. A name no orchestrator answers to is refused
/// definitively, as the daemon's is.
///
/// ## Examples
///
/// ```gleam
/// let reach = fake_orchestrators.reach("0198c0de-0000-7000-8000-000000000001", [box], fn() { True })
/// ```
pub fn reach(
  session: String,
  boxes: List(Box),
  offered: fn() -> Bool,
) -> Reach {
  voting(session, boxes, offered, process.new_subject())
}

/// A reach that also reports each vote the session casts to a link keeper, as the
/// orchestrator's name and the vote, in order.
///
/// ## Examples
///
/// ```gleam
/// let votes = process.new_subject()
/// let reach = fake_orchestrators.voting(session, [box], fn() { True }, votes)
/// ```
pub fn voting(
  session: String,
  boxes: List(Box),
  offered: fn() -> Bool,
  votes: Subject(#(String, remote_reach.Vote)),
) -> Reach {
  remote_reach.Reach(
    session:,
    orchestrators: list.map(boxes, fn(box) { box.name }),
    offered:,
    spawn: fn(name, parent, site, _depth, _tools, request, within_ms) {
      ask(boxes, name, fn(reply) {
        AskSpawn(parent:, site:, request:, within_ms:, reply:)
      })
    },
    join: fn(name, _parent, handles, window_ms) {
      ask(boxes, name, fn(reply) { AskJoin(handles:, window_ms:, reply:) })
    },
    release: fn(name, parent) {
      ask(boxes, name, fn(reply) { AskRelease(parent:, reply:) })
    },
    send: fn(name, _parent, _child, message_id, text) {
      ask(boxes, name, fn(reply) { AskSend(message_id:, text:, reply:) })
    },
    resolve: fn(
      name,
      _parent,
      _child,
      escalation_id,
      _decision,
      expected_seq,
      _by,
    ) {
      ask(boxes, name, fn(reply) {
        AskResolve(escalation_id:, expected_seq:, reply:)
      })
    },
    keep: fn(name, vote) { process.send(votes, #(name, vote)) },
  )
}

/// Hands a child's mail to the parent session's inbox as the box `box` would,
/// and answers what the inbox does. The inbox admits the message only if the box
/// is the orchestrator the child's stub names, as the daemon's host does.
///
/// ## Examples
///
/// ```gleam
/// fake_orchestrators.deliver_to_laptop(box, inbox, parent, child, "7b1c", "done")
/// ```
pub fn deliver_to_laptop(
  box: Box,
  inbox: agency.ChildInbox,
  parent: remote_spawn.Parent,
  child: Handle,
  message_id: String,
  text: String,
) -> Result(remote_mail.Receipt, remote_mail.ChildRefusal) {
  inbox.mail(parent, child, message_id, text, fn(name) { name == box.name })
}

// One call to the orchestrator that answers to `name`, or the definitive refusal
// for a name none does.
fn ask(
  boxes: List(Box),
  name: String,
  build: fn(Subject(Result(answer, peer_mail.Failure))) -> Ask,
) -> Result(answer, peer_mail.Failure) {
  case list.find(boxes, fn(box) { box.name == name }) {
    Ok(box) -> process.call(box.inbox, 5000, fn(reply) { Asked(build(reply)) })
    Error(Nil) -> Error(remote_reach.not_configured(name))
  }
}

fn handle(state: State, call: Call) -> actor.Next(State, Call) {
  case call {
    Set(mode) -> actor.continue(State(..state, mode:))
    Settle(handle) ->
      actor.continue(State(..state, settled: [handle, ..state.settled]))
    Owing(count) -> actor.continue(State(..state, owed: count))
    Look(reply:) -> {
      process.send(
        reply,
        Report(
          spawns: list.reverse(state.spawns),
          windows: list.reverse(state.windows),
          children: dict.values(state.children),
          joins: state.joins,
          join_windows: list.reverse(state.join_windows),
          releases: list.reverse(state.releases),
          sends: list.reverse(state.sends),
          resolves: list.reverse(state.resolves),
        ),
      )
      actor.continue(state)
    }
    Asked(AskSpawn(parent:, site:, request:, within_ms:, reply:)) ->
      spawn(
        State(..state, windows: [within_ms, ..state.windows]),
        parent,
        site,
        request,
        reply,
      )
    Asked(AskJoin(handles:, window_ms:, reply:)) ->
      join(state, handles, window_ms, reply)
    Asked(AskRelease(parent:, reply:)) -> release(state, parent, reply)
    Asked(AskSend(message_id:, text:, reply:)) ->
      send(state, message_id, text, reply)

    // A decision is recorded and refused: the fake holds no record to judge it
    // against, and a test that wants the box's judgement uses the real one.
    Asked(AskResolve(escalation_id:, expected_seq:, reply:)) -> {
      process.send(
        reply,
        Ok(remote_escalation.Refused(reason: "the fake decides nothing")),
      )
      actor.continue(
        State(..state, resolves: [
          #(escalation_id, expected_seq),
          ..state.resolves
        ]),
      )
    }
  }
}

// A send is recorded whatever the network does to its answer, as a real
// orchestrator acts before it replies. The first delivery of an id answers that
// it steered the child, and a repeat answers `Admitted`, which is the receipt a
// real orchestrator stores.
fn send(
  state: State,
  message_id: String,
  text: String,
  reply: Subject(Result(remote_mail.Landing, peer_mail.Failure)),
) -> actor.Next(State, Call) {
  let state = State(..state, sends: [#(message_id, text), ..state.sends])
  let #(mode, state) = consume(state)
  case mode {
    Down | DownFirst(..) -> {
      process.send(reply, Error(peer_mail.Unreachable))
      actor.continue(state)
    }
    Refuses(reason:) -> {
      process.send(reply, Error(peer_mail.Refused(reason)))
      actor.continue(state)
    }
    Up | LosesReplies | LosesFirst(..) -> {
      let #(landing, state) = deliver(state, message_id, text)
      process.send(reply, case mode {
        LosesReplies | LosesFirst(..) -> Error(peer_mail.Unreachable)
        Up | Down | Refuses(..) | DownFirst(..) -> Ok(landing)
      })
      actor.continue(state)
    }
  }
}

fn deliver(
  state: State,
  message_id: String,
  text: String,
) -> #(remote_mail.Landing, State) {
  case dict.has_key(state.delivered, message_id) {
    True -> #(remote_mail.Admitted, state)
    False -> {
      let #(entry, _generator) =
        ids.mint_entry(ids.generator(
          clock.fixed(at: 1000),
          seed: seed_of(message_id),
        ))
      #(
        remote_mail.Steered(entry:),
        State(
          ..state,
          delivered: dict.insert(state.delivered, message_id, text),
        ),
      )
    }
  }
}

// A release is recorded whatever the network does to its answer, as a real
// orchestrator acts before it replies. Its answer is the number of children the
// orchestrator holds, which a test reads as how many it stopped.
fn release(
  state: State,
  parent: remote_spawn.Parent,
  reply: Subject(Result(Int, peer_mail.Failure)),
) -> actor.Next(State, Call) {
  let state = State(..state, releases: [parent, ..state.releases])
  case state.mode {
    Down | DownFirst(..) -> process.send(reply, Error(peer_mail.Unreachable))
    Refuses(reason:) -> process.send(reply, Error(peer_mail.Refused(reason)))
    LosesReplies | LosesFirst(..) ->
      process.send(reply, Error(peer_mail.Unreachable))
    Up -> process.send(reply, Ok(dict.size(state.children)))
  }
  actor.continue(state)
}

// A spawn is adopted by call site: the first one makes a child and every later
// one from the same site answers it. `LosesReplies` acts and then answers
// nothing the caller can use.
fn spawn(
  state: State,
  parent: remote_spawn.Parent,
  site: CallSite,
  request: Request,
  reply: Subject(Result(Spawned, peer_mail.Failure)),
) -> actor.Next(State, Call) {
  let state = State(..state, spawns: [site, ..state.spawns])
  let #(mode, state) = consume(state)
  case mode {
    Down | DownFirst(..) -> {
      process.send(reply, Error(peer_mail.Unreachable))
      actor.continue(state)
    }
    Refuses(reason:) -> {
      process.send(reply, Error(peer_mail.Refused(reason)))
      actor.continue(state)
    }
    Up | LosesReplies | LosesFirst(..) -> {
      let #(child, state) = adopt(state, parent, site, request)
      process.send(reply, case mode {
        LosesReplies | LosesFirst(..) -> Error(peer_mail.Unreachable)
        Up | Down | Refuses(..) | DownFirst(..) -> Ok(child)
      })
      actor.continue(state)
    }
  }
}

// The mode this spawn meets, and the state after it. A counted mode is used up
// one spawn at a time and becomes `Up` after the last.
fn consume(state: State) -> #(Mode, State) {
  case state.mode {
    DownFirst(n:) -> #(Down, State(..state, mode: after(DownFirst, n)))
    LosesFirst(n:) -> #(
      LosesReplies,
      State(..state, mode: after(LosesFirst, n)),
    )
    Up | Down | LosesReplies | Refuses(..) -> #(state.mode, state)
  }
}

fn after(counted: fn(Int) -> Mode, n: Int) -> Mode {
  case n <= 1 {
    True -> Up
    False -> counted(n - 1)
  }
}

fn adopt(
  state: State,
  parent: remote_spawn.Parent,
  site: CallSite,
  request: Request,
) -> #(Spawned, State) {
  let key = site_key(site)
  case dict.get(state.children, key) {
    Ok(existing) -> #(existing, state)
    Error(Nil) -> {
      let child = make_child(parent, site, request)
      #(
        child,
        State(..state, children: dict.insert(state.children, key, child)),
      )
    }
  }
}

// The child's name is derived as the real receiver derives it, from the parent
// reference `^main`, so a test sees the names a real orchestrator would give.
fn make_child(
  parent: remote_spawn.Parent,
  site: CallSite,
  request: Request,
) -> Spawned {
  let assert Ok(name) =
    agency.child_name(
      agent.Caller(
        strand: "^" <> parent.strand,
        operation: site.operation,
        step_id: site.step_id,
        source_index: site.source_index,
        minter: site.minter,
      ),
      request.purpose,
    )
    as "the purpose in a test is a usable one"
  let #(operation, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 1000), seed: seed_of(name)))
  remote_spawn.Spawned(
    handle: agent.Handle(strand: name, operation:),
    tools: ["agent_note", "agent_send"],
    model: "box-model",
    model_id: "box-model-id",
    remaining_ms: 1_800_000,
  )
}

fn join(
  state: State,
  handles: List(Handle),
  window_ms: Int,
  reply: Subject(Result(List(Joined), peer_mail.Failure)),
) -> actor.Next(State, Call) {
  let state =
    State(..state, joins: state.joins + 1, join_windows: [
      window_ms,
      ..state.join_windows
    ])
  case state.mode {
    Down | DownFirst(..) -> {
      process.send(reply, Error(peer_mail.Unreachable))
    }
    Refuses(reason:) -> {
      process.send(reply, Error(peer_mail.Refused(reason)))
    }
    Up | LosesReplies | LosesFirst(..) -> {
      let entries =
        list.map(handles, fn(handle) {
          case list.contains(state.settled, handle) {
            True ->
              remote_spawn.Ready(
                handle:,
                outcome: agent.Completed,
                report: "done on " <> handle.strand,
                result: agent.NoResultAsked,
                notes: [],
                usage: remote_spawn.ChildUsage(
                  input: 100,
                  output: 20,
                  cache_read: 5,
                  cache_write: 7,
                  cost: 0.5,
                ),
                owed: state.owed,
              )
            False -> remote_spawn.Pending(handle:, waited_ms: window_ms)
          }
        })
      process.send(reply, case state.mode {
        LosesReplies | LosesFirst(..) -> Error(peer_mail.Unreachable)
        Up | Down | Refuses(..) | DownFirst(..) -> Ok(entries)
      })
    }
  }
  actor.continue(state)
}

fn site_key(site: CallSite) -> String {
  ids.op_id_to_string(site.operation)
  <> "|"
  <> site.step_id
  <> "|"
  <> string.inspect(site.source_index)
  <> "|"
  <> string.inspect(site.minter)
}

fn seed_of(text: String) -> Int {
  list.fold(string.to_utf_codepoints(text), 31, fn(total, point) {
    total * 31 + string.utf_codepoint_to_int(point)
  })
}
