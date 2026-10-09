//// A daemon that does not hold a session can say which orchestrator does
//// (protocol-change/078, phase 3). The terminal holds no credential for
//// another daemon, so it never follows the redirect: it decodes the two
//// refusals and prints the launch line that reaches the owner.

import gleam/option.{None, Some}
import gleam/string
import tui/daemon
import tui/daemon/protocol
import tui/daemon/selection

const session = "0198c0de-0000-7000-8000-000000000001"

fn error_frame(body: String) -> String {
  "{\"v\":2,\"reply_to\":4,\"event\":\"error\",\"body\":" <> body <> "}"
}

pub fn not_owner_decodes_the_owner_and_its_address_test() {
  assert protocol.decode(error_frame(
      "{\"code\":\"not_owner\",\"message\":\"this session is owned by another orchestrator\",\"orchestrator\":\"beta\",\"address\":\"wss://beta.example.com:8443/v2/control\"}",
    ))
    == Ok(protocol.Redirected(
      Some(4),
      protocol.NotOwner("beta", Some("wss://beta.example.com:8443/v2/control")),
    ))
}

pub fn not_owner_without_an_address_decodes_with_none_test() {
  assert protocol.decode(error_frame(
      "{\"code\":\"not_owner\",\"message\":\"m\",\"orchestrator\":\"beta\"}",
    ))
    == Ok(protocol.Redirected(Some(4), protocol.NotOwner("beta", None)))
}

pub fn owner_unreachable_decodes_the_silent_orchestrators_test() {
  assert protocol.decode(error_frame(
      "{\"code\":\"owner_unreachable\",\"message\":\"m\",\"orchestrators\":[\"beta\",\"gamma\"]}",
    ))
    == Ok(protocol.Redirected(
      Some(4),
      protocol.OwnerUnreachable(["beta", "gamma"]),
    ))
}

pub fn a_redirect_that_does_not_decode_is_an_ordinary_refusal_test() {
  // The frame is still a refusal with its code and words, so the operator learns
  // that the daemon refused. Only the pointer is lost.
  assert protocol.decode(error_frame(
      "{\"code\":\"not_owner\",\"message\":\"m\"}",
    ))
    == Ok(protocol.Refused(Some(4), "not_owner", "m"))
  assert protocol.decode(error_frame(
      "{\"code\":\"not_owner\",\"message\":\"m\",\"orchestrator\":\"beta\",\"address\":7}",
    ))
    == Ok(protocol.Refused(Some(4), "not_owner", "m"))
  assert protocol.decode(error_frame(
      "{\"code\":\"owner_unreachable\",\"message\":\"m\",\"orchestrators\":[]}",
    ))
    == Ok(protocol.Refused(Some(4), "owner_unreachable", "m"))
  assert protocol.decode(error_frame(
      "{\"code\":\"owner_unreachable\",\"message\":\"m\",\"orchestrators\":[1]}",
    ))
    == Ok(protocol.Refused(Some(4), "owner_unreachable", "m"))
}

pub fn the_terminal_prints_the_launch_line_for_the_owner_test() {
  let words =
    selection.failure_for(
      session,
      daemon.Redirected(protocol.NotOwner(
        "beta",
        Some("wss://beta.example.com:8443/v2/control"),
      )),
    )
  assert words
    == "session "
    <> session
    <> " is owned by orchestrator beta; connect to it with: loom --addr wss://beta.example.com:8443/v2/control --session "
    <> session
    <> " --token-file <owner token file on that host>"
}

pub fn an_owner_with_no_address_is_named_and_the_placeholder_is_shown_test() {
  let words =
    selection.failure_for(
      session,
      daemon.Redirected(protocol.NotOwner("beta", None)),
    )
  assert string.contains(words, "owned by orchestrator beta")
  assert string.contains(words, "no address in this daemon's configuration")
  assert string.contains(words, "loom --addr <its control address> --session")
}

pub fn an_unreachable_owner_names_who_did_not_answer_test() {
  let words =
    selection.failure_for(
      session,
      daemon.Redirected(protocol.OwnerUnreachable(["beta", "gamma"])),
    )
  assert string.contains(words, "did not answer: beta, gamma")
  assert string.contains(words, "retry, or connect to one of them directly")
}

pub fn the_plain_failure_wording_leaves_the_session_to_the_caller_test() {
  assert string.contains(
    selection.failure(daemon.Redirected(protocol.NotOwner("beta", None))),
    "<session-id>",
  )
  assert selection.failure_for(session, daemon.Busy)
    == selection.failure(daemon.Busy)
}
