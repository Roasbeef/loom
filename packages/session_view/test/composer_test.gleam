//// The collapsed words of a harness injection and of a large paste, and the
//// one function that takes the terminal's key hint off them for a host with
//// no such key.
////
//// `transcript_text` words a collapsed row with `Ctrl+G` because the
//// terminal is the host that has the key, and its words are the contract the
//// terminal's tests pin. `without_expand_hint` is what the page draws
//// instead.

import gleam/string
import session_view/composer

pub fn a_collapsed_injection_keeps_the_terminals_hint_test() {
  assert composer.transcript_text("[loom] rule \"r\"\n\nbody", False)
    == "[loom] rule \"r\"  [Ctrl+G to expand]"
}

pub fn the_hint_comes_off_a_collapsed_row_test() {
  assert composer.without_expand_hint("[loom] rule \"r\"  [Ctrl+G to expand]")
    == "[loom] rule \"r\""
  assert composer.without_expand_hint("advisor feed: user:  [Ctrl+G to expand]")
    == "advisor feed: user:"
}

pub fn a_pastes_token_count_stays_when_the_hint_goes_test() {
  let paste = string.repeat("word ", 4000)
  let collapsed = composer.transcript_text(paste, False)
  assert string.contains(collapsed, "Ctrl+G to expand")

  let shown = composer.without_expand_hint(collapsed)
  assert !string.contains(shown, "Ctrl+G")
  assert string.ends_with(shown, " tokens]")
}

pub fn text_with_no_hint_is_unchanged_test() {
  assert composer.without_expand_hint("ordinary turn") == "ordinary turn"
}
