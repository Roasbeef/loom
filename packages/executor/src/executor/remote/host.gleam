//// One local lifetime owner for registered remote admission and its listener.
////
//// `configure` freezes administrative scope and verifies both opaque custody
//// bindings before a socket exists. `start` creates the TLS listener inside the
//// host actor, then links admission custody and its bounded acceptor supervisor
//// beneath that owner. A child failure fails the host; no restart recreates a
//// service over the same journal. The caller observes that failed lifetime as
//// `Unavailable`, never as a native-retirement witness.
////
//// `close` first closes listener admission, quiesces the serialized service,
//// stops connection workers, and invokes existing scoped native drain. Journal
//// release follows witnessed epoch closure, native retirement and service exit.
//// An uncertain close retains journal evidence and a fenced owner for explicit
//// inspection; retry cannot reopen admission. Abnormal shutdown closes listener
//// admission and attempts drain, but never releases evidence on that path.
////
//// Native pool and journal construction belong to the trusted caller. Successful
//// startup transfers exclusive use of those handles to this lifetime; a failed
//// startup leaves them caller-owned for drain and reconciliation. Once acceptors
//// exist, even a startup failure can follow admission; no epoch is rolled back.
//// The handles do not encode re-registration,
//// fresh epochs, automatic restart or a second owner budget. Brutal host kill
//// cannot run cleanup; its socket closes with its OTP owner, while the caller
//// must reconcile original native custody and retained journal evidence.

import broker/executor as local
import broker/internal/call
import executor/remote/journal
import executor/remote/listener
import executor/remote/registration
import executor/remote/service
import executor/remote/tls
import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import weft/actor

/// Trusted provisioning facts, supplied together before ownership transfer.
pub type Provisioning {
  Provisioning(
    /// Original scoped custody and native handles; its verifier is replaced
    /// with the fixed registration verifier below.
    service: service.Config,
    /// Immutable canonical paths, policy ceiling and enforcement authority.
    registration: registration.Registration,
    /// Parsed bounded credentials and the exact administratively pinned peer.
    tls: tls.Settings,
    /// Explicit interface exposure; the peer cannot choose it.
    bind: tls.Bind,
    /// Administrative TCP port, or zero for an ephemeral local fixture.
    port: Int,
    /// Fixed connection-worker count, between one and four.
    workers: Int,
    /// Finite complete socket-exchange budget, between 100 and 30000 ms.
    exchange_ms: Int,
  )
}

/// Validated immutable configuration; constructing it starts no process or socket.
pub opaque type Config {
  Config(provisioning: Provisioning)
}

/// A local lifetime address; endpoint identity never carries native authority.
pub opaque type Host {
  Host(pid: process.Pid, subject: process.Subject(Message))
}

/// Fixed local topology for operator observation and parent supervision.
pub type View {
  View(
    /// Actual assigned port, observed only after listener creation succeeds.
    port: Int,
    /// Admission actor owned by this host, not an independent unlinked service.
    service: process.Pid,
    /// Bounded listener worker subtree owned by this host.
    acceptors: process.Pid,
  )
}

/// Refusal and cleanup uncertainty preserve original custody, never reopen it.
pub type Error {
  /// Labels, epochs, custody bindings or capacity/deadlines do not agree.
  InvalidConfiguration

  /// Construction was not published; late failure may follow peer admission,
  /// so the caller retains original handles for drain and reconciliation.
  StartupFailed

  /// The lifetime owner died or did not answer; native retirement is unknown.
  Unavailable

  /// Admission is fenced, but complete durable retirement was not established.
  CleanupUncertain
}

type Resources {
  Resources(
    config: Config,
    listener: tls.Listener,
    service: service.Service,
    acceptors: process.Pid,
    port: Int,
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
  Finish
}

type Shutdown {
  Shutdown
}

/// Checks all immutable bindings and bounds before the host can listen.
/// A supplied arbitrary verifier cannot replace canonical registration checks.
///
/// ## Examples
///
/// ```gleam
/// // host.configure(provisioning) -> Ok(config)
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
    && provisioning.port >= 0
    && provisioning.port <= 65_535
    && provisioning.workers >= 1
    && provisioning.workers <= 4
    && provisioning.exchange_ms >= 100
    && provisioning.exchange_ms <= 30_000
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

/// Starts one linked owner and transfers exclusive custody only on success.
/// Failure closes its listener and linked admission children; the supplied
/// native/journal handles remain with the caller for cleanup or inspection. A
/// late startup timeout can follow admission, so failure never grants replay.
///
/// ## Examples
///
/// ```gleam
/// // host.start(config) -> Ok(host)
/// ```
pub fn start(config: Config) -> Result(Host, Error) {
  builder(config)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.replace_error(StartupFailed)
}

/// Supplies a temporary child; failure never restarts this custody incarnation.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.add(tree, host.supervised(config))
/// ```
pub fn supervised(config: Config) -> supervision.ChildSpecification(Host) {
  builder(config)
  |> actor.supervised
  |> supervision.restart(supervision.Temporary)
  |> supervision.timeout(35_000)
}

/// Returns the local lifetime PID for explicit parent observation.
///
/// ## Examples
///
/// ```gleam
/// // process.monitor(host.pid(running))
/// ```
pub fn pid(host: Host) -> process.Pid {
  host.pid
}

/// Observes a live host or its fenced uncertain-close state.
/// Stored topology is returned only after the actual owner answers.
///
/// ## Examples
///
/// ```gleam
/// // host.observe(running) -> Ok(view), while serving.
/// ```
pub fn observe(host: Host) -> Result(View, Error) {
  call.try_call(host.subject, waiting: 1000, sending: Observe)
  |> result.unwrap(Error(Unavailable))
}

/// Closes new admissions and waits for complete witnessed lifetime cleanup.
/// `Ok` includes epoch closure, native retirement, owned actor exit and journal
/// release. Any uncertainty retains the original journal; actor/socket death
/// alone is never reported as success.
///
/// ## Examples
///
/// ```gleam
/// // host.close(running) -> Ok(Nil), after actual scoped native retirement.
/// ```
pub fn close(host: Host) -> Result(Nil, Error) {
  let monitor = process.monitor(host.pid)
  let answer =
    call.try_call(host.subject, waiting: 35_000, sending: Close)
    |> result.unwrap(Error(Unavailable))
  let outcome = case answer {
    Ok(Nil) -> wait_down(monitor, 2000)
    Error(error) -> Error(error)
  }
  process.demonitor_process(monitor)
  outcome
}

fn builder(config: Config) -> actor.Builder(State, Message, Host) {
  actor.new_with_initialiser(6000, fn(subject) {
    use resources <- result.try(
      initialise(config)
      |> result.replace_error(
        "remote host construction failed before ownership transfer",
      ),
    )
    Ok(
      actor.initialised(Serving(resources))
      |> actor.returning(Host(process.self(), subject)),
    )
  })
  |> actor.on_message(handle)
  |> actor.trapping_exits(True)
  |> actor.on_shutdown(shutdown)
}

fn initialise(config: Config) -> Result(Resources, Error) {
  let provisioning = config.provisioning
  use Nil <- result.try(tls.start() |> result.replace_error(StartupFailed))
  use socket <- result.try(
    tls.listen(provisioning.tls, provisioning.bind, provisioning.port)
    |> result.replace_error(StartupFailed),
  )
  let observed_port = tls.port(socket)
  let started = service.supervised(provisioning.service).start()
  case started {
    Error(_) -> {
      tls.close_listener(socket)
      Error(StartupFailed)
    }
    Ok(started) -> {
      case observed_port {
        Ok(port) -> initialise_listener(config, socket, started.data, port)
        Error(_) -> {
          tls.close_listener(socket)
          process.send_exit(started.pid)
          Error(StartupFailed)
        }
      }
    }
  }
}

fn initialise_listener(
  config: Config,
  socket: tls.Listener,
  remote: service.Service,
  port: Int,
) -> Result(Resources, Error) {
  let provisioning = config.provisioning
  let started = {
    use accepting <- result.try(
      listener.configure(
        socket,
        remote,
        provisioning.workers,
        provisioning.exchange_ms,
      )
      |> result.replace_error(StartupFailed),
    )
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(listener.supervised(accepting))
    |> supervisor.start
    |> result.replace_error(StartupFailed)
  }
  case started {
    Ok(started) -> Ok(Resources(config, socket, remote, started.pid, port))
    Error(error) -> {
      // A partial supervisor start may already have accepted a configured peer.
      // Close and drain conservatively; retain the original journal for its
      // caller even if construction never published a host handle.
      tls.close_listener(socket)
      let _ = service.shutdown(remote)
      Error(error)
    }
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case state, message {
    Serving(resources), Observe(reply) -> {
      process.send(
        reply,
        Ok(View(
          resources.port,
          service.pid(resources.service),
          resources.acceptors,
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
  // Listener closure owns the first ordering edge. Existing accepted exchanges
  // cannot grant new native authority after the serialized quiesce replies.
  tls.close_listener(resources.listener)
  let quiesced = service.quiesce(resources.service)
  let workers = stop_acceptors(resources.acceptors)
  let monitor = process.monitor(service.pid(resources.service))
  let drained = service.shutdown(resources.service)
  let ended = case drained {
    Ok(Nil) -> wait_down(monitor, 2000)
    Error(_) -> Error(CleanupUncertain)
  }
  process.demonitor_process(monitor)
  use Nil <- result.try(quiesced |> result.replace_error(CleanupUncertain))
  use Nil <- result.try(workers)
  use Nil <- result.try(drained |> result.replace_error(CleanupUncertain))
  use Nil <- result.try(ended)
  journal.release(resources.config.provisioning.service.journal)
  |> result.replace_error(CleanupUncertain)
}

fn stop_acceptors(pid: process.Pid) -> Result(Nil, Error) {
  let monitor = process.monitor(pid)
  process.unlink(pid)
  process.send_abnormal_exit(pid, Shutdown)
  let ended = wait_down(monitor, 2000)
  process.demonitor_process(monitor)
  ended
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
      // A child failure or parent exit cannot turn best-effort drain into a
      // durable host acknowledgement. Evidence stays caller-recoverable even
      // when these local native cleanup attempts succeed.
      tls.close_listener(resources.listener)
      let _ = stop_acceptors(resources.acceptors)
      let _ = service.quiesce(resources.service)
      let _ = service.shutdown(resources.service)
      let original = resources.config.provisioning.service
      let _ = journal.close_epoch(original.journal)
      let _ = local.close(original.native, draining: 2000, helpers: 5000)
      Nil
    }
  }
}
