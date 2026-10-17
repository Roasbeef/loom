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
//// `start_movers` → `node_reads` → `start_orchestrator_port` →
//// `start_release_drain` → `start_delegate_sweep` → `listen_moving` →
//// `publish_endpoint` → `wait`
////
//// 1. `main` parses the flags, `claim_endpoint` reserves this VM, and
////    `prepare_startup` reads the configuration once and prepares the root.
//// 2. `run` starts the daemon's services in order. `start_executor` comes
////    first, so a machine that serves workspaces answers peers before any
////    client can connect. `sweep_delegate_sessions` then settles the delegate
////    sessions a previous run left, before anything is served or moved.
////    `start_movers` follows it and resumes every move this
////    daemon had in flight, and `start_orchestrator_port` follows that, so a
////    daemon with distribution answers a peer's question about which sessions
////    it holds, takes the sessions a peer moves to it, and reports itself
////    (protocol-change/085). The port comes after the movers and the executor
////    host because a report reads both: the moves in flight and the host's
////    ledger. `node_reads` builds that report once, and both the port, which
////    answers a peer with it, and `listen_moving`, whose `deployment.status`
////    reads the daemon's own facts through it, are given the same closure.
////    `start_release_drain` follows the port and keeps telling other
////    orchestrators that a deleted parent session no longer needs the
////    subagents they run for it. `start_delegate_sweep` follows the drain and
////    starts the hourly pass that deletes delegate sessions whose spawner was
////    removed and closes idle resident ones, using the same
////    `sweep_delegate_sessions` the boot ran once.
//// 2a. Each delegate session is assembled with `deadline_tick_of` and
////    `metering_of`: the first gives it the tick that enforces its children's
////    deadlines, the second the recorder and the child budget of a metered
////    spawner (protocol-change/084, phase 2).
//// 3. `listen_moving` binds the listener, and `publish_endpoint` records the
////    bound port for the reservation this VM holds.
//// 4. `wait` blocks on the signal relay, the root and the executor host, and a
////    loss of either of the last two ends the daemon.

import argv
import client/agency
import client/catalog
import client/daemon/limits
import client/daemon/listener
import client/daemon/manager
import client/daemon/node_facts
import client/daemon/profiles
import client/daemon/restart
import client/daemon/root
import client/daemon/server
import client/daemon/session_socket
import client/daemon/ui_assets
import client/daemon/ui_login
import client/daemon/ui_sessions
import client/daemon/ui_socket
import client/delegate_host
import client/deployment
import client/directory/deletion
import client/directory/member
import client/directory/migrate
import client/directory/ownership
import client/directory/seats
import client/directory/settings as directory_settings
import client/directory/store
import client/distribution
import client/distribution_plan
import client/executor_plane
import client/executors
import client/host
import client/internal/ffi_os
import client/ledger_boot
import client/ledger_control
import client/ledger_holdings
import client/ledger_reference
import client/ledger_rows
import client/ledger_service.{type Service}
import client/membership_ledger
import client/node_report
import client/orchestrators
import client/peer_defaults
import client/peer_mail
import client/peer_outbox_drain
import client/peers
import client/pools
import client/profile_switch
import client/remote/address
import client/remote/host as executor_host
import client/remote/orchestrator_port
import client/remote/remote_peer
import client/remote/remote_spawner
import client/remote/workspace
import client/remote_reach
import client/remote_release
import client/remote_spawn
import client/roster.{type Roster}
import client/serve
import client/session_directory
import client/session_importer
import client/session_move
import client/session_mover
import client/session_movers
import client/spawners
import client/system_prompt
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
import runtime/effects
import simplifile
import storage/catalogue
import telemetry/field
import telemetry/handler
import telemetry/log.{type Logger}
import tom
import weft/actor
import weft/poll
import weft/registry as names

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
    /// at startup and never reread (protocol-change/078). These are the rows the
    /// operator wrote. A daemon that runs from a ledger also uses the executors
    /// the ledger links it to (protocol-change/086, phase 2), which
    /// `executor_roster` adds when the list is read.
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
    /// and never reread (protocol-change/078, phase 3). These are the rows the
    /// operator wrote, and `orchestrator_roster` adds the ledger's.
    orchestrators: List(orchestrators.Orchestrator),
    /// The `[directory]` table, read at startup and never reread: whether this
    /// daemon is a member of the session directory's Khepri cluster and who the
    /// members are (protocol-change/083). `None` leaves the daemon exactly as
    /// it was before the directory existed.
    directory: Option(directory_settings.Settings),
    /// The running member actor, set by `run` once `start_directory` has
    /// started it; `None` on a daemon that is not a member, and before then.
    member: Option(member.Member),
    /// The orchestrators that may start subagents on this daemon, and on what
    /// terms, read from `[spawners.<name>]` at startup and never reread
    /// (protocol-change/084). A daemon with none accepts no spawns.
    spawners: List(spawners.Spawner),
    /// The distribution membership `prepare_startup` started, or `None` when
    /// the configuration has no `[distribution]` table. It is how the daemon
    /// reaches the peers it asks, and a daemon without it asks nobody and
    /// answers nobody.
    membership: Option(distribution.Membership),
    /// The membership ledger's process with this node's names, when
    /// `[distribution]` names a ledger (protocol-change/086).
    /// `start_distribution` started the process before distribution, so its pin
    /// table existed before the listener did. The `ledger.*` control commands
    /// append and read entries through this handle.
    ledger: Option(ledger_control.Handle),
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

/// The executor host this daemon started, as the rest of the daemon holds it.
pub type ExecutorHost {
  ExecutorHost(
    /// A monitor on the host, whose `DOWN` ends the daemon (`wait`).
    monitor: process.Monitor,
    /// What the host says about itself, as the executor facts of a report.
    /// `None` when the host did not answer within `executor_summary_ms`, which
    /// a report treats as a source that said nothing and not as a host with
    /// nothing in its ledger.
    facts: fn() -> Option(node_report.ExecutorFacts),
  )
}

// How long a report waits for the host to read its ledger. The host answers in
// its own turn between calls, so a wait this long means it is busy with
// admissions, and a report that is part-way through its own deadline is better
// without the executor facts than late.
const executor_summary_ms = 2000

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
      None,
      [],
      None,
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
//
// A configured ledger is opened and its process started first, and
// distribution after it. The constraint is that the pin table must exist before
// the listener does: in ledger mode the TLS callback refuses every handshake
// with `ledger_unavailable` while the table is absent, so a listener opened
// first would turn away the first peers for no reason of theirs. The ledger
// process needs no distribution to start, because a monitor of node changes is
// valid on a VM that is not distributed yet. `ledger_boot.start` does both in
// that order and keeps the process linked to this one for the life of the
// daemon, like the other services.
fn start_distribution(
  document: dict.Dict(String, tom.Toml),
  configuration: String,
  cluster: distribution.Cluster,
  logger: Logger,
) -> Result(Option(ledger_boot.Booted), String) {
  use found <- result.try(
    distribution.from_document(document)
    |> result.map_error(fn(reason) { configuration <> ": " <> reason }),
  )
  case found {
    None -> Ok(None)
    Some(settings) ->
      ledger_boot.start(settings, cluster, logger)
      |> result.map(Some)
      |> result.map_error(fn(reason) { configuration <> ": " <> reason })
  }
}

/// The directory settings of a daemon, given the table it read: the table
/// itself when the trust is a static peer list, and the ledger's seats when the
/// trust is a ledger, where a node is a member exactly when its own entry gives
/// it a `voter` or `learner` standing. Every `[orchestrators.<name>]` node of a
/// member must be a member, the rule of protocol-change/083 that a parse
/// cannot check against a ledger, so it is checked here with the ledger the
/// process holds. A count of voters outside three to seven, or an even count,
/// is logged and not refused: the ledger records a fact the operator's command
/// already vetted.
///
/// ## Examples
///
/// ```gleam
/// // main.ledger_directory(None, None, "loom@a.example", [], logger) == Ok(None)
/// ```
@internal
pub fn ledger_directory(
  configured: Option(directory_settings.Settings),
  ledger: Option(Service),
  local: String,
  listed: List(orchestrators.Orchestrator),
  logger: Logger,
) -> Result(Option(directory_settings.Settings), String) {
  case ledger {
    None -> Ok(configured)
    Some(service) -> {
      use status <- result.try(
        ledger_service.status(service, 5000)
        |> result.replace_error("the ledger process did not answer"),
      )
      case directory_settings.from_ledger(status.ledger, local) {
        None -> Ok(None)
        Some(found) -> {
          use Nil <- result.map(directory_settings.require_orchestrators(
            listed,
            found.members,
          ))
          let voters =
            list.count(seats.places(status.ledger), fn(place) {
              place.seat == store.Voter
            })
          case
            voters < directory_settings.minimum_members
            || voters > directory_settings.maximum_members
            || int.is_even(voters)
          {
            True ->
              log.warn(logger, "daemon.directory_voters", [
                field.count("voters", voters),
              ])
            False -> Nil
          }
          Some(found)
        }
      }
    }
  }
}

// The tables that name a peer are checked against the ledger once, here, after
// the ledger process holds the file and before the daemon listens. Parsing them
// never reads the ledger (`client/ledger_reference`), because a session parses
// them on every create and open and a ledger changes while a daemon runs. A
// node no entry ever named refuses the start. A node that was a member and no
// longer is a row the daemon logs and keeps, so that a `revoke` never turns the
// next restart into an outage of the sessions that do not use that node. The
// executor names that pools and spawners list are judged the same way, because
// the ledger can give an executor a row that no table defines.
fn audit_started(
  booted: Option(ledger_boot.Booted),
  document: dict.Dict(String, tom.Toml),
  rows: List(ledger_reference.Row),
  written: List(String),
  names: List(ledger_reference.NameRow),
  logger: Logger,
) -> Result(Nil, String) {
  use found <- result.try(distribution.from_document(document))
  case
    option.then(booted, fn(started) { started.ledger }),
    option.then(found, distribution.ledger_path)
  {
    Some(service), Some(path) -> {
      let local = atom.to_string(node.name(node.self()))
      use Nil <- result.try(audit_references(service, local, path, rows, logger))
      audit_executor_names(service, local, path, written, names, logger)
    }
    _, _ -> Ok(Nil)
  }
}

/// Compares the executor names that pools and spawners list with the ledger a
/// running ledger process holds, as `audit_references` compares nodes. A name
/// that is neither a written `[executors.<name>]` row nor a name the ledger ever
/// gave is an `Error` with a sentence for the operator. A name whose member was
/// revoked, or is an executor this node is not linked to, is logged as a warning
/// and the start goes on: the pool skips such an executor as it skips one that
/// is down.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = main.audit_executor_names(service, local, path, ["box"], names, logger)
/// ```
@internal
pub fn audit_executor_names(
  service: Service,
  local: String,
  path: String,
  written: List(String),
  names: List(ledger_reference.NameRow),
  logger: Logger,
) -> Result(Nil, String) {
  use status <- result.try(
    ledger_service.status(service, 5000)
    |> result.replace_error("the ledger process did not answer"),
  )
  use inert <- result.map(ledger_reference.audit_names(
    status.ledger,
    local,
    path,
    written,
    names,
  ))
  list.each(inert, fn(found) {
    log.warn(logger, "daemon.ledger_name_inert", [
      field.text("row", found.row.key),
      field.text("name", found.row.name),
      field.text("reason", found.reason),
    ])
  })
}

/// The executor names the pools and spawners of a configuration list, with
/// the key each was written under, in the order a refusal should report them.
///
/// ## Examples
///
/// ```gleam
/// // main.reference_names([], []) == []
/// ```
@internal
pub fn reference_names(
  configured_pools: List(pools.Pool),
  configured_spawners: List(spawners.Spawner),
) -> List(ledger_reference.NameRow) {
  list.flatten([
    list.flat_map(configured_pools, fn(pool) {
      list.map(pool.executors, fn(name) {
        ledger_reference.NameRow("pools." <> pool.name <> ".executors", name)
      })
    }),
    list.filter_map(configured_spawners, fn(spawner) {
      case spawner.placement {
        spawners.OnExecutor(executor:, ..) ->
          Ok(ledger_reference.NameRow(
            "spawners." <> spawner.name <> ".executor",
            executor,
          ))
        spawners.InPool(..) | spawners.InDirectory(..) -> Error(Nil)
      }
    }),
  ])
}

/// Compares the rows of the tables that name a peer with the ledger a running
/// ledger process holds, for the node named `local` whose ledger file is
/// `path`. A row naming a node that no entry has ever named is an `Error` with
/// a sentence for the operator. A row naming a node that was a member and is
/// not an active linked member now is logged as a warning and the start goes
/// on, because the row is inert: peer resolution answers only for names in the
/// current pin table, so a call to it fails when it is made.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = main.audit_references(service, local, path, rows, logger)
/// ```
@internal
pub fn audit_references(
  service: Service,
  local: String,
  path: String,
  rows: List(ledger_reference.Row),
  logger: Logger,
) -> Result(Nil, String) {
  use status <- result.try(
    ledger_service.status(service, 5000)
    |> result.replace_error("the ledger process did not answer"),
  )
  use inert <- result.map(ledger_reference.audit(
    status.ledger,
    local,
    path,
    rows,
  ))
  list.each(inert, fn(found) {
    log.warn(logger, "daemon.ledger_row_inert", [
      field.text("row", found.row.key),
      field.text("node", found.row.node),
      field.text("reason", found.reason),
    ])
  })
}

/// The node every row of the tables that name a peer names, in the order a
/// refusal should report them. `[directory]` is not among them: with a ledger
/// the directory's members are the ledger's, and `ledger_directory` checks the
/// `[orchestrators]` rows against them.
///
/// ## Examples
///
/// ```gleam
/// // main.reference_rows([], [], []) == []
/// ```
@internal
pub fn reference_rows(
  configured_executors: List(executors.Executor),
  configured_orchestrators: List(orchestrators.Orchestrator),
  configured_spawners: List(spawners.Spawner),
) -> List(ledger_reference.Row) {
  list.flatten([
    list.map(configured_executors, fn(row) {
      ledger_reference.Row("executors." <> row.name <> ".node", row.node)
    }),
    list.map(configured_orchestrators, fn(row) {
      ledger_reference.Row("orchestrators." <> row.name <> ".node", row.node)
    }),
    list.map(configured_spawners, fn(row) {
      ledger_reference.Row("spawners." <> row.name <> ".node", row.node)
    }),
  ])
}

// The handle the `ledger.*` commands use: the process and this node's names. The
// node is distributed by now, so its own name is the VM's.
fn ledger_handle(
  booted: Option(ledger_boot.Booted),
  configuration: String,
) -> Result(Option(ledger_control.Handle), String) {
  case booted {
    Some(ledger_boot.Booted(ledger: Some(service), membership:)) -> {
      // The node is distributed by now. `ledger.holdings` asks the orchestrators
      // the ledger links it to over that distribution.
      let local = atom.to_string(node.name(node.self()))
      ledger_control.handle(service, local)
      |> result.map(fn(handle) {
        Some(ledger_control.asking(
          handle,
          ledger_holdings.over_distribution(membership, local),
        ))
      })
      |> result.map_error(fn(reason) { configuration <> ": " <> reason })
    }
    Some(ledger_boot.Booted(ledger: None, ..)) | None -> Ok(None)
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
) -> Result(Option(ExecutorHost), String) {
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
      let limits = executor_plane.scope_limits()
      use started <- result.try(
        executor_host.start_reporting(executor_host.Config(
          name: address.default(),
          ledger_path: config.state_root <> "/exec-ledger.db",
          limits:,
          max_result_bytes: executor_host.default_max_result_bytes,
          execution_result_bytes: executor_host.default_execution_result_bytes,
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
      let platform = system_prompt.platform(ffi_os.platform())
      let names = list.map(configured, fn(workspace) { workspace.name })
      let summarize = started.data.summarize
      Ok(
        Some(
          ExecutorHost(monitor: process.monitor(started.pid), facts: fn() {
            summarize(executor_summary_ms)
            |> result.map(node_facts.executor_facts(_, limits, platform, names))
            |> option.from_result
          }),
        ),
      )
    }
  }
}

/// Starts this daemon's membership in the session directory's Khepri cluster
/// when the configuration has a `[directory]` table (protocol-change/083), and
/// nothing otherwise. A store marked joined is started before this returns; one
/// that has not joined is joined in the background, and until then every store
/// call is refused as no quorum. The actor is linked to the process that starts
/// the daemon's services, as the orchestrator port is.
///
/// ## Examples
///
/// ```gleam
/// // assert main.start_directory(Config(..config, directory: None), logger) == Ok(None)
/// ```
@internal
pub fn start_directory(
  config: Config,
  logger: Logger,
) -> Result(Option(member.Member), String) {
  case config.directory, config.membership {
    Some(settings), Some(membership) ->
      member.start(member.Config(
        directory: directory_path(config.state_root),
        members: members_of(config, settings),
        local: atom.to_string(node.name(node.self())),
        membership:,
        logger:,
      ))
      |> result.map(Some)
    _, _ -> Ok(None)
  }
}

// Who the member actor takes its members from: the configured list, or the
// ledger the daemon runs, read afresh on every tick because the seats change
// while the daemon runs. The read is a local call to the ledger process, which
// answers it between two messages.
fn members_of(
  config: Config,
  settings: directory_settings.Settings,
) -> member.Members {
  case config.ledger {
    None -> member.Listed(settings.members)
    Some(handle) ->
      member.Followed(read: fn() {
        ledger_service.status(handle.service, 1000)
        |> result.map(fn(status) { seats.read(status.ledger) })
        |> result.replace_error(Nil)
      })
  }
}

/// Where a member keeps its directory store.
///
/// ## Examples
///
/// ```gleam
/// assert main.directory_path("/s") == "/s/directory"
/// ```
pub fn directory_path(state_root: String) -> String {
  state_root <> "/directory"
}

/// Starts the orchestrator port when the configuration has a `[distribution]`
/// table, and registers nothing otherwise.
///
/// The port answers a peer orchestrator's question about whether this daemon's
/// catalogue holds a session. It runs whether or not this daemon lists any
/// `[orchestrators.<name>]` of its own, since an orchestrator can be asked by a
/// peer that lists it without listing that peer back. It also relays the three
/// subagent messages to `spawn_host`, which refuses all of them for a daemon with
/// no `[spawners.<name>]` and otherwise serves them from the sender's delegate
/// session. It is linked to the
/// process that starts the daemon's services, so an abnormal exit of the port
/// ends the daemon the way the executor host's does: a daemon that silently
/// stopped answering would make every peer report it unreachable.
///
/// ## Examples
///
/// ```gleam
/// // assert main.start_orchestrator_port(Config(..config, membership: None), daemon, logger, peer, delegate, orchestrator_port.unreported()) == Ok(Nil)
/// ```
@internal
pub fn start_orchestrator_port(
  config: Config,
  daemon: root.Root(instance),
  logger: Logger,
  peer_endpoint: fn(instance) -> Option(peer_mail.Endpoint),
  delegate_endpoint: fn(instance) -> agency.DelegateEndpoint,
  reads: orchestrator_port.Reads,
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
          ownership: session_directory_of(config, ready.registry).ownership,
          registry: ready.registry,
          state_root: ready.state_root,
          sessions_directory: ready.sessions_directory,
          domain_configuration:,
          clock: clock.from_function(ffi_os.system_time_ms),
          orchestrators: orchestrator_roster(config),
          executors: executor_roster(config),
          logger:,
        ))
      let delegates =
        delegate_host.Context(
          registry: ready.registry,
          sessions_directory: ready.sessions_directory,
          domain_configuration:,
          generator: fn() {
            ids.generator(
              clock.from_function(ffi_os.system_time_ms),
              ffi_os.unique_positive_integer(),
            )
          },
          now_ms: ffi_os.system_time_ms,
          endpoint: delegate_endpoint,
        )
      use _started <- result.try(
        orchestrator_port.start_with(
          orchestrator_port.default(),
          catalogue_holds(ready.registry),
          peer_command(ready.registry, peer_endpoint),
          server.local_description(ready.registry),
          importer,
          spawn_host(
            config.spawners,
            delegate_host.resolver(delegates),
            delegate_host.spawn_resolver(delegates),
            delegate_host.releaser(delegates),
          ),
          ledger_holdings.from_catalogue(
            ready.registry,
            executor_roster(config),
          ),
          reads,
        )
        |> result.map_error(fn(error) {
          "the orchestrator port did not start: " <> string.inspect(error)
        }),
      )
      log.info(logger, "daemon.orchestrator_port", [
        field.count(
          "orchestrators",
          list.length(roster.rows(orchestrator_roster(config))),
        ),
        field.count("spawners", list.length(config.spawners)),
      ])
      Ok(Nil)
    }
  }
}

// The report this daemon gives of itself, to a peer that asks and to its own
// `deployment.status`. Each source is a function the daemon holds and
// `node_facts.report` calls under one deadline: the executor host's own account,
// the registry and the movers for the orchestrator facts, and the directory
// member for the cluster view. The start time is taken here, which is when the
// daemon begins to answer, and uptime is the difference of two readings of this
// node's clock.
fn node_reads(
  config: Config,
  daemon: root.Root(instance),
  executor: Option(ExecutorHost),
  movers: session_movers.Control,
) -> Result(orchestrator_port.Reads, String) {
  use ready <- result.map(root.ready(daemon, within: 20_000))
  let local = atom.to_string(node.name(node.self()))
  let identity = build_identity.current()
  let version = identity.version
  let commit = identity.commit
  let epoch = ready.epoch
  let registry = ready.registry
  let started_ms = ffi_os.system_time_ms()
  orchestrator_port.Reads(report: fn() {
    node_facts.report(
      node_facts.Sources(
        node: local,
        build_version: version,
        build_commit: commit,
        epoch:,
        started_ms:,
        now_ms: ffi_os.system_time_ms,
        peers: fn() { listed_nodes(config) },
        orchestrator: fn() {
          orchestrator_facts(config, registry, local, movers)
        },
        executor: fn() {
          case executor {
            Some(hosted) -> hosted.facts()
            None -> None
          }
        },
        directory: fn() { directory_facts(config, local) },
      ),
    )
  })
}

// The nodes of the orchestrators and executors this daemon lists, once each and
// in name order. With a ledger these are the nodes it links this daemon to, so
// the list names who this daemon would dial and not only who its file pinned.
fn listed_nodes(config: Config) -> List(String) {
  list.append(
    list.map(roster.rows(orchestrator_roster(config)), fn(row) { row.node }),
    list.map(roster.rows(executor_roster(config)), fn(row) { row.node }),
  )
  |> nodes_of
}

// Each node once, in name order. A report lists at most `node_report.max_peers`
// of them, the ledger's member cap, so a list built from a roster never needs
// cutting.
fn nodes_of(nodes: List(String)) -> List(String) {
  nodes |> list.unique |> list.sort(string.compare)
}

// What this daemon says as an orchestrator. A daemon that is none (an executor
// in a ledger, or one with nothing listed) says nothing, as does one whose
// registry or catalogue would not answer: a count it could not make is left out
// and never reported as zero.
fn orchestrator_facts(
  config: Config,
  registry: manager.Manager(instance),
  local: String,
  movers: session_movers.Control,
) -> Option(node_report.OrchestratorFacts) {
  case ownership_of(config, local) {
    None -> None
    Some(_) -> {
      let listed = executor_roster(config)
      {
        use counts <- result.try(
          manager.summary(registry) |> result.replace_error(Nil),
        )
        use placements <- result.map(ledger_holdings.placements(
          registry,
          listed,
        ))
        node_report.OrchestratorFacts(
          capacity: counts.capacity,
          occupied: counts.occupied,
          resident: counts.resident,
          // An importer is always built in `start_orchestrator_port`, so every
          // daemon that reports as an orchestrator accepts moved sessions.
          imports: node_report.Receiving,
          executor_nodes: roster.rows(listed)
            |> list.map(fn(row) { row.node })
            |> nodes_of,
          placements:,
          moves: movers.moves(),
        )
      }
      |> option.from_result
    }
  }
}

/// Starts the release drainer when the configuration has a `[distribution]`
/// table, and starts nothing otherwise (protocol-change/084, phase 2).
///
/// Deleting a parent session that started subagents on another orchestrator
/// leaves one row for each orchestrator that may hold a child
/// (`client/remote_release`). The rows belong to no session, so their drainer is
/// the daemon's: a third instance of the outbox drainer, started beside the
/// orchestrator port and linked to the process that starts the daemon's
/// services. It reads the rows through the registry, tells each orchestrator,
/// and settles a row when the orchestrator answers. The registry rings it
/// when a deletion writes a row, because it sleeps while nothing is owed.
///
/// ## Examples
///
/// ```gleam
/// // assert main.start_release_drain(Config(..config, membership: None), daemon, logger) == Ok(Nil)
/// ```
@internal
pub fn start_release_drain(
  config: Config,
  daemon: root.Root(instance),
  logger: Logger,
) -> Result(Nil, String) {
  case config.membership {
    None -> Ok(Nil)
    Some(membership) -> {
      use ready <- result.try(root.ready(daemon, within: 20_000))
      use namespace <- result.try(names.start())
      let name = names.new_address(namespace)
      let options =
        peer_outbox_drain.over(
          remote_release.pass(
            fn() {
              manager.remote_releases(ready.registry)
              |> result.map_error(string.inspect)
            },
            fn(release) {
              manager.settle_remote_release(ready.registry, release)
              |> result.map_error(string.inspect)
            },
            remote_spawner.release_over(membership, orchestrator_roster(config)),
            logger,
          ),
          effects.real_timers().after,
        )
      use _started <- result.try(
        peer_outbox_drain.start(options, name)
        |> result.map_error(fn(error) {
          "the release drainer did not start: " <> string.inspect(error)
        }),
      )
      manager.on_releases_owed(ready.registry, fn() {
        peer_outbox_drain.poke(name)
      })
      log.info(logger, "daemon.release_drain", [])
      Ok(Nil)
    }
  }
}

// What a directory member says: the cluster as it sees it, and whether its own
// copy is current. The copy is confirmed by a fence and a read of this node's
// own migration marker, so a member that has lost its quorum says `Unconfirmed`
// instead of describing a cluster it can no longer vouch for.
fn directory_facts(
  config: Config,
  local: String,
) -> Option(node_report.DirectoryFacts) {
  case config.directory, config.member {
    Some(_), Some(handle) ->
      Some(
        node_facts.directory_facts(
          fn() { member.status_within(handle, node_facts.status_ms) },
          fn() { store.confirm_current(local, node_facts.confirm_ms) },
        ),
      )
    Some(_), None | None, Some(_) | None, None -> None
  }
}

/// Forwards one peer-mail command from another orchestrator to a session
/// resident here, the way the control commands reach the same session
/// (`server.peer_endpoint`): resolve the identity with the manager and call the
/// session's own endpoint. A session that is not resident but that this
/// catalogue holds and can open answers `peer_mail.not_open_reason`, which the
/// sender turns back into `NotOpen` and waits on. One this catalogue does not
/// hold, or that its owner archived, answers `peers.not_running`, a refusal,
/// because a message will never cause it to open.
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
      Error(_) ->
        case server.standing(registry, session) {
          server.Unopened | server.Handed -> Error(peer_mail.not_open_reason)
          server.Archived | server.Unheld -> Error(peers.not_running)
        }
      Ok(resident) ->
        case endpoint(resident) {
          None -> Error("peer_service_unavailable")
          Some(found) -> found.call(command) |> peer_mail.plain
        }
    }
  }
}

/// The functions the orchestrator port calls for the four subagent messages
/// (protocol-change/084). Each one judges the sender first: the node the message
/// came from must be the node of a configured `[spawners.<name>]`, or the
/// answer is `UnknownSpawner`, which is also what a daemon with no spawners
/// says to every node.
///
/// A message from a configured spawner is served by the Agency of that spawner's
/// delegate session for the parent the message names. `delegates` finds that
/// Agency, creating or opening the session as needed (`delegate_host.resolver`),
/// and a refusal it returns is the answer. The spawner's table supplies the
/// terms the Agency judges the spawn by: the tool ceiling, the depth and the
/// deadlines. A join and a run end need no terms, because they concern children
/// the Agency already holds.
///
/// A spawn is served by `spawning`, which is `delegates` plus the judgment of
/// the spawner's rolling day (`delegate_host.spawn_resolver`): a join or a run
/// end creates no child, so a day cap never refuses it.
///
/// A release is served by `releasing` and not by `delegates`: it finds the
/// session the pair already has and creates none, which `delegates` would do
/// for a pair with no row (`delegate_host.releaser`). The sender is judged the
/// same way, so a node no spawner names is refused first.
///
/// ## Examples
///
/// ```gleam
/// // main.spawn_host([], delegates, spawning, releasing).run_ended(origin, operation)
/// // -> Error(remote_spawn.UnknownSpawner(origin.node))
/// ```
@internal
pub fn spawn_host(
  configured: List(spawners.Spawner),
  delegates: fn(spawners.Spawner, remote_spawn.Parent) ->
    Result(agency.DelegateEndpoint, remote_spawn.SpawnRefusal),
  spawning: fn(spawners.Spawner, remote_spawn.Parent) ->
    Result(agency.DelegateEndpoint, remote_spawn.SpawnRefusal),
  releasing: fn(spawners.Spawner, remote_spawn.Parent) ->
    Result(Int, remote_spawn.SpawnRefusal),
) -> orchestrator_port.SpawnHost {
  let serving_by = fn(resolve, origin: remote_spawn.Origin) {
    use spawner <- result.try(
      spawners.by_node(configured, origin.node)
      |> result.replace_error(remote_spawn.UnknownSpawner(node: origin.node)),
    )
    use endpoint <- result.map(resolve(spawner, origin.parent))
    #(spawner, endpoint)
  }
  let serving = serving_by(delegates, _)
  orchestrator_port.SpawnHost(
    spawn: fn(origin, call_site, depth, parent_tools, request) {
      use #(spawner, endpoint) <- result.try(serving_by(spawning, origin))
      endpoint.spawn(
        remote_spawn.Delegation(
          parent: origin.parent,
          depth:,
          parent_tools:,
          terms: delegate_host.terms_of(spawner),
        ),
        call_site,
        request,
      )
    },
    join: fn(origin, handles, within_ms) {
      use #(_spawner, endpoint) <- result.try(serving(origin))
      endpoint.join(origin.parent, handles, within_ms)
    },
    run_ended: fn(origin, operation) {
      use #(_spawner, endpoint) <- result.try(serving(origin))
      endpoint.run_ended(operation)
    },
    release: fn(origin) {
      use spawner <- result.try(
        spawners.by_node(configured, origin.node)
        |> result.replace_error(remote_spawn.UnknownSpawner(node: origin.node)),
      )
      releasing(spawner, origin.parent)
    },
  )
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

// How one session reaches the other orchestrators it may start children on
// (protocol-change/084). A daemon with no distribution reaches none. A session
// may start a child elsewhere only while its owner holds it alone, which is the
// test default peer links already use, asked at each spawn because inviting a
// member changes the answer.
fn reach_of(
  config: Config,
  registry: manager.Manager(instance),
  session: String,
) -> Option(remote_reach.Reach) {
  case config.membership {
    None -> None
    Some(membership) ->
      Some(
        remote_spawner.over_distribution(
          membership,
          orchestrator_roster(config),
          session,
          fn() { list.contains(manager.unshared_sessions(registry), session) },
        ),
      )
  }
}

// The directory the control socket asks when its own catalogue misses. With no
// distribution there is nobody to ask and the directory answers `Unknown`.
//
// A directory member reads its copy of the owner record instead of asking its
// peers, and on an orchestrator (a daemon that places sessions on executors)
// it also carries the record writes; an executor member builds none, which is
// how it is held to never writing (protocol-change/083).
fn session_directory_of(
  config: Config,
  registry: manager.Manager(instance),
) -> session_directory.Directory {
  case config.membership {
    None -> session_directory.none()
    Some(membership) -> {
      let local = atom.to_string(node.name(node.self()))
      let base = case config.directory {
        Some(_) ->
          session_directory.khepri(
            orchestrator_roster(config),
            local,
            catalogue_holds(registry),
            store.read,
          )
        None ->
          session_directory.peers(
            orchestrator_roster(config),
            catalogue_holds(registry),
            session_directory.over_distribution(membership),
          )
      }
      let connected =
        base
        |> session_directory.with_reach(remote_peer.over_distribution(
          membership,
        ))
        |> session_directory.describing(session_directory.description_over(
          membership,
        ))
        |> session_directory.activating(session_directory.activation_over(
          membership,
        ))
        |> session_directory.settling(session_directory.settle_over(
          membership,
          orchestrator_roster(config),
        ))
      case config.directory, config.member {
        Some(_), Some(handle) ->
          session_directory.as_member(
            connected,
            ownership_of(config, local),
            fn() { member.status(handle) },
          )
        _, _ -> connected
      }
    }
  }
}

// How `deployment.status` connects to the nodes of this daemon's own
// configuration: over the distribution it started, under its own node name. A
// daemon with no `[distribution]` table has no peers to connect to.
fn deployment_reach(config: Config) -> deployment.Reach {
  let self = atom.to_string(node.name(node.self()))
  case config.membership {
    Some(membership) -> deployment.over(membership, self)
    None -> deployment.alone(self)
  }
}

// The executors this daemon uses: the `[executors.<name>]` rows of its file
// and, when it runs from a ledger, a row for each executor the ledger links it
// to (protocol-change/086, phase 2). A part of the daemon that outlives a
// request holds the roster and reads it at the moment it decides, so an
// executor enrolled or revoked while the daemon runs is seen by the next
// decision. A daemon without a ledger has the rows of its file, as before.
fn executor_roster(config: Config) -> Roster(executors.Executor) {
  case config.ledger {
    Some(handle) ->
      ledger_rows.executor_roster(
        handle.service,
        handle.local,
        config.executors,
      )
    None -> roster.fixed(config.executors)
  }
}

// The orchestrators this daemon asks and moves sessions to, combined the same
// way as the executors.
fn orchestrator_roster(config: Config) -> Roster(orchestrators.Orchestrator) {
  case config.ledger {
    Some(handle) ->
      ledger_rows.orchestrator_roster(
        handle.service,
        handle.local,
        config.orchestrators,
      )
    None -> roster.fixed(config.orchestrators)
  }
}

/// The record writes, for a member that is an orchestrator. An executor member
/// has none, which is how it is held to never writing.
///
/// A daemon with a ledger is an orchestrator when the ledger says its node is
/// one, and not when it has rows. This value is built once, when the services
/// start, and a ledger daemon's rows change while it runs: an orchestrator
/// enrolled before its first executor, or before the orchestrator beside it, has
/// no rows at boot and would hold no writes for as long as the daemon lived. Its
/// role is the one fact that does not move, because a name is enrolled once with
/// the role it keeps. A daemon with no ledger decides from the rows of its file,
/// which are fixed for its life: an executor, a pool or an orchestrator listed.
///
/// ## Examples
///
/// ```gleam
/// // main.ownership_of(config, "loom@hub.example") // -> Some(ownership)
/// ```
@internal
pub fn ownership_of(
  config: Config,
  local: String,
) -> Option(ownership.Ownership) {
  case config.ledger {
    Some(handle) ->
      case ledger_role(handle.service, local) {
        Ok(distribution_plan.Orchestrator) -> Some(ownership.over_store(local))
        Ok(distribution_plan.Executor) | Error(Nil) -> None
      }
    None ->
      case
        roster.rows(executor_roster(config)),
        config.pools,
        roster.rows(orchestrator_roster(config))
      {
        [], [], [] -> None
        _, _, _ -> Some(ownership.over_store(local))
      }
  }
}

// The role the ledger gives the node, or `Error` when the process does not
// answer or does not list the node. A daemon that cannot confirm its role holds
// no writes, as one that is not an orchestrator holds none.
fn ledger_role(
  service: Service,
  local: String,
) -> Result(distribution_plan.Role, Nil) {
  use status <- result.try(
    ledger_service.status(service, 5000) |> result.replace_error(Nil),
  )
  membership_ledger.member_at(status.ledger, local)
  |> result.map(fn(member) { member.role })
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
      let directory = session_directory_of(config, ready.registry)
      let #(authority, upkeep) = case directory.ownership {
        // The movers' periodic pass seeds the store from the catalogue until
        // it has once, then finishes the deletions left marked; on request it
        // writes the local sessions' records.
        Some(ownership) -> #(
          session_mover.Recorded(ownership:),
          session_movers.Upkeep(
            every_tick: fn() {
              let _seeded =
                migrate.seed(
                  ready.registry,
                  ownership,
                  roster.rows(orchestrator_roster(config)),
                  logger,
                )
              deletion.finish_pending(
                ready.registry,
                ready.sessions_directory,
                ownership,
              )
            },
            cover: fn() {
              migrate.cover_local(ready.registry, ownership, logger)
              |> result.replace(Nil)
            },
            release: fn(session) {
              let _released = ownership.release_local(session)
              Nil
            },
          ),
        )
        None -> #(session_mover.Rows, session_movers.no_upkeep())
      }
      let environment =
        session_mover.Environment(
          authority:,
          registry: ready.registry,
          orchestrators: orchestrator_roster(config),
          directory:,
          courier: session_directory.courier_over(membership),
          close: closer_of(config, membership),
          clock: clock.from_function(ffi_os.system_time_ms),
          node: atom.to_string(node.name(node.self())),
          budget: session_mover.default_budget(),
          after: crash_after_step(),
          logger:,
        )
      use control <- result.try(session_movers.start_with(
        environment,
        session_movers.retry_ms,
        session_directory.over_distribution(membership),
        session_movers.give_up_after_ms,
        upkeep,
      ))
      use resumed <- result.try(session_movers.resume(control, ready.registry))
      log.info(logger, "daemon.movers", [
        field.count("resumed", resumed),
        field.count(
          "orchestrators",
          list.length(roster.rows(orchestrator_roster(config))),
        ),
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
  let configured = executor_roster(config)
  fn(executor, session, workspace_name, incarnation) {
    case workspace.reach(Some(membership), roster.rows(configured), executor) {
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
  use directory <- result.try(
    directory_settings.from_document(document)
    |> result.map_error(fn(reason) { configuration <> ": " <> reason }),
  )
  case directory {
    Some(found) ->
      case directory_settings.even(found) {
        True ->
          log.warn(logger, "daemon.directory_even_members", [
            field.count("members", list.length(found.members)),
          ])
        False -> Nil
      }
    None -> Nil
  }
  use spawners <- result.try(
    spawners.from_document(document)
    |> result.map_error(fn(reason) { configuration <> ": " <> reason }),
  )
  use booted <- result.try(start_distribution(
    document,
    configuration,
    directory_settings.cluster(directory),
    logger,
  ))
  use ledger <- result.try(ledger_handle(booted, configuration))
  use directory <- result.try(
    ledger_directory(
      directory,
      option.then(booted, fn(started) { started.ledger }),
      atom.to_string(node.name(node.self())),
      orchestrators,
      logger,
    )
    |> result.map_error(fn(reason) { configuration <> ": " <> reason }),
  )
  use Nil <- result.try(
    audit_started(
      booted,
      document,
      reference_rows(executors, orchestrators, spawners),
      list.map(executors, fn(row) { row.name }),
      reference_names(pools, spawners),
      logger,
    )
    |> result.map_error(fn(reason) { configuration <> ": " <> reason }),
  )
  let config =
    Config(
      ..config,
      view:,
      peer_policy:,
      executors:,
      pools:,
      workspaces:,
      orchestrators:,
      directory:,
      spawners:,
      membership: option.map(booted, fn(started) { started.membership }),
      ledger:,
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
        use tick <- result.try(
          deadline_tick_of(directory, registration.id)
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
            remote_reach: reach_of(config, directory, registration.id),
            deadline_tick_ms: tick,
            metering: metering_of(
              directory,
              config.spawners,
              registration.id,
              logger,
            ),
          )
        let settings =
          serve.Settings(
            ..settings,
            first_prompt: Some(fn(text) {
              manager.seed_subtitle(directory, registration.id, text)
            }),
            profile_desk: Some(profile_desk(
              directory,
              registration,
              profiles.effective(registration.configuration, configuration),
              logger,
            )),
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
              workspace.fixed(
                config.membership,
                roster.rows(executor_roster(config)),
                name,
                chosen,
              ),
            )
          _, pool ->
            serve.assemble_registered(
              settings,
              identity,
              logger,
              owner,
              Some(services),
              workspace.pooled(
                config.membership,
                roster.rows(executor_roster(config)),
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

/// How often a session's Agency reaps overdue children on its own, or `None`.
///
/// Only a delegate session has a tick: its children belong to a spawner that
/// may never come back to wait on them, so the session enforces the deadline
/// itself (protocol-change/084). A marker that cannot be read is an error and
/// not "no tick", as it is for the catalogue and for moves: the session would
/// otherwise open as an ordinary one and its children would outlive their
/// deadlines. The caller refuses the open.
///
/// ## Examples
///
/// ```gleam
/// // main.deadline_tick_of(registry, delegate_session_id) == Ok(Some(15_000))
/// ```
@internal
pub fn deadline_tick_of(
  registry: manager.Manager(instance),
  id: String,
) -> Result(Option(Int), String) {
  case manager.delegate_of(registry, id) {
    Ok(Some(_delegate)) -> Ok(Some(agency.delegate_deadline_tick_ms))
    Ok(None) -> Ok(None)
    Error(_) -> Error("the session's delegate marker could not be read")
  }
}

/// What a delegate session reports about its children's spend, or `None`.
///
/// Only the delegate session of a spawner whose table is still configured and
/// sets a metering key has one. The day's tokens are recorded only when
/// `token_budget_per_day` is set, since nothing else reads them, and the child's
/// budget travels as it is. The recorder runs on the process the usage hook
/// spawns (`agency.metering_hooks`), so a registry that cannot be reached costs
/// that process a warning and the day a few uncounted tokens, never a stalled
/// child.
///
/// ## Examples
///
/// ```gleam
/// // main.metering_of(registry, [], delegate_session_id, logger) == None
/// ```
@internal
pub fn metering_of(
  registry: manager.Manager(instance),
  configured: List(spawners.Spawner),
  id: String,
  logger: Logger,
) -> Option(agency.Metering) {
  case manager.delegate_of(registry, id) {
    Ok(Some(marker)) ->
      case spawners.find(configured, marker.spawner) {
        Ok(spawner) ->
          case spawners.metered(spawner) {
            True ->
              Some(agency.Metering(
                spend: spend_recorder(registry, spawner, logger),
                child_budget: spawner.child_token_budget,
              ))
            False -> None
          }
        Error(Nil) -> None
      }
    Ok(None) -> None
    Error(_) -> None
  }
}

// The function that adds a child's tokens to the spawner's day, or one that does
// nothing when the spawner sets no day budget.
fn spend_recorder(
  registry: manager.Manager(instance),
  spawner: spawners.Spawner,
  logger: Logger,
) -> fn(Int) -> Nil {
  case spawner.token_budget_per_day {
    None -> fn(_tokens) { Nil }
    Some(_budget) -> fn(tokens) {
      case
        manager.add_spend(
          registry,
          spawner.name,
          now_ms: ffi_os.system_time_ms(),
          tokens:,
        )
      {
        Ok(Nil) -> Nil
        Error(_) ->
          log.warn(logger, "daemon.spawner_spend_lost", [
            field.text("spawner", spawner.name),
            field.count("tokens", tokens),
          ])
      }
    }
  }
}

/// Sweeps the delegate sessions once (protocol-change/084): deletes those that
/// are due and closes the resident ones that are idle.
///
/// At boot this runs before the orchestrator port starts, so no message from a
/// spawner can touch a session while it is being judged. Nothing is resident
/// yet, and a delegate session is not reopened at boot, so every session older
/// than its spawner's `retain_s` holds no child that can still run: the decoder
/// keeps `retain_s` at or above `max_within_s`. A session whose spawner's table
/// has since been removed is deleted whatever its age, because nothing can send
/// it a message again. Later, the hourly sweep (`start_delegate_sweep`) runs the
/// same pass over a registry with sessions resident, and closes a resident
/// session with no child that has a run and no message for `idle_close_s`, so
/// that it gives its executor scope back. A sweep that fails is logged and does
/// not stop the daemon, because the sessions it would have swept are only idle
/// and the next sweep tries again.
///
/// ## Examples
///
/// ```gleam
/// // main.sweep_delegate_sessions(config, daemon, logger, ffi_os.system_time_ms())
/// ```
@internal
pub fn sweep_delegate_sessions(
  config: Config,
  daemon: root.Root(serve.Resident),
  logger: Logger,
  now_ms: Int,
) -> Result(Nil, String) {
  use ready <- result.map(root.ready(daemon, within: 20_000))
  let sweep =
    manager.Sweep(
      standing: spawners.standing(config.spawners, _),
      activity: fn(resident: serve.Resident) {
        case resident.spawns.occupancy() {
          agency.Vacant -> manager.Quiet
          agency.Occupied -> manager.Busy
        }
      },
    )
  case
    manager.sweep_delegates(
      ready.registry,
      sweep,
      now_ms,
      ready.sessions_directory,
    )
  {
    Ok(manager.Swept(deleted:, closed:)) ->
      log.info(logger, "daemon.delegate_sweep", [
        field.count("deleted", deleted),
        field.count("closed", closed),
      ])
    Error(_) -> log.warn(logger, "daemon.delegate_sweep_failed", [])
  }
}

/// How often the daemon sweeps its delegate sessions, in milliseconds: one hour.
/// The sweep frees an executor scope an hour after a session went idle, so a
/// finer period would only read the catalogue more often.
pub const delegate_sweep_every_ms = 3_600_000

/// Starts the actor that sweeps the delegate sessions every
/// `delegate_sweep_every_ms` (protocol-change/084).
///
/// A resident delegate session never hibernates, because its 15 s deadline tick
/// is shorter than the hibernation delay, so without this sweep an idle one
/// holds one of its executor's sixteen scopes until the daemon next restarts.
/// The actor is linked to the process that starts the daemon's services and
/// carries nothing but the configuration: each fire reads the registry and the
/// clock afresh through `sweep_delegate_sessions`. The period is a weft
/// periodic, which arms the next fire after the handler returns, so a slow
/// sweep delays the next one and never queues a backlog.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = main.start_delegate_sweep(config, daemon, logger)
/// ```
@internal
pub fn start_delegate_sweep(
  config: Config,
  daemon: root.Root(serve.Resident),
  logger: Logger,
) -> Result(Nil, String) {
  actor.new_with_initialiser(1000, fn(inbox) {
    actor.initialised(Nil) |> actor.returning(inbox) |> Ok
  })
  |> actor.on_message(fn(state, _tick: SweepTick) {
    let _swept =
      sweep_delegate_sessions(config, daemon, logger, ffi_os.system_time_ms())
    actor.continue(state)
  })
  |> actor.periodic(every: delegate_sweep_every_ms, sending: SweepTick)
  |> actor.start
  |> result.replace(Nil)
  |> result.replace_error("the delegate sweep did not start")
}

/// The one message of the delegate sweep's actor: the hour has passed.
pub type SweepTick {
  SweepTick
}

// What a session's hub needs to read and switch its own model profile
// (protocol-change/082). Every closure runs in the hub's process, over the
// registry handle the builder was given, so none of them holds a credential:
// the hub has already judged who may switch (the owner), and what it asks of
// the daemon is the registry's write and a restart of this very session.
//
// `configuration` is the file this session loads, resolved the way creation
// resolved it (`profiles.effective`), so the names the hub offers are the names
// its own open will accept. The restart runs in a process the session does not
// own (`restart.begin`), and a failure of either step is logged and leaves the
// profile saved for the next open.
fn profile_desk(
  registry: manager.Manager(serve.Resident),
  registration: catalogue.Registration,
  configuration: String,
  logger: Logger,
) -> profile_switch.Desk {
  let id = registration.id
  profile_switch.Desk(
    current: registration.profile,
    names: fn() { profiles.names(configuration) },
    load: fn(profile) {
      profiles.load(configuration, profile)
      |> result.map_error(profiles.refusal_message)
    },
    save: fn(profile) {
      manager.set_profile(registry, id, profile)
      |> result.replace_error("the session catalogue refused the write")
    },
    restart: fn() {
      restart.begin(registry, id, fn(failure) {
        log.warn(logger, "daemon.profile_restart_failed", [
          field.ident("session", id),
          field.text("stage", case failure {
            restart.NotStopped -> "stop"
            restart.NotReopened -> "reopen"
          }),
        ])
      })
    },
  )
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
    orchestrator_port.unreported(),
  )
}

/// Starts the daemon listener as `listen_serving` does, with the control its
/// owner commands use to hand sessions to other orchestrators, which
/// `start_movers` builds, and the reads that report on the daemon itself, which
/// `node_reads` builds. `deployment.status` states the daemon's own facts through
/// the same closure the orchestrator port answers a peer with.
///
/// ## Examples
///
/// ```gleam
/// // main.listen_moving(config, daemon, upgrade, peers, Some(ui), movers, reads)
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
  reads: orchestrator_port.Reads,
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
      executors: executor_roster(config),
      pools: config.pools,
      directory: session_directory_of(config, ready.registry),
      movers:,
      deployment: deployment.reporting(deployment_reach(config), reads.report),
      ledger: config.ledger,
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
      use member <- result.try(start_directory(config, logger))
      let config = Config(..config, member:)
      use executor <- result.try(start_executor(config, logger))
      use Nil <- result.try(sweep_delegate_sessions(
        config,
        daemon,
        logger,
        ffi_os.system_time_ms(),
      ))
      use movers <- result.try(start_movers(config, daemon, logger))
      use reads <- result.try(node_reads(config, daemon, executor, movers))
      use Nil <- result.try(start_orchestrator_port(
        config,
        daemon,
        logger,
        fn(resident: serve.Resident) { Some(resident.peer) },
        fn(resident: serve.Resident) { resident.spawns },
        reads,
      ))
      use Nil <- result.try(start_release_drain(config, daemon, logger))
      use Nil <- result.try(start_delegate_sweep(config, daemon, logger))
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
        reads,
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

fn wait(
  daemon: root.Root(instance),
  watch: process.Monitor,
  executor: Option(ExecutorHost),
  signals: process.Subject(host.Stop),
  logger: Logger,
) {
  let selector =
    process.new_selector()
    |> process.select_map(signals, Signal)
    |> process.select_specific_monitor(watch, fn(down) { RootGone(down.reason) })
  let selector = case executor {
    Some(hosted) ->
      process.select_specific_monitor(selector, hosted.monitor, fn(down) {
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
      server.local_peer(registry, fn(resident) { Ok(endpoint(resident)) }),
      sessions,
    ),
    describe: peers.described(server.local_description(registry), sessions),
  )
}
