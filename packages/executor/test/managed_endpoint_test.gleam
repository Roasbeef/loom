//// Real original-endpoint controls use isolated pinned TLS runtimes and SQLite.
//// Fixed fixture witnesses exercise publication/removal policy, not physical
//// full-host retirement or ordinary registered daemon assembly.

import distribution_fixture as fixture
import executor/remote/distribution
import gleam/int
import gleam/list
import gleam/string
import gleam/time/timestamp
import simplifile
import weft

pub fn legacy_and_managed_publication_bypass_refusal_test() {
  run_case("compatibility")
}

pub fn original_store_claim_row_endpoint_and_close_validation_test() {
  run_case("validation")
}

pub fn exact_retirement_absence_and_original_endpoint_retry_test() {
  run_case("removal")
}

pub fn more_than_sixteen_clean_opens_and_finite_history_exhaustion_test() {
  run_case("capacity")
}

pub fn sixteen_global_claimed_and_published_slots_remain_charged_test() {
  run_case("quota")
}

pub fn actual_assigned_and_unusable_credit_refuse_removal_test() {
  run_case("credits")
}

pub fn full_compile_enrollment_must_match_original_association_test() {
  run_case("enrollment")
}

fn run_case(name: String) {
  let assert Ok(here) = simplifile.current_directory() as "package directory"
  let #(seconds, nanos) =
    timestamp.system_time()
    |> timestamp.to_unix_seconds_and_nanoseconds
  let root =
    here
    <> "/build/managed-endpoint-"
    <> name
    <> "-"
    <> int.to_string(seconds)
    <> int.to_string(nanos)
  let assert Ok(provisioned) = fixture.provision(root, "managed")
    as "original pinned TLS provisioning"
  assert fixture.write_provisioned(provisioned, root <> "/fixture.term")
    == Ok(Nil)
  let executor = #(
    provisioned.executor_config,
    provisioned.executor_options,
    "managed_endpoint_fixture:run("
      <> erlang_string(root)
      <> ","
      <> erlang_string(name)
      <> "),halt(0).",
  )
  let roles = case name {
    "credits" -> [
      executor,
      #(
        provisioned.owner_config,
        provisioned.owner_options,
        "managed_endpoint_fixture:owner_run("
          <> erlang_string(root)
          <> "),halt(0).",
      ),
    ]
    _ -> [executor]
  }
  let executable = fixture.current_executable()
  let outcomes =
    weft.new(
      list.map(roles, fn(role) {
        fn() {
          fixture.run_node(
            executable,
            list.append(fixture.node_arguments(role.1), [
              "-noshell",
              "-eval",
              role.2,
            ]),
            here,
            distribution.bootstrap_home(role.0),
          )
        }
      }),
    )
    |> weft.deadline(25_000)
    |> weft.start
  let values = weft.values(outcomes)
  assert list.length(values) == list.length(roles)
  list.index_map(values, fn(value, index) {
    let #(code, output) = value
    assert simplifile.write(
        root <> "/role-" <> int.to_string(index) <> ".log",
        int.to_string(code) <> "\n" <> output,
      )
      == Ok(Nil)
  })
  list.each(values, fn(value) {
    let #(code, output) = value
    assert code == 0 as output
    assert !string.contains(output, "=CRASH REPORT=") as output
    assert !string.contains(output, "=ERROR REPORT=") as output
  })
  assert simplifile.read(root <> "/success") == Ok(name)
  assert simplifile.delete(root) == Ok(Nil)
}

fn erlang_string(value: String) -> String {
  "<<\""
  <> { value |> string.replace("\\", "\\\\") |> string.replace("\"", "\\\"") }
  <> "\">>"
}
