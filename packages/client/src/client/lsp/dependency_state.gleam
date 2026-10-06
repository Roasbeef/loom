//// Detects when an offline Gleam server needs fresh dependency preparation.
////
//// A warm query compares the selected package's manifest and inventory,
//// plus configurations throughout its workspace-local path dependency graph.
//// Only digests cross into manager state. The graph walk has a fixed bound,
//// and every read passes the same real-path and protection gate as LSP
//// answer reads, using the authorized workspace as its outer boundary.

import client/lsp/resolve
import filepath
import gleam/bool
import gleam/dict
import gleam/list
import gleam/result
import gleam/string
import host/claim
import simplifile
import tom

/// Fingerprints dependency inputs and the selected package's installation.
///
/// Missing generated files have a distinct digest. Missing or invalid
/// project configuration refuses reuse rather than blessing a stale server.
/// Path dependencies outside the authorized workspace refuse before any
/// harness read; a profile does not grant setup access by naming a path.
///
/// ## Examples
///
/// ```gleam
/// // dependency_state.fingerprint("/work", [], ["/work"], "/work/app")
/// // -> Ok(digest), changing when app or sibling dependencies change.
/// ```
pub fn fingerprint(
  workspace: String,
  protected: List(String),
  authorized: List(String),
  root: String,
) -> Result(String, String) {
  use configs <- result.try(
    walk(workspace, protected, authorized, [root], [], []),
  )
  use manifest <- result.try(
    generated(
      workspace,
      protected,
      authorized,
      root <> "/manifest.toml",
      fn(text) { text },
    ),
  )
  use inventory <- result.try(generated(
    workspace,
    protected,
    authorized,
    root <> "/build/packages/packages.toml",
    entries,
  ))
  Ok(claim.digest(string.join([manifest, inventory, ..configs], "\n")))
}

// Cycles in path dependencies do not turn a query into an unbounded walk.
// Gleam diagnoses them during setup; this walk records each real root once.
fn walk(
  workspace: String,
  protected: List(String),
  authorized: List(String),
  pending: List(String),
  seen: List(String),
  digests: List(String),
) -> Result(List(String), String) {
  case pending {
    [] -> Ok(list.sort(digests, string.compare))
    [root, ..rest] -> {
      use real <- result.try(admit(workspace, protected, authorized, root))
      use <- bool.lazy_guard(list.contains(seen, real), fn() {
        walk(workspace, protected, authorized, rest, seen, digests)
      })
      use <- bool.lazy_guard(list.length(seen) >= 64, fn() {
        Error(
          "dependency preparation supports at most 64 workspace-local packages",
        )
      })
      use path <- result.try(admit(
        workspace,
        protected,
        authorized,
        real <> "/gleam.toml",
      ))
      use config <- result.try(metadata(path))
      use fields <- result.try(
        tom.parse(config) |> result.replace_error(path <> " is not valid TOML"),
      )
      let children =
        list.flat_map(["dependencies", "dev_dependencies"], fn(section) {
          dependencies(dict.get(fields, section), real)
        })
      walk(
        workspace,
        protected,
        authorized,
        list.append(rest, children),
        [real, ..seen],
        [real <> ":" <> claim.digest(config), ..digests],
      )
    }
  }
}

// Only Gleam's path dependency tables introduce more local configurations.
// Registry and git dependencies remain the fixed downloader's responsibility.
fn dependencies(section: Result(tom.Toml, Nil), root: String) -> List(String) {
  case section {
    Ok(tom.Table(entries)) | Ok(tom.InlineTable(entries)) ->
      entries
      |> dict.values
      |> list.filter_map(fn(value) {
        case value {
          tom.InlineTable(fields) | tom.Table(fields) -> {
            use path <- result.try(dict.get(fields, "path"))
            case path {
              tom.String(path) -> filepath.expand(filepath.join(root, path))
              _ -> Error(Nil)
            }
          }
          _ -> Error(Nil)
        }
      })
    _ -> []
  }
}

// Gleam serializes the package inventory from a hash map, so two writes of
// the same installation can list its packages in different orders. Setup
// writes one order and the server's own first compile may rewrite another,
// after the manager has already stamped the start. Comparing raw bytes
// would read that rewrite as a changed dependency and restart a healthy
// server, so the inventory is digested as its sorted lines: the set of
// installed packages, not the order Gleam happened to print them.
fn entries(text: String) -> String {
  text |> string.split("\n") |> list.sort(string.compare) |> string.join("\n")
}

// A worktree starts without generated metadata. Absence is an input state,
// while an existing unreadable or protected file is an actionable failure.
// The file's text passes through `normalize` before it is digested.
fn generated(
  workspace: String,
  protected: List(String),
  authorized: List(String),
  path: String,
  normalize: fn(String) -> String,
) -> Result(String, String) {
  use admitted <- result.try(admit(workspace, protected, authorized, path))
  case simplifile.is_file(admitted) {
    Ok(False) -> Ok(path <> ":missing")
    Ok(True) ->
      metadata(admitted)
      |> result.map(fn(text) { path <> ":" <> claim.digest(normalize(text)) })
    Error(error) -> Error(path <> ": " <> simplifile.describe_error(error))
  }
}

// Configuration files are small inputs, not a second source corpus. Stat
// before reading bounds the normal allocation; the length check also
// refuses a file that grew between stat and read.
fn metadata(path: String) -> Result(String, String) {
  use info <- result.try(
    simplifile.file_info(path) |> result.map_error(simplifile.describe_error),
  )
  use <- bool.lazy_guard(
    simplifile.file_info_type(info) != simplifile.File,
    fn() { Error(path <> " is not a regular dependency metadata file") },
  )
  use <- bool.lazy_guard(info.size > 131_072, fn() {
    Error(path <> " exceeds the 128 KiB dependency metadata limit")
  })
  use text <- result.try(resolve.read_text(path))
  use <- bool.lazy_guard(string.byte_size(text) > 131_072, fn() {
    Error(path <> " exceeds the 128 KiB dependency metadata limit")
  })
  Ok(text)
}

/// Requires both generated dependency records after successful setup.
///
/// Gleam writes the package inventory only after downloads finish. A
/// missing or malformed record refuses the server even if setup exited
/// zero, keeping an incomplete project out of the offline lease.
///
/// ## Examples
///
/// ```gleam
/// // dependency_state.verify("/work", [], ["/work"], "/work/app") == Ok(Nil)
/// ```
pub fn verify(
  workspace: String,
  protected: List(String),
  authorized: List(String),
  root: String,
) -> Result(Nil, String) {
  list.try_each(
    [root <> "/manifest.toml", root <> "/build/packages/packages.toml"],
    fn(path) {
      use admitted <- result.try(admit(workspace, protected, authorized, path))
      use content <- result.try(metadata(admitted))
      tom.parse(content)
      |> result.map(fn(_fields) { Nil })
      |> result.replace_error(
        path <> " is not valid prepared dependency metadata",
      )
    },
  )
}

// Workspace containment alone is not session permission. A narrowed session
// may grant only one subdirectory, so every metadata read must also fit a
// real readable or writable root already carried by that session.
fn admit(
  workspace: String,
  protected: List(String),
  authorized: List(String),
  path: String,
) -> Result(String, String) {
  use real <- result.try(resolve.admit(root: workspace, protected:, path:))
  let allowed =
    list.any(authorized, fn(root) {
      let root = resolve.workspace_real(root)
      root == "/" || real == root || string.starts_with(real, root <> "/")
    })
  case allowed {
    True -> Ok(real)
    False ->
      Error(path <> " is outside the session's authorized dependency roots")
  }
}
