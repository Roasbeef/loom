//// Remembered approvals belong to one saved session, not one execution.
////
//// The operator gateway prepares a reserved fact update from the exact grants
//// it validated. The runtime commits that update with the approval under two
//// sequence guards. Dispatch reads the fact once; running calls retain their
//// snapshot. This is separate from directory additions because approval can
//// name an exact file, including a writable file that does not exist yet.

import broker/policy
import client/escalate
import client/grants
import core/json
import core/message
import core/origin
import core/register
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/api
import runtime/escalation
import session/session
import storage/storage
import tools/fs
import tools/tool

/// Reserved against model-authored fact writes.
pub const key = "client/permission_grants"

/// Action grants are private authority, separate from general session policy.
pub const action_prefix = "client/action_grants/"

/// Captures standing authority and consent for precisely this invocation.
///
/// Complete effective arguments participate in the identity. Omitting an
/// option or changing the requesting strand requires a new decision, even
/// when the shell command is unchanged.
///
/// ## Examples
///
/// ```gleam
/// // permissions.read_for(opened, "main", "bash", arguments)
/// ```
pub fn read_for(
  opened: session.Session,
  strand: String,
  tool_name: String,
  arguments: json.JsonValue,
) -> Result(List(policy.Grant), String) {
  use standing <- result.try(read(opened))
  let action = escalate.action_digest(arguments)
  use cell <- result.try(
    storage.get_register(
      opened.store,
      register.FactCustom,
      action_key(strand, tool_name, action),
    )
    |> result.map_error(fn(_) { "action permissions could not be read" }),
  )
  case cell {
    None -> Ok(standing)
    Some(cell) -> {
      use approved <- result.try(grants_from(cell.value.payload))
      use <- bool.guard(
        approved != [policy.GrantLimit(policy.WallSeconds, 0)],
        Error("remembered action wall authority is malformed"),
      )
      Ok(list.append(standing, approved))
    }
  }
}

// The session is the workspace authority. Within it, neither another tool
// nor another strand may inherit consent to run the same arguments forever.
fn action_key(strand: String, tool_name: String, action: String) -> String {
  action_prefix
  <> escalate.action_digest(
    json.Array([
      json.String(strand),
      json.String(tool_name),
      json.String(action),
    ]),
  )
}

/// Prepares exact-action wall consent or the existing general permission union.
///
/// The gateway has already validated the echoed action and grant subset.
/// The reserved change is committed atomically with that captured approval.
///
/// ## Examples
///
/// ```gleam
/// // permissions.remembering_action(runtime, record, approved, author)
/// ```
pub fn remembering_action(
  runtime: api.Runtime,
  record: escalation.Escalation,
  approved: List(policy.Grant),
  author: Option(message.Origin),
) -> Result(api.ReservedFactChange, String) {
  case approved {
    [policy.GrantLimit(policy.WallSeconds, 0)] -> {
      use action <- result.try(option.to_result(
        record.action,
        "session wall consent requires an exact action",
      ))
      use tool_name <- result.try(option.to_result(
        record.tool,
        "session wall consent requires a tool",
      ))
      use scope <- result.try(option.to_result(
        record.scope,
        "session wall consent requires a requesting strand",
      ))
      let key = action_key(scope.strand, tool_name, action)
      use cell <- result.try(
        api.fact_cell(runtime, key)
        |> result.map_error(fn(_) { "action permissions could not be read" }),
      )
      Ok(api.ReservedFactChange(
        key:,
        value: json.Object([
          #("grants", json.Array(list.map(approved, grants.encode))),
          #("origin", origin.encode(author)),
        ]),
        expected: option.map(cell, fn(cell) { cell.seq }),
      ))
    }
    _ -> remembering(runtime, approved, author)
  }
}

/// Reads and validates the standing authority captured by the next invocation.
///
/// ## Examples
///
/// ```gleam
/// // permissions.read(opened)
/// ```
pub fn read(opened: session.Session) -> Result(List(policy.Grant), String) {
  use cell <- result.try(
    storage.get_register(opened.store, register.FactCustom, key)
    |> result.map_error(fn(_) { "session permissions could not be read" }),
  )
  case cell {
    None -> Ok([])
    Some(cell) -> decode(cell.value.payload) |> result.try(validate_live)
  }
}

/// Decodes only the filesystem and full-network grants eligible for persistence.
///
/// ## Examples
///
/// ```gleam
/// assert permissions.decode(json.Object([])) |> result.is_error
/// ```
pub fn decode(value: json.JsonValue) -> Result(List(policy.Grant), String) {
  use decoded <- result.try(grants_from(value))
  use _ <- result.try(list.try_map(decoded, validate))
  Ok(list.unique(decoded))
}

fn grants_from(value: json.JsonValue) -> Result(List(policy.Grant), String) {
  use value <- result.try(
    tool.optional_value(value, "grants")
    |> result.try(fn(value) {
      option.to_result(value, "session permissions are missing grants")
    }),
  )
  use encoded <- result.try(case value {
    json.Array(values) -> Ok(values)
    _ -> Error("session permissions must contain a grants array")
  })
  use decoded <- result.try(
    grants.decode_all(encoded)
    |> result.map_error(fn(_) { "session permission grant is malformed" }),
  )
  Ok(decoded)
}

fn validate(grant: policy.Grant) -> Result(Nil, String) {
  case grant {
    policy.GrantReadableRoot(path) | policy.GrantWritableRoot(path) -> {
      use <- bool.guard(
        !canonical(path),
        Error("remembered paths must be canonical and absolute"),
      )
      Ok(Nil)
    }
    policy.GrantNetwork(policy.NetworkFull) -> Ok(Nil)
    policy.GrantNetwork(_)
    | policy.GrantEnv(_)
    | policy.GrantLimit(..)
    | policy.GrantScratch(_) ->
      Error("only filesystem and full-network permissions can be remembered")
  }
}

fn canonical(path: String) -> Bool {
  string.starts_with(path, "/")
  && !list.any(string.split(path, "/"), fn(part) { part == "." || part == ".." })
  && { path == "/" || !string.ends_with(path, "/") }
  && !string.contains(path, "//")
  && !string.contains(path, "\u{0}")
}

// A renamed path must not silently become authority over a new symlink
// target. Missing writable leaves remain valid beneath their canonical parent.
fn validate_live(
  values: List(policy.Grant),
) -> Result(List(policy.Grant), String) {
  let filesystem = fs.real_filesystem()
  use _ <- result.try(
    list.try_map(values, fn(grant) {
      case grant {
        policy.GrantReadableRoot(path) | policy.GrantWritableRoot(path) -> {
          use current <- result.try(
            fs.resolve_real(filesystem, "/", path)
            |> result.map_error(fn(_) {
              "remembered permission path could not be resolved"
            }),
          )
          use <- bool.guard(
            current != path,
            Error("remembered permission path changed its canonical target"),
          )
          Ok(Nil)
        }
        policy.GrantNetwork(_)
        | policy.GrantEnv(_)
        | policy.GrantLimit(..)
        | policy.GrantScratch(_) -> Ok(Nil)
      }
    }),
  )
  Ok(values)
}

/// Prepares the durable union without committing ahead of the human's decision.
///
/// Every grant must be eligible; mixed requests remain once-only rather than
/// silently remembering a subset. The returned expectation protects concurrent
/// approvals from overwriting one another's remembered authority.
///
/// ## Examples
///
/// ```gleam
/// // permissions.remembering(runtime, approved, author)
/// ```
pub fn remembering(
  runtime: api.Runtime,
  approved: List(policy.Grant),
  author: Option(message.Origin),
) -> Result(api.ReservedFactChange, String) {
  use <- bool.guard(
    approved == [],
    Error("there are no permissions to remember"),
  )
  use _ <- result.try(list.try_map(approved, validate))
  use _ <- result.try(validate_live(approved))
  use cell <- result.try(
    api.fact_cell(runtime, key)
    |> result.map_error(fn(_) { "session permissions could not be read" }),
  )
  use previous <- result.try(case cell {
    None -> Ok([])
    Some(cell) -> decode(cell.value)
  })
  let union = list.unique(list.append(previous, approved))
  Ok(api.ReservedFactChange(
    key:,
    value: json.Object([
      #("grants", json.Array(list.map(union, grants.encode))),
      #("origin", origin.encode(author)),
    ]),
    expected: option.map(cell, fn(cell) { cell.seq }),
  ))
}
