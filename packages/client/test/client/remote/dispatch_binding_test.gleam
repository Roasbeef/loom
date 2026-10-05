//// Focused custody adapter tests use the actual custodian and SQLite database.
////
//// Callbacks are exercised directly through the production configuration. TLS
//// membership comes from a private TLS-configured VM; no executor is contacted.
//// These tests establish durable binding and receipt behavior, not product E2E.

import broker/dispatch
import broker/exec
import client/remote/custodian
import client/remote/dispatch_binding
import core/clock
import core/ids
import core/msgpack as mp
import core/remote_tool
import executor
import executor/remote/beam_endpoint as connection
import executor/remote/dispatcher
import executor/remote/distribution
import executor/remote/identity
import executor/remote/journal_codec
import executor/remote/wire
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import simplifile
import storage/owner_custody as custody
import support/beam_owner_fixture
import weft/poll
import weft/registry

type Fixture {
  Fixture(owner: custodian.Handle, config: custodian.Config, pid: process.Pid)
}

fn session_id(number: Int) -> ids.SessionId {
  ids.mint_session(ids.generator(clock.fixed(1000), number)).0
}

fn operation(number: Int) -> ids.OpId {
  ids.mint_op(ids.generator(clock.fixed(1000), number)).0
}

fn request_id(number: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(1000), number)).0
}

fn scope() -> identity.Scope {
  let assert Ok(workspace) = identity.workspace_id("checkout")
    as "The fixture workspace has a valid administrative label."
  let assert Ok(executor) = identity.executor_id("linux")
    as "The executor is provisioned independently of its hostname."
  let assert Ok(epoch) = identity.epoch(1) as "The original epochs are valid."
  identity.scope(session_id(1), workspace, executor, epoch, epoch)
}

fn parent() -> remote_tool.ToolKey {
  let assert Ok(key) =
    remote_tool.key(
      session_id(1),
      operation(2),
      "parent:tools",
      0,
      string.repeat("a", 64),
      request_id(3),
    )
    as "The parent retains the original runtime tool identity."
  key
}

fn origin(number: Int) -> remote_tool.ChildOrigin {
  let assert Ok(origin) =
    remote_tool.system_child(session_id(1), "fixture", number)
    as "Each system child has an explicit original service and ordinal."
  origin
}

fn limits(children: Int) -> custody.Limits {
  let assert Ok(limits) = custody.limits(4, children, 16_777_216, 2_097_152)
    as "The fixture reserves enough durable receipt space within hard ceilings."
  limits
}

fn fixture(name: String, limits: custody.Limits) -> Fixture {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let directory =
    "/private/tmp/loom-dispatch-binding-"
    <> name
    <> "-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "This test owns a fresh directory without removing shared files."
  let path = directory <> "/owner.sqlite"
  let assert Ok(store) = custody.open(path, session_id(1), limits)
    as "Fixture admission uses actual SQLite."
  let assert Ok(bytes) = custody.payload(limits, <<"parent request":utf8>>)
    as "The immutable parent fixture fits."
  assert custody.admit_fresh(store, parent(), bytes, bytes) == Ok(custody.Fresh)
  assert custody.close(store) == Ok(Nil)

  let assert Ok(names) = registry.start()
    as "A fresh registry owns this fixture's supervised address."
  let assert Ok(config) =
    custodian.config(path, session_id(1), limits, 1, 5000, fn(_, _, _) {
      panic as "These callback tests never execute a tool body."
    })
    as "The actual custodian config has finite capacity and lifetime."
  let owner = custodian.new(names, config)
  let assert Ok(started) = custodian.start(owner, config)
    as "The actual custodian reopens the seeded journal."
  Fixture(owner, config, started.pid)
}

fn stop(fixture: Fixture) -> Nil {
  let monitor = process.monitor(fixture.pid)
  assert custodian.stop(fixture.owner) == Ok(Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "The old SQLite owner closes before reopen."
  Nil
}

fn connection(
  scope: identity.Scope,
  peer: distribution.Peer,
) -> connection.Config {
  let fields = identity.scope_fields(scope)
  connection.Config(
    peer:,
    owner: "owner",
    executor: fields.2,
    scope:,
    generation: 1,
    within_ms: 1000,
  )
}

fn prepared() -> wire.Prepared {
  let assert Ok(registration) = identity.digest(<<7:size(256)>>)
    as "Registration evidence has the exact digest width."
  wire.Prepared(
    "physical:compile",
    registration,
    wire.Finite(5000),
    exec.ExecRequest(
      ["/bin/sh", "-c", "printf exact"],
      [#("LANG", "C")],
      "/executor/checkout",
      Some(executor.base_policy("/executor/checkout")),
      <<9:size(256)>>,
      exec.PlatformEnforcement,
    ),
    wire.Logs,
  )
}

fn dispatch(origin: remote_tool.ChildOrigin) -> dispatch.Dispatch {
  let prepared = prepared()
  dispatch.Dispatch(
    dispatch.CallContext(operation(4), prepared.step, Some(origin)),
    prepared.request,
    11,
    6000,
    clock.fixed(1000),
    None,
    fn(_) { Nil },
    fn(_) { Nil },
  )
}

fn config(
  fixture: Fixture,
  connection: connection.Config,
  prepared: wire.Prepared,
  candidate: ids.EntryId,
  fenced: process.Subject(custody.Error),
) -> dispatcher.Config {
  let assert Ok(binding) =
    dispatch_binding.new(
      fixture.owner,
      connection,
      fn(_) { Ok(prepared) },
      fn() { candidate },
      poll.monotonic().now,
      17,
      5000,
      fn(error) { process.send(fenced, error) },
    )
    as "The opaque production binding validates before exposing callbacks."
  dispatch_binding.configuration(binding)
}

fn untouched(owner: custodian.Handle, origin: remote_tool.ChildOrigin) -> Nil {
  let assert Ok(#(_, _, None)) = custodian.child(owner, origin)
    as "Failed receipt verification leaves the real SQLite terminal NULL."
  Nil
}

pub fn exact_retry_retains_original_uuid_and_physical_coordinates_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@dispatch_binding_test",
    "exact_retry_retains_original_uuid_and_physical_coordinates_test",
  )
  let fixture = fixture("retry", limits(8))
  let fenced = process.new_subject()
  let assert Ok(origin) = remote_tool.tool_child(parent(), remote_tool.Compile)
    as "The compile child preserves its immutable parent key."
  let request = dispatch(origin)
  let first =
    config(
      fixture,
      connection(scope(), peer),
      prepared(),
      request_id(10),
      fenced,
    )
  let second =
    config(
      fixture,
      connection(scope(), peer),
      prepared(),
      request_id(11),
      fenced,
    )
  let assert Ok(reserved) = first.reserve(request)
    as "Reservation commits before exposing a sendable key."
  assert second.reserve(dispatch.Dispatch(..request, seq: 99)) == Ok(reserved)
  assert reserved.prepared == prepared()
  assert identity.key_scope(reserved.key) == scope()
  assert identity.key_fields(reserved.key)
    == #(
      ids.op_id_to_string(operation(4)),
      ids.entry_id_to_string(request_id(10)),
    )
  assert remote_tool.operation(parent()) != request.context.operation
  assert remote_tool.step(parent()) != reserved.prepared.step
  let assert Ok(#(id, bytes, None)) = custodian.child(fixture.owner, origin)
    as "The exact envelope is durable under the unchanged original child."
  assert id == request_id(10)
  let assert Ok(encoded) = wire.encode_prepared(prepared())
    as "The bare Prepared is valid but does not contain administrative scope."
  assert bytes != encoded
  assert mp.decode(bytes)
    == Ok(
      mp.ArrayValue([
        mp.IntValue(1),
        mp.StringValue("owner"),
        mp.BinaryValue(journal_codec.binding(scope())),
        mp.StringValue(ids.op_id_to_string(operation(4))),
        mp.StringValue(prepared().step),
        mp.BinaryValue(encoded),
      ]),
    )
  first.uncertain(reserved.key, digest(reserved))
  assert custodian.child(fixture.owner, origin) == Ok(#(id, bytes, None))
  assert process.receive(fenced, 0) == Error(Nil)
  stop(fixture)
}

fn digest(reserved: dispatcher.Reserved) -> identity.Digest {
  let assert Ok(digest) = wire.prepared_digest(reserved.prepared)
    as "The exact canonical Prepared digest is computed by production wire."
  digest
}

pub fn changed_prepared_step_operation_and_administrative_scope_conflict_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@dispatch_binding_test",
    "changed_prepared_step_operation_and_administrative_scope_conflict_test",
  )
  let fixture = fixture("conflicts", limits(8))
  let fenced = process.new_subject()
  let request = dispatch(origin(0))
  let original = prepared()
  let first =
    config(fixture, connection(scope(), peer), original, request_id(10), fenced)
  let assert Ok(reserved) = first.reserve(request)
    as "The original immutable envelope commits once."
  let changed = [
    wire.Prepared(..original, stream: wire.ProtocolStream),
    wire.Prepared(..original, lifetime: wire.Finite(4000)),
    wire.Prepared(..original, step: "physical:job"),
    wire.Prepared(
      ..original,
      request: exec.ExecRequest(..original.request, argv: ["/bin/false"]),
    ),
  ]
  list.each(changed, fn(prepared) {
    let config =
      config(
        fixture,
        connection(scope(), peer),
        prepared,
        request_id(11),
        fenced,
      )
    assert config.reserve(
        dispatch.Dispatch(
          ..request,
          context: dispatch.CallContext(..request.context, step: prepared.step),
          request: prepared.request,
        ),
      )
      == Error(Nil)
  })
  assert first.reserve(
      dispatch.Dispatch(
        ..request,
        context: dispatch.CallContext(
          ..request.context,
          operation: operation(5),
        ),
      ),
    )
    == Error(Nil)

  let assert Ok(workspace) = identity.workspace_id("other-checkout")
    as "A changed workspace is valid configuration but cannot replace old custody."
  let assert Ok(executor) = identity.executor_id("linux")
    as "The original executor label is valid."
  let assert Ok(other_executor) = identity.executor_id("other-linux")
    as "The changed executor label is valid."
  let assert Ok(epoch1) = identity.epoch(1) as "The original epoch is valid."
  let assert Ok(epoch2) = identity.epoch(2) as "The changed epoch is valid."
  let assert Ok(original_workspace) = identity.workspace_id("checkout")
    as "The original workspace label is valid."
  let changed_scopes = [
    identity.scope(session_id(1), workspace, executor, epoch1, epoch1),
    identity.scope(
      session_id(1),
      original_workspace,
      other_executor,
      epoch1,
      epoch1,
    ),
    identity.scope(session_id(1), original_workspace, executor, epoch2, epoch1),
    identity.scope(session_id(1), original_workspace, executor, epoch1, epoch2),
    identity.scope(session_id(2), original_workspace, executor, epoch1, epoch1),
  ]
  list.each(changed_scopes, fn(scope) {
    let changed =
      config(fixture, connection(scope, peer), original, request_id(11), fenced)
    assert changed.reserve(request) == Error(Nil)
    assert changed.receive(origin(0), reserved.key, digest(reserved), [], <<1>>)
      == Error(Nil)
  })
  let changed_owner =
    config(
      fixture,
      connection.Config(..connection(scope(), peer), owner: "other-owner"),
      original,
      request_id(11),
      fenced,
    )
  assert changed_owner.reserve(request) == Error(Nil)
  untouched(fixture.owner, origin(0))
  stop(fixture)
}

pub fn missing_foreign_origin_and_changed_clearance_are_refused_before_reserve_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@dispatch_binding_test",
    "missing_foreign_origin_and_changed_clearance_are_refused_before_reserve_test",
  )
  let fixture = fixture("clearance", limits(8))
  let fenced = process.new_subject()
  let request = dispatch(origin(0))
  let config =
    config(
      fixture,
      connection(scope(), peer),
      prepared(),
      request_id(10),
      fenced,
    )
  assert config.reserve(
      dispatch.Dispatch(
        ..request,
        context: dispatch.CallContext(..request.context, origin: None),
      ),
    )
    == Error(Nil)
  let assert Ok(foreign) = remote_tool.system_child(session_id(2), "fixture", 0)
    as "A foreign session origin remains a valid typed origin."
  assert config.reserve(dispatch(foreign)) == Error(Nil)
  assert config.reserve(
      dispatch.Dispatch(
        ..request,
        request: exec.ExecRequest(..request.request, token: <<8:size(256)>>),
      ),
    )
    == Error(Nil)
  assert config.reserve(
      dispatch.Dispatch(
        ..request,
        context: dispatch.CallContext(
          ..request.context,
          step: "changed:cleared-step",
        ),
      ),
    )
    == Error(Nil)
  assert custodian.child(fixture.owner, origin(0)) == Error(custody.Missing)
  stop(fixture)
}

pub fn cross_child_cross_id_scope_operation_and_digest_receipts_leave_null_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@dispatch_binding_test",
    "cross_child_cross_id_scope_operation_and_digest_receipts_leave_null_test",
  )
  let fixture = fixture("forgeries", limits(8))
  let fenced = process.new_subject()
  let first =
    config(
      fixture,
      connection(scope(), peer),
      prepared(),
      request_id(10),
      fenced,
    )
  let second =
    config(
      fixture,
      connection(scope(), peer),
      prepared(),
      request_id(11),
      fenced,
    )
  let assert Ok(a) = first.reserve(dispatch(origin(0)))
    as "First child reserves its original UUID."
  let assert Ok(b) = second.reserve(dispatch(origin(1)))
    as "Second child reserves a different UUID."
  assert first.receive(origin(1), a.key, digest(a), [], <<1>>) == Error(Nil)
  assert first.receive(origin(0), b.key, digest(a), [], <<1>>) == Error(Nil)
  let assert Ok(id) =
    identity.request_id(ids.entry_id_to_string(request_id(10)))
    as "The original request UUID parses."
  let other_operation = identity.request_key(scope(), operation(5), id)
  assert first.receive(origin(0), other_operation, digest(a), [], <<1>>)
    == Error(Nil)
  let assert Ok(wrong_digest) = identity.digest(<<77:size(256)>>)
    as "The forged digest has valid width."
  assert first.receive(origin(0), a.key, wrong_digest, [], <<1>>) == Error(Nil)
  let assert Ok(workspace) = identity.workspace_id("foreign")
    as "The foreign scope label is valid."
  let assert Ok(executor) = identity.executor_id("linux")
    as "The executor label remains valid."
  let assert Ok(epoch) = identity.epoch(1) as "The epochs remain valid."
  let wrong_scope =
    identity.scope(session_id(1), workspace, executor, epoch, epoch)
  assert first.receive(
      origin(0),
      identity.request_key(wrong_scope, operation(4), id),
      digest(a),
      [],
      <<1>>,
    )
    == Error(Nil)
  untouched(fixture.owner, origin(0))
  untouched(fixture.owner, origin(1))
  stop(fixture)
}

pub fn exact_ordered_receipt_survives_reopen_and_changed_retry_conflicts_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@dispatch_binding_test",
    "exact_ordered_receipt_survives_reopen_and_changed_retry_conflicts_test",
  )
  let fixture = fixture("reopen", limits(8))
  let fenced = process.new_subject()
  let config =
    config(
      fixture,
      connection(scope(), peer),
      prepared(),
      request_id(10),
      fenced,
    )
  let assert Ok(reserved) = config.reserve(dispatch(origin(0)))
    as "The child request commits."
  let outputs = [<<0, 255>>, <<128, 0, 1>>]
  let terminal = <<0, 2, 0, 255>>
  let assert Ok(receipt) = custodian.receipt(outputs, terminal)
    as "The ordered binary receipt encodes."
  assert config.receive(
      origin(0),
      reserved.key,
      digest(reserved),
      outputs,
      terminal,
    )
    == Ok(Nil)
  let assert Ok(#(id, envelope, Some(actual))) =
    custodian.child(fixture.owner, origin(0))
    as "Success follows actual durable commit."
  assert actual == receipt
  stop(fixture)
  let assert Ok(reopened) = custodian.start(fixture.owner, fixture.config)
    as "The original address reopens the SQLite journal."
  assert custodian.child(fixture.owner, origin(0))
    == Ok(#(id, envelope, Some(receipt)))
  assert config.receive(
      origin(0),
      reserved.key,
      digest(reserved),
      outputs,
      terminal,
    )
    == Ok(Nil)
  assert config.receive(
      origin(0),
      reserved.key,
      digest(reserved),
      list.reverse(outputs),
      terminal,
    )
    == Error(Nil)
  assert config.receive(origin(0), reserved.key, digest(reserved), outputs, <<
      3,
    >>)
    == Error(Nil)
  assert custodian.child(fixture.owner, origin(0))
    == Ok(#(id, envelope, Some(receipt)))
  stop(Fixture(..fixture, pid: reopened.pid))
}

pub fn cancellation_before_reservation_survives_reopen_without_uuid_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@dispatch_binding_test",
    "cancellation_before_reservation_survives_reopen_without_uuid_test",
  )
  let fixture = fixture("cancel", limits(8))
  let fenced = process.new_subject()
  let config =
    config(
      fixture,
      connection(scope(), peer),
      prepared(),
      request_id(10),
      fenced,
    )
  let request = dispatch(origin(0))
  config.cancel_reserved(request)
  config.cancel_reserved(request)
  assert config.reserve(request) == Error(Nil)
  assert custodian.reserve_child(fixture.owner, origin(0), request_id(10), <<1>>)
    == Error(custody.Frozen)
  assert process.receive(fenced, 0) == Error(Nil)
  stop(fixture)
  let assert Ok(reopened) = custodian.start(fixture.owner, fixture.config)
    as "The cancellation placeholder survives close and reopen."
  assert config.reserve(request) == Error(Nil)
  stop(Fixture(..fixture, pid: reopened.pid))
}

pub fn unavailable_storage_invokes_mandatory_fence_and_receipt_fails_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@dispatch_binding_test",
    "unavailable_storage_invokes_mandatory_fence_and_receipt_fails_test",
  )
  let fixture = fixture("unavailable", limits(8))
  let fenced = process.new_subject()
  let config =
    config(
      fixture,
      connection(scope(), peer),
      prepared(),
      request_id(10),
      fenced,
    )
  let assert Ok(reserved) = config.reserve(dispatch(origin(0)))
    as "The original reservation exists before storage loss."
  stop(fixture)
  config.cancel_reserved(dispatch(origin(0)))
  let assert Ok(custody.Unavailable(_)) = process.receive(fenced, 1000)
    as "Storage failure invokes the mandatory assembly fence with its error."
  assert config.receive(origin(0), reserved.key, digest(reserved), [], <<1>>)
    == Error(Nil)
  let assert Ok(reopened) = custodian.start(fixture.owner, fixture.config)
    as "Reopen inspects the original evidence rather than inventing cancellation success."
  untouched(fixture.owner, origin(0))
  stop(Fixture(..fixture, pid: reopened.pid))
}

pub fn saturated_storage_invokes_mandatory_fence_for_unreserved_child_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@dispatch_binding_test",
    "saturated_storage_invokes_mandatory_fence_for_unreserved_child_test",
  )
  let fixture = fixture("full", limits(1))
  let fenced = process.new_subject()
  let config =
    config(
      fixture,
      connection(scope(), peer),
      prepared(),
      request_id(10),
      fenced,
    )
  let assert Ok(_) = config.reserve(dispatch(origin(0)))
    as "One child consumes the journal's complete child capacity."
  config.cancel_reserved(dispatch(origin(1)))
  assert process.receive(fenced, 1000) == Ok(custody.Capacity)
  assert custodian.child(fixture.owner, origin(1)) == Error(custody.Missing)
  stop(fixture)
}

pub fn bare_prepared_and_malformed_envelopes_cannot_publish_receipt_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@dispatch_binding_test",
    "bare_prepared_and_malformed_envelopes_cannot_publish_receipt_test",
  )
  let fixture = fixture("malformed", limits(8))
  let fenced = process.new_subject()
  let config =
    config(
      fixture,
      connection(scope(), peer),
      prepared(),
      request_id(10),
      fenced,
    )
  let assert Ok(encoded) = wire.encode_prepared(prepared())
    as "The bare Prepared deliberately lacks full scope."
  assert custodian.reserve_child(
      fixture.owner,
      origin(0),
      request_id(10),
      encoded,
    )
    == Ok(#(request_id(10), encoded))
  let assert Ok(id) =
    identity.request_id(ids.entry_id_to_string(request_id(10)))
    as "The supplied receipt UUID is otherwise valid."
  let key = identity.request_key(scope(), operation(4), id)
  let assert Ok(digest) = wire.prepared_digest(prepared())
    as "The supplied Prepared digest is otherwise valid."
  assert config.receive(origin(0), key, digest, [], <<1>>) == Error(Nil)
  let malformed = <<145, 1>>
  assert custodian.reserve_child(
      fixture.owner,
      origin(1),
      request_id(11),
      malformed,
    )
    == Ok(#(request_id(11), malformed))
  assert config.receive(origin(1), key, digest, [], <<1>>) == Error(Nil)
  untouched(fixture.owner, origin(0))
  untouched(fixture.owner, origin(1))
  stop(fixture)
}

pub fn envelope_overhead_keeps_existing_request_ceiling_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@dispatch_binding_test",
    "envelope_overhead_keeps_existing_request_ceiling_test",
  )
  let fixture = fixture("bound", limits(8))
  let fenced = process.new_subject()
  let original = prepared()
  let wide =
    wire.Prepared(
      ..original,
      request: exec.ExecRequest(
        ..original.request,
        argv: list.append(list.repeat(string.repeat("a", 8192), 15), [
          string.repeat("b", 1024),
        ]),
      ),
    )
  let assert Ok(bytes) = wire.encode_prepared(wide)
    as "The initial large canonical Prepared fits by itself."
  let padding = 131_072 - bit_array.byte_size(bytes)
  let wide =
    wire.Prepared(
      ..wide,
      request: exec.ExecRequest(
        ..wide.request,
        argv: list.append(list.repeat(string.repeat("a", 8192), 15), [
          string.repeat("b", 1024 + padding),
        ]),
      ),
    )
  let assert Ok(bytes) = wire.encode_prepared(wide)
    as "The boundary-sized Prepared remains within the existing standalone limit."
  assert bit_array.byte_size(bytes) == 131_072
  let config =
    config(fixture, connection(scope(), peer), wide, request_id(10), fenced)
  assert config.reserve(
      dispatch.Dispatch(..dispatch(origin(0)), request: wide.request),
    )
    == Error(Nil)
  assert custodian.child(fixture.owner, origin(0)) == Error(custody.Missing)
  stop(fixture)
}

pub fn invalid_prepared_or_binding_is_refused_before_durable_reserve_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@dispatch_binding_test",
    "invalid_prepared_or_binding_is_refused_before_durable_reserve_test",
  )
  let fixture = fixture("invalid", limits(8))
  let fenced = process.new_subject()
  let original = prepared()
  list.each(
    [
      wire.Prepared(..original, lifetime: wire.Finite(-1)),
      wire.Prepared(
        ..original,
        request: exec.ExecRequest(..original.request, policy: None),
      ),
    ],
    fn(prepared) {
      let config =
        config(
          fixture,
          connection(scope(), peer),
          prepared,
          request_id(10),
          fenced,
        )
      assert config.reserve(
          dispatch.Dispatch(..dispatch(origin(0)), request: prepared.request),
        )
        == Error(Nil)
    },
  )
  let valid = connection(scope(), peer)
  list.each(
    [
      connection.Config(..valid, executor: "other"),
      connection.Config(..valid, owner: "../bad"),
      connection.Config(..valid, within_ms: 0),
      connection.Config(..valid, generation: 0),
      connection.Config(..valid, within_ms: 30_001),
    ],
    fn(connection) {
      let assert Error(custody.Invalid(_)) =
        dispatch_binding.new(
          fixture.owner,
          connection,
          fn(_) { Ok(original) },
          fn() { request_id(10) },
          poll.monotonic().now,
          17,
          5000,
          fn(error) { process.send(fenced, error) },
        )
        as "Invalid administrative configuration cannot expose callbacks."
    },
  )
  assert custodian.child(fixture.owner, origin(0)) == Error(custody.Missing)
  stop(fixture)
}

pub fn cancellation_during_preparation_fences_later_uuid_reservation_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@dispatch_binding_test",
    "cancellation_during_preparation_fences_later_uuid_reservation_test",
  )
  let fixture = fixture("cancel-during-prepare", limits(8))
  let fenced = process.new_subject()
  let normal =
    config(
      fixture,
      connection(scope(), peer),
      prepared(),
      request_id(10),
      fenced,
    )
  let assert Ok(binding) =
    dispatch_binding.new(
      fixture.owner,
      connection(scope(), peer),
      fn(request) {
        normal.cancel_reserved(request)
        Ok(prepared())
      },
      fn() { request_id(11) },
      poll.monotonic().now,
      17,
      5000,
      fn(error) { process.send(fenced, error) },
    )
    as "A cancellation can commit while preparation is still in progress."
  let config = dispatch_binding.configuration(binding)
  assert config.reserve(dispatch(origin(0))) == Error(Nil)
  assert custodian.reserve_child(fixture.owner, origin(0), request_id(11), <<1>>)
    == Error(custody.Frozen)
  assert process.receive(fenced, 0) == Error(Nil)
  stop(fixture)
}

pub fn oversized_receipt_refuses_without_committing_terminal_test() {
  use peer <- beam_owner_fixture.run(
    "client@remote@dispatch_binding_test",
    "oversized_receipt_refuses_without_committing_terminal_test",
  )
  let fixture = fixture("receipt-bound", limits(8))
  let fenced = process.new_subject()
  let config =
    config(
      fixture,
      connection(scope(), peer),
      prepared(),
      request_id(10),
      fenced,
    )
  let assert Ok(reserved) = config.reserve(dispatch(origin(0)))
    as "The original child is durable before receipt validation."
  let large_output = bit_array.from_string(string.repeat("o", 16_385))
  let large_terminal = bit_array.from_string(string.repeat("t", 32_769))
  assert config.receive(
      origin(0),
      reserved.key,
      digest(reserved),
      [large_output],
      <<1>>,
    )
    == Error(Nil)
  assert config.receive(
      origin(0),
      reserved.key,
      digest(reserved),
      [],
      large_terminal,
    )
    == Error(Nil)
  untouched(fixture.owner, origin(0))
  stop(fixture)
}
