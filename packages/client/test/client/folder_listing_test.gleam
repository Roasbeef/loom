//// Which directories the folder picker may list (protocol-change/132), against a
//// real filesystem: the canonical path is judged, so a link or a `..` cannot lead
//// out of the home, a hidden folder and `Library` are never shown, and each bound
//// refuses rather than cuts without saying.

import client/daemon/folder_listing
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
