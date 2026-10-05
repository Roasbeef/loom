//// What `<loom-switcher>` decides (`web_client/switcher_rule`): the shortcut
//// that opens it, which sessions a query lists and where the highlight goes.

import gleam/list
import web_client/switcher_rule.{
  Bare, Choose, Composing, Down, Match, Other, Pass, Primary, Row, Running,
  Saved, Typing, Up,
}

fn rows() -> List(switcher_rule.Row) {
  [
    Row("review auth", "loom", "Fix the flaky retry test", Running),
    Row("docs sweep", "loom", "", Saved),
    Row("Session 0198a2f4", "weft", "review the poll module", Running),
  ]
}

pub fn the_shortcut_is_k_with_command_or_control_test() {
  assert switcher_rule.shortcut("k", Primary)
  assert switcher_rule.shortcut("K", Primary)
  assert !switcher_rule.shortcut("k", Bare)
  assert !switcher_rule.shortcut("k", Other)
  assert !switcher_rule.shortcut("j", Primary)
}

pub fn arrows_and_enter_are_the_lists_and_everything_else_is_the_browsers_test() {
  assert switcher_rule.intent("ArrowUp", Typing) == Up
  assert switcher_rule.intent("ArrowDown", Typing) == Down
  assert switcher_rule.intent("Enter", Typing) == Choose
  assert switcher_rule.intent("a", Typing) == Pass
  assert switcher_rule.intent("Escape", Typing) == Pass
}

// An input method confirming a candidate with Enter must not open a session.
pub fn a_composing_key_is_left_to_the_input_method_test() {
  list.each(["Enter", "ArrowUp", "ArrowDown"], fn(key) {
    assert switcher_rule.intent(key, Composing) == Pass
  })
}

pub fn an_empty_query_lists_every_row_in_order_test() {
  let listed = switcher_rule.matching(rows(), "")
  assert list.map(listed, fn(match) { match.index }) == [0, 1, 2]
  assert switcher_rule.matching(rows(), "   ") == listed
}

pub fn every_word_must_appear_in_any_case_test() {
  assert list.map(switcher_rule.matching(rows(), "LOOM docs"), fn(match) {
      match.index
    })
    == [1]
  assert switcher_rule.matching(rows(), "loom nothing") == []
}

// A word that matches a name lists ahead of one that matches only a
// subtitle, and each group keeps the sidebar's order.
pub fn name_matches_list_before_detail_matches_test() {
  let listed = switcher_rule.matching(rows(), "review")
  assert list.map(listed, fn(match) { match.index }) == [0, 2]
  let listed = switcher_rule.matching(rows(), "poll")
  assert listed
    == [
      Match(
        2,
        Row("Session 0198a2f4", "weft", "review the poll module", Running),
      ),
    ]
  let ranked =
    switcher_rule.matching(
      [
        Row("alpha", "x", "uses beta", Running),
        Row("beta", "x", "", Saved),
      ],
      "beta",
    )
  assert list.map(ranked, fn(match) { match.index }) == [1, 0]
}

// Markup in a name is only characters to compare; it is never interpreted.
pub fn a_name_is_compared_as_text_test() {
  let tricky = [Row("<b>bold</b>", "x", "", Running)]
  assert list.length(switcher_rule.matching(tricky, "<b>")) == 1
  assert switcher_rule.matching(tricky, "bold") != []
}

pub fn the_highlight_wraps_at_both_ends_test() {
  assert switcher_rule.moved(0, Down, 3) == 1
  assert switcher_rule.moved(2, Down, 3) == 0
  assert switcher_rule.moved(0, Up, 3) == 2
  assert switcher_rule.moved(1, Up, 3) == 0
}

pub fn an_empty_list_holds_the_highlight_at_the_top_test() {
  assert switcher_rule.moved(0, Down, 0) == 0
  assert switcher_rule.moved(3, Up, 0) == 0
}

pub fn a_shorter_list_pulls_the_highlight_back_in_test() {
  assert switcher_rule.kept(5, 2) == 1
  assert switcher_rule.kept(0, 0) == 0
  assert switcher_rule.kept(1, 4) == 1
}

pub fn a_workspace_is_named_by_its_last_segment_test() {
  assert switcher_rule.workspace_label("/home/ada/src/loom") == "loom"
  assert switcher_rule.workspace_label("/home/ada/src/loom/") == "loom"
  assert switcher_rule.workspace_label("/") == "/"
  assert switcher_rule.workspace_label("") == ""
}

// The pages the bar offers (the way home, the admin page) list ahead of the
// sessions the sidebar draws, they match a typed name, and their row says what
// the page is for and nothing about a workspace or a saved state.
pub fn a_page_of_the_app_lists_first_and_says_what_it_is_for_test() {
  let home = Row("Home", "", "Your sessions", switcher_rule.Place)
  let listed = switcher_rule.matching([home, ..rows()], "")
  assert list.map(listed, fn(match) { match.index }) == [0, 1, 2, 3]
  assert switcher_rule.detail(home) == "Your sessions"
  assert list.map(switcher_rule.matching([home, ..rows()], "ho"), fn(match) {
      match.index
    })
    == [0]
}

pub fn a_session_row_names_its_workspace_subtitle_and_saved_state_test() {
  assert switcher_rule.detail(Row("a", "loom", "Fix the test", Running))
    == "loom · Fix the test"
  assert switcher_rule.detail(Row("a", "loom", "", Saved)) == "loom · saved"
  assert switcher_rule.detail(Row("a", "", "", Running)) == ""
}

// The chip lives in another element's shadow tree, so a click opens the
// switcher only when an element on its path carries the marker.
pub fn only_the_marked_chip_summons_the_switcher_test() {
  assert switcher_rule.summons(Ok(switcher_rule.summon_value))
  assert !switcher_rule.summons(Ok("something-else"))
  assert !switcher_rule.summons(Error(Nil))
}
