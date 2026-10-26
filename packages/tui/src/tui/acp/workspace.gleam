//// Which workspace an ACP session may bind, decided from the client's request.
////
//// ACP's `session/new` carries `cwd`, a host path chosen by the *client*. Loom
//// binds a session to a workspace the *operator* controls, and a path a peer
//// sends is exactly the input that must never become that binding unchecked.
//// This module is the gate between the two: a session's workspace is either a
//// directory at or below a root the operator named when starting `loom acp`,
//// or a workspace registered by name on an executor. A path outside every
//// root is refused, and nothing here ever invents a workspace from a string
//// the client supplied.
////
//// The check runs on canonical paths. The client's `cwd` is resolved through
//// the filesystem (symbolic links and `..` included) before it is compared, so
//// a link inside a root that points outside it does not pass. The roots are
//// canonicalised once when the server starts, so the comparison is between two
//// canonical strings.
////
//// ## Flow
////
//// `choose` → `local` / `registered` → `within`
////
//// 1. `choose` reads `_meta.loom.workspace` to pick between the two kinds.
//// 2. `local` canonicalises the client's working directory and demands
////    containment in a root.
//// 3. `registered` takes a name and an executor or pool, never a path.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tui/acp/schema

/// The workspace a session will be created in.
pub type Choice {
  /// A directory on the daemon's host, already canonical and inside a root.
  Local(path: String)

  /// A workspace registered by name on an executor or in a pool.
  Registered(name: String, executor: String, pool: String)
}

/// Decides the workspace for a session request.
///
/// `canonical` resolves a path through the filesystem and fails when it does
/// not exist or is not a directory; it is a parameter so the policy is
/// testable without a disk. `roots` are canonical already.
///
/// ## Examples
///
/// ```gleam
/// let canonical = fn(path) { Ok(path) }
/// let meta = schema.Meta(None, None, None, None, None, schema.GuidanceLoaded)
/// assert workspace.choose(meta, "/work/app", ["/work"], canonical)
///   == Ok(workspace.Local("/work/app"))
/// ```
///
/// ```gleam
/// let canonical = fn(path) { Ok(path) }
/// let meta = schema.Meta(None, None, None, None, None, schema.GuidanceLoaded)
/// let assert Error(_) = workspace.choose(meta, "/etc", ["/work"], canonical)
/// ```
pub fn choose(
  meta: schema.Meta,
  cwd: String,
  roots: List(String),
  canonical: fn(String) -> Result(String, String),
) -> Result(Choice, String) {
  // A named workspace is selected by the extension; otherwise `cwd` decides.
  case meta.workspace, meta.executor, meta.pool {
    Some(name), executor, pool -> registered(name, executor, pool)

    None, None, None -> local(cwd, roots, canonical)

    None, _, _ ->
      Error("_meta.loom.executor and pool need _meta.loom.workspace")
  }
}

/// Names a workspace registered on an executor or in a pool.
fn registered(
  name: String,
  executor: Option(String),
  pool: Option(String),
) -> Result(Choice, String) {
  case string.trim(name), executor, pool {
    "", _, _ -> Error("_meta.loom.workspace must not be empty")

    name, Some(executor), None -> Ok(Registered(name, executor, ""))

    name, None, Some(pool) -> Ok(Registered(name, "", pool))

    _, Some(_), Some(_) -> Error("_meta.loom.executor and pool are exclusive")

    _, None, None ->
      Error(
        "_meta.loom.workspace is a registered name and needs an executor or pool",
      )
  }
}

/// Resolves a client path and admits it only inside an operator root.
fn local(
  cwd: String,
  roots: List(String),
  canonical: fn(String) -> Result(String, String),
) -> Result(Choice, String) {
  // A relative path has no meaning to the daemon's host, so it is refused
  // before the filesystem is consulted.
  case string.starts_with(cwd, "/") {
    False -> Error("cwd must be an absolute path")
    True -> {
      use resolved <- result.try(
        canonical(cwd)
        |> result.map_error(fn(reason) { "cwd is not usable: " <> reason }),
      )
      admit(resolved, roots)
    }
  }
}

/// Admits a canonical path only when some operator root contains it.
fn admit(resolved: String, roots: List(String)) -> Result(Choice, String) {
  case list.any(roots, within(_, resolved)) {
    True -> Ok(Local(resolved))
    False ->
      Error("cwd is outside the workspace roots this server was started with")
  }
}

/// Whether `path` is `root` or lies below it, by whole path segments.
///
/// The comparison is on segments so that `/work/app-evil` is not mistaken for
/// a child of `/work/app`.
///
/// ## Examples
///
/// ```gleam
/// assert workspace.within("/work", "/work")
/// assert workspace.within("/work", "/work/app")
/// assert !workspace.within("/work/app", "/work/app-evil")
/// assert workspace.within("/", "/anywhere")
/// ```
pub fn within(root: String, path: String) -> Bool {
  case root {
    "/" -> string.starts_with(path, "/")
    _ -> path == root || string.starts_with(path, root <> "/")
  }
}
