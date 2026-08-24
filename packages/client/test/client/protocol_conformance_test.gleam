//// Golden-fixture conformance: the gateway must accept every command
//// fixture and emit byte-identical encodings of every event fixture
//// from the TUI's normative corpus
//// (`packages/tui/internal/proto/testdata/`). Each fixture is decoded
//// with the typed protocol codecs and re-encoded canonically; the
//// output must equal the file byte for byte, which pins both the
//// envelope and every nested body (entries, messages, usage in the
//// core codec vocabulary) to the Go client's expectations.

import client/protocol
import gleam/list
import gleam/string
import simplifile

const testdata = "../tui/internal/proto/testdata"

fn fixture(file: String) -> String {
  let assert Ok(text) = simplifile.read(testdata <> "/" <> file)
    as "the golden fixture corpus must be readable"
  string.trim_end(text)
}

fn roundtrip_command(file: String) -> Nil {
  let raw = fixture(file)
  let assert Ok(envelope) = protocol.decode_command(raw)
    as "every command fixture must decode"
  let encoded = protocol.encode_command(envelope)
  assert encoded == raw
  Nil
}

fn roundtrip_event(file: String) -> Nil {
  let raw = fixture(file)
  let assert Ok(envelope) = protocol.decode_event(raw)
    as "every event fixture must decode"
  let encoded = protocol.encode_event(envelope)
  assert encoded == raw
  Nil
}

pub fn command_fixtures_roundtrip_test() {
  [
    "cmd_abort.json", "cmd_approve.json", "cmd_approve_all.json",
    "cmd_catch_up.json", "cmd_compact.json", "cmd_create_strand.json",
    "cmd_deny.json", "cmd_follow_up.json", "cmd_fork.json", "cmd_navigate.json",
    "cmd_prompt.json", "cmd_set_config.json", "cmd_steer.json",
    "cmd_subscribe.json", "cmd_subscribe_resume.json",
  ]
  |> list.each(roundtrip_command)
}

pub fn event_fixtures_roundtrip_test() {
  [
    "event_entry_assistant.json", "event_entry_compaction.json",
    "event_entry_tool_result.json", "event_entry_user.json", "event_error.json",
    "event_escalation_approved.json", "event_escalation_pending.json",
    "event_op_transition.json", "event_snapshot_full.json",
    "event_snapshot_resume.json", "event_snapshot_strands.json",
    "event_strand_result_done.json", "event_strand_result_failed.json",
    "event_stream_delta_text.json", "event_stream_delta_thinking.json",
    "event_stream_delta_tool_call.json", "event_usage.json",
  ]
  |> list.each(roundtrip_event)
}

// The corpus above must be the whole corpus: a fixture added to the
// TUI's testdata without a roundtrip here would silently drop coverage.
pub fn corpus_is_complete_test() {
  let assert Ok(files) = simplifile.read_directory(testdata)
  let json_files =
    files
    |> list.filter(string.ends_with(_, ".json"))
    |> list.sort(string.compare)
  assert list.length(json_files) == 32
}

// --- strictness and tolerance ----------------------------------------------

pub fn wrong_version_refused_test() {
  let assert Error(protocol.BadEnvelope(..)) =
    protocol.decode_command("{\"v\":2,\"id\":1,\"cmd\":\"abort\",\"body\":{}}")
}

pub fn missing_id_refused_test() {
  let assert Error(protocol.BadEnvelope(..)) =
    protocol.decode_command("{\"v\":1,\"cmd\":\"abort\",\"body\":{}}")
}

pub fn malformed_frame_reported_test() {
  let assert Error(protocol.MalformedFrame(..)) =
    protocol.decode_command("{\"v\":1,")
}

pub fn unknown_command_tolerated_test() {
  let assert Ok(protocol.CommandEnvelope(
    id: 9,
    command: protocol.UnknownCommand(cmd: "future_thing", ..),
  )) =
    protocol.decode_command(
      "{\"v\":1,\"id\":9,\"cmd\":\"future_thing\",\"body\":{\"x\":1}}",
    )
}

pub fn unknown_event_tolerated_test() {
  let assert Ok(protocol.EventEnvelope(
    event: protocol.UnknownEvent(event: "future_event", ..),
    ..,
  )) =
    protocol.decode_event(
      "{\"v\":1,\"event\":\"future_event\",\"body\":{\"x\":1}}",
    )
}

pub fn unknown_fields_ignored_test() {
  let assert Ok(protocol.CommandEnvelope(
    id: 4,
    command: protocol.Abort(strand: "main"),
  )) =
    protocol.decode_command(
      "{\"v\":1,\"id\":4,\"cmd\":\"abort\","
      <> "\"body\":{\"strand\":\"main\",\"later_field\":true}}",
    )
}

pub fn bad_body_names_command_test() {
  let assert Error(protocol.BadBody(id: 7, cmd: "prompt", ..)) =
    protocol.decode_command(
      "{\"v\":1,\"id\":7,\"cmd\":\"prompt\",\"body\":{\"strand\":\"main\"}}",
    )
}
