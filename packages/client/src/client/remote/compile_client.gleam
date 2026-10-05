//// Owner consumption of the whole remote compiler under original tool custody.
////
//// `new` pins the existing owner, Broker, enrollment and concrete TLS BEAM endpoint.
//// Live assembly passes the original runner callback's incarnation-pinned Handle;
//// an external historical handle never supplies another live admission.
//// `service` is an internal CompileService adapter for the custodian's original
//// Fresh managed body. That existing owner admits at most four bodies; this
//// module creates no second actor, Broker, registry or execution budget. Trusted
//// assembly must install its lifecycle admission fence before enabling this
//// adapter: a callback in a killed worker cannot fence a missing final report.
////
//// The administrative Peer belongs to the original successful TLS distribution
//// boot. Whole Compile and native command traffic use its one fixed endpoint.
//// Bounded operation headers and reply segments retain the existing canonical
//// service input, completion and native receipt bytes; runtime membership itself
//// proves neither service admission nor receipt retention.
////
//// The original managed caller owns the observation; its death cancels the
//// nested weft run without claiming queued writes were retracted.
////
//// A live call converts its original nonzero Unix budget to one monotonic
//// deadline. It reserves exact input before transmission, observes real Ready,
//// retains one immutable finite-wall offer and uses actual Broker clearance.
//// The dispatcher owns native settlement and its ordered durable receipt. Only
//// a checked exact outer completion retained by the owner permits outer ACK.
//// Recovery observes original identities and never reconstructs live permission.
////
//// Service custody uses Compile; the native command uses CompileCommand. Their
//// receipts, cancellation, executor collection and resource cleanup are separate.
//// A timeout ends observation and cannot retract a queued write or prove that a
//// peer consumed an ask. Consumer-detected uncertain custody invokes the existing
//// mandatory fatal fence, while production lifetime fencing remains assembly's
//// independent prerequisite. ExecutorArtifact paths never become owner paths.
////
//// ## Flow
////
//// - `new` validates pinned facts; `service` projects `invoke` over the original
////   adapter. `live_identity` and `original_deadline` refuse before effects.
//// - `invoke` enters `live_call`, `reserve_original`, `challenge_submit` and
////   `await_ready`. `start_native` retains the offer before `accepted_command`
////   constructs the private clearance; `await_completion` observes exact evidence.
//// - `recover` and `cancel`/`cancel_original` resolve `historical` with the existing canonical
////   envelope decoder. Neither path challenges, clears, prepares or mints.
//// - `retain_completion` and `native_evidence` validate independent native
////   custody before `acknowledge`. `receipt_terminal` scans the closed ordered
////   receipt shape because its aggregate can exceed the generic wire scanner.

import broker/broker
import broker/command as offer
import broker/enrollment
import broker/policy
import client/remote/custodian
import codemode/compile
import codemode/enforcement
import codemode/identity as phase
import codemode/service_command
import codemode/service_input as input
import codemode/service_resources as resources
import codemode/vet
import core/clock
import core/command
import core/ids
import core/remote_tool
import core/workspace
import executor/remote/beam_endpoint as transport
import executor/remote/compile_completion as completion
import executor/remote/compile_wire as protocol
import executor/remote/identity
import executor/remote/resource_journal as journal
import executor/remote/wire
import gleam/bit_array
import gleam/bool
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import storage/owner_custody as custody
import tools/tool
import weft
import weft/poll

/// Fixed trusted compiler facts, without a source or execution budget.
@internal
pub type Facts {
  /// The host selects these once before exposing its physical CompileService.
  Facts(
    /// The actual owner-vetting seam, checked again by the executor contract.
    seam: input.ProgramSeam,
    /// Original policy limits; compiler regions are derived only from Ready.
    policy_seed: policy.SandboxPolicy,
    /// Original maximum compiler stage, distinct from the whole invocation.
    build_timeout_ms: Int,
    /// Actual original Broker clearance wait, distinct from challenge lifetime.
    clearance_wait_ms: Int,
    /// Full host facade table before the pipeline selects imported modules.
    generated: List(#(String, String)),
    /// Original configured owner quotas; the actual custodian rechecks them.
    owner_limits: custody.Limits,
  )
}

/// Trusted local wiring for the original bounded managed owner body.
@internal
pub opaque type Config {
  Config(
    /// The existing durable owner and its already configured finite quotas.
    owner: custodian.Handle,
    /// Exact administrative enrollment; advertisements never replace it.
    enrolled: enrollment.SessionEnrollment,
    /// Original session Broker; this module constructs no second authority.
    original_broker: broker.Broker,
    /// Same administratively configured TLS BEAM peer as the native dispatcher.
    endpoint: transport.Config,
    /// Existing UUID candidate allocator, unused during historical observation.
    mint: fn() -> ids.EntryId,
    /// Same Unix clock capability used when constructing the original Broker.
    original_clock: clock.Clock,
    /// Same monotonic reader used by the original native dispatcher.
    now: fn() -> Int,
    /// Fixed original service facts, without per-call authority.
    facts: Facts,
  )
}

/// Configuration refusal occurs before journal or transport activity.
@internal
pub type ConfigurationError {
  /// Endpoint, full scope or bounded compiler facts failed validation.
  InvalidConfiguration
}

/// A failure retains original provenance rather than granting replacement work.
@internal
pub type Error {
  /// Original phase, complete identity or bounded canonical evidence disagrees.
  Invalid(reason: String)

  /// A queued custody operation may still complete; the assembly is fenced.
  OwnerUnavailable(reason: custody.Error)

  /// The original observation ended without authoritative completion.
  Uncertain
}

/// Executor collection is independent of the already committed owner receipt.
@internal
pub type Acknowledgement {
  /// Exact owner completion is durable; peer collection was not confirmed.
  OwnerRetained

  /// The peer reported the same completion digest as acknowledged.
  ExecutorAcknowledged
}

/// Historical outcomes grant no Submit, clearance or preparation capability.
@internal
pub type Observation {
  /// Original identity remains retained without an exact final completion.
  Pending(
    /// Entire original service key, including its independent UUID.
    key: command.ServiceKey,
    /// Location history is data only, never a usable resource lease.
    preparation: journal.Status,
  )

  /// Exact completion is durably retained locally before this result escapes.
  Completed(
    /// Original service key, never a fresh retry identity.
    key: command.ServiceKey,
    /// Artifact/error and enforcement derived by the closed completion codec.
    compiled: compile.Compiled,
    /// Peer collection state; local receipt does not depend on its success.
    acknowledgement: Acknowledgement,
  )
}

/// A cancellation fence proves admission ordering, not native retirement.
@internal
pub type Cancellation {
  /// No service reservation was observed; its original origin is fenced locally.
  LocalFence

  /// Local service/offer/native custody is fenced and the peer responded.
  ExecutorFence(
    /// Resource fence preserves original history and possible in-flight effects.
    fence: journal.PreparationFence,
  )
}

type Reservation {
  Reservation(
    original: custody.ServiceRequest,
    body: input.CompileInput,
    outbound: journal.Input,
  )
}

type Admission {
  Fresh(reservation: Reservation)
  Historical(reservation: Reservation, receipt: Option(custody.Payload))
}

type AcceptedCompileCommand {
  AcceptedCompileCommand(spec: broker.CallSpec, origin: remote_tool.ChildOrigin)
}

/// Pins the existing capabilities without effects or creating another clock.
/// Facts.owner_limits carries the original configured quotas; the actual owner
/// remains authoritative if a supplied quota value differs.
/// Only trusted assembly may expose this adapter inside the original Fresh
/// custodian body, using that callback's pinned owner Handle and its durable
/// missing-report admission fence.
///
/// ## Examples
///
/// ```gleam
/// compile_client.new(owner, enrolled, broker, endpoint, mint, clock, now, facts)
/// // -> Ok(config), when full scope and fixed compiler bounds agree.
/// ```
@internal
pub fn new(
  owner: custodian.Handle,
  enrolled: enrollment.SessionEnrollment,
  original_broker: broker.Broker,
  endpoint: transport.Config,
  mint: fn() -> ids.EntryId,
  original_clock: clock.Clock,
  now: fn() -> Int,
  facts: Facts,
) -> Result(Config, ConfigurationError) {
  let fields = identity.scope_fields(endpoint.scope)
  use semantic <- result.try(
    workspace.scope_from_fields(
      fields.0,
      fields.1,
      fields.2,
      fields.3,
      fields.4,
    )
    |> result.replace_error(InvalidConfiguration),
  )
  use _owner <- result.try(
    identity.executor_id(endpoint.owner)
    |> result.replace_error(InvalidConfiguration),
  )
  use Nil <- result.try(
    transport.validate(endpoint) |> result.replace_error(InvalidConfiguration),
  )
  use Nil <- result.try(
    policy.validate(facts.policy_seed)
    |> result.replace_error(InvalidConfiguration),
  )
  use <- bool.guard(
    !{
      semantic == enrollment.native_facts(enrolled).scope
      && endpoint.executor == fields.2
      && endpoint.generation > 0
      && endpoint.generation <= 2_147_483_647
      && endpoint.within_ms > 0
      && endpoint.within_ms <= 30_000
      && facts.build_timeout_ms > 0
      && facts.build_timeout_ms <= 86_400_000
      && facts.clearance_wait_ms > 0
      && facts.clearance_wait_ms <= 30_000
    },
    Error(InvalidConfiguration),
  )
  Ok(Config(
    owner,
    enrolled,
    original_broker,
    endpoint,
    mint,
    original_clock,
    now,
    facts,
  ))
}

/// Projects the real physical adapter without granting unrestricted concurrency.
/// The host installs it only in the existing bounded Fresh managed tool body;
/// historical recovery never invokes this compile callback.
///
/// ## Examples
///
/// ```gleam
/// let physical = compile_client.service(config)
/// physical.compile(original_compile_request)
/// // -> Compiled(result, enforcement), after exact custody or explicit uncertainty.
/// ```
@internal
pub fn service(config: Config) -> compile.CompileService {
  compile.CompileService(
    dependencies: compile.default_dependencies(),
    generated: config.facts.generated,
    compile: invoke(config, _),
  )
}

/// Reads historical evidence without minting, clearance or first submission.
/// A single Query may transfer an exact existing completion and ACK its receipt.
/// An existing owner receipt retries only its original digest ACK and remains
/// usable when that finite endpoint exchange fails.
///
/// ## Examples
///
/// ```gleam
/// compile_client.recover(config, original_compile_origin)
/// // -> Ok(Completed(original_key, compiled, OwnerRetained)).
/// ```
@internal
pub fn recover(
  config: Config,
  original: remote_tool.ChildOrigin,
) -> Result(Observation, Error) {
  use #(reserved, receipt) <- result.try(historical(config, original))
  case receipt {
    Some(bytes) -> {
      use value <- result.try(decode_completion(
        config,
        reserved,
        custody.bytes(bytes),
      ))
      use digest <- result.try(wire.digest(custody.bytes(bytes)) |> invalid)

      // Historical ACK transfers only this already committed digest. Its failure
      // cannot erase the usable local result or grant another live invocation.
      let acknowledged = acknowledge(config, reserved, digest, None)
      Ok(Completed(
        reserved.outbound.key,
        completion.compiled(value),
        acknowledged,
      ))
    }
    None -> {
      use reply <- result.try(exchange(config, reserved, protocol.Query, None))
      observe_reply(config, reserved, reply, None)
    }
  }
}

/// Commits the original local fence before asking the peer to cancel.
/// Missing reservation fences the Compile origin before it can reserve an ID;
/// timeout cannot be interpreted as consumed cancellation or native retirement.
///
/// ## Examples
///
/// ```gleam
/// compile_client.cancel(config, original_compile_origin)
/// // -> Ok(LocalFence), when no original service reservation exists.
/// ```
@internal
pub fn cancel(
  config: Config,
  original: remote_tool.ChildOrigin,
) -> Result(Cancellation, Error) {
  use Nil <- result.try(compile_origin(original))
  use parent <- result.try(remote_tool.child_tool(original) |> invalid)
  let answer = cancel_original(config, original)

  // Failed observation of a queued cancellation cannot release the original
  // run's admission. A pinned live owner persists sticky custody directly.
  case answer {
    Error(Uncertain) | Error(OwnerUnavailable(custody.Unavailable(_))) -> {
      let _fenced = custodian.fatal_fence(config.owner, parent)
      answer
    }
    Ok(_)
    | Error(Invalid(_))
    | Error(OwnerUnavailable(custody.Conflict))
    | Error(OwnerUnavailable(custody.Missing))
    | Error(OwnerUnavailable(custody.Capacity))
    | Error(OwnerUnavailable(custody.Frozen))
    | Error(OwnerUnavailable(custody.Invalid(_)))
    | Error(OwnerUnavailable(custody.CollectionPending)) -> answer
  }
}

fn cancel_original(
  config: Config,
  original: remote_tool.ChildOrigin,
) -> Result(Cancellation, Error) {
  case historical(config, original) {
    Error(OwnerUnavailable(custody.Missing)) -> {
      use Nil <- result.try(
        owner(custodian.cancel_child(config.owner, original)),
      )
      Ok(LocalFence)
    }
    Error(error) -> Error(error)
    Ok(#(reserved, _)) -> {
      use Nil <- result.try(
        owner(custodian.cancel_service(config.owner, reserved.outbound.key)),
      )
      use reply <- result.try(exchange(config, reserved, protocol.Cancel, None))
      case reply {
        protocol.Cancelled(fence) -> Ok(ExecutorFence(fence))
        protocol.Challenge(_, _, _) | protocol.Observed(_, _) ->
          Error(Uncertain)
      }
    }
  }
}

fn invoke(config: Config, request: compile.CompileRequest) -> compile.Compiled {
  let result = {
    use original <- result.try(live_identity(request.identity))
    use parent <- result.try(remote_tool.child_tool(original) |> invalid)
    use deadline <- result.try(original_deadline(config, request.identity))
    use original_input <- result.try(
      input.compile_input(
        config.enrolled,
        config.facts.seam,
        vet.vetted_source(request.vetted),
        request.generated,
        request.dependencies,
        config.facts.policy_seed,
        config.facts.build_timeout_ms,
      )
      |> invalid,
    )

    // Pure wire refusal precedes the uncertainty-bearing observer. Only a task
    // that can ask custody or transport requires sticky fencing on failure.
    let body = fn() {
      live_call(config, request, original_input, original, deadline)
    }
    let observed = case
      weft.new([body])
      |> weft.cancel_when_exits(process.self())
      |> weft.deadline(remaining(config, deadline))
      |> weft.start
    {
      [weft.Completed(_, answer)] -> Ok(answer)
      [weft.Failed(_, error)] -> Error(error)
      [weft.Abandoned(_)] | [weft.NeverStarted(_)] -> Error(Uncertain)
      _ -> Error(Uncertain)
    }

    // The live attempt may have queued work before its response was lost.
    // Sticky host fencing prevents a final error report from reopening admission;
    // assembly's durable lifecycle fence also covers death of this observer.
    case observed {
      Ok(value) -> Ok(value)
      Error(error) -> {
        let _fenced = custodian.fatal_fence(config.owner, parent)
        Error(error)
      }
    }
  }
  case result {
    Ok(compiled) -> compiled
    Error(_) ->
      compile.Compiled(
        Error(compile.BuildUnavailable(
          "remote compile observation unavailable; original custody retained",
        )),
        enforcement.Unreported(
          "remote compile completion was not durably observed",
        ),
      )
  }
}

fn live_identity(
  identity: phase.PhaseIdentity,
) -> Result(remote_tool.ChildOrigin, Error) {
  use <- bool.guard(
    phase.phase(identity) != phase.Build,
    Error(Invalid("compile requires Build phase")),
  )
  use native <- result.try(
    phase.command_origin(identity)
    |> result.replace_error(Invalid("invalid managed Build origin")),
  )
  use native <- result.try(option.to_result(
    native,
    Invalid("remote compile requires original managed parent"),
  ))
  use parent <- result.try(
    remote_tool.child_tool(native)
    |> result.replace_error(Invalid("missing original tool parent")),
  )
  remote_tool.tool_child(parent, remote_tool.Compile) |> invalid
}

fn original_deadline(
  config: Config,
  identity: phase.PhaseIdentity,
) -> Result(Int, Error) {
  let origin = config.now()
  let #(wall, _) = clock.read(config.original_clock)
  let budget = phase.pooled_budget(identity)
  let within = budget.deadline_ms - wall
  use <- bool.guard(
    !{
      budget.deadline_ms > 0
      && within > 0
      && within <= 86_400_000
      && budget.max_outstanding > 0
    },
    Error(Invalid("compile requires original finite live budget")),
  )
  Ok(origin + within)
}

fn live_call(
  config: Config,
  request: compile.CompileRequest,
  body: input.CompileInput,
  origin: remote_tool.ChildOrigin,
  deadline: Int,
) -> Result(compile.Compiled, Error) {
  use admitted <- result.try(reserve_original(config, request, origin, body))
  case admitted {
    Historical(reserved, receipt) -> {
      let result = case receipt {
        Some(bytes) ->
          decode_completion(config, reserved, custody.bytes(bytes))
          |> result.map(completion.compiled)
        None -> observe_existing(config, reserved, deadline)
      }
      result
    }
    Fresh(reserved) -> {
      use submitted <- result.try(challenge_submit(config, reserved, deadline))
      use first <- result.try(await_ready(config, reserved, submitted, deadline))
      case first {
        protocol.Observed(_, protocol.Retained(_, _, _, _)) ->
          completed_reply(config, reserved, first, Some(deadline))
        protocol.Observed(
          journal.Prepared(resources.CompileReady(locations)),
          protocol.Pending,
        ) -> {
          use Nil <- result.try(start_native(
            config,
            reserved,
            locations,
            request.identity,
            deadline,
          ))
          await_completion(config, reserved, deadline)
        }
        protocol.Observed(
          journal.Prepared(resources.LaunchReady(_)),
          protocol.Pending,
        )
        | protocol.Observed(journal.Reserved, protocol.Pending)
        | protocol.Observed(journal.Unknown(_), protocol.Pending)
        | protocol.Observed(journal.Released(_), protocol.Pending)
        | protocol.Challenge(_, _, _)
        | protocol.Cancelled(_) -> Error(Uncertain)
      }
    }
  }
}

fn reserve_original(
  config: Config,
  request: compile.CompileRequest,
  origin: remote_tool.ChildOrigin,
  body: input.CompileInput,
) -> Result(Admission, Error) {
  let bytes = input.encode_compile(body)
  case custodian.child(config.owner, origin) {
    Ok(_) -> {
      use #(reserved, receipt) <- result.try(historical(config, origin))
      use Nil <- result.try(same_live_request(reserved, body, request.identity))
      Ok(Historical(reserved, receipt))
    }
    Error(custody.Missing) -> {
      use parent <- result.try(
        remote_tool.child_tool(origin)
        |> result.replace_error(Invalid("missing original parent")),
      )
      use step <- result.try(
        workspace.step(phase.step_id(request.identity)) |> invalid,
      )
      let #(registration, contract) = enrollment.digests(config.enrolled)
      use key <- result.try(
        command.service_key(
          parent,
          command.CompileService,
          enrollment.native_facts(config.enrolled).scope,
          phase.op_id(request.identity),
          step,
          config.mint(),
          hash(bytes),
          registration,
          contract,
        )
        |> invalid,
      )
      use retained <- result.try(
        owner(custodian.reserve_service_child(config.owner, key, bytes)),
      )
      Ok(Fresh(Reservation(retained, body, journal.Input(key, bytes))))
    }
    Error(error) -> owner(Error(error))
  }
}

fn same_live_request(
  reserved: Reservation,
  expected: input.CompileInput,
  original_phase: phase.PhaseIdentity,
) -> Result(Nil, Error) {
  let #(_, operation, step) = command.coordinates(reserved.outbound.key)
  use <- bool.guard(
    !{
      reserved.outbound.body == input.encode_compile(expected)
      && operation == phase.op_id(original_phase)
      && workspace.step_string(step) == phase.step_id(original_phase)
    },
    Error(Invalid("retained compile differs from original request")),
  )
  Ok(Nil)
}

fn historical(
  config: Config,
  origin: remote_tool.ChildOrigin,
) -> Result(#(Reservation, Option(custody.Payload)), Error) {
  use Nil <- result.try(compile_origin(origin))
  use row <- result.try(owner(custodian.child(config.owner, origin)))
  use outbound <- result.try(
    protocol.decode_input(config.enrolled, row.1)
    |> result.replace_error(Invalid("invalid historical compile envelope")),
  )
  use <- bool.guard(
    command.service_origin(outbound.key) != origin
      || command.request_id(outbound.key) != row.0,
    Error(Invalid("historical Compile origin changed")),
  )
  use stored <- result.try(
    owner(custodian.service_child(config.owner, outbound.key)),
  )
  use <- bool.guard(
    custody.service_content(stored.0) != row.1,
    Error(Invalid("historical service bytes changed")),
  )
  use body <- result.try(input.decode_compile(outbound.body) |> invalid)
  Ok(#(Reservation(stored.0, body, outbound), stored.1))
}

fn compile_origin(origin: remote_tool.ChildOrigin) -> Result(Nil, Error) {
  case remote_tool.child_role(origin) {
    Ok(remote_tool.Compile) -> Ok(Nil)
    Ok(_) | Error(_) ->
      Error(Invalid("outer receipt requires Compile service origin"))
  }
}

fn challenge_submit(
  config: Config,
  reserved: Reservation,
  deadline: Int,
) -> Result(protocol.Reply, Error) {
  use challenge <- result.try(exchange(
    config,
    reserved,
    protocol.ChallengeRequest,
    Some(deadline),
  ))
  use nonce <- result.try(case challenge {
    protocol.Challenge(key, nonce, 1000) if key == reserved.outbound.key ->
      Ok(nonce)
    protocol.Challenge(_, _, _)
    | protocol.Observed(_, _)
    | protocol.Cancelled(_) ->
      Error(Invalid("invalid original Compile challenge"))
  })
  let budget = remaining(config, deadline) - 1100
  use <- bool.guard(budget <= 0, Error(Uncertain))
  exchange(config, reserved, protocol.Submit(nonce, budget), Some(deadline))
}

fn await_ready(
  config: Config,
  reserved: Reservation,
  first: protocol.Reply,
  deadline: Int,
) -> Result(protocol.Reply, Error) {
  case first {
    protocol.Observed(journal.Reserved, protocol.Pending)
    | protocol.Observed(journal.Unknown(None), protocol.Pending) ->
      poll_ready(config, reserved, deadline)
    protocol.Observed(_, _) -> Ok(first)
    protocol.Challenge(_, _, _) | protocol.Cancelled(_) -> Error(Uncertain)
  }
}

fn poll_ready(
  config: Config,
  reserved: Reservation,
  deadline: Int,
) -> Result(protocol.Reply, Error) {
  case
    poll.until(within: remaining(config, deadline), every: 25, attempt: fn() {
      case exchange(config, reserved, protocol.Query, Some(deadline)) {
        Ok(protocol.Observed(journal.Reserved, protocol.Pending))
        | Ok(protocol.Observed(journal.Unknown(None), protocol.Pending)) ->
          poll.Retry
        Ok(reply) -> poll.Done(reply)
        Error(error) -> poll.Fail(error)
      }
    })
  {
    poll.Answered(reply) -> Ok(reply)
    poll.Failed(error) -> Error(error)
    poll.Expired -> Error(Uncertain)
  }
}

fn start_native(
  config: Config,
  reserved: Reservation,
  locations: resources.CompileLocations,
  original: phase.PhaseIdentity,
  deadline: Int,
) -> Result(Nil, Error) {
  // Only pending successful asks consume this startup allowance. An abandoned
  // ask remains uncertain and cannot justify a new attempt or renewed wall.
  let pending =
    44_000 + config.facts.clearance_wait_ms + 2 * config.endpoint.within_ms
  let available = { remaining(config, deadline) - 1100 - pending } / 1000
  let seed_wall = config.facts.policy_seed.limits.wall_s
  let ceiling_wall =
    enrollment.native_facts(config.enrolled).ceiling.limits.wall_s
  let wall =
    list.fold(
      [seed_wall, ceiling_wall],
      config.facts.build_timeout_ms / 1000,
      fn(cap, limit) {
        case limit > 0 {
          True -> int.min(cap, limit)
          False -> cap
        }
      },
    )
    |> int.min(available)
  use <- bool.guard(wall <= 0, Error(Uncertain))
  use expected <- result.try(
    service_command.compile_from_input(
      config.enrolled,
      reserved.outbound.key,
      reserved.body,
      locations,
      wall,
    )
    |> invalid,
  )
  let proposed = service_command.offer(expected)
  use bytes <- result.try(offer.encode(proposed) |> invalid)
  use payload <- result.try(
    owner(custody.command_offer_payload(
      config.facts.owner_limits,
      offer.reference(proposed),
      hash(bytes),
      bytes,
    )),
  )

  // The returned admission proves the immutable offer transaction completed.
  // A lost reply grants no clearance, even if recovery later finds the write.
  use _ <- result.try(
    owner(custodian.admit_offer(config.owner, reserved.original, payload)),
  )
  use accepted <- result.try(accepted_command(
    config,
    reserved,
    payload,
    locations,
    original,
    wall,
  ))
  use <- bool.guard(remaining(config, deadline) <= 0, Error(Uncertain))
  let events = process.new_subject()
  use _ <- result.try(
    broker.clear_call_from(
      config.original_broker,
      accepted.origin,
      accepted.spec,
      events: events,
      waiting: config.facts.clearance_wait_ms,
    )
    |> result.replace_error(Uncertain),
  )

  // The dispatcher commits the ordered native receipt before its settlement.
  // The surrounding original weft deadline bounds this per-receive collector.
  use settled <- result.try(
    tool.collect_events(events, waiting: remaining(config, deadline))
    |> result.replace_error(Uncertain),
  )
  case settled.outcome {
    broker.CallExited(_) -> Ok(Nil)
    broker.CallFailed(_) -> Error(Uncertain)
  }
}

fn accepted_command(
  config: Config,
  reserved: Reservation,
  retained: custody.CommandOfferPayload,
  locations: resources.CompileLocations,
  original: phase.PhaseIdentity,
  wall: Int,
) -> Result(AcceptedCompileCommand, Error) {
  use origin <- result.try(live_identity(original))
  use Nil <- result.try(same_live_request(reserved, reserved.body, original))
  use <- bool.guard(
    custody.service_identity(reserved.original) != reserved.outbound.key
      || command.service_origin(reserved.outbound.key) != origin,
    Error(Invalid("retained service differs from original phase")),
  )
  use expected <- result.try(
    service_command.compile_from_input(
      config.enrolled,
      reserved.outbound.key,
      reserved.body,
      locations,
      wall,
    )
    |> invalid,
  )
  use proposed <- result.try(
    offer.decode(custody.offer_content(retained)) |> invalid,
  )
  use Nil <- result.try(service_command.matches(expected, proposed) |> invalid)
  let ref = offer.reference(proposed)
  use <- bool.guard(
    custody.offer_identity(retained)
      != #(ref, hash(custody.offer_content(retained))),
    Error(Invalid("retained offer identity differs")),
  )
  let data = offer.data(proposed)
  let native = enrollment.native_facts(config.enrolled)

  // Compose keeps left-side set order. Construct these sets in native-ceiling
  // order before actual clearance, while retaining ordered literal environment.
  let projected =
    policy.SandboxPolicy(
      ..data.requirements,
      protected: list.unique(list.append(
        native.ceiling.protected,
        data.requirements.protected,
      )),
      env_allow: list.filter(native.ceiling.env_allow, fn(name) {
        list.contains(data.requirements.env_allow, name)
      }),
    )
  use Nil <- result.try(policy.validate(projected) |> invalid)
  use <- bool.guard(
    list.sort(projected.env_allow, string.compare)
      != list.sort(data.requirements.env_allow, string.compare),
    Error(Invalid("native ceiling cannot admit required compiler environment")),
  )
  let #(bounded, _) = policy.compose(native.ceiling, projected, [])
  use <- bool.guard(
    normalized(bounded) != normalized(projected),
    Error(Invalid("effective compiler policy exceeds native ceiling")),
  )
  use native_origin <- result.try(phase.command_origin(original) |> invalid)
  use native_origin <- result.try(option.to_result(
    native_origin,
    Invalid("missing original native origin"),
  ))
  use <- bool.guard(
    native_origin != command.native_origin(ref),
    Error(Invalid("native command parent differs")),
  )
  Ok(AcceptedCompileCommand(
    broker.CallSpec(
      op_id: phase.op_id(original),
      step_id: phase.step_id(original),
      base_policy: projected,
      requirements: projected,
      grants: [],
      response: broker.RefuseNarrowed,
      demand: native.demand,
      argv: data.argv,
      env: data.env,
      cwd: data.cwd,
      budget: phase.pooled_budget(original),
    ),
    native_origin,
  ))
}

fn await_completion(
  config: Config,
  reserved: Reservation,
  deadline: Int,
) -> Result(compile.Compiled, Error) {
  case
    poll.until(within: remaining(config, deadline), every: 25, attempt: fn() {
      case exchange(config, reserved, protocol.Query, Some(deadline)) {
        Ok(protocol.Observed(_, protocol.Pending)) -> poll.Retry
        Ok(reply) -> {
          case completed_reply(config, reserved, reply, Some(deadline)) {
            Ok(value) -> poll.Done(value)
            Error(error) -> poll.Fail(error)
          }
        }
        Error(error) -> poll.Fail(error)
      }
    })
  {
    poll.Answered(value) -> Ok(value)
    poll.Failed(error) -> Error(error)
    poll.Expired -> Error(Uncertain)
  }
}

fn observe_existing(
  config: Config,
  reserved: Reservation,
  deadline: Int,
) -> Result(compile.Compiled, Error) {
  await_completion(config, reserved, deadline)
}

fn observe_reply(
  config: Config,
  reserved: Reservation,
  reply: protocol.Reply,
  deadline: Option(Int),
) -> Result(Observation, Error) {
  case reply {
    protocol.Observed(status, protocol.Pending) ->
      Ok(Pending(reserved.outbound.key, status))
    protocol.Observed(_, protocol.Retained(value, bytes, digest, _)) -> {
      use checked <- result.try(retain_completion(
        config,
        reserved,
        value,
        bytes,
        digest,
      ))
      let acknowledged = acknowledge(config, reserved, digest, deadline)
      Ok(Completed(
        reserved.outbound.key,
        completion.compiled(checked),
        acknowledged,
      ))
    }
    protocol.Challenge(_, _, _) | protocol.Cancelled(_) -> Error(Uncertain)
  }
}

fn completed_reply(
  config: Config,
  reserved: Reservation,
  reply: protocol.Reply,
  deadline: Option(Int),
) -> Result(compile.Compiled, Error) {
  use observed <- result.try(observe_reply(config, reserved, reply, deadline))
  case observed {
    Completed(_, compiled, _) -> Ok(compiled)
    Pending(_, _) -> Error(Uncertain)
  }
}

fn retain_completion(
  config: Config,
  reserved: Reservation,
  purported: completion.CompileCompletion,
  bytes: BitArray,
  digest: identity.Digest,
) -> Result(completion.CompileCompletion, Error) {
  use checked <- result.try(decode_completion(config, reserved, bytes))
  use actual_digest <- result.try(wire.digest(bytes) |> invalid)
  use <- bool.guard(
    checked != purported || actual_digest != digest,
    Error(Invalid("completion DTO differs from exact canonical bytes")),
  )
  use current <- result.try(
    owner(custodian.service_child(config.owner, reserved.outbound.key)),
  )
  use <- bool.guard(
    custody.service_content(current.0)
      != custody.service_content(reserved.original),
    Error(Invalid("original service custody changed")),
  )
  use Nil <- result.try(native_evidence(config, reserved, checked))

  // A late exact receipt is valid after cancellation. Only this committed
  // NativeReceipt operation permits the caller to send the outer ACK.
  use Nil <- result.try(
    owner(custodian.receive_child(
      config.owner,
      command.service_origin(reserved.outbound.key),
      command.request_id(reserved.outbound.key),
      bytes,
    )),
  )
  Ok(checked)
}

fn decode_completion(
  config: Config,
  reserved: Reservation,
  bytes: BitArray,
) -> Result(completion.CompileCompletion, Error) {
  use <- bool.guard(
    bit_array.byte_size(bytes) > 262_144,
    Error(Invalid("outer completion exceeds closed codec bound")),
  )
  use checked <- result.try(
    completion.decode(config.enrolled, reserved.outbound.key, bytes) |> invalid,
  )
  use canonical <- result.try(completion.encode(checked) |> invalid)
  use <- bool.guard(
    canonical != bytes || completion.original(checked) != reserved.outbound.key,
    Error(Invalid("noncanonical or foreign completion")),
  )
  Ok(checked)
}

fn native_evidence(
  config: Config,
  reserved: Reservation,
  checked: completion.CompileCompletion,
) -> Result(Nil, Error) {
  case completion.native_association(checked) {
    None -> Ok(Nil)
    Some(actual) -> {
      use ref <- result.try(
        command.command_ref(reserved.outbound.key, command.CompileCommand)
        |> invalid,
      )
      use stored <- result.try(
        owner(custodian.command_child(config.owner, ref)),
      )
      use prepared <- result.try(
        wire.decode_prepared(custody.bytes(stored.1)) |> invalid,
      )
      use canonical <- result.try(wire.encode_prepared(prepared) |> invalid)
      use digest <- result.try(wire.prepared_digest(prepared) |> invalid)
      let #(_, operation, _) = command.coordinates(reserved.outbound.key)
      use <- bool.guard(
        canonical != custody.bytes(stored.1)
          || digest != actual.digest
          || identity.key_scope(actual.key) != config.endpoint.scope
          || identity.key_fields(actual.key)
          != #(ids.op_id_to_string(operation), ids.entry_id_to_string(stored.0)),
        Error(Invalid(
          "completion native association differs from actual Prepared",
        )),
      )
      use receipt <- result.try(option.to_result(stored.2, Uncertain))
      use terminal <- result.try(receipt_terminal(custody.bytes(receipt)))
      use <- bool.guard(
        terminal != actual.terminal,
        Error(Invalid("completion native terminal differs from durable receipt")),
      )
      Ok(Nil)
    }
  }
}

fn acknowledge(
  config: Config,
  reserved: Reservation,
  digest: identity.Digest,
  deadline: Option(Int),
) -> Acknowledgement {
  case exchange(config, reserved, protocol.Acknowledge(digest), deadline) {
    Ok(protocol.Observed(
      _,
      protocol.Retained(_, _, retained_digest, journal.ReceiptAcknowledged),
    ))
      if retained_digest == digest
    -> ExecutorAcknowledged
    Ok(protocol.Observed(_, _))
    | Ok(protocol.Challenge(_, _, _))
    | Ok(protocol.Cancelled(_))
    | Error(_) -> OwnerRetained
  }
}

fn exchange(
  config: Config,
  reserved: Reservation,
  command: protocol.Command,
  deadline: Option(Int),
) -> Result(protocol.Reply, Error) {
  let within = case deadline {
    Some(deadline) ->
      int.min(config.endpoint.within_ms, remaining(config, deadline))
    None -> config.endpoint.within_ms
  }
  use <- bool.guard(within <= 0, Error(Uncertain))
  use _header <- result.try(
    protocol.encode_command(command)
    |> result.replace_error(Invalid("invalid closed Compile command")),
  )
  use canonical <- result.try(
    protocol.encode_input(config.enrolled, reserved.outbound)
    |> result.replace_error(Invalid("invalid original Compile input")),
  )
  use #(metadata, content) <- result.try(
    transport.compile_exchange(
      transport.Config(..config.endpoint, within_ms: within),
      command,
      canonical,
    )
    |> result.map_error(fn(error) {
      case error {
        transport.InvalidConfiguration | transport.InvalidInvocation ->
          Invalid("invalid closed Compile exchange")
        transport.ConflictingRegistration
        | transport.Uncertain
        | transport.UnsupportedCommand -> Uncertain
      }
    }),
  )
  protocol.decode_reply(
    config.enrolled,
    reserved.outbound.key,
    metadata,
    content,
  )
  |> result.replace_error(Uncertain)
}

fn remaining(config: Config, deadline: Int) -> Int {
  int.max(0, deadline - config.now())
}

fn owner(value: Result(a, custody.Error)) -> Result(a, Error) {
  case value {
    Ok(value) -> Ok(value)
    Error(error) -> Error(OwnerUnavailable(error))
  }
}

fn invalid(value: Result(a, e)) -> Result(a, Error) {
  result.replace_error(value, Invalid("invalid bounded compiler evidence"))
}

fn hash(bytes: BitArray) -> String {
  // SHA-256 has a fixed-size result; refusal is represented at callers' bounded
  // codec constructors instead of introducing an independent digest encoding.
  case wire.digest(bytes) {
    Ok(digest) ->
      string.lowercase(bit_array.base16_encode(identity.digest_bytes(digest)))
    Error(_) -> ""
  }
}

fn normalized(value: policy.SandboxPolicy) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..value,
    protected: list.sort(value.protected, string.compare),
    env_allow: list.sort(value.env_allow, string.compare),
  )
}

// -- Closed ordered-receipt parser -------------------------------------------
// The generic bounded MessagePack decoder has a fixed 256 KiB wire profile.
// Native custody instead permits 64 output chunks plus a 32 KiB terminal, so
// this private scanner accepts exactly that nonrecursive shape before slicing.

fn receipt_terminal(bytes: BitArray) -> Result(BitArray, Error) {
  use <- bool.guard(
    bit_array.byte_size(bytes) > 2_097_152,
    Error(Invalid("native receipt aggregate exceeds custody bound")),
  )
  use body <- result.try(case bytes {
    <<0x92, rest:bits>> -> Ok(rest)
    _ -> Error(Invalid("native receipt must contain outputs and terminal"))
  })
  use #(count, outputs) <- result.try(receipt_array(body))
  use #(chunks, remaining) <- result.try(receipt_chunks(outputs, count, []))
  use #(terminal, trailing) <- result.try(receipt_binary(remaining, 32_768))
  use <- bool.guard(
    trailing != <<>>,
    Error(Invalid("trailing native receipt bytes")),
  )
  use canonical <- result.try(custodian.receipt(chunks, terminal) |> invalid)
  use <- bool.guard(
    canonical != bytes,
    Error(Invalid("noncanonical native receipt")),
  )
  Ok(terminal)
}

fn receipt_array(bytes: BitArray) -> Result(#(Int, BitArray), Error) {
  case bytes {
    <<tag, rest:bits>> if tag >= 0x90 && tag <= 0x9f -> Ok(#(tag - 0x90, rest))
    <<0xdc, count:16, rest:bits>> if count <= 64 -> Ok(#(count, rest))
    <<0xdd, count:32, rest:bits>> if count <= 64 -> Ok(#(count, rest))
    _ ->
      Error(Invalid("native receipt output count exceeds 64 or is not an array"))
  }
}

fn receipt_chunks(
  bytes: BitArray,
  count: Int,
  reversed: List(BitArray),
) -> Result(#(List(BitArray), BitArray), Error) {
  case count {
    0 -> Ok(#(list.reverse(reversed), bytes))
    _ -> {
      use #(chunk, rest) <- result.try(receipt_binary(bytes, 16_384))
      receipt_chunks(rest, count - 1, [chunk, ..reversed])
    }
  }
}

fn receipt_binary(
  bytes: BitArray,
  limit: Int,
) -> Result(#(BitArray, BitArray), Error) {
  use #(size, body) <- result.try(case bytes {
    <<0xc4, size, rest:bits>> -> Ok(#(size, rest))
    <<0xc5, size:16, rest:bits>> -> Ok(#(size, rest))
    <<0xc6, size:32, rest:bits>> -> Ok(#(size, rest))
    _ -> Error(Invalid("native receipt members must be bounded binary values"))
  })
  use <- bool.guard(
    size > limit || size > bit_array.byte_size(body),
    Error(Invalid("native receipt member exceeds bound or is truncated")),
  )
  case body {
    <<value:size(size)-bytes, rest:bits>> -> Ok(#(value, rest))
    _ -> Error(Invalid("truncated native receipt member"))
  }
}
