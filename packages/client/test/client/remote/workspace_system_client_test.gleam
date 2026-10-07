//// Registered system first-submit controls over actual SQLite and TLS services.
//// The filesystem adapter resolves and reads real executor-only files. A narrow
//// wrapper counts actual read calls and exposes fixed file barriers; it cannot
//// manufacture a semantic completion. Owner receipt mutations are SQL faults.

import broker/enrollment
import broker/exec
import broker/executor as native
import broker/policy
import client/daemon/deployment
import client/remote/custodian
import client/remote/workspace_binding as binding
import client/remote/workspace_client as client
import core/clock
import core/generation
import core/ids
import core/remote_tool
import core/workspace as cw
import distribution_fixture
import executor/remote/admission
import executor/remote/beam_endpoint as connection
import executor/remote/distribution
import executor/remote/identity
import executor/remote/internal/beam_protocol as transport
import executor/remote/journal as native_journal
import executor/remote/registration
import executor/remote/service as native_service
import executor/remote/workspace_journal as journal
import executor/remote/workspace_service as service
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import sqlight
import storage/owner_custody as custody
import support/workspace_system_beam_fixture as beam_fixture
import telemetry/log
import tools/directory_access
import tools/fs
import tools/tool
import tools/workspace
import tools/workspace_codec as codec
import tools/workspace_local as local
import weft/poll
import weft/registry

type Fixture {
  FixtureState(
    root: String,
    owner: custodian.Handle,
    ready: custodian.RegisteredOwner,
    owner_config: custodian.Config,
    owner_pid: process.Pid,
    book: journal.Journal,
    connection: connection.Config,
  )
}

pub fn preadmit_then_ordinary_invoke_observes_without_a_first_read_test() {
  use peer <- beam_fixture.run(
    "preadmit_then_ordinary_invoke_observes_without_a_first_read_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  let c = config(f, 500)
  let #(plan, intent) = retained_plan(f, c, "control", 11, path("proof.txt"))
  let assert Ok(admitted) =
    custodian.admit_system_child(f.owner, intent, fn(origin, id) {
      payload(path("proof.txt"), origin, id)
    })
    as "Actual pre-admission commits the system origin without executor work."
  assert admitted.admission == custody.Fresh
  start_executor(f)
  let assert Ok(ordinary) =
    client.new(
      scope(),
      f.owner,
      fn() { entry(999) },
      connection.Config(..f.connection, within_ms: 500),
      500,
    )
    as "Legacy consumer binds exact original scope."
  let answer =
    client.invoke(
      ordinary,
      admitted.origin,
      operation(),
      step(),
      workspace.System(workspace.WorkspaceAdministration),
      workspace.Read(path("proof.txt"), workspace.Text),
    )
  assert answer
    == Error(client.OwnerUnavailable(
      admitted.origin,
      custody.Invalid("registered system child requires retained intent"),
    ))
  assert read_count(f) == 0
  let assert Ok(row) = custodian.child(f.owner, admitted.origin)
    as "Actual child remains retained with no receipt."
  assert row.0 == entry(11)
  assert row.2 == None
  assert connection.workspace_exchange(f.connection, transport.Query, row.1)
    == Error(connection.Uncertain)

  // The named path receives Retained too; no API accepts the earlier Fresh enum.
  assert_system_pending(client.invoke_system(c, plan, intent))
  assert read_count(f) == 0
  assert executor_rows(f) == 0
  finish(f)
}

pub fn actual_first_read_retains_large_original_bytes_before_ack_test() {
  use peer <- beam_fixture.run(
    "actual_first_read_retains_large_original_bytes_before_ack_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  let source = string.repeat("x", 1_048_577)
  assert simplifile.write(f.root <> "/executor/proof.txt", source) == Ok(Nil)
  assert simplifile.write(f.root <> "/owner/proof.txt", "owner canary")
    == Ok(Nil)
  let c = config(f, 5000)
  let #(plan, intent) = retained_plan(f, c, "first", 11, path("proof.txt"))
  assert bit_array.byte_size(client.system_read_content(plan)) < 8192
  start_executor(f)
  assert_completed(client.invoke_system(c, plan, intent), source)
  assert read_count(f) == 1
  let origin = system_child(0)
  let assert Ok(#(id, request, Some(receipt))) =
    custodian.child(f.owner, origin)
    as "Complete original source bytes have durable owner custody before return."
  assert id == entry(11)
  assert bit_array.byte_size(receipt) > 1_048_576
  assert custodian.receipt_generation(f.owner, origin, id)
    == Ok(#(receipt, association()))
  assert connection.workspace_exchange(f.connection, transport.Query, request)
    == Ok(journal.Acknowledged(journal.digest(receipt)))
  assert simplifile.read(f.root <> "/owner/proof.txt") == Ok("owner canary")

  // A new physical file cannot replace the original retained source on retry.
  assert simplifile.write(f.root <> "/executor/proof.txt", "later") == Ok(Nil)
  assert_completed(client.invoke_system(c, plan, intent), source)
  assert read_count(f) == 1
  assert scalar(f, "SELECT COUNT(*) FROM owner_system_intent") == 1
  assert scalar(f, "SELECT next_ordinal FROM owner_system_ordinal") == 1
  finish(f)
}

pub fn concurrent_exact_admission_performs_one_real_read_test() {
  use peer <- beam_fixture.run(
    "concurrent_exact_admission_performs_one_real_read_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  let c = config(f, 5000)
  let deadline = poll.monotonic().now() + 20_000
  let assert Ok(plan) =
    client.system_read_plan(
      c,
      "concurrent",
      operation(),
      step(),
      entry(11),
      path("proof.txt"),
      deadline,
    )
    as "Concurrent callers share the exact original fixed deadline."
  let intent = retain(f, "concurrent", 11, plan)
  start_executor(f)
  let answers = process.new_subject()
  let caller = fn() {
    process.send(answers, client.invoke_system(c, plan, intent))
  }
  let _ = process.spawn_unlinked(caller)
  let _ = process.spawn_unlinked(caller)
  let assert Ok(first) = process.receive(answers, 10_000)
    as "First original observer settles."
  let assert Ok(second) = process.receive(answers, 10_000)
    as "Concurrent retained observer settles."
  diagnose_concurrent(first, "first", deadline)
  diagnose_concurrent(second, "second", deadline)
  let first_receipt = concurrent_completion(c, plan, intent, first, deadline)
  let second_receipt = concurrent_completion(c, plan, intent, second, deadline)
  assert first_receipt == second_receipt
  let assert Ok(#(id, request, Some(receipt))) =
    custodian.child(f.owner, system_child(0))
    as "Both callers converge to the same original durable receipt."
  assert id == entry(11)
  assert receipt == first_receipt
  let assert Ok(expected_request) =
    codec.encode_invocation(invocation(
      path("proof.txt"),
      system_child(0),
      entry(11),
    ))
    as "The retained original request compares to the exact fixed invocation."
  assert request == expected_request
  assert custodian.receipt_generation(f.owner, system_child(0), id)
    == Ok(#(receipt, association()))
  assert connection.workspace_exchange(f.connection, transport.Query, request)
    == Ok(journal.Acknowledged(journal.digest(receipt)))
  assert poll.monotonic().now() < deadline
  assert read_count(f) == 1
  assert scalar(f, "SELECT COUNT(*) FROM owner_custody_children") == 1
  assert scalar(f, "SELECT COUNT(*) FROM owner_system_intent") == 1
  assert scalar(f, "SELECT next_ordinal FROM owner_system_ordinal") == 1
  finish(f)
}

pub fn full_plan_endpoint_generation_and_changed_request_refuse_test() {
  use peer <- beam_fixture.run(
    "full_plan_endpoint_generation_and_changed_request_refuse_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  let table = deployment_table(peer)
  assert client.new_system(
      f.ready,
      table,
      connection.Config(..f.connection, generation: 2),
      limits(codec.max_completion_bytes),
      5000,
    )
    == Error(client.InvalidConfiguration)
  assert client.new_system(
      f.ready,
      table,
      connection.Config(..f.connection, scope: identity_scope(2)),
      limits(codec.max_completion_bytes),
      5000,
    )
    == Error(client.InvalidConfiguration)
  let c = config(f, 5000)
  let deadline = poll.monotonic().now() + 20_000
  let assert Ok(plan) =
    client.system_read_plan(
      c,
      "changed",
      operation(),
      step(),
      entry(11),
      path("proof.txt"),
      deadline,
    )
    as "Original whole plan fixes one deadline for every changed-field control."
  let intent = retain(f, "changed", 11, plan)
  let variants = [
    #(operation(), step(), entry(11), path("different.txt")),
    #(
      ids.mint_op(ids.generator(clock.fixed(1000), 99)).0,
      step(),
      entry(11),
      path("proof.txt"),
    ),
    #(operation(), checked_step("other"), entry(11), path("proof.txt")),
    #(operation(), step(), entry(12), path("proof.txt")),
  ]
  list.each(variants, fn(v) {
    let assert Ok(changed) =
      client.system_read_plan(c, "changed", v.0, v.1, v.2, v.3, deadline)
      as "Changed coordinates form another pure plan, never another retained intent."
    assert client.invoke_system(c, changed, intent)
      == Error(client.InvalidSystemPlan)
  })
  assert scalar(f, "SELECT COUNT(*) FROM owner_custody_children") == 0
  start_executor(f)
  assert_completed(client.invoke_system(c, plan, intent), "original")
  let assert Ok(changed_binding) =
    binding.system_reservation(
      f.owner,
      readback(f, intent),
      invocation(path("proof.txt"), system_child(0), entry(11)),
    )
    as "Exact canonical expected reservation validates."
  assert bit_array.byte_size(binding.content(changed_binding)) > 0
  assert binding.system_reservation(
      f.owner,
      readback(f, intent),
      invocation(path("different.txt"), system_child(0), entry(11)),
    )
    == Error(custody.Conflict)
  assert read_count(f) == 1
  finish(f)
}

pub fn incomplete_actual_child_readback_refuses_before_submit_test() {
  use peer <- beam_fixture.run(
    "incomplete_actual_child_readback_refuses_before_submit_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  let c = config(f, 5000)
  let #(plan, intent) =
    retained_plan(f, c, "incomplete-child", 11, path("proof.txt"))
  start_executor(f)
  mutate(
    f,
    "CREATE TRIGGER suppress_child_link BEFORE INSERT ON owner_child_generation BEGIN SELECT RAISE(IGNORE); END",
  )
  let assert Error(client.SystemOwnerUnavailable(_)) =
    client.invoke_system(c, plan, intent)
    as "An inserted request without complete generation link never escapes as Fresh."
  assert scalar(f, "SELECT COUNT(*) FROM owner_custody_children") == 0
  assert scalar(f, "SELECT next_ordinal FROM owner_system_ordinal") == 0
  assert read_count(f) == 0
  mutate(f, "DROP TRIGGER suppress_child_link")
  mutate(
    f,
    "CREATE TRIGGER replace_child_uuid AFTER INSERT ON owner_custody_children BEGIN UPDATE owner_custody_children SET request_id='"
      <> ids.entry_id_to_string(entry(99))
      <> "'; END",
  )
  let assert Error(client.SystemOwnerUnavailable(_)) =
    client.invoke_system(c, plan, intent)
    as "The full real child UUID must match the original intent before first Submit."
  assert scalar(f, "SELECT COUNT(*) FROM owner_custody_children") == 0
  assert scalar(f, "SELECT next_ordinal FROM owner_system_ordinal") == 0
  assert read_count(f) == 0
  mutate(f, "DROP TRIGGER replace_child_uuid")
  assert_completed(client.invoke_system(c, plan, intent), "original")
  assert read_count(f) == 1
  finish(f)
}

pub fn permissive_encoder_profile_cannot_bypass_original_owner_quota_test() {
  use peer <- beam_fixture.run(
    "permissive_encoder_profile_cannot_bypass_original_owner_quota_test",
  )
  let f = fixture(peer, 2048)
  let c = config(f, 500)
  let #(plan, intent) =
    retained_plan(f, c, "quota", 11, path(string.repeat("a", 3000)))
  start_executor(f)
  assert client.invoke_system(c, plan, intent)
    == Error(client.SystemOwnerUnavailable(custody.Capacity))
  assert scalar(f, "SELECT COUNT(*) FROM owner_custody_children") == 0
  assert scalar(f, "SELECT next_ordinal FROM owner_system_ordinal") == 0
  assert read_count(f) == 0
  finish(f)
}

pub fn receipt_readback_failure_withholds_ack_and_completion_test() {
  use peer <- beam_fixture.run(
    "receipt_readback_failure_withholds_ack_and_completion_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  let c = config(f, 5000)
  let #(plan, intent) = retained_plan(f, c, "receipt", 11, path("proof.txt"))
  mutate(
    f,
    "CREATE TRIGGER reject_receipt BEFORE UPDATE OF terminal ON owner_custody_children BEGIN SELECT RAISE(ABORT, 'receipt refusal'); END",
  )
  start_executor(f)
  let assert Ok(client.Pending(reserved, client.ReceiptUncertain)) =
    client.invoke_system(c, plan, intent)
    as "Real read completed but no durable receipt can authorize source promotion."
  assert read_count(f) == 1
  let assert Ok(journal.Finished(bytes)) =
    connection.workspace_exchange(
      f.connection,
      transport.Query,
      binding.content(reserved),
    )
    as "Executor retains the real complete source without ACK."
  mutate(f, "DROP TRIGGER reject_receipt")
  assert simplifile.write(f.root <> "/executor/proof.txt", "later") == Ok(Nil)
  assert_completed(client.invoke_system(c, plan, intent), "original")
  assert custodian.receipt_generation(f.owner, system_child(0), entry(11))
    == Ok(#(bytes, association()))
  assert read_count(f) == 1
  finish(f)
}

pub fn canonical_wrong_association_after_receipt_commit_withholds_ack_test() {
  use peer <- beam_fixture.run(
    "canonical_wrong_association_after_receipt_commit_withholds_ack_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  let c = config(f, 5000)
  let #(plan, intent) =
    retained_plan(f, c, "receipt-association", 11, path("proof.txt"))
  let #(key, hash, _, predecessor) =
    generation.association_fields(association())
  let wrong = generation.association(key, hash, entry(99), predecessor)
  let assert Ok(encoded) = generation.encode_association(wrong)
    as "Wrong owner-use remains a complete canonical association."
  let update = association_update(encoded, entry(99))
  mutate(
    f,
    "CREATE TRIGGER replace_receipt_association AFTER UPDATE OF terminal ON owner_custody_children BEGIN "
      <> update
      <> "; END",
  )
  start_executor(f)
  let assert Ok(client.Pending(reserved, client.ReceiptUncertain)) =
    client.invoke_system(c, plan, intent)
    as "The actual receipt writer succeeds, but a different complete association cannot authorize ACK or Completed."
  let assert Ok(#(receipt, actual)) =
    custodian.receipt_generation(f.owner, system_child(0), entry(11))
    as "Receipt readback really returns complete valid bytes and the changed association."
  assert actual == wrong
  assert connection.workspace_exchange(
      f.connection,
      transport.Query,
      binding.content(reserved),
    )
    == Ok(journal.Finished(receipt))
  assert read_count(f) == 1

  // Restoration reconciles only the original read and completion, not new work.
  mutate(f, "DROP TRIGGER replace_receipt_association")
  let assert Ok(original) = generation.encode_association(association())
    as "Original canonical association."
  mutate(f, association_update(original, entry(1)))
  assert_completed(client.invoke_system(c, plan, intent), "original")
  assert read_count(f) == 1
  finish(f)
}

pub fn suppressed_receipt_readback_never_promotes_or_acknowledges_test() {
  use peer <- beam_fixture.run(
    "suppressed_receipt_readback_never_promotes_or_acknowledges_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  let c = config(f, 5000)
  let #(plan, intent) =
    retained_plan(f, c, "suppressed-receipt", 11, path("proof.txt"))
  mutate(
    f,
    "CREATE TRIGGER suppress_receipt BEFORE UPDATE OF terminal ON owner_custody_children BEGIN SELECT RAISE(IGNORE); END",
  )
  start_executor(f)
  let assert Ok(client.Pending(reserved, client.ReceiptUncertain)) =
    client.invoke_system(c, plan, intent)
    as "Successful SQL return without actual terminal readback grants no completion or ACK."
  assert custodian.receipt_generation(f.owner, system_child(0), entry(11))
    == Error(custody.Missing)
  let assert Ok(journal.Finished(_)) =
    connection.workspace_exchange(
      f.connection,
      transport.Query,
      binding.content(reserved),
    )
    as "Original executor completion survives suppressed owner receipt."
  mutate(f, "DROP TRIGGER suppress_receipt")
  assert_completed(client.invoke_system(c, plan, intent), "original")
  assert read_count(f) == 1
  finish(f)
}

pub fn discarded_original_admission_reply_is_retained_without_submit_test() {
  use peer <- beam_fixture.run(
    "discarded_original_admission_reply_is_retained_without_submit_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  let c = config(f, 500)
  let #(plan, intent) =
    retained_plan(f, c, "discarded-admission", 11, path("proof.txt"))

  // The actual original transaction completes, but its returned evidence is
  // deliberately dropped. Later invocation must not recreate its first send.
  let _unobserved =
    custodian.admit_system_child(f.owner, intent, fn(origin, id) {
      payload(path("proof.txt"), origin, id)
    })
  start_executor(f)
  assert_system_pending(client.invoke_system(c, plan, intent))
  let assert Ok(row) = custodian.child(f.owner, system_child(0))
    as "Original identity can be read back."
  assert row.0 == entry(11)
  assert row.2 == None
  assert connection.workspace_exchange(f.connection, transport.Query, row.1)
    == Error(connection.Uncertain)
  assert read_count(f) == 0
  assert executor_rows(f) == 0
  assert scalar(f, "SELECT next_ordinal FROM owner_system_ordinal") == 1
  finish(f)
}

pub fn original_unacknowledged_real_receipt_recovers_without_second_read_test() {
  use peer <- beam_fixture.run(
    "original_unacknowledged_real_receipt_recovers_without_second_read_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  let c = config(f, 5000)
  let #(plan, intent) =
    retained_plan(f, c, "unacknowledged-receipt", 11, path("proof.txt"))
  let assert Ok(admitted) =
    custodian.admit_system_child(f.owner, intent, fn(origin, id) {
      payload(path("proof.txt"), origin, id)
    })
    as "Original real Fresh transaction."
  let assert Ok(reserved) =
    binding.system_reservation(
      f.owner,
      admitted,
      invocation(path("proof.txt"), admitted.origin, admitted.request_id),
    )
    as "Exact actual reservation."
  start_executor(f)
  assert connection.workspace_exchange(
      f.connection,
      transport.Submit,
      binding.content(reserved),
    )
    == Ok(journal.Unknown)
  let assert poll.Answered(receipt) =
    poll.until(5000, 10, fn() {
      case
        connection.workspace_exchange(
          f.connection,
          transport.Query,
          binding.content(reserved),
        )
      {
        Ok(journal.Finished(bytes)) -> poll.Done(bytes)
        _ -> poll.Retry
      }
    })
    as "Direct boundary control observes the same claimed real filesystem read; it never submits again."
  let assert Ok(_) = binding.receive(reserved, receipt)
    as "Original writer commits exact real receipt."

  // This control deliberately ends observation at the receipt/ACK boundary.
  // It has no manufactured completion and sends no replacement request.
  assert connection.workspace_exchange(
      f.connection,
      transport.Query,
      binding.content(reserved),
    )
    == Ok(journal.Finished(receipt))
  assert simplifile.write(f.root <> "/executor/proof.txt", "later") == Ok(Nil)
  assert_completed(client.invoke_system(c, plan, intent), "original")
  assert read_count(f) == 1
  finish(f)
}

pub fn reopened_history_has_no_system_send_authority_test() {
  use peer <- beam_fixture.run(
    "reopened_history_has_no_system_send_authority_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  let c = config(f, 5000)
  let #(plan, intent) = retained_plan(f, c, "history", 11, path("proof.txt"))
  let #(pending_plan, pending_intent) =
    retained_plan(f, c, "history-pending", 12, path("proof.txt"))
  start_executor(f)
  assert_completed(client.invoke_system(c, plan, intent), "original")
  stop_owner(f)
  let assert Ok(started) = custodian.start(f.owner, f.owner_config)
    as "Historical original companion reopens."
  let history = FixtureState(..f, owner_pid: started.pid)
  assert custodian.registered(history.owner)
    == Ok(custodian.HistoryOnly(pin(), association()))
  let assert Error(client.SystemOwnerUnavailable(_)) =
    client.invoke_system(c, pending_plan, pending_intent)
    as "Original pinned ready configuration cannot follow a replacement actor."
  let retained = retain(history, "history", 11, plan)
  let assert Ok(admitted) =
    custodian.admit_system_child(history.owner, retained, fn(origin, id) {
      payload(path("proof.txt"), origin, id)
    })
    as "Historical readback preserves original coordinates."
  assert admitted.admission == custody.Retained
  assert custodian.admit_system_child(
      history.owner,
      pending_intent,
      fn(origin, id) { payload(path("proof.txt"), origin, id) },
    )
    == Error(custody.Frozen)
  assert read_count(history) == 1
  assert scalar(history, "SELECT next_ordinal FROM owner_system_ordinal") == 1
  finish(history)
}

pub fn caller_death_leaves_original_service_completion_owned_test() {
  use peer <- beam_fixture.run(
    "caller_death_leaves_original_service_completion_owned_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  let c = config(f, 5000)
  let #(plan, intent) =
    retained_plan(f, c, "caller-death", 11, path("proof.txt"))
  beam_fixture.mark(f.root, "hold-read")
  start_executor(f)
  let caller =
    process.spawn_unlinked(fn() {
      let _ = client.invoke_system(c, plan, intent)
      Nil
    })
  beam_fixture.await(f.root, "reading")
  let monitor = process.monitor(caller)
  process.kill(caller)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "Caller is gone while executor read remains service-owned."
  beam_fixture.mark(f.root, "release-read")
  let assert Ok(#(_, request, _)) = custodian.child(f.owner, system_child(0))
    as "Admitted original identity remains after caller death."
  let assert poll.Answered(bytes) =
    poll.until(5000, 10, fn() {
      case
        connection.workspace_exchange(f.connection, transport.Query, request)
      {
        Ok(journal.Finished(bytes)) -> poll.Done(bytes)
        _ -> poll.Retry
      }
    })
    as "Actual service commits the read independently of the dead observer."
  assert codec.decode_completion(
      workspace.Read(path("proof.txt"), workspace.Text),
      bytes,
    )
    |> result.is_ok
  assert_completed(client.invoke_system(c, plan, intent), "original")
  assert read_count(f) == 1
  finish(f)
}

pub fn original_fixed_deadline_expires_without_renewal_or_read_test() {
  use peer <- beam_fixture.run(
    "original_fixed_deadline_expires_without_renewal_or_read_test",
  )
  let f = fixture(peer, codec.max_completion_bytes)
  let c = config(f, 5000)
  let assert Ok(plan) =
    client.system_read_plan(
      c,
      "expired",
      operation(),
      step(),
      entry(11),
      path("proof.txt"),
      poll.monotonic().now() - 1,
    )
    as "Pure metadata can represent historical expired work."
  let intent = retain(f, "expired", 11, plan)
  start_executor(f)
  assert client.invoke_system(c, plan, intent)
    == Error(client.SystemObservationExpired)
  assert scalar(f, "SELECT COUNT(*) FROM owner_custody_children") == 0
  assert read_count(f) == 0
  finish(f)
}

fn assert_completed(answer, expected: String) {
  let assert Ok(client.Completed(
    Ok(local.Completed(
      workspace.ReadCompleted(Ok(workspace.TextRead(text))),
      None,
    )),
    client.Confirmed,
  )) = answer
    as "Actual Read/Text bytes, canonical receipt and matching ACK complete."
  assert text == expected
}

// Missing Query has no status frame and can exhaust the first observer's budget
// before the winner replies. Only that exact transport uncertainty may observe
// the same retained plan; it cannot replace the UUID or renew its fixed deadline.
fn concurrent_completion(
  config: client.SystemConfig,
  plan: client.SystemReadPlan,
  intent: custody.IntentReadback,
  answer: Result(client.Outcome, client.SystemError),
  deadline: Int,
) -> BitArray {
  let completed = case answer {
    Ok(client.Completed(_, client.Confirmed)) -> answer
    Ok(client.Pending(reservation, client.TransportUncertain)) -> {
      let expected = invocation(path("proof.txt"), system_child(0), entry(11))
      assert binding.invocation(reservation) == expected
      assert binding.system_origin(reservation) == Ok(system_child(0))
      assert poll.monotonic().now() < deadline
      client.invoke_system(config, plan, intent)
    }
    _ ->
      panic as "Only the diagnosed original transport uncertainty may recover."
  }
  assert_completed(completed, "original")
  let assert Ok(client.Completed(result, client.Confirmed)) = completed
    as "Each original observer reaches canonical acknowledged completion."
  let assert Ok(bytes) =
    codec.encode_completion(
      workspace.Read(path("proof.txt"), workspace.Text),
      result,
    )
    as "Both observed completions have the same canonical receipt representation."
  bytes
}

// Diagnostics project only the outcome variant and original identity checks.
// They never print the opaque reservation or loosen completion requirements.
fn diagnose_concurrent(
  answer: Result(client.Outcome, client.SystemError),
  label: String,
  deadline: Int,
) {
  let kind = case answer {
    Ok(client.Completed(_, client.Confirmed)) -> "completed-confirmed"
    Ok(client.Completed(_, client.Retained)) -> "completed-retained"
    Ok(client.Pending(reservation, reason)) -> {
      let expected = invocation(path("proof.txt"), system_child(0), entry(11))
      assert binding.invocation(reservation) == expected
      assert binding.system_origin(reservation) == Ok(system_child(0))
      case reason {
        client.AwaitingEvidence ->
          "pending-awaiting-evidence-original-id-origin-checked"
        client.TransportUncertain ->
          "pending-transport-uncertain-original-id-origin-checked"
        client.ReceiptUncertain ->
          "pending-receipt-uncertain-original-id-origin-checked"
      }
    }
    Ok(client.Cancelled(_)) -> "cancelled"
    Ok(client.InvariantFailure(_)) -> "invariant-failure"
    Error(client.InvalidSystemPlan) -> "invalid-plan"
    Error(client.SystemObservationExpired) -> "observation-expired"
    Error(client.SystemObservationLost) -> "observation-lost"
    Error(client.SystemOwnerUnavailable(_)) -> "owner-unavailable"
  }
  io.println(
    "CONCURRENT "
    <> label
    <> " "
    <> kind
    <> " remaining-ms="
    <> int.to_string(deadline - poll.monotonic().now()),
  )
}

fn assert_system_pending(answer: Result(client.Outcome, client.SystemError)) {
  case answer {
    Ok(client.Pending(_, client.AwaitingEvidence))
    | Ok(client.Pending(_, client.TransportUncertain))
    | Error(client.SystemObservationExpired) -> Nil
    _ -> panic as "Retained system admission must remain observation-only."
  }
}

fn config(f: Fixture, within: Int) -> client.SystemConfig {
  let assert Ok(value) =
    client.new_system(
      f.ready,
      deployment_table(f.connection.peer),
      connection.Config(..f.connection, within_ms: within),
      limits(codec.max_completion_bytes),
      within,
    )
    as "Real registered owner and actual concrete endpoint form a closed system configuration."
  value
}

fn retained_plan(
  f: Fixture,
  c: client.SystemConfig,
  address: String,
  seed: Int,
  path: cw.RelativePath,
) {
  let assert Ok(plan) =
    client.system_read_plan(
      c,
      address,
      operation(),
      step(),
      entry(seed),
      path,
      poll.monotonic().now() + 20_000,
    )
    as "Complete original plan is fixed before child admission."
  #(plan, retain(f, address, seed, plan))
}

fn retain(f: Fixture, address: String, seed: Int, plan: client.SystemReadPlan) {
  let assert Ok(intent) =
    custodian.retain_system_intent(
      f.owner,
      address,
      custody.WorkspaceAdministration,
      operation(),
      cw.step_string(step()),
      entry(seed),
      client.system_read_content(plan),
    )
    as "Actual SQLite custodian retains original fixed system intent."
  intent
}

fn invocation(
  path: cw.RelativePath,
  _origin: remote_tool.ChildOrigin,
  id: ids.EntryId,
) {
  workspace.invocation(
    scope(),
    operation(),
    step(),
    workspace.System(workspace.WorkspaceAdministration),
    id,
    workspace.Read(path, workspace.Text),
  )
}

fn payload(
  path: cw.RelativePath,
  origin: remote_tool.ChildOrigin,
  id: ids.EntryId,
) {
  let assert Ok(bytes) = codec.encode_invocation(invocation(path, origin, id))
    as "Closed canonical complete semantic read."
  custody.workspace_request(limits(codec.max_completion_bytes), bytes)
  |> result.map(custody.WorkspaceSystem)
}

fn readback(f: Fixture, intent: custody.IntentReadback) {
  let assert Ok(value) =
    custodian.admit_system_child(f.owner, intent, fn(origin, id) {
      payload(path("proof.txt"), origin, id)
    })
    as "Retained actual origin can be inspected without Fresh authority."
  assert value.admission == custody.Retained
  value
}

fn system_child(ordinal: Int) {
  let assert Ok(value) =
    remote_tool.system_child(session(), "workspace-administration", ordinal)
    as "Only actual allocated origin is used for test inspection."
  value
}

fn limits(payload: Int) {
  let assert Ok(value) = custody.limits(4, 64, 268_435_456, payload)
    as "Finite original owner ceiling."
  value
}

fn fixture(peer: distribution.Peer, payload: Int) -> Fixture {
  let root = beam_fixture.root() <> "/data"
  assert simplifile.create_directory_all(root <> "/owner") == Ok(Nil)
  assert simplifile.create_directory_all(root <> "/executor") == Ok(Nil)
  assert simplifile.write(root <> "/executor/proof.txt", "original") == Ok(Nil)
  assert simplifile.write(root <> "/read-count", "0") == Ok(Nil)
  let assert Ok(names) = registry.start()
    as "Fixture owns an original registry."
  let assert Ok(owner_config) =
    custodian.config_with_reports(
      root <> "/owner/custody.db",
      session(),
      limits(payload),
      1,
      5000,
      fn(_, _, _) { panic as "System reads must never execute a parent tool." },
      bootstrap.sha256,
    )
    as "Original owner actor has finite custody."
  let assert Ok(owner_config) =
    custodian.with_registered(owner_config, pin(), association(), 1)
    as "Original registered immutable metadata."
  let owner = custodian.new(names, owner_config)
  let assert Ok(started) = custodian.start(owner, owner_config)
    as "Actual original SQLite writer starts."
  let assert Ok(custodian.ReadyForActivation(ready)) =
    custodian.registered(owner)
    as "Only this original writer grants assembly readiness; this is not activation."
  let assert Ok(book_limits) = journal.limits(4, 268_435_456)
    as "Original executor journal ceiling."
  let assert Ok(book) =
    journal.fresh(root <> "/executor/custody.db", scope(), book_limits)
    as "Actual separate executor SQLite journal."
  FixtureState(
    root,
    owner,
    ready,
    owner_config,
    started.pid,
    book,
    connection.Config(peer, "owner", "executor", identity_scope(1), 1, 5000),
  )
}

fn pin() -> custody.EnrollmentPin {
  let roots = ["/work", "/build", "/channel"]
  let base = policy.workspace_default("/work")
  let ceiling =
    policy.SandboxPolicy(
      ..base,
      writable_roots: roots,
      readable_roots: ["/tools", "/seed"],
      protected: [],
      mounts: [],
    )
  let native =
    enrollment.NativeFacts(scope(), roots, ceiling, exec.FullEnforcement)
  let code =
    enrollment.CodeModeFacts(
      "/work",
      "/build",
      "/channel",
      "/tools/gleam",
      "/tools/erl",
      "/seed",
      ["/tools"],
      [],
      "/tools",
    )
  let assert Ok(registered) =
    registration.new(
      identity_scope(1),
      roots,
      ceiling,
      exec.FullEnforcement,
      Ok,
    )
    as "Actual registration codec validates fixed native enrollment."
  let digest =
    identity.digest_bytes(registration.digest(registered))
    |> bit_array.base16_encode
    |> string.lowercase
  let assert Ok(enrolled) =
    enrollment.new(native, code, digest, string.repeat("4", 64))
    as "Complete immutable enrollment."
  let assert Ok(bytes) = enrollment.encode(enrolled)
    as "Canonical full enrollment bytes."
  let assert Ok(descriptor) = generation.digest(<<2:size(256)>>)
    as "Descriptor width."
  let assert Ok(hash) = generation.digest(bootstrap.sha256(bytes))
    as "Real SHA-256 of complete canonical enrollment."
  let #(_, binding) = cw.scope_fields(scope())
  let assert Ok(pin) =
    custody.enrollment_pin(session(), binding, descriptor, hash, bytes)
    as "Complete original pin."
  pin
}

fn association() {
  let #(_, _, descriptor, hash, _) = custody.enrollment_fields(pin())
  let assert Ok(key) = generation.key(scope(), descriptor, 1)
    as "Original generation."
  generation.association(key, hash, entry(1), generation.FirstGeneration)
}

fn deployment_table(peer: distribution.Peer) {
  let node = distribution.name(peer)
  let digest =
    generation.digest_bytes(custody.enrollment_fields(pin()).2)
    |> bit_array.base16_encode
    |> string.lowercase
  let document = "schema = 1
endpoint_lifetime = \"retired_slots_v1\"
owner = \"owner\"
local_node = \"owner@owner.example.invalid\"
[membership]
ca = \"/etc/loom-owner/ca.pem\"
certificate = \"/etc/loom-owner/cert.pem\"
key = \"/etc/loom-owner/key.pem\"
cookie = \"/etc/loom-owner/.erlang.cookie\"
options = \"/etc/loom-owner/tls.options\"
[[peers]]
node = \"" <> node <> "\"
leaf_sha256 = \"" <> string.repeat("1", 64) <> "\"
[[workspaces]]
executor = \"executor\"
workspace = \"checkout\"
peer = \"" <> node <> "\"
workspace_epoch = 1
session_epoch = 1
first_generation = 1
generation_policy = \"clean_successor\"
descriptor_sha256 = \"" <> digest <> "\"
"
  let assert Ok(table) = deployment.decode(document)
    as "Immutable selected deployment table."
  table
}

fn counted_filesystem(root: String) -> tool.FileSystem {
  let original = fs.real_filesystem()
  tool.FileSystem(..original, read: fn(path) {
    let directory = root <> "/.."
    let assert Ok(text) = simplifile.read(directory <> "/read-count")
      as "Finite read counter."
    let assert Ok(count) = int.parse(text) as "Exact read count."
    assert simplifile.write(
        directory <> "/read-count",
        int.to_string(count + 1),
      )
      == Ok(Nil)
    beam_fixture.mark(directory, "reading")
    case simplifile.is_file(directory <> "/hold-read") {
      Ok(True) -> beam_fixture.await(directory, "release-read")
      _ -> Nil
    }
    original.read(path)
  })
}

fn read_count(f: Fixture) -> Int {
  let assert Ok(text) = simplifile.read(f.root <> "/read-count")
    as "Original counter is readable."
  let assert Ok(value) = int.parse(text) as "Original counter is integer."
  value
}

fn mutate(f: Fixture, statement: String) -> Nil {
  let assert Ok(db) = sqlight.open(f.root <> "/owner/custody.db")
    as "Test SQL fault injector is not a custody Store."
  assert sqlight.exec(statement, db) == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
}

fn scalar(f: Fixture, statement: String) -> Int {
  let assert Ok(db) = sqlight.open(f.root <> "/owner/custody.db")
    as "Finite independent evidence inspector."
  let assert Ok([value]) =
    sqlight.query(statement, db, [], decode.at([0], decode.int))
    as "One exact scalar row."
  assert sqlight.close(db) == Ok(Nil)
  value
}

fn executor_rows(f: Fixture) -> Int {
  let assert Ok(db) = sqlight.open(f.root <> "/executor/custody.db")
    as "Read-only test inspection of actual executor journal rows."
  let assert Ok([value]) =
    sqlight.query(
      "SELECT COUNT(*) FROM workspace_call",
      db,
      [],
      decode.at([0], decode.int),
    )
    as "Exact journal row inventory."
  assert sqlight.close(db) == Ok(Nil)
  value
}

fn association_update(bytes: BitArray, owner_use: ids.EntryId) -> String {
  "UPDATE owner_generation_associations SET association=X'"
  <> bit_array.base16_encode(bytes)
  <> "',digest=X'"
  <> bit_array.base16_encode(bootstrap.sha256(bytes))
  <> "',owner_use='"
  <> ids.entry_id_to_string(owner_use)
  <> "'"
}

fn checked_step(text: String) {
  let assert Ok(value) = cw.step(text) as "Closed step validates."
  value
}

/// The fixed executor role hosts actual SQLite, filesystem and native services.
/// Only test barriers control setup; production operations cross the TLS endpoint.
pub fn executor_main() -> Nil {
  let runtime_root = beam_fixture.root()
  let root = runtime_root <> "/data"
  let assert Ok(provisioned) =
    distribution_fixture.read_provisioned(runtime_root <> "/fixture.term")
    as "The executor receives only its original administrative fixture."
  let assert Ok(membership) = distribution.start(provisioned.executor_config)
    as "The independent executor enters real mutual TLS membership."
  let assert Ok(owner) = distribution.peer(membership, provisioned.owner_name)
    as "The registered owner has exact admitted boot provenance."
  let assert poll.Answered(Nil) =
    poll.until(10_000, 10, fn() {
      case simplifile.is_file(root <> "/start") {
        Ok(True) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "The owner commits and releases test setup before executor startup."

  // Executor reservations have a distinct actual SQLite journal and ceiling.
  let assert Ok(limits) = journal.limits(4, 268_435_456)
    as "The executor retains the original reservation ceiling."
  let assert Ok(book) =
    journal.recover(root <> "/executor/custody.db", scope(), limits)
    as "The original journal metadata and historical fences reopen unchanged."
  let host = local_host(scope(), context(root <> "/executor"), fn(_) { None })
  let assert Ok(config) = service.configure(host, book, 2, 10_000)
    as "Concrete semantic host and journal share the exact original scope."
  let assert Ok(semantic) = service.start(config)
    as "Real executor-local filesystem work owns its own effect custody."

  // Enrollment derives from concrete local service owners, never wire callbacks.
  let #(native_executor, native_remote) = concrete_native(root)
  let assert Ok(row) =
    connection.registration(
      owner,
      native_remote,
      Some(semantic),
      process.self(),
    )
    as "Enrollment binds the actual native and semantic actors locally."
  let assert Ok(server_config) = connection.configure_server([row], 10_000)
    as "Only this original scope enters the finite node-wide rendezvous."
  let assert Ok(endpoint) = connection.start(server_config)
    as "The actual fixed endpoint publishes after TLS bootstrap and local setup."
  beam_fixture.mark(root, "ready")

  // The original enclosing executor role owns physical service close and join.
  let assert poll.Answered(Nil) =
    poll.until(20_000, 10, fn() {
      case simplifile.is_file(root <> "/done") {
        Ok(True) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "Finite fixed role reaches original host shutdown."
  connection.quiesce(endpoint)
  assert service.close(semantic) == Ok(Nil)
  assert journal.mode(book) == Ok(journal.SealedScope)
  assert journal.release(book) == Ok(Nil)
  connection.stop(endpoint)
  assert native.close(native_executor, draining: 1000, helpers: 1000) == Ok(Nil)
  beam_fixture.mark(runtime_root, "executor-success")
}

fn concrete_native(root: String) {
  let assert Ok(executor) =
    native.start(native.ExecutorConfig(
      fn() { Error(exec.PoolUnavailable) },
      fn(_) { Nil },
      fn() { Error(exec.PoolUnavailable) },
      fn(_) { Ok(Nil) },
      4,
      log.discard(),
    ))
    as "A real native actor exists; semantic-only cases allocate no process pool."
  let assert Ok(capacity) = admission.capacity(4)
    as "Native admission remains finite even though these cases send no commands."
  let assert Ok(book) =
    native_journal.fresh(root <> "/native.sqlite", identity_scope(1), capacity)
    as "Actual native registration has separate SQLite custody."
  let assert Ok(remote) =
    native_service.start(native_service.Config(
      "owner",
      "executor",
      identity_scope(1),
      1,
      book,
      executor,
      fn(_, _) { Ok(Nil) },
      poll.monotonic().now,
    ))
    as "The endpoint enrollment derives from the real scoped native service."
  #(executor, remote)
}

// Seeding commits before the executor opens this same journal. Recovery retains
// its exact metadata, Accepted/Started fences and all original invocation bytes.
fn start_executor(f: Fixture) -> Nil {
  case simplifile.is_file(f.root <> "/start") {
    Ok(True) -> Nil
    _ -> {
      assert journal.release(f.book) == Ok(Nil)
      beam_fixture.mark(f.root, "start")
      beam_fixture.await(f.root, "ready")
    }
  }
}

fn context(root: String) -> tool.Ctx {
  tool.Ctx(
    workspace: tool.LocalWorkspace(root, counted_filesystem(root)),
    strand: "main",
    op_id: operation(),
    step_id: "workspace",
    source_index: 0,
    base_policy: policy.workspace_default(root),
    directory_access: directory_access.none(),
    grants: [],
    demand: exec.FullEnforcement,
    env: [],
    clock: clock.fixed(1000),
    owner_blobs: tool.OwnerBlobs(root <> "/.blobs", fs.real_filesystem()),
    clear_call: fn(_, _) {
      panic as "File-only fixture must not launch a process."
    },
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
}

fn session() {
  ids.mint_session(ids.generator(clock.fixed(1000), 1)).0
}

fn operation() {
  ids.mint_op(ids.generator(clock.fixed(1000), 2)).0
}

fn entry(seed: Int) {
  ids.mint_entry(ids.generator(clock.fixed(1000), seed)).0
}

fn step() {
  let assert Ok(value) = cw.step("workspace") as "Fixture step validates."
  value
}

fn path(text: String) {
  let assert Ok(value) = cw.relative_path(text) as "Fixture path is relative."
  value
}

fn scope() {
  let assert Ok(value) =
    cw.scope_from_fields(
      ids.session_id_to_string(session()),
      "checkout",
      "executor",
      1,
      1,
    )
    as "Complete scope validates."
  value
}

fn identity_scope(epoch: Int) {
  let assert Ok(w) = identity.workspace_id("checkout")
    as "Workspace label validates."
  let assert Ok(e) = identity.executor_id("executor")
    as "Executor label validates."
  let assert Ok(owner_epoch) = identity.epoch(epoch) as "Owner epoch validates."
  let assert Ok(workspace_epoch) = identity.epoch(1)
    as "Workspace epoch validates."
  identity.scope(session(), w, e, owner_epoch, workspace_epoch)
}

fn stop_owner(f: Fixture) {
  let monitor = process.monitor(f.owner_pid)
  assert custodian.stop(f.owner) == Ok(Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "SQLite owner exits before reopen."
  Nil
}

fn finish(f: Fixture) {
  assert journal.release(f.book) == Ok(Nil)
  stop_owner(f)
  beam_fixture.mark(f.root, "done")
  beam_fixture.await(beam_fixture.root(), "executor-success")
}

// A registered context cannot construct the executor-local host.
fn local_host(
  scope: cw.Scope,
  ctx: tool.Ctx,
  observer: fn(String) -> option.Option(String),
) -> local.Host {
  let assert Ok(host) = local.new(scope, ctx, observer)
    as "fixture must have local authority"
  host
}
