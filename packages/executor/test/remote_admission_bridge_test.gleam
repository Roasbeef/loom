//// Differential observations of the production remote admission reducer.
////
//// Every fixture is a real opaque Book constructed by public APIs. The local
//// Lean runner compares these observations with its proved finite step function.
//// Phase, event, custody, receipt, effect and error projections use exhaustive
//// constructor matches so a vocabulary change requires maintaining this bridge.
//// The fixture digest values represent equality classes, not arbitrary bytes.

import core/ids
import executor/remote/admission
import executor/remote/identity
import gleam/io
import gleam/list
import gleam/string

type GateChoice {
  OpenGate
  ClosedGate
}

type RequestChoice {
  SameRequest
  ConflictingRequest
}

/// Prints computed TSV rows for the model-local differential runner.
///
/// ## Examples
///
/// Run `gleam run -m remote_admission_bridge_test` inside packages/executor.
pub fn main() -> Nil {
  list.each(rows(), io.println)
}

/// Requires every reachable class to have a public-API fixture.
///
/// ## Examples
///
/// The repository test runner discovers this function alongside existing tests.
pub fn reachable_classes_are_unique_and_complete_test() -> Nil {
  let books = reachable_books()
  let names = list.map(books, phase_of_book)
  assert list.length(names) == 19
  assert list.length(list.unique(names)) == 19
  assert list.length(rows()) == 684
}

fn rows() -> List(String) {
  use gate <- list.flat_map([OpenGate, ClosedGate])
  use open_book <- list.flat_map(reachable_books())
  let book = case gate {
    OpenGate -> open_book
    ClosedGate -> admission.close(open_book)
  }
  use request <- list.flat_map([SameRequest, ConflictingRequest])
  use event <- list.map(events())
  let supplied = case request {
    SameRequest -> digest(1)
    ConflictingRequest -> digest(2)
  }
  let outcome = admission.reduce(book, key(), supplied, event)

  // Duplicate admission must preserve every class and cannot emit an effect.
  let assert Ok(duplicate) = admission.admit(book, key(), digest(1))
    as "same-key admission remains available in every retained phase"
  assert duplicate.next == book
  assert duplicate.effect == admission.NoLaunch
  assert admission.inspect(book, key(), digest(1)) == Ok(duplicate.evidence)
  assert gate_of_book(book) == gate
  string.join(
    [
      "BRIDGE",
      gate_text(gate),
      phase_of_book(book),
      request_text(request),
      event_text(event),
      outcome_text(outcome),
    ],
    "\t",
  )
}

fn reachable_books() -> List(admission.Book) {
  let assert Ok(capacity) = admission.capacity(1)
    as "the fixture reserves one retained key"
  let assert Ok(accepted) =
    admission.admit(admission.new(scope(), capacity), key(), digest(1))
    as "the initial fixture is admitted through the production API"
  let a = accepted.next
  let i0 = apply(a, admission.AuthorizeLaunch)
  let i1 = apply(i0, admission.ConfirmRetirement)

  // Both fixed digests are reached independently, never injected as evidence.
  let settled =
    list.flat_map([digest(9), digest(8)], fn(d) {
      let fp = apply(a, admission.RefuseBeforeLaunch(d))
      let fd = apply(fp, admission.ConfirmOwnerReceipt(d))
      let x = apply(fd, admission.Compact)
      let t0p = apply(i0, admission.ObserveTerminal(d))
      let t0d = apply(t0p, admission.ConfirmOwnerReceipt(d))
      let t1p = apply(i1, admission.ObserveTerminal(d))
      let t1d = apply(t1p, admission.ConfirmOwnerReceipt(d))
      let r = apply(t1d, admission.Compact)
      [fp, fd, x, t0p, t0d, t1p, t1d, r]
    })
  [a, i0, i1, ..settled]
}

fn apply(book: admission.Book, event: admission.Event) -> admission.Book {
  let assert Ok(changed) = admission.reduce(book, key(), digest(1), event)
    as "the reachability witness uses a successful production transition"
  changed.next
}

fn events() -> List(admission.Event) {
  [
    admission.AuthorizeLaunch,
    admission.RefuseBeforeLaunch(digest(9)),
    admission.RefuseBeforeLaunch(digest(8)),
    admission.ObserveTerminal(digest(9)),
    admission.ObserveTerminal(digest(8)),
    admission.ConfirmRetirement,
    admission.ConfirmOwnerReceipt(digest(9)),
    admission.ConfirmOwnerReceipt(digest(8)),
    admission.Compact,
  ]
}

fn phase_of_book(book: admission.Book) -> String {
  let assert Ok(evidence) = admission.inspect(book, key(), digest(1))
    as "the real book retains its exact admitted row"
  assert admission.retained_count(book) == 1
  phase_text(admission.phase(evidence))
}

fn outcome_text(
  outcome: Result(admission.Transition, admission.AdmissionError),
) -> String {
  case outcome {
    Error(reason) -> "error:" <> error_text(reason)
    Ok(changed) -> {
      let p = phase_text(admission.phase(changed.evidence))
      assert phase_of_book(changed.next) == p
      let assert Ok(evidence) =
        admission.inspect(changed.next, key(), digest(1))
        as "the successor book stores the returned evidence"
      assert evidence == changed.evidence
      "ok:"
      <> p
      <> ":"
      <> effect_text(changed.effect)
      <> ":"
      <> gate_text(gate_of_book(changed.next))
    }
  }
}

// New-key admission distinguishes closure from an open full book without
// reading private Gate fields or mutating the observed book.
fn gate_of_book(book: admission.Book) -> GateChoice {
  let another = key_with_request("00000000-0000-7000-8000-000000000004")
  let assert Error(reason) = admission.admit(book, another, digest(1))
    as "a retained full book cannot admit another key"
  case reason {
    admission.EpochClosed -> ClosedGate
    admission.Saturated -> OpenGate
    admission.CapacityRange
    | admission.ScopeMismatch
    | admission.RequestConflict
    | admission.UnknownRequest
    | admission.NotLaunched
    | admission.LaunchAlreadyAuthorized
    | admission.ResultConflict
    | admission.MissingTerminal
    | admission.NotForgettable ->
      panic as "the full-book gate probe has a distinct refusal"
  }
}

fn phase_text(phase: admission.Phase) -> String {
  case phase {
    admission.Admitted -> "a"
    admission.LaunchIntent(c) -> "i" <> custody_text(c)
    admission.Refused(d, r) -> "f" <> result_text(d) <> receipt_text(r)
    admission.Terminal(d, c, r) ->
      "t" <> result_text(d) <> custody_text(c) <> receipt_text(r)
    admission.Retired(d) -> "r" <> result_text(d)
    admission.RetiredRefusal(d) -> "x" <> result_text(d)
  }
}

fn custody_text(custody: admission.NativeCustody) -> String {
  case custody {
    admission.NativeUnconfirmed -> "0"
    admission.NativeRetired -> "1"
  }
}

fn receipt_text(receipt: admission.OwnerReceipt) -> String {
  case receipt {
    admission.ReceiptPending -> "p"
    admission.ReceiptDurable -> "d"
  }
}

fn effect_text(effect: admission.Effect) -> String {
  case effect {
    admission.NoLaunch -> "no-launch"
    admission.Launch(request) -> {
      assert request == key()
      "launch"
    }
  }
}

fn event_text(event: admission.Event) -> String {
  case event {
    admission.AuthorizeLaunch -> "launch"
    admission.RefuseBeforeLaunch(d) -> "refuse-" <> result_text(d)
    admission.ObserveTerminal(d) -> "terminal-" <> result_text(d)
    admission.ConfirmRetirement -> "retirement"
    admission.ConfirmOwnerReceipt(d) -> "receipt-" <> result_text(d)
    admission.Compact -> "compact"
  }
}

fn error_text(error: admission.AdmissionError) -> String {
  case error {
    admission.CapacityRange -> "CapacityRange"
    admission.ScopeMismatch -> "ScopeMismatch"
    admission.RequestConflict -> "RequestConflict"
    admission.EpochClosed -> "EpochClosed"
    admission.Saturated -> "Saturated"
    admission.UnknownRequest -> "UnknownRequest"
    admission.NotLaunched -> "NotLaunched"
    admission.LaunchAlreadyAuthorized -> "LaunchAlreadyAuthorized"
    admission.ResultConflict -> "ResultConflict"
    admission.MissingTerminal -> "MissingTerminal"
    admission.NotForgettable -> "NotForgettable"
  }
}

fn result_text(digest_value: identity.Digest) -> String {
  case digest_value == digest(9), digest_value == digest(8) {
    True, False -> "a"
    False, True -> "b"
    True, True | False, False ->
      panic as "the fixture result must be one of two distinct digests"
  }
}

fn gate_text(gate: GateChoice) -> String {
  case gate {
    OpenGate -> "open"
    ClosedGate -> "closed"
  }
}

fn request_text(request: RequestChoice) -> String {
  case request {
    SameRequest -> "equal"
    ConflictingRequest -> "conflict"
  }
}

fn scope() -> identity.Scope {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "the fixture session is UUIDv7"
  let assert Ok(workspace) = identity.workspace_id("loom")
    as "the fixture workspace is provisioned"
  let assert Ok(executor) = identity.executor_id("dev")
    as "the fixture executor is provisioned"
  let assert Ok(epoch) = identity.epoch(1) as "the fixture epoch is positive"
  identity.scope(session, workspace, executor, epoch, epoch)
}

fn key() -> identity.RequestKey {
  key_with_request("00000000-0000-7000-8000-000000000003")
}

fn key_with_request(text: String) -> identity.RequestKey {
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "the fixture operation is UUIDv7"
  let assert Ok(request) = identity.request_id(text)
    as "the fixture request is UUIDv7"
  identity.request_key(scope(), operation, request)
}

fn digest(number: Int) -> identity.Digest {
  let assert Ok(value) = identity.digest(<<number:size(256)>>)
    as "the fixture digest is exactly 32 bytes"
  value
}
