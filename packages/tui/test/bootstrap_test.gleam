import core/json
import filepath
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/endpoint
import simplifile
import tui/attachment
import tui/bootstrap
import tui/connection
import tui/daemon
import tui/daemon/protocol as control
import tui/daemon/selection
import tui/internal/ffi_bootstrap
import tui/session_channel
import tui/sessions
import weft
import weft/poll

pub fn workspace_names_are_stable_and_distinct_test() {
  let first = bootstrap.workspace_name("/work/alpha")
  assert first == bootstrap.workspace_name("/work/alpha")
  assert first != bootstrap.workspace_name("/other/alpha")
  assert string.starts_with(first, "alpha-")
  assert string.length(first) == string.length("alpha-") + 12
}

pub fn workspace_name_bounds_hostile_basename_test() {
  let name =
    bootstrap.workspace_name(
      "/work/THIS is a very long repository name with spaces and 🚀 symbols",
    )
  assert string.starts_with(name, "this-is-a-very-long-repository-")
  assert string.length(name) <= 32 + 1 + 12
}

pub fn session_id_matches_server_first_dot_rule_test() {
  assert bootstrap.session_id("/state/plain") == "plain"
  assert bootstrap.session_id("/state/plain.db") == "plain"
  assert bootstrap.session_id("/state/multi.part.db") == "multi"
  assert bootstrap.session_id("/state/.db") == ".db"
}

pub fn local_gateway_address_rejects_lookalikes_test() {
  assert bootstrap.local_gateway_address("ws://127.0.0.1:44123/v1/ws")
  assert !bootstrap.local_gateway_address("wss://127.0.0.1:44123/v1/ws")
  assert !bootstrap.local_gateway_address("ws://localhost:44123/v1/ws")
  assert !bootstrap.local_gateway_address("ws://127.0.0.1.evil:44123/v1/ws")
  assert !bootstrap.local_gateway_address("ws://127.0.0.1:0/v1/ws")
  assert !bootstrap.local_gateway_address("ws://127.0.0.1:65536/v1/ws")
  assert !bootstrap.local_gateway_address("ws://127.0.0.1:44123/v1/ws?q=1")
  assert !bootstrap.local_gateway_address("ws://user@127.0.0.1:44123/v1/ws")
}

pub fn launch_arguments_do_not_trust_workspace_configuration_test() {
  let arguments =
    bootstrap.launch_arguments(
      "/state/session.db",
      "/hostile/workspace",
      "44123",
      "/state/session.db.token",
      "/bin/sleep",
      "",
    )
  assert arguments
    == [
      "--session",
      "/state/session.db",
      "--workspace",
      "/hostile/workspace",
      "--bind",
      "127.0.0.1:44123",
      "--token-file",
      "/state/session.db.token",
    ]
  assert !list.contains(arguments, "--config")
}

pub fn the_default_catalogue_lives_in_the_state_root_test() {
  assert bootstrap.default_catalogue_path("/home/me/.loom")
    == "/home/me/.loom/loom.toml"
}

pub fn launch_arguments_forward_an_operator_named_config_test() {
  let arguments =
    bootstrap.launch_arguments(
      "/state/session.db",
      "/workspace",
      "44123",
      "/state/session.db.token",
      "/bin/sleep",
      "/home/operator/loom-baseten.toml",
    )
  assert list.contains(arguments, "--config")
  assert list.contains(arguments, "/home/operator/loom-baseten.toml")
  // The catalogue rides behind the fixed surface, never in place of it.
  let assert ["--session", "/state/session.db", "--workspace", "/workspace", ..] =
    arguments
}

pub fn implicit_path_discovery_ignores_relative_entries_test() {
  assert bootstrap.installed_path_candidates(
      "bin:/opt/loom/bin::../tools:/usr/local/bin",
    )
    == ["/opt/loom/bin/loomd", "/usr/local/bin/loomd"]
}

pub fn private_file_round_trip_is_bounded_test() {
  let root = test_root("private-file")
  let path = filepath.join(root, "record")
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = ffi_bootstrap.ensure_private_directory(root)
  let assert Ok(Nil) = ffi_bootstrap.atomic_write_private(path, "ready\n")
  let assert Ok(bytes) = ffi_bootstrap.read_private_bounded(path, 32)
  assert bit_array.to_string(bytes) == Ok("ready\n")
  assert ffi_bootstrap.read_regular_bounded(path, 3)
    == Error("file exceeds the bounded read limit")
  let _ = simplifile.delete(root)
}

pub fn private_directory_listing_is_bounded_test() {
  let root = test_root("bounded-directory")
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = ffi_bootstrap.ensure_private_directory(root)
  let assert Ok(Nil) =
    ffi_bootstrap.atomic_write_private(filepath.join(root, "first"), "one")
  let assert Ok(Nil) =
    ffi_bootstrap.atomic_write_private(filepath.join(root, "second"), "two")
  assert ffi_bootstrap.list_directory_bounded(root, 1)
    == Error("directory exceeds the entry limit")
  let assert Ok(entries) = ffi_bootstrap.list_directory_bounded(root, 2)
  assert list.length(entries) == 2
  let _ = simplifile.delete(root)
}

pub fn local_session_discovery_validates_launcher_records_test() {
  let root = test_root("session-discovery")
  let workspace = filepath.join(root, "workspace")
  let state = filepath.join(root, "state")
  let session_directory = filepath.join(state, "sessions")
  let session = filepath.join(session_directory, "review.db")
  let endpoint_directory = filepath.join(state, "endpoints")
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
  let assert Ok(Nil) = ffi_bootstrap.ensure_private_directory(state)
  let assert Ok(Nil) = ffi_bootstrap.ensure_private_directory(session_directory)
  let assert Ok(Nil) =
    ffi_bootstrap.ensure_private_directory(endpoint_directory)
  let assert Ok(Nil) = simplifile.write(session, "")
  let assert Ok(canonical_workspace) =
    ffi_bootstrap.canonical_directory(workspace)
  let assert Ok(canonical_state) = ffi_bootstrap.canonical_directory(state)
  let assert Ok(canonical_session) = ffi_bootstrap.canonical_path(session)
  let key = digest_prefix(canonical_session, 24)
  let endpoint = filepath.join(endpoint_directory, key <> ".json")
  let record =
    json.Object([
      #("version", json.Int(2)),
      #("gateway_protocol", json.Int(1)),
      #("status", json.String("ready")),
      #("workspace", json.String(canonical_workspace)),
      #("session_file", json.String(canonical_session)),
      #("session", json.String("review")),
      #("address", json.String("ws://127.0.0.1:44123/v1/ws")),
      #(
        "token_file",
        json.String(filepath.join(
          filepath.join(canonical_state, "tokens"),
          key <> ".token",
        )),
      ),
      #(
        "log_file",
        json.String(filepath.join(
          filepath.join(canonical_state, "logs"),
          key <> ".log",
        )),
      ),
      #("server_pid", json.Int(0)),
      #("server_birth", json.String("")),
      #("started_at_ms", json.Int(ffi_bootstrap.system_time_ms())),
    ])
    |> json.to_string
  let assert Ok(Nil) = ffi_bootstrap.atomic_write_private(endpoint, record)
  let assert Ok(Nil) =
    ffi_bootstrap.atomic_write_private(
      filepath.join(endpoint_directory, "malformed.json"),
      "not json",
    )

  // A second, otherwise identical record proves the exclusion below is the
  // status alone: it is listed while ready and vanishes once it says
  // starting, as a record a failed spawn abandoned would.
  let pending = filepath.join(session_directory, "pending.db")
  let assert Ok(Nil) = simplifile.write(pending, "")
  let assert Ok(canonical_pending) = ffi_bootstrap.canonical_path(pending)
  let pending_key = digest_prefix(canonical_pending, 24)
  let pending_endpoint =
    filepath.join(endpoint_directory, pending_key <> ".json")
  let pending_record =
    record
    |> string.replace(canonical_session, canonical_pending)
    |> string.replace("\"review\"", "\"pending\"")
    |> string.replace(key, pending_key)
  let options = bootstrap.Options(workspace, session, "/bin/loomd", state, "")
  let assert Ok(Nil) =
    ffi_bootstrap.atomic_write_private(pending_endpoint, pending_record)
  let assert Ok([_, _]) = bootstrap.discover_sessions(options)
    as "a ready sibling record is listed"
  let assert Ok(Nil) =
    ffi_bootstrap.atomic_write_private(
      pending_endpoint,
      string.replace(pending_record, "\"ready\"", "\"starting\""),
    )
  let assert Ok([choice]) = bootstrap.discover_sessions(options)
  assert choice
    == bootstrap.SessionChoice(
      session: "review",
      workspace: canonical_workspace,
      session_file: canonical_session,
    )
  assert bootstrap.session_options(options, choice)
    == bootstrap.Options(
      workspace: canonical_workspace,
      session_file: canonical_session,
      server: "/bin/loomd",
      state_directory: state,
      config: "",
    )
  let _ = simplifile.delete(root)
}

pub fn launch_lock_is_single_winner_test() {
  let root = test_root("launch-lock")
  let path = filepath.join(root, "session.lock")
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = ffi_bootstrap.ensure_private_directory(root)
  let assert Ok(first) = ffi_bootstrap.try_launch_lock(path)
  assert ffi_bootstrap.try_launch_lock(path) == Error("busy")
  ffi_bootstrap.release_launch_lock(first)
  let assert Ok(second) = ffi_bootstrap.try_launch_lock(path)
  ffi_bootstrap.release_launch_lock(second)
  let _ = simplifile.delete(root)
}

pub fn launch_lock_is_released_when_its_owner_dies_test() {
  let root = test_root("launch-lock-owner-death")
  let path = filepath.join(root, "session.lock")
  let ready = process.new_subject()
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = ffi_bootstrap.ensure_private_directory(root)
  let holder =
    process.spawn_unlinked(fn() {
      // Only the resource owner may receive on its parking inbox. A parent
      // inbox would crash this worker and release the lock before the kill.
      let parked = process.new_subject()
      let assert Ok(lock) = ffi_bootstrap.try_launch_lock(path)
      process.send(ready, Nil)
      let _ = process.receive(parked, 5000)
      ffi_bootstrap.release_launch_lock(lock)
    })
  let assert Ok(Nil) = process.receive(ready, 1000)
  assert ffi_bootstrap.try_launch_lock(path) == Error("busy")
  process.kill(holder)
  let assert Ok(recovered) = acquire_lock_eventually(path, 20)
  ffi_bootstrap.release_launch_lock(recovered)
  let _ = simplifile.delete(root)
}

pub fn launch_lock_keeps_one_inode_across_reacquisition_test() {
  let root = test_root("launch-lock-inode")
  let path = filepath.join(root, "session.lock")
  let anchor = filepath.join(root, "anchor.lock")
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = ffi_bootstrap.ensure_private_directory(root)
  let assert Ok(first) = ffi_bootstrap.try_launch_lock(path)
  let assert Ok(original) = simplifile.file_info(path)

  // Keep the original inode allocated even if a faulty unlock unlinks the
  // pathname. Otherwise inode reuse could hide that the lock was replaced.
  let assert Ok(Nil) = simplifile.create_link(to: path, from: anchor)
  ffi_bootstrap.release_launch_lock(first)
  let assert Ok(second) = acquire_lock_eventually(path, 20)
  let assert Ok(reacquired) = simplifile.file_info(path)
  assert reacquired.inode == original.inode
  assert ffi_bootstrap.try_launch_lock(anchor) == Error("busy")

  // Acquiring through the retained alias must exclude the public pathname
  // too, after another release and acquisition in the opposite direction.
  ffi_bootstrap.release_launch_lock(second)
  let assert Ok(third) = acquire_lock_eventually(anchor, 20)
  assert ffi_bootstrap.try_launch_lock(path) == Error("busy")
  let assert Ok(retained) = simplifile.file_info(path)
  assert retained.inode == original.inode
  ffi_bootstrap.release_launch_lock(third)
  let _ = simplifile.delete(root)
}

pub fn process_identity_distinguishes_one_process_lifetime_test() {
  let root = test_root("process-identity")
  let log = filepath.join(root, "sleep.log")
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = ffi_bootstrap.ensure_private_directory(root)
  let assert Ok(started) =
    ffi_bootstrap.spawn_server("/bin/sleep", ["30"], root, log)
  let process_port = started.0
  let pid = started.1
  let assert Ok(ffi_bootstrap.ProcessPresent(first)) =
    ffi_bootstrap.process_identity(pid)
  let assert Ok(Nil) = ffi_bootstrap.release_server_process(process_port)
  assert ffi_bootstrap.process_identity(pid)
    == Ok(ffi_bootstrap.ProcessPresent(first))
  ffi_bootstrap.terminate_process_group(pid)
  ffi_bootstrap.close_server_process(process_port)
  assert_process_stops(pid, 20)
  let _ = simplifile.delete(root)
}

pub fn paused_server_dies_with_launcher_before_release_test() {
  let root = test_root("paused-server-owner-death")
  let marker = filepath.join(root, "started")
  let log = filepath.join(root, "server.log")
  let ready = process.new_subject()
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = ffi_bootstrap.ensure_private_directory(root)

  let launcher =
    process.spawn_unlinked(fn() {
      // The launcher must remain alive until the test kills it, so its
      // parking inbox belongs to this process rather than the parent.
      let parked = process.new_subject()
      let assert Ok(started) =
        ffi_bootstrap.spawn_server(
          "/bin/sh",
          ["-c", "touch \"$1\"", "loomd-test", marker],
          root,
          log,
        )
      process.send(ready, started.1)
      let _ = process.receive(parked, 5000)
      ffi_bootstrap.close_server_process(started.0)
    })

  let assert Ok(pid) = process.receive(ready, 1000)
  assert !ffi_bootstrap.path_exists(marker)
  process.kill(launcher)
  assert_process_stops(pid, 20)
  process.sleep(50)
  assert !ffi_bootstrap.path_exists(marker)
  let _ = simplifile.delete(root)
}

pub fn bootstrap_real_server_lifecycle_test() {
  case ffi_bootstrap.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
    Error(Nil) -> Nil
    Ok(server) -> run_real_server_lifecycle(server)
  }
}

fn run_real_server_lifecycle(server: String) -> Nil {
  let root = test_root("real-server")
  let workspace = filepath.join(root, "workspace")
  let state = filepath.join(root, "state")
  let other_workspace = filepath.join(root, "other-workspace")
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
  let assert Ok(Nil) = simplifile.create_directory_all(other_workspace)
  let assert Ok(workspace) = ffi_bootstrap.canonical_directory(workspace)
    as "wire workspace paths are absolute, not relative to the daemon cwd"
  let assert Ok(other_workspace) =
    ffi_bootstrap.canonical_directory(other_workspace)
  let configuration = filepath.join(root, "fixture.toml")
  let assert Ok(Nil) =
    simplifile.write(
      configuration,
      "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"UNUSED\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n[roles]\nmain = [\"fixture\"]\n[memory]\ndistill = \"off\"\n",
    )
    as "a deterministic launch never uses environment-backed maintenance"
  let assert Ok(configuration) = ffi_bootstrap.absolute_path(configuration)
  let options = bootstrap.Options(workspace, "", server, state, configuration)
  let terminal = process.self()
  let launched =
    weft.new(
      list.map([1, 2], fn(_) {
        fn() { bootstrap.resolve_daemon(options, terminal, 40_000) }
      }),
    )
    |> weft.deadline(45_000)
    |> weft.start
  let assert [first, second] = weft.values(launched)
    as "both bounded concurrent launchers authenticate the same daemon"
  assert first.record == second.record
  assert daemon.hello(first.control).epoch == daemon.hello(second.control).epoch
  let assert Ok(control.SessionsReply(empty)) =
    daemon.request(first.control, control.ListSessions("", None), 5000)
    as "bootstrap restores only catalogue metadata"
  assert empty.sessions == []
  let assert Ok(address) = endpoint.address(first.record)
  let assert Ok(token) = simplifile.read(first.paths.token)
  assert first.paths.token == filepath.join(first.paths.root, "owner.token")
  let assert Ok(host) =
    selection.host(first.control, address, string.trim(token))
  let assert Ok(target) =
    selection.create(host, "bootstrap-fixture", workspace, configuration)
    as "an explicit create reserves and opens a canonical session"
  let switched =
    wait_for_attachment(attachment.start(fn() { Ok(target) }, 20_000), 20_000)
  let assert attachment.Adopted(channel, cut, _, _, _, _) = switched
    as "the terminal validates the bounded capture before actual adoption"
  assert cut.attachment.expected == target.expected
  session_channel.close(channel)

  // A cancelled attempt must take its unadopted socket down. Two paths
  // cover it: a task that has returned its socket but whose outcome nobody
  // pulled is closed by the cancel's drain, and a task still running has
  // its socket killed through the link. Both attempts publish the socket's
  // pid on the side so the proof never pulls the outcome itself.
  let told = process.new_subject()
  let choice = bootstrap.SessionChoice(target.expected.session, workspace, "")
  let returned =
    sessions.start_with(
      choice.session,
      fn(frames) {
        let opened = open_fixture_socket(choice, options, target, frames)
        process.send(told, socket_owner(opened))
        opened
      },
      within: 90_000,
    )
  let assert Ok(Ok(returned_pid)) = process.receive(told, 40_000)
    as "a second switch should connect"
  assert process.is_alive(returned_pid)
  sessions.cancel(returned)
  assert_process_exits(returned_pid, 100)
  let running =
    sessions.start_with(
      choice.session,
      fn(frames) {
        let opened = open_fixture_socket(choice, options, target, frames)
        process.send(told, socket_owner(opened))
        process.sleep_forever()
        opened
      },
      within: 90_000,
    )
  let assert Ok(Ok(running_pid)) = process.receive(told, 40_000)
    as "a third switch should connect"
  assert process.is_alive(running_pid)
  sessions.cancel(running)
  assert_process_exits(running_pid, 100)
  daemon.close(second.control)

  // Workspace selection does not select a daemon. Detaching both terminals
  // leaves the same native lifetime available to another workspace.
  daemon.close(first.control)
  let assert Ok(third) =
    bootstrap.resolve_daemon(
      bootstrap.Options(..options, workspace: other_workspace),
      terminal,
      40_000,
    )
    as "another workspace reuses the same daemon after terminal detach"
  assert third.record == first.record
  assert simplifile.read(third.paths.token) == Ok(token)
  let pid = first.record.fence.pid
  let assert Ok(ffi_bootstrap.ProcessPresent(identity)) =
    ffi_bootstrap.process_identity(pid)
  assert identity == first.record.fence.birth
  assert ffi_bootstrap.process_identity(pid)
    == Ok(ffi_bootstrap.ProcessPresent(identity))
  daemon.close(third.control)
  ffi_bootstrap.terminate_process_group(pid)
  assert_process_stops(pid, 200)
  let assert Ok(restarted) = bootstrap.resolve_daemon(options, terminal, 40_000)
    as "an observed departed native owner permits a new daemon epoch"
  assert daemon.hello(restarted.control).epoch
    != daemon.hello(first.control).epoch
  assert simplifile.read(restarted.paths.token) == Ok(token)
  let assert Ok(control.SessionsReply(restored)) =
    daemon.request(restarted.control, control.ListSessions("", None), 5000)
    as "restart restores the saved catalogue without executing a session"
  let assert [saved] = restored.sessions
    as "the single explicitly created session survives daemon restart"
  assert saved.session_id == target.expected.session
  assert saved.status == control.Saved
  let assert Ok(restarted_address) = endpoint.address(restarted.record)
  let assert Ok(restarted_host) =
    selection.host(restarted.control, restarted_address, string.trim(token))
  let reopened =
    wait_for_attachment(
      attachment.start(
        fn() { selection.open(restarted_host, saved.session_id) },
        20_000,
      ),
      20_000,
    )
  let assert attachment.Adopted(reopened_channel, reopened_cut, _, _, _, _) =
    reopened
    as "only an explicit reopen obtains a new incarnation and credited cut"
  assert reopened_cut.attachment.expected.session == saved.session_id
  assert reopened_cut.attachment.expected.epoch != target.expected.epoch
  session_channel.close(reopened_channel)
  daemon.close(restarted.control)
  let restarted_pid = restarted.record.fence.pid
  assert ffi_bootstrap.process_identity(restarted_pid)
    == Ok(ffi_bootstrap.ProcessPresent(restarted.record.fence.birth))
  ffi_bootstrap.terminate_process_group(restarted_pid)
  assert_process_stops(restarted_pid, 200)
  let _ = simplifile.delete(root)
  Nil
}

// Only the existing generic cancellation harness remains here. Its callback
// opens the already-authorized v2 target; no legacy discovery or protocol runs.
fn open_fixture_socket(choice, options, target: attachment.Target, frames) {
  use socket <- result.map(connection.connect(
    target.address,
    target.token,
    frames,
  ))
  sessions.Opened(
    choice,
    options,
    bootstrap.Target(target.address, target.expected.session, target.token),
    socket,
  )
}

fn wait_for_attachment(status, within) {
  case
    poll.fold_until(
      clock: poll.monotonic(),
      within: within,
      every: poll.Fixed(5),
      from: status,
      attempt: fn(status) {
        case attachment.poll(status) {
          #(_, Some(outcome)) -> poll.Settled(outcome)
          #(next, None) -> poll.Pending(next)
        }
      },
    )
  {
    poll.Answer(outcome) -> outcome
    poll.RanOut(pending) -> {
      attachment.cancel(pending)
      panic as "the bounded credited attachment did not settle"
    }
    poll.Failure(reason) -> panic as string.inspect(reason)
  }
}

fn acquire_lock_eventually(
  path: String,
  attempts: Int,
) -> Result(ffi_bootstrap.LaunchLock, String) {
  case
    poll.until(within: attempts * 25, every: 25, attempt: fn() {
      case ffi_bootstrap.try_launch_lock(path) {
        Ok(lock) -> poll.Done(lock)
        Error("busy") -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })
  {
    poll.Answered(lock) -> Ok(lock)
    poll.Failed(reason) -> Error(reason)
    poll.Expired -> Error("busy")
  }
}

fn assert_process_stops(pid: Int, attempts: Int) -> Nil {
  let observed =
    poll.until(within: attempts * 50, every: 50, attempt: fn() {
      case ffi_bootstrap.process_identity(pid) {
        Ok(ffi_bootstrap.ProcessAbsent) -> poll.Done(Nil)
        Ok(ffi_bootstrap.ProcessPresent(_)) | Error(_) -> poll.Retry
      }
    })
  assert observed == poll.Answered(Nil)
    as "the native process must be observed absent before replacement"
}

fn socket_owner(
  opened: Result(sessions.Opened, String),
) -> Result(process.Pid, Nil) {
  case opened {
    Ok(sessions.Opened(socket:, ..)) -> connection.owner(socket)
    Error(_reason) -> Error(Nil)
  }
}

fn assert_process_exits(pid: process.Pid, attempts: Int) -> Nil {
  let observed =
    poll.until(within: attempts * 10, every: 10, attempt: fn() {
      case process.is_alive(pid) {
        False -> poll.Done(Nil)
        True -> poll.Retry
      }
    })
  assert observed == poll.Answered(Nil)
    as "the abandoned socket actor should have exited"
}

fn test_root(name: String) -> String {
  "build/bootstrap-test-"
  <> name
  <> "-"
  <> string.inspect(ffi_bootstrap.system_time_ms())
}

fn digest_prefix(value: String, length: Int) -> String {
  ffi_bootstrap.sha256(<<value:utf8>>)
  |> bit_array.base16_encode
  |> string.lowercase
  |> string.slice(at_index: 0, length:)
}
