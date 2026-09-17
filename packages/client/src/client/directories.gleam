//// Session-owned directory additions, committed only by the operator gateway.
////
//// The boot policy remains immutable. Each tool dispatch reads this reserved
//// fact once and captures both jail roots and native filesystem additions.
//// Missing state preserves the baseline; corrupt or unavailable state refuses
//// the invocation. Call-bound approvals never write this fact.

import broker/policy
import core/corruption
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
import session/session
import simplifile
import storage/storage
import tools/directory_access
import tools/fs
import tools/tool

/// Reserved against model-controlled fact writes.
pub const key = "client/directory_access"

/// Authenticated gateway operations over one session's directory additions.
pub type Admin {
  Admin(
    /// Validates and atomically commits one operator-requested addition.
    add: fn(json.JsonValue, Option(message.Origin)) ->
      Result(json.JsonValue, String),
    /// Reads the committed additions for reconnecting clients.
    read: fn() -> Result(json.JsonValue, String),
  )
}

/// Reads only explicit additions, never the jail's broad host-read policy.
///
/// ## Examples
///
/// ```gleam
/// // directories.read(session)
/// ```
pub fn read(
  opened: session.Session,
) -> Result(directory_access.Access, String) {
  use cell <- result.try(
    storage.get_register(opened.store, register.FactCustom, key)
    |> result.map_error(fn(_) { "session directory access could not be read" }),
  )
  case cell {
    None -> Ok(directory_access.none())
    Some(cell) ->
      decode(cell.value.payload)
      |> result.map_error(fn(_) { "session directory access is malformed" })
      |> result.try(validate_live)
  }
}

// A stored canonical name must not become authority over a new symlink
// target after restart. Validate before both jail and native policy capture.
fn validate_live(
  access: directory_access.Access,
) -> Result(directory_access.Access, String) {
  let filesystem = fs.real_filesystem()
  use _ <- result.try(
    list.try_map(access.readable, fn(path) {
      use current <- result.try(
        fs.resolve_real(filesystem, "/", path)
        |> result.map_error(fn(_) { "an added directory could not be resolved" }),
      )
      use <- bool.guard(
        current != path,
        Error("an added directory changed its canonical target"),
      )
      use exists <- result.try(
        simplifile.is_directory(path)
        |> result.map_error(fn(_) {
          "an added directory could not be inspected"
        }),
      )
      case exists {
        True -> Ok(Nil)
        False -> Error("an added directory no longer exists")
      }
    }),
  )
  Ok(access)
}

/// Decodes durable directory state without accepting non-filesystem grants.
///
/// ## Examples
///
/// ```gleam
/// assert directories.decode(json.Object([])) |> result.is_error
/// ```
pub fn decode(
  value: json.JsonValue,
) -> Result(directory_access.Access, corruption.CorruptionReport) {
  decode_access(value)
  |> result.map_error(fn(reason) {
    corruption.report(
      at: "client/directories",
      on: "directories",
      expected: "canonical directory entries",
      context: reason,
    )
  })
}

fn decode_access(
  value: json.JsonValue,
) -> Result(directory_access.Access, String) {
  use entries <- result.try(case value {
    json.Object(fields) ->
      case list.key_find(fields, "directories") {
        Ok(json.Array(entries)) -> Ok(entries)
        _ -> Error("missing directories array")
      }
    _ -> Error("expected directory state object")
  })
  list.try_fold(entries, directory_access.none(), fn(access, entry) {
    use path <- result.try(tool.required_string(entry, "path"))
    use mode <- result.try(tool.required_string(entry, "access"))
    use <- bool.guard(
      !canonical(path),
      Error("directory must be canonical and absolute"),
    )
    add_access(access, path, mode)
  })
}

fn canonical(path: String) -> Bool {
  string.starts_with(path, "/")
  && path != ""
  && !list.any(string.split(path, "/"), fn(part) { part == "." || part == ".." })
  && { path == "/" || !string.ends_with(path, "/") }
  && !string.contains(path, "//")
  && !string.contains(path, "\u{0}")
}

fn add_access(
  access: directory_access.Access,
  path: String,
  mode: String,
) -> Result(directory_access.Access, String) {
  case mode {
    "read" ->
      Ok(directory_access.approved(access, [policy.GrantReadableRoot(path)]))
    "write" ->
      Ok(directory_access.approved(access, [policy.GrantWritableRoot(path)]))
    _ -> Error("directory access must be read or write")
  }
}

/// Renders canonical additions independently of inherited jail policy.
///
/// ## Examples
///
/// ```gleam
/// assert directories.encode(directory_access.none()) == json.Array([])
/// ```
pub fn encode(access: directory_access.Access) -> json.JsonValue {
  json.Array(
    list.map(access.readable, fn(path) {
      let mode = case list.contains(access.writable, path) {
        True -> "write"
        False -> "read"
      }
      json.Object([#("path", json.String(path)), #("access", json.String(mode))])
    }),
  )
}

/// Builds the operator door with the same immutable protection as execution.
///
/// ## Examples
///
/// ```gleam
/// // directories.admin(opened, runtime, workspace, base)
/// ```
pub fn admin(
  opened: session.Session,
  runtime: fn() -> Result(api.Runtime, Nil),
  workspace: String,
  base: policy.SandboxPolicy,
) -> Admin {
  Admin(
    read: fn() { read(opened) |> result.map(encode) },
    add: fn(value, author) {
      use requested <- result.try(tool.required_string(value, "path"))
      use mode <- result.try(tool.required_string(value, "access"))
      let filesystem = fs.real_filesystem()
      let absolute = case requested {
        "/" <> _ -> requested
        _ -> workspace <> "/" <> requested
      }
      use path <- result.try(
        case mode {
          "read" -> fs.resolve_real(filesystem, "/", absolute)
          _ ->
            fs.resolve_writable_roots(
              filesystem,
              "/",
              [],
              base.protected,
              absolute,
            )
        }
        |> result.map_error(fn(_) {
          "directory could not be resolved or is protected"
        }),
      )
      use directory <- result.try(
        simplifile.is_directory(path)
        |> result.map_error(fn(_) { "directory could not be inspected" }),
      )
      use <- bool.guard(
        !directory,
        Error("add-dir requires an existing directory"),
      )
      use live <- result.try(
        runtime() |> result.map_error(fn(_) { "session is unavailable" }),
      )
      use cell <- result.try(
        api.fact_cell(live, key)
        |> result.map_error(fn(_) { "directory state could not be read" }),
      )
      use existing <- result.try(case cell {
        None -> Ok(directory_access.none())
        Some(cell) ->
          decode(cell.value)
          |> result.map_error(fn(_) { "directory state is malformed" })
      })
      use updated <- result.try(add_access(existing, path, mode))
      let payload =
        json.Object([
          #("directories", encode(updated)),
          #("origin", origin.encode(author)),
        ])
      let expected = option.map(cell, fn(cell) { cell.seq })
      use _ <- result.try(
        api.put_reserved_fact_expecting(live, key, payload, expected:)
        |> result.map_error(fn(_) {
          "directory access commit was refused; retry the command"
        }),
      )
      Ok(encode(updated))
    },
  )
}
