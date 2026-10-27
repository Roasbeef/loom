//// The map from a repository's logical name to the directory that holds its
//// clone on this machine.
////
//// A task records which repository it was mined from as a name such as
//// `loom`, never as a path. The path is where one machine happened to put a
//// clone, so it cannot be part of what the task means: hashing it into the
//// task id would bind a mined task set to the host that mined it, and
//// moving the clone would change every task's identity. The name is
//// identity; the path is supplied by the operator on every run, through
//// `--repo <name>=<path>` flags, and lives only in this module's `Repos`
//// value.
////
//// A name is safe by its charset alone: lowercase ASCII letters, digits and
//// hyphens, starting with a letter or digit, so it can never be read as a
//// git option or a remote helper. A path is operator input and is held to
//// the rules the task decoder used to apply to the repository field: it is
//// absolute, at most 1024 bytes, free of NUL and of git's `::` remote-helper
//// syntax, and has no segment that starts with `-`. Those checks run when a
//// path enters the map, so a `Repos` value holds only paths git can take as
//// a directory.
////
//// A name is never trusted to be the right repository. `resolve` asks the
//// clone for the tree of the task's commit and refuses unless it equals the
//// tree the task recorded: the content address, not the name or the path,
//// pins the bytes a trial starts from. A clone that lacks the commit, or
//// holds a different history under the same name, fails there.
////
//// Nothing here clones or fetches. The map is built from flags, optionally
//// completed with the current checkout as `loom`, and consulted by
//// materialisation, proving, the miner and the exporter.

import client/secrets.{type Runner}
import eval/git
import eval/wire
import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string

/// The operator's mapping from repository names to absolute clone paths.
/// Opaque, so every path in it has passed `check_path`.
pub opaque type Repos {
  Repos(paths: Dict(String, String))
}

/// The name Loom's own history is mined under, and the one the default
/// resolution supplies when no flag names it.
pub const default_name = "loom"

/// The longest a repository name may be.
const name_limit = 64

/// The longest a clone path may be, in bytes.
const path_limit = 1024

/// The longest a git answer may wait: asking for one tree is a lookup.
const git_timeout_ms = 300_000

/// A map with no repositories.
///
/// ## Examples
///
/// ```gleam
/// assert repos.path(repos.empty(), "loom") |> result.is_error
/// ```
///
pub fn empty() -> Repos {
  Repos(paths: dict.new())
}

/// True for a name that matches `[a-z0-9][a-z0-9-]{0,63}`.
///
/// ## Examples
///
/// ```gleam
/// assert repos.valid_name("loom")
/// assert !repos.valid_name("--upload-pack=x")
/// ```
///
pub fn valid_name(name: String) -> Bool {
  let letters = string.to_graphemes(name)

  // The first letter may not be a hyphen, which would let a name read as an
  // option; the rest may. The length bound only needs the elements past it.
  case letters {
    [] -> False
    [first, ..rest] ->
      list.drop(letters, name_limit) == []
      && string.contains(name_start, first)
      && list.all(rest, fn(letter) { string.contains(name_rest, letter) })
  }
}

// The first character of a name may not be a hyphen, which would let a name
// read as an option.
const name_start = "abcdefghijklmnopqrstuvwxyz0123456789"

const name_rest = "abcdefghijklmnopqrstuvwxyz0123456789-"

/// Adds one repository. The name must be valid, the path must pass
/// `check_path`, and a name may be given only once: two paths for one name
/// would make which clone a task runs against depend on flag order.
///
/// ## Examples
///
/// ```gleam
/// assert repos.add(repos.empty(), "loom", "/src/loom") |> result.is_ok
/// assert repos.add(repos.empty(), "loom", "src/loom") |> result.is_error
/// ```
///
pub fn add(known: Repos, name: String, path: String) -> Result(Repos, String) {
  use <- bool.lazy_guard(when: !valid_name(name), return: fn() {
    Error("repository name `" <> name <> "` must match [a-z0-9][a-z0-9-]{0,63}")
  })
  use Nil <- result.try(check_path(path))

  // A second path for one name would let flag order choose the clone.
  use <- bool.lazy_guard(when: dict.has_key(known.paths, name), return: fn() {
    Error("repository `" <> name <> "` is named twice")
  })

  Ok(Repos(paths: dict.insert(known.paths, name, path)))
}

/// Reads repeated `--repo` values, each `<name>=<path>`, into a map. The
/// split is at the first `=`, so a path may itself contain one.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(known) = repos.from_flags(["loom=/src/loom", "other=/src/o"])
/// assert repos.path(known, "other") == Ok("/src/o")
/// ```
///
pub fn from_flags(specs: List(String)) -> Result(Repos, String) {
  list.try_fold(specs, empty(), fn(known, spec) {
    case string.split_once(spec, "=") {
      Ok(#(name, path)) -> add(known, name, path)
      Error(Nil) -> Error("--repo wants <name>=<path>, got `" <> spec <> "`")
    }
  })
}

/// Completes the map with the current checkout as `loom` when no flag named
/// it. The checkout is what `git rev-parse --show-toplevel` answers in the
/// process's working directory. Outside a checkout, or when that answer is
/// not an acceptable path, the map is returned unchanged and a task that
/// needs `loom` is refused by `resolve` with an error that names the flag:
/// a plan of inline tasks must not need a repository to run.
///
/// ## Examples
///
/// ```gleam
/// let known = repos.with_default(repos.empty(), secrets.host_runner())
/// ```
///
pub fn with_default(known: Repos, runner: Runner) -> Repos {
  use <- bool.guard(
    when: dict.has_key(known.paths, default_name),
    return: known,
  )

  let found = {
    use capture <- result.try(runner(
      ["git", "rev-parse", "--show-toplevel"],
      git_timeout_ms,
    ))
    use <- bool.lazy_guard(when: capture.status != 0, return: fn() {
      Error("not a checkout")
    })

    add(known, default_name, string.trim(capture.output))
  }

  result.unwrap(found, known)
}

/// The clone path recorded for a name, without looking inside it.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(known) = repos.from_flags(["loom=/src/loom"])
/// assert repos.path(known, "loom") == Ok("/src/loom")
/// ```
///
pub fn path(known: Repos, name: String) -> Result(String, String) {
  dict.get(known.paths, name)
  |> result.map_error(fn(_missing) {
    "no clone is known for repository `"
    <> name
    <> "`; pass --repo "
    <> name
    <> "=<absolute path>"
  })
}

/// The clone path for a task's repository, once the clone has confirmed it
/// holds the task's tree: `commit` must exist there and `<commit>^{tree}`
/// must equal `tree`. A different clone, a rewritten history or a wrong name
/// all fail here, which is what makes resolving a name by operator input
/// safe.
///
/// ## Examples
///
/// ```gleam
/// // repos.resolve(known, secrets.host_runner(), "loom", commit, tree)
/// // == Ok("/src/loom")
/// ```
///
pub fn resolve(
  known: Repos,
  runner: Runner,
  name: String,
  commit: String,
  tree: String,
) -> Result(String, String) {
  use clone <- result.try(path(known, name))
  use <- bool.lazy_guard(
    when: !{ wire.is_hex(commit, 40) && wire.is_hex(tree, 40) },
    return: fn() { Error("commit and tree must be 40-digit lowercase hex") },
  )
  use answer <- result.try(
    git.ask(runner, clone, ["rev-parse", commit <> "^{tree}"], git_timeout_ms)
    |> result.map_error(fn(reason) {
      "repository `"
      <> name
      <> "` at "
      <> clone
      <> " lacks "
      <> commit
      <> ": "
      <> reason
    }),
  )
  let actual = string.trim(answer)

  // Equal tree ids are what let the task claim the agent starts from the
  // bytes it was minted from, whichever clone answered.
  use <- bool.lazy_guard(when: actual != tree, return: fn() {
    Error(
      "tree mismatch: the task records "
      <> tree
      <> " but "
      <> commit
      <> " has "
      <> actual
      <> " in repository `"
      <> name
      <> "` at "
      <> clone,
    )
  })

  Ok(clone)
}

/// Accepts an absolute local path that git cannot read as an option or a
/// transport: at most 1024 bytes, no NUL, no `::` (git's remote-helper
/// syntax), no segment starting with `-`. URLs are refused by the leading
/// `/`.
///
/// ## Examples
///
/// ```gleam
/// assert repos.check_path("/srv/git/loom") == Ok(Nil)
/// assert repos.check_path("/srv/ext::sh") |> result.is_error
/// ```
///
pub fn check_path(path: String) -> Result(Nil, String) {
  let acceptable =
    string.starts_with(path, "/")
    && wire.bytes(path) <= path_limit
    && !string.contains(path, "::")
    && !string.contains(path, "\u{0}")
    && list.all(string.split(path, "/"), fn(piece) {
      !string.starts_with(piece, "-")
    })

  use <- bool.lazy_guard(when: !acceptable, return: fn() {
    Error(
      "repository path must be absolute, at most 1024 bytes, with no `::`, NUL or option-like segment",
    )
  })

  Ok(Nil)
}
