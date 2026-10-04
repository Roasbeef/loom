//// Closed owner custody for the compiler beneath one retained Compile service.
////
//// The original session Broker has already cleared a real Dispatch. This module
//// independently compares its immutable offer/input/enrollment and actual Prepared
//// before the existing atomic custodian reservation grants a sendable native key.
//// It never clears a call, replaces a Broker, resolves executor paths locally or
//// constructs physical Ready evidence. Location reconstruction proves equality only.
////
//// Exact retries may allocate an unused candidate, but SQLite returns the original
//// UUID and bytes. Historical receipt and cancellation resolve the same indexed
//// full reference. Cancellation keeps those bytes for a late native receipt; it
//// cannot promise that the executor performed no effect. Recovery reads data only
//// through existing custodian APIs and never calls prepare/mint or returns Reserved.
////
//// Fresh reservation has three existing five-second asks: offer, service and
//// atomic native reservation. Receipt has three; cancellation has two. Caller
//// assembly owns aggregate admission and the unchanged whole-service deadline.
//// These successful-call budgets are not hard real-time bounds on abandoned asks.
//// SatelliteCommand is explicitly unsupported until its closed Launch assembly.
////
//// `new` pins local capabilities. `reserve` enters `resolved_offer`, `expected`
//// and `checked_prepared` before one atomic reserve. `receive` reads original
//// native bytes before durable receipt; `cancel` fences the resolved whole service.
//// `matches_scope`, `hash` and `normalized` preserve their bounded facts.

import broker/command as offer
import broker/dispatch
import broker/enrollment
import broker/policy
import client/remote/custodian
import codemode/service_command
import codemode/service_input as input
import codemode/service_resources as resources
import core/command
import core/ids
import core/remote_tool
import core/workspace
import executor/remote/dispatcher
import executor/remote/identity
import executor/remote/wire
import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import storage/owner_custody as custody

/// Fixed trusted local capabilities shared with the original dispatch binding.
@internal
pub opaque type Binding {
  /// No peer value or historical row can construct a live dispatcher capability.
  Binding(
    /// Existing supervised owner custody, including its finite limits.
    owner: custodian.Handle,
    /// Complete original administrative snapshot.
    enrolled: enrollment.SessionEnrollment,
    /// Original connection scope, including both authority epochs.
    scope: identity.Scope,
    /// Existing actual-Dispatch materializer, preserving clearance.
    prepare: fn(dispatch.Dispatch) -> Result(wire.Prepared, Nil),
    /// Existing candidate allocator; atomic retries retain the stored UUID.
    mint: fn() -> ids.EntryId,
  )
}

/// Pins the enrollment to the same complete configured connection scope.
/// This creates no actor, request identity, policy clearance or physical resource.
///
/// ## Examples
///
/// ```gleam
/// command_binding.new(owner, enrolled, scope, prepare, mint)
/// // -> Ok(binding)
/// ```
@internal
pub fn new(
  owner: custodian.Handle,
  enrolled: enrollment.SessionEnrollment,
  scope: identity.Scope,
  prepare: fn(dispatch.Dispatch) -> Result(wire.Prepared, Nil),
  mint: fn() -> ids.EntryId,
) -> Result(Binding, custody.Error) {
  use Nil <- result.try(
    bool.guard(
      !{ matches_scope(scope, enrollment.native_facts(enrolled).scope) },
      Error(custody.Conflict),
      fn() { Ok(Nil) },
    ),
  )
  Ok(Binding(owner, enrolled, scope, prepare, mint))
}

/// Reserves unchanged actual Prepared only after closed original Compile checks.
/// The atomic custodian operation owns cancellation and original UUID uniqueness.
/// A discarded candidate never replaces that logical identity. This API belongs
/// only to the live cleared Dispatch; recovery must use historical reads instead.
///
/// ## Examples
///
/// ```gleam
/// command_binding.reserve(binding, actual_dispatch)
/// // -> Ok(dispatcher.CommandReserved(key, actual_prepared, original_ref))
/// ```
@internal
pub fn reserve(
  binding: Binding,
  request: dispatch.Dispatch,
) -> Result(dispatcher.Reserved, custody.Error) {
  use origin <- result.try(
    request.context.origin
    |> option.to_result(custody.Invalid("missing command origin")),
  )
  use resolved <- result.try(resolved_offer(binding, origin))
  let #(accepted, proposal) = resolved
  let ref = offer.reference(proposal)
  let #(_, operation, step) = command.coordinates(command.service(ref))
  use Nil <- result.try(
    bool.guard(
      !{
        request.context.operation == operation
        && request.context.step == workspace.step_string(step)
      },
      Error(custody.Conflict),
      fn() { Ok(Nil) },
    ),
  )
  use expected <- result.try(expected(binding, proposal))
  use Nil <- result.try(service_command.matches(expected, proposal) |> invalid)
  use prepared <- result.try(
    binding.prepare(request)
    |> result.replace_error(custody.Invalid("actual preparation refused")),
  )

  // The callback cannot replace cleared authority or physical coordinates.
  use Nil <- result.try(
    bool.guard(
      !{
        prepared.request == request.request
        && prepared.step == request.context.step
      },
      Error(custody.Conflict),
      fn() { Ok(Nil) },
    ),
  )
  use Nil <- result.try(checked_prepared(proposal, prepared))
  use encoded <- result.try(wire.encode_prepared(prepared) |> invalid)
  let candidate = binding.mint()
  use stored <- result.try(custodian.reserve_command_child(
    binding.owner,
    accepted,
    candidate,
    encoded,
  ))
  use Nil <- result.try(
    bool.guard(
      !{ custody.bytes(stored.1) == encoded },
      Error(custody.Conflict),
      fn() { Ok(Nil) },
    ),
  )
  use decoded <- result.try(
    wire.decode_prepared(custody.bytes(stored.1)) |> invalid,
  )
  use Nil <- result.try(
    bool.guard(!{ decoded == prepared }, Error(custody.Conflict), fn() {
      Ok(Nil)
    }),
  )
  use id <- result.try(
    identity.request_id(ids.entry_id_to_string(stored.0)) |> invalid,
  )
  Ok(dispatcher.CommandReserved(
    identity.request_key(binding.scope, operation, id),
    prepared,
    ref,
  ))
}

/// Retains exact ordered receipt before the dispatcher sends DurableReceipt.
/// Cancelled evidence remains readable and accepts late native receipts. This
/// reconstructs historical data only and invokes neither prepare nor mint.
///
/// ## Examples
///
/// ```gleam
/// command_binding.receive(binding, origin, key, digest, outputs, terminal)
/// // -> Ok(Nil)
/// ```
@internal
pub fn receive(
  binding: Binding,
  origin: remote_tool.ChildOrigin,
  key: identity.RequestKey,
  digest: identity.Digest,
  outputs: List(BitArray),
  terminal: BitArray,
) -> Result(Nil, custody.Error) {
  use resolved <- result.try(resolved_offer(binding, origin))
  let proposal = resolved.1
  let ref = offer.reference(proposal)
  use stored <- result.try(custodian.command_child(binding.owner, ref))
  use prepared <- result.try(
    wire.decode_prepared(custody.bytes(stored.1)) |> invalid,
  )
  use encoded <- result.try(wire.encode_prepared(prepared) |> invalid)
  use Nil <- result.try(
    bool.guard(
      !{ encoded == custody.bytes(stored.1) },
      Error(custody.Conflict),
      fn() { Ok(Nil) },
    ),
  )
  use Nil <- result.try(checked_prepared(proposal, prepared))
  use original_digest <- result.try(wire.prepared_digest(prepared) |> invalid)
  let #(_, operation, _) = command.coordinates(command.service(ref))

  // Full immutable identity must match before any terminal bytes can commit.
  use Nil <- result.try(
    bool.guard(
      !{
        identity.key_scope(key) == binding.scope
        && identity.key_fields(key)
        == #(ids.op_id_to_string(operation), ids.entry_id_to_string(stored.0))
        && digest == original_digest
      },
      Error(custody.Conflict),
      fn() { Ok(Nil) },
    ),
  )
  use receipt <- result.try(custodian.receipt(outputs, terminal))
  custodian.receive_child(binding.owner, origin, stored.0, receipt)
}

/// Fences the exact original whole service, offer and any allocated native child.
/// Missing custody refuses: ChildOrigin cannot reconstruct the full service key.
/// The embedding dispatch binding invokes its mandatory fatal fence on failure.
///
/// ## Examples
///
/// ```gleam
/// command_binding.cancel(binding, origin)
/// // -> Ok(Nil)
/// ```
@internal
pub fn cancel(
  binding: Binding,
  origin: remote_tool.ChildOrigin,
) -> Result(Nil, custody.Error) {
  use resolved <- result.try(resolved_offer(binding, origin))
  custodian.cancel_service(
    binding.owner,
    command.service(offer.reference(resolved.1)),
  )
}

fn resolved_offer(
  binding: Binding,
  origin: remote_tool.ChildOrigin,
) -> Result(#(custody.CommandOfferPayload, offer.CommandOffer), custody.Error) {
  use role <- result.try(remote_tool.child_role(origin) |> invalid)
  use Nil <- result.try(case role {
    remote_tool.CompileCommand -> Ok(Nil)
    remote_tool.SatelliteCommand ->
      Error(custody.Invalid("unsupported SatelliteCommand"))
    remote_tool.Compile
    | remote_tool.Launch
    | remote_tool.AdmittedCapability(_, _, _)
    | remote_tool.Capability(_)
    | remote_tool.Workspace(_) -> Error(custody.Invalid("not a CompileCommand"))
  })
  use accepted <- result.try(custodian.command_offer_for_origin(
    binding.owner,
    origin,
  ))
  let #(ref, digest) = custody.offer_identity(accepted)
  let bytes = custody.offer_content(accepted)
  use proposal <- result.try(offer.decode(bytes) |> invalid)
  use canonical <- result.try(offer.encode(proposal) |> invalid)
  use actual_digest <- result.try(hash(bytes))
  let service = command.service(ref)
  let #(scope, _, _) = command.coordinates(service)
  let #(_, registration, contract) = command.digests(service)
  use Nil <- result.try(
    bool.guard(
      !{
        canonical == bytes
        && actual_digest == digest
        && offer.reference(proposal) == ref
        && command.native_origin(ref) == origin
        && scope == enrollment.native_facts(binding.enrolled).scope
        && enrollment.digests(binding.enrolled) == #(registration, contract)
      },
      Error(custody.Conflict),
      fn() { Ok(Nil) },
    ),
  )
  Ok(#(accepted, proposal))
}

fn expected(
  binding: Binding,
  proposal: offer.CommandOffer,
) -> Result(service_command.ExpectedCommand, custody.Error) {
  let service = command.service(offer.reference(proposal))
  use retained <- result.try(custodian.service_child(binding.owner, service))
  use body <- result.try(custody.service_input(retained.0))
  use original <- result.try(input.decode_compile(body) |> invalid)
  let facts = input.compile_facts(original)
  use body_digest <- result.try(hash(body))
  let #(input_digest, _, _) = command.digests(service)
  use Nil <- result.try(
    bool.guard(
      !{ input.encode_compile(original) == body && body_digest == input_digest },
      Error(custody.Conflict),
      fn() { Ok(Nil) },
    ),
  )
  use Nil <- result.try(
    enrollment.matches(binding.enrolled, facts.enrolled) |> invalid,
  )
  use root <- result.try(
    enrollment.compile_path(binding.enrolled, service) |> invalid,
  )
  use locations <- result.try(
    resources.admit_compile_locations(binding.enrolled, service, root)
    |> invalid,
  )
  service_command.compile_from_input(
    binding.enrolled,
    service,
    original,
    locations,
    offer.data(proposal).requirements.limits.wall_s,
  )
  |> invalid
}

fn checked_prepared(
  proposal: offer.CommandOffer,
  prepared: wire.Prepared,
) -> Result(Nil, custody.Error) {
  let service = command.service(offer.reference(proposal))
  let #(_, _, step) = command.coordinates(service)
  let #(_, registration, _) = command.digests(service)
  use actual <- result.try(
    prepared.request.policy |> option.to_result(custody.Conflict),
  )
  use Nil <- result.try(policy.validate(actual) |> invalid)
  let data = offer.data(proposal)
  let #(bounded, _) = policy.compose(data.requirements, actual, [])
  use Nil <- result.try(
    bool.guard(
      !{
        prepared.step == workspace.step_string(step)
        && string.lowercase(
          bit_array.base16_encode(identity.digest_bytes(prepared.registration)),
        )
        == registration
        && prepared.stream == wire.Logs
        && prepared.request.argv == data.argv
        && prepared.request.env == data.env
        && prepared.request.cwd == data.cwd
        && normalized(bounded) == normalized(actual)
      },
      Error(custody.Conflict),
      fn() { Ok(Nil) },
    ),
  )
  case prepared.lifetime {
    wire.Finite(ms)
      if actual.limits.wall_s > 0 && actual.limits.wall_s * 1000 <= ms
    -> Ok(Nil)
    wire.Finite(_) | wire.Session -> Error(custody.Conflict)
  }
}

fn matches_scope(native: identity.Scope, enrolled: workspace.Scope) -> Bool {
  let #(session, binding) = workspace.scope_fields(enrolled)
  let #(selector, workspace_epoch, session_epoch) =
    workspace.binding_fields(binding)
  let #(executor, name) = workspace.selector_fields(selector)
  identity.scope_fields(native)
  == #(
    ids.session_id_to_string(session),
    name,
    executor,
    session_epoch,
    workspace_epoch,
  )
}

fn hash(bytes: BitArray) -> Result(String, custody.Error) {
  use digest <- result.try(wire.digest(bytes) |> invalid)
  Ok(string.lowercase(bit_array.base16_encode(identity.digest_bytes(digest))))
}

fn normalized(value: policy.SandboxPolicy) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..value,
    protected: list.sort(value.protected, string.compare),
    env_allow: list.sort(value.env_allow, string.compare),
  )
}

fn invalid(value: Result(a, e)) -> Result(a, custody.Error) {
  result.replace_error(
    value,
    custody.Invalid("invalid retained compiler evidence"),
  )
}
