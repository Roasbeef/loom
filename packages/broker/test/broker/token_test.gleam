import broker/policy
import broker/token
import core/clock
import core/ids
import gleam/bit_array
import gleam/int
import gleam/list

// Deterministic "entropy" that returns `count` copies of one byte.
fn fixed_entropy(byte: Int) -> fn(Int) -> BitArray {
  fn(count) {
    list.repeat(<<byte>>, count)
    |> bit_array.concat
  }
}

fn two_ops() -> #(ids.OpId, ids.OpId) {
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 7)
  let #(first, generator) = ids.mint_op(generator)
  let #(second, _generator) = ids.mint_op(generator)
  #(first, second)
}

fn binding(
  op_id: ids.OpId,
  step_id: String,
  deadline_ms: Int,
) -> token.Binding {
  token.Binding(
    op_id:,
    step_id:,
    policy: policy.workspace_default("/work"),
    deadline_ms:,
  )
}

pub fn mint_and_check_roundtrip_test() {
  let #(op, _) = two_ops()
  let vault = token.new(entropy: token.production_entropy())
  let assert Ok(#(vault, minted)) = token.mint(vault, binding(op, "s1", 1000))
  assert bit_array.byte_size(token.to_bytes(minted)) == token.byte_count
  assert token.check(vault, token.to_bytes(minted), now: 500)
    == Ok(binding(op, "s1", 1000))
}

pub fn unknown_token_refused_test() {
  let vault = token.new(entropy: token.production_entropy())
  assert token.check(vault, <<1, 2, 3>>, now: 0) == Error(token.UnknownToken)
}

pub fn wrong_bytes_always_refused_test() {
  let #(op, _) = two_ops()
  let vault = token.new(entropy: fixed_entropy(0xaa))
  let assert Ok(#(vault, minted)) = token.mint(vault, binding(op, "s1", 1000))
  // Same length, one bit different anywhere: refused.
  let assert <<first, rest:bytes>> = token.to_bytes(minted)
  let flipped_first = { first + 1 } % 256
  let flipped = bit_array.concat([<<flipped_first>>, rest])
  assert token.check(vault, flipped, now: 0) == Error(token.UnknownToken)
  // Prefix of the real bytes: refused.
  let assert Ok(prefix) =
    bit_array.slice(from: token.to_bytes(minted), at: 0, take: 16)
  assert token.check(vault, prefix, now: 0) == Error(token.UnknownToken)
}

pub fn expired_token_refused_test() {
  let #(op, _) = two_ops()
  let vault = token.new(entropy: token.production_entropy())
  let assert Ok(#(vault, minted)) = token.mint(vault, binding(op, "s1", 1000))
  assert token.check(vault, token.to_bytes(minted), now: 1001)
    == Error(token.Expired(deadline_ms: 1000))
  // The deadline instant itself is still valid.
  let assert Ok(_) = token.check(vault, token.to_bytes(minted), now: 1000)
}

pub fn revoked_token_refused_test() {
  let #(op, _) = two_ops()
  let vault = token.new(entropy: token.production_entropy())
  let assert Ok(#(vault, minted)) = token.mint(vault, binding(op, "s1", 1000))
  let vault = token.revoke(vault, token.to_bytes(minted))
  assert token.check(vault, token.to_bytes(minted), now: 0)
    == Error(token.Revoked)
}

pub fn revoke_is_idempotent_test() {
  let #(op, _) = two_ops()
  let vault = token.new(entropy: token.production_entropy())
  let assert Ok(#(vault, minted)) = token.mint(vault, binding(op, "s1", 1000))
  let once = token.revoke(vault, token.to_bytes(minted))
  let twice = token.revoke(once, token.to_bytes(minted))
  assert once == twice
  // Revoking unknown bytes changes nothing.
  assert token.revoke(vault, <<9, 9, 9>>) == vault
}

pub fn revoked_wins_over_expired_test() {
  let #(op, _) = two_ops()
  let vault = token.new(entropy: token.production_entropy())
  let assert Ok(#(vault, minted)) = token.mint(vault, binding(op, "s1", 1000))
  let vault = token.revoke(vault, token.to_bytes(minted))
  assert token.check(vault, token.to_bytes(minted), now: 2000)
    == Error(token.Revoked)
}

pub fn check_for_wrong_binding_refused_test() {
  let #(op, other_op) = two_ops()
  let vault = token.new(entropy: token.production_entropy())
  let assert Ok(#(vault, minted)) = token.mint(vault, binding(op, "s1", 1000))
  let bytes = token.to_bytes(minted)
  // Right binding: accepted.
  let assert Ok(_) =
    token.check_for(vault, bytes, op_id: op, step_id: "s1", now: 0)
  // Wrong step: refused.
  assert token.check_for(vault, bytes, op_id: op, step_id: "s2", now: 0)
    == Error(token.WrongBinding)
  // Wrong op: refused.
  assert token.check_for(vault, bytes, op_id: other_op, step_id: "s1", now: 0)
    == Error(token.WrongBinding)
}

pub fn revoke_all_kills_every_op_token_test() {
  let #(op, other_op) = two_ops()
  let vault = token.new(entropy: token.production_entropy())
  let assert Ok(#(vault, first)) = token.mint(vault, binding(op, "s1", 1000))
  let assert Ok(#(vault, second)) = token.mint(vault, binding(op, "s2", 1000))
  let assert Ok(#(vault, other)) =
    token.mint(vault, binding(other_op, "s1", 1000))
  let vault = token.revoke_all(vault, op)
  assert token.check(vault, token.to_bytes(first), now: 0)
    == Error(token.Revoked)
  assert token.check(vault, token.to_bytes(second), now: 0)
    == Error(token.Revoked)
  // The other operation's token survives.
  let assert Ok(_) = token.check(vault, token.to_bytes(other), now: 0)
  // Idempotent.
  assert token.revoke_all(vault, op) == vault
}

pub fn entropy_failure_refused_test() {
  let #(op, _) = two_ops()
  let vault = token.new(entropy: fn(_count) { <<1, 2, 3>> })
  assert token.mint(vault, binding(op, "s1", 1000))
    == Error(token.EntropyFailure(got_bytes: 3))
}

pub fn duplicate_entropy_refused_test() {
  let #(op, _) = two_ops()
  let vault = token.new(entropy: fixed_entropy(0x42))
  let assert Ok(#(vault, _)) = token.mint(vault, binding(op, "s1", 1000))
  assert token.mint(vault, binding(op, "s2", 1000))
    == Error(token.DuplicateToken)
}

pub fn drop_expired_prunes_but_still_refuses_test() {
  let #(op, _) = two_ops()
  let vault = token.new(entropy: token.production_entropy())
  let assert Ok(#(vault, old)) = token.mint(vault, binding(op, "s1", 100))
  let assert Ok(#(vault, live)) = token.mint(vault, binding(op, "s2", 10_000))
  assert token.size(vault) == 2
  let vault = token.drop_expired(vault, now: 5000, grace_ms: 1000)
  assert token.size(vault) == 1
  // Dropped tokens refuse as unknown — refused either way.
  assert token.check(vault, token.to_bytes(old), now: 5000)
    == Error(token.UnknownToken)
  let assert Ok(_) = token.check(vault, token.to_bytes(live), now: 5000)
}

// Property-flavoured sweep: across many minted tokens, every wrong
// presentation is refused and every right one accepted before deadline.
pub fn many_tokens_property_test() {
  let #(op, _) = two_ops()
  let vault = token.new(entropy: token.production_entropy())
  let #(vault, tokens) =
    int.range(from: 1, to: 51, with: #(vault, []), run: fn(acc, index) {
      let #(vault, tokens) = acc
      let step = "step-" <> int.to_string(index)
      let assert Ok(#(vault, minted)) =
        token.mint(vault, binding(op, step, 1000))
      #(vault, [#(step, minted), ..tokens])
    })
  list.each(tokens, fn(pair) {
    let #(step, minted) = pair
    let assert Ok(checked) =
      token.check_for(
        vault,
        token.to_bytes(minted),
        op_id: op,
        step_id: step,
        now: 999,
      )
    assert checked.step_id == step
    // The same token under any other step's binding refuses.
    assert token.check_for(
        vault,
        token.to_bytes(minted),
        op_id: op,
        step_id: step <> "-x",
        now: 999,
      )
      == Error(token.WrongBinding)
    // And after the deadline it expires.
    assert token.check(vault, token.to_bytes(minted), now: 1001)
      == Error(token.Expired(deadline_ms: 1000))
  })
}
