//// The directories below the owner's home, listed for the web composer's folder
//// picker (protocol-change/132).
////
//// A browser cannot name a folder on the daemon's machine, so the page draws a
//// picker and asks the daemon what is there. That is a read of the owner's files
//// by a browser, so this module is where its bounds and refusals are made, and
//// the page only words them. `web_view/folder_browse` holds the vocabulary and
//// the pure rules; this module asks the filesystem, which is the one thing only
//// the host can do.
////
//// The order is the safety. The trail the page sent is judged by its spelling
//// first (`folder_browse.trail_ok`), then joined to the canonical home and made
//// canonical again, which resolves every link and fails for a name that does not
//// exist. Only the canonical path is judged against the home, so a link inside
//// the home that leads out of it is refused for where it ends and not for what
//// it is called. The same judgement is made for each child, so a link out is
//// never even listed, and the page cannot be offered a row it could not open.
////
//// Nothing here echoes a path or the operating system's error: every refusal is
//// one of `folder_browse.Refusal`, whose words are fixed.
////
//// ## Flow
////
//// `list_in` → `resolved` → `children_of` → `gather`
////
//// 1. `list_in` takes the canonical home the caller read, checks the trail's
////    spelling and depth, and asks `resolved` for the canonical directory.
//// 2. `children_of` reads the directory under the entry bound
////    (`read_children`), so a directory with more entries than
////    `folder_browse.entry_limit` costs one listing and no further call.
//// 3. `gather` walks the sorted names, keeps those that are directories inside
////    the home, marks a Git checkout, and stops at `folder_browse.shown_limit`.

import gleam/list
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import web_view/creations
import web_view/folder_browse.{type Answer, type Child, type Cut, type Refusal}

// The text `bootstrap.list_directory_bounded` returns for a directory over the
// limit. It is the one failure the picker words differently from the others, and
// `folder_listing_test` fails if the text changes.
const over_limit = "directory exceeds the entry limit"

/// Lists the directory a trail names below a canonical home directory. The
/// daemon passes the home it read from the environment (`new_folder.home`), and a
/// test names one.
///
/// A trail with a component `folder_browse.component_ok` refuses is `NotAFolder`,
/// and one longer than `folder_browse.depth_limit` is `TooDeep`, both before the
/// filesystem is touched. A trail that does not resolve to a directory that is
/// the home or inside it is `NotAFolder`, which covers a missing name, a file, a
/// link that leaves the home, a hidden folder and `~/Library`. A canonical
/// directory deeper than the limit, which a link can make of a short trail, is
/// `TooDeep`; one exactly at the limit lists no children.
///
/// ## Examples
///
/// ```gleam
/// // folder_listing.list_in("/Users/o", ["code"])
/// ```
pub fn list_in(home: String, trail: List(String)) -> Answer {
  use Nil <- result.try(spelled(trail))
  use folder <- result.try(resolved(home, trail))
  let below = trail_below(home, folder)
  use Nil <- result.try(shallow(below))

  // A directory at the limit is chosen or typed for, never opened further. The
  // trail passed `shallow`, so it is at the limit when it has a last component
  // at that depth.
  case list.drop(below, folder_browse.depth_limit - 1) {
    [_, ..] ->
      Ok(folder_browse.Listing(
        trail: below,
        children: [],
        cut: folder_browse.AtDepthLimit,
      ))
    [] -> children_of(home, folder, below)
  }
}

/// A trail's spelling: the depth is `TooDeep` and any component the rule refuses is
/// `NotAFolder`, in that order, so a very long trail is not read component by
/// component first.
fn spelled(trail: List(String)) -> Result(Nil, Refusal) {
  use Nil <- result.try(shallow(trail))

  // A component the rule refuses, such as `..` or one holding a slash, means the
  // trail names no folder, however the filesystem would have read it.
  case list.all(trail, folder_browse.component_ok) {
    True -> Ok(Nil)
    False -> Error(folder_browse.NotAFolder)
  }
}

/// A trail within the depth bound.
fn shallow(trail: List(String)) -> Result(Nil, Refusal) {
  case list.drop(trail, folder_browse.depth_limit) {
    [_, ..] -> Error(folder_browse.TooDeep)
    [] -> Ok(Nil)
  }
}

/// The canonical directory a trail names, when it is the home or lies inside it by
/// `creations.inside`. The home itself is the one place `inside` refuses that a
/// listing allows, since the picker starts there and only a creation may not.
fn resolved(home: String, trail: List(String)) -> Result(String, Refusal) {
  let joined = string.join([home, ..trail], "/")

  use folder <- result.try(
    bootstrap.canonical_directory(joined)
    |> result.replace_error(folder_browse.NotAFolder),
  )

  // The home is listed, a directory inside it is listed, and everything else,
  // which includes a link that ended outside and a hidden or `Library` folder, is
  // refused in the words of a folder that is not there.
  case folder == home, creations.inside(home, folder) {
    True, _ | False, Ok(Nil) -> Ok(folder)
    False, Error(_) -> Error(folder_browse.NotAFolder)
  }
}

/// The components of a canonical directory below the home, outermost first.
fn trail_below(home: String, folder: String) -> List(String) {
  case folder == home {
    True -> []
    False ->
      string.drop_start(folder, string.length(home) + 1)
      |> string.split("/")
  }
}

/// The listing of a directory that may be opened.
fn children_of(home: String, folder: String, below: List(String)) -> Answer {
  use names <- result.try(read_children(folder))

  let sorted =
    list.filter(names, fn(name) { !string.starts_with(name, ".") })
    |> list.filter(folder_browse.component_ok)
    |> list.sort(fn(a, b) {
      string.compare(string.lowercase(a), string.lowercase(b))
    })
  let #(children, cut) = gather(home, folder, sorted, [], 0)

  Ok(folder_browse.Listing(trail: below, children:, cut:))
}

/// One directory's entries under the entry bound. The bound is the reader's own,
/// which refuses a directory over it and so never returns a part of one.
fn read_children(folder: String) -> Result(List(String), Refusal) {
  bootstrap.list_directory_bounded(folder, folder_browse.entry_limit)
  |> result.map_error(fn(error) {
    case error == over_limit {
      True -> folder_browse.TooMany
      False -> folder_browse.Unreadable
    }
  })
}

/// Walks the sorted names. A name is kept when it is a directory that is canonical
/// inside the home, the same test the trail itself passes, so a link out of the
/// home, a file and a dangling link are left out. The walk stops once
/// `shown_limit` are kept and says so when a name remained, without examining it.
fn gather(
  home: String,
  folder: String,
  names: List(String),
  kept: List(Child),
  count: Int,
) -> #(List(Child), Cut) {
  case names {
    [] -> #(list.reverse(kept), folder_browse.Whole)
    [_, ..] if count >= folder_browse.shown_limit -> #(
      list.reverse(kept),
      folder_browse.CutShort,
    )
    [name, ..rest] ->
      case child(home, folder, name) {
        Ok(each) -> gather(home, folder, rest, [each, ..kept], count + 1)
        Error(Nil) -> gather(home, folder, rest, kept, count)
      }
  }
}

/// One name as a child row, or `Error(Nil)` for one that is not a directory
/// inside the home. Its marker is one look at `.git` in the directory it resolves
/// to, so a linked checkout is marked as the checkout it is.
fn child(home: String, folder: String, name: String) -> Result(Child, Nil) {
  use real <- result.try(
    bootstrap.canonical_directory(folder <> "/" <> name)
    |> result.replace_error(Nil),
  )
  use Nil <- result.map(
    creations.inside(home, real) |> result.replace_error(Nil),
  )

  folder_browse.Child(name:, marker: marker(real))
}

/// Whether a directory holds a `.git`: a directory in a checkout, a file in a
/// linked worktree.
fn marker(real: String) -> folder_browse.Marker {
  let git = real <> "/.git"

  // Either answer says it is a checkout, and a path that cannot be examined is
  // taken to be a plain folder, since the mark is only a hint on the row.
  case simplifile.is_directory(git), simplifile.is_file(git) {
    Ok(True), _ | _, Ok(True) -> folder_browse.Repository
    Ok(False), Ok(False)
    | Ok(False), Error(_)
    | Error(_), Ok(False)
    | Error(_), Error(_)
    -> folder_browse.Plain
  }
}
