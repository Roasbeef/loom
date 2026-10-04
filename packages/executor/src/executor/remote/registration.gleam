//// Administrative ceilings for one executor-resident workspace binding.
////
//// `new` freezes the exact scope, working directories, sandbox ceiling and
//// enforcement demand into a digest. `verify` checks already-cleared native
//// materialization against those facts; it never rewrites argv, environment,
//// paths or policy. The owner's broker remains the approval and budget owner.
////
//// The injected canonicalizer runs beside the executor checkout. Every offered
//// access root must already have its canonical spelling, so a symlink alias
//// cannot turn a lexical subtree grant into access outside the registration.
//// Preparation must create required roots before clearance. Optional missing
//// mounts are conservatively refused by this adapter too. Kernel enforcement
//// still owns races after validation; this is not a replacement for the jail.

import broker/enrollment
import broker/exec
import broker/policy
import core/msgpack
import core/workspace
import executor/remote/identity
import executor/remote/journal_codec
import executor/remote/wire
import gleam/bool
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

/// Frozen administrative authority; remote commands cannot construct it.
pub opaque type Registration {
  Registration(
    /// Exact session, executor, workspace and authority epochs.
    scope: identity.Scope,
    /// Canonical directories in which prepared commands may start.
    working_roots: List(String),
    /// Maximum native access and resource authority.
    ceiling: policy.SandboxPolicy,
    /// Required kernel enforcement posture.
    demand: exec.EnforcementDemand,
    /// Canonical executor-local path resolution, supplied by trusted assembly.
    canonicalize: fn(String) -> Result(String, Nil),
    /// Evidence over every immutable administrative field above.
    digest: identity.Digest,
  )
}

/// Constructs a bounded registration after checking its executor-local paths.
/// The caller loads these facts from owner-controlled administration, not from
/// a tool argument. Resolution failures grant no partial registration.
///
/// ## Examples
///
/// ```gleam
/// // registration.new(scope, [checkout], ceiling, demand, canonicalize)
/// ```
pub fn new(
  scope: identity.Scope,
  working_roots: List(String),
  ceiling: policy.SandboxPolicy,
  demand: exec.EnforcementDemand,
  canonicalize: fn(String) -> Result(String, Nil),
) -> Result(Registration, Nil) {
  use <- bool.guard(
    working_roots == [] || list.length(working_roots) > 16,
    Error(Nil),
  )
  use Nil <- result.try(policy.validate(ceiling) |> result.replace_error(Nil))
  use Nil <- result.try(check_paths(working_roots, canonicalize))
  use Nil <- result.try(check_paths(access_paths(ceiling), canonicalize))
  use bytes <- result.try(policy.encode(ceiling) |> result.replace_error(Nil))
  let enforcement = case demand {
    exec.FullEnforcement -> 0
    exec.BestEffort -> 1
    exec.PlatformEnforcement -> 2
  }
  use encoded <- result.try(
    wire.encode_value(
      msgpack.ArrayValue([
        msgpack.IntValue(1),
        msgpack.BinaryValue(journal_codec.binding(scope)),
        msgpack.ArrayValue(list.map(working_roots, msgpack.StringValue)),
        msgpack.BinaryValue(bytes),
        msgpack.IntValue(enforcement),
      ]),
    )
    |> result.replace_error(Nil),
  )
  use digest <- result.try(wire.digest(encoded) |> result.replace_error(Nil))
  Ok(Registration(scope, working_roots, ceiling, demand, canonicalize, digest))
}

/// Returns the immutable validated scope without refreshing authority.
///
/// ## Examples
///
/// ```gleam
/// // registration.scope(registered) == provisioned_scope
/// ```
pub fn scope(registered: Registration) -> identity.Scope {
  registered.scope
}

/// Returns the digest the owner must clear with the prepared command.
///
/// ## Examples
///
/// ```gleam
/// // registration.digest(registered)
/// ```
pub fn digest(registered: Registration) -> identity.Digest {
  registered.digest
}

/// Describes exact native facts without exporting the local canonicalizer.
/// The shared Scope conversion preserves the session and both original epochs;
/// no digest bytes or registration encoding are changed by this projection.
///
/// ## Examples
///
/// `describe(registered)` returns facts for a later pinned session enrollment.
pub fn describe(
  registered: Registration,
) -> Result(enrollment.NativeFacts, Nil) {
  let #(session, name, executor, session_epoch, workspace_epoch) =
    identity.scope_fields(registered.scope)
  use scope <- result.try(
    workspace.scope_from_fields(
      session,
      name,
      executor,
      session_epoch,
      workspace_epoch,
    )
    |> result.replace_error(Nil),
  )
  Ok(enrollment.NativeFacts(
    scope:,
    working_roots: registered.working_roots,
    ceiling: registered.ceiling,
    demand: registered.demand,
  ))
}

/// Validates exact native materialization without widening or rewriting it.
/// A matching registration digest is necessary evidence, never approval itself.
/// The service calls this before admission and again before native launch.
///
/// ## Examples
///
/// ```gleam
/// // service.Config(..config, verify: registration.verify(registered, _, _))
/// ```
pub fn verify(
  registered: Registration,
  key: identity.RequestKey,
  prepared: wire.Prepared,
) -> Result(Nil, Nil) {
  use <- bool.guard(
    identity.key_scope(key) != registered.scope
      || prepared.registration != registered.digest
      || !sufficient_demand(registered.demand, prepared.request.demand),
    Error(Nil),
  )
  use requested <- result.try(case prepared.request.policy {
    Some(value) -> Ok(value)
    None -> Error(Nil)
  })
  use Nil <- result.try(policy.validate(requested) |> result.replace_error(Nil))

  // Comparing the full meet also preserves mandatory protected paths and mount
  // requirements; an empty shortfall alone does not express those obligations.
  let #(bounded, _) = policy.compose(registered.ceiling, requested, [])
  use <- bool.guard(bounded != requested, Error(Nil))
  use Nil <- result.try(check_paths(
    access_paths(requested),
    registered.canonicalize,
  ))
  use Nil <- result.try(check_paths(
    [prepared.request.cwd],
    registered.canonicalize,
  ))
  use <- bool.guard(
    !list.any(registered.working_roots, within(_, prepared.request.cwd)),
    Error(Nil),
  )
  use <- bool.guard(
    !list.all(prepared.request.env, fn(pair) {
      list.contains(requested.env_allow, pair.0)
    }),
    Error(Nil),
  )

  // Session lifetime must be explicit in both administrative and cleared wall
  // authority. Other limits remain the exact policy supplied by the owner.
  let lifetime_allowed = case prepared.lifetime {
    wire.Session ->
      requested.limits.wall_s == 0 && registered.ceiling.limits.wall_s == 0
    wire.Finite(ceiling_ms) ->
      requested.limits.wall_s > 0
      && requested.limits.wall_s * 1000 <= ceiling_ms
  }
  use <- bool.guard(!lifetime_allowed, Error(Nil))
  wire.encode_prepared(prepared)
  |> result.replace(Nil)
  |> result.replace_error(Nil)
}

fn sufficient_demand(
  required: exec.EnforcementDemand,
  offered: exec.EnforcementDemand,
) -> Bool {
  case required, offered {
    exec.FullEnforcement, exec.BestEffort
    | exec.FullEnforcement, exec.PlatformEnforcement
    | exec.PlatformEnforcement, exec.BestEffort
    -> False
    exec.FullEnforcement, exec.FullEnforcement
    | exec.PlatformEnforcement, exec.FullEnforcement
    | exec.PlatformEnforcement, exec.PlatformEnforcement
    | exec.BestEffort, exec.FullEnforcement
    | exec.BestEffort, exec.PlatformEnforcement
    | exec.BestEffort, exec.BestEffort
    -> True
  }
}

fn access_paths(value: policy.SandboxPolicy) -> List(String) {
  let scratch = case value.scratch {
    policy.ScratchTmpfs -> []
    policy.ScratchPath(path) -> [path]
  }
  list.flatten([
    value.writable_roots,
    value.readable_roots,
    list.map(value.mounts, fn(mount) { mount.path }),
    scratch,
  ])
}

fn check_paths(
  paths: List(String),
  canonicalize: fn(String) -> Result(String, Nil),
) -> Result(Nil, Nil) {
  use <- bool.guard(list.length(paths) > 128, Error(Nil))
  use _ <- result.try(
    list.try_map(paths, fn(path) {
      use <- bool.guard(
        !string.starts_with(path, "/") || string.contains(path, "\u{0000}"),
        Error(Nil),
      )
      use canonical <- result.try(canonicalize(path))
      case path == canonical {
        True -> Ok(Nil)
        False -> Error(Nil)
      }
    }),
  )
  Ok(Nil)
}

fn within(root: String, path: String) -> Bool {
  root == "/" || root == path || string.starts_with(path, root <> "/")
}
