//// Exercises the production startup and Ready publication boundaries in one
//// isolated TLS emulator, switching aliases only after startup has read them.

import client/daemon/main
import client/daemon/root
import gleam/bytes_tree
import gleam/http/response
import gleam/option.{None, Some}
import host/endpoint
import host/launch_metadata
import mist
import simplifile
import telemetry/log

pub fn run(
  state: String,
  config_alias: String,
  config_target: String,
  options_alias: String,
  options_target: String,
  replacement: String,
) -> Nil {
  let assert Ok(config) =
    main.parse(["--state-dir", state, "--config", config_alias])
    as "the fixture uses production daemon flags"
  let assert Ok(#(config, paths, fence)) = main.claim_endpoint(config)
    as "the isolated VM claims its own native reservation"
  let assert Ok(#(config, daemon)) = main.prepare_startup(config, log.discard())
    as "startup must consume the original TLS settings"
  let assert Some(#(Some(source), launch_metadata.Tls(options))) =
    config.launch_setting
    as "the launch must be representable before the alias switches"
  assert source == config_target
  assert options == options_target

  // The switch happens after production startup has captured and read both
  // settings, and before it publishes Ready; no clock or sleep orders it.
  let assert Ok(Nil) = simplifile.delete(config_alias)
  let assert Ok(Nil) = simplifile.create_symlink(replacement, config_alias)
  let assert Ok(Nil) = simplifile.delete(options_alias)
  let assert Ok(Nil) = simplifile.create_symlink(replacement, options_alias)
  let assert Ok(serving) =
    main.listen(config, daemon, fn(_, _) {
      response.new(501)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("unused")))
    })
    as "the real daemon listener is ready for publication"
  let assert Ok(Nil) = main.publish_endpoint(config, serving, paths, fence)
    as "a changed alias must not block serving"
  let assert Ok(Some(endpoint.Ready(ready_fence, _, _, epoch, _))) =
    endpoint.load(paths)
    as "the same native reservation publishes the real Ready epoch"
  assert ready_fence == fence
  assert epoch == serving.ready.epoch
  assert launch_metadata.load(paths) == Ok(None)
  let assert Ok(Nil) = root.shutdown(daemon, within: 5000)
    as "the isolated root shuts down cleanly"
  Nil
}
