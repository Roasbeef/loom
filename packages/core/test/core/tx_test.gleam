import core/json
import core/register
import core/tx
import gleam/option.{None, Some}

// The tx module is pure vocabulary; these tests pin the frozen shapes so a
// field rename or reorder breaks loudly.

pub fn tx_carries_writes_in_order_test() {
  let writes = [
    tx.SetRegister(
      ns: register.OpState,
      key: "op-1",
      value: register.value(json.Int(1)),
    ),
    tx.DeleteRegister(ns: register.PendingEntry, key: "e-1"),
  ]
  let transaction = tx.Tx(writes:, expected: [])
  assert transaction.writes == writes
  assert transaction.expected == []
}

pub fn seq_expectation_shapes_test() {
  let must_exist = tx.Expect(ns: register.OpState, key: "op-1", seq: Some(4))
  let must_not_exist = tx.Expect(ns: register.OpMeta, key: "op-2", seq: None)
  assert must_exist.seq == Some(4)
  assert must_not_exist.seq == None
}

pub fn commit_result_shape_test() {
  let result = tx.CommitResult(first_seq: 10, seqs: [10, 11, 13], ts: 99)
  assert result.first_seq == 10
  assert result.seqs == [10, 11, 13]
  assert result.ts == 99
}

pub fn commit_error_variants_test() {
  let failed = tx.Expect(ns: register.StrandState, key: "main", seq: Some(1))
  assert tx.StaleExpectation(failed:).failed == failed
  assert tx.Faulted(reason: "disk gone").reason == "disk gone"
}
