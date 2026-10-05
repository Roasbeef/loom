//// Custody-only tests run in a fresh TLS-configured owner VM so their Peer
//// values come from the production bootstrap. They do not fabricate opaque
//// membership or connect to an executor. Each child must print a final witness
//// after its assertions; a premature exit with status zero is not a pass.

import argv
import distribution_fixture
import executor/remote/distribution
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import gleam/time/timestamp
import simplifile
import support/internal/ffi_proc

/// Runs one fixed local test entrypoint with a real administrative Peer.
/// The module and function names are test source constants, never network input.
///
/// ## Examples
/// `use peer <- beam_owner_fixture.run("fixture_test", "custody_test")`.
pub fn run(
  module: String,
  function: String,
  body: fn(distribution.Peer) -> Nil,
) -> Nil {
  case argv.load().arguments {
    ["--beam-owner-fixture", path] -> {
      let assert Ok(fixture) = distribution_fixture.read_provisioned(path)
        as "The child reads its original private administrative fixture."
      let assert Ok(membership) = distribution.start(fixture.owner_config)
        as "The owner boots through the real TLS-only admission boundary."
      let assert Ok(peer) = distribution.peer(membership, fixture.executor_name)
        as "Only the exact administratively configured executor is usable."
      body(peer)
      io.println(witness(function))
    }
    _ -> run_child(module, function)
  }
}

fn run_child(module: String, function: String) -> Nil {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let directory =
    "/private/tmp/loom-beam-owner-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let assert Ok(fixture) = distribution_fixture.provision(directory, "binding")
    as "Private certificate and cookie provisioning must succeed."
  let path = directory <> "/fixture.term"
  assert distribution_fixture.write_provisioned(fixture, path) == Ok(Nil)
  let assert Ok(erl) = ffi_proc.which("erl")
    as "The executing Gleam suite requires its Erlang runtime."
  let assert Ok(cwd) = simplifile.current_directory()
    as "The child retains this package's dependency paths."

  // Only fixed identifiers enter the Erlang expression. The fixture path is
  // an argv value, so path spelling never becomes executable source text.
  assert safe_name(module)
  assert safe_name(function)
  let arguments =
    list.append(distribution_fixture.node_arguments(fixture.owner_options), [
      "-noshell",
      "-eval",
      "'" <> module <> "':'" <> function <> "'(), halt().",
      "-extra",
      "--beam-owner-fixture",
      path,
    ])
  let assert Ok(#(status, output)) =
    distribution_fixture.run_node(
      erl,
      arguments,
      cwd,
      distribution.bootstrap_home(fixture.owner_config),
    )
    as "The independent owner emulator must return its real exit status."
  let removed = simplifile.delete(directory)
  assert status == 0 as output
  assert string.contains(output, witness(function))
    as "An early exit cannot masquerade as completed custody assertions."
  assert removed == Ok(Nil) as "The exited child's private fixture is removed."
}

fn safe_name(value: String) -> Bool {
  value != ""
  && list.all(string.to_graphemes(value), fn(character) {
    string.contains("abcdefghijklmnopqrstuvwxyz0123456789_@", character)
  })
}

fn witness(function: String) -> String {
  "LOOM_BEAM_OWNER_CASE_PASSED:" <> function
}
