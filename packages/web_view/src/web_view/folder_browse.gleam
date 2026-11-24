//// The folder picker's vocabulary: what the owner's page asks of the daemon to
//// walk the directories below the owner's home, what it answers, and the fixed
//// words for each refusal (protocol-change/132).
////
//// The composer's "Choose a folder…" draws a picker in the page, because a
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

import gleam/list
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
