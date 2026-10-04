//// Real SQLite service/offer/native custody and conservative collection controls.

import core/clock
import core/codec
import core/command
import core/entry
import core/ids
import core/json
import core/message
import core/register
import core/remote_tool
import core/tx
import core/workspace
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import sqlight
import storage/owner_command_offers_schema
import storage/owner_custody as custody
import storage/sqlite
import storage/storage
import support/fixtures

fn limits() -> custody.Limits {
  let assert Ok(limits) = custody.limits(8, 64, 1_048_576, 4096)
    as "Finite fixture limits validate."
  limits
}

fn key(index: Int) -> remote_tool.ToolKey {
  let generator = ids.generator(clock.fixed(1000), 77)
  let #(session, generator) = ids.mint_session(generator)
  let #(operation, _) = ids.mint_op(generator)
  let #(entry, _) =
    ids.mint_entry(ids.generator(clock.fixed(1001), index + 100))
  let assert Ok(key) =
    remote_tool.key(
      session,
      operation,
      "parent",
      index,
      string.repeat("a", 64),
      entry,
    )
    as "Complete fixture provenance validates."
  key
}

fn id(seed: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(2000), seed)).0
}

fn make_service(
  parent: remote_tool.ToolKey,
  role: command.ServiceRole,
  input: String,
) -> command.ServiceKey {
  let assert Ok(scope) =
    workspace.scope_from_fields(
      ids.session_id_to_string(remote_tool.session(parent)),
      "repo",
      "executor",
      2,
      3,
    )
    as "Both original authority epochs validate."
  let assert Ok(step) = workspace.step("physical:build")
    as "The physical step is bounded."
  let assert Ok(service) =
    command.service_key(
      parent,
      role,
      scope,
      remote_tool.operation(parent),
      step,
      id(1),
      string.repeat(input, 64),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "The exact original service validates."
  service
}

fn ref(service: command.ServiceKey) -> command.CommandRef {
  let role = case command.service_role(service) {
    command.CompileService -> command.CompileCommand
    command.LaunchService -> command.SatelliteCommand
  }
  let assert Ok(ref) = command.command_ref(service, role)
    as "Closed outer/native purpose agrees."
  ref
}

fn payload(text: String) -> custody.Payload {
  let assert Ok(payload) =
    custody.payload(limits(), bit_array.from_string(text))
    as "Bounded fixture payload validates."
  payload
}

fn request(service: command.ServiceKey) -> custody.ServiceRequest {
  let assert Ok(request) =
    custody.service_request(limits(), service, <<"exact input":utf8>>)
    as "Complete bounded service envelope validates."
  request
}

fn make_offer(
  service: command.ServiceKey,
  bytes: String,
) -> custody.CommandOfferPayload {
  let assert Ok(offer) =
    custody.command_offer_payload(
      limits(),
      ref(service),
      string.repeat("d", 64),
      bit_array.from_string(bytes),
    )
    as "The immutable bounded proposal validates."
  offer
}

fn open(name: String, parent: remote_tool.ToolKey) -> #(String, custody.Store) {
  let path = fixtures.scratch("command-custody-" <> name) <> "/owner.db"
  let assert Ok(store) =
    custody.open(path, remote_tool.session(parent), limits())
    as "Actual separate custody SQLite opens."
  assert custody.admit(store, parent, payload("args"), payload("request"))
    == Ok(Nil)
  #(path, store)
}

pub fn exact_service_offer_native_uuid_survive_reopen_and_changed_offer_conflicts_test() {
  let parent = key(0)
  let service = make_service(parent, command.CompileService, "a")
  let #(path, store) = open("exact-reopen", parent)
  let original = request(service)
  let offer = make_offer(service, "argv/env/cwd/full-policy")
  assert custody.admit_service_child(store, original) == Ok(Nil)
  assert custody.admit_service_child(store, original) == Ok(Nil)
  assert custody.admit_offer(store, original, offer) == Ok(custody.Fresh)
  assert custody.admit_offer(store, original, offer) == Ok(custody.Retained)
  assert custody.admit_offer(
      store,
      original,
      make_offer(service, "changed argv"),
    )
    == Error(custody.Conflict)
  assert custody.admit_command_child(
      store,
      make_offer(service, "changed argv"),
      id(2),
      payload("complete Prepared token A"),
    )
    == Error(custody.Conflict)
  assert custody.child(store, command.native_origin(ref(service)))
    == Error(custody.Missing)
  assert custody.admit_command_child(
      store,
      offer,
      id(2),
      payload("complete Prepared token A"),
    )
    == Ok(#(id(2), payload("complete Prepared token A")))
  assert custody.admit_command_child(
      store,
      offer,
      id(3),
      payload("complete Prepared token A"),
    )
    == Ok(#(id(2), payload("complete Prepared token A")))
  assert custody.admit_command_child(
      store,
      offer,
      id(3),
      payload("replacement token B"),
    )
    == Error(custody.Conflict)
  assert custody.close(store) == Ok(Nil)
  let assert Ok(store) =
    custody.open(path, remote_tool.session(parent), limits())
    as "Custody reopens without the original callback."
  assert custody.service_child(store, service) == Ok(#(original, None))
  assert custody.offer(store, ref(service)) == Ok(offer)
  assert custody.command_child(store, ref(service))
    == Ok(#(id(2), payload("complete Prepared token A"), None))
  let changed = make_service(parent, command.CompileService, "b")
  assert custody.service_child(store, changed) == Error(custody.Conflict)
  assert custody.admit_offer(
      store,
      request(changed),
      make_offer(changed, "same command"),
    )
    == Error(custody.Conflict)
  assert custody.close(store) == Ok(Nil)
}

pub fn cancellation_before_offer_and_native_allocation_is_permanent_test() {
  let parent = key(0)
  let service = make_service(parent, command.LaunchService, "a")
  let #(path, store) = open("pre-offer-cancel", parent)
  assert custody.cancel_service(store, service) == Ok(Nil)
  assert custody.cancel_service(store, service) == Ok(Nil)
  assert custody.admit_service_child(store, request(service))
    == Error(custody.Frozen)
  assert custody.admit_offer(
      store,
      request(service),
      make_offer(service, "exact command"),
    )
    == Error(custody.Frozen)
  assert custody.admit_command_child(
      store,
      make_offer(service, "exact command"),
      id(2),
      payload("complete Prepared"),
    )
    == Error(custody.Frozen)
  assert custody.child(store, command.native_origin(ref(service)))
    == Error(custody.Missing)
  assert custody.close(store) == Ok(Nil)
  let assert Ok(store) =
    custody.open(path, remote_tool.session(parent), limits())
    as "The pre-allocation fence survives reopen."
  assert custody.admit_service_child(store, request(service))
    == Error(custody.Frozen)
  assert custody.close(store) == Ok(Nil)
}

pub fn cancellation_preserves_allocated_native_uuid_and_late_receipt_test() {
  let parent = key(0)
  let service = make_service(parent, command.CompileService, "a")
  let #(_, store) = open("late-native", parent)
  let offer = make_offer(service, "exact command")
  assert custody.admit_service_child(store, request(service)) == Ok(Nil)
  assert custody.admit_offer(store, request(service), offer)
    == Ok(custody.Fresh)
  assert custody.admit_command_child(
      store,
      offer,
      id(2),
      payload("complete Prepared"),
    )
    == Ok(#(id(2), payload("complete Prepared")))
  assert custody.cancel_service(store, service) == Ok(Nil)
  assert custody.cancel_service(store, service) == Ok(Nil)
  assert custody.offer(store, ref(service)) == Error(custody.Frozen)
  assert custody.admit_command_child(
      store,
      offer,
      id(3),
      payload("complete Prepared"),
    )
    == Error(custody.Frozen)
  assert custody.receive_child(
      store,
      command.native_origin(ref(service)),
      id(2),
      payload("late exact native terminal"),
    )
    == Ok(Nil)
  assert custody.command_child(store, ref(service))
    == Ok(#(
      id(2),
      payload("complete Prepared"),
      Some(payload("late exact native terminal")),
    ))
  let assert Ok(completion) =
    custody.workspace_completion(limits(), <<"outer terminal":utf8>>)
    as "Outer completion is bounded."
  assert custody.receive_workspace_child(
      store,
      command.service_origin(service),
      id(1),
      completion,
    )
    == Error(custody.Frozen)
  assert custody.close(store) == Ok(Nil)
}

fn scalar(db: sqlight.Connection, sql: String) -> Int {
  let assert Ok([value]) =
    sqlight.query(sql, db, [], decode.field(0, decode.int, decode.success))
    as "The bounded scalar is an exact singleton."
  value
}

fn corrupt(path: String, sql: String) {
  let assert Ok(db) = sqlight.open(path)
    as "Test-only corruption connection opens."
  assert sqlight.exec(sql, db) == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
}

pub fn additive_v2_upgrade_preserves_original_child_and_refuses_bad_limits_before_ddl_test() {
  let parent = key(0)
  let #(path, store) = open("v2-migrate", parent)
  let assert Ok(native) =
    remote_tool.tool_child(parent, remote_tool.CompileCommand)
    as "Existing native-only child has its disjoint role."
  assert custody.admit_child(
      store,
      native,
      id(2),
      payload("original v2 native"),
    )
    == Ok(Nil)
  assert custody.close(store) == Ok(Nil)
  corrupt(
    path,
    "DROP TABLE owner_custody_command_offers; PRAGMA user_version=2",
  )
  let assert Ok(store) =
    custody.open(path, remote_tool.session(parent), limits())
    as "The additive migration preserves live custody."
  assert custody.child(store, native)
    == Ok(#(id(2), payload("original v2 native"), None))
  assert custody.close(store) == Ok(Nil)
  let assert Ok(db) = sqlight.open(path) as "Migrated schema is inspectable."
  assert scalar(db, "PRAGMA user_version") == 3
  assert scalar(db, "SELECT COUNT(*) FROM owner_custody_command_offers") == 0
  assert sqlight.close(db) == Ok(Nil)
  corrupt(
    path,
    "DROP TABLE owner_custody_command_offers; PRAGMA user_version=2; UPDATE owner_custody_meta SET tool_limit=9",
  )
  assert custody.open(path, remote_tool.session(parent), limits())
    == Error(custody.Conflict)
  let assert Ok(db) = sqlight.open(path) as "Refused v2 is still inspectable."
  assert scalar(db, "PRAGMA user_version") == 2
  assert scalar(
      db,
      "SELECT COUNT(*) FROM sqlite_master WHERE name='owner_custody_command_offers'",
    )
    == 0
  assert sqlight.close(db) == Ok(Nil)
}

pub fn v2_collected_preallocation_cancellation_fence_migrates_without_losing_replay_guard_test() {
  let parent = key(0)
  let #(path, store) = open("v2-collected-cancel", parent)
  let assert Ok(origin) =
    remote_tool.tool_child(parent, remote_tool.CompileCommand)
    as "The prior native-only cancellation uses its original child address."
  assert custody.cancel_child(store, origin) == Ok(Nil)
  let #(proof, source, _) =
    committed_unknown(store, parent, "v2-collected-cancel")
  assert custody.collect(store, proof) == Ok(Nil)
  assert custody.child(store, origin) == Error(custody.Frozen)

  // An unrelated live child must remain available after the journal upgrades.
  let live = key(1)
  let assert Ok(live_origin) =
    remote_tool.tool_child(live, remote_tool.SatelliteCommand)
    as "The unrelated allocation has a separate native identity."
  assert custody.admit(store, live, payload("args"), payload("request"))
    == Ok(Nil)
  assert custody.admit_child(store, live_origin, id(2), payload("live request"))
    == Ok(Nil)
  assert custody.close(store) == Ok(Nil)
  assert storage.close(source) == Ok(Nil)

  // The unchanged prior API history supplies the exact format-2 row shape.
  corrupt(
    path,
    "DROP TABLE owner_custody_command_offers; PRAGMA user_version=2",
  )
  let assert Ok(db) = sqlight.open(path)
    as "The genuine collected cancellation history is inspectable."
  assert scalar(
      db,
      "SELECT COUNT(*) FROM owner_custody_children WHERE request_id IS NULL AND state='frozen' AND typeof(request)='blob' AND length(request)=0 AND terminal IS NULL",
    )
    == 1
  assert sqlight.close(db) == Ok(Nil)
  let assert Ok(store) =
    custody.open(path, remote_tool.session(parent), limits())
    as "A valid prior collected ID-less cancellation fence must migrate."
  assert custody.lookup(store, parent) == Ok(custody.Collected)
  assert custody.child(store, origin) == Error(custody.Frozen)
  assert custody.admit_child(store, origin, id(3), payload("replacement"))
    == Error(custody.Frozen)
  assert custody.child(store, live_origin)
    == Ok(#(id(2), payload("live request"), None))
  assert custody.close(store) == Ok(Nil)
  let assert Ok(db) = sqlight.open(path)
    as "The migrated permanent fence remains inspectable."
  assert scalar(db, "PRAGMA user_version") == 3
  assert scalar(db, "SELECT COUNT(*) FROM owner_custody_command_offers") == 0
  assert sqlight.close(db) == Ok(Nil)
}

pub fn v2_idless_fences_refuse_malformed_state_body_terminal_or_reservation_test() {
  list.index_map(
    ["state='retained'", "request=X'01'", "terminal=X'01'", "reserved_bytes=1"],
    fn(change, index) {
      let parent = key(index)
      let name = "v2-bad-fence-" <> ids.entry_id_to_string(id(index))
      let #(path, store) = open(name, parent)
      let assert Ok(origin) =
        remote_tool.tool_child(parent, remote_tool.CompileCommand)
        as "The original cancellation precedes any native UUID."
      assert custody.cancel_child(store, origin) == Ok(Nil)
      let #(proof, source, _) = committed_unknown(store, parent, name)
      assert custody.collect(store, proof) == Ok(Nil)
      assert custody.close(store) == Ok(Nil)
      assert storage.close(source) == Ok(Nil)
      corrupt(
        path,
        "DROP TABLE owner_custody_command_offers; PRAGMA user_version=2; UPDATE owner_custody_children SET "
          <> change,
      )
      assert custody.open(path, remote_tool.session(parent), limits())
        == Error(custody.Invalid("invalid legacy custody headers"))
      let assert Ok(db) = sqlight.open(path)
        as "Malformed format-2 fences refuse before additive DDL."
      assert scalar(db, "PRAGMA user_version") == 2
      assert scalar(
          db,
          "SELECT COUNT(*) FROM sqlite_master WHERE name='owner_custody_command_offers'",
        )
        == 0
      assert sqlight.close(db) == Ok(Nil)
    },
  )
}

pub fn v2_corrupt_header_refuses_before_additive_schema_mutation_test() {
  let parent = key(0)
  let #(path, store) = open("v2-corrupt", parent)
  assert custody.close(store) == Ok(Nil)
  corrupt(
    path,
    "DROP TABLE owner_custody_command_offers; PRAGMA user_version=2; UPDATE owner_custody_tools SET reserved_bytes=1",
  )
  assert custody.open(path, remote_tool.session(parent), limits())
    == Error(custody.Invalid("invalid legacy custody headers"))
  let assert Ok(db) = sqlight.open(path)
    as "The refused migration is inspectable."
  assert scalar(db, "PRAGMA user_version") == 2
  assert scalar(
      db,
      "SELECT COUNT(*) FROM sqlite_master WHERE name='owner_custody_command_offers'",
    )
    == 0
  assert sqlight.close(db) == Ok(Nil)
}

pub fn offer_header_type_size_reservation_and_identity_corruption_refuse_test() {
  list.index_map(
    [
      "offer=zeroblob(262145)", "offer=CAST(X'6162' AS TEXT)",
      "reserved_bytes=1", "identity=zeroblob(8193)", "identity=X'5b5d'",
      "service_id='changed'",
    ],
    fn(change, index) {
      let parent = key(index)
      let service = make_service(parent, command.CompileService, "a")
      let #(path, store) =
        open("offer-corrupt-" <> ids.entry_id_to_string(id(index)), parent)
      assert custody.admit_service_child(store, request(service)) == Ok(Nil)
      assert custody.admit_offer(
          store,
          request(service),
          make_offer(service, "exact command"),
        )
        == Ok(custody.Fresh)
      assert custody.close(store) == Ok(Nil)
      corrupt(path, "UPDATE owner_custody_command_offers SET " <> change)
      let assert Ok(store) =
        custody.open(path, remote_tool.session(parent), limits())
        as "Metadata opens without transferring the corrupt offer BLOB."
      assert custody.offer(store, ref(service)) |> result.is_error
      assert custody.close(store) == Ok(Nil)
    },
  )
}

pub fn complete_service_and_native_headers_are_total_and_bounded_test() {
  let parent = key(0)
  let service = make_service(parent, command.CompileService, "a")
  let #(path, store) = open("service-corrupt-header", parent)
  assert custody.admit_service_child(store, request(service)) == Ok(Nil)
  assert custody.close(store) == Ok(Nil)
  corrupt(path, "UPDATE owner_custody_children SET request=X'ffffffff'")
  let assert Ok(store) =
    custody.open(path, remote_tool.session(parent), limits())
    as "Service payload decoding follows bounded SQL headers."
  assert custody.service_child(store, service)
    == Error(custody.Invalid(
      "owner payload exceeds bound before materialization",
    ))
  assert custody.close(store) == Ok(Nil)
}

fn final_unknown() -> message.AgentMessage {
  message.ToolResultMessage(
    tool_call_id: "call",
    tool_name: "remote",
    content: [message.ToolResultText("ResourceOutcomeUnknown", None)],
    details: None,
    usage: None,
    added_tool_names: None,
    is_error: True,
    timestamp: 1,
  )
}

pub fn final_unknown_readback_cannot_collect_service_without_any_offer_test() {
  let parent = key(0)
  let service = make_service(parent, command.LaunchService, "a")
  let #(_, store) = open("unknown-no-offer-collect", parent)
  assert custody.admit_service_child(store, request(service)) == Ok(Nil)
  let #(proof, source, outcome) = committed_unknown(store, parent, "no-offer")
  assert custody.collect(store, proof) == Error(custody.CollectionPending)
  assert custody.lookup(store, parent) == Ok(custody.FinalOutcome(outcome))
  assert custody.service_child(store, service) == Ok(#(request(service), None))
  assert custody.cancel_service(store, service) == Ok(Nil)
  assert custody.collect(store, proof) == Error(custody.CollectionPending)
  assert custody.close(store) == Ok(Nil)
  assert storage.close(source) == Ok(Nil)
}

fn committed_unknown(
  store: custody.Store,
  parent: remote_tool.ToolKey,
  name: String,
) {
  let outcome =
    final_unknown() |> codec.encode_message |> json.to_string |> payload
  assert custody.finish(store, parent, outcome) == Ok(Nil)
  let root = fixtures.scratch("command-custody-session-readback-" <> name)
  let assert Ok(source) =
    sqlite.open(
      sqlite.config(root <> "/session.db", "command-custody"),
      clock.stepping(1000, 1),
    )
    as "Collection reads actual conversation SQLite."
  let result_entry =
    entry.MessageEntry(
      id: remote_tool.result_entry(parent),
      parent: None,
      seq: 0,
      ts: 0,
      message: final_unknown(),
      terminate: False,
    )
  let assert Ok(_) =
    storage.commit(
      source,
      tx.Tx(
        [
          tx.InsertEntry(result_entry),
          tx.SetRegister(
            register.FactCustom,
            "session/id",
            register.value(
              json.String(ids.session_id_to_string(remote_tool.session(parent))),
            ),
          ),
        ],
        [],
      ),
    )
    as "The exact final Unknown is committed at its reserved result entry."
  let assert Ok(proof) =
    custody.verify_commit(store, parent, source, fn(exact, readback) {
      case
        custody.bytes(exact) == custody.bytes(outcome)
        && readback.message == final_unknown()
        && readback.termination == custody.Continues
      {
        True -> Ok(Nil)
        False -> Error("changed actual final readback")
      }
    })
    as "Final Unknown readback supplies only the ordinary result proof."
  #(proof, source, outcome)
}

pub fn generated_offer_migration_schema_matches_source_test() {
  let assert Ok(source) = simplifile.read("sql/owner_command_offers.sql")
    as "The named additive DDL exists."
  assert source == owner_command_offers_schema.schema
}

pub fn offer_full_allowance_refuses_capacity_without_native_or_offer_mutation_test() {
  let parent = key(0)
  let service = make_service(parent, command.CompileService, "a")
  let path = fixtures.scratch("command-custody-offer-byte-cap") <> "/owner.db"
  let assert Ok(small) = custody.limits(8, 64, 12_000, 4096)
    as "Persistent total bytes are deliberately scarce."
  let assert Ok(store) = custody.open(path, remote_tool.session(parent), small)
    as "The small empty journal opens."
  assert custody.admit(store, parent, payload("args"), payload("request"))
    == Ok(Nil)
  assert custody.admit_service_child(store, request(service)) == Ok(Nil)
  assert custody.admit_offer(
      store,
      request(service),
      make_offer(service, "tiny exact command"),
    )
    == Error(custody.Capacity)
  assert custody.offer(store, ref(service)) == Error(custody.Missing)
  assert custody.child(store, command.native_origin(ref(service)))
    == Error(custody.Missing)
  assert custody.service_child(store, service) == Ok(#(request(service), None))
  assert custody.close(store) == Ok(Nil)
}

pub fn native_reservation_respects_original_actual_child_64_ceiling_test() {
  let parent = key(0)
  let service = make_service(parent, command.CompileService, "a")
  let #(_, store) = open("native-child-cap", parent)
  assert custody.admit_service_child(store, request(service)) == Ok(Nil)
  assert custody.admit_offer(
      store,
      request(service),
      make_offer(service, "exact command"),
    )
    == Ok(custody.Fresh)
  int.range(0, 63, Nil, fn(_, index) {
    let assert Ok(origin) =
      remote_tool.tool_child(parent, remote_tool.Workspace(index))
      as "Each real semantic child has a disjoint ordinal."
    assert custody.admit_child(
        store,
        origin,
        id(index + 100),
        payload("semantic child"),
      )
      == Ok(Nil)
    Nil
  })
  assert custody.admit_command_child(
      store,
      make_offer(service, "exact command"),
      id(2),
      payload("complete Prepared"),
    )
    == Error(custody.Capacity)
  assert custody.child(store, command.native_origin(ref(service)))
    == Error(custody.Missing)
  assert custody.offer(store, ref(service))
    == Ok(make_offer(service, "exact command"))
  assert custody.close(store) == Ok(Nil)
}

pub fn fixed_two_offer_purposes_and_frozen_fences_never_evict_test() {
  let parent = key(0)
  let compile = make_service(parent, command.CompileService, "a")
  let launch = make_service(parent, command.LaunchService, "a")
  let #(path, store) = open("fixed-offer-purposes", parent)
  assert custody.admit_service_child(store, request(compile)) == Ok(Nil)
  // The outer service IDs are globally unique even beneath one parent.
  let #(scope, operation, step) = command.coordinates(launch)
  let #(input, registration, contract) = command.digests(launch)
  let assert Ok(launch) =
    command.service_key(
      parent,
      command.LaunchService,
      scope,
      operation,
      step,
      id(4),
      input,
      registration,
      contract,
    )
    as "The Launch service owns its distinct original UUID."
  assert custody.admit_service_child(store, request(launch)) == Ok(Nil)
  assert custody.admit_offer(
      store,
      request(compile),
      make_offer(compile, "compile command"),
    )
    == Ok(custody.Fresh)
  assert custody.admit_offer(
      store,
      request(launch),
      make_offer(launch, "satellite command"),
    )
    == Ok(custody.Fresh)
  assert custody.close(store) == Ok(Nil)
  corrupt(
    path,
    "UPDATE owner_custody_command_offers SET state='frozen', offer=X'', reserved_bytes=reserved_bytes-4096",
  )
  let assert Ok(store) =
    custody.open(path, remote_tool.session(parent), limits())
    as "Permanent offer fences consume capacity after reopen."
  assert custody.offer(store, ref(compile)) == Error(custody.Frozen)
  assert custody.admit_offer(
      store,
      request(compile),
      make_offer(compile, "replacement"),
    )
    == Error(custody.Frozen)
  assert custody.admit_command_child(
      store,
      make_offer(compile, "compile command"),
      id(2),
      payload("complete Prepared"),
    )
    == Error(custody.Frozen)
  assert custody.close(store) == Ok(Nil)
  let assert Ok(db) = sqlight.open(path)
    as "Frozen rows are still durably present."
  assert scalar(db, "SELECT COUNT(*) FROM owner_custody_command_offers") == 2
  assert scalar(
      db,
      "SELECT MIN(reserved_bytes)>0 FROM owner_custody_command_offers",
    )
    == 1
  assert sqlight.close(db) == Ok(Nil)
}

pub fn orphan_corrupt_offer_cannot_evade_final_readback_collection_guard_test() {
  let parent = key(0)
  let service = make_service(parent, command.CompileService, "a")
  let #(path, store) = open("orphan-offer", parent)
  assert custody.admit_service_child(store, request(service)) == Ok(Nil)
  assert custody.admit_offer(
      store,
      request(service),
      make_offer(service, "exact command"),
    )
    == Ok(custody.Fresh)
  corrupt(
    path,
    "DELETE FROM owner_custody_children; UPDATE owner_custody_command_offers SET offer=zeroblob(262145)",
  )
  assert custody.offer(store, ref(service)) == Error(custody.Missing)
  let #(proof, source, outcome) =
    committed_unknown(store, parent, "orphan-offer")
  assert custody.collect(store, proof) == Error(custody.CollectionPending)
  assert custody.lookup(store, parent) == Ok(custody.FinalOutcome(outcome))
  assert custody.close(store) == Ok(Nil)
  let assert Ok(db) = sqlight.open(path)
    as "The orphan recovery bytes were not collected."
  assert scalar(db, "SELECT LENGTH(offer) FROM owner_custody_command_offers")
    == 262_145
  assert sqlight.close(db) == Ok(Nil)
  assert storage.close(source) == Ok(Nil)
}

pub fn impossible_per_parent_offer_overcount_refuses_before_blob_materialization_test() {
  let parent = key(0)
  let service = make_service(parent, command.CompileService, "a")
  let #(path, store) = open("impossible-offer-count", parent)
  assert custody.admit_service_child(store, request(service)) == Ok(Nil)
  assert custody.admit_offer(
      store,
      request(service),
      make_offer(service, "exact command"),
    )
    == Ok(custody.Fresh)
  corrupt(
    path,
    "INSERT INTO owner_custody_command_offers SELECT address || '-corrupt1', parent, service_origin, service_id, identity, native_origin || '-corrupt1', offer_digest, zeroblob(262145), state, reserved_bytes FROM owner_custody_command_offers; INSERT INTO owner_custody_command_offers SELECT address || '-corrupt2', parent, service_origin, service_id, identity, native_origin || '-corrupt2', offer_digest, zeroblob(262145), state, reserved_bytes FROM owner_custody_command_offers LIMIT 1",
  )
  assert custody.offer(store, ref(service))
    == Error(custody.Invalid(
      "command offer count exceeds fixed service purposes",
    ))
  assert custody.close(store) == Ok(Nil)
}
