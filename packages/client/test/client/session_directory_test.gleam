//// The session directory decides who owns a session from the local catalogue
//// and the replies of the configured orchestrators (protocol-change/078,
//// phase 3). The policy is pure, and the fan-out around it is bounded by a
//// deadline.

import client/orchestrators.{type Orchestrator}
import client/remote/orchestrator_port.{NotOwned, Owned}
import client/session_directory.{Elsewhere, Here, Unknown, Unreachable}
import client/session_move
import core/json
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/string
import host/bootstrap

const id = "0198c0de-0000-7000-8000-000000000001"

fn beta() -> Orchestrator {
  orchestrators.Orchestrator(
    name: "beta",
    node: "beta@10.0.0.2",
    address: Some("wss://beta.example.com/v2/control"),
  )
}

fn gamma() -> Orchestrator {
  orchestrators.plain("gamma", "gamma@10.0.0.3")
}

// --- the policy -----------------------------------------------------------

pub fn nobody_asked_is_unknown_test() {
  assert session_directory.decide([]) == Error(Unknown)
}

pub fn every_peer_answering_not_held_is_unknown_test() {
  assert session_directory.decide([
      #(beta(), Ok(NotOwned)),
      #(gamma(), Ok(NotOwned)),
    ])
    == Error(Unknown)
}

pub fn the_peer_that_holds_the_session_is_the_owner_test() {
  assert session_directory.decide([
      #(beta(), Ok(NotOwned)),
      #(gamma(), Ok(Owned)),
    ])
    == Ok(Elsewhere(gamma()))
}

pub fn a_positive_answer_outweighs_a_silent_peer_test() {
  // A holder is proof. The peer that did not answer cannot contradict it.
  assert session_directory.decide([#(beta(), Error(Nil)), #(gamma(), Ok(Owned))])
    == Ok(Elsewhere(gamma()))
}

pub fn the_first_holder_in_configuration_order_wins_test() {
  assert session_directory.decide([#(beta(), Ok(Owned)), #(gamma(), Ok(Owned))])
    == Ok(Elsewhere(beta()))
}

pub fn a_silent_peer_with_no_holder_makes_the_miss_unreachable_test() {
  // The session may live on exactly the machine that did not answer.
  assert session_directory.decide([
      #(beta(), Ok(NotOwned)),
      #(gamma(), Error(Nil)),
    ])
    == Error(Unreachable(["gamma"]))
  assert session_directory.decide([
      #(beta(), Error(Nil)),
      #(gamma(), Error(Nil)),
    ])
    == Error(Unreachable(["beta", "gamma"]))
}

// --- the directory --------------------------------------------------------

// An asker that records each question on a subject the test reads, and answers
// with `answer` for the orchestrator it was asked about.
fn recording(
  sent: process.Subject(String),
  answer: fn(Orchestrator) -> Result(orchestrator_port.Ownership, Nil),
) -> fn(Orchestrator, String) -> Result(orchestrator_port.Ownership, Nil) {
  fn(orchestrator: Orchestrator, _session: String) {
    process.send(sent, orchestrator.name)
    answer(orchestrator)
  }
}

fn questions(sent: process.Subject(String)) -> List(String) {
  case process.receive(sent, 0) {
    Ok(name) -> [name, ..questions(sent)]
    Error(Nil) -> []
  }
}

pub fn a_daemon_that_lists_no_orchestrator_asks_nobody_test() {
  let sent = process.new_subject()
  let directory =
    session_directory.peers(
      [],
      fn(_id) { Ok(NotOwned) },
      recording(sent, fn(_) { Ok(Owned) }),
    )
  assert directory.lookup(id) == Error(Unknown)
  assert questions(sent) == []
  assert session_directory.none().lookup(id) == Error(Unknown)
}

pub fn a_session_the_local_catalogue_holds_is_here_and_asks_nobody_test() {
  let sent = process.new_subject()
  let directory =
    session_directory.peers(
      [beta(), gamma()],
      fn(_id) { Ok(Owned) },
      recording(sent, fn(_) { Ok(Owned) }),
    )
  assert directory.lookup(id) == Ok(Here)
  assert questions(sent) == []
}

pub fn a_local_miss_asks_every_orchestrator_and_names_the_holder_test() {
  let sent = process.new_subject()
  let directory =
    session_directory.peers(
      [beta(), gamma()],
      fn(_id) { Ok(NotOwned) },
      recording(sent, fn(orchestrator) {
        case orchestrator.name {
          "gamma" -> Ok(Owned)
          _ -> Ok(NotOwned)
        }
      }),
    )
  assert directory.lookup(id) == Ok(Elsewhere(gamma()))
  assert list.sort(questions(sent), string.compare) == ["beta", "gamma"]
}

pub fn a_local_catalogue_that_cannot_answer_still_asks_the_peers_test() {
  let sent = process.new_subject()
  let directory =
    session_directory.peers(
      [beta()],
      fn(_id) { Error(Nil) },
      recording(sent, fn(_) { Ok(Owned) }),
    )
  assert directory.lookup(id) == Ok(Elsewhere(beta()))
}

pub fn every_peer_saying_not_held_is_unknown_and_a_silent_one_is_unreachable_test() {
  let directory = fn(
    answer: fn(Orchestrator) -> Result(orchestrator_port.Ownership, Nil),
  ) {
    session_directory.peers(
      [beta(), gamma()],
      fn(_id) { Ok(NotOwned) },
      fn(orchestrator, _session) { answer(orchestrator) },
    )
  }
  assert directory(fn(_) { Ok(NotOwned) }).lookup(id) == Error(Unknown)
  assert directory(fn(orchestrator) {
      case orchestrator.name {
        "beta" -> Error(Nil)
        _ -> Ok(NotOwned)
      }
    }).lookup(id)
    == Error(Unreachable(["beta"]))
}

pub fn the_peers_are_asked_at_once_test() {
  // Two peers that each take half a second answer inside one half-second, not
  // two: the lookup waits for the slowest peer and not for the sum.
  let directory =
    session_directory.peers(
      [beta(), gamma()],
      fn(_id) { Ok(NotOwned) },
      fn(_orchestrator, _session) {
        process.sleep(500)
        Ok(NotOwned)
      },
    )
  let started = bootstrap.monotonic_time_ms()
  assert directory.lookup(id) == Error(Unknown)
  assert bootstrap.monotonic_time_ms() - started < 900
}

pub fn a_peer_that_outlasts_the_deadline_is_silent_and_does_not_hold_the_lookup_test() {
  let directory =
    session_directory.peers(
      [beta(), gamma()],
      fn(_id) { Ok(NotOwned) },
      fn(orchestrator, _session) {
        case orchestrator.name {
          "beta" -> {
            process.sleep(session_directory.deadline_ms * 5)
            Ok(Owned)
          }
          _ -> Ok(NotOwned)
        }
      },
    )
  let started = bootstrap.monotonic_time_ms()
  assert directory.lookup(id) == Error(Unreachable(["beta"]))
  let waited = bootstrap.monotonic_time_ms() - started
  assert waited >= session_directory.deadline_ms
  assert waited < session_directory.deadline_ms * 2
}

pub fn a_question_that_crashes_is_silence_not_a_negative_test() {
  let directory =
    session_directory.peers(
      [beta()],
      fn(_id) { Ok(NotOwned) },
      fn(_orchestrator, _session) { panic as "the question crashed" },
    )
  assert directory.lookup(id) == Error(Unreachable(["beta"]))
}

// --- a session that moved away ----------------------------------------------

pub fn a_tombstone_in_the_local_catalogue_names_the_new_owner_and_asks_nobody_test() {
  let sent = process.new_subject()
  let directory =
    session_directory.peers(
      [beta(), gamma()],
      fn(_id) { Ok(orchestrator_port.Moved(to: "gamma")) },
      recording(sent, fn(_) { Ok(Owned) }),
    )

  // The catalogue's own record of the hand-over is the whole answer, so no peer
  // is asked and the configured row of the new owner is returned.
  assert directory.lookup(id) == Ok(Elsewhere(gamma()))
  assert questions(sent) == []
}

pub fn a_tombstone_naming_an_orchestrator_no_longer_listed_still_redirects_test() {
  let directory =
    session_directory.peers(
      [beta()],
      fn(_id) { Ok(orchestrator_port.Moved(to: "retired")) },
      fn(_, _) { Ok(Owned) },
    )
  let assert Ok(Elsewhere(found)) = directory.lookup(id)
  assert found.name == "retired"
  assert found.address == option.None
}

pub fn a_peers_tombstone_redirects_when_nobody_holds_the_session_test() {
  // The session went to beta, which is silent. The tombstone is proof of where
  // it went, so the asker is not left with an unreachable miss.
  assert session_directory.decide([
      #(beta(), Error(Nil)),
      #(gamma(), Ok(orchestrator_port.Moved(to: "beta"))),
    ])
    == Ok(Elsewhere(beta()))
}

pub fn a_holder_outweighs_a_tombstone_that_points_elsewhere_test() {
  // The session moved from gamma to beta and on again to a third machine
  // that answered that it holds it.
  assert session_directory.decide([
      #(beta(), Ok(Owned)),
      #(gamma(), Ok(orchestrator_port.Moved(to: "beta"))),
    ])
    == Ok(Elsewhere(beta()))
  assert session_directory.decide([
      #(beta(), Ok(orchestrator_port.Moved(to: "gamma"))),
      #(gamma(), Ok(Owned)),
    ])
    == Ok(Elsewhere(gamma()))
}

pub fn a_directory_describes_nothing_until_it_is_given_the_question_test() {
  let unreachable = Error("owner unreachable")
  let plain =
    session_directory.peers([beta()], fn(_) { Ok(NotOwned) }, fn(_, _) {
      Ok(NotOwned)
    })
  assert plain.describe(beta(), id) == unreachable
  assert session_directory.none().describe(beta(), id) == unreachable
  let asking =
    session_directory.describing(plain, fn(orchestrator, session) {
      Ok(json.String(orchestrator.name <> " " <> session))
    })
  assert asking.describe(beta(), id) == Ok(json.String("beta " <> id))

  // Describing leaves the lookup as it was.
  assert asking.lookup(id) == plain.lookup(id)
}

pub fn a_directory_activates_nothing_until_it_is_given_the_question_test() {
  let activation =
    session_move.Activation(
      session: id,
      op: "op1",
      from_node: "alpha@10.0.0.1",
      digest: "00",
      incarnation: 1,
      manifest: session_move.Manifest(
        workspace: "repo",
        name: "n",
        profile: option.None,
        model: option.None,
        executor: "box",
        pool: "",
        subtitle: option.None,
        created_at: 0,
      ),
    )
  let plain =
    session_directory.peers([beta()], fn(_) { Ok(NotOwned) }, fn(_, _) {
      Ok(NotOwned)
    })
  assert plain.activate(beta(), activation) == Error(Nil)
  assert session_directory.none().activate(beta(), activation) == Error(Nil)
  let asking =
    session_directory.activating(plain, fn(orchestrator, asked) {
      assert orchestrator == beta()
      assert asked == activation
      Ok(session_move.Accepted)
    })
  assert asking.activate(beta(), activation) == Ok(session_move.Accepted)

  // Giving a directory its question changes nothing about what it looks up.
  assert asking.lookup(id) == Error(Unknown)
}
