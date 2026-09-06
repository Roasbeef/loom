//// A shipped VM dies after SQLite identity publication but before confirmation.
//// An actual MCP initialize request proves assembly crossed identity publication.
//// The handshake has a finite timeout, so post-crash Reserved metadata and the
//// exact SQLite identity, not the marker alone, prove the interrupted boundary.
//// Recovery observes the original lease and waits for its natural expiry before
//// retrying the same creation key. No provider or code-mode program is executed.

import broker/token
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/json
import gleam/bit_array
import gleam/dynamic/decode
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
import sqlight
import storage/catalogue
import storage/domain
import storage/sqlite
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
/// `scripts/test.sh client --match daemon_shipped_identity_survives_vm_crash`.
pub fn daemon_shipped_identity_survives_vm_crash_test_() -> EunitTest {
  // EUnit's runner scales this timeout by ten. Native cleanup retains thirty
  // seconds outside the bounded body, including when a body assertion fails.
  Timeout(23, fn() {
    case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
      Error(Nil) ->
        io.println_error(
          "SKIP shipped identity recovery: LOOM_BOOTSTRAP_E2E_SERVER is unset",
        )
      Ok(server) -> fixture(server)
    }
  })
}

fn fixture(server: String) {
  let directory =
    "build/shipped-identity-recovery-"
    <> bit_array.base16_encode(token.production_entropy()(16))
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the crash fixture owns a fresh private directory"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "native startup receives absolute paths"
  let assert Ok(paths) = endpoint.paths(directory <> "/state")
    as "cleanup retains the private endpoint before startup"
  io.println_error("shipped identity recovery fixture: " <> directory)
  let outcomes =
    weft.new([
      fn() {
        exercise(server, directory, paths)
        Ok(Nil)
      },
    ])
    |> weft.deadline(200_000)
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
  // The isolated workspace has no seed. Use the gate's prepared repository
  // seed through the ordinary operator flag, so MCP is actually registered.
  let assert Ok(seed) = native.canonical_directory("../../build/codemode-seed")
    as "the enabled fixture requires make codemode-seed"
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
          ["--capacity", "1", "--codemode-seed", seed],
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
  let assert Ok(escript) = ffi_proc.which("escript")
    as "the enabled fixture requires the installed OTP escript"
  let assert Ok(script) =
    native.canonical_path("test/support/mcp_identity_barrier.escript")
    as "the fixture uses its checked-in test-only stdio server"
  let marker = directory <> "/initialized"
  let release = directory <> "/answer-initialize"
  let configuration = directory <> "/fixture.toml"
  write_configuration(configuration, escript, script, marker, release)
  let assert Ok(first) = launch(server, paths, configuration)
    as "the shipped daemon authenticates through native bootstrap"
  let request =
    protocol.CreateSession(
      "identity-at-crash",
      workspace,
      "target",
      configuration,
    )
  let assert Ok(protocol.SessionReply(created)) =
    daemon.request(first.control, request, 5000)
    as "creation publishes a parked operation before assembly"
  let #(reserved, selected) = durable(paths)
  assert reserved.id == created.session_id
  assert reserved.state == catalogue.Reserved

  // Receipt is an observation, not an indefinite latch: MCP can time out and
  // let assembly continue without that server. Do not inspect files in a loop
  // hoping to kill in time; the checks after native departure decide the proof.
  let mcp_fence = await_initialize(marker)
  let original = first.record
  crash(paths, original)
  daemon.close(first.control)
  departed(mcp_fence)
  assert durable(paths) == #(reserved, selected)
  assert reserved.state == catalogue.Reserved
  assert_identity(reserved.path, reserved.id)
  let original_lease = lease(reserved.path)
  let #(_, _, expires) = original_lease
  assert expires > native.system_time_ms()
    as "the crashed writer still owns an unexpired lease"

  // Only the test server's response policy changes. The durable configuration
  // path, request key and domain remain byte-for-byte identical on both retries.
  assert simplifile.write(release, "answer") == Ok(Nil)
  assert endpoint.load(paths) == Ok(Some(original))
  assert endpoint.availability(paths) == Ok(endpoint.Vacant)
  let assert Ok(second) = launch(server, paths, configuration)
    as "actual native departure permits stale-fence takeover"
  assert second.record.fence != original.fence
  assert daemon.hello(second.control).epoch != daemon.hello(first.control).epoch
  assert_empty(second.control)
  assert durable(paths) == #(reserved, selected)
  assert_metadata_only(second.control, reserved)

  // A real create is admitted, but its storage open must refuse the crashed
  // writer's unexpired lease. A stolen lease would reach Resident and fail the
  // bounded Saved observation; any lease mutation also fails the exact check.
  assert expires > native.system_time_ms()
    as "the immediate retry is made before natural expiry"
  let assert Ok(protocol.SessionReply(immediate)) =
    daemon.request(second.control, request, 5000)
    as "the same-key immediate retry keeps its original reservation"
  assert immediate.session_id == reserved.id
  await_saved(second.control, reserved.id)
  assert durable(paths) == #(reserved, selected)
  assert lease(reserved.path) == original_lease
  assert_identity(reserved.path, reserved.id)

  io.println_error(
    "identity recovery intentionally waits for the crashed writer's natural 60-second lease expiry",
  )
  let assert poll.Answered(Nil) =
    poll.until(within: 65_000, every: 100, attempt: fn() {
      case native.system_time_ms() >= expires {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "natural lease expiry is bounded without rewriting durable timestamps"
  assert lease(reserved.path) == original_lease
  let assert Ok(protocol.SessionReply(retried)) =
    daemon.request(second.control, request, 5000)
    as "explicit same-key creation resumes after the original lease expires"
  assert retried.session_id == reserved.id
  await_resident(second.control, reserved.id)
  assert durable(paths)
    == #(catalogue.Registration(..reserved, state: catalogue.Saved), selected)
  assert_identity(reserved.path, reserved.id)
  let #(old_owner, old_fence, _) = original_lease
  let #(new_owner, new_fence, _) = lease(reserved.path)
  assert new_owner != old_owner
  assert new_fence > old_fence

  let assert Ok(_) =
    daemon.request(second.control, protocol.StopSession(reserved.id), 5000)
    as "the recovered original identity begins orderly retirement"
  await_saved(second.control, reserved.id)
  let assert Ok(_) = daemon.request(second.control, protocol.Shutdown, 5000)
    as "the recovered daemon accepts orderly shutdown"
  daemon.close(second.control)
  departed(second.record.fence)
}

fn write_configuration(path, escript, script, marker, release) -> Nil {
  // JSON strings use the same escaping needed by these TOML basic strings.
  // Fixture paths never enter a shell command or an executable search path.
  let command =
    [escript, script, marker, release]
    |> list.map(fn(value) { json.to_string(json.String(value)) })
    |> string.join(", ")
  let assert Ok(Nil) =
    simplifile.write(
      path,
      "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"UNUSED\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n[roles]\nmain = [\"fixture\"]\n[memory]\ndistill = \"off\"\n[mcp.identity_barrier]\ncommand = ["
        <> command
        <> "]\n",
    )
    as "metadata-only configuration selects the real external startup barrier"
  Nil
}

fn await_initialize(marker) -> endpoint.Fence {
  let assert poll.Answered(pid) =
    poll.until(within: 20_000, every: 10, attempt: fn() {
      case simplifile.read(marker) {
        Ok(text) ->
          case int.parse(string.trim(text)) {
            Ok(pid) if pid > 1 -> poll.Done(pid)
            _ -> poll.Fail("the initialize marker must contain the server PID")
          }
        Error(_) -> poll.Retry
      }
    })
    as "actual MCP initialize arrives; missing code-mode/MCP prerequisites fail"
  let assert Ok(native.ProcessPresent(birth)) = native.process_identity(pid)
    as "the reporting test server's native birth identity is observable"
  endpoint.Fence(pid, birth, native.system_time_ms())
}

fn assert_identity(path, expected) -> Nil {
  let assert Ok(#(Some(id), _)) = sqlite.identity(path)
    as "the conversation contains a persisted SQLite identity"
  assert id == expected
  Nil
}

// This test-only query observes the actual writer fence without attempting an
// acquisition. Close its connection before checking rows, including on errors.
fn lease(path) {
  assert simplifile.is_file(path) == Ok(True)
  let assert Ok(connection) = sqlight.open(path)
    as "the existing identity database permits independent lease observation"
  let decoder = {
    use owner <- decode.field(0, decode.string)
    use fence <- decode.field(1, decode.int)
    use expires <- decode.field(2, decode.int)
    decode.success(#(owner, fence, expires))
  }
  let rows =
    sqlight.query(
      "SELECT owner_id, fence, expires_at_ms FROM writer_lease",
      connection,
      [],
      decoder,
    )
  assert sqlight.close(connection) == Ok(Nil)
  let assert Ok([held]) = rows as "exactly one original writer lease is durable"
  held
}

// Keep inspection connections short-lived and close before checking outcomes.
// These are existing generated DAL reads, never fixture-written reservations.
fn durable(paths: endpoint.Paths) {
  let assert Ok(store) = catalogue.open(paths.catalogue)
    as "the durable catalogue can be inspected independently"
  let record = catalogue.by_request_key(store, "identity-at-crash")
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
  assert list.length(page.sessions) == 1
  assert list.any(page.sessions, fn(row) { row.session_id == reserved.id })
  let assert Ok(protocol.SessionReply(row)) =
    daemon.request(control, protocol.GetSession(reserved.id), 5000)
    as "the reserved identity remains individually discoverable"

  // Slot-less rows project as Saved; the refusal distinguishes an unfinished
  // reservation from an initialized conversation that ordinary open may resume.
  assert row.status == protocol.Saved
  let assert Error(daemon.Refused("not_initialized", _)) =
    daemon.request(control, protocol.OpenSession(reserved.id), 5000)
    as "ordinary open cannot initialize a reserved conversation"
  assert_empty(control)
  assert_identity(reserved.path, reserved.id)
}

fn await_resident(control, id) {
  let assert poll.Answered(Nil) =
    poll.until(within: 15_000, every: 25, attempt: fn() {
      case daemon.request(control, protocol.GetSession(id), 2000) {
        Ok(protocol.SessionReply(protocol.Session(
          status: protocol.Resident(_),
          ..,
        ))) -> poll.Done(Nil)
        Ok(protocol.SessionReply(protocol.Session(
          status: protocol.Opening(_),
          ..,
        ))) -> poll.Retry
        other -> poll.Fail(string.inspect(other))
      }
    })
    as "explicit assembly reaches its resident incarnation"
}

fn await_saved(control, id) {
  let assert poll.Answered(Nil) =
    poll.until(within: 15_000, every: 25, attempt: fn() {
      case daemon.request(control, protocol.GetSession(id), 2000) {
        Ok(protocol.SessionReply(protocol.Session(status: protocol.Saved, ..))) ->
          poll.Done(Nil)
        Ok(protocol.SessionReply(protocol.Session(
          status: protocol.Opening(_),
          ..,
        )))
        | Ok(protocol.SessionReply(protocol.Session(
            status: protocol.Stopping(_),
            ..,
          ))) -> poll.Retry
        other -> poll.Fail(string.inspect(other))
      }
    })
    as "the failed or stopped assembly retires without accepting a resident writer"
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
