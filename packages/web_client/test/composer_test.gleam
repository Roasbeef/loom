//// The composer's rules: the table it decodes, which rows a draft lists, what
//// a key does, how the highlight moves and is kept in view, and how a
//// returned prompt is claimed once and joined to a draft.

import gleam/list
import gleam/option.{None, Some}
import web_client/composer_rule.{
  type Entry, Bare, Closed, Complete, Composing, Consumed, Continues, Entry,
  Fresh, Listing, Observed, Other, Repeating, Sending,
}

fn table() -> List(Entry) {
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

fn commands(rows: List(Entry)) -> List(String) {
  list.map(rows, fn(row) { row.command })
}

pub fn entries_decode_the_servers_table_test() {
  assert composer_rule.entries(
      "[{\"c\":\"/compact\",\"d\":\"shrink\",\"a\":false},"
      <> "{\"c\":\"/effort\",\"d\":\"set\",\"a\":true}]",
    )
    == [
      Entry("/compact", "shrink", Complete),
      Entry("/effort", "set", Continues),
    ]
}

pub fn entries_that_are_not_a_table_decode_to_none_test() {
  assert composer_rule.entries("not json") == []
  assert composer_rule.entries("{\"c\":\"/compact\"}") == []
  assert composer_rule.entries("[{\"c\":\"/compact\"}]") == []
}

pub fn a_slash_word_lists_the_one_word_commands_it_prefixes_test() {
  assert commands(composer_rule.matching(table(), "/co"))
    == ["/compact", "/context"]
  assert commands(composer_rule.matching(table(), "/effort")) == ["/effort"]
}

pub fn a_trailing_space_does_not_count_for_a_one_word_command_test() {
  assert commands(composer_rule.matching(table(), "/compact ")) == ["/compact"]
}

pub fn text_that_is_not_a_slash_word_lists_nothing_test() {
  assert composer_rule.matching(table(), "hello") == []
  assert composer_rule.matching(table(), "") == []
  assert composer_rule.matching(table(), "/nope now") == []
}

pub fn a_closed_vocabulary_lists_its_arguments_past_the_space_test() {
  assert commands(composer_rule.matching(table(), "/effort "))
    == ["/effort low", "/effort high"]
  assert commands(composer_rule.matching(table(), "/effort lo"))
    == ["/effort low"]
  assert commands(composer_rule.matching(table(), "/goal c")) == ["/goal clear"]
}

pub fn leading_space_is_ignored_when_matching_test() {
  assert commands(composer_rule.matching(table(), "  /co"))
    == ["/compact", "/context"]
}

pub fn control_or_command_enter_sends_and_cancels_the_default_test() {
  assert composer_rule.intent("Enter", Sending, Fresh, Closed)
    == Some(Consumed(composer_rule.Send))
  assert composer_rule.intent("Enter", Sending, Fresh, Listing)
    == Some(Consumed(composer_rule.Send))
}

pub fn a_held_send_chord_sends_once_test() {
  assert composer_rule.intent("Enter", Sending, Repeating, Closed)
    == Some(Consumed(composer_rule.Hold))
}

pub fn keys_during_composition_are_the_input_methods_test() {
  assert composer_rule.intent("Enter", Sending, Composing, Listing) == None
  assert composer_rule.intent("ArrowDown", Bare, Composing, Listing) == None
}

pub fn the_list_keys_apply_only_while_it_shows_test() {
  assert composer_rule.intent("ArrowDown", Bare, Fresh, Listing)
    == Some(Consumed(composer_rule.Move(composer_rule.Down)))
  assert composer_rule.intent("ArrowUp", Bare, Repeating, Listing)
    == Some(Consumed(composer_rule.Move(composer_rule.Up)))
  assert composer_rule.intent("Tab", Bare, Fresh, Listing)
    == Some(Consumed(composer_rule.Accept))
  assert composer_rule.intent("Enter", Bare, Fresh, Listing)
    == Some(Consumed(composer_rule.Accept))
  assert composer_rule.intent("Escape", Bare, Fresh, Listing)
    == Some(Observed(composer_rule.Dismiss))

  assert composer_rule.intent("ArrowDown", Bare, Fresh, Closed) == None
  assert composer_rule.intent("Tab", Bare, Fresh, Closed) == None
  assert composer_rule.intent("Enter", Bare, Fresh, Closed) == None
  assert composer_rule.intent("Escape", Bare, Fresh, Closed) == None
}

pub fn a_held_tab_or_enter_takes_one_row_only_test() {
  assert composer_rule.intent("Tab", Bare, Repeating, Listing) == None
  assert composer_rule.intent("Enter", Bare, Repeating, Listing) == None
}

pub fn modified_list_keys_are_the_browsers_test() {
  assert composer_rule.intent("ArrowDown", Other, Fresh, Listing) == None
  assert composer_rule.intent("Tab", Other, Fresh, Listing) == None
  assert composer_rule.intent("Enter", Other, Fresh, Listing) == None
}

pub fn the_highlight_wraps_at_both_ends_test() {
  assert composer_rule.moved(0, 3, composer_rule.Up) == 2
  assert composer_rule.moved(2, 3, composer_rule.Down) == 0
  assert composer_rule.moved(1, 3, composer_rule.Down) == 2
  assert composer_rule.moved(1, 3, composer_rule.Up) == 0
}

pub fn an_empty_list_holds_the_highlight_at_the_top_test() {
  assert composer_rule.moved(0, 0, composer_rule.Down) == 0
  assert composer_rule.moved(5, 0, composer_rule.Up) == 0
}

pub fn the_first_count_heard_is_the_baseline_test() {
  assert composer_rule.hear(composer_rule.Unseen, 4)
    == #(composer_rule.Seen(taken: 4), composer_rule.Nothing)
}

pub fn a_rising_count_claims_the_range_above_what_was_taken_test() {
  assert composer_rule.hear(composer_rule.Seen(taken: 4), 5)
    == #(composer_rule.Seen(taken: 5), composer_rule.Take(after: 4, up_to: 5))
}

pub fn two_returns_before_a_paint_claim_disjoint_ranges_test() {
  let #(returns, first) = composer_rule.hear(composer_rule.Seen(taken: 1), 2)
  let #(returns, second) = composer_rule.hear(returns, 3)

  assert first == composer_rule.Take(after: 1, up_to: 2)
  assert second == composer_rule.Take(after: 2, up_to: 3)
  assert returns == composer_rule.Seen(taken: 3)
}

pub fn a_repeated_or_falling_count_claims_nothing_test() {
  assert composer_rule.hear(composer_rule.Seen(taken: 4), 4)
    == #(composer_rule.Seen(taken: 4), composer_rule.Nothing)
  assert composer_rule.hear(composer_rule.Seen(taken: 4), 2)
    == #(composer_rule.Seen(taken: 4), composer_rule.Nothing)
}

pub fn a_count_that_falls_and_rises_again_does_not_retake_test() {
  let #(returns, _) = composer_rule.hear(composer_rule.Seen(taken: 4), 2)

  assert composer_rule.hear(returns, 4)
    == #(composer_rule.Seen(taken: 4), composer_rule.Nothing)
}

pub fn taken_are_the_prompts_in_the_range_oldest_first_test() {
  assert composer_rule.taken([#(3, "c"), #(1, "a"), #(2, "b")], 1, 3)
    == ["b", "c"]
}

pub fn taken_leaves_prompts_outside_the_range_test() {
  assert composer_rule.taken([#(1, "a"), #(2, "b"), #(4, "d")], 2, 3) == []
  assert composer_rule.taken([], 0, 5) == []
}

pub fn an_empty_draft_takes_the_prompt_as_its_draft_test() {
  assert composer_rule.joined("", "again") == "again"
  assert composer_rule.joined(" \n ", "again") == "again"
}

pub fn a_typed_draft_keeps_its_text_above_the_prompt_test() {
  assert composer_rule.joined("draft", "again") == "draft\n\nagain"
  assert list.fold(["a", "b"], "draft", composer_rule.joined)
    == "draft\n\na\n\nb"
}

pub fn a_row_already_in_view_leaves_the_list_where_it_is_test() {
  assert composer_rule.revealed(30.0, 20.0, 0.0, 100.0) == 0.0
  assert composer_rule.revealed(80.0, 20.0, 0.0, 100.0) == 0.0
}

pub fn a_row_above_the_view_is_brought_to_the_top_test() {
  assert composer_rule.revealed(10.0, 20.0, 40.0, 100.0) == 10.0
}

pub fn a_row_below_the_view_is_brought_to_the_bottom_test() {
  assert composer_rule.revealed(160.0, 20.0, 40.0, 100.0) == 80.0
}

// The send buttons are disabled while there is nothing to send, so the page
// never raises "Nothing to send." for a press of an empty editor.
pub fn an_empty_editor_with_no_image_has_nothing_to_send_test() {
  assert composer_rule.gate("", composer_rule.Unattached) == composer_rule.Shut
  assert composer_rule.gate("  \n\t", composer_rule.Unattached)
    == composer_rule.Shut
}

pub fn a_word_or_an_image_is_something_to_send_test() {
  assert composer_rule.gate("hi", composer_rule.Unattached)
    == composer_rule.Open
  assert composer_rule.gate("", composer_rule.Attached) == composer_rule.Open
  assert composer_rule.gate(" \n", composer_rule.Attached) == composer_rule.Open
}

pub fn the_attached_attribute_is_yes_or_nothing_test() {
  assert composer_rule.attachments("yes") == composer_rule.Attached
  assert composer_rule.attachments("no") == composer_rule.Unattached
  assert composer_rule.attachments("") == composer_rule.Unattached
}
