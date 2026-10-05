//// Fixed workspace scenarios run on independent TLS-admitted owner and executor
//// OS VMs. Coordination files establish test ordering; effects and exchanges use
//// the actual scoped service and endpoint. Failed node logs remain available.
//// `safe_name` bounds the only fixed source identifier in a child entrypoint.

import argv
import distribution_fixture
import executor/remote/distribution
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import gleam/time/timestamp
import simplifile
import weft
import weft/poll

/// Runs one fixed owner scenario with a genuine configured executor Peer.
///
/// ## Examples
/// `use peer <- workspace_beam_fixture.run("workspace_case_test")`.
pub fn run(name: String, body: fn(distribution.Peer) -> Nil) -> Nil {
  case argv.load().arguments {
    ["--workspace-fixture-owner", root] -> {
      let assert Ok(provisioned) =
        distribution_fixture.read_provisioned(root <> "/fixture.term")
        as "The child reads the original private administrative fixture."
      let assert Ok(membership) = distribution.start(provisioned.owner_config)
        as "The owner enters the real TLS-only runtime membership."
      let assert Ok(peer) =
        distribution.peer(membership, provisioned.executor_name)
        as "Only the exact configured executor is available."
      body(peer)
      io.println(witness(name))
    }
    _ -> run_nodes(name)
  }
}

/// Returns the parent-selected directory carried as data in the child's argv.
///
/// ## Examples
/// `workspace_beam_fixture.root()`.
pub fn root() -> String {
  let assert [_, root] = argv.load().arguments
    as "Only a fixed owner or executor role uses this test helper."
  root
}

/// Writes a fixed local test barrier after the preceding assertion or effect.
///
/// ## Examples
/// `workspace_beam_fixture.mark(root, "written")`.
pub fn mark(root: String, name: String) -> Nil {
  assert simplifile.write(root <> "/" <> name, "ready") == Ok(Nil)
}

/// Observes a fixed test barrier with a finite independent wait budget.
///
/// ## Examples
/// `workspace_beam_fixture.await(root, "ready")`.
pub fn await(root: String, name: String) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(10_000, 10, fn() {
      case simplifile.is_file(root <> "/" <> name) {
        Ok(True) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "The original fixed role reaches its barrier within the test lifetime."
  Nil
}

fn run_nodes(name: String) -> Nil {
  assert safe_name(name)
  let assert Ok(here) = simplifile.current_directory()
    as "The test retains the actual package directory."
  assert simplifile.create_directory_all(here <> "/build") == Ok(Nil)
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let root =
    here
    <> "/build/workspace-beam-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let assert Ok(provisioned) = distribution_fixture.provision(root, "workspace")
    as "The isolated pair has distinct exact named certificate pins."
  assert distribution_fixture.write_provisioned(
      provisioned,
      root <> "/fixture.term",
    )
    == Ok(Nil)

  // Launch flags and private OTP homes derive from this same original fixture.
  let executable = distribution_fixture.current_executable()
  let roles = [
    #(
      provisioned.executor_config,
      provisioned.executor_options,
      "client@remote@workspace_client_test:executor_main(),halt(0).",
      "--workspace-fixture-executor",
      "executor",
    ),
    #(
      provisioned.owner_config,
      provisioned.owner_options,
      "'client@remote@workspace_client_test':'" <> name <> "'(),halt(0).",
      "--workspace-fixture-owner",
      "owner",
    ),
  ]

  // Both role runners are finite managed observations of independent OS nodes.
  // Each node owns its local SQLite actors and its explicit teardown barriers.
  let outcomes =
    weft.new_prepared(
      list.map(roles, fn(role) {
        let #(config, options, entrypoint, flag, role_name) = role
        weft.managed(fn(_) {
          let result =
            distribution_fixture.run_node(
              executable,
              list.append(distribution_fixture.node_arguments(options), [
                "-noshell", "-eval", entrypoint, "-extra", flag, root,
              ]),
              here,
              distribution.bootstrap_home(config),
            )
          case result {
            Ok(#(_, output)) -> {
              assert simplifile.write(
                  root <> "/" <> role_name <> ".log",
                  output,
                )
                == Ok(Nil)
            }
            Error(reason) -> {
              assert simplifile.write(
                  root <> "/" <> role_name <> ".log",
                  reason,
                )
                == Ok(Nil)
            }
          }
          result
        })
      }),
    )
    |> weft.deadline(25_000)
    |> weft.start
  let assert [executor_result, owner_result] = weft.values(outcomes)
    as "Both node runners must return; failures retain their fixture logs."
  let values = [executor_result, owner_result]
  list.each(values, fn(value) {
    let #(status, output) = value
    assert status == 0 as output
  })
  let assert Ok(owner_log) = simplifile.read(root <> "/owner.log")
    as "The original owner emulator returns its own output."
  assert string.contains(owner_log, witness(name))
    as "Premature VM exit zero cannot stand in for completed assertions."
  assert simplifile.is_file(root <> "/executor-success") == Ok(True)
    as "The actual executor performs explicit local service teardown."
  assert simplifile.delete(root) == Ok(Nil)
}

fn safe_name(name: String) -> Bool {
  name != ""
  && list.all(string.to_graphemes(name), fn(character) {
    string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", character)
  })
}

fn witness(name: String) -> String {
  "LOOM_WORKSPACE_BEAM_CASE_PASSED:" <> name
}
