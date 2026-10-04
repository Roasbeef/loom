import core/ids
import executor/remote/admission
import executor/remote/identity
import gleam/int
import gleam/list
import gleam/result
import gleam/string

const session_text = "00000000-0000-7000-8000-000000000001"

const operation_text = "00000000-0000-7000-8000-000000000002"

fn scope(
  session_text: String,
  workspace_text: String,
  executor_text: String,
  session_epoch: Int,
  workspace_epoch: Int,
) -> identity.Scope {
  let assert Ok(session) = ids.parse_session_id(session_text)
    as "the fixture session is UUIDv7"
  let assert Ok(workspace) = identity.workspace_id(workspace_text)
    as "the fixture workspace is provisioned"
  let assert Ok(executor) = identity.executor_id(executor_text)
    as "the fixture executor is provisioned"
  let assert Ok(session_epoch) = identity.epoch(session_epoch)
    as "the fixture session epoch is positive"
  let assert Ok(workspace_epoch) = identity.epoch(workspace_epoch)
    as "the fixture workspace epoch is positive"
  identity.scope(session, workspace, executor, session_epoch, workspace_epoch)
}

fn binding() -> identity.Scope {
  scope(session_text, "loom", "dev", 2, 2)
}

fn key(scope: identity.Scope, number: Int) -> identity.RequestKey {
  let assert Ok(operation) = ids.parse_op_id(operation_text)
    as "the fixture operation is UUIDv7"
  let text =
    "00000000-0000-7000-8000-"
    <> string.pad_start(int.to_string(number), 12, "0")
  let assert Ok(request) = identity.request_id(text)
    as "the fixture request is UUIDv7"
  identity.request_key(scope, operation, request)
}

fn digest(number: Int) -> identity.Digest {
  let assert Ok(value) = identity.digest(<<number:size(256)>>)
    as "the fixture digest is exactly 32 bytes"
  value
}

fn empty(capacity: Int) -> admission.Book {
  let assert Ok(capacity) = admission.capacity(capacity)
    as "the fixture capacity is bounded"
  admission.new(binding(), capacity)
}

fn accepted(capacity: Int) -> admission.Book {
  let assert Ok(accepted) =
    admission.admit(empty(capacity), key(binding(), 1), digest(1))
    as "the fixture admits one key"
  accepted.next
}

fn step(book: admission.Book, event: admission.Event) -> admission.Transition {
  let assert Ok(changed) =
    admission.reduce(book, key(binding(), 1), digest(1), event)
    as "the fixture transition is valid"
  changed
}

pub fn admission_reserves_capacity_and_returns_exact_duplicate_evidence_test() {
  let request = key(binding(), 1)
  let assert Ok(first) = admission.admit(empty(1), request, digest(1))
    as "first admission reserves the slot"
  assert first.effect == admission.NoLaunch
  assert admission.phase(first.evidence) == admission.Admitted
  assert admission.retained_count(first.next) == 1

  let assert Ok(duplicate) = admission.admit(first.next, request, digest(1))
    as "duplicate admission recovers the same record"
  assert duplicate == first
  assert admission.admit(first.next, request, digest(2))
    == Error(admission.RequestConflict)
  assert admission.admit(first.next, key(binding(), 2), digest(1))
    == Error(admission.Saturated)
  assert admission.inspect(first.next, request, digest(2))
    == Error(admission.RequestConflict)
}

pub fn scope_and_both_epochs_are_checked_before_any_lookup_test() {
  let book = accepted(1)
  let wrong_scopes = [
    scope("00000000-0000-7000-8000-000000000099", "loom", "dev", 2, 2),
    scope(session_text, "other", "dev", 2, 2),
    scope(session_text, "loom", "other", 2, 2),
    scope(session_text, "loom", "dev", 1, 2),
    scope(session_text, "loom", "dev", 2, 1),
    scope(session_text, "loom", "dev", 3, 2),
    scope(session_text, "loom", "dev", 2, 3),
  ]
  list.each(wrong_scopes, fn(scope) {
    let request = key(scope, 1)
    assert admission.admit(book, request, digest(1))
      == Error(admission.ScopeMismatch)
    assert admission.inspect(book, request, digest(1))
      == Error(admission.ScopeMismatch)
    assert admission.reduce(book, request, digest(1), admission.AuthorizeLaunch)
      == Error(admission.ScopeMismatch)
  })
}

pub fn operations_are_part_of_the_stable_key_test() {
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000099")
    as "another valid operation"
  let assert Ok(request) =
    identity.request_id("00000000-0000-7000-8000-000000000001")
    as "the same request UUID"
  let other = identity.request_key(binding(), operation, request)
  assert admission.admit(accepted(1), other, digest(1))
    == Error(admission.Saturated)
}

pub fn persisted_launch_intent_recovery_never_authorizes_second_launch_test() {
  let request = key(binding(), 1)
  let first = step(accepted(1), admission.AuthorizeLaunch)
  assert first.effect == admission.Launch(request)
  assert admission.phase(first.evidence)
    == admission.LaunchIntent(admission.NativeUnconfirmed)

  // Restoring the complete committed pure value models adapter recovery.
  // The old returned effect is not replayed; a retry reduces the restored book.
  let restored = first.next
  let retried = step(restored, admission.AuthorizeLaunch)
  assert retried.effect == admission.NoLaunch
  assert retried.next == restored
  let assert Ok(duplicate) = admission.admit(restored, request, digest(1))
    as "lost admission acknowledgement is recovered"
  assert duplicate.evidence == first.evidence
  assert duplicate.effect == admission.NoLaunch
  assert admission.reduce(
      restored,
      request,
      digest(2),
      admission.AuthorizeLaunch,
    )
    == Error(admission.RequestConflict)
}

pub fn terminal_and_receipt_without_native_retirement_are_not_forgettable_test() {
  let launched = step(accepted(1), admission.AuthorizeLaunch)
  let terminal = step(launched.next, admission.ObserveTerminal(digest(9)))
  let received = step(terminal.next, admission.ConfirmOwnerReceipt(digest(9)))
  assert admission.phase(received.evidence)
    == admission.Terminal(
      digest(9),
      admission.NativeUnconfirmed,
      admission.ReceiptDurable,
    )
  assert admission.reduce(
      received.next,
      key(binding(), 1),
      digest(1),
      admission.Compact,
    )
    == Error(admission.NotForgettable)

  // A disconnected owner supplies no retirement event; inspection cannot
  // replace native evidence with a successful terminal result or receipt.
  assert admission.inspect(received.next, key(binding(), 1), digest(1))
    == Ok(received.evidence)
}

pub fn native_retirement_without_owner_durable_receipt_is_not_forgettable_test() {
  let launched = step(accepted(1), admission.AuthorizeLaunch)
  let retired = step(launched.next, admission.ConfirmRetirement)
  assert admission.phase(retired.evidence)
    == admission.LaunchIntent(admission.NativeRetired)
  assert admission.reduce(
      retired.next,
      key(binding(), 1),
      digest(1),
      admission.Compact,
    )
    == Error(admission.NotForgettable)

  let terminal = step(retired.next, admission.ObserveTerminal(digest(9)))
  assert admission.phase(terminal.evidence)
    == admission.Terminal(
      digest(9),
      admission.NativeRetired,
      admission.ReceiptPending,
    )
  assert admission.reduce(
      terminal.next,
      key(binding(), 1),
      digest(1),
      admission.Compact,
    )
    == Error(admission.NotForgettable)
}

pub fn compacted_ids_remain_fenced_and_do_not_free_capacity_test() {
  let launched = step(accepted(1), admission.AuthorizeLaunch)
  let terminal = step(launched.next, admission.ObserveTerminal(digest(9)))
  let received = step(terminal.next, admission.ConfirmOwnerReceipt(digest(9)))
  let retired = step(received.next, admission.ConfirmRetirement)
  let compacted = step(retired.next, admission.Compact)
  assert admission.phase(compacted.evidence) == admission.Retired(digest(9))
  assert admission.retained_count(compacted.next) == 1
  assert step(compacted.next, admission.AuthorizeLaunch).effect
    == admission.NoLaunch
  assert step(compacted.next, admission.Compact) == compacted

  let assert Ok(retry) =
    admission.admit(compacted.next, key(binding(), 1), digest(1))
    as "the old ID is still admitted, never new"
  assert retry.evidence == compacted.evidence
  assert retry.effect == admission.NoLaunch
  assert admission.admit(compacted.next, key(binding(), 2), digest(1))
    == Error(admission.Saturated)
  assert admission.admit(compacted.next, key(binding(), 1), digest(2))
    == Error(admission.RequestConflict)
}

pub fn closed_epoch_rejects_delayed_new_keys_but_recovers_old_evidence_test() {
  let launched = step(accepted(2), admission.AuthorizeLaunch)
  let closed = admission.close(launched.next)
  assert admission.close(closed) == closed
  assert admission.admit(closed, key(binding(), 2), digest(1))
    == Error(admission.EpochClosed)
  let assert Ok(retry) = admission.admit(closed, key(binding(), 1), digest(1))
    as "closure preserves duplicate admission inspection"
  assert retry.evidence == launched.evidence
  assert step(closed, admission.AuthorizeLaunch).effect == admission.NoLaunch

  // Already launched work may settle while the epoch drains.
  let terminal = step(closed, admission.ObserveTerminal(digest(9)))
  let received = step(terminal.next, admission.ConfirmOwnerReceipt(digest(9)))
  let retired = step(received.next, admission.ConfirmRetirement)
  let compacted = step(retired.next, admission.Compact)
  assert admission.phase(compacted.evidence) == admission.Retired(digest(9))
  assert admission.admit(compacted.next, key(binding(), 2), digest(1))
    == Error(admission.EpochClosed)
}

pub fn closing_an_unlaunched_admission_prevents_its_first_launch_test() {
  let book = admission.close(accepted(1))
  assert admission.reduce(
      book,
      key(binding(), 1),
      digest(1),
      admission.AuthorizeLaunch,
    )
    == Error(admission.EpochClosed)
  let assert Ok(retry) = admission.admit(book, key(binding(), 1), digest(1))
    as "an unlaunched closed admission remains inspectable"
  assert admission.phase(retry.evidence) == admission.Admitted
}

pub fn closed_before_launch_refusal_settles_with_receipt_and_retained_fence_test() {
  let book = admission.close(accepted(1))
  let refused = step(book, admission.RefuseBeforeLaunch(digest(9)))
  assert refused.effect == admission.NoLaunch
  assert admission.phase(refused.evidence)
    == admission.Refused(digest(9), admission.ReceiptPending)
  assert step(refused.next, admission.ConfirmRetirement) == refused

  // Refusal proves native absence, but only the owner's committed receipt
  // completes settlement. Compaction preserves both the key and refusal origin.
  let received = step(refused.next, admission.ConfirmOwnerReceipt(digest(9)))
  let compacted = step(received.next, admission.Compact)
  assert admission.phase(compacted.evidence)
    == admission.RetiredRefusal(digest(9))
  assert compacted.effect == admission.NoLaunch
  assert admission.retained_count(compacted.next) == 1
  assert step(compacted.next, admission.AuthorizeLaunch).effect
    == admission.NoLaunch
  assert admission.admit(compacted.next, key(binding(), 2), digest(1))
    == Error(admission.EpochClosed)
}

pub fn refusal_requires_the_exact_durable_owner_receipt_before_compact_test() {
  list.each([accepted(1), admission.close(accepted(1))], fn(book) {
    let refused = step(book, admission.RefuseBeforeLaunch(digest(9)))
    assert admission.reduce(
        refused.next,
        key(binding(), 1),
        digest(1),
        admission.Compact,
      )
      == Error(admission.NotForgettable)
    assert admission.reduce(
        refused.next,
        key(binding(), 1),
        digest(1),
        admission.ConfirmOwnerReceipt(digest(8)),
      )
      == Error(admission.ResultConflict)

    // Native absence is already proven. Repeating retirement cannot substitute
    // for a receipt, even if the epoch's launch gate is still open.
    let retired = step(refused.next, admission.ConfirmRetirement)
    assert retired == refused
    assert admission.reduce(
        retired.next,
        key(binding(), 1),
        digest(1),
        admission.Compact,
      )
      == Error(admission.NotForgettable)
    let received = step(retired.next, admission.ConfirmOwnerReceipt(digest(9)))
    assert admission.phase(received.evidence)
      == admission.Refused(digest(9), admission.ReceiptDurable)
    assert admission.phase(step(received.next, admission.Compact).evidence)
      == admission.RetiredRefusal(digest(9))
  })
}

pub fn refusal_retries_preserve_compatible_evidence_after_compaction_test() {
  let refused = step(accepted(1), admission.RefuseBeforeLaunch(digest(9)))
  let received = step(refused.next, admission.ConfirmOwnerReceipt(digest(9)))
  let compacted = step(received.next, admission.Compact)
  list.each([refused, received, compacted], fn(before) {
    assert step(before.next, admission.RefuseBeforeLaunch(digest(9))) == before
    assert step(before.next, admission.ConfirmRetirement) == before
    assert step(before.next, admission.AuthorizeLaunch).effect
      == admission.NoLaunch
    assert admission.reduce(
        before.next,
        key(binding(), 1),
        digest(1),
        admission.RefuseBeforeLaunch(digest(8)),
      )
      == Error(admission.ResultConflict)
    assert admission.reduce(
        before.next,
        key(binding(), 1),
        digest(1),
        admission.ConfirmOwnerReceipt(digest(8)),
      )
      == Error(admission.ResultConflict)

    // ObserveTerminal describes launched work. A matching digest does not make
    // that observation compatible with a definite refusal's persisted origin.
    assert admission.reduce(
        before.next,
        key(binding(), 1),
        digest(1),
        admission.ObserveTerminal(digest(9)),
      )
      == Error(admission.NotLaunched)
  })
  assert step(received.next, admission.ConfirmOwnerReceipt(digest(9)))
    == received
  assert step(compacted.next, admission.ConfirmOwnerReceipt(digest(9)))
    == compacted
  assert step(compacted.next, admission.Compact) == compacted
  assert admission.admit(compacted.next, key(binding(), 2), digest(1))
    == Error(admission.Saturated)
}

pub fn refusal_is_rejected_after_launch_intent_test() {
  let launched = step(accepted(1), admission.AuthorizeLaunch)
  assert admission.reduce(
      launched.next,
      key(binding(), 1),
      digest(1),
      admission.RefuseBeforeLaunch(digest(9)),
    )
    == Error(admission.LaunchAlreadyAuthorized)
}

pub fn refusal_is_rejected_after_recovering_launch_intent_test() {
  let launched = step(accepted(1), admission.AuthorizeLaunch)

  // Recovery loads the persisted intent without replaying its launch effect.
  // Closing that restored epoch cannot prove the native launch never happened.
  let restored = admission.close(launched.next)
  assert admission.reduce(
      restored,
      key(binding(), 1),
      digest(1),
      admission.RefuseBeforeLaunch(digest(9)),
    )
    == Error(admission.LaunchAlreadyAuthorized)
  assert step(restored, admission.AuthorizeLaunch).effect == admission.NoLaunch
  let assert Ok(evidence) =
    admission.inspect(restored, key(binding(), 1), digest(1))
    as "refusal rejection preserves recovered uncertain native custody"
  assert admission.phase(evidence)
    == admission.LaunchIntent(admission.NativeUnconfirmed)
}

pub fn launched_results_never_become_refusals_even_with_matching_digest_test() {
  let launched = step(accepted(1), admission.AuthorizeLaunch)
  let retired_intent = step(launched.next, admission.ConfirmRetirement)
  let terminal = step(launched.next, admission.ObserveTerminal(digest(9)))
  let received = step(terminal.next, admission.ConfirmOwnerReceipt(digest(9)))
  let retired = step(received.next, admission.ConfirmRetirement)
  let compacted = step(retired.next, admission.Compact)

  // Native retirement proves work is gone, not that it never ran. Retaining
  // origin after compaction prevents a matching result from claiming refusal.
  list.each(
    [retired_intent, terminal, received, retired, compacted],
    fn(before) {
      list.each([digest(9), digest(8)], fn(result_digest) {
        assert admission.reduce(
            before.next,
            key(binding(), 1),
            digest(1),
            admission.RefuseBeforeLaunch(result_digest),
          )
          == Error(admission.LaunchAlreadyAuthorized)
      })
    },
  )
}

pub fn refusal_checks_scope_request_digest_and_admission_before_settlement_test() {
  let book = accepted(1)
  let event = admission.RefuseBeforeLaunch(digest(9))
  let stale = scope(session_text, "loom", "dev", 1, 2)
  assert admission.reduce(book, key(stale, 1), digest(1), event)
    == Error(admission.ScopeMismatch)
  assert admission.reduce(book, key(binding(), 1), digest(2), event)
    == Error(admission.RequestConflict)
  assert admission.reduce(book, key(binding(), 2), digest(1), event)
    == Error(admission.UnknownRequest)
}

pub fn missing_and_unlaunched_records_refuse_lifecycle_claims_test() {
  assert admission.inspect(empty(1), key(binding(), 1), digest(1))
    == Error(admission.UnknownRequest)
  assert admission.reduce(
      empty(1),
      key(binding(), 1),
      digest(1),
      admission.AuthorizeLaunch,
    )
    == Error(admission.UnknownRequest)
  let book = accepted(1)
  assert admission.reduce(
      book,
      key(binding(), 1),
      digest(1),
      admission.ObserveTerminal(digest(9)),
    )
    == Error(admission.NotLaunched)
  assert admission.reduce(
      book,
      key(binding(), 1),
      digest(1),
      admission.ConfirmRetirement,
    )
    == Error(admission.NotLaunched)
  assert admission.reduce(
      book,
      key(binding(), 1),
      digest(1),
      admission.ConfirmOwnerReceipt(digest(9)),
    )
    == Error(admission.MissingTerminal)
  assert admission.reduce(book, key(binding(), 1), digest(1), admission.Compact)
    == Error(admission.NotForgettable)
}

pub fn terminal_and_receipt_retries_match_exact_result_even_after_compaction_test() {
  let launched = step(accepted(1), admission.AuthorizeLaunch)
  assert admission.reduce(
      launched.next,
      key(binding(), 1),
      digest(1),
      admission.ConfirmOwnerReceipt(digest(9)),
    )
    == Error(admission.MissingTerminal)
  let terminal = step(launched.next, admission.ObserveTerminal(digest(9)))
  let received = step(terminal.next, admission.ConfirmOwnerReceipt(digest(9)))
  let retired = step(received.next, admission.ConfirmRetirement)
  let compacted = step(retired.next, admission.Compact)

  list.each(
    [terminal.next, received.next, retired.next, compacted.next],
    fn(book) {
      let assert Ok(before) =
        admission.inspect(book, key(binding(), 1), digest(1))
        as "the same admitted key is retained"
      assert step(book, admission.ObserveTerminal(digest(9))).evidence == before
      assert admission.reduce(
          book,
          key(binding(), 1),
          digest(1),
          admission.ObserveTerminal(digest(8)),
        )
        == Error(admission.ResultConflict)
      assert admission.reduce(
          book,
          key(binding(), 1),
          digest(1),
          admission.ConfirmOwnerReceipt(digest(8)),
        )
        == Error(admission.ResultConflict)
      assert step(book, admission.AuthorizeLaunch).effect == admission.NoLaunch
    },
  )
  assert step(received.next, admission.ConfirmOwnerReceipt(digest(9)))
    == received
  assert step(retired.next, admission.ConfirmRetirement) == retired
}

pub fn capacity_is_positive_and_bounded_test() {
  assert admission.capacity(1) |> result.is_ok
  assert admission.capacity(65_536) |> result.is_ok
  list.each([-1, 0, 65_537], fn(value) {
    assert admission.capacity(value) == Error(admission.CapacityRange)
  })
}

// Enumerate every six-event sequence from one admission (8^6 leaves).
// Closure is included at every position, so delayed settlement and launch
// retries are checked across both open and closed authority states. Refusal
// must retain a history with no native launch authorization.
pub fn exhaustive_short_sequences_preserve_one_launch_and_retained_key_test() {
  explore(accepted(1), 0, 6)
}

fn explore(book: admission.Book, launches: Int, remaining: Int) -> Nil {
  let request = key(binding(), 1)
  let assert Ok(evidence) = admission.inspect(book, request, digest(1))
    as "no transition removes the admitted replay fence"
  assert admission.retained_count(book) == 1
  assert launches <= 1
  let assert Ok(duplicate) = admission.admit(book, request, digest(1))
    as "same-key queries always recover evidence"
  assert duplicate.evidence == evidence
  assert duplicate.effect == admission.NoLaunch

  // A refusal's native-absence proof must agree with the entire launch history.
  case admission.phase(evidence) {
    admission.Refused(_, _) | admission.RetiredRefusal(_) -> {
      assert launches == 0
    }
    admission.Admitted
    | admission.LaunchIntent(_)
    | admission.Terminal(_, _, _)
    | admission.Retired(_) -> Nil
  }

  case remaining {
    0 -> Nil
    _ -> {
      list.each(
        [
          admission.AuthorizeLaunch,
          admission.RefuseBeforeLaunch(digest(9)),
          admission.ObserveTerminal(digest(9)),
          admission.ConfirmRetirement,
          admission.ConfirmOwnerReceipt(digest(9)),
          admission.Compact,
          admission.ObserveTerminal(digest(8)),
        ],
        fn(event) {
          case admission.reduce(book, request, digest(1), event) {
            Error(_) -> explore(book, launches, remaining - 1)
            Ok(changed) -> {
              let launches = case changed.effect {
                admission.Launch(_) -> launches + 1
                admission.NoLaunch -> launches
              }
              assert launches <= 1
              explore(changed.next, launches, remaining - 1)
            }
          }
        },
      )
      explore(admission.close(book), launches, remaining - 1)
    }
  }
}
