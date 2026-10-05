//// Actual SQLite custody checks: lost replies, conflicts, quotas, oversized
//// corruption, session readback and permanent replay fences. Test-only SQL
//// corrupts files deliberately; production calls use Parrot named queries.

import core/clock
import core/codec
import core/entry
import core/ids
import core/json
import core/message
import core/register
import core/remote_tool
import core/tx
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import sqlight
import storage/owner_custody as custody
import storage/owner_custody_schema
import storage/sql
import storage/sqlite
import storage/storage
import support/fixtures

fn ceilings() -> custody.Limits {
  let assert Ok(limits) = custody.limits(8, 32, 131_072, 1024)
    as "fixture ceilings are bounded"
  limits
}

fn identity(
  index: Int,
  digest: String,
  result_seed: Int,
) -> remote_tool.ToolKey {
  let generator = ids.generator(clock.fixed(1000), 77)
  let #(session, generator) = ids.mint_session(generator)
  let #(operation, _) = ids.mint_op(generator)
  let #(entry, _) =
    ids.mint_entry(ids.generator(clock.fixed(1001), result_seed))
  let assert Ok(key) =
    remote_tool.key(
      session,
      operation,
      "step",
      index,
      string.repeat(digest, 64),
      entry,
    )
    as "fixture complete key validates"
  key
}

fn child_id(seed: Int) -> ids.EntryId {
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(2000), seed))
  id
}

fn payload(text: String) -> custody.Payload {
  let assert Ok(payload) =
    custody.payload(ceilings(), bit_array.from_string(text))
    as "fixture bytes fit the bound"
  payload
}

fn open(name: String, key: remote_tool.ToolKey) -> #(String, custody.Store) {
  let path = fixtures.scratch("owner-custody-" <> name) <> "/owner.db"
  let assert Ok(store) =
    custody.open(path, remote_tool.session(key), ceilings())
    as "separate per-session custody database opens"
  #(path, store)
}

pub fn exact_final_outcome_survives_lost_callback_and_reopen_test() {
  let key = identity(2, "a", 10)
  let #(path, store) = open("final-reopen", key)
  assert custody.admit(store, key, payload("args"), payload("scope:request"))
    == Ok(Nil)
  assert custody.finish(store, key, payload("exact final tool report"))
    == Ok(Nil)
  assert custody.finish(store, key, payload("exact final tool report"))
    == Ok(Nil)
  assert custody.finish(store, key, payload("different report"))
    == Error(custody.Conflict)
  assert custody.close(store) == Ok(Nil)

  // The original callback no longer exists. The immutable final payload is
  // the only authority returned by the reopened journal.
  let assert Ok(store) =
    custody.open(path, remote_tool.session(key), ceilings())
    as "journal reopens independently of the callback"
  assert custody.lookup(store, key)
    == Ok(custody.FinalOutcome(payload("exact final tool report")))
  assert custody.close(store) == Ok(Nil)
}

pub fn complete_identity_and_scope_conflicts_fail_closed_test() {
  let key = identity(2, "a", 10)
  let #(_path, store) = open("conflicts", key)
  assert custody.admit(
      store,
      key,
      payload("args"),
      payload("workspace:epoch:request"),
    )
    == Ok(Nil)
  assert custody.admit(
      store,
      key,
      payload("changed args"),
      payload("workspace:epoch:request"),
    )
    == Error(custody.Conflict)
  assert custody.admit(
      store,
      key,
      payload("args"),
      payload("other-workspace:epoch:request"),
    )
    == Error(custody.Conflict)
  assert custody.lookup(store, identity(2, "b", 10)) == Error(custody.Conflict)
  assert custody.lookup(store, identity(2, "a", 11)) == Error(custody.Conflict)
  assert custody.admit(
      store,
      identity(3, "a", 10),
      payload("args"),
      payload("workspace:epoch:request"),
    )
    == Error(custody.Conflict)
  assert custody.lookup(store, identity(3, "a", 10)) == Error(custody.Missing)
  assert custody.finish(store, identity(3, "a", 10), payload("final"))
    == Error(custody.Missing)
  assert custody.close(store) == Ok(Nil)
}

pub fn child_link_replay_and_child_only_evidence_never_yield_final_test() {
  let key = identity(0, "a", 1)
  let #(path, store) = open("child-replay", key)
  assert custody.admit(store, key, payload("args"), payload("request"))
    == Ok(Nil)
  let assert Ok(compile) = remote_tool.tool_child(key, remote_tool.Compile)
    as "compile origin validates"
  let id = child_id(1)
  assert custody.admit_child(store, compile, id, payload("immutable compile"))
    == Ok(Nil)
  assert custody.receive_child(store, compile, id, payload("compile succeeded"))
    == Ok(Nil)
  assert custody.close(store) == Ok(Nil)
  let assert Ok(store) =
    custody.open(path, remote_tool.session(key), ceilings())
    as "child link survives connection and owner restart"
  assert custody.child(store, compile)
    == Ok(#(
      id,
      payload("immutable compile"),
      Some(payload("compile succeeded")),
    ))
  assert custody.lookup(store, key)
    == Ok(custody.AwaitingFinal(payload("request"), payload("args"), 1))
  assert custody.admit_child(store, compile, id, payload("immutable compile"))
    == Ok(Nil)
  assert custody.admit_child(
      store,
      compile,
      child_id(2),
      payload("immutable compile"),
    )
    == Error(custody.Conflict)
  assert custody.admit_child(store, compile, id, payload("rewritten compile"))
    == Error(custody.Conflict)
  assert custody.receive_child(store, compile, id, payload("changed terminal"))
    == Error(custody.Conflict)
  assert custody.close(store) == Ok(Nil)
}

pub fn compile_launch_capability_and_system_origins_are_distinct_test() {
  let key = identity(0, "a", 1)
  let #(_path, store) = open("origins", key)
  assert custody.admit(store, key, payload("args"), payload("request"))
    == Ok(Nil)
  let origins = [
    remote_tool.tool_child(key, remote_tool.Compile),
    remote_tool.tool_child(key, remote_tool.Launch),
    remote_tool.tool_child(key, remote_tool.Capability(0)),
    remote_tool.tool_child(key, remote_tool.Capability(1)),
    remote_tool.system_child(remote_tool.session(key), "lsp", 0),
  ]
  let _ =
    list.index_map(origins, fn(origin, index) {
      let assert Ok(origin) = origin as "typed child origin validates"
      assert custody.admit_child(
          store,
          origin,
          child_id(index),
          payload("same bytes, distinct invocation"),
        )
        == Ok(Nil)
      let assert Ok(#(id, _, None)) = custody.child(store, origin)
        as "each namespace has its stable child"
      assert id == child_id(index)
    })
  assert custody.close(store) == Ok(Nil)
}

pub fn quotas_reserve_final_bytes_and_refuse_without_eviction_test() {
  let key = identity(0, "a", 1)
  let path = fixtures.scratch("owner-custody-capacity") <> "/owner.db"
  let assert Ok(limits) = custody.limits(1, 1, 8192, 1024)
    as "fixture has exactly one tool slot"
  let assert Ok(store) = custody.open(path, remote_tool.session(key), limits)
    as "bounded journal opens"
  assert custody.admit(store, key, payload("args"), payload("request"))
    == Ok(Nil)
  assert custody.admit(
      store,
      identity(1, "a", 2),
      payload("args"),
      payload("request"),
    )
    == Error(custody.Capacity)
  assert custody.finish(store, key, payload(string.repeat("x", 1024)))
    == Ok(Nil)
  assert custody.lookup(store, key)
    == Ok(custody.FinalOutcome(payload(string.repeat("x", 1024))))
  assert custody.payload(
      limits,
      bit_array.from_string(string.repeat("x", 1025)),
    )
    == Error(custody.Capacity)
  assert custody.close(store) == Ok(Nil)

  // A payload constructed under a larger ceiling cannot bypass this handle's.
  let assert Ok(smaller) = custody.limits(1, 1, 8192, 8)
    as "smaller per-payload ceiling validates"
  let path = fixtures.scratch("owner-custody-small-payload") <> "/owner.db"
  let assert Ok(store) = custody.open(path, remote_tool.session(key), smaller)
    as "small-payload journal opens"
  assert custody.admit(
      store,
      key,
      payload("oversized arguments"),
      payload("request"),
    )
    == Error(custody.Capacity)
  assert custody.lookup(store, key) == Error(custody.Missing)
  assert custody.close(store) == Ok(Nil)
}

pub fn partial_byte_payload_never_reaches_sqlite_binding_test() {
  assert custody.payload(ceilings(), <<1:size(1)>>)
    == Error(custody.Invalid("owner payload must contain whole bytes"))
}

pub fn byte_capacity_refuses_before_admission_mutation_test() {
  let key = identity(0, "a", 1)
  let assert Ok(limits) = custody.limits(4, 4, 1, 1024)
    as "a one-byte journal is valid but cannot admit work"
  let path = fixtures.scratch("owner-custody-byte-limit") <> "/owner.db"
  let assert Ok(store) = custody.open(path, remote_tool.session(key), limits)
    as "empty bounded journal opens"
  assert custody.admit(store, key, payload("args"), payload("request"))
    == Error(custody.Capacity)
  assert custody.lookup(store, key) == Error(custody.Missing)
  assert custody.close(store) == Ok(Nil)
}

pub fn oversized_corrupt_blobs_are_refused_before_materialization_test() {
  let key = identity(0, "a", 1)
  let #(path, store) = open("oversized-corruption", key)
  assert custody.admit(store, key, payload("args"), payload("request"))
    == Ok(Nil)
  assert custody.close(store) == Ok(Nil)
  let assert Ok(db) = sqlight.open(path)
    as "corruption fixture connection opens"
  assert sqlight.exec(
      "UPDATE owner_custody_tools SET request = zeroblob(1048576)",
      db,
    )
    == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
  let assert Ok(store) =
    custody.open(path, remote_tool.session(key), ceilings())
    as "metadata opens without materializing tool blobs"
  assert custody.lookup(store, key)
    == Error(custody.Invalid(
      "owner payload exceeds bound before materialization",
    ))
  assert custody.close(store) == Ok(Nil)
}

pub fn oversized_corrupt_child_terminal_is_refused_before_value_decoder_test() {
  let key = identity(0, "a", 1)
  let #(path, store) = open("oversized-child", key)
  assert custody.admit(store, key, payload("args"), payload("request"))
    == Ok(Nil)
  let assert Ok(origin) = remote_tool.tool_child(key, remote_tool.Launch)
    as "launch child origin validates"
  assert custody.admit_child(
      store,
      origin,
      child_id(1),
      payload("launch request"),
    )
    == Ok(Nil)
  assert custody.close(store) == Ok(Nil)
  let assert Ok(db) = sqlight.open(path) as "child corruption connection opens"
  assert sqlight.exec(
      "UPDATE owner_custody_children SET terminal = zeroblob(1048576)",
      db,
    )
    == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
  let assert Ok(store) =
    custody.open(path, remote_tool.session(key), ceilings())
    as "metadata opens without decoding terminal bytes"
  assert custody.child(store, origin)
    == Error(custody.Invalid(
      "owner payload exceeds bound before materialization",
    ))
  assert custody.receive_child(
      store,
      origin,
      child_id(1),
      payload("small terminal"),
    )
    == Error(custody.Invalid(
      "owner payload exceeds bound before materialization",
    ))
  assert custody.close(store) == Ok(Nil)
}

pub fn underreserved_corrupt_rows_are_refused_before_payload_fetch_test() {
  let key = identity(0, "a", 1)
  let #(path, store) = open("underreserved-corruption", key)
  assert custody.admit(store, key, payload("args"), payload("request"))
    == Ok(Nil)
  assert custody.close(store) == Ok(Nil)
  let assert Ok(db) = sqlight.open(path) as "corruption fixture opens"
  assert sqlight.exec("UPDATE owner_custody_tools SET reserved_bytes = 0", db)
    == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
  let assert Ok(store) =
    custody.open(path, remote_tool.session(key), ceilings())
    as "metadata opens independently of row payloads"
  let assert Error(custody.Invalid(_)) = custody.lookup(store, key)
    as "header accounting refuses before the value query"
  assert custody.close(store) == Ok(Nil)
}

fn finalized_message() -> message.AgentMessage {
  message.ToolResultMessage(
    tool_call_id: "call",
    tool_name: "remote",
    content: [message.ToolResultText("final", None)],
    details: None,
    usage: None,
    added_tool_names: None,
    is_error: False,
    timestamp: 1,
  )
}

fn validate(
  payload: custody.Payload,
  readback: custody.ResultReadback,
) -> Result(Nil, String) {
  use text <- result.try(
    bit_array.to_string(custody.bytes(payload))
    |> result.replace_error("invalid UTF-8"),
  )
  use json <- result.try(
    json.parse(text) |> result.replace_error("invalid JSON"),
  )
  use expected <- result.try(
    codec.decode_message(json) |> result.replace_error("invalid message"),
  )
  case
    readback.message == expected && readback.termination == custody.Continues
  {
    True -> Ok(Nil)
    False -> Error("session result differs from owner final outcome")
  }
}

pub fn only_exact_committed_reserved_result_entry_can_collect_test() {
  let key = identity(0, "a", 1)
  let #(_path, store) = open("collection", key)
  let root = fixtures.scratch("owner-custody-session-result")
  let assert Ok(session_store) =
    sqlite.open(
      sqlite.config(root <> "/session.db", "custody-test"),
      clock.stepping(1000, 1),
    )
    as "actual session SQLite opens"
  assert custody.admit(store, key, payload("args"), payload("request"))
    == Ok(Nil)
  let outcome =
    finalized_message() |> codec.encode_message |> json.to_string |> payload
  assert custody.finish(store, key, outcome) == Ok(Nil)
  let assert Error(_) =
    custody.verify_commit(store, key, session_store, validate)
    as "final custody alone cannot collect before session commit/readback"
  let wrong_id = child_id(101)
  let wrong_entry =
    entry.MessageEntry(
      id: wrong_id,
      parent: None,
      seq: 0,
      ts: 0,
      message: finalized_message(),
      terminate: False,
    )
  let assert Ok(_) =
    storage.commit(
      session_store,
      tx.Tx(
        [
          tx.InsertEntry(wrong_entry),
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
    as "an unrelated result entry commits"
  let assert Error(_) =
    custody.verify_commit(store, key, session_store, validate)
    as "another entry cannot stand in for the reserved entry"
  let exact_entry =
    entry.MessageEntry(..wrong_entry, id: remote_tool.result_entry(key))
  let assert Ok(_) =
    storage.commit(session_store, tx.Tx([tx.InsertEntry(exact_entry)], []))
    as "exact result commits at the originally reserved entry"
  let assert Ok(proof) =
    custody.verify_commit(store, key, session_store, validate)
    as "collection proof requires readback and exact outcome validation"
  assert custody.collect(store, proof) == Error(custody.CollectionPending)
  assert custody.discharge(store, key, outcome) == Ok(Nil)
  assert custody.collect(store, proof) == Ok(Nil)
  assert custody.collect(store, proof) == Ok(Nil)
  assert custody.unreleased(store) == Ok(custody.Released)
  assert custody.lookup(store, key) == Ok(custody.Collected)
  assert custody.admit(store, key, payload("args"), payload("request"))
    == Error(custody.Frozen)
  assert custody.finish(store, key, outcome) == Error(custody.Frozen)
  assert custody.lookup(store, identity(0, "b", 1)) == Error(custody.Conflict)
  assert custody.close(store) == Ok(Nil)
  assert storage.close(session_store) == Ok(Nil)
}

pub fn result_readback_checks_content_termination_and_session_identity_test() {
  let key = identity(0, "a", 1)
  let #(_path, store) = open("readback-conflicts", key)
  let root = fixtures.scratch("owner-custody-session-readback-conflicts")
  let assert Ok(session_store) =
    sqlite.open(
      sqlite.config(root <> "/session.db", "custody-test"),
      clock.stepping(1000, 1),
    )
    as "actual result readback SQLite opens"
  assert custody.admit(store, key, payload("args"), payload("request"))
    == Ok(Nil)
  let outcome =
    finalized_message() |> codec.encode_message |> json.to_string |> payload
  assert custody.finish(store, key, outcome) == Ok(Nil)
  let result =
    entry.MessageEntry(
      id: remote_tool.result_entry(key),
      parent: None,
      seq: 0,
      ts: 0,
      message: finalized_message(),
      terminate: True,
    )
  let assert Ok(_) =
    storage.commit(
      session_store,
      tx.Tx(
        [
          tx.InsertEntry(result),
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
    as "wrong termination commits under the reserved identity"
  let assert Error(custody.Invalid(_)) =
    custody.verify_commit(store, key, session_store, validate)
    as "equal message bytes cannot hide changed termination"
  let assert Error(custody.Invalid(_)) =
    custody.verify_commit(store, key, session_store, fn(_, readback) {
      case readback.message == message.UserMessage([], 0, None) {
        True -> Ok(Nil)
        False -> Error("wrong finalized content")
      }
    })
    as "readback content is the actual committed message"
  let #(other_session, _) =
    ids.mint_session(ids.generator(clock.fixed(3000), 8))
  let assert Ok(_) =
    storage.commit(
      session_store,
      tx.Tx(
        [
          tx.SetRegister(
            register.FactCustom,
            "session/id",
            register.value(json.String(ids.session_id_to_string(other_session))),
          ),
        ],
        [],
      ),
    )
    as "corruption fixture impersonates another session identity"
  assert custody.verify_commit(store, key, session_store, fn(_, _) { Ok(Nil) })
    == Error(custody.Conflict)
  assert custody.lookup(store, key) == Ok(custody.FinalOutcome(outcome))
  assert custody.close(store) == Ok(Nil)
  assert storage.close(session_store) == Ok(Nil)
}

pub fn corrupt_sqlite_text_payload_is_refused_at_header_before_decoder_test() {
  let key = identity(0, "a", 1)
  let #(path, store) = open("text-corruption", key)
  assert custody.admit(store, key, payload("args"), payload("request"))
    == Ok(Nil)
  assert custody.close(store) == Ok(Nil)
  let assert Ok(db) = sqlight.open(path) as "corruption connection opens"
  assert sqlight.exec(
      "UPDATE owner_custody_tools SET arguments = CAST(zeroblob(1048576) AS TEXT)",
      db,
    )
    == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
  let assert Ok(store) =
    custody.open(path, remote_tool.session(key), ceilings())
    as "metadata opens"
  assert custody.lookup(store, key)
    == Error(custody.Invalid(
      "owner payload exceeds bound before materialization",
    ))
  assert custody.close(store) == Ok(Nil)
}

pub fn session_binding_and_persisted_quotas_cannot_change_on_reopen_test() {
  let key = identity(0, "a", 1)
  let #(path, store) = open("binding", key)
  assert custody.close(store) == Ok(Nil)
  let #(other, _) = ids.mint_session(ids.generator(clock.fixed(3000), 8))
  assert custody.open(path, other, ceilings()) == Error(custody.Conflict)
  let assert Ok(changed) = custody.limits(9, 32, 131_072, 1024)
    as "changed ceilings validate independently"
  assert custody.open(path, remote_tool.session(key), changed)
    == Error(custody.Conflict)
}

pub fn source_and_embedded_owner_schema_are_identical_test() {
  let assert Ok(source) = simplifile.read("sql/owner_custody.sql")
    as "schema source exists"
  assert source == owner_custody_schema.schema
}

// Restoring named placeholders tests sqlc output against source, including
// repeated parameters. Merely finding query names would miss generated drift.
fn named(text: String, names: List(String)) -> String {
  list.index_fold(names, text, fn(text, name, index) {
    string.replace(text, "?" <> int.to_string(index + 1), "@" <> name)
  })
}

fn normalized(text: String) -> String {
  text
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(fn(line) { line != "" && !string.starts_with(line, "--") })
  |> list.map(fn(line) { string.replace(line, ";", "") })
  |> string.join("\n")
}

pub fn generated_owner_queries_match_named_sql_source_test() {
  let assert Ok(source) = simplifile.read("src/storage/sql/owner_custody.sql")
    as "named query source exists"
  let empty = <<>>
  let generated = [
    sql.owner_custody_metadata().0,
    named(sql.initialize_owner_custody("", 0, 0, 0, 0).0, [
      "session_id",
      "tool_limit",
      "child_limit",
      "byte_limit",
      "payload_limit",
    ]),
    sql.owner_custody_budget().0,
    named(sql.owner_tool_header("").0, ["address"]),
    named(sql.owner_tool_value("", 0).0, ["address", "payload_limit"]),
    named(sql.insert_owner_tool("", empty, "", empty, empty, 0).0, [
      "address",
      "identity",
      "result_entry",
      "arguments",
      "request",
      "reserved_bytes",
    ]),
    named(sql.finish_owner_tool(None, "").0, ["outcome", "address"]),
    named(sql.freeze_owner_tool("").0, ["address"]),
    named(sql.owner_child_header("").0, ["origin"]),
    named(sql.owner_child_value("", 0).0, ["origin", "payload_limit"]),
    named(sql.owner_child_count("").0, ["parent"]),
    named(sql.insert_owner_child("", "", Some(""), empty, 0).0, [
      "origin",
      "parent",
      "request_id",
      "request",
      "reserved_bytes",
    ]),
    named(sql.finish_owner_child(None, "").0, ["terminal", "origin"]),
    named(sql.freeze_owner_children("").0, ["parent"]),
    named(sql.cancel_owner_child("", "", 0).0, [
      "origin", "parent", "reserved_bytes",
    ]),
    sql.owner_legacy_custody_budget().0,
    named(sql.owner_legacy_invalid_headers(0).0, ["payload_limit"]),
    named(sql.owner_command_offer_header("").0, ["address"]),
    named(sql.owner_command_offer_header_by_native_origin("").0, [
      "native_origin",
    ]),
    named(sql.owner_command_offer_value("", 0).0, ["address", "offer_limit"]),
    named(sql.owner_command_offer_count("").0, ["parent"]),
    named(
      sql.insert_owner_command_offer("", "", "", "", empty, "", "", empty, 0).0,
      [
        "address",
        "parent",
        "service_origin",
        "service_id",
        "identity",
        "native_origin",
        "offer_digest",
        "offer",
        "reserved_bytes",
      ],
    ),
    named(sql.cancel_owner_command_offers("").0, ["service_origin"]),
    named(sql.cancel_owner_allocated_child("").0, ["origin"]),
    sql.owner_unreleased_run().0,
    named(sql.discharge_owner_run("", None).0, ["address", "outcome"]),
  ]
  assert normalized(source) == normalized(string.join(generated, "\n"))
}

// Fresh custody survives each crash boundary even when final bytes already exist.
pub fn run_custody_requires_exact_final_and_retains_unreleased_on_reopen_test() {
  let key = identity(0, "a", 55)
  let #(path, store) = open("unreleased-reopen", key)
  assert custody.unreleased(store) == Ok(custody.Released)
  assert custody.admit_fresh(store, key, payload("args"), payload("request"))
    == Ok(custody.Fresh)
  assert custody.unreleased(store) == Ok(custody.Unreleased)
  assert custody.discharge(store, key, payload("final"))
    == Error(custody.Missing)
  assert custody.close(store) == Ok(Nil)
  let assert Ok(store) =
    custody.open(path, remote_tool.session(key), ceilings())
    as "Fresh COMMIT before spawn keeps run custody on reopen."
  assert custody.unreleased(store) == Ok(custody.Unreleased)
  assert custody.finish(store, key, payload("final")) == Ok(Nil)
  assert custody.close(store) == Ok(Nil)
  let assert Ok(store) =
    custody.open(path, remote_tool.session(key), ceilings())
    as "Outcome COMMIT before drain keeps run custody on reopen."
  assert custody.unreleased(store) == Ok(custody.Unreleased)
  assert custody.discharge(store, key, payload("changed"))
    == Error(custody.Conflict)
  assert custody.unreleased(store) == Ok(custody.Unreleased)
  assert custody.discharge(store, key, payload("final")) == Ok(Nil)
  assert custody.unreleased(store) == Ok(custody.Released)
  assert custody.close(store) == Ok(Nil)
}

pub fn failed_discharge_transaction_retains_unreleased_test() {
  let key = identity(0, "a", 56)
  let #(path, store) = open("failed-discharge", key)
  assert custody.admit(store, key, payload("args"), payload("request"))
    == Ok(Nil)
  assert custody.finish(store, key, payload("final")) == Ok(Nil)
  let assert Ok(db) = sqlight.open(path)
    as "The fixture injects a deferred COMMIT failure."
  assert sqlight.exec(
      "CREATE TABLE discharge_parent (id INTEGER PRIMARY KEY); CREATE TABLE discharge_guard (ref INTEGER REFERENCES discharge_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER reject_discharge AFTER UPDATE OF run_custody ON owner_custody_tools BEGIN INSERT INTO discharge_guard(ref) VALUES (1); END",
      db,
    )
    == Ok(Nil)
  let assert Error(custody.Conflict) =
    custody.discharge(store, key, payload("final"))
    as "A failed transaction cannot release a run."
  assert custody.unreleased(store) == Ok(custody.Unreleased)
  assert custody.close(store) == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
}

pub fn previous_owner_formats_refuse_missing_discharge_proof_test() {
  let key = identity(0, "a", 57)
  let #(path, store) = open("previous-format", key)
  assert custody.admit(store, key, payload("args"), payload("request"))
    == Ok(Nil)
  assert custody.finish(store, key, payload("historical final")) == Ok(Nil)
  assert custody.close(store) == Ok(Nil)
  let assert Ok(db) = sqlight.open(path) as "The fixture owns this journal."
  assert sqlight.exec(
      "DROP INDEX owner_tool_run_custody; ALTER TABLE owner_custody_tools DROP COLUMN run_custody; PRAGMA user_version=3",
      db,
    )
    == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
  assert custody.open(path, remote_tool.session(key), ceilings())
    == Error(custody.Invalid("unsupported owner custody database"))
}
