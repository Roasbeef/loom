import core/clock
import core/ids
import gleam/list
import gleam/string
import support/generate

fn fresh(at ts: Int, seed seed: Int) -> ids.Generator {
  ids.generator(clock.fixed(at: ts), seed:)
}

// --- minting basics -----------------------------------------------------

pub fn mint_is_deterministic_test() {
  let #(first, _) = ids.mint_entry(fresh(at: 1000, seed: 7))
  let #(second, _) = ids.mint_entry(fresh(at: 1000, seed: 7))
  assert first == second
}

pub fn different_seeds_mint_different_ids_test() {
  let #(first, _) = ids.mint_entry(fresh(at: 1000, seed: 7))
  let #(second, _) = ids.mint_entry(fresh(at: 1000, seed: 8))
  assert first != second
}

pub fn successive_mints_differ_test() {
  let generator = fresh(at: 1000, seed: 7)
  let #(first, generator) = ids.mint_entry(generator)
  let #(second, _generator) = ids.mint_entry(generator)
  assert first != second
}

pub fn mint_uses_clock_time_test() {
  let #(id, _) = ids.mint_entry(fresh(at: 1_700_000_000_123, seed: 1))
  assert ids.entry_id_timestamp_ms(id) == 1_700_000_000_123
}

pub fn usage_and_op_ids_mint_test() {
  let generator = fresh(at: 55, seed: 3)
  let #(usage_id, generator) = ids.mint_usage(generator)
  let #(op_id, _generator) = ids.mint_op(generator)
  assert ids.usage_id_timestamp_ms(usage_id) == 55
  assert ids.op_id_timestamp_ms(op_id) == 55
}

pub fn text_form_shape_test() {
  let #(id, _) = ids.mint_entry(fresh(at: 1000, seed: 1))
  let text = ids.entry_id_to_string(id)
  assert string.length(text) == 36
  // Version nibble is 7, variant digit is one of 8, 9, a, b.
  assert string.slice(text, at_index: 14, length: 1) == "7"
  let variant = string.slice(text, at_index: 19, length: 1)
  assert variant == "8" || variant == "9" || variant == "a" || variant == "b"
  assert string.lowercase(text) == text
}

// --- ordering laws ------------------------------------------------------

pub fn lexicographic_order_follows_time_order_test() {
  // Strictly advancing clock: each id's text must sort strictly after the
  // previous one.
  let generator = ids.generator(clock.stepping(from: 1000, by: 1), seed: 5)
  let #(texts, _generator) =
    list.fold(generate.range(1, 100), from: #([], generator), with: fn(acc, _) {
      let #(texts, generator) = acc
      let #(id, generator) = ids.mint_entry(generator)
      #([ids.entry_id_to_string(id), ..texts], generator)
    })
  let texts = list.reverse(texts)
  assert texts == list.sort(texts, by: string.compare)
  assert list.length(list.unique(texts)) == 100
}

pub fn time_prefix_is_lexicographic_across_magnitudes_test() {
  let times = [0, 1, 255, 256, 65_535, 1_700_000_000_000, 0xFFFFFFFFFFFF]
  let texts =
    list.map(times, fn(ts) {
      let #(id, _) = ids.mint_entry(fresh(at: ts, seed: 9))
      ids.entry_id_to_string(id)
    })
  assert texts == list.sort(texts, by: string.compare)
}

// --- follower minting ---------------------------------------------------

pub fn follower_shares_time_prefix_test() {
  let generator = fresh(at: 1_699_999_999_999, seed: 4)
  let #(leader, generator) = ids.mint_entry(generator)
  let #(follower, _generator) = ids.mint_follower(generator, of: leader)
  assert ids.entry_id_timestamp_ms(follower)
    == ids.entry_id_timestamp_ms(leader)
  // The first 13 characters of the text form are the 48-bit time prefix.
  let leader_prefix = string.slice(ids.entry_id_to_string(leader), 0, 13)
  let follower_prefix = string.slice(ids.entry_id_to_string(follower), 0, 13)
  assert leader_prefix == follower_prefix
}

pub fn follower_ignores_current_clock_test() {
  // The follower inherits the leader's prefix even when the generator's
  // own clock has moved past midnight.
  let #(leader, _) = ids.mint_entry(fresh(at: 86_399_999, seed: 2))
  let later = fresh(at: 86_400_001, seed: 3)
  let #(follower, _) = ids.mint_follower(later, of: leader)
  assert ids.entry_id_timestamp_ms(follower) == 86_399_999
}

pub fn follower_has_fresh_random_tail_test() {
  let generator = fresh(at: 1000, seed: 4)
  let #(leader, generator) = ids.mint_entry(generator)
  let #(follower, generator) = ids.mint_follower(generator, of: leader)
  let #(second_follower, _generator) = ids.mint_follower(generator, of: leader)
  assert follower != leader
  assert follower != second_follower
}

// --- text roundtrips ----------------------------------------------------

pub fn parse_roundtrip_property_test() {
  let seed = generate.seed(11)
  let #(ids_list, _seed) = generate.list_of(seed, 200, generate.entry_id)
  list.each(ids_list, fn(id) {
    assert ids.parse_entry_id(ids.entry_id_to_string(id)) == Ok(id)
  })
}

pub fn usage_and_op_roundtrip_test() {
  let seed = generate.seed(12)
  let #(usage_ids, seed) = generate.list_of(seed, 50, generate.usage_id)
  let #(op_ids, _seed) = generate.list_of(seed, 50, generate.op_id)
  list.each(usage_ids, fn(id) {
    assert ids.parse_usage_id(ids.usage_id_to_string(id)) == Ok(id)
  })
  list.each(op_ids, fn(id) {
    assert ids.parse_op_id(ids.op_id_to_string(id)) == Ok(id)
  })
}

pub fn parse_accepts_uppercase_test() {
  let #(id, _) = ids.mint_entry(fresh(at: 1_700_000_000_000, seed: 6))
  let text = string.uppercase(ids.entry_id_to_string(id))
  assert ids.parse_entry_id(text) == Ok(id)
}

// A uuid group is accepted when it holds exactly as many hexadecimal
// digits as its place demands, and the check counts down through the group
// rather than measuring it — so the boundary is worth pinning from both
// sides rather than from the inside. Each group is tried at its width, one
// digit short of it and one digit past it, with the dashes left in place so
// that the group split still succeeds and it is the width that decides.
pub fn parse_group_width_is_exact_test() {
  let assert Ok(_at_the_bound) =
    ids.parse_entry_id("0195c8d1-4a2e-7b31-8000-000000000000")

  let below = [
    "0195c8d-4a2e-7b31-8000-000000000000",
    "0195c8d1-4a2-7b31-8000-000000000000",
    "0195c8d1-4a2e-7b3-8000-000000000000",
    "0195c8d1-4a2e-7b31-800-000000000000",
    "0195c8d1-4a2e-7b31-8000-00000000000",
  ]
  let above = [
    "0195c8d12-4a2e-7b31-8000-000000000000",
    "0195c8d1-4a2e0-7b31-8000-000000000000",
    "0195c8d1-4a2e-7b312-8000-000000000000",
    "0195c8d1-4a2e-7b31-80000-000000000000",
    "0195c8d1-4a2e-7b31-8000-0000000000000",
  ]
  list.each(list.append(below, above), fn(text) {
    let assert Error(_report) = ids.parse_entry_id(text)
  })
}

pub fn parse_rejects_invalid_test() {
  let invalid = [
    "",
    "not-a-uuid",
    // valid shape, version 4 instead of 7
    "0195c8d1-4a2e-4b31-8000-000000000000",
    // valid shape, wrong variant (version nibble ok)
    "0195c8d1-4a2e-7b31-0000-000000000000",
    // non-hex character
    "0195c8d1-4a2e-7b31-8000-00000000000g",
    // wrong group lengths
    "0195c8d-14a2e-7b31-8000-000000000000",
    "0195c8d1-4a2e-7b31-8000-0000000000000",
    // missing and extra groups
    "0195c8d14a2e7b318000000000000000",
    "0195c8d1-4a2e-7b31-8000-0000-00000000",
    // whitespace and sign sneaking past a naive hex parse
    " 195c8d1-4a2e-7b31-8000-000000000000",
    "-195c8d1-4a2e-7b31-8000-000000000000",
    "0195c8d1-4a2e-7b31-8000-00000000000 ",
  ]
  list.each(invalid, fn(text) {
    let assert Error(_report) = ids.parse_entry_id(text)
    let assert Error(_report) = ids.parse_usage_id(text)
    let assert Error(_report) = ids.parse_op_id(text)
  })
}
