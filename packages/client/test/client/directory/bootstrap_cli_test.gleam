//// `loomd directory bootstrap` refuses before it reserves or starts anything
//// when it would start a second cluster or has nothing to create
//// (protocol-change/080). The emulator scenarios in `distribution_test` cover
//// the members it asks.

import client/daemon/directory_cli
import gleam/string
import simplifile
import support/remote_fixtures

const distribution_table =
  "[distribution]
node = \"alpha@10.0.0.1\"
ca = \"/etc/loom/ca.pem\"
certificate = \"/etc/loom/cert.pem\"
key = \"/etc/loom/key.pem\"
cookie = \"/home/loom/.erlang.cookie\"

[[distribution.peers]]
node = \"bravo@10.0.0.2\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000001\"

[[distribution.peers]]
node = \"exec@10.0.0.3\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000002\"
"

const directory_table =
  "
[directory]
members = [\"alpha@10.0.0.1\", \"bravo@10.0.0.2\", \"exec@10.0.0.3\"]
"

fn absolute(path: String) -> String {
  let assert Ok(cwd) = simplifile.current_directory() as "a working directory"
  cwd <> "/" <> path
}

pub fn a_configuration_without_a_directory_is_refused_test() {
  let scratch = absolute(remote_fixtures.scratch("bootstrap-none"))
  let config = scratch <> "/loom.toml"
  let assert Ok(Nil) = simplifile.write(config, distribution_table) as "written"
  let assert Error(reason) =
    directory_cli.run([
      "bootstrap",
      "--state-dir",
      scratch <> "/state",
      "--config",
      config,
    ])
    as "a file with no [directory] is refused"
  assert string.contains(reason, "has no [directory] table")
}

pub fn a_member_that_already_holds_a_store_is_refused_test() {
  let scratch = absolute(remote_fixtures.scratch("bootstrap-held"))
  let config = scratch <> "/loom.toml"
  let assert Ok(Nil) =
    simplifile.write(config, distribution_table <> directory_table)
    as "written"

  // A server's directory is what a started store leaves; the Ra system's own
  // files alone are not a store (`store_test`).
  let assert Ok(Nil) =
    simplifile.create_directory_all(scratch <> "/state/directory/LOOMSERVER1")
    as "a store's server directory"
  let assert Error(reason) =
    directory_cli.run([
      "bootstrap",
      "--state-dir",
      scratch <> "/state",
      "--config",
      config,
    ])
    as "a member with a store is refused"
  assert string.contains(reason, "already holds a directory store")

  // The refusal names the remedy for each case.
  assert string.contains(reason, "start this daemon and it rejoins")
  assert string.contains(
    reason,
    "remove " <> scratch <> "/state/directory and run bootstrap again",
  )
}

pub fn a_missing_config_flag_is_refused_with_the_usage_test() {
  let assert Error(reason) = directory_cli.run(["bootstrap"])
    as "the config is required"
  assert string.contains(reason, "--config is required")
  let assert Error(usage) = directory_cli.run(["status"])
    as "an unknown command"
  assert usage == directory_cli.usage
}
