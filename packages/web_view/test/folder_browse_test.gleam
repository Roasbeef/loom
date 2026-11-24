//// The folder picker's pure rules (`web_view/folder_browse`, protocol-change/132):
//// which names may be one component of a trail, how a trail is bounded and
//// written, and which presses the listing the page holds can build a trail for.

import gleam/list
import gleam/string
import web_view/folder_browse.{Child, Listing, Plain, Repository, Whole}

fn listing() -> folder_browse.Listing {
  Listing(
    trail: ["code"],
    children: [Child("app", Repository), Child("notes", Plain)],
    cut: Whole,
  )
}

// A component is one ordinary name. Everything that could climb, split, hide a
// line break or be changed by the trim a typed path gets is refused.
pub fn a_component_is_one_ordinary_name_test() {
  assert folder_browse.component_ok("app")
  assert folder_browse.component_ok("my project")
  assert folder_browse.component_ok(".hidden")
  assert !folder_browse.component_ok("")
  assert !folder_browse.component_ok(".")
  assert !folder_browse.component_ok("..")
  assert !folder_browse.component_ok("a/b")
  assert !folder_browse.component_ok("/")
  assert !folder_browse.component_ok("a\nb")
  assert !folder_browse.component_ok("a\u{0}b")
  assert !folder_browse.component_ok(" padded")
  assert !folder_browse.component_ok("padded ")
  assert !folder_browse.component_ok(string.repeat("x", 256))
  assert folder_browse.component_ok(string.repeat("x", 255))
}

// A trail is bounded in depth as well as in each name.
pub fn a_trail_is_bounded_in_depth_test() {
  assert folder_browse.trail_ok([])
  assert folder_browse.trail_ok(list.repeat("d", folder_browse.depth_limit))
  assert !folder_browse.trail_ok(list.repeat("d", folder_browse.depth_limit + 1))
  assert !folder_browse.trail_ok(["code", ".."])
}

// The creation takes the picked folder as a `~/` path, which the daemon judges
// as it judges one typed.
pub fn a_trail_is_written_as_a_home_path_test() {
  assert folder_browse.trail_text([]) == "~"
  assert folder_browse.trail_text(["code", "app"]) == "~/code/app"
}

// A descent is built from the listing the page holds, so an index the page did
// not draw builds nothing.
pub fn a_descent_names_only_a_drawn_child_test() {
  assert folder_browse.below(listing(), 0) == Ok(["code", "app"])
  assert folder_browse.below(listing(), 1) == Ok(["code", "notes"])
  assert folder_browse.below(listing(), 2) == Error(Nil)
  assert folder_browse.below(listing(), -1) == Error(Nil)
}

// An ancestor is a depth above the one on screen: the home, or a directory of
// the trail short of its end.
pub fn an_ascent_names_only_an_ancestor_test() {
  let deep = Listing(trail: ["a", "b", "c"], children: [], cut: Whole)
  assert folder_browse.above(deep, 0) == Ok([])
  assert folder_browse.above(deep, 2) == Ok(["a", "b"])
  assert folder_browse.above(deep, 3) == Error(Nil)
  assert folder_browse.above(deep, 4) == Error(Nil)
  assert folder_browse.above(deep, -1) == Error(Nil)
}

// Each refusal has its own fixed sentence, and none carries a path.
pub fn each_refusal_has_its_own_words_test() {
  let all = [
    folder_browse.NoHome,
    folder_browse.NotAFolder,
    folder_browse.TooDeep,
    folder_browse.TooMany,
    folder_browse.Unreadable,
  ]
  let words = list.map(all, folder_browse.refusal_words)
  assert list.length(list.unique(words)) == 5
  assert list.all(words, fn(sentence) { !string.contains(sentence, "/") })
}
