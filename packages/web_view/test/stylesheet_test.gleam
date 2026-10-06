//// The built stylesheet, for the few rules whose absence or value is a
//// finding of the web UI critique and has no other test: the sidebar draws no
//// strand bars, an idle session is one quiet colour on the home and the
//// sidebar, and a saved row's buttons keep clear of its chevron.
////
//// The text asserted on is the Tailwind build's output, which `make
//// gen-client` writes and `make web_assets --check` keeps current, so a
//// change to the source rules reaches this file only through a rebuild.

import gleam/bit_array
import gleam/string
import web_view/page

@external(erlang, "stylesheet_ffi", "read")
fn read(path: String) -> Result(BitArray, Nil)

fn stylesheet() -> String {
  let assert Ok(path) = page.static_file(page.stylesheet_asset)
    as "the stylesheet is in priv"
  let assert Ok(bytes) = read(path) as "the stylesheet reads"
  let assert Ok(text) = bit_array.to_string(bytes) as "it is text"
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
