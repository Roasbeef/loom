//// The top-level relay against a shipped daemon over pinned TLS distribution.
//// The probe is a separate VM and uses the production relay; the target's own
//// spawner table judges the node attributed to the reply subject before it may
//// obtain offers. The legacy request verifies the retained 094 port as well.

import client/tui_e2e_test.{type EunitTest}
import gleam/string
import simplifile
import support/remote_daemons.{Trust}
import support/remote_duo

pub fn the_shipped_endpoint_serves_only_configured_spawners_test_() -> EunitTest {
  remote_duo.shipped("shipped remote top", fn(duo) {
    let keys = remote_duo.provision(duo)
    let config =
      string.join(
        [
          remote_daemons.model_table("http://127.0.0.1:9"),
          remote_daemons.distribution_table(keys.bravo, keys.authority, [
            Trust(keys.alpha.node, keys.alpha.pin),
            Trust(keys.executor.node, keys.executor.pin),
          ]),
          "[profiles.kid.roles]\nmain = [\"fixture\"]\n",
          "[spawners.probe]\nnode = \""
            <> keys.alpha.node
            <> "\"\ndirectory = \""
            <> duo.directory
            <> "\"\nprofile = \"kid\"\n",
          "[spawners.probe.top_level]\nprofiles = [\"kid\"]\n",
        ],
        "\n",
      )
    let assert Ok(Nil) = simplifile.write(duo.bravo.config, config)
      as "the target's configured spawner is written"
    remote_daemons.write_options(duo.bravo)
    let _running = remote_daemons.start(duo.bravo)
    let allowed =
      remote_daemons.probe(
        duo.bravo.launcher,
        duo.directory,
        "allowed",
        keys.alpha,
        keys.authority,
        [Trust(keys.bravo.node, keys.bravo.pin)],
      )
    let denied =
      remote_daemons.probe(
        duo.bravo.launcher,
        duo.directory,
        "denied",
        keys.executor,
        keys.authority,
        [Trust(keys.bravo.node, keys.bravo.pin)],
      )
    let target = keys.bravo.node
    let answers =
      remote_daemons.run_probe(allowed, duo.directory, [
        "placements " <> target,
        "legacy " <> target,
      ])
    assert answers
      == [
        "RESULT placements " <> target <> " profiles=kid models=fixture",
        "RESULT legacy " <> target <> " profiles=kid models=fixture",
      ]
    let refused =
      remote_daemons.run_probe(denied, duo.directory, [
        "placements " <> target,
      ])
    assert refused == ["RESULT placements " <> target <> " unknown-spawner"]
  })
}
