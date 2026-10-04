//// SQLite preparation custody controls, observing returned claims as effects.
//// No fixture creates resources or treats historical Ready as a live lease.

import broker/enrollment
import broker/exec
import broker/policy
import codemode/compile
import codemode/service_input as input
import codemode/service_resources as resources
import core/command
import core/ids
import core/json
import core/remote_tool
import core/workspace as cw
import executor/remote/resource_journal as j
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
  fixture("fences", limits(4, 30_000_000), fn(_path, book) {
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
  fixture("race", limits(3, 30_000_000), fn(path, book) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, original) == Ok(j.Reserved)
    let assert Ok(other) = j.recover(path, enrolled(), limits(3, 30_000_000))
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
  fixture("restart", limits(3, 30_000_000), fn(path, book) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, original) == Ok(j.Reserved)
    assert j.release_endpoint(book) == Ok(Nil)
    let assert Ok(reserved) = j.recover(path, enrolled(), limits(3, 30_000_000))
      as "Reserved recovers before any claim."
    assert j.inspect(reserved, original) == Ok(j.Reserved)
    let assert Ok(j.Claimed(claim)) = j.claim_preparation(reserved, original)
      as "Exactly one live permission after COMMIT."
    assert j.original(claim) == original
    assert j.release_endpoint(reserved) == Ok(Nil)
    let assert Ok(unknown) = j.recover(path, enrolled(), limits(3, 30_000_000))
      as "Preparing recovery has no live permission."
    assert j.reserve(unknown, original) == Ok(j.Unknown(None))
    assert j.claim_preparation(unknown, original)
      == Ok(j.Existing(j.Unknown(None)))
    assert j.commit_ready(claim, compile_ready(original.key)) == Error(j.Closed)
    assert j.release_endpoint(unknown) == Ok(Nil)
  })
}

pub fn prepared_unknown_and_released_retain_exact_historical_ready_test() {
  fixture("ready", limits(2, 30_000_000), fn(path, book) {
    let original = compiled("pub fn main() { Nil }", 3)
    let ready = compile_ready(original.key)
    assert j.reserve(book, original) == Ok(j.Reserved)
    let assert Ok(j.Claimed(claim)) = j.claim_preparation(book, original)
      as "Live preparation."
    assert j.commit_ready(claim, ready) == Ok(j.Prepared(ready))
    assert j.commit_ready(claim, ready) == Ok(j.Prepared(ready))
    let assert Ok(observer) = j.recover(path, enrolled(), limits(2, 30_000_000))
      as "Ready is historical on another connection."
    assert j.inspect(observer, original) == Ok(j.Prepared(ready))
    assert j.claim_preparation(observer, original)
      == Ok(j.Existing(j.Prepared(ready)))
    assert j.mark_unknown(observer, original) == Ok(j.Unknown(Some(ready)))
    assert j.commit_ready(claim, ready) == Error(j.Conflict)
    assert j.release_endpoint(observer) == Ok(Nil)
    let assert Ok(unknown) = j.recover(path, enrolled(), limits(2, 30_000_000))
      as "Uncertainty retains immutable location bytes."
    assert j.inspect(unknown, original) == Ok(j.Unknown(Some(ready)))
    assert j.mark_released(unknown, original, j.ResourceOwnerCleaned)
      == Ok(j.Released(Some(ready)))
    assert j.release_endpoint(unknown) == Ok(Nil)
    let assert Ok(released) = j.recover(path, enrolled(), limits(2, 30_000_000))
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
  fixture("empty", limits(2, 30_000_000), fn(path, book) {
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
      j.recover(path, enrolled(), limits(2, 30_000_000))
      as "No historical Ready exists."
    assert j.inspect(recovered, original) == Ok(j.Released(None))
    assert j.release_endpoint(recovered) == Ok(Nil)
  })
}

pub fn ready_must_match_full_key_and_original_launch_producer_test() {
  fixture("launch", limits(4, 30_000_000), fn(_path, book) {
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
  fixture("capacity-short", limits(2, required - 1), fn(_path, book) {
    assert j.reserve(book, original) == Error(j.Capacity)
    assert j.claim_preparation(book, original) == Error(j.Missing)
  })
  fixture("capacity-exact", limits(2, required), fn(_path, book) {
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
  fixture("capacity-distinct", limits(2, byte_allowance), fn(_path, book) {
    assert j.reserve(book, distinct) == Ok(j.Reserved)
  })
  fixture("capacity-full", limits(2, byte_allowance), fn(path, book) {
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
      j.recover(path, enrolled(), limits(2, byte_allowance))
      as "Saturated sealed evidence remains inspectable."
    assert j.reserve(recovered, original) == Ok(j.Released(Some(ready)))
    assert j.claim_preparation(recovered, original)
      == Ok(j.Existing(j.Released(Some(ready))))
    assert j.reserve(recovered, distinct) == Error(j.Sealed)
    assert j.release_endpoint(recovered) == Ok(Nil)
  })
}

pub fn seal_fences_independent_first_claim_but_not_original_ready_test() {
  fixture("seal", limits(3, 30_000_000), fn(path, book) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, original) == Ok(j.Reserved)
    let assert Ok(other) = j.recover(path, enrolled(), limits(3, 30_000_000))
      as "Independent writer."
    assert j.seal(book) == Ok(j.SealedScope)
    assert j.mode(other) == Ok(j.SealedScope)
    assert j.reserve(other, original) == Ok(j.Reserved)
    assert j.claim_preparation(other, original) == Error(j.Sealed)
    assert j.release_endpoint(other) == Ok(Nil)
  })
  fixture("late-ready", limits(2, 30_000_000), fn(_path, book) {
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
  fixture("binding", limits(2, 30_000_000), fn(path, book) {
    assert j.fresh(path, enrolled(), limits(2, 30_000_000))
      == Error(j.AlreadyExists)
    assert j.recover(path, enrolled(), limits(3, 30_000_000))
      == Error(j.BindingMismatch)
    assert j.recover(path, enrolled(), limits(2, 30_000_001))
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
    assert j.recover(path, changed, limits(2, 30_000_000))
      == Error(j.BindingMismatch)
    assert j.release_endpoint(book) == Ok(Nil)
    execute(
      path,
      "PRAGMA ignore_check_constraints=ON; UPDATE resource_meta SET format=2",
    )
    assert j.recover(path, enrolled(), limits(2, 30_000_000))
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
      fixture("corrupt", limits(2, 30_000_000), fn(path, book) {
        let original = compiled("pub fn main() { Nil }", 3)
        assert j.reserve(book, original) == Ok(j.Reserved)
        execute(path, "PRAGMA ignore_check_constraints=ON; " <> sql)
        assert j.inspect(book, original) == Error(j.Corrupt)
        assert j.recover(path, enrolled(), limits(2, 30_000_000))
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
      fixture("ready-corrupt", limits(2, 30_000_000), fn(path, book) {
        let original = compiled("pub fn main() { Nil }", 3)
        assert j.reserve(book, original) == Ok(j.Reserved)
        let assert Ok(j.Claimed(claim)) = j.claim_preparation(book, original)
          as "Original preparing row."
        assert j.commit_ready(claim, compile_ready(original.key))
          == Ok(j.Prepared(compile_ready(original.key)))
        assert j.release_endpoint(book) == Ok(Nil)
        execute(path, "PRAGMA ignore_check_constraints=ON; " <> sql)
        assert j.recover(path, enrolled(), limits(2, 30_000_000))
          == Error(j.Corrupt)
      })
    },
  )
}

pub fn suppressed_insert_and_claim_never_acknowledge_permission_test() {
  fixture("suppressed-insert", limits(2, 30_000_000), fn(path, book) {
    let original = compiled("pub fn main() { Nil }", 3)
    execute(
      path,
      "CREATE TRIGGER suppress_insert BEFORE INSERT ON resource_call BEGIN SELECT RAISE(IGNORE); END",
    )
    assert j.reserve(book, original) == Error(j.Uncertain)
    let assert Ok(recovered) =
      j.recover(path, enrolled(), limits(2, 30_000_000))
      as "No durable reservation was acknowledged."
    assert j.inspect(recovered, original) == Error(j.Missing)
    assert j.release_endpoint(recovered) == Ok(Nil)
  })
  fixture("suppressed-claim", limits(2, 30_000_000), fn(path, book) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, original) == Ok(j.Reserved)
    execute(
      path,
      "CREATE TRIGGER suppress_claim BEFORE UPDATE ON resource_call WHEN NEW.phase=1 BEGIN SELECT RAISE(IGNORE); END",
    )
    assert j.claim_preparation(book, original) == Error(j.Uncertain)
    let assert Ok(recovered) =
      j.recover(path, enrolled(), limits(2, 30_000_000))
      as "Reservation survived refused update."
    assert j.inspect(recovered, original) == Ok(j.Reserved)
    assert j.claim_preparation(recovered, original) == Error(j.Uncertain)

    // This poisoned endpoint may exit before a later close acknowledgement.
    let _ = j.release_endpoint(recovered)
    Nil
  })
}

pub fn failed_commit_never_returns_preparation_permission_test() {
  fixture("commit-failure", limits(2, 30_000_000), fn(path, book) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, original) == Ok(j.Reserved)
    execute(
      path,
      "PRAGMA foreign_keys=ON; CREATE TABLE parent(id INTEGER PRIMARY KEY); CREATE TABLE child(id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fail_commit AFTER UPDATE ON resource_call WHEN NEW.phase=1 BEGIN INSERT INTO child VALUES(1); END",
    )
    assert j.claim_preparation(book, original) == Error(j.Uncertain)
    let assert Ok(recovered) =
      j.recover(path, enrolled(), limits(2, 30_000_000))
      as "Only committed Reserved evidence survived the failed COMMIT."
    assert j.inspect(recovered, original) == Ok(j.Reserved)
    assert j.claim_preparation(recovered, original) == Error(j.Uncertain)
    let _ = j.release_endpoint(recovered)
    Nil
  })
}

pub fn ignored_ready_reply_recovers_bytes_without_another_claim_test() {
  fixture("lost-ready-reply", limits(2, 30_000_000), fn(path, book) {
    let original = compiled("pub fn main() { Nil }", 3)
    assert j.reserve(book, original) == Ok(j.Reserved)
    let assert Ok(j.Claimed(claim)) = j.claim_preparation(book, original)
      as "One original claim."
    let ready = compile_ready(original.key)

    // Discard acknowledgement and recover evidence rather than repeating effects.
    let _ = j.commit_ready(claim, ready)
    assert j.release_endpoint(book) == Ok(Nil)
    let assert Ok(recovered) =
      j.recover(path, enrolled(), limits(2, 30_000_000))
      as "Original issued bytes survived a discarded acknowledgement."
    assert j.inspect(recovered, original) == Ok(j.Prepared(ready))
    assert j.claim_preparation(recovered, original)
      == Ok(j.Existing(j.Prepared(ready)))
    assert j.release_endpoint(recovered) == Ok(Nil)
  })
}

pub fn invalid_bodies_and_digest_linkage_fail_before_reservation_test() {
  fixture("invalid", limits(2, 30_000_000), fn(_path, book) {
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
  ]
  assert normalize(source) == normalize(string.join(generated, "\n"))
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
  + 262_144
  + 100
}

fn fixture(name: String, limits: j.Limits, run: fn(String, j.Journal) -> Nil) {
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
  let assert Ok(book) = j.fresh(path, enrolled(), limits)
    as "Fresh exact journal."
  run(path, book)
  let _ = j.release_endpoint(book)
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
