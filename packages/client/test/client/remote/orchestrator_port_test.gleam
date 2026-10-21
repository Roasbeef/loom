//// The orchestrator port answers one question from the catalogue: does this
//// daemon hold the session (protocol-change/078, phase 3). It answers
//// `Owned` or `NotOwned` when it could tell and says nothing when it could not,
//// so that silence is never mistaken for a negative. It also relays the three
//// subagent messages to a spawn host (protocol-change/084), each in a task of
//// its own so that the question about ownership is never kept waiting.

import client/catalogue_page
import client/daemon/main as daemon_main
import client/daemon/manager
import client/executors
import client/listed_sessions.{Further, Last}
import client/node_report
import client/protocol
import client/remote/address.{type Address}
import client/remote/orchestrator_port.{type Message, NotOwned, Owned}
import client/remote_escalation
import client/remote_mail
import client/remote_spawn.{
  Attached, CallSite, ChildUsage, Parent, Ready, Request, Spawned,
}
import client/roster
import client/session_move
import client/spawners
import core/clock
import core/glance
import core/ids
import core/json
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import storage/catalogue
import support/held_catalogue
import tools/agent

const answers_within_ms = 1000

// A fake catalogue holding `owned-1`. Any other id is absent, and the id
// `unreadable` is one the catalogue cannot answer for. What the real
// catalogue counts as held (reserved and archived rows included) is proved
// where the real registry is, in `daemon_directory_test`.
fn held(id: String) -> Result(orchestrator_port.Ownership, Nil) {
  case id {
    "unreadable" -> Error(Nil)
    "owned-1" -> Ok(Owned)
    _ -> Ok(NotOwned)
  }
}

// A port under a private name, addressed on this node.
fn started() -> Address(Message) {
  let name = process.new_name("orchestrator_port")
  let assert Ok(_) = orchestrator_port.start(name, held)
    as "the port starts under its name"
  address.Address(node: node.self(), name:)
}

pub fn a_session_the_catalogue_holds_is_owned_test() {
  let port = started()
  assert orchestrator_port.ask(port, "owned-1", answers_within_ms) == Ok(Owned)
}

pub fn a_session_the_catalogue_lacks_is_not_owned_test() {
  let port = started()
  assert orchestrator_port.ask(port, "elsewhere-1", answers_within_ms)
    == Ok(NotOwned)
}

pub fn a_catalogue_that_cannot_answer_produces_silence_and_the_port_serves_on_test() {
  let port = started()

  // No reply at all, so the asker's wait ends at its own bound. A `NotOwned`
  // here would let a failed read pass for proof that the session exists
  // nowhere.
  assert orchestrator_port.ask(port, "unreadable", 100) == Error(Nil)

  // The failed question did not stop the port.
  assert orchestrator_port.ask(port, "owned-1", answers_within_ms) == Ok(Owned)
}

// A port that serves descriptions from a fake catalogue holding `owned-1`.
fn describing() -> Address(Message) {
  let name = process.new_name("orchestrator_port")
  let assert Ok(_) =
    orchestrator_port.start_with(
      name,
      held,
      fn(_session, _command) { Error(orchestrator_port.peer_unserved) },
      fn(session) {
        case session {
          "owned-1" -> Ok(json.String("described " <> session))
          _ -> Error("not_found")
        }
      },
      orchestrator_port.declining(),
      orchestrator_port.refusing_spawns(),
      orchestrator_port.refusing_children(),
      orchestrator_port.unheld,
      orchestrator_port.unreported(),
    )
    as "the port starts under its name"
  address.Address(node: node.self(), name:)
}

pub fn a_description_is_the_describers_answer_or_its_reason_test() {
  let port = describing()
  assert orchestrator_port.ask_description(port, "owned-1", answers_within_ms)
    == Ok(Ok(json.String("described owned-1")))
  assert orchestrator_port.ask_description(
      port,
      "elsewhere-1",
      answers_within_ms,
    )
    == Ok(Error("not_found"))
}

// A port whose catalogue holds what `holder` says.
fn holding(holder: orchestrator_port.Holder) -> Address(Message) {
  let name = process.new_name("orchestrator_port")
  let assert Ok(_) =
    orchestrator_port.start_with(
      name,
      held,
      fn(_session, _command) { Error(orchestrator_port.peer_unserved) },
      fn(_session) { Error("not_found") },
      orchestrator_port.declining(),
      orchestrator_port.refusing_spawns(),
      orchestrator_port.refusing_children(),
      holder,
      orchestrator_port.unreported(),
    )
    as "the port starts under its name"
  address.Address(node: node.self(), name:)
}

pub fn what_the_catalogue_holds_is_the_holders_answer_test() {
  let busy =
    orchestrator_port.Held(sessions: 4, placed: [
      orchestrator_port.Placed(executor_node: "box@10.0.0.2", sessions: 3),
    ])
  let port = holding(fn() { Ok(busy) })
  assert orchestrator_port.ask_holds(port, answers_within_ms) == Ok(busy)
}

pub fn a_catalogue_that_cannot_be_read_is_silence_and_never_none_test() {
  // The holder says it could not read. The asker must not be able to take that
  // for a daemon that owns nothing, so the answer is the same as no answer.
  let port = holding(fn() { Error(Nil) })
  assert orchestrator_port.ask_holds(port, answers_within_ms) == Error(Nil)

  // A port started without a holder is in the same position, and serves on.
  let unheld = started()
  assert orchestrator_port.ask_holds(unheld, answers_within_ms) == Error(Nil)
  assert orchestrator_port.ask(unheld, "owned-1", answers_within_ms)
    == Ok(Owned)
}

pub fn a_slow_holder_does_not_keep_a_lookup_waiting_test() {
  let port =
    holding(fn() {
      process.sleep(400)
      Ok(orchestrator_port.Held(sessions: 0, placed: []))
    })
  let reply = process.new_subject()
  process.spawn(fn() {
    process.send(reply, orchestrator_port.ask_holds(port, 3000))
  })

  // The ownership question is answered while the walk is still running.
  assert orchestrator_port.ask(port, "owned-1", answers_within_ms) == Ok(Owned)
  assert process.receive(reply, 3000)
    == Ok(Ok(orchestrator_port.Held(sessions: 0, placed: [])))
}

pub fn a_port_with_no_describer_refuses_every_description_test() {
  let port = started()
  assert orchestrator_port.ask_description(port, "owned-1", answers_within_ms)
    == Ok(Error(orchestrator_port.peer_unserved))

  // The refusal does not stop the question the port exists for.
  assert orchestrator_port.ask(port, "owned-1", answers_within_ms) == Ok(Owned)
}

pub fn the_port_has_its_own_name_apart_from_the_executor_host_test() {
  assert orchestrator_port.default_name == "loom_orchestrator"
  assert orchestrator_port.default_name != address.default_name
}

pub fn a_second_port_under_one_name_does_not_start_test() {
  let name = process.new_name("orchestrator_port")
  let assert Ok(_) = orchestrator_port.start(name, held)
    as "the first port starts"
  let assert Error(_) = orchestrator_port.start(name, held)
    as "the name is taken"
  Nil
}

// --- receiving a moved session (phase 5) --------------------------------------

fn chunk(offset: Int, bytes: BitArray) -> session_move.Chunk {
  session_move.Chunk(session: "s1", op: "op1", offset:, total: 6, bytes:)
}

fn activation() -> session_move.Activation {
  session_move.Activation(
    session: "s1",
    op: "op1",
    from_node: "alpha@10.0.0.1",
    digest: "00",
    incarnation: 2,
    manifest: session_move.Manifest(
      workspace: "repo",
      name: "n",
      profile: option.None,
      model: option.None,
      executor: "box",
      pool: "",
      subtitle: option.None,
      created_at: 1,
    ),
  )
}

// A port whose importer records each call on `seen` and answers from the
// arguments, under a private name.
fn importing(
  seen: process.Subject(String),
  activate: fn(session_move.Activation) -> session_move.Verdict,
) -> Address(Message) {
  let name = process.new_name("orchestrator_port")
  let importer =
    orchestrator_port.Importer(
      chunk: fn(piece: session_move.Chunk) {
        process.send(
          seen,
          "chunk "
            <> int.to_string(piece.offset)
            <> "/"
            <> int.to_string(piece.total),
        )
        session_move.Accepted
      },
      stage: fn(session, op) {
        process.send(seen, "stage " <> session <> " " <> op)
        case session {
          "unreadable" -> Error(Nil)
          _ -> Ok(session_move.Received)
        }
      },
      activate:,
    )
  let assert Ok(_) = orchestrator_port.start_importing(name, held, importer)
    as "the port starts under its name"
  address.Address(node: node.self(), name:)
}

pub fn a_port_with_no_importer_refuses_every_piece_and_activation_test() {
  let port = started()
  assert orchestrator_port.send_chunk(port, chunk(0, <<1, 2, 3>>), 1000)
    == Ok(session_move.Refused(session_move.NotImporting))
  assert orchestrator_port.ask_stage(port, "s1", "op1", 1000)
    == Ok(session_move.Absent)
  assert orchestrator_port.ask_activation(port, activation(), 1000)
    == Ok(session_move.Refused(session_move.NotImporting))

  // It still answers the question it always answered.
  assert orchestrator_port.ask(port, "owned-1", answers_within_ms) == Ok(Owned)
}

pub fn pieces_reach_the_importer_in_the_order_they_were_sent_test() {
  let seen = process.new_subject()
  let port = importing(seen, fn(_) { session_move.Accepted })
  assert orchestrator_port.send_chunk(port, chunk(0, <<1, 2, 3>>), 1000)
    == Ok(session_move.Accepted)
  assert orchestrator_port.send_chunk(port, chunk(3, <<4, 5, 6>>), 1000)
    == Ok(session_move.Accepted)
  assert process.receive(seen, 0) == Ok("chunk 0/6")
  assert process.receive(seen, 0) == Ok("chunk 3/6")
}

pub fn the_stage_comes_from_the_importer_and_names_the_move_test() {
  let seen = process.new_subject()
  let port = importing(seen, fn(_) { session_move.Accepted })
  assert orchestrator_port.ask_stage(port, "s1", "op1", 1000)
    == Ok(session_move.Received)
  assert process.receive(seen, 0) == Ok("stage s1 op1")
}

pub fn a_stage_the_importer_cannot_read_is_silence_and_the_port_serves_on_test() {
  let seen = process.new_subject()
  let port = importing(seen, fn(_) { session_move.Accepted })

  // No reply at all. An `Absent` here would tell the sender that nothing is
  // held, and it would send the whole file again to a receiver that may already
  // hold the session.
  assert orchestrator_port.ask_stage(port, "unreadable", "op1", 100)
    == Error(Nil)
  assert process.receive(seen, 0) == Ok("stage unreadable op1")

  // The failed question did not stop the port.
  assert orchestrator_port.ask_stage(port, "s1", "op1", 1000)
    == Ok(session_move.Received)
}

pub fn an_activation_is_answered_and_a_lookup_is_not_kept_waiting_behind_it_test() {
  let seen = process.new_subject()

  // The activation takes a second, as hashing and opening a large copy would.
  let port =
    importing(seen, fn(_) {
      process.sleep(1000)
      session_move.Accepted
    })
  let asker = process.new_subject()
  let _pid =
    process.spawn(fn() {
      process.send(
        asker,
        orchestrator_port.ask_activation(port, activation(), 5000),
      )
    })

  // While it runs, ownership is answered inside a tenth of that. A port that
  // ran the activation in its own turn would answer this after it.
  process.sleep(100)
  let started = bootstrap.monotonic_time_ms()
  assert orchestrator_port.ask(port, "owned-1", 500) == Ok(Owned)
  assert bootstrap.monotonic_time_ms() - started < 300
  assert process.receive(asker, 0) == Error(Nil)
  assert process.receive(asker, 5000) == Ok(Ok(session_move.Accepted))
}

pub fn a_crashing_activation_is_silence_and_the_port_serves_on_test() {
  let seen = process.new_subject()
  let port = importing(seen, fn(_) { panic as "the importer fails" })
  assert orchestrator_port.ask_activation(port, activation(), 200) == Error(Nil)
  assert orchestrator_port.ask(port, "owned-1", answers_within_ms) == Ok(Owned)
}

pub fn a_tombstone_is_a_third_answer_and_carries_the_new_owner_test() {
  let name = process.new_name("orchestrator_port")
  let assert Ok(_) =
    orchestrator_port.start(name, fn(_) {
      Ok(orchestrator_port.Moved(to: "laptop"))
    })
  let port = address.Address(node: node.self(), name:)
  assert orchestrator_port.ask(port, "s1", answers_within_ms)
    == Ok(orchestrator_port.Moved(to: "laptop"))
}

// --- subagents on another orchestrator (protocol-change/084) ------------------

// The node this test runs on, which is the node the port sees as the requester,
// because the asker and the port share a VM.
fn own_node() -> String {
  atom.to_string(node.name(node.self()))
}

fn operation() -> ids.OpId {
  let #(operation, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 7))
  operation
}

fn parent() -> remote_spawn.Parent {
  Parent(session: "s1", strand: "main")
}

fn call_site() -> remote_spawn.CallSite {
  CallSite(
    operation: operation(),
    step_id: "step-1",
    source_index: 0,
    minter: agent.ToolCall,
  )
}

fn request() -> remote_spawn.Request {
  Request(
    purpose: "run the suite",
    brief: "Run make e2e.",
    model: None,
    tools: None,
    within_ms: Some(60_000),
    result_schema: None,
    detach: Attached,
  )
}

fn handle() -> agent.Handle {
  agent.Handle(strand: "sub:^main/run-the-suite-1", operation: operation())
}

fn spawned() -> remote_spawn.Spawned {
  Spawned(
    handle: handle(),
    tools: ["bash"],
    model: "fast",
    model_id: "fast-1",
    remaining_ms: 60_000,
  )
}

fn ready(handle: agent.Handle) -> remote_spawn.Joined {
  Ready(
    handle:,
    outcome: agent.Completed,
    report: "done",
    result: agent.NoResultAsked,
    notes: [],
    usage: ChildUsage(
      input: 1,
      output: 2,
      cache_read: 3,
      cache_write: 4,
      cost: 0.5,
    ),
    owed: 0,
  )
}

// A host that records what it was asked on `seen`, waits `pause_ms`, and
// answers successfully.
fn hosting(
  seen: process.Subject(String),
  pause_ms: Int,
) -> orchestrator_port.SpawnHost {
  orchestrator_port.SpawnHost(
    spawn: fn(origin, site, depth, tools, asked) {
      process.send(
        seen,
        "spawn "
          <> origin.node
          <> " "
          <> origin.parent.session
          <> "/"
          <> origin.parent.strand
          <> " "
          <> site.step_id
          <> " depth "
          <> int.to_string(depth)
          <> " tools "
          <> string.join(tools, ",")
          <> " "
          <> asked.purpose,
      )
      process.sleep(pause_ms)
      Ok(spawned())
    },
    join: fn(origin, handles, within_ms) {
      process.send(
        seen,
        "join "
          <> origin.node
          <> " "
          <> origin.parent.strand
          <> " "
          <> int.to_string(list.length(handles))
          <> " within "
          <> int.to_string(within_ms),
      )
      process.sleep(pause_ms)
      Ok(list.map(handles, ready))
    },
    run_ended: fn(origin, ended) {
      process.send(
        seen,
        "run_ended "
          <> origin.node
          <> " "
          <> origin.parent.strand
          <> " "
          <> ids.op_id_to_string(ended),
      )
      process.sleep(pause_ms)
      Ok(2)
    },
    release: fn(origin) {
      process.send(
        seen,
        "release " <> origin.node <> " " <> origin.parent.session,
      )
      process.sleep(pause_ms)
      Ok(3)
    },
    send: fn(origin, child, message_id, text) {
      process.send(
        seen,
        "send "
          <> origin.node
          <> " "
          <> origin.parent.strand
          <> " "
          <> child.strand
          <> " "
          <> message_id
          <> " "
          <> text,
      )
      process.sleep(pause_ms)
      Ok(remote_mail.encode_landing(remote_mail.Admitted))
    },
    resolve: fn(origin, child, id, decision, seq, decider) {
      process.send(
        seen,
        "resolve "
          <> origin.node
          <> " "
          <> origin.parent.strand
          <> " "
          <> child.strand
          <> " "
          <> id
          <> " "
          <> string.inspect(decision)
          <> " "
          <> int.to_string(seq)
          <> " "
          <> decider.name,
      )
      process.sleep(pause_ms)
      Ok(remote_escalation.Forgotten)
    },
    history: fn(origin, child, cursor, limit) {
      process.send(
        seen,
        "history "
          <> origin.node
          <> " "
          <> origin.parent.strand
          <> " "
          <> child.strand
          <> " before "
          <> int.to_string(cursor)
          <> " limit "
          <> int.to_string(limit),
      )
      process.sleep(pause_ms)
      Ok(json.Object([#("child", json.String(child.strand))]))
    },
  )
}

// A port under a private name that serves the spawn messages with `host`.
fn spawning(host: orchestrator_port.SpawnHost) -> Address(Message) {
  let name = process.new_name("orchestrator_port")
  let assert Ok(_) =
    orchestrator_port.start_with(
      name,
      held,
      fn(_session, _command) { Error(orchestrator_port.peer_unserved) },
      fn(_session) { Error("not_found") },
      orchestrator_port.declining(),
      host,
      orchestrator_port.refusing_children(),
      orchestrator_port.unheld,
      orchestrator_port.unreported(),
    )
    as "the port starts under its name"
  address.Address(node: node.self(), name:)
}

pub fn a_port_with_no_spawn_host_refuses_all_three_messages_test() {
  let port = started()
  let refusal = remote_spawn.UnknownSpawner(node: own_node())
  assert orchestrator_port.ask_spawn(
      port,
      parent(),
      call_site(),
      0,
      ["bash"],
      request(),
      1000,
    )
    == Ok(Error(refusal))
  assert orchestrator_port.ask_join(port, parent(), [handle()], 25_000, 1000)
    == Ok(Error(refusal))
  assert orchestrator_port.ask_run_ended(port, parent(), operation(), 1000)
    == Ok(Error(refusal))

  // It still answers the question it always answered.
  assert orchestrator_port.ask(port, "owned-1", answers_within_ms) == Ok(Owned)
}

pub fn a_spawn_reaches_the_host_with_its_origin_and_the_handle_comes_back_test() {
  let seen = process.new_subject()
  let port = spawning(hosting(seen, 0))
  assert orchestrator_port.ask_spawn(
      port,
      parent(),
      call_site(),
      1,
      ["bash", "grep"],
      request(),
      1000,
    )
    == Ok(Ok(spawned()))
  assert process.receive(seen, 0)
    == Ok(
      "spawn "
      <> own_node()
      <> " s1/main step-1 depth 1 tools bash,grep run the suite",
    )
}

pub fn a_join_reaches_the_host_and_answers_one_entry_per_handle_test() {
  let seen = process.new_subject()
  let port = spawning(hosting(seen, 0))
  let other = agent.Handle(..handle(), strand: "sub:^main/second-2")
  assert orchestrator_port.ask_join(
      port,
      parent(),
      [handle(), other],
      25_000,
      1000,
    )
    == Ok(Ok([ready(handle()), ready(other)]))
  assert process.receive(seen, 0)
    == Ok("join " <> own_node() <> " main 2 within 25000")
}

pub fn a_run_end_reaches_the_host_and_answers_the_count_stopped_test() {
  let seen = process.new_subject()
  let port = spawning(hosting(seen, 0))
  assert orchestrator_port.ask_run_ended(port, parent(), operation(), 1000)
    == Ok(Ok(2))
  assert process.receive(seen, 0)
    == Ok(
      "run_ended " <> own_node() <> " main " <> ids.op_id_to_string(operation()),
    )
}

pub fn a_release_reaches_the_host_and_answers_the_count_stopped_test() {
  let seen = process.new_subject()
  let port = spawning(hosting(seen, 0))
  assert orchestrator_port.ask_release(port, parent(), 1000) == Ok(Ok(3))

  // The host is told which node asked and which parent session is released, and
  // the strand the message carried is not part of what it is told.
  assert process.receive(seen, 0)
    == Ok("release " <> own_node() <> " " <> parent().session)
}

pub fn a_refusal_from_the_host_is_the_answer_to_each_message_test() {
  let refusing =
    orchestrator_port.SpawnHost(
      spawn: fn(_origin, _site, _depth, _tools, _asked) {
        Error(remote_spawn.CapReached(cap: remote_spawn.MaxSessions, limit: 4))
      },
      join: fn(_origin, _handles, _within_ms) {
        Error(remote_spawn.StoreFailure(reason: "the store failed"))
      },
      run_ended: fn(_origin, _ended) { Error(remote_spawn.ParentRunEnded) },
      release: fn(_origin) {
        Error(remote_spawn.StoreFailure(reason: "the store failed"))
      },
      send: fn(_origin, _child, _id, _text) {
        Error(remote_spawn.StoreFailure(reason: "the store failed"))
      },
      resolve: fn(_origin, _child, _id, _decision, _seq, _decider) {
        Error(remote_spawn.StoreFailure(reason: "the store failed"))
      },
      history: fn(_origin, _child, _cursor, _limit) {
        Error(remote_spawn.TranscriptHidden)
      },
    )
  let port = spawning(refusing)
  assert orchestrator_port.ask_spawn(
      port,
      parent(),
      call_site(),
      0,
      [],
      request(),
      1000,
    )
    == Ok(
      Error(remote_spawn.CapReached(cap: remote_spawn.MaxSessions, limit: 4)),
    )
  assert orchestrator_port.ask_join(port, parent(), [handle()], 25_000, 1000)
    == Ok(Error(remote_spawn.StoreFailure(reason: "the store failed")))
  assert orchestrator_port.ask_run_ended(port, parent(), operation(), 1000)
    == Ok(Error(remote_spawn.ParentRunEnded))
  assert orchestrator_port.ask_release(port, parent(), 1000)
    == Ok(Error(remote_spawn.StoreFailure(reason: "the store failed")))
}

pub fn a_slow_answer_to_any_of_the_three_does_not_keep_a_lookup_waiting_test() {
  let seen = process.new_subject()

  // Each answer takes a second, as opening a session or waiting on a child
  // would. All three are in flight together.
  let port = spawning(hosting(seen, 1000))
  let spawns = process.new_subject()
  let joins = process.new_subject()
  let ends = process.new_subject()
  let _spawner =
    process.spawn(fn() {
      process.send(
        spawns,
        orchestrator_port.ask_spawn(
          port,
          parent(),
          call_site(),
          0,
          [],
          request(),
          5000,
        ),
      )
    })
  let _joiner =
    process.spawn(fn() {
      process.send(
        joins,
        orchestrator_port.ask_join(port, parent(), [handle()], 25_000, 5000),
      )
    })
  let _ender =
    process.spawn(fn() {
      process.send(
        ends,
        orchestrator_port.ask_run_ended(port, parent(), operation(), 5000),
      )
    })

  // While they run, ownership is answered inside its 500 ms deadline, half of
  // what each of them takes. A port that ran any of them in its own turn would
  // let that deadline pass in silence.
  process.sleep(100)
  assert orchestrator_port.ask(port, "owned-1", 500) == Ok(Owned)

  // None has answered yet, and then each does.
  assert process.receive(spawns, 0) == Error(Nil)
  assert process.receive(joins, 0) == Error(Nil)
  assert process.receive(ends, 0) == Error(Nil)
  assert process.receive(spawns, 5000) == Ok(Ok(Ok(spawned())))
  assert process.receive(joins, 5000) == Ok(Ok(Ok([ready(handle())])))
  assert process.receive(ends, 5000) == Ok(Ok(Ok(2)))
}

pub fn a_crashing_host_is_silence_and_the_port_serves_on_test() {
  let crashing =
    orchestrator_port.SpawnHost(
      spawn: fn(_origin, _site, _depth, _tools, _asked) {
        panic as "the spawn host fails"
      },
      join: fn(_origin, _handles, _within_ms) { panic as "the spawn host fails" },
      run_ended: fn(_origin, _ended) { panic as "the spawn host fails" },
      release: fn(_origin) { panic as "the spawn host fails" },
      send: fn(_origin, _child, _id, _text) { panic as "the spawn host fails" },
      resolve: fn(_origin, _child, _id, _decision, _seq, _decider) {
        panic as "the spawn host fails"
      },
      history: fn(_origin, _child, _cursor, _limit) {
        panic as "the spawn host fails"
      },
    )
  let port = spawning(crashing)

  // No reply at all, so each asker's wait ends at its own bound. A spawn that
  // met this is resent by its sender, and the receiver answers the resend with
  // the child the call site already made.
  assert orchestrator_port.ask_spawn(
      port,
      parent(),
      call_site(),
      0,
      [],
      request(),
      200,
    )
    == Error(Nil)
  assert orchestrator_port.ask_join(port, parent(), [handle()], 25_000, 200)
    == Error(Nil)
  assert orchestrator_port.ask_run_ended(port, parent(), operation(), 200)
    == Error(Nil)
  assert orchestrator_port.ask_release(port, parent(), 200) == Error(Nil)

  // The failed messages did not stop the port.
  assert orchestrator_port.ask(port, "owned-1", answers_within_ms) == Ok(Owned)
}

// --- what a child sends its parent, and a send into a child (phase 2) ---------

// A child host that records what it was asked, with the origin, and admits
// everything from the node `trusted`.
fn receiving(
  seen: process.Subject(String),
  trusted: String,
  pause_ms: Int,
) -> orchestrator_port.ChildHost {
  orchestrator_port.ChildHost(
    mail: fn(origin, child, message_id, text) {
      process.send(
        seen,
        "mail "
          <> origin.node
          <> " "
          <> origin.parent.session
          <> "/"
          <> origin.parent.strand
          <> " "
          <> child.strand
          <> " "
          <> message_id
          <> " "
          <> text,
      )
      process.sleep(pause_ms)
      case origin.node == trusted {
        True -> Ok(remote_mail.Delivered)
        False -> Error(remote_mail.OriginMismatch)
      }
    },
    progress: fn(origin, child, glance) {
      process.send(
        seen,
        "progress " <> origin.node <> " " <> child.strand <> " " <> glance.title,
      )
      process.sleep(pause_ms)
      case origin.node == trusted {
        True -> Ok(Nil)
        False -> Error(remote_mail.OriginMismatch)
      }
    },
    escalation: fn(origin, child, record) {
      process.send(
        seen,
        "escalation "
          <> origin.node
          <> " "
          <> child.strand
          <> " "
          <> record.escalation_id
          <> " "
          <> int.to_string(record.seq),
      )
      process.sleep(pause_ms)
      case origin.node == trusted {
        True -> Ok(Nil)
        False -> Error(remote_mail.OriginMismatch)
      }
    },
  )
}

// A port under a private name that serves a child's messages with `host`.
fn receiving_port(host: orchestrator_port.ChildHost) -> Address(Message) {
  let name = process.new_name("orchestrator_port")
  let assert Ok(_) =
    orchestrator_port.start_with(
      name,
      held,
      fn(_session, _command) { Error(orchestrator_port.peer_unserved) },
      fn(_session) { Error("not_found") },
      orchestrator_port.declining(),
      orchestrator_port.refusing_spawns(),
      host,
      orchestrator_port.unheld,
      orchestrator_port.unreported(),
    )
    as "the port starts under its name"
  address.Address(node: node.self(), name:)
}

fn a_glance() -> glance.Glance {
  glance.Glance(
    operation: ids.op_id_to_string(operation()),
    title: "running the suite",
    summary: "",
    at: 1000,
    tokens: 0,
  )
}

pub fn a_send_reaches_the_host_with_its_origin_and_answers_the_landing_test() {
  let seen = process.new_subject()
  let port = spawning(hosting(seen, 0))
  assert orchestrator_port.ask_send(
      port,
      parent(),
      handle(),
      "m1",
      "also the tests",
      1000,
    )
    == Ok(Ok(remote_mail.encode_landing(remote_mail.Admitted)))
  assert process.receive(seen, 0)
    == Ok(
      "send "
      <> own_node()
      <> " main sub:^main/run-the-suite-1 m1 also the tests",
    )
}

pub fn a_daemon_with_no_orchestrators_refuses_a_childs_mail_and_progress_test() {
  let port = started()
  assert orchestrator_port.ask_mail(
      port,
      parent(),
      handle(),
      "m1",
      "done",
      1000,
    )
    == Ok(Error(remote_mail.OriginMismatch))
  assert orchestrator_port.ask_progress(
      port,
      parent(),
      handle(),
      a_glance(),
      1000,
    )
    == Ok(Error(remote_mail.OriginMismatch))

  // It still answers the question it always answered.
  assert orchestrator_port.ask(port, "owned-1", answers_within_ms) == Ok(Owned)
}

pub fn a_childs_mail_and_progress_reach_the_host_with_their_origin_test() {
  let seen = process.new_subject()
  let port = receiving_port(receiving(seen, own_node(), 0))
  assert orchestrator_port.ask_mail(
      port,
      parent(),
      handle(),
      "m1",
      "found it",
      1000,
    )
    == Ok(Ok(remote_mail.Delivered))
  assert process.receive(seen, 0)
    == Ok(
      "mail " <> own_node() <> " s1/main sub:^main/run-the-suite-1 m1 found it",
    )
  assert orchestrator_port.ask_progress(
      port,
      parent(),
      handle(),
      a_glance(),
      1000,
    )
    == Ok(Ok(Nil))
  assert process.receive(seen, 0)
    == Ok(
      "progress "
      <> own_node()
      <> " sub:^main/run-the-suite-1 running the suite",
    )
}

pub fn a_message_from_an_untrusted_node_is_refused_as_an_origin_mismatch_test() {
  let seen = process.new_subject()
  let port = receiving_port(receiving(seen, "somebody@else", 0))
  assert orchestrator_port.ask_mail(
      port,
      parent(),
      handle(),
      "m1",
      "found it",
      1000,
    )
    == Ok(Error(remote_mail.OriginMismatch))
  assert orchestrator_port.ask_progress(
      port,
      parent(),
      handle(),
      a_glance(),
      1000,
    )
    == Ok(Error(remote_mail.OriginMismatch))
}

pub fn a_slow_child_host_does_not_keep_a_lookup_waiting_test() {
  let seen = process.new_subject()
  let port = receiving_port(receiving(seen, own_node(), 1500))

  // The mail is still being admitted when the lookup is asked, and the lookup is
  // answered at once: each runs apart from the port.
  let late = process.new_subject()
  let _asker =
    process.spawn(fn() {
      process.send(
        late,
        orchestrator_port.ask_mail(port, parent(), handle(), "m1", "slow", 5000),
      )
    })
  assert process.receive(seen, 1000) |> result.is_ok
  assert orchestrator_port.ask(port, "owned-1", answers_within_ms) == Ok(Owned)
  assert process.receive(late, 5000) == Ok(Ok(Ok(remote_mail.Delivered)))
}

pub fn a_crashing_child_host_is_silence_and_the_port_serves_on_test() {
  let crashing =
    orchestrator_port.ChildHost(
      mail: fn(_origin, _child, _id, _text) { panic as "the child host fails" },
      progress: fn(_origin, _child, _glance) { panic as "the child host fails" },
      escalation: fn(_origin, _child, _record) {
        panic as "the child host fails"
      },
    )
  let port = receiving_port(crashing)
  assert orchestrator_port.ask_mail(port, parent(), handle(), "m1", "x", 200)
    == Error(Nil)
  assert orchestrator_port.ask_progress(
      port,
      parent(),
      handle(),
      a_glance(),
      200,
    )
    == Error(Nil)
  assert orchestrator_port.ask(port, "owned-1", answers_within_ms) == Ok(Owned)
}

// --- report ------------------------------------------------------------------

// A port whose daemon reports what `reads` says.
fn reporting(reads: orchestrator_port.Reads) -> Address(Message) {
  let name = process.new_name("orchestrator_port")
  let assert Ok(_) =
    orchestrator_port.start_with(
      name,
      held,
      fn(_session, _command) { Error(orchestrator_port.peer_unserved) },
      fn(_session) { Error("not_found") },
      orchestrator_port.declining(),
      orchestrator_port.refusing_spawns(),
      orchestrator_port.refusing_children(),
      orchestrator_port.unheld,
      reads,
    )
    as "the port starts under its name"
  address.Address(node: node.self(), name:)
}

fn identity() -> node_report.NodeReport {
  node_report.bare(
    node: "box@10.0.0.2",
    build_version: "0.3.0",
    build_commit: "abc123",
    epoch: "epoch-1",
    started_ms: 1000,
    now_ms: 9000,
  )
}

pub fn a_report_is_what_the_daemon_supplies_test() {
  let executor =
    node_report.ExecutorFacts(
      protocol: 3,
      scopes: node_report.ScopeCounts(
        open: 1,
        closing: 0,
        closed_clean: 0,
        closed_unknown: 0,
      ),
      scope_limit: 16,
      unclean: [],
      ledger_bytes: 0,
      ledger_limit: 1024,
      unacknowledged: 0,
      platform: "linux/x86_64",
      observed: None,
      workspaces: ["proj"],
      worktrees: option.None,
    )
  let supplied = node_report.NodeReport(..identity(), executor: Some(executor))
  let port =
    reporting(
      orchestrator_port.Reads(..orchestrator_port.unreported(), report: fn() {
        supplied
      }),
    )
  assert orchestrator_port.ask_report(port, answers_within_ms) == Ok(supplied)
}

pub fn an_executor_only_node_reports_no_orchestrator_facts_test() {
  let supplied = identity()
  let port =
    reporting(
      orchestrator_port.Reads(..orchestrator_port.unreported(), report: fn() {
        supplied
      }),
    )
  let assert Ok(report) = orchestrator_port.ask_report(port, answers_within_ms)
  assert report.orchestrator == None
  assert report.directory == None
}

pub fn a_port_with_nothing_to_report_says_only_who_it_is_test() {
  let name = process.new_name("orchestrator_port")
  let assert Ok(_) = orchestrator_port.start(name, held)
    as "the port starts under its name"
  let port = address.Address(node: node.self(), name:)
  let assert Ok(report) = orchestrator_port.ask_report(port, answers_within_ms)
  assert report.node == atom.to_string(node.name(node.self()))
  assert report.orchestrator == None
  assert report.executor == None
  assert report.directory == None
}

// --- a page of a child's transcript (protocol-change/090) ---------------------

// A spawner table for this node, whose `transcript` key is `transcript`. The
// table is parsed and then moved to the node this process runs on, as
// `agency_test` does, since a test VM's node cannot be named in a table.
fn spawners_with(transcript: String) -> List(spawners.Spawner) {
  let assert Ok(configured) = spawners.parse("[distribution]
node = \"box@100.64.0.9\"
ca = \"/etc/loom/ca.pem\"
certificate = \"/etc/loom/cert.pem\"
key = \"/etc/loom/key.pem\"
cookie = \"/home/loom/.erlang.cookie\"

[[distribution.peers]]
node = \"laptop@100.64.0.5\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000001\"

[profiles.cheap-review.roles]
main = [\"fast\"]

[spawners.laptop]
node = \"laptop@100.64.0.5\"
directory = \"/srv/loom/scratch\"
profile = \"cheap-review\"
" <> transcript <> "\n") as "the spawner table parses"
  list.map(configured, fn(spawner) {
    spawners.Spawner(..spawner, node: own_node())
  })
}

pub fn a_history_reaches_the_host_with_its_origin_cursor_and_limit_test() {
  let seen = process.new_subject()
  let port = spawning(hosting(seen, 0))
  assert orchestrator_port.ask_history(port, parent(), handle(), 41, 20, 1000)
    == Ok(Ok(json.Object([#("child", json.String(handle().strand))])))
  assert process.receive(seen, 0)
    == Ok(
      "history "
      <> own_node()
      <> " main sub:^main/run-the-suite-1 before 41 limit 20",
    )
}

// A spawner whose table says nothing about transcripts keeps them on the box.
// The read is refused before any session is looked for, so neither the
// function that makes a session nor the one that finds one is asked.
pub fn a_history_is_refused_when_the_spawner_keeps_transcripts_test() {
  let host =
    daemon_main.spawn_host(
      spawners_with(""),
      fn(_, _) { panic as "a read must not make a session" },
      fn(_, _) { panic as "a read must not release a session" },
      fn(_, _) { panic as "a hidden transcript must not be looked for" },
    )
  let port = spawning(host)
  assert orchestrator_port.ask_history(port, parent(), handle(), 0, 50, 1000)
    == Ok(Error(remote_spawn.TranscriptHidden))

  // Saying so explicitly is the same.
  let explicit =
    daemon_main.spawn_host(
      spawners_with("transcript = \"hidden\""),
      fn(_, _) { panic as "a read must not make a session" },
      fn(_, _) { panic as "a read must not release a session" },
      fn(_, _) { panic as "a hidden transcript must not be looked for" },
    )
  assert orchestrator_port.ask_history(
      spawning(explicit),
      parent(),
      handle(),
      0,
      50,
      1000,
    )
    == Ok(Error(remote_spawn.TranscriptHidden))
}

// A read for a parent the box holds no open session for is refused, and the
// function that makes a session is never asked: a `ChildHistory` that arrives
// before its `Spawn`, or after the session closed, creates nothing.
pub fn a_history_never_creates_a_session_test() {
  let looked = process.new_subject()
  let host =
    daemon_main.spawn_host(
      spawners_with("transcript = \"visible\""),
      fn(_, _) { panic as "a read must not make a session" },
      fn(_, _) { panic as "a read must not release a session" },
      fn(spawner, asked) {
        process.send(looked, #(spawner.name, asked))
        Ok(None)
      },
    )
  let port = spawning(host)
  let assert Ok(Error(remote_spawn.InvalidArgument(reason:))) =
    orchestrator_port.ask_history(port, parent(), handle(), 0, 50, 1000)
    as "the read must be refused, not left unanswered"
  assert string.contains(reason, "is not a child")
  assert process.receive(looked, 0) == Ok(#("laptop", parent()))
}

pub fn a_report_that_fails_is_silence_and_the_port_serves_on_test() {
  let port =
    reporting(
      orchestrator_port.Reads(..orchestrator_port.unreported(), report: fn() {
        panic as "the report fails"
      }),
    )

  // No reply at all, so the asker's wait ends at its own bound and is never
  // read as a node with nothing to say.
  assert orchestrator_port.ask_report(port, 200)
    == Error(orchestrator_port.AskTimedOut)

  // The failed report did not stop the port.
  assert orchestrator_port.ask(port, "owned-1", answers_within_ms) == Ok(Owned)
}

// --- sessions ----------------------------------------------------------------

// A port over a real registry, listing what `catalogue_page` reads from it. The
// executor `box` is listed on a node, so a row placed on it names that node.
fn listing() -> #(
  Address(Message),
  manager.Manager(String),
  catalogue.Catalogue,
  String,
) {
  let #(registry, store, directory) = held_catalogue.start()
  let listed = roster.fixed([executors.plain("box", "loom@box.example.net")])
  let port =
    reporting(
      orchestrator_port.Reads(
        ..orchestrator_port.unreported(),
        sessions: catalogue_page.from_catalogue(registry, listed),
      ),
    )
  #(port, registry, store, directory)
}

fn ids_of(page: listed_sessions.Page) -> List(String) {
  list.map(page.rows, fn(row) { row.session_id })
}

pub fn a_port_with_no_catalogue_lists_an_empty_page_test() {
  let name = process.new_name("orchestrator_port")
  let assert Ok(_) = orchestrator_port.start(name, held)
    as "the port starts under its name"
  let port = address.Address(node: node.self(), name:)
  assert orchestrator_port.ask_sessions(port, "", 20, answers_within_ms)
    == Ok(listed_sessions.empty())
}

pub fn a_page_names_the_session_and_its_executor_node_test() {
  let #(port, _registry, store, directory) = listing()
  let _ = held_catalogue.registered_n(store, directory, "box", 1)
  let _ = held_catalogue.registered_n(store, directory, "gone", 1)
  let assert Ok(page) =
    orchestrator_port.ask_sessions(port, "", 20, answers_within_ms)
  assert page.more == Last

  // The row on `box` carries the node the table lists. The row on an executor
  // no row lists keeps its key and has no node to attribute it to.
  let nodes =
    list.map(page.rows, fn(row) { #(row.executor, row.executor_node) })
    |> list.sort(fn(a, b) {
      string.compare(string.inspect(a), string.inspect(b))
    })
  assert nodes
    == [
      #(Some("box"), Some("loom@box.example.net")),
      #(Some("gone"), None),
    ]
  let assert [row, ..] = page.rows
  assert row.status == listed_sessions.Saved
  assert row.pool == None
}

pub fn pages_follow_one_another_in_identity_order_test() {
  let #(port, _registry, store, directory) = listing()
  let all =
    held_catalogue.registered_n(store, directory, "box", 5)
    |> list.sort(string.compare)
  let assert Ok(first) = orchestrator_port.ask_sessions(port, "", 2, 1000)
  assert ids_of(first) == list.take(all, 2)
  assert first.more == Further

  let assert Ok(second) =
    orchestrator_port.ask_sessions(port, last_of(first), 2, 1000)
  assert ids_of(second) == list.take(list.drop(all, 2), 2)
  assert second.more == Further

  // The last page holds the one row left, and the page that ends exactly at the
  // end of the catalogue is `Last`, not one more `Further`.
  let assert Ok(third) =
    orchestrator_port.ask_sessions(port, last_of(second), 2, 1000)
  assert ids_of(third) == list.drop(all, 4)
  assert third.more == Last
}

fn last_of(page: listed_sessions.Page) -> String {
  let assert Ok(row) = list.last(page.rows) as "the page has rows"
  row.session_id
}

pub fn a_page_that_fills_exactly_is_last_test() {
  let #(port, _registry, store, directory) = listing()
  let _ = held_catalogue.registered_n(store, directory, "box", 3)
  let assert Ok(page) = orchestrator_port.ask_sessions(port, "", 3, 1000)
  assert list.length(page.rows) == 3
  assert page.more == Last
}

pub fn moving_and_moved_sessions_are_not_listed_test() {
  let #(port, _registry, store, directory) = listing()
  let all =
    held_catalogue.registered_n(store, directory, "box", 4)
    |> list.sort(string.compare)
  let assert [moving, moved, ..kept] = all
  let assert Ok(_) =
    catalogue.begin_move(store, moving, op: "op-1", to: "bravo")
  let assert Ok(_) = catalogue.begin_move(store, moved, op: "op-2", to: "bravo")
  let assert Ok(_) = catalogue.finish_move(store, moved, op: "op-2")

  // Another orchestrator lists both, so this one lists neither: no identity
  // appears on two.
  let assert Ok(page) = orchestrator_port.ask_sessions(port, "", 20, 1000)
  assert ids_of(page) == kept
  assert page.more == Last
}

pub fn a_page_skips_across_a_whole_catalogue_page_of_moved_sessions_test() {
  let #(port, _registry, store, directory) = listing()
  let count = catalogue.page_limit + 5
  let all =
    held_catalogue.registered_n(store, directory, "box", count)
    |> list.sort(string.compare)
  let #(away, kept) = list.split(all, catalogue.page_limit)
  list.each(away, fn(id) {
    let assert Ok(_) = catalogue.begin_move(store, id, op: "op", to: "bravo")
    let assert Ok(_) = catalogue.finish_move(store, id, op: "op")
    Nil
  })

  // The first catalogue page holds only handed-away sessions, so the walk reads
  // on to the second for the rows it is asked for.
  let assert Ok(first) = orchestrator_port.ask_sessions(port, "", 2, 1000)
  assert ids_of(first) == list.take(kept, 2)
  assert first.more == Further

  let assert Ok(rest) =
    orchestrator_port.ask_sessions(port, last_of(first), 100, 1000)
  assert ids_of(rest) == list.drop(kept, 2)
  assert rest.more == Last
}

pub fn the_page_size_is_clamped_to_one_through_the_most_test() {
  let #(port, _registry, store, directory) = listing()
  let _ = held_catalogue.registered_n(store, directory, "", 3)
  let assert Ok(least) = orchestrator_port.ask_sessions(port, "", 0, 1000)
  assert list.length(least.rows) == 1
  assert least.more == Further

  let assert Ok(most) = orchestrator_port.ask_sessions(port, "", 5000, 1000)
  assert list.length(most.rows) == 3
  assert most.more == Last
}

pub fn a_catalogue_that_cannot_be_read_is_silence_and_not_an_empty_page_test() {
  let #(port, registry, _store, _directory) = listing()
  manager.shutdown(registry)
  assert orchestrator_port.ask_sessions(port, "", 20, 1000) == Error(Nil)

  // The failed read did not stop the port.
  assert orchestrator_port.ask(port, "owned-1", answers_within_ms) == Ok(Owned)
}

// --- a child's request for more authority, and the decision (protocol-change/089)

fn a_request() -> protocol.EscalationRecord {
  protocol.EscalationRecord(
    escalation_id: "policy-ab",
    op: "op-1",
    strand: "sub:^main/run-the-suite-1",
    status: "pending",
    tool: "bash",
    action: "d1",
    preview: "make",
    asked: 1,
    denial: None,
    seq: 3,
    origin: None,
    placement: None,
    admitted: None,
  )
}

pub fn a_daemon_with_no_orchestrators_refuses_a_childs_request_test() {
  let port = started()
  assert orchestrator_port.ask_escalation(
      port,
      parent(),
      handle(),
      a_request(),
      1000,
    )
    == Ok(Error(remote_mail.OriginMismatch))
}

pub fn a_childs_request_reaches_the_host_with_its_origin_test() {
  let seen = process.new_subject()
  let port = receiving_port(receiving(seen, own_node(), 0))
  assert orchestrator_port.ask_escalation(
      port,
      parent(),
      handle(),
      a_request(),
      1000,
    )
    == Ok(Ok(Nil))
  assert process.receive(seen, 0)
    == Ok(
      "escalation " <> own_node() <> " sub:^main/run-the-suite-1 policy-ab 3",
    )
}

pub fn a_request_from_an_untrusted_node_is_refused_as_an_origin_mismatch_test() {
  let seen = process.new_subject()
  let port = receiving_port(receiving(seen, "somebody@else", 0))
  assert orchestrator_port.ask_escalation(
      port,
      parent(),
      handle(),
      a_request(),
      1000,
    )
    == Ok(Error(remote_mail.OriginMismatch))
}

pub fn a_decision_reaches_the_spawn_host_with_its_origin_and_answers_test() {
  let seen = process.new_subject()
  let port = spawning(hosting(seen, 0))
  assert orchestrator_port.ask_resolve(
      port,
      parent(),
      handle(),
      "policy-ab",
      remote_escalation.Deny,
      3,
      remote_escalation.Decider(principal: "ab12", name: "Ola"),
      1000,
    )
    == Ok(Ok(remote_escalation.Forgotten))
  assert process.receive(seen, 0)
    == Ok(
      "resolve "
      <> own_node()
      <> " main sub:^main/run-the-suite-1 policy-ab Deny 3 Ola",
    )
}

pub fn a_daemon_that_accepts_no_spawns_refuses_a_decision_test() {
  let port = started()
  let assert Ok(Error(remote_spawn.UnknownSpawner(..))) =
    orchestrator_port.ask_resolve(
      port,
      parent(),
      handle(),
      "policy-ab",
      remote_escalation.Deny,
      3,
      remote_escalation.Decider(principal: "ab12", name: "Ola"),
      1000,
    )
}
