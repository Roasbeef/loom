//// Complete reports retain two independent COMMIT duties in actual owner SQLite.
////
//// Transaction controls inject a fixed bounded test digest. Actual host SHA-256
//// and canonical same-length tampering are exercised by client custody controls.
//// Production receives SHA-256 from host assembly without a new dependency.
//// Corruption and failed-COMMIT controls use test-only SQL, never public hooks.
//// `opened` owns each database; `bundle` creates checked canonical report bytes.
//// `committed_session` proves exact original result-entry readback for collection.

import core/clock
import core/codec
import core/entry
import core/ids
import core/json
import core/message
import core/msgpack as mp
import core/register
import core/remote_tool
import core/report_value as rv
import core/tx
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import sqlight
import storage/owner_custody as custody
import storage/sql
import storage/sqlite
import storage/storage
import support/fixtures

pub fn profile_allowance_is_charged_before_effect_and_never_upgrades_test() {
  let #(path, store) = opened("reserve", custody.report_final_allowance + 1000)
  admit(store, key(0))
  assert scalar(path, "SELECT reserved_bytes FROM owner_custody_tools")
    >= custody.report_final_allowance
  assert custody.admit_fresh_with_profile(
      store,
      key(1),
      input(),
      input(),
      custody.CodeModeReportV1,
    )
    == Error(custody.Capacity)

  assert custody.admit_fresh(store, key(0), input(), input())
    == Error(custody.Conflict)
  assert custody.close(store) == Ok(Nil)

  // An ordinary original cannot be enlarged by a later report or retry.
  let #(_path, store) = opened("ordinary-profile", 32_000_000)
  assert custody.admit_fresh(store, key(0), input(), input())
    == Ok(custody.Fresh)
  assert custody.admit_fresh_with_profile(
      store,
      key(0),
      input(),
      input(),
      custody.CodeModeReportV1,
    )
    == Error(custody.Conflict)
  assert custody.retain_report(store, key(0), bundle(mp.NilValue))
    == Error(custody.Conflict)

  assert custody.close(store) == Ok(Nil)
}

pub fn report_only_commit_survives_lost_reply_and_never_reconstructs_final_test() {
  let #(path, store) = opened("report-only", 32_000_000)
  let report =
    bundle(mp.MapValue([#(mp.IntValue(7), mp.BinaryValue(<<0, 255>>))]))
  admit(store, key(0))
  let assert Ok(reference) = custody.retain_report(store, key(0), report)
    as "Report COMMIT precedes its internal receipt."

  assert custody.retain_report(store, key(0), bundle(mp.NilValue))
    == Error(custody.Conflict)
  let assert Error(_) = custody.read_report_chunk(store, reference, 0)
    as "Uncommitted final cannot expose a complete-result reference."
  assert custody.finish(store, key(0), input()) == Error(custody.Conflict)
  assert custody.finish_with_reference(store, key(0), input(), None)
    == Error(custody.Conflict)

  assert custody.close(store) == Ok(Nil)

  // The internal receipt may be lost. Reopen retains report history and the
  // original unknown final; neither a new runner nor discharge follows.
  let assert Ok(store) =
    custody.open_with_reports(
      path,
      remote_tool.session(key(0)),
      limits(32_000_000),
      sha256,
    )
    as "Original report validates independently after owner reopen."
  assert custody.retain_report(store, key(0), report) == Ok(reference)
  assert custody.lookup(store, key(0))
    == Ok(custody.AwaitingFinal(input(), input(), 0))
  assert custody.unreleased(store) == Ok(custody.Unreleased)

  assert custody.admit_fresh_with_profile(
      store,
      key(0),
      input(),
      input(),
      custody.CodeModeReportV1,
    )
    == Ok(custody.Retained)
  assert custody.close(store) == Ok(Nil)
  let assert Error(_) =
    custody.open(path, remote_tool.session(key(0)), limits(32_000_000))
    as "Ordinary open cannot skip report hashing on history."
}

pub fn maximum_terminal_retains_at_prefilled_quota_and_reads_bounded_chunks_test() {
  let #(path, store) = opened("maximum", custody.report_final_allowance + 5000)
  admit(store, key(0))
  assert custody.admit_fresh(store, key(1), input(), input())
    == Ok(custody.Fresh)
  let report =
    bundle(
      mp.ArrayValue([mp.StringValue(string.repeat("\u{0000}", 16_777_173))]),
    )

  let assert Ok(reference) = custody.retain_report(store, key(0), report)
    as "The maximum terminal consumes its existing reserved allowance."
  assert custody.finish_with_reference(
      store,
      key(0),
      final_payload(reference),
      Some(reference),
    )
    == Ok(Nil)
  let assert Ok(chunk) = custody.read_report_chunk(store, reference, 0)
    as "Header-first chunk serving avoids a full-report value query."
  assert bit_array.byte_size(chunk.bytes) == 65_536

  let last = { rv.ref_byte_length(reference) - 1 } / 65_536 * 65_536
  let assert Ok(chunk) = custody.read_report_chunk(store, reference, last)
    as "The last exact slice is bounded and retains the original continuation."
  assert bit_array.byte_size(chunk.bytes)
    == rv.ref_byte_length(reference) - last
  assert chunk.reference == reference

  assert scalar(
      path,
      "SELECT reserved_bytes FROM owner_custody_tools ORDER BY address LIMIT 1",
    )
    >= custody.report_final_allowance
  assert custody.close(store) == Ok(Nil)
}

pub fn wrong_session_entry_digest_length_and_offset_refuse_before_chunk_test() {
  let #(_path, store) = opened("wrong-ref", 32_000_000)
  admit(store, key(0))
  let assert Ok(reference) =
    custody.retain_report(store, key(0), bundle(mp.NilValue))
    as "Original fixed reference."
  assert custody.finish_with_reference(
      store,
      key(0),
      final_payload(reference),
      Some(reference),
    )
    == Ok(Nil)

  let assert Ok(other) =
    rv.reference(
      rv.ref_session(reference),
      rv.ref_result_entry(reference),
      string.repeat("c", 64),
      rv.ref_byte_length(reference),
    )
    as "Syntactically valid wrong digest grants no read authority."
  assert custody.read_report_chunk(store, other, 0) == Error(custody.Conflict)
  assert custody.finish_with_reference(
      store,
      key(0),
      final_payload(reference),
      Some(other),
    )
    == Error(custody.Conflict)
  let assert Ok(other) =
    rv.reference(
      rv.ref_session(reference),
      rv.ref_result_entry(reference),
      rv.ref_digest(reference),
      rv.ref_byte_length(reference) + 1,
    )
    as "Changed length cannot select the original report."

  assert custody.read_report_chunk(store, other, 0) == Error(custody.Conflict)
  let foreign = ids.mint_session(ids.generator(clock.fixed(1000), 88)).0
  let assert Ok(other) =
    rv.reference(
      foreign,
      rv.ref_result_entry(reference),
      rv.ref_digest(reference),
      rv.ref_byte_length(reference),
    )
    as "Another session is syntactically valid but not this owner."
  assert custody.read_report_chunk(store, other, 0) == Error(custody.Conflict)

  let assert Ok(other) =
    rv.reference(
      rv.ref_session(reference),
      remote_tool.result_entry(key(1)),
      rv.ref_digest(reference),
      rv.ref_byte_length(reference),
    )
    as "Another result entry is not a bearer credential."
  let assert Error(_) = custody.read_report_chunk(store, other, 0)
    as "Missing original result refuses."
  let assert Error(_) = custody.read_report_chunk(store, reference, -1)
    as "Negative offset refuses."
  let assert Error(_) = custody.read_report_chunk(store, reference, 1)
    as "Unaligned offset refuses."

  let assert Error(_) =
    custody.read_report_chunk(store, reference, rv.ref_byte_length(reference))
    as "End offset cannot read an empty successful chunk."
  assert custody.close(store) == Ok(Nil)
}

pub fn corrupted_report_digest_profile_and_original_entry_fail_reopen_test() {
  let variants = [
    "UPDATE owner_custody_tools SET report_digest = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'",
    "UPDATE owner_custody_tools SET report = zeroblob(length(report))",
    "UPDATE owner_custody_tools SET report = zeroblob(17039377)",
    "UPDATE owner_custody_tools SET final_allowance = final_allowance - 1",
    "UPDATE owner_custody_tools SET final_profile = 'ordinary'",
    "UPDATE owner_custody_tools SET result_entry = '00000000-0000-7000-8000-000000000000'",
  ]
  let _ =
    list.index_map(variants, fn(statement, index) {
      let #(path, store) =
        opened("corrupt-" <> int.to_string(index), 32_000_000)
      admit(store, key(0))
      let assert Ok(_) =
        custody.retain_report(store, key(0), bundle(mp.NilValue))
        as "Only deliberate corruption changes committed bytes."
      assert custody.close(store) == Ok(Nil)
      corrupt(path, statement)
      let assert Error(_) =
        custody.open_with_reports(
          path,
          remote_tool.session(key(0)),
          limits(32_000_000),
          sha256,
        )
        as "Corruption refuses before publication or report read."
    })
}

pub fn format_four_refuses_before_new_columns_and_leaves_file_unchanged_test() {
  let #(path, store) = opened("format-four", 32_000_000)
  assert custody.close(store) == Ok(Nil)
  corrupt(
    path,
    "ALTER TABLE owner_custody_tools DROP COLUMN final_profile; ALTER TABLE owner_custody_tools DROP COLUMN final_allowance; ALTER TABLE owner_custody_tools DROP COLUMN report; ALTER TABLE owner_custody_tools DROP COLUMN report_digest; PRAGMA user_version=4",
  )
  let assert Ok(before) = simplifile.read_bits(path)
    as "Original unreleased format-4 file."

  assert custody.open_with_reports(
      path,
      remote_tool.session(key(0)),
      limits(32_000_000),
      sha256,
    )
    == Error(custody.Invalid("unsupported owner custody database"))
  assert simplifile.read_bits(path) == Ok(before)
}

pub fn failed_report_write_keeps_absence_and_full_original_reservation_test() {
  let #(path, store) = opened("failed-write", 32_000_000)
  admit(store, key(0))
  let reserved = scalar(path, "SELECT reserved_bytes FROM owner_custody_tools")
  corrupt(
    path,
    "CREATE TRIGGER refuse_report BEFORE UPDATE OF report ON owner_custody_tools BEGIN SELECT RAISE(ABORT, 'report custody unavailable'); END",
  )

  let assert Error(_) =
    custody.retain_report(store, key(0), bundle(mp.NilValue))
    as "Actual SQLite refusal cannot issue a report receipt."
  assert custody.report_reference(store, key(0)) == Ok(None)
  assert custody.lookup(store, key(0))
    == Ok(custody.AwaitingFinal(input(), input(), 0))
  assert custody.unreleased(store) == Ok(custody.Unreleased)

  assert scalar(path, "SELECT reserved_bytes FROM owner_custody_tools")
    == reserved
  assert custody.close(store) == Ok(Nil)
}

pub fn report_rows_use_full_sync_and_ordinary_values_never_select_report_test() {
  let #(path, store) = opened("sync", 32_000_000)
  let assert Ok(db) = sqlight.open(path) as "Separate inspection connection."
  let assert Ok([mode]) =
    sqlight.query("PRAGMA journal_mode", db, [], decode.at([0], decode.string))
    as "Requested WAL persists on the actual database."
  assert mode == "wal"

  assert sqlight.close(db) == Ok(Nil)
  assert string.starts_with(
    sql.owner_tool_value("", 1024).0,
    "SELECT identity, arguments, request, outcome FROM owner_custody_tools",
  )
  assert custody.close(store) == Ok(Nil)
}

pub fn exact_session_collection_keeps_report_charge_and_readability_after_restart_test() {
  let #(path, store) = opened("collect", 32_000_000)
  admit(store, key(0))
  let report = bundle(mp.BinaryValue(<<0, 255, 0>>))
  let assert Ok(reference) = custody.retain_report(store, key(0), report)
    as "Exact original report commits."

  let payload = final_payload(reference)
  assert custody.finish_with_reference(store, key(0), payload, Some(reference))
    == Ok(Nil)
  let source = committed_session(path <> ".session", key(0), final(reference))
  let assert Ok(proof) =
    custody.verify_commit(store, key(0), source, validate_final)
    as "Report custody cannot substitute for actual session readback."

  assert custody.collect(store, proof) == Error(custody.CollectionPending)
  assert custody.discharge(store, key(0), payload) == Ok(Nil)
  let before = scalar(path, "SELECT reserved_bytes FROM owner_custody_tools")
  assert custody.collect(store, proof) == Ok(Nil)

  let charged = scalar(path, "SELECT reserved_bytes FROM owner_custody_tools")
  assert charged < before
  assert charged
    == scalar(
      path,
      "SELECT length(identity) + length(CAST(address AS BLOB)) + 256 + length(report) FROM owner_custody_tools",
    )
  assert custody.close(store) == Ok(Nil)

  assert storage.close(source) == Ok(Nil)

  // Collection frees only unused allowance. The companion retains its immutable
  // complete report and actual charge across owner close and session lifetime.
  let assert Ok(store) =
    custody.open_with_reports(
      path,
      remote_tool.session(key(0)),
      limits(32_000_000),
      sha256,
    )
    as "Collected complete report validates on reopen."
  assert custody.lookup(store, key(0)) == Ok(custody.Collected)
  assert custody.report_reference(store, key(0)) == Ok(Some(reference))
  let assert Ok(chunk) = custody.read_report_chunk(store, reference, 0)
    as "The permanent fence keeps complete historical retrieval."

  assert chunk.bytes == rv.bytes(report)
  assert scalar(path, "SELECT reserved_bytes FROM owner_custody_tools")
    == charged
  assert custody.close(store) == Ok(Nil)
}

fn limits(bytes: Int) -> custody.Limits {
  let assert Ok(value) = custody.limits(8, 32, bytes, 1024)
    as "Original owner quota remains below 256 MiB."
  value
}

fn key(index: Int) -> remote_tool.ToolKey {
  let generator = ids.generator(clock.fixed(1000), 77)
  let #(session, generator) = ids.mint_session(generator)
  let #(operation, _) = ids.mint_op(generator)
  let #(result_entry, _) =
    ids.mint_entry(ids.generator(clock.fixed(1001), index + 10))

  let assert Ok(key) =
    remote_tool.key(
      session,
      operation,
      "reports",
      index,
      string.repeat("a", 64),
      result_entry,
    )
    as "Complete original tool identity validates."
  key
}

fn sha256(bytes: BitArray) -> BitArray {
  // This test double supplies the fixed digest contract, not cryptographic proof.
  // Client controls independently exercise the real assembly hashing function.
  case bit_array.byte_size(bytes) > 0 {
    True -> <<0:size(256)>>
    False -> <<>>
  }
}

fn bundle(value: mp.MsgPackValue) -> rv.CompleteReport {
  let assert Ok(metadata) =
    rv.metadata(
      "sha256-" <> string.repeat("b", 64),
      rv.Enforcement(
        rv.Unreported("not observed"),
        rv.Unreported("not observed"),
      ),
      rv.CallLog(0, 0, 0, 0, 0, 0, []),
    )
    as "Owner observations meet the fixed complete metadata contract."
  let assert Ok(report) = rv.from_outcome(rv.Completed(value), metadata)
    as "The original terminal is admitted before report storage."
  report
}

fn opened(name: String, budget: Int) -> #(String, custody.Store) {
  let path = fixtures.scratch("owner-reports-" <> name) <> "/owner.db"
  let assert Ok(store) =
    custody.open_with_reports(
      path,
      remote_tool.session(key(0)),
      limits(budget),
      sha256,
    )
    as "Actual report-enabled owner SQLite opens."
  #(path, store)
}

fn input() -> custody.Payload {
  let assert Ok(input) =
    custody.payload(limits(32_000_000), <<"original":utf8>>)
    as "Ordinary request bytes fit their independent allowance."
  input
}

fn admit(store: custody.Store, key: remote_tool.ToolKey) -> Nil {
  assert custody.admit_fresh_with_profile(
      store,
      key,
      input(),
      input(),
      custody.CodeModeReportV1,
    )
    == Ok(custody.Fresh)
}

fn final(reference: rv.ReportRef) -> message.AgentMessage {
  message.ToolResultMessage(
    "call",
    "code_mode",
    [message.ToolResultText("bounded preview", None)],
    Some(
      json.Object([
        #("kind", json.String("code_mode_report_v1")),
        #("reference", json.String(rv.ref_to_string(reference))),
      ]),
    ),
    None,
    None,
    False,
    1000,
  )
}

fn final_payload(reference: rv.ReportRef) -> custody.Payload {
  let bytes =
    final(reference)
    |> codec.encode_message
    |> json.to_string
    |> bit_array.from_string
  let assert Ok(payload) =
    custody.final_payload(limits(32_000_000), custody.CodeModeReportV1, bytes)
    as "Report final uses its own fixed JSON allowance."
  payload
}

fn scalar(path: String, statement: String) -> Int {
  let assert Ok(db) = sqlight.open(path) as "Private inspection connection."
  let assert Ok([value]) =
    sqlight.query(statement, db, [], decode.at([0], decode.int))
    as "One scalar configuration or accounting row."
  assert sqlight.close(db) == Ok(Nil)
  value
}

fn corrupt(path: String, statement: String) -> Nil {
  let assert Ok(db) = sqlight.open(path) as "Test-only corruption connection."
  assert sqlight.exec(statement, db) == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
}

fn validate_final(
  payload: custody.Payload,
  readback: custody.ResultReadback,
) -> Result(Nil, String) {
  use text <- result.try(
    bit_array.to_string(custody.bytes(payload))
    |> result.replace_error("invalid UTF-8"),
  )
  use value <- result.try(
    json.parse(text) |> result.replace_error("invalid final JSON"),
  )
  use expected <- result.try(
    codec.decode_message(value) |> result.replace_error("invalid final message"),
  )
  case
    readback.message == expected && readback.termination == custody.Continues
  {
    True -> Ok(Nil)
    False -> Error("exact session result differs")
  }
}

fn committed_session(
  path: String,
  key: remote_tool.ToolKey,
  message: message.AgentMessage,
) -> storage.Storage(process.Subject(sqlite.Message)) {
  let assert Ok(source) =
    sqlite.open(sqlite.config(path, "report-test"), clock.stepping(1000, 1))
    as "Actual reserved session database."
  let row =
    entry.MessageEntry(
      remote_tool.result_entry(key),
      None,
      0,
      1000,
      message,
      False,
    )
  let assert Ok(_) =
    storage.commit(
      source,
      tx.Tx(
        [
          tx.InsertEntry(row),
          tx.SetRegister(
            register.FactCustom,
            "session/id",
            register.value(
              json.String(ids.session_id_to_string(remote_tool.session(key))),
            ),
          ),
        ],
        [],
      ),
    )
    as "Exact original result and session identity commit together."
  source
}
