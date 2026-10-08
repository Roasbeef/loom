//// The binary's single-daemon entrypoint, independent of any conversation.
////
//// Startup acquires one private catalogue and credential, restores metadata,
//// and binds one v2 listener. Provider configuration and session resources are
//// resolved only inside an explicitly admitted session builder. The root handle
//// survives readiness failures so bounded shutdown can report uncertainty.
////
//// ## Flow
////
//// `main` → `claim_endpoint` → `prepare_startup` → `run` → `start_executor` →
//// `start_orchestrator_port` → `start_movers` → `listen_moving` →
//// `publish_endpoint` → `wait`
////
//// 1. `main` parses the flags, `claim_endpoint` reserves this VM, and
////    `prepare_startup` reads the configuration once and prepares the root.
//// 2. `run` starts the daemon's services in order. `start_executor` comes
////    first, so a machine that serves workspaces answers peers before any
////    client can connect, and `start_orchestrator_port` follows it, so a
////    daemon with distribution answers a peer's question about which sessions
////    it holds and takes the sessions a peer moves to it. `start_movers`
////    follows that and resumes every move this daemon had in flight.
//// 3. `listen_moving` binds the listener, and `publish_endpoint` records the
////    bound port for the reservation this VM holds.
//// 4. `wait` blocks on the signal relay, the root and the executor host, and a
////    loss of either of the last two ends the daemon.

import argv
import client/catalog
import client/daemon/limits
import client/daemon/listener
import client/daemon/manager
import client/daemon/root
import client/daemon/server
import client/daemon/session_socket
import client/daemon/ui_assets
import client/daemon/ui_login
import client/daemon/ui_sessions
import client/daemon/ui_socket
import client/distribution
import client/executor_plane
import client/executors
import client/host
import client/internal/ffi_os
import client/orchestrators
import client/peer_defaults
import client/peer_mail
import client/peers
import client/pools
import client/remote/address
import client/remote/host as executor_host
import client/remote/orchestrator_port
import client/remote/remote_peer
import client/remote/workspace
import client/serve
import client/session_directory
import client/session_importer
import client/session_move
import client/session_mover
import client/session_movers
import client/workspaces
import core/clock
import core/glance
import core/ids
import core/json.{type JsonValue}
import gleam/dict
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import host/build_identity
import host/endpoint
import mist
import simplifile
import storage/catalogue
import telemetry/field
import telemetry/handler
import telemetry/log.{type Logger}
import tom
import weft/poll

/// Daemon-wide choices; session defaults are resolved only on explicit open.
pub type Config {
  Config(
    /// Private root, defaulting to the operator's ~/.loom directory.
    state_root: String,
    /// A literal loopback address; remote cleartext serving is refused.
    bind_host: String,
    /// Zero requests an ephemeral port.
    bind_port: Int,
    /// Maximum occupied session reservations, including unconfirmed cleanup.
    capacity: Int,
    /// Display name used only when creating the first stable owner identity.
    owner_display_name: String,
    /// Helper/configuration/enforcement flags understood by serve's resolver.
    session_defaults: List(String),
    /// Whether the listener serves the web view (`--ui` or daemon.ui).
    view: WebView,
    /// Whether sessions are linked to each other without a grant, read from
    /// `[peers]` at startup and never reread (protocol-change/077).
    peer_policy: peer_mail.Policy,
    /// The executors sessions may be placed on, read from `[executors.<name>]`
    /// at startup and never reread (protocol-change/078).
    executors: List(executors.Executor),
    /// The groups of those executors a session may be created in, read from
    /// `[pools.<name>]` at startup and never reread (protocol-change/078).
    pools: List(pools.Pool),
    /// The checkouts this machine serves to orchestrators, read from
    /// `[workspaces.<name>]` at startup and never reread (protocol-change/078).
    /// A daemon with none starts no executor host.
    workspaces: List(workspaces.Workspace),
    /// The other orchestrators this daemon asks which of them owns a session
    /// its own catalogue lacks, read from `[orchestrators.<name>]` at startup
    /// and never reread (protocol-change/078, phase 3).
    orchestrators: List(orchestrators.Orchestrator),
    /// The distribution membership `prepare_startup` started, or `None` when
    /// the configuration has no `[distribution]` table. It is how the daemon
    /// reaches the peers it asks, and a daemon without it asks nobody and
    /// answers nobody.
    membership: Option(distribution.Membership),
  )
}

/// Whether the daemon serves the web view under `/ui` (protocol-change/051).
pub type WebView {
  /// No `/ui` route, no `hello` field and no `ui.link`: the default.
  ViewOff

  /// `loomd --ui` or `[daemon] ui = true`: the listener serves the view.
  ViewOn
}

/// A ready root and its original public listener, with no per-session token.
pub type Serving(instance) {
  Serving(
    /// Existing daemon authority and transitive shutdown witness owner.
    daemon: root.Root(instance),
    /// Restored metadata and current daemon epoch.
    ready: root.Ready(instance),
    /// Original Mist supervisor and actual bound port.
    listener: listener.Bound,
  )
}

type Event {
  Signal(host.Stop)
  RootGone(process.ExitReason)
  ExecutorGone(process.ExitReason)
}

/// Which half of session startup produced a failure.
///
/// These stages bound the diagnostic vocabulary without exposing configuration
/// paths or provider data carried by the original error.
@internal
pub type StartStage {
  /// The resolver refused the daemon's defaults or the session's registration.
  SettingsResolution

  /// The builder reached the session's own resources and one of them refused.
  RuntimeAssembly
}

/// Starts the default daemon and reports startup or shutdown failures nonzero.
///
/// ## Examples
///
/// ```gleam
/// // loomd --state-dir /private/loom --bind 127.0.0.1:0 --capacity 8
/// ```
pub fn main() -> Nil {
  let logger =
    handler.install(
      threshold: handler.threshold_named(bootstrap.getenv(
        handler.level_variable,
      )),
    )
  case
    parse(argv.load().arguments)
    |> result.try(claim_endpoint)
    |> result.try(fn(claimed) {
      let #(config, paths, fence) = claimed
      prepare_startup(config, logger)
      |> result.map(fn(prepared) {
        let #(config, daemon) = prepared
        #(config, paths, fence, daemon)
      })
    })
  {
    Error(reason) -> {
      io.println_error("loomd: " <> reason)
      ffi_os.halt(1)
    }
    Ok(#(config, paths, fence, daemon)) ->
      run(config, paths, fence, daemon, logger)
  }
}

/// Reserves this VM before the production path opens catalogue or effects.
///
/// A launcher releases launch.lock before waiting for the child. The child
/// reacquires it here and adopts only the Starting record with its own birth
/// identity. Direct foreground startup publishes the same reservation itself.
///
/// ## Examples
///
/// ```gleam
/// // main.claim_endpoint(config)
/// ```
@internal
pub fn claim_endpoint(
  config: Config,
) -> Result(#(Config, endpoint.Paths, endpoint.Fence), String) {
  use paths <- result.try(endpoint.paths(config.state_root))
  use own <- result.try(endpoint.observe(bootstrap.current_process_id()))
  use lock <- result.try(acquire_launch_lock(paths))
  let claimed = endpoint.claim(paths, own)
  bootstrap.release_launch_lock(lock)
  claimed
  |> result.map(fn(fence) {
    #(Config(..config, state_root: paths.root), paths, fence)
  })
}

/// Publishes the actual bound control port only for the retained reservation.
///
/// This record is deliberately not removed during shutdown: the original VM,
/// rather than a BEAM root or a socket probe, owns replacement eligibility.
///
/// ## Examples
///
/// ```gleam
/// // main.publish_endpoint(config, serving, paths, fence)
/// ```
@internal
pub fn publish_endpoint(
  config: Config,
  serving: Serving(instance),
  paths: endpoint.Paths,
  fence: endpoint.Fence,
) -> Result(Nil, String) {
  use _still_ready <- result.try(root.ready(serving.daemon, within: 1000))
  use lock <- result.try(acquire_launch_lock(paths))
  let published =
    endpoint.publish_ready(
      paths,
      fence,
      config.bind_host,
      serving.listener.port,
      serving.ready.epoch,
      Some(build_identity.current()),
    )
  bootstrap.release_launch_lock(lock)
  published
}

fn acquire_launch_lock(paths: endpoint.Paths) {
  case
    poll.until(within: 5000, every: 25, attempt: fn() {
      case bootstrap.try_launch_lock(paths.launch_lock) {
        Ok(lock) -> poll.Done(lock)
        Error("busy") -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })
  {
    poll.Answered(lock) -> Ok(lock)
    poll.Failed(reason) -> Error("daemon launch lock: " <> reason)
    poll.Expired -> Error("timed out acquiring daemon launch lock")
  }
}

/// Parses daemon flags without loading a session configuration or opening files.
///
/// ## Examples
///
/// ```gleam
/// // main.parse(["--state-dir", "/private/loom", "--capacity", "8"])
/// ```
@internal
pub fn parse(arguments: List(String)) -> Result(Config, String) {
  let initial =
    Config(
      "",
      "127.0.0.1",
      0,
      8,
      "Owner",
      [],
      ViewOff,
      peer_defaults.off,
      [],
      [],
      [],
      [],
      None,
    )
  use config <- result.try(parse_loop(arguments, initial))
  use state_root <- result.try(case config.state_root {
    "" ->
      bootstrap.getenv("HOME")
      |> result.replace_error("HOME is unset; pass --state-dir")
      |> result.map(fn(home) { home <> "/.loom" })
    path -> Ok(path)
  })
  use state_root <- result.try(bootstrap.absolute_path(state_root))
  Ok(Config(..config, state_root:))
}

fn parse_loop(
  arguments: List(String),
  config: Config,
) -> Result(Config, String) {
  case arguments {
    [] -> Ok(config)
    ["--state-dir", value, ..rest] ->
      parse_loop(rest, Config(..config, state_root: value))
    ["--ui", ..rest] -> parse_loop(rest, Config(..config, view: ViewOn))
    ["--owner-name", value, ..rest] if value != "" ->
      parse_loop(rest, Config(..config, owner_display_name: value))
    ["--capacity", value, ..rest] -> {
      use capacity <- result.try(
        int.parse(value) |> result.replace_error("invalid --capacity"),
      )
      case capacity > 0 && capacity <= 1024 {
        True -> parse_loop(rest, Config(..config, capacity:))
        False -> Error("--capacity must be between 1 and 1024")
      }
    }
    ["--bind", value, ..rest] -> {
      use #(bind_host, bind_port) <- result.try(bind_address(value))
      parse_loop(rest, Config(..config, bind_host:, bind_port:))
    }
    ["--read-scope", value, ..rest] -> {
      use _scope <- result.try(catalog.parse_read_scope(value))
      parse_loop(
        rest,
        Config(
          ..config,
          session_defaults: list.append(config.session_defaults, [
            "--read-scope",
            value,
          ]),
        ),
      )
    }
    ["--network", value, ..rest] -> {
      use _network <- result.try(catalog.parse_tool_network(value))
      parse_loop(
        rest,
        Config(
          ..config,
          session_defaults: list.append(config.session_defaults, [
            "--network",
            value,
          ]),
        ),
      )
    }
    [flag, value, ..rest]
      if flag == "--helper"
      || flag == "--config"
      || flag == "--codemode-seed"
      || flag == "--codemode-seams"
    ->
      parse_loop(
        rest,
        Config(
          ..config,
          session_defaults: list.append(config.session_defaults, [flag, value]),
        ),
      )
    [flag, ..rest] if flag == "--best-effort" || flag == "--full-enforcement" ->
      case
        list.any(config.session_defaults, fn(value) {
          value == "--best-effort" || value == "--full-enforcement"
        })
      {
        True -> Error("enforcement flags cannot be combined")
        False ->
          parse_loop(
            rest,
            Config(
              ..config,
              session_defaults: list.append(config.session_defaults, [flag]),
            ),
          )
      }
    [unknown, ..] -> Error("unknown or incomplete daemon argument: " <> unknown)
  }
}

fn bind_address(value: String) -> Result(#(String, Int), String) {
  use #(host, port) <- result.try(case string.split(value, ":") {
    ["127.0.0.1", port] -> Ok(#("127.0.0.1", port))
    ["[", "", "1]", port] -> Ok(#("::1", port))
    _ -> Error("--bind requires loopback 127.0.0.1:port or [::1]:port")
  })
  use port <- result.try(
    int.parse(port) |> result.replace_error("invalid --bind port"),
  )
  case port >= 0 && port <= 65_535 {
    True -> Ok(#(host, port))
    False -> Error("--bind port is outside 0..65535")
  }
}

// Trusted distribution is started first, before the catalogue or any session
// resource is opened, so a VM booted wrongly is refused with nothing to undo.
// Without a `[distribution]` table nothing happens and the VM stays
// non-distributed. The membership is kept for the sessions registered on an
// executor, which resolve their peer through it when they open.
fn start_distribution(
  document: dict.Dict(String, tom.Toml),
  configuration: String,
) -> Result(Option(distribution.Membership), String) {
  use found <- result.try(
    distribution.from_document(document)
    |> result.map_error(fn(reason) { configuration <> ": " <> reason }),
  )
  case found {
    None -> Ok(None)
    Some(settings) ->
      distribution.start(settings, distribution.NotMember)
      |> result.map(Some)
      |> result.map_error(fn(fault) {
        configuration <> ": " <> distribution.describe(fault)
      })
  }
}

// Each served checkout has to be a directory now, so an operator who mistyped
// a root learns it at startup and not from the first session that attaches.
// The plane factory checks again at every attach, because a directory can go
// away in between.
fn existing_roots(served: List(workspaces.Workspace)) -> Result(Nil, String) {
  list.try_each(served, fn(workspace) {
    bootstrap.canonical_directory(workspace.root)
    |> result.map(fn(_resolved) { Nil })
    |> result.map_error(fn(reason) {
      "workspaces."
      <> workspace.name
      <> ".root "
      <> workspace.root
      <> " is not a directory: "
      <> reason
    })
  })
}

/// Starts the executor host when the configuration serves any workspace, and
/// returns the monitor `wait` watches it by. A configuration with none starts
/// nothing and registers no name.
///
/// The host is deliberately not linked and not restarted. The workspace planes
/// it builds are not in its link set, so a host that restarted alone would leave
/// their helper pools and jobs actors running and build a second set beside
/// them on the next attach. Its death therefore ends the daemon, and the
/// ledger's recovery on the next boot turns every call it had in flight into an
/// unknown outcome.
///
/// ## Examples
///
/// ```gleam
/// // assert main.start_executor(Config(..config, workspaces: []), logger) == Ok(None)
/// ```
@internal
pub fn start_executor(
  config: Config,
  logger: Logger,
) -> Result(Option(process.Monitor), String) {
  case config.workspaces {
    [] -> Ok(None)
    configured -> {
      use configuration <- result.try(captured_domain_configuration(
        config.session_defaults,
        "",
      ))
      use machine <- result.try(executor_plane.machine(
        config.session_defaults,
        configuration,
        config.state_root,
        logger,
      ))
      use started <- result.try(
        executor_host.start(executor_host.Config(
          name: address.default(),
          ledger_path: config.state_root <> "/exec-ledger.db",
          limits: executor_plane.scope_limits(),
          max_result_bytes: executor_host.default_max_result_bytes,
          clock: clock.from_function(ffi_os.system_time_ms),
          factory: executor_plane.factory(machine, configured),
        ))
        |> result.map_error(fn(error) {
          "the executor host did not start: " <> string.inspect(error)
        }),
      )
      process.unlink(started.pid)
      log.info(logger, "daemon.executor_serving", [
        field.count("workspaces", list.length(configured)),
      ])
      Ok(Some(process.monitor(started.pid)))
    }
  }
}

/// Starts the orchestrator port when the configuration has a `[distribution]`
/// table, and registers nothing otherwise.
///
/// The port answers a peer orchestrator's question about whether this daemon's
/// catalogue holds a session. It runs whether or not this daemon lists any
/// `[orchestrators.<name>]` of its own, since an orchestrator can be asked by a
/// peer that lists it without listing that peer back. It is linked to the
/// process that starts the daemon's services, so an abnormal exit of the port
/// ends the daemon the way the executor host's does: a daemon that silently
/// stopped answering would make every peer report it unreachable.
///
/// ## Examples
///
/// ```gleam
/// // assert main.start_orchestrator_port(Config(..config, membership: None), daemon, logger, peer) == Ok(Nil)
/// ```
@internal
pub fn start_orchestrator_port(
  config: Config,
  daemon: root.Root(instance),
  logger: Logger,
  peer_endpoint: fn(instance) -> Option(peer_mail.Endpoint),
) -> Result(Nil, String) {
  case config.membership {
    None -> Ok(Nil)
    Some(_) -> {
      use ready <- result.try(root.ready(daemon, within: 20_000))
      use domain_configuration <- result.try(captured_domain_configuration(
        config.session_defaults,
        "",
      ))
      let importer =
        session_importer.new(session_importer.Context(
          registry: ready.registry,
          state_root: ready.state_root,
          sessions_directory: ready.sessions_directory,
          domain_configuration:,
          clock: clock.from_function(ffi_os.system_time_ms),
          orchestrators: config.orchestrators,
          executors: config.executors,
          logger:,
        ))
      use _started <- result.try(
        orchestrator_port.start_with(
          orchestrator_port.default(),
          catalogue_holds(ready.registry),
          peer_command(ready.registry, peer_endpoint),
          importer,
        )
        |> result.map_error(fn(error) {
          "the orchestrator port did not start: " <> string.inspect(error)
        }),
      )
      log.info(logger, "daemon.orchestrator_port", [
        field.count("orchestrators", list.length(config.orchestrators)),
      ])
      Ok(Nil)
    }
  }
}

/// Forwards one peer-mail command from another orchestrator to a session
/// resident here, the way the control commands reach the same session
/// (`server.peer_endpoint`): resolve the identity with the manager and call the
/// session's own endpoint. A session that is not resident answers
/// `peers.not_running`, the refusal a send within one daemon gets, so the
/// sender cannot tell where the recipient was supposed to be.
///
/// ## Examples
///
/// ```gleam
/// // main.peer_command(ready.registry, fn(resident) { Some(resident.peer) })("0198...", command)
/// ```
@internal
pub fn peer_command(
  registry: manager.Manager(instance),
  endpoint: fn(instance) -> Option(peer_mail.Endpoint),
) -> fn(String, peer_mail.Command) -> Result(JsonValue, String) {
  fn(session, command) {
    case manager.resolve(registry, session) {
      Error(_) -> Error(peers.not_running)
      Ok(resident) ->
        case endpoint(resident) {
          None -> Error("peer_service_unavailable")
          Some(found) -> found.call(command) |> peer_mail.plain
        }
    }
  }
}

/// Whether this daemon's catalogue holds a session, in any state and any
/// visibility: `Owned` for a `reserved` or `saved` registration, archived or
/// not, `NotOwned` when the catalogue has no such identity, and `Error(Nil)`
/// when the registry could not answer. A `reserved` row counts because a
/// creation retried under its original key has to land on the orchestrator that
/// reserved it.
///
/// A session this catalogue handed to another orchestrator is `Moved` and names
/// it. The registration is still here, but only as the tombstone that records
/// whom the session went to, so the answer says so and not `Owned`: a peer that
/// asked whether this daemon holds the session is told where it went.
///
/// ## Examples
///
/// ```gleam
/// // main.catalogue_holds(ready.registry)("0198c0de-0000-7000-8000-000000000001")
/// ```
@internal
pub fn catalogue_holds(
  registry: manager.Manager(instance),
) -> fn(String) -> Result(orchestrator_port.Ownership, Nil) {
  fn(id) {
    case manager.get(registry, id) {
      Ok(_) ->
        case manager.custody(registry, id) {
          Ok(catalogue.Moved(to:, ..)) -> Ok(orchestrator_port.Moved(to:))
          Ok(catalogue.Resident)
          | Ok(catalogue.Moving(..))
          | Ok(catalogue.Imported(..)) -> Ok(orchestrator_port.Owned)
          Error(_) -> Error(Nil)
        }
      Error(manager.Catalogue(catalogue.Missing)) ->
        Ok(orchestrator_port.NotOwned)
      Error(_) -> Error(Nil)
    }
  }
}

// The directory the control socket asks when its own catalogue misses. With no
// distribution there is nobody to ask and the directory answers `Unknown`.
fn session_directory_of(
  config: Config,
  registry: manager.Manager(instance),
) -> session_directory.Directory {
  case config.membership {
    None -> session_directory.none()
    Some(membership) ->
      session_directory.peers(
        config.orchestrators,
        catalogue_holds(registry),
        session_directory.over_distribution(membership),
      )
      |> session_directory.with_reach(remote_peer.over_distribution(membership))
      |> session_directory.activating(session_directory.activation_over(
        membership,
      ))
      |> session_directory.settling(session_directory.settle_over(
        membership,
        config.orchestrators,
      ))
  }
}

/// Starts the movers that hand sessions to other orchestrators, resumes every
/// move this daemon had in flight, and returns the control the listener gives its
/// owner commands (protocol-change/078, phase 5).
///
/// A daemon with no `[distribution]` has no peer to hand a session to, so it
/// moves nothing and its control lists no destination. One with distribution
/// always starts the movers, whether or not it lists an orchestrator, because a
/// move begun before a restart is resumed from the catalogue and not from the
/// configuration that began it. The actor is linked to the process that starts
/// the daemon's services, as the orchestrator port is.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(control) = main.start_movers(config, daemon, logger)
/// ```
@internal
pub fn start_movers(
  config: Config,
  daemon: root.Root(instance),
  logger: Logger,
) -> Result(session_movers.Control, String) {
  case config.membership {
    None -> {
      // Without distribution there is nobody to hand a session to, but a move
      // begun under a configuration that had it is still in the catalogue. It
      // cannot be resumed, and the operator is told so rather than left to find
      // a session that refuses to open.
      use ready <- result.map(root.ready(daemon, within: 20_000))
      case manager.moving_sessions(ready.registry) {
        Ok([_, ..] as stuck) ->
          log.warn(logger, "daemon.moves_cannot_resume", [
            field.count("moves", list.length(stuck)),
          ])
        Ok([]) | Error(_) -> Nil
      }
      session_movers.idle()
    }
    Some(membership) -> {
      use ready <- result.try(root.ready(daemon, within: 20_000))
      let environment =
        session_mover.Environment(
          registry: ready.registry,
          orchestrators: config.orchestrators,
          directory: session_directory_of(config, ready.registry),
          courier: session_directory.courier_over(membership),
          close: closer_of(config, membership),
          clock: clock.from_function(ffi_os.system_time_ms),
          node: atom.to_string(node.name(node.self())),
          budget: session_mover.default_budget(),
          after: crash_after_step(),
          logger:,
        )
      use control <- result.try(session_movers.start(
        environment,
        session_movers.retry_ms,
        session_directory.over_distribution(membership),
      ))
      use resumed <- result.try(session_movers.resume(control, ready.registry))
      log.info(logger, "daemon.movers", [
        field.count("resumed", resumed),
        field.count("orchestrators", list.length(config.orchestrators)),
      ])
      Ok(control)
    }
  }
}

// How a mover asks an executor to close the scope of a session that has no
// runtime. An executor this daemon does not list, or whose node it does not
// trust, cannot be asked, and the move waits as it does for one that is down.
fn closer_of(
  config: Config,
  membership: distribution.Membership,
) -> session_mover.Closer {
  let configured = config.executors
  fn(executor, session, workspace_name, incarnation) {
    case workspace.reach(Some(membership), configured, executor) {
      Ok(reach) ->
        workspace.close_stopped(reach, session, workspace_name, incarnation)
      Error(_unreachable) -> Error(workspace.CloseUnanswered)
    }
  }
}

// TEST-ONLY. `LOOM_MOVE_CRASH_AFTER=<step>` halts the VM the moment the named
// step of a session move is durable, so a shipped test can lose the source at
// each of the six steps and watch a restart finish the move. The steps are
// `intent`, `close`, `cut`, `send`, `activate` and `retire`. Unset, or set to
// anything else, it does nothing. It is read once at startup, is not documented
// for operators, and has no counterpart in the configuration file.
fn crash_after_step() -> fn(session_move.Step) -> Nil {
  case
    bootstrap.getenv("LOOM_MOVE_CRASH_AFTER")
    |> result.replace_error(Nil)
    |> result.try(session_move.parse_step)
  {
    Ok(wanted) -> fn(step) {
      case step == wanted {
        True -> ffi_os.halt(1)
        False -> Nil
      }
    }
    Error(Nil) -> fn(_step) { Nil }
  }
}

/// Prepares the root before acquiring any daemon file or session resource.
/// The caller retains the returned handle through listen or shutdown failures.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(daemon) = main.prepare(config, logger)
/// ```
@internal
pub fn prepare(
  config: Config,
  logger: Logger,
) -> Result(root.Root(serve.Resident), String) {
  prepare_startup(config, logger) |> result.map(fn(prepared) { prepared.1 })
}

/// Captures startup settings and prepares the root without opening a session.
///
/// The returned configuration owns the web-view choice for this daemon's life.
/// The startup file is read once for UI and connection limits alike; a session's
/// catalogue cannot turn routes on or off. An explicit `--ui` always enables it.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(#(config, daemon)) = main.prepare_startup(config, logger)
/// ```
@internal
pub fn prepare_startup(
  config: Config,
  logger: Logger,
) -> Result(#(Config, root.Root(serve.Resident)), String) {
  use configuration <- result.try(captured_domain_configuration(
    config.session_defaults,
    "",
  ))
  use document <- result.try(case configuration {
    "" -> Ok(dict.new())
    path -> {
      use text <- result.try(
        simplifile.read(path)
        |> result.map_error(fn(error) {
          "the daemon config file "
          <> path
          <> " is unreadable: "
          <> string.inspect(error)
        }),
      )
      tom.parse(text)
      |> result.map_error(fn(error) {
        path <> ": invalid daemon configuration: " <> string.inspect(error)
      })
    }
  })
  use connection_limits <- result.try(
    limits.from_document(document)
    |> result.map_error(fn(reason) { configuration <> ": " <> reason }),
  )

  // Validation above makes a missing or false UI setting the only other
  // possibility. The command-line opt-in remains authoritative over the file.
  let view = case dict.get(document, "daemon") {
    Ok(tom.Table(fields)) ->
      case dict.get(fields, "ui") {
        Ok(tom.Bool(True)) -> ViewOn
        _ -> config.view
      }
    _ -> config.view
  }
  use peer_policy <- result.try(
    peer_defaults.from_document(document)
    |> result.map_error(fn(reason) { configuration <> ": " <> reason }),
  )
  use executors <- result.try(
    executors.from_document(document)
    |> result.map_error(fn(reason) { configuration <> ": " <> reason }),
  )
  use pools <- result.try(
    pools.from_document(document)
    |> result.map_error(fn(reason) { configuration <> ": " <> reason }),
  )
  use workspaces <- result.try(
    workspaces.from_document(document)
    |> result.map_error(fn(reason) { configuration <> ": " <> reason }),
  )
  use Nil <- result.try(
    existing_roots(workspaces)
    |> result.map_error(fn(reason) { configuration <> ": " <> reason }),
  )
  use orchestrators <- result.try(
    orchestrators.from_document(document)
    |> result.map_error(fn(reason) { configuration <> ": " <> reason }),
  )
  use membership <- result.try(start_distribution(document, configuration))
  let config =
    Config(
      ..config,
      view:,
      peer_policy:,
      executors:,
      pools:,
      workspaces:,
      orchestrators:,
      membership:,
    )
  root.start(
    root.Config(
      config.state_root,
      config.owner_display_name,
      config.capacity,
      connection_limits,
    ),
    manager.Assembly(
      domain_build: fn(selected, sources, owner) {
        serve.build_domain(selected, sources, logger, owner)
        |> diagnose_domain_start(logger, selected.configuration)
      },
      build: fn(registration, selected, services, owner, directory) {
        use identity <- result.try(
          ids.parse_session_id(registration.id)
          |> result.replace_error("invalid reserved session identity"),
        )
        use state <- result.try(
          bootstrap.canonical_directory(config.state_root)
          |> diagnose_start(logger, identity, SettingsResolution),
        )
        use settings <- result.try(
          serve.resolve_managed(
            config.session_defaults,
            registration,
            selected,
            state,
          )
          |> diagnose_start(logger, identity, SettingsResolution),
        )
        let settings =
          serve.Settings(
            ..settings,
            peer_directory: Some(peer_directory_across(
              directory,
              fn(resident: serve.Resident) { resident.peer },
              session_directory_of(config, directory),
            )),
            peer_defaults: Some(
              peer_mail.Defaults(policy: config.peer_policy, eligible: fn() {
                manager.unshared_sessions(directory)
              }),
            ),
          )
        let settings =
          serve.Settings(
            ..settings,
            first_prompt: Some(fn(text) {
              manager.seed_subtitle(directory, registration.id, text)
            }),
          )

        // A workspace registered on an executor, or in a pool of them, is
        // assembled with the executor's host in reach, and a daemon that cannot
        // reach one says so in the reason the opening operation reports. The
        // session records the executor an open chose in its own store, and the
        // catalogue is told once so that a listing can show it.
        let session_id = registration.id
        let chosen = fn(executor) {
          manager.seed_executor(directory, session_id, executor)
        }
        case registration.executor, registration.pool {
          "", "" ->
            serve.assemble_in_domain(
              settings,
              identity,
              logger,
              owner,
              services,
            )
          name, "" ->
            serve.assemble_registered(
              settings,
              identity,
              logger,
              owner,
              Some(services),
              workspace.fixed(membership, config.executors, name, chosen),
            )
          _, pool ->
            serve.assemble_registered(
              settings,
              identity,
              logger,
              owner,
              Some(services),
              workspace.pooled(
                membership,
                config.executors,
                config.pools,
                pool,
                chosen,
              ),
            )
        }
        |> diagnose_start(logger, identity, RuntimeAssembly)
        |> result.map(serve.resident)
      },
      fatal: serve.resident_children,
      drain: serve.drain_resident,
    ),
  )
  |> result.map(fn(daemon) { #(config, daemon) })
}

// Domain construction precedes session assembly, so its failures never reach
// the session diagnostic below. Preserve a fixed classification before the
// failed owner retires; the domain identity itself contains a workspace path.
fn diagnose_domain_start(
  outcome: Result(value, String),
  logger: Logger,
  configuration: String,
) -> Result(value, String) {
  outcome
  |> result.map_error(fn(reason) {
    let class = case
      configuration != ""
      && {
        string.starts_with(reason, configuration <> ": ")
        || string.starts_with(
          reason,
          "the config file " <> configuration <> " is unreadable: ",
        )
      }
    {
      True -> "configuration_rejected"
      False -> "assembly_failed"
    }
    log.error(logger, "daemon.domain_start_failed", [
      field.text("stage", "domain_assembly"),
      field.text("class", class),
      field.text("reason", glance.clip(reason, 2048)),
    ])
    reason
  })
}

// A failed builder can retire before the control client reads its operation.
// Record the classified cause here, while it still exists, rather than keeping
// failed instances alive for diagnostics. The caller receives the same error;
// only fixed labels, a validated session identity and the path-free detail
// that `start_class` returns enter the log.
fn diagnose_start(
  outcome: Result(value, String),
  logger: Logger,
  identity: ids.SessionId,
  stage: StartStage,
) -> Result(value, String) {
  outcome
  |> result.map_error(fn(reason) {
    let #(stage_name, class, detail) = start_class(stage, reason)
    log.error(
      logger,
      "daemon.session_start_failed",
      list.append(
        [
          field.ident("session", ids.session_id_to_string(identity)),
          field.text("stage", stage_name),
          field.text("class", class),
        ],
        detail,
      ),
    )
    reason
  })
}

/// Classifies a start failure into the stage, class and detail a log record
/// may carry.
///
/// Prefixes recognize errors from the existing resolver and assembly boundary.
/// An unknown error stays useful as a stage-specific class, never as raw text.
///
/// A class alone is not something an operator can act on, so a class that has
/// an actionable fact behind it also returns that fact as its own field. Only
/// values proven free of a path or a credential may be returned this way; the
/// reason string itself is not, which is why it is matched rather than
/// logged. An executor reason is the one exception, and only when it names no
/// path (see `executor_detail`). The lease expiry qualifies: it is a
/// millisecond instant minted by the writer that died, and it is the entire
/// answer to "when can I retry?".
///
/// ## Examples
///
/// ```gleam
/// // main.start_class(RuntimeAssembly,
/// //   "another writer holds this session's lease until epoch ms 42")
/// // == #("runtime_assembly", "lease_held",
/// //      [field.count("lease_expires_at_ms", 42)])
/// ```
@internal
pub fn start_class(
  stage: StartStage,
  reason: String,
) -> #(String, String, List(field.Field)) {
  case stage {
    SettingsResolution -> {
      let class = case
        string.starts_with(reason, "no loom-exec sandbox helper found.")
        || string.starts_with(reason, "the helper binary does not exist: ")
      {
        True -> "helper_unavailable"
        False -> "settings_rejected"
      }
      #("settings_resolution", class, [])
    }
    RuntimeAssembly -> {
      let #(class, detail) = case reason {
        "the session base policy is not one the sandbox can enforce: " <> _ -> #(
          "policy_rejected",
          [],
        )

        // A lease the previous incarnation could not release. The expiry is
        // the only thing that clears it, so it is what the record carries.
        "another writer holds this session's lease until epoch ms " <> expiry -> #(
          "lease_held",
          case int.parse(expiry) {
            Ok(expires_at_ms) -> [
              field.count("lease_expires_at_ms", expires_at_ms),
            ]
            Error(Nil) -> []
          },
        )

        "the session did not open (held lease? bad path?): " <> _ -> #(
          "storage_open_failed",
          [],
        )

        // A remote open that could not reach or attach its executor. The reason
        // is what separates a network failure from a pin, a capacity or an
        // incarnation refusal, and it is the only thing an operator reading
        // the log can act on.
        "executor_unavailable: " <> detail -> #(
          "executor_unavailable",
          executor_detail(detail),
        )

        _ -> #("assembly_failed", [])
      }
      #("runtime_assembly", class, detail)
    }
  }
}

// The reason an executor could not hold a session, as a log field, or no field
// when the text could name a path.
//
// Most of these reasons are fixed sentences from the open path. Two kinds are
// not: a storage error, which `string.inspect` renders with the session's own
// path, and a sentence the executor wrote, which can carry a path from its
// disk. Every path contains a separator, so a reason with one is dropped
// whole rather than scrubbed, and the class alone is logged as it was before.
// Nothing here is built from a key, a cookie or a certificate. The length is
// bounded because part of the text comes from another machine.
fn executor_detail(detail: String) -> List(field.Field) {
  case string.contains(detail, "/") || string.contains(detail, "\\") {
    True -> []
    False -> [field.text("reason", glance.clip(detail, 512))]
  }
}

/// Restores metadata, then publishes the sole listener before returning its port.
/// The caller owns daemon cleanup even if this bounded startup returns an error.
///
/// ## Examples
///
/// ```gleam
/// // main.listen(config, daemon, fn(request, attachment) { upgrade(request, attachment) })
/// ```
@internal
pub fn listen(
  config: Config,
  daemon: root.Root(instance),
  upgrade: fn(Request(mist.Connection), server.Attachment(instance)) ->
    Response(mist.ResponseData),
) -> Result(Serving(instance), String) {
  listen_with_peers(config, daemon, upgrade, fn(_) { None })
}

/// Starts the daemon listener with the resident peer endpoint projection.
///
/// ## Examples
///
/// ```gleam
/// // main.listen_with_peers(config, daemon, upgrade, fn(resident) { Some(resident.peer) })
/// ```
@internal
pub fn listen_with_peers(
  config: Config,
  daemon: root.Root(instance),
  upgrade: fn(Request(mist.Connection), server.Attachment(instance)) ->
    Response(mist.ResponseData),
  peer_endpoint: fn(instance) -> Option(peer_mail.Endpoint),
) -> Result(Serving(instance), String) {
  listen_serving(config, daemon, upgrade, peer_endpoint, None)
}

/// Starts the daemon listener, serving the web view when `ui` is present.
///
/// ## Examples
///
/// ```gleam
/// // main.listen_serving(config, daemon, upgrade, peers, Some(ui))
/// ```
@internal
pub fn listen_serving(
  config: Config,
  daemon: root.Root(instance),
  upgrade: fn(Request(mist.Connection), server.Attachment(instance)) ->
    Response(mist.ResponseData),
  peer_endpoint: fn(instance) -> Option(peer_mail.Endpoint),
  ui: Option(server.Ui(instance)),
) -> Result(Serving(instance), String) {
  listen_moving(
    config,
    daemon,
    upgrade,
    peer_endpoint,
    ui,
    session_movers.idle(),
  )
}

/// Starts the daemon listener as `listen_serving` does, with the control its
/// owner commands use to hand sessions to other orchestrators. `start_movers`
/// builds it.
///
/// ## Examples
///
/// ```gleam
/// // main.listen_moving(config, daemon, upgrade, peers, Some(ui), movers)
/// ```
@internal
pub fn listen_moving(
  config: Config,
  daemon: root.Root(instance),
  upgrade: fn(Request(mist.Connection), server.Attachment(instance)) ->
    Response(mist.ResponseData),
  peer_endpoint: fn(instance) -> Option(peer_mail.Endpoint),
  ui: Option(server.Ui(instance)),
  movers: session_movers.Control,
) -> Result(Serving(instance), String) {
  use ready <- result.try(root.ready(daemon, within: 20_000))
  use domain_configuration <- result.try(captured_domain_configuration(
    config.session_defaults,
    "",
  ))
  let routing =
    server.Config(
      daemon:,
      peer_endpoint:,
      domain_configuration:,
      executors: config.executors,
      pools: config.pools,
      directory: session_directory_of(config, ready.registry),
      movers:,
      generator: fn() {
        ids.generator(
          clock.from_function(ffi_os.system_time_ms),
          ffi_os.unique_positive_integer(),
        )
      },
      session_upgrade: upgrade,
      ui:,
    )
  let builder =
    mist.new(fn(request) { server.handle(routing, request) })
    |> mist.bind(config.bind_host)
    |> mist.port(config.bind_port)
  let builder = case config.bind_host {
    "::1" -> mist.with_ipv6(builder)
    _ -> builder
  }
  use listener <- result.try(root.start_listener(
    daemon,
    builder,
    within: 15_000,
  ))
  Ok(Serving(daemon, ready, listener))
}

// Capture the daemon owner's choice before any session is admitted. The final
// --config wins just as in the session resolver; absence stays explicit.
fn captured_domain_configuration(
  arguments: List(String),
  selected: String,
) -> Result(String, String) {
  case arguments {
    [] ->
      case selected {
        "" -> Ok("")
        path -> bootstrap.absolute_path(path)
      }
    ["--config", path, ..rest] -> captured_domain_configuration(rest, path)
    [_, ..rest] -> captured_domain_configuration(rest, selected)
  }
}

fn run(
  config: Config,
  paths: endpoint.Paths,
  fence: endpoint.Fence,
  daemon: root.Root(serve.Resident),
  logger: Logger,
) -> Nil {
  let watch = process.monitor(root.pid(daemon))
  let signals = process.new_subject()
  host.relay_sigterm(signals, ffi_os.wait_for_sigterm)
  case
    {
      use executor <- result.try(start_executor(config, logger))
      use Nil <- result.try(
        start_orchestrator_port(
          config,
          daemon,
          logger,
          fn(resident: serve.Resident) { Some(resident.peer) },
        ),
      )
      use movers <- result.try(start_movers(config, daemon, logger))
      use ui <- result.try(web_view(config, daemon))
      use serving <- result.try(listen_moving(
        config,
        daemon,
        fn(request, attachment) {
          session_socket.upgrade(
            daemon,
            request,
            attachment,
            attachment.instance.gateway,
          )
        },
        fn(resident: serve.Resident) { Some(resident.peer) },
        ui,
        movers,
      ))
      publish_endpoint(config, serving, paths, fence)
      |> result.replace(#(serving, executor))
    }
  {
    Error(reason) -> {
      log.error(logger, "daemon.start_failed", [field.text("reason", reason)])
      let outcome = root.shutdown(daemon, within: 30_000)
      report_shutdown(logger, outcome)
      ffi_os.halt(1)
    }
    Ok(#(serving, executor)) -> {
      let host = case config.bind_host {
        "::1" -> "[::1]"
        host -> host
      }
      io.println(
        "loomd: daemon listening on ws://"
        <> host
        <> ":"
        <> int.to_string(serving.listener.port)
        <> "/v2/control (token file "
        <> serving.ready.state_root
        <> "/owner.token)",
      )
      case config.view {
        ViewOn ->
          io.println("loomd: web view on; run `loom ui` for your home page")
        ViewOff -> Nil
      }
      log.info(logger, "daemon.listening", [
        field.count("port", serving.listener.port),
      ])
      wait(daemon, watch, executor, signals, logger)
    }
  }
}

// The web view's assets, tables and socket, when startup enabled the UI.
// The tables' actor is linked to this process, which lives as long as the
// daemon does.
fn web_view(
  config: Config,
  daemon: root.Root(serve.Resident),
) -> Result(Option(server.Ui(serve.Resident)), String) {
  case config.view {
    ViewOff -> Ok(None)
    ViewOn -> {
      // The page's assets are read once, here, so a release that lost one
      // refuses `--ui` at startup rather than serving a page without it.
      use assets <- result.try(ui_assets.load())
      use sessions <- result.try(
        ui_sessions.start(ui_sessions.production(bootstrap.monotonic_time_ms)),
      )

      // The login's root key is read here, once, with the registry that can
      // revoke the rows of a lost one (`ui_login.root_key`): a key that is
      // present and wrong refuses `--ui` at startup rather than serving a view
      // whose logins can never verify.
      use ready <- result.try(root.ready(daemon, within: 20_000))
      use root_key <- result.map(ui_login.root_key(
        ready.state_root,
        ready.registry,
      ))
      Some(
        server.Ui(
          sessions:,
          result_reader: fn(resident: serve.Resident) { resident.result_reader },
          assets:,
          root_key:,
          upgrade: fn(request, attachment, open, register, seen) {
            ui_socket.upgrade(
              daemon,
              request,
              attachment,
              attachment.instance.gateway,
              attachment.instance.worktree,
              sessions,
              open,
              register,
              seen,
            )
          },
          home: fn(request, attachment, open, seen) {
            ui_socket.upgrade_home(
              daemon,
              request,
              attachment,
              sessions,
              open,
              seen,
            )
          },
          admin: fn(request, attachment, open, ceiling) {
            ui_socket.upgrade_admin(
              daemon,
              request,
              attachment,
              sessions,
              open,
              ceiling,
            )
          },
        ),
      )
    }
  }
}

fn wait(daemon, watch, executor, signals, logger) {
  let selector =
    process.new_selector()
    |> process.select_map(signals, Signal)
    |> process.select_specific_monitor(watch, fn(down) { RootGone(down.reason) })
  let selector = case executor {
    Some(monitor) ->
      process.select_specific_monitor(selector, monitor, fn(down) {
        ExecutorGone(down.reason)
      })
    None -> selector
  }
  case process.selector_receive_forever(selector) {
    Signal(host.Signalled) -> {
      let outcome = root.shutdown(daemon, within: 30_000)
      report_shutdown(logger, outcome)
      case outcome {
        Ok(Nil) -> Nil
        Error(_) -> ffi_os.halt(1)
      }
    }
    RootGone(process.Normal) -> log.info(logger, "daemon.stopped", [])
    RootGone(process.Killed)
    | RootGone(process.Abnormal(_))
    | Signal(host.Faulted(..)) -> {
      log.error(logger, "daemon.retirement_unconfirmed", [])
      ffi_os.halt(1)
    }

    // The host ending at all, however it ended, is fatal: see `start_executor`
    // for why it is never restarted on its own.
    ExecutorGone(_reason) -> {
      log.error(logger, "daemon.executor_lost", [])
      ffi_os.halt(1)
    }
  }
}

fn report_shutdown(logger: Logger, outcome: Result(Nil, String)) {
  case outcome {
    Ok(Nil) -> log.info(logger, "daemon.stopped", [])
    Error(reason) ->
      log.error(logger, "daemon.retirement_unconfirmed", [
        field.text("reason", reason),
      ])
  }
}

/// Supplies resident-only peer resolution and catalogue-only discovery.
/// This closure carries manager handles, never a session Runtime graph.
///
/// ## Examples
///
/// ```gleam
/// // main.peer_directory(registry, fn(resident) { resident.peer })
/// ```
@internal
pub fn peer_directory(
  registry: manager.Manager(instance),
  endpoint: fn(instance) -> peer_mail.Endpoint,
) -> peers.Directory {
  peer_directory_across(registry, endpoint, session_directory.none())
}

/// Supplies the peer directory a session's tools use: a resident session
/// resolves to its Agency, and a session another orchestrator owns resolves to
/// that orchestrator's port, found through `sessions` (`peers.routed`).
///
/// ## Examples
///
/// ```gleam
/// // main.peer_directory_across(registry, fn(resident) { resident.peer }, sessions)
/// ```
@internal
pub fn peer_directory_across(
  registry: manager.Manager(instance),
  endpoint: fn(instance) -> peer_mail.Endpoint,
  sessions: session_directory.Directory,
) -> peers.Directory {
  peers.Directory(
    resolve: peers.routed(
      fn(id) {
        manager.resolve(registry, id)
        |> result.map(endpoint)
        |> result.map_error(fn(error) {
          peer_mail.Refused(string.inspect(error))
        })
      },
      sessions,
    ),
    describe: fn(id) {
      manager.get(registry, id)
      |> result.map(server.view_json)
      |> result.map_error(string.inspect)
    },
  )
}
