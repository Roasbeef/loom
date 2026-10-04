//// SQLite preparation custody controls, observing returned claims as effects.
//// No fixture creates resources or treats historical Ready as a live lease.

import broker/command as offer
import broker/dispatch
import broker/enrollment
import broker/exec
import broker/policy
import codemode/compile
import codemode/service_command
import codemode/service_input as input
import codemode/service_resources as resources
import core/command
import core/ids
import core/json
import core/msgpack as mp
import core/remote_tool
import core/workspace as cw
import executor/remote/admission
import executor/remote/compile_completion as completion
import executor/remote/identity
import executor/remote/journal as native_journal
import executor/remote/journal_codec
import executor/remote/native
import executor/remote/payload
import executor/remote/resource_journal as j
import executor/remote/wire
import executor/resource_schema
import executor/sql
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import simplifile
import sqlight
import weft

pub fn full_key_body_uuid_and_logical_address_fences_test() {
  fixture("fences", limits(4, 30_000_000), fn(_path, book, _native) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.inspect(book, original) == Error(j.Missing)
    assert j.reserve(book, original) == Ok(j.Reserved)
    assert j.reserve(book, original) == Ok(j.Reserved)
    let changes = [
      compiled("pub fn main() { 1 }", 3),
      compiled("pub fn main() { Nil }", 5),
      rekey(
        original,
        "different-physical",
        3,
        parent("parent", 3, hash("a"), 4),
      ),
      rekey(original, "physical:build", 3, parent("parent", 3, hash("f"), 4)),
      rekey(original, "physical:build", 3, parent("parent", 3, hash("a"), 6)),
    ]
    list.each(changes, fn(changed) {
      assert remote_tool.child_address(command.service_origin(changed.key))
        == remote_tool.child_address(command.service_origin(original.key))
      assert j.reserve(book, changed) == Error(j.Conflict)
    })
    let another_address =
      rekey(
        original,
        "physical:build",
        3,
        parent("other-parent", 3, hash("a"), 4),
      )
    assert remote_tool.child_address(command.service_origin(another_address.key))
      != remote_tool.child_address(command.service_origin(original.key))
    assert j.reserve(book, another_address) == Error(j.Conflict)
  })
}

pub fn independent_connections_return_one_committed_claim_test() {
  fixture("race", limits(3, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, original) == Ok(j.Reserved)
    let assert Ok(other) =
      j.recover(path, enrolled(), limits(3, 30_000_000), native)
      as "Independent SQLite endpoint."
    let outcomes =
      [book, other]
      |> list.map(fn(endpoint) {
        fn() { j.claim_preparation(endpoint, original) }
      })
      |> weft.new
      |> weft.limit(2)
      |> weft.deadline(5000)
      |> weft.start
    let values = weft.values(outcomes)
    assert list.length(values) == 2
    assert list.length(
        list.filter(values, fn(value) {
          case value {
            j.Claimed(_) -> True
            _ -> False
          }
        }),
      )
      == 1
    assert list.contains(values, j.Existing(j.Unknown(None)))
    assert j.claim_preparation(book, original)
      == Ok(j.Existing(j.Unknown(None)))
    assert j.release_endpoint(other) == Ok(Nil)
  })
}

pub fn reserved_and_preparing_recovery_never_replays_a_claim_test() {
  fixture("restart", limits(3, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, original) == Ok(j.Reserved)
    assert j.release_endpoint(book) == Ok(Nil)
    let assert Ok(reserved) =
      j.recover(path, enrolled(), limits(3, 30_000_000), native)
      as "Reserved recovers before any claim."
    assert j.inspect(reserved, original) == Ok(j.Reserved)
    let assert Ok(j.Claimed(claim)) = j.claim_preparation(reserved, original)
      as "Exactly one live permission after COMMIT."
    assert j.original(claim) == original
    assert j.release_endpoint(reserved) == Ok(Nil)
    let assert Ok(unknown) =
      j.recover(path, enrolled(), limits(3, 30_000_000), native)
      as "Preparing recovery has no live permission."
    assert j.reserve(unknown, original) == Ok(j.Unknown(None))
    assert j.claim_preparation(unknown, original)
      == Ok(j.Existing(j.Unknown(None)))
    assert j.commit_ready(claim, compile_ready(original.key)) == Error(j.Closed)
    assert j.release_endpoint(unknown) == Ok(Nil)
  })
}

pub fn prepared_unknown_and_released_retain_exact_historical_ready_test() {
  fixture("ready", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let ready = compile_ready(original.key)
    assert j.reserve(book, original) == Ok(j.Reserved)
    let assert Ok(j.Claimed(claim)) = j.claim_preparation(book, original)
      as "Live preparation."
    assert j.commit_ready(claim, ready) == Ok(j.Prepared(ready))
    assert j.commit_ready(claim, ready) == Ok(j.Prepared(ready))
    let assert Ok(observer) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "Ready is historical on another connection."
    assert j.inspect(observer, original) == Ok(j.Prepared(ready))
    assert j.claim_preparation(observer, original)
      == Ok(j.Existing(j.Prepared(ready)))
    assert j.mark_unknown(observer, original) == Ok(j.Unknown(Some(ready)))
    assert j.commit_ready(claim, ready) == Error(j.Conflict)
    assert j.release_endpoint(observer) == Ok(Nil)
    let assert Ok(unknown) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "Uncertainty retains immutable location bytes."
    assert j.inspect(unknown, original) == Ok(j.Unknown(Some(ready)))
    assert j.mark_released(unknown, original, j.ResourceOwnerCleaned)
      == Ok(j.Released(Some(ready)))
    assert j.release_endpoint(unknown) == Ok(Nil)
    let assert Ok(released) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "Cleanup leaves original fences and receipt."
    assert j.inspect(released, original) == Ok(j.Released(Some(ready)))
    assert j.mark_unknown(released, original) == Ok(j.Released(Some(ready)))
    assert j.claim_preparation(released, original)
      == Ok(j.Existing(j.Released(Some(ready))))
    assert j.commit_ready(claim, ready) == Error(j.Conflict)
    assert stored_ready(path) == resources.encode(ready)
    assert j.release_endpoint(released) == Ok(Nil)
  })
}

pub fn no_ready_is_fabricated_and_late_claim_is_fenced_test() {
  fixture("empty", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, original) == Ok(j.Reserved)
    assert j.mark_unknown(book, original) == Error(j.Conflict)
    assert j.mark_released(book, original, j.ResourceOwnerCleaned)
      == Error(j.Conflict)
    let assert Ok(j.Claimed(claim)) = j.claim_preparation(book, original)
      as "Preparing first."
    assert j.mark_unknown(book, original) == Ok(j.Unknown(None))
    assert j.mark_unknown(book, original) == Ok(j.Unknown(None))
    assert j.commit_ready(claim, compile_ready(original.key))
      == Error(j.Conflict)
    assert j.mark_released(book, original, j.ResourceOwnerCleaned)
      == Ok(j.Released(None))
    assert j.commit_ready(claim, compile_ready(original.key))
      == Error(j.Conflict)
    assert j.release_endpoint(book) == Ok(Nil)
    let assert Ok(recovered) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "No historical Ready exists."
    assert j.inspect(recovered, original) == Ok(j.Released(None))
    assert j.release_endpoint(recovered) == Ok(Nil)
  })
}

pub fn ready_must_match_full_key_and_original_launch_producer_test() {
  fixture("launch", limits(4, 30_000_000), fn(_path, book, _native) {
    let producer = compiled("pub fn main() { Nil }", 3)
    let started = launched(producer.key, 5)
    assert j.reserve(book, producer) == Ok(j.Reserved)
    let assert Ok(j.Claimed(build)) = j.claim_preparation(book, producer)
      as "Compile preparation."
    assert j.reserve(book, started) == Ok(j.Reserved)
    let assert Ok(j.Claimed(run)) = j.claim_preparation(book, started)
      as "Launch syntax/identity admitted; physical artifact proof remains external."
    let ready = launch_ready(started.key, producer.key)
    assert j.commit_ready(build, ready) == Error(j.InvalidInput)
    assert j.commit_ready(run, compile_ready(producer.key))
      == Error(j.InvalidInput)
    let another_producer = compiled("pub fn main() { 1 }", 7)
    assert j.commit_ready(run, launch_ready(started.key, another_producer.key))
      == Error(j.InvalidInput)
    let changed =
      rekey(started, "another-physical-run", 5, command.parent(started.key))
    assert j.commit_ready(run, launch_ready(changed.key, producer.key))
      == Error(j.InvalidInput)
    assert j.commit_ready(build, compile_ready(producer.key))
      == Ok(j.Prepared(compile_ready(producer.key)))
    assert j.commit_ready(run, ready) == Ok(j.Prepared(ready))
    assert j.commit_ready(run, launch_ready(started.key, another_producer.key))
      == Error(j.InvalidInput)
    assert j.inspect(book, started) == Ok(j.Prepared(ready))
  })
}

pub fn complete_byte_allowance_is_reserved_and_never_reclaimed_test() {
  let original = compiled("pub fn main() { Nil }", 3)
  let required = reservation(original)
  fixture("capacity-short", limits(2, required - 1), fn(_path, book, _native) {
    assert j.reserve(book, original) == Error(j.Capacity)
    assert j.claim_preparation(book, original) == Error(j.Missing)
  })
  fixture("capacity-exact", limits(2, required), fn(_path, book, _native) {
    assert j.reserve(book, original) == Ok(j.Reserved)
  })
  let distinct =
    rekey(
      original,
      "physical:build",
      8,
      parent("other-parent", 3, hash("a"), 4),
    )
  let distinct_required = reservation(distinct)
  let byte_allowance = case required >= distinct_required {
    True -> required
    False -> distinct_required
  }

  // Either invocation fits alone, but their combined lifetime reservations do not.
  assert required <= byte_allowance
  assert distinct_required <= byte_allowance
  assert required + distinct_required > byte_allowance
  fixture(
    "capacity-distinct",
    limits(2, byte_allowance),
    fn(_path, book, _native) {
      assert j.reserve(book, distinct) == Ok(j.Reserved)
    },
  )
  fixture("capacity-full", limits(2, byte_allowance), fn(path, book, native) {
    assert j.reserve(book, original) == Ok(j.Reserved)
    let assert Ok(j.Claimed(claim)) = j.claim_preparation(book, original)
      as "Full Ready allowance fits."
    let ready = compile_ready(original.key)
    assert j.commit_ready(claim, ready) == Ok(j.Prepared(ready))
    assert j.mark_released(book, original, j.ResourceOwnerCleaned)
      == Ok(j.Released(Some(ready)))

    // A second row is available, so only retained byte custody can refuse this.
    assert j.reserve(book, distinct) == Error(j.Capacity)
    assert j.seal(book) == Ok(j.SealedScope)
    assert j.release_endpoint(book) == Ok(Nil)
    let assert Ok(recovered) =
      j.recover(path, enrolled(), limits(2, byte_allowance), native)
      as "Saturated sealed evidence remains inspectable."
    assert j.reserve(recovered, original) == Ok(j.Released(Some(ready)))
    assert j.claim_preparation(recovered, original)
      == Ok(j.Existing(j.Released(Some(ready))))
    assert j.reserve(recovered, distinct) == Error(j.Sealed)
    assert j.release_endpoint(recovered) == Ok(Nil)
  })
}

pub fn seal_fences_independent_first_claim_but_not_original_ready_test() {
  fixture("seal", limits(3, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, original) == Ok(j.Reserved)
    let assert Ok(other) =
      j.recover(path, enrolled(), limits(3, 30_000_000), native)
      as "Independent writer."
    assert j.seal(book) == Ok(j.SealedScope)
    assert j.mode(other) == Ok(j.SealedScope)
    assert j.reserve(other, original) == Ok(j.Reserved)
    assert j.claim_preparation(other, original) == Error(j.Sealed)
    assert j.release_endpoint(other) == Ok(Nil)
  })
  fixture("late-ready", limits(2, 30_000_000), fn(_path, book, _native) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, original) == Ok(j.Reserved)
    let assert Ok(j.Claimed(claim)) = j.claim_preparation(book, original)
      as "Claim preceded seal."
    assert j.seal(book) == Ok(j.SealedScope)
    assert j.commit_ready(claim, compile_ready(original.key))
      == Ok(j.Prepared(compile_ready(original.key)))
  })
}

pub fn exact_enrollment_quotas_and_schema_bind_recovery_test() {
  fixture("binding", limits(2, 30_000_000), fn(path, book, native) {
    assert j.fresh(path, enrolled(), limits(2, 30_000_000), native)
      == Error(j.AlreadyExists)
    assert j.recover(path, enrolled(), limits(3, 30_000_000), native)
      == Error(j.BindingMismatch)
    assert j.recover(path, enrolled(), limits(2, 30_000_001), native)
      == Error(j.BindingMismatch)
    let code = enrollment.code_mode_facts(enrolled())
    let assert Ok(changed) =
      enrollment.new(
        enrollment.native_facts(enrolled()),
        enrollment.CodeModeFacts(..code, gleam_path: "/tc/bin/another"),
        hash("b"),
        hash("c"),
      )
      as "Independently valid changed snapshot with unchanged digest claims."
    assert j.recover(path, changed, limits(2, 30_000_000), native)
      == Error(j.BindingMismatch)
    assert j.release_endpoint(book) == Ok(Nil)
    execute(
      path,
      "PRAGMA ignore_check_constraints=ON; UPDATE resource_meta SET format=3",
    )
    assert j.recover(path, enrolled(), limits(2, 30_000_000), native)
      == Error(j.Corrupt)
  })
}

pub fn malformed_oversized_or_wrong_type_stored_values_are_refused_test() {
  list.each(
    [
      "UPDATE resource_call SET service_header=zeroblob(8193)",
      "UPDATE resource_call SET input=zeroblob(9437185),input_size=9437185",
      "UPDATE resource_call SET address=zeroblob(8193)",
      "UPDATE resource_call SET ready=zeroblob(262145),ready_size=262145",
      "UPDATE resource_call SET input_digest=zeroblob(40000000)",
      "UPDATE resource_call SET input_size=zeroblob(40000000)",
      "UPDATE resource_call SET phase='invalid'",
      "UPDATE resource_meta SET enrollment=zeroblob(40000000)",
      "UPDATE resource_call SET service_header=X'c0'",
      "UPDATE resource_call SET input_digest=zeroblob(32)",
      "UPDATE resource_call SET input=X'c0',input_size=1",
    ],
    fn(sql) {
      fixture("corrupt", limits(2, 30_000_000), fn(path, book, native) {
        let original = compiled("pub fn main() { Nil }", 3)
        assert j.reserve(book, original) == Ok(j.Reserved)
        execute(path, "PRAGMA ignore_check_constraints=ON; " <> sql)
        assert j.inspect(book, original) == Error(j.Corrupt)
        assert j.recover(path, enrolled(), limits(2, 30_000_000), native)
          == Error(j.Corrupt)
      })
    },
  )
}

pub fn ready_corruption_never_becomes_successful_recovery_test() {
  list.each(
    [
      "UPDATE resource_call SET ready_digest=zeroblob(32)",
      "UPDATE resource_call SET ready=X'c0',ready_size=1",
      "UPDATE resource_call SET phase=0",
    ],
    fn(sql) {
      fixture("ready-corrupt", limits(2, 30_000_000), fn(path, book, native) {
        let original = compiled("pub fn main() { Nil }", 3)
        assert j.reserve(book, original) == Ok(j.Reserved)
        let assert Ok(j.Claimed(claim)) = j.claim_preparation(book, original)
          as "Original preparing row."
        assert j.commit_ready(claim, compile_ready(original.key))
          == Ok(j.Prepared(compile_ready(original.key)))
        assert j.release_endpoint(book) == Ok(Nil)
        execute(path, "PRAGMA ignore_check_constraints=ON; " <> sql)
        assert j.recover(path, enrolled(), limits(2, 30_000_000), native)
          == Error(j.Corrupt)
      })
    },
  )
}

pub fn suppressed_insert_and_claim_never_acknowledge_permission_test() {
  fixture("suppressed-insert", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    execute(
      path,
      "CREATE TRIGGER suppress_insert BEFORE INSERT ON resource_call BEGIN SELECT RAISE(IGNORE); END",
    )
    assert j.reserve(book, original) == Error(j.Uncertain)
    let assert Ok(recovered) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "No durable reservation was acknowledged."
    assert j.inspect(recovered, original) == Error(j.Missing)
    assert j.release_endpoint(recovered) == Ok(Nil)
  })
  fixture("suppressed-claim", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, original) == Ok(j.Reserved)
    execute(
      path,
      "CREATE TRIGGER suppress_claim BEFORE UPDATE ON resource_call WHEN NEW.phase=1 BEGIN SELECT RAISE(IGNORE); END",
    )
    assert j.claim_preparation(book, original) == Error(j.Uncertain)
    let assert Ok(recovered) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "Reservation survived refused update."
    assert j.inspect(recovered, original) == Ok(j.Reserved)
    assert j.claim_preparation(recovered, original) == Error(j.Uncertain)

    // This poisoned endpoint may exit before a later close acknowledgement.
    let _ = j.release_endpoint(recovered)
    Nil
  })
}

pub fn failed_commit_never_returns_preparation_permission_test() {
  fixture("commit-failure", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, original) == Ok(j.Reserved)
    execute(
      path,
      "PRAGMA foreign_keys=ON; CREATE TABLE parent(id INTEGER PRIMARY KEY); CREATE TABLE child(id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fail_commit AFTER UPDATE ON resource_call WHEN NEW.phase=1 BEGIN INSERT INTO child VALUES(1); END",
    )
    assert j.claim_preparation(book, original) == Error(j.Uncertain)
    let assert Ok(recovered) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "Only committed Reserved evidence survived the failed COMMIT."
    assert j.inspect(recovered, original) == Ok(j.Reserved)
    assert j.claim_preparation(recovered, original) == Error(j.Uncertain)
    let _ = j.release_endpoint(recovered)
    Nil
  })
}

pub fn ignored_ready_reply_recovers_bytes_without_another_claim_test() {
  fixture("lost-ready-reply", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, original) == Ok(j.Reserved)
    let assert Ok(j.Claimed(claim)) = j.claim_preparation(book, original)
      as "One original claim."
    let ready = compile_ready(original.key)

    // Discard acknowledgement and recover evidence rather than repeating effects.
    let _ = j.commit_ready(claim, ready)
    assert j.release_endpoint(book) == Ok(Nil)
    let assert Ok(recovered) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "Original issued bytes survived a discarded acknowledgement."
    assert j.inspect(recovered, original) == Ok(j.Prepared(ready))
    assert j.claim_preparation(recovered, original)
      == Ok(j.Existing(j.Prepared(ready)))
    assert j.release_endpoint(recovered) == Ok(Nil)
  })
}

pub fn invalid_bodies_and_digest_linkage_fail_before_reservation_test() {
  fixture("invalid", limits(2, 30_000_000), fn(_path, book, _native) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, j.Input(original.key, <<>>)) == Error(j.InvalidInput)
    assert j.reserve(book, j.Input(original.key, <<1:size(1)>>))
      == Error(j.InvalidInput)
    let large = string.repeat("a", 9_437_185)
    assert j.reserve(book, j.Input(original.key, <<large:utf8>>))
      == Error(j.InvalidInput)
    let wrong_digest =
      key(
        command.CompileService,
        "physical:build",
        3,
        command.parent(original.key),
        <<>>,
      )
    assert j.reserve(book, j.Input(wrong_digest, original.body))
      == Error(j.InvalidInput)
    assert j.inspect(book, original) == Error(j.Missing)
  })
}

pub fn schema_and_named_queries_match_generated_artifacts_test() {
  let assert Ok(schema) = simplifile.read("sql/resources.sql")
    as "Owned schema source."
  assert schema == resource_schema.schema
  let assert Ok(source) = simplifile.read("src/executor/sql/resources.sql")
    as "Owned named queries."
  let generated = [
    sql.initialize_resources(<<>>, 1, 1).0,
    sql.resource_format().0,
    sql.resource_metadata().0,
    sql.resource_headers(1).0,
    sql.resource_bodies(<<>>).0,
    sql.insert_resource(<<>>, <<>>, <<>>, 0, <<>>, 1, <<>>).0,
    sql.claim_resource(<<>>).0,
    sql.commit_resource_ready(<<>>, 1, <<>>, <<>>).0,
    sql.mark_resource_unknown(<<>>).0,
    sql.release_resource(<<>>).0,
    sql.seal_resources().0,
    sql.resource_address(<<>>).0,
    sql.associate_resource_native(<<>>, Some(<<>>), <<>>, <<>>, <<>>).0,
    sql.resource_native_owner(Some(<<>>)).0,
    sql.commit_resource_compile(<<>>, <<>>, <<>>).0,
    sql.fail_resource_preparation(<<>>, <<>>, <<>>).0,
    sql.acknowledge_resource_compile(<<>>, <<>>).0,
  ]
  assert normalize(source) == normalize(string.join(generated, "\n"))
}

pub fn before_native_lost_reply_recovers_retained_handle_and_fences_ready_test() {
  fixture("before-recovery", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, original) == Ok(j.Reserved)
    let assert Ok(j.Claimed(claim)) = j.claim_preparation(book, original)
      as "Original live preparation custody."
    let value = before(original, "mkdir refused")
    let bytes = encode_completion(value)
    let _ = j.fail_preparation(claim, value)
    assert j.commit_ready(claim, compile_ready(original.key))
      == Error(j.Conflict)
    assert j.release_endpoint(book) == Ok(Nil)
    let assert Ok(recovered) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "Exact closed result recovers without the original Claim."
    let assert Ok(j.CompileRetained(retained, j.ReceiptPending)) =
      j.inspect_compile(recovered, original)
      as "Recovery constructs the local retention handle."
    assert j.retained_compile_bytes(retained) == bytes
    assert j.retained_compile_value(retained) == value
    assert j.retained_compile_digest(retained) == hash_bytes(bytes)
    assert j.claim_preparation(recovered, original)
      == Ok(j.Existing(j.Unknown(None)))
    assert native_journal.release(native) == Ok(Nil)
    assert j.commit_compile(recovered, original, value) == Ok(retained)
    assert j.acknowledge_compile(
        recovered,
        original,
        j.retained_compile_digest(retained),
      )
      == Ok(j.CompileRetained(retained, j.ReceiptAcknowledged))
    assert j.release_endpoint(recovered) == Ok(Nil)
  })
}

pub fn request_without_admission_and_terminal_without_settlement_are_not_custody_test() {
  fixture("split-native", limits(2, 30_000_000), fn(_path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let _ = prepared_resource(book, original)
    let prepared = prepared_command(original)
    let key = native_key(original, 8)
    let bytes = encode_prepared(prepared)
    let digest = hash_bytes(bytes)
    let ref = command_ref(original)
    assert bit_array.byte_size(
        journal_codec.encode(journal_codec.Admit(key, digest)),
      )
      == 106
    assert native_journal.put_payload(
        native,
        key,
        digest,
        payload.Request(bytes),
      )
      == Ok(Nil)
    assert j.associate_native(book, original, ref, key, digest)
      == Error(j.Conflict)
    let assert Ok(_) = native_journal.admit(native, key, digest)
      as "Actual durable admission."
    assert j.associate_native(book, original, ref, key, digest)
      == Ok(j.Associated(ref, key, digest, prepared))
    let assert Ok(_) =
      native_journal.apply(native, key, digest, admission.AuthorizeLaunch)
      as "Only the native journal grants launch intent."
    let terminal = terminal_bytes()
    assert native_journal.put_payload(
        native,
        key,
        digest,
        payload.Terminal(terminal),
      )
      == Ok(Nil)
    let value = success(original, key, digest, terminal)
    assert j.commit_compile(book, original, value) == Error(j.Conflict)
    let terminal_digest = hash_bytes(terminal)
    assert digest != terminal_digest
    let assert Ok(_) =
      native_journal.apply(
        native,
        key,
        digest,
        admission.ObserveTerminal(terminal_digest),
      )
      as "Terminal reducer commit follows payload commit."
    let assert Ok(_) =
      native_journal.apply(native, key, digest, admission.ConfirmRetirement)
      as "Real native retirement is independent."
    let assert Ok(_) =
      native_journal.apply(
        native,
        key,
        digest,
        admission.ConfirmOwnerReceipt(terminal_digest),
      )
      as "Native owner receipt is independent of outer Compile receipt."
    let assert Ok(_) =
      native_journal.apply(native, key, digest, admission.Compact)
      as "Positive terminal evidence survives retirement compaction."
    let assert Ok(retained) = j.commit_compile(book, original, value)
      as "Exact settled completion."
    assert j.retained_compile_digest(retained) != digest
    assert j.retained_compile_digest(retained) != terminal_digest
    assert j.inspect_compile(book, original)
      == Ok(j.CompileRetained(retained, j.ReceiptPending))
  })
}

pub fn committed_retries_and_ack_survive_native_endpoint_loss_and_seal_test() {
  fixture("history-only", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let _ = prepared_resource(book, original)
    let #(ref, key, digest, prepared) =
      admitted(native, book, original, 8, prepared_command(original))
    let terminal = native_terminal(native, key, digest)
    let value = success(original, key, digest, terminal)
    let assert Ok(retained) = j.commit_compile(book, original, value)
      as "Original completion retained."
    let different =
      native_failure(original, key, digest, terminal, "different finalizer")
    assert j.commit_compile(book, original, different) == Error(j.Conflict)
    assert j.acknowledge_compile(book, original, digest) == Error(j.Conflict)
    assert j.mark_released(book, original, j.ResourceOwnerCleaned)
      == Ok(j.Released(Some(compile_ready(original.key))))
    assert j.seal(book) == Ok(j.SealedScope)
    assert native_journal.release(native) == Ok(Nil)
    assert j.associate_native(book, original, ref, key, digest)
      == Ok(j.Associated(ref, key, digest, prepared))
    assert j.commit_compile(book, original, value) == Ok(retained)
    assert j.release_endpoint(book) == Ok(Nil)
    let assert Ok(recovered) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "Recovery validates historical association without native I/O."
    assert j.inspect_compile(recovered, original)
      == Ok(j.CompileRetained(retained, j.ReceiptPending))
    assert j.commit_compile(recovered, original, value) == Ok(retained)
    let expected = Ok(j.CompileRetained(retained, j.ReceiptAcknowledged))
    assert j.acknowledge_compile(
        recovered,
        original,
        j.retained_compile_digest(retained),
      )
      == expected
    assert j.acknowledge_compile(
        recovered,
        original,
        j.retained_compile_digest(retained),
      )
      == expected
    assert j.claim_preparation(recovered, original)
      == Ok(j.Existing(j.Released(Some(compile_ready(original.key)))))
    assert j.release_endpoint(recovered) == Ok(Nil)
  })
}

pub fn ready_without_native_cannot_settle_before_and_launch_outcomes_are_closed_test() {
  fixture("ready-no-negative", limits(3, 30_000_000), fn(_path, book, _native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let claim = prepared_resource(book, original)
    let failure = before(original, "clearance refused")
    assert j.fail_preparation(claim, failure) == Error(j.Conflict)
    assert j.commit_compile(book, original, failure) == Error(j.Conflict)
    assert j.inspect_compile(book, original) == Ok(j.CompilePending)
    let launch = launched(original.key, 7)
    assert j.reserve(book, launch) == Ok(j.Reserved)
    assert j.inspect_compile(book, launch) == Error(j.UnsupportedRole)
    assert j.inspect_native(book, launch) == Error(j.UnsupportedRole)
    assert j.commit_compile(book, launch, failure) == Error(j.UnsupportedRole)
    assert j.acknowledge_compile(book, launch, hash_bytes(<<1>>))
      == Error(j.UnsupportedRole)
  })
}

pub fn admitted_narrower_policy_is_preserved_and_wider_template_refuses_test() {
  fixture("policy-narrow", limits(2, 30_000_000), fn(_path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let _ = prepared_resource(book, original)
    let original_prepared = prepared_command(original)
    let assert Some(original_policy) = original_prepared.request.policy
      as "Complete cleared policy."
    let narrower =
      policy.SandboxPolicy(
        ..original_policy,
        limits: policy.Limits(..original_policy.limits, cpu_s: 1),
        protected: [
          "/alloc/protected",
          ..list.reverse(original_policy.protected)
        ],
        env_allow: list.reverse(original_policy.env_allow),
      )
    let prepared =
      wire.Prepared(
        ..original_prepared,
        request: exec.ExecRequest(
          ..original_prepared.request,
          policy: Some(narrower),
        ),
      )
    let #(ref, key, digest, _) = admitted(native, book, original, 8, prepared)
    assert j.inspect_native(book, original)
      == Ok(j.Associated(ref, key, digest, prepared))
  })
  list.each(["network", "roots"], fn(dimension) {
    fixture("policy-wide", limits(2, 30_000_000), fn(_path, book, native) {
      let original = compiled("pub fn main() { Nil }", 3)
      let _ = prepared_resource(book, original)
      let good = prepared_command(original)
      let assert Some(base) = good.request.policy as "Native policy."
      // Each witness changes one authority dimension, so root rejection cannot
      // conceal a missing network comparison or the converse.
      let wider = case dimension {
        "network" -> policy.SandboxPolicy(..base, network: policy.NetworkFull)
        _ ->
          policy.SandboxPolicy(..base, writable_roots: [
            "/",
            ..base.writable_roots
          ])
      }
      let prepared =
        wire.Prepared(
          ..good,
          request: exec.ExecRequest(..good.request, policy: Some(wider)),
        )
      let key = native_key(original, 8)
      let digest = retain_native_request(native, key, prepared)
      assert j.associate_native(
          book,
          original,
          command_ref(original),
          key,
          digest,
        )
        == Error(j.Conflict)
      assert j.inspect_native(book, original) == Ok(j.Unassociated)
    })
  })
}

pub fn full_reference_and_actual_prepared_fields_bind_association_test() {
  fixture("exact-native", limits(3, 30_000_000), fn(_path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let _ = prepared_resource(book, original)
    let good = prepared_command(original)
    let bad = [
      wire.Prepared(..good, step: "other-physical"),
      wire.Prepared(..good, registration: hash_bytes(<<1>>)),
      wire.Prepared(
        ..good,
        request: exec.ExecRequest(..good.request, argv: [
          "/tc/bin/gleam",
          "other",
        ]),
      ),
      wire.Prepared(
        ..good,
        request: exec.ExecRequest(
          ..good.request,
          env: list.reverse(good.request.env),
        ),
      ),
      wire.Prepared(
        ..good,
        request: exec.ExecRequest(..good.request, cwd: "/alloc/other"),
      ),
    ]
    list.index_map(bad, fn(prepared, index) {
      let key = native_key(original, 10 + index)
      let digest = retain_native_request(native, key, prepared)
      assert j.associate_native(
          book,
          original,
          command_ref(original),
          key,
          digest,
        )
        == Error(j.Conflict)
    })
    let key = native_key(original, 8)
    let digest = retain_native_request(native, key, good)
    let changed =
      rekey(original, "physical:build", 9, parent("parent", 3, hash("d"), 4))
    assert j.associate_native(book, original, command_ref(changed), key, digest)
      == Error(j.Conflict)
    assert j.associate_native(
        book,
        original,
        command_ref(original),
        key,
        digest,
      )
      == Ok(j.Associated(command_ref(original), key, digest, good))
    assert j.associate_native(
        book,
        original,
        command_ref(original),
        key,
        hash_bytes(<<2>>),
      )
      == Error(j.Conflict)
    let other =
      rekey(
        original,
        "physical:build",
        9,
        parent("other-parent", 3, hash("a"), 4),
      )
    let _ = prepared_resource(book, other)
    assert j.associate_native(book, other, command_ref(other), key, digest)
      == Error(j.Conflict)
  })
}

pub fn foreign_native_operation_and_pinned_scope_cannot_associate_test() {
  fixture("native-binding", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let _ = prepared_resource(book, original)
    let prepared = prepared_command(original)
    let assert Ok(operation) =
      ids.parse_op_id("00000000-0000-7000-8000-000000000012")
      as "Foreign native operation."
    let assert Ok(request) = identity.request_id(ids.entry_id_to_string(id(8)))
      as "Independent UUID."
    let key = identity.request_key(native_scope(), operation, request)
    let digest = retain_native_request(native, key, prepared)
    assert j.associate_native(
        book,
        original,
        command_ref(original),
        key,
        digest,
      )
      == Error(j.Conflict)
    let #(session, name, executor, _, workspace_epoch) =
      identity.scope_fields(native_scope())
    let assert Ok(session_epoch) = identity.epoch(3) as "Another session epoch."
    let assert Ok(name) = identity.workspace_id(name) as "Same workspace."
    let assert Ok(executor) = identity.executor_id(executor) as "Same executor."
    let assert Ok(workspace_epoch) = identity.epoch(workspace_epoch)
      as "Same workspace epoch."
    let assert Ok(session) = ids.parse_session_id(session)
      as "Same native session."
    let other_scope =
      identity.scope(session, name, executor, session_epoch, workspace_epoch)
    let assert Ok(capacity) = admission.capacity(20)
      as "Other native scope capacity."
    let assert Ok(other) =
      native_journal.fresh(path <> ".foreign", other_scope, capacity)
      as "Real independent native journal."
    assert j.recover(path, enrolled(), limits(2, 30_000_000), other)
      == Error(j.BindingMismatch)
    assert native_journal.release(other) == Ok(Nil)
  })
}

pub fn legacy_format_is_refused_before_accessing_new_columns_test() {
  fixture("legacy-format", limits(2, 30_000_000), fn(path, book, native) {
    assert j.release_endpoint(book) == Ok(Nil)
    execute(
      path,
      "DROP TABLE resource_call; DROP TABLE resource_meta; CREATE TABLE resource_meta(id INTEGER,format INTEGER); INSERT INTO resource_meta VALUES(1,1)",
    )
    assert j.recover(path, enrolled(), limits(2, 30_000_000), native)
      == Error(j.BindingMismatch)
  })
}

pub fn association_completion_and_ack_suppressed_writes_never_acknowledge_test() {
  list.each([0, 1, 2], fn(stage) {
    fixture("custody-suppressed", limits(2, 30_000_000), fn(path, book, native) {
      let original = compiled("pub fn main() { Nil }", 3)
      let _ = prepared_resource(book, original)
      let prepared = prepared_command(original)
      let key = native_key(original, 8)
      let digest = retain_native_request(native, key, prepared)
      let ref = command_ref(original)
      case stage {
        0 -> {
          execute(
            path,
            "CREATE TRIGGER suppress_association BEFORE UPDATE OF native_id ON resource_call BEGIN SELECT RAISE(IGNORE); END",
          )
          assert j.associate_native(book, original, ref, key, digest)
            == Error(j.Uncertain)
        }
        1 | 2 -> {
          let assert Ok(_) =
            j.associate_native(book, original, ref, key, digest)
            as "Actual association."
          let terminal = native_terminal(native, key, digest)
          let value = success(original, key, digest, terminal)
          case stage {
            1 -> {
              execute(
                path,
                "CREATE TRIGGER suppress_completion BEFORE UPDATE OF completion ON resource_call BEGIN SELECT RAISE(IGNORE); END",
              )
              assert j.commit_compile(book, original, value)
                == Error(j.Uncertain)
            }
            2 -> {
              let assert Ok(retained) = j.commit_compile(book, original, value)
                as "Retained before ACK."
              execute(
                path,
                "CREATE TRIGGER suppress_ack BEFORE UPDATE OF outer_receipt ON resource_call BEGIN SELECT RAISE(IGNORE); END",
              )
              assert j.acknowledge_compile(
                  book,
                  original,
                  j.retained_compile_digest(retained),
                )
                == Error(j.Uncertain)
            }
            _ -> Nil
          }
        }
        _ -> Nil
      }
      let _ = j.release_endpoint(book)
      let assert Ok(recovered) =
        j.recover(path, enrolled(), limits(2, 30_000_000), native)
        as "Only committed custody recovers."
      case stage {
        0 -> {
          assert j.inspect_native(recovered, original) == Ok(j.Unassociated)
        }
        1 -> {
          assert j.inspect_compile(recovered, original) == Ok(j.CompilePending)
        }
        2 -> {
          let assert Ok(j.CompileRetained(_, j.ReceiptPending)) =
            j.inspect_compile(recovered, original)
            as "Suppressed outer acknowledgement remains pending."
          Nil
        }
        _ -> Nil
      }
      assert j.release_endpoint(recovered) == Ok(Nil)
    })
  })
}

pub fn failed_compile_commit_recovers_pending_without_retained_handle_test() {
  fixture("completion-commit", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let _ = prepared_resource(book, original)
    let #(_, key, digest, _) =
      admitted(native, book, original, 8, prepared_command(original))
    let terminal = native_terminal(native, key, digest)
    execute(
      path,
      "CREATE TABLE parent(id INTEGER PRIMARY KEY); CREATE TABLE child(id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fail_completion AFTER UPDATE OF completion ON resource_call BEGIN INSERT INTO child VALUES(99); END",
    )
    assert j.commit_compile(
        book,
        original,
        success(original, key, digest, terminal),
      )
      == Error(j.Uncertain)
    let _ = j.release_endpoint(book)
    let assert Ok(recovered) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "Failed COMMIT did not retain a result."
    assert j.inspect_compile(recovered, original) == Ok(j.CompilePending)
    assert j.release_endpoint(recovered) == Ok(Nil)
  })
}

pub fn custody_corruption_is_bounded_before_decoder_and_never_grants_permission_test() {
  list.each(
    [
      "UPDATE resource_call SET command_ref=zeroblob(40000000)",
      "UPDATE resource_call SET native_identity=zeroblob(107)",
      "UPDATE resource_call SET native_prepared=zeroblob(40000000)",
      "UPDATE resource_call SET completion=zeroblob(40000000)",
      "UPDATE resource_call SET completion_digest=zeroblob(31)",
      "UPDATE resource_call SET outer_receipt=2",
    ],
    fn(change) {
      fixture(
        "custody-corruption",
        limits(2, 30_000_000),
        fn(path, book, native) {
          let original = compiled("pub fn main() { Nil }", 3)
          let _ = prepared_resource(book, original)
          assert j.release_endpoint(book) == Ok(Nil)
          execute(path, "PRAGMA ignore_check_constraints=ON; " <> change)
          assert j.recover(path, enrolled(), limits(2, 30_000_000), native)
            == Error(j.Corrupt)
        },
      )
    },
  )
}

pub fn guarded_queries_refuse_each_oversized_projection_test() {
  // The generated decoders must fail at the guarded column itself. No custody
  // relationship or MessagePack decoder participates in these query assertions.
  list.each(
    [
      #("id=zeroblob(37)", 0, None),
      #("address=zeroblob(8193)", 1, Some(0)),
      #("service_header=zeroblob(8193)", 2, Some(1)),
      #("input_digest=zeroblob(33)", 4, None),
      #("input=zeroblob(9437185),input_size=9437185", 5, Some(2)),
      #("ready_digest=zeroblob(33)", 7, None),
      #("ready=zeroblob(262145),ready_size=262145", 8, Some(3)),
      #("native_id=zeroblob(37)", 9, None),
      #("command_ref=zeroblob(8193)", 10, Some(4)),
      #("native_identity=zeroblob(107)", 11, Some(5)),
      #("native_prepared=zeroblob(131073)", 12, Some(6)),
      #("completion=zeroblob(262145)", 13, Some(7)),
      #("completion_digest=zeroblob(33)", 14, None),
    ],
    fn(change) {
      fixture(
        "guarded-projection",
        limits(2, 30_000_000),
        fn(path, book, _native) {
          let original = compiled("pub fn main() { Nil }", 3)
          let _ = prepared_resource(book, original)
          assert j.release_endpoint(book) == Ok(Nil)
          let assert Ok(connection) = sqlight.open(path)
            as "Independent guarded-query reader."
          let headers = sql.resource_headers(2)
          let assert Ok([header]) =
            sqlight.query(headers.0, connection, [sqlight.int(2)], headers.2)
            as "The untouched row passes the complete generated header decoder."
          assert header.valid == 1
          let bodies = sql.resource_bodies(header.id)
          let assert Ok([_]) =
            sqlight.query(
              bodies.0,
              connection,
              [sqlight.blob(header.id)],
              bodies.2,
            )
            as "The untouched row passes the complete generated body decoder."
          assert sqlight.close(connection) == Ok(Nil)
          execute(
            path,
            "PRAGMA ignore_check_constraints=ON; UPDATE resource_call SET "
              <> change.0,
          )

          // A NULL produced by the individual size guard fails at its exact column.
          // A missing guard yields a decoded row, even when header.valid is zero.
          let assert Ok(connection) = sqlight.open(path)
            as "Read the intentionally oversized stored column."
          assert_projection_refused(
            sqlight.query(headers.0, connection, [sqlight.int(2)], headers.2),
            change.1,
          )
          case change.2 {
            Some(field) ->
              assert_projection_refused(
                sqlight.query(
                  bodies.0,
                  connection,
                  [sqlight.blob(header.id)],
                  bodies.2,
                ),
                field,
              )
            None -> Nil
          }
          assert sqlight.close(connection) == Ok(Nil)
        },
      )
    },
  )
}

pub fn live_association_returns_one_bound_permit_and_later_cancel_is_in_flight_test() {
  fixture("live-first", limits(2, 30_000_000), fn(_path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let claim = prepared_resource(book, original)
    let prepared = prepared_command(original)
    let key = native_key(original, 8)
    let digest = retain_live_request(native, key, prepared)
    let ref = command_ref(original)
    let assert Ok(permit) = j.associate_live_native(claim, ref, key, digest)
      as "Only the original live association commits launch eligibility."
    assert j.native_launch_binding(permit) == #(book, ref, key, digest)
    assert j.associate_live_native(claim, ref, key, digest) == Error(j.Conflict)
    assert j.inspect_native(book, original)
      == Ok(j.Associated(ref, key, digest, prepared))
    assert j.mark_unknown(book, original)
      == Ok(j.Unknown(Some(compile_ready(original.key))))
    assert j.inspect_native(book, original)
      == Ok(j.Associated(ref, key, digest, prepared))

    // Cancellation after association follows that same tuple. Resource custody
    // neither rolls back native admission nor promises cancellation before spawn.
    let assert Ok(evidence) = native_journal.inspect(native, key, digest)
      as "Actual original admitted record."
    assert admission.phase(evidence) == admission.Admitted
    let assert Ok(decision) =
      native_journal.apply(native, key, digest, admission.AuthorizeLaunch)
      as "The already-admitted native continuation retains its separate ordering."
    let assert admission.Launch(_) = decision.effect
      as "Native reducer grants launch once."
    let assert Ok(duplicate) =
      native_journal.apply(native, key, digest, admission.AuthorizeLaunch)
      as "Native reducer rejects a second launch effect."
    assert duplicate.effect == admission.NoLaunch
  })
}

pub fn cancellation_before_live_association_blocks_permission_but_preserves_history_test() {
  fixture("live-cancel-first", limits(2, 30_000_000), fn(_path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let claim = prepared_resource(book, original)
    let prepared = prepared_command(original)
    let key = native_key(original, 8)
    let digest = retain_live_request(native, key, prepared)
    let ref = command_ref(original)
    assert j.mark_unknown(book, original)
      == Ok(j.Unknown(Some(compile_ready(original.key))))
    assert j.associate_live_native(claim, ref, key, digest) == Error(j.Conflict)
    assert j.inspect_native(book, original) == Ok(j.Unassociated)
    assert j.associate_native(book, original, ref, key, digest)
      == Ok(j.Associated(ref, key, digest, prepared))
    assert j.associate_live_native(claim, ref, key, digest) == Error(j.Conflict)
    let assert Ok(evidence) = native_journal.inspect(native, key, digest)
      as "Historical association does not authorize native launch."
    assert admission.phase(evidence) == admission.Admitted
  })
}

pub fn live_association_requires_ready_and_open_scope_on_original_claim_test() {
  list.each([0, 1, 2], fn(stage) {
    fixture("live-eligibility", limits(2, 30_000_000), fn(_path, book, native) {
      let original = compiled("pub fn main() { Nil }", 3)
      assert j.reserve(book, original) == Ok(j.Reserved)
      let assert Ok(j.Claimed(claim)) = j.claim_preparation(book, original)
        as "Original preparation claim."
      case stage {
        0 -> Nil
        1 -> {
          let assert Ok(_) = j.commit_ready(claim, compile_ready(original.key))
            as "Ready first."
          assert j.seal(book) == Ok(j.SealedScope)
        }
        2 -> {
          let assert Ok(_) = j.commit_ready(claim, compile_ready(original.key))
            as "Ready first."
          let assert Ok(_) =
            j.mark_released(book, original, j.ResourceOwnerCleaned)
            as "Actual owner cleanup."
          Nil
        }
        _ -> Nil
      }
      let key = native_key(original, 8)
      let digest = retain_live_request(native, key, prepared_command(original))
      let error = case stage {
        1 -> j.Sealed
        _ -> j.Conflict
      }
      assert j.associate_live_native(claim, command_ref(original), key, digest)
        == Error(error)
      assert j.inspect_native(book, original) == Ok(j.Unassociated)
    })
  })
}

pub fn live_request_and_authority_without_actual_admit_cannot_grant_permission_test() {
  fixture("live-no-admit", limits(2, 30_000_000), fn(_path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let claim = prepared_resource(book, original)
    let prepared = prepared_command(original)
    let key = native_key(original, 8)
    let bytes = encode_prepared(prepared)
    let digest = hash_bytes(bytes)
    assert native_journal.put_payload(
        native,
        key,
        digest,
        payload.Request(bytes),
      )
      == Ok(Nil)
    assert native_journal.put_payload(
        native,
        key,
        digest,
        payload.Authority(authority(1, -30_000, 10_000)),
      )
      == Ok(Nil)
    assert j.associate_live_native(claim, command_ref(original), key, digest)
      == Error(j.Conflict)
    assert j.inspect_native(book, original) == Ok(j.Unassociated)
    let assert Ok(_) = native_journal.admit(native, key, digest)
      as "Actual Admit follows both payloads."
    let assert Ok(permit) =
      j.associate_live_native(claim, command_ref(original), key, digest)
      as "Negative absolute clock era is preserved without deriving a new deadline."
    assert j.native_launch_binding(permit)
      == #(book, command_ref(original), key, digest)
  })
}

pub fn live_requires_exact_canonical_finite_authority_despite_actual_admit_test() {
  let assert Ok(shape) =
    wire.encode_value(mp.ArrayValue([mp.IntValue(1), mp.IntValue(10)]))
    as "Wrong authority tuple size."
  let authorities = [
    None,
    Some(authority(0, 30_000, 10_000)),
    Some(authority(2_147_483_648, 30_000, 10_000)),
    Some(authority(1, 0, 10_000)),
    Some(authority(1, 30_000, 999)),
    Some(authority(1, 30_000, 180_000)),
    Some(shape),
    Some(<<147, 204, 1, 2, 205, 3, 232>>),
  ]
  list.each(authorities, fn(value) {
    fixture("live-authority", limits(2, 30_000_000), fn(_path, book, native) {
      let original = compiled("pub fn main() { Nil }", 3)
      let claim = prepared_resource(book, original)
      let prepared = prepared_command(original)
      let key = native_key(original, 8)
      let digest = retain_native_request(native, key, prepared)
      case value {
        None -> Nil
        Some(bytes) -> {
          assert native_journal.put_payload(
              native,
              key,
              digest,
              payload.Authority(bytes),
            )
            == Ok(Nil)
        }
      }
      assert j.associate_live_native(claim, command_ref(original), key, digest)
        == Error(j.Conflict)
      assert j.inspect_native(book, original) == Ok(j.Unassociated)

      // These same genuine admitted records remain readable historically. New
      // live eligibility alone requires the native actor's complete authority order.
      assert j.associate_native(
          book,
          original,
          command_ref(original),
          key,
          digest,
        )
        == Ok(j.Associated(command_ref(original), key, digest, prepared))
    })
  })
}

pub fn live_reference_and_original_endpoint_are_exactly_bound_test() {
  fixture("live-exact-binding", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let claim = prepared_resource(book, original)
    assert j.claim_journal(claim) == book
    assert j.native_endpoint(book) == native
    let assert Ok(capacity) = admission.capacity(20)
      as "Other native endpoint capacity."
    let assert Ok(foreign) =
      native_journal.fresh(path <> ".foreign", native_scope(), capacity)
      as "Same scope does not imply identical actual native journal custody."
    assert j.native_endpoint(book) != foreign
    assert native_journal.scope(foreign) == native_journal.scope(native)
    let prepared = prepared_command(original)
    let key = native_key(original, 8)
    let digest = retain_live_request(native, key, prepared)
    let substituted =
      rekey(original, "physical:build", 3, parent("parent", 3, hash("a"), 5))
    assert j.associate_live_native(claim, command_ref(substituted), key, digest)
      == Error(j.Conflict)
    assert j.inspect_native(book, original) == Ok(j.Unassociated)
    let ref = command_ref(original)
    let assert Ok(permit) = j.associate_live_native(claim, ref, key, digest)
      as "The exact reference succeeds after a refused substitution."
    assert j.native_launch_binding(permit) == #(book, ref, key, digest)
    assert native_journal.release(foreign) == Ok(Nil)
  })
}

pub fn historical_input_lookup_compares_entire_key_at_same_logical_slot_test() {
  fixture("read-full-key", limits(2, 30_000_000), fn(_path, book, _native) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.retained_input(book, original.key) == Error(j.Missing)
    assert j.reserve(book, original) == Ok(j.Reserved)
    assert j.retained_input(book, original.key) == Ok(original)
    let changed_body = compiled("pub fn main() { 1 }", 3)
    let #(original_scope, operation, step) = command.coordinates(original.key)
    let assert Ok(foreign_scope) =
      cw.scope_from_fields(
        "00000000-0000-7000-8000-000000000001",
        "checkout",
        "linux",
        3,
        7,
      )
      as "Changed authority epoch."
    let assert Ok(changed_scope) =
      command.service_key(
        command.parent(original.key),
        command.CompileService,
        foreign_scope,
        operation,
        step,
        id(3),
        command.digests(original.key).0,
        hash("b"),
        hash("c"),
      )
      as "Full key with foreign epoch."
    let assert Ok(changed_registration) =
      command.service_key(
        command.parent(original.key),
        command.CompileService,
        original_scope,
        operation,
        step,
        id(3),
        command.digests(original.key).0,
        hash("d"),
        hash("c"),
      )
      as "Full key with foreign registration."
    let assert Ok(changed_contract) =
      command.service_key(
        command.parent(original.key),
        command.CompileService,
        original_scope,
        operation,
        step,
        id(3),
        command.digests(original.key).0,
        hash("b"),
        hash("d"),
      )
      as "Full key with foreign contract."
    let substitutions = [
      changed_body.key,
      rekey(original, "different:step", 3, command.parent(original.key)).key,
      rekey(original, "physical:build", 9, command.parent(original.key)).key,
      rekey(original, "physical:build", 3, parent("parent", 3, hash("f"), 4)).key,
      rekey(original, "physical:build", 3, parent("parent", 3, hash("a"), 5)).key,
      changed_scope,
      changed_registration,
      changed_contract,
    ]
    list.each(substitutions, fn(key) {
      assert remote_tool.child_address(command.service_origin(key))
        == remote_tool.child_address(command.service_origin(original.key))
      assert j.retained_input(book, key) == Error(j.Conflict)
    })
    assert j.retained_input(book, original.key) == Ok(original)
  })
}

pub fn historical_input_ready_and_completion_survive_reopen_without_native_endpoint_test() {
  fixture("read-reopen", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let claim = prepared_resource(book, original)
    let prepared = prepared_command(original)
    let key = native_key(original, 8)
    let digest = retain_live_request(native, key, prepared)
    let ref = command_ref(original)
    let assert Ok(_) = j.associate_live_native(claim, ref, key, digest)
      as "Fresh original permission."
    let terminal = native_terminal(native, key, digest)
    let assert Ok(retained) =
      j.commit_compile(book, original, success(original, key, digest, terminal))
      as "Exact settled outcome."
    assert j.seal(book) == Ok(j.SealedScope)
    assert native_journal.release(native) == Ok(Nil)
    assert j.retained_input(book, original.key) == Ok(original)
    assert j.release_endpoint(book) == Ok(Nil)
    let assert Ok(reopened) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "Historical evidence does not need a live native endpoint."
    let assert Ok(saved) = j.retained_input(reopened, original.key)
      as "Exact retained input only."
    assert saved == original
    assert j.inspect(reopened, saved)
      == Ok(j.Prepared(compile_ready(original.key)))
    assert j.inspect_compile(reopened, saved)
      == Ok(j.CompileRetained(retained, j.ReceiptPending))
    assert j.claim_preparation(reopened, saved)
      == Ok(j.Existing(j.Prepared(compile_ready(original.key))))
    assert j.associate_native(reopened, saved, ref, key, digest)
      == Ok(j.Associated(ref, key, digest, prepared))
    assert j.associate_live_native(claim, ref, key, digest) == Error(j.Closed)
    assert j.release_endpoint(reopened) == Ok(Nil)
  })
}

pub fn ignored_live_permission_reply_never_reconstructs_another_permit_test() {
  fixture("live-lost-reply", limits(2, 30_000_000), fn(_path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let claim = prepared_resource(book, original)
    let prepared = prepared_command(original)
    let key = native_key(original, 8)
    let digest = retain_live_request(native, key, prepared)
    let ref = command_ref(original)

    // This caller discards the actual committed response, as after a lost ACK.
    // No subsequent call may reconstruct its live continuation from the row.
    let _ignored = j.associate_live_native(claim, ref, key, digest)
    assert j.inspect_native(book, original)
      == Ok(j.Associated(ref, key, digest, prepared))
    assert j.associate_live_native(claim, ref, key, digest) == Error(j.Conflict)
    assert j.associate_native(book, original, ref, key, digest)
      == Ok(j.Associated(ref, key, digest, prepared))
  })
}

pub fn historical_association_winning_first_never_grants_a_live_retry_test() {
  fixture("history-first", limits(2, 30_000_000), fn(_path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let claim = prepared_resource(book, original)
    let prepared = prepared_command(original)
    let key = native_key(original, 8)
    let digest = retain_live_request(native, key, prepared)
    let ref = command_ref(original)
    assert j.associate_native(book, original, ref, key, digest)
      == Ok(j.Associated(ref, key, digest, prepared))
    assert j.associate_live_native(claim, ref, key, digest) == Error(j.Conflict)
    assert j.retained_input(book, original.key) == Ok(original)
  })
}

pub fn historical_launch_input_lookup_returns_data_without_a_compile_permit_test() {
  fixture("history-launch", limits(2, 30_000_000), fn(_path, book, _native) {
    let producer = compiled("pub fn main() { Nil }", 3)
    let original = launched(producer.key, 8)
    assert j.reserve(book, original) == Ok(j.Reserved)
    let assert Ok(j.Claimed(claim)) = j.claim_preparation(book, original)
      as "Original Launch preparation."
    let ready = launch_ready(original.key, producer.key)
    assert j.commit_ready(claim, ready) == Ok(j.Prepared(ready))
    assert j.retained_input(book, original.key) == Ok(original)
    let compiled_ref = command_ref(producer)
    let native_key = native_key(producer, 9)
    let digest = hash_bytes(<<>>)
    assert j.associate_live_native(claim, compiled_ref, native_key, digest)
      == Error(j.UnsupportedRole)
  })
}

pub fn failed_live_association_commit_never_returns_permission_test() {
  fixture("live-commit-failure", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let claim = prepared_resource(book, original)
    let key = native_key(original, 8)
    let digest = retain_live_request(native, key, prepared_command(original))
    let ref = command_ref(original)
    execute(
      path,
      "PRAGMA foreign_keys=ON; CREATE TABLE live_parent(id INTEGER PRIMARY KEY); CREATE TABLE live_child(id INTEGER REFERENCES live_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fail_live_commit AFTER UPDATE OF native_id ON resource_call BEGIN INSERT INTO live_child VALUES(1); END",
    )
    assert j.associate_live_native(claim, ref, key, digest)
      == Error(j.Uncertain)
    let assert Ok(reopened) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "Association rolled back."
    assert j.inspect_native(reopened, original) == Ok(j.Unassociated)
    assert j.associate_live_native(claim, ref, key, digest) == Error(j.Closed)
    assert j.release_endpoint(reopened) == Ok(Nil)
  })
}

fn assert_projection_refused(
  answer: Result(List(a), sqlight.Error),
  field: Int,
) {
  let assert Error(sqlight.SqlightError(code, message, offset)) = answer
    as "The guarded generated projection must refuse before semantic decoding."
  assert code == sqlight.GenericError
  assert offset == -1
  assert string.starts_with(message, "Decoder failed, expected ")
  assert string.ends_with(message, " in " <> int.to_string(field))
}

fn before(original: j.Input, reason: String) -> completion.CompileCompletion {
  let assert Ok(value) =
    completion.failed_before_native(
      enrolled(),
      original.key,
      compile.WorkspaceSetupFailed(reason),
    )
    as "Closed original Before-native error."
  value
}

fn encode_completion(value: completion.CompileCompletion) -> BitArray {
  let assert Ok(bytes) = completion.encode(value) as "Canonical exact result."
  bytes
}

fn hash_bytes(bytes: BitArray) -> identity.Digest {
  let assert Ok(hash) = wire.digest(bytes) as "Canonical SHA-256 evidence."
  hash
}

fn authority(generation: Int, deadline: Int, budget: Int) -> BitArray {
  let assert Ok(bytes) =
    wire.encode_value(
      mp.ArrayValue([
        mp.IntValue(generation),
        mp.IntValue(deadline),
        mp.IntValue(budget),
      ]),
    )
    as "Canonical original native authority tuple."
  bytes
}

fn retain_live_request(
  native: native_journal.Journal,
  key: identity.RequestKey,
  prepared: wire.Prepared,
) -> identity.Digest {
  let bytes = encode_prepared(prepared)
  let digest = hash_bytes(bytes)
  assert native_journal.put_payload(native, key, digest, payload.Request(bytes))
    == Ok(Nil)
  assert native_journal.put_payload(
      native,
      key,
      digest,
      payload.Authority(authority(1, 30_000, 10_000)),
    )
    == Ok(Nil)
  let assert Ok(_) = native_journal.admit(native, key, digest)
    as "Real Request/Authority/Admit order."
  digest
}

fn command_ref(original: j.Input) -> command.CommandRef {
  let assert Ok(ref) = command.command_ref(original.key, command.CompileCommand)
    as "Closed original command purpose."
  ref
}

fn prepared_resource(book: j.Journal, original: j.Input) -> j.Claim {
  assert j.reserve(book, original) == Ok(j.Reserved)
  let assert Ok(j.Claimed(claim)) = j.claim_preparation(book, original)
    as "First committed preparation."
  assert j.commit_ready(claim, compile_ready(original.key))
    == Ok(j.Prepared(compile_ready(original.key)))
  claim
}

fn prepared_command(original: j.Input) -> wire.Prepared {
  let assert Ok(decoded) = input.decode_compile(original.body)
    as "Exact bounded original input."
  let assert resources.CompileReady(locations) = compile_ready(original.key)
    as "Fixed allocation."
  let assert Ok(expected) =
    service_command.compile_from_input(
      enrolled(),
      original.key,
      decoded,
      locations,
      5,
    )
    as "Pure expectation without invented source admission."
  let data = offer.data(service_command.offer(expected))
  wire.Prepared(
    "physical:build",
    hash_bytes_from_hex(hash("b")),
    wire.Finite(180_000),
    exec.ExecRequest(
      data.argv,
      data.env,
      data.cwd,
      Some(data.requirements),
      <<0:size(256)>>,
      exec.PlatformEnforcement,
    ),
    wire.Logs,
  )
}

fn hash_bytes_from_hex(text: String) -> identity.Digest {
  let assert Ok(bytes) = bit_array.base16_decode(text)
    as "Full digest spelling."
  let assert Ok(hash) = identity.digest(bytes) as "Full digest bytes."
  hash
}

fn native_key(original: j.Input, number: Int) -> identity.RequestKey {
  let assert Ok(request) =
    identity.request_id(ids.entry_id_to_string(id(number)))
    as "Independent native UUID."
  identity.request_key(
    native_scope(),
    remote_tool.operation(command.parent(original.key)),
    request,
  )
}

fn encode_prepared(prepared: wire.Prepared) -> BitArray {
  let assert Ok(bytes) = wire.encode_prepared(prepared)
    as "Canonical full Prepared."
  bytes
}

fn retain_native_request(
  native: native_journal.Journal,
  key: identity.RequestKey,
  prepared: wire.Prepared,
) -> identity.Digest {
  let bytes = encode_prepared(prepared)
  let digest = hash_bytes(bytes)
  assert native_journal.put_payload(native, key, digest, payload.Request(bytes))
    == Ok(Nil)
  let assert Ok(_) = native_journal.admit(native, key, digest)
    as "Actual native journal admission."
  digest
}

fn admitted(
  native: native_journal.Journal,
  book: j.Journal,
  original: j.Input,
  number: Int,
  prepared: wire.Prepared,
) -> #(command.CommandRef, identity.RequestKey, identity.Digest, wire.Prepared) {
  let key = native_key(original, number)
  let digest = retain_native_request(native, key, prepared)
  let ref = command_ref(original)
  assert j.associate_native(book, original, ref, key, digest)
    == Ok(j.Associated(ref, key, digest, prepared))
  #(ref, key, digest, prepared)
}

fn terminal_bytes() -> BitArray {
  let exit =
    exec.ExecResult(
      0,
      0,
      100,
      200,
      False,
      False,
      ["seatbelt"],
      False,
      99,
      False,
      False,
    )
  let assert Ok(bytes) = native.encode_terminal(dispatch.Completed(exit))
    as "Exact canonical native terminal."
  bytes
}

fn native_terminal(
  native: native_journal.Journal,
  key: identity.RequestKey,
  digest: identity.Digest,
) -> BitArray {
  let assert Ok(_) =
    native_journal.apply(native, key, digest, admission.AuthorizeLaunch)
    as "Native intent."
  let bytes = terminal_bytes()
  assert native_journal.put_payload(
      native,
      key,
      digest,
      payload.Terminal(bytes),
    )
    == Ok(Nil)
  let assert Ok(_) =
    native_journal.apply(
      native,
      key,
      digest,
      admission.ObserveTerminal(hash_bytes(bytes)),
    )
    as "Settled native terminal."
  bytes
}

fn success(
  original: j.Input,
  key: identity.RequestKey,
  digest: identity.Digest,
  terminal: BitArray,
) -> completion.CompileCompletion {
  let assert resources.CompileReady(locations) = compile_ready(original.key)
    as "Original compile locations."
  let root = resources.compile_fields(locations).1
  let assert Ok(value) =
    completion.successful(
      enrolled(),
      original.key,
      locations,
      key,
      digest,
      terminal,
      compile.BuildProducts(root <> "/ebin", "sha256-" <> hash("f")),
    )
    as "Closed native-associated success."
  value
}

fn native_failure(
  original: j.Input,
  key: identity.RequestKey,
  digest: identity.Digest,
  terminal: BitArray,
  reason: String,
) -> completion.CompileCompletion {
  let assert Ok(value) =
    completion.failed_native(
      enrolled(),
      original.key,
      key,
      digest,
      terminal,
      compile.ArtifactIncomplete(reason),
    )
    as "Closed finalizer failure retaining actual terminal."
  value
}

fn limits(rows: Int, bytes: Int) -> j.Limits {
  let assert Ok(limits) = j.limits(rows, bytes) as "Finite immutable ceilings."
  limits
}

fn scope() -> cw.Scope {
  let assert Ok(scope) =
    cw.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "checkout",
      "linux",
      2,
      7,
    )
    as "Full original scope."
  scope
}

fn hash(c: String) -> String {
  string.repeat(c, 64)
}

fn base() -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    writable_roots: ["/work", "/alloc"],
    readable_roots: ["/tc", "/seed", "/work"],
    protected: ["/work/.git"],
    network: policy.NetworkOff,
    limits: policy.Limits(11, 12, 13, 14, 15, 16),
    env_allow: ["PATH", "HOME"],
    scratch: policy.ScratchTmpfs,
    mounts: [
      policy.Mount("/tc", policy.MountReadOnly, policy.MountRequired),
      policy.Mount("/seed", policy.MountReadOnly, policy.MountOptional),
    ],
  )
}

fn enrolled() -> enrollment.SessionEnrollment {
  let assert Ok(enrolled) =
    enrollment.new(
      enrollment.NativeFacts(scope(), ["/"], base(), exec.PlatformEnforcement),
      enrollment.CodeModeFacts(
        "/work",
        "/alloc/build",
        "/alloc/channel",
        "/tc/bin/gleam",
        "/tc/bin/erl",
        "/seed",
        ["/tc"],
        base().mounts,
        "/tc/bin",
      ),
      hash("b"),
      hash("c"),
    )
    as "Exact isolated trusted enrollment."
  enrolled
}

fn id(number: Int) -> ids.EntryId {
  let assert Ok(id) =
    ids.parse_entry_id(
      "00000000-0000-7000-8000-"
      <> string.pad_start(int.to_string(number), 12, "0"),
    )
    as "Original UUID."
  id
}

fn parent(
  step: String,
  index: Int,
  digest: String,
  result: Int,
) -> remote_tool.ToolKey {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Session UUID."
  let assert Ok(operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "Operation UUID."
  let assert Ok(parent) =
    remote_tool.key(session, operation, step, index, digest, id(result))
    as "Complete original managed parent."
  parent
}

fn key(
  role: command.ServiceRole,
  step: String,
  number: Int,
  parent: remote_tool.ToolKey,
  body: BitArray,
) -> command.ServiceKey {
  let assert Ok(step) = cw.step(step) as "Physical coordinate."
  let digest = string.lowercase(bit_array.base16_encode(j.digest(body)))
  let assert Ok(key) =
    command.service_key(
      parent,
      role,
      scope(),
      remote_tool.operation(parent),
      step,
      id(number),
      digest,
      hash("b"),
      hash("c"),
    )
    as "Digest-linked complete service key."
  key
}

fn compiled(source: String, number: Int) -> j.Input {
  let assert Ok(decoded) =
    input.compile_input(
      enrolled(),
      input.WorkspaceProgram,
      source,
      [],
      compile.default_dependencies(),
      base(),
      180_000,
    )
    as "Canonical compile input."
  let body = input.encode_compile(decoded)
  j.Input(
    key(
      command.CompileService,
      "physical:build",
      number,
      parent("parent", 3, hash("a"), 4),
      body,
    ),
    body,
  )
}

fn rekey(
  original: j.Input,
  step: String,
  number: Int,
  parent: remote_tool.ToolKey,
) -> j.Input {
  j.Input(
    key(command.service_role(original.key), step, number, parent, original.body),
    original.body,
  )
}

fn launched(producer: command.ServiceKey, number: Int) -> j.Input {
  let #(scope, operation, step) = command.coordinates(producer)
  let #(digest, _, contract) = command.digests(producer)
  let artifact =
    compile.ExecutorArtifact(
      scope,
      operation,
      step,
      ids.entry_id_to_string(command.request_id(producer)),
      digest,
      "issued-artifact",
      contract,
      compile.entry_module,
      "sha256-" <> hash("e"),
    )
  let assert Ok(decoded) =
    input.launch_input(
      enrolled(),
      producer,
      artifact,
      [],
      cw.root(),
      base(),
      hash("d"),
    )
    as "Canonical launch body, without successful artifact proof."
  let body = input.encode_launch(decoded)
  j.Input(
    key(
      command.LaunchService,
      "physical:run",
      number,
      command.parent(producer),
      body,
    ),
    body,
  )
}

fn compile_ready(key: command.ServiceKey) -> resources.Ready {
  let assert Ok(path) = enrollment.compile_path(enrolled(), key)
    as "Derived exact build root."
  let assert Ok(locations) =
    resources.admit_compile_locations(enrolled(), key, path)
    as "Location equality only."
  resources.CompileReady(locations)
}

fn launch_ready(
  key: command.ServiceKey,
  producer: command.ServiceKey,
) -> resources.Ready {
  let assert Ok(paths) = enrollment.launch_paths(enrolled(), key)
    as "Fixed channel locations."
  let assert Ok(resources) =
    resources.admit_launch_resources(
      enrolled(),
      key,
      producer,
      paths.0,
      paths.1,
      paths.2,
    )
    as "Full parent/location equality only."
  resources.LaunchReady(resources)
}

fn reservation(original: j.Input) -> Int {
  string.byte_size(
    remote_tool.child_address(command.service_origin(original.key)),
  )
  + string.byte_size(json.to_string(command.encode_service(original.key)))
  + bit_array.byte_size(original.body)
  + 663_826
}

fn native_scope() -> identity.Scope {
  let #(session, binding) = cw.scope_fields(scope())
  let #(selector, workspace_epoch, session_epoch) = cw.binding_fields(binding)
  let #(executor, name) = cw.selector_fields(selector)
  let assert Ok(name) = identity.workspace_id(name)
    as "Enrolled workspace label."
  let assert Ok(executor) = identity.executor_id(executor)
    as "Enrolled executor label."
  let assert Ok(session_epoch) = identity.epoch(session_epoch)
    as "Session epoch."
  let assert Ok(workspace_epoch) = identity.epoch(workspace_epoch)
    as "Workspace epoch."
  identity.scope(session, name, executor, session_epoch, workspace_epoch)
}

fn fixture(
  name: String,
  limits: j.Limits,
  run: fn(String, j.Journal, native_journal.Journal) -> Nil,
) {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let directory =
    "/tmp/loom-resource-journal-"
    <> name
    <> "-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let assert Ok(Nil) = simplifile.create_directory(directory)
    as "Isolated fixture."
  let path = directory <> "/resources.sqlite"
  let assert Ok(native_capacity) = admission.capacity(20)
    as "Native fixture capacity."
  let assert Ok(native) =
    native_journal.fresh(
      directory <> "/native.sqlite",
      native_scope(),
      native_capacity,
    )
    as "Independent native journal under the exact enrolled scope."
  let assert Ok(book) = j.fresh(path, enrolled(), limits, native)
    as "Fresh exact journal."
  run(path, book, native)
  let _ = j.release_endpoint(book)
  let _ = native_journal.release(native)
  let assert Ok(Nil) = simplifile.delete(directory)
    as "Remove test resources after endpoint closure."
  Nil
}

fn execute(path: String, text: String) {
  let assert Ok(connection) = sqlight.open(path)
    as "Trusted test corruption connection."
  assert sqlight.exec(text, connection) == Ok(Nil)
  assert sqlight.close(connection) == Ok(Nil)
}

fn stored_ready(path: String) -> Result(BitArray, resources.Error) {
  let assert Ok(connection) = sqlight.open(path)
    as "Independent evidence reader."
  let assert Ok([bytes]) =
    sqlight.query(
      "SELECT ready FROM resource_call",
      connection,
      [],
      decode.field(0, decode.bit_array, decode.success),
    )
    as "Exact retained bytes."
  assert sqlight.close(connection) == Ok(Nil)
  Ok(bytes)
}

fn normalize(source: String) -> String {
  source
  |> string.split("\n")
  |> list.filter(fn(line) { !string.starts_with(string.trim(line), "--") })
  |> string.join(" ")
  |> string.replace(";", "")
  |> string.split(" ")
  |> list.filter(fn(part) { part != "" })
  |> string.join(" ")
}
