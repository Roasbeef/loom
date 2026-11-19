//// The draft the browser holds across a reconnect: what is kept, for which
//// page, and when it is gone.

import gleam/option.{None, Some}
import gleam/string
import web_client/draft_rule

const page = "/ui/p/aa/orchestrators/bravo/sessions/s1/ws"

pub fn a_held_draft_comes_back_for_its_own_page_test() {
  let raw = draft_rule.holding(page, "fix the test\nthen run it")
  assert draft_rule.held(raw, page) == "fix the test\nthen run it"
}

pub fn another_pages_draft_is_not_put_back_test() {
  let raw = draft_rule.holding(page, "mine")
  assert draft_rule.held(raw, "/ui/p/bb/sessions/s2/ws") == ""
}

pub fn an_empty_draft_holds_nothing_test() {
  assert draft_rule.holding(page, "") == None
  assert draft_rule.holding(page, "  \n ") == None
}

pub fn a_missing_or_broken_attribute_holds_no_draft_test() {
  assert draft_rule.held(None, page) == ""
  assert draft_rule.held(Some("not json"), page) == ""
  assert draft_rule.held(Some("{\"key\":1}"), page) == ""
}

pub fn text_with_quotes_and_markup_round_trips_as_text_test() {
  let text = "say \"hi\" </script><b>x</b> \\ done"
  assert draft_rule.held(draft_rule.holding(page, text), page) == text
}

pub fn a_draft_is_cut_to_the_limit_test() {
  let long = repeated(draft_rule.limit + 50)
  let kept = draft_rule.held(draft_rule.holding(page, long), page)
  assert kept == repeated(draft_rule.limit)
}

fn repeated(count: Int) -> String {
  string.repeat("a", count)
}
