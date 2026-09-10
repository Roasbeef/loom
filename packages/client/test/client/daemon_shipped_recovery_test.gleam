//// A shipped VM dies after durable reservation but before target assembly.
//// Capacity refusal exposes that boundary without a timing race or failpoint:
//// reservation commits first, while the sole resident session prevents the
//// target from acquiring storage. A fresh VM must restore metadata only and
//// recover the exact reservation when its original creation key is retried.
//// This does not cover the later identity-before-confirmation crash boundary.

import broker/token
import client/tui_e2e_test.{type EunitTest, Timeout}
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap as native
import host/endpoint
import simplifile
import storage/catalogue
import storage/domain
import storage/sqlite
import support/daemon_observation
import support/internal/ffi_proc
import tui/bootstrap as terminal_bootstrap
import tui/daemon
import tui/daemon/bootstrap
import tui/daemon/protocol
import weft
import weft/poll

/// Exercises reservation recovery against the supplied shipped executable.
///
/// ## Examples
///
/// `scripts/test.sh client --match daemon_shipped_reservation_survives_vm_crash`.
pub fn daemon_shipped_reservation_survives_vm_crash_test_() -> EunitTest {
  // EUnit's runner scales this timeout by ten. Native cleanup retains thirty
  // seconds outside the bounded body, including when a body assertion fails.
  Timeout(12, fn() {
    case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
      Error(Nil) ->
        io.println_error(
          "SKIP shipped reservation recovery: LOOM_BOOTSTRAP_E2E_SERVER is unset",
        )
      Ok(server) -> fixture(server)
    }
  })
}

fn fixture(server: String) {
  let directory =
    "build/shipped-recovery-"
    <> bit_array.base16_encode(token.production_entropy()(16))
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the crash fixture owns a fresh private directory"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "native startup receives absolute paths"
  let assert Ok(paths) = endpoint.paths(directory <> "/state")
    as "cleanup retains the private endpoint before startup"
  io.println_error("shipped reservation recovery fixture: " <> directory)
  let outcomes =
    weft.new([
      fn() {
        exercise(server, directory, paths)
        Ok(Nil)
      },
    ])
    |> weft.deadline(90_000)
    |> weft.start

  // The body can fail before returning a connection, or after replacing the
  // first VM. Its private endpoint identifies whichever original child still
  // needs retirement. A closed socket never substitutes for native departure.
  cleanup(paths)
  let assert [weft.Completed(0, Nil)] = outcomes
    as "whole-VM recovery completes within the independent body deadline"
  Nil
}

fn launch(server, paths: endpoint.Paths, configuration) {
  bootstrap.resolve(
    paths,
    process.self(),
    fn() {
      Ok(bootstrap.Launch(
        server,
        list.append(
          terminal_bootstrap.daemon_launch_arguments(
            paths.root,
            server,
            configuration,
          ),
          ["--capacity", "1"],
        ),
      ))
    },
    30_000,
  )
}

fn exercise(server, directory, paths: endpoint.Paths) {
  let workspace = directory <> "/workspace"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
    as "the fixture workspace exists"
  let configuration = directory <> "/fixture.toml"
  let assert Ok(Nil) =
    simplifile.write(
      configuration,
      "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"UNUSED\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n[roles]\nmain = [\"fixture\"]\n[memory]\ndistill = \"off\"\n",
    )
    as "assembly needs neither a provider request nor background distillation"
  let assert Ok(first) = launch(server, paths, configuration)
    as "the shipped daemon authenticates through native bootstrap"
  let assert Ok(protocol.SessionReply(blocker)) =
    daemon.request(
      first.control,
      protocol.CreateSession("occupy", workspace, "blocker", configuration),
      5000,
    )
    as "explicit creation occupies the sole runtime slot"
  await_resident(first, blocker.session_id)

  // This refusal is a durable barrier, not an ambiguous caller timeout. The
  // manager commits the reservation before testing its occupied capacity.
  let request =
    protocol.CreateSession(
      "reserved-at-crash",
      workspace,
      "target",
      configuration,
    )
  let assert Error(daemon.Refused("capacity", _)) =
    daemon.request(first.control, request, 5000)
    as "capacity refuses assembly after committing the target reservation"
  let #(reserved, selected) = durable(paths)
  assert reserved.state == catalogue.Reserved
  assert reserved.request_key == "reserved-at-crash"
  assert reserved.name == "target"
  assert reserved.workspace == workspace
  assert reserved.configuration == configuration
  assert simplifile.is_file(reserved.path) == Ok(False)
  let original = first.record
  crash(paths, original)
  daemon.close(first.control)

  // Preserve the stale discovery record for bootstrap to reconcile. Neither
  // test cleanup nor a registry-only restart performs the takeover for it.
  // Native departure does not witness the separate lock holder's exit. Its
  // port EOF should retire it while the replacement VM boots; otherwise
  // startup fails rather than stealing an occupied lifetime lock.
  assert endpoint.load(paths) == Ok(Some(original))
  assert endpoint.availability(paths) == Ok(endpoint.Vacant)
  assert durable(paths) == #(reserved, selected)
  let assert Ok(second) = launch(server, paths, configuration)
    as "native departure permits a fresh shipped VM to adopt the same state"
  assert second.record.fence != original.fence
  assert daemon.hello(second.control).epoch != daemon.hello(first.control).epoch
  assert endpoint.load(paths) == Ok(Some(second.record))
  assert_empty(second.control)
  assert durable(paths) == #(reserved, selected)
  assert simplifile.is_file(reserved.path) == Ok(False)

  assert_metadata_only(second.control, reserved)
  let assert Ok(protocol.SessionReply(retried)) =
    daemon.request(second.control, request, 5000)
    as "the original creation key explicitly resumes its durable reservation"
  assert retried.session_id == reserved.id
  await_resident(second, reserved.id)

  // Original custody must retire before the independent identity inspection.
  let assert Ok(_) =
    daemon.request(second.control, protocol.StopSession(reserved.id), 5000)
    as "the recovered session begins orderly retirement"
  await_saved(second, reserved.id)
  assert durable(paths)
    == #(catalogue.Registration(..reserved, state: catalogue.Saved), selected)
  let assert Ok(#(Some(id), _)) = sqlite.identity(reserved.path)
    as "the recovered conversation has a real persisted SQLite identity"
  assert id == reserved.id
  let assert Ok(_) = daemon.request(second.control, protocol.Shutdown, 5000)
    as "the recovered daemon accepts orderly shutdown"
  daemon.close(second.control)
  departed(second.record.fence)
}

// Keep inspection connections short-lived and close before checking outcomes.
// These are existing generated DAL reads, never fixture-written reservations.
fn durable(paths: endpoint.Paths) {
  let assert Ok(store) = catalogue.open(paths.catalogue)
    as "the durable catalogue can be inspected independently"
  let record = catalogue.by_request_key(store, "reserved-at-crash")
  let selected =
    result.try(record, fn(record) { domain.for_session(store, record.id) })
  assert catalogue.close(store) == Ok(Nil)
  let assert Ok(record) = record as "the original request key is persisted"
  let assert Ok(selected) = selected
    as "the original domain mapping is persisted"
  #(record, selected)
}

fn assert_empty(control) {
  let assert Ok(protocol.StatusReply(status)) =
    daemon.request(control, protocol.Status, 5000)
    as "metadata-only restoration reports its runtime accounting"
  assert status.capacity == 1
  assert status.occupied == 0
  assert status.opening == 0
  assert status.resident == 0
  assert status.domain_occupied == 0
}

fn assert_metadata_only(control, reserved: catalogue.Registration) {
  let assert Ok(protocol.SessionsReply(page)) =
    daemon.request(control, protocol.ListSessions("", None), 5000)
    as "listing restored metadata does not initialize files"
  assert list.length(page.sessions) == 2
  assert list.any(page.sessions, fn(row) { row.session_id == reserved.id })
  let assert Ok(protocol.SessionReply(row)) =
    daemon.request(control, protocol.GetSession(reserved.id), 5000)
    as "the reserved identity remains individually discoverable"

  // The status is what distinguishes an unfinished reservation from an
  // initialized conversation that ordinary open may resume. It used to be the
  // refusal alone: a slot-less row projected as Saved whatever the catalogue
  // said, so this row was offered for selection and then refused.
  assert row.status == protocol.Reserved
  let assert Error(daemon.Refused("not_initialized", _)) =
    daemon.request(control, protocol.OpenSession(reserved.id), 5000)
    as "ordinary open cannot initialize a reserved conversation"
  assert_empty(control)
  assert simplifile.is_file(reserved.path) == Ok(False)
}

fn await_resident(connected, id) {
  let assert poll.Answered(Nil) =
    poll.until(within: 15_000, every: 25, attempt: fn() {
      case daemon_observation.session(connected, id, 2000) {
        Ok(protocol.SessionReply(protocol.Session(
          status: protocol.Resident(_),
          ..,
        ))) -> poll.Done(Nil)
        Ok(protocol.SessionReply(protocol.Session(
          status: protocol.Opening(_),
          ..,
        ))) -> poll.Retry

        // The timed-out observation has closed its own connection. The next
        // attempt authenticates a fresh owner at the same daemon epoch.
        Error(daemon.TimedOut) -> poll.Retry

        other -> poll.Fail(string.inspect(other))
      }
    })
    as "explicit assembly reaches its resident incarnation"
}

fn await_saved(connected, id) {
  let assert poll.Answered(Nil) =
    poll.until(within: 15_000, every: 25, attempt: fn() {
      case daemon_observation.session(connected, id, 2000) {
        Ok(protocol.SessionReply(protocol.Session(status: protocol.Saved, ..))) ->
          poll.Done(Nil)
        Ok(protocol.SessionReply(protocol.Session(
          status: protocol.Stopping(_),
          ..,
        ))) -> poll.Retry

        // The timed-out observation has closed its own connection. The next
        // attempt authenticates a fresh owner at the same daemon epoch.
        Error(daemon.TimedOut) -> poll.Retry

        other -> poll.Fail(string.inspect(other))
      }
    })
    as "the original runtime custody retires before inspecting its identity"
}

fn crash(paths: endpoint.Paths, original: endpoint.Endpoint) {
  assert endpoint.load(paths) == Ok(Some(original))
  assert original.fence.pid != native.current_process_id()
  assert endpoint.is_present(original.fence) == Ok(True)
  let assert Ok(kill) = ffi_proc.which("kill")
    as "the host provides the ordinary signal utility"
  let assert Ok(#(0, _)) =
    ffi_proc.run(kill, ["-KILL", int.to_string(original.fence.pid)], paths.root)
    as "SIGKILL targets only this fixture's verified original VM"
  departed(original.fence)
}

fn departed(fence: endpoint.Fence) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 10_000, every: 25, attempt: fn() {
      case endpoint.is_present(fence) {
        Ok(False) -> poll.Done(Nil)
        Ok(True) -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })
    as "the original native identity departs, not merely its socket"
  Nil
}

fn cleanup(paths: endpoint.Paths) {
  let assert Ok(record) = endpoint.load(paths)
    as "cleanup decodes only this fixture's private endpoint"
  case record {
    None -> Nil
    Some(record) -> {
      assert record.fence.pid != native.current_process_id()
      let assert Ok(present) = endpoint.is_present(record.fence)
        as "cleanup checks the original birth identity before signaling"
      case present {
        True -> native.terminate_process_group(record.fence.pid)
        False -> Nil
      }
      departed(record.fence)
    }
  }
}
