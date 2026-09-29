//// What `<loom-shell>` decides (`web_client/shell_rule`): which side columns
//// are open, what each button says, and what a closed column lets the
//// keyboard reach.

import gleam/list
import web_client/shell_rule.{
  Closed, Layout, Listed, Open, Panel, Reachable, Sidebar, Unlisted, Unreachable,
}

pub fn a_page_starts_with_both_columns_open_test() {
  assert shell_rule.initial() == Layout(sidebar: Open, panel: Open)
  assert shell_rule.state(shell_rule.initial(), Sidebar) == Open
  assert shell_rule.state(shell_rule.initial(), Panel) == Open
}

// A button changes its own column and leaves the other as it was, in either
// order, and pressing it again puts the column back.
pub fn each_button_moves_only_its_own_column_test() {
  let sidebar_closed = shell_rule.toggled(shell_rule.initial(), Sidebar)
  assert sidebar_closed == Layout(sidebar: Closed, panel: Open)

  let both_closed = shell_rule.toggled(sidebar_closed, Panel)
  assert both_closed == Layout(sidebar: Closed, panel: Closed)

  let other_order =
    shell_rule.toggled(shell_rule.toggled(shell_rule.initial(), Panel), Sidebar)
  assert other_order == both_closed

  assert shell_rule.toggled(both_closed, Sidebar)
    == Layout(sidebar: Open, panel: Closed)
  assert shell_rule.toggled(shell_rule.toggled(both_closed, Panel), Panel)
    == both_closed
}

// The rule the design states for a hidden column: its content is not
// reachable by the keyboard. It follows the state alone, so no layout can
// hold a closed column that a key can reach.
pub fn a_closed_column_cannot_be_reached_and_an_open_one_can_test() {
  assert shell_rule.reach(Closed) == Unreachable
  assert shell_rule.reach(Open) == Reachable

  let layouts = [
    shell_rule.initial(),
    Layout(sidebar: Closed, panel: Open),
    Layout(sidebar: Open, panel: Closed),
    Layout(sidebar: Closed, panel: Closed),
  ]
  list.each(layouts, fn(layout) {
    list.each([Sidebar, Panel], fn(region) {
      let state = shell_rule.state(layout, region)
      assert { shell_rule.reach(state) == Unreachable } == { state == Closed }
    })
  })
}

pub fn each_button_says_what_pressing_it_does_test() {
  assert shell_rule.label(Sidebar, Open) == "Hide sessions"
  assert shell_rule.label(Sidebar, Closed) == "Show sessions"
  assert shell_rule.label(Panel, Open) == "Hide strands"
  assert shell_rule.label(Panel, Closed) == "Show strands"
}

// An observer's page has no sidebar, so its bar has no button for one; the
// strand panel's button is there either way.
pub fn a_page_without_a_sidebar_has_no_button_for_one_test() {
  assert shell_rule.has_button(Listed, Sidebar)
  assert !shell_rule.has_button(Unlisted, Sidebar)
  assert shell_rule.has_button(Listed, Panel)
  assert shell_rule.has_button(Unlisted, Panel)
}

// The server writes `listed` or `none`. Decoding is total: whatever else
// arrives, or nothing, is a page with no sidebar.
pub fn the_sidebar_attribute_decodes_totally_test() {
  assert shell_rule.presence("listed") == Listed
  assert shell_rule.presence("none") == Unlisted
  assert shell_rule.presence("") == Unlisted
  assert shell_rule.presence("Listed") == Unlisted
  assert shell_rule.presence(" listed") == Unlisted
  assert shell_rule.presence("listed listed") == Unlisted
  assert shell_rule.presence("<b>") == Unlisted
}
