import core/generation as g
import core/ids
import core/msgpack as mp
import core/workspace
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result

pub fn range_and_all_scope_coordinates_are_retained_test() {
  let original_scope = scope("dev", 1, 2)
  let descriptor = digest(1)
  list.each([0, -1, 2_147_483_648], fn(number) {
    assert g.key(original_scope, descriptor, number) == Error(g.GenerationRange)
  })
  let assert Ok(key) = g.key(original_scope, descriptor, 2_147_483_647)
    as "maximum generation"
  let assert Ok(bytes) = g.encode_key(key) as "canonical key"
  assert g.decode_key(bytes) == Ok(key)
  assert g.key_fields(key) == #(original_scope, descriptor, 2_147_483_647)
  list.each(
    [scope("other", 1, 2), scope("dev", 2, 2), scope("dev", 1, 3)],
    fn(changed) {
      let assert Ok(other) = g.key(changed, descriptor, 2_147_483_647)
        as "changed scope"
      assert key != other
    },
  )
}

pub fn closed_lineage_requires_both_original_predecessor_digests_test() {
  let first = associated(1, g.FirstGeneration)
  let node = digest(4)
  let owner = digest(5)
  let same_owner = associated(2, g.Successor(node, owner))
  let next = with_owner(same_owner, "00000000-0000-7000-8000-000000000002")
  assert g.checked_successor(same_owner, first, node, owner)
    == Error(g.LineageMismatch)
  assert g.checked_first(first, 1) == Ok(Nil)
  assert g.checked_first(first, 2) == Error(g.LineageMismatch)
  assert g.checked_first(next, 2) == Error(g.LineageMismatch)
  assert g.checked_successor(next, first, node, owner) == Ok(Nil)
  assert g.checked_successor(next, first, owner, node)
    == Error(g.LineageMismatch)
  assert g.checked_successor(
      associated(3, g.Successor(node, owner)),
      first,
      node,
      owner,
    )
    == Error(g.LineageMismatch)
  let max = associated(2_147_483_647, g.FirstGeneration)
  assert g.checked_successor(first, max, node, owner)
    == Error(g.LineageMismatch)
}

pub fn association_codec_roundtrips_and_rejects_changed_or_noncanonical_shapes_test() {
  let original = associated(2, g.Successor(digest(4), digest(5)))
  let assert Ok(bytes) = g.encode_association(original)
    as "canonical association"
  assert g.decode_association(bytes) == Ok(original)
  assert g.decode_association_value(g.association_value(original))
    == Ok(original)
  assert g.decode_association(<<bytes:bits, 0>>) |> result.is_error
  assert g.decode_association(<<0:size(8200)>>) |> result.is_error
  assert g.decode_association(<<0:size(1)>>) |> result.is_error
  assert g.decode_association_value(mp.ArrayValue([mp.IntValue(1)]))
    |> result.is_error

  // A wider array header is syntactically valid MessagePack but not canonical.
  let assert <<0x96, rest:bits>> = bytes as "fixed six-element association"
  assert g.decode_association(<<0xdc, 0, 6, rest:bits>>) |> result.is_error
  int.range(0, bit_array.byte_size(bytes) - 1, with: Nil, run: fn(_, size) {
    let assert Ok(truncated) = bit_array.slice(bytes, 0, size)
      as "byte-aligned prefix"
    assert g.decode_association(truncated) |> result.is_error
    Nil
  })
}

pub fn digest_width_and_owner_identity_remain_immutable_test() {
  assert g.digest(<<0:size(255)>>) == Error(g.DigestSize)
  assert g.digest(<<0:size(264)>>) == Error(g.DigestSize)
  let original = associated(1, g.FirstGeneration)
  let #(key, enrollment, _, predecessor) = g.association_fields(original)
  let assert Ok(owner) =
    ids.parse_entry_id("00000000-0000-7000-8000-000000000002")
    as "other owner use"
  assert g.association(key, enrollment, owner, predecessor) != original
  assert g.association(key, digest(9), owner, predecessor) != original
}

fn with_owner(
  value: g.GenerationAssociation,
  owner_text: String,
) -> g.GenerationAssociation {
  let #(key, enrollment, _, predecessor) = g.association_fields(value)
  let assert Ok(owner) = ids.parse_entry_id(owner_text) as "fresh owner use"
  g.association(key, enrollment, owner, predecessor)
}

fn digest(byte: Int) -> g.Digest {
  let assert Ok(value) = g.digest(<<byte:size(256)>>) as "fixed digest"
  value
}

fn scope(
  executor: String,
  session_epoch: Int,
  workspace_epoch: Int,
) -> workspace.Scope {
  let assert Ok(value) =
    workspace.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "loom",
      executor,
      session_epoch,
      workspace_epoch,
    )
    as "complete checked scope"
  value
}

fn associated(
  number: Int,
  predecessor: g.Predecessor,
) -> g.GenerationAssociation {
  let assert Ok(key) = g.key(scope("dev", 1, 2), digest(1), number)
    as "checked generation"
  let assert Ok(owner) =
    ids.parse_entry_id("00000000-0000-7000-8000-000000000001")
    as "owner use"
  g.association(key, digest(2), owner, predecessor)
}
