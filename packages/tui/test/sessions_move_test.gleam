//// `loom sessions move <id> --to <orchestrator>` hands a session to another
//// orchestrator (protocol-change/078, phase 5). The launcher parses and refuses
//// what it can before any daemon is started, the control protocol carries the
//// command and its answer, and the refusals a move meets are worded for the
//// terminal.

import gleam/option.{Some}
import gleam/string
import tui
import tui/daemon
import tui/daemon/protocol
import tui/daemon/selection

const session = "0198c0de-0000-7000-8000-000000000001"

pub fn the_move_names_a_session_and_a_destination_test() {
  assert tui.launch_sessions(["move", session, "--to", "laptop"])
    == Ok(tui.MoveRegistration(session, "laptop"))

  // The shared local options compose with it in either order.
  assert tui.launch_sessions([
      "move", session, "--to", "laptop", "--state-dir", "/tmp/x",
    ])
    == Ok(tui.MoveRegistration(session, "laptop"))
  assert tui.launch_sessions([
      "move",
      session,
      "--state-dir",
      "/tmp/x",
      "--to",
      "laptop",
    ])
    == Ok(tui.MoveRegistration(session, "laptop"))
}

pub fn a_move_without_its_session_or_destination_is_refused_with_the_usage_test() {
  let assert Error(no_session) = tui.launch_sessions(["move"])
  assert string.contains(no_session, "sessions move needs a session id")
  assert string.contains(no_session, "loom sessions move <session-id> --to")
  let assert Error(no_destination) = tui.launch_sessions(["move", session])
  assert string.contains(no_destination, "needs --to <orchestrator>")
  let assert Error(dangling) = tui.launch_sessions(["move", session, "--to"])
  assert string.contains(dangling, "--to")
}

pub fn a_destination_that_is_not_an_orchestrator_name_is_refused_here_test() {
  // The daemon's table is keyed by names, so an address or a path is a mistake
  // the launcher can name before it starts anything.
  let assert Error(address) =
    tui.launch_sessions([
      "move", session, "--to", "wss://laptop.example.com/v2/control",
    ])
  assert string.contains(address, "--to must be the name of an orchestrator")
  let assert Error(upper) =
    tui.launch_sessions(["move", session, "--to", "Laptop"])
  assert string.contains(upper, "Laptop")
}

pub fn the_usage_documents_move_and_what_it_returns_test() {
  let assert Error(usage) = tui.launch_sessions(["bogus"])
  assert string.contains(
    usage,
    "loom sessions move <session-id> --to <orchestrator>",
  )
  assert string.contains(usage, "returns once the")
}

pub fn the_command_is_a_mutation_encoded_with_the_epoch_and_the_destination_test() {
  assert protocol.name(protocol.MoveSession(session, "laptop"))
    == "sessions.move"
  assert protocol.mutates(protocol.MoveSession(session, "laptop"))
  assert protocol.encode(
      3,
      protocol.MoveSession(session, "laptop"),
      protocol.Epoch("current"),
    )
    == Ok(
      "{\"v\":2,\"id\":3,\"cmd\":\"sessions.move\",\"body\":{\"epoch\":\"current\",\"session_id\":\""
      <> session
      <> "\",\"to\":\"laptop\"}}",
    )
  let assert Error(_) =
    protocol.encode(
      3,
      protocol.MoveSession("not-an-id", "laptop"),
      protocol.Epoch("current"),
    )
    as "the session is a canonical identity"
}

pub fn the_answer_names_the_move_the_daemon_accepted_test() {
  assert protocol.decode(
      "{\"v\":2,\"reply_to\":3,\"event\":\"sessions.move\",\"body\":{\"session_id\":\""
      <> session
      <> "\",\"op\":\"0192f3c1-7b0e-7d2a-9c11-4f5a6b7c8d9e\",\"to\":\"laptop\",\"state\":\"moving\"}}",
    )
    == Ok(protocol.Answer(
      3,
      "sessions.move",
      protocol.MovedReply(
        session,
        "0192f3c1-7b0e-7d2a-9c11-4f5a6b7c8d9e",
        "laptop",
      ),
    ))
  let assert Error(_) =
    protocol.decode(
      "{\"v\":2,\"reply_to\":3,\"event\":\"sessions.move\",\"body\":{\"session_id\":\""
      <> session
      <> "\",\"to\":\"laptop\"}}",
    )
    as "an answer with no operation is not an answer"
}

pub fn a_move_toward_a_session_that_already_left_prints_where_it_went_test() {
  // The daemon answers `not_owner` with the orchestrator, and the terminal words
  // the launch that reaches it, as for any redirect.
  let refusal =
    protocol.decode(
      "{\"v\":2,\"reply_to\":3,\"event\":\"error\",\"body\":{\"code\":\"not_owner\",\"message\":\"m\",\"orchestrator\":\"laptop\",\"address\":\"wss://laptop.example.com:8443/v2/control\"}}",
    )
  assert refusal
    == Ok(protocol.Redirected(
      Some(3),
      protocol.NotOwner(
        "laptop",
        Some("wss://laptop.example.com:8443/v2/control"),
      ),
    ))
  let words =
    selection.failure_for(
      session,
      daemon.Redirected(protocol.NotOwner(
        "laptop",
        Some("wss://laptop.example.com:8443/v2/control"),
      )),
    )
  assert string.contains(words, "is owned by orchestrator laptop")
}

pub fn the_other_refusals_a_move_meets_keep_their_code_and_words_test() {
  let words = fn(code, message) {
    selection.failure_for(session, daemon.Refused(code, message))
  }
  assert words("orchestrator_unknown", "request refused")
    == "orchestrator_unknown: request refused"
  assert words("not_movable", "request refused")
    == "not_movable: request refused"
  assert words("conflict", "request refused") == "conflict: request refused"
}
