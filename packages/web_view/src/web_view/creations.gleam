//// Creating a session from the home page: what the owner's page asks, what the
//// daemon answers, and the fixed words for each refusal (protocol-change/065,
//// the fourth pull request).
////
//// Creating a session starts an agent in a workspace, so it is the owner's act
//// and a page never holds owner authority. The page therefore asks the daemon
//// to make the same session the control command `sessions.create` makes,
//// through the same function and the same owner check, and the daemon decides
//// whether the page's principal may ask. A page chooses three things and no
//// others: one of the workspaces its own list drew, a name, and whether the
//// session is shareable. It never types a path. The workspace is the
//// catalogue's own text carried in the message the server drew, and the daemon
//// checks again that the owner already has a session in it, so a frame that
//// names a directory the owner has no session in creates nothing.
////
//// This module holds the types the request and its answer are made of, so the
//// page and the daemon agree on a vocabulary without the page learning
//// anything else about the daemon, and the one rule for a name, which both
//// the form and the daemon apply.
////
//// The owner may also open a session in a folder that holds none yet
//// (protocol-change/074), so a request names a `Place`: a workspace the page's
//// own list or its recent folders drew, or a path the owner typed. A typed path
//// is the one place a browser's text names a directory, so this module holds
//// the pure half of what the daemon does with it: the hygiene rule for the text
//// (`typed_path`), the expansion of a leading `~` (`expanded`) and the rule for
//// where a canonical folder may be (`inside`). The half that asks the
//// filesystem is the daemon's (`client/daemon/folders`).

import gleam/list
import gleam/string
import session_view/text_hygiene

/// The most bytes a session's name may hold: the catalogue's own bound.
pub const name_limit = 256

/// Whether the new session keeps its own notes and history apart from its
/// workspace's. The daemon's domain scopes are `session_only` and
/// `workspace_private`; the page words the choice by what it allows.
pub type Sharing {
  /// The session is isolated from its workspace's aggregate, so the owner may
  /// invite someone to it from its page afterwards (`web_view/invites`,
  /// `NotIsolated`).
  Shareable

  /// The session contributes to its workspace's aggregate and may not be
  /// shared with anyone. This is what a session created without the box ticked
  /// is, and what the terminal creates by default.
  Private
}

/// The most bytes a typed path may hold, which is the catalogue's own bound on
/// a workspace.
pub const path_limit = 4096

/// Where a creation asks for its session to be made.
pub type Place {
  /// A workspace the page drew: one the owner holds a session in, or one of the
  /// owner's recent folders. It is text the daemon wrote into the tree, and the
  /// daemon checks that it is still one of those.
  Drawn(workspace: String)

  /// A path the owner typed into the form for another folder. It is the
  /// browser's text and nothing else is: the daemon decides whether it names a
  /// folder the owner may use (`inside`, and the checks of
  /// `client/daemon/folders`).
  Typed(path: String)
}

/// A folder the owner recently started a session in, as the daemon remembers it.
/// `id` is the daemon's identity for the entry, which the page keys its list by
/// and names to forget one, so a press that was in flight when the list changed
/// reaches the same entry or nothing. `path` is the canonical folder, which the
/// page draws as a text node and nowhere else.
pub type Recent {
  Recent(id: Int, path: String)
}

/// What the daemon answers to a request to create a session.
pub type Answer {
  /// The session was created and opened, and the daemon minted a ticket for its
  /// page. `path` is the ticket's exchange, which the browser navigates to. The
  /// ticket is single use and lives 60 seconds.
  Ticketed(path: String)

  /// Nothing was created, or a session was created and did not open. Every
  /// page shows the fixed words for the reason (`reason_words`) and never the
  /// daemon's own text.
  Declined(reason: Reason)
}

/// Why no ticket was minted.
pub type Reason {
  /// The page's principal is not the daemon's owner, the page's ceiling is not
  /// an operator's, or the page has ended. One answer for each, so a page
  /// learns nothing else about its standing.
  NotOwner

  /// The workspace is not one the owner holds a session in. The page draws
  /// only such workspaces, so this is a list that changed under the person or
  /// a frame the page did not draw.
  NotKnown

  /// The typed path does not name a folder the daemon can use: it is empty,
  /// holds a control character, is not absolute once `~` is expanded, does not
  /// exist, is not a directory, or is not one the owner owns and may read and
  /// write. One answer for each, so a page learns nothing about the filesystem
  /// beyond whether the folder is usable.
  NotAFolder

  /// The folder exists and is usable, and is not inside the owner's home
  /// directory, or is the home directory itself, or is or lies in a hidden
  /// folder (one whose name begins with a dot).
  OutsideHome

  /// The name is empty after trimming, longer than `name_limit` bytes, or
  /// holds a control, zero-width or direction-changing character.
  InvalidName

  /// This credential has created as many sessions as it may recently. The
  /// count is the daemon's and is kept for the credential and not for the page,
  /// so opening another page does not reset it.
  TooMany

  /// The daemon has no room for another running session.
  Full

  /// The session was created and did not become resident in time, or the
  /// registry refused to open it. It exists and is in the list.
  NotOpened

  /// The daemon could not answer: it was starting, stopping or slow, or the
  /// directory could not be used.
  Unavailable
}

/// The words a page shows for a refusal. They are fixed here, one per reason,
/// so nothing the daemon wrote reaches a browser.
///
/// ## Examples
///
/// ```gleam
/// assert creations.reason_words(creations.TooMany)
///   == "You have created many sessions this hour. Try again later."
/// ```
pub fn reason_words(reason: Reason) -> String {
  case reason {
    NotOwner -> "Only the owner can create a session."
    NotKnown -> "That workspace is not in your list. Reload the page."
    NotAFolder ->
      "That folder does not exist or cannot be used. Give the path of a folder you own."
    OutsideHome ->
      "Choose a folder inside your home directory. The home directory itself and hidden folders are not allowed."
    InvalidName ->
      "Use a name of up to 256 bytes with no control or invisible characters."
    TooMany -> "You have created many sessions this hour. Try again later."
    Full -> "The daemon has no room for another session. Stop one first."
    NotOpened ->
      "The session was created and did not open. It will appear in the list shortly; resume it from there."
    Unavailable -> "The daemon could not create the session. Try again."
  }
}

/// The name a creation uses: the typed name with its ends trimmed, or the
/// workspace's folder name when none was typed, or `Error(Nil)` for a name the
/// catalogue's bound or the page's text rule refuses.
///
/// The text rule is the one that draws a name safely anywhere: a name that
/// `text_hygiene.single_line` would change (a control, a newline, a zero-width
/// or direction-changing character) is refused rather than changed, so the
/// session is called what the owner typed.
///
/// ## Examples
///
/// ```gleam
/// assert creations.chosen_name("  review  ", "/work/loom") == Ok("review")
/// assert creations.chosen_name("", "/work/loom") == Ok("loom")
/// assert creations.chosen_name("a\nb", "/work/loom") == Error(Nil)
/// ```
pub fn chosen_name(typed: String, workspace: String) -> Result(String, Nil) {
  let typed = string.trim(typed)
  let name = case typed {
    "" -> folder(workspace)
    named -> named
  }
  case
    name != ""
    && string.byte_size(name) <= name_limit
    && text_hygiene.single_line(name) == name
  {
    True -> Ok(name)
    False -> Error(Nil)
  }
}

/// The name a blank field gets: the last non-empty segment of the workspace's
/// path, or "New session" for a path with none, which a canonical workspace
/// never has except the root.
///
/// ## Examples
///
/// ```gleam
/// assert creations.folder("/work/loom") == "loom"
/// assert creations.folder("/") == "New session"
/// ```
pub fn folder(workspace: String) -> String {
  let segments =
    string.split(workspace, "/") |> list.filter(fn(part) { part != "" })
  case list.last(segments) {
    Ok(name) -> name
    Error(Nil) -> "New session"
  }
}

/// The path a form's text stands for, or `Error(Nil)` for text that cannot name
/// a folder: empty after trimming, longer than `path_limit` bytes, or holding a
/// control, zero-width or direction-changing character (the rule `chosen_name`
/// applies to a name). The text is not otherwise judged here; the daemon decides
/// whether the folder exists.
///
/// ## Examples
///
/// ```gleam
/// assert creations.typed_path("  ~/code/app ") == Ok("~/code/app")
/// assert creations.typed_path("") == Error(Nil)
/// assert creations.typed_path("/a\nb") == Error(Nil)
/// ```
pub fn typed_path(typed: String) -> Result(String, Nil) {
  let path = string.trim(typed)
  case
    path != ""
    && string.byte_size(path) <= path_limit
    && text_hygiene.single_line(path) == path
  {
    True -> Ok(path)
    False -> Error(Nil)
  }
}

/// The absolute path a typed one names, with a leading `~` standing for `home`,
/// or `Error(Nil)` for a path that is neither absolute nor `~`-relative. A
/// relative path would be resolved against the daemon's own working directory,
/// which the owner cannot see, so it is refused. `~user` is refused as well: it
/// would name another account's home.
///
/// ## Examples
///
/// ```gleam
/// assert creations.expanded("~/code", "/home/o") == Ok("/home/o/code")
/// assert creations.expanded("~", "/home/o") == Ok("/home/o")
/// assert creations.expanded("/srv/app", "/home/o") == Ok("/srv/app")
/// assert creations.expanded("code", "/home/o") == Error(Nil)
/// assert creations.expanded("~root/x", "/home/o") == Error(Nil)
/// ```
pub fn expanded(path: String, home: String) -> Result(String, Nil) {
  case path {
    "~" -> Ok(home)
    "~/" <> rest -> Ok(home <> "/" <> rest)
    "/" <> _ -> Ok(path)
    _ -> Error(Nil)
  }
}

// macOS keeps Keychains, Cookies, browser profiles and Mail in `~/Library`, which
// Finder hides without a dot. The volume is case-insensitive, so the comparison
// is too.
fn first_is_library(segments: List(String)) -> Bool {
  case segments {
    [first, ..] -> string.lowercase(first) == "library"
    [] -> False
  }
}

/// Whether a canonical folder may start a session, given the canonical home
/// directory: it must lie strictly inside `home`, and no segment below home may
/// begin with a dot, and the first may not be `Library` in any case.
///
/// A session's agent may write to its whole workspace, so the home directory
/// itself would hand it every dotfile and credential the owner keeps there. The
/// hidden-folder rule keeps it from `~/.ssh`, `~/.aws`, `~/.config` and the
/// daemon's own default state directory, where a session's conversation is
/// kept. Both arguments are already resolved through symbolic links and `..`
/// (`bootstrap.canonical_directory`), so the comparison is of segments and no
/// link or dot-dot can step outside it.
///
/// ## Examples
///
/// ```gleam
/// assert creations.inside("/home/o", "/home/o/code/app") == Ok(Nil)
/// assert creations.inside("/home/o", "/home/o") == Error(creations.OutsideHome)
/// assert creations.inside("/home/o", "/home/other") == Error(creations.OutsideHome)
/// assert creations.inside("/home/o", "/home/o/.ssh") == Error(creations.OutsideHome)
/// assert creations.inside("/home/o", "/home/o/Library/Keychains") == Error(creations.OutsideHome)
/// ```
pub fn inside(home: String, folder: String) -> Result(Nil, Reason) {
  case string.starts_with(folder, home <> "/") {
    False -> Error(OutsideHome)
    True -> {
      let below = string.drop_start(folder, string.length(home) + 1)
      let segments = string.split(below, "/")
      let hidden =
        list.any(segments, string.starts_with(_, "."))
        || first_is_library(segments)
      case below != "" && !hidden {
        True -> Ok(Nil)
        False -> Error(OutsideHome)
      }
    }
  }
}
