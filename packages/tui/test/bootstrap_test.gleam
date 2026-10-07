import etui/backend
import etui/widgets/textarea as text_area
import filepath
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap as host_bootstrap
import host/build_identity
import host/endpoint
import session_view/model as session_model
import session_view/session_channel
import simplifile
import tui
import tui/attachment
import tui/bootstrap
import tui/connection
import tui/daemon
import tui/daemon/bootstrap as daemon_bootstrap
import tui/daemon/protocol as control
import tui/daemon/selection
import tui/inbound
import tui/interaction
import tui/job
import tui/job_runner
import tui/model as tui_model
import tui/runtime
import tui/session_control
import tui/session_selector
import tui/terminal_lane
import tui/view_set
import tui/workspace
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

pub fn control_address_accepts_the_bracketed_ipv6_loopback_test() {
  // `uri.parse` keeps the brackets, so the bracketed literal is what a
  // `--bind [::1]:0` daemon's own published address parses back into. An
  // unbracketed arm alone refuses that daemon as if it were remote.
  assert daemon.valid_address("ws://[::1]:1234/v2/control") == Ok(Nil)
  assert daemon.valid_address("ws://127.0.0.1:1234/v2/control") == Ok(Nil)
  assert daemon.valid_address("wss://control.example:443/v2/control") == Ok(Nil)
  assert daemon.valid_address("ws://[::2]:1234/v2/control")
    == Error(daemon.Invalid("remote control requires TLS"))
  assert daemon.valid_address("ws://example.com:1234/v2/control")
    == Error(daemon.Invalid("remote control requires TLS"))
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

pub fn session_configuration_resolves_trusted_default_and_explicit_paths_test() {
  let root = test_root("creation-config")
  let assert Ok(Nil) = host_bootstrap.ensure_private_directory(root)
    as "fixture state root exists"
  let workspace = filepath.join(root, "workspace")
  let assert Ok(Nil) = host_bootstrap.ensure_private_directory(workspace)
    as "fixture workspace exists"
  assert simplifile.write(filepath.join(workspace, "loom.toml"), "untrusted")
    == Ok(Nil)
  let options = bootstrap.Options(workspace, "", "", root, "", "")
  assert bootstrap.session_configuration(options) == Ok("")

  let path = bootstrap.default_catalogue_path(root)
  assert !string.starts_with(path, "/")
  assert simplifile.write(path, "trusted") == Ok(Nil)
  let assert Ok(canonical) = host_bootstrap.canonical_path(path)
    as "trusted default has a canonical path"
  assert bootstrap.session_configuration(options) == Ok(canonical)
  assert bootstrap.session_configuration(
      bootstrap.Options(..options, config: path),
    )
    == Ok(canonical)

  // Linux realpath accepts a missing final component when its parent exists.
  // Creation must refuse that path before it retains an idempotency key.
  let missing = filepath.join(root, "missing.toml")
  assert bootstrap.session_configuration(
      bootstrap.Options(..options, config: missing),
    )
    == Error("resolve config " <> missing <> ": file does not exist")

  // `--config ~/.loom` is the ordinary typo for `~/.loom/loom.toml`, and a
  // directory exists, canonicalises, and survives to creation unless the
  // requirement is a regular file rather than an entry of some kind.
  let directory = filepath.join(root, "catalogue.d")
  let assert Ok(Nil) = host_bootstrap.ensure_private_directory(directory)
    as "the fixture directory exists"
  assert bootstrap.session_configuration(
      bootstrap.Options(..options, config: directory),
    )
    == Error("resolve config " <> directory <> ": not a regular file")

  // A dangling symbolic link is an entry by `link_info` and nothing at all by
  // `file_info`. It is the second path the old existence check let through.
  let dangling = filepath.join(root, "dangling.toml")
  assert simplifile.create_symlink(filepath.join(root, "absent.toml"), dangling)
    == Ok(Nil)
  assert bootstrap.session_configuration(
      bootstrap.Options(..options, config: dangling),
    )
    == Error("resolve config " <> dangling <> ": file does not exist")
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
  let assert Ok(Nil) = host_bootstrap.ensure_private_directory(root)
  let assert Ok(Nil) = host_bootstrap.atomic_write_private(path, "ready\n")
  let assert Ok(bytes) = host_bootstrap.read_private_bounded(path, 32)
  assert bit_array.to_string(bytes) == Ok("ready\n")
  assert host_bootstrap.read_bounded(path, 3)
    == Error("file exceeds the bounded read limit")
  let _ = simplifile.delete(root)
}

pub fn private_directory_listing_is_bounded_test() {
  let root = test_root("bounded-directory")
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = host_bootstrap.ensure_private_directory(root)
  let assert Ok(Nil) =
    host_bootstrap.atomic_write_private(filepath.join(root, "first"), "one")
  let assert Ok(Nil) =
    host_bootstrap.atomic_write_private(filepath.join(root, "second"), "two")
  assert host_bootstrap.list_directory_bounded(root, 1)
    == Error("directory exceeds the entry limit")
  let assert Ok(entries) = host_bootstrap.list_directory_bounded(root, 2)
  assert list.length(entries) == 2
  let _ = simplifile.delete(root)
}

pub fn launch_lock_is_single_winner_test() {
  let root = test_root("launch-lock")
  let path = filepath.join(root, "session.lock")
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = host_bootstrap.ensure_private_directory(root)
  let assert Ok(first) = host_bootstrap.try_launch_lock(path)
  assert host_bootstrap.try_launch_lock(path) == Error("busy")
  host_bootstrap.release_launch_lock(first)

  // Closing the port precedes the external holder's exit, so reacquisition
  // waits for the kernel lock to be released within the existing bound.
  let assert Ok(second) = acquire_lock_eventually(path, 20)
  host_bootstrap.release_launch_lock(second)
  let _ = simplifile.delete(root)
}

pub fn launch_lock_is_released_when_its_owner_dies_test() {
  let root = test_root("launch-lock-owner-death")
  let path = filepath.join(root, "session.lock")
  let ready = process.new_subject()
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = host_bootstrap.ensure_private_directory(root)
  let holder =
    process.spawn_unlinked(fn() {
      // Only the resource owner may receive on its parking inbox. A parent
      // inbox would crash this worker and release the lock before the kill.
      let parked = process.new_subject()
      let assert Ok(lock) = host_bootstrap.try_launch_lock(path)
      process.send(ready, Nil)
      let _ = process.receive(parked, 5000)
      host_bootstrap.release_launch_lock(lock)
    })
  let assert Ok(Nil) = process.receive(ready, 1000)
  assert host_bootstrap.try_launch_lock(path) == Error("busy")
  process.kill(holder)
  let assert Ok(recovered) = acquire_lock_eventually(path, 20)
  host_bootstrap.release_launch_lock(recovered)
  let _ = simplifile.delete(root)
}

pub fn launch_lock_keeps_one_inode_across_reacquisition_test() {
  let root = test_root("launch-lock-inode")
  let path = filepath.join(root, "session.lock")
  let anchor = filepath.join(root, "anchor.lock")
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = host_bootstrap.ensure_private_directory(root)
  let assert Ok(first) = host_bootstrap.try_launch_lock(path)
  let assert Ok(original) = simplifile.file_info(path)

  // Keep the original inode allocated even if a faulty unlock unlinks the
  // pathname. Otherwise inode reuse could hide that the lock was replaced.
  let assert Ok(Nil) = simplifile.create_link(to: path, from: anchor)
  host_bootstrap.release_launch_lock(first)
  let assert Ok(second) = acquire_lock_eventually(path, 20)
  let assert Ok(reacquired) = simplifile.file_info(path)
  assert reacquired.inode == original.inode
  assert host_bootstrap.try_launch_lock(anchor) == Error("busy")

  // Acquiring through the retained alias must exclude the public pathname
  // too, after another release and acquisition in the opposite direction.
  host_bootstrap.release_launch_lock(second)
  let assert Ok(third) = acquire_lock_eventually(anchor, 20)
  assert host_bootstrap.try_launch_lock(path) == Error("busy")
  let assert Ok(retained) = simplifile.file_info(path)
  assert retained.inode == original.inode
  host_bootstrap.release_launch_lock(third)
  let _ = simplifile.delete(root)
}

pub fn process_identity_distinguishes_one_process_lifetime_test() {
  let root = test_root("process-identity")
  let log = filepath.join(root, "sleep.log")
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = host_bootstrap.ensure_private_directory(root)
  let assert Ok(started) =
    host_bootstrap.spawn_server("/bin/sleep", ["30"], root, log)
  let process_port = started.0
  let pid = started.1
  let assert Ok(host_bootstrap.ProcessPresent(first)) =
    host_bootstrap.process_identity(pid)
  let assert Ok(Nil) = host_bootstrap.release_server_process(process_port)
  assert host_bootstrap.process_identity(pid)
    == Ok(host_bootstrap.ProcessPresent(first))
  host_bootstrap.terminate_process_group(pid)
  host_bootstrap.close_server_process(process_port)
  assert_process_stops(pid, 20)
  let _ = simplifile.delete(root)
}

// A wrapper leads its own process group from the moment spawn_server returns.
// The port learns a child's pid as soon as it is forked, but the child calls
// setsid(2) afterwards, on its own schedule; a group signal sent inside that
// window reaches nobody, and the wrapper outlives its cleanup. Under load the
// window was wide enough to fail the lifetime test above. Twenty spawns make an
// early return near-certain to be caught, since an unsettled child was seen on
// about one spawn in five even on an idle host. Procfs names the group
// directly, so the check needs it; Darwin still runs the lifetime tests.
pub fn spawned_wrapper_leads_its_own_process_group_test() {
  case host_bootstrap.path_exists("/proc/self/stat") {
    False -> Nil
    True -> {
      let root = test_root("process-group")
      let log = filepath.join(root, "sleep.log")
      let _ = simplifile.delete(root)
      let assert Ok(Nil) = host_bootstrap.ensure_private_directory(root)
      int.range(from: 0, to: 20, with: Nil, run: fn(_, _) {
        let assert Ok(#(process_port, pid)) =
          host_bootstrap.spawn_server("/bin/sleep", ["30"], root, log)
        assert process_group(pid) == Ok(pid)
          as "a spawned wrapper must already lead its own process group"
        host_bootstrap.terminate_process_group(pid)
        host_bootstrap.close_server_process(process_port)
        assert_process_stops(pid, 20)
      })
      let _ = simplifile.delete(root)
      Nil
    }
  }
}

pub fn paused_server_dies_with_launcher_before_release_test() {
  let root = test_root("paused-server-owner-death")
  let marker = filepath.join(root, "started")
  let log = filepath.join(root, "server.log")
  let ready = process.new_subject()
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = host_bootstrap.ensure_private_directory(root)

  let launcher =
    process.spawn_unlinked(fn() {
      // The launcher must remain alive until the test kills it, so its
      // parking inbox belongs to this process rather than the parent.
      let parked = process.new_subject()
      let assert Ok(started) =
        host_bootstrap.spawn_server(
          "/bin/sh",
          ["-c", "touch \"$1\"", "loomd-test", marker],
          root,
          log,
        )
      process.send(ready, started.1)
      let _ = process.receive(parked, 5000)
      host_bootstrap.close_server_process(started.0)
    })

  let assert Ok(pid) = process.receive(ready, 1000)
  assert !host_bootstrap.path_exists(marker)
  process.kill(launcher)
  assert_process_stops(pid, 20)
  process.sleep(50)
  assert !host_bootstrap.path_exists(marker)
  let _ = simplifile.delete(root)
}

pub fn bootstrap_real_server_lifecycle_test() {
  case host_bootstrap.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
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
  let assert Ok(workspace) = host_bootstrap.canonical_directory(workspace)
    as "wire workspace paths are absolute, not relative to the daemon cwd"
  let assert Ok(other_workspace) =
    host_bootstrap.canonical_directory(other_workspace)
  let assert Ok(Nil) = host_bootstrap.ensure_private_directory(state)
    as "the trusted default belongs to the private state root"
  let configuration = bootstrap.default_catalogue_path(state)
  let assert Ok(Nil) =
    simplifile.write(
      configuration,
      "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"UNUSED\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n[roles]\nmain = [\"fixture\"]\n[memory]\ndistill = \"off\"\n",
    )
    as "a deterministic launch never uses environment-backed maintenance"
  let assert Ok(configuration) = host_bootstrap.absolute_path(configuration)
  let options = bootstrap.Options(workspace, "", server, state, "", "")
  assert bootstrap.session_configuration(options) == Ok(configuration)
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
  let model =
    tui.new_model(connection.new_inbox(), workspace.discover_from(workspace))
  let model =
    tui_model.Model(
      shared: session_model.Shared(
        ..model.shared,
        // Local startup clears the demonstration identity before selection.
        // This draft is unassigned until the first session is adopted.
        session: "",
      ),
      view: model.view
        |> view_set.local_options(Some(options))
        |> view_set.overlay(
          tui_model.DaemonSelector(session_selector.new(empty, "")),
        )
        |> view_set.input(text_area.state_from_string("retained draft")),
    )
    |> runtime.adopt_control(host)

  // A local path failure sends no creation request and retains no durable key.
  // Correcting the option must permit the same selector action immediately.
  let invalid =
    tui_model.Model(
      ..model,
      view: view_set.local_options(
        model.view,
        Some(
          bootstrap.Options(
            ..options,
            config: filepath.join(root, "absent/loom.toml"),
          ),
        ),
      ),
    )
  let refused = configured(tui.update(backend.KeyPress("n"), invalid))
  assert refused.view.creation_key == None
  assert text_area.value(refused.view.input) == "retained draft"
  assert !attachment.busy(refused.view.candidate)
  let creating =
    configured(tui.update(
      backend.KeyPress("n"),
      tui_model.Model(
        ..refused,
        view: view_set.local_options(refused.view, Some(options)),
      ),
    ))
  let switched = wait_for_attachment(creating, 20_000)
  let assert attachment.Adopted(channel, cut, _, _, _, selected_name, _) =
    switched
    as "the terminal validates the bounded capture before actual adoption"
  let adopted =
    interaction.candidate_outcome(creating, attachment.idle(), Some(switched))
  assert adopted.shared.current_model == "fixture"
  assert text_area.value(adopted.view.input) == "retained draft"
  assert adopted.view.creation_key == None
  let assert Some(server_build) = daemon.hello(first.control).build
    as "the built daemon launcher exports its own artifact identity"
  assert !build_identity.matches(
    build_identity.current(),
    build_identity.Identity(server_build.version, server_build.commit),
  )
    as "the e2e client identity differs from the built daemon"
  assert_build_notice(adopted)
  let assert Some(#(adopted_cut, adopted_view)) = adopted.shared.captured
    as "adoption retained its coherent projection"
  let refreshed =
    inbound.apply_channel_update(
      adopted,
      session_channel.Captured(
        adopted_cut,
        adopted_view,
        session_channel.Refreshed,
      ),
    )
  assert_build_notice(refreshed)
  let assert Ok(target) = selection.open(host, cut.attachment.expected.session)
    as "the created session is already resident"
  assert cut.attachment.expected == target.expected
  assert selected_name == target.session_name
  assert adopted.shared.session_label
    == Some(#(target.expected.session, target.session_name))
  close_channel(channel)

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
  let assert Ok(host_bootstrap.ProcessPresent(identity)) =
    host_bootstrap.process_identity(pid)
  assert identity == first.record.fence.birth
  assert host_bootstrap.process_identity(pid)
    == Ok(host_bootstrap.ProcessPresent(identity))
  let assert Ok(reused) = bootstrap.reconnect_daemon(options, terminal, 5000)
    as "a healthy native daemon can be reused after a transient socket loss"
  assert reused.record == first.record
  daemon.close(reused.control)
  daemon.close(third.control)
  host_bootstrap.terminate_process_group(pid)

  // Drive the shipped loss transition without first waiting for VM exit.
  // The bounded observation must bridge that interval and publish one new
  // host. The actual successful event then starts the normal adoption path.
  // The flush performs the relaunch the loss queued, as the loop would
  // after the step that saw the loss.
  let reconnecting =
    inbound.apply_channel_update(
      adopted,
      session_channel.Failed("daemon exited"),
    )
    |> runtime.flush
  let assert tui_model.ReconnectAttempting(_) = reconnecting.view.reconnect
    as "the attached local terminal owns one reconnect attempt"
  let assert Ok(reconnected) =
    process.selector_receive(
      job_runner.selector(reconnecting.view.running),
      40_000,
    )
    as "the bounded relaunch produces an outcome"
  let assert job.ReconnectArrived(
    reply: weft.PulledOutcome(weft.Completed(value: restarted_host, ..)),
    ..,
  ) = reconnected
    as "native retirement permits a replacement daemon"
  let assert Ok(Some(record)) = endpoint.load(first.paths)
    as "the replacement publishes its own native fence and epoch"
  let restarted =
    daemon_bootstrap.Connected(
      selection.control(restarted_host),
      first.paths,
      record,
    )
  assert_process_stops(pid, 200)
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
  let reattaching =
    runtime.hold(reconnecting, reconnected)
    |> session_control.drain_reconnect
    |> runtime.flush
  let reopened = wait_for_attachment(reattaching, 20_000)
  let assert attachment.Adopted(
    reopened_channel,
    reopened_cut,
    _,
    _,
    _,
    reopened_name,
    _,
  ) = reopened
    as "only an explicit reopen obtains a new incarnation and credited cut"
  assert reopened_cut.attachment.expected.session == saved.session_id
  assert reopened_name == saved.name
  assert reopened_cut.attachment.expected.epoch != target.expected.epoch
  let readopted =
    interaction.candidate_outcome(
      reattaching,
      attachment.idle(),
      Some(reopened),
    )
  assert readopted.shared.session == adopted.shared.session
  assert text_area.value(readopted.view.input) == "retained draft"
  assert_build_notice(readopted)
  close_channel(reopened_channel)

  // A control request that times out retires its owner, and closing it is the
  // same retirement by another route. Before `selection.reconnect` existed the
  // terminal had no way back: `daemon_host` was written only during startup,
  // so one slow registry read left every later `/sessions`, open and create
  // failing for the process's lifetime. The route survives the owner, so it
  // mints another one, and the daemon itself is untouched by either.
  daemon.close(restarted.control)
  let assert Error(_) =
    daemon.request(restarted.control, control.ListSessions("", None), 5000)
    as "the retired owner answers nothing"
  let assert Ok(rebuilt) = selection.reconnect(restarted_host, terminal)
    as "the surviving route mints a second control owner"
  assert daemon.owner(selection.control(rebuilt))
    != daemon.owner(restarted.control)
  let assert Ok(control.SessionsReply(after_reconnect)) =
    daemon.request(
      selection.control(rebuilt),
      control.ListSessions("", None),
      5000,
    )
    as "metadata listing works again on the rebuilt control"
  assert list.length(after_reconnect.sessions) == 1
  daemon.close(selection.control(rebuilt))

  let restarted_pid = restarted.record.fence.pid
  assert host_bootstrap.process_identity(restarted_pid)
    == Ok(host_bootstrap.ProcessPresent(restarted.record.fence.birth))
  host_bootstrap.terminate_process_group(restarted_pid)
  assert_process_stops(restarted_pid, 200)
  let _ = simplifile.delete(root)
  Nil
}

fn close_channel(channel: terminal_lane.Lane) -> Nil {
  let #(_, outputs) =
    session_channel.take_outputs(session_channel.close(channel))
  list.each(outputs, terminal_lane.perform)
}

// Drives a model's attachment attempt outside the terminal loop until it
// settles: before each poll the runtime receives the job's messages and the
// attempt's frames, and after it the flush performs what the poll decided,
// which includes what the candidate's channel queued, in the order the
// runtime would after a step.
// A creation resolves its configuration in a job before it retains a key
// (ADR-013, phase 2 S6), so the key press starts that job and the tick that
// takes its reply makes the creation's checks and starts the attachment.
// This ticks until it has.
fn configured(model: tui_model.Model) -> tui_model.Model {
  let assert poll.Answer(configured) =
    poll.fold_until(
      clock: poll.monotonic(),
      within: 5000,
      every: poll.Fixed(5),
      from: model,
      attempt: fn(current: tui_model.Model) {
        case current.view.configuring {
          None -> poll.Settled(current)
          Some(_) -> poll.Pending(tui.update(backend.Tick, current))
        }
      },
    )
    as "the configuration job answers"
  configured
}

fn wait_for_attachment(model: tui_model.Model, within: Int) {
  case
    poll.fold_until(
      clock: poll.monotonic(),
      within: within,
      every: poll.Fixed(5),
      from: model,
      attempt: fn(model) {
        let model = runtime.receive(model)
        let #(next, outcome, decided) =
          attachment.poll(
            model.view.candidate,
            now: host_bootstrap.monotonic_time_ms(),
          )
        let model =
          list.fold(
            decided,
            tui_model.Model(..model, view: view_set.candidate(model.view, next)),
            tui_model.emit_attachment,
          )
          |> runtime.flush
        case outcome {
          Some(outcome) -> poll.Settled(outcome)
          None -> poll.Pending(model)
        }
      },
    )
  {
    poll.Answer(outcome) -> outcome
    poll.RanOut(pending) -> {
      let _ =
        runtime.flush(tui_model.emit_attachment(
          pending,
          attachment.Abandon(pending.view.candidate),
        ))
      panic as "the bounded credited attachment did not settle"
    }
    poll.Failure(reason) -> panic as string.inspect(reason)
  }
}

fn acquire_lock_eventually(
  path: String,
  attempts: Int,
) -> Result(host_bootstrap.LaunchLock, String) {
  case
    poll.until(within: attempts * 25, every: 25, attempt: fn() {
      case host_bootstrap.try_launch_lock(path) {
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
      case host_bootstrap.process_identity(pid) {
        Ok(host_bootstrap.ProcessAbsent) -> poll.Done(Nil)
        Ok(host_bootstrap.ProcessPresent(_)) | Error(_) -> poll.Retry
      }
    })
  assert observed == poll.Answered(Nil)
    as "the native process must be observed absent before replacement"
}

// The command name in a stat line is parenthesised and may hold spaces, so
// the fields are counted from the last closing parenthesis: state, parent,
// then the process group.
fn process_group(pid: Int) -> Result(Int, Nil) {
  use stat <- result.try(
    simplifile.read("/proc/" <> int.to_string(pid) <> "/stat")
    |> result.replace_error(Nil),
  )
  use fields <- result.try(list.last(string.split(stat, ") ")))
  case string.split(fields, " ") {
    [_state, _parent, group, ..] -> int.parse(group)
    _ -> Error(Nil)
  }
}

fn test_root(name: String) -> String {
  "build/bootstrap-test-"
  <> name
  <> "-"
  <> string.inspect(host_bootstrap.system_time_ms())
}

// The update notice is a projection of retained authenticated identity. Each
// adoption and refresh must leave exactly one copy in the visible transcript.
fn assert_build_notice(model: tui_model.Model) {
  assert list.count(model.shared.transcript, fn(line) {
      string.contains(line.text, "differs from this client's")
    })
    == 1
    as "coherent capture must retain the authenticated build mismatch"
}
