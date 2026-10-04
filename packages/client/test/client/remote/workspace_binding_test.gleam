//// Actual SQLite and custodian actor regressions for semantic workspace custody.
////
//// Every fixture owns a unique directory and reopens the same durable journal.
//// The runner is deliberately unreachable: child evidence never runs a tool or
//// reconstructs a final outcome. These checks end below transport assembly.

import client/remote/custodian
import client/remote/workspace_binding as binding
import core/clock
import core/ids
import core/remote_tool
import core/workspace as scope
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import host/bootstrap
import simplifile
import sqlight
import storage/owner_custody as custody
import tools/fs
import tools/hashline
import tools/workspace as w
import tools/workspace_codec as codec
import tools/workspace_local as local
import weft
import weft/registry

type Fixture {
  Fixture(
    owner: custodian.Handle,
    config: custodian.Config,
    pid: process.Pid,
    path: String,
  )
}

fn session(n: Int) {
  ids.mint_session(ids.generator(clock.fixed(1000), n)).0
}

fn operation(n: Int) {
  ids.mint_op(ids.generator(clock.fixed(1000), n)).0
}

fn id(n: Int) {
  ids.mint_entry(ids.generator(clock.fixed(1000), n)).0
}

fn step(text: String) {
  let assert Ok(step) = scope.step(text) as "Fixture step is bounded."
  step
}

fn bound(epoch: Int) {
  let assert Ok(bound) =
    scope.scope_from_fields(
      ids.session_id_to_string(session(1)),
      "checkout",
      "linux",
      epoch,
      1,
    )
    as "Fixture administrative scope is valid."
  bound
}

fn key(digest: String) {
  let assert Ok(key) =
    remote_tool.key(
      session(1),
      operation(2),
      "tool:workspace",
      3,
      digest,
      id(3),
    )
    as "Fixture retains complete runtime ToolKey."
  key
}

fn digest(pair: String) {
  let assert Ok(bytes) = bit_array.base16_decode(string.repeat(pair, 32))
    as "Exact 32-byte digest fixture."
  bytes
}

fn tool_source(digest: BitArray) {
  let assert Ok(source) = w.tool_origin(3, digest)
    as "Fixture source digest has exact SHA-256 width."
  w.Tool(source)
}

fn tool_child(role: remote_tool.ChildRole) {
  let assert Ok(child) =
    remote_tool.tool_child(key(string.repeat("a", 64)), role)
    as "Fixture tool child ordinal is bounded."
  child
}

fn system_child(n: Int) {
  let assert Ok(child) =
    remote_tool.system_child(session(1), "workspace-administration", n)
    as "Fixture system origin is explicit."
  child
}

fn limits(payload: Int) {
  let assert Ok(limits) = custody.limits(4, 32, 134_217_728, payload)
    as "Fixture quotas include full completion allowance before effects."
  limits
}

fn fixture(name: String, quota: Int) {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let directory =
    "/private/tmp/loom-owner-workspace-"
    <> name
    <> "-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  assert simplifile.create_directory_all(directory) == Ok(Nil)
  let path = directory <> "/owner.sqlite"
  let limits = limits(quota)
  let assert Ok(store) = custody.open(path, session(1), limits)
    as "Seed parent custody in actual SQLite."
  let assert Ok(payload) = custody.payload(limits, <<"parent":utf8>>)
    as "Small parent request fits unchanged native limit."
  assert custody.admit(store, key(string.repeat("a", 64)), payload, payload)
    == Ok(Nil)
  assert custody.close(store) == Ok(Nil)
  let assert Ok(names) = registry.start() as "Fixture owns its registry."
  let assert Ok(config) =
    custodian.config(path, session(1), limits, 1, 5000, fn(_, _) {
      panic as "Workspace reservation and recovery cannot execute a tool body."
    })
    as "Finite custodian configuration is valid."
  let owner = custodian.new(names, config)
  let assert Ok(started) = custodian.start(owner, config)
    as "Real actor reopens the seeded store."
  Fixture(owner, config, started.pid, path)
}

fn stop(f: Fixture) {
  let monitor = process.monitor(f.pid)
  assert custodian.stop(f.owner) == Ok(Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "Old SQLite owner closes before reopen."
  Nil
}

fn reopen(f: Fixture) {
  stop(f)
  let assert Ok(started) = custodian.start(f.owner, f.config)
    as "Same immutable metadata reopens."
  Fixture(..f, pid: started.pid)
}

fn owner_binding(f: Fixture, candidate: Int) {
  binding.new(bound(1), f.owner, fn() { id(candidate) })
}

fn reserve(
  b: binding.Binding,
  child: remote_tool.ChildOrigin,
  request: w.Request,
) {
  binding.reserve(
    b,
    child,
    operation(2),
    step("system:setup"),
    w.System(w.WorkspaceAdministration),
    request,
  )
}

fn completion(request: w.Request, response: w.Response) {
  let assert Ok(bytes) =
    codec.encode_completion(request, Ok(local.Completed(response, None)))
    as "Fixture completion matches its retained request."
  bytes
}

fn initialized() {
  completion(w.Initialize, w.InitializationCompleted(Ok(w.Initialized)))
}

fn empty_receipt(f: Fixture, child: remote_tool.ChildOrigin) {
  let assert Ok(#(_, _, None)) = custodian.child(f.owner, child)
    as "Refused receipt leaves SQLite terminal NULL."
  Nil
}

pub fn canonical_retry_never_mints_and_retains_full_invocation_test() {
  let f = fixture("retry", codec.max_completion_bytes)
  let b = owner_binding(f, 10)
  let child = system_child(0)
  let assert Ok(first) = reserve(b, child, w.Initialize)
    as "Complete canonical invocation commits before send."
  let retry =
    binding.new(bound(1), f.owner, fn() {
      panic as "Retained retry must read original identity before consulting mint."
    })
  let assert Ok(second) = reserve(retry, child, w.Initialize)
    as "Exact retry reconstructs candidate using retained UUID."
  assert binding.content(second) == binding.content(first)
  assert codec.decode_invocation(binding.content(first))
    == Ok(binding.invocation(first))
  let #(scope, op, physical_step, origin, request_id) =
    w.invocation_identity(binding.invocation(first))
  assert #(scope, op, physical_step, origin, request_id)
    == #(
      bound(1),
      operation(2),
      step("system:setup"),
      w.System(w.WorkspaceAdministration),
      id(10),
    )
  assert custodian.reserve_workspace_child(
      f.owner,
      child,
      id(11),
      binding.content(first),
    )
    == Error(custody.Conflict)
  assert custodian.child(f.owner, child)
    == Ok(#(id(10), binding.content(first), None))
  stop(f)
}

pub fn changed_operation_step_origin_scope_and_request_conflict_test() {
  let f = fixture("changes", codec.max_completion_bytes)
  let b = owner_binding(f, 10)
  let child = system_child(0)
  let assert Ok(first) = reserve(b, child, w.Initialize)
    as "Original reservation."
  assert binding.reserve(
      b,
      child,
      operation(4),
      step("system:setup"),
      w.System(w.WorkspaceAdministration),
      w.Initialize,
    )
    == Error(custody.Conflict)
  assert binding.reserve(
      b,
      child,
      operation(2),
      step("other"),
      w.System(w.WorkspaceAdministration),
      w.Initialize,
    )
    == Error(custody.Conflict)
  assert binding.reserve(
      b,
      child,
      operation(2),
      step("system:setup"),
      w.System(w.Compiler),
      w.Initialize,
    )
    == Error(custody.Conflict)
  assert reserve(
      binding.new(bound(2), f.owner, fn() { id(11) }),
      child,
      w.Initialize,
    )
    == Error(custody.Conflict)
  assert reserve(b, child, w.Guidance) == Error(custody.Conflict)
  assert custodian.child(f.owner, child)
    == Ok(#(id(10), binding.content(first), None))
  stop(f)
}

pub fn toolkey_provenance_and_native_workspace_namespace_are_checked_test() {
  let f = fixture("provenance", codec.max_completion_bytes)
  let b = owner_binding(f, 10)
  let source = tool_source(digest("aa"))
  let child = tool_child(remote_tool.Workspace(0))
  let assert Ok(first) =
    binding.reserve(
      b,
      child,
      operation(2),
      step("tool:workspace"),
      source,
      w.Initialize,
    )
    as "Tool retains exact operation, step, source index and arguments digest."
  assert binding.reserve(
      b,
      child,
      operation(4),
      step("tool:workspace"),
      source,
      w.Initialize,
    )
    == Error(custody.Conflict)
  assert binding.reserve(
      b,
      child,
      operation(2),
      step("other"),
      source,
      w.Initialize,
    )
    == Error(custody.Conflict)
  assert binding.reserve(
      b,
      child,
      operation(2),
      step("tool:workspace"),
      tool_source(digest("bb")),
      w.Initialize,
    )
    == Error(custody.Conflict)
  let assert Ok(other_source) = w.tool_origin(2, digest("aa"))
    as "Changed source index remains independently well-formed."
  assert binding.reserve(
      b,
      child,
      operation(2),
      step("tool:workspace"),
      w.Tool(other_source),
      w.Initialize,
    )
    == Error(custody.Conflict)
  list.each(
    [
      remote_tool.Compile,
      remote_tool.Launch,
      remote_tool.CompileCommand,
      remote_tool.SatelliteCommand,
      remote_tool.Capability(0),
      remote_tool.AdmittedCapability(
        "fs.read",
        0,
        remote_tool.SemanticWorkspace,
      ),
      remote_tool.AdmittedCapability("proc.run", 0, remote_tool.NativeCommand),
    ],
    fn(role) {
      assert binding.reserve(
          b,
          tool_child(role),
          operation(2),
          step("tool:workspace"),
          source,
          w.Initialize,
        )
        == Error(custody.Conflict)
    },
  )
  let assert Ok(foreign) =
    remote_tool.system_child(session(2), "workspace-administration", 0)
    as "Foreign session origin is syntactically valid."
  assert reserve(b, foreign, w.Initialize) == Error(custody.Conflict)
  assert reserve(b, child, w.Initialize) == Error(custody.Conflict)
  let assert Ok(changed_key) =
    remote_tool.key(
      session(1),
      operation(2),
      "tool:workspace",
      3,
      string.repeat("b", 64),
      id(3),
    )
    as "Changed argument digest retains the same logical parent address."
  let assert Ok(changed_child) =
    remote_tool.tool_child(changed_key, remote_tool.Workspace(0))
    as "Changed immutable ToolKey cannot bypass the parent's retained identity."
  assert binding.reserve(
      b,
      changed_child,
      operation(2),
      step("tool:workspace"),
      tool_source(digest("bb")),
      w.Initialize,
    )
    == Error(custody.Conflict)
  let assert Ok(changed_result_key) =
    remote_tool.key(
      session(1),
      operation(2),
      "tool:workspace",
      3,
      string.repeat("a", 64),
      id(30),
    )
    as "Changed result entry retains the same logical parent address."
  let assert Ok(changed_result_child) =
    remote_tool.tool_child(changed_result_key, remote_tool.Workspace(0))
    as "Changed result identity cannot create another workspace child."
  assert binding.reserve(
      b,
      changed_result_child,
      operation(2),
      step("tool:workspace"),
      source,
      w.Initialize,
    )
    == Error(custody.Conflict)
  assert custodian.child(f.owner, child)
    == Ok(#(id(10), binding.content(first), None))
  stop(f)
}

pub fn mismatched_response_changed_receipt_and_storage_loss_cannot_ack_test() {
  let f = fixture("receipt", codec.max_completion_bytes)
  let b = owner_binding(f, 10)
  let child = system_child(0)
  let assert Ok(reserved) = reserve(b, child, w.Initialize)
    as "Original reservation."
  let wrong =
    completion(
      w.Read(scope.root(), w.Text),
      w.ReadCompleted(Ok(w.TextRead("wrong"))),
    )
  assert binding.receive(reserved, wrong) |> result.is_error
  empty_receipt(f, child)
  let bytes = initialized()
  let assert Ok(ack) = binding.receive(reserved, bytes)
    as "Exact completion durably commits."
  assert binding.acknowledgement(ack) == #(id(10), bootstrap.sha256(bytes))
  assert binding.receive(reserved, bytes) == Ok(ack)
  let changed =
    completion(
      w.Initialize,
      w.InitializationCompleted(Ok(w.AlreadyInitialized)),
    )
  assert binding.receive(reserved, changed) == Error(custody.Conflict)
  let f = reopen(f)
  let assert Ok(#(recovered, Some(retained))) = binding.recover(b, child)
    as "Recovery uses same original child and exact persisted receipt."
  assert retained == bytes
  assert binding.content(recovered) == binding.content(reserved)
  assert binding.receive(recovered, retained) == Ok(ack)
  stop(f)
  assert binding.receive(reserved, bytes) |> result.is_error
}

pub fn full_thirty_two_mib_receipt_survives_custodian_reopen_test() {
  let f = fixture("full-ceiling", codec.max_completion_bytes)
  let child = system_child(0)
  let assert Ok(reserved) = reserve(owner_binding(f, 10), child, w.Initialize)
    as "Full configured receipt capacity is reserved before effects."

  // Raw typed custody exercises the exact 32-MiB ceiling independently of the
  // codec's smaller legal Initialize response. It grants no binding ACK.
  let bytes =
    string.repeat("x", codec.max_completion_bytes) |> bit_array.from_string
  assert custodian.receive_workspace_child(f.owner, child, id(10), bytes)
    == Ok(Nil)
  assert custodian.receive_child(f.owner, child, id(10), bytes)
    == Error(custody.Capacity)
  let f = reopen(f)
  assert custodian.child(f.owner, child)
    == Ok(#(id(10), binding.content(reserved), Some(bytes)))
  assert binding.recover(owner_binding(f, 11), child) |> result.is_error
  stop(f)
}

pub fn large_valid_edit_completion_survives_binding_recovery_test() {
  let f = fixture("large-edit", codec.max_completion_bytes)
  let child = system_child(0)
  let b = owner_binding(f, 10)
  let before = string.repeat("x", 8_388_608)
  let edited = string.repeat("y", 16_777_000)
  let request =
    w.AnchoredEdit(scope.root(), hashline.Plan(hashline.digest(before), []))
  let assert Ok(reserved) = reserve(b, child, request)
    as "Semantic edit reservation."
  let bytes =
    completion(request, w.EditCompleted(Ok(fs.Landed(before, edited))))
  assert bit_array.byte_size(bytes) > 25_165_000
  let assert Ok(ack) = binding.receive(reserved, bytes)
    as "Full edit evidence commits before ACK."
  let f = reopen(f)
  let assert Ok(#(recovered, Some(retained))) = binding.recover(b, child)
    as "Large completion survives actual SQLite and custodian reopen."
  assert retained == bytes
  assert binding.receive(recovered, retained) == Ok(ack)
  stop(f)
}

pub fn small_quota_and_cancellation_fence_prevent_send_or_late_ack_test() {
  let f = fixture("quota-cancel", 4096)
  let b = owner_binding(f, 10)
  let large = w.Write(scope.root(), string.repeat("x", 4097))
  assert reserve(b, system_child(0), large) == Error(custody.Capacity)
  assert custodian.child(f.owner, system_child(0)) == Error(custody.Missing)
  assert custodian.cancel_child(f.owner, system_child(0)) == Ok(Nil)
  assert reserve(b, system_child(0), w.Initialize) == Error(custody.Frozen)
  let assert Ok(reserved) = reserve(b, system_child(1), w.Initialize)
    as "Uncancelled origin reserves."
  assert custodian.cancel_child(f.owner, system_child(1)) == Ok(Nil)
  assert binding.receive(reserved, initialized()) == Error(custody.Frozen)
  empty_receipt(f, system_child(1))
  let f = reopen(f)
  assert reserve(b, system_child(0), w.Initialize) == Error(custody.Frozen)
  assert binding.receive(reserved, initialized()) == Error(custody.Frozen)
  stop(f)
}

pub fn malformed_reservation_never_signals_durable_receipt_test() {
  let f = fixture("corrupt", codec.max_completion_bytes)
  let child = system_child(0)
  let assert Ok(reserved) = reserve(owner_binding(f, 10), child, w.Initialize)
    as "Original row reserves full result allowance."
  let assert Ok(db) = sqlight.open(f.path)
    as "Idle serialized owner permits test corruption."
  assert sqlight.exec(
      "UPDATE owner_custody_children SET reserved_bytes = length(CAST(origin AS BLOB)) + length(CAST(parent AS BLOB)) + 164 + length(request)",
      db,
    )
    == Ok(Nil)
  assert binding.receive(reserved, initialized()) |> result.is_error
  assert sqlight.close(db) == Ok(Nil)
  stop(f)
}

pub fn concurrent_reservations_never_adopt_a_new_execution_identity_test() {
  let f = fixture("concurrent", codec.max_completion_bytes)
  let child = system_child(0)
  let b1 = owner_binding(f, 10)
  let b2 = owner_binding(f, 11)
  let report =
    weft.new([
      fn() { Ok(reserve(b1, child, w.Initialize)) },
      fn() { Ok(reserve(b2, child, w.Initialize)) },
    ])
    |> weft.deadline(5000)
    |> weft.start
  let successes =
    report
    |> list.filter_map(fn(value) {
      case value {
        weft.Completed(_, Ok(reserved)) -> Ok(binding.content(reserved))
        weft.Completed(_, Error(custody.Conflict)) -> Error(Nil)
        _ ->
          panic as "Concurrent reservation must return retained bytes or explicit conflict."
      }
    })
  let assert [first, ..rest] = successes as "One durable candidate must win."
  assert list.all(rest, fn(bytes) { bytes == first })
  let assert Ok(#(_, retained, None)) = custodian.child(f.owner, child)
    as "One origin retains exactly one request."
  assert retained == first
  stop(f)
}

pub fn sqlite_write_refusal_does_not_signal_durable_receipt_test() {
  let f = fixture("write-refusal", codec.max_completion_bytes)
  let child = system_child(0)
  let assert Ok(reserved) = reserve(owner_binding(f, 10), child, w.Initialize)
    as "Original invocation has durable custody."
  let assert Ok(db) = sqlight.open(f.path)
    as "Test connection installs a receipt-write refusal."
  assert sqlight.exec(
      "CREATE TRIGGER reject_workspace_receipt BEFORE UPDATE OF terminal ON owner_custody_children BEGIN SELECT RAISE(ABORT, 'test receipt write refusal'); END",
      db,
    )
    == Ok(Nil)
  assert binding.receive(reserved, initialized()) == Error(custody.Conflict)
  empty_receipt(f, child)
  assert sqlight.close(db) == Ok(Nil)
  stop(f)
}

pub fn foreign_retained_uuid_or_request_cannot_grant_ack_test() {
  let f = fixture("foreign-retained", codec.max_completion_bytes)
  let b = owner_binding(f, 10)
  let child = system_child(0)
  let assert Ok(reserved) = reserve(b, child, w.Initialize)
    as "Original opaque reservation retains expected ID and invocation."
  let assert Ok(db) = sqlight.open(f.path)
    as "Test-only mutation exercises receipt recheck rather than forged constructors."
  assert result.is_ok(sqlight.query(
    "UPDATE owner_custody_children SET request_id = ?",
    db,
    [sqlight.text(ids.entry_id_to_string(id(11)))],
    decode.success(Nil),
  ))
  assert binding.receive(reserved, initialized()) == Error(custody.Conflict)
  assert result.is_ok(sqlight.query(
    "UPDATE owner_custody_children SET request_id = ?",
    db,
    [sqlight.text(ids.entry_id_to_string(id(10)))],
    decode.success(Nil),
  ))
  let foreign =
    w.invocation(
      bound(1),
      operation(2),
      step("system:setup"),
      w.System(w.WorkspaceAdministration),
      id(10),
      w.Guidance,
    )
  let assert Ok(bytes) = codec.encode_invocation(foreign)
    as "Foreign request has a valid canonical spelling."
  assert result.is_ok(sqlight.query(
    "UPDATE owner_custody_children SET request = ?",
    db,
    [sqlight.blob(bytes)],
    decode.success(Nil),
  ))
  assert binding.receive(reserved, initialized()) == Error(custody.Conflict)
  empty_receipt(f, child)
  assert sqlight.close(db) == Ok(Nil)
  stop(f)
}

pub fn configured_receipt_quota_prechecks_before_mailbox_send_test() {
  let f = fixture("precheck", 4096)
  let b = owner_binding(f, 10)
  let child = system_child(0)
  let request = w.Read(scope.root(), w.Text)
  let assert Ok(reserved) = reserve(b, child, request)
    as "Small semantic request fits configured quota."
  let bytes =
    completion(
      request,
      w.ReadCompleted(Ok(w.TextRead(string.repeat("x", 4097)))),
    )
  assert binding.receive(reserved, bytes) == Error(custody.Capacity)
  empty_receipt(f, child)
  stop(f)

  // Capacity must precede registry lookup and send even when the actor is gone.
  assert custodian.receive_workspace_child(f.owner, child, id(10), bytes)
    == Error(custody.Capacity)
  assert custodian.reserve_workspace_child(f.owner, child, id(10), bytes)
    == Error(custody.Capacity)
}

pub fn native_mailbox_entry_limits_remain_unchanged_test() {
  let f = fixture("native-precheck", codec.max_completion_bytes)
  stop(f)
  let request = <<0:size(131_073 * 8)>>
  assert custodian.reserve_child(f.owner, system_child(0), id(10), request)
    == Error(custody.Capacity)
  let receipt = <<0:size(2_097_153 * 8)>>
  assert custodian.receive_child(f.owner, system_child(0), id(10), receipt)
    == Error(custody.Capacity)
}
