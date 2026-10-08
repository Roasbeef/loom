//// The orchestrator port answers one question from the catalogue: does this
//// daemon hold the session (protocol-change/078, phase 3). It answers
//// `Owned` or `NotOwned` when it could tell and says nothing when it could not,
//// so that silence is never mistaken for a negative.

import client/remote/address.{type Address}
import client/remote/orchestrator_port.{type Message, NotOwned, Owned}
import gleam/erlang/node
import gleam/erlang/process

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
