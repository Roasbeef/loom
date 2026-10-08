//// The orchestrator port answers one question from the catalogue: does this
//// daemon hold the session (protocol-change/078, phase 3). It answers
//// `Owned` or `NotOwned` when it could tell and says nothing when it could not,
//// so that silence is never mistaken for a negative.

import client/remote/address.{type Address}
import client/remote/orchestrator_port.{type Message, NotOwned, Owned}
import client/session_move
import gleam/erlang/node
import gleam/erlang/process
import gleam/int
import gleam/option
import host/bootstrap

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
