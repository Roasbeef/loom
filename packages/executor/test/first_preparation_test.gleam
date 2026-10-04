//// Original preparation admission and cancellation use one SQLite transaction.
//// These controls observe actual committed phases across independent opens.
//// Managed peers are joined before their results become test evidence.

import broker/command as offer
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
import executor/remote/identity
import executor/remote/journal as native_journal
import executor/remote/payload
import executor/remote/resource_journal as j
import executor/remote/wire
import executor/sql
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import simplifile
import sqlight
import weft

type Racing {
  Admitted(j.FirstAdmission)
  Fenced(j.PreparationFence)
}

pub fn independent_opens_issue_only_one_first_claim_test() {
  fixture("first-race", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let assert Ok(other) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "Independent writer."
    let values =
      [book, other]
      |> list.map(fn(endpoint) {
        fn() { j.admit_preparation(endpoint, original) }
      })
      |> weft.new
      |> weft.limit(2)
      |> weft.deadline(5000)
      |> weft.start
      |> weft.values
    assert list.length(values) == 2
    let claims =
      list.filter_map(values, fn(value) {
        case value {
          j.FreshClaim(claim) -> Ok(claim)
          j.Retained(_) -> Error(Nil)
        }
      })
    let assert [claim] = claims
      as "One insertion issued the only original Claim."
    assert j.original(claim) == original
    assert list.contains(values, j.Retained(j.Unknown(None)))
    assert j.admit_preparation(other, original)
      == Ok(j.Retained(j.Unknown(None)))
    assert stored_phase(path) == 1
    assert j.release_endpoint(other) == Ok(Nil)
  })
}

pub fn retained_reserved_never_becomes_new_first_admission_test() {
  fixture("old-reserved", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, original) == Ok(j.Reserved)
    assert j.admit_preparation(book, original) == Ok(j.Retained(j.Reserved))
    assert j.release_endpoint(book) == Ok(Nil)
    let assert Ok(reopened) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "Historical unclaimed reservation."
    assert j.admit_preparation(reopened, original) == Ok(j.Retained(j.Reserved))
    assert stored_phase(path) == 0

    // Explicit trusted component claim behavior remains available separately.
    let assert Ok(j.Claimed(_)) = j.claim_preparation(reopened, original)
      as "Existing explicit API is unchanged."
    assert j.admit_preparation(reopened, original)
      == Ok(j.Retained(j.Unknown(None)))
    assert j.release_endpoint(reopened) == Ok(Nil)
  })
}

pub fn ignored_first_reply_recovers_history_without_authority_test() {
  fixture("ignored-first", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let _ignored = j.admit_preparation(book, original)
    assert stored_phase(path) == 1
    assert j.release_endpoint(book) == Ok(Nil)
    let assert Ok(reopened) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "Only durable state survives the lost reply."
    assert j.admit_preparation(reopened, original)
      == Ok(j.Retained(j.Unknown(None)))
    assert j.release_endpoint(reopened) == Ok(Nil)
  })
}

pub fn cancellation_before_submit_retains_unknown_and_no_claim_test() {
  fixture("cancel-first", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.fence_preparation(book, original)
      == Ok(j.InputFenced(j.Unknown(None)))
    assert stored_phase(path) == 3
    assert j.admit_preparation(book, original)
      == Ok(j.Retained(j.Unknown(None)))
    assert j.claim_preparation(book, original)
      == Ok(j.Existing(j.Unknown(None)))
    assert j.release_endpoint(book) == Ok(Nil)
    let assert Ok(reopened) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "Missing-row cancellation committed the permanent original fence."
    assert j.fence_preparation(reopened, original)
      == Ok(j.InputFenced(j.Unknown(None)))
    assert j.admit_preparation(reopened, original)
      == Ok(j.Retained(j.Unknown(None)))
    assert j.release_endpoint(reopened) == Ok(Nil)
  })
}

pub fn reserved_cancellation_reaches_phase_zero_guard_test() {
  fixture("cancel-reserved", limits(2, 30_000_000), fn(path, book, _native) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, original) == Ok(j.Reserved)
    assert stored_phase(path) == 0
    assert j.fence_preparation(book, original)
      == Ok(j.InputFenced(j.Unknown(None)))
    assert stored_phase(path) == 3
    assert j.admit_preparation(book, original)
      == Ok(j.Retained(j.Unknown(None)))
  })
}

pub fn admission_and_fence_race_serialize_two_legal_histories_test() {
  fixture("admit-cancel-race", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let assert Ok(other) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "Independent cancellation writer."
    let values =
      [
        fn() { j.admit_preparation(book, original) |> result.map(Admitted) },
        fn() { j.fence_preparation(other, original) |> result.map(Fenced) },
      ]
      |> weft.new
      |> weft.limit(2)
      |> weft.deadline(5000)
      |> weft.start
      |> weft.values
    assert list.length(values) == 2
    assert list.contains(values, Fenced(j.InputFenced(j.Unknown(None))))
    let assert Ok(first) =
      list.find(values, fn(value) {
        case value {
          Admitted(_) -> True
          Fenced(_) -> False
        }
      })
      as "The joined admission result is observed directly."
    let assert Admitted(admitted) = first
    case admitted {
      j.FreshClaim(claim) -> {
        assert j.original(claim) == original
        assert j.commit_ready(claim, compile_ready(original.key))
          == Error(j.Conflict)
      }
      j.Retained(status) -> {
        assert status == j.Unknown(None)
      }
    }
    assert stored_phase(path) == 3
    assert j.admit_preparation(book, original)
      == Ok(j.Retained(j.Unknown(None)))
    assert j.release_endpoint(other) == Ok(Nil)
  })
}

pub fn ready_fence_blocks_live_association_and_preserves_receipt_test() {
  fixture("ready-fence", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let assert Ok(j.FreshClaim(claim)) = j.admit_preparation(book, original)
      as "First live continuation."
    let ready = compile_ready(original.key)
    assert j.commit_ready(claim, ready) == Ok(j.Prepared(ready))
    assert j.admit_preparation(book, original)
      == Ok(j.Retained(j.Prepared(ready)))
    let key = native_key(original, 8)
    let prepared = prepared_command(original)
    let digest = retain_live_request(native, key, prepared)
    assert j.fence_preparation(book, original)
      == Ok(j.InputFenced(j.Unknown(Some(ready))))
    assert j.commit_ready(claim, ready) == Error(j.Conflict)
    assert j.associate_live_native(claim, command_ref(original), key, digest)
      == Error(j.Conflict)
    assert j.inspect_native(book, original) == Ok(j.Unassociated)
    assert j.admit_preparation(book, original)
      == Ok(j.Retained(j.Unknown(Some(ready))))
    assert j.mark_released(book, original, j.ResourceOwnerCleaned)
      == Ok(j.Released(Some(ready)))
    assert j.fence_preparation(book, original)
      == Ok(j.InputFenced(j.Released(Some(ready))))
    assert j.admit_preparation(book, original)
      == Ok(j.Retained(j.Released(Some(ready))))
    assert j.release_endpoint(book) == Ok(Nil)
    let assert Ok(reopened) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "Original receipt survives permanent fence and cleanup."
    assert j.inspect(reopened, original) == Ok(j.Released(Some(ready)))
    assert j.release_endpoint(reopened) == Ok(Nil)
  })
}

pub fn preparing_fence_blocks_late_ready_and_sealed_existing_is_compared_test() {
  fixture("preparing-fence", limits(2, 30_000_000), fn(path, book, _native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let assert Ok(j.FreshClaim(claim)) = j.admit_preparation(book, original)
      as "Preparing is durable before fence."
    assert j.seal(book) == Ok(j.SealedScope)
    assert j.fence_preparation(book, compiled("pub fn main() { 1 }", 3))
      == Error(j.Conflict)
    assert stored_phase(path) == 1
    assert j.fence_preparation(book, original)
      == Ok(j.InputFenced(j.Unknown(None)))
    assert j.commit_ready(claim, compile_ready(original.key))
      == Error(j.Conflict)
    assert stored_phase(path) == 3
  })
}

pub fn sealed_missing_returns_scope_disposition_without_row_or_capacity_test() {
  fixture("sealed-absent", limits(1, 1), fn(path, book, _native) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.seal(book) == Ok(j.SealedScope)
    assert j.fence_preparation(book, original) == Ok(j.ScopeFenced)
    assert row_count(path) == 0
    assert j.inspect(book, original) == Error(j.Missing)
    assert j.admit_preparation(book, original) == Error(j.Sealed)
  })
}

pub fn full_conflicts_refuse_even_sealed_and_address_collision_is_not_scope_fence_test() {
  fixture("exact-fences", limits(3, 30_000_000), fn(path, book, _native) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, original) == Ok(j.Reserved)
    assert j.seal(book) == Ok(j.SealedScope)
    let changes = [
      compiled("pub fn main() { 1 }", 3),
      compiled("pub fn main() { Nil }", 5),
      rekey(original, "changed:physical", 3, parent("parent", 3, hash("a"), 4)),
      rekey(original, "physical:build", 3, parent("parent", 3, hash("f"), 4)),
      rekey(original, "physical:build", 3, parent("parent", 3, hash("a"), 6)),
      rekey(
        original,
        "physical:build",
        3,
        parent("other-parent", 3, hash("a"), 4),
      ),
    ]
    list.each(changes, fn(changed) {
      assert j.admit_preparation(book, changed) == Error(j.Conflict)
      assert j.fence_preparation(book, changed) == Error(j.Conflict)
    })
    assert stored_phase(path) == 0
    assert j.admit_preparation(book, original) == Ok(j.Retained(j.Reserved))
    assert j.fence_preparation(book, original)
      == Ok(j.InputFenced(j.Unknown(None)))
  })
}

pub fn failed_commit_never_issues_claim_or_successful_fence_test() {
  list.each([1, 3], fn(phase) {
    fixture(
      "failed-commit-" <> int.to_string(phase),
      limits(2, 30_000_000),
      fn(path, book, native) {
        execute(
          path,
          "CREATE TABLE parent(id INTEGER PRIMARY KEY); CREATE TABLE child(id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fail_commit AFTER UPDATE ON resource_call WHEN NEW.phase="
            <> int.to_string(phase)
            <> " BEGIN INSERT INTO child VALUES(1); END",
        )
        let original = compiled("pub fn main() { Nil }", 3)
        case phase {
          1 -> {
            assert j.admit_preparation(book, original) == Error(j.Uncertain)
          }
          3 -> {
            assert j.fence_preparation(book, original) == Error(j.Uncertain)
          }
          _ -> panic as "Closed fixture phases."
        }
        let assert Ok(reopened) =
          j.recover(path, enrolled(), limits(2, 30_000_000), native)
          as "Uncommitted insertion and phase are absent."
        assert j.inspect(reopened, original) == Error(j.Missing)
        assert row_count(path) == 0
        assert j.release_endpoint(reopened) == Ok(Nil)
      },
    )
  })
}

pub fn suppressed_phase_never_acknowledges_and_rolls_back_new_identity_test() {
  fixture("suppress-fence", limits(2, 30_000_000), fn(path, book, native) {
    execute(
      path,
      "CREATE TRIGGER suppress_fence BEFORE UPDATE ON resource_call WHEN NEW.phase=3 BEGIN SELECT RAISE(IGNORE); END",
    )
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.fence_preparation(book, original) == Error(j.Uncertain)
    let assert Ok(reopened) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "A suppressed transition does not leave its inserted reservation."
    assert j.inspect(reopened, original) == Error(j.Missing)
    assert row_count(path) == 0
    assert j.release_endpoint(reopened) == Ok(Nil)
  })
}

pub fn missing_fences_use_full_capacity_and_never_refund_it_test() {
  let original = compiled("pub fn main() { Nil }", 3)
  let required = reservation(original)
  fixture("short-fence", limits(2, required - 1), fn(path, book, _native) {
    assert j.fence_preparation(book, original) == Error(j.Capacity)
    assert j.admit_preparation(book, original) == Error(j.Capacity)
    assert row_count(path) == 0
  })
  fixture("exact-fence", limits(1, required), fn(path, book, _native) {
    assert j.fence_preparation(book, original)
      == Ok(j.InputFenced(j.Unknown(None)))
    let other =
      rekey(
        original,
        "physical:build",
        5,
        parent("other-parent", 3, hash("a"), 4),
      )
    assert j.fence_preparation(book, other) == Error(j.Capacity)
    assert j.admit_preparation(book, other) == Error(j.Capacity)
    assert row_count(path) == 1
  })
}

pub fn malformed_oversized_and_wrong_digest_input_refuse_before_rows_test() {
  fixture("invalid-first", limits(2, 30_000_000), fn(path, book, _native) {
    let original = compiled("pub fn main() { Nil }", 3)
    list.each(
      [<<>>, <<original.body:bits, 0>>, <<0:size(75_497_480)>>],
      fn(body) {
        let invalid = j.Input(original.key, body)
        assert j.admit_preparation(book, invalid) == Error(j.InvalidInput)
        assert j.fence_preparation(book, invalid) == Error(j.InvalidInput)
      },
    )
    let changed = compiled("pub fn main() { 1 }", 3)
    let invalid = j.Input(original.key, changed.body)
    assert j.admit_preparation(book, invalid) == Error(j.InvalidInput)
    assert j.fence_preparation(book, invalid) == Error(j.InvalidInput)
    assert row_count(path) == 0
  })
}

pub fn named_fence_query_matches_source_and_returns_actual_phase_test() {
  let assert Ok(source) = simplifile.read("src/executor/sql/resources.sql")
    as "Named query source."
  assert string.contains(source, sql.fence_resource_preparation(<<>>).0)
  fixture("query-phase", limits(2, 30_000_000), fn(path, book, _native) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, original) == Ok(j.Reserved)
    let assert Ok(connection) = sqlight.open(path)
      as "Direct generated transition control."
    let #(text, _params, decoder) =
      sql.fence_resource_preparation(
        bit_array.from_string(
          ids.entry_id_to_string(command.request_id(original.key)),
        ),
      )
    let assert Ok([sql.FenceResourcePreparation(3)]) =
      sqlight.query(
        text,
        connection,
        [
          sqlight.blob(
            bit_array.from_string(
              ids.entry_id_to_string(command.request_id(original.key)),
            ),
          ),
        ],
        decoder,
      )
      as "The phase-zero row reaches the new named SQL predicate."
    assert sqlight.close(connection) == Ok(Nil)
    assert stored_phase(path) == 3
  })
}

pub fn failed_existing_ready_fence_commit_preserves_ready_test() {
  fixture("ready-failed-fence", limits(2, 30_000_000), fn(path, book, native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let assert Ok(j.FreshClaim(claim)) = j.admit_preparation(book, original)
      as "Original live preparation."
    let ready = compile_ready(original.key)
    assert j.commit_ready(claim, ready) == Ok(j.Prepared(ready))
    execute(
      path,
      "CREATE TABLE parent(id INTEGER PRIMARY KEY); CREATE TABLE child(id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fail_fence_commit AFTER UPDATE ON resource_call WHEN NEW.phase=3 BEGIN INSERT INTO child VALUES(1); END",
    )
    assert j.fence_preparation(book, original) == Error(j.Uncertain)
    let assert Ok(reopened) =
      j.recover(path, enrolled(), limits(2, 30_000_000), native)
      as "Failed cancellation COMMIT cannot assert a durable fence."
    assert j.inspect(reopened, original) == Ok(j.Prepared(ready))
    assert stored_phase(path) == 2
    assert j.release_endpoint(reopened) == Ok(Nil)
  })
}

pub fn association_before_new_fence_retains_in_flight_native_tuple_test() {
  fixture(
    "association-first-fence",
    limits(2, 30_000_000),
    fn(_path, book, native) {
      let original = compiled("pub fn main() { Nil }", 3)
      let assert Ok(j.FreshClaim(claim)) = j.admit_preparation(book, original)
        as "Original live preparation."
      let ready = compile_ready(original.key)
      assert j.commit_ready(claim, ready) == Ok(j.Prepared(ready))
      let prepared = prepared_command(original)
      let key = native_key(original, 8)
      let digest = retain_live_request(native, key, prepared)
      let ref = command_ref(original)
      let assert Ok(permit) = j.associate_live_native(claim, ref, key, digest)
        as "Association wins before cancellation."
      assert j.fence_preparation(book, original)
        == Ok(j.InputFenced(j.Unknown(Some(ready))))
      assert j.inspect_native(book, original)
        == Ok(j.Associated(ref, key, digest, prepared))
      assert j.native_launch_binding(permit) == #(book, ref, key, digest)

      // The fence preserves committed native eligibility as in-flight evidence.
      let assert Ok(decision) =
        native_journal.apply(native, key, digest, admission.AuthorizeLaunch)
        as "Native reducer owns the separate at-most-once effect."
      let assert admission.Launch(_) = decision.effect
        as "Cancellation cannot pretend the earlier association never happened."
      Nil
    },
  )
}

pub fn changed_registration_binding_refuses_before_row_insertion_test() {
  fixture("wrong-binding-first", limits(2, 30_000_000), fn(path, book, _native) {
    let original = compiled("pub fn main() { Nil }", 3)
    let #(scope, operation, step) = command.coordinates(original.key)
    let #(digest, _, contract) = command.digests(original.key)
    let assert Ok(changed) =
      command.service_key(
        command.parent(original.key),
        command.CompileService,
        scope,
        operation,
        step,
        command.request_id(original.key),
        digest,
        hash("d"),
        contract,
      )
      as "Syntactically valid foreign registration evidence."
    let foreign = j.Input(changed, original.body)
    assert j.admit_preparation(book, foreign) == Error(j.InvalidInput)
    assert j.fence_preparation(book, foreign) == Error(j.InvalidInput)
    assert row_count(path) == 0
  })
}

fn stored_phase(path: String) -> Int {
  scalar(path, "SELECT phase FROM resource_call")
}

fn row_count(path: String) -> Int {
  scalar(path, "SELECT count(*) FROM resource_call")
}

fn scalar(path: String, text: String) -> Int {
  let assert Ok(connection) = sqlight.open(path)
    as "Independent committed state reader."
  let assert Ok([value]) =
    sqlight.query(
      text,
      connection,
      [],
      decode.field(0, decode.int, decode.success),
    )
    as "One scalar value."
  assert sqlight.close(connection) == Ok(Nil)
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

fn compile_ready(key: command.ServiceKey) -> resources.Ready {
  let assert Ok(path) = enrollment.compile_path(enrolled(), key)
    as "Derived exact build root."
  let assert Ok(locations) =
    resources.admit_compile_locations(enrolled(), key, path)
    as "Location equality only."
  resources.CompileReady(locations)
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

fn hash_bytes(bytes: BitArray) -> identity.Digest {
  let assert Ok(hash) = wire.digest(bytes) as "Canonical SHA-256 evidence."
  hash
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
