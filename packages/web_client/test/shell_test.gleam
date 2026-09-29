//// What `<loom-shell>` decides (`web_client/shell_rule`): which side columns
//// are open, which tab the panel shows, what each button and tab says, and
//// what a closed column lets the keyboard reach.

import gleam/option.{None, Some}
import web_client/shell_rule.{
  Changes, Closed, Layout, Listed, Open, Panel, Reachable, Session, Sidebar,
  Strands, Unlisted, Unreachable,
}

pub fn a_page_starts_with_both_columns_open_on_the_strands_tab_test() {
  assert shell_rule.initial()
    == Layout(sidebar: Open, panel: Open, tab: Strands)
  assert shell_rule.state(shell_rule.initial(), Sidebar) == Open
  assert shell_rule.state(shell_rule.initial(), Panel) == Open
}

// A button changes its own column and leaves the other as it was, in either
// order, and pressing it again puts the column back.
pub fn each_button_moves_only_its_own_column_test() {
  let sidebar_closed = shell_rule.toggled(shell_rule.initial(), Sidebar)
  assert sidebar_closed == Layout(sidebar: Closed, panel: Open, tab: Strands)

  let both_closed = shell_rule.toggled(sidebar_closed, Panel)
  assert both_closed == Layout(sidebar: Closed, panel: Closed, tab: Strands)

  let other_order =
    shell_rule.toggled(shell_rule.toggled(shell_rule.initial(), Panel), Sidebar)
  assert other_order == both_closed

  assert shell_rule.toggled(both_closed, Sidebar)
    == Layout(sidebar: Open, panel: Closed, tab: Strands)
  assert shell_rule.toggled(shell_rule.toggled(both_closed, Panel), Panel)
    == both_closed
}

// The rule the design states for a hidden column: its content is not
// reachable by the keyboard. It follows the state alone, so no layout can
// hold a closed column that a key can reach.
pub fn a_closed_column_cannot_be_reached_and_an_open_one_can_test() {
  assert shell_rule.reach(Closed) == Unreachable
  assert shell_rule.reach(Open) == Reachable
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

// Pressing a tab shows that tab and moves nothing else: the columns keep
// their state, in either state, and pressing the shown tab again changes
// nothing.
pub fn a_tab_changes_only_the_tab_shown_test() {
  let layout = shell_rule.chosen(shell_rule.initial(), Changes)
  assert layout == Layout(sidebar: Open, panel: Open, tab: Changes)
  assert shell_rule.chosen(layout, Changes) == layout
  assert shell_rule.chosen(layout, Session).tab == Session
  assert shell_rule.chosen(layout, Strands) == shell_rule.initial()

  let closed = shell_rule.toggled(shell_rule.initial(), Panel)
  assert shell_rule.chosen(closed, Session)
    == Layout(sidebar: Open, panel: Closed, tab: Session)
}

// A column's button does not change the tab, so a panel closed and opened
// again comes back on the tab it left.
pub fn closing_and_opening_the_panel_keeps_the_tab_test() {
  let layout = shell_rule.chosen(shell_rule.initial(), Session)
  let reopened =
    layout
    |> shell_rule.toggled(Panel)
    |> shell_rule.toggled(Panel)
  assert reopened == layout
  assert shell_rule.toggled(layout, Sidebar).tab == Session
}

pub fn the_tabs_are_drawn_in_a_fixed_order_with_fixed_words_test() {
  assert shell_rule.tabs() == [Strands, Changes, Session]
  assert shell_rule.tab_label(Strands) == "Strands"
  assert shell_rule.tab_label(Changes) == "Changes"
  assert shell_rule.tab_label(Session) == "Session"
}

// The stylesheet spells these states, so each is a fixed literal that no tab
// shares with another.
pub fn each_tab_has_its_own_custom_state_test() {
  assert shell_rule.tab_state(Strands) == "tab-strands"
  assert shell_rule.tab_state(Changes) == "tab-changes"
  assert shell_rule.tab_state(Session) == "tab-session"
}

// The badge count is the server's number. Decoding is total: a value that is
// not a plain, short, non-negative number is none, whatever else it holds.
pub fn the_needing_attribute_decodes_totally_test() {
  assert shell_rule.needing("0") == 0
  assert shell_rule.needing("3") == 3
  assert shell_rule.needing("12") == 12
  assert shell_rule.needing("9999") == 9999
  assert shell_rule.needing("") == 0
  assert shell_rule.needing("-1") == 0
  assert shell_rule.needing("+2") == 0
  assert shell_rule.needing("1.5") == 0
  assert shell_rule.needing("2 ") == 0
  assert shell_rule.needing("99999") == 0
  assert shell_rule.needing("<b>2</b>") == 0
  assert shell_rule.needing("1e3") == 0
}

pub fn the_badge_shows_a_count_up_to_nine_and_nothing_for_none_test() {
  assert shell_rule.badge(0) == None
  assert shell_rule.badge(-3) == None
  assert shell_rule.badge(1) == Some("1")
  assert shell_rule.badge(9) == Some("9")
  assert shell_rule.badge(10) == Some("9+")
  assert shell_rule.badge(9999) == Some("9+")
}

// The number is not read by a screen reader from the badge, which is
// decoration, so the tab's own label says it.
pub fn the_strands_tab_names_how_many_strands_wait_test() {
  assert shell_rule.strands_words(0) == "Strands"
  assert shell_rule.strands_words(1) == "Strands, 1 needs approval"
  assert shell_rule.strands_words(2) == "Strands, 2 need approval"
  assert shell_rule.strands_words(-1) == "Strands"
}

// The marker on a control with no handler is the server's number, a card's
// position. Decoding is total: whatever else it holds is no request, so a
// control that says something else does nothing.
pub fn a_strand_marker_decodes_totally_test() {
  assert shell_rule.relay("0") == Ok(shell_rule.Relay(0, shell_rule.Keep))
  assert shell_rule.relay("1") == Ok(shell_rule.Relay(1, shell_rule.Show))
  assert shell_rule.relay("12") == Ok(shell_rule.Relay(12, shell_rule.Show))
  assert shell_rule.relay("999") == Ok(shell_rule.Relay(999, shell_rule.Show))
  assert shell_rule.relay("007") == Ok(shell_rule.Relay(7, shell_rule.Show))
  assert shell_rule.relay("") == Error(Nil)
  assert shell_rule.relay("1000") == Error(Nil)
  assert shell_rule.relay("-1") == Error(Nil)
  assert shell_rule.relay("+1") == Error(Nil)
  assert shell_rule.relay("1.0") == Error(Nil)
  assert shell_rule.relay(" 1") == Error(Nil)
  assert shell_rule.relay("main") == Error(Nil)
  assert shell_rule.relay("sub:tests") == Error(Nil)
  assert shell_rule.relay("<b>1</b>") == Error(Nil)
  assert shell_rule.relay("1\n2") == Error(Nil)
}

// A click on a strand shows the panel on the Strands tab wherever the reader
// left it, and leaves the sidebar alone, in either state.
pub fn a_relayed_strand_click_shows_the_strands_tab_test() {
  let away =
    shell_rule.initial()
    |> shell_rule.toggled(Panel)
    |> shell_rule.toggled(Sidebar)
    |> shell_rule.chosen(Session)
  assert away == Layout(sidebar: Closed, panel: Closed, tab: Session)

  let shown = shell_rule.relayed(away, shell_rule.Relay(2, shell_rule.Show))
  assert shown == Layout(sidebar: Closed, panel: Open, tab: Strands)

  // Already showing: nothing moves.
  assert shell_rule.relayed(
      shell_rule.initial(),
      shell_rule.Relay(2, shell_rule.Show),
    )
    == shell_rule.initial()
}

// `All strands` is a relay of position zero: it presses `main`'s card and does
// not reopen a panel the reader closed, or leave the tab they chose.
pub fn all_strands_leaves_the_layout_as_it_is_test() {
  let away =
    shell_rule.initial()
    |> shell_rule.toggled(Panel)
    |> shell_rule.chosen(Changes)
  let assert Ok(relay) = shell_rule.relay("0")
  assert shell_rule.relayed(away, relay) == away
}

// The card pressed is found by the server's fixed attribute and the number
// alone.
pub fn a_card_is_named_by_its_position_test() {
  assert shell_rule.card_selector(0) == "[data-loom-card=\"0\"]"
  assert shell_rule.card_selector(14) == "[data-loom-card=\"14\"]"
}
