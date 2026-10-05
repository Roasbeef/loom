//// One temporary native scope owner borrows the node's shared TLS BEAM endpoint.
////
//// `configure` checks immutable journal and canonical registration bindings.
//// `start` privately creates the linked native service, derives its concrete
//// endpoint row with this owner's PID, then registers last. Register and any
//// cleanup fence are sent by the same owner, so a lost publication reply cannot
//// leave a later registration behind an earlier missing-row fence.
////
//// `close` fences that exact immutable row, quiesces admission and polls its
//// original transport custody while reply producers remain live. Native shutdown
//// consumes the service's retained original close disposition, including a prior
//// wire CloseScope. Service exit and journal release follow successful witnesses.
//// Failure still attempts native cleanup, retains evidence and stays fenced.
//// The borrowed endpoint and every sibling scope remain node-owned.
//// `retire` releases the original journal only after `settle` establishes every
//// required fence, transport, native and service-exit witness.
////
//// Successful startup transfers exclusive use of the original supplied native
//// and journal handles. Startup failure retains their original identity for
//// caller reconciliation; late failure may follow publication and native work.
//// Temporary supervision never recreates a claim. Brutal death cannot run the
//// cleanup hook; the endpoint's owner monitor fences the row, but DOWN proves
//// neither transport drain nor native retirement. This owner assembles native
//// service custody only, without Compile or workspace resource cleanup claims.

import broker/internal/call
import executor/remote/beam_endpoint as endpoint
import executor/remote/distribution
import executor/remote/journal
import executor/remote/registration
import executor/remote/service
import gleam/erlang/process
import gleam/option.{None}
import gleam/otp/supervision
import gleam/result
import weft/actor
import weft/poll

/// Original native custody and borrowed node administration, fixed before start.
pub type Provisioning {
  /// Publication transfers no new authority beyond these original handles.
  Provisioning(
    /// Original scoped journal and native pool; the verifier is replaced below.
    service: service.Config,
    /// Canonical paths, policy ceiling and enforcement fixed by administration.
    registration: registration.Registration,
    /// Node-owned shared endpoint; this scope never stops or replaces it.
    endpoint: endpoint.Server,
    /// Original owner Peer resolved from successful executor-node membership.
    owner: distribution.Peer,
    /// Transport drain budget, between 100 and 30000 ms, before native cleanup.
    drain_ms: Int,
  )
}

/// Validated immutable facts; construction publishes no row and starts no service.
pub opaque type Config {
  Config(provisioning: Provisioning)
}

/// Exact temporary owner address and finite allowance for sequential cleanup.
pub opaque type Host {
  Host(pid: process.Pid, subject: process.Subject(Message), close_ms: Int)
}

/// Actual topology reported only by the original live scope owner.
pub type View {
  /// The native service is owned; the shared endpoint is borrowed.
  View(
    /// Concrete linked native admission service created by this owner.
    service: process.Pid,
    /// Original node-wide endpoint shared with sibling scopes.
    endpoint: process.Pid,
  )
}

/// Refusals and uncertainty never reopen original native authority.
pub type Error {
  /// Immutable scope or finite drain configuration does not agree.
  InvalidConfiguration

  /// No successful ownership transfer; publication may precede a lost reply.
  StartupFailed

  /// The owner died or failed to answer; native retirement remains unknown.
  Unavailable

  /// Required drain, native, durable or journal-release witness is missing.
  CleanupUncertain
}

type Resources {
  Resources(
    config: Config,
    service: service.Service,
    row: endpoint.Registration,
  )
}

type State {
  Serving(resources: Resources)
  Fenced(resources: Resources)
  Retired
}

type Message {
  Close(reply: process.Subject(Result(Nil, Error)))
  Observe(reply: process.Subject(Result(View, Error)))
  EndpointDown
  Finish
}

/// Checks exact immutable custody before creating a linked service or row.
/// Arbitrary supplied callbacks cannot replace canonical registration verification.
///
/// ## Examples
///
/// ```gleam
/// host.configure(provisioning) // -> Ok(config), before publication.
/// ```
pub fn configure(provisioning: Provisioning) -> Result(Config, Error) {
  use Nil <- result.try(
    service.validate(provisioning.service)
    |> result.replace_error(InvalidConfiguration),
  )
  let scope = provisioning.service.scope
  case
    registration.scope(provisioning.registration) == scope
    && journal.scope(provisioning.service.journal) == scope
    && provisioning.drain_ms >= 100
    && provisioning.drain_ms <= 30_000
  {
    True -> {
      let registered = provisioning.registration
      let configured =
        service.Config(..provisioning.service, verify: fn(key, prepared) {
          registration.verify(registered, key, prepared)
        })
      Ok(Config(Provisioning(..provisioning, service: configured)))
    }
    False -> Error(InvalidConfiguration)
  }
}

/// Starts one linked temporary owner and registers its concrete service last.
/// Failed publication attempts exact fencing and native cleanup without releasing
/// the caller's original journal. A timeout grants no replay or absence proof.
///
/// ## Examples
///
/// ```gleam
/// host.start(config) // -> Ok(host), after row publication acknowledgement.
/// ```
pub fn start(config: Config) -> Result(Host, Error) {
  builder(config)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.replace_error(StartupFailed)
}

/// Supplies temporary supervision over the same original custody incarnation.
/// Its shutdown allowance covers transport polling and reserved native cleanup.
///
/// ## Examples
///
/// ```gleam
/// supervisor.add(tree, host.supervised(config)) // -> A temporary child.
/// ```
pub fn supervised(config: Config) -> supervision.ChildSpecification(Host) {
  builder(config)
  |> actor.supervised
  |> supervision.restart(supervision.Temporary)
  |> supervision.timeout(close_budget(config))
}

/// Returns the original scope owner's identity for parent monitoring.
///
/// ## Examples
///
/// ```gleam
/// process.monitor(host.pid(running)) // -> The concrete owner monitor.
/// ```
pub fn pid(host: Host) -> process.Pid {
  host.pid
}

/// Returns actual service/endpoint topology, or the sticky uncertain disposition.
///
/// ## Examples
///
/// ```gleam
/// host.observe(running) // -> Ok(view), while serving.
/// ```
pub fn observe(host: Host) -> Result(View, Error) {
  call.try_call(host.subject, waiting: 1000, sending: Observe)
  |> result.unwrap(Error(Unavailable))
}

/// Fences and drains only this scope, then joins service and releases its journal.
/// Success requires every original witness plus owner exit. A timeout stops this
/// caller's wait; cleanup continues in the original owner and grants no replay.
///
/// ## Examples
///
/// ```gleam
/// host.close(running) // -> Ok(Nil), after actual scoped retirement.
/// ```
pub fn close(host: Host) -> Result(Nil, Error) {
  let monitor = process.monitor(host.pid)
  let answer =
    call.try_call(host.subject, waiting: host.close_ms, sending: Close)
    |> result.unwrap(Error(Unavailable))
  let outcome = case answer {
    Ok(Nil) -> wait_down(monitor, 2000)
    Error(error) -> Error(error)
  }
  process.demonitor_process(monitor)
  outcome
}

fn builder(config: Config) -> actor.Builder(State, Message, Host) {
  // Late startup refusal can spend the transport allowance and native cleanup
  // grace. The initializer must not abandon the original owner before those asks.
  actor.new_with_initialiser(config.provisioning.drain_ms + 40_000, fn(subject) {
    use resources <- result.try(
      initialise(config)
      |> result.replace_error("scoped BEAM host ownership transfer failed"),
    )
    let monitor = process.monitor(endpoint.pid(config.provisioning.endpoint))
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_specific_monitor(monitor, fn(_) { EndpointDown })
    Ok(
      actor.initialised(Serving(resources))
      |> actor.selecting(selector)
      |> actor.returning(Host(process.self(), subject, close_budget(config))),
    )
  })
  |> actor.on_message(handle)
  |> actor.trapping_exits(True)
  |> actor.on_shutdown(shutdown)
}

fn close_budget(config: Config) -> Int {
  // Sequential maxima are fence 1s, quiesce 2s, poll plus its final 1s ask,
  // native shutdown 30s, service join 2s and journal release 30s. A 4s margin
  // preserves cleanup time without extending any original command authority.
  config.provisioning.drain_ms + 70_000
}

fn initialise(config: Config) -> Result(Resources, Error) {
  let provisioning = config.provisioning
  case process.is_alive(endpoint.pid(provisioning.endpoint)) {
    False -> Error(StartupFailed)
    True -> {
      use started <- result.try(
        service.supervised(provisioning.service).start()
        |> result.replace_error(StartupFailed),
      )
      let formed = form_resources(config, started.data)
      case formed {
        Ok(resources) -> publish(resources)
        Error(error) -> {
          let _ = service.shutdown(started.data)
          Error(error)
        }
      }
    }
  }
}

fn form_resources(
  config: Config,
  native: service.Service,
) -> Result(Resources, Error) {
  use row <- result.try(
    endpoint.registration(
      config.provisioning.owner,
      native,
      None,
      process.self(),
    )
    |> result.replace_error(StartupFailed),
  )
  Ok(Resources(config, native, row))
}

fn publish(resources: Resources) -> Result(Resources, Error) {
  // Register and cleanup Fence originate in this same process. Lost ACK cannot
  // reorder the fence before a delayed publication sent by another producer.
  case
    endpoint.register(resources.config.provisioning.endpoint, resources.row)
  {
    Ok(Nil) -> Ok(resources)
    Error(_) -> {
      let _ = settle(resources)
      Error(StartupFailed)
    }
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case state, message {
    Serving(resources), Observe(reply) -> {
      process.send(
        reply,
        Ok(View(
          service.pid(resources.service),
          endpoint.pid(resources.config.provisioning.endpoint),
        )),
      )
      actor.continue(state)
    }
    Fenced(_), Observe(reply) -> {
      process.send(reply, Error(CleanupUncertain))
      actor.continue(state)
    }
    Serving(resources), Close(reply) -> {
      let outcome = retire(resources)
      process.send(reply, outcome)
      case outcome {
        Ok(Nil) -> actor.continue(Retired) |> actor.then_handle(Finish)
        Error(_) -> actor.continue(Fenced(resources))
      }
    }
    Fenced(_), Close(reply) -> {
      process.send(reply, Error(CleanupUncertain))
      actor.continue(state)
    }
    Serving(_), EndpointDown | Fenced(_), EndpointDown ->
      actor.stop_abnormal("shared BEAM endpoint lifetime ended")
    Retired, EndpointDown -> actor.continue(state)
    Retired, Finish -> actor.stop()
    Serving(_), Finish | Fenced(_), Finish -> actor.continue(state)
    Retired, Close(reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(state)
    }
    Retired, Observe(reply) -> {
      process.send(reply, Error(Unavailable))
      actor.continue(state)
    }
  }
}

fn retire(resources: Resources) -> Result(Nil, Error) {
  use Nil <- result.try(settle(resources))
  journal.release(resources.config.provisioning.service.journal)
  |> result.replace_error(CleanupUncertain)
}

fn settle(resources: Resources) -> Result(Nil, Error) {
  // Attempt every cleanup phase before combining results. Failed fencing or
  // transport expiry must not consume the separately reserved native allowance.
  let fenced =
    endpoint.fence(resources.config.provisioning.endpoint, resources.row)
  let quiesced = service.quiesce(resources.service)
  let transport = drain_transport(resources)
  let monitor = process.monitor(service.pid(resources.service))
  let native = service.shutdown(resources.service)
  let ended = case native {
    Ok(Nil) -> wait_down(monitor, 2000)
    Error(_) -> Error(CleanupUncertain)
  }
  process.demonitor_process(monitor)

  // DOWN is required only after service-owned original retirement success.
  // Neither a successful native result nor actor exit replaces a missing fence
  // or actual-answer/join witness for the shared transport row.
  use Nil <- result.try(fenced |> result.replace_error(CleanupUncertain))
  use Nil <- result.try(quiesced |> result.replace_error(CleanupUncertain))
  use Nil <- result.try(transport)
  use Nil <- result.try(native |> result.replace_error(CleanupUncertain))
  ended
}

fn drain_transport(resources: Resources) -> Result(Nil, Error) {
  let server = resources.config.provisioning.endpoint
  let row = resources.row
  case
    poll.until(resources.config.provisioning.drain_ms, 10, fn() {
      case endpoint.inspect_drain(server, row) {
        Ok(endpoint.Drained) -> poll.Done(Nil)
        Ok(endpoint.Busy) -> poll.Retry
        Ok(endpoint.DrainUncertain) | Error(_) -> poll.Fail(CleanupUncertain)
      }
    })
  {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Expired | poll.Failed(_) -> Error(CleanupUncertain)
  }
}

fn wait_down(monitor: process.Monitor, within: Int) -> Result(Nil, Error) {
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive(within)
  |> result.replace_error(CleanupUncertain)
}

fn shutdown(state: State, _reason: process.ExitReason) -> Nil {
  case state {
    Retired -> Nil
    Serving(resources) | Fenced(resources) -> {
      // Abnormal shutdown still uses the original service's close disposition.
      // A dead service has lost that witness; no second native close can recreate
      // it. Best-effort cleanup never releases the retained journal on this path.
      let _ = settle(resources)
      Nil
    }
  }
}
