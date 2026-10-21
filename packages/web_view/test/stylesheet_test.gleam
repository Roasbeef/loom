//// The built stylesheet, for the few rules whose absence or value is a
//// finding of the web UI critique and has no other test: the sidebar draws no
//// strand bars, an idle session is one quiet colour on the home and the
//// sidebar, and a saved row's buttons keep clear of its chevron.
////
//// The text asserted on is the Tailwind build's output, which `make
//// gen-client` writes and `make web_assets --check` keeps current, so a
//// change to the source rules reaches this file only through a rebuild.

import gleam/list
import gleam/string
import simplifile
import web_view/page

fn stylesheet() -> String {
  let assert Ok(path) = page.static_file(page.stylesheet_asset)
    as "the stylesheet is in priv"
  let assert Ok(text) = simplifile.read(path) as "the stylesheet reads"
  text
}

// F132: the strand bars are gone from the sidebar, so no rule styles them.
pub fn no_rule_styles_the_strand_bars_test() {
  let css = stylesheet()
  assert !string.contains(css, ".dots{")
  assert !string.contains(css, ".bar{")
  assert !string.contains(css, ".bar.w{")
}

// F125: an idle row's dot is the quiet colour on the home as it is in the
// sidebar. The accent rule on the home names the running and working rows and
// not the idle ones.
pub fn an_idle_dot_is_one_quiet_colour_on_both_lists_test() {
  let css = stylesheet()
  assert string.contains(
    css,
    ".residency.idle .glyph{color:var(--color-fg-quiet)}",
  )
  assert string.contains(
    css,
    ".home-row.idle .home-glyph{color:var(--color-fg-quiet)}",
  )
  assert !string.contains(css, ".home-row.idle .home-glyph,")
  assert !string.contains(css, ",.home-row.idle .home-glyph")
}

// F137: the buttons of a saved row end 46px from the right, which leaves the
// chevron a clear gap at the narrow widths where the row is at its tightest.
pub fn a_rows_buttons_keep_clear_of_its_chevron_test() {
  let css = stylesheet()
  assert string.contains(css, "position:absolute;top:50%;right:46px")
}

// A sidebar row's menu toggle is a 32px square at the row's right edge, drawn
// on hover and on keyboard focus, and a 44px target that is always drawn on a
// touch screen, which has no hover. It is a native disclosure, so it needs no
// handler and the row's own button keeps every click on the row's body.
pub fn the_row_menu_toggle_is_a_small_target_and_a_large_one_on_touch_test() {
  let css = stylesheet()
  assert string.contains(css, ".row-menu-toggle{width:32px;height:32px")
  assert string.contains(css, "opacity:0")
  assert string.contains(
    css,
    ".row-menu-toggle{opacity:1;width:44px;height:44px",
  )
  assert string.contains(css, "@media (hover:none)")
}

// The archive control keeps its class and is drawn as a labelled item of the
// row's menu, whose text is the control's own `aria-label`.
pub fn the_archive_control_is_a_labelled_menu_item_test() {
  let css = stylesheet()
  assert string.contains(css, ".session-archive:after{content:attr(aria-label)")
  assert !string.contains(css, "li.session:hover>.session-archive")
}

// The phone's menu button carries a count of the sessions waiting on the person,
// as a word for each number the page can send, capped at ten.
pub fn the_menu_button_counts_the_sessions_that_need_the_person_test() {
  let css = stylesheet()
  assert string.contains(
    css,
    ":host([waiting=\"1\"]) .toggle-sidebar:after{content:\"1\"}",
  )
  assert string.contains(
    css,
    ":host([waiting=\"10\"]) .toggle-sidebar:after{content:\"9+\"}",
  )
}

// F143: a home row's buttons sit in four fixed columns, Rename first, so
// Rename is where it is on every row whichever buttons the row has. Stop and
// Move share the second, Archive has the third and Delete the fourth.
pub fn a_rows_buttons_keep_their_columns_test() {
  let css = stylesheet()
  assert string.contains(css, "grid-template-columns:72px 72px 72px 64px")
  assert string.contains(css, ".home-rename{grid-column:1}")
  assert string.contains(css, ".home-act-lead{grid-column:2}")
  assert string.contains(css, ".home-act{grid-column:3}")
  assert string.contains(css, ".home-act-delete{grid-column:4}")
}

// The Abandon controls have a quiet-button rule: a hairline border, no fill.
pub fn the_abandon_controls_are_quiet_buttons_test() {
  let css = stylesheet()
  assert string.contains(
    css,
    "button.admin-abandon{border:1px solid var(--color-divider);",
  )
}

// F156: the transcript ends in room for the "Jump to latest" button, so the
// last row is not under it when the reader has scrolled to the end.
pub fn the_transcript_ends_in_room_for_the_jump_button_test() {
  let css = stylesheet()
  assert string.contains(css, "scrollbar-width:thin;flex-direction:column")
  assert string.contains(css, "padding-bottom:56px")
}

// F163: the "Jump to latest" button is over no row at any width. It is a disc in
// a 48px strip at the scroller's right edge, and the column keeps a right
// padding of whatever the gutter lacks, so the strip is clear with the strands
// panel open (a 44px gutter at 1440) and at 800px (none).
pub fn the_jump_button_has_a_strip_no_row_reaches_test() {
  let css = stylesheet()
  assert string.contains(css, "container-type:inline-size")
  assert string.contains(css, "padding-right:clamp(0px,438px - 50cqw,48px)")
  // The anchor's own padding is set in the rule that also names the scroller,
  // which outranks `loom-follow.follow > *` and its clamp.
  assert string.contains(
    css,
    "loom-follow.follow>.jump-anchor{align-self:stretch;max-width:none;padding-right:8px}",
  )
  assert string.contains(css, ".jump-latest{")
  assert string.contains(css, "width:32px;height:32px;")
}

// The body of the first rule that begins with `selector{`, or empty.
fn rule_of(css: String, selector: String) -> String {
  case string.split_once(css, selector <> "{") {
    Ok(#(_, after)) ->
      case string.split_once(after, "}") {
        Ok(#(body, _)) -> body
        Error(Nil) -> ""
      }
    Error(Nil) -> ""
  }
}

// The Admin page's machines (protocol-change/085): each group is a tinted list
// with a hairline border, the machine's page and the peers' strip are tinted
// blocks with a hairline border, none of them has a coloured edge or a shadow,
// and a state pill never wraps.
pub fn the_machines_have_no_accent_bar_and_no_shadow_test() {
  let css = stylesheet()
  assert string.contains(
    rule_of(css, "ul.admin-fleet"),
    "border:1px solid var(--color-divider)",
  )
  assert string.contains(rule_of(css, "}.pill"), "white-space:nowrap")
  list.each(
    [
      "section.admin-machine",
      "ul.admin-fleet",
      ".admin-node-pick[aria-current]",
      ".admin-tabs",
      "button.admin-tab[aria-selected=true]",
      ".admin-command",
      ".home-peers",
    ],
    fn(selector) {
      let body = rule_of(css, selector)
      assert body != "" as selector
      assert !string.contains(body, "shadow") as selector
      assert !string.contains(body, "border-left") as selector
      assert !string.contains(body, "border-inline-start") as selector
    },
  )
  assert string.contains(
    rule_of(css, "section.admin-machine"),
    "border:1px solid var(--color-divider)",
  )
  assert string.contains(
    rule_of(css, ".home-peers"),
    "border:1px solid var(--color-divider)",
  )
}

// A pulsing mark is a motion, so the stylesheet stops every animation under
// reduced motion and leaves the marks and the ticking text standing: the
// running call's dot and the composer's busy dot both stay, still.
pub fn reduced_motion_stills_the_working_marks_test() {
  let css = stylesheet()
  assert string.contains(css, "@media (prefers-reduced-motion:reduce)")
  assert string.contains(css, "animation:none!important")
  assert string.contains(css, ".step.pending .glyph{")
  assert string.contains(css, ".busy-dot{")
  assert string.contains(css, ".running-time{")
}

// A page with the sidebar says Admin once: the bar's own button is not drawn, though
// it stays in the document for the switcher, and the bar's product name gives way to
// the sidebar's top line where the sidebar is a column.
pub fn the_bar_does_not_repeat_what_the_sidebar_says_test() {
  let css = stylesheet()
  assert string.contains(css, ".session-head .home-admin{display:none}")
  assert string.contains(
    css,
    "loom-shell[sidebar=listed] .session-head .brand{display:none}",
  )
}

// A recent place's cell does not shrink or wrap, and the names of its sessions
// take the room that is left and end in an ellipsis. With a long list of names the
// place used to wrap one word to a line ("exec · repo-wt" broken vertically).
pub fn a_recent_place_never_wraps_and_its_names_are_ellipsised_test() {
  let css = stylesheet()
  assert string.contains(css, ".recent-place{white-space:nowrap;flex:none;")
  assert string.contains(
    css,
    "text-overflow:ellipsis;white-space:nowrap;flex:1 1 0;",
  )
  assert string.contains(css, ".recent-hint{min-width:0;")
}

// The new-session composer's chips, form and send button carry their own
// `place-` names. The strand cards on the Strands tab draw `ul.chips` and
// `li.chip`, the operator's composer draws `form.composer` and `button.send`,
// and a bare `.chip{height:36px}` or `.send{border:0}` once reached all of them.
pub fn the_new_session_composer_does_not_use_the_names_other_views_use_test() {
  let css = stylesheet()
  assert string.contains(css, ".place-chip{")
  assert string.contains(css, ".place-chips{")
  assert string.contains(css, ".place-send{")
  assert string.contains(css, "form.place-composer{")
  assert !string.contains(css, ".chips{position:relative;display:flex")
  assert !string.contains(css, ".chip{display:inline-flex")
  assert !string.contains(css, ".chip{height:44px")
  assert !string.contains(css, ".send{display:inline-flex")
  assert !string.contains(css, "form.composer{display:flex")
}

// The relayed session page scrolls as a whole, so none of its children may
// shrink: the approvals section sets overflow, which gives it a minimum size of
// zero as a flex item, and a long transcript once squeezed it to no height.
pub fn the_relayed_pane_does_not_shrink_its_children_test() {
  let css = stylesheet()
  assert string.contains(css, ".relayed-pane>*{flex-shrink:0}")
}
