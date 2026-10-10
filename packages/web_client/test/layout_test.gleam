//// What `<loom-shell>` keeps between page loads (`web_client/layout_rule`):
//// the storage item's name, how a layout is written, and how any stored text
//// is read back into a layout.

import gleam/list
import gleam/option.{None, Some}
import web_client/layout_rule.{Anonymous, Identified}
import web_client/shell_rule.{
  Changes, Closed, Layout, Open, Panel, Session, Strands, Trace,
}

const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// Storage that throws answers the same `Error` as an item that is not there,
// so a blocked browser is the same case as a first visit.
pub fn a_page_with_nothing_stored_gets_the_default_layout_test() {
  assert layout_rule.restore(Error(Nil)) == shell_rule.initial()
}

pub fn a_layout_survives_a_round_trip_test() {
  let layout = Layout(sidebar: Closed, panel: Open, tab: Session)
  assert layout_rule.restore(Ok(layout_rule.encode(layout))) == layout

  let toggled = shell_rule.toggled(shell_rule.initial(), Panel)
  assert layout_rule.restore(Ok(layout_rule.encode(toggled))) == toggled
}

pub fn every_layout_round_trips_test() {
  let states = [Open, Closed]
  let tabs = shell_rule.tabs()
  let layouts = {
    use sidebar <- list.flat_map(states)
    use panel <- list.flat_map(states)
    use tab <- list.flat_map(tabs)
    [Layout(sidebar:, panel:, tab:)]
  }
  assert list.length(layouts) == 16
  assert list.all(layouts, fn(layout) {
    layout_rule.restore(Ok(layout_rule.encode(layout))) == layout
  })
}

pub fn the_encoding_is_a_plain_object_of_words_test() {
  assert layout_rule.encode(shell_rule.initial())
    == "{\"sidebar\":\"open\",\"panel\":\"open\",\"tab\":\"strands\"}"
  assert layout_rule.encode(Layout(sidebar: Closed, panel: Closed, tab: Changes))
    == "{\"sidebar\":\"closed\",\"panel\":\"closed\",\"tab\":\"changes\"}"
}

// Whatever is in the item, the page draws. None of these is a layout, and
// each is the default.
pub fn a_malformed_value_gets_the_default_layout_test() {
  let default = shell_rule.initial()
  assert layout_rule.restore(Ok("")) == default
  assert layout_rule.restore(Ok("not json")) == default
  assert layout_rule.restore(Ok("{\"sidebar\":\"closed\"")) == default
  assert layout_rule.restore(Ok("[]")) == default
  assert layout_rule.restore(Ok("null")) == default
  assert layout_rule.restore(Ok("\"closed\"")) == default
  assert layout_rule.restore(Ok("{\"sidebar\":true,\"panel\":false}"))
    == default
  assert layout_rule.restore(Ok("{\"tab\":3}")) == default
}

// A field of the wrong type fails the whole decoder, sibling fields
// included, as `restore` documents: the record is untrustworthy, so the
// default stands rather than half of it.
pub fn a_field_of_the_wrong_type_discards_the_whole_record_test() {
  assert layout_rule.restore(Ok("{\"sidebar\":\"closed\",\"panel\":false}"))
    == shell_rule.initial()
  assert layout_rule.restore(Ok(
      "{\"sidebar\":\"closed\",\"panel\":\"closed\",\"tab\":3}",
    ))
    == shell_rule.initial()
}

// A tab that a later release removed, or a word nothing wrote, is the
// default for that field alone: the columns the same object names are kept.
pub fn an_unknown_tab_is_the_default_tab_and_keeps_the_columns_test() {
  assert layout_rule.restore(Ok(
      "{\"sidebar\":\"closed\",\"panel\":\"open\",\"tab\":\"jobs\"}",
    ))
    == Layout(sidebar: Closed, panel: Open, tab: Strands)
  assert layout_rule.restore(Ok(
      "{\"sidebar\":\"open\",\"panel\":\"closed\",\"tab\":\"Changes\"}",
    ))
    == Layout(sidebar: Open, panel: Closed, tab: Strands)
}

// A layout stored before the Trace tab existed names one of the three older
// tabs and decodes as it did, and a stored `trace` is the new tab.
pub fn a_layout_stored_before_the_trace_tab_still_decodes_test() {
  assert layout_rule.restore(Ok(
      "{\"sidebar\":\"closed\",\"panel\":\"open\",\"tab\":\"session\"}",
    ))
    == Layout(sidebar: Closed, panel: Open, tab: Session)
  assert layout_rule.restore(Ok(
      "{\"sidebar\":\"open\",\"panel\":\"open\",\"tab\":\"trace\"}",
    ))
    == Layout(sidebar: Open, panel: Open, tab: Trace)
}

pub fn an_unknown_column_word_is_open_and_keeps_the_tab_test() {
  assert layout_rule.restore(Ok(
      "{\"sidebar\":\"ajar\",\"panel\":\"closed\",\"tab\":\"session\"}",
    ))
    == Layout(sidebar: Open, panel: Closed, tab: Session)
}

pub fn a_missing_field_is_that_fields_default_test() {
  assert layout_rule.restore(Ok("{}")) == shell_rule.initial()
  assert layout_rule.restore(Ok("{\"panel\":\"closed\"}"))
    == Layout(sidebar: Open, panel: Closed, tab: Strands)
  assert layout_rule.restore(Ok("{\"tab\":\"changes\",\"extra\":1}"))
    == Layout(sidebar: Open, panel: Open, tab: Changes)
}

pub fn the_layout_is_kept_under_the_workspace_digest_test() {
  assert layout_rule.workspace(digest) == Identified(digest)
  assert layout_rule.layout_key(Identified(digest))
    == Some("loom.layout.v1." <> digest)
}

// The key is built only from what the daemon computes. A path, markup, an
// empty attribute, upper case or a digest of the wrong length is not one, and
// a page with no workspace neither reads nor writes a layout.
pub fn text_that_is_not_a_digest_names_no_workspace_test() {
  assert layout_rule.workspace("") == Anonymous
  assert layout_rule.workspace("/home/me/project") == Anonymous
  assert layout_rule.workspace("<b>") == Anonymous
  assert layout_rule.workspace("0123abcd") == Anonymous
  assert layout_rule.workspace(digest <> "0") == Anonymous
  assert layout_rule.workspace(
      "0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef",
    )
    == Anonymous
  assert layout_rule.layout_key(Anonymous) == None
}

pub fn two_workspaces_do_not_share_a_key_test() {
  let other = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
  assert layout_rule.layout_key(layout_rule.workspace(digest))
    != layout_rule.layout_key(layout_rule.workspace(other))
}

// The theme is the browser's, not the workspace's, so its item has no digest
// and cannot collide with a layout's.
pub fn the_theme_has_its_own_item_test() {
  assert layout_rule.theme_key == "loom.theme.v1"
  assert layout_rule.layout_key(Identified(digest))
    != Some(layout_rule.theme_key)
}

// A page whose storage says nothing, or something no release wrote, follows
// the system's setting.
pub fn a_missing_or_unknown_theme_follows_the_system_test() {
  assert layout_rule.theme(Error(Nil)) == layout_rule.System
  assert layout_rule.theme(Ok("")) == layout_rule.System
  assert layout_rule.theme(Ok("sepia")) == layout_rule.System
  assert layout_rule.theme(Ok("Dark")) == layout_rule.System
  assert layout_rule.theme(Ok("{\"theme\":\"dark\"}")) == layout_rule.System
}

pub fn every_theme_round_trips_test() {
  list.each(
    [layout_rule.System, layout_rule.Light, layout_rule.Dark],
    fn(theme) {
      assert layout_rule.theme(Ok(layout_rule.encode_theme(theme))) == theme
    },
  )
}

// One button, three themes, and back where it started. Pressing it three
// times is the identity, so the reader can always return to the system's
// setting.
pub fn the_button_cycles_through_all_three_and_back_test() {
  assert layout_rule.next_theme(layout_rule.System) == layout_rule.Light
  assert layout_rule.next_theme(layout_rule.Light) == layout_rule.Dark
  assert layout_rule.next_theme(layout_rule.Dark) == layout_rule.System
}

// Following the system is the absence of the root's attribute, which is what
// leaves the stylesheet's `prefers-color-scheme` rule in charge.
pub fn only_a_chosen_theme_sets_the_root_attribute_test() {
  assert layout_rule.data_theme(layout_rule.System) == None
  assert layout_rule.data_theme(layout_rule.Light) == Some("light")
  assert layout_rule.data_theme(layout_rule.Dark) == Some("dark")
}

pub fn the_button_says_what_the_page_shows_and_what_pressing_does_test() {
  assert layout_rule.word(layout_rule.System) == "Auto"
  assert layout_rule.label(layout_rule.System)
    == "Theme: following the system. Switch to light."
  assert layout_rule.label(layout_rule.Light) == "Theme: light. Switch to dark."
  assert layout_rule.label(layout_rule.Dark)
    == "Theme: dark. Switch to following the system."
}

// The panel's tab is the reader's habit, so it has an item of its own for the
// browser and does not depend on the workspace's layout item.
pub fn the_tab_has_its_own_item_per_browser_test() {
  assert layout_rule.tab_key == "loom.panel.tab.v1"
  assert layout_rule.encode_tab(Changes) == "changes"
  list.each(shell_rule.tabs(), fn(tab) {
    assert layout_rule.restored_tab(Ok(layout_rule.encode_tab(tab)))
      == Some(tab)
  })
}

pub fn a_missing_or_unknown_saved_tab_is_no_choice_test() {
  assert layout_rule.restored_tab(Error(Nil)) == None
  assert layout_rule.restored_tab(Ok("jobs")) == None
  assert layout_rule.restored_tab(Ok("Changes")) == None
}

pub fn a_panel_width_is_kept_under_one_item_for_the_browser_test() {
  assert layout_rule.width_key == "loom.panel.width.v1"
  assert layout_rule.encode_width(480) == "480"
}

pub fn a_stored_width_in_range_is_restored_test() {
  assert layout_rule.restored_width(Ok("480")) == Some(480)
  assert layout_rule.restored_width(Ok("280")) == Some(280)
  assert layout_rule.restored_width(Ok("4000")) == Some(4000)
}

// Text from storage is whatever anything wrote, so a width this release
// would not choose, or no number at all, leaves the default standing.
pub fn a_stored_width_out_of_range_or_malformed_is_ignored_test() {
  assert layout_rule.restored_width(Error(Nil)) == None
  assert layout_rule.restored_width(Ok("")) == None
  assert layout_rule.restored_width(Ok("wide")) == None
  assert layout_rule.restored_width(Ok("340px")) == None
  assert layout_rule.restored_width(Ok("34.5")) == None
  assert layout_rule.restored_width(Ok("279")) == None
  assert layout_rule.restored_width(Ok("4001")) == None
  assert layout_rule.restored_width(Ok("-340")) == None
  assert layout_rule.restored_width(Ok("0")) == None
  assert layout_rule.restored_width(Ok("99999999999999999999")) == None
}

pub fn every_width_in_range_round_trips_test() {
  assert list.all(sweep(280, 4000), fn(width) {
    layout_rule.restored_width(Ok(layout_rule.encode_width(width)))
    == Some(width)
  })
}

// Every integer from `low` to `high`, for the sweeps above.
fn sweep(low: Int, high: Int) -> List(Int) {
  case low > high {
    True -> []
    False -> [low, ..sweep(low + 1, high)]
  }
}
