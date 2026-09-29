//// What `<loom-shell>` keeps between page loads (`web_client/layout_rule`):
//// the storage item's name, how a layout is written, and how any stored text
//// is read back into a layout.

import gleam/list
import gleam/option.{None, Some}
import web_client/layout_rule.{Anonymous, Identified}
import web_client/shell_rule.{
  Changes, Closed, Layout, Open, Panel, Session, Strands,
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
  assert list.length(layouts) == 12
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

// A tab that a later release removed, or a word nothing wrote, is the
// default for that field alone: the columns the same object names are kept.
pub fn an_unknown_tab_is_the_default_tab_and_keeps_the_columns_test() {
  assert layout_rule.restore(Ok(
      "{\"sidebar\":\"closed\",\"panel\":\"open\",\"tab\":\"trace\"}",
    ))
    == Layout(sidebar: Closed, panel: Open, tab: Strands)
  assert layout_rule.restore(Ok(
      "{\"sidebar\":\"open\",\"panel\":\"closed\",\"tab\":\"Changes\"}",
    ))
    == Layout(sidebar: Open, panel: Closed, tab: Strands)
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
