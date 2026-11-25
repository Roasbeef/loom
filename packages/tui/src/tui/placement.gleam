//// Where a newly created session's workspace lives: a directory on the
//// daemon's own host, a name registered on an executor, or a name registered
//// on the executors of a pool (protocol-change/078).
////
//// The two are different kinds of text. A path on the daemon's host is
//// canonicalized there; a registered name is never canonicalized, statted or
//// created on this machine, because only the executor can resolve it. The
//// terminal therefore keeps the name apart from every path it handles. It
//// never reaches the launcher's `--workspace` resolution, the footer's
//// repository probe or the picker's path arithmetic as if it were a
//// directory, and a launch cannot name an executor or a pool without a
//// workspace or a workspace without one, because both live in one variant.
////
//// The shape rules below repeat the daemon's (`storage/catalogue`), which this
//// package cannot import. They exist to refuse a typo before a daemon round
//// trip; the daemon judges the same text again when the creation arrives, so a
//// rule that drifts here can only make this client stricter or looser than the
//// daemon, never unsafe.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The longest executor or pool name the daemon accepts, in characters.
const executor_name_limit = 32

/// The longest registered workspace name the daemon accepts, in bytes.
const workspace_name_limit = 128

/// Where a newly created session's workspace lives.
pub type Placement {
  /// The workspace is the launch's directory on the daemon's own host.
  OnThisHost

  /// The workspace is the name registered on this executor, an
  /// `[executors.<name>]` key of the daemon's configuration.
  OnExecutor(
    /// The executor, as the daemon's configuration names it.
    executor: String,
    /// The workspace name registered on that executor, kept exactly as typed.
    workspace: String,
  )

  /// The workspace is the name registered on the executors of this pool, a
  /// `[pools.<name>]` key of the daemon's configuration. The daemon picks the
  /// executor when the session first opens.
  InPool(
    /// The pool, as the daemon's configuration names it.
    pool: String,
    /// The workspace name registered on the pool's executors, kept exactly as
    /// typed.
    workspace: String,
  )

  /// The workspace is a new Git worktree of the launch's directory on the
  /// daemon's own host, on a branch of its own, so the session's changes stay
  /// out of the directory itself (protocol-change/133). The directory is the
  /// launch's, exactly as for `OnThisHost`; this variant only adds where the
  /// session works inside it.
  InWorktree(
    /// The commit-ish the session's branch starts from: `HEAD` unless
    /// `--base` named another.
    base: String,
  )
}

/// The start point a worktree session's branch has when `--base` names none.
pub const default_base = "HEAD"

/// Takes `--worktree` and `--base <commit-ish>` out of a launch's words and
/// answers the base the session's worktree starts from, or `None` when the
/// launch did not ask for one.
///
/// `--base` is a refinement of `--worktree` and means nothing alone, so it is
/// refused without it. Each flag may appear once, and a base that Git would read
/// as an option (a leading `-`), or that holds a space or a control character,
/// is refused here before a daemon round trip. The daemon judges the same text
/// again, so a rule that drifts can only make this client stricter or looser
/// than the daemon, never unsafe.
///
/// ## Examples
///
/// ```gleam
/// assert placement.take_worktree(["--worktree", "--workspace", "/w"])
///   == Ok(#(Some("HEAD"), ["--workspace", "/w"]))
/// assert placement.take_worktree(["--worktree", "--base", "origin/main"])
///   == Ok(#(Some("origin/main"), []))
/// assert placement.take_worktree(["--workspace", "/w"])
///   == Ok(#(None, ["--workspace", "/w"]))
/// let assert Error(_) = placement.take_worktree(["--base", "main"])
/// ```
pub fn take_worktree(
  arguments: List(String),
) -> Result(#(Option(String), List(String)), String) {
  use #(asked, rest) <- result.try(take_switch(arguments, "--worktree"))
  use #(base, rest) <- result.try(take_base(rest))

  // Decide what the two words mean together.
  case asked, base {
    False, None -> Ok(#(None, rest))
    False, Some(_) -> Error("--base refines --worktree: add --worktree")
    True, None -> Ok(#(Some(default_base), rest))
    True, Some(text) ->
      case is_base(text) {
        True -> Ok(#(Some(text), rest))
        False ->
          Error(
            "--base needs a branch, tag or commit name: not empty, not starting with -, and with no space or control character",
          )
      }
  }
}

/// Folds a worktree choice into the placement a launch settled on. Only a
/// directory on the daemon's host has a worktree to make: a workspace on an
/// executor or in a pool is served by a machine that chooses its own mode in
/// its `[workspaces.<name>]` table (protocol-change/095).
///
/// ## Examples
///
/// ```gleam
/// assert placement.in_worktree(placement.OnThisHost, Some("HEAD"))
///   == Ok(placement.InWorktree("HEAD"))
/// assert placement.in_worktree(placement.OnThisHost, None)
///   == Ok(placement.OnThisHost)
/// let assert Error(_) =
///   placement.in_worktree(placement.OnExecutor("box", "app"), Some("HEAD"))
/// ```
pub fn in_worktree(
  chosen: Placement,
  base: Option(String),
) -> Result(Placement, String) {
  case chosen, base {
    _, None -> Ok(chosen)
    OnThisHost, Some(base) -> Ok(InWorktree(base))
    InWorktree(_), Some(base) -> Ok(InWorktree(base))
    OnExecutor(..), Some(_) | InPool(..), Some(_) ->
      Error(
        "--worktree makes a worktree of a directory on this machine; a workspace on an executor or in a pool chooses its own mode in the executor's [workspaces] table",
      )
  }
}

/// Whether text may be the start point of a worktree's branch. It repeats
/// `catalogue.is_worktree_base`, which this package cannot import.
fn is_base(text: String) -> Bool {
  text != ""
  && string.byte_size(text) <= 255
  && !string.starts_with(text, "-")
  && list.all(string.to_utf_codepoints(text), fn(point) {
    let code = string.utf_codepoint_to_int(point)
    code > 32 && code != 127
  })
}

/// Takes one switch out of the words, refusing a switch given twice, because a
/// repeated flag is more likely a mistake than an intention.
fn take_switch(
  arguments: List(String),
  flag: String,
) -> Result(#(Bool, List(String)), String) {
  case list.count(arguments, fn(word) { word == flag }) {
    0 -> Ok(#(False, arguments))
    1 -> Ok(#(True, list.filter(arguments, fn(word) { word != flag })))
    _ -> Error(flag <> " was given more than once")
  }
}

/// Takes `--base` and its value out of the words.
fn take_base(
  arguments: List(String),
) -> Result(#(Option(String), List(String)), String) {
  case list.count(arguments, fn(word) { word == "--base" }) {
    0 -> Ok(#(None, arguments))
    1 -> without_base(arguments, [])
    _ -> Error("--base was given more than once")
  }
}

/// Splits the words around the one `--base`, keeping the others in order.
fn without_base(
  arguments: List(String),
  kept: List(String),
) -> Result(#(Option(String), List(String)), String) {
  case arguments {
    [] -> Error("missing value for --base")
    ["--base"] -> Error("missing value for --base")
    ["--base", value, ..rest] ->
      Ok(#(Some(value), list.append(list.reverse(kept), rest)))
    [word, ..rest] -> without_base(rest, [word, ..kept])
  }
}

/// Builds a placement from the words of `--executor`, `--pool` and
/// `--workspace`.
///
/// Neither of the first two means a path on this host, and `--workspace` alone
/// is that path, so only an executor or a pool makes the workspace a registered
/// name. Naming both is refused, and so is either one with no workspace,
/// because the daemon has no default registered workspace to fall back on. The
/// refusals name the flag and say what it wanted, and they never echo a value
/// that is not a name.
///
/// ## Examples
///
/// ```gleam
/// assert placement.new(None, None, Some("/work")) == Ok(placement.OnThisHost)
/// assert placement.new(Some("box"), None, Some("app"))
///   == Ok(placement.OnExecutor("box", "app"))
/// assert placement.new(None, Some("builders"), Some("app"))
///   == Ok(placement.InPool("builders", "app"))
/// let assert Error(_) = placement.new(Some("box"), None, None)
/// ```
pub fn new(
  executor: Option(String),
  pool: Option(String),
  workspace: Option(String),
) -> Result(Placement, String) {
  case executor, pool, workspace {
    None, None, _ -> Ok(OnThisHost)
    Some(_), Some(_), _ ->
      Error(
        "--executor and --pool are exclusive: name where a session goes once",
      )
    Some(_), None, None ->
      Error(
        "--executor needs --workspace <registered name>, the name of a workspace registered on that executor",
      )
    None, Some(_), None ->
      Error(
        "--pool needs --workspace <registered name>, the name of a workspace registered on that pool's executors",
      )
    Some(executor), None, Some(workspace) ->
      case is_executor_name(executor), is_workspace_name(workspace) {
        False, _ ->
          Error(
            "--executor needs an executor name: a lowercase letter, then lowercase letters, numbers, _ or -, at most 32 characters",
          )
        True, False ->
          Error(
            "--workspace with --executor needs a registered workspace name: 1 to 128 bytes with no / and no NUL, not a path",
          )
        True, True -> Ok(OnExecutor(executor, workspace))
      }
    None, Some(pool), Some(workspace) ->
      case is_executor_name(pool), is_workspace_name(workspace) {
        False, _ ->
          Error(
            "--pool needs a pool name: a lowercase letter, then lowercase letters, numbers, _ or -, at most 32 characters",
          )
        True, False ->
          Error(
            "--workspace with --pool needs a registered workspace name: 1 to 128 bytes with no / and no NUL, not a path",
          )
        True, True -> Ok(InPool(pool, workspace))
      }
  }
}

/// How a listing names a workspace: the path of a session on the daemon's host,
/// or `executor:name` for a session on an executor, the way `scp` writes a
/// host and a path. A registered name has no `/`, so the two cannot be mistaken
/// for each other, and the label is display text only: nothing parses it back.
///
/// ## Examples
///
/// ```gleam
/// assert placement.label(None, "/work/loom") == "/work/loom"
/// assert placement.label(Some("box"), "app") == "box:app"
/// ```
pub fn label(executor: Option(String), workspace: String) -> String {
  case executor {
    Some(executor) -> executor <> ":" <> workspace
    None -> workspace
  }
}

/// Whether text is the name of an orchestrator: the key of an
/// `[orchestrators.<name>]` table, which has the grammar of an executor name.
/// `loom sessions move --to` takes one, and refuses anything else before a
/// daemon is asked.
///
/// ## Examples
///
/// ```gleam
/// assert placement.is_orchestrator_name("laptop")
/// assert !placement.is_orchestrator_name("Laptop")
/// ```
pub fn is_orchestrator_name(text: String) -> Bool {
  is_executor_name(text)
}

/// An executor or pool name has the grammar of a profile name.
fn is_executor_name(text: String) -> Bool {
  case string.to_graphemes(text) {
    [first, ..rest] ->
      string.drop_start(text, executor_name_limit) == ""
      && is_lowercase(first)
      && list.all(rest, fn(grapheme) {
        is_lowercase(grapheme)
        || grapheme == "_"
        || grapheme == "-"
        || list.contains(string.to_graphemes("0123456789"), grapheme)
      })
    [] -> False
  }
}

fn is_lowercase(grapheme: String) -> Bool {
  list.contains(string.to_graphemes("abcdefghijklmnopqrstuvwxyz"), grapheme)
}

fn is_workspace_name(text: String) -> Bool {
  text != ""
  && string.byte_size(text) <= workspace_name_limit
  && !string.contains(text, "/")
  && !string.contains(text, "\u{0}")
}
