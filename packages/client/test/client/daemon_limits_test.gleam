//// Daemon settings are startup-owned and share one parser with the catalogue.

import broker/token
import client/catalog
import client/daemon/limits
import client/daemon/listen_address
import client/daemon/main as entrypoint
import client/daemon/root
import client/daemon/ui_origin
import gleam/bit_array
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import telemetry/log
import tom

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

pub fn ui_setting_is_boolean_in_startup_and_catalogue_parsers_test() {
  let assert Ok(example) = simplifile.read("../../docs/examples/loom.toml")
    as "the committed catalogue is a complete session configuration"
  list.each(["true", "false"], fn(value) {
    let text = "[daemon]\nui = " <> value <> "\n"
    assert limits.parse(text) == Ok(limits.defaults)
    assert catalog.parse(example <> "\nui = " <> value <> "\n")
      |> result.is_ok()
  })
  list.each(["1", "\"true\"", "[]", "{}"], fn(value) {
    let text = "[daemon]\nui = " <> value <> "\n"
    assert limits.parse(text) == Error("daemon.ui must be true or false")
    assert catalog.parse(text) == Error("daemon.ui must be true or false")
  })
}

pub fn startup_captures_ui_and_cli_opt_in_wins_test() {
  let assert Ok(listed) = ui_origin.parse("https://box.example:8443")
    as "the fixture origin parses"
  let origins = "ui_origins = [\"https://Box.example:8443/\"]\n"
  list.each(
    [
      #("", [], entrypoint.ViewOff),
      #("ui = false\n", [], entrypoint.ViewOff),
      #("ui = true\n", [], entrypoint.ViewOn([])),
      #("ui = false\n", ["--ui"], entrypoint.ViewOn([])),
      #("ui = true\n" <> origins, [], entrypoint.ViewOn([listed])),
      #(origins, ["--ui"], entrypoint.ViewOn([listed])),
    ],
    fn(fixture) {
      let #(setting, flags, expected) = fixture
      let path =
        "build/test_db/daemon-ui-"
        <> bit_array.base16_encode(token.production_entropy()(8))
      let assert Ok(Nil) = bootstrap.ensure_private_directory(path)
        as "fixture directory exists"
      let selected = path <> "/selected.toml"
      assert simplifile.write(selected, "[daemon]\n" <> setting) == Ok(Nil)
      let assert Ok(config) =
        entrypoint.parse(list.append(
          [
            "--state-dir",
            path <> "/state",
            "--config",
            path <> "/missing.toml",
            "--config",
            selected,
          ],
          flags,
        ))
        as "the last startup catalogue is selected"
      let assert Ok(#(resolved, daemon)) =
        entrypoint.prepare_startup(config, log.discard())
        as "startup captures settings without opening a session"
      assert resolved.view == expected
      assert root.connection_limits(daemon) == limits.defaults
      assert root.shutdown(daemon, within: 5000) == Ok(Nil)
    },
  )
}

pub fn invalid_ui_setting_refuses_startup_before_state_is_created_test() {
  let path =
    "build/test_db/daemon-invalid-ui-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(Nil) = bootstrap.ensure_private_directory(path)
    as "fixture directory exists"
  let selected = path <> "/invalid.toml"
  assert simplifile.write(selected, "[daemon]\nui = \"true\"\n") == Ok(Nil)
  let assert Ok(config) =
    entrypoint.parse(["--state-dir", path <> "/state", "--config", selected])
    as "flag parsing does not acquire resources"
  let assert Error(reason) = entrypoint.prepare_startup(config, log.discard())
    as "invalid UI configuration refuses startup"
  assert string.contains(reason, "daemon.ui must be true or false")
  assert simplifile.is_directory(path <> "/state") == Ok(False)
}

// A listed origin belongs to the web view, so a list on a daemon that does not
// serve the view refuses startup, and a bad entry refuses it naming the entry,
// in the startup parser and the catalogue's alike (protocol-change/052).
pub fn listed_origins_refuse_startup_without_the_view_or_when_malformed_test() {
  let refused = fn(setting) {
    let path =
      "build/test_db/daemon-ui-origins-"
      <> bit_array.base16_encode(token.production_entropy()(8))
    let assert Ok(Nil) = bootstrap.ensure_private_directory(path)
      as "fixture directory exists"
    let selected = path <> "/origins.toml"
    assert simplifile.write(selected, "[daemon]\n" <> setting) == Ok(Nil)
    let assert Ok(config) =
      entrypoint.parse(["--state-dir", path <> "/state", "--config", selected])
      as "flag parsing does not acquire resources"
    let assert Error(reason) = entrypoint.prepare_startup(config, log.discard())
      as "the origins refuse startup"
    assert simplifile.is_directory(path <> "/state") == Ok(False)
    reason
  }
  assert string.contains(
    refused("ui_origins = [\"https://box.example:8443\"]\n"),
    "daemon.ui_origins needs the web view",
  )
  assert string.contains(
    refused("ui = true\nui_origins = [\"http://box.example:8443\"]\n"),
    "\"http://box.example:8443\" must use https",
  )
  assert catalog.parse("[daemon]\nui_origins = [\"https://box.example/ui\"]\n")
    |> result.is_error
}

pub fn executors_without_distribution_refuse_startup_before_state_is_created_test() {
  let path =
    "build/test_db/daemon-invalid-executors-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(Nil) = bootstrap.ensure_private_directory(path)
    as "fixture directory exists"
  let selected = path <> "/executors.toml"
  assert simplifile.write(
      selected,
      "[executors.build-box]\nnode = \"executor@10.0.0.2\"\n",
    )
    == Ok(Nil)
  let assert Ok(config) =
    entrypoint.parse(["--state-dir", path <> "/state", "--config", selected])
    as "flag parsing does not acquire resources"
  let assert Error(reason) = entrypoint.prepare_startup(config, log.discard())
    as "an executor with no distribution peers refuses startup"
  assert string.contains(
    reason,
    "executors needs a [distribution] table naming its peers",
  )
  assert simplifile.is_directory(path <> "/state") == Ok(False)
}

// `[daemon] bind` is read with the grammar `--bind` is: either loopback
// literal, any port in 0..65535, and nothing else. The catalogue parser
// refuses a bad value with the startup parser's words.
pub fn bind_setting_accepts_only_loopback_in_both_parsers_test() {
  assert listen_address.parse("127.0.0.1:4100", from: "daemon.bind")
    == Ok(listen_address.Address("127.0.0.1", 4100))
  assert listen_address.parse("[::1]:0", from: "daemon.bind")
    == Ok(listen_address.Address("::1", 0))
  assert limits.parse("[daemon]\nbind = \"127.0.0.1:4100\"\n")
    == Ok(limits.defaults)
  assert listen_address.from_document(dict.new()) == Ok(None)
  let assert Ok(document) = tom.parse("[daemon]\nbind = \"[::1]:4100\"\n")
    as "the fixture is valid TOML"
  assert listen_address.from_document(document)
    == Ok(Some(listen_address.Address("::1", 4100)))

  // Each refusal names the key and the value, whichever reader sees it.
  list.each(
    [
      #(
        "\"0.0.0.0:9000\"",
        "daemon.bind \"0.0.0.0:9000\" is not loopback; use 127.0.0.1:port or [::1]:port",
      ),
      #(
        "\"localhost:4100\"",
        "daemon.bind \"localhost:4100\" is not loopback; use 127.0.0.1:port or [::1]:port",
      ),
      #("\"127.0.0.1:http\"", "daemon.bind port \"http\" is not a number"),
      #("\"127.0.0.1:65536\"", "daemon.bind port 65536 is outside 0..65535"),
      #(
        "4100",
        "daemon.bind must be a string such as \"127.0.0.1:4100\" or \"[::1]:4100\"",
      ),
    ],
    fn(fixture) {
      let #(value, expected) = fixture
      let text = "[daemon]\nbind = " <> value <> "\n"
      assert limits.parse(text) == Error(expected)
      assert catalog.parse(text) == Error(expected)
    },
  )
}

// The file names the address when no flag does, and an explicit `--bind`
// outranks the file even when the flag repeats the built-in default.
pub fn startup_binds_the_file_address_unless_the_flag_names_one_test() {
  list.each(
    [
      #([], listen_address.Address("::1", 4100), entrypoint.BindFile),
      #(
        ["--bind", "127.0.0.1:0"],
        listen_address.Address("127.0.0.1", 0),
        entrypoint.BindFlag,
      ),
    ],
    fn(fixture) {
      let #(flags, expected, source) = fixture
      let path =
        "build/test_db/daemon-bind-"
        <> bit_array.base16_encode(token.production_entropy()(8))
      let assert Ok(Nil) = bootstrap.ensure_private_directory(path)
        as "fixture directory exists"
      let selected = path <> "/bind.toml"
      assert simplifile.write(selected, "[daemon]\nbind = \"[::1]:4100\"\n")
        == Ok(Nil)
      let assert Ok(config) =
        entrypoint.parse(list.append(
          ["--state-dir", path <> "/state", "--config", selected],
          flags,
        ))
        as "flag parsing does not read the file"
      let assert Ok(#(resolved, daemon)) =
        entrypoint.prepare_startup(config, log.discard())
        as "startup captures the address without opening a session"
      assert listen_address.Address(resolved.bind_host, resolved.bind_port)
        == expected
      assert resolved.bind_source == source
      assert root.shutdown(daemon, within: 5000) == Ok(Nil)
    },
  )
}

pub fn invalid_bind_setting_refuses_startup_before_state_is_created_test() {
  let path =
    "build/test_db/daemon-invalid-bind-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(Nil) = bootstrap.ensure_private_directory(path)
    as "fixture directory exists"
  let selected = path <> "/invalid.toml"
  assert simplifile.write(selected, "[daemon]\nbind = \"0.0.0.0:9000\"\n")
    == Ok(Nil)
  let assert Ok(config) =
    entrypoint.parse([
      "--state-dir",
      path <> "/state",
      "--bind",
      "127.0.0.1:0",
      "--config",
      selected,
    ])
    as "flag parsing does not read the file"
  let assert Error(reason) = entrypoint.prepare_startup(config, log.discard())
    as "a bad file address refuses startup even when the flag wins"
  assert string.contains(reason, selected <> ": daemon.bind \"0.0.0.0:9000\"")
  assert simplifile.is_directory(path <> "/state") == Ok(False)
}
