//// Daemon settings are startup-owned and share one parser with the catalogue.

import broker/token
import client/catalog
import client/daemon/limits
import client/daemon/main as entrypoint
import client/daemon/root
import gleam/bit_array
import gleam/list
import gleam/string
import host/bootstrap
import simplifile
import telemetry/log

pub fn absent_and_partial_daemon_tables_keep_defaults_test() {
  assert limits.parse("") == Ok(limits.defaults)
  assert limits.parse("[daemon]\nprofile = true\n") == Ok(limits.defaults)
  assert limits.parse("[daemon]\nmax_connections = 9\n")
    == Ok(limits.Limits(9, limits.defaults.reserved_message_bytes))
  assert limits.parse("[daemon]\nmax_reserved_message_bytes = 100000000\n")
    == Ok(limits.Limits(limits.defaults.connections, 100_000_000))
}

pub fn invalid_connection_limits_are_refused_by_both_parsers_test() {
  list.each(["max_connections", "max_reserved_message_bytes"], fn(key) {
    list.each(["0", "-1", "1.5", "true", "\"64\""], fn(value) {
      let text = "[daemon]\n" <> key <> " = " <> value <> "\n"
      let expected = "daemon." <> key <> " must be a positive integer"
      assert limits.parse(text) == Error(expected)
      assert catalog.parse(text) == Error(expected)
    })
  })
  assert limits.parse("[daemon]\nmax_connection = 4\n")
    == Error("unknown key `max_connection` in [daemon]")
}

pub fn startup_reads_limits_from_the_last_explicit_config_test() {
  let path =
    "build/test_db/daemon-limits-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(Nil) = bootstrap.ensure_private_directory(path)
    as "fixture directory exists"
  let selected = path <> "/selected.toml"
  assert simplifile.write(
      selected,
      "[daemon]\nmax_connections = 11\nmax_reserved_message_bytes = 123456789\n",
    )
    == Ok(Nil)
  let assert Ok(config) =
    entrypoint.parse([
      "--state-dir",
      path <> "/state",
      "--config",
      path <> "/missing.toml",
      "--config",
      selected,
    ])
    as "daemon flags retain the last owner configuration"
  let assert Ok(daemon) = entrypoint.prepare(config, log.discard())
    as "startup accepts daemon settings without opening a session"
  assert root.connection_limits(daemon) == limits.Limits(11, 123_456_789)
  assert root.shutdown(daemon, within: 5000) == Ok(Nil)
}

pub fn invalid_startup_limits_fail_before_state_is_created_test() {
  let path =
    "build/test_db/daemon-invalid-limits-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(Nil) = bootstrap.ensure_private_directory(path)
    as "fixture directory exists"
  let selected = path <> "/invalid.toml"
  assert simplifile.write(selected, "[daemon]\nmax_connections = 0\n")
    == Ok(Nil)
  let assert Ok(config) =
    entrypoint.parse(["--state-dir", path <> "/state", "--config", selected])
    as "flag parsing does not acquire resources"
  let assert Error(reason) = entrypoint.prepare(config, log.discard())
    as "invalid limits refuse startup"
  assert string.contains(
    reason,
    "daemon.max_connections must be a positive integer",
  )
  assert simplifile.is_directory(path <> "/state") == Ok(False)
}
