//// Shared endpoint tests exercise real control sockets and native process fences.
//// In-VM root loss is deliberately distinct from native VM exit. The native
//// startup test executes this build's client entrypoint through erl, preserving
//// the paused wrapper PID across exec without relying on a stale shipment.

import broker/token
import client/daemon/domain as domain_service
import client/daemon/main as entrypoint
import client/daemon/manager
import client/daemon/root
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import host/bootstrap as host
import host/endpoint
import mist
import tui/bootstrap
import tui/daemon
import tui/daemon/bootstrap as daemon_bootstrap
import tui/daemon/protocol
import weft/poll

fn paths() {
  let assert Ok(paths) =
    endpoint.paths(
      "build/test_db/daemon-bootstrap-"
      <> bit_array.base16_encode(token.production_entropy()(8)),
    )
    as "private endpoint state is fresh for this test"
  paths
}

fn claimed_listener() {
  let paths = paths()
  let assert Ok(config) = entrypoint.parse(["--state-dir", paths.root])
    as "fixture uses production daemon flags"
  let assert Ok(#(config, paths, fence)) = entrypoint.claim_endpoint(config)
    as "Starting precedes catalogue acquisition"
  assert !host.path_exists(paths.catalogue)
  let assert Ok(daemon) =
    root.start(
      root.Config(paths.root, "Owner", 2),
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, _) { Ok(record.id) },
        fatal: fn(_) { [] },
      ),
    )
    as "real root retains its catalogue"
  let assert Ok(serving) =
    entrypoint.listen(config, daemon, fn(_, _) {
      response.new(501)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("no sessions")))
    })
    as "root retains a real listener before publishing Ready"
  assert entrypoint.publish_endpoint(config, serving, paths, fence) == Ok(Nil)
  #(config, paths, serving)
}

fn options(paths: endpoint.Paths, workspace) {
  bootstrap.Options(
    workspace,
    "",
    "/missing/installed/loomd",
    paths.root,
    "/missing/operator/config",
  )
}

fn no_launch() {
  Error("this live endpoint must not invoke executable discovery")
}

pub fn daemon_bootstrap_two_workspaces_reuse_one_pid_without_opening_test() {
  let #(_, paths, serving) = claimed_listener()
  let assert Ok(first) =
    bootstrap.resolve_daemon(options(paths, "/work/one"), process.self(), 2000)
    as "first workspace authenticates the shared daemon"
  let assert Ok(second) =
    bootstrap.resolve_daemon(options(paths, "/work/two"), process.self(), 2000)
    as "second workspace reuses the same daemon"
  assert first.record == second.record
  assert first.record.fence.pid == host.current_process_id()
  assert daemon.hello(first.control).epoch
    == protocol.Epoch(serving.ready.epoch)
  let assert Ok(protocol.StatusReply(status)) =
    daemon.request(second.control, protocol.Status, 1000)
    as "authenticated status comes from the real daemon manager"
  assert status.occupied == 0
  daemon.close(first.control)
  daemon.close(second.control)
  assert root.shutdown(serving.daemon, within: 5000) == Ok(Nil)
  assert endpoint.load(paths) == Ok(Some(first.record))
  let assert Error(_) = endpoint.claim(paths, first.record.fence)
    as "normal root shutdown does not establish native VM departure"
}

pub fn daemon_bootstrap_root_kill_alive_vm_never_replaces_test() {
  let #(_, paths, serving) = claimed_listener()
  let watch = process.monitor(serving.listener.supervisor)
  process.kill(root.pid(serving.daemon))
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(3000)
    as "root KILL closes its original listener"
  let assert poll.Answered(lock) =
    poll.until(within: 2000, every: 5, attempt: fn() {
      case host.try_launch_lock(paths.root <> "/daemon.lock") {
        Ok(lock) -> poll.Done(lock)
        Error(_) -> poll.Retry
      }
    })
    as "the lifetime lock may already be released despite the live VM"
  host.release_launch_lock(lock)
  let assert Ok(endpoint.Occupied(record)) = endpoint.availability(paths)
    as "the containing VM fence survives root and lock loss"
  let attempted = process.new_subject()
  let assert Error(_) =
    daemon_bootstrap.resolve(
      paths,
      process.self(),
      fn() {
        process.send(attempted, Nil)
        no_launch()
      },
      1000,
    )
    as "failed authenticated probe cannot authorize replacement"
  assert process.receive(attempted, 0) == Error(Nil)
  assert endpoint.load(paths) == Ok(Some(record))
}

pub fn daemon_bootstrap_mismatched_epoch_preserves_record_test() {
  let #(_, paths, serving) = claimed_listener()
  let assert Ok(Some(endpoint.Ready(fence, host, port, _))) =
    endpoint.load(paths)
    as "production publication uses the actual nonzero bound port"
  let wrong = endpoint.Ready(fence, host, port, "different-epoch")
  assert endpoint.write(paths, wrong) == Ok(Nil)
  let assert Error(_) =
    daemon_bootstrap.resolve(paths, process.self(), no_launch, 1000)
    as "valid credential plus wrong epoch is not authenticated discovery"
  assert endpoint.load(paths) == Ok(Some(wrong))
  assert root.shutdown(serving.daemon, within: 5000) == Ok(Nil)
}

fn native_launch(paths: endpoint.Paths) {
  let assert Ok(erl) = host.find_executable("erl")
    as "this test executes the same installed Erlang as its parent VM"
  let assert Ok(build) = host.canonical_directory("build/dev/erlang")
    as "current compiled modules are the child test artifact"
  let assert Ok(packages) = host.list_directory_bounded(build, 256)
    as "the compiled dependency list is bounded"
  let code_paths =
    list.map(packages, fn(package) { build <> "/" <> package <> "/ebin" })
  let arguments =
    list.append(["-pa", ..code_paths], [
      "-noshell", "-eval", "client@@main:run(client)", "-extra", "--state-dir",
      paths.root, "--bind", "127.0.0.1:0", "--config", "/missing/lazy/config",
      "--helper", "/missing/lazy/helper",
    ])
  Ok(daemon_bootstrap.Launch(erl, arguments))
}

pub fn daemon_bootstrap_native_child_lock_handoff_and_two_workspace_reuse_test() {
  let paths = paths()
  let resolved =
    daemon_bootstrap.resolve(
      paths,
      process.self(),
      fn() { native_launch(paths) },
      10_000,
    )
  case resolved {
    Error(reason) -> {
      cleanup_native(paths)
      panic as reason
    }
    Ok(first) -> {
      assert first.record.fence.pid != host.current_process_id()
      let second =
        bootstrap.resolve_daemon(
          options(paths, "/other/workspace"),
          process.self(),
          2000,
        )
      let result = daemon.request(first.control, protocol.Status, 1000)
      let _shutdown = daemon.request(first.control, protocol.Shutdown, 1000)
      daemon.close(first.control)
      case second {
        Ok(second) -> {
          assert second.record == first.record
          daemon.close(second.control)
        }
        Error(reason) -> {
          cleanup_native(paths)
          panic as reason
        }
      }
      let departed =
        poll.until(within: 5000, every: 10, attempt: fn() {
          case endpoint.is_present(first.record.fence) {
            Ok(False) -> poll.Done(Nil)
            Ok(True) -> poll.Retry
            Error(reason) -> poll.Fail(reason)
          }
        })
      cleanup_native(paths)
      let assert poll.Answered(Nil) = departed
        as "native process departure, not control reply, permits replacement"
      let assert Ok(protocol.StatusReply(status)) = result
        as "native child completed authenticated v2 control without runtime setup"
      assert status.occupied == 0
      assert endpoint.load(paths) == Ok(Some(first.record))
      assert endpoint.availability(paths) == Ok(endpoint.Vacant)
    }
  }
}

pub fn daemon_bootstrap_concurrent_native_launchers_share_one_child_test() {
  let paths = paths()
  let terminal = process.self()
  let replies = process.new_subject()
  let launched = process.new_subject()
  list.each([1, 2], fn(_) {
    process.spawn_unlinked(fn() {
      let outcome =
        daemon_bootstrap.resolve(
          paths,
          terminal,
          fn() {
            process.send(launched, Nil)
            native_launch(paths)
          },
          10_000,
        )
      process.send(replies, outcome)
    })
  })
  let first = process.receive(replies, 12_000)
  let second = process.receive(replies, 12_000)

  // Request shutdown before assertions so a refusal still has fixture cleanup.
  list.each([first, second], fn(outcome) {
    case outcome {
      Ok(Ok(connection)) -> {
        let _ = daemon.request(connection.control, protocol.Shutdown, 1000)
        daemon.close(connection.control)
      }
      Ok(Error(_)) | Error(_) -> Nil
    }
  })
  cleanup_native(paths)
  let assert Ok(Ok(first)) = first
    as "the first launcher completes the real child handshake"
  let assert Ok(Ok(second)) = second
    as "the competing launcher waits outside the child's launch lock"
  assert first.record == second.record
  assert process.receive(launched, 0) == Ok(Nil)
  assert process.receive(launched, 0) == Error(Nil)
}

// Failure cleanup targets only the child recorded by this fresh test fixture.
// Rechecking the full birth fence avoids signalling a reused numeric PID.
fn cleanup_native(paths) {
  let own_pid = host.current_process_id()
  case endpoint.load(paths) {
    Ok(Some(record)) ->
      case endpoint.is_present(record.fence) {
        Ok(True) if record.fence.pid != own_pid ->
          host.terminate_process_group(record.fence.pid)
        Ok(True) | Ok(False) | Error(_) -> Nil
      }
    Ok(None) | Error(_) -> Nil
  }
}
