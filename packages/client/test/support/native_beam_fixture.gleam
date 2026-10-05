//// Native component scenarios own independent TLS owner and executor OS VMs.
//// The generation manager starts VM2 only after VM1 returns actual exit zero
//// and its separate native drain witness exists. Endpoint DOWN is not a join.
//// `safe_name` admits only the two fixed source scenarios.

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

/// Runs one fixed native owner scenario with genuine TLS membership.
///
/// ## Examples
/// `use peer <- native_beam_fixture.run("success")`.
pub fn run(name: String, body: fn(distribution.Peer) -> Nil) -> Nil {
  case argv.load().arguments {
    ["--native-beam-owner", root] -> {
      let assert Ok(provisioned) =
        distribution_fixture.read_provisioned(root <> "/fixture.term")
        as "The owner reads its original private administrative fixture."
      let assert Ok(membership) = distribution.start(provisioned.owner_config)
        as "The owner VM enters real mutual TLS distribution."
      let assert Ok(peer) =
        distribution.peer(membership, provisioned.executor_name)
        as "Only the provisioned original executor name is available."
      body(peer)
      io.println(witness(name))
    }
    _ -> run_nodes(name)
  }
}

/// Returns the parent-selected local scenario directory from fixed-role argv.
///
/// ## Examples
/// `native_beam_fixture.root()`.
pub fn root() -> String {
  let assert [_, root] = argv.load().arguments
    as "Only a fixed owner or executor role reads this fixture argument."
  root
}

/// Commits one fixed test barrier after the preceding effect or assertion.
///
/// ## Examples
/// `native_beam_fixture.mark(root, "rotate")`.
pub fn mark(root: String, name: String) -> Nil {
  assert simplifile.write(root <> "/" <> name, "ready") == Ok(Nil)
}

/// Observes one original fixed barrier under an independent finite budget.
///
/// ## Examples
/// `native_beam_fixture.await(root, "executor-ready-2")`.
pub fn await(root: String, name: String) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(20_000, 10, fn() {
      case simplifile.is_file(root <> "/" <> name) {
        Ok(True) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "The original scenario reaches its fixed barrier within the role lifetime."
  Nil
}

fn run_nodes(name: String) -> Nil {
  assert safe_name(name)
  let assert Ok(here) = simplifile.current_directory()
    as "The scenario runs beside the actual client and native helper packages."
  assert simplifile.create_directory_all(here <> "/build/remote-owner")
    == Ok(Nil)
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let root =
    here
    <> "/build/remote-owner/"
    <> name
    <> "-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)

  // Credential homes are separate from the effects checkout and journal.
  let assert Ok(provisioned) = distribution_fixture.provision(root, "native")
    as "Distinct named pins and private cookies bind both roles."
  assert distribution_fixture.write_provisioned(
      provisioned,
      root <> "/fixture.term",
    )
    == Ok(Nil)

  // Fixed role functions share only administrative fixture data and test files.
  // The owner keeps its custodian live while the manager joins VM1 then VM2.
  assert simplifile.write(root <> "/scenario", name) == Ok(Nil)
  let outcomes =
    weft.new_prepared([
      weft.managed(fn(_) { manage_executor(here, root, name, provisioned) }),
      weft.managed(fn(_) { run_owner(here, root, provisioned) }),
    ])
    |> weft.deadline(70_000)
    |> weft.start
  let assert [executor_result, owner_result] = weft.values(outcomes)
    as "Both finite node runners must return; failure keeps their scenario logs."
  list.each([executor_result, owner_result], fn(result) {
    let #(status, output) = result
    assert status == 0 as output
  })

  // Status zero and each exact completion witness are independent assertions.
  let assert Ok(output) = simplifile.read(root <> "/owner.log")
    as "The actual original owner VM returns its own output."
  assert string.contains(output, witness(name))
    as "An early OS-node exit zero cannot stand in for completed assertions."
  assert simplifile.is_file(root <> "/native-drained-1") == Ok(True)
  case name {
    "success" -> {
      assert simplifile.is_file(root <> "/vm-exited-1") == Ok(True)
      assert simplifile.is_file(root <> "/native-drained-2") == Ok(True)
    }
    "refusals" -> Nil
    _ -> panic as "Only the two fixed source scenarios are valid."
  }
  assert simplifile.delete(root) == Ok(Nil)
}

fn run_owner(
  here: String,
  root: String,
  provisioned: distribution_fixture.Provisioned,
) {
  let result =
    run_vm(
      here,
      root,
      provisioned.owner_config,
      provisioned.owner_options,
      "client@remote@native_integration:main(),halt(0).",
      "--native-beam-owner",
    )
  case result {
    Ok(#(status, output)) -> {
      assert simplifile.write(root <> "/owner.log", output) == Ok(Nil)
      case status {
        0 -> Nil
        _ -> mark(root, "abort")
      }
    }
    Error(reason) -> {
      assert simplifile.write(root <> "/owner.log", reason) == Ok(Nil)
      mark(root, "abort")
    }
  }
  result
}

fn manage_executor(
  here: String,
  root: String,
  name: String,
  provisioned: distribution_fixture.Provisioned,
) {
  let first =
    run_vm(
      here,
      root,
      provisioned.executor_config,
      provisioned.executor_options,
      "client@remote@native_integration:executor_main(),halt(0).",
      "--native-beam-executor-1",
    )
  let assert Ok(#(status, output)) = first
    as "The old executor emulator returns its actual exit status."
  assert simplifile.write(root <> "/executor-1.log", output) == Ok(Nil)
  assert status == 0 as output
  assert simplifile.is_file(root <> "/native-drained-1") == Ok(True)
    as "OS exit alone cannot prove the native helper subtree drained."
  mark(root, "vm-exited-1")

  // Actual VM1 exit retires all transport processes, including delayed managed
  // credit completion. The retained journal remains fenced before VM2 opens it.
  case name, simplifile.is_file(root <> "/abort") {
    "success", Ok(False) -> {
      let second =
        run_vm(
          here,
          root,
          provisioned.executor_config,
          provisioned.executor_options,
          "client@remote@native_integration:executor_main(),halt(0).",
          "--native-beam-executor-2",
        )
      case second {
        Ok(#(_, bytes)) -> {
          assert simplifile.write(root <> "/executor-2.log", bytes) == Ok(Nil)
        }
        Error(reason) -> {
          assert simplifile.write(root <> "/executor-2.log", reason) == Ok(Nil)
        }
      }
      second
    }
    _, _ -> Ok(#(status, output))
  }
}

fn run_vm(
  here: String,
  root: String,
  config: distribution.Config,
  options: String,
  entrypoint: String,
  flag: String,
) {
  distribution_fixture.run_node(
    distribution_fixture.current_executable(),
    list.append(distribution_fixture.node_arguments(options), [
      "-noshell", "-eval", entrypoint, "-extra", flag, root,
    ]),
    here,
    distribution.bootstrap_home(config),
  )
}

fn safe_name(name: String) -> Bool {
  name == "success" || name == "refusals"
}

fn witness(name: String) -> String {
  "LOOM_NATIVE_BEAM_CASE_PASSED:" <> name
}
