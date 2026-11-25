//// Which directories the folder picker may list (protocol-change/132), against a
//// real filesystem: the canonical path is judged, so a link or a `..` cannot lead
//// out of the home, a hidden folder and `Library` are never shown, and each bound
//// refuses rather than cuts without saying.

import client/daemon/folder_listing
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import support/extensions
import web_view/folder_browse.{Child, Listing, Plain, Repository}

// A canonical, empty directory standing for the owner's home.
fn owners_home(name: String) -> String {
  let assert Ok(home) = bootstrap.canonical_directory(extensions.scratch(name))
    as "the scratch directory resolves"
  home
}

fn make(path: String) -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all(path)
    as "the directory is made"
  Nil
}

fn names(listing: folder_browse.Listing) -> List(String) {
  list.map(listing.children, fn(child) { child.name })
}

// A listing holds directories only, sorted without regard to case, with a Git
// checkout marked (a `.git` directory, or the file a linked worktree has), and
// leaves out files, hidden directories and `Library`.
pub fn a_listing_holds_visible_directories_in_order_test() {
  let home = owners_home("listing-order")
  make(home <> "/beta")
  make(home <> "/Alpha")
  make(home <> "/repo/.git")
  make(home <> "/worktree")
  make(home <> "/.ssh")
  make(home <> "/Library/Keychains")
  let assert Ok(Nil) = simplifile.write(home <> "/worktree/.git", "gitdir: x")
    as "a linked worktree's .git file"
  let assert Ok(Nil) = simplifile.write(home <> "/notes.txt", "x") as "a file"

  let assert Ok(listing) = folder_listing.list_in(home, [])
  assert listing.trail == []
  assert listing.cut == folder_browse.Whole
  assert listing.children
    == [
      Child("Alpha", Plain),
      Child("beta", Plain),
      Child("repo", Repository),
      Child("worktree", Repository),
    ]
}

// A trail is followed one directory at a time, and the listing says where it is.
pub fn a_trail_is_followed_below_the_home_test() {
  let home = owners_home("listing-trail")
  make(home <> "/code/app")
  make(home <> "/code/lib")

  assert folder_listing.list_in(home, ["code"])
    == Ok(Listing(
      trail: ["code"],
      children: [Child("app", Plain), Child("lib", Plain)],
      cut: folder_browse.Whole,
    ))
  assert folder_listing.list_in(home, ["code", "app"])
    == Ok(Listing(
      trail: ["code", "app"],
      children: [],
      cut: folder_browse.Whole,
    ))
}

// A trail that is spelled to climb, split or hide is refused before the
// filesystem is asked, and one that names nothing, a file, a hidden folder or
// `Library` is refused after, in the same words.
pub fn a_trail_that_names_nothing_listable_is_refused_test() {
  let home = owners_home("listing-refused")
  make(home <> "/code")
  make(home <> "/.ssh")
  make(home <> "/Library/Keychains")

  // The same folder in lower case, so that on a case-sensitive filesystem it is
  // the rule's case-folding that refuses it and not the folder's absence.
  make(home <> "/library/Keychains")
  let assert Ok(Nil) = simplifile.write(home <> "/file", "x") as "a file"

  let refused = Error(folder_browse.NotAFolder)
  assert folder_listing.list_in(home, [".."]) == refused
  assert folder_listing.list_in(home, ["code", "..", ".."]) == refused
  assert folder_listing.list_in(home, ["code/.."]) == refused
  assert folder_listing.list_in(home, [""]) == refused
  assert folder_listing.list_in(home, ["/etc"]) == refused
  assert folder_listing.list_in(home, ["a\nb"]) == refused
  assert folder_listing.list_in(home, ["missing"]) == refused
  assert folder_listing.list_in(home, ["file"]) == refused
  assert folder_listing.list_in(home, [".ssh"]) == refused
  assert folder_listing.list_in(home, ["Library"]) == refused
  assert folder_listing.list_in(home, ["library", "Keychains"]) == refused
}

// A link that leaves the home is refused as a trail and is not listed as a child,
// however it is named. A link that stays inside is listed and followed, and the
// listing reports the directory it really is.
pub fn a_link_cannot_lead_out_of_the_home_test() {
  let home = owners_home("listing-links")
  let assert Ok(outside) =
    bootstrap.canonical_directory(extensions.scratch("listing-links-outside"))
    as "a folder outside home"
  make(outside <> "/deep")
  make(home <> "/code/app")
  make(home <> "/.secrets")
  let assert Ok(Nil) = simplifile.create_symlink(outside, home <> "/escape")
    as "a link out"
  let assert Ok(Nil) =
    simplifile.create_symlink(home <> "/code/app", home <> "/shortcut")
    as "a link in"
  let assert Ok(Nil) =
    simplifile.create_symlink(home <> "/.secrets", home <> "/innocent")
    as "a link to a hidden folder"
  let assert Ok(Nil) =
    simplifile.create_symlink(home <> "/nowhere", home <> "/dangling")
    as "a dangling link"
  let assert Ok(Nil) = simplifile.write(home <> "/code/note", "x") as "a file"
  let assert Ok(Nil) =
    simplifile.create_symlink(home <> "/code/note", home <> "/tofile")
    as "a link to a file"

  let assert Ok(listing) = folder_listing.list_in(home, [])
  assert names(listing) == ["code", "shortcut"]

  let refused = Error(folder_browse.NotAFolder)
  assert folder_listing.list_in(home, ["escape"]) == refused
  assert folder_listing.list_in(home, ["escape", "deep"]) == refused
  assert folder_listing.list_in(home, ["innocent"]) == refused
  assert folder_listing.list_in(home, ["dangling"]) == refused
  assert folder_listing.list_in(home, ["tofile"]) == refused

  let assert Ok(followed) = folder_listing.list_in(home, ["shortcut"])
  assert followed.trail == ["code", "app"]
}

// The depth bound: a trail longer than the limit is refused without a look, one
// at the limit lists no children and says why, and a link that makes a short
// trail deeper than the limit is refused for where it ends.
pub fn the_depth_bound_refuses_and_stops_test() {
  let home = owners_home("listing-depth")
  let deepest = list.repeat("d", folder_browse.depth_limit)
  make(home <> "/" <> join(deepest))
  make(home <> "/" <> join(deepest) <> "/below")

  assert folder_listing.list_in(home, [])
    |> result.map(fn(listing) { names(listing) })
    == Ok(["d"])

  let one_too_many = list.append(deepest, ["below"])
  assert folder_listing.list_in(home, one_too_many)
    == Error(folder_browse.TooDeep)

  assert folder_listing.list_in(home, deepest)
    == Ok(Listing(trail: deepest, children: [], cut: folder_browse.AtDepthLimit))

  let assert Ok(Nil) =
    simplifile.create_symlink(
      home <> "/" <> join(deepest) <> "/below",
      home <> "/shallow",
    )
    as "a link to a directory deeper than the limit"
  assert folder_listing.list_in(home, ["shallow"])
    == Error(folder_browse.TooDeep)
}

fn join(names: List(String)) -> String {
  list.fold(names, "", fn(path, name) {
    case path {
      "" -> name
      _ -> path <> "/" <> name
    }
  })
}

// The entry bound: a directory at the limit is listed, and one entry more is
// refused outright, not cut, so no part of it is shown as though it were whole.
// The shown bound is separate: a listing past it says it was cut.
pub fn the_entry_bound_refuses_and_the_shown_bound_cuts_test() {
  let home = owners_home("listing-entries")
  upto(folder_browse.entry_limit)
  |> list.each(fn(each) { make(home <> "/many/d" <> pad(each)) })

  let assert Ok(listing) = folder_listing.list_in(home, ["many"])
  assert list.length(listing.children) == folder_browse.shown_limit
  assert listing.cut == folder_browse.CutShort
  assert names(listing)
    == list.map(upto(folder_browse.shown_limit), fn(each) { "d" <> pad(each) })

  make(home <> "/many/one-more")
  assert folder_listing.list_in(home, ["many"]) == Error(folder_browse.TooMany)
}

fn pad(number: Int) -> String {
  string.pad_start(int.to_string(number), 4, "0")
}

// The integers from one to `last`, in order.
fn upto(last: Int) -> List(Int) {
  list.index_map(list.repeat(Nil, last), fn(_, index) { index + 1 })
}

// A directory the daemon's user cannot read is refused in fixed words. A user who
// can read everything, as root can, has no such directory, and the test says so
// rather than passing without having asked.
pub fn an_unreadable_directory_is_refused_cleanly_test() {
  let home = owners_home("listing-unreadable")
  make(home <> "/locked/inside")
  let assert Ok(Nil) =
    simplifile.set_permissions_octal(home <> "/locked", 0o000)
    as "the directory is locked"

  let answer = folder_listing.list_in(home, ["locked"])
  let readable = simplifile.read_directory(home <> "/locked")
  let _ = simplifile.set_permissions_octal(home <> "/locked", 0o755)

  case readable {
    Ok(_) ->
      io.println_error(
        "SKIP: an_unreadable_directory_is_refused_cleanly_test (this user reads a mode 000 directory)",
      )
    Error(_) -> {
      // The trail itself resolves (`stat` needs only the parent), so the refusal
      // is the read's.
      assert answer == Error(folder_browse.Unreadable)
    }
  }
}

// A directory of links out of the home costs a bounded number of resolutions: the
// walk stops after `inspect_limit` names whether or not they were kept, and says
// the listing is cut, so a folder past the bound is not listed.
pub fn the_inspection_bound_counts_the_names_refused_test() {
  let home = owners_home("listing-inspect")
  let assert Ok(outside) =
    bootstrap.canonical_directory(extensions.scratch("listing-inspect-outside"))
    as "a folder outside home"
  list.each(upto(folder_browse.inspect_limit), fn(each) {
    let assert Ok(Nil) =
      simplifile.create_symlink(outside, home <> "/a" <> pad(each))
      as "a link out"
    Nil
  })
  make(home <> "/zlast")

  let assert Ok(listing) = folder_listing.list_in(home, [])
  assert listing.children == []
  assert listing.cut == folder_browse.CutShort
}

// A link to a directory whose real name `component_ok` refuses is refused, since
// the canonical trail drawn for it could not be sent back.
pub fn a_canonical_trail_with_an_unsendable_name_is_refused_test() {
  let home = owners_home("listing-padded")
  make(home <> "/padded ")
  let assert Ok(Nil) =
    simplifile.create_symlink(home <> "/padded ", home <> "/shortcut")
    as "a link to it"

  assert folder_listing.list_in(home, ["shortcut"])
    == Error(folder_browse.NotAFolder)
}

fn clock() -> Int {
  0
}

// The index of a home with the daemon's bounds and no seeds.
fn indexed(home: String) -> folder_browse.Index {
  folder_listing.index_in(home, [], folder_listing.limits, clock)
}

// The trails the fragment finds in an index, best first.
fn found(index: folder_browse.Index, fragment: String) -> List(List(String)) {
  folder_browse.rank(index.entries, fragment)
}

// The index lists real visible directories below the home and the ranking puts an
// exact name first, then a name that starts with the fragment, then one that holds
// it, the shallower first within a kind. A hidden folder, `Library`, a file, and
// what a build-output folder holds are not listed, but a folder named like build
// output is itself found.
pub fn the_index_ranks_names_and_skips_what_a_creation_refuses_test() {
  let home = owners_home("index-order")
  make(home <> "/work/Loom")
  make(home <> "/code/deep/inside/oldloom")
  make(home <> "/loom-picker")
  make(home <> "/loom")
  make(home <> "/.hidden/loom")
  make(home <> "/Library/loom")
  make(home <> "/code/node_modules/loom")
  make(home <> "/code/app")
  let assert Ok(Nil) = simplifile.write(home <> "/loom.txt", "x") as "a file"

  let index = indexed(home)
  assert found(index, "loom")
    == [
      ["loom"],
      ["work", "Loom"],
      ["loom-picker"],
      ["code", "deep", "inside", "oldloom"],
    ]
  assert index.reach == folder_browse.Covered
  assert index.home == home

  // The build-output folder is an entry itself and nothing below it is.
  assert found(index, "node_modules") == [["code", "node_modules"]]
}

// A fragment with a slash is looked for in the whole trail, and a leading `~/` is
// the home.
pub fn a_slash_names_a_path_test() {
  let home = owners_home("index-slash")
  make(home <> "/code/app")
  make(home <> "/other/app")

  let index = indexed(home)
  assert found(index, "code/app") == [["code", "app"]]
  assert folder_browse.needle("~/code/app") == Ok("code/app")
}

// A link is not followed: what lies behind one is not listed and the walk never
// leaves the home, while a real folder beside the links is found, so the empty
// answer is the rule and not a broken walk.
pub fn the_index_follows_no_link_test() {
  let home = owners_home("index-link")
  let outside = owners_home("index-link-outside")
  make(outside <> "/loom-secret")
  make(home <> "/real/loom-real")
  let assert Ok(Nil) = simplifile.create_symlink(outside, home <> "/loom-link")
    as "a link out of the home"
  let assert Ok(Nil) =
    simplifile.create_symlink(home <> "/real", home <> "/loom-in")
    as "a link inside the home"

  assert found(indexed(home), "loom") == [["real", "loom-real"]]
}

// A directory at the depth bound is listed and one below it is not.
pub fn the_depth_bound_lists_six_levels_and_not_seven_test() {
  let home = owners_home("index-depth")
  make(home <> "/a/b/c/d/e/six-dir")
  make(home <> "/a/b/c/d/e/f/seven-dir")

  let index = indexed(home)
  assert found(index, "six-dir") == [["a", "b", "c", "d", "e", "six-dir"]]
  assert found(index, "seven-dir") == []
  assert index.reach == folder_browse.Covered
}

// The visit bound ends the build with what it has and says so, and a match beyond
// it is not found. The entry bound and the clock do the same.
pub fn each_bound_ends_the_build_and_says_so_test() {
  let home = owners_home("index-bounds")
  list.each(["a", "b", "c", "d", "e", "f"], fn(name) {
    make(home <> "/" <> name <> "/inner-" <> name)
  })
  make(home <> "/zz/target-zz")

  let visits =
    folder_listing.index_in(
      home,
      [],
      folder_listing.Limits(..folder_listing.limits, visits: 3),
      clock,
    )
  assert visits.reach == folder_browse.Stopped
  assert found(visits, "target-zz") == []

  let entries =
    folder_listing.index_in(
      home,
      [],
      folder_listing.Limits(..folder_listing.limits, entries: 2),
      clock,
    )
  assert entries.reach == folder_browse.Stopped

  // The bound is checked between directories, so the root's seven children are
  // all listed before the build stops.
  assert list.length(entries.entries) == 7

  // A clock that is past the bound stops the walk before it reads a directory.
  let ticks = process.new_subject()
  process.send(ticks, 0)
  let late = fn() {
    case process.receive(ticks, 0) {
      Ok(_) -> 0
      Error(Nil) -> 10_000
    }
  }
  let timed =
    folder_listing.index_in(
      home,
      [],
      folder_listing.Limits(..folder_listing.limits, ms: 50),
      late,
    )
  assert timed.reach == folder_browse.Stopped
  assert found(timed, "target-zz") == []

  // With room, everything is found.
  assert found(indexed(home), "target-zz") == [["zz", "target-zz"]]
}

// Below a Git checkout the walk keeps descending but lists only folders that hold a
// `.git`, which are its worktrees and sub-repositories.
pub fn below_a_checkout_only_checkouts_are_listed_test() {
  let home = owners_home("index-checkout")
  make(home <> "/code/proj/.git")
  make(home <> "/code/proj/src/deep")
  make(home <> "/code/proj/worktrees/feature")
  let assert Ok(Nil) =
    simplifile.write(home <> "/code/proj/worktrees/feature/.git", "gitdir: x")
    as "a linked worktree's .git file"
  make(home <> "/code/proj/vendor/lib/.git")

  let index = indexed(home)
  assert found(index, "proj") == [["code", "proj"]]
  assert found(index, "feature") == [["code", "proj", "worktrees", "feature"]]
  assert found(index, "lib") == [["code", "proj", "vendor", "lib"]]
  assert found(index, "deep") == []
  assert found(index, "src") == []
  assert found(index, "worktrees") == []
}

// A deep container of repositories, as an owner keeps them, is found when the
// remembered folders seed the walk, though a wide home spends a small budget before
// reaching it breadth first.
pub fn the_remembered_folders_seed_a_deep_container_test() {
  let home = owners_home("index-seeds")
  let container = "/gocode/src/github.com/roasbeef"
  make(home <> container <> "/loom/.git")
  make(home <> container <> "/weft/.git")
  list.each(["a", "b", "c", "d", "e", "f", "g", "h"], fn(name) {
    make(home <> "/" <> name <> "/x/y")
  })

  let tight = folder_listing.Limits(..folder_listing.limits, visits: 12)
  let unseeded = folder_listing.index_in(home, [], tight, clock)
  assert found(unseeded, "weft") == []

  let seeded =
    folder_listing.index_in(home, [home <> container <> "/loom"], tight, clock)
  assert found(seeded, "weft")
    == [["gocode", "src", "github.com", "roasbeef", "weft"]]

  // A seed that reaches the container through a link, or lies outside the home, is
  // not read.
  let outside = owners_home("index-seeds-outside")
  make(outside <> "/gocode/src/github.com/roasbeef/loom")
  let assert Ok(Nil) = simplifile.create_symlink(outside, home <> "/via-link")
    as "a link out of the home"
  let hostile =
    folder_listing.index_in(
      home,
      [
        home <> "/via-link/gocode/src/github.com/roasbeef/loom",
        outside <> "/gocode/src/github.com/roasbeef/loom",
      ],
      tight,
      clock,
    )
  assert found(hostile, "loom") == []
}
