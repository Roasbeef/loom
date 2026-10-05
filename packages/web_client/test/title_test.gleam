//// What `<loom-title>` decides (`web_client/title_rule`): the tab's title for a
//// session page, from the name the bar draws and the count of strands waiting.

import gleam/string
import web_client/title_rule

pub fn a_session_tab_is_titled_by_its_name_test() {
  assert title_rule.session("ws · main", 0) == "ws · main — Loom"
  assert title_rule.session("docs sweep", 0) == "docs sweep — Loom"
}

// A session that needs the person shows how many strands wait, in front, so a
// tab strip full of sessions says which one to go to.
pub fn a_waiting_session_leads_with_its_count_test() {
  assert title_rule.session("ws · main", 1) == "(1) ws · main — Loom"
  assert title_rule.session("ws · main", 12) == "(12) ws · main — Loom"
}

// Before the bar is drawn there is no name, and the title is the product alone
// rather than an empty session or an identity.
pub fn a_page_with_no_name_is_the_product_alone_test() {
  assert title_rule.session("", 0) == "Loom"
  assert title_rule.session("   ", 3) == "Loom"
}

pub fn a_name_is_trimmed_test() {
  assert title_rule.session("  ws  ", 0) == "ws — Loom"
}

// The server writes the count, but a value that is not a count is no waiting
// session, and a negative one is not either.
pub fn the_count_is_a_whole_number_above_zero_test() {
  assert title_rule.needing_from("3") == 3
  assert title_rule.needing_from(" 2 ") == 2
  assert title_rule.needing_from("0") == 0
  assert title_rule.needing_from("-4") == 0
  assert title_rule.needing_from("many") == 0
  assert title_rule.needing_from("") == 0
}

// A session's name is model-adjacent text. The title is assigned to the
// document as text, so the rule passes the name through as it is and adds
// nothing around it that could be read as markup.
pub fn a_hostile_name_is_only_ever_title_text_test() {
  let hostile = "<img src=x onerror=alert(1)></title><script>x</script>"
  let title = title_rule.session(hostile, 0)
  assert title == hostile <> " — Loom"
  assert !string.contains(string.replace(title, hostile, ""), "<")
}
