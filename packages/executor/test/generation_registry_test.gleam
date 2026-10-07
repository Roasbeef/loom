//// Real SQLite generation-custody controls, independent from physical assembly.
////
//// Trusted verifiers in this component fixture validate fixed original evidence.
//// They do not simulate native cleanup or endpoint transport. The assertions
//// cover the DAL's durable ordering, exact identities and finite reservations.

import core/generation as g
import core/ids
import core/msgpack as mp
import core/workspace
import executor/generation_registry as r
import executor/generation_registry_schema
import gleam/crypto
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import simplifile
import sqlight
import weft

pub fn selected_numeric_profile_and_schema_source_parity_test() {
  assert r.limits(16, 4096, 268_435_456) == Ok(r.selected_limits())
  list.each(
    [#(0, 1, 1), #(17, 1, 1), #(1, 4097, 1), #(1, 1, 268_435_457)],
    fn(bound) {
      assert r.limits(bound.0, bound.1, bound.2) == Error(r.InvalidLimits)
    },
  )
  let assert Ok(text) = simplifile.read("sql/generations.sql")
    as "schema source"
  assert text == generation_registry_schema.schema
}

pub fn first_claim_duplicates_and_original_door_conflicts_test() {
  fixture("original", limits(2, 4, 200_000), fn(path, store) {
    let original = association(1, 1, g.FirstGeneration)
    let assert Ok(r.Fresh(claim)) = r.admit(store, original, doors(1), 1, None)
      as "one original claim"
    assert r.original(claim) == original
    assert r.admit(store, original, doors(1), 1, None)
      == Ok(r.Retained(r.Claimed))
    assert r.admit(store, original, doors(2), 1, None) == Error(r.Conflict)
    let changed = association_with_owner(original, 99)
    assert r.admit(store, changed, doors(1), 1, None) == Error(r.Conflict)
    assert r.release(store) == Ok(Nil)
    let assert Ok(restored) = r.recover(path, uuid(9), limits(2, 4, 200_000))
      as "historical reopen"
    assert r.admit(restored, original, doors(1), 1, None)
      == Ok(r.Retained(r.Unknown))
    assert r.prepare_publication(claim, digest(1)) == Error(r.Uncertain)
    assert r.release(restored) == Ok(Nil)
  })
}

pub fn close_before_activate_is_a_permanent_no_claim_fence_test() {
  fixture("no-claim", limits(1, 3, 200_000), fn(path, store) {
    let original = association(1, 1, g.FirstGeneration)
    let key = g.association_key(original)
    assert r.close_generation(store, key) == Ok(r.Retired)
    let assert Ok(retired) = r.retirement(store, key)
      as "durable never-started record"
    assert r.retirement_fields(retired).1 == r.NeverStarted
    assert r.admit(store, original, doors(1), 1, None) == Error(r.Fenced)
    assert r.close_generation(store, key) == Ok(r.Retired)

    // NeverStarted did not allocate or release a startup slot.
    let assert Ok(r.Fresh(_)) =
      r.admit(store, association(2, 1, g.FirstGeneration), doors(2), 1, None)
      as "unrelated original claim"
    assert r.release(store) == Ok(Nil)
    let assert Ok(restored) = r.recover(path, uuid(9), limits(1, 3, 200_000))
      as "persistent close fence"
    assert r.admit(restored, original, doors(1), 1, None) == Error(r.Fenced)
    assert r.retirement(restored, key) == Ok(retired)
    assert r.release(restored) == Ok(Nil)
  })
}

pub fn publishing_commit_and_close_fence_ordering_test() {
  fixture("publication", limits(2, 4, 200_000), fn(path, store) {
    let original = association(1, 1, g.FirstGeneration)
    let assert Ok(r.Fresh(claim)) = r.admit(store, original, doors(1), 1, None)
      as "startup claim"
    let assert Ok(permit) = r.prepare_publication(claim, digest(6))
      as "publication intent committed"
    assert scalar(path, "SELECT phase FROM generation_record") == 1
    assert r.prepare_publication(claim, digest(6)) == Error(r.Fenced)
    assert r.close_generation(store, g.association_key(original))
      == Ok(r.Closing)
    assert r.published(permit) == Error(r.Fenced)
    assert r.retire_started(
        claim,
        evidence(r.UnpublishedFenced),
        verify_started,
      )
      == Error(r.Conflict)
    assert r.retire_started(
        claim,
        evidence(r.PublishedFencedDrained(digest(7))),
        verify_started,
      )
      == Error(r.Conflict)
    let assert Ok(retired) =
      r.retire_started(
        claim,
        evidence(r.PublishedFencedDrained(digest(6))),
        verify_started,
      )
      as "all original published witnesses"
    assert r.retirement(store, g.association_key(original)) == Ok(retired)
    assert scalar(path, "SELECT live FROM generation_record") == 1

    // A failed removal acknowledgement retains its original charged slot.
    assert r.remove(store, retired, fn(_) { Error(r.Uncertain) })
      == Error(r.Uncertain)
    assert scalar(path, "SELECT live FROM generation_record") == 1
    assert r.remove(store, retired, verify_removed) == Ok(Nil)
    assert scalar(path, "SELECT phase FROM generation_record") == 5
    assert scalar(path, "SELECT live FROM generation_record") == 0
    assert r.remove(store, retired, verify_removed) == Ok(Nil)
    assert r.retirement(store, g.association_key(original)) == Ok(retired)
  })
}

pub fn interrupted_claim_and_publication_keep_original_capacity_test() {
  list.each([0, 1, 2], fn(phase) {
    fixture("recovery", limits(1, 4, 200_000), fn(path, store) {
      let original = association(1, 1, g.FirstGeneration)
      let assert Ok(r.Fresh(claim)) =
        r.admit(store, original, doors(1), 1, None)
        as "original claim"
      case phase {
        0 -> Nil
        _ -> {
          let assert Ok(permit) = r.prepare_publication(claim, digest(6))
            as "original publication intent"
          case phase {
            2 -> {
              assert r.published(permit) == Ok(Nil)
            }
            _ -> Nil
          }
        }
      }
      assert r.release(store) == Ok(Nil)
      let assert Ok(restored) = r.recover(path, uuid(8), limits(1, 4, 200_000))
        as "unavailable original custody"
      assert r.observe(restored, g.association_key(original)) == Ok(r.Unknown)
      assert r.admit(restored, original, doors(1), 1, None)
        == Ok(r.Retained(r.Unknown))
      assert r.admit(
          restored,
          association(2, 1, g.FirstGeneration),
          doors(2),
          1,
          None,
        )
        == Error(r.Capacity)
      assert r.retirement(restored, g.association_key(original))
        == Error(r.Missing)
      assert r.close_generation(restored, g.association_key(original))
        == Ok(r.Unknown)
      assert scalar(path, "SELECT live FROM generation_record") == 1
      assert r.release(restored) == Ok(Nil)
    })
  })
}

pub fn actual_sixteen_global_slots_require_removed_before_reuse_test() {
  fixture("sixteen", limits(16, 32, 2_000_000), fn(path, store) {
    let claims =
      list.index_map(list.repeat(Nil, 16), fn(_, index) {
        let number = index + 1
        let original = association(number, 1, g.FirstGeneration)
        let assert Ok(r.Fresh(claim)) =
          r.admit(store, original, doors(number), 1, None)
          as "global original claim"
        claim
      })
    let next = association(17, 1, g.FirstGeneration)
    assert r.admit(store, next, doors(17), 1, None) == Error(r.Capacity)
    let assert [first, ..] = claims as "first of sixteen claims"
    let key = g.association_key(r.original(first))
    assert r.close_generation(store, key) == Ok(r.Closing)
    let assert Ok(retired) =
      r.retire_started(first, evidence(r.UnpublishedFenced), verify_started)
      as "never published full retirement"
    assert r.admit(store, next, doors(17), 1, None) == Error(r.Capacity)
    assert r.remove(store, retired, verify_removed) == Ok(Nil)
    let assert Ok(r.Fresh(_)) = r.admit(store, next, doors(17), 1, None)
      as "only committed removal returned slot"
    assert scalar(path, "SELECT COUNT(*) FROM generation_record") == 17
    assert scalar(path, "SELECT SUM(live) FROM generation_record") == 16
    assert r.admit(store, r.original(first), doors(1), 1, None)
      == Ok(r.Retained(r.Removed))
  })
}

pub fn permanent_row_and_byte_quotas_include_no_claim_close_test() {
  fixture("rows", limits(1, 2, 200_000), fn(path, store) {
    list.each([1, 2], fn(number) {
      assert r.close_generation(
          store,
          g.association_key(association(number, 1, g.FirstGeneration)),
        )
        == Ok(r.Retired)
    })
    assert r.close_generation(
        store,
        g.association_key(association(3, 1, g.FirstGeneration)),
      )
      == Error(r.Capacity)
    assert scalar(path, "SELECT COUNT(*) FROM generation_record") == 2
    assert r.close_generation(
        store,
        g.association_key(association(1, 1, g.FirstGeneration)),
      )
      == Ok(r.Retired)
  })
  fixture("bytes", limits(1, 4, 1), fn(path, store) {
    assert r.close_generation(
        store,
        g.association_key(association(1, 1, g.FirstGeneration)),
      )
      == Error(r.Capacity)
    assert r.admit(
        store,
        association(1, 1, g.FirstGeneration),
        doors(1),
        1,
        None,
      )
      == Error(r.Capacity)
    assert scalar(path, "SELECT COUNT(*) FROM generation_record") == 0
  })
}

pub fn immediate_successor_requires_full_original_node_and_owner_proof_test() {
  fixture("successor", limits(1, 4, 200_000), fn(path, store) {
    let previous = association(1, 1, g.FirstGeneration)
    let assert Ok(r.Fresh(claim)) = r.admit(store, previous, doors(1), 1, None)
      as "first generation"
    assert r.close_generation(store, g.association_key(previous))
      == Ok(r.Closing)
    let assert Ok(node) =
      r.retire_started(claim, evidence(r.UnpublishedFenced), verify_started)
      as "committed predecessor retirement"
    let node_hash = r.retirement_fields(node).3
    let owner_bytes = doors(90)
    assert r.attest_predecessor(store, previous, owner_bytes, fn(_, _, _) {
        Error(r.Conflict)
      })
      == Error(r.Conflict)
    let assert Ok(proof) =
      r.attest_predecessor(store, previous, owner_bytes, verify_owner)
      as "authenticated original owner joins"
    let owner_hash = hash(owner_bytes)
    let next =
      association_with_owner(
        association(1, 2, g.Successor(node_hash, owner_hash)),
        2,
      )

    // Node retirement alone is insufficient: original removal must commit.
    assert r.admit(store, next, doors(2), 1, Some(proof)) == Error(r.Fenced)
    assert r.remove(store, node, verify_removed) == Ok(Nil)
    assert r.admit(
        store,
        association(1, 2, g.Successor(node_hash, owner_hash)),
        doors(2),
        1,
        Some(proof),
      )
      == Error(r.Conflict)
    let changed =
      association_with_owner(
        association(1, 2, g.Successor(owner_hash, node_hash)),
        2,
      )
    assert r.admit(store, changed, doors(2), 1, Some(proof))
      == Error(r.Conflict)
    let assert Ok(r.Fresh(_)) = r.admit(store, next, doors(2), 1, Some(proof))
      as "exact immediate clean successor"
    assert r.attest_predecessor(store, previous, doors(91), verify_owner)
      == Error(r.Conflict)
    assert scalar(path, "SELECT COUNT(*) FROM generation_record") == 2
  })
}

pub fn no_claim_predecessor_survives_reopen_with_full_owner_association_test() {
  fixture("never-successor", limits(1, 4, 200_000), fn(path, store) {
    let previous = association(1, 3, g.FirstGeneration)
    let key = g.association_key(previous)
    assert r.close_generation(store, key) == Ok(r.Retired)
    let assert Ok(node) = r.retirement(store, key)
      as "never started node predecessor"
    let bytes = doors(90)
    let assert Ok(proof) =
      r.attest_predecessor(store, previous, bytes, verify_owner)
      as "full owner association bound even without node claim"
    let next =
      association_with_owner(
        association(1, 4, g.Successor(r.retirement_fields(node).3, hash(bytes))),
        2,
      )
    let assert Ok(r.Fresh(_)) = r.admit(store, next, doors(2), 3, Some(proof))
      as "configured first three then exact four"
    assert r.release(store) == Ok(Nil)
    let assert Ok(restored) = r.recover(path, uuid(8), limits(1, 4, 200_000))
      as "full immutable predecessor records"
    assert r.attest_predecessor(restored, previous, bytes, verify_owner)
      |> result.is_ok
    assert r.retirement(restored, key) == Ok(node)
    assert r.release(restored) == Ok(Nil)
  })
}

pub fn suppressed_retirement_update_and_failed_commit_issue_no_record_or_claim_test() {
  fixture("suppressed", limits(1, 4, 200_000), fn(path, store) {
    let original = association(1, 1, g.FirstGeneration)
    let assert Ok(r.Fresh(claim)) = r.admit(store, original, doors(1), 1, None)
      as "original startup"
    assert r.close_generation(store, g.association_key(original))
      == Ok(r.Closing)
    mutate(
      path,
      "CREATE TRIGGER suppress_retirement BEFORE UPDATE OF retirement ON generation_record BEGIN SELECT RAISE(IGNORE); END;",
    )
    assert r.retire_started(
        claim,
        evidence(r.UnpublishedFenced),
        verify_started,
      )
      == Error(r.Uncertain)
    let assert Ok(restored) = r.recover(path, uuid(8), limits(1, 4, 200_000))
      as "failed update recovery"
    assert r.retirement(restored, g.association_key(original))
      == Error(r.Missing)
    assert r.observe(restored, g.association_key(original)) == Ok(r.Unknown)
    assert r.release(restored) == Ok(Nil)
  })
  fixture("commit", limits(1, 4, 200_000), fn(path, store) {
    mutate(
      path,
      "CREATE TABLE fault_parent(id INTEGER PRIMARY KEY); CREATE TABLE fault_child(id INTEGER REFERENCES fault_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fail_commit AFTER INSERT ON generation_record BEGIN INSERT INTO fault_child VALUES(1); END;",
    )
    assert r.admit(
        store,
        association(1, 1, g.FirstGeneration),
        doors(1),
        1,
        None,
      )
      == Error(r.Uncertain)
    assert scalar(path, "SELECT COUNT(*) FROM generation_record") == 0
  })
}

pub fn corruption_is_refused_before_oversized_body_or_new_claim_test() {
  fixture("corrupt", limits(1, 4, 200_000), fn(path, store) {
    let original = association(1, 1, g.FirstGeneration)
    let assert Ok(r.Fresh(_)) = r.admit(store, original, doors(1), 1, None)
      as "original row"
    assert r.release(store) == Ok(Nil)
    mutate(
      path,
      "PRAGMA ignore_check_constraints=ON; UPDATE generation_record SET doors=zeroblob(4097);",
    )
    assert r.recover(path, uuid(8), limits(1, 4, 200_000)) == Error(r.Corrupt)
    assert scalar(path, "SELECT COUNT(*) FROM generation_record") == 1
  })
}

pub fn independent_connections_issue_only_one_original_claim_test() {
  fixture("independent", limits(2, 4, 200_000), fn(path, store) {
    let assert Ok(other) = r.recover(path, uuid(101), limits(2, 4, 200_000))
      as "independent original connection"
    let original = association(1, 1, g.FirstGeneration)
    let results =
      [store, other]
      |> list.map(fn(endpoint) {
        fn() { r.admit(endpoint, original, doors(1), 1, None) }
      })
      |> weft.new
      |> weft.limit(2)
      |> weft.deadline(5000)
      |> weft.start
      |> weft.values
    assert list.length(results) == 2
    assert list.length(
        list.filter(results, fn(answer) {
          case answer {
            r.Fresh(_) -> True
            r.Retained(_) -> False
          }
        }),
      )
      == 1
    assert list.contains(results, r.Retained(r.Claimed))
    assert scalar(path, "SELECT COUNT(*) FROM generation_record") == 1
    assert r.release(other) == Ok(Nil)
  })
}

pub fn suppressed_first_insert_never_issues_claim_or_close_ack_test() {
  list.each([0, 1], fn(mode) {
    fixture("insert", limits(1, 4, 200_000), fn(path, store) {
      mutate(
        path,
        "CREATE TRIGGER suppress_insert BEFORE INSERT ON generation_record BEGIN SELECT RAISE(IGNORE); END;",
      )
      let original = association(1, 1, g.FirstGeneration)
      case mode {
        0 -> {
          assert r.admit(store, original, doors(1), 1, None)
            == Error(r.Uncertain)
        }
        _ -> {
          assert r.close_generation(store, g.association_key(original))
            == Error(r.Uncertain)
        }
      }
      assert scalar(path, "SELECT COUNT(*) FROM generation_record") == 0
    })
  })
}

pub fn failed_removed_commit_retains_original_record_and_slot_test() {
  fixture("remove", limits(1, 4, 200_000), fn(path, store) {
    let original = association(1, 1, g.FirstGeneration)
    let assert Ok(r.Fresh(claim)) = r.admit(store, original, doors(1), 1, None)
      as "one startup"
    assert r.close_generation(store, g.association_key(original))
      == Ok(r.Closing)
    let assert Ok(retired) =
      r.retire_started(claim, evidence(r.UnpublishedFenced), verify_started)
      as "complete original retirement"
    mutate(
      path,
      "CREATE TRIGGER suppress_removed BEFORE UPDATE OF live ON generation_record BEGIN SELECT RAISE(IGNORE); END;",
    )
    assert r.remove(store, retired, verify_removed) == Error(r.Uncertain)
    let assert Ok(restored) = r.recover(path, uuid(8), limits(1, 4, 200_000))
      as "retirement preserved after removal uncertainty"
    assert r.retirement(restored, g.association_key(original)) == Ok(retired)
    assert r.observe(restored, g.association_key(original)) == Ok(r.Retired)
    assert r.admit(
        restored,
        association(2, 1, g.FirstGeneration),
        doors(2),
        1,
        None,
      )
      == Error(r.Capacity)
    mutate(path, "DROP TRIGGER suppress_removed;")
    assert r.remove(restored, retired, verify_removed) == Ok(Nil)
    assert r.retirement(restored, g.association_key(original)) == Ok(retired)
    assert r.release(restored) == Ok(Nil)
  })
}

fn limits(live: Int, rows: Int, bytes: Int) -> r.Limits {
  let assert Ok(value) = r.limits(live, rows, bytes) as "finite selected limits"
  value
}

fn uuid(number: Int) -> ids.EntryId {
  let assert Ok(id) =
    ids.parse_entry_id(
      "00000000-0000-7000-8000-"
      <> string.pad_start(int.to_string(number), 12, "0"),
    )
    as "canonical owner-use UUID"
  id
}

fn association(
  session: Int,
  number: Int,
  predecessor: g.Predecessor,
) -> g.GenerationAssociation {
  let session_text = ids.entry_id_to_string(uuid(session))
  let assert Ok(scope) =
    workspace.scope_from_fields(session_text, "loom", "dev", 1, 1)
    as "full scope"
  let assert Ok(key) = g.key(scope, digest(1), number) as "positive generation"
  g.association(key, digest(2), uuid(session), predecessor)
}

fn association_with_owner(
  original: g.GenerationAssociation,
  owner: Int,
) -> g.GenerationAssociation {
  let #(key, enrollment, _, predecessor) = g.association_fields(original)
  g.association(key, enrollment, uuid(owner), predecessor)
}

fn digest(number: Int) -> g.Digest {
  let assert Ok(value) = g.digest(<<number:size(256)>>) as "fixed digest"
  value
}

fn hash(bytes: BitArray) -> g.Digest {
  let assert Ok(value) = g.digest(crypto.hash(crypto.Sha256, bytes))
    as "exact content hash"
  value
}

fn doors(number: Int) -> BitArray {
  let assert Ok(bytes) = mp.encode(mp.ArrayValue([mp.IntValue(number)]))
    as "fixed canonical fixture doors"
  bytes
}

fn evidence(endpoint: r.EndpointWitness) -> r.StartedEvidence {
  r.StartedEvidence(
    endpoint,
    digest(11),
    digest(12),
    digest(13),
    digest(14),
    digest(15),
    digest(16),
    digest(17),
  )
}

fn verify_started(
  claim: r.StartupClaim,
  evidence: r.StartedEvidence,
) -> Result(Nil, r.Error) {
  assert g.key_fields(g.association_key(r.original(claim))).2 > 0
  assert evidence.continuations == digest(11)
  assert evidence.resources == digest(12)
  assert evidence.native_scope == digest(13)
  assert evidence.covered_keys == digest(14)
  assert evidence.services == digest(15)
  assert evidence.journals == digest(16)
  assert evidence.host == digest(17)
  Ok(Nil)
}

fn verify_removed(retired: r.RetirementRecord) -> Result(Nil, r.Error) {
  let #(_, kind, _, _) = r.retirement_fields(retired)
  assert kind != r.NeverStarted
  Ok(Nil)
}

fn verify_owner(
  previous: g.GenerationAssociation,
  node: r.RetirementRecord,
  bytes: BitArray,
) -> Result(Nil, r.Error) {
  assert g.association_key(previous) == r.retirement_fields(node).0
  assert bytes == doors(90) || bytes == doors(91)
  Ok(Nil)
}

fn fixture(
  name: String,
  limit: r.Limits,
  run: fn(String, r.Store) -> Nil,
) -> Nil {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let directory =
    "/tmp/loom-generation-"
    <> name
    <> "-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let assert Ok(Nil) = simplifile.create_directory(directory)
    as "exclusive scratch directory"
  let path = directory <> "/generations.sqlite"
  let assert Ok(store) = r.fresh(path, uuid(100), limit) as "new bounded ledger"
  run(path, store)
  let _ = r.release(store)
  let assert Ok(Nil) = simplifile.delete(directory)
    as "whole scratch directory removed"
  Nil
}

fn scalar(path: String, sql: String) -> Int {
  let assert Ok(connection) = sqlight.open(path)
    as "fixture readback connection"
  let assert Ok([value]) =
    sqlight.query(
      sql,
      connection,
      [],
      decode.field(0, decode.int, decode.success),
    )
    as "one scalar readback"
  assert sqlight.close(connection) == Ok(Nil)
  value
}

fn mutate(path: String, sql: String) -> Nil {
  let assert Ok(connection) = sqlight.open(path) as "fixture fault connection"
  assert sqlight.exec(sql, connection) == Ok(Nil)
  assert sqlight.close(connection) == Ok(Nil)
}
