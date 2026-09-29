//// The composer's rules: the table it decodes, which rows a draft lists, what
//// a key does, how the highlight moves and is kept in view, and how a
//// returned prompt is claimed once and joined to a draft.

import gleam/list
import gleam/option.{None, Some}
import web_client/composer.{
  Bare, Closed, Complete, Composing, Consumed, Continues, Entry, Fresh, Listing,
  Observed, Other, Repeating, Sending,
}

fn table() -> List(composer.Entry) {
  [
    Entry("/compact", "shrink the context", Complete),
    Entry("/context", "show the context", Complete),
    Entry("/effort", "set the effort", Continues),
    Entry("/effort low", "least effort", Complete),
    Entry("/effort high", "most effort", Complete),
    Entry("/goal", "set a goal", Continues),
    Entry("/goal clear", "drop the goal", Complete),
  ]
}

fn commands(rows: List(composer.Entry)) -> List(String) {
  list.map(rows, fn(row) { row.command })
}

pub fn entries_decode_the_servers_table_test() {
  assert composer.entries(
      "[{\"c\":\"/compact\",\"d\":\"shrink\",\"a\":false},"
      <> "{\"c\":\"/effort\",\"d\":\"set\",\"a\":true}]",
    )
    == [
      Entry("/compact", "shrink", Complete),
      Entry("/effort", "set", Continues),
    ]
}

pub fn entries_that_are_not_a_table_decode_to_none_test() {
  assert composer.entries("not json") == []
  assert composer.entries("{\"c\":\"/compact\"}") == []
  assert composer.entries("[{\"c\":\"/compact\"}]") == []
}

pub fn a_slash_word_lists_the_one_word_commands_it_prefixes_test() {
  assert commands(composer.matching(table(), "/co")) == ["/compact", "/context"]
  assert commands(composer.matching(table(), "/effort")) == ["/effort"]
}

pub fn a_trailing_space_does_not_count_for_a_one_word_command_test() {
  assert commands(composer.matching(table(), "/compact ")) == ["/compact"]
}

pub fn text_that_is_not_a_slash_word_lists_nothing_test() {
  assert composer.matching(table(), "hello") == []
  assert composer.matching(table(), "") == []
  assert composer.matching(table(), "/nope now") == []
}

pub fn a_closed_vocabulary_lists_its_arguments_past_the_space_test() {
  assert commands(composer.matching(table(), "/effort "))
    == ["/effort low", "/effort high"]
  assert commands(composer.matching(table(), "/effort lo")) == ["/effort low"]
  assert commands(composer.matching(table(), "/goal c")) == ["/goal clear"]
}

pub fn leading_space_is_ignored_when_matching_test() {
  assert commands(composer.matching(table(), "  /co"))
    == ["/compact", "/context"]
}

pub fn control_or_command_enter_sends_and_cancels_the_default_test() {
  assert composer.intent("Enter", Sending, Fresh, Closed)
    == Some(Consumed(composer.Sent))
  assert composer.intent("Enter", Sending, Fresh, Listing)
    == Some(Consumed(composer.Sent))
}

pub fn a_held_send_chord_sends_once_test() {
  assert composer.intent("Enter", Sending, Repeating, Closed)
    == Some(Consumed(composer.Ignored))
}

pub fn keys_during_composition_are_the_input_methods_test() {
  assert composer.intent("Enter", Sending, Composing, Listing) == None
  assert composer.intent("ArrowDown", Bare, Composing, Listing) == None
}

pub fn the_list_keys_apply_only_while_it_shows_test() {
  assert composer.intent("ArrowDown", Bare, Fresh, Listing)
    == Some(Consumed(composer.Moved(composer.Down)))
  assert composer.intent("ArrowUp", Bare, Repeating, Listing)
    == Some(Consumed(composer.Moved(composer.Up)))
  assert composer.intent("Tab", Bare, Fresh, Listing)
    == Some(Consumed(composer.Accepted))
  assert composer.intent("Enter", Bare, Fresh, Listing)
    == Some(Consumed(composer.Accepted))
  assert composer.intent("Escape", Bare, Fresh, Listing)
    == Some(Observed(composer.Dismissed))

  assert composer.intent("ArrowDown", Bare, Fresh, Closed) == None
  assert composer.intent("Tab", Bare, Fresh, Closed) == None
  assert composer.intent("Enter", Bare, Fresh, Closed) == None
  assert composer.intent("Escape", Bare, Fresh, Closed) == None
}

pub fn a_held_tab_or_enter_takes_one_row_only_test() {
  assert composer.intent("Tab", Bare, Repeating, Listing) == None
  assert composer.intent("Enter", Bare, Repeating, Listing) == None
}

pub fn modified_list_keys_are_the_browsers_test() {
  assert composer.intent("ArrowDown", Other, Fresh, Listing) == None
  assert composer.intent("Tab", Other, Fresh, Listing) == None
  assert composer.intent("Enter", Other, Fresh, Listing) == None
}

pub fn the_highlight_wraps_at_both_ends_test() {
  assert composer.moved(0, 3, composer.Up) == 2
  assert composer.moved(2, 3, composer.Down) == 0
  assert composer.moved(1, 3, composer.Down) == 2
  assert composer.moved(1, 3, composer.Up) == 0
}

pub fn an_empty_list_holds_the_highlight_at_the_top_test() {
  assert composer.moved(0, 0, composer.Down) == 0
  assert composer.moved(5, 0, composer.Up) == 0
}

pub fn the_first_count_heard_is_the_baseline_test() {
  assert composer.hear(composer.Unseen, 4)
    == #(composer.Seen(taken: 4), composer.Nothing)
}

pub fn a_rising_count_claims_the_range_above_what_was_taken_test() {
  assert composer.hear(composer.Seen(taken: 4), 5)
    == #(composer.Seen(taken: 5), composer.Take(after: 4, up_to: 5))
}

pub fn two_returns_before_a_paint_claim_disjoint_ranges_test() {
  let #(returns, first) = composer.hear(composer.Seen(taken: 1), 2)
  let #(returns, second) = composer.hear(returns, 3)

  assert first == composer.Take(after: 1, up_to: 2)
  assert second == composer.Take(after: 2, up_to: 3)
  assert returns == composer.Seen(taken: 3)
}

pub fn a_repeated_or_falling_count_claims_nothing_test() {
  assert composer.hear(composer.Seen(taken: 4), 4)
    == #(composer.Seen(taken: 4), composer.Nothing)
  assert composer.hear(composer.Seen(taken: 4), 2)
    == #(composer.Seen(taken: 4), composer.Nothing)
}

pub fn a_count_that_falls_and_rises_again_does_not_retake_test() {
  let #(returns, _) = composer.hear(composer.Seen(taken: 4), 2)

  assert composer.hear(returns, 4)
    == #(composer.Seen(taken: 4), composer.Nothing)
}

pub fn taken_are_the_prompts_in_the_range_oldest_first_test() {
  assert composer.taken([#(3, "c"), #(1, "a"), #(2, "b")], 1, 3) == ["b", "c"]
}

pub fn taken_leaves_prompts_outside_the_range_test() {
  assert composer.taken([#(1, "a"), #(2, "b"), #(4, "d")], 2, 3) == []
  assert composer.taken([], 0, 5) == []
}

pub fn an_empty_draft_takes_the_prompt_as_its_draft_test() {
  assert composer.joined("", "again") == "again"
  assert composer.joined(" \n ", "again") == "again"
}

pub fn a_typed_draft_keeps_its_text_above_the_prompt_test() {
  assert composer.joined("draft", "again") == "draft\n\nagain"
  assert list.fold(["a", "b"], "draft", composer.joined) == "draft\n\na\n\nb"
}

pub fn a_row_already_in_view_leaves_the_list_where_it_is_test() {
  assert composer.revealed(30.0, 20.0, 0.0, 100.0) == 0.0
  assert composer.revealed(80.0, 20.0, 0.0, 100.0) == 0.0
}

pub fn a_row_above_the_view_is_brought_to_the_top_test() {
  assert composer.revealed(10.0, 20.0, 40.0, 100.0) == 10.0
}

pub fn a_row_below_the_view_is_brought_to_the_bottom_test() {
  assert composer.revealed(160.0, 20.0, 40.0, 100.0) == 80.0
}
