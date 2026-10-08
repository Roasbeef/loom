//// The `[workspaces.<name>]` tables: the checkouts an executor serves
//// (protocol-change/078).
////
//// An orchestrator registers a workspace by name, and the name is all it ever
//// sends: it never learns or interprets a path on the executor. This module is
//// the executor's side of that arrangement, the table that turns a name into
//// the directory the machine's operator chose to expose. A name that is not in
//// the table is refused at attach, so a session cannot reach a directory the
//// operator did not list.
////
//// Like `[distribution]` and `[executors.<name>]`, the daemon reads the table
//// once, when it starts, and never rereads it. The catalogue parser validates
//// the same table (`client/catalog`), so a typo is refused wherever the file is
//// read and not only at startup. Validation here is pure: it reads no file. The
//// daemon checks that each root is a directory when it starts, and the plane
//// factory checks again at attach, because a directory can vanish between the
//// two.
////
//// Absence is the safe answer. With no `[workspaces]` table the daemon starts
//// no executor host, and every attach to it is refused for want of one.
////
//// ## Flow
////
//// `from_document` → `row` → `known_keys`
////
//// 1. `from_document` reads the table and requires `[distribution]`, because
////    an executor with no pinned peers has nobody to serve.
//// 2. `row` validates one entry's name and its single key, `root`.
//// 3. `find` resolves a name an orchestrator sent to its configured row.

import client/distribution
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import storage/catalogue
import tom

/// One configured workspace: the name orchestrators register it under and the
/// directory it names on this machine.
pub type Workspace {
  Workspace(
    /// The `[workspaces.<name>]` key, which satisfies
    /// `catalogue.is_workspace_name`.
    name: String,
    /// The absolute directory on this machine. Existence is checked when the
    /// daemon starts and again at each attach, not when the file is parsed.
    root: String,
  )
}

/// Reads the workspaces from configuration text, for callers that hold no
/// parsed document.
///
/// ## Examples
///
/// ```gleam
/// assert workspaces.parse("") == Ok([])
/// ```
pub fn parse(text: String) -> Result(List(Workspace), String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(fn(error) {
      "invalid daemon configuration: " <> string.inspect(error)
    }),
  )
  from_document(document)
}

/// Validates the `[workspaces.<name>]` tables of a parsed configuration
/// document and returns the workspaces sorted by name.
///
/// Omission is an empty list. Each table names exactly one key, `root`, an
/// absolute path with no `..` segment. A name outside the
/// registered-workspace grammar, a key the table does not know and a value of
/// the wrong type are each refused with the key's full name, so the operator
/// can find the line. A document with workspaces and no `[distribution]` table
/// is refused, because nobody could reach them.
///
/// ## Examples
///
/// ```gleam
/// assert workspaces.from_document(dict.new()) == Ok([])
/// ```
pub fn from_document(
  document: Dict(String, tom.Toml),
) -> Result(List(Workspace), String) {
  case dict.get(document, "workspaces") {
    Error(Nil) -> Ok([])
    Ok(tom.Table(tables)) -> {
      use configured <- result.try(
        dict.to_list(tables)
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
        |> list.try_map(fn(entry) { row(entry.0, entry.1) }),
      )

      // The table is only useful to a node that peers can reach.
      use found <- result.try(distribution.from_document(document))
      case found {
        Some(_settings) -> Ok(configured)
        None ->
          Error("workspaces needs a [distribution] table naming its peers")
      }
    }
    Ok(_) -> Error("workspaces must be a table of [workspaces.<name>] tables")
  }
}

/// Finds the workspace with this name.
///
/// ## Examples
///
/// ```gleam
/// assert workspaces.find([], "loom") == Error(Nil)
/// ```
pub fn find(
  configured: List(Workspace),
  name: String,
) -> Result(Workspace, Nil) {
  list.find(configured, fn(workspace) { workspace.name == name })
}

fn row(name: String, value: tom.Toml) -> Result(Workspace, String) {
  use Nil <- result.try(case catalogue.is_workspace_name(name) {
    True -> Ok(Nil)
    False ->
      Error(
        "workspaces."
        <> name
        <> " is not a workspace name: 1 to 128 bytes, no / and no NUL",
      )
  })
  case value {
    tom.Table(fields) -> {
      use Nil <- result.try(known_keys(
        dict.keys(fields),
        ["root"],
        "[workspaces." <> name <> "]",
      ))
      case dict.get(fields, "root") {
        Ok(tom.String(root)) -> {
          use Nil <- result.try(
            absolute(root)
            |> result.map_error(fn(reason) {
              "workspaces." <> name <> ".root " <> reason
            }),
          )
          Ok(Workspace(name:, root:))
        }
        Ok(_) -> Error("workspaces." <> name <> ".root must be a string")
        Error(Nil) -> Error("workspaces." <> name <> ".root is required")
      }
    }
    _ -> Error("workspaces." <> name <> " must be a table")
  }
}

// A root has to name one directory unambiguously. A relative path would mean
// whatever the daemon's working directory happens to be, and a `..` segment
// would let the text say one place while the resolved path is another.
fn absolute(root: String) -> Result(Nil, String) {
  case
    string.starts_with(root, "/"),
    list.contains(string.split(root, "/"), "..")
  {
    False, _ -> Error("must be an absolute path")
    True, True -> Error("must not contain a .. segment")
    True, False -> Ok(Nil)
  }
}

fn known_keys(
  present: List(String),
  allowed: List(String),
  place: String,
) -> Result(Nil, String) {
  case list.find(present, fn(key) { !list.contains(allowed, key) }) {
    Error(Nil) -> Ok(Nil)
    Ok(unknown) ->
      Error(
        "unknown key `"
        <> unknown
        <> "` in "
        <> place
        <> " (allowed: "
        <> string.join(allowed, ", ")
        <> ")",
      )
  }
}
