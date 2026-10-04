//// Administrative admission checks before remote native execution.
////
//// The canonicalizer supplies controlled filesystem observations here. Native
//// containment and symlink races remain kernel properties tested by the jail.

import broker/exec
import broker/policy
import core/ids
import core/workspace
import executor/remote/identity
import executor/remote/registration
import executor/remote/wire
import gleam/list
import gleam/option.{None, Some}

fn scope(epoch_number: Int) -> identity.Scope {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "valid session"
  let assert Ok(workspace) = identity.workspace_id("checkout")
    as "valid workspace"
  let assert Ok(executor) = identity.executor_id("linux") as "valid executor"
  let assert Ok(epoch) = identity.epoch(epoch_number) as "valid epoch"
  identity.scope(session, workspace, executor, epoch, epoch)
}

fn key(epoch: Int) -> identity.RequestKey {
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "valid operation"
  let assert Ok(request) =
    identity.request_id("00000000-0000-7000-8000-000000000003")
    as "valid request"
  identity.request_key(scope(epoch), operation, request)
}

fn ceiling() -> policy.SandboxPolicy {
  let base = policy.workspace_default("/work")
  policy.SandboxPolicy(
    ..base,
    readable_roots: ["/tools", "/work"],
    writable_roots: ["/work"],
    protected: ["/work/.git"],
    env_allow: ["PATH"],
    scratch: policy.ScratchTmpfs,
    mounts: [],
    limits: policy.Limits(..base.limits, wall_s: 10, output_bytes: 262_144),
  )
}

fn registered() -> registration.Registration {
  let assert Ok(value) =
    registration.new(scope(1), ["/work"], ceiling(), exec.FullEnforcement, Ok)
    as "administrative paths resolve"
  value
}

fn prepared(registered: registration.Registration) -> wire.Prepared {
  wire.Prepared(
    "launch",
    registration.digest(registered),
    wire.Finite(10_000),
    exec.ExecRequest(
      ["/tools/sh", "-c", "true"],
      [#("PATH", "/tools")],
      "/work",
      Some(ceiling()),
      <<1:size(256)>>,
      exec.FullEnforcement,
    ),
    wire.Logs,
  )
}

pub fn exact_materialization_and_narrower_resource_policy_test() {
  let registered = registered()
  let original = prepared(registered)
  assert registration.verify(registered, key(1), original) == Ok(Nil)
  let narrowed =
    policy.SandboxPolicy(
      ..ceiling(),
      limits: policy.Limits(..ceiling().limits, wall_s: 2),
    )
  let request = exec.ExecRequest(..original.request, policy: Some(narrowed))
  assert registration.verify(
      registered,
      key(1),
      wire.Prepared(..original, request:),
    )
    == Ok(Nil)
  assert registration.verify(registered, key(1), original) == Ok(Nil)
}

pub fn administrative_scope_and_digest_are_not_remote_choices_test() {
  let registered = registered()
  let original = prepared(registered)
  assert registration.verify(registered, key(2), original) == Error(Nil)
  let assert Ok(other) =
    registration.new(scope(2), ["/work"], ceiling(), exec.FullEnforcement, Ok)
    as "another administrative epoch"
  assert registration.digest(registered) != registration.digest(other)
  assert registration.verify(
      registered,
      key(1),
      wire.Prepared(..original, registration: registration.digest(other)),
    )
    == Error(Nil)
}

pub fn native_authority_cannot_exceed_registration_test() {
  let registered = registered()
  let original = prepared(registered)
  let base = ceiling()
  let too_wide = [
    policy.SandboxPolicy(..base, writable_roots: ["/"]),
    policy.SandboxPolicy(..base, protected: []),
    policy.SandboxPolicy(..base, network: policy.NetworkFull),
    policy.SandboxPolicy(..base, env_allow: ["PATH", "SECRET"]),
    policy.SandboxPolicy(
      ..base,
      limits: policy.Limits(..base.limits, wall_s: 0),
    ),
    policy.SandboxPolicy(..base, mounts: [
      policy.Mount("/secret", policy.MountReadOnly, policy.MountRequired),
    ]),
    policy.SandboxPolicy(..base, scratch: policy.ScratchPath("/work")),
  ]
  list.each(too_wide, fn(offered) {
    let request = exec.ExecRequest(..original.request, policy: Some(offered))
    assert registration.verify(
        registered,
        key(1),
        wire.Prepared(..original, request:),
      )
      == Error(Nil)
  })
}

pub fn cwd_environment_and_enforcement_cannot_escape_test() {
  let registered = registered()
  let original = prepared(registered)
  let invalid = [
    exec.ExecRequest(..original.request, cwd: "/work-other"),
    exec.ExecRequest(..original.request, env: [#("SECRET", "not-allowed")]),
    exec.ExecRequest(..original.request, demand: exec.BestEffort),
    exec.ExecRequest(..original.request, demand: exec.PlatformEnforcement),
    exec.ExecRequest(..original.request, policy: None),
  ]
  list.each(invalid, fn(request) {
    assert registration.verify(
        registered,
        key(1),
        wire.Prepared(..original, request:),
      )
      == Error(Nil)
  })
}

pub fn canonical_aliases_are_refused_before_lexical_composition_test() {
  let resolve = fn(path) {
    case path {
      "/work/alias" -> Ok("/secret")
      "/work/../secret" -> Ok("/secret")
      "/work/missing" -> Error(Nil)
      _ -> Ok(path)
    }
  }
  let assert Ok(registered) =
    registration.new(
      scope(1),
      ["/work"],
      ceiling(),
      exec.FullEnforcement,
      resolve,
    )
    as "registered root resolves"
  let original = prepared(registered)
  list.each(["/work/alias", "/work/../secret", "/work/missing"], fn(path) {
    let request = exec.ExecRequest(..original.request, cwd: path)
    assert registration.verify(
        registered,
        key(1),
        wire.Prepared(..original, request:),
      )
      == Error(Nil)
    let widened = policy.SandboxPolicy(..ceiling(), writable_roots: [path])
    let request = exec.ExecRequest(..original.request, policy: Some(widened))
    assert registration.verify(
        registered,
        key(1),
        wire.Prepared(..original, request:),
      )
      == Error(Nil)
  })
  assert registration.new(
      scope(1),
      ["/work/alias"],
      ceiling(),
      exec.FullEnforcement,
      resolve,
    )
    == Error(Nil)
}

pub fn session_lifetime_requires_explicit_unbounded_wall_authority_test() {
  let registered = registered()
  let original = prepared(registered)
  assert registration.verify(
      registered,
      key(1),
      wire.Prepared(..original, lifetime: wire.Session),
    )
    == Error(Nil)
  assert registration.verify(
      registered,
      key(1),
      wire.Prepared(..original, lifetime: wire.Finite(9999)),
    )
    == Error(Nil)
  let session_policy =
    policy.SandboxPolicy(
      ..ceiling(),
      limits: policy.Limits(..ceiling().limits, wall_s: 0),
    )
  let assert Ok(session) =
    registration.new(
      scope(1),
      ["/work"],
      session_policy,
      exec.FullEnforcement,
      Ok,
    )
    as "explicit administrative session authority"
  let request =
    exec.ExecRequest(..original.request, policy: Some(session_policy))
  assert registration.verify(
      session,
      key(1),
      wire.Prepared(
        ..original,
        registration: registration.digest(session),
        lifetime: wire.Session,
        request:,
      ),
    )
    == Ok(Nil)
}

pub fn registration_rejects_empty_and_excessive_working_roots_test() {
  assert registration.new(scope(1), [], ceiling(), exec.FullEnforcement, Ok)
    == Error(Nil)
  assert registration.new(
      scope(1),
      list.repeat("/work", 17),
      ceiling(),
      exec.FullEnforcement,
      Ok,
    )
    == Error(Nil)
}

/// Description retains every administrative field and never exports a callback.
pub fn native_description_preserves_exact_scope_policy_and_digest_test() {
  let registered = registered()
  let digest = registration.digest(registered)
  let assert Ok(facts) = registration.describe(registered)
    as "Validated executor identity converts totally to shared scope."
  let assert Ok(expected) =
    workspace.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "checkout",
      "linux",
      1,
      1,
    )
    as "The shared scope keeps both epochs."
  assert facts.scope == expected
  assert facts.working_roots == ["/work"]
  assert facts.ceiling == ceiling()
  assert facts.demand == exec.FullEnforcement
  assert registration.digest(registered) == digest
  let assert Ok(other) =
    registration.new(scope(2), ["/work"], ceiling(), exec.FullEnforcement, Ok)
    as "A changed administrative epoch is distinct."
  let assert Ok(changed) = registration.describe(other)
    as "Total changed description."
  assert changed.scope != facts.scope
}
