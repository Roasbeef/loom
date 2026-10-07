//// Startup diagnostics use the ordinary credited snapshot and control error
//// decoders. They carry no new command or session mutation authority.

import core/json
import core/message
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/snapshot
import session_view/snapshot_view
import tui/daemon
import tui/daemon/protocol
import tui/daemon/selection
import tui_test/pushed

pub fn startup_control_refusal_accepts_the_exact_byte_bound_test() {
  let reason = string.repeat("λ", 1024)
  assert protocol.decode(refusal(reason))
    == Ok(protocol.Refused(Some(1), "start_failed", reason))
  assert selection.failure(daemon.Refused("start_failed", reason))
    == "session startup failed: " <> reason
  let assert Error(_) = protocol.decode(refusal(reason <> "x"))
    as "the peer cannot exceed the 2048-byte diagnostic bound"
}

// A creation refused for an unusable configuration and a session that failed
// to start for the same cause read alike, instead of the first reading as an
// unknown profile.
pub fn an_unusable_configuration_reads_as_a_startup_failure_test() {
  let reason = "loom.toml: unknown key `retry2` in the top level"

  assert selection.failure(daemon.Refused("unusable_configuration", reason))
    == selection.failure(daemon.Refused("start_failed", reason))
}

pub fn extension_refusal_metadata_is_optional_but_totally_bounded_test() {
  let assert Ok(old) = snapshot_view.decode(captured(None))
    as "old daemons remain readable"
  let assert Some(old_tools) = old.tools as "tool availability remains present"
  assert old_tools.extension_refusals == []
  let reason = string.repeat("λ", 1024)
  let assert Ok(view) =
    snapshot_view.decode(
      captured(Some(json.Array(list.repeat(json.String(reason), 32)))),
    )
    as "both extension bounds are inclusive"
  let assert Some(tools) = view.tools
    as "validated diagnostics are adopted together"
  assert tools.extension_refusals == list.repeat(reason, 32)
  list.each(
    [
      json.Array(list.repeat(json.String("refused"), 33)),
      json.Array([json.String(reason <> "x")]),
      json.Array([json.Int(1)]),
      json.String("refused"),
    ],
    fn(bad) {
      let assert Error(_) = snapshot_view.decode(captured(Some(bad)))
        as "malformed diagnostic metadata cannot be partially adopted"
    },
  )
}

fn refusal(reason: String) -> String {
  json.to_string(
    json.Object([
      #("v", json.Int(2)),
      #("reply_to", json.Int(1)),
      #("event", json.String("error")),
      #(
        "body",
        json.Object([
          #("code", json.String("start_failed")),
          #("message", json.String(reason)),
        ]),
      ),
    ]),
  )
}

fn captured(refusals) {
  let assert Ok(json.Object(fields)) = json.parse(pushed.metadata())
    as "fixture metadata is valid JSON"
  let extra = case refusals {
    None -> []
    Some(value) -> [#("extension_refusals", value)]
  }
  snapshot.Captured(
    snapshot.Attachment(
      snapshot.Expected("A", "epoch", "incarnation"),
      "fixture",
      message.Origin("fixture", "Fixture"),
      snapshot.Owner,
    ),
    1,
    json.Object([
      #(
        "tool_availability",
        json.Object([
          #("registered", json.Array([])),
          #("code_mode_issue", json.Null),
          ..extra
        ]),
      ),
      ..fields
    ]),
    snapshot.Window([], 0, None),
    None,
  )
}
