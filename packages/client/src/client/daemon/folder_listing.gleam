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
//// The picker also indexes (`index_in`). The search over folder names is one
//// bounded walk of the home that the page holds and ranks in memory, not a walk
//// for each keystroke. The walk is the same read of the owner's files, so it keeps
//// the same rule from the other side: it follows no symbolic link, so every
//// directory it reports lies inside the canonical home by construction and none is
//// resolved one process at a time. It reads the folders that hold the owner's
//// remembered folders first, so a container of repositories is read before the
//// rest of the home spends the budget. Below a Git checkout it keeps descending but
//// lists only the folders that hold a `.git` themselves, which are its worktrees
//// and sub-repositories. It skips what a creation would refuse (hidden folders,
//// `~/Library`) and does not enter build output.
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

  let #(children, cut) = gather(home, folder, listable(names), [], 0, 0)

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

/// The names of a directory a picker or an index may show: not hidden, spelled so
/// a trail can carry them, and sorted without regard to case.
fn listable(names: List(String)) -> List(String) {
  list.filter(names, fn(name) {
    !string.starts_with(name, ".") && folder_browse.component_ok(name)
  })
  |> list.sort(fn(a, b) {
    string.compare(string.lowercase(a), string.lowercase(b))
  })
}

// The names an index lists but does not descend into. A folder of one of them is
// still an entry, since the person may be looking for it by name, but its contents
// are build output that no one starts a session inside.
const not_descended = ["node_modules", "_build", "build", "target"]

/// The bounds of one index build.
pub type Limits {
  Limits(
    /// The deepest directory listed, below the home.
    depth: Int,
    /// The most directories read.
    visits: Int,
    /// The most entries listed.
    entries: Int,
    /// The longest the build may run, in milliseconds.
    ms: Int,
  )
}

/// The bounds the daemon builds with.
pub const limits =
  Limits(
    depth: folder_browse.index_depth,
    visits: folder_browse.index_visit_limit,
    entries: folder_browse.index_entry_limit,
    ms: folder_browse.index_ms,
  )

// Whether a directory sits below a Git checkout, where only folders that hold a
// `.git` are listed.
type Context {
  Anywhere
  BelowCheckout
}

// A directory waiting to be read.
type Pending {
  Pending(trail: List(String), depth: Int, context: Context)
}

// The build's progress: the directories waiting (the front list is read first and
// the back list is the newest, reversed), the entries listed so far newest first
// with their count, the directories read and the instant to stop at.
type Walk {
  Walk(
    front: List(Pending),
    back: List(Pending),
    found: List(folder_browse.Entry),
    count: Int,
    read: Int,
    stop_at: Int,
  )
}

/// The index of the folder names below a canonical home directory.
///
/// `seeds` are absolute paths of folders the owner has used. Each one's parent, when
/// it lies below the home, is read before the rest of the home, so a container of
/// repositories is indexed first. A seed is a hint and not a path to trust: each of
/// its components is checked as a real, visible directory before it is read.
///
/// The walk is breadth first, follows no symbolic link and lists a directory only
/// when it is a real one. It stops, saying so, at the limits' directories read,
/// entries or time. A directory that cannot be read, or holds more than
/// `folder_browse.entry_limit` entries, is passed over.
///
/// ## Examples
///
/// ```gleam
/// // folder_listing.index_in("/Users/o", ["/Users/o/code/app"], folder_listing.limits, clock)
/// ```
pub fn index_in(
  home: String,
  seeds: List(String),
  bounds: Limits,
  now: fn() -> Int,
) -> folder_browse.Index {
  let parents = seed_trails(home, seeds, bounds)
  let start =
    Walk(
      front: list.append(
        list.map(parents, fn(seed) {
          Pending(seed.0, list.length(seed.0), seed.1)
        }),
        [Pending([], 0, Anywhere)],
      ),
      back: [],
      found: [],
      count: 0,
      read: 0,
      stop_at: now() + bounds.ms,
    )
  let #(entries, reach) =
    crawl(home, start, list.map(parents, fn(seed) { seed.0 }), bounds, now)

  folder_browse.Index(home:, entries:, reach:)
}

/// The distinct parent folders of the seeds, each with the context it is read in.
///
/// A parent is kept only when it lies below the home, is shallower than the depth
/// bound (so its children, one level down, are still trails a creation takes), and
/// every component of it is a real visible directory. Its context is
/// `BelowCheckout` when the home or any component holds a `.git`, because a
/// remembered folder inside a repository must not index the repository's internals
/// that the walk from the home would have left out.
fn seed_trails(
  home: String,
  seeds: List(String),
  bounds: Limits,
) -> List(#(List(String), Context)) {
  list.filter_map(seeds, fn(path) {
    // A seed outside the home names nothing the index may read, whatever its
    // spelling, so only a path that begins with the home and a slash is split.
    case string.starts_with(path, home <> "/") {
      True -> {
        let below = string.drop_start(path, string.length(home) + 1)
        let trail =
          string.split(below, "/")
          |> list.reverse
          |> list.drop(1)
          |> list.reverse

        // A home that is itself a checkout makes every seed below one.
        let outer = case holds_git(home) {
          True -> BelowCheckout
          False -> Anywhere
        }

        // An empty parent is the home, which is read anyway, and a deep one would
        // list trails past what a creation accepts.
        case trail != [] && list.length(trail) < bounds.depth {
          True ->
            real_trail(home, trail, [], outer)
            |> result.map(fn(context) { #(trail, context) })
          False -> Error(Nil)
        }
      }
      False -> Error(Nil)
    }
  })
  |> list.unique
}

/// The context a trail is read in, when every component of it is a visible real
/// directory, checked from the home down, so a link anywhere in it makes the whole
/// trail refused. A component that holds a `.git` makes the context `BelowCheckout`.
fn real_trail(
  home: String,
  rest: List(String),
  done: List(String),
  context: Context,
) -> Result(Context, Nil) {
  // The trail is walked from the home down, one component at a time, so the first
  // link or hidden name stops the walk before anything below it is touched.
  case rest {
    [] -> Ok(context)
    [name, ..more] -> {
      let so_far = list.append(done, [name])
      let path = string.join([home, ..so_far], "/")
      let allowed =
        listable([name]) == [name]
        && !is_library(list.length(done), name)
        && is_real_directory(path)

      // A component that is hidden, a link or not a directory refuses the trail;
      // one that holds a checkout changes how what is below it is listed.
      case allowed, holds_git(path) {
        False, _ -> Error(Nil)
        True, True -> real_trail(home, more, so_far, BelowCheckout)
        True, False -> real_trail(home, more, so_far, context)
      }
    }
  }
}

/// Reads the waiting directories in order until none is left or a bound is reached.
fn crawl(
  home: String,
  walk: Walk,
  seeds: List(List(String)),
  bounds: Limits,
  now: fn() -> Int,
) -> #(List(folder_browse.Entry), folder_browse.Reach) {
  let spent =
    walk.read >= bounds.visits
    || walk.count >= bounds.entries
    || now() >= walk.stop_at

  // The build ends with what it has when a bound is reached, and otherwise takes
  // the next waiting directory.
  case spent, take(walk) {
    True, _ -> #(list.reverse(walk.found), folder_browse.Stopped)
    False, Error(Nil) -> #(list.reverse(walk.found), folder_browse.Covered)
    False, Ok(#(item, rest)) ->
      crawl(
        home,
        read_into(home, rest, item, seeds, bounds),
        seeds,
        bounds,
        now,
      )
  }
}

/// The next waiting directory and the walk without it.
fn take(walk: Walk) -> Result(#(Pending, Walk), Nil) {
  // The back list is turned over only when the front is empty, so each directory
  // costs a constant and not the length of the queue.
  case walk.front {
    [item, ..rest] -> Ok(#(item, Walk(..walk, front: rest)))
    [] ->
      case list.reverse(walk.back) {
        [item, ..rest] -> Ok(#(item, Walk(..walk, front: rest, back: [])))
        [] -> Error(Nil)
      }
  }
}

/// Reads one directory: lists its children that may be shown and queues those that
/// may be read. A directory that holds a `.git`, or sits below one, lists only the
/// children that hold a `.git` themselves.
fn read_into(
  home: String,
  walk: Walk,
  item: Pending,
  seeds: List(List(String)),
  bounds: Limits,
) -> Walk {
  let folder = string.join([home, ..item.trail], "/")
  let walk = Walk(..walk, read: walk.read + 1)

  // A directory that cannot be read, or holds more than the entry bound, adds
  // nothing and is not retried.
  case read_children(folder) {
    Error(_) -> walk
    Ok(names) -> {
      let checkout = list.contains(names, ".git")

      // Everything below a checkout is read as below one: the walk goes on through
      // its folders to find sub-repositories, but lists only those.
      let below = case item.context, checkout {
        Anywhere, False -> Anywhere
        Anywhere, True | BelowCheckout, _ -> BelowCheckout
      }

      let children =
        listable(names)
        |> list.filter(fn(name) {
          !is_library(item.depth, name)
          && is_real_directory(folder <> "/" <> name)
        })

      list.fold(children, walk, fn(walk, name) {
        let trail = list.append(item.trail, [name])

        // Outside a checkout every folder is listed. Inside one, a folder is listed
        // only when it holds a `.git`, which is how a worktree or sub-repository
        // is told from the repository's own source folders.
        let shown = case item.context, checkout {
          Anywhere, False -> True
          Anywhere, True | BelowCheckout, _ -> holds_git(folder <> "/" <> name)
        }

        // The count is of listed entries, which is what the entry bound limits; a
        // folder that is only read through is queued below but not counted.
        let walk = case shown {
          True ->
            Walk(
              ..walk,
              found: [
                folder_browse.Entry(trail:, lower: string.lowercase(name)),
                ..walk.found
              ],
              count: walk.count + 1,
            )
          False -> walk
        }

        // A directory is read later only when it is above the depth bound, is not
        // build output and is not a seed, which is already waiting.
        case
          item.depth + 1 < bounds.depth
          && !list.contains(not_descended, string.lowercase(name))
          && !list.contains(seeds, trail)
        {
          True ->
            Walk(..walk, back: [
              Pending(trail, item.depth + 1, below),
              ..walk.back
            ])
          False -> walk
        }
      })
    }
  }
}

/// Whether a directory holds a `.git`, a directory in a checkout or a file in a
/// linked worktree.
fn holds_git(path: String) -> Bool {
  marker(path) == folder_browse.Repository
}

/// Whether a name is `Library` directly below the home, which a creation refuses
/// as hidden although no dot begins it, on a volume that ignores case.
fn is_library(depth: Int, name: String) -> Bool {
  depth == 0 && string.lowercase(name) == "library"
}

/// Whether a path is a directory itself and not a link to one, which is the one
/// kind of entry an index follows.
fn is_real_directory(path: String) -> Bool {
  case simplifile.link_info(path) {
    Ok(info) -> simplifile.file_info_type(info) == simplifile.Directory
    Error(_) -> False
  }
}
