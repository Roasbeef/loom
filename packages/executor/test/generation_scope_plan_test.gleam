//// Real SQLite provenance controls use no service or physical-retirement host.
////
//// The named trusted component verifier checks fixed synthetic retirement
//// metadata only to exercise permanent quota retention. It establishes no
//// physical cleanup. Migration uses a pinned original format-one schema.

import broker/enrollment
import broker/exec
import broker/policy
import core/generation as g
import core/ids
import core/lsp_command as id
import core/msgpack as mp
import core/workspace
import executor/generation_registry as r
import executor/generation_scope_plan as p
import executor/generation_scope_plan_migration
import executor/remote/admission
import executor/remote/lsp_journal as lsp
import executor/remote/resource_journal as resource
import executor/remote/workspace_journal as ws
import executor/sql
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import parrot/dev
import simplifile
import sqlight
import weft

pub fn disabled_lsp_preserves_full_enrollment_paths_and_selected_limits_test() {
  let plan = selected_plan(1, p.DisabledLsp)
  let #(header, body, digest) = p.encoded(plan)
  assert p.decode(header, body, digest) == Ok(plan)
  assert p.lsp_inputs(plan) == None
  assert p.original(plan) == association_fixture(1, enrollment_fixture(1))
  assert p.enrolled(plan) == enrollment_fixture(1)
  assert p.owner_peer(plan) == "owner@owner.example.invalid"
  let assert Ok(capacity) = admission.capacity(7) as "actual native capacity"
  assert p.native(plan) == #("/state/1/native.sqlite", capacity)
  let assert Ok(workspace_limits) = ws.limits(3, 100_000)
    as "actual workspace limits"
  let assert Ok(resource_limits) = resource.limits(5, 200_000)
    as "actual resource limits"
  assert p.workspace_inputs(plan)
    == #("/state/1/workspace.sqlite", workspace_limits)
  assert p.resource_inputs(plan)
    == #("/state/1/resource.sqlite", resource_limits)
  assert p.reservation(plan)
    == bit_array.byte_size(header) + bit_array.byte_size(body) + 32
}

pub fn enabled_lsp_retains_every_ordered_profile_and_original_limits_test() {
  let profiles = profile_inventory(16)
  let selected =
    p.EnabledLsp(
      p.Journal("/state/1/lsp.sqlite", 2, 300_000),
      fixed_digest(9),
      profiles,
    )
  let plan = selected_plan(1, selected)
  let #(header, body, digest) = p.encoded(plan)
  assert p.decode(header, body, digest) == Ok(plan)
  let assert Some(#(path, lsp_limits, contract, inventory)) = p.lsp_inputs(plan)
    as "enabled original inputs"
  assert path == "/state/1/lsp.sqlite"
  assert lsp.limits(2, 300_000) == Ok(lsp_limits)
  assert contract == fixed_digest(9)
  list.index_fold(profiles, Nil, fn(_, profile, ordinal) {
    let assert Ok(checked) = id.checked_profile(inventory, ordinal)
      as "actual ordered inventory"
    assert id.selected_project(checked, profile.server, profile.workspace_root)
      |> result.is_ok
  })
  fixture(1_000_000, fn(path, store) {
    let assert Ok(r.Fresh(_)) =
      r.admit_planned(store, p.original(plan), doors(), 1, None, plan)
      as "enabled complete original SQL provenance"
    assert r.scope_plan(store, g.association_key(p.original(plan)))
      == Ok(Some(plan))
    assert r.release(store) == Ok(Nil)
    let assert Ok(restored) = r.recover(path, uuid(101), limits(1_000_000))
      as "enabled history readback"
    assert r.scope_plan(restored, g.association_key(p.original(plan)))
      == Ok(Some(plan))
    assert r.release(restored) == Ok(Nil)
  })
  assert id.checked_profile(inventory, 16) |> result.is_error
  assert make_plan(
      1,
      enrollment_fixture(1),
      p.EnabledLsp(p.Journal(path, 2, 300_000), contract, []),
    )
    == Error(p.Invalid)
  assert make_plan(
      1,
      enrollment_fixture(1),
      p.EnabledLsp(p.Journal(path, 2, 300_000), contract, profile_inventory(17)),
    )
    == Error(p.Invalid)
}

pub fn exact_scope_enrollment_path_and_profile_validation_test() {
  let enrolled = enrollment_fixture(1)
  let original = association_fixture(1, enrolled)
  let assert Ok(capacity) = admission.capacity(7) as "actual checked capacity"
  let workspace = p.Journal("/state/1/workspace.sqlite", 3, 100_000)
  let resource = p.Journal("/state/1/resource.sqlite", 5, 200_000)
  assert p.new(
      original,
      enrollment_fixture(2),
      "owner@owner.example.invalid",
      "/state/1/native.sqlite",
      capacity,
      workspace,
      resource,
      p.DisabledLsp,
    )
    == Error(p.Mismatch)
  let #(key, _, owner, predecessor) = g.association_fields(original)
  assert p.new(
      g.association(key, fixed_digest(8), owner, predecessor),
      enrolled,
      "owner@owner.example.invalid",
      "/state/1/native.sqlite",
      capacity,
      workspace,
      resource,
      p.DisabledLsp,
    )
    == Error(p.Mismatch)
  list.each(
    [
      "relative",
      "/state/../native",
      "/state//native",
      "/state/native/",
      "/state/n\u{0}",
      "/" <> string.repeat("n", 4096),
    ],
    fn(path) {
      assert p.new(
          original,
          enrolled,
          "owner@owner.example.invalid",
          path,
          capacity,
          workspace,
          resource,
          p.DisabledLsp,
        )
        == Error(p.Invalid)
    },
  )
  assert p.new(
      original,
      enrolled,
      "owner@owner.example.invalid",
      workspace.path,
      capacity,
      workspace,
      resource,
      p.DisabledLsp,
    )
    == Error(p.Invalid)
  assert p.new(
      original,
      enrolled,
      "owner@local",
      "/state/1/native.sqlite",
      capacity,
      workspace,
      resource,
      p.DisabledLsp,
    )
    == Error(p.Invalid)
  assert p.new(
      original,
      enrolled,
      "owner@owner.example.invalid",
      "/state/1/native.sqlite",
      capacity,
      p.Journal(workspace.path, 0, 1),
      resource,
      p.DisabledLsp,
    )
    == Error(p.Invalid)
}

pub fn canonical_body_integrity_and_hostile_framing_are_total_test() {
  let #(header, body, digest) = p.encoded(selected_plan(1, p.DisabledLsp))
  assert p.decode(header, <<body:bits, 0>>, digest) == Error(p.Mismatch)
  assert p.decode(<<header:bits, 0>>, body, digest) == Error(p.Mismatch)
  assert p.decode(header, body, fixed_digest(8)) == Error(p.Mismatch)
  let oversized = bit_array.from_string(string.repeat("x", 262_145))
  assert p.decode(oversized, body, digest) == Error(p.Invalid)
  assert p.decode(header, oversized, digest) == Error(p.Invalid)
  let malformed = <<0xdd, 0xff, 0xff, 0xff, 0xff>>
  assert p.decode(malformed, body, plan_hash(malformed, body))
    == Error(p.Invalid)
  let assert <<_:size(8), tail:bits>> = header as "canonical array header"
  let alternate = <<0xdc, 0, 9, tail:bits>>
  assert p.decode(alternate, body, plan_hash(alternate, body))
    == Error(p.Mismatch)
}

pub fn enrollment_above_generic_binary_ceiling_is_retained_separately_test() {
  let base = enrollment_fixture(1)
  let native = enrollment.native_facts(base)
  let long_paths =
    list.index_map(list.repeat(Nil, 30), fn(_, n) {
      "/immutable/" <> int.to_string(n) <> string.repeat("x", 4080)
    })
  let protected =
    list.index_map(list.repeat(Nil, 3), fn(_, n) {
      "/reserved/" <> int.to_string(n) <> string.repeat("y", 4080)
    })
  let assert Ok(large) =
    enrollment.new(
      enrollment.NativeFacts(
        ..native,
        ceiling: policy.SandboxPolicy(
          ..native.ceiling,
          readable_roots: ["/tc", "/seed", ..long_paths],
          protected: protected,
        ),
      ),
      enrollment.code_mode_facts(base),
      enrollment.digests(base).0,
      enrollment.digests(base).1,
    )
    as "existing valid large enrollment"
  let assert Ok(plan) = make_plan(1, large, p.DisabledLsp)
    as "separate original body"
  let #(header, body, digest) = p.encoded(plan)
  assert bit_array.byte_size(body) > 131_072
  assert bit_array.byte_size(body) <= 262_144
  assert p.decode(header, body, digest) == Ok(plan)
  fixture(1_000_000, fn(path, store) {
    let assert Ok(r.Fresh(_)) =
      r.admit_planned(store, p.original(plan), doors(), 1, None, plan)
      as "actual original large-body insertion"
    assert r.scope_plan(store, g.association_key(p.original(plan)))
      == Ok(Some(plan))
    assert scalar(path, "SELECT length(enrollment) FROM generation_scope_plan")
      == bit_array.byte_size(body)
  })
}

pub fn exact_first_duplicate_original_plan_and_recovered_observation_test() {
  fixture(1_000_000, fn(path, store) {
    let plan = selected_plan(1, p.DisabledLsp)
    let original = p.original(plan)
    let key = g.association_key(original)
    let assert Ok(r.Fresh(claim)) =
      r.admit_planned(store, original, doors(), 1, None, plan)
      as "only first committed planned admission"
    assert r.original(claim) == original
    assert r.scope_plan(store, key) == Ok(Some(plan))
    assert r.admit_planned(store, original, doors(), 1, None, plan)
      == Ok(r.Retained(r.Claimed))
    assert r.admit(store, original, doors(), 1, None)
      == Ok(r.Retained(r.Claimed))
    assert r.admit_planned(
        store,
        p.original(selected_plan(2, p.DisabledLsp)),
        doors(),
        1,
        None,
        plan,
      )
      == Error(r.Conflict)
    list.each(changed_plans(plan), fn(changed) {
      assert r.admit_planned(store, original, doors(), 1, None, changed)
        == Error(r.Conflict)
    })
    assert scalar(path, "SELECT COUNT(*) FROM generation_record") == 1
    assert scalar(path, "SELECT COUNT(*) FROM generation_scope_plan") == 1
    let charged = scalar(path, "SELECT SUM(reservation) FROM generation_record")
    assert r.release(store) == Ok(Nil)
    let assert Ok(restored) = r.recover(path, uuid(101), limits(1_000_000))
      as "recovery observes original plan without a new claim"
    assert r.scope_plan(restored, key) == Ok(Some(plan))
    assert r.admit_planned(restored, original, doors(), 1, None, plan)
      == Ok(r.Retained(r.Unknown))
    assert scalar(path, "SELECT SUM(reservation) FROM generation_record")
      == charged
    assert r.prepare_publication(claim, fixed_digest(1)) == Error(r.Uncertain)
    assert r.release(restored) == Ok(Nil)
  })
}

pub fn independent_original_writers_issue_one_planned_claim_test() {
  fixture(1_000_000, fn(path, store) {
    let assert Ok(other) = r.recover(path, uuid(101), limits(1_000_000))
      as "second original writer"
    let plan = selected_plan(1, p.DisabledLsp)
    let answers =
      [store, other]
      |> list.map(fn(endpoint) {
        fn() {
          r.admit_planned(endpoint, p.original(plan), doors(), 1, None, plan)
        }
      })
      |> weft.new
      |> weft.limit(2)
      |> weft.deadline(5000)
      |> weft.start
      |> weft.values
    assert list.length(answers) == 2
    assert list.contains(answers, r.Retained(r.Claimed))
    assert list.length(
        list.filter(answers, fn(answer) {
          case answer {
            r.Fresh(_) -> True
            r.Retained(_) -> False
          }
        }),
      )
      == 1
    assert scalar(path, "SELECT COUNT(*) FROM generation_scope_plan") == 1
    assert r.scope_plan(other, g.association_key(p.original(plan)))
      == Ok(Some(plan))
    assert r.release(other) == Ok(Nil)
  })
}

pub fn parent_child_atomic_rollback_and_exact_readback_test() {
  list.each(
    [
      "CREATE TRIGGER reject_parent BEFORE INSERT ON generation_record BEGIN SELECT RAISE(ABORT,'fixture'); END;",
      "CREATE TRIGGER reject_plan BEFORE INSERT ON generation_scope_plan BEGIN SELECT RAISE(ABORT,'fixture'); END;",
      "CREATE TRIGGER suppress_plan BEFORE INSERT ON generation_scope_plan BEGIN SELECT RAISE(IGNORE); END;",
      "CREATE TRIGGER change_plan AFTER INSERT ON generation_scope_plan BEGIN UPDATE generation_scope_plan SET digest=zeroblob(32); END;",
    ],
    fn(trigger) {
      fixture(1_000_000, fn(path, store) {
        mutate(path, trigger)
        let plan = selected_plan(1, p.DisabledLsp)
        assert r.admit_planned(store, p.original(plan), doors(), 1, None, plan)
          == Error(r.Uncertain)
        assert scalar(path, "SELECT COUNT(*) FROM generation_record") == 0
        assert scalar(path, "SELECT COUNT(*) FROM generation_scope_plan") == 0
        assert scalar(
            path,
            "SELECT COALESCE(SUM(reservation),0) FROM generation_record",
          )
          == 0
      })
    },
  )
}

pub fn failed_commit_never_issues_planned_startup_authority_test() {
  fixture(1_000_000, fn(path, store) {
    mutate(
      path,
      "CREATE TABLE commit_failure(key BLOB REFERENCES generation_record(key) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER block_commit AFTER INSERT ON generation_scope_plan BEGIN INSERT INTO commit_failure VALUES(X'ff'); END;",
    )
    let plan = selected_plan(1, p.DisabledLsp)
    assert r.admit_planned(store, p.original(plan), doors(), 1, None, plan)
      == Error(r.Uncertain)
    assert scalar(path, "SELECT COUNT(*) FROM generation_record") == 0
    assert scalar(path, "SELECT COUNT(*) FROM generation_scope_plan") == 0
  })
}

pub fn both_bodies_are_charged_before_any_claim_test() {
  let plan = selected_plan(1, p.DisabledLsp)
  let #(header, body, _) = p.encoded(plan)
  let base = legacy_charge()
  list.each(
    [
      base,
      base + bit_array.byte_size(header) + 32,
      base + bit_array.byte_size(body) + 32,
    ],
    fn(bytes) {
      fixture(bytes, fn(path, store) {
        assert r.admit_planned(store, p.original(plan), doors(), 1, None, plan)
          == Error(r.Capacity)
        assert scalar(path, "SELECT COUNT(*) FROM generation_record") == 0
        assert scalar(path, "SELECT COUNT(*) FROM generation_scope_plan") == 0
      })
    },
  )
  fixture(base + p.reservation(plan), fn(path, store) {
    let assert Ok(r.Fresh(claim)) =
      r.admit_planned(store, p.original(plan), doors(), 1, None, plan)
      as "exact total quota fits"
    assert scalar(path, "SELECT reservation FROM generation_record")
      == base + p.reservation(plan)
    assert r.admit_planned(store, p.original(plan), doors(), 1, None, plan)
      == Ok(r.Retained(r.Claimed))
    assert r.close_generation(store, g.association_key(p.original(plan)))
      == Ok(r.Closing)
    let assert Ok(retired) =
      r.retire_started(claim, evidence(), trusted_component_retirement_verifier)
      as "complete synthetic component retirement"
    assert r.remove(store, retired, trusted_component_removal_verifier)
      == Ok(Nil)
    let next = selected_plan(2, p.DisabledLsp)
    assert r.admit_planned(store, p.original(next), doors(), 1, None, next)
      == Error(r.Capacity)
    assert scalar(path, "SELECT SUM(live) FROM generation_record") == 0
    assert scalar(path, "SELECT reservation FROM generation_record")
      == base + p.reservation(plan)
  })
}

pub fn removed_plans_stay_charged_beyond_sixteen_clean_component_opens_test() {
  fixture(2_000_000, fn(path, store) {
    list.each(list.index_map(list.repeat(Nil, 32), fn(_, i) { i + 1 }), fn(n) {
      let plan = selected_plan(n, p.DisabledLsp)
      let key = g.association_key(p.original(plan))
      let assert Ok(r.Fresh(claim)) =
        r.admit_planned(store, p.original(plan), doors(), 1, None, plan)
        as "next distinct original component generation"
      assert r.close_generation(store, key) == Ok(r.Closing)
      let assert Ok(retired) =
        r.retire_started(
          claim,
          evidence(),
          trusted_component_retirement_verifier,
        )
        as "synthetic component witness admission"
      let charged =
        scalar(path, "SELECT SUM(reservation) FROM generation_record")
      assert r.remove(store, retired, trusted_component_removal_verifier)
        == Ok(Nil)
      assert scalar(path, "SELECT SUM(reservation) FROM generation_record")
        == charged
      assert r.scope_plan(store, key) == Ok(Some(plan))
    })
    assert scalar(path, "SELECT COUNT(*) FROM generation_scope_plan") == 32
    assert scalar(path, "SELECT SUM(live) FROM generation_record") == 0
    let exhausted = selected_plan(33, p.DisabledLsp)
    assert r.admit_planned(
        store,
        p.original(exhausted),
        doors(),
        1,
        None,
        exhausted,
      )
      == Error(r.Capacity)
  })
}

pub fn never_started_and_legacy_rows_cannot_gain_provenance_on_retry_test() {
  fixture(1_000_000, fn(path, store) {
    let first = selected_plan(1, p.DisabledLsp)
    let key = g.association_key(p.original(first))
    assert r.close_generation(store, key) == Ok(r.Retired)
    assert r.scope_plan(store, key) == Ok(None)
    assert r.admit_planned(store, p.original(first), doors(), 1, None, first)
      == Error(r.Fenced)
    let legacy = selected_plan(2, p.DisabledLsp)
    let assert Ok(r.Fresh(_)) =
      r.admit(store, p.original(legacy), doors(), 1, None)
      as "unchanged native component admission"
    assert r.scope_plan(store, g.association_key(p.original(legacy)))
      == Ok(None)
    assert r.admit_planned(store, p.original(legacy), doors(), 1, None, legacy)
      == Error(r.Conflict)
    assert scalar(path, "SELECT COUNT(*) FROM generation_scope_plan") == 0
  })
}

pub fn version_one_upgrade_preserves_old_reservations_and_never_backfills_test() {
  directory(fn(path) {
    let plan = selected_plan(1, p.DisabledLsp)
    version_one(path, p.original(plan))
    let charged = scalar(path, "SELECT reservation FROM generation_record")
    let assert Ok(store) = r.recover(path, uuid(100), limits(1_000_000))
      as "checked additive v2 migration"
    assert scalar(path, "SELECT format FROM generation_meta") == 2
    assert scalar(path, "SELECT reservation FROM generation_record") == charged
    assert scalar(path, "SELECT COUNT(*) FROM generation_scope_plan") == 0
    assert r.scope_plan(store, g.association_key(p.original(plan))) == Ok(None)
    assert r.admit(store, p.original(plan), doors(), 1, None)
      == Ok(r.Retained(r.Unknown))
    assert r.admit_planned(store, p.original(plan), doors(), 1, None, plan)
      == Error(r.Conflict)
    assert r.release(store) == Ok(Nil)
  })
  let assert Ok(migration) = simplifile.read("sql/generations_v2.sql")
    as "migration source"
  assert migration == generation_scope_plan_migration.schema
}

pub fn corrupt_old_scalar_body_and_unknown_version_refuse_before_upgrade_test() {
  list.each(
    [
      "PRAGMA ignore_check_constraints=ON; UPDATE generation_record SET phase='invalid';",
      "PRAGMA ignore_check_constraints=ON; UPDATE generation_record SET association=zeroblob(1025);",
      "UPDATE generation_record SET association=zeroblob(32);",
      "PRAGMA ignore_check_constraints=ON; UPDATE generation_meta SET format=99;",
    ],
    fn(fault) {
      directory(fn(path) {
        version_one(path, p.original(selected_plan(1, p.DisabledLsp)))
        mutate(path, fault)
        let format = scalar(path, "SELECT format FROM generation_meta")
        assert r.recover(path, uuid(100), limits(1_000_000)) == Error(r.Corrupt)
        assert scalar(path, "SELECT format FROM generation_meta") == format
        assert scalar(
            path,
            "SELECT COUNT(*) FROM sqlite_master WHERE name='generation_scope_plan'",
          )
          == 0
        assert scalar(
            path,
            "SELECT COUNT(*) FROM generation_record WHERE phase=6",
          )
          == 0
      })
    },
  )
}

pub fn corrupt_plan_scalars_and_orphans_poison_even_unrelated_observation_test() {
  list.each(
    [
      "PRAGMA ignore_check_constraints=ON; UPDATE generation_record SET reservation=reservation+262145-(SELECT length(header) FROM generation_scope_plan); UPDATE generation_scope_plan SET header=zeroblob(262145);",
      "PRAGMA ignore_check_constraints=ON; UPDATE generation_scope_plan SET enrollment=zeroblob(262145);",
      "PRAGMA ignore_check_constraints=ON; UPDATE generation_scope_plan SET digest='not-a-blob';",
      "PRAGMA foreign_keys=OFF; INSERT INTO generation_scope_plan VALUES(X'ff',X'90',X'90',zeroblob(32));",
      "DELETE FROM generation_scope_plan;",
    ],
    fn(fault) {
      fixture(1_000_000, fn(path, store) {
        let plan = selected_plan(1, p.DisabledLsp)
        let assert Ok(r.Fresh(_)) =
          r.admit_planned(store, p.original(plan), doors(), 1, None, plan)
          as "valid original before external corruption"
        mutate(path, fault)
        assert r.scope_plan(
            store,
            g.association_key(p.original(selected_plan(2, p.DisabledLsp))),
          )
          == Error(r.Corrupt)
        assert scalar(path, "SELECT phase FROM generation_record") == 0
        assert r.recover(path, uuid(101), limits(1_000_000)) == Error(r.Corrupt)
        assert scalar(path, "SELECT phase FROM generation_record") == 0
      })
    },
  )
}

pub fn canonical_wrong_parent_and_digest_refuse_before_recovery_mutation_test() {
  list.each([0, 1], fn(fault) {
    fixture(1_000_000, fn(path, store) {
      let plan = selected_plan(1, p.DisabledLsp)
      let assert Ok(r.Fresh(_)) =
        r.admit_planned(store, p.original(plan), doors(), 1, None, plan)
        as "valid original canonical parent"
      assert r.release(store) == Ok(Nil)
      case fault {
        0 -> replace_plan(path, selected_plan(2, p.DisabledLsp))
        _ ->
          mutate(path, "UPDATE generation_scope_plan SET digest=zeroblob(32);")
      }
      assert r.recover(path, uuid(101), limits(1_000_000)) == Error(r.Corrupt)
      assert scalar(path, "SELECT phase FROM generation_record") == 0
    })
  })
}

fn replace_plan(path: String, plan: p.Plan) -> Nil {
  let #(header, body, digest) = p.encoded(plan)
  let assert Ok(connection) = sqlight.open(path)
    as "fixture canonical child corruption"
  assert sqlight.query(
      "UPDATE generation_scope_plan SET header=?,enrollment=?,digest=?",
      connection,
      [
        sqlight.blob(header),
        sqlight.blob(body),
        sqlight.blob(g.digest_bytes(digest)),
      ],
      decode.success(Nil),
    )
    |> result.is_ok
  assert sqlight.close(connection) == Ok(Nil)
}

fn make_plan(
  number: Int,
  enrolled: enrollment.SessionEnrollment,
  lsp: p.Lsp,
) -> Result(p.Plan, p.Error) {
  let prefix = "/state/" <> int.to_string(number)
  let assert Ok(capacity) = admission.capacity(7)
    as "actual selected native profile"
  p.new(
    association_fixture(number, enrolled),
    enrolled,
    "owner@owner.example.invalid",
    prefix <> "/native.sqlite",
    capacity,
    p.Journal(prefix <> "/workspace.sqlite", 3, 100_000),
    p.Journal(prefix <> "/resource.sqlite", 5, 200_000),
    lsp,
  )
}

fn selected_plan(number: Int, lsp: p.Lsp) -> p.Plan {
  let assert Ok(plan) = make_plan(number, enrollment_fixture(number), lsp)
    as "exact selected immutable provenance"
  plan
}

fn changed_plans(plan: p.Plan) -> List(p.Plan) {
  let native = p.native(plan)
  let ws = p.Journal(p.workspace_inputs(plan).0, 3, 100_000)
  let resource = p.Journal(p.resource_inputs(plan).0, 5, 200_000)
  let assert Ok(capacity) = admission.capacity(8)
    as "distinct valid native capacity"
  let variants = [
    #(
      p.owner_peer(plan),
      native.0 <> ".changed",
      native.1,
      ws,
      resource,
      p.DisabledLsp,
    ),
    #(p.owner_peer(plan), native.0, capacity, ws, resource, p.DisabledLsp),
    #(
      p.owner_peer(plan),
      native.0,
      native.1,
      p.Journal(ws.path, 2, ws.bytes),
      resource,
      p.DisabledLsp,
    ),
    #(
      p.owner_peer(plan),
      native.0,
      native.1,
      p.Journal(ws.path, ws.rows, 99_999),
      resource,
      p.DisabledLsp,
    ),
    #(
      p.owner_peer(plan),
      native.0,
      native.1,
      ws,
      p.Journal(resource.path, 4, resource.bytes),
      p.DisabledLsp,
    ),
    #(
      p.owner_peer(plan),
      native.0,
      native.1,
      ws,
      p.Journal(resource.path, resource.rows, 199_999),
      p.DisabledLsp,
    ),
    #(
      "owner@other.example.invalid",
      native.0,
      native.1,
      ws,
      resource,
      p.DisabledLsp,
    ),
    #(
      p.owner_peer(plan),
      native.0,
      native.1,
      ws,
      resource,
      p.EnabledLsp(
        p.Journal("/state/1/lsp.sqlite", 2, 300_000),
        fixed_digest(9),
        profile_inventory(16),
      ),
    ),
  ]
  list.map(variants, fn(fields) {
    let assert Ok(changed) =
      p.new(
        p.original(plan),
        p.enrolled(plan),
        fields.0,
        fields.1,
        fields.2,
        fields.3,
        fields.4,
        fields.5,
      )
      as "one independently changed original fact"
    changed
  })
}

fn profile_inventory(count: Int) -> List(id.Profile) {
  list.index_map(list.repeat(Nil, count), fn(_, ordinal) {
    id.Profile("server-" <> int.to_string(ordinal), "/work")
  })
}

fn enrollment_fixture(number: Int) -> enrollment.SessionEnrollment {
  let assert Ok(scope) =
    workspace.scope_from_fields(
      ids.entry_id_to_string(uuid(number)),
      "checkout",
      "linux",
      2,
      7,
    )
    as "complete original scope"
  let policy =
    policy.SandboxPolicy(
      ["/work", "/alloc"],
      ["/tc", "/seed", "/work"],
      ["/work/.git"],
      policy.NetworkOff,
      policy.Limits(11, 12, 13, 14, 15, 16),
      ["PATH", "HOME"],
      policy.ScratchTmpfs,
      [
        policy.Mount("/tc", policy.MountReadOnly, policy.MountRequired),
        policy.Mount("/seed", policy.MountReadOnly, policy.MountOptional),
      ],
    )
  let assert Ok(enrolled) =
    enrollment.new(
      enrollment.NativeFacts(scope, ["/"], policy, exec.PlatformEnforcement),
      enrollment.CodeModeFacts(
        "/work",
        "/alloc/build",
        "/alloc/channel",
        "/tc/bin/gleam",
        "/tc/bin/erl",
        "/seed",
        ["/tc"],
        policy.mounts,
        "/tc/bin",
      ),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "full valid enrollment"
  enrolled
}

fn association_fixture(
  number: Int,
  enrolled: enrollment.SessionEnrollment,
) -> g.GenerationAssociation {
  let assert Ok(bytes) = enrollment.encode(enrolled)
    as "canonical enrollment body"
  let assert Ok(key) =
    g.key(enrollment.native_facts(enrolled).scope, fixed_digest(1), 1)
    as "full generation key"
  g.association(
    key,
    content_hash(bytes),
    uuid(number + 1000),
    g.FirstGeneration,
  )
}

fn uuid(number: Int) -> ids.EntryId {
  let assert Ok(value) =
    ids.parse_entry_id(
      "00000000-0000-7000-8000-"
      <> string.pad_start(int.to_string(number), 12, "0"),
    )
    as "original fixture UUID"
  value
}

fn fixed_digest(number: Int) -> g.Digest {
  let assert Ok(digest) = g.digest(<<number:size(256)>>) as "fixed digest"
  digest
}

fn content_hash(bytes: BitArray) -> g.Digest {
  let assert Ok(digest) = g.digest(crypto.hash(crypto.Sha256, bytes))
    as "actual digest"
  digest
}

fn plan_hash(header: BitArray, body: BitArray) -> g.Digest {
  content_hash(<<
    "loom.generation.scope-plan.digest/1":utf8,
    bit_array.byte_size(header):size(64),
    header:bits,
    bit_array.byte_size(body):size(64),
    body:bits,
  >>)
}

fn doors() -> BitArray {
  let assert Ok(bytes) =
    mp.encode(mp.ArrayValue([mp.StringValue("original doors")]))
    as "canonical door metadata"
  bytes
}

fn limits(bytes: Int) -> r.Limits {
  let assert Ok(limits) = r.limits(1, 32, bytes) as "selected permanent quota"
  limits
}

fn directory(run: fn(String) -> a) -> a {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let directory =
    "/private/tmp/loom-gsp-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  assert simplifile.create_directory(directory) == Ok(Nil)
  let value = run(directory <> "/registry.sqlite")
  assert simplifile.delete(directory) == Ok(Nil)
  value
}

fn fixture(bytes: Int, run: fn(String, r.Store) -> Nil) -> Nil {
  directory(fn(path) {
    let assert Ok(store) = r.fresh(path, uuid(100), limits(bytes))
      as "actual bounded original registry writer"
    run(path, store)
    let _ = r.release(store)
    Nil
  })
}

fn scalar(path: String, text: String) -> Int {
  let assert Ok(connection) = sqlight.open(path) as "fixture scalar connection"
  let assert Ok([value]) =
    sqlight.query(
      text,
      connection,
      [],
      decode.field(0, decode.int, decode.success),
    )
    as "scalar readback"
  assert sqlight.close(connection) == Ok(Nil)
  value
}

fn mutate(path: String, text: String) -> Nil {
  let assert Ok(connection) = sqlight.open(path) as "fixture fault connection"
  assert sqlight.exec(text, connection) == Ok(Nil)
  assert sqlight.close(connection) == Ok(Nil)
}

fn legacy_charge() -> Int {
  directory(fn(path) {
    let assert Ok(store) = r.fresh(path, uuid(100), limits(1_000_000))
      as "baseline legacy quota"
    let assert Ok(r.Fresh(_)) =
      r.admit(
        store,
        p.original(selected_plan(1, p.DisabledLsp)),
        doors(),
        1,
        None,
      )
      as "legacy parent only"
    let charged = scalar(path, "SELECT reservation FROM generation_record")
    assert r.release(store) == Ok(Nil)
    charged
  })
}

fn version_one(path: String, associated: g.GenerationAssociation) -> Nil {
  let assert Ok(schema) = simplifile.read("test/fixtures/generations_v1.sql")
    as "pinned former schema"
  mutate(
    path,
    schema <> "INSERT INTO generation_meta VALUES(1,1,1,32,1000000);",
  )
  let key = g.association_key(associated)
  let assert Ok(key_bytes) = g.encode_key(key) as "canonical original key"
  let assert Ok(scope_key) = g.key(g.key_scope(key), fixed_digest(0), 1)
    as "original scope index"
  let assert Ok(scope_bytes) = g.encode_key(scope_key)
    as "canonical original scope"
  let assert Ok(body) = g.encode_association(associated)
    as "old canonical association"
  let #(_, _, owner, _) = g.association_fields(associated)
  let query =
    sql.insert_generation_claim(
      key_bytes,
      scope_bytes,
      1,
      body,
      crypto.hash(crypto.Sha256, body),
      bit_array.from_string(ids.entry_id_to_string(owner)),
      doors(),
      bit_array.from_string(ids.entry_id_to_string(uuid(99))),
      bit_array.byte_size(key_bytes)
        * 2
        + 1024
        + 4096
        + 36
        * 2
        + 32
        * 4
        + 8192
        * 2,
    )
  let arguments =
    list.map(query.1, fn(parameter) {
      case parameter {
        dev.ParamInt(value) -> sqlight.int(value)
        dev.ParamBitArray(value) -> sqlight.blob(value)
        _ -> panic as "only original typed query parameters"
      }
    })
  let assert Ok(connection) = sqlight.open(path)
    as "old registry fixture connection"
  assert sqlight.query(query.0, connection, arguments, decode.success(Nil))
    |> result.is_ok
  assert sqlight.close(connection) == Ok(Nil)
}

fn evidence() -> r.StartedEvidence {
  r.StartedEvidence(
    r.UnpublishedFenced,
    fixed_digest(11),
    fixed_digest(12),
    fixed_digest(13),
    fixed_digest(14),
    fixed_digest(15),
    fixed_digest(16),
    fixed_digest(17),
  )
}

fn trusted_component_retirement_verifier(
  claim: r.StartupClaim,
  provided: r.StartedEvidence,
) -> Result(Nil, r.Error) {
  assert g.key_fields(g.association_key(r.original(claim))).2 == 1
  assert provided == evidence()
  Ok(Nil)
}

fn trusted_component_removal_verifier(
  record: r.RetirementRecord,
) -> Result(Nil, r.Error) {
  assert r.retirement_fields(record).1 == r.StartedRetired(evidence())
  Ok(Nil)
}
