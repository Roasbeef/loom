//// The folder picker's vocabulary: what the owner's page asks of the daemon to
//// walk the directories below the owner's home, what it answers, and the fixed
//// words for each refusal (protocol-change/132).
////
//// The composer's "Open folder…" draws a picker in the page, because a
//// browser's file dialog cannot name a path on the daemon's machine. The picker
//// needs the daemon to say which directories exist, and that lists the owner's
//// files to a browser, so the request is narrow. The page never sends a path. It
//// sends a trail, the names of the directories below the home from the outermost
//// in, and the daemon (`client/daemon/folder_listing`) resolves it against the
//// home it reads itself, so a trail cannot name anything outside the home
//// however it is spelled.
////
//// This module is the pure half. It holds the bounds, the rule for a name that
//// may be a component of a trail, the types of the answer, and the words. The
//// half that asks the filesystem is the daemon's, because only the host can say
//// what a name resolves to.
////
//// The picker also finds. The folder search (protocol-change/132, the addendum
//// on searching) asks the daemon once for an index of the folder names below the
//// home, and the page ranks that index in memory for each keystroke. The only
//// browser text the search reads is the fragment, which `needle` judges here, and
//// a hit is a trail the page keeps and names by index.
////
//// ## Flow
////
//// `component_ok` and `trail_ok` → the daemon lists → `Listing` or `Refusal`
////
//// 1. The page builds a trail from the listing it holds: the listing's own trail
////    plus a child's name, or a prefix of the trail. It never builds one from
////    the browser's text.
//// 2. The daemon checks the trail's spelling (each name with `component_ok`) and
////    its depth against the depth bound, resolves the trail against the home, and
////    answers a `Listing` whose trail is the canonical one, or a `Refusal`.
//// 3. `trail_text` writes a trail as the `~/` path the creation judges.
////
//// the daemon indexes once → `needle` → `rank`
////
//// 1. The daemon walks the home breadth first, bounded in depth, directories read,
////    entries and time, and answers an `Index` of folder names.
//// 2. `needle` turns the typed text into the lowercase fragment, or refuses a
////    fragment too short to be worth ranking.
//// 3. `rank` picks the best entries for the fragment, and `hit_trail` is the one
////    place a found folder becomes a trail the creation judges.

import gleam/int
import gleam/list
import gleam/order
import gleam/string
import session_view/text_hygiene

/// The most directories below the home a trail may name.
pub const depth_limit = 8

/// The most entries a directory may hold and still be listed. A directory with
/// more is refused rather than cut, so the owner is never shown a part of it
/// as though it were the whole.
pub const entry_limit = 1000

/// The most names one listing makes canonical, kept or not. Each costs a process
/// to resolve, so the bound counts the names refused as well as those shown: a
/// directory of a thousand links out costs this many and no more.
pub const inspect_limit = 300

/// The most child directories one listing returns.
pub const shown_limit = 200

/// The most bytes one name may hold, the filesystem's own bound.
pub const name_limit = 255

/// The fewest characters a search fragment may hold. One letter matches most of
/// the home and says little.
pub const needle_min = 2

/// The most characters a search fragment may hold, the length the composer keeps
/// of the search text.
pub const needle_limit = 64

/// The most hits one search shows.
pub const find_limit = 20

/// The most directories below the home the index lists. It is below
/// `depth_limit`, so every entry is a trail a creation takes.
pub const index_depth = 6

/// The most directories one index build reads, which bounds its cost whatever the
/// shape of the home. An index that reaches it says it stopped.
pub const index_visit_limit = 20_000

/// The most entries one index holds, which bounds its memory the same way.
pub const index_entry_limit = 60_000

/// The longest an index build may run, in milliseconds. It ends with what it has
/// and says it stopped.
pub const index_ms = 4000

/// How long a page keeps an index before it asks for another, in milliseconds.
pub const index_ttl_ms = 300_000

/// The words on a name's row, and where it leads.
pub type Child {
  Child(
    /// The directory's name: a text node, never an attribute.
    name: String,
    /// Whether the directory holds a `.git`, which the row marks.
    marker: Marker,
  )
}

/// Whether a child directory is the root of a Git checkout.
pub type Marker {
  /// The directory holds a `.git`, a directory or a file as a worktree has.
  Repository

  /// The directory holds none.
  Plain
}

/// Whether the listing holds every child directory the daemon would show.
pub type Cut {
  /// Every child directory is listed.
  Whole

  /// The listing stopped at `shown_limit` rows or `inspect_limit` names examined,
  /// so there may be more.
  CutShort

  /// The directory is `depth_limit` below the home, so its children are not
  /// listed: the owner may choose it, or type a path.
  AtDepthLimit
}

/// One directory as the daemon read it.
pub type Listing {
  Listing(
    /// The directory's canonical trail below the home, `[]` for the home. It is
    /// what the breadcrumb draws, and a symbolic link has already been followed.
    trail: List(String),
    /// The child directories that lie inside the home, sorted without regard to
    /// case. Hidden directories, files and links out of the home are not here.
    children: List(Child),
    /// Whether the children are all of them.
    cut: Cut,
  )
}

/// Why a trail was not listed. Each has one sentence and none names the trail or
/// the operating system's error, since the picker is not to be a probe of what
/// exists.
pub type Refusal {
  /// The daemon has no home directory it can resolve.
  NoHome

  /// The trail names no directory the picker may show: it does not exist, it is
  /// not a directory, it leaves the home by a link or is hidden.
  NotAFolder

  /// The trail is more than `depth_limit` directories below the home.
  TooDeep

  /// The directory holds more than `entry_limit` entries.
  TooMany

  /// The directory could not be read.
  Unreadable
}

/// What a read of one directory gave: the listing, or why it was refused.
pub type Answer =
  Result(Listing, Refusal)

/// Whether an index build looked at every directory it was allowed to.
pub type Reach {
  /// The build ended because every directory within `index_depth` had been read.
  Covered

  /// The build stopped at `index_visit_limit` directories, `index_entry_limit`
  /// entries or `index_ms`, so there may be more.
  Stopped
}

/// One directory of the index.
pub type Entry {
  Entry(
    /// The directory's trail below the home, outermost first, never empty. The
    /// build walks real directories and follows no link, so it is also the
    /// directory's canonical trail.
    trail: List(String),
    /// The directory's own name in lower case, kept so a keystroke compares
    /// without lowering every name again.
    lower: String,
  )
}

/// The folder names below the home, as one bounded walk found them. The page holds
/// it for `index_ttl_ms` and ranks it in memory for each keystroke.
pub type Index {
  Index(
    /// The canonical home the entries lie below, which lets the page compare a
    /// remembered folder's whole path with an entry's.
    home: String,
    /// The directories the build listed, shallowest first.
    entries: List(Entry),
    /// Whether the build looked everywhere it could.
    reach: Reach,
  )
}

/// What an index build gave: the index, or why the daemon would not build one.
pub type IndexAnswer =
  Result(Index, Refusal)

/// Whether a name may be one component of a trail: not empty, not `.` or `..`, no
/// slash, no control character or line break, no space at either end (a path is
/// trimmed where it is typed, so a name the trim would change cannot round trip),
/// and at most `name_limit` bytes. A hidden name passes: whether it may be shown
/// is the daemon's rule for a directory, not a rule of spelling.
///
/// ## Examples
///
/// ```gleam
/// assert folder_browse.component_ok("app")
/// assert !folder_browse.component_ok("..")
/// assert !folder_browse.component_ok("a/b")
/// ```
pub fn component_ok(name: String) -> Bool {
  name != ""
  && name != "."
  && name != ".."
  && !string.contains(name, "/")
  && string.byte_size(name) <= name_limit
  && string.trim(name) == name
  && text_hygiene.single_line(name) == name
}

/// Whether a trail is one the daemon will resolve: at most `depth_limit`
/// components, each of which `component_ok` accepts.
///
/// ## Examples
///
/// ```gleam
/// assert folder_browse.trail_ok(["code", "app"])
/// assert folder_browse.trail_ok([])
/// assert !folder_browse.trail_ok(["code", ".."])
/// ```
pub fn trail_ok(trail: List(String)) -> Bool {
  list.drop(trail, depth_limit) == [] && list.all(trail, component_ok)
}

/// A trail as the `~/` path a creation takes, which the daemon judges as it
/// judges a typed one. The home itself is `~`.
///
/// ## Examples
///
/// ```gleam
/// assert folder_browse.trail_text(["code", "app"]) == "~/code/app"
/// assert folder_browse.trail_text([]) == "~"
/// ```
pub fn trail_text(trail: List(String)) -> String {
  case trail {
    [] -> "~"
    [_, ..] -> "~/" <> string.join(trail, "/")
  }
}

/// The trail one directory further down, or `Error(Nil)` for an index that names
/// no child of the listing. This is the one place a descent is built, so a press
/// whose index the page did not draw reaches nothing.
///
/// ## Examples
///
/// ```gleam
/// let listing = folder_browse.Listing(["a"], [folder_browse.Child("b", folder_browse.Plain)], folder_browse.Whole)
/// assert folder_browse.below(listing, 0) == Ok(["a", "b"])
/// assert folder_browse.below(listing, 1) == Error(Nil)
/// ```
pub fn below(listing: Listing, index: Int) -> Result(List(String), Nil) {
  case index >= 0, list.drop(listing.children, index) {
    True, [Child(name:, ..), ..] -> Ok(list.append(listing.trail, [name]))
    True, [] | False, _ -> Error(Nil)
  }
}

/// The trail of the ancestor `depth` components down from the home: `0` is the
/// home, and the listing's own depth is refused, since it is where the person
/// already is.
///
/// ## Examples
///
/// ```gleam
/// let listing = folder_browse.Listing(["a", "b"], [], folder_browse.Whole)
/// assert folder_browse.above(listing, 1) == Ok(["a"])
/// assert folder_browse.above(listing, 2) == Error(Nil)
/// ```
pub fn above(listing: Listing, depth: Int) -> Result(List(String), Nil) {
  // An ancestor is a depth with a component at or below it: dropping that many
  // leaves at least the directory on screen.
  case depth >= 0, list.drop(listing.trail, depth) {
    True, [_, ..] -> Ok(list.take(listing.trail, depth))
    True, [] | False, _ -> Error(Nil)
  }
}

/// The fixed sentence for a refusal.
///
/// ## Examples
///
/// ```gleam
/// assert folder_browse.refusal_words(folder_browse.TooMany) != ""
/// ```
pub fn refusal_words(refusal: Refusal) -> String {
  case refusal {
    NoHome -> "The daemon cannot find your home folder to list."
    NotAFolder ->
      "That folder is not there, or it is outside your home folder. Go up, or type a path."
    TooDeep ->
      "That is deeper than the picker goes. Go up, or type the path of the folder."
    TooMany ->
      "That folder holds too many entries to list. Go up, or type the path of the folder."
    Unreadable -> "That folder cannot be read. Go up, or type a path."
  }
}

/// The fragment a search looks for, from the text the person typed: trimmed,
/// lowercase, a leading `~/` removed so a pasted path searches as the path below
/// the home, a single line of at least `needle_min` and at most `needle_limit`
/// characters. Anything else is `Error(Nil)`, so the page ranks nothing.
///
/// ## Examples
///
/// ```gleam
/// assert folder_browse.needle("  Loom ") == Ok("loom")
/// assert folder_browse.needle("~/code/app") == Ok("code/app")
/// assert folder_browse.needle("l") == Error(Nil)
/// ```
pub fn needle(text: String) -> Result(String, Nil) {
  let trimmed = string.trim(text) |> string.lowercase

  // A fragment is kept only if its length and spelling pass.
  let fragment = case string.starts_with(trimmed, "~/") {
    True -> string.drop_start(trimmed, 2)
    False -> trimmed
  }

  let length = string.length(fragment)

  // A fragment is kept only if it is long enough to be worth ranking, short
  // enough to be a name, and one line.
  case
    length >= needle_min
    && length <= needle_limit
    && text_hygiene.single_line(fragment) == fragment
  {
    True -> Ok(fragment)
    False -> Error(Nil)
  }
}

/// The index entries a fragment finds, best first, at most `find_limit`. An entry
/// is found when its name holds the fragment; a fragment with a slash is looked
/// for in the whole trail instead, so `code/app` finds the `app` below `code`.
/// The order is an exact name, then a name that starts with the fragment, then one
/// that holds it, and within a kind the shallower directory, then the trail
/// alphabetically.
///
/// ## Examples
///
/// ```gleam
/// let entries = [folder_browse.Entry(["a", "loomy"], "loomy"), folder_browse.Entry(["loom"], "loom")]
/// assert folder_browse.rank(entries, "loom") == [["loom"], ["a", "loomy"]]
/// ```
pub fn rank(entries: List(Entry), fragment: String) -> List(List(String)) {
  let slashed = string.contains(fragment, "/")

  list.filter_map(entries, fn(entry) {
    // An entry is ranked by how well its name holds the fragment.
    let held = case slashed {
      True -> string.lowercase(string.join(entry.trail, "/"))
      False -> entry.lower
    }

    // An entry is ranked by how well its name holds the fragment.
    case kind(held, fragment) {
      Ok(rank) ->
        Ok(#(
          rank,
          list.length(entry.trail),
          string.join(entry.trail, "/"),
          entry.trail,
        ))
      Error(Nil) -> Error(Nil)
    }
  })
  |> list.sort(fn(a, b) {
    int.compare(a.0, b.0)
    |> order.break_tie(int.compare(a.1, b.1))
    |> order.break_tie(string.compare(a.2, b.2))
  })
  |> list.take(find_limit)
  |> list.map(fn(found) { found.3 })
}

/// How well a name holds a fragment: 0 for the same, 1 for a start, 2 for any
/// other place, and `Error(Nil)` for not at all.
fn kind(held: String, fragment: String) -> Result(Int, Nil) {
  case held == fragment, string.starts_with(held, fragment) {
    True, _ -> Ok(0)
    False, True -> Ok(1)
    False, False ->
      case string.contains(held, fragment) {
        True -> Ok(2)
        False -> Error(Nil)
      }
  }
}

/// The trail at an index of the trails the page holds, or `Error(Nil)` for an
/// index that names none. This is the one place a found folder becomes a trail, so
/// a press whose index the page did not draw reaches nothing.
///
/// ## Examples
///
/// ```gleam
/// assert folder_browse.hit_trail([["a", "b"]], 0) == Ok(["a", "b"])
/// assert folder_browse.hit_trail([["a", "b"]], 1) == Error(Nil)
/// ```
pub fn hit_trail(
  hits: List(List(String)),
  index: Int,
) -> Result(List(String), Nil) {
  case index >= 0, list.drop(hits, index) {
    True, [trail, ..] -> Ok(trail)
    True, [] | False, _ -> Error(Nil)
  }
}
