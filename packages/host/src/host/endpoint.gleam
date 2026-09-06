//// One private discovery record fences the daemon's entire operating-system VM.
////
//// A failed WebSocket probe says nothing about native retirement. Launchers
//// replace this record only after observing that its PID/birth identity is
//// absent or different. The launch lock serializes that decision separately
//// from the daemon root's lifetime lock. A record survives normal shutdown and
//// root death: neither event establishes that the containing VM has exited.

import core/json
import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap

/// Fixed paths beneath the caller's canonical private state directory.
pub type Paths {
  Paths(
    /// Canonical directory shared by all local workspaces.
    root: String,
    /// Atomic discovery record, with no bearer credential inside it.
    record: String,
    /// Short-lived launch serialization, never the daemon lifetime lock.
    launch_lock: String,
    /// Stable owner credential; endpoint JSON cannot redirect this path.
    token: String,
    /// Native child output, never a workspace-selected path.
    log: String,
    /// Its presence makes a missing record an operator-recovery case.
    catalogue: String,
  )
}

/// An OS PID paired with the platform's observed process birth marker.
pub type Fence {
  Fence(
    /// PID of the paused exec wrapper or running BEAM VM.
    pid: Int,
    /// Platform-qualified birth identity, not a PID alone.
    birth: String,
    /// Diagnostic wall-clock launch time, not replacement authority.
    started_at_ms: Int,
  )
}

/// A native process reservation, followed by authenticated-listener discovery.
pub type Endpoint {
  /// Published before releasing a child or opening the foreground catalogue.
  Starting(fence: Fence)

  /// Published only after the root has retained its original listener owner.
  Ready(
    /// The same reservation; readiness never changes native identity.
    fence: Fence,
    /// Literal loopback host, with IPv6 brackets added by address().
    host: String,
    /// Actual nonzero bound port, including when startup requested port zero.
    port: Int,
    /// Authenticated control hello must name this daemon epoch.
    epoch: String,
  )
}

/// Replacement is allowed only for fresh state or an observed departed process.
pub type Availability {
  /// There is no live native owner according to the current observation.
  Vacant

  /// The recorded VM is alive; failed probes must preserve this record.
  Occupied(record: Endpoint)
}

/// Validates and canonicalizes the private directory before deriving fixed paths.
///
/// ## Examples
///
/// ```gleam
/// // endpoint.paths("/private/loom")
/// ```
pub fn paths(directory: String) -> Result(Paths, String) {
  use absolute <- result.try(bootstrap.absolute_path(directory))
  use Nil <- result.try(bootstrap.ensure_private_directory(absolute))
  use root <- result.try(bootstrap.canonical_directory(absolute))
  Ok(Paths(
    root,
    root <> "/daemon.endpoint",
    root <> "/launch.lock",
    root <> "/owner.token",
    root <> "/daemon.log",
    root <> "/catalogue.db",
  ))
}

/// Observes one existing process; observation errors never mean absence.
///
/// ## Examples
///
/// ```gleam
/// // endpoint.observe(bootstrap.current_process_id())
/// ```
pub fn observe(pid: Int) -> Result(Fence, String) {
  use identity <- result.try(bootstrap.process_identity(pid))
  case identity {
    bootstrap.ProcessAbsent -> Error("daemon process exited before publication")
    bootstrap.ProcessPresent(birth) ->
      Ok(Fence(pid, birth, bootstrap.system_time_ms()))
  }
}

/// Checks the entire native identity, separately from any connection probe.
///
/// ## Examples
///
/// ```gleam
/// // endpoint.is_present(record.fence)
/// ```
pub fn is_present(fence: Fence) -> Result(Bool, String) {
  bootstrap.process_identity(fence.pid)
  |> result.map(fn(identity) {
    case identity {
      bootstrap.ProcessPresent(birth) -> birth == fence.birth
      bootstrap.ProcessAbsent -> False
    }
  })
}

/// Reads a bounded private record; malformed or inaccessible records are errors.
///
/// ## Examples
///
/// ```gleam
/// // endpoint.load(paths)
/// ```
pub fn load(paths: Paths) -> Result(Option(Endpoint), String) {
  case bootstrap.path_exists(paths.record) {
    False -> Ok(None)
    True -> {
      use bytes <- result.try(bootstrap.read_private_bounded(paths.record, 4096))
      use text <- result.try(
        bit_array.to_string(bytes)
        |> result.replace_error("daemon endpoint is not UTF-8"),
      )
      decode(text) |> result.map(Some)
    }
  }
}

/// Checks replacement authority while the caller holds the launch lock.
///
/// A missing record beside existing catalogue state is not evidence of a dead
/// VM. The operator must establish quiescence and restore discovery explicitly.
///
/// ## Examples
///
/// ```gleam
/// // endpoint.availability(paths)
/// ```
pub fn availability(paths: Paths) -> Result(Availability, String) {
  use record <- result.try(load(paths))
  case record {
    None ->
      case bootstrap.path_exists(paths.catalogue) {
        False -> Ok(Vacant)
        True ->
          Error(
            "daemon endpoint is missing beside an existing catalogue; establish that the previous VM and its native children have exited, then recover the endpoint record; automatic startup will not erase or replace this state",
          )
      }
    Some(record) -> {
      use present <- result.try(is_present(record.fence))
      case present {
        True -> Ok(Occupied(record))
        False -> Ok(Vacant)
      }
    }
  }
}

/// Publishes a reservation, or adopts the matching paused wrapper reservation.
///
/// The caller holds launch.lock. Adoption compares PID and birth rather than
/// wall-clock time, because the daemon observes itself after the launcher did.
/// A Ready record cannot be adopted to restart a root inside a still-live VM.
///
/// ## Examples
///
/// ```gleam
/// // endpoint.claim(paths, own_fence)
/// ```
pub fn claim(paths: Paths, own: Fence) -> Result(Fence, String) {
  use available <- result.try(availability(paths))
  case available {
    Vacant -> write(paths, Starting(own)) |> result.replace(own)
    Occupied(Starting(fence))
      if fence.pid == own.pid && fence.birth == own.birth
    -> Ok(fence)
    Occupied(_) ->
      Error("recorded daemon VM is still alive; refusing another daemon root")
  }
}

/// Atomically writes a typed record after validating its encoded representation.
///
/// Callers retain launch.lock for reservation or readiness publication.
///
/// ## Examples
///
/// ```gleam
/// // endpoint.write(paths, endpoint.Starting(fence))
/// ```
pub fn write(paths: Paths, record: Endpoint) -> Result(Nil, String) {
  let text = encode(record)
  use _validated <- result.try(decode(text))
  bootstrap.atomic_write_private(paths.record, text)
}

/// Replaces only the current matching Starting record with listener readiness.
///
/// ## Examples
///
/// ```gleam
/// // endpoint.publish_ready(paths, fence, "127.0.0.1", port, epoch)
/// ```
pub fn publish_ready(
  paths: Paths,
  fence: Fence,
  host: String,
  port: Int,
  epoch: String,
) -> Result(Nil, String) {
  use current <- result.try(load(paths))
  case current {
    Some(Starting(found)) if found == fence ->
      write(paths, Ready(fence, host, port, epoch))
    _ -> Error("daemon endpoint reservation changed before readiness")
  }
}

/// Builds the sole control route from validated address fields.
///
/// ## Examples
///
/// ```gleam
/// // endpoint.address(record)
/// ```
pub fn address(record: Endpoint) -> Result(String, String) {
  case record {
    Starting(_) -> Error("daemon is still starting")
    Ready(_, host, port, _) -> {
      let host = case host {
        "::1" -> "[::1]"
        _ -> host
      }
      Ok("ws://" <> host <> ":" <> int_text(port) <> "/v2/control")
    }
  }
}

/// Encodes the fixed version-one endpoint schema for gateway protocol two.
///
/// ## Examples
///
/// ```gleam
/// // endpoint.decode(endpoint.encode(record)) == Ok(record)
/// ```
pub fn encode(record: Endpoint) -> String {
  let fence = record.fence
  let common = [
    #("version", json.Int(1)),
    #("protocol", json.Int(2)),
    #("pid", json.Int(fence.pid)),
    #("birth", json.String(fence.birth)),
    #("started_at_ms", json.Int(fence.started_at_ms)),
  ]
  let fields = case record {
    Starting(_) -> [#("status", json.String("starting")), ..common]
    Ready(_, host, port, epoch) -> [
      #("status", json.String("ready")),
      #("host", json.String(host)),
      #("port", json.Int(port)),
      #("epoch", json.String(epoch)),
      ..common
    ]
  }
  json.to_string(json.Object(fields))
}

/// Totally decodes a bounded, duplicate-key-free private endpoint record.
///
/// Unknown schema versions and malformed identities fail closed, even when
/// the record happens to contain a PID which no longer exists.
///
/// ## Examples
///
/// ```gleam
/// endpoint.decode("{}") // Error("invalid daemon endpoint")
/// ```
pub fn decode(text: String) -> Result(Endpoint, String) {
  use <- bool.guard(
    string.byte_size(text) > 4096,
    Error("invalid daemon endpoint"),
  )
  use value <- result.try(
    json.parse(text)
    |> result.replace_error("invalid daemon endpoint"),
  )
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("invalid daemon endpoint")
  })
  use version <- result.try(number(fields, "version"))
  use protocol <- result.try(number(fields, "protocol"))
  use pid <- result.try(number(fields, "pid"))
  use birth <- result.try(text_field(fields, "birth"))
  use started <- result.try(number(fields, "started_at_ms"))
  use status <- result.try(text_field(fields, "status"))

  // This is an identity fence, not a loosely interpreted connection hint.
  use <- bool.guard(
    !{
      version == 1
      && protocol == 2
      && pid > 1
      && started > 0
      && birth != ""
      && string.byte_size(birth) <= 256
    },
    Error("invalid daemon endpoint"),
  )
  let fence = Fence(pid, birth, started)
  case status {
    "starting" -> {
      // Six required keys were each found above, so an object with nothing
      // past its sixth field cannot also carry a duplicate: a repeat of any
      // key would make a seventh. That is what refuses a record whose second
      // `pid` a different parser might have preferred. `list.drop` rather
      // than `list.length` because the question stops at the bound.
      use <- bool.guard(
        list.drop(fields, 6) != [],
        Error("invalid daemon endpoint"),
      )
      Ok(Starting(fence))
    }
    "ready" -> {
      use host <- result.try(text_field(fields, "host"))
      use port <- result.try(number(fields, "port"))
      use epoch <- result.try(text_field(fields, "epoch"))

      // Nine required keys, so nothing past the ninth field, for the same
      // reason the starting record allows nothing past its sixth.
      use <- bool.guard(
        !{
          list.drop(fields, 9) == []
          && { host == "127.0.0.1" || host == "::1" }
          && port > 0
          && port <= 65_535
          && epoch != ""
          && string.byte_size(epoch) <= 128
        },
        Error("invalid daemon endpoint"),
      )
      Ok(Ready(fence, host, port, epoch))
    }
    _ -> Error("invalid daemon endpoint")
  }
}

fn number(fields, key) {
  use value <- result.try(field(fields, key))
  case value {
    json.Int(value) -> Ok(value)
    json.Object(_)
    | json.Array(_)
    | json.String(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("invalid daemon endpoint")
  }
}

fn text_field(fields, key) {
  use value <- result.try(field(fields, key))
  case value {
    json.String(value) -> Ok(value)
    json.Object(_)
    | json.Array(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("invalid daemon endpoint")
  }
}

fn field(fields, key) {
  list.key_find(fields, key) |> result.replace_error("invalid daemon endpoint")
}

fn int_text(value) {
  json.to_string(json.Int(value))
}
