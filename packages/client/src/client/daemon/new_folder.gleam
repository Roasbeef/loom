//// Whether a path the owner typed names a folder a session may start in
//// (protocol-change/074).
////
//// The home page's form for another folder is the one place a browser's text
//// names a directory, and a session's agent may write to its whole workspace, so
//// the daemon decides what a path may be and the page only words the refusal.
//// `creations` holds the pure half of the rule (the text's hygiene, the `~`
//// expansion and where a canonical folder may lie); this module is the half that
//// asks the filesystem, because only the host can say what a path resolves to.
////
//// The order matters. The text is checked first, then `~` is expanded against the
//// home directory, then the path is made canonical, which resolves every symbolic
//// link and `..` and fails for a path that does not exist or is not a directory.
//// Only the canonical path is judged against the home directory, so a link inside
//// home that points outside it, or a `..` that climbs out, is refused for where it
//// ends up and not for how it was spelled. Last, the folder must be owned by the
//// user the home directory is owned by and that owner must be able to read,
//// write and search it, which is what a session in it needs and what a folder the
//// daemon's user merely passes through lacks.
////
//// Nothing here echoes the path: every refusal is a `creations.Reason` whose
//// words are fixed, one sentence for each reason (`creations.reason_words`).
////
//// ## Flow
////
//// `check` → `check_in` → `usable`
////
//// 1. `check` reads the daemon user's home directory (`home`) and calls
////    `check_in`, which a test calls with a home of its own.
//// 2. `check_in` applies the pure rules and the canonical resolution, and returns
////    the canonical folder.
//// 3. `apart_from` keeps a folder away from the daemon's own state directory.
//// 4. `usable` compares the folder's owner and mode with the home directory's.

import gleam/int
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import web_view/creations.{type Reason}

/// The daemon user's home directory in canonical form, or `Unavailable` when the
/// environment names none or it cannot be resolved. The owner's own home is the
/// bound a typed folder must lie in, so a daemon that cannot find it offers no
/// folder rather than guessing one.
///
/// ## Examples
///
/// ```gleam
/// // new_folder.home()
/// ```
pub fn home() -> Result(String, Reason) {
  bootstrap.getenv("HOME")
  |> result.replace_error(creations.Unavailable)
  |> result.try(fn(path) {
    bootstrap.canonical_directory(path)
    |> result.replace_error(creations.Unavailable)
  })
}

/// The canonical folder a typed or remembered path names, if a session may start
/// there, judged against the daemon user's home directory.
///
/// ## Examples
///
/// ```gleam
/// // new_folder.check("~/code/app")
/// ```
pub fn check(typed: String, state_root: String) -> Result(String, Reason) {
  use home <- result.try(home())
  check_in(typed, home, state_root)
}

/// `check` against a given canonical home directory, so a test names one.
///
/// A path that is empty, holds a control character, is relative, does not exist
/// or is not a directory is `NotAFolder`, as is a folder the home directory's
/// owner does not own or cannot read, write and search. A canonical folder that
/// is the home directory itself, lies outside it or lies in a hidden folder is
/// `HomeItself`, `OutsideHome` or `HiddenFolder` (`creations.inside`), and the
/// daemon's own state folder, or one containing or inside it, is `StateFolder`.
///
/// ## Examples
///
/// ```gleam
/// // new_folder.check_in("~/code/app", "/Users/o")
/// ```
pub fn check_in(
  typed: String,
  home: String,
  state_root: String,
) -> Result(String, Reason) {
  use path <- result.try(
    creations.typed_path(typed) |> result.replace_error(creations.NotAFolder),
  )
  use absolute <- result.try(
    creations.expanded(path, home) |> result.replace_error(creations.NotAFolder),
  )
  use folder <- result.try(
    bootstrap.canonical_directory(absolute)
    |> result.replace_error(creations.NotAFolder),
  )
  use Nil <- result.try(creations.inside(home, folder))
  use Nil <- result.try(apart_from(folder, state_root))
  use Nil <- result.map(usable(folder, home))
  folder
}

// A session's workspace is writable, so a folder that is the daemon's state
// directory, lies in it or contains it would hand the agent the catalogue, the
// credentials and every session's database. The default state directory is
// hidden and so already refused; this covers one the owner placed elsewhere in
// home. The state root is canonicalized here so a link to it is no way round;
// one that cannot be resolved refuses every folder, which fails closed.
fn apart_from(folder: String, state_root: String) -> Result(Nil, Reason) {
  use root <- result.try(
    bootstrap.canonical_directory(state_root)
    |> result.replace_error(creations.Unavailable),
  )
  case
    folder == root
    || string.starts_with(folder, root <> "/")
    || string.starts_with(root, folder <> "/")
  {
    True -> Error(creations.StateFolder)
    False -> Ok(Nil)
  }
}

// The folder's owner is the home directory's, and that owner has read, write and
// search permission on it. The daemon runs as the owner of the home directory,
// so the comparison stands in for "owned by the daemon user" without asking the
// operating system for the daemon's own identity.
fn usable(folder: String, home: String) -> Result(Nil, Reason) {
  let info = fn(path) {
    simplifile.file_info(path) |> result.replace_error(creations.NotAFolder)
  }
  use folder_info <- result.try(info(folder))
  use home_info <- result.try(info(home))
  let owner_all = 0o700
  case
    folder_info.user_id == home_info.user_id
    && int.bitwise_and(folder_info.mode, owner_all) == owner_all
  {
    True -> Ok(Nil)
    False -> Error(creations.NotAFolder)
  }
}
