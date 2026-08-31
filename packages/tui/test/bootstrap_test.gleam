import core/json
import filepath
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import simplifile
import tui/bootstrap
import tui/internal/ffi_bootstrap

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

pub fn process_identity_distinguishes_one_process_lifetime_test() {
  let root = test_root("process-identity")
  let log = filepath.join(root, "sleep.log")
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = ffi_bootstrap.ensure_private_directory(root)
  let assert Ok(started) =
    ffi_bootstrap.spawn_server("/bin/sleep", ["30"], root, log)
  let process_port = started.0
  let pid = started.1
  let assert Ok(first) = ffi_bootstrap.process_identity(pid)
  assert ffi_bootstrap.process_identity(pid) == Ok(first)
  ffi_bootstrap.terminate_process_group(pid)
  ffi_bootstrap.close_server_process(process_port)
  assert_process_stops(pid, 20)
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
  let session_directory = filepath.join(root, "session")
  let session = filepath.join(session_directory, "multi.part.db")
  let state = filepath.join(root, "state")
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
  let assert Ok(Nil) = simplifile.create_directory_all(session_directory)
  let options = bootstrap.Options(workspace, session, server, state)
  let assert Ok(first) = bootstrap.resolve(options)
  process.sleep(100)
  let assert Ok(second) = bootstrap.resolve(options)
  assert first.address == second.address
  assert first.session == "multi"
  assert first.session == second.session
  assert first.token == second.token
  let assert Ok(pid) = endpoint_pid(state)
  let assert Ok(identity) = ffi_bootstrap.process_identity(pid)
  assert ffi_bootstrap.process_identity(pid) == Ok(identity)
  ffi_bootstrap.terminate_process_group(pid)
  assert_process_stops(pid, 20)
  let _ = simplifile.delete(root)
  Nil
}

fn assert_process_stops(pid: Int, attempts: Int) -> Nil {
  case ffi_bootstrap.process_identity(pid), attempts {
    Error(_), _ -> Nil
    Ok(_), 0 -> panic as "detached server did not stop"
    Ok(_), _ -> {
      process.sleep(50)
      assert_process_stops(pid, attempts - 1)
    }
  }
}

fn endpoint_pid(state: String) -> Result(Int, String) {
  let directory = filepath.join(state, "endpoints")
  use names <- result.try(
    simplifile.read_directory(directory)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  use name <- result.try(case names {
    [name] -> Ok(name)
    _ -> Error("expected exactly one endpoint record")
  })
  use contents <- result.try(
    simplifile.read(filepath.join(directory, name))
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  use value <- result.try(
    json.parse(contents)
    |> result.map_error(fn(report) { report.expected }),
  )
  case value {
    json.Object(fields) ->
      case list.key_find(fields, "server_pid") {
        Ok(json.Int(pid)) -> Ok(pid)
        _ -> Error("endpoint record has no server pid")
      }
    _ -> Error("endpoint record is not an object")
  }
}

fn test_root(name: String) -> String {
  "build/bootstrap-test-"
  <> name
  <> "-"
  <> string.inspect(ffi_bootstrap.system_time_ms())
}
