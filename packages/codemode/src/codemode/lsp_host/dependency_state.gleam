//// Detects when an offline Gleam server needs fresh dependency preparation.
////
//// A warm query compares the selected package's manifest and inventory,
//// plus configurations throughout its workspace-local path dependency graph.
//// Inventory identity ignores table order, which Gleam rewrites from maps.
//// Only digests cross into manager state. The graph walk has a fixed bound,
//// and every read passes the same real-path and protection gate as LSP
//// answer reads, using the authorized workspace as its outer boundary.

import codemode/lsp_host/resolve
import core/json
import filepath
import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/list
import gleam/result
import gleam/string
import simplifile
import tom
import tools/blob

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
      fn(text) { Ok(digest(text)) },
    ),
  )
  use inventory <- result.try(generated(
    workspace,
    protected,
    authorized,
    root <> "/build/packages/packages.toml",
    inventory_digest,
  ))
  Ok(digest(string.join([manifest, inventory, ..configs], "\n")))
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
        [real <> ":" <> digest(config), ..digests],
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

// A worktree starts without generated metadata. Absence is an input state,
// while an existing unreadable or protected file is an actionable failure.
fn generated(
  workspace: String,
  protected: List(String),
  authorized: List(String),
  path: String,
  digest: fn(String) -> Result(String, String),
) -> Result(String, String) {
  use admitted <- result.try(admit(workspace, protected, authorized, path))
  case simplifile.is_file(admitted) {
    Ok(False) -> Ok(path <> ":missing")
    Ok(True) -> {
      use text <- result.try(metadata(admitted))
      use stamp <- result.try(
        digest(text)
        |> result.map_error(fn(reason) { path <> ": " <> reason }),
      )
      Ok(path <> ":" <> stamp)
    }
    Error(error) -> Error(path <> ": " <> simplifile.describe_error(error))
  }
}

// The compiler inventory contains package versions and git commit strings
// in tables, not ordered instructions. Canonical JSON preserves every key
// and value while making map iteration order irrelevant to lease reuse.
fn inventory_digest(text: String) -> Result(String, String) {
  use fields <- result.try(
    tom.parse(text)
    |> result.replace_error("package inventory is not valid TOML"),
  )
  use value <- result.try(inventory_value(tom.Table(fields), 0))
  Ok(value |> json.canonical |> json.to_string |> digest)
}

// Current inventories reach root -> git -> package -> commit. Refuse an
// unknown value or deeper table instead of omitting an installation input
// or allowing workspace data to drive an unbounded recursive traversal.
fn inventory_value(
  value: tom.Toml,
  depth: Int,
) -> Result(json.JsonValue, String) {
  case value {
    tom.String(text) -> Ok(json.String(text))
    tom.Table(fields) | tom.InlineTable(fields) -> {
      use <- bool.lazy_guard(depth >= 3, fn() {
        Error("package inventory exceeds three table levels")
      })
      use entries <- result.try(
        fields
        |> dict.to_list
        |> list.try_map(fn(field) {
          use child <- result.try(inventory_value(field.1, depth + 1))
          Ok(#(field.0, child))
        }),
      )
      Ok(json.Object(entries))
    }
    _ -> Error("package inventory must contain only tables and strings")
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

// Keep the existing SHA-256 text fingerprints without importing owner claim
// administration. The shared blob address uses the same digest bytes.
fn digest(value: String) -> String {
  blob.ref_for(bit_array.from_string(value)) |> string.drop_start(7)
}
