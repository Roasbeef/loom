import core/ids
import executor/remote/admission
import executor/remote/identity
import executor/remote/journal
import executor/remote/journal_codec
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/time/timestamp
import simplifile
import sqlight
import weft

fn scope(epoch: Int) -> identity.Scope {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
  let assert Ok(workspace) = identity.workspace_id("loom")
  let assert Ok(executor) = identity.executor_id("dev")
  let assert Ok(epoch) = identity.epoch(epoch)
  identity.scope(session, workspace, executor, epoch, epoch)
}

fn key(number: Int) -> identity.RequestKey {
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000002")
  let assert Ok(request) =
    identity.request_id(
      "00000000-0000-7000-8000-"
      <> string.pad_start(int.to_string(number), 12, "0"),
    )
  identity.request_key(scope(1), operation, request)
}

fn digest(number: Int) -> identity.Digest {
  let assert Ok(value) = identity.digest(<<number:size(256)>>)
  value
}

fn capacity(number: Int) -> admission.Capacity {
  let assert Ok(value) = admission.capacity(number)
  value
}

fn fixture(name: String, run: fn(String, journal.Journal) -> Nil) -> Nil {
  let #(seconds, nanoseconds) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let directory =
    "/tmp/loom-journal-"
    <> name
    <> "-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanoseconds)
  let assert Ok(Nil) = simplifile.create_directory(directory)
  let path = directory <> "/custody.sqlite"
  let assert Ok(book) = journal.fresh(path, scope(1), capacity(2))
  run(path, book)
  let _ = journal.release(book)
  let assert Ok(Nil) = simplifile.delete(directory)
  Nil
}

fn reopen(path: String, book: journal.Journal) -> journal.Journal {
  assert journal.release(book) == Ok(Nil)
  let assert Ok(restored) = journal.recover(path, scope(1), capacity(2))
  restored
}

fn admit(book: journal.Journal, number: Int) -> journal.Decision {
  let assert Ok(decision) = journal.admit(book, key(number), digest(1))
  decision
}

fn step(book: journal.Journal, event: admission.Event) -> journal.Decision {
  let assert Ok(decision) = journal.apply(book, key(1), digest(1), event)
  decision
}

fn execute(path: String, sql: String) -> Nil {
  let assert Ok(connection) = sqlight.open(path)
  assert sqlight.exec(sql, connection) == Ok(Nil)
  assert sqlight.close(connection) == Ok(Nil)
}

fn counts(path: String) -> #(Int, Int) {
  let assert Ok(connection) = sqlight.open(path)
  let decoder = {
    use rows <- decode.field(0, decode.int)
    use bytes <- decode.field(1, decode.int)
    decode.success(#(rows, bytes))
  }
  let assert Ok([value]) =
    sqlight.query(
      "SELECT COUNT(*), COALESCE(SUM(length(payload)),0) FROM custody_event",
      connection,
      [],
      decoder,
    )
  assert sqlight.close(connection) == Ok(Nil)
  value
}

pub fn admitted_and_launch_intent_close_reopen_no_second_launch_test() {
  fixture("intent", fn(path, book) {
    let first = admit(book, 1)
    let book = reopen(path, book)
    assert journal.inspect(book, key(1), digest(1)) == Ok(first.evidence)
    let launched = step(book, admission.AuthorizeLaunch)
    assert launched.effect == admission.Launch(key(1))
    let book = reopen(path, book)
    assert step(book, admission.AuthorizeLaunch).effect == admission.NoLaunch
    assert admit(book, 1).evidence == launched.evidence
    assert counts(path) == #(2, 212)
    assert journal.apply(
        book,
        key(1),
        digest(1),
        admission.RefuseBeforeLaunch(digest(9)),
      )
      == Error(journal.Rejected(admission.LaunchAlreadyAuthorized))
    assert journal.release(book) == Ok(Nil)
  })
}

pub fn exact_duplicates_and_no_change_events_do_not_grow_journal_test() {
  fixture("duplicates", fn(path, book) {
    let first = admit(book, 1)
    list.each(list.repeat(Nil, 50), fn(_) {
      assert admit(book, 1) == first
    })
    assert counts(path) == #(1, 106)
    let launched = step(book, admission.AuthorizeLaunch)
    list.each(list.repeat(Nil, 50), fn(_) {
      assert step(book, admission.AuthorizeLaunch).evidence == launched.evidence
    })
    assert counts(path) == #(2, 212)
    let retired = step(book, admission.ConfirmRetirement)
    assert step(book, admission.ConfirmRetirement) == retired
    assert counts(path) == #(3, 318)
  })
}

pub fn terminal_receipt_and_native_retirement_are_independent_across_reopen_test() {
  fixture("terminal", fn(path, book) {
    let _ = admit(book, 1)
    let _ = step(book, admission.AuthorizeLaunch)
    let terminal = step(book, admission.ObserveTerminal(digest(9)))
    let book = reopen(path, book)
    assert journal.inspect(book, key(1), digest(1)) == Ok(terminal.evidence)
    let received = step(book, admission.ConfirmOwnerReceipt(digest(9)))
    let book = reopen(path, book)
    assert journal.inspect(book, key(1), digest(1)) == Ok(received.evidence)
    assert journal.apply(book, key(1), digest(1), admission.Compact)
      == Error(journal.Rejected(admission.NotForgettable))
    let _ = step(book, admission.ConfirmRetirement)
    let tombstone = step(book, admission.Compact)
    assert admission.phase(tombstone.evidence) == admission.Retired(digest(9))
    let book = reopen(path, book)
    assert admit(book, 1).evidence == tombstone.evidence
    assert step(book, admission.AuthorizeLaunch).effect == admission.NoLaunch
    assert journal.apply(
        book,
        key(1),
        digest(1),
        admission.ObserveTerminal(digest(8)),
      )
      == Error(journal.Rejected(admission.ResultConflict))
    assert journal.apply(
        book,
        key(1),
        digest(1),
        admission.RefuseBeforeLaunch(digest(9)),
      )
      == Error(journal.Rejected(admission.LaunchAlreadyAuthorized))
    assert counts(path).0 == 6
    assert journal.release(book) == Ok(Nil)
  })
}

pub fn retirement_before_result_requires_receipt_and_survives_reopen_test() {
  fixture("retirement", fn(path, book) {
    let _ = admit(book, 1)
    let _ = step(book, admission.AuthorizeLaunch)
    let _ = step(book, admission.ConfirmRetirement)
    let book = reopen(path, book)
    let terminal = step(book, admission.ObserveTerminal(digest(9)))
    assert admission.phase(terminal.evidence)
      == admission.Terminal(
        digest(9),
        admission.NativeRetired,
        admission.ReceiptPending,
      )
    assert journal.apply(book, key(1), digest(1), admission.Compact)
      == Error(journal.Rejected(admission.NotForgettable))
    let _ = step(book, admission.ConfirmOwnerReceipt(digest(9)))
    assert admission.phase(step(book, admission.Compact).evidence)
      == admission.Retired(digest(9))
    assert journal.release(book) == Ok(Nil)
  })
}

pub fn closed_epoch_and_refusal_origin_survive_recovery_and_compaction_test() {
  fixture("refusal", fn(path, book) {
    let _ = admit(book, 1)
    assert journal.close_epoch(book) == Ok(Nil)
    assert journal.close_epoch(book) == Ok(Nil)
    let book = reopen(path, book)
    assert journal.apply(book, key(1), digest(1), admission.AuthorizeLaunch)
      == Error(journal.Rejected(admission.EpochClosed))
    assert journal.admit(book, key(2), digest(1))
      == Error(journal.Rejected(admission.EpochClosed))
    let refusal = step(book, admission.RefuseBeforeLaunch(digest(9)))
    let book = reopen(path, book)
    assert journal.inspect(book, key(1), digest(1)) == Ok(refusal.evidence)
    assert journal.apply(book, key(1), digest(1), admission.Compact)
      == Error(journal.Rejected(admission.NotForgettable))
    assert journal.apply(
        book,
        key(1),
        digest(1),
        admission.ConfirmOwnerReceipt(digest(8)),
      )
      == Error(journal.Rejected(admission.ResultConflict))
    let _ = step(book, admission.ConfirmOwnerReceipt(digest(9)))
    let compacted = step(book, admission.Compact)
    let book = reopen(path, book)
    assert admission.phase(admit(book, 1).evidence)
      == admission.RetiredRefusal(digest(9))
    assert step(book, admission.RefuseBeforeLaunch(digest(9))) == compacted
    assert step(book, admission.AuthorizeLaunch).effect == admission.NoLaunch
    assert journal.apply(
        book,
        key(1),
        digest(1),
        admission.ObserveTerminal(digest(9)),
      )
      == Error(journal.Rejected(admission.NotLaunched))
    assert counts(path).0 == 5
    assert journal.release(book) == Ok(Nil)
  })
}

pub fn fresh_and_recovery_refuse_reset_and_exact_binding_mismatches_test() {
  fixture("binding", fn(path, book) {
    let first = admit(book, 1)
    assert journal.fresh(path, scope(1), capacity(2))
      == Error(journal.AlreadyExists)
    assert journal.recover(path <> ".absent", scope(1), capacity(2))
      == Error(journal.Missing)
    assert simplifile.exists(path <> ".absent", False) == Ok(False)
    assert journal.recover(path, scope(2), capacity(2))
      == Error(journal.BindingMismatch)
    assert journal.recover(path, scope(1), capacity(1))
      == Error(journal.BindingMismatch)
    assert journal.admit(book, key(1), digest(2))
      == Error(journal.Rejected(admission.RequestConflict))
    let #(operation_text, request_text) = identity.key_fields(key(1))
    let assert Ok(operation) = ids.parse_op_id(operation_text)
    let assert Ok(request) = identity.request_id(request_text)
    let other = identity.request_key(scope(2), operation, request)
    assert journal.admit(book, other, digest(1))
      == Error(journal.Rejected(admission.ScopeMismatch))
    assert journal.inspect(book, key(1), digest(1)) == Ok(first.evidence)
    assert counts(path).0 == 1
  })
}

pub fn two_opens_concurrent_admission_and_launch_grant_exactly_once_test() {
  fixture("writers", fn(path, first) {
    let assert Ok(second) = journal.recover(path, scope(1), capacity(2))
    let tasks =
      list.index_map(list.repeat(Nil, 20), fn(_, index) {
        let writer = case index % 2 {
          0 -> first
          _ -> second
        }
        fn() {
          use _ <- result.try(journal.admit(writer, key(1), digest(1)))
          journal.apply(writer, key(1), digest(1), admission.AuthorizeLaunch)
        }
      })
    let outcomes =
      tasks |> weft.new |> weft.limit(20) |> weft.deadline(10_000) |> weft.start
    let launches =
      list.map(outcomes, fn(outcome) {
        let assert weft.Completed(_, decision) = outcome
          as "every writer completes"
        case decision.effect {
          admission.Launch(_) -> 1
          admission.NoLaunch -> 0
        }
      })
    assert list.fold(launches, 0, fn(sum, count) { sum + count }) == 1
    assert counts(path) == #(2, 212)
    assert journal.inspect(first, key(1), digest(1))
      == journal.inspect(second, key(1), digest(1))
    assert journal.close_epoch(first) == Ok(Nil)
    assert journal.admit(second, key(2), digest(1))
      == Error(journal.Rejected(admission.EpochClosed))
    assert journal.release(second) == Ok(Nil)
  })
}

pub fn lifetime_capacity_keeps_tombstones_reserved_after_reopen_test() {
  fixture("capacity", fn(path, book) {
    let _ = admit(book, 1)
    let _ = step(book, admission.RefuseBeforeLaunch(digest(9)))
    let _ = step(book, admission.ConfirmOwnerReceipt(digest(9)))
    let _ = step(book, admission.Compact)
    let _ = admit(book, 2)
    let book = reopen(path, book)
    assert journal.admit(book, key(3), digest(1))
      == Error(journal.Rejected(admission.Saturated))
    assert step(book, admission.AuthorizeLaunch).effect == admission.NoLaunch
    assert counts(path).0 == 5
    assert journal.release(book) == Ok(Nil)
  })
}

pub fn malformed_unknown_oversized_and_truncated_records_fail_closed_test() {
  list.each(
    [
      "UPDATE custody_event SET payload=x'0102' WHERE seq=1",
      "UPDATE custody_event SET payload=x'0163' WHERE seq=1",
      "UPDATE custody_event SET payload=zeroblob(1000000) WHERE seq=1",
      "UPDATE custody_event SET payload='text' WHERE seq=1",
      "DELETE FROM custody_event WHERE seq=2",
      "DELETE FROM custody_event WHERE seq=1",
      "UPDATE custody_event SET seq=9 WHERE seq=2",
      "PRAGMA ignore_check_constraints=ON; UPDATE custody_meta SET version=99999999",
      "UPDATE custody_meta SET bytes=0",
      "PRAGMA ignore_check_constraints=ON; UPDATE custody_meta SET capacity=zeroblob(1000000)",
      "PRAGMA ignore_check_constraints=ON; UPDATE custody_meta SET version=zeroblob(1000000)",
      "PRAGMA ignore_check_constraints=ON; UPDATE custody_meta SET bytes=zeroblob(1000000)",
    ],
    fn(sql) {
      fixture("corruption", fn(path, book) {
        let _ = admit(book, 1)
        let _ = step(book, admission.AuthorizeLaunch)
        assert journal.release(book) == Ok(Nil)
        execute(path, sql)
        assert journal.recover(path, scope(1), capacity(2))
          == Error(journal.Corrupt)
      })
    },
  )
}

pub fn metadata_blobs_are_corrupt_even_when_schema_accepts_them_test() {
  fixture("metadata-affinity", fn(path, book) {
    assert journal.release(book) == Ok(Nil)

    // An empty ledger permits this value even with every CHECK enabled.
    // SQL projection guards refuse its type before returning the blob.
    execute(path, "UPDATE custody_meta SET capacity=zeroblob(1000000)")
    assert journal.recover(path, scope(1), capacity(2))
      == Error(journal.Corrupt)
  })
}

pub fn semantically_invalid_and_duplicate_durable_commands_fail_closed_test() {
  fixture("semantic", fn(path, book) {
    let _ = admit(book, 1)
    assert journal.release(book) == Ok(Nil)
    execute(
      path,
      "INSERT INTO custody_event SELECT 2,payload FROM custody_event WHERE seq=1; UPDATE custody_meta SET version=2,bytes=212",
    )
    assert journal.recover(path, scope(1), capacity(2))
      == Error(journal.Corrupt)
  })
  fixture("unknown-key", fn(path, book) {
    assert journal.release(book) == Ok(Nil)
    let payload =
      journal_codec.encode(journal_codec.Apply(
        key(1),
        digest(1),
        admission.AuthorizeLaunch,
      ))
    let assert Ok(connection) = sqlight.open(path)
    let assert Ok(_) =
      sqlight.query(
        "INSERT INTO custody_event VALUES (1,?)",
        connection,
        [sqlight.blob(payload)],
        decode.int,
      )
    assert sqlight.exec(
        "UPDATE custody_meta SET version=1,bytes=106",
        connection,
      )
      == Ok(Nil)
    assert sqlight.close(connection) == Ok(Nil)
    assert journal.recover(path, scope(1), capacity(2))
      == Error(journal.Corrupt)
  })
}

pub fn append_failure_poisoning_requires_recovery_and_never_grants_launch_test() {
  fixture("append-failure", fn(path, book) {
    let _ = admit(book, 1)
    execute(
      path,
      "CREATE TRIGGER reject_append BEFORE INSERT ON custody_event BEGIN SELECT RAISE(ABORT,'test'); END",
    )
    assert journal.apply(book, key(1), digest(1), admission.AuthorizeLaunch)
      == Error(journal.Uncertain)
    assert_unavailable(book)
    assert counts(path).0 == 1
    execute(path, "DROP TRIGGER reject_append")
    let assert Ok(restored) = journal.recover(path, scope(1), capacity(2))
    assert admission.phase(admit(restored, 1).evidence) == admission.Admitted
    assert step(restored, admission.AuthorizeLaunch).effect
      == admission.Launch(key(1))
    assert journal.release(restored) == Ok(Nil)
  })
}

pub fn commit_boundary_failure_poisoning_restores_only_committed_custody_test() {
  fixture("commit-failure", fn(path, book) {
    let _ = admit(book, 1)
    execute(
      path,
      "PRAGMA foreign_keys=ON; CREATE TABLE parent(id INTEGER PRIMARY KEY); CREATE TABLE child(id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fail_commit AFTER INSERT ON custody_event BEGIN INSERT INTO child VALUES(1); END",
    )
    assert journal.apply(book, key(1), digest(1), admission.AuthorizeLaunch)
      == Error(journal.Uncertain)
    assert_unavailable(book)
    assert counts(path).0 == 1
    execute(path, "DROP TRIGGER fail_commit")
    let assert Ok(restored) = journal.recover(path, scope(1), capacity(2))
    assert admission.phase(admit(restored, 1).evidence) == admission.Admitted
    assert step(restored, admission.AuthorizeLaunch).effect
      == admission.Launch(key(1))
    assert journal.release(restored) == Ok(Nil)
  })
}

pub fn memory_uri_and_relative_paths_cannot_acknowledge_durable_custody_test() {
  list.each(
    [
      ":memory:",
      "file:transient?mode=memory&cache=shared",
      "relative.sqlite",
      "/private/tmp/invalid\u{0}name",
    ],
    fn(path) {
      assert journal.fresh(path, scope(1), capacity(2))
        == Error(journal.InvalidPath)
      assert journal.recover(path, scope(1), capacity(2))
        == Error(journal.InvalidPath)
    },
  )
}

pub fn failed_head_update_rolls_back_appended_intent_and_poison_closes_test() {
  fixture("cas-failure", fn(path, book) {
    let _ = admit(book, 1)
    execute(
      path,
      "CREATE TRIGGER reject_head BEFORE UPDATE ON custody_meta BEGIN SELECT RAISE(IGNORE); END",
    )
    assert journal.apply(book, key(1), digest(1), admission.AuthorizeLaunch)
      == Error(journal.Uncertain)
    assert_unavailable(book)
    assert counts(path) == #(1, 106)
    execute(path, "DROP TRIGGER reject_head")
    let assert Ok(restored) = journal.recover(path, scope(1), capacity(2))
    assert admission.phase(admit(restored, 1).evidence) == admission.Admitted
    assert journal.release(restored) == Ok(Nil)
  })
}

pub fn codec_roundtrips_every_event_and_rejects_noncanonical_or_extra_bytes_test() {
  let commands = [
    journal_codec.CloseEpoch,
    journal_codec.Admit(key(1), digest(1)),
    journal_codec.Apply(key(1), digest(1), admission.AuthorizeLaunch),
    journal_codec.Apply(
      key(1),
      digest(1),
      admission.RefuseBeforeLaunch(digest(9)),
    ),
    journal_codec.Apply(key(1), digest(1), admission.ObserveTerminal(digest(9))),
    journal_codec.Apply(key(1), digest(1), admission.ConfirmRetirement),
    journal_codec.Apply(
      key(1),
      digest(1),
      admission.ConfirmOwnerReceipt(digest(9)),
    ),
    journal_codec.Apply(key(1), digest(1), admission.Compact),
  ]
  list.each(commands, fn(command) {
    let encoded = journal_codec.encode(command)
    assert journal_codec.decode(encoded, scope(1)) == Ok(command)
    assert journal_codec.decode(<<encoded:bits, 0>>, scope(1)) == Error(Nil)
  })
  list.each([<<>>, <<1>>, <<2, 0>>, <<1, 8>>, <<0, 0>>], fn(bytes) {
    assert journal_codec.decode(bytes, scope(1)) == Error(Nil)
  })
  let operation = "00000000-0000-7ABC-8DEF-000000000002"
  let request = "00000000-0000-7000-8000-000000000001"
  assert journal_codec.decode(
      <<1, 1, operation:utf8, request:utf8, 0:size(256)>>,
      scope(1),
    )
    == Error(Nil)
}

pub fn schema_enforces_reserved_record_and_byte_bounds_test() {
  fixture("schema-bounds", fn(path, _) {
    let assert Ok(connection) = sqlight.open(path)
    assert sqlight.exec("UPDATE custody_meta SET version=14", connection)
      |> result.is_error
    assert sqlight.exec("UPDATE custody_meta SET bytes=1", connection)
      |> result.is_error
    assert sqlight.close(connection) == Ok(Nil)
  })
}

fn assert_unavailable(book: journal.Journal) -> Nil {
  // The failure reply precedes actor exit. Racing that exit may report either
  // a closed endpoint or uncertain delivery; neither exposes custody evidence.
  let answer = journal.inspect(book, key(1), digest(1))
  assert answer == Error(journal.Closed) || answer == Error(journal.Uncertain)
}
