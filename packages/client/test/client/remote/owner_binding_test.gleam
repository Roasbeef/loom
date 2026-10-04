//// Real SQLite owner binding through the runtime's actual ToolSurface/ToolRun.
////
//// The injected runner replaces physical remote transport only. Every owner
//// admission, immutable comparison, final write, reopen and receipt is real.

import client/remote/custodian
import client/remote/outcome
import client/remote/tool_custody
import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/msgpack
import core/register
import core/remote_tool
import core/tx
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import host/bootstrap
import machine/operation
import runtime/effects
import simplifile
import storage/owner_custody as custody
import storage/sqlite
import storage/storage
import weft/poll
import weft/registry

fn session_id() -> ids.SessionId {
  ids.mint_session(ids.generator(clock.fixed(1000), 15)).0
}

fn run(index: Int) -> effects.ToolRun {
  effects.ToolRun(
    operation: ids.mint_op(ids.generator(clock.fixed(1000), 17)).0,
    step_id: "same-batch:tools",
    source_index: index,
    result_entry: ids.mint_entry(ids.generator(clock.fixed(1001), index + 100)).0,
    strand: "main",
    call: message.ToolCall(
      id: "call-" <> int.to_string(index),
      name: "code_mode",
      arguments: json.Object([#("program", json.String("cleared program"))]),
      thought_signature: Some("provider signature"),
      namespace: Some("provider namespace"),
    ),
    arguments: json.Object([#("program", json.String("effective program"))]),
    replay: operation.ReplaySafe,
    grants: [json.Object([#("approved", json.String("network"))])],
  )
}

fn final(run: effects.ToolRun) -> effects.ToolOutcome {
  effects.ToolCompleted(
    message.ToolResultMessage(
      tool_call_id: run.call.id,
      tool_name: run.call.name,
      content: [
        message.ToolResultText("exact text", Some("text signature")),
        message.ToolResultImage("AA==", "image/png"),
      ],
      details: Some(json.Object([#("receipt", json.Int(7))])),
      usage: None,
      added_tool_names: Some(["added"]),
      is_error: True,
      timestamp: 12_345,
    ),
    True,
  )
}

fn limits() -> custody.Limits {
  let assert Ok(limits) = custody.limits(16, 64, 67_108_864, 2_097_152)
    as "the child payload allowance fits the unchanged total hard ceiling"
  limits
}

fn path(name: String) -> String {
  let path =
    "/private/tmp/loom-owner-binding-"
    <> name
    <> "-"
    <> int.to_string(bootstrap.system_time_ms())
  let assert Ok(Nil) = simplifile.create_directory_all(path)
    as "this test owns a fresh directory without deleting shared files"
  path <> "/owner.db"
}

fn start(
  path: String,
  capacity: Int,
  runner: fn(remote_tool.ToolKey, effects.ToolRun) -> effects.ToolOutcome,
) {
  let assert Ok(names) = registry.start() as "owner address namespace starts"
  let assert Ok(config) =
    custodian.config(path, session_id(), limits(), capacity, 5000, runner)
    as "owner config is finite"
  let owner = custodian.new(names, config)
  let assert Ok(started) = custodian.start(owner, config)
    as "the actor owns the real SQLite handle"
  #(owner, config, started.pid)
}

fn surface(owner: custodian.Handle, scope: BitArray) -> effects.ToolSurface {
  tool_custody.wrap(local(), tool_custody.Managed(session_id(), scope, owner))
}

fn local() -> effects.ToolSurface {
  effects.ToolSurface(
    clear: fn(query) {
      effects.Cleared(query.call.arguments, operation.ReplaySafe)
    },
    run: fn(_) { effects.ToolFailed("local path marker") },
    recover: fn(_, _) { effects.UnmanagedLocal },
    replay_still_safe: fn(name) { name == "code_mode" },
    execution_mode: fn(_) { effects.ConcurrentExecution },
  )
}

fn recover(
  surface: effects.ToolSurface,
  run: effects.ToolRun,
) -> effects.ToolRecovery {
  surface.recover(run, fn(_) { Nil })
}

fn stop(owner: custodian.Handle, pid: process.Pid) {
  let monitor = process.monitor(pid)
  assert custodian.stop(owner) == Ok(Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "journal close finishes before reopening its file"
  Nil
}

fn invocation(run: effects.ToolRun) -> tool_custody.Invocation {
  let assert Ok(invocation) =
    tool_custody.invocation(
      session_id(),
      <<"full:authority:workspace:epochs":utf8>>,
      run,
    )
    as "runtime original IDs and canonical arguments construct complete identity"
  invocation
}

pub fn distinct_indices_execute_once_and_preserve_metadata_test() {
  let seen = process.new_subject()
  let #(owner, _config, pid) =
    start(path("indices"), 2, fn(key, original) {
      process.send(seen, #(key, original))
      final(original)
    })
  let tools = surface(owner, <<"full:authority:workspace:epochs":utf8>>)
  let first = run(0)
  let second = run(1)
  assert tools.run(first) == final(first)
  assert tools.run(second) == final(second)
  let assert Ok(#(first_key, actual_first)) = process.receive(seen, 1000)
    as "first real runner receives full original ToolRun"
  let assert Ok(#(second_key, actual_second)) = process.receive(seen, 1000)
    as "second source index gets an independent runner invocation"
  assert actual_first == first
  assert actual_second == second
  assert first_key == invocation(first).key
  assert second_key == invocation(second).key
  assert remote_tool.address(first_key) != remote_tool.address(second_key)
  assert remote_tool.operation(first_key) == first.operation
  assert remote_tool.step(first_key) == first.step_id
  let assert effects.ToolFailed(_) = tools.run(first)
    as "an admitted retry cannot execute the program body twice"
  assert process.receive(seen, 20) == Error(Nil)
  assert recover(tools, first) == effects.RecoveredOutcome(final(first))
  assert tools.replay_still_safe("code_mode") == True
  assert tools.replay_still_safe("other") == False
  assert tools.execution_mode("code_mode") == effects.ConcurrentExecution
  assert tool_custody.wrap(local(), tool_custody.Local).run(first)
    == effects.ToolFailed("local path marker")
  stop(owner, pid)
}

pub fn callback_death_does_not_cancel_owner_and_exact_final_survives_reopen_test() {
  let started = process.new_subject()
  let directory = path("callback-loss")
  let #(owner, config, pid) =
    start(directory, 1, fn(_, original) {
      let release = process.new_subject()
      process.send(started, release)
      let assert Ok(Nil) = process.receive(release, 2000)
        as "the independently owned body continues after callback death"
      final(original)
    })
  let tools = surface(owner, <<"full:authority:workspace:epochs":utf8>>)
  let caller = process.spawn_unlinked(fn() { tools.run(run(0)) })
  let assert Ok(release) = process.receive(started, 1000)
    as "admission committed before the runner starts"
  process.kill(caller)
  let assert effects.UnknownOutcome(_) = recover(tools, run(0))
    as "an active body without final bytes is reported truthfully unknown"
  process.send(release, Nil)
  let expected = final(run(0))
  let assert poll.Answered(_) =
    poll.until(2000, 10, fn() {
      case recover(tools, run(0)) {
        effects.RecoveredOutcome(outcome) if outcome == expected ->
          poll.Done(outcome)
        _ -> poll.Retry
      }
    })
    as "the owner commits the exact report without a living callback"
  stop(owner, pid)
  let assert Ok(reopened) = custodian.start(owner, config)
    as "the same reclaimable owner address reopens the real database"
  assert recover(tools, run(0)) == effects.RecoveredOutcome(final(run(0)))
  let assert effects.ToolFailed(_) = tools.run(run(0))
    as "restart cannot rerun an old admitted body"
  assert process.receive(started, 20) == Error(Nil)
  stop(owner, reopened.pid)
}

pub fn scope_argument_call_metadata_and_result_conflicts_fail_closed_test() {
  let #(owner, _, pid) =
    start(path("conflicts"), 1, fn(_, original) { final(original) })
  let tools = surface(owner, <<"full:authority:workspace:epochs":utf8>>)
  let original = run(0)
  assert tools.run(original) == final(original)
  let assert effects.UnknownOutcome(_) =
    recover(surface(owner, <<"other authority":utf8>>), original)
    as "scope comparison remains immutable after final persistence"
  let assert effects.UnknownOutcome(_) =
    recover(tools, effects.ToolRun(..original, arguments: json.Object([])))
    as "changed canonical argument digest reaches the original conflict fence"
  let assert effects.UnknownOutcome(_) =
    recover(
      tools,
      effects.ToolRun(
        ..original,
        call: message.ToolCall(..original.call, id: "changed"),
      ),
    )
    as "call ID participates in retained request equality"
  let assert effects.UnknownOutcome(_) =
    recover(
      tools,
      effects.ToolRun(..original, result_entry: run(1).result_entry),
    )
    as "changed reserved result identity cannot read another final outcome"
  let changed_order = json.Object([#("z", json.Int(1)), #("a", json.Int(2))])
  let a = effects.ToolRun(..original, arguments: changed_order)
  let b =
    effects.ToolRun(
      ..original,
      arguments: json.Object([#("a", json.Int(2)), #("z", json.Int(1))]),
    )
  assert invocation(a).key == invocation(b).key
  stop(owner, pid)
}

pub fn missing_or_unavailable_managed_custody_never_uses_local_replay_test() {
  let #(owner, _, pid) =
    start(path("missing"), 1, fn(_, original) { final(original) })
  let tools = surface(owner, <<"full:authority:workspace:epochs":utf8>>)
  let assert effects.UnknownOutcome(_) = recover(tools, run(0))
    as "missing evidence is unknown despite ReplaySafe"
  stop(owner, pid)
  let assert effects.UnknownOutcome(_) = recover(tools, run(0))
    as "unavailable managed custody never returns UnmanagedLocal"
  let assert effects.ToolFailed(reason) = tools.run(run(0))
    as "unavailable owner does not execute the local body"
  assert reason != "local path marker"
  assert recover(tool_custody.wrap(local(), tool_custody.Local), run(0))
    == effects.UnmanagedLocal
}

pub fn actual_supervision_restarts_owner_without_reexecuting_awaiting_body_test() {
  let directory = path("supervised")
  let original = run(0)
  let request = invocation(original)
  let assert Ok(store) = custody.open(directory, session_id(), limits())
    as "real unfinished admission is persisted before owner startup"
  let assert Ok(args) = custody.payload(limits(), request.arguments)
    as "canonical args fit"
  let assert Ok(bytes) = custody.payload(limits(), request.request)
    as "immutable scope fits"
  assert custody.admit_fresh(store, request.key, args, bytes)
    == Ok(custody.Fresh)
  assert custody.admit_fresh(store, request.key, args, bytes)
    == Ok(custody.Retained)
  let assert Ok(child_origin) =
    remote_tool.tool_child(request.key, remote_tool.Compile)
    as "unfinished report has a real compile child"
  assert custody.admit_child(store, child_origin, run(2).result_entry, bytes)
    == Ok(Nil)
  assert custody.receive_child(store, child_origin, run(2).result_entry, bytes)
    == Ok(Nil)
  assert custody.close(store) == Ok(Nil)
  let seen = process.new_subject()
  let assert Ok(names) = registry.start() as "supervised registry starts"
  let assert Ok(config) =
    custodian.config(directory, session_id(), limits(), 1, 2000, fn(_, run) {
      process.send(seen, Nil)
      final(run)
    })
    as "supervised owner config validates"
  let owner = custodian.new(names, config)
  let starts = process.new_subject()
  let specification = custodian.supervised(owner, config)
  let observed =
    supervision.ChildSpecification(..specification, start: fn() {
      use started <- result.map(specification.start())
      process.send(starts, started.pid)
      started
    })
  let assert Ok(services) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(observed)
    |> supervisor.start
    as "actual supervisor owns the serialized journal actor"
  let tools = surface(owner, <<"full:authority:workspace:epochs":utf8>>)
  let assert effects.UnknownOutcome(_) = recover(tools, original)
    as "an unfinished old admission remains unknown"
  let assert effects.ToolFailed(_) = tools.run(original)
    as "owner startup does not grant old orphan replay permission"
  assert process.receive(seen, 20) == Error(Nil)

  // Killing the actual child forces the supervisor to reclaim the same owner
  // address and reopen the journal without granting another body execution.
  let assert Ok(first) = process.receive(starts, 2000)
    as "the first supervised child published its address"
  process.kill(first)
  let assert Ok(second) = process.receive(starts, 2000)
    as "the supervisor restarted the killed owner"
  assert first != second
  let assert effects.UnknownOutcome(_) = recover(tools, original)
    as "retained evidence survives an actual supervised restart"
  let assert effects.ToolFailed(_) = tools.run(original)
    as "the restarted owner cannot execute an already admitted body"
  assert custodian.child(owner, child_origin)
    == Ok(#(run(2).result_entry, request.request, Some(request.request)))
  assert process.receive(seen, 20) == Error(Nil)
  process.unlink(services.pid)
  process.send_exit(services.pid)
}

pub fn child_ids_requests_exact_large_receipts_and_cancellation_fence_test() {
  let directory = path("children")
  let #(owner, config, pid) =
    start(directory, 1, fn(_, original) { final(original) })
  let original = run(0)
  assert surface(owner, <<"full:authority:workspace:epochs":utf8>>).run(
      original,
    )
    == final(original)
  let key = invocation(original).key
  let assert Ok(child) = remote_tool.tool_child(key, remote_tool.Compile)
    as "compile origin binds the full original parent key"
  let first_id = run(2).result_entry
  let request = <<"prepared request":utf8>>
  assert custodian.reserve_child(owner, child, first_id, request)
    == Ok(#(first_id, request))
  assert custodian.reserve_child(owner, child, run(3).result_entry, request)
    == Ok(#(first_id, request))
  assert custodian.reserve_child(owner, child, first_id, <<"changed":utf8>>)
    == Error(custody.Conflict)
  let outputs =
    list.repeat(bit_array.from_string(string.repeat("x", 16_384)), 64)
  let terminal = bit_array.from_string(string.repeat("t", 32_768))
  let assert Ok(receipt) = custodian.receipt(outputs, terminal)
    as "one MiB output and 32 KiB terminal fit the bounded child envelope"
  assert bit_array.byte_size(receipt) > 1_048_576
  assert bit_array.byte_size(receipt) < 2_097_152
  assert custodian.receive_child(owner, child, first_id, receipt) == Ok(Nil)
  assert custodian.receive_child(owner, child, run(3).result_entry, receipt)
    == Error(custody.Conflict)
  assert custodian.receipt(list.append(outputs, [<<>>]), terminal)
    == Error(custody.Capacity)
  let assert Ok(cancelled) = remote_tool.tool_child(key, remote_tool.Launch)
    as "cancel uses the original launch origin without an invented request ID"
  assert custodian.cancel_child(owner, cancelled) == Ok(Nil)
  assert custodian.cancel_child(owner, cancelled) == Ok(Nil)
  assert custodian.reserve_child(owner, cancelled, run(4).result_entry, request)
    == Error(custody.Frozen)
  stop(owner, pid)
  let assert Ok(reopened) = custodian.start(owner, config)
    as "receipt and cancellation reopen"
  assert custodian.child(owner, child)
    == Ok(#(first_id, request, Some(receipt)))
  assert msgpack.decode(receipt)
    == Ok(
      msgpack.ArrayValue([
        msgpack.ArrayValue(list.map(outputs, msgpack.BinaryValue)),
        msgpack.BinaryValue(terminal),
      ]),
    )
  assert custodian.reserve_child(owner, cancelled, run(4).result_entry, request)
    == Error(custody.Frozen)
  assert custodian.cancel_child(owner, child) == Ok(Nil)
  assert custodian.child(owner, child)
    == Ok(#(first_id, request, Some(receipt)))
  assert custodian.receive_child(owner, child, first_id, receipt) == Ok(Nil)
  assert custodian.reserve_child(owner, child, first_id, request)
    == Error(custody.Frozen)
  stop(owner, reopened.pid)
}

pub fn owner_active_capacity_refuses_before_admission_test() {
  let started = process.new_subject()
  let #(owner, _, pid) =
    start(path("capacity"), 1, fn(_, original) {
      let release = process.new_subject()
      process.send(started, release)
      let assert Ok(Nil) = process.receive(release, 2000)
        as "test releases owned worker"
      final(original)
    })
  let tools = surface(owner, <<"full:authority:workspace:epochs":utf8>>)
  let done = process.new_subject()
  let _caller =
    process.spawn_unlinked(fn() { process.send(done, tools.run(run(0))) })
  let assert Ok(release) = process.receive(started, 1000)
    as "first slot is actively owned"
  let second = invocation(run(1))
  assert custodian.execute(
      owner,
      second.key,
      second.arguments,
      second.request,
      run(1),
    )
    == Error(custody.Capacity)
  assert custodian.lookup(owner, second.key, second.arguments, second.request)
    == Error(custody.Missing)
  assert process.receive(started, 20) == Error(Nil)
  process.send(release, Nil)
  assert process.receive(done, 1000) == Ok(final(run(0)))
  stop(owner, pid)
}

pub fn only_exact_reserved_session_result_collects_test() {
  let directory = path("collection")
  let #(owner, _, pid) =
    start(directory, 1, fn(_, original) { final(original) })
  let original = run(0)
  let key = invocation(original).key
  assert surface(owner, <<"full:authority:workspace:epochs":utf8>>).run(
      original,
    )
    == final(original)
  let assert Ok(source) =
    sqlite.open(
      sqlite.config(directory <> ".session", "binding-test"),
      clock.stepping(1000, 1),
    )
    as "collector reads actual session SQLite rather than a supplied proof"
  let assert Error(_) = custodian.collect(owner, key, source)
    as "owner final persistence alone grants no collection authority"
  let assert effects.ToolCompleted(message, _) = final(original)
    as "fixture has exact finalized message"
  let assert Ok(_) =
    storage.commit(
      source,
      tx.Tx(
        [
          tx.SetRegister(
            register.FactCustom,
            "session/id",
            register.value(json.String(ids.session_id_to_string(session_id()))),
          ),
          tx.InsertEntry(entry.MessageEntry(
            original.result_entry,
            None,
            0,
            0,
            message,
            True,
          )),
        ],
        [],
      ),
    )
    as "original reserved result entry and exact fields durably commit"
  assert custodian.collect(owner, key, source) == Ok(Nil)
  let assert effects.ToolFailed(_) =
    surface(owner, <<"full:authority:workspace:epochs":utf8>>).run(original)
    as "collection keeps a permanent no-rerun fence"
  assert storage.close(source) == Ok(Nil)
  stop(owner, pid)
}

pub fn exact_validator_rejects_changed_fields_and_synthetic_failure_test() {
  let original = run(0)
  let assert effects.ToolCompleted(actual, _) = final(original)
    as "fixture is finalized"
  let assert Ok(encoded) = effects.encode_tool_outcome(final(original))
    as "full exact outcome encodes"
  let assert Ok(payload) = custody.payload(limits(), encoded)
    as "outcome fits custody"
  assert outcome.validate_commit(
      payload,
      custody.ResultReadback(actual, custody.Terminates),
    )
    == Ok(Nil)
  let assert Error(_) =
    outcome.validate_commit(
      payload,
      custody.ResultReadback(actual, custody.Continues),
    )
    as "termination participates in exact collection proof"
  let assert message.ToolResultMessage(
    id,
    name,
    content,
    details,
    usage,
    names,
    is_error,
    timestamp,
  ) = actual
    as "fixture exposes every result field"
  let changed = [
    message.ToolResultMessage(
      id,
      name,
      content,
      details,
      usage,
      names,
      is_error,
      timestamp + 1,
    ),
    message.ToolResultMessage(
      id,
      name,
      content,
      None,
      usage,
      names,
      is_error,
      timestamp,
    ),
    message.ToolResultMessage(
      id,
      name,
      [],
      details,
      usage,
      names,
      is_error,
      timestamp,
    ),
    message.ToolResultMessage(
      id,
      name,
      content,
      details,
      usage,
      None,
      is_error,
      timestamp,
    ),
    message.ToolResultMessage(
      id,
      name,
      content,
      details,
      usage,
      names,
      False,
      timestamp,
    ),
  ]
  list.each(changed, fn(message) {
    let assert Error(_) =
      outcome.validate_commit(
        payload,
        custody.ResultReadback(message, custody.Terminates),
      )
      as "every changed durable message field denies collection"
  })
  let assert Ok(failed) =
    effects.encode_tool_outcome(effects.ToolFailed("unknown"))
    as "failure encodes exactly"
  let assert Ok(failed) = custody.payload(limits(), failed)
    as "failed payload is bounded"
  let assert Error(_) =
    outcome.validate_commit(
      failed,
      custody.ResultReadback(actual, custody.Terminates),
    )
    as "runtime synthetic messages never fabricate owner collection proof"
}
