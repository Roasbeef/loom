//// Whole remote Launch consumer inside the original Fresh managed owner body.
////
//// The original custodian retains canonical service input and one immutable
//// SatelliteCommand offer before the existing Broker clears it. History grants
//// no new Claim, token placement, bridge nonce or Connection. Executor paths
//// remain opaque data. The owner converts its original Unix budget once; the
//// executor's installed deadline stays on the executor's independent clock.
////
//// Finite metadata admission ends before awaiting the original paused socket
//// handoff. Native observation remains owned by `launch_execution` after that
//// handoff, independently of program frames and transport/resource release.
////
//// ## Flow
////
//// `new` pins trusted capabilities, while `launcher` projects `invoke` under
//// original Fresh admission. `reserve` binds the full successful Compile
//// producer before `launch` spends Challenge/PlaceToken, `await_ready`,
//// `expected` and `retain_offer`. The original bridge binds before `clear`;
//// The native companion keeps native custody after the paused Connection escapes.
//// `recover` reads history only. `await_completion`, `observe_completion` and
//// `checked_completion` uses `collect_missing_native` before `native_evidence`
//// compares the independently retained bytes before owner
//// COMMIT and `acknowledge`. `exchange_original` retains the complete original
//// input; `fenced` quarantines uncertainty without issuing another attempt.

import broker/broker
import broker/command as offer
import broker/enrollment
import broker/policy
import client/remote/command_binding
import client/remote/custodian
import client/remote/launch_execution
import client/remote/launch_receipt
import codemode/compile
import codemode/identity as phase
import codemode/run_channel as channel
import codemode/service_command
import codemode/service_input as input
import codemode/service_resources as resources
import core/clock
import core/command
import core/ids
import core/remote_tool
import core/workspace
import executor/remote/beam_endpoint as transport
import executor/remote/compile_completion
import executor/remote/compile_wire
import executor/remote/identity
import executor/remote/internal/beam_protocol
import executor/remote/launch_beam as bridge
import executor/remote/launch_completion as completion
import executor/remote/launch_wire as protocol
import executor/remote/resource_journal as journal
import executor/remote/wire
import gleam/bit_array
import gleam/bool
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import storage/owner_custody as custody
import weft
import weft/poll

/// Original owner quotas and the separately bounded Broker clearance ask.
@internal
pub type Facts {
  /// These facts introduce neither a new authority nor a per-call deadline.
  Facts(
    /// Actual configured custodian quotas, rechecked by that original actor.
    owner_limits: custody.Limits,
    /// Maximum original Broker ask in milliseconds.
    clearance_wait_ms: Int,
  )
}

/// Trusted local wiring retained by the original managed Fresh body.
@internal
pub opaque type Config {
  Config(
    /// The original incarnation-pinned Fresh owner Handle.
    owner: custodian.Handle,
    /// The exact administrative enrollment retained by that owner.
    enrolled: enrollment.SessionEnrollment,
    /// The original session Broker shared with command dispatch.
    original_broker: broker.Broker,
    /// The administratively resolved peer and original complete binding.
    endpoint: transport.Config,
    /// The existing candidate allocator, never used by recovery.
    mint: fn() -> ids.EntryId,
    /// The original Unix budget clock supplied to the Broker.
    original_clock: clock.Clock,
    /// The original owner monotonic clock, never an executor clock.
    now: fn() -> Int,
    /// Fixed trusted bounds without per-call authority.
    facts: Facts,
  )
}

/// Invalid configuration refuses before custody or transport effects.
@internal
pub type ConfigurationError {
  /// Original full scope or finite trusted facts do not agree.
  InvalidConfiguration
}

/// Observation failures retain original service authority without replacement.
@internal
pub type Error {
  /// Pure original input or canonical retained evidence disagrees.
  Invalid

  /// Original custody or observation was not confirmed.
  Uncertain

  /// Actual original Broker refused before native dispatch.
  Refused(
    /// Physical preparation release remains independently observed.
    resources: channel.ResourceDrain,
  )
}

/// Historical evidence never reconstructs a live Connection.
@internal
pub type Observation {
  /// The original service has no retained closed result yet.
  Pending(
    /// Full original identity, never a replacement request.
    key: command.ServiceKey,
    /// Existing preparation history, never a usable Claim.
    preparation: journal.Status,
  )

  /// The exact outer completion is committed in original owner custody.
  Completed(
    /// Full unchanged service identity.
    key: command.ServiceKey,
    /// Node settlement/refusal is independent of cap outcome and cleanup.
    completion: completion.LaunchCompletion,
    /// Collection state cannot erase that already durable result.
    acknowledgement: Acknowledgement,
  )
}

/// Outer executor collection follows the exact owner completion COMMIT.
@internal
pub type Acknowledgement {
  /// Local committed result remains usable after a lost finite ACK reply.
  OwnerRetained

  /// The original executor acknowledged the same exact digest.
  ExecutorAcknowledged
}

type Reservation {
  Reservation(
    original: custody.ServiceRequest,
    outbound: journal.Input,
    admitted: input.AdmittedLaunch,
    identity: phase.PhaseIdentity,
  )
}

/// Pins the existing owner, Broker, administrative peer and clock capabilities.
/// Only the original incarnation-pinned Fresh callback may expose the launcher.
///
/// ## Examples
/// `new(owner, enrolled, broker, endpoint, mint, clock, now, facts)`.
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
  use Nil <- result.try(
    transport.validate(endpoint)
    |> result.replace_error(InvalidConfiguration),
  )
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
  use <- bool.guard(
    semantic != enrollment.native_facts(enrolled).scope
      || endpoint.executor != fields.2
      || endpoint.generation <= 0
      || facts.clearance_wait_ms <= 0
      || facts.clearance_wait_ms > 30_000,
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

/// Projects one production whole-Launch callback under existing admission.
/// A repeated or historical invocation never recreates its live connection.
///
/// ## Examples
/// `launcher(config)(original_request)` returns one paused original connection.
@internal
pub fn launcher(config: Config) -> channel.Launcher {
  invoke(config, _)
}

fn invoke(
  config: Config,
  request: channel.LaunchRequest,
) -> Result(channel.Connection, channel.LaunchFailure) {
  let #(artifact, original, seed, demand, env, cwd) = channel.execution(request)
  let attempted = {
    use <- bool.guard(
      phase.phase(original) != phase.Run
        || demand != enrollment.native_facts(config.enrolled).demand
        || bit_array.byte_size(channel.token(request)) != 32,
      Error(Invalid),
    )
    use native_origin <- result.try(
      phase.command_origin(original)
      |> result.replace_error(Invalid)
      |> result.try(option_required),
    )
    use parent <- result.try(
      remote_tool.child_tool(native_origin)
      |> result.replace_error(Invalid),
    )
    use origin <- result.try(
      remote_tool.tool_child(parent, remote_tool.Launch)
      |> result.replace_error(Invalid),
    )
    use relative <- result.try(
      workspace.relative_path(cwd)
      |> result.replace_error(Invalid),
    )
    use Nil <- result.try(
      policy.validate(seed) |> result.replace_error(Invalid),
    )
    let #(wall, _) = clock.read(config.original_clock)
    let within = phase.pooled_budget(original).deadline_ms - wall
    use <- bool.guard(within <= 0 || within > 86_400_000, Error(Invalid))
    let deadline = config.now() + within

    // Exact successful owner-retained Compile evidence precedes reservation.
    // This lookup never invokes the compiler or treats an artifact as a path.
    use producer_origin <- result.try(
      remote_tool.tool_child(parent, remote_tool.Compile)
      |> result.replace_error(Invalid),
    )
    use row <- result.try(
      custodian.child(config.owner, producer_origin)
      |> result.replace_error(Uncertain),
    )
    use producer <- result.try(
      compile_wire.decode_input(config.enrolled, row.1)
      |> result.replace_error(Invalid),
    )
    use <- bool.guard(
      command.service_origin(producer.key) != producer_origin
        || command.request_id(producer.key) != row.0,
      Error(Invalid),
    )
    use retained <- result.try(
      custodian.service_child(config.owner, producer.key)
      |> result.replace_error(Uncertain),
    )
    use <- bool.guard(
      custody.service_content(retained.0) != row.1
        || custody.service_identity(retained.0) != producer.key,
      Error(Invalid),
    )
    use completion_bytes <- result.try(retained.1 |> option_required)
    use completed <- result.try(
      compile_completion.decode(
        config.enrolled,
        producer.key,
        custody.bytes(completion_bytes),
      )
      |> result.replace_error(Invalid),
    )
    use canonical <- result.try(
      compile_completion.encode(completed)
      |> result.replace_error(Invalid),
    )
    use <- bool.guard(
      canonical != custody.bytes(completion_bytes),
      Error(Invalid),
    )
    use body <- result.try(
      input.launch_input(
        config.enrolled,
        producer.key,
        artifact,
        env,
        relative,
        seed,
        hash(channel.token(request)),
      )
      |> result.replace_error(Invalid),
    )
    use reserved <- result.try(fenced(
      config,
      parent,
      reserve(
        config,
        origin,
        parent,
        body,
        producer.key,
        compile_completion.compiled(completed),
        original,
      ),
    ))
    let parent_pid = process.self()
    let #(host_pid, _) = channel.endpoint(channel.host(request))
    let live = case
      weft.new([
        fn() { launch(config, reserved, request, deadline, parent_pid) },
      ])
      |> weft.deadline(remaining(config, deadline))
      |> weft.cancel_when_exits(parent_pid)
      |> weft.cancel_when_exits(host_pid)
      |> weft.start
    {
      [weft.Completed(_, connection)] -> Ok(connection)
      [weft.Failed(_, error)] -> Error(error)
      _ -> Error(Uncertain)
    }
    fenced(config, parent, live)
  }
  case attempted {
    Ok(connection) -> Ok(connection)
    Error(Invalid) ->
      Error(channel.LaunchRefused(
        "invalid original remote Launch request",
        channel.ResourcesReleased,
      ))
    Error(Refused(preparation)) ->
      Error(channel.LaunchRefused(
        "original Broker clearance refused",
        preparation,
      ))
    Error(Uncertain) ->
      Error(channel.LaunchOutcomeUnknown(
        "original remote Launch custody or handoff not observed",
      ))
  }
}

fn reserve(
  config: Config,
  origin: remote_tool.ChildOrigin,
  parent: remote_tool.ToolKey,
  body: input.LaunchInput,
  producer: command.ServiceKey,
  completed: compile.Compiled,
  original: phase.PhaseIdentity,
) -> Result(Reservation, Error) {
  case custodian.child(config.owner, origin) {
    Ok(_) -> Error(Uncertain)
    Error(custody.Missing) -> {
      let bytes = input.encode_launch(body)
      use step <- result.try(
        workspace.step(phase.step_id(original))
        |> result.replace_error(Invalid),
      )
      let #(registration, contract) = enrollment.digests(config.enrolled)
      use key <- result.try(
        command.service_key(
          parent,
          command.LaunchService,
          enrollment.native_facts(config.enrolled).scope,
          phase.op_id(original),
          step,
          config.mint(),
          hash(bytes),
          registration,
          contract,
        )
        |> result.replace_error(Invalid),
      )
      use admitted <- result.try(
        input.admit_launch(key, config.enrolled, body, producer, completed)
        |> result.replace_error(Invalid),
      )
      use retained <- result.try(
        custodian.reserve_service_child(config.owner, key, bytes)
        |> result.replace_error(Uncertain),
      )
      Ok(Reservation(retained, journal.Input(key, bytes), admitted, original))
    }
    Error(_) -> Error(Uncertain)
  }
}

fn launch(
  config: Config,
  reserved: Reservation,
  request: channel.LaunchRequest,
  deadline: Int,
  parent_pid: process.Pid,
) -> Result(channel.Connection, Error) {
  use challenge <- result.try(exchange(
    config,
    reserved,
    protocol.ChallengeRequest,
    None,
    deadline,
  ))
  use nonce <- result.try(case challenge {
    protocol.Challenge(key, nonce, 1000) if key == reserved.outbound.key ->
      Ok(nonce)
    _ -> Error(Uncertain)
  })
  let budget = remaining(config, deadline) - 1100
  use <- bool.guard(budget <= 0, Error(Uncertain))
  use placed <- result.try(exchange(
    config,
    reserved,
    protocol.PlaceToken(nonce, budget),
    Some(channel.token(request)),
    deadline,
  ))
  use ready <- result.try(await_ready(config, reserved, placed, deadline))
  use expected <- result.try(expected(config, reserved, ready, deadline))
  use Nil <- result.try(retain_offer(config, reserved, expected))
  let endpoint = config.endpoint
  let pin =
    beam_protocol.Binding(
      endpoint.owner,
      endpoint.executor,
      endpoint.generation,
      endpoint.scope,
    )
  use stream <- result.try(
    bridge.start_owner(
      endpoint.peer,
      pin,
      reserved.outbound.key,
      channel.host(request),
      deadline,
      config.now,
    )
    |> result.replace_error(Uncertain),
  )
  let joined = {
    use answer <- result.try(
      transport.bind_launch(endpoint, bridge.offer(stream))
      |> result.replace_error(Uncertain),
    )
    use Nil <- result.try(
      bridge.install(stream, answer) |> result.replace_error(Uncertain),
    )
    use execution <- result.try(clear(
      config,
      reserved,
      expected,
      stream,
      deadline,
      parent_pid,
    ))
    use connection <- result.try(
      bridge.await_connection(stream, remaining(config, deadline))
      |> result.replace_error(Uncertain),
    )
    Ok(
      channel.Connection(..connection, close: fn() {
        launch_execution.close(execution)
      }),
    )
  }
  case joined {
    Ok(connection) -> Ok(connection)
    Error(error) -> {
      bridge.cancel(stream)
      let closed = bridge.close(stream)
      case error, closed.transport, closed.resources {
        Refused(_), channel.TransportJoined, channel.ResourcesReleased ->
          Error(Refused(channel.ResourcesReleased))
        _, _, _ -> Error(error)
      }
    }
  }
}

fn await_ready(
  config: Config,
  reserved: Reservation,
  first: protocol.Reply,
  deadline: Int,
) -> Result(resources.LaunchResources, Error) {
  let observed = case first {
    protocol.Observed(
      journal.Prepared(resources.LaunchReady(ready)),
      protocol.Pending,
    ) -> Ok(ready)
    protocol.Observed(journal.Reserved, protocol.Pending)
    | protocol.Observed(journal.Unknown(None), protocol.Pending) -> {
      case
        poll.until(
          within: remaining(config, deadline),
          every: 25,
          attempt: fn() {
            case exchange(config, reserved, protocol.Query, None, deadline) {
              Ok(protocol.Observed(
                journal.Prepared(resources.LaunchReady(ready)),
                protocol.Pending,
              )) -> poll.Done(ready)
              Ok(protocol.Observed(journal.Reserved, protocol.Pending))
              | Ok(protocol.Observed(journal.Unknown(None), protocol.Pending)) ->
                poll.Retry
              Ok(_) -> poll.Fail(Uncertain)
              Error(error) -> poll.Fail(error)
            }
          },
        )
      {
        poll.Answered(ready) -> Ok(ready)
        poll.Failed(error) -> Error(error)
        poll.Expired -> Error(Uncertain)
      }
    }
    _ -> Error(Uncertain)
  }
  observed
}

fn expected(
  config: Config,
  reserved: Reservation,
  ready: resources.LaunchResources,
  deadline: Int,
) -> Result(service_command.ExpectedCommand, Error) {
  let #(_, body) = input.admitted_launch(reserved.admitted)
  let facts = input.launch_facts(body)
  let startup =
    44_000 + config.facts.clearance_wait_ms + 2 * config.endpoint.within_ms
  let available = { remaining(config, deadline) - startup - 1100 } / 1000
  let wall =
    list.fold(
      [
        facts.policy_seed.limits.wall_s,
        enrollment.native_facts(config.enrolled).ceiling.limits.wall_s,
      ],
      available,
      fn(cap, bound) {
        case bound > 0 {
          True -> int.min(cap, bound)
          False -> cap
        }
      },
    )
  use <- bool.guard(wall <= 0, Error(Uncertain))
  service_command.launch(config.enrolled, reserved.admitted, ready, wall)
  |> result.replace_error(Uncertain)
}

fn retain_offer(
  config: Config,
  reserved: Reservation,
  expected: service_command.ExpectedCommand,
) -> Result(Nil, Error) {
  let proposed = service_command.offer(expected)
  use bytes <- result.try(
    offer.encode(proposed) |> result.replace_error(Uncertain),
  )
  use payload <- result.try(
    custody.command_offer_payload(
      config.facts.owner_limits,
      offer.reference(proposed),
      hash(bytes),
      bytes,
    )
    |> result.replace_error(Uncertain),
  )
  custodian.admit_offer(config.owner, reserved.original, payload)
  |> result.replace(Nil)
  |> result.replace_error(Uncertain)
}

fn clear(
  config: Config,
  reserved: Reservation,
  expected: service_command.ExpectedCommand,
  stream: bridge.Owner,
  deadline: Int,
  parent_pid: process.Pid,
) -> Result(launch_execution.Execution, Error) {
  let proposed = service_command.offer(expected)
  let data = offer.data(proposed)
  let native = enrollment.native_facts(config.enrolled)
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
  use Nil <- result.try(
    policy.validate(projected) |> result.replace_error(Uncertain),
  )

  // Required environment and confinement must survive the original ceiling.
  // A narrower cleared command cannot be mistaken for the immutable offer.
  use <- bool.guard(
    list.sort(projected.env_allow, string.compare)
      != list.sort(data.requirements.env_allow, string.compare),
    Error(Uncertain),
  )
  let #(bounded, _) =
    policy.compose(native.ceiling, projected, phase.grants(reserved.identity))
  use <- bool.guard(
    normalized(bounded) != normalized(projected),
    Error(Uncertain),
  )

  use native_origin <- result.try(
    phase.command_origin(reserved.identity)
    |> result.replace_error(Uncertain)
    |> result.try(option_required),
  )
  use <- bool.guard(
    native_origin != command.native_origin(offer.reference(proposed))
      || remaining(config, deadline) <= 0,
    Error(Uncertain),
  )
  let spec =
    broker.CallSpec(
      op_id: phase.op_id(reserved.identity),
      step_id: phase.step_id(reserved.identity),
      base_policy: projected,
      requirements: projected,
      grants: phase.grants(reserved.identity),
      response: broker.RefuseNarrowed,
      demand: native.demand,
      argv: data.argv,
      env: data.env,
      cwd: data.cwd,
      budget: phase.pooled_budget(reserved.identity),
    )
  let owner = config.owner
  let key = reserved.outbound.key
  let cancellation = fn() {
    let _ = custodian.cancel_service(owner, key)
    Nil
  }
  let finish_outer = fn() {
    await_completion(config, reserved.outbound, deadline + 6000)
    |> result.replace(Nil)
    |> result.replace_error(Nil)
  }
  case
    launch_execution.start(
      config.original_broker,
      native_origin,
      spec,
      stream,
      parent_pid,
      deadline,
      config.now,
      config.facts.clearance_wait_ms,
      cancellation,
      finish_outer,
    )
  {
    Ok(execution) -> Ok(execution)
    Error(broker.BrokerUnavailable) -> {
      let _ = custodian.cancel_service(config.owner, key)
      let _ = exchange(config, reserved, protocol.Cancel, None, deadline)
      Error(Uncertain)
    }
    Error(_) -> {
      use reply <- result.try(exchange(
        config,
        reserved,
        protocol.RefuseBeforeNative,
        None,
        deadline,
      ))
      use _ <- result.try(observe_completion(
        config,
        reserved.outbound,
        reply,
        Some(deadline + 6000),
      ))
      Error(
        Refused(channel.ResourcesUnresolved(
          "original preparation cleanup not observed",
        )),
      )
    }
  }
}

fn exchange(
  config: Config,
  reserved: Reservation,
  operation: protocol.Command,
  token: option.Option(BitArray),
  deadline: Int,
) -> Result(protocol.Reply, Error) {
  exchange_original(config, reserved.outbound, operation, token, Some(deadline))
}

fn exchange_original(
  config: Config,
  original: journal.Input,
  operation: protocol.Command,
  token: option.Option(BitArray),
  deadline: option.Option(Int),
) -> Result(protocol.Reply, Error) {
  let within = case deadline {
    Some(deadline) ->
      int.min(config.endpoint.within_ms, remaining(config, deadline))
    None -> config.endpoint.within_ms
  }
  use <- bool.guard(within <= 0, Error(Uncertain))
  use bytes <- result.try(
    case token {
      Some(raw) -> protocol.encode_placement(config.enrolled, original, raw)
      None -> protocol.encode_input(config.enrolled, original)
    }
    |> result.replace_error(Uncertain),
  )
  use #(metadata, content) <- result.try(
    transport.launch_exchange(
      transport.Config(..config.endpoint, within_ms: within),
      operation,
      bytes,
    )
    |> result.replace_error(Uncertain),
  )
  protocol.decode_reply(config.enrolled, original, metadata, content)
  |> result.replace_error(Uncertain)
}

fn option_required(value: option.Option(a)) -> Result(a, Error) {
  value |> option.to_result(Uncertain)
}

fn remaining(config: Config, deadline: Int) -> Int {
  int.max(0, deadline - config.now())
}

fn hash(bytes: BitArray) -> String {
  string.lowercase(bit_array.base16_encode(journal.digest(bytes)))
}

fn fenced(
  config: Config,
  parent: remote_tool.ToolKey,
  observed: Result(a, Error),
) -> Result(a, Error) {
  case observed {
    Error(Uncertain) -> {
      let _ = custodian.fatal_fence(config.owner, parent)
      Error(Uncertain)
    }
    Ok(value) -> Ok(value)
    Error(Invalid) -> Error(Invalid)
    Error(Refused(resources)) -> Error(Refused(resources))
  }
}

/// Observes exact retained Launch evidence and retries only its original ACK.
/// This path never mints, places a token, clears, binds or awaits a Connection.
///
/// ## Examples
/// `recover(config, original_launch_origin)` returns historical evidence only.
@internal
pub fn recover(
  config: Config,
  origin: remote_tool.ChildOrigin,
) -> Result(Observation, Error) {
  // This budget bounds read-only observation, never dispatch or live authority.
  let observation_deadline = config.now() + config.endpoint.within_ms
  use <- bool.guard(
    remote_tool.child_role(origin) != Ok(remote_tool.Launch),
    Error(Invalid),
  )
  use row <- result.try(
    custodian.child(config.owner, origin) |> result.replace_error(Uncertain),
  )
  use original <- result.try(
    protocol.decode_input(config.enrolled, row.1)
    |> result.replace_error(Invalid),
  )
  use <- bool.guard(
    command.service_origin(original.key) != origin
      || command.request_id(original.key) != row.0,
    Error(Invalid),
  )
  use stored <- result.try(
    custodian.service_child(config.owner, original.key)
    |> result.replace_error(Uncertain),
  )
  use <- bool.guard(custody.service_content(stored.0) != row.1, Error(Invalid))
  case stored.1 {
    Some(bytes) -> {
      use checked <- result.try(checked_completion(
        config,
        original,
        custody.bytes(bytes),
        Some(observation_deadline),
      ))
      use digest <- result.try(
        wire.digest(custody.bytes(bytes)) |> result.replace_error(Invalid),
      )
      Ok(Completed(
        original.key,
        checked,
        acknowledge(config, original, digest, Some(observation_deadline)),
      ))
    }
    None -> {
      use reply <- result.try(exchange_original(
        config,
        original,
        protocol.Query,
        None,
        Some(observation_deadline),
      ))
      observe_completion(config, original, reply, Some(observation_deadline))
    }
  }
}

fn await_completion(
  config: Config,
  original: journal.Input,
  deadline: Int,
) -> Result(Observation, Error) {
  case
    poll.until(within: remaining(config, deadline), every: 25, attempt: fn() {
      case
        exchange_original(
          config,
          original,
          protocol.Query,
          None,
          Some(deadline),
        )
      {
        Ok(protocol.Observed(_, protocol.Pending)) -> poll.Retry
        Ok(reply) -> poll.Done(reply)
        Error(Uncertain) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
  {
    poll.Answered(reply) ->
      observe_completion(config, original, reply, Some(deadline))
    poll.Failed(error) -> Error(error)
    poll.Expired -> Error(Uncertain)
  }
}

fn observe_completion(
  config: Config,
  original: journal.Input,
  reply: protocol.Reply,
  deadline: option.Option(Int),
) -> Result(Observation, Error) {
  case reply {
    protocol.Observed(preparation, protocol.Pending) ->
      Ok(Pending(original.key, preparation))
    protocol.Observed(_, protocol.Retained(purported, bytes, digest, _)) -> {
      use checked <- result.try(checked_completion(
        config,
        original,
        bytes,
        deadline,
      ))
      use actual <- result.try(
        wire.digest(bytes) |> result.replace_error(Invalid),
      )
      use <- bool.guard(
        checked != purported || actual != digest,
        Error(Invalid),
      )
      use row <- result.try(
        custodian.service_child(config.owner, original.key)
        |> result.replace_error(Uncertain),
      )
      use canonical <- result.try(
        protocol.encode_input(config.enrolled, original)
        |> result.replace_error(Invalid),
      )
      use <- bool.guard(
        custody.service_content(row.0) != canonical,
        Error(Invalid),
      )

      // Only the original custodian's exact-byte COMMIT permits collection.
      // ACK loss cannot grant another Launch or discard a known local result.
      use Nil <- result.try(
        custodian.receive_child(
          config.owner,
          command.service_origin(original.key),
          command.request_id(original.key),
          bytes,
        )
        |> result.replace_error(Uncertain),
      )
      Ok(Completed(
        original.key,
        checked,
        acknowledge(config, original, digest, deadline),
      ))
    }
    protocol.Challenge(_, _, _) | protocol.Cancelled(_) -> Error(Uncertain)
  }
}

fn checked_completion(
  config: Config,
  original: journal.Input,
  bytes: BitArray,
  deadline: option.Option(Int),
) -> Result(completion.LaunchCompletion, Error) {
  use checked <- result.try(
    completion.decode(config.enrolled, original.key, bytes)
    |> result.replace_error(Invalid),
  )
  use canonical <- result.try(
    completion.encode(checked) |> result.replace_error(Invalid),
  )
  use <- bool.guard(
    canonical != bytes || completion.original(checked) != original.key,
    Error(Invalid),
  )
  use Nil <- result.try(collect_missing_native(
    config,
    original,
    checked,
    deadline,
  ))
  use Nil <- result.try(native_evidence(config, original, checked))
  Ok(checked)
}

// Final aborts the original Broker step before close. Its cancelled dispatcher
// may lack a receipt even though the executor has settled the exact native row.
fn collect_missing_native(
  config: Config,
  original: journal.Input,
  checked: completion.LaunchCompletion,
  deadline: option.Option(Int),
) -> Result(Nil, Error) {
  case completion.native_association(checked) {
    None -> Ok(Nil)
    Some(actual) -> {
      use ref <- result.try(
        command.command_ref(original.key, command.SatelliteCommand)
        |> result.replace_error(Invalid),
      )
      use stored <- result.try(
        custodian.command_child(config.owner, ref)
        |> result.replace_error(Uncertain),
      )
      case stored.2 {
        Some(_) -> Ok(Nil)
        None -> {
          use deadline <- result.try(deadline |> option_required)
          use binding <- result.try(
            command_binding.new(
              config.owner,
              config.enrolled,
              config.endpoint.scope,
              fn(_) { Error(Nil) },
              config.mint,
            )
            |> result.replace_error(Invalid),
          )
          launch_receipt.collect(
            binding,
            config.endpoint,
            ref,
            actual.key,
            actual.digest,
            actual.terminal,
            deadline,
            config.now,
          )
          |> result.replace_error(Uncertain)
        }
      }
    }
  }
}

fn native_evidence(
  config: Config,
  original: journal.Input,
  checked: completion.LaunchCompletion,
) -> Result(Nil, Error) {
  case completion.native_association(checked) {
    None -> Ok(Nil)
    Some(actual) -> {
      use ref <- result.try(
        command.command_ref(original.key, command.SatelliteCommand)
        |> result.replace_error(Invalid),
      )
      use stored <- result.try(
        custodian.command_child(config.owner, ref)
        |> result.replace_error(Uncertain),
      )
      use prepared <- result.try(
        wire.decode_prepared(custody.bytes(stored.1))
        |> result.replace_error(Invalid),
      )
      use canonical <- result.try(
        wire.encode_prepared(prepared) |> result.replace_error(Invalid),
      )
      use digest <- result.try(
        wire.prepared_digest(prepared) |> result.replace_error(Invalid),
      )
      let #(_, operation, _) = command.coordinates(original.key)
      use <- bool.guard(
        canonical != custody.bytes(stored.1)
          || digest != actual.digest
          || identity.key_scope(actual.key) != config.endpoint.scope
          || identity.key_fields(actual.key)
          != #(ids.op_id_to_string(operation), ids.entry_id_to_string(stored.0)),
        Error(Invalid),
      )
      use receipt <- result.try(stored.2 |> option_required)
      use terminal <- result.try(
        launch_receipt.terminal(custody.bytes(receipt))
        |> result.replace_error(Invalid),
      )
      use <- bool.guard(terminal != actual.terminal, Error(Invalid))
      Ok(Nil)
    }
  }
}

fn acknowledge(
  config: Config,
  original: journal.Input,
  digest: identity.Digest,
  deadline: option.Option(Int),
) -> Acknowledgement {
  case
    exchange_original(
      config,
      original,
      protocol.Acknowledge(digest),
      None,
      deadline,
    )
  {
    Ok(protocol.Observed(
      _,
      protocol.Retained(_, _, actual, journal.ReceiptAcknowledged),
    ))
      if actual == digest
    -> ExecutorAcknowledged
    _ -> OwnerRetained
  }
}

fn normalized(value: policy.SandboxPolicy) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..value,
    protected: list.sort(list.unique(value.protected), string.compare),
    env_allow: list.sort(list.unique(value.env_allow), string.compare),
  )
}
