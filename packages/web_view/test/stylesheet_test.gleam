//// The built stylesheet, for the few rules whose absence or value is a
//// finding of the web UI critique and has no other test: the sidebar draws no
//// strand bars, an idle session is one quiet colour on the home and the
//// sidebar, and a saved row's buttons keep clear of its chevron.
////
//// The text asserted on is the Tailwind build's output, which `make
//// gen-client` writes and `make web_assets --check` keeps current, so a
//// change to the source rules reaches this file only through a rebuild.

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

// F140: a sidebar row reserves a column for the archive button and the button
// is a 24px square in it, so it never lies over the row's dot or activity word.
pub fn the_archive_button_has_a_column_of_its_own_test() {
  let css = stylesheet()
  assert string.contains(css, "padding-right:30px")
  assert string.contains(css, "width:24px;height:24px")
}

// F147: the column is reserved on every row, with a button or without, so the
// activity word is in one place down the list: no rule keys the padding to a
// row that holds the button, and the rows that are one button have it too.
pub fn every_row_reserves_the_archive_column_test() {
  let css = stylesheet()
  assert !string.contains(css, "li.session:has(>.session-archive)")
  assert string.contains(
    css,
    "li.session{padding-right:30px;position:relative}",
  )
  assert string.contains(
    css,
    "li.session:has(>.session-open){padding:0 30px 0 0}",
  )
}

// F143: a home row's buttons sit in three fixed columns, Rename first, so
// Rename is where it is on every row whichever buttons the row has.
pub fn a_rows_buttons_keep_their_columns_test() {
  let css = stylesheet()
  assert string.contains(css, "grid-template-columns:72px 72px 64px")
  assert string.contains(css, ".home-rename{grid-column:1}")
  assert string.contains(css, ".home-act{grid-column:2}")
  assert string.contains(css, ".home-act-delete{grid-column:3}")
}

// F155: a row that is not a button (the page's own, a saved row while another
// resume is out) reserves the 7px a button's own padding gives the rows that are
// buttons, so its activity word ends where theirs do: 30px of the column and 7px
// of the button's padding.
pub fn a_row_that_is_not_a_button_ends_where_the_others_do_test() {
  let css = stylesheet()
  assert string.contains(
    css,
    "li.session:not(:has(>.session-open)){padding-right:37px}",
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
