//// Real filesystem/SQLite counterexamples for semantic effect ownership.
////
//// The existing WriteObserver blocks after an actual disk write, so Unknown
//// and cancellation are tested across the effect window rather than by mocking
//// the service's effect function. All waits are finite; weft owns test callers.

import broker/broker
import broker/exec
import broker/policy
import core/clock
import core/ids
import core/workspace as cw
import executor/remote/workspace_journal as j
import executor/remote/workspace_service as service
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import simplifile
import sqlight
import tools/directory_access
import tools/fs
import tools/hashline
import tools/tool
import tools/workspace as w
import tools/workspace_codec as codec
import tools/workspace_local as local
import weft
import weft/poll

type Parked {
  Parked(worker: process.Pid, release: process.Subject(Nil))
}

pub fn config_binds_exact_scope_and_finite_run_caps_test() {
  fixture("config", fn(root, book) {
    let host = host(root, fn(_) { None })
    assert service.configure(host, book, 0, 1000)
      == Error(service.InvalidConfiguration)
    assert service.configure(host, book, 5, 1000)
      == Error(service.InvalidConfiguration)
    assert service.configure(host, book, 1, 0)
      == Error(service.InvalidConfiguration)
    assert service.configure(host, book, 1, 30_001)
      == Error(service.InvalidConfiguration)
    let wrong = local_host(scope(2), ctx(root), fn(_) { None })
    assert service.configure(wrong, book, 1, 1000)
      == Error(service.InvalidConfiguration)
    let remote = start(host, book, 4, 30_000)
    assert service.scope(remote) == scope(1)
    assert j.mode(book) == Ok(j.Open)
    assert service.close(remote) == Ok(Nil)
    assert j.mode(book) == Ok(j.SealedScope)
    assert simplifile.is_file(root <> "/file") == Ok(False)
  })
}

pub fn duplicate_write_after_caller_loss_replays_exact_completion_once_test() {
  fixture("write-replay", fn(root, book) {
    let parked = process.new_subject()
    let remote = start(host(root, barrier(root, parked)), book, 1, 5000)
    let input = invocation(1, 1, w.Write(path("file"), "landed"))

    // The submitting connection analogue exits before the observer is released.
    let callers =
      weft.new([fn() { Ok(#(process.self(), service.submit(remote, input))) }])
      |> weft.deadline(3000)
      |> weft.start
    let assert [#(caller, Ok(j.Unknown))] = weft.values(callers)
      as "initial status belongs to a caller that has now retired"
    assert !process.is_alive(caller)
    let held = receive_parked(parked)
    assert simplifile.read(root <> "/file") == Ok("landed")
    assert service.submit(remote, input) == Ok(j.Unknown)
    assert service.query(remote, input) == Ok(j.Unknown)
    assert simplifile.read(root <> "/effects") == Ok("effect\n")
    process.send(held.release, Nil)
    let exact = finished(remote, input)
    let assert Ok(Ok(local.Completed(w.WriteCompleted(Ok(_)), None))) =
      codec.decode_completion(w.Write(path("file"), "landed"), exact)
      as "the full real write result was retained"

    assert service.submit(remote, input) == Ok(j.Finished(exact))
    assert service.query(remote, input) == Ok(j.Finished(exact))
    assert simplifile.read(root <> "/effects") == Ok("effect\n")
    assert service.acknowledge(remote, input, j.digest(exact))
      == Ok(j.Acknowledged(j.digest(exact)))
    assert service.submit(remote, input) == Ok(j.Acknowledged(j.digest(exact)))
    assert service.close(remote) == Ok(Nil)
  })
}

pub fn anchored_edit_duplicate_cannot_replace_its_success_with_stale_test() {
  fixture("edit", fn(root, book) {
    assert simplifile.write(root <> "/file", "before\n") == Ok(Nil)
    let remote = start(host(root, counted(root)), book, 1, 3000)
    let assert [first] = hashline.annotate("before\n") as "one anchor"
    let ref = hashline.Ref(first.line, first.anchor)
    let plan =
      hashline.Plan(hashline.digest("before\n"), [
        hashline.Replace(ref, ref, ["after"]),
      ])
    let request = w.AnchoredEdit(path("file"), plan)
    let input = invocation(1, 1, request)
    assert service.submit(remote, input) == Ok(j.Unknown)
    let exact = finished(remote, input)
    let assert Ok(Ok(local.Completed(w.EditCompleted(Ok(_)), None))) =
      codec.decode_completion(request, exact)
      as "original anchored edit succeeded"
    assert simplifile.read(root <> "/file") == Ok("after\n")
    assert service.submit(remote, input) == Ok(j.Finished(exact))
    assert simplifile.read(root <> "/effects") == Ok("effect\n")
    assert service.close(remote) == Ok(Nil)
  })
}

pub fn recovered_started_is_unknown_and_never_touches_disk_test() {
  fixture("recovered-started", fn(root, book) {
    let input = invocation(1, 1, w.Write(path("file"), "forbidden"))
    assert j.admit(book, input) == Ok(j.Accepted)
    let assert Ok(j.Claimed(_)) = j.claim(book, input)
      as "pre-crash first claim"
    assert j.release(book) == Ok(Nil)
    let recovered = recover(root)
    let remote = start(host(root, counted(root)), recovered, 1, 1000)
    assert service.submit(remote, input) == Ok(j.Unknown)
    assert service.query(remote, input) == Ok(j.Unknown)
    assert simplifile.is_file(root <> "/file") == Ok(False)
    assert simplifile.is_file(root <> "/effects") == Ok(False)
    assert service.close(remote) == Ok(Nil)
    assert j.release(recovered) == Ok(Nil)
  })
}

pub fn recovered_accepted_may_take_only_its_first_claim_test() {
  fixture("recovered-accepted", fn(root, book) {
    let input = invocation(1, 1, w.Write(path("file"), "first"))
    assert j.admit(book, input) == Ok(j.Accepted)
    assert j.release(book) == Ok(Nil)
    let recovered = recover(root)
    let remote = start(host(root, counted(root)), recovered, 1, 1000)
    assert service.submit(remote, input) == Ok(j.Unknown)
    let exact = finished(remote, input)
    assert service.submit(remote, input) == Ok(j.Finished(exact))
    assert simplifile.read(root <> "/effects") == Ok("effect\n")
    assert service.close(remote) == Ok(Nil)
    assert j.release(recovered) == Ok(Nil)
  })
}

pub fn seal_fences_first_claims_across_independent_open_and_recovery_test() {
  fixture("sealed", fn(root, book) {
    let accepted = invocation(1, 1, w.Write(path("file"), "forbidden"))
    let new = invocation(2, 1, w.Write(path("file"), "new"))
    assert j.admit(book, accepted) == Ok(j.Accepted)
    let other = recover(root)
    assert j.seal(book) == Ok(j.SealedScope)
    assert j.seal(book) == Ok(j.SealedScope)
    assert j.mode(other) == Ok(j.SealedScope)
    assert j.claim(other, accepted) == Error(j.Sealed)
    assert j.admit(other, new) == Error(j.Sealed)
    assert j.admit(other, accepted) == Ok(j.Accepted)
    let remote = start(host(root, counted(root)), other, 1, 1000)
    assert service.submit(remote, accepted) == Error(service.Custody(j.Sealed))
    assert service.query(remote, accepted) == Ok(j.Accepted)
    assert service.close(remote) == Ok(Nil)
    assert j.release(book) == Ok(Nil)
    assert j.release(other) == Ok(Nil)
    let final = recover(root)
    assert j.mode(final) == Ok(j.SealedScope)
    assert j.claim(final, accepted) == Error(j.Sealed)
    assert j.admit(final, new) == Error(j.Sealed)
    assert simplifile.is_file(root <> "/file") == Ok(False)
    assert j.release(final) == Ok(Nil)
  })
}

pub fn completion_and_ack_remain_exact_after_seal_and_reopen_test() {
  fixture("sealed-completion", fn(root, book) {
    let parked = process.new_subject()
    let remote = start(host(root, barrier(root, parked)), book, 1, 5000)
    let input = invocation(1, 1, w.Write(path("file"), "landed"))
    assert service.submit(remote, input) == Ok(j.Unknown)
    let held = receive_parked(parked)
    assert j.seal(book) == Ok(j.SealedScope)
    process.send(held.release, Nil)
    let exact = finished(remote, input)
    assert service.query(remote, input) == Ok(j.Finished(exact))
    assert service.submit(remote, input) == Ok(j.Finished(exact))
    assert service.acknowledge(remote, input, j.digest(exact))
      == Ok(j.Acknowledged(j.digest(exact)))
    assert service.close(remote) == Ok(Nil)
    assert j.release(book) == Ok(Nil)
    let final = recover(root)
    assert j.mode(final) == Ok(j.SealedScope)
    assert j.inspect(final, input) == Ok(j.Acknowledged(j.digest(exact)))
    assert j.claim(final, input)
      == Ok(j.Existing(j.Acknowledged(j.digest(exact))))
    assert simplifile.read(root <> "/effects") == Ok("effect\n")
    assert j.release(final) == Ok(Nil)
  })
}

pub fn active_capacity_refuses_before_admission_but_duplicates_reconcile_test() {
  fixture("capacity", fn(root, book) {
    let parked = process.new_subject()
    let remote = start(host(root, barrier(root, parked)), book, 1, 5000)
    let first = invocation(1, 1, w.Write(path("file"), "first"))
    let second = invocation(2, 1, w.Write(path("next"), "second"))
    assert service.submit(remote, first) == Ok(j.Unknown)
    let held = receive_parked(parked)
    assert service.submit(remote, first) == Ok(j.Unknown)
    assert service.submit(remote, second) == Error(service.Capacity)
    assert j.inspect(book, second) == Error(j.Missing)
    assert j.claim(book, second) == Error(j.Missing)
    assert simplifile.is_file(root <> "/next") == Ok(False)
    process.send(held.release, Nil)
    let _ = finished(remote, first)

    // A completed run returns its live slot without deleting the original fence.
    let assert poll.Answered(j.Unknown) =
      poll.until(2000, 10, fn() {
        case service.submit(remote, second) {
          Ok(status) -> poll.Done(status)
          Error(service.Capacity) -> poll.Retry
          Error(error) -> poll.Fail(error)
        }
      })
      as "the first final report returned capacity"
    let second_held = receive_parked(parked)
    process.send(second_held.release, Nil)
    let _ = finished(remote, second)
    assert simplifile.read(root <> "/effects") == Ok("effect\neffect\n")
    assert service.close(remote) == Ok(Nil)
  })
}

pub fn task_deadline_keeps_landed_effect_unknown_without_replay_test() {
  fixture("deadline", fn(root, book) {
    let parked = process.new_subject()
    let remote = start(host(root, barrier(root, parked)), book, 1, 100)
    let input = invocation(1, 1, w.Write(path("file"), "landed"))
    assert service.submit(remote, input) == Ok(j.Unknown)
    let held = receive_parked(parked)
    gone(held.worker)
    assert simplifile.read(root <> "/file") == Ok("landed")
    assert service.query(remote, input) == Ok(j.Unknown)
    assert service.submit(remote, input) == Ok(j.Unknown)
    assert j.claim(book, input) == Ok(j.Existing(j.Unknown))
    assert simplifile.read(root <> "/effects") == Ok("effect\n")
    assert service.close(remote) == Ok(Nil)
  })
}

pub fn close_seals_then_joins_and_never_claims_filesystem_rollback_test() {
  fixture("close", fn(root, book) {
    let parked = process.new_subject()
    let remote = start(host(root, barrier(root, parked)), book, 1, 5000)
    let input = invocation(1, 1, w.Write(path("file"), "landed"))
    assert service.submit(remote, input) == Ok(j.Unknown)
    let held = receive_parked(parked)
    assert service.close(remote) == Ok(Nil)
    gone(service.pid(remote))
    assert !process.is_alive(held.worker)
    assert j.mode(book) == Ok(j.SealedScope)
    assert j.inspect(book, input) == Ok(j.Unknown)
    assert j.claim(book, input) == Ok(j.Existing(j.Unknown))
    assert simplifile.read(root <> "/file") == Ok("landed")
    assert simplifile.read(root <> "/effects") == Ok("effect\n")
    assert j.release(book) == Ok(Nil)
    let final = recover(root)
    assert j.mode(final) == Ok(j.SealedScope)
    assert j.inspect(final, input) == Ok(j.Unknown)
    assert j.release(final) == Ok(Nil)
  })
}

pub fn completion_encode_failure_after_write_stays_unknown_test() {
  fixture("encoding", fn(root, book) {
    let workers = process.new_subject()
    let remote =
      start(
        host(root, fn(_) {
          mark(root)
          process.send(workers, process.self())
          Some(string.repeat("x", 65_537))
        }),
        book,
        1,
        1000,
      )
    let input = invocation(1, 1, w.Write(path("file"), "landed"))
    assert service.submit(remote, input) == Ok(j.Unknown)
    let assert poll.Answered(Nil) =
      poll.until(2000, 10, fn() {
        case simplifile.read(root <> "/effects") {
          Ok("effect\n") -> poll.Done(Nil)
          _ -> poll.Retry
        }
      })
      as "the actual filesystem effect happened before encoding failed"
    let assert Ok(worker) = process.receive(workers, 1000)
      as "the encoder's concrete worker identity"
    gone(worker)
    assert service.query(remote, input) == Ok(j.Unknown)
    assert service.close(remote) == Ok(Nil)
    assert j.inspect(book, input) == Ok(j.Unknown)
    assert j.claim(book, input) == Ok(j.Existing(j.Unknown))
    assert simplifile.read(root <> "/file") == Ok("landed")
  })
}

pub fn canonical_byte_and_scope_validation_precedes_effects_test() {
  fixture("invalid", fn(root, book) {
    let remote = start(host(root, counted(root)), book, 1, 1000)
    let valid = invocation(1, 1, w.Write(path("file"), "landed"))
    assert service.submit(remote, <<0xc0>>) == Error(service.InvalidInput)
    assert service.submit(remote, <<valid:bits, 0>>)
      == Error(service.InvalidInput)
    assert service.submit(
        remote,
        invocation(1, 2, w.Write(path("file"), "wrong")),
      )
      == Error(service.ScopeMismatch)
    assert service.acknowledge(remote, valid, <<0:size(255)>>)
      == Error(service.InvalidInput)
    assert j.inspect(book, valid) == Error(j.Missing)
    assert simplifile.is_file(root <> "/file") == Ok(False)
    assert service.close(remote) == Ok(Nil)
  })
}

pub fn seal_failure_still_cancels_tasks_and_retains_original_unknown_test() {
  fixture("seal-failure", fn(root, book) {
    let parked = process.new_subject()
    let remote = start(host(root, barrier(root, parked)), book, 1, 5000)
    let input = invocation(1, 1, w.Write(path("file"), "landed"))
    assert service.submit(remote, input) == Ok(j.Unknown)
    let held = receive_parked(parked)
    execute(
      root,
      "CREATE TRIGGER fail_seal BEFORE UPDATE ON workspace_meta BEGIN SELECT RAISE(FAIL,'seal fault'); END",
    )
    assert service.close(remote) == Error(service.Uncertain)
    gone(service.pid(remote))
    assert !process.is_alive(held.worker)
    let final = recover(root)
    assert j.mode(final) == Ok(j.Open)
    assert j.inspect(final, input) == Ok(j.Unknown)
    assert j.claim(final, input) == Ok(j.Existing(j.Unknown))
    assert simplifile.read(root <> "/effects") == Ok("effect\n")
    assert j.release(final) == Ok(Nil)
  })
}

pub fn old_or_invalid_metadata_refuses_recovery_without_migration_test() {
  fixture("version", fn(root, book) {
    assert j.release(book) == Ok(Nil)
    execute(
      root,
      "PRAGMA ignore_check_constraints=ON; UPDATE workspace_meta SET format=1",
    )
    assert j.recover(root <> "/custody.sqlite", scope(1), limits())
      == Error(j.Corrupt)
    let assert Ok(connection) = sqlight.open(root <> "/custody.sqlite")
      as "verify no version migration"
    assert sqlight.query(
        "SELECT format FROM workspace_meta",
        connection,
        [],
        decode.field(0, decode.int, decode.success),
      )
      == Ok([1])
    assert sqlight.close(connection) == Ok(Nil)
  })
  fixture("old-schema", fn(root, book) {
    assert j.release(book) == Ok(Nil)
    execute(root, "ALTER TABLE workspace_meta DROP COLUMN mode")
    assert j.recover(root <> "/custody.sqlite", scope(1), limits())
      == Error(j.Corrupt)
  })
}

pub fn task_crash_after_write_keeps_unknown_and_service_alive_test() {
  fixture("task-crash", fn(root, book) {
    let workers = process.new_subject()
    let remote =
      start(
        host(root, fn(_) {
          mark(root)
          process.send(workers, process.self())
          panic as "fixture observer crashes after the disk effect"
        }),
        book,
        1,
        1000,
      )
    let input = invocation(1, 1, w.Write(path("file"), "landed"))
    assert service.submit(remote, input) == Ok(j.Unknown)
    let assert Ok(worker) = process.receive(workers, 1000)
      as "crashed effect worker"
    gone(worker)
    assert service.query(remote, input) == Ok(j.Unknown)
    assert service.submit(remote, input) == Ok(j.Unknown)
    assert process.is_alive(service.pid(remote))
    assert simplifile.read(root <> "/effects") == Ok("effect\n")
    assert service.close(remote) == Ok(Nil)
  })
}

pub fn actor_kill_after_claim_cancels_owned_run_without_replay_test() {
  fixture("actor-kill", fn(root, book) {
    let parked = process.new_subject()
    let remote = start(host(root, barrier(root, parked)), book, 1, 5000)
    let input = invocation(1, 1, w.Write(path("file"), "landed"))
    assert service.submit(remote, input) == Ok(j.Unknown)
    let held = receive_parked(parked)
    process.kill(service.pid(remote))
    gone(service.pid(remote))
    gone(held.worker)
    assert service.submit(remote, input) == Error(service.Uncertain)
    assert j.inspect(book, input) == Ok(j.Unknown)
    assert j.release(book) == Ok(Nil)
    let final = recover(root)
    let restarted = start(host(root, counted(root)), final, 1, 1000)
    assert service.submit(restarted, input) == Ok(j.Unknown)
    assert simplifile.read(root <> "/effects") == Ok("effect\n")
    assert service.close(restarted) == Ok(Nil)
    assert j.release(final) == Ok(Nil)
  })
}

pub fn failed_completion_persistence_after_write_keeps_unknown_on_recovery_test() {
  fixture("finish-failure", fn(root, book) {
    let parked = process.new_subject()
    let remote = start(host(root, barrier(root, parked)), book, 1, 5000)
    let input = invocation(1, 1, w.Write(path("file"), "landed"))
    assert service.submit(remote, input) == Ok(j.Unknown)
    let held = receive_parked(parked)
    execute(
      root,
      "CREATE TRIGGER fail_finish BEFORE UPDATE ON workspace_call WHEN NEW.phase=2 BEGIN SELECT RAISE(FAIL,'finish fault'); END",
    )
    process.send(held.release, Nil)
    gone(held.worker)

    // The worker observes the failed commit reply before the journal finishes
    // shutting down. A query racing that shutdown can lose its reply instead
    // of observing an already-closed actor; neither result permits replay.
    assert list.contains(
      [Error(service.Custody(j.Closed)), Error(service.Custody(j.Uncertain))],
      service.query(remote, input),
    )
    assert service.close(remote) == Error(service.Uncertain)
    let final = recover(root)
    assert j.inspect(final, input) == Ok(j.Unknown)
    assert j.claim(final, input) == Ok(j.Existing(j.Unknown))
    assert simplifile.read(root <> "/file") == Ok("landed")
    assert simplifile.read(root <> "/effects") == Ok("effect\n")
    assert j.release(final) == Ok(Nil)
  })
}

fn fixture(name: String, run: fn(String, j.Journal) -> Nil) {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let root =
    "/tmp/loom-workspace-effect-"
    <> name
    <> "-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  assert simplifile.create_directory(root) == Ok(Nil)
  let assert Ok(book) = j.fresh(root <> "/custody.sqlite", scope(1), limits())
    as "real SQLite custody"
  run(root, book)
  let _ = j.release(book)
  assert simplifile.delete(root) == Ok(Nil)
}

fn scope(epoch: Int) -> cw.Scope {
  let assert Ok(scope) =
    cw.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "checkout",
      "executor",
      epoch,
      1,
    )
    as "exact scope"
  scope
}

fn limits() -> j.Limits {
  let assert Ok(limits) = j.limits(6, 256_000_000) as "whole result reservation"
  limits
}

fn recover(root: String) -> j.Journal {
  let assert Ok(book) = j.recover(root <> "/custody.sqlite", scope(1), limits())
    as "original exact evidence"
  book
}

fn path(value: String) -> cw.RelativePath {
  let assert Ok(path) = cw.relative_path(value) as "relative semantic path"
  path
}

fn operation() -> ids.OpId {
  let assert Ok(op) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "operation identity"
  op
}

fn invocation(number: Int, epoch: Int, request: w.Request) -> BitArray {
  let assert Ok(id) =
    ids.parse_entry_id(
      "00000000-0000-7000-8000-"
      <> string.pad_start(int.to_string(number), 12, "0"),
    )
    as "original invocation identity"
  let assert Ok(step) = cw.step("physical-step") as "physical step"
  let assert Ok(bytes) =
    codec.encode_invocation(w.invocation(
      scope(epoch),
      operation(),
      step,
      w.System(w.WorkspaceAdministration),
      id,
      request,
    ))
    as "whole canonical invocation"
  bytes
}

fn ctx(root: String) -> tool.Ctx {
  tool.Ctx(
    workspace: tool.LocalWorkspace(root, fs.real_filesystem()),
    strand: "main",
    op_id: operation(),
    step_id: "physical-step",
    source_index: 0,
    base_policy: policy.workspace_default(root),
    directory_access: directory_access.none(),
    grants: [],
    demand: exec.FullEnforcement,
    env: [],
    clock: clock.fixed(0),
    owner_blobs: tool.OwnerBlobs(root <> "/.blobs", fs.real_filesystem()),
    clear_call: fn(_, _) { Error(broker.BrokerUnavailable) },
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
}

fn host(root: String, observer: fs.WriteObserver) -> local.Host {
  local_host(scope(1), ctx(root), observer)
}

fn start(
  host: local.Host,
  book: j.Journal,
  active: Int,
  within: Int,
) -> service.Service {
  let assert Ok(config) = service.configure(host, book, active, within)
    as "checked assembly"
  let assert Ok(remote) = service.start(config) as "effect service actor"
  remote
}

fn mark(root: String) {
  let previous = case simplifile.read(root <> "/effects") {
    Ok(text) -> text
    Error(_) -> ""
  }
  assert simplifile.write(root <> "/effects", previous <> "effect\n") == Ok(Nil)
}

fn counted(root: String) -> fs.WriteObserver {
  fn(_) {
    mark(root)
    None
  }
}

fn barrier(root: String, parked: process.Subject(Parked)) -> fs.WriteObserver {
  fn(_) {
    mark(root)
    let release = process.new_subject()
    process.send(parked, Parked(process.self(), release))
    let assert Ok(Nil) = process.receive(release, 10_000)
      as "finite fixture observation barrier"
    None
  }
}

fn receive_parked(parked: process.Subject(Parked)) -> Parked {
  let assert Ok(held) = process.receive(parked, 2000)
    as "post-write observation"
  held
}

fn finished(remote: service.Service, input: BitArray) -> BitArray {
  let assert poll.Answered(bytes) =
    poll.until(3000, 10, fn() {
      case service.query(remote, input) {
        Ok(j.Finished(bytes)) -> poll.Done(bytes)
        Ok(j.Unknown) -> poll.Retry
        value -> poll.Fail(value)
      }
    })
    as "exact committed completion"
  bytes
}

fn gone(pid: process.Pid) {
  let assert poll.Answered(Nil) =
    poll.until(2000, 10, fn() {
      case process.is_alive(pid) {
        True -> poll.Retry
        False -> poll.Done(Nil)
      }
    })
    as "finite task join"
}

fn execute(root: String, text: String) {
  let assert Ok(connection) = sqlight.open(root <> "/custody.sqlite")
    as "test fault connection"
  assert sqlight.exec(text, connection) == Ok(Nil)
  assert sqlight.close(connection) == Ok(Nil)
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
