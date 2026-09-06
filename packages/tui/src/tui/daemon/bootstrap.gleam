//// Shared-daemon discovery without selecting or opening a conversation.
////
//// The native birth fence, not a failed connection, authorizes replacement.
//// Startup holds launch.lock only through paused-child publication and release;
//// the child reacquires that lock before adopting the reservation. Waiting for
//// readiness while retaining the launch lock would deadlock parent and child.
//// The returned control connection belongs to the terminal PID throughout its
//// handshake, even when this function runs in a short-lived bootstrap worker.

import gleam/bit_array
import gleam/bool
import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap as host
import host/endpoint
import tui/daemon
import tui/daemon/protocol
import weft/poll

/// Trusted executable and arguments resolved outside the workspace.
pub type Launch {
  Launch(
    /// An absolute executable selected by the installed discovery ladder.
    executable: String,
    /// Only global daemon flags; no session database or workspace token.
    arguments: List(String),
  )
}

/// An authenticated daemon connection, independent of the selected workspace.
pub type Connected {
  Connected(
    /// The terminal-owned control connection; no session was opened.
    control: daemon.Connection,
    /// Shared fixed paths, including the private stable owner credential.
    paths: endpoint.Paths,
    /// Native identity and exact epoch authenticated by this connection.
    record: endpoint.Endpoint,
  )
}

type Reservation {
  Reservation(record: endpoint.Endpoint, child: Option(host.ServerProcess))
}

/// Resolves one shared daemon without mutating its session catalogue.
///
/// The launch callback runs only after the locked check proves replacement is
/// permitted. Existing live daemons do not require a discoverable executable
/// or a readable model configuration in this terminal's environment.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.resolve(paths, terminal_pid, fn() { Ok(launch) }, 30_000)
/// ```
pub fn resolve(
  paths: endpoint.Paths,
  owner: process.Pid,
  launch: fn() -> Result(Launch, String),
  within_ms: Int,
) -> Result(Connected, String) {
  case within_ms > 0 && within_ms <= 90_000 {
    False -> Error("daemon startup budget must be between 1 and 90000 ms")
    True ->
      resolve_bounded(
        paths,
        owner,
        launch,
        host.monotonic_time_ms() + within_ms,
      )
  }
}

fn resolve_bounded(paths, owner, launch, deadline) {
  use lock <- result.try(acquire_lock(paths, deadline))
  let reserved = reserve(paths, launch, deadline)
  host.release_launch_lock(lock)
  use reservation <- result.try(reserved)

  // A started native daemon is independent after release. Closing our wrapper
  // port drops only this bootstrap handle; it is not retirement evidence and
  // never permits erasing or replacing the published native fence.
  let outcome = await_ready(paths, reservation.record.fence, owner, deadline)
  case reservation.child {
    None -> Nil
    Some(child) -> host.close_server_process(child)
  }
  outcome
}

fn acquire_lock(paths: endpoint.Paths, deadline: Int) {
  case
    poll.until(
      within: int.max(0, deadline - host.monotonic_time_ms()),
      every: 25,
      attempt: fn() {
        case host.try_launch_lock(paths.launch_lock) {
          Ok(lock) -> poll.Done(lock)
          Error("busy") -> poll.Retry
          Error(reason) -> poll.Fail(reason)
        }
      },
    )
  {
    poll.Answered(lock) -> Ok(lock)
    poll.Failed(reason) -> Error("daemon launch lock: " <> reason)
    poll.Expired -> Error("timed out acquiring daemon launch lock")
  }
}

fn reserve(
  paths: endpoint.Paths,
  launch: fn() -> Result(Launch, String),
  deadline: Int,
) {
  use <- bool.guard(
    host.monotonic_time_ms() >= deadline,
    Error("daemon startup deadline expired before native launch"),
  )
  use available <- result.try(endpoint.availability(paths))
  case available {
    endpoint.Occupied(record) -> Ok(Reservation(record, None))
    endpoint.Vacant -> {
      use launch <- result.try(launch())
      use <- bool.guard(
        host.monotonic_time_ms() >= deadline,
        Error("daemon startup deadline expired during executable discovery"),
      )
      use #(child, pid) <- result.try(host.spawn_server(
        launch.executable,
        launch.arguments,
        paths.root,
        paths.log,
      ))
      let reserved = publish_and_release(paths, child, pid, deadline)
      case reserved {
        Ok(record) -> Ok(Reservation(record, Some(child)))
        Error(reason) -> {
          host.close_server_process(child)
          Error(reason)
        }
      }
    }
  }
}

fn publish_and_release(paths, child, pid, deadline) {
  use fence <- result.try(endpoint.observe(pid))
  let record = endpoint.Starting(fence)
  use Nil <- result.try(endpoint.write(paths, record))

  // An expired caller cannot release new native effects after its budget.
  // The paused child's port is closed by reserve on this error path.
  use <- bool.guard(
    host.monotonic_time_ms() >= deadline,
    Error("daemon startup deadline expired before child release"),
  )
  use Nil <- result.try(host.release_server_process(child))
  Ok(record)
}

fn await_ready(paths, fence, owner, deadline) {
  let outcome =
    poll.until(
      within: int.max(0, deadline - host.monotonic_time_ms()),
      every: 25,
      attempt: fn() {
        case readiness(paths, fence) {
          Error(reason) -> poll.Fail(reason)
          Ok(endpoint.Starting(_)) -> poll.Retry
          Ok(record) -> poll.Done(record)
        }
      },
    )
  use record <- result.try(case outcome {
    poll.Answered(record) -> Ok(record)
    poll.Failed(reason) -> Error(reason)
    poll.Expired ->
      Error(
        "daemon VM is still alive or unconfirmed but did not publish readiness; its endpoint was preserved",
      )
  })
  probe(paths, record, owner, deadline - host.monotonic_time_ms())
}

fn readiness(paths, fence) {
  use current <- result.try(endpoint.load(paths))
  use record <- result.try(case current {
    Some(record) if record.fence == fence -> Ok(record)
    _ -> Error("daemon endpoint changed while waiting for readiness")
  })
  use present <- result.try(endpoint.is_present(fence))
  case present {
    True -> Ok(record)
    False -> Error("daemon VM exited before authenticated readiness")
  }
}

/// Authenticates an already published endpoint without permitting replacement.
///
/// This is also the explicit test seam for epoch and native-fence validation.
/// Neither a transport error nor a mismatched hello starts another daemon.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.probe(paths, ready_record, terminal_pid, 1000)
/// ```
@internal
pub fn probe(
  paths: endpoint.Paths,
  record: endpoint.Endpoint,
  owner: process.Pid,
  within_ms: Int,
) -> Result(Connected, String) {
  use address <- result.try(endpoint.address(record))
  use token <- result.try(read_token(paths.token))
  use control <- result.try(
    daemon.connect(address, token, owner, within_ms)
    |> result.replace_error(
      "recorded daemon VM did not complete authenticated v2 control hello; endpoint preserved, no replacement started",
    ),
  )
  let protocol.Epoch(actual_epoch) = daemon.hello(control).epoch
  case record {
    endpoint.Ready(_, _, _, epoch) if epoch == actual_epoch ->
      Ok(Connected(control, paths, record))
    _ -> {
      daemon.close(control)
      Error(
        "authenticated daemon epoch differs from its endpoint; endpoint preserved",
      )
    }
  }
}

fn read_token(path) {
  use bytes <- result.try(host.read_private_bounded(path, 65))
  use value <- result.try(
    bit_array.to_string(bytes)
    |> result.replace_error("owner credential is not UTF-8"),
  )
  let value = string.trim(value)
  case string.byte_size(value) == 64 {
    False -> Error("owner credential is not a 256-bit token")
    True -> {
      use decoded <- result.try(
        bit_array.base16_decode(value)
        |> result.replace_error("owner credential is not hexadecimal"),
      )
      case bit_array.byte_size(decoded) == 32 {
        True -> Ok(value)
        False -> Error("owner credential is not a 256-bit token")
      }
    }
  }
}
