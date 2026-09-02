//// Golden-fixture conformance: the gateway must accept every command
//// fixture and emit byte-identical encodings of every event fixture
//// from the gateway's normative corpus (`packages/client/testdata/protocol`).
//// Each fixture is decoded
//// with the typed protocol codecs and re-encoded canonically; the
//// output must equal the file byte for byte, which pins both the
//// envelope and every nested body (entries, messages, usage in the
//// core codec vocabulary) to the frozen protocol document.

import client/protocol
import gleam/list
import gleam/string
import simplifile

const testdata = "testdata/protocol"

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

// The two corpora are named once, as constants, so the completeness
// test below can compare them against the directory rather than against
// a number. A count alone catches a fixture added without a roundtrip
// and misses the opposite mistake — a fixture quietly dropped from a
// list while its file stays on disk — which is the one that silently
// loses coverage.
const command_fixtures = [
  "cmd_abort.json", "cmd_approve.json", "cmd_approve_all.json",
  "cmd_catch_up.json", "cmd_compact.json", "cmd_create_strand.json",
  "cmd_deny.json", "cmd_follow_up.json", "cmd_fork.json", "cmd_models.json",
  "cmd_navigate.json", "cmd_prompt.json", "cmd_prompt_content.json",
  "cmd_schedule_cancel.json", "cmd_schedules.json", "cmd_set_config.json",
  "cmd_set_config_model.json", "cmd_steer.json", "cmd_subscribe.json",
  "cmd_subscribe_resume.json",
]

const event_fixtures = [
  "event_entry_assistant.json", "event_entry_compaction.json",
  "event_entry_tool_result.json", "event_entry_user.json", "event_error.json",
  "event_escalation_approved.json", "event_escalation_pending.json",
  "event_op_transition.json", "event_snapshot_full.json",
  "event_snapshot_models.json", "event_snapshot_resume.json",
  "event_snapshot_schedules.json", "event_snapshot_strands.json",
  "event_strand_result_done.json", "event_strand_result_failed.json",
  "event_stream_delta_text.json", "event_stream_delta_thinking.json",
  "event_stream_delta_tool_call.json", "event_usage.json",
]

pub fn command_fixtures_roundtrip_test() {
  command_fixtures
  |> list.each(roundtrip_command)
}

pub fn event_fixtures_roundtrip_test() {
  event_fixtures
  |> list.each(roundtrip_event)
}

// The corpus above must be the whole corpus, in both directions: a
// fixture added without a roundtrip here would silently drop coverage,
// and a fixture removed from one of the lists while its file remains
// would drop coverage without changing a single count. Comparing the
// two sorted lists catches both; the count is kept beside it because it
// is what a reader checks a `protocol-change` against.
pub fn corpus_is_complete_test() {
  let assert Ok(files) = simplifile.read_directory(testdata)
  let json_files =
    files
    |> list.filter(string.ends_with(_, ".json"))
    |> list.sort(string.compare)
  let covered =
    list.append(command_fixtures, event_fixtures)
    |> list.sort(string.compare)
  assert covered == json_files
  assert list.length(json_files) == 39
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

pub fn prompt_content_empty_list_is_refused_test() {
  let assert Error(protocol.BadBody(
    id: 8,
    cmd: "prompt_content",
    reason: "content must be a non-empty array",
  )) =
    protocol.decode_command(
      "{\"v\":1,\"id\":8,\"cmd\":\"prompt_content\","
      <> "\"body\":{\"strand\":\"main\",\"content\":[]}}",
    )
}

pub fn prompt_content_malformed_block_refuses_whole_command_test() {
  let assert Error(protocol.BadBody(
    id: 9,
    cmd: "prompt_content",
    reason: "valid base64 image bytes",
  )) =
    protocol.decode_command(
      "{\"v\":1,\"id\":9,\"cmd\":\"prompt_content\",\"body\":{"
      <> "\"strand\":\"main\",\"content\":["
      <> "{\"type\":\"text\",\"text\":\"keep me\"},"
      <> "{\"type\":\"image\",\"data\":\"not base64\","
      <> "\"mimeType\":\"image/png\"}]}}",
    )
}

pub fn prompt_content_refuses_empty_image_media_type_test() {
  let assert Error(protocol.BadBody(
    id: 10,
    cmd: "prompt_content",
    reason: "a non-empty media type",
  )) =
    protocol.decode_command(
      "{\"v\":1,\"id\":10,\"cmd\":\"prompt_content\",\"body\":{"
      <> "\"strand\":\"main\",\"content\":["
      <> "{\"type\":\"image\",\"data\":\"iVBORw0KGgo=\","
      <> "\"mimeType\":\"  \"}]}}",
    )
}

pub fn prompt_content_refuses_unknown_and_wrong_typed_blocks_test() {
  let assert Error(protocol.BadBody(
    id: 11,
    cmd: "prompt_content",
    reason: "text or image",
  )) =
    protocol.decode_command(
      "{\"v\":1,\"id\":11,\"cmd\":\"prompt_content\",\"body\":{"
      <> "\"strand\":\"main\",\"content\":[{\"type\":\"audio\"}]}}",
    )
  let assert Error(protocol.BadBody(
    id: 12,
    cmd: "prompt_content",
    reason: "a string",
  )) =
    protocol.decode_command(
      "{\"v\":1,\"id\":12,\"cmd\":\"prompt_content\",\"body\":{"
      <> "\"strand\":\"main\",\"content\":["
      <> "{\"type\":\"image\",\"data\":7,\"mimeType\":\"image/png\"}]}}",
    )
}
