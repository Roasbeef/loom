//// Real SQLite owner pin, lifetime generation links and system intent controls.
//// Hash injection uses a deterministic content-sensitive test double here;
//// The pure-family fixture now uses WorkspaceSystem; native staged controls are
//// separate below and do not claim actual Broker execution. Production SHA-256 remains the trusted host assembly's responsibility.

import core/clock
import core/command
import core/generation
import core/ids
import core/msgpack as mp
import core/remote_tool
import core/report_value as rv
import core/workspace
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import sqlight
import storage/owner_custody as custody
import support/fixtures

fn limits() -> custody.Limits {
  let assert Ok(value) = custody.limits(8, 64, 1_048_576, 1024)
    as "Bounded fixture quota."
  value
}

fn id(seed: Int) -> ids.EntryId {
  let #(value, _) = ids.mint_entry(ids.generator(clock.fixed(2000), seed))
  value
}

fn coordinates() -> #(ids.SessionId, ids.OpId, workspace.RegisteredBinding) {
  let #(session, generator) =
    ids.mint_session(ids.generator(clock.fixed(1000), 77))
  let #(operation, _) = ids.mint_op(generator)
  let assert Ok(selector) = workspace.selector("executor", "workspace")
    as "Selector validates."
  let assert Ok(binding) = workspace.registered_binding(selector, 1, 2)
    as "Epochs validate."
  #(session, operation, binding)
}

fn hash(bytes: BitArray) -> BitArray {
  <<hash_walk(bytes, 1):size(256)>>
}

fn hash_walk(bytes: BitArray, seed: Int) -> Int {
  case bytes {
    <<value, rest:bits>> ->
      hash_walk(rest, { seed * 31 + value } % 2_147_483_647)
    <<>> -> seed
    _ -> 0
  }
}

fn digest(bytes: BitArray) -> generation.Digest {
  let assert Ok(value) = generation.digest(hash(bytes))
    as "Hash double returns 32 bytes."
  value
}

fn payload(text: String) -> custody.Payload {
  let assert Ok(value) = custody.payload(limits(), bit_array.from_string(text))
    as "Fixture payload fits."
  value
}

fn pin() -> custody.EnrollmentPin {
  let #(session, _, binding) = coordinates()
  let bytes = <<"canonical enrollment">>
  let assert Ok(value) =
    custody.enrollment_pin(
      session,
      binding,
      digest(<<"descriptor">>),
      digest(bytes),
      bytes,
    )
    as "Pin has bounded bytes."
  value
}

fn association(
  number: Int,
  owner_seed: Int,
  previous: generation.Predecessor,
) -> generation.GenerationAssociation {
  let #(session, _, binding) = coordinates()
  let assert Ok(key) =
    generation.key(
      workspace.scope(session, binding),
      digest(<<"descriptor">>),
      number,
    )
    as "Generation validates."
  generation.association(
    key,
    digest(<<"canonical enrollment">>),
    id(owner_seed),
    previous,
  )
}

fn tool(index: Int) -> remote_tool.ToolKey {
  let #(session, operation, _) = coordinates()
  let assert Ok(key) =
    remote_tool.key(
      session,
      operation,
      "step",
      index,
      string.repeat("a", 64),
      id(100 + index),
    )
    as "Complete tool validates."
  key
}

fn opened(name: String) -> #(String, custody.Store, custody.LiveGeneration) {
  opened_with_limits(name, limits())
}

fn opened_with_limits(
  name: String,
  ceilings: custody.Limits,
) -> #(String, custody.Store, custody.LiveGeneration) {
  let path = fixtures.scratch("owner-generations-" <> name) <> "/owner.db"
  let #(session, _, _) = coordinates()
  let assert Ok(store) =
    custody.open_with_reports(path, session, ceilings, hash)
    as "Real companion opens."
  let assert Ok(_) = custody.pin_enrollment(store, pin())
    as "Pin commits and reads back."
  let associated = association(1, 1, generation.FirstGeneration)
  let assert Ok(custody.FreshGeneration(live)) =
    custody.retain_generation(store, associated, 1)
    as "Only original admission is live."
  #(path, store, live)
}

fn mutate(path: String, sql: String) -> Nil {
  let assert Ok(connection) = sqlight.open(path) as "Test connection opens."
  let assert Ok(Nil) = sqlight.exec(sql, connection)
    as "Test-only SQL succeeds."
  let assert Ok(Nil) = sqlight.close(connection) as "Test connection closes."
  Nil
}

fn scalar(path: String, sql: String) -> Int {
  let assert Ok(connection) = sqlight.open(path)
    as "Read-only inspection connection opens."
  let assert Ok([value]) =
    sqlight.query(sql, connection, [], decode.at([0], decode.int))
    as "Scalar inspection succeeds."
  let assert Ok(Nil) = sqlight.close(connection) as "Inspection closes."
  value
}

fn close_record(live: custody.LiveGeneration) -> custody.OwnerCloseRecord {
  let assert Ok(node) =
    mp.encode(
      mp.ArrayValue([mp.IntValue(1), mp.StringValue("original node retirement")]),
    )
    as "Node fixture encodes."
  let joins =
    custody.OwnerJoins(
      digest(<<"runtime">>),
      digest(<<"broker">>),
      digest(<<"custodian">>),
    )
  let assert Ok(value) =
    custody.owner_close_record(
      custody.live_association(live),
      node,
      digest(node),
      joins,
    )
    as "Close frame validates."
  value
}

fn intent(
  live: custody.LiveGeneration,
  address: String,
  request_id: ids.EntryId,
  content: String,
) -> custody.SystemIntent {
  let #(_, operation, _) = coordinates()
  let assert Ok(value) =
    custody.system_intent(
      live,
      address,
      custody.WorktreeObservation,
      operation,
      "startup-git",
      request_id,
      bit_array.from_string(content),
    )
    as "Trusted stable intent validates."
  value
}

fn build(
  origin: remote_tool.ChildOrigin,
  request_id: ids.EntryId,
) -> Result(custody.SystemReservationPayload, custody.Error) {
  let text =
    remote_tool.child_address(origin) <> ids.entry_id_to_string(request_id)
  use request <- result.try(custody.workspace_request(
    limits(),
    bit_array.from_string(text),
  ))
  Ok(custody.WorkspaceSystem(request))
}

pub fn immutable_pin_retries_and_changed_bytes_conflict_test() {
  let #(_path, store, _) = opened("pin")
  let assert Ok(readback) = custody.pin_enrollment(store, pin())
    as "Exact pin retry reads back."
  assert custody.pin_value(readback) == pin()
  assert custody.read_enrollment(store) == Ok(pin())
  let #(session, _, binding) = coordinates()
  let assert Ok(changed) =
    custody.enrollment_pin(
      session,
      binding,
      digest(<<"descriptor">>),
      digest(<<"changed">>),
      <<"changed">>,
    )
    as "Changed pin is structurally valid."
  assert custody.pin_enrollment(store, changed) == Error(custody.Conflict)
  let assert Ok(wrong_hash) =
    custody.enrollment_pin(
      session,
      binding,
      digest(<<"descriptor">>),
      digest(<<"wrong">>),
      <<"canonical enrollment">>,
    )
    as "Wrong digest has correct width."
  assert custody.pin_enrollment(store, wrong_hash) == Error(custody.Conflict)
  assert custody.close(store) == Ok(Nil)
}

pub fn format_five_additive_migration_preserves_local_final_and_fence_test() {
  let path = fixtures.scratch("owner-generations-migration") <> "/owner.db"
  let #(session, _, _) = coordinates()
  let assert Ok(store) = custody.open(path, session, limits())
    as "Local companion opens."
  assert custody.admit(store, tool(0), payload("args"), payload("original"))
    == Ok(Nil)
  assert custody.finish(store, tool(0), payload("retained final")) == Ok(Nil)
  let assert Ok(origin) =
    remote_tool.tool_child(tool(0), remote_tool.Workspace(3))
    as "Child origin validates."
  assert custody.cancel_child(store, origin) == Ok(Nil)
  assert custody.close(store) == Ok(Nil)

  // Removing only the empty additions produces the exact populated format-five
  // schema. The old report/tool/fence tables and their rows remain unchanged.
  mutate(
    path,
    "DROP TABLE owner_custody_enrollment; DROP TABLE owner_generation_associations; DROP TABLE owner_generation_closes; DROP TABLE owner_tool_generation; DROP TABLE owner_child_generation; DROP TABLE owner_system_intent; DROP TABLE owner_system_ordinal; PRAGMA user_version=5",
  )
  let assert Ok(store) = custody.open(path, session, limits())
    as "Populated format five migrates additively."
  assert custody.lookup(store, tool(0))
    == Ok(custody.FinalOutcome(payload("retained final")))
  assert custody.admit_child(store, origin, id(20), payload("late"))
    == Error(custody.Frozen)
  assert custody.read_enrollment(store) == Error(custody.Missing)
  assert scalar(path, "PRAGMA user_version") == 7
  assert scalar(path, "SELECT COUNT(*) FROM owner_generation_associations") == 0
  assert custody.close(store) == Ok(Nil)
}

pub fn enrollment_corrupt_scalar_header_refuses_before_blob_read_test() {
  let #(path, store, _) = opened("pin-header")
  assert custody.close(store) == Ok(Nil)
  mutate(
    path,
    "UPDATE owner_custody_enrollment SET enrollment_bytes = zeroblob(262145)",
  )
  let #(session, _, _) = coordinates()
  let assert Error(custody.Invalid(_)) =
    custody.open_with_reports(path, session, limits(), hash)
    as "Oversized pin refuses on scalar preflight."
  mutate(
    path,
    "UPDATE owner_custody_enrollment SET enrollment_bytes = X'01', reserved_bytes = X'00'",
  )
  let assert Error(custody.Invalid(_)) =
    custody.open_with_reports(path, session, limits(), hash)
    as "BLOB quota refuses without materialization."
}

pub fn generation_live_custody_is_not_recreated_by_readback_test() {
  let #(path, store, live) = opened("generation-history")
  let associated = custody.live_association(live)
  assert custody.retain_generation(store, associated, 1)
    == Ok(custody.RetainedGeneration(associated))
  assert custody.admit_registered_fresh_with_profile(
      store,
      live,
      tool(0),
      payload("a"),
      payload("r"),
      custody.OrdinaryFinal,
    )
    == Ok(custody.Fresh)
  assert custody.admit_registered_fresh_with_profile(
      store,
      live,
      tool(0),
      payload("a"),
      payload("r"),
      custody.OrdinaryFinal,
    )
    == Ok(custody.Retained)
  assert custody.tool_generation(store, tool(0)) == Ok(associated)
  assert custody.admit_fresh(store, tool(1), payload("a"), payload("r"))
    == Error(custody.Invalid(
      "registered admission requires original live generation",
    ))
  assert custody.close(store) == Ok(Nil)
  let #(session, _, _) = coordinates()
  let assert Ok(reopened) =
    custody.open_with_reports(path, session, limits(), hash)
    as "Exact metadata reopens."
  assert custody.retain_generation(reopened, associated, 1)
    == Ok(custody.RetainedGeneration(associated))
  assert custody.admit_registered_fresh_with_profile(
      reopened,
      live,
      tool(1),
      payload("a"),
      payload("r"),
      custody.OrdinaryFinal,
    )
    == Error(custody.Frozen)
  assert custody.tool_generation(reopened, tool(0)) == Ok(associated)
  assert custody.close(reopened) == Ok(Nil)
}

pub fn closed_generation_refuses_delayed_live_handle_and_successor_binds_proof_test() {
  let #(_path, store, live) = opened("successor")
  let close = close_record(live)
  assert custody.retain_generation_close(store, close, fn(_) {
      Error("joins missing")
    })
    == Error(custody.Invalid("joins missing"))
  let assert Ok(owner_digest) =
    custody.retain_generation_close(store, close, fn(value) {
      case
        custody.owner_close_fields(value) == custody.owner_close_fields(close)
      {
        True -> Ok(Nil)
        False -> Error("changed original witnesses")
      }
    })
    as "Trusted live witness validator authorizes exact close."
  assert custody.retain_generation_close(store, close, fn(_) {
      Error("historical retry must not reattest")
    })
    == Ok(owner_digest)
  assert custody.read_generation_close(
      store,
      generation.association_key(custody.live_association(live)),
    )
    == Ok(close)
  assert custody.admit_registered_fresh_with_profile(
      store,
      live,
      tool(0),
      payload("a"),
      payload("r"),
      custody.OrdinaryFinal,
    )
    == Error(custody.Frozen)
  let #(_, _, node_digest, _) = custody.owner_close_fields(close)
  let invalid =
    association(3, 2, generation.Successor(node_digest, owner_digest))
  assert custody.retain_generation(store, invalid, 1) |> result.is_error
  let next = association(2, 2, generation.Successor(node_digest, owner_digest))
  let assert Ok(custody.FreshGeneration(second)) =
    custody.retain_generation(store, next, 1)
    as "Exact clean immediate successor is admitted."
  assert custody.admit_registered_fresh_with_profile(
      store,
      second,
      tool(0),
      payload("a"),
      payload("r"),
      custody.OrdinaryFinal,
    )
    == Ok(custody.Fresh)
  assert custody.tool_generation(store, tool(0)) == Ok(next)
  assert custody.close(store) == Ok(Nil)
}

pub fn registered_tool_child_links_are_atomic_and_compare_full_parent_test() {
  let #(path, store, live) = opened("tool-child-link")
  assert custody.admit_registered_fresh_with_profile(
      store,
      live,
      tool(0),
      payload("a"),
      payload("r"),
      custody.OrdinaryFinal,
    )
    == Ok(custody.Fresh)
  let assert Ok(origin) =
    remote_tool.tool_child(tool(0), remote_tool.Workspace(0))
    as "Tool child validates."
  mutate(
    path,
    "CREATE TRIGGER fail_child_link BEFORE INSERT ON owner_child_generation BEGIN SELECT RAISE(ABORT, 'fixture failure'); END",
  )
  assert custody.admit_registered_child(
      store,
      live,
      origin,
      id(10),
      payload("input"),
    )
    == Error(custody.Conflict)
  assert scalar(path, "SELECT COUNT(*) FROM owner_custody_children") == 0
  mutate(path, "DROP TRIGGER fail_child_link")
  assert custody.admit_registered_child(
      store,
      live,
      origin,
      id(10),
      payload("input"),
    )
    == Ok(custody.Fresh)
  assert custody.admit_registered_child(
      store,
      live,
      origin,
      id(10),
      payload("input"),
    )
    == Ok(custody.Retained)
  assert custody.admit_registered_child(
      store,
      live,
      origin,
      id(11),
      payload("input"),
    )
    == Error(custody.Conflict)
  assert custody.admit_registered_child(
      store,
      live,
      origin,
      id(10),
      payload("changed"),
    )
    == Error(custody.Conflict)
  assert custody.child_generation(store, origin)
    == Ok(custody.live_association(live))
  let #(session, operation, _) = coordinates()
  let assert Ok(changed_parent) =
    remote_tool.key(
      session,
      operation,
      "step",
      0,
      string.repeat("b", 64),
      id(100),
    )
    as "Changed complete digest is structurally valid."
  let assert Ok(changed_origin) =
    remote_tool.tool_child(changed_parent, remote_tool.Workspace(0))
    as "Same logical child address validates."
  assert custody.child_generation(store, changed_origin)
    == Error(custody.Conflict)
  assert custody.close(store) == Ok(Nil)
}

pub fn suppressed_tool_link_and_commit_failure_cannot_return_fresh_test() {
  let #(path, store, live) = opened("tool-link-suppression")
  mutate(
    path,
    "CREATE TRIGGER suppress_tool_link BEFORE INSERT ON owner_tool_generation BEGIN SELECT RAISE(IGNORE); END",
  )
  assert custody.admit_registered_fresh_with_profile(
      store,
      live,
      tool(0),
      payload("a"),
      payload("r"),
      custody.OrdinaryFinal,
    )
    == Error(custody.Missing)
  assert scalar(path, "SELECT COUNT(*) FROM owner_custody_tools") == 0
  mutate(
    path,
    "DROP TRIGGER suppress_tool_link; CREATE TABLE missing_parent (id INTEGER PRIMARY KEY); CREATE TABLE deferred_failure (parent INTEGER REFERENCES missing_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fail_tool_commit AFTER INSERT ON owner_custody_tools BEGIN INSERT INTO deferred_failure VALUES (77); END",
  )
  assert custody.admit_registered_fresh_with_profile(
      store,
      live,
      tool(0),
      payload("a"),
      payload("r"),
      custody.OrdinaryFinal,
    )
    == Error(custody.Conflict)
  assert scalar(path, "SELECT COUNT(*) FROM owner_custody_tools") == 0
  assert scalar(path, "SELECT COUNT(*) FROM owner_tool_generation") == 0
  assert custody.close(store) == Ok(Nil)
}

pub fn intent_reserves_and_transfers_one_slot_stably_test() {
  let #(path, store, live) = opened("intent-stable")
  let original = intent(live, "retained startup phase", id(10), "intent")
  let assert Ok(retained) = custody.retain_system_intent(store, original)
    as "Original intent commits."
  assert custody.retain_system_intent(store, original) == Ok(retained)
  assert scalar(
      path,
      "SELECT COUNT(*) FROM owner_system_intent WHERE child_address IS NULL",
    )
    == 1
  assert scalar(
      path,
      "SELECT next_ordinal FROM owner_system_ordinal WHERE service='worktree-observation'",
    )
    == 0
  let old_charge =
    scalar(path, "SELECT reserved_bytes FROM owner_system_intent")
  let assert Ok(first) = custody.admit_system_child(store, retained, build)
    as "Original child/link/counter commit."
  assert first.admission == custody.Fresh
  assert first.request_id == id(10)
  assert first.generation
    == generation.association_key(custody.live_association(live))
  let assert Ok(again) = custody.admit_system_child(store, retained, build)
    as "Exact retry reads original child."
  assert again.admission == custody.Retained
  assert again.origin == first.origin
  assert scalar(path, "SELECT COUNT(*) FROM owner_custody_children") == 1
  assert scalar(path, "SELECT COUNT(*) FROM owner_child_generation") == 1
  assert scalar(
      path,
      "SELECT COUNT(*) FROM owner_system_intent WHERE child_address IS NULL",
    )
    == 0
  assert scalar(path, "SELECT reserved_bytes FROM owner_system_intent")
    == old_charge
    - 2048
    + string.byte_size(remote_tool.child_address(first.origin))
    + bit_array.byte_size(
      remote_tool.encode_child(first.origin) |> result.unwrap(<<>>),
    )
    + string.byte_size("workspace")
  assert scalar(
      path,
      "SELECT next_ordinal FROM owner_system_ordinal WHERE service='worktree-observation'",
    )
    == 1
  assert custody.retain_system_intent(
      store,
      intent(live, "retained startup phase", id(11), "intent"),
    )
    == Error(custody.Conflict)
  assert custody.retain_system_intent(
      store,
      intent(live, "retained startup phase", id(10), "changed"),
    )
    == Error(custody.Conflict)
  assert custody.admit_system_child(store, retained, fn(_, _) {
      Ok(custody.NativeSystem(payload("changed input")))
    })
    == Error(custody.Conflict)
  let assert Ok(_workspace_payload) =
    custody.workspace_request(
      limits(),
      custody.bytes(payload(
        remote_tool.child_address(first.origin)
        <> ids.entry_id_to_string(id(10)),
      )),
    )
    as "Identical bytes fit workspace profile."
  assert custody.admit_system_child(store, retained, fn(_, _) {
      use native <- result.try(custody.payload(
        limits(),
        custody.bytes(payload(
          remote_tool.child_address(first.origin)
          <> ids.entry_id_to_string(id(10)),
        )),
      ))
      Ok(custody.NativeSystem(native))
    })
    == Error(custody.Conflict)
  assert custody.close(store) == Ok(Nil)
}

pub fn system_link_failure_rolls_back_slot_transfer_and_ordinal_test() {
  let #(path, store, live) = opened("system-rollback")
  let assert Ok(intent) =
    custody.retain_system_intent(
      store,
      intent(live, "startup", id(10), "intent"),
    )
    as "Intent is committed first."
  let charge = scalar(path, "SELECT reserved_bytes FROM owner_system_intent")
  mutate(
    path,
    "CREATE TRIGGER suppress_child_link BEFORE INSERT ON owner_child_generation BEGIN SELECT RAISE(IGNORE); END",
  )
  assert custody.admit_system_child(store, intent, build)
    == Error(custody.Missing)
  assert scalar(path, "SELECT COUNT(*) FROM owner_custody_children") == 0
  assert scalar(
      path,
      "SELECT COUNT(*) FROM owner_system_intent WHERE child_address IS NULL",
    )
    == 1
  assert scalar(path, "SELECT reserved_bytes FROM owner_system_intent")
    == charge
  assert scalar(
      path,
      "SELECT next_ordinal FROM owner_system_ordinal WHERE service='worktree-observation'",
    )
    == 0
  mutate(path, "DROP TRIGGER suppress_child_link")
  let assert Ok(first) = custody.admit_system_child(store, intent, build)
    as "Original intent is still usable after known rollback."
  assert first.admission == custody.Fresh
  assert custody.close(store) == Ok(Nil)
}

pub fn system_counter_survives_clean_generation_successor_and_history_reopen_test() {
  let #(path, store, live) = opened("system-generations")
  let original = intent(live, "startup", id(10), "intent")
  let assert Ok(retained) = custody.retain_system_intent(store, original)
    as "First intent retains."
  let assert Ok(first) = custody.admit_system_child(store, retained, build)
    as "First child commits."
  let close = close_record(live)
  let assert Ok(owner) =
    custody.retain_generation_close(store, close, fn(_) { Ok(Nil) })
    as "Original joins attest."
  let #(_, _, node, _) = custody.owner_close_fields(close)
  let next = association(2, 2, generation.Successor(node, owner))
  let assert Ok(custody.FreshGeneration(second)) =
    custody.retain_generation(store, next, 1)
    as "Successor admitted."
  let assert Ok(second_intent) =
    custody.retain_system_intent(
      store,
      intent(second, "startup", id(11), "intent"),
    )
    as "Distinct generation startup intent retains."
  let assert Ok(second_child) =
    custody.admit_system_child(store, second_intent, build)
    as "Second lifetime child commits."
  let assert remote_tool.SystemFields(_, _, 0) =
    remote_tool.child_fields(first.origin)
    as "First ordinal is zero."
  let assert remote_tool.SystemFields(_, _, 1) =
    remote_tool.child_fields(second_child.origin)
    as "Successor never resets ordinal."
  assert custody.child_generation(store, first.origin)
    == Ok(custody.live_association(live))
  assert custody.child_generation(store, second_child.origin) == Ok(next)
  let #(associated, address, service, operation, step, request_id, bytes) =
    custody.system_intent_fields(retained)
  let assert Ok(historical) =
    custody.historical_system_intent(
      associated,
      address,
      service,
      operation,
      step,
      request_id,
      bytes,
    )
    as "Historical reconstruction grants no live handle."
  assert custody.close(store) == Ok(Nil)
  let #(session, _, _) = coordinates()
  let assert Ok(store) =
    custody.open_with_reports(path, session, limits(), hash)
    as "Original companion reopens."
  let assert Ok(history) = custody.read_system_intent(store, historical)
    as "Exact old intent readback survives."
  let assert Ok(observed) = custody.admit_system_child(store, history, build)
    as "Existing child remains historical observation."
  assert observed.admission == custody.Retained
  assert observed.origin == first.origin
  assert scalar(
      path,
      "SELECT next_ordinal FROM owner_system_ordinal WHERE service='worktree-observation'",
    )
    == 2
  assert custody.close(store) == Ok(Nil)
}

pub fn pending_system_slot_and_lifetime_exhaustion_refuse_without_mutation_test() {
  let assert Ok(small) = custody.limits(8, 1, 1_048_576, 1024)
    as "Single child quota validates."
  let #(path, store, live) = opened_with_limits("pending-capacity", small)
  let assert Ok(retained) =
    custody.retain_system_intent(store, intent(live, "first", id(10), "intent"))
    as "First pending slot reserves."
  assert custody.retain_system_intent(
      store,
      intent(live, "second", id(11), "intent"),
    )
    == Error(custody.Capacity)
  let assert Ok(first) = custody.admit_system_child(store, retained, build)
    as "Slot transfer does not double-charge count."
  assert first.admission == custody.Fresh
  assert scalar(path, "SELECT COUNT(*) FROM owner_system_intent") == 1
  assert custody.close(store) == Ok(Nil)
  let #(path, store, live) = opened("ordinal-exhaustion")
  let assert Ok(retained) =
    custody.retain_system_intent(store, intent(live, "last", id(10), "intent"))
    as "Pending slot reserves."
  mutate(path, "UPDATE owner_system_ordinal SET next_ordinal=4095")
  let assert Ok(last) = custody.admit_system_child(store, retained, build)
    as "Last allowed ordinal commits."
  let assert remote_tool.SystemFields(_, _, 4095) =
    remote_tool.child_fields(last.origin)
    as "Ordinal 4095 is allowed."
  assert custody.retain_system_intent(
      store,
      intent(live, "beyond", id(11), "intent"),
    )
    == Error(custody.Capacity)
  assert scalar(
      path,
      "SELECT next_ordinal FROM owner_system_ordinal WHERE service='worktree-observation'",
    )
    == 4096
  assert scalar(path, "SELECT COUNT(*) FROM owner_system_intent") == 1
  assert custody.close(store) == Ok(Nil)
}

pub fn history_intent_without_child_cannot_allocate_test() {
  let #(path, store, live) = opened("history-no-child")
  let original = intent(live, "startup", id(10), "intent")
  let assert Ok(retained) = custody.retain_system_intent(store, original)
    as "Original pending slot commits."
  let #(associated, address, service, operation, step, request_id, bytes) =
    custody.system_intent_fields(retained)
  let assert Ok(historical) =
    custody.historical_system_intent(
      associated,
      address,
      service,
      operation,
      step,
      request_id,
      bytes,
    )
    as "Historical intent is data only."
  let assert Ok(readback) = custody.read_system_intent(store, historical)
    as "Original exact intent reads back."
  assert custody.admit_system_child(store, readback, build)
    == Error(custody.Frozen)
  assert scalar(path, "SELECT COUNT(*) FROM owner_custody_children") == 0
  assert scalar(
      path,
      "SELECT next_ordinal FROM owner_system_ordinal WHERE service='worktree-observation'",
    )
    == 0
  assert custody.close(store) == Ok(Nil)
}

pub fn populated_format_five_reports_and_migration_refusals_are_preserved_test() {
  let path =
    fixtures.scratch("owner-generations-report-migration") <> "/owner.db"
  let #(session, _, _) = coordinates()
  let assert Ok(large) = custody.limits(8, 64, 32_000_000, 1024)
    as "Report quota fits fixed reservation."
  let assert Ok(store) = custody.open_with_reports(path, session, large, hash)
    as "Report-enabled local companion opens."
  assert custody.admit_fresh_with_profile(
      store,
      tool(0),
      payload("a"),
      payload("r"),
      custody.CodeModeReportV1,
    )
    == Ok(custody.Fresh)
  let assert Ok(metadata) =
    rv.metadata(
      "sha256-" <> string.repeat("b", 64),
      rv.Enforcement(
        rv.Unreported("not observed"),
        rv.Unreported("not observed"),
      ),
      rv.CallLog(0, 0, 0, 0, 0, 0, []),
    )
    as "Report metadata validates."
  let assert Ok(report) =
    rv.from_outcome(rv.Completed(mp.BinaryValue(<<0, 255, 0>>)), metadata)
    as "Complete report validates."
  let assert Ok(reference) = custody.retain_report(store, tool(0), report)
    as "Complete report commits."
  let charge = scalar(path, "SELECT reserved_bytes FROM owner_custody_tools")
  assert custody.close(store) == Ok(Nil)
  mutate(
    path,
    "DROP TABLE owner_custody_enrollment; DROP TABLE owner_generation_associations; DROP TABLE owner_generation_closes; DROP TABLE owner_tool_generation; DROP TABLE owner_child_generation; DROP TABLE owner_system_intent; DROP TABLE owner_system_ordinal; PRAGMA user_version=5",
  )
  let #(wrong_session, _) =
    ids.mint_session(ids.generator(clock.fixed(1001), 99))
  assert custody.open_with_reports(path, wrong_session, large, hash)
    == Error(custody.Conflict)
  assert scalar(path, "PRAGMA user_version") == 5
  let assert Error(custody.Invalid(_)) = custody.open(path, session, large)
    as "Missing hash refuses inside migration transaction."
  assert scalar(path, "PRAGMA user_version") == 5
  assert scalar(
      path,
      "SELECT COUNT(*) FROM sqlite_master WHERE name='owner_generation_associations'",
    )
    == 0
  let assert Ok(store) = custody.open_with_reports(path, session, large, hash)
    as "Format-five report migrates atomically with hash verification."
  assert custody.report_reference(store, tool(0)) == Ok(Some(reference))
  assert custody.retain_report(store, tool(0), report) == Ok(reference)
  assert scalar(path, "SELECT reserved_bytes FROM owner_custody_tools")
    == charge
  assert scalar(path, "SELECT length(report) FROM owner_custody_tools")
    == bit_array.byte_size(rv.bytes(report))
  assert custody.close(store) == Ok(Nil)
}

pub fn metadata_byte_ceiling_is_charged_once_and_refuses_without_mutation_test() {
  let path = fixtures.scratch("owner-generations-byte-ceiling") <> "/owner.db"
  let #(session, _, _) = coordinates()
  let assert Ok(small) = custody.limits(8, 64, 300, 1024)
    as "Small aggregate quota validates."
  let assert Ok(store) = custody.open_with_reports(path, session, small, hash)
    as "Empty companion opens below pin allowance."
  assert custody.pin_enrollment(store, pin()) == Error(custody.Capacity)
  assert scalar(path, "SELECT COUNT(*) FROM owner_custody_enrollment") == 0
  assert custody.close(store) == Ok(Nil)
  let #(path, store, live) = opened("metadata-charges")
  let charge =
    scalar(path, "SELECT reserved_bytes FROM owner_custody_enrollment")
  let assert Ok(_) = custody.pin_enrollment(store, pin())
    as "Exact pin retry succeeds."
  assert scalar(path, "SELECT reserved_bytes FROM owner_custody_enrollment")
    == charge
  let associated = custody.live_association(live)
  let generation_charge =
    scalar(path, "SELECT reserved_bytes FROM owner_generation_associations")
  assert custody.retain_generation(store, associated, 1)
    == Ok(custody.RetainedGeneration(associated))
  assert scalar(
      path,
      "SELECT reserved_bytes FROM owner_generation_associations",
    )
    == generation_charge
  mutate(
    path,
    "UPDATE owner_generation_associations SET reserved_bytes=1048576",
  )
  assert custody.retain_system_intent(
      store,
      intent(live, "overquota", id(10), "intent"),
    )
    == Error(custody.Capacity)
  assert scalar(path, "SELECT COUNT(*) FROM owner_system_intent") == 0
  assert scalar(path, "SELECT COUNT(*) FROM owner_system_ordinal") == 0
  assert custody.close(store) == Ok(Nil)
}

pub fn pending_system_per_parent_limit_remains_sixty_four_test() {
  let #(path, store, live) = opened("parent-capacity")
  int.range(from: 0, to: 64, with: Nil, run: fn(_, index) {
    let assert Ok(_) =
      custody.retain_system_intent(
        store,
        intent(
          live,
          "intent-" <> int.to_string(index),
          id(1000 + index),
          "intent",
        ),
      )
      as "Each of the first 64 eventual slots retains."
    Nil
  })
  assert custody.retain_system_intent(
      store,
      intent(live, "sixty-fifth", id(2000), "intent"),
    )
    == Error(custody.Capacity)
  assert scalar(path, "SELECT COUNT(*) FROM owner_system_intent") == 64
  assert scalar(path, "SELECT COUNT(*) FROM owner_custody_children") == 0
  assert custody.close(store) == Ok(Nil)
}

pub fn reopened_corrupt_generation_and_intent_metadata_refuses_test() {
  let #(path, store, live) = opened("corrupt-generation")
  let assert Ok(_) =
    custody.retain_system_intent(
      store,
      intent(live, "startup", id(10), "intent"),
    )
    as "Intent commits."
  assert custody.close(store) == Ok(Nil)
  let #(session, _, _) = coordinates()
  mutate(
    path,
    "UPDATE owner_system_intent SET step=CAST(zeroblob(129) AS TEXT)",
  )
  let assert Error(custody.Invalid(_)) =
    custody.open_with_reports(path, session, limits(), hash)
    as "Oversized metadata refuses before BLOB materialization."
  mutate(
    path,
    "UPDATE owner_system_intent SET step='startup-git'; UPDATE owner_generation_associations SET digest=zeroblob(32)",
  )
  assert custody.open_with_reports(path, session, limits(), hash)
    == Error(custody.Conflict)
}

pub fn registered_service_offer_command_links_and_failed_native_insert_test() {
  let #(path, store, live) = opened("service-links")
  assert custody.admit_registered_fresh_with_profile(
      store,
      live,
      tool(0),
      payload("a"),
      payload("r"),
      custody.OrdinaryFinal,
    )
    == Ok(custody.Fresh)
  let #(session, operation, binding) = coordinates()
  let assert Ok(step) = workspace.step("compile") as "Service phase validates."
  let assert Ok(service) =
    command.service_key(
      tool(0),
      command.CompileService,
      workspace.scope(session, binding),
      operation,
      step,
      id(20),
      string.repeat("a", 64),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "Whole original service validates."
  let assert Ok(request) =
    custody.service_request(limits(), service, <<"service input">>)
    as "Full service request fits."
  assert custody.admit_registered_service_child(store, live, request)
    == Ok(custody.Fresh)
  assert custody.admit_registered_service_child(store, live, request)
    == Ok(custody.Retained)
  assert custody.child_generation(store, command.service_origin(service))
    == Ok(custody.live_association(live))
  let assert Ok(ref) = command.command_ref(service, command.CompileCommand)
    as "Native role is disjoint."
  let assert Ok(offer) =
    custody.command_offer_payload(limits(), ref, string.repeat("d", 64), <<
      "exact offer",
    >>)
    as "Offer fits fixed bound."
  assert custody.admit_registered_offer(store, live, request, offer)
    == Ok(custody.Fresh)
  assert custody.admit_registered_offer(store, live, request, offer)
    == Ok(custody.Retained)
  mutate(
    path,
    "CREATE TRIGGER fail_native_link BEFORE INSERT ON owner_child_generation BEGIN SELECT RAISE(ABORT,'native link failure'); END",
  )
  assert custody.admit_registered_command_child(
      store,
      live,
      offer,
      id(30),
      payload("cleared native"),
    )
    == Error(custody.Conflict)
  assert scalar(path, "SELECT COUNT(*) FROM owner_custody_children") == 1
  mutate(path, "DROP TRIGGER fail_native_link")
  assert custody.admit_registered_command_child(
      store,
      live,
      offer,
      id(30),
      payload("cleared native"),
    )
    == Ok(#(custody.Fresh, id(30), payload("cleared native")))
  assert custody.admit_registered_command_child(
      store,
      live,
      offer,
      id(31),
      payload("cleared native"),
    )
    == Ok(#(custody.Retained, id(30), payload("cleared native")))
  assert custody.child_generation(store, command.native_origin(ref))
    == Ok(custody.live_association(live))
  assert custody.admit_registered_command_child(
      store,
      live,
      offer,
      id(30),
      payload("changed native"),
    )
    == Error(custody.Conflict)
  assert custody.close(store) == Ok(Nil)
}

pub fn system_workspace_profile_retains_the_full_result_allowance_test() {
  let assert Ok(large) = custody.limits(8, 64, 40_000_000, 33_554_432)
    as "Workspace result ceiling validates."
  let #(path, store, live) = opened_with_limits("workspace-system", large)
  let assert Ok(retained) =
    custody.retain_system_intent(
      store,
      intent(live, "initialize", id(10), "intent"),
    )
    as "Workspace work retains original intent."
  let assert Ok(request) =
    custody.workspace_request(large, <<"complete workspace input">>)
    as "Workspace request validates."
  let assert Ok(child) =
    custody.admit_system_child(store, retained, fn(_, _) {
      Ok(custody.WorkspaceSystem(request))
    })
    as "Workspace child commits under its closed profile."
  assert child.admission == custody.Fresh
  let reserve =
    scalar(path, "SELECT reserved_bytes FROM owner_custody_children")
  assert reserve > 33_554_432
  let assert Ok(completion) =
    custody.workspace_completion(
      large,
      bit_array.from_string(string.repeat("x", 2_097_153)),
    )
    as "Workspace terminal exceeds native profile but fits existing full profile."
  assert custody.receive_workspace_child(
      store,
      child.origin,
      child.request_id,
      completion,
    )
    == Ok(Nil)
  assert scalar(path, "SELECT length(terminal) FROM owner_custody_children")
    == 2_097_153
  assert custody.child_generation(store, child.origin)
    == Ok(custody.live_association(live))
  assert custody.close(store) == Ok(Nil)
}

pub fn native_pending_allocates_once_and_history_never_rearms_test() {
  let #(path, store, live) = opened("native-pending")
  let assert Ok(intent) =
    custody.retain_system_intent(
      store,
      intent(live, "native", id(20), "original command declaration"),
    )
    as "Synthetic ordinary work retains its original slot."
  assert custody.admit_system_child(store, intent, fn(_, _) {
      Ok(custody.NativeSystem(payload("uncleared dummy")))
    })
    == Error(custody.Invalid("fresh native system requires pending allocation"))
  let charge = scalar(path, "SELECT reserved_bytes FROM owner_system_intent")
  let assert Ok(custody.FreshPending(pending)) =
    custody.allocate_native_system(store, intent)
    as "Only the original allocation supplies pending authority."
  let #(origin, uuid, associated) = custody.pending_system_fields(pending)
  assert uuid == id(20)
  assert associated == custody.live_association(live)
  assert scalar(path, "SELECT reserved_bytes FROM owner_system_intent")
    == charge
  assert scalar(path, "SELECT COUNT(*) FROM owner_custody_children") == 0
  assert scalar(path, "SELECT COUNT(*) FROM owner_child_generation") == 0
  assert scalar(path, "SELECT next_ordinal FROM owner_system_ordinal") == 1
  assert custody.allocate_native_system(store, intent)
    == Ok(custody.RetainedPending(origin, uuid, custody.NativePending))
  let request =
    payload("synthetic complete post-clearance bytes; not a Broker fixture")
  let assert Ok(admitted) =
    custody.admit_pending_system(store, pending, request)
    as "Final payload admission transfers the original reserved slot."
  assert admitted.admission == custody.Fresh
  assert admitted.origin == origin
  let assert Ok(again) = custody.admit_pending_system(store, pending, request)
    as "Duplicate storage observation cannot grant a second send."
  assert again.admission == custody.Retained
  assert custody.admit_pending_system(store, pending, payload("altered bytes"))
    == Error(custody.Conflict)
  assert scalar(path, "SELECT next_ordinal FROM owner_system_ordinal") == 1
  assert scalar(path, "SELECT COUNT(*) FROM owner_custody_children") == 1
  assert custody.child_generation(store, origin) == Ok(associated)
  assert custody.cancel_native_system(store, intent) == Ok(Nil)
  assert custody.receive_child(
      store,
      origin,
      uuid,
      payload("matching late terminal"),
    )
    == Ok(Nil)
  assert custody.close(store) == Ok(Nil)
  let #(session, _, _) = coordinates()
  let assert Ok(reopened) =
    custody.open_with_reports(path, session, limits(), hash)
    as "Format seven retains original native history after reopen."
  assert custody.allocate_native_system(reopened, intent)
    == Ok(custody.RetainedPending(origin, uuid, custody.NativeAdmitted))
  assert custody.child_generation(reopened, origin) == Ok(associated)
  assert custody.close(reopened) == Ok(Nil)
}

pub fn native_cancelled_pending_keeps_ordinal_slot_and_allowance_test() {
  let assert Ok(single) = custody.limits(8, 1, 1_048_576, 1024)
    as "One original pending slot bounds the inventory."
  let #(path, store, live) = opened_with_limits("native-cancel", single)
  let assert Ok(retained) =
    custody.retain_system_intent(
      store,
      intent(live, "native", id(20), "declaration"),
    )
    as "Unallocated native work retains."
  let charge = scalar(path, "SELECT reserved_bytes FROM owner_system_intent")
  assert custody.cancel_native_system(store, retained) == Ok(Nil)
  let assert Ok(custody.RetainedPending(origin, uuid, custody.NativeCancelled)) =
    custody.allocate_native_system(store, retained)
    as "Unallocated cancellation allocates and cancels the original once."
  assert uuid == id(20)
  assert scalar(path, "SELECT reserved_bytes FROM owner_system_intent")
    == charge
  assert scalar(path, "SELECT next_ordinal FROM owner_system_ordinal") == 1
  assert scalar(path, "SELECT COUNT(*) FROM owner_custody_children") == 0
  assert custody.retain_system_intent(
      store,
      intent(live, "second", id(21), "declaration"),
    )
    == Error(custody.Capacity)
  assert custody.cancel_native_system(store, retained) == Ok(Nil)
  assert custody.allocate_native_system(store, retained)
    == Ok(custody.RetainedPending(origin, uuid, custody.NativeCancelled))
  assert custody.close(store) == Ok(Nil)
  let #(session, _, _) = coordinates()
  let assert Ok(store) = custody.open_with_reports(path, session, single, hash)
    as "Cancelled pending retains its full charge across reopen."
  assert scalar(path, "SELECT next_ordinal FROM owner_system_ordinal") == 1
  assert custody.close(store) == Ok(Nil)
}

pub fn final_native_rollback_keeps_the_previously_spent_ordinal_test() {
  let #(path, store, live) = opened("native-admission-rollback")
  let assert Ok(retained) =
    custody.retain_system_intent(
      store,
      intent(live, "native", id(20), "declaration"),
    )
    as "Native work retains."
  let assert Ok(custody.FreshPending(pending)) =
    custody.allocate_native_system(store, retained)
    as "Original allocation commits before clearance."
  mutate(
    path,
    "CREATE TRIGGER suppress_native_link BEFORE INSERT ON owner_child_generation BEGIN SELECT RAISE(IGNORE); END",
  )
  assert custody.admit_pending_system(store, pending, payload("actual bytes"))
    |> result.is_error
  assert scalar(path, "SELECT next_ordinal FROM owner_system_ordinal") == 1
  assert scalar(path, "SELECT COUNT(*) FROM owner_custody_children") == 0
  assert scalar(
      path,
      "SELECT COUNT(*) FROM owner_system_intent WHERE child_profile='native_pending'",
    )
    == 1
  mutate(path, "DROP TRIGGER suppress_native_link")
  assert custody.cancel_native_system(store, retained) == Ok(Nil)
  assert custody.admit_pending_system(store, pending, payload("actual bytes"))
    == Error(custody.Frozen)
  assert custody.close(store) == Ok(Nil)
}

pub fn format_six_rejects_pending_without_advancing_its_header_test() {
  let #(path, store, live) = opened("native-old-six")
  let assert Ok(retained) =
    custody.retain_system_intent(
      store,
      intent(live, "native", id(20), "declaration"),
    )
    as "Native work retains."
  let assert Ok(custody.FreshPending(_)) =
    custody.allocate_native_system(store, retained)
    as "Format-seven pending is structurally valid."
  assert custody.close(store) == Ok(Nil)
  mutate(path, "PRAGMA user_version=6")
  let #(session, _, _) = coordinates()
  assert custody.open_with_reports(path, session, limits(), hash)
    |> result.is_error
  assert scalar(path, "PRAGMA user_version") == 6
  mutate(path, "PRAGMA user_version=7")
  let assert Ok(store) =
    custody.open_with_reports(path, session, limits(), hash)
    as "Its actual format remains valid without invented generation links."
  assert custody.close(store) == Ok(Nil)
}

pub fn allocated_pending_does_not_spend_future_ordinals_twice_test() {
  let #(path, store, live) = opened("pending-inventories")
  list.each(
    list.index_map(list.repeat(Nil, 63), fn(_, index) { index }),
    fn(index) {
      let assert Ok(retained) =
        custody.retain_system_intent(
          store,
          intent(
            live,
            "work-" <> int.to_string(index),
            id(100 + index),
            "declaration",
          ),
        )
        as "Each distinct synthetic occurrence reserves one child slot."
      let assert Ok(custody.FreshPending(_)) =
        custody.allocate_native_system(store, retained)
        as "Allocated pending spends its ordinal exactly once."
      assert custody.cancel_native_system(store, retained) == Ok(Nil)
    },
  )
  mutate(path, "UPDATE owner_system_ordinal SET next_ordinal=4095")
  let assert Ok(last) =
    custody.retain_system_intent(
      store,
      intent(live, "last", id(200), "declaration"),
    )
    as "Sixty-three allocated pending rows do not count as future ordinals."
  assert custody.retain_system_intent(
      store,
      intent(live, "overflow", id(201), "declaration"),
    )
    == Error(custody.Capacity)
  let assert Ok(custody.FreshPending(pending)) =
    custody.allocate_native_system(store, last)
    as "Ordinal 4095 remains available to its original reserved slot."
  let #(origin, _, _) = custody.pending_system_fields(pending)
  let assert remote_tool.SystemFields(_, _, 4095) =
    remote_tool.child_fields(origin)
    as "The lifetime counter reaches its actual representation ceiling."
  assert scalar(path, "SELECT next_ordinal FROM owner_system_ordinal") == 4096
  assert scalar(path, "SELECT COUNT(*) FROM owner_system_intent") == 64
  assert scalar(path, "SELECT COUNT(*) FROM owner_custody_children") == 0
  assert custody.close(store) == Ok(Nil)
  let #(session, _, _) = coordinates()
  let assert Ok(store) =
    custody.open_with_reports(path, session, limits(), hash)
    as "Both distinct bounded inventories validate after reopen."
  assert custody.close(store) == Ok(Nil)
}

pub fn derived_workspace_native_checks_retained_parent_and_cancellation_test() {
  let #(path, store, live) = opened("derived-workspace")
  assert custody.admit_registered_fresh_with_profile(
      store,
      live,
      tool(0),
      payload("args"),
      payload("request"),
      custody.OrdinaryFinal,
    )
    == Ok(custody.Fresh)
  let assert Ok(parent) =
    remote_tool.tool_child(tool(0), remote_tool.Workspace(0))
    as "Original semantic parent preserves the actual ToolKey."
  let assert Ok(semantic) =
    custody.workspace_request(limits(), <<"synthetic Invocation envelope">>)
    as "The storage component uses opaque bytes rather than claiming real Git execution."
  assert custody.admit_registered_workspace_child(
      store,
      live,
      parent,
      id(30),
      semantic,
    )
    == Ok(custody.Fresh)
  let assert Ok(checked) =
    custody.semantic_parent(store, live, id(30), <<
      "synthetic Invocation envelope",
    >>)
    as "The owner resolves exact original retained input."
  assert custody.semantic_parent(store, live, id(30), <<"altered input">>)
    == Error(custody.Conflict)
  let assert Ok(native) =
    remote_tool.workspace_command_child(parent, remote_tool.GitStatus)
    as "Native identity is deterministic and disjoint."
  assert custody.admit_registered_child(
      store,
      live,
      native,
      id(31),
      payload("bytes"),
    )
    == Error(custody.Invalid(
      "workspace command requires retained semantic parent",
    ))
  assert custody.admit_workspace_command(
      store,
      checked,
      native,
      id(31),
      payload("bytes"),
    )
    == Ok(custody.Fresh)
  assert custody.admit_workspace_command(
      store,
      checked,
      native,
      id(31),
      payload("bytes"),
    )
    == Ok(custody.Retained)
  assert custody.admit_workspace_command(
      store,
      checked,
      native,
      id(32),
      payload("bytes"),
    )
    == Error(custody.Conflict)
  assert custody.child_generation(store, native)
    == Ok(custody.live_association(live))
  assert scalar(path, "SELECT COUNT(*) FROM owner_custody_children") == 2
  assert custody.cancel_child(store, parent) == Ok(Nil)
  let assert Ok(later) =
    remote_tool.workspace_command_child(parent, remote_tool.GitRevision)
    as "Another fixed phase does not escape parent cancellation."
  assert custody.admit_workspace_command(
      store,
      checked,
      later,
      id(32),
      payload("later"),
    )
    == Error(custody.Frozen)
  assert custody.cancel_child(store, native) == Ok(Nil)
  assert custody.receive_child(
      store,
      native,
      id(31),
      payload("matching late native"),
    )
    == Ok(Nil)
  assert custody.semantic_evidence(store, parent) |> result.is_ok
  assert custody.close(store) == Ok(Nil)
  mutate(path, "PRAGMA user_version=6")
  let #(session, _, _) = coordinates()
  assert custody.open_with_reports(path, session, limits(), hash)
    |> result.is_error
  assert scalar(path, "PRAGMA user_version") == 6
  mutate(path, "PRAGMA user_version=7")
  let assert Ok(store) =
    custody.open_with_reports(path, session, limits(), hash)
    as "Whole immutable derivation survives legitimate reopen."
  assert custody.child_generation(store, native)
    == Ok(custody.live_association(live))
  assert custody.close(store) == Ok(Nil)
}

pub fn derived_system_workspace_requires_the_actual_allocated_semantic_row_test() {
  let #(path, store, live) = opened("derived-system")
  let assert Ok(intent) =
    custody.retain_system_intent(
      store,
      intent(live, "semantic", id(30), "original semantic work"),
    )
    as "Semantic ordinary work retains."
  let assert Ok(semantic) = custody.admit_system_child(store, intent, build)
    as "The original pure workspace family allocates the actual SystemChild."
  let assert Ok(parent) =
    custody.semantic_parent(
      store,
      live,
      semantic.request_id,
      bit_array.from_string(
        remote_tool.child_address(semantic.origin)
        <> ids.entry_id_to_string(semantic.request_id),
      ),
    )
    as "Exact original system semantic bytes resolve."
  let assert Ok(native) =
    remote_tool.workspace_command_child(semantic.origin, remote_tool.GitStatus)
    as "Derivation does not allocate another system ordinal."
  assert custody.admit_workspace_command(
      store,
      parent,
      native,
      id(31),
      payload("actual native bytes"),
    )
    == Ok(custody.Fresh)
  assert scalar(path, "SELECT next_ordinal FROM owner_system_ordinal") == 1
  let assert Ok(fabricated) =
    remote_tool.system_child(
      remote_tool.child_session(semantic.origin),
      "worktree-observation",
      1,
    )
    as "Pure identity syntax alone does not prove system allocation."
  let assert Ok(forged) =
    remote_tool.workspace_command_child(fabricated, remote_tool.GitStatus)
    as "Pure derivation alone supplies no storage permission."
  assert custody.admit_workspace_command(
      store,
      parent,
      forged,
      id(32),
      payload("bytes"),
    )
    == Error(custody.Conflict)
  assert custody.child_generation(store, native)
    == Ok(custody.live_association(live))
  assert custody.close(store) == Ok(Nil)
}

pub fn unallocated_native_cancellation_after_generation_close_spends_once_test() {
  let #(path, store, live) = opened("native-cancel-after-close")
  let assert Ok(retained) =
    custody.retain_system_intent(
      store,
      intent(live, "native", id(20), "original declaration"),
    )
    as "Original occurrence retains before owner closure."
  let charge = scalar(path, "SELECT reserved_bytes FROM owner_system_intent")
  assert custody.retain_generation_close(store, close_record(live), fn(_) {
      Ok(Nil)
    })
    |> result.is_ok
  assert custody.allocate_native_system(store, retained)
    == Error(custody.Frozen)
  assert custody.cancel_native_system(store, retained) == Ok(Nil)
  assert custody.cancel_native_system(store, retained) == Ok(Nil)
  assert scalar(path, "SELECT next_ordinal FROM owner_system_ordinal") == 1
  assert scalar(path, "SELECT COUNT(*) FROM owner_custody_children") == 0
  assert scalar(path, "SELECT reserved_bytes FROM owner_system_intent")
    == charge
  assert scalar(
      path,
      "SELECT COUNT(*) FROM owner_system_intent WHERE child_profile='native_cancelled'",
    )
    == 1
  assert custody.close(store) == Ok(Nil)
}

pub fn allocated_and_cancelled_pending_share_derived_system_quota_group_test() {
  let assert Ok(mixed) = custody.limits(8, 96, 1_048_576, 1024)
    as "The companion limit exceeds 64, so it cannot hide a broken parent-group check."
  let #(path, store, live) =
    opened_with_limits("mixed-system-derived-quota", mixed)
  let assert Ok(retained) =
    custody.retain_system_intent(
      store,
      intent(live, "semantic", id(20), "original semantic declaration"),
    )
    as "Original system workspace occurrence retains."
  let assert Ok(request) =
    custody.workspace_request(limits(), <<
      "synthetic semantic input; no Broker fixture",
    >>)
    as "Storage compares complete bytes while the client owns typed semantics."
  let assert Ok(parent) =
    custody.admit_system_child(store, retained, fn(_, _) {
      Ok(custody.WorkspaceSystem(request))
    })
    as "Actual allocated workspace intent becomes the semantic parent."
  let assert Ok(semantic) =
    custody.semantic_parent(store, live, parent.request_id, <<
      "synthetic semantic input; no Broker fixture",
    >>)
    as "Actual retained semantic origin supplies the checked parent."
  let assert Ok(derived) =
    remote_tool.workspace_command_child(parent.origin, remote_tool.GitStatus)
    as "Derived command stays in the actual original system quota group."
  let pending =
    list.map(
      list.index_map(list.repeat(Nil, 63), fn(_, index) { index }),
      fn(index) {
        let assert Ok(value) =
          custody.retain_system_intent(
            store,
            intent(
              live,
              "pending:" <> int.to_string(index),
              id(100 + index),
              "declaration",
            ),
          )
          as "Pending native slots fill the same original service group."
        assert custody.cancel_native_system(store, value) == Ok(Nil)
        value
      },
    )
  assert list.length(pending) == 63
  let charge =
    scalar(path, "SELECT SUM(reserved_bytes) FROM owner_system_intent")
  assert custody.admit_workspace_command(
      store,
      semantic,
      derived,
      id(300),
      payload("native"),
    )
    == Error(custody.Capacity)
  assert custody.cancel_child(store, derived) == Error(custody.Capacity)
  list.each(pending, fn(value) {
    assert custody.cancel_native_system(store, value) == Ok(Nil)
  })
  assert scalar(path, "SELECT SUM(reserved_bytes) FROM owner_system_intent")
    == charge
  assert scalar(path, "SELECT COUNT(*) FROM owner_custody_children") == 1
  assert scalar(path, "SELECT next_ordinal FROM owner_system_ordinal") == 64
  assert custody.admit_workspace_command(
      store,
      semantic,
      derived,
      id(300),
      payload("native"),
    )
    == Error(custody.Capacity)
  assert custody.close(store) == Ok(Nil)
  let #(session, _, _) = coordinates()
  let assert Ok(reopened) =
    custody.open_with_reports(path, session, mixed, hash)
    as "All permanent pending charges reopen without a fake child link."
  assert custody.close(reopened) == Ok(Nil)
}

pub fn pending_charge_corruption_refuses_before_reopen_without_backfill_test() {
  let #(path, store, live) = opened("pending-undercharge")
  let assert Ok(intent) =
    custody.retain_system_intent(
      store,
      intent(live, "native", id(20), "original declaration"),
    )
    as "Original occurrence retains its full allowance."
  let assert Ok(custody.FreshPending(_)) =
    custody.allocate_native_system(store, intent)
    as "Actual fresh pending stage allocates no child."
  assert custody.close(store) == Ok(Nil)
  mutate(path, "UPDATE owner_system_intent SET reserved_bytes=reserved_bytes-1")
  let #(session, _, _) = coordinates()
  assert custody.open_with_reports(path, session, limits(), hash)
    |> result.is_error
  assert scalar(path, "PRAGMA user_version") == 7
  assert scalar(path, "SELECT COUNT(*) FROM owner_custody_children") == 0
  assert scalar(path, "SELECT next_ordinal FROM owner_system_ordinal") == 1
}

pub fn format_six_admitted_native_history_migrates_without_new_permission_test() {
  let #(path, store, live) = opened("six-native-history")
  let original = intent(live, "native", id(20), "old declaration")
  let assert Ok(retained) = custody.retain_system_intent(store, original)
    as "The original complete intent retains."
  let assert Ok(custody.FreshPending(pending)) =
    custody.allocate_native_system(store, retained)
    as "The test prepares an admitted native row with the unchanged old representation."
  let request = payload("old complete native envelope")
  let assert Ok(admitted) =
    custody.admit_pending_system(store, pending, request)
    as "No pending stage remains in the old-format fixture."
  let before =
    scalar(path, "SELECT SUM(reserved_bytes) FROM owner_system_intent")
  assert custody.close(store) == Ok(Nil)
  mutate(path, "PRAGMA user_version=6")
  let #(session, _, _) = coordinates()
  let assert Ok(reopened) =
    custody.open_with_reports(path, session, limits(), hash)
    as "An exact old admitted native vocabulary migrates transactionally without backfill."
  assert scalar(path, "PRAGMA user_version") == 7
  assert scalar(path, "SELECT SUM(reserved_bytes) FROM owner_system_intent")
    == before
  let assert Ok(history) = custody.read_system_intent(reopened, original)
    as "Original work identity remains historical evidence."
  assert custody.allocate_native_system(reopened, history)
    == Ok(custody.RetainedPending(
      admitted.origin,
      id(20),
      custody.NativeAdmitted,
    ))
  let assert Ok(old) =
    custody.admit_system_child(reopened, history, fn(_, _) {
      Ok(custody.NativeSystem(request))
    })
    as "Old pure native readback remains supported without Fresh allocation."
  assert old.admission == custody.Retained
  assert old.origin == admitted.origin
  assert scalar(path, "SELECT COUNT(*) FROM owner_custody_children") == 1
  assert scalar(path, "SELECT COUNT(*) FROM owner_child_generation") == 1
  assert scalar(path, "SELECT next_ordinal FROM owner_system_ordinal") == 1
  assert custody.close(reopened) == Ok(Nil)
}
