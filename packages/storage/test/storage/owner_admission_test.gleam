//// Admission allowance corruption must fail before final writes or receipts.
//// Test-only SQL removes exactly the unused reservation rather than zeroing it.

import core/clock
import core/ids
import core/remote_tool
import gleam/bit_array
import gleam/dynamic/decode
import gleam/option.{Some}
import gleam/string
import sqlight
import storage/owner_custody as custody
import support/fixtures

fn key(step: String) -> remote_tool.ToolKey {
  let generator = ids.generator(clock.fixed(1000), 61)
  let #(session, generator) = ids.mint_session(generator)
  let #(operation, generator) = ids.mint_op(generator)
  let #(result, _) = ids.mint_entry(generator)
  let assert Ok(key) =
    remote_tool.key(session, operation, step, 0, string.repeat("a", 64), result)
    as "fixture full identity is valid"
  key
}

fn limits() -> custody.Limits {
  let assert Ok(limits) = custody.limits(8, 32, 262_144, 4096)
    as "fixture quotas reserve future outcome payloads"
  limits
}

fn payload(text: String) -> custody.Payload {
  let assert Ok(bytes) = custody.payload(limits(), bit_array.from_string(text))
    as "fixture payload fits finite allowance"
  bytes
}

pub fn current_size_corruption_cannot_acknowledge_tool_or_child_terminal_test() {
  let key = key("parent")
  let directory = fixtures.scratch("owner-full-reservation-corruption")
  let assert Ok(store) =
    custody.open(directory <> "/owner.db", remote_tool.session(key), limits())
    as "actual owner SQLite opens"
  assert custody.admit_fresh(
      store,
      key,
      payload("arguments"),
      payload("scope request"),
    )
    == Ok(custody.Fresh)
  assert custody.admit_fresh(
      store,
      key,
      payload("arguments"),
      payload("scope request"),
    )
    == Ok(custody.Retained)
  let assert Ok(child) = remote_tool.tool_child(key, remote_tool.Compile)
    as "child carries the exact retained parent identity"
  let id = ids.mint_entry(ids.generator(clock.fixed(2000), 10)).0
  assert custody.admit_child(store, child, id, payload("native request"))
    == Ok(Nil)
  let assert Ok(db) = sqlight.open(directory <> "/owner.db")
    as "test corruption connection opens beside idle serialized custody"
  assert sqlight.exec(
      "UPDATE owner_custody_children SET reserved_bytes = length(CAST(origin AS BLOB)) + length(CAST(parent AS BLOB)) + 36 + length(request)",
      db,
    )
    == Ok(Nil)
  let assert Error(custody.Invalid(_)) =
    custody.receive_child(store, child, id, payload("terminal receipt"))
    as "missing unused child allowance is refused before a durable receipt"
  assert sqlight.query(
      "SELECT terminal IS NULL FROM owner_custody_children",
      db,
      [],
      decode.at([0], decode.int),
    )
    == Ok([1])
  assert sqlight.exec(
      "UPDATE owner_custody_tools SET reserved_bytes = length(identity) + length(CAST(address AS BLOB)) + length(arguments) + length(request)",
      db,
    )
    == Ok(Nil)
  let assert Error(custody.Invalid(_)) =
    custody.finish(store, key, payload("final report"))
    as "missing unused final allowance is refused before live callback success"
  assert sqlight.query(
      "SELECT outcome IS NULL FROM owner_custody_tools",
      db,
      [],
      decode.at([0], decode.int),
    )
    == Ok([1])
  assert sqlight.close(db) == Ok(Nil)
  assert custody.close(store) == Ok(Nil)
}

pub fn long_escaped_workspace_step_roundtrips_through_guarded_projection_test() {
  let key = key(string.repeat("\"", 1024))
  let directory = fixtures.scratch("owner-long-escaped-step")
  let assert Ok(store) =
    custody.open(directory <> "/owner.db", remote_tool.session(key), limits())
    as "full workspace step opens owner journal"
  assert custody.admit_fresh(store, key, payload("arguments"), payload("scope"))
    == Ok(custody.Fresh)
  assert custody.finish(store, key, payload("exact report")) == Ok(Nil)
  assert custody.lookup(store, key)
    == Ok(custody.FinalOutcome(payload("exact report")))
  assert custody.close(store) == Ok(Nil)
  let assert Ok(store) =
    custody.open(directory <> "/owner.db", remote_tool.session(key), limits())
    as "header and SQL projection bounds agree after reopen"
  assert custody.lookup(store, key)
    == Ok(custody.FinalOutcome(payload("exact report")))
  assert custody.close(store) == Ok(Nil)
}

pub fn cancelled_reserved_child_retains_exact_result_and_id_test() {
  let key = key("parent")
  let directory = fixtures.scratch("owner-cancelled-link-readback")
  let assert Ok(store) =
    custody.open(directory <> "/owner.db", remote_tool.session(key), limits())
    as "cancelled link test opens"
  assert custody.admit(store, key, payload("args"), payload("request"))
    == Ok(Nil)
  let assert Ok(child) = remote_tool.tool_child(key, remote_tool.Capability(0))
    as "original capability origin validates"
  let id = ids.mint_entry(ids.generator(clock.fixed(2000), 10)).0
  assert custody.admit_child(store, child, id, payload("immutable")) == Ok(Nil)
  assert custody.cancel_child(store, child) == Ok(Nil)
  assert custody.receive_child(
      store,
      child,
      id,
      payload("exact cancelled terminal"),
    )
    == Ok(Nil)
  assert custody.child(store, child)
    == Ok(#(id, payload("immutable"), Some(payload("exact cancelled terminal"))))
  assert custody.admit_child(store, child, id, payload("immutable"))
    == Error(custody.Frozen)
  assert custody.close(store) == Ok(Nil)
}
