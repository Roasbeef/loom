//// The claim token's shape and the address rule every secret is held to.

import gleam/bit_array
import gleam/list
import gleam/string
import host/claim

// Deterministic entropy: `count` copies of one byte.
fn fixed(byte: Int) -> fn(Int) -> BitArray {
  fn(count) { list.repeat(<<byte>>, count) |> bit_array.concat }
}

pub fn minted_tokens_are_prefixed_lowercase_hex_test() {
  let token = claim.mint_token(fixed(0xab))
  assert token == "loomclaim_" <> string.repeat("ab", 32)
  assert claim.validate_token(token) == Ok(Nil)
  assert claim.is_claim_shaped(token)
  assert claim.is_hex_256(claim.digest(token))
  assert claim.digest(token) != string.drop_start(token, 10)
}

pub fn only_the_exact_token_shape_is_a_claim_test() {
  let hex = string.repeat("a", 64)
  assert claim.validate_token(hex) != Ok(Nil)
  assert claim.validate_token("loomclaim_" <> string.uppercase(hex)) != Ok(Nil)
  assert claim.validate_token("loomclaim_" <> string.repeat("a", 63)) != Ok(Nil)
  assert claim.validate_token(" loomclaim_" <> hex) != Ok(Nil)
  assert claim.validate_token("loomclaim_" <> hex <> "0") != Ok(Nil)
  assert !claim.is_claim_shaped(hex)
  assert claim.is_hex_256(hex)
  assert !claim.is_hex_256(string.uppercase(hex))
}

pub fn secrets_cross_cleartext_only_to_loopback_test() {
  assert claim.remote_address("wss://loom.example.com/v2/control") == Ok(Nil)
  assert claim.remote_address("ws://127.0.0.1:4000/v2/control") == Ok(Nil)
  assert claim.remote_address("ws://[::1]:4000/v2/control") == Ok(Nil)
  let assert Error(_) = claim.remote_address("ws://loom.example.com/v2/control")
  let assert Error(_) =
    claim.remote_address("wss://loom.example.com/v2/sessions/x/ws")
  let assert Error(_) =
    claim.remote_address("wss://user@loom.example.com/v2/control")
}

pub fn claim_endpoint_keeps_the_host_and_changes_only_the_path_test() {
  assert claim.endpoint("wss://loom.example.com:8443/v2/control")
    == Ok("wss://loom.example.com:8443/v2/claim")
  assert claim.endpoint("ws://127.0.0.1:4000/v2/control")
    == Ok("ws://127.0.0.1:4000/v2/claim")
  let assert Error(_) = claim.endpoint("ws://loom.example.com/v2/control")
}
