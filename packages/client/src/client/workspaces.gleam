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
//// ## Shared and worktree
////
//// A workspace is `Shared` by default: every session that attaches under the
//// name runs its tools in `root`, as before. With `mode = "worktree"` each
//// session instead gets its own linked Git worktree of `root` and its own
//// branch (protocol-change/095). The mode carries the one setting only it
//// uses, `base`, the commit-ish each new branch starts from. Keeping `base`
//// inside the `Worktree` variant, rather than beside the mode, makes the
//// refused combination (a base on a shared workspace) unrepresentable once a
//// row has parsed.
////
//// ## Flow
////
//// `from_document` → `row` → `mode_of` → `known_keys`
////
//// 1. `from_document` reads the table and requires the distribution table,
////    because an executor with no pinned peers has nobody to serve.
//// 2. `row` validates one entry's name and keys.
//// 3. `mode_of` reads the mode and its base together, so a base cannot be
////    accepted without the mode that uses it.
//// 4. `find` resolves a name an orchestrator sent to its configured row.

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
    /// Whether sessions share `root` or each get a worktree of it.
    mode: Mode,
  )
}

/// How the sessions of one workspace relate to its checkout.
pub type Mode {
  /// Every session runs its tools in `root`.
  Shared

  /// Every session runs in a linked Git worktree of `root`, on a branch of its
  /// own, created when it first attaches (protocol-change/095).
  Worktree(
    /// The commit-ish each new branch starts from, resolved in `root` when the
    /// worktree is created. `HEAD` unless the table names another.
    base: String,
  )
}

/// The start point a worktree workspace uses when its table names none.
pub const default_base = "HEAD"

/// A workspace whose sessions share its checkout.
///
/// ## Examples
///
/// ```gleam
/// assert workspaces.shared("loom", "/srv/loom").mode == workspaces.Shared
/// ```
pub fn shared(name: String, root: String) -> Workspace {
  Workspace(name:, root:, mode: Shared)
}

/// The word `mode` takes in the configuration file, and the word the census
/// carries.
///
/// ## Examples
///
/// ```gleam
/// assert workspaces.mode_word(workspaces.Worktree("HEAD")) == "worktree"
/// ```
pub fn mode_word(mode: Mode) -> String {
  case mode {
    Shared -> "shared"
    Worktree(..) -> "worktree"
  }
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
/// Omission is an empty list. Each table names `root`, an absolute path with no
/// `..` segment, and may name `mode` (`shared`, the default, or `worktree`) and,
/// with `worktree` only, `base`. A name outside the
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
  // Decide how to handle dict.get(document, "workspaces") {.
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

      // Decide how to handle found {.
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

/// Establishes row for the caller, keeping its validation and result policy at this boundary.
fn row(name: String, value: tom.Toml) -> Result(Workspace, String) {
  // Decide how to handle use Nil <- result.try( catalogue.is_workspace_name(name) {.
  use Nil <- result.try(case catalogue.is_workspace_name(name) {
    True -> Ok(Nil)
    False ->
      Error(
        "workspaces."
        <> name
        <> " is not a workspace name: 1 to 128 bytes, no / and no NUL",
      )
  })

  // Decide how to handle value {.
  case value {
    tom.Table(fields) -> {
      use Nil <- result.try(known_keys(
        dict.keys(fields),
        ["root", "mode", "base"],
        "[workspaces." <> name <> "]",
      ))

      // Decide how to handle dict.get(fields, "root") {.
      case dict.get(fields, "root") {
        Ok(tom.String(root)) -> {
          use Nil <- result.try(
            absolute(root)
            |> result.map_error(fn(reason) {
              "workspaces." <> name <> ".root " <> reason
            }),
          )
          use mode <- result.map(mode_of(fields, "workspaces." <> name))
          Workspace(name:, root:, mode:)
        }
        Ok(_) -> Error("workspaces." <> name <> ".root must be a string")
        Error(Nil) -> Error("workspaces." <> name <> ".root is required")
      }
    }
    _ -> Error("workspaces." <> name <> " must be a table")
  }
}

// Reads `mode` and `base` together. `base` is accepted only with `worktree`,
// and must be a commit-ish Git can resolve from a command line: not empty, not
// starting with `-` (which Git would read as an option), and free of control
// characters and spaces. Whether the name resolves in `root` is Git's to say
// when the first worktree is made.

/// Establishes mode of for the caller, keeping its validation and result policy at this boundary.
fn mode_of(
  fields: Dict(String, tom.Toml),
  place: String,
) -> Result(Mode, String) {
  let base = dict.get(fields, "base")

  // Decide how to handle dict.get(fields, "mode"), base {.
  case dict.get(fields, "mode"), base {
    Error(Nil), Error(Nil) | Ok(tom.String("shared")), Error(Nil) -> Ok(Shared)
    Ok(tom.String("worktree")), Error(Nil) -> Ok(Worktree(base: default_base))
    Ok(tom.String("worktree")), Ok(tom.String(text)) ->
      usable_base(text)
      |> result.map(Worktree)
      |> result.map_error(fn(reason) { place <> ".base " <> reason })
    Ok(tom.String("worktree")), Ok(_) ->
      Error(place <> ".base must be a string")
    Ok(tom.String("shared")), Ok(_) | Error(Nil), Ok(_) ->
      Error(place <> ".base needs mode = \"worktree\"")
    Ok(tom.String(_)), _ ->
      Error(place <> ".mode must be \"shared\" or \"worktree\"")
    Ok(_), _ -> Error(place <> ".mode must be a string")
  }
}

/// Establishes usable base for the caller, keeping its validation and result policy at this boundary.
fn usable_base(text: String) -> Result(String, String) {
  let printable =
    list.all(string.to_utf_codepoints(text), fn(point) {
      let code = string.utf_codepoint_to_int(point)
      code > 32 && code != 127
    })

  // Decide how to handle text != "" && !string.starts_with(text, "-") && printable {.
  case text != "" && !string.starts_with(text, "-") && printable {
    True -> Ok(text)
    False ->
      Error(
        "must be a branch, tag or commit name: not empty, not starting with -, "
        <> "and with no space or control character",
      )
  }
}

/// Checks that text names one directory unambiguously: an absolute path with no
/// `..` segment. A relative path would mean whatever the daemon's working
/// directory happens to be, and a `..` segment would let the text say one place
/// while the resolved path is another. The refusal is a phrase that completes
/// "`<key>` ...", and `client/spawners` reuses the rule for its `directory`.
///
/// ## Examples
///
/// ```gleam
/// assert workspaces.absolute("/srv/loom") == Ok(Nil)
/// assert workspaces.absolute("loom") == Error("must be an absolute path")
/// ```
pub fn absolute(root: String) -> Result(Nil, String) {
  case
    string.starts_with(root, "/"),
    list.contains(string.split(root, "/"), "..")
  {
    False, _ -> Error("must be an absolute path")
    True, True -> Error("must not contain a .. segment")
    True, False -> Ok(Nil)
  }
}

/// Establishes known keys for the caller, keeping its validation and result policy at this boundary.
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
