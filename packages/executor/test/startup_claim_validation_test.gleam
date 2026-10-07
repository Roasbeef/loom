//// Original startup validation reads the same admitted writer and complete Plan.
//// These real SQLite controls grant no physical retirement, service or endpoint.
//// A same-incarnation independent writer models a forged replacement handle;
//// it must not inherit another connection's claim with identical durable fields.

import broker/enrollment
import broker/exec
import broker/policy
import core/generation as g
import core/ids
import core/msgpack as mp
import core/workspace
import executor/generation_registry as r
import executor/generation_scope_plan as p
import executor/remote/admission
import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import simplifile

pub fn original_claim_and_exact_plan_validate_without_transition_test() {
  directory(fn(path, store) {
    let plan = plan()
    let assert Ok(r.Fresh(claim)) = admit(store, plan)
      as "The original transaction commits its only claim and Plan."
    assert r.validate_startup(store, claim, plan) == Ok(Nil)
    assert r.validate_startup(store, claim, plan) == Ok(Nil)
    assert r.observe(store, g.association_key(p.original(plan)))
      == Ok(r.Claimed)
    assert r.scope_plan(store, g.association_key(p.original(plan)))
      == Ok(Some(plan))
    assert admit(store, plan) == Ok(r.Retained(r.Claimed))
    assert r.release(store) == Ok(Nil)
    let assert Ok(restored) = r.recover(path, uuid(99), limits())
      as "Reopening with a new writer preserves history only."
    assert r.observe(restored, g.association_key(p.original(plan)))
      == Ok(r.Unknown)
    assert r.validate_startup(restored, claim, plan) == Error(r.Conflict)
    assert r.release(restored) == Ok(Nil)
  })
}

pub fn same_incarnation_separate_writer_cannot_substitute_original_test() {
  directory(fn(path, store) {
    let plan = plan()
    let assert Ok(r.Fresh(claim)) = admit(store, plan)
      as "The sole live claim belongs to this original connection."
    let assert Ok(other) = r.fresh(path <> ".other", uuid(80), limits())
      as "An actual independent writer has the same test incarnation."
    let assert Ok(r.Fresh(_)) = admit(other, plan)
      as "Matching durable fields alone cannot substitute for the original writer."
    assert r.scope_plan(other, g.association_key(p.original(plan)))
      == Ok(Some(plan))
    assert r.observe(other, g.association_key(p.original(plan)))
      == Ok(r.Claimed)
    assert r.validate_startup(other, claim, plan) == Error(r.Conflict)
    assert r.validate_startup(store, claim, plan) == Ok(Nil)
    assert r.release(other) == Ok(Nil)
    assert r.validate_startup(store, claim, plan) == Ok(Nil)
    assert r.release(store) == Ok(Nil)
  })
}

pub fn complete_plan_change_refuses_before_claimed_state_changes_test() {
  directory(fn(_, store) {
    let original = plan()
    let assert Ok(r.Fresh(claim)) = admit(store, original)
      as "Exact original provenance precedes all changed metadata controls."
    let assert Ok(changed) =
      p.new(
        p.original(original),
        p.enrolled(original),
        "other@node.invalid",
        p.native(original).0,
        p.native(original).1,
        p.Journal("/state/1/workspace.sqlite", 4, 300_000),
        p.Journal("/state/1/resource.sqlite", 4, 300_000),
        p.DisabledLsp,
      )
      as "A valid different complete Plan retains the same association."
    assert r.validate_startup(store, claim, changed) == Error(r.Conflict)
    assert r.scope_plan(store, g.association_key(p.original(original)))
      == Ok(Some(original))
    assert r.validate_startup(store, claim, original) == Ok(Nil)
    assert r.release(store) == Ok(Nil)
  })
}

pub fn closing_before_publication_never_revalidates_a_live_claim_test() {
  directory(fn(_, store) {
    let original = plan()
    let assert Ok(r.Fresh(claim)) = admit(store, original)
      as "The original startup was admitted before Close."
    assert r.close_generation(store, g.association_key(p.original(original)))
      == Ok(r.Closing)
    assert r.validate_startup(store, claim, original) == Error(r.Fenced)
    assert r.release(store) == Ok(Nil)
  })
}

pub fn publishing_and_published_are_not_fresh_startup_test() {
  directory(fn(_, store) {
    let original = plan()
    let assert Ok(r.Fresh(claim)) = admit(store, original)
      as "The original startup claim is live exactly once."
    let assert Ok(permit) = r.prepare_publication(claim, fixed_digest(8))
      as "Real Publishing COMMIT precedes this refusal control."
    assert r.validate_startup(store, claim, original) == Error(r.Fenced)
    assert r.published(permit) == Ok(Nil)
    assert r.validate_startup(store, claim, original) == Error(r.Fenced)
    assert r.release(store) == Ok(Nil)
  })
}

pub fn released_original_writer_is_uncertain_without_new_authority_test() {
  directory(fn(_, store) {
    let original = plan()
    let assert Ok(r.Fresh(claim)) = admit(store, original)
      as "Only the original live connection issued this claim."
    assert r.release(store) == Ok(Nil)
    assert r.validate_startup(store, claim, original) == Error(r.Uncertain)
  })
}

fn directory(run: fn(String, r.Store) -> Nil) -> Nil {
  let assert Ok(here) = simplifile.current_directory()
    as "The actual portable test package directory exists."
  let suffix = crypto.strong_random_bytes(8) |> bit_array.base16_encode
  let directory = here <> "/build/loom-startup-" <> suffix
  assert simplifile.create_directory(directory) == Ok(Nil)
  let path = directory <> "/registry.sqlite"
  let assert Ok(store) = r.fresh(path, uuid(80), limits())
    as "The original real SQLite registry connection opens."
  run(path, store)
  assert simplifile.delete(directory) == Ok(Nil)
}

fn limits() -> r.Limits {
  let assert Ok(limits) = r.limits(2, 32, 1_000_000)
    as "The finite registry profile is valid."
  limits
}

fn admit(store: r.Store, original: p.Plan) -> Result(r.Admission, r.Error) {
  let assert Ok(doors) =
    mp.encode(mp.ArrayValue([mp.StringValue("original doors")]))
    as "Canonical original door metadata is retained."
  r.admit_planned(store, p.original(original), doors, 1, None, original)
}

fn plan() -> p.Plan {
  let enrolled = enrollment_fixture(1)
  let associated = association_fixture(1, enrolled)
  let assert Ok(capacity) = admission.capacity(4)
    as "The selected original native capacity is positive."
  let assert Ok(plan) =
    p.new(
      associated,
      enrolled,
      "owner@node.invalid",
      "/state/1/native.sqlite",
      capacity,
      p.Journal("/state/1/workspace.sqlite", 4, 300_000),
      p.Journal("/state/1/resource.sqlite", 4, 300_000),
      p.DisabledLsp,
    )
    as "The complete original metadata Plan is checked."
  plan
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
