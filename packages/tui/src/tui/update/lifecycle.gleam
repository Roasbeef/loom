//// Updating a running daemon is an authenticated lifecycle operation. The
//// original PID and birth identity remain the retirement witness even when
//// control sockets close or another launcher publishes a newer endpoint.

import gleam/bool
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import host/bootstrap as host
import host/endpoint
import host/launch_metadata
import tui/bootstrap
import tui/daemon
import tui/daemon/bootstrap as discovery
import tui/daemon/protocol
import tui/view_link
import weft/poll

/// Captures the current daemon without starting one or selecting a session.
///
/// ## Examples
///
/// ```gleam
/// // lifecycle.capture(paths)
/// ```
pub fn capture(
  paths: endpoint.Paths,
) -> Result(Option(discovery.Connected), String) {
  use available <- result.try(endpoint.availability(paths))

  // Check whether the control endpoint is currently occupied.
  case available {
    endpoint.Vacant -> Ok(None)
    endpoint.Occupied(record) ->
      discovery.probe(paths, record, process.self(), 5000)
      |> result.map(Some)
  }
}

/// Validates the original launch before publication or retirement.
///
/// The metadata describes a launch but never grants authority. Its identity
/// must match the already authenticated endpoint before invoking the staged
/// server with literal paths and a sanitized child environment.
///
/// ## Examples
///
/// ```gleam
/// // lifecycle.prepare(previous, "", staged_server)
/// ```
pub fn prepare(
  previous: Option(discovery.Connected),
  explicit_config: String,
  staged_server: String,
) -> Result(Option(launch_metadata.Record), String) {
  // A vacant endpoint retains the ordinary cold-start path.
  case previous {
    None -> Ok(None)
    Some(connected) -> {
      use metadata <- result.try(matching_metadata(connected))
      use Nil <- result.try(check_config(explicit_config, metadata.config))
      use env <- result.try(host.find_executable("env"))
      let arguments =
        list.append(environment(metadata.mode), [
          staged_server,
          "__launch_preflight",
          ..preflight_arguments(metadata)
        ])
      use outcome <- result.try(view_link.launch_within(env, arguments, 30_000))

      // A timeout or nonzero exit leaves the original daemon untouched.
      case outcome {
        view_link.Exited(0) -> Ok(Some(metadata))
        view_link.Exited(_) -> Error("staged daemon launch preflight failed")
        view_link.StillRunning ->
          Error("staged daemon launch preflight timed out")
      }
    }
  }
}

/// Matches the private facts to the authenticated native incarnation.
fn matching_metadata(connected: discovery.Connected) {
  use loaded <- result.try(launch_metadata.load(connected.paths))

  // Absence cannot establish the original launch mode.
  use metadata <- result.try(case loaded {
    None ->
      Error(
        "daemon launch metadata is missing; restart with the original setup before updating",
      )
    Some(record) -> Ok(record)
  })

  // The authenticated ready epoch and full native fence must both match.
  use <- bool.guard(
    !matches(connected.record, metadata),
    Error("daemon launch metadata does not match the authenticated endpoint"),
  )
  Ok(metadata)
}

/// Tests the complete endpoint fence and ready epoch against launch facts.
///
/// The caller must separately authenticate the endpoint; this comparison is
/// only a consistency check and does not confer replacement authority.
///
/// ## Examples
///
/// ```gleam
/// // lifecycle.matches(ready, metadata)
/// ```
@internal
pub fn matches(
  record: endpoint.Endpoint,
  metadata: launch_metadata.Record,
) -> Bool {
  case record {
    endpoint.Ready(fence, _, _, epoch, _) ->
      fence == metadata.fence && epoch == metadata.epoch
    endpoint.Starting(_) -> False
  }
}

/// An explicit updater choice cannot replace the original configuration.
fn check_config(explicit: String, original: Option(String)) {
  // Only the captured source may be used for a live replacement.
  case explicit, original {
    "", _ -> Ok(Nil)
    _, None ->
      Error(
        "updater configuration differs from the original daemon configuration",
      )
    path, Some(expected) -> {
      use actual <- result.try(host.canonical_path(path))
      use <- bool.guard(
        actual != expected,
        Error(
          "updater configuration differs from the original daemon configuration",
        ),
      )
      Ok(Nil)
    }
  }
}

/// Builds env's literal arguments without mutating the terminal environment.
///
/// ## Examples
///
/// ```gleam
/// // lifecycle.environment(launch_metadata.LocalOnly)
/// ```
@internal
pub fn environment(mode: launch_metadata.Mode) -> List(String) {
  let cleared = [
    "-u", "ERL_FLAGS", "-u", "ERL_AFLAGS", "-u", "ERL_ZFLAGS", "-u",
    "ERL_EPMD_PORT", "-u", "ERL_EPMD_ADDRESS", "-u", "LOOM_DISTRIBUTION_OPTFILE",
    "-u", "LOOM_DEBUG_ARGS_FILE",
  ]

  // TLS restores the original options after clearing inherited VM flags.
  case mode {
    launch_metadata.LocalOnly -> cleared
    launch_metadata.Tls(options:) ->
      list.append(cleared, ["LOOM_DISTRIBUTION_OPTFILE=" <> options])
  }
}

/// Selects the exact source and mode for the staged server's check.
fn preflight_arguments(metadata: launch_metadata.Record) {
  // The mode selects the staged server validation branch.
  let mode = case metadata.mode {
    launch_metadata.LocalOnly -> "local"
    launch_metadata.Tls(_) -> "tls"
  }

  // An absent source stays absent rather than acquiring a default.
  case metadata.config {
    None -> [mode]
    Some(path) -> [mode, path]
  }
}

/// Retires the captured daemon and verifies the replacement's build identity.
///
/// A lost shutdown reply is inconclusive: the old daemon may have closed the
/// socket while completing shutdown. Only observing its native retirement
/// permits progress. Expiry leaves the installed trees intact and reports
/// that no replacement was started; the updater never escalates to SIGKILL.
///
/// ## Examples
///
/// ```gleam
/// // lifecycle.restart(previous, options, settings, expected_commit)
/// ```
pub fn restart(
  previous: Option(discovery.Connected),
  options: bootstrap.Options,
  settings: Option(launch_metadata.Record),
  expected_commit: String,
) -> Result(Nil, String) {
  let retired = retire(previous, settings)

  // A failed retirement must release the original control connection.
  case retired {
    Ok(Nil) -> Nil
    Error(_) ->
      case previous {
        None -> Nil
        Some(connected) -> daemon.close(connected.control)
      }
  }

  use Nil <- result.try(retired)
  use connected <- result.try(reconnect(previous, options, settings))
  let hello = daemon.hello(connected.control)
  let identity = hello.build
  let protocol.Epoch(epoch) = hello.epoch
  daemon.close(connected.control)

  // A replacement cannot claim the previous incarnation.
  let same_epoch = case settings {
    None -> False
    Some(metadata) -> epoch == metadata.epoch
  }

  use <- bool.guard(
    same_epoch,
    Error("replacement daemon retained the previous epoch"),
  )

  // Verify daemon reports expected build commit.
  case identity {
    Some(protocol.Build(_, commit)) if commit == expected_commit -> Ok(Nil)
    Some(_) ->
      Error(
        "installed release, but the accepting daemon reports a different commit",
      )
    None ->
      Error(
        "installed release, but the accepting daemon reports no build identity",
      )
  }
}

/// Reauthenticates the same endpoint immediately before shutdown.
fn retire(
  previous: Option(discovery.Connected),
  settings: Option(launch_metadata.Record),
) {
  // Retirement requires the captured connection and its validated facts.
  case previous, settings {
    None, None -> Ok(Nil)
    Some(connected), Some(expected) -> {
      use available <- result.try(endpoint.availability(connected.paths))

      // A new endpoint cannot inherit the captured shutdown authority.
      use record <- result.try(case available {
        endpoint.Occupied(record) if record == connected.record -> Ok(record)
        endpoint.Occupied(_) | endpoint.Vacant ->
          Error("daemon endpoint changed before shutdown")
      })

      use fresh <- result.try(discovery.probe(
        connected.paths,
        record,
        process.self(),
        5000,
      ))
      let current = matching_metadata(fresh)

      // Only unchanged facts permit shutdown on the fresh authenticated socket.
      case current {
        Ok(actual) if actual == expected -> {
          let _reply = daemon.request(fresh.control, protocol.Shutdown, 5000)
          daemon.close(fresh.control)
          daemon.close(connected.control)
          await_retirement(record.fence)
        }
        Ok(_) | Error(_) -> {
          daemon.close(fresh.control)
          Error("daemon launch metadata changed before shutdown")
        }
      }
    }
    None, Some(_) | Some(_), None ->
      Error("daemon launch state changed before shutdown")
  }
}

/// Starts the replacement with the checked source and child environment.
fn reconnect(
  previous: Option(discovery.Connected),
  options: bootstrap.Options,
  settings: Option(launch_metadata.Record),
) {
  // Cold starts retain discovery; replacements use the captured launch.
  case previous, settings {
    None, None -> bootstrap.reconnect_daemon(options, process.self(), 30_000)
    Some(connected), Some(metadata) -> {
      use server <- result.try(bootstrap.server_executable(options.server))
      use env <- result.try(host.find_executable("env"))

      let args =
        replacement_arguments(connected.paths.root, server, metadata.config)
      let args = list.append(environment(metadata.mode), [server, ..args])
      discovery.reconnect(
        connected.paths,
        process.self(),
        fn() { Ok(discovery.Launch(env, args)) },
        30_000,
      )
    }
    None, Some(_) | Some(_), None ->
      Error("daemon launch state changed before replacement")
  }
}

/// Builds replacement arguments while preserving an absent configuration.
///
/// An explicit empty argument prevents the shipped wrapper from selecting the
/// state-root default before the daemon observes the same absence.
///
/// ## Examples
///
/// ```gleam
/// // lifecycle.replacement_arguments("/state", "/bin/loomd", None)
/// ```
@internal
pub fn replacement_arguments(
  state: String,
  server: String,
  config: Option(String),
) -> List(String) {
  // A present source uses the existing daemon argument construction.
  case config {
    Some(path) -> bootstrap.daemon_launch_arguments(state, server, path)
    None ->
      bootstrap.daemon_launch_arguments(state, server, "")
      |> list.append(["--config", ""])
  }
}

/// Polls until the previous daemon fence is removed or the timeout expires.
fn await_retirement(fence) {
  case
    poll.until(within: 90_000, every: 50, attempt: fn() {
      case endpoint.is_present(fence) {
        Ok(False) -> poll.Done(Nil)
        Ok(True) -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })
  {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(reason) ->
      Error("cannot verify old daemon retirement: " <> reason)
    poll.Expired ->
      Error(
        "release installed; old daemon has not retired after 90 seconds; no replacement started",
      )
  }
}
