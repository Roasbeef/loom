//// The files a jailed tool must not read, from the executor's configuration.
////
//// An executor reached over the untrusted link (protocol-change/109) has no
//// `[distribution]` table, so its identity is the private key of its
//// `[executor_listener]`. Model code runs as the same user as the daemon, so
//// the key must be masked from every jail the executor starts. These tests
//// pin the list `executor_plane.machine` hands the jails; the live check in
//// `daemon_shipped_microvm_test` reads the key from a real jail and fails.

import client/executor_plane
import client/serve
import gleam/option.{None, Some}
import simplifile
import support/remote_fixtures as fixtures

const listener =
  "[executor_listener]
listen = \"0.0.0.0:4370\"
ca = \"/srv/loom-node/creds/ca.pem\"
certificate = \"/srv/loom-node/creds/cert.pem\"
key = \"/srv/loom-node/creds/key.pem\"
orchestrators = [\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"]
"

const link =
  "[executor_link]
ca = \"/vm/link/ca.pem\"
certificate = \"/vm/link/orchestrator.pem\"
key = \"/vm/link/orchestrator.key\"
"

const node =
  "[distribution]
node = \"owner@10.0.0.1\"
ca = \"/etc/loom/ca.pem\"
certificate = \"/etc/loom/cert.pem\"
key = \"/etc/loom/key.pem\"
cookie = \"/home/loom/.erlang.cookie\"
ledger = \"/var/loom/ledger.log\"
"

pub fn a_listeners_key_is_masked_from_the_jails_like_a_nodes_test() {
  // The guest has no `[distribution]`, so the listener's key is the one secret
  // there is. The certificates are public and stay readable.
  assert executor_plane.masked_files(listener)
    == Ok(["/srv/loom-node/creds/key.pem"])
}

pub fn a_distribution_node_still_masks_its_key_and_cookie_test() {
  assert executor_plane.masked_files(node)
    == Ok(["/etc/loom/key.pem", "/home/loom/.erlang.cookie"])
  assert executor_plane.masked_files("") == Ok([])
}

pub fn an_orchestrators_link_key_is_masked_too_test() {
  assert executor_plane.masked_files(link) == Ok(["/vm/link/orchestrator.key"])
}

pub fn a_configuration_the_daemon_would_refuse_masks_nothing_and_says_why_test() {
  // Both tables together are refused by the daemon's own reader, and the mask
  // reports that instead of guessing which files to hide.
  let assert Error(_) = executor_plane.masked_files(node <> listener)
}

pub fn a_sessions_jail_masks_the_link_keys_its_configuration_names_test() {
  // A `LOOM_VM_HOME` outside `~/.loom/vm` is not covered by the directory mask,
  // so the orchestrator's key must be masked by name in every session's jail.
  let directory = fixtures.scratch("link-secrets")
  let path = directory <> "/loom.toml"
  let assert Ok(Nil) = simplifile.write(path, link <> listener)
    as "the configuration is written"
  assert serve.link_secrets(Some(path))
    == ["/vm/link/orchestrator.key", "/srv/loom-node/creds/key.pem"]
  assert serve.link_secrets(None) == []
  assert serve.link_secrets(Some(directory <> "/absent.toml")) == []
}
