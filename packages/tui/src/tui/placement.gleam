//// Where a newly created session's workspace lives: a directory on the
//// daemon's own host, or a name registered on an executor
//// (protocol-change/078).
////
//// The two are different kinds of text. A path on the daemon's host is
//// canonicalized there; a registered name is never canonicalized, statted or
//// created on this machine, because only the executor can resolve it. The
//// terminal therefore keeps the name apart from every path it handles. It
//// never reaches the launcher's `--workspace` resolution, the footer's
//// repository probe or the picker's path arithmetic as if it were a
//// directory, and a launch cannot name an executor without a workspace or a
//// workspace without an executor, because both live in one variant.
////
//// The shape rules below repeat the daemon's (`storage/catalogue`), which this
//// package cannot import. They exist to refuse a typo before a daemon round
//// trip; the daemon judges the same text again when the creation arrives, so a
//// rule that drifts here can only make this client stricter or looser than the
//// daemon, never unsafe.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The longest executor name the daemon accepts, in characters.
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
}

/// Builds a placement from the words of `--executor` and `--workspace`.
///
/// Neither flag means a path on this host, and `--workspace` alone is that
/// path, so only an executor makes the workspace a registered name. An
/// executor with no workspace is refused, because the daemon has no default
/// registered workspace to fall back on. The refusals name the flag and say
/// what it wanted, and they never echo a value that is not a name.
///
/// ## Examples
///
/// ```gleam
/// assert placement.new(None, Some("/work")) == Ok(placement.OnThisHost)
/// assert placement.new(Some("box"), Some("app"))
///   == Ok(placement.OnExecutor("box", "app"))
/// let assert Error(_) = placement.new(Some("box"), None)
/// ```
pub fn new(
  executor: Option(String),
  workspace: Option(String),
) -> Result(Placement, String) {
  case executor, workspace {
    None, _ -> Ok(OnThisHost)
    Some(_), None ->
      Error(
        "--executor needs --workspace <registered name>, the name of a workspace registered on that executor",
      )
    Some(executor), Some(workspace) ->
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

// An executor name has the grammar of a profile name.
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
