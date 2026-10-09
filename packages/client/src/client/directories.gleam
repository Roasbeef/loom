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

/// Resolves one requested directory addition against the filesystem of the
/// machine it names, and returns the canonical path to record.
///
/// This is the half of an operator's `add-dir` which needs the files: a
/// relative request is taken against `workspace`, a `read` addition must
/// resolve to a real directory, and any other mode must resolve to one
/// outside `protected`. The other half, the compare-and-set of the fact,
/// needs the session's store and not the files, so a session whose
/// workspace is on another node asks that node for this and writes the
/// fact itself.
///
/// ## Examples
///
/// ```gleam
/// // directories.resolve_addition("/work", protected, "lib", "read")
/// // -> Ok("/work/lib")
/// ```
pub fn resolve_addition(
  workspace: String,
  protected: List(String),
  requested: String,
  mode: String,
) -> Result(String, String) {
  let filesystem = fs.real_filesystem()
  let absolute = case requested {
    "/" <> _ -> requested
    _ -> workspace <> "/" <> requested
  }
  use path <- result.try(
    case mode {
      "read" -> fs.resolve_real(filesystem, "/", absolute)
      _ -> fs.resolve_writable_roots(filesystem, "/", [], protected, absolute)
    }
    |> result.map_error(fn(_) {
      "directory could not be resolved or is protected"
    }),
  )
  use directory <- result.try(
    simplifile.is_directory(path)
    |> result.map_error(fn(_) { "directory could not be inspected" }),
  )
  use <- bool.guard(!directory, Error("add-dir requires an existing directory"))
  Ok(path)
}

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
/// This is the stored read followed by the live revalidation, in that order,
/// for callers which hold the session and the workspace on one machine. A
/// caller which does not (the owner of a session whose files live on another
/// node) uses `read_stored` and leaves `revalidate` to the node that can
/// stat the paths.
///
/// ## Examples
///
/// ```gleam
/// // directories.read(session)
/// ```
pub fn read(
  opened: session.Session,
) -> Result(directory_access.Access, String) {
  read_store(opened.store)
}

/// Reads the committed additions from the store without touching the
/// filesystem.
///
/// The value is stored authority, not yet trusted: a canonical name recorded
/// before a restart may now resolve through a different symlink. `revalidate`
/// is the check which makes it usable, and it runs wherever the paths live.
///
/// ## Examples
///
/// ```gleam
/// // directories.read_stored(session)
/// ```
pub fn read_stored(
  opened: session.Session,
) -> Result(directory_access.Access, String) {
  stored(opened.store)
}

// Directory readback needs the durable store, not the lease-renewal callback
// or the rest of Session. Both readers still validate live canonical targets.
fn read_store(
  store: storage.Storage(Nil),
) -> Result(directory_access.Access, String) {
  stored(store) |> result.try(revalidate)
}

// The store half of every reader: a read fault or a malformed record refuses,
// a missing record is the empty set.
fn stored(
  store: storage.Storage(Nil),
) -> Result(directory_access.Access, String) {
  use cell <- result.try(
    storage.get_register(store, register.FactCustom, key)
    |> result.map_error(fn(_) { "session directory access could not be read" }),
  )
  case cell {
    None -> Ok(directory_access.none())
    Some(cell) ->
      decode(cell.value.payload)
      |> result.map_error(fn(_) { "session directory access is malformed" })
  }
}

/// Checks stored additions against the filesystem of the node it runs on.
///
/// A stored canonical name must not become authority over a new symlink
/// target after restart. Validate before both jail and native policy capture.
/// Every path must still resolve to itself and still be a directory; the
/// first that does not refuses the whole set.
///
/// ## Examples
///
/// ```gleam
/// assert directories.revalidate(directory_access.none())
///   == Ok(directory_access.none())
/// ```
pub fn revalidate(
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
  // Compatibility callers retain their acquisition timing: filesystem
  // validation happens before this supplier is invoked, including failure.
  admin_with_facts(
    opened,
    fn() { runtime() |> result.map(api.fact_handle) },
    workspace,
    base,
  )
}

/// Builds the operator door with a lazy, projected writer capability.
///
/// Production projects the handle before retaining its supplier. Filesystem
/// validation, authenticated origin and conditional commitment remain owned
/// here; the handle changes retention without widening directory authority.
/// Readback owns only Storage and writable resolution owns only protections.
///
/// ## Examples
///
/// ```gleam
/// // let facts = api.fact_handle(runtime)
/// // directories.admin_with_facts(opened, fn() { Ok(facts) }, workspace, base)
/// ```
@internal
pub fn admin_with_facts(
  opened: session.Session,
  facts: fn() -> Result(api.FactHandle, Nil),
  workspace: String,
  base: policy.SandboxPolicy,
) -> Admin {
  let protected = base.protected
  admin_over(opened, facts, fn(requested, mode) {
    resolve_addition(workspace, protected, requested, mode)
  })
}

/// Builds the operator door over a resolver for the half that needs the
/// workspace's files.
///
/// `resolve` takes the requested path and the access mode and answers the
/// canonical path to record. Locally it is `resolve_addition` over the
/// session's workspace and protections; for a workspace on another node it
/// asks that node. Everything else (the authenticated origin, the
/// conditional commit, readback) needs the session's store and stays here.
///
/// ## Examples
///
/// ```gleam
/// // directories.admin_over(opened, fn() { Ok(facts) }, plane.resolve_directory)
/// ```
@internal
pub fn admin_over(
  opened: session.Session,
  facts: fn() -> Result(api.FactHandle, Nil),
  resolve: fn(String, String) -> Result(String, String),
) -> Admin {
  let store = opened.store

  Admin(
    read: fn() { read_store(store) |> result.map(encode) },
    add: fn(value, author) {
      use requested <- result.try(tool.required_string(value, "path"))
      use mode <- result.try(tool.required_string(value, "access"))
      use path <- result.try(resolve(requested, mode))
      use live <- result.try(
        facts() |> result.map_error(fn(_) { "session is unavailable" }),
      )
      use cell <- result.try(
        api.fact_cell_with(live, key)
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
        api.put_reserved_fact_expecting_with(live, key, payload, expected:)
        |> result.map_error(fn(_) {
          "directory access commit was refused; retry the command"
        }),
      )
      Ok(encode(updated))
    },
  )
}
