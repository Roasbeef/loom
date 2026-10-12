//// The orchestrator port answers one question from the catalogue: does this
//// daemon hold the session (protocol-change/078, phase 3). It answers
//// `Owned` or `NotOwned` when it could tell and says nothing when it could not,
//// so that silence is never mistaken for a negative. It also relays the three
//// subagent messages to a spawn host (protocol-change/084), each in a task of
//// its own so that the question about ownership is never kept waiting.

import client/remote/address.{type Address}
import client/remote/orchestrator_port.{type Message, NotOwned, Owned}
import client/remote_spawn.{
  Attached, CallSite, ChildUsage, Parent, Ready, Request, Spawned,
}
import client/session_move
import core/clock
import core/ids
import core/json
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
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

pub fn a_refusal_from_the_host_is_the_answer_to_each_message_test() {
  let refusing =
    orchestrator_port.SpawnHost(
      spawn: fn(_origin, _site, _depth, _tools, _asked) {
        Error(remote_spawn.CapReached(cap: remote_spawn.MaxSessions, limit: 4))
      },
      join: fn(_origin, _handles, _within_ms) {
        Error(remote_spawn.Unimplemented)
      },
      run_ended: fn(_origin, _ended) { Error(remote_spawn.ParentRunEnded) },
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
    == Ok(Error(remote_spawn.Unimplemented))
  assert orchestrator_port.ask_run_ended(port, parent(), operation(), 1000)
    == Ok(Error(remote_spawn.ParentRunEnded))
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

  // While they run, ownership is answered inside a tenth of that. A port that
  // ran any of them in its own turn would answer this after it.
  process.sleep(100)
  let started = bootstrap.monotonic_time_ms()
  assert orchestrator_port.ask(port, "owned-1", 500) == Ok(Owned)
  assert bootstrap.monotonic_time_ms() - started < 300

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

  // The failed messages did not stop the port.
  assert orchestrator_port.ask(port, "owned-1", answers_within_ms) == Ok(Owned)
}
