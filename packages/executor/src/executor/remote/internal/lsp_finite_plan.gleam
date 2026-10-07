//// Closed Registered finite native plans, without owner clearance or effects.
////
//// The actual descriptor, registration and jail freeze physical facts once.
//// Probe and Prepare retain their real startup lease; Search retains its exact
//// finite invocation, enrolled ordinal and root. `checked_probe`, `checked_search`
//// and `checked_prepare` select only their fixed recipes. `verify` compares the
//// unchanged owner-cleared request; no constructor mints a capability token.
//// `recipe` is also the collector's closed bounds selector. `binding` commits
//// the same descriptor/enrollment pair as the original LSP Store.

import broker/enrollment
import broker/exec as broker_exec
import broker/policy
import codemode/lsp_host/jail
import codemode/lsp_host/manager
import codemode/lsp_host/preparation
import codemode/lsp_host/profile
import codemode/lsp_host/resolve
import core/generation as g
import core/ids
import core/lsp_command as id
import core/msgpack as mp
import core/workspace as core_workspace
import executor/remote/deployment
import executor/remote/identity
import executor/remote/lsp_journal
import executor/remote/lsp_wire
import executor/remote/registration
import executor/remote/wire
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lsp/query as lsp_query

/// Fixed finite recipes; ServerLease has no variant at this boundary.
@internal
pub type Recipe {
  /// Ten seconds and 256 KiB per stream prove the actual enforcement demand.
  Probe

  /// Ten seconds and 4 MiB per stream collect one original rg search.
  Search

  /// Sixty seconds and 1 MiB per stream run approved Gleam dependency download.
  Prepare
}

/// Frozen physical facts and complete parent, never native launch authority.
@internal
pub opaque type CheckedFinitePlan {
  CheckedFinitePlan(
    /// The actual immutable physical registration.
    registration: registration.Registration,
    /// The complete original canonical command reference.
    ref: id.LspCommandRef,
    /// The retained exact semantic request.
    request: lsp_wire.Request,
    /// The original checked warm selection, when present.
    selected: Option(id.SelectedProject),
    /// The complete original enrolled profile order.
    inventory: id.EnrolledProfiles,
    /// The exact descriptor digest for generation binding.
    descriptor: g.Digest,
    /// The canonical original enrollment digest.
    enrollment: g.Digest,
    /// The closed finite recipe, never ServerLease.
    kind: Recipe,
    /// The exact original admitted finite control, never refreshed at verify.
    control: id.AdmittedFiniteControl,
    /// Resolved immutable physical bytes, without a Broker token.
    spec: BrokerSpecData,
  )
}

// The resolved data is retained without Broker grants or a cleared token.
type BrokerSpecData {
  BrokerSpec(
    argv: List(String),
    env: List(#(String, String)),
    cwd: String,
    step: String,
    policy: policy.SandboxPolicy,
  )
}

/// Refused descriptor, parent, declared recipe or materialization.
@internal
pub type Error {
  /// Complete original facts do not match their actual declaration.
  InvalidFinitePlan
}

/// Fixes the approved enforcement probe under its real original lease.
///
/// ## Examples
/// Passing a Search or ServerLease reference refuses before any offer.
@internal
pub fn checked_probe(
  descriptor: deployment.Descriptor,
  registered: registration.Registration,
  placement: jail.Placement,
  base: policy.SandboxPolicy,
  ref: id.LspCommandRef,
  request: lsp_wire.Request,
  reading: fn(String) -> Result(String, Nil),
  original_control: id.AdmittedFiniteControl,
) -> Result(CheckedFinitePlan, Error) {
  checked(
    descriptor,
    registered,
    placement,
    base,
    ref,
    request,
    None,
    Probe,
    reading,
    original_control,
  )
}

/// Fixes rg argv from the retained query and its enrolled profile separators.
///
/// ## Examples
/// A changed cold ordinal/root or warm selection cannot construct a plan.
@internal
pub fn checked_search(
  descriptor: deployment.Descriptor,
  registered: registration.Registration,
  placement: jail.Placement,
  base: policy.SandboxPolicy,
  ref: id.LspCommandRef,
  request: lsp_wire.Request,
  selected: Option(id.SelectedProject),
  reading: fn(String) -> Result(String, Nil),
  original_control: id.AdmittedFiniteControl,
) -> Result(CheckedFinitePlan, Error) {
  checked(
    descriptor,
    registered,
    placement,
    base,
    ref,
    request,
    selected,
    Search,
    reading,
    original_control,
  )
}

/// Fixes only the declared GleamDependencies recipe and its finite network grant.
/// Recipe completion is distinct from verified dependency readiness.
///
/// ## Examples
/// AlreadyPrepared never gains network authority through this constructor.
@internal
pub fn checked_prepare(
  descriptor: deployment.Descriptor,
  registered: registration.Registration,
  placement: jail.Placement,
  base: policy.SandboxPolicy,
  ref: id.LspCommandRef,
  request: lsp_wire.Request,
  reading: fn(String) -> Result(String, Nil),
  original_control: id.AdmittedFiniteControl,
) -> Result(CheckedFinitePlan, Error) {
  checked(
    descriptor,
    registered,
    placement,
    base,
    ref,
    request,
    None,
    Prepare,
    reading,
    original_control,
  )
}

/// Derives the exact descriptor/enrollment binding at the actual generation.
///
/// ## Examples
/// The caller compares this opaque value with its original Store Binding.
@internal
pub fn binding(
  plan: CheckedFinitePlan,
  number: Int,
) -> Result(lsp_journal.Binding, Error) {
  use facts <- result.try(registration.describe(plan.registration) |> invalid)
  use key <- result.try(g.key(facts.scope, plan.descriptor, number) |> invalid)
  Ok(lsp_journal.binding(key, plan.enrollment))
}

/// Encodes the immutable complete physical offer without a capability token.
///
/// ## Examples
/// Exact offer bytes must commit before original owner clearance begins.
@internal
pub fn offer(plan: CheckedFinitePlan) -> Result(BitArray, Error) {
  use ref <- result.try(lsp_wire.encode_command(plan.ref) |> invalid)
  use policy <- result.try(policy.encode(plan.spec.policy) |> invalid)
  use encoded <- result.try(
    wire.encode_value(
      mp.ArrayValue([
        mp.IntValue(1),
        mp.BinaryValue(ref),
        mp.StringValue(plan.spec.step),
        mp.StringValue(plan.spec.cwd),
        mp.ArrayValue(list.map(plan.spec.argv, mp.StringValue)),
        mp.ArrayValue(
          list.map(plan.spec.env, fn(pair) {
            mp.ArrayValue([mp.StringValue(pair.0), mp.StringValue(pair.1)])
          }),
        ),
        mp.BinaryValue(policy),
        mp.BinaryValue(
          identity.digest_bytes(registration.digest(plan.registration)),
        ),
      ]),
    )
    |> invalid,
  )
  use <- bool.guard(
    bit_array.byte_size(encoded) > 131_072,
    Error(InvalidFinitePlan),
  )
  Ok(encoded)
}

/// Checks actual owner-cleared bytes and complete original semantic identity.
/// Registration rechecks real physical authority; this comparison grants no clearance.
///
/// ## Examples
/// Changed argv, environment, stream, parent or policy cannot dispatch this plan.
@internal
pub fn verify(
  plan: CheckedFinitePlan,
  ref: id.LspCommandRef,
  request: lsp_wire.Request,
  selected: Option(id.SelectedProject),
  key: identity.RequestKey,
  prepared: wire.Prepared,
  control: id.AdmittedFiniteControl,
) -> Result(Nil, Error) {
  use Nil <- result.try(
    registration.verify(plan.registration, key, prepared) |> invalid,
  )
  use bytes <- result.try(lsp_wire.encode_command(ref) |> invalid)
  use actual <- result.try(
    lsp_wire.decode_command(bytes, request, plan.inventory, selected) |> invalid,
  )
  let #(_, _, remaining, _, _) = id.control_fields(control)
  bool.guard(
    !{
      control == plan.control
      && actual == plan.ref
      && request == plan.request
      && selected == plan.selected
      && prepared.step == plan.spec.step
      && prepared.stream == wire.ProtocolStream
      && prepared.lifetime == wire.Finite(remaining)
      && prepared.request.argv == plan.spec.argv
      && prepared.request.env == plan.spec.env
      && prepared.request.cwd == plan.spec.cwd
      && prepared.request.policy == Some(plan.spec.policy)
    },
    Error(InvalidFinitePlan),
    fn() { Ok(Nil) },
  )
}

/// Inspects the fixed role from the complete checked command vocabulary.
///
/// ## Examples
/// ServerLease cannot enter the finite collector.
@internal
pub fn recipe(ref: id.LspCommandRef) -> Result(Recipe, Error) {
  case id.command_value(ref) {
    mp.ArrayValue([_, mp.ArrayValue([mp.IntValue(0), _, mp.IntValue(0)])]) ->
      Ok(Probe)
    mp.ArrayValue([_, mp.ArrayValue([mp.IntValue(0), _, mp.IntValue(1)])]) ->
      Ok(Prepare)
    mp.ArrayValue([_, mp.ArrayValue([mp.IntValue(1), _, _, _])]) -> Ok(Search)
    _ -> Error(InvalidFinitePlan)
  }
}

/// Original fixed native wall ceiling; queueing never restarts it.
///
/// ## Examples
/// Search and Probe require their ten seconds to fit original remaining time.
@internal
pub fn wall_ms(kind: Recipe) -> Int {
  case kind {
    Probe | Search -> 10_000
    Prepare -> 60_000
  }
}

/// The finite lifetime cap of each producer stream.
///
/// ## Examples
/// Search stdout and stderr together are at most eight MiB.
@internal
pub fn stream_bytes(kind: Recipe) -> Int {
  case kind {
    Probe -> 262_144
    Search -> 4_194_304
    Prepare -> 1_048_576
  }
}

fn checked(
  descriptor: deployment.Descriptor,
  registered: registration.Registration,
  placement: jail.Placement,
  base: policy.SandboxPolicy,
  ref: id.LspCommandRef,
  request: lsp_wire.Request,
  selected: Option(id.SelectedProject),
  kind: Recipe,
  reading: fn(String) -> Result(String, Nil),
  original_control: id.AdmittedFiniteControl,
) -> Result(CheckedFinitePlan, Error) {
  use Nil <- result.try(original_timing(ref, original_control))
  use actual <- result.try(recipe(ref))
  use <- bool.guard(actual != kind, Error(InvalidFinitePlan))
  let #(session, _, _, _, _) =
    identity.scope_fields(registration.scope(registered))
  use session <- result.try(ids.parse_session_id(session) |> invalid)
  use enrolled <- result.try(
    deployment.describe(descriptor, session) |> invalid,
  )
  use facts <- result.try(registration.describe(registered) |> invalid)
  use <- bool.guard(
    !{
      facts == enrollment.native_facts(enrolled)
      && placement.workspace
      == enrollment.code_mode_facts(enrolled).workspace_root
      && list.contains(deployment.lsp_profiles(descriptor), placement.server)
    },
    Error(InvalidFinitePlan),
  )
  let #(bounded_base, _) = policy.compose(facts.ceiling, base, [])
  use <- bool.guard(
    bounded_base != base || base.limits.cpu_s <= 0,
    Error(InvalidFinitePlan),
  )
  use encoded <- result.try(enrollment.encode(enrolled) |> invalid)
  use enrolled_digest <- result.try(
    g.digest(crypto.hash(crypto.Sha256, encoded)) |> invalid,
  )
  let declarations = deployment.lsp_profiles(descriptor)
  use inventory <- result.try(
    id.enrolled_profiles(
      facts.scope,
      enrolled_digest,
      list.map(declarations, fn(server) {
        id.Profile(server.name, placement.workspace)
      }),
    )
    |> invalid,
  )
  use ref_bytes <- result.try(lsp_wire.encode_command(ref) |> invalid)
  use checked_ref <- result.try(
    lsp_wire.decode_command(ref_bytes, request, inventory, selected) |> invalid,
  )
  use <- bool.guard(checked_ref != ref, Error(InvalidFinitePlan))

  // Search narrows the existing declared project access before building its jail.
  // The descriptor comparison above used the original declaration, not this copy.
  let placed = case kind {
    Search ->
      jail.Placement(
        ..placement,
        server: profile.LspServer(
          ..placement.server,
          project: profile.ProjectReadOnly,
        ),
      )
    Probe | Prepare -> placement
  }
  use built <- result.try(jail.policy_for(placed, base, reading:) |> invalid)
  use Nil <- result.try(parent_matches(
    ref,
    request,
    placement,
    built,
    inventory,
    declarations,
    enrolled_digest,
    enrollment.digests(enrolled).1,
    facts.scope,
  ))
  use spec <- result.try(specification(
    kind,
    built,
    placement,
    request,
    base.limits.cpu_s,
    ref,
  ))
  let #(bounded, shortfall) = policy.compose(facts.ceiling, spec.policy, [])
  use <- bool.guard(
    bounded != spec.policy || shortfall != [],
    Error(InvalidFinitePlan),
  )
  use descriptor <- result.try(
    deployment.descriptor_fields(descriptor).3
    |> bit_array.base16_decode
    |> invalid,
  )
  use descriptor <- result.try(g.digest(descriptor) |> invalid)
  Ok(CheckedFinitePlan(
    registered,
    ref,
    request,
    selected,
    inventory,
    descriptor,
    enrolled_digest,
    kind,
    original_control,
    spec,
  ))
}

fn parent_matches(
  ref: id.LspCommandRef,
  request: lsp_wire.Request,
  placement: jail.Placement,
  built: jail.Jail,
  inventory: id.EnrolledProfiles,
  declarations: List(profile.LspServer),
  enrollment_digest: g.Digest,
  contract_hex: String,
  scope: core_workspace.Scope,
) -> Result(Nil, Error) {
  case id.command_value(ref), id.command_parent(ref) {
    mp.ArrayValue([
      _,
      mp.ArrayValue([
        mp.IntValue(1),
        _,
        mp.IntValue(ordinal),
        mp.StringValue(root),
      ]),
    ]),
      id.Search(_, _, _)
    -> {
      use server <- result.try(
        list.first(list.drop(declarations, ordinal)) |> invalid,
      )
      use _ <- result.try(id.checked_profile(inventory, ordinal) |> invalid)
      bool.guard(
        server != placement.server || root != placement.root,
        Error(InvalidFinitePlan),
        fn() { Ok(Nil) },
      )
    }
    _, id.Startup(lease) -> {
      case id.lease_value(lease) {
        mp.ArrayValue([
          _,
          _,
          lease_scope,
          _,
          _,
          mp.StringValue(step),
          mp.StringValue(request_id),
          mp.BinaryValue(input),
          mp.BinaryValue(enrolled),
          mp.BinaryValue(contract),
          _,
          _,
        ]) -> {
          use uuid <- result.try(ids.parse_entry_id(request_id) |> invalid)
          use original <- result.try(
            lsp_journal.lease_input(placement.server.name, placement.root, uuid)
            |> invalid,
          )
          use expected_contract <- result.try(
            bit_array.base16_decode(contract_hex) |> invalid,
          )
          let #(session, binding) = core_workspace.scope_fields(scope)
          let #(selector, workspace_epoch, session_epoch) =
            core_workspace.binding_fields(binding)
          let #(executor, workspace) = core_workspace.selector_fields(selector)
          let expected_scope =
            mp.ArrayValue([
              mp.StringValue(ids.session_id_to_string(session)),
              mp.StringValue(executor),
              mp.StringValue(workspace),
              mp.IntValue(workspace_epoch),
              mp.IntValue(session_epoch),
            ])
          use _ <- result.try(lsp_wire.encode_request(request) |> invalid)
          bool.guard(
            !{
              lease_scope == expected_scope
              && step == built.step_id
              && input == crypto.hash(crypto.Sha256, original)
              && enrolled == g.digest_bytes(enrollment_digest)
              && contract == expected_contract
            },
            Error(InvalidFinitePlan),
            fn() { Ok(Nil) },
          )
        }
        _ -> Error(InvalidFinitePlan)
      }
    }
    _, _ -> Error(InvalidFinitePlan)
  }
}

fn specification(
  kind: Recipe,
  built: jail.Jail,
  placement: jail.Placement,
  request: lsp_wire.Request,
  cpu: Int,
  ref: id.LspCommandRef,
) -> Result(BrokerSpecData, Error) {
  case kind {
    Prepare -> {
      use <- bool.guard(
        placement.server.preparation != profile.GleamDependencies,
        Error(InvalidFinitePlan),
      )
      use op <- result.try(original_operation(ref))
      use spec <- result.try(
        preparation.call_spec(built, op, broker_exec.FullEnforcement, now_ms: 0)
        |> invalid,
      )
      let #(cleared, shortfall) =
        policy.compose(spec.base_policy, spec.requirements, [])
      use <- bool.guard(shortfall != [], Error(InvalidFinitePlan))
      Ok(BrokerSpec(spec.argv, spec.env, spec.cwd, spec.step_id, cleared))
    }
    Probe | Search -> {
      use argv <- result.try(case kind {
        Probe -> Ok(manager.probe_argv)
        Search -> {
          use query <- result.try(symbol_query(request))
          let identifier =
            resolve.split_symbol(
              query.symbol,
              placement.server.qualifier_separators,
            ).identifier
          use <- bool.guard(identifier == "", Error(InvalidFinitePlan))
          Ok(
            manager.search_argv(manager.Search(
              placement.server,
              placement.root,
              identifier,
            )),
          )
        }
        Prepare -> Error(InvalidFinitePlan)
      })
      let suffix = case kind {
        Probe -> "/probe"
        Search -> "/search"
        Prepare -> ""
      }
      let required =
        policy.SandboxPolicy(
          ..built.requirements,
          limits: policy.Limits(
            ..built.requirements.limits,
            cpu_s: cpu,
            wall_s: wall_ms(kind) / 1000,
            output_bytes: stream_bytes(kind),
          ),
        )
      let #(cleared, shortfall) = policy.compose(built.base, required, [])
      use <- bool.guard(shortfall != [], Error(InvalidFinitePlan))
      Ok(BrokerSpec(
        argv,
        built.env,
        built.cwd,
        built.step_id <> suffix,
        cleared,
      ))
    }
  }
}

// Preparation attribution uses the real parent operation, never a placeholder.
fn original_operation(ref: id.LspCommandRef) -> Result(ids.OpId, Error) {
  let value = case id.command_parent(ref) {
    id.Startup(lease) -> id.lease_value(lease)
    id.Search(invocation, _, _) ->
      id.capture_value(id.invocation_capture(invocation))
  }
  case value {
    mp.ArrayValue([_, _, _, _, mp.StringValue(operation), ..]) ->
      ids.parse_op_id(operation) |> invalid
    _ -> Error(InvalidFinitePlan)
  }
}

fn symbol_query(
  request: lsp_wire.Request,
) -> Result(lsp_query.SymbolQuery, Error) {
  case request {
    lsp_wire.Definition(query)
    | lsp_wire.References(query)
    | lsp_wire.Hover(query)
    | lsp_wire.Calls(query, _)
    | lsp_wire.PrepareRename(query, _)
    | lsp_wire.ApplyRename(query, _, _) -> Ok(query)
    lsp_wire.Outline(_)
    | lsp_wire.Diagnostics(_)
    | lsp_wire.AfterWrite(_, _)
    | lsp_wire.Observe(_) -> Error(InvalidFinitePlan)
  }
}

fn invalid(answer: Result(a, b)) -> Result(a, Error) {
  result.replace_error(answer, InvalidFinitePlan)
}

// Search carries its own complete timing proposal. Startup carries the explicit
// checked original control because its lease header cannot reconstruct R or E0.
fn original_timing(
  ref: id.LspCommandRef,
  control: id.AdmittedFiniteControl,
) -> Result(Nil, Error) {
  case id.command_parent(ref) {
    id.Startup(_) -> Ok(Nil)
    id.Search(invocation, _, _) -> {
      let proposal = id.invocation_proposal(invocation)
      use digest <- result.try(lsp_wire.timing_digest(proposal) |> invalid)
      let #(era, _, remaining, _, original_digest) = id.control_fields(control)
      case id.timing_value(proposal) {
        mp.ArrayValue([_, mp.StringValue(proposed_era), _, mp.IntValue(r), _]) ->
          bool.guard(
            digest != original_digest
              || r != remaining
              || proposed_era != id.era_string(era),
            Error(InvalidFinitePlan),
            fn() { Ok(Nil) },
          )
        _ -> Error(InvalidFinitePlan)
      }
    }
  }
}
