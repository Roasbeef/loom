//// Workspace custody counterexamples across independent SQLite endpoints.
////
//// Claims are the observed execution count, independent from effect mechanics.
//// Tests retain the original bytes across lost replies and reopen; no fixture
//// reconstructs Started as permission. Corruption probes cross the SQL driver
//// through guarded header/body projections rather than a mock database.

import core/ids
import core/workspace as cw
import executor/remote/workspace_journal as j
import executor/sql
import executor/workspace_schema
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import gleam/time/timestamp
import simplifile
import sqlight
import tools/workspace as w
import tools/workspace_codec as codec
import tools/workspace_local as local
import weft

pub fn reservation_and_exact_identity_conflicts_test() {
  fixture("identity", limits(3, 100_000_000), fn(path, book) {
    let bytes = invocation(1, 1, "a")
    assert j.inspect(book, bytes) == Error(j.Missing)
    assert j.admit(book, bytes) == Ok(j.Accepted)
    assert j.admit(book, bytes) == Ok(j.Accepted)
    assert j.admit(book, invocation(1, 1, "b")) == Error(j.Conflict)
    assert j.admit(book, invocation(1, 2, "a")) == Error(j.ScopeMismatch)
    let assert Ok(other) = j.recover(path, scope(1), limits(3, 100_000_000))
      as "independent open"
    assert j.admit(other, bytes) == Ok(j.Accepted)
    assert j.release(other) == Ok(Nil)
    assert j.recover(path, scope(2), limits(3, 100_000_000))
      == Error(j.BindingMismatch)
    assert j.recover(path, scope(1), limits(4, 100_000_000))
      == Error(j.BindingMismatch)
  })
}

pub fn every_original_coordinate_and_scope_field_is_immutable_test() {
  fixture("coordinates", limits(2, 100_000_000), fn(_path, book) {
    let bytes = invocation(1, 1, "a")
    let assert Ok(call) = codec.decode_invocation(bytes) as "original call"
    let #(scope, op, step, origin, id) = w.invocation_identity(call)
    let request = w.request(call)
    let assert Ok(other_op) =
      ids.parse_op_id("00000000-0000-7000-8000-000000000099")
      as "changed operation"
    let assert Ok(other_step) = cw.step("other-step") as "changed physical step"
    let assert Ok(tool_origin) = w.tool_origin(3, <<1:size(256)>>)
      as "real tool provenance"
    assert j.admit(book, bytes) == Ok(j.Accepted)
    list.each(
      [
        w.invocation(scope, other_op, step, origin, id, request),
        w.invocation(scope, op, other_step, origin, id, request),
        w.invocation(scope, op, step, w.Tool(tool_origin), id, request),
      ],
      fn(changed) {
        let assert Ok(bytes) = codec.encode_invocation(changed)
          as "changed canonical input"
        assert j.admit(book, bytes) == Error(j.Conflict)
      },
    )
    list.each(
      [
        #("00000000-0000-7000-8000-000000000099", "loom", "dev", 1, 1),
        #("00000000-0000-7000-8000-000000000001", "other", "dev", 1, 1),
        #("00000000-0000-7000-8000-000000000001", "loom", "other", 1, 1),
        #("00000000-0000-7000-8000-000000000001", "loom", "dev", 2, 1),
        #("00000000-0000-7000-8000-000000000001", "loom", "dev", 1, 2),
      ],
      fn(fields) {
        let #(session, workspace, executor, session_epoch, workspace_epoch) =
          fields
        let assert Ok(changed) =
          cw.scope_from_fields(
            session,
            workspace,
            executor,
            session_epoch,
            workspace_epoch,
          )
          as "changed scope"
        let assert Ok(bytes) =
          codec.encode_invocation(w.invocation(
            changed,
            op,
            step,
            origin,
            id,
            request,
          ))
          as "scope canonical input"
        assert j.admit(book, bytes) == Error(j.ScopeMismatch)
      },
    )
  })
}

pub fn started_recovery_never_recreates_a_claim_test() {
  fixture("started", limits(2, 100_000_000), fn(path, book) {
    let bytes = invocation(1, 1, "a")
    assert j.admit(book, bytes) == Ok(j.Accepted)
    let assert Ok(j.Claimed(claim)) = j.claim(book, bytes) as "one live claim"
    assert codec.encode_invocation(j.invocation(claim)) == Ok(bytes)
    assert j.claim(book, bytes) == Ok(j.Existing(j.Unknown))
    assert j.cancel(book, bytes) == Ok(j.Unknown)
    assert j.release(book) == Ok(Nil)
    let assert Ok(recovered) = j.recover(path, scope(1), limits(2, 100_000_000))
      as "restart does not reset Started"
    assert j.admit(recovered, bytes) == Ok(j.Unknown)
    assert j.claim(recovered, bytes) == Ok(j.Existing(j.Unknown))
    assert j.finish(claim, completion("a")) == Error(j.Closed)
    assert j.release(recovered) == Ok(Nil)
  })
}

pub fn lost_finished_reply_replays_exact_bytes_and_ack_keeps_fence_test() {
  fixture("finished", limits(2, 100_000_000), fn(path, book) {
    let bytes = invocation(1, 1, "a")
    let result = completion("a")
    assert j.admit(book, bytes) == Ok(j.Accepted)
    let assert Ok(j.Claimed(claim)) = j.claim(book, bytes) as "first claim"
    assert j.finish(claim, result) == Ok(j.Finished(result))
    assert j.finish(claim, result) == Ok(j.Finished(result))
    assert j.finish(claim, completion("b")) == Error(j.Conflict)
    assert j.acknowledge(book, bytes, <<0:size(256)>>) == Error(j.Conflict)
    assert sizes(path).0 > 0
    assert sizes(path).1 > 0
    assert j.release(book) == Ok(Nil)
    let assert Ok(recovered) = j.recover(path, scope(1), limits(2, 100_000_000))
      as "exact completion survives lost reply"
    assert j.inspect(recovered, bytes) == Ok(j.Finished(result))
    assert j.claim(recovered, bytes) == Ok(j.Existing(j.Finished(result)))
    assert j.acknowledge(recovered, bytes, j.digest(result))
      == Ok(j.Acknowledged(j.digest(result)))
    assert sizes(path) == #(0, 0, 1)
    assert j.admit(recovered, bytes) == Ok(j.Acknowledged(j.digest(result)))
    assert j.claim(recovered, bytes)
      == Ok(j.Existing(j.Acknowledged(j.digest(result))))
    assert j.admit(recovered, invocation(1, 1, "different"))
      == Error(j.Conflict)
    assert j.acknowledge(recovered, bytes, <<0:size(256)>>) == Error(j.Conflict)
    assert j.release(recovered) == Ok(Nil)
    let assert Ok(final) = j.recover(path, scope(1), limits(2, 100_000_000))
      as "tombstone survives reopen"
    assert j.claim(final, bytes)
      == Ok(j.Existing(j.Acknowledged(j.digest(result))))
    assert j.release(final) == Ok(Nil)
  })
}

pub fn independent_endpoints_race_one_execution_permission_test() {
  fixture("race", limits(2, 100_000_000), fn(path, book) {
    let bytes = invocation(1, 1, "a")
    assert j.admit(book, bytes) == Ok(j.Accepted)
    let assert Ok(other) = j.recover(path, scope(1), limits(2, 100_000_000))
      as "second database actor"
    let outcomes =
      [book, other]
      |> list.map(fn(endpoint) { fn() { j.claim(endpoint, bytes) } })
      |> weft.new
      |> weft.limit(2)
      |> weft.deadline(5000)
      |> weft.start
    let results = weft.values(outcomes)
    assert list.length(results) == 2
    let claims =
      list.filter(results, fn(answer) {
        case answer {
          j.Claimed(_) -> True
          _ -> False
        }
      })
    assert list.length(claims) == 1
    assert list.contains(results, j.Existing(j.Unknown))
    assert j.release(other) == Ok(Nil)
  })
}

pub fn full_completion_reservation_prevents_effect_admission_test() {
  let bytes = invocation(1, 1, "a")
  let required = codec.max_completion_bytes + bit_array.byte_size(bytes)
  fixture("bytes", limits(2, required - 1), fn(_path, book) {
    assert j.admit(book, bytes) == Error(j.Capacity)
    assert j.claim(book, bytes) == Error(j.Missing)
  })
  fixture("reclaim", limits(1, required), fn(_path, book) {
    assert j.admit(book, bytes) == Ok(j.Accepted)
    let assert Ok(j.Claimed(claim)) = j.claim(book, bytes) as "fits exactly"
    let result = completion("a")
    assert j.finish(claim, result) == Ok(j.Finished(result))
    assert j.acknowledge(book, bytes, j.digest(result))
      == Ok(j.Acknowledged(j.digest(result)))

    // Freed bytes never free a lifetime identity slot.
    assert j.admit(book, invocation(2, 1, "b")) == Error(j.Capacity)
  })
}

pub fn cancellation_fences_claims_before_effects_test() {
  fixture("cancel", limits(2, 100_000_000), fn(path, book) {
    let bytes = invocation(1, 1, "a")
    assert j.admit(book, bytes) == Ok(j.Accepted)
    assert j.cancel(book, bytes) == Ok(j.Cancelled)
    assert j.cancel(book, bytes) == Ok(j.Cancelled)
    assert j.claim(book, bytes) == Ok(j.Existing(j.Cancelled))
    assert j.acknowledge(book, bytes, <<0:size(256)>>) == Error(j.Conflict)
    assert j.release(book) == Ok(Nil)
    let assert Ok(recovered) = j.recover(path, scope(1), limits(2, 100_000_000))
      as "cancelled fence survives"
    assert j.claim(recovered, bytes) == Ok(j.Existing(j.Cancelled))
    assert j.release(recovered) == Ok(Nil)
  })
}

pub fn malformed_and_wrong_kind_bytes_never_enter_custody_test() {
  fixture("invalid", limits(2, 100_000_000), fn(path, book) {
    assert j.admit(book, <<1:size(1)>>) == Error(j.InvalidInput)
    assert j.admit(book, <<0xc0>>) == Error(j.InvalidInput)
    assert j.acknowledge(book, invocation(1, 1, "a"), <<0:size(255)>>)
      == Error(j.InvalidInput)
    assert sizes(path) == #(0, 0, 0)
    let bytes = invocation(1, 1, "a")
    assert j.admit(book, bytes) == Ok(j.Accepted)
    let assert Ok(j.Claimed(claim)) = j.claim(book, bytes) as "read request"
    let assert Ok(wrong) =
      codec.encode_completion(
        w.Initialize,
        Ok(local.Completed(w.InitializationCompleted(Ok(w.Initialized)), None)),
      )
      as "valid completion for wrong operation"
    assert j.finish(claim, wrong) == Error(j.InvalidInput)
    assert j.inspect(book, bytes) == Ok(j.Unknown)
  })
}

pub fn oversized_and_wrong_type_columns_poison_without_body_decode_test() {
  list.each(
    [
      "UPDATE workspace_call SET request=zeroblob(9437185)",
      "UPDATE workspace_call SET request_size=zeroblob(40000000)",
      "UPDATE workspace_call SET result=zeroblob(33554433)",
      "UPDATE workspace_call SET request_digest=zeroblob(40000000)",
      "UPDATE workspace_call SET phase='invalid'",
      "UPDATE workspace_meta SET binding=zeroblob(40000000)",
    ],
    fn(sql) {
      fixture("corrupt", limits(2, 100_000_000), fn(path, book) {
        let bytes = invocation(1, 1, "a")
        assert j.admit(book, bytes) == Ok(j.Accepted)
        execute(path, "PRAGMA ignore_check_constraints=ON; " <> sql)
        assert j.inspect(book, bytes) == Error(j.Corrupt)
        assert j.recover(path, scope(1), limits(2, 100_000_000))
          == Error(j.Corrupt)
      })
    },
  )
}

pub fn bounded_bodies_still_require_original_digests_and_codec_kinds_test() {
  list.each(
    [
      "UPDATE workspace_call SET request_digest=zeroblob(32)",
      "UPDATE workspace_call SET result_digest=zeroblob(32)",
      "UPDATE workspace_call SET result=X'c0',result_size=1",
      "UPDATE workspace_call SET phase=0",
    ],
    fn(sql) {
      fixture("content-corrupt", limits(2, 100_000_000), fn(path, book) {
        let bytes = invocation(1, 1, "a")
        assert j.admit(book, bytes) == Ok(j.Accepted)
        let assert Ok(j.Claimed(claim)) = j.claim(book, bytes)
          as "original claim"
        let result = completion("a")
        assert j.finish(claim, result) == Ok(j.Finished(result))
        assert j.release(book) == Ok(Nil)
        execute(path, sql)
        assert j.recover(path, scope(1), limits(2, 100_000_000))
          == Error(j.Corrupt)
      })
    },
  )
}

pub fn failed_claim_update_never_grants_execution_permission_test() {
  fixture("suppressed-update", limits(2, 100_000_000), fn(path, book) {
    let bytes = invocation(1, 1, "a")
    assert j.admit(book, bytes) == Ok(j.Accepted)

    // Even a damaged schema that suppresses the write must not return Claimed.
    execute(
      path,
      "CREATE TRIGGER suppress_claim BEFORE UPDATE ON workspace_call WHEN NEW.phase=1 BEGIN SELECT RAISE(IGNORE); END",
    )
    assert j.claim(book, bytes) == Error(j.Uncertain)
    let assert Ok(recovered) = j.recover(path, scope(1), limits(2, 100_000_000))
      as "original accepted reservation remains"
    assert j.inspect(recovered, bytes) == Ok(j.Accepted)
    assert j.claim(recovered, bytes) == Error(j.Uncertain)
  })
}

pub fn schema_and_named_queries_match_generated_artifacts_test() {
  let assert Ok(schema) = simplifile.read("sql/workspace.sql")
    as "schema source"
  assert schema == workspace_schema.schema
  let assert Ok(source) = simplifile.read("src/executor/sql/workspace.sql")
    as "named SQL source"
  let generated = [
    sql.initialize_workspace(<<>>, 1, 1).0,
    sql.workspace_metadata().0,
    sql.workspace_headers(1).0,
    sql.workspace_bodies(<<>>).0,
    sql.insert_workspace(<<>>, <<>>, 1, <<>>).0,
    sql.claim_workspace(<<>>).0,
    sql.finish_workspace(<<>>, 1, <<>>, <<>>).0,
    sql.acknowledge_workspace(<<>>).0,
    sql.cancel_workspace(<<>>).0,
  ]
  assert normalize(source) == normalize(string.join(generated, "\n"))
}

fn scope(epoch: Int) -> cw.Scope {
  let assert Ok(scope) =
    cw.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "loom",
      "dev",
      epoch,
      epoch,
    )
    as "valid full scope"
  scope
}

fn limits(rows: Int, bytes: Int) -> j.Limits {
  let assert Ok(limits) = j.limits(rows, bytes) as "finite limits"
  limits
}

fn invocation(number: Int, epoch: Int, path: String) -> BitArray {
  let assert Ok(id) =
    ids.parse_entry_id(
      "00000000-0000-7000-8000-"
      <> string.pad_start(int.to_string(number), 12, "0"),
    )
    as "request UUID"
  let assert Ok(op) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "operation UUID"
  let assert Ok(step) = cw.step("real-step") as "original step"
  let assert Ok(path) = cw.relative_path(path) as "bounded relative path"
  let assert Ok(bytes) =
    codec.encode_invocation(w.invocation(
      scope(epoch),
      op,
      step,
      w.System(w.WorktreeObservation),
      id,
      w.Read(path, w.Text),
    ))
    as "canonical invocation"
  bytes
}

fn completion(text: String) -> BitArray {
  let assert Ok(path) = cw.relative_path("a") as "read path"
  let assert Ok(bytes) =
    codec.encode_completion(
      w.Read(path, w.Text),
      Ok(local.Completed(w.ReadCompleted(Ok(w.TextRead(text))), None)),
    )
    as "canonical read completion"
  bytes
}

fn fixture(name: String, limits: j.Limits, run: fn(String, j.Journal) -> Nil) {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let directory =
    "/tmp/loom-workspace-journal-"
    <> name
    <> "-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let assert Ok(Nil) = simplifile.create_directory(directory)
    as "fixture directory"
  let path = directory <> "/custody.sqlite"
  let assert Ok(book) = j.fresh(path, scope(1), limits) as "fresh journal"
  run(path, book)
  let _ = j.release(book)
  let assert Ok(Nil) = simplifile.delete(directory) as "remove fixture"
  Nil
}

fn execute(path: String, text: String) {
  let assert Ok(connection) = sqlight.open(path) as "corruption connection"
  assert sqlight.exec(text, connection) == Ok(Nil)
  assert sqlight.close(connection) == Ok(Nil)
}

fn sizes(path: String) -> #(Int, Int, Int) {
  let assert Ok(connection) = sqlight.open(path) as "inspection connection"
  let decoder = {
    use request <- decode.field(0, decode.int)
    use result <- decode.field(1, decode.int)
    use count <- decode.field(2, decode.int)
    decode.success(#(request, result, count))
  }
  let assert Ok([sizes]) =
    sqlight.query(
      "SELECT COALESCE(SUM(length(request)),0),COALESCE(SUM(length(result)),0),COUNT(*) FROM workspace_call",
      connection,
      [],
      decoder,
    )
    as "payload size aggregate"
  assert sqlight.close(connection) == Ok(Nil)
  sizes
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
