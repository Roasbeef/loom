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
//// The picker also searches (`find_in`). A search is the same read of the owner's
//// files, so it keeps the same rule from the other side: it walks real
//// directories and follows no symbolic link, so every directory it reports lies
//// inside the canonical home by construction and none is resolved one process at
//// a time. It is bounded in depth, in directories read and in hits
//// (`folder_browse.find_depth`, `visit_limit`, `find_limit`), skips what a
//// creation would refuse (hidden folders, `~/Library`), and does not descend into
//// build output, where a checkout keeps thousands of directories nobody starts a
//// session in.
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
////    the home, marks a Git checkout, and stops at `folder_browse.shown_limit` kept
////    or `folder_browse.inspect_limit` examined.

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

  // A link can end in a directory whose real name `component_ok` refuses, such
  // as one with a space at either end. The trail drawn would then be one the
  // page could not send back, so it is refused as a folder that is not there.
  use Nil <- result.try(case list.all(below, folder_browse.component_ok) {
    True -> Ok(Nil)
    False -> Error(folder_browse.NotAFolder)
  })

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

  // The resolver trims a space at either end of a name, so a link to such a
  // directory resolves to a path that is not there. The canonical path must be
  // a directory as it is spelled.
  use Nil <- result.try(case simplifile.is_directory(folder) {
    Ok(True) -> Ok(Nil)
    Ok(False) | Error(_) -> Error(folder_browse.NotAFolder)
  })

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
  let #(children, cut) = gather(home, folder, sorted, [], 0, 0)

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
/// `shown_limit` are kept or `inspect_limit` names are examined, and says so when a
/// name remained, without examining it.
fn gather(
  home: String,
  folder: String,
  names: List(String),
  kept: List(Child),
  count: Int,
  examined: Int,
) -> #(List(Child), Cut) {
  // The walk ends at the end of the names, or says it was cut when either bound
  // is reached while names remain: rows kept, or names made canonical, which
  // counts the ones that were refused.
  case names {
    [] -> #(list.reverse(kept), folder_browse.Whole)
    [_, ..]
      if count >= folder_browse.shown_limit
      || examined >= folder_browse.inspect_limit
    -> #(list.reverse(kept), folder_browse.CutShort)
    [name, ..rest] ->
      case child(home, folder, name) {
        Ok(each) ->
          gather(home, folder, rest, [each, ..kept], count + 1, examined + 1)
        Error(Nil) -> gather(home, folder, rest, kept, count, examined + 1)
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

// The names a search reads but does not descend into. A hit may still be one of
// them, since the person may be looking for it by name, but its contents are
// build output that no one starts a session inside.
const not_descended = ["node_modules", "_build", "build", "target"]

/// The directories below a canonical home directory whose name holds the
/// fragment `text` says, shallowest first and in name order within a level.
///
/// The text is judged by `folder_browse.needle` again here, whatever the page did,
/// and a text it refuses is `NotAFolder`, a case no page of ours produces. The
/// walk is breadth first so that a match near the home is found before a match
/// deep in a checkout, and it stops at `folder_browse.find_limit` hits or
/// `visit_limit` directories read, saying so. A directory that cannot be read, or
/// holds more than `folder_browse.entry_limit` entries, is passed over without
/// being reported. Hidden names, `~/Library` and any name `component_ok` refuses
/// are neither reported nor read, and a symbolic link is neither, since only a
/// real directory is followed.
///
/// ## Examples
///
/// ```gleam
/// // folder_listing.find_in("/Users/o", "loom")
/// ```
pub fn find_in(home: String, text: String) -> folder_browse.FindAnswer {
  use fragment <- result.try(
    folder_browse.needle(text) |> result.replace_error(folder_browse.NotAFolder),
  )

  let #(found, reach) = sweep(home, fragment, [[]], 0, 0, [])

  Ok(folder_browse.Found(
    hits: list.map(found, fn(trail) {
      folder_browse.Hit(
        trail:,
        marker: marker(string.join([home, ..trail], "/")),
      )
    }),
    reach:,
  ))
}

/// Reads one level of directories, then the level below the directories of it
/// that may be descended into. `visited` counts directories read across levels and
/// `found` holds the hits so far, newest first.
fn sweep(
  home: String,
  fragment: String,
  level: List(List(String)),
  depth: Int,
  visited: Int,
  found: List(List(String)),
) -> #(List(List(String)), folder_browse.Reach) {
  // A level with no directory left ends the search having looked everywhere; a
  // level below `find_depth` is not read.
  case level, depth >= folder_browse.find_depth {
    [], _ | _, True -> #(list.reverse(found), folder_browse.Covered)
    [_, ..], False -> {
      let read = read_level(home, fragment, level, depth, visited, found, [])

      // The walk goes on to the next level, or ends where a bound was reached.
      case read {
        Capped(found:) -> #(list.reverse(found), folder_browse.Stopped)
        Ran(next:, visited:, found:) ->
          sweep(home, fragment, next, depth + 1, visited, found)
      }
    }
  }
}

// What reading a level gave: the directories of the next level with the counts so
// far, or the fact that a bound was reached.
type Level {
  Ran(next: List(List(String)), visited: Int, found: List(List(String)))
  Capped(found: List(List(String)))
}

/// Reads each directory of a level in turn, adding its matching children to
/// `found` and its descendable children to `next`. It stops, keeping what it
/// found, when `visit_limit` directories were read or `find_limit` hits are in
/// hand.
fn read_level(
  home: String,
  fragment: String,
  level: List(List(String)),
  depth: Int,
  visited: Int,
  found: List(List(String)),
  next: List(List(String)),
) -> Level {
  // A level is read directory by directory until it is done or a bound stops it.
  case level {
    [] -> Ran(next: list.reverse(next), visited:, found:)
    [_, ..] if visited >= folder_browse.visit_limit -> Capped(found:)
    [trail, ..rest] -> {
      let children = children_below(home, trail, depth)

      // A level's children are matched first and descended into afterwards, so
      // the hit cap is reached by the shallowest matches.
      let #(found, capped) = add_hits(fragment, trail, children, found)

      // The hit cap ends the walk here, and otherwise the level goes on.
      case capped {
        True -> Capped(found:)
        False ->
          read_level(
            home,
            fragment,
            rest,
            depth,
            visited + 1,
            found,
            list.append(
              list.reverse(
                list.filter_map(children, fn(name) { descended(trail, name) }),
              ),
              next,
            ),
          )
      }
    }
  }
}

/// The names of the real directories inside one directory that a search may
/// report, sorted without regard to case. A link is not a real directory, a name
/// a creation would refuse is left out, and a directory that cannot be read or
/// holds more than the entry bound has none.
fn children_below(
  home: String,
  trail: List(String),
  depth: Int,
) -> List(String) {
  let folder = string.join([home, ..trail], "/")

  // A directory that cannot be read has no children to report.
  case read_children(folder) {
    Error(_) -> []
    Ok(names) ->
      list.filter(names, fn(name) {
        !string.starts_with(name, ".")
        && folder_browse.component_ok(name)
        && !is_library(depth, name)
        && is_real_directory(folder <> "/" <> name)
      })
      |> list.sort(fn(a, b) {
        string.compare(string.lowercase(a), string.lowercase(b))
      })
  }
}

/// Whether a name is `Library` directly below the home, which a creation refuses
/// as hidden although no dot begins it, on a volume that ignores case.
fn is_library(depth: Int, name: String) -> Bool {
  depth == 0 && string.lowercase(name) == "library"
}

/// Whether a path is a directory itself and not a link to one, which is the one
/// kind of entry a search follows.
fn is_real_directory(path: String) -> Bool {
  case simplifile.link_info(path) {
    Ok(info) -> simplifile.file_info_type(info) == simplifile.Directory
    Error(_) -> False
  }
}

/// Adds the children whose name holds the fragment to the hits, stopping at
/// `find_limit`. The boolean is whether the cap was reached with children left.
fn add_hits(
  fragment: String,
  trail: List(String),
  children: List(String),
  found: List(List(String)),
) -> #(List(List(String)), Bool) {
  gather_hits(fragment, trail, children, found, list.length(found))
}

/// Walks the children with the count of hits held, so the cap is a comparison and
/// not a count of the list at each name.
fn gather_hits(
  fragment: String,
  trail: List(String),
  children: List(String),
  found: List(List(String)),
  count: Int,
) -> #(List(List(String)), Bool) {
  // The children are walked in order until the hit cap is reached.
  case children {
    [] -> #(found, False)
    [_, ..] if count >= folder_browse.find_limit -> #(found, True)
    [name, ..rest] -> {
      let below = list.append(trail, [name])

      // A child whose name holds the fragment is kept as a hit.
      case folder_browse.matches(fragment, below) {
        True -> gather_hits(fragment, trail, rest, [below, ..found], count + 1)
        False -> gather_hits(fragment, trail, rest, found, count)
      }
    }
  }
}

/// The trail of a child that a search reads next, or `Error(Nil)` for one it
/// does not descend into.
fn descended(trail: List(String), name: String) -> Result(List(String), Nil) {
  case list.contains(not_descended, string.lowercase(name)) {
    True -> Error(Nil)
    False -> Ok(list.append(trail, [name]))
  }
}
