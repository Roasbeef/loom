//// The binary's single-daemon entrypoint, independent of any conversation.
////
//// Startup acquires one private catalogue and credential, restores metadata,
//// and binds one v2 listener. Provider configuration and session resources are
//// resolved only inside an explicitly admitted session builder. The root handle
//// survives readiness failures so bounded shutdown can report uncertainty.

import argv
import client/daemon/listener
import client/daemon/manager
import client/daemon/root
import client/daemon/server
import client/daemon/session_socket
import client/host
import client/internal/ffi_os
import client/serve
import core/clock
import core/ids
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import host/bootstrap
import host/endpoint
import mist
import telemetry/field
import telemetry/handler
import telemetry/log.{type Logger}
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
  )
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
}

// These stages bound the diagnostic vocabulary without exposing configuration
// paths or provider data carried by the original error.
type StartStage {
  SettingsResolution
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
      prepare(config, logger)
      |> result.map(fn(daemon) { #(config, paths, fence, daemon) })
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
  let initial = Config("", "127.0.0.1", 0, 8, "Owner", [])
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
) -> Result(root.Root(serve.Instance), String) {
  root.start(
    root.Config(config.state_root, config.owner_display_name, config.capacity),
    manager.Assembly(
      domain_build: fn(selected, sources, owner) {
        serve.build_domain(selected, sources, logger, owner)
      },
      build: fn(registration, selected, services, owner) {
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
        serve.assemble_in_domain(settings, identity, logger, owner, services)
        |> diagnose_start(logger, identity, RuntimeAssembly)
      },
      fatal: serve.instance_children,
    ),
  )
}

// A failed builder can retire before the control client reads its operation.
// Record the classified cause here, while it still exists, rather than keeping
// failed instances alive for diagnostics. The caller receives the same error;
// only fixed labels and a validated session identity enter the log.
fn diagnose_start(
  outcome: Result(value, String),
  logger: Logger,
  identity: ids.SessionId,
  stage: StartStage,
) -> Result(value, String) {
  outcome
  |> result.map_error(fn(reason) {
    let #(stage_name, class) = start_class(stage, reason)
    log.error(logger, "daemon.session_start_failed", [
      field.ident("session", ids.session_id_to_string(identity)),
      field.text("stage", stage_name),
      field.text("class", class),
    ])
    reason
  })
}

// Prefixes recognize errors from the existing resolver and assembly boundary.
// An unknown error stays useful as a stage-specific class, never as raw text.
fn start_class(stage: StartStage, reason: String) -> #(String, String) {
  case stage {
    SettingsResolution -> {
      let class = case
        string.starts_with(reason, "no loom-exec sandbox helper found.")
        || string.starts_with(reason, "the helper binary does not exist: ")
      {
        True -> "helper_unavailable"
        False -> "settings_rejected"
      }
      #("settings_resolution", class)
    }
    RuntimeAssembly -> {
      let class = case reason {
        "the session base policy is not one the sandbox can enforce: " <> _ ->
          "policy_rejected"
        "the session did not open (held lease? bad path?): " <> _ ->
          "storage_open_failed"
        _ -> "assembly_failed"
      }
      #("runtime_assembly", class)
    }
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
  use ready <- result.try(root.ready(daemon, within: 20_000))
  use domain_configuration <- result.try(captured_domain_configuration(
    config.session_defaults,
    "",
  ))
  let routing =
    server.Config(
      daemon:,
      domain_configuration:,
      generator: fn() {
        ids.generator(
          clock.from_function(ffi_os.system_time_ms),
          ffi_os.unique_positive_integer(),
        )
      },
      session_upgrade: upgrade,
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
  daemon: root.Root(serve.Instance),
  logger: Logger,
) -> Nil {
  let watch = process.monitor(root.pid(daemon))
  let signals = process.new_subject()
  host.relay_sigterm(signals, ffi_os.wait_for_sigterm)
  case
    listen(config, daemon, fn(request, attachment) {
      session_socket.upgrade(
        daemon,
        request,
        attachment,
        attachment.instance.gateway,
      )
    })
    |> result.try(fn(serving) {
      publish_endpoint(config, serving, paths, fence)
      |> result.replace(serving)
    })
  {
    Error(reason) -> {
      log.error(logger, "daemon.start_failed", [field.text("reason", reason)])
      let outcome = root.shutdown(daemon, within: 30_000)
      report_shutdown(logger, outcome)
      ffi_os.halt(1)
    }
    Ok(serving) -> {
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
      log.info(logger, "daemon.listening", [
        field.count("port", serving.listener.port),
      ])
      wait(daemon, watch, signals, logger)
    }
  }
}

fn wait(daemon, watch, signals, logger) {
  let event =
    process.new_selector()
    |> process.select_map(signals, Signal)
    |> process.select_specific_monitor(watch, fn(down) { RootGone(down.reason) })
    |> process.selector_receive_forever
  case event {
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
