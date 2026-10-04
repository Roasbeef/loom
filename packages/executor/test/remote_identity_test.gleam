import executor/remote/identity
import gleam/list
import gleam/result
import gleam/string

pub fn administrative_labels_are_bounded_ascii_and_case_sensitive_test() {
  list.each(["a", "Dev_1.test-2", string.repeat("x", 128)], fn(label) {
    assert identity.executor_id(label) |> result.is_ok
    assert identity.workspace_id(label) |> result.is_ok
  })
  list.each(["", string.repeat("x", 129)], fn(label) {
    assert identity.executor_id(label) == Error(identity.LabelSize)
    assert identity.workspace_id(label) == Error(identity.LabelSize)
  })

  list.each(["a/b", "a b", "é", "a\n", "a\u{0}", "host:1"], fn(label) {
    assert identity.executor_id(label) == Error(identity.LabelCharacter)
    assert identity.workspace_id(label) == Error(identity.LabelCharacter)
  })
  assert identity.executor_id("Dev") != identity.executor_id("dev")
}

pub fn request_ids_use_total_core_uuidv7_validation_test() {
  let lowercase = "00000000-0000-7abc-8def-000000000001"
  let uppercase = "00000000-0000-7ABC-8DEF-000000000001"
  assert identity.request_id(lowercase) |> result.is_ok
  assert identity.request_id(lowercase) == identity.request_id(uppercase)

  list.each(
    [
      "",
      string.repeat("a", 10_000),
      "00000000-0000-6abc-8def-000000000001",
      "00000000-0000-7abc-0def-000000000001",
      "00000000-0000-7abc-8def-00000000000g",
    ],
    fn(text) {
      assert identity.request_id(text) == Error(identity.InvalidRequestId)
    },
  )
}

pub fn epochs_are_positive_bounded_values_test() {
  assert identity.epoch(1) |> result.is_ok
  assert identity.epoch(2_147_483_647) |> result.is_ok
  list.each([-1, 0, 2_147_483_648], fn(value) {
    assert identity.epoch(value) == Error(identity.EpochRange)
  })
}

pub fn digests_require_exactly_256_bits_and_compare_exactly_test() {
  assert identity.digest(<<0:size(256)>>) |> result.is_ok
  assert identity.digest(<<1:size(256)>>) != identity.digest(<<0:size(256)>>)
  list.each(
    [<<>>, <<0:size(248)>>, <<0:size(255)>>, <<0:size(257)>>],
    fn(bytes) {
      assert identity.digest(bytes) == Error(identity.DigestSize)
    },
  )
}
