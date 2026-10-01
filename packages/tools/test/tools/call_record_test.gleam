//// The per-call record: its bounds, its redaction allowlist and its wire
//// shape.
////
//// Every test is pure. The redaction cases here build `args` by hand
//// because they exercise the summariser's own rules; the per-capability
//// rows are pinned against the real encoders in the `cap` package's
//// `call_record_redaction_test`, where a key the encoders write and the
//// allowlist reads can no longer drift apart unnoticed.

import core/json
import core/msgpack
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tools/call_record.{CallCancelled, CallFailed, CallOk, CallUnsettled}

// The golden wire shape. `session_view/call_tree`'s decoder test holds the
// same literal, so a change to either side fails the other.
const golden =
  "{\"started_unix_ms\":1790000000000,\"elapsed_ms\":1840,\"total\":2,\"failed\":1,\"cancelled\":0,\"unsettled\":0,\"items\":[{\"cap\":\"fs.read\",\"args\":\"src/app.gleam\",\"status\":\"ok\",\"start_ms\":12,\"duration_ms\":3},{\"cap\":\"proc.run\",\"args\":\"gleam +2 args\",\"status\":\"failed\",\"error\":\"exec_failed\",\"start_ms\":20,\"duration_ms\":1511}]}"

fn path_args(path: String) -> msgpack.MsgPackValue {
  msgpack.MapValue([
    #(msgpack.StringValue("path"), msgpack.StringValue(path)),
  ])
}

fn summary(cap: String, args: msgpack.MsgPackValue) -> option.Option(String) {
  call_record.summarise(cap, args)
}

pub fn the_golden_log_encodes_exactly_test() {
  let log =
    call_record.CallLog(
      started_unix_ms: 1_790_000_000_000,
      elapsed_ms: 1840,
      total: 2,
      failed: 1,
      cancelled: 0,
      unsettled: 0,
      items: [
        call_record.CallRecord(
          cap: "fs.read",
          args: Some("src/app.gleam"),
          status: CallOk,
          error: None,
          start_ms: 12,
          duration_ms: 3,
        ),
        call_record.CallRecord(
          cap: "proc.run",
          args: Some("gleam +2 args"),
          status: CallFailed,
          error: Some("exec_failed"),
          start_ms: 20,
          duration_ms: 1511,
        ),
      ],
    )
  assert json.to_string(call_record.to_json(log)) == golden
}

pub fn an_empty_log_has_no_items_test() {
  assert json.to_string(call_record.to_json(call_record.empty()))
    == "{\"started_unix_ms\":0,\"elapsed_ms\":0,\"total\":0,\"failed\":0,\"cancelled\":0,\"unsettled\":0,\"items\":[]}"
}

pub fn a_path_is_the_whole_summary_test() {
  assert summary("fs.write", path_args("notes/a.txt")) == Some("notes/a.txt")
}

pub fn an_unlisted_capability_has_no_summary_test() {
  assert summary("net.fetch", path_args("https://example.invalid")) == None
  assert summary("mcp.github.search", path_args("x")) == None
}

pub fn a_missing_or_mistyped_key_has_no_summary_test() {
  assert summary("fs.read", msgpack.MapValue([])) == None
  assert summary("fs.read", msgpack.NilValue) == None
  assert summary(
      "fs.read",
      msgpack.MapValue([
        #(msgpack.StringValue("path"), msgpack.IntValue(3)),
      ]),
    )
    == None
}

pub fn a_job_start_keeps_only_the_first_token_test() {
  let args =
    msgpack.MapValue([
      #(
        msgpack.StringValue("command"),
        msgpack.StringValue("  curl -H 'Authorization: Bearer s3cret' x"),
      ),
    ])
  assert summary("job.start", args) == Some("curl")
}

pub fn a_process_keeps_the_executable_and_an_argument_count_test() {
  let args =
    msgpack.MapValue([
      #(
        msgpack.StringValue("argv"),
        msgpack.ArrayValue([
          msgpack.StringValue("/usr/bin/curl"),
          msgpack.StringValue("--token=s3cret"),
          msgpack.StringValue("https://example.invalid"),
        ]),
      ),
      #(msgpack.StringValue("stdin"), msgpack.StringValue("s3cret")),
    ])
  assert summary("proc.run", args) == Some("curl +2 args")
}

pub fn control_characters_are_removed_test() {
  let text = "a\u{1b}[31mb\u{7f}c\u{9b}d\ne"
  assert summary("fs.read", path_args(text)) == Some("a[31mbcde")
}

pub fn a_long_summary_is_cut_on_a_boundary_and_marked_test() {
  // 100 two-byte characters: 200 bytes, cut to 93 bytes of content (46
  // characters, 92 bytes) plus the three-byte marker.
  let long = string.repeat("é", 100)
  let assert Some(cut) = summary("fs.read", path_args(long))
  assert string.ends_with(cut, "…")
  assert string.length(cut) == 47
  assert call_record_byte_size(cut) == 95
}

pub fn a_summary_at_the_limit_is_not_marked_test() {
  let exact = string.repeat("a", 96)
  assert summary("fs.read", path_args(exact)) == Some(exact)
  let assert Some(cut) = summary("fs.read", path_args(exact <> "a"))
  assert call_record_byte_size(cut) == 96
  assert string.ends_with(cut, "…")
}

fn call_record_byte_size(text: String) -> Int {
  bit_array.byte_size(bit_array.from_string(text))
}

pub fn a_hostile_name_is_sanitised_and_bounded_test() {
  let #(ledger, _seq) =
    call_record.admit(
      call_record.start(1000),
      string.repeat("X/", 60),
      msgpack.NilValue,
      1005,
    )
  let log = call_record.finish(ledger, [], 1010)
  let assert [record] = log.items
  assert string.length(record.cap) == 64
  assert record.cap == string.repeat("__", 32)
}

pub fn offsets_are_relative_and_never_negative_test() {
  let ledger = call_record.start(1000)
  let #(ledger, early) =
    call_record.admit(ledger, "kv.get", msgpack.NilValue, 900)
  let ledger = call_record.settle(ledger, early, CallOk, None, 800)
  let log = call_record.finish(ledger, [], 700)
  let assert [record] = log.items
  assert record.start_ms == 0
  assert record.duration_ms == 0
  assert log.elapsed_ms == 0
}

pub fn the_log_keeps_the_first_records_and_counts_every_call_test() {
  let ledger =
    list.fold(numbers(200), call_record.start(0), fn(ledger, n) {
      call_record.refuse(ledger, "fs.read", msgpack.NilValue, "policy", n)
    })
  let log = call_record.finish(ledger, [], 500)
  assert log.total == 200
  assert log.failed == 200
  assert list.length(log.items) == call_record.max_records
  assert list.map(log.items, fn(record) { record.start_ms }) == numbers(128)
}

pub fn unsettled_calls_are_closed_at_the_end_of_the_execution_test() {
  let ledger = call_record.start(0)
  let #(ledger, first) =
    call_record.admit(ledger, "proc.run", msgpack.NilValue, 10)
  let #(ledger, second) =
    call_record.admit(ledger, "proc.run", msgpack.NilValue, 20)
  let ledger =
    call_record.settle(ledger, second, CallCancelled, Some("aborted"), 25)
  let log = call_record.finish(ledger, [first], 100)
  assert log.unsettled == 1
  assert log.cancelled == 1
  let assert [one, two] = log.items
  assert one.status == CallUnsettled
  assert one.duration_ms == 90
  assert two.status == CallCancelled
  assert two.error == Some("aborted")
  assert two.duration_ms == 5
}

pub fn an_error_code_is_bounded_to_its_alphabet_test() {
  let ledger =
    call_record.refuse(
      call_record.start(0),
      "fs.read",
      msgpack.NilValue,
      "Bad Code: /etc/passwd " <> string.repeat("x", 60),
      1,
    )
  let log = call_record.finish(ledger, [], 2)
  let assert [record] = log.items
  let assert Some(code) = record.error
  assert string.length(code) == 48
  assert string.starts_with(code, "_ad__ode___etc_passwd_")
}

// The integers from zero up to, not including, `count`.
fn numbers(count: Int) -> List(Int) {
  list.index_map(list.repeat(Nil, count), fn(_, index) { index })
}
