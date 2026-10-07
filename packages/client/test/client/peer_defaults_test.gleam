//// The `[peers]` table is strict, total and off by default (protocol-change/077).

import client/catalog
import client/peer_defaults
import client/peer_mail.{BusyOnly, MayWake, NoDefaultLinks, Policy, SameOwner}
import gleam/list

pub fn an_absent_table_links_nothing_and_never_wakes_test() {
  assert peer_defaults.parse("") == Ok(Policy(NoDefaultLinks, BusyOnly))
  assert peer_defaults.parse("[daemon]\nui = true\n")
    == Ok(Policy(NoDefaultLinks, BusyOnly))
}

pub fn a_table_naming_one_key_keeps_the_other_default_test() {
  assert peer_defaults.parse("[peers]\ndefault_links = \"same_owner\"\n")
    == Ok(Policy(SameOwner, BusyOnly))
  assert peer_defaults.parse("[peers]\ndefault_wake = \"may_wake\"\n")
    == Ok(Policy(NoDefaultLinks, MayWake))
  assert peer_defaults.parse("[peers]\n")
    == Ok(Policy(NoDefaultLinks, BusyOnly))
}

pub fn both_keys_are_read_test() {
  assert peer_defaults.parse(
      "[peers]\ndefault_links = \"same_owner\"\ndefault_wake = \"may_wake\"\n",
    )
    == Ok(Policy(SameOwner, MayWake))
  assert peer_defaults.parse(
      "[peers]\ndefault_links = \"off\"\ndefault_wake = \"busy_only\"\n",
    )
    == Ok(Policy(NoDefaultLinks, BusyOnly))
}

pub fn an_unknown_word_or_type_is_refused_by_name_test() {
  list.each(["\"always\"", "\"Same_Owner\"", "\"\"", "true", "1"], fn(value) {
    assert peer_defaults.parse("[peers]\ndefault_links = " <> value <> "\n")
      == Error("peers.default_links must be \"off\" or \"same_owner\"")
  })
  list.each(["\"wake\"", "\"MAY_WAKE\"", "false", "0"], fn(value) {
    assert peer_defaults.parse("[peers]\ndefault_wake = " <> value <> "\n")
      == Error("peers.default_wake must be \"busy_only\" or \"may_wake\"")
  })
}

pub fn an_unknown_key_or_a_non_table_is_refused_test() {
  assert peer_defaults.parse("[peers]\ndefault_link = \"same_owner\"\n")
    == Error("unknown key `default_link` in [peers]")
  assert peer_defaults.parse("peers = \"same_owner\"\n")
    == Error("peers must be a [peers] table")
}

pub fn the_catalogue_parser_refuses_what_the_policy_parser_refuses_test() {
  // The catalogue validates the table before it looks for any model, so a
  // typo is refused by every reader of the file and not only at startup.
  let text = "[peers]\ndefault_links = \"always\"\n"
  assert catalog.parse(text)
    == Error("peers.default_links must be \"off\" or \"same_owner\"")
  let text = "[peers]\ndefault_wake = \"always\"\n"
  assert catalog.parse(text)
    == Error("peers.default_wake must be \"busy_only\" or \"may_wake\"")
}
