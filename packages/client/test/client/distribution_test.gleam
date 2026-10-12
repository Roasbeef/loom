//// Trusted distribution (protocol-change/078): the configuration refusals run
//// in process, and the transport controls boot separate emulators with the
//// production boot flags and real TLS, because a fake handshake would not
//// exercise the verify callback that is the trust boundary.

import client/catalog
import client/daemon/distribution_cli
import client/distribution
import client/internal/ffi_os
import gleam/dict
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import simplifile

const pin = "0000000000000000000000000000000000000000000000000000000000000001"

const other_pin =
  "0000000000000000000000000000000000000000000000000000000000000002"

fn document(extra: String, peers: String) -> String {
  "[distribution]\n"
  <> "node = \"owner@10.0.0.1\"\n"
  <> "ca = \"/etc/loom/ca.pem\"\n"
  <> "certificate = \"/etc/loom/cert.pem\"\n"
  <> "key = \"/etc/loom/key.pem\"\n"
  <> "cookie = \"/home/loom/.erlang.cookie\"\n"
  <> extra
  <> peers
}

fn peer(node: String, sha256: String) -> String {
  "\n[[distribution.peers]]\nnode = \""
  <> node
  <> "\"\nsha256 = \""
  <> sha256
  <> "\"\n"
}

fn refused(text: String, fragment: String) {
  let assert Error(message) = distribution.parse(text)
    as "The configuration must be refused."
  assert string.contains(message, fragment)
}

pub fn absent_table_leaves_distribution_off_test() {
  assert distribution.parse("") == Ok(None)
  assert distribution.from_document(dict.new()) == Ok(None)
}

pub fn valid_table_parses_test() {
  let text =
    document(
      "listen_port = 9100\n",
      peer("executor@10.0.0.2", pin) <> peer("backup@10.0.0.3", other_pin),
    )
  let assert Ok(Some(config)) = distribution.parse(text)
  let rendered = distribution.tls_options(config)
  assert string.contains(rendered, "verify_peer")
  assert string.contains(rendered, "executor@10.0.0.2")
  assert string.contains(rendered, "fail_if_no_peer_cert")
  assert string.contains(rendered, "/etc/loom/ca.pem")
  assert !string.contains(rendered, ".erlang.cookie")
}

pub fn boot_arguments_are_the_tls_flags_test() {
  assert distribution.boot_arguments("/o/opts")
    == [
      "-proto_dist", "inet_tls", "-ssl_dist_optfile", "/o/opts", "-kernel",
      "connect_all", "false",
    ]
  assert distribution.launcher_variable == "LOOM_DISTRIBUTION_OPTFILE"
}

pub fn pin_must_be_32_bytes_of_hex_test() {
  refused(
    document("", peer("executor@10.0.0.2", "00")),
    "distribution.peers.sha256 must be 64 hexadecimal characters",
  )
  refused(
    document("", peer("executor@10.0.0.2", string.repeat("zz", 32))),
    "must be hexadecimal",
  )
}

pub fn duplicate_peers_are_refused_test() {
  refused(
    document(
      "",
      peer("executor@10.0.0.2", pin) <> peer("executor@10.0.0.2", other_pin),
    ),
    "lists a node name twice",
  )
  refused(
    document("", peer("executor@10.0.0.2", pin) <> peer("backup@10.0.0.3", pin)),
    "lists a pin twice",
  )
}

pub fn a_node_cannot_trust_itself_test() {
  refused(
    document("", peer("owner@10.0.0.1", pin)),
    "must not list this node itself",
  )
}

pub fn missing_and_unknown_keys_are_refused_test() {
  let without_key =
    string.replace(
      document("", peer("executor@10.0.0.2", pin)),
      "key = \"/etc/loom/key.pem\"\n",
      "",
    )
  refused(without_key, "distribution.key is required")
  refused(
    document("cookie_file = \"/x\"\n", peer("executor@10.0.0.2", pin)),
    "unknown key `cookie_file` in [distribution]",
  )
  refused(
    document("", peer("executor@10.0.0.2", pin) <> "extra = 1\n"),
    "unknown key `extra` in [[distribution.peers]]",
  )
  refused(document("", ""), "needs at least one [[distribution.peers]]")
}

pub fn names_paths_and_ports_are_bounded_test() {
  refused(
    string.replace(
      document("", peer("executor@10.0.0.2", pin)),
      "owner@10.0.0.1",
      "owner",
    ),
    "distribution.node must be a full node name",
  )
  refused(
    document("", peer("executor", pin)),
    "distribution.peers.node must be a full node name",
  )
  refused(
    string.replace(
      document("", peer("executor@10.0.0.2", pin)),
      "/etc/loom/ca.pem",
      "ca.pem",
    ),
    "distribution.ca must be an absolute path",
  )
  refused(
    document("listen_port = 70000\n", peer("executor@10.0.0.2", pin)),
    "distribution.listen_port must be between 1 and 65535",
  )
  refused(
    document("listen_port = \"9100\"\n", peer("executor@10.0.0.2", pin)),
    "distribution.listen_port must be a whole number",
  )
}

pub fn the_catalogue_parser_refuses_a_bad_table_too_test() {
  let catalogue =
    "[models.one]\ndialect = \"anthropic\"\napi_key_env = \"KEY\"\n"
    <> "model_id = \"m-1\"\ncontext_window = 1000\nmax_output_tokens = 100\n"
    <> "[roles]\nmain = [\"one\"]\n"
  let good = document("", peer("executor@10.0.0.2", pin))
  let assert Ok(_) = catalog.parse(catalogue <> good)
  let assert Error(message) =
    catalog.parse(catalogue <> string.replace(good, "ca =", "cacert ="))
  assert string.contains(message, "cacert")
}

pub fn a_vm_without_the_boot_flags_is_refused_untouched_test() {
  let assert Ok(Some(config)) =
    distribution.parse(document("", peer("executor@10.0.0.2", pin)))
  let assert Error(distribution.UnsafeBoot(_)) =
    distribution.start(config, distribution.NotMember)
    as "A VM booted without the TLS flags must not start distribution."

  // The operator is told how to boot it, not only that it was refused.
  let message =
    distribution.describe(distribution.UnsafeBoot(
      distribution.NotTlsDistribution,
    ))
  assert string.contains(message, "-proto_dist inet_tls")
  assert string.contains(message, "loomd distribution options")
  assert string.contains(message, "LOOM_DISTRIBUTION_OPTFILE")
}

pub fn the_options_command_writes_a_private_file_test() {
  let directory =
    "build/distribution-cli-" <> int.to_string(ffi_os.unique_positive_integer())
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let config = directory <> "/loom.toml"
  let output = directory <> "/dist.options"
  let text = document("", peer("executor@10.0.0.2", pin))
  let assert Ok(Nil) = simplifile.write(config, text)
  let assert Ok(Nil) =
    distribution_cli.write_options(["options", config, output])
  let assert Ok(Some(parsed)) = distribution.parse(text)
  let assert Ok(written) = simplifile.read(output)
  assert written == distribution.tls_options(parsed)
  let assert Ok(info) = simplifile.file_info(output)
  assert int.bitwise_and(info.mode, 0o077) == 0

  // A configuration without the table, and a malformed command line, are
  // refused rather than leaving an options file nobody asked for.
  let assert Ok(Nil) = simplifile.write(config, "")
  let assert Error(message) =
    distribution_cli.write_options(["options", config, directory <> "/none"])
  assert string.contains(message, "has no [distribution] table")
  let assert Error(usage) = distribution_cli.write_options(["options"])
  assert usage == distribution_cli.usage
  let assert Ok(Nil) = simplifile.delete(directory)
}

// --- two real emulators -----------------------------------------------------

@external(erlang, "client_distribution_fixture_ffi", "scenario")
fn scenario(name: String) -> Result(Nil, String)

fn proves(name: String, why: String) {
  let assert Ok(Nil) = scenario(name) as why
  Nil
}

pub fn pinned_peers_connect_and_exchange_a_message_test() {
  proves(
    "connect",
    "Two nodes with correct pins must connect hidden, exchange a message, "
      <> "and keep automatic connection off.",
  )
}

pub fn a_wrong_leaf_pin_is_refused_from_either_side_test() {
  proves(
    "wrong_leaf_server",
    "A client must refuse a server leaf that is not the pinned one.",
  )
  proves(
    "wrong_leaf_client",
    "A server must refuse a client leaf that is not the pinned one.",
  )
}

pub fn a_pin_without_the_node_name_or_the_ca_is_refused_test() {
  proves(
    "wrong_san",
    "A leaf that matches the pin but not the node name must be refused.",
  )
  proves(
    "wrong_ca",
    "A leaf that matches the pin and name but not the CA must be refused.",
  )
}

pub fn a_cookie_mismatch_is_refused_test() {
  proves(
    "wrong_cookie",
    "Right certificates with different cookies must not connect.",
  )
}

pub fn a_send_to_an_unconnected_peer_does_not_connect_test() {
  proves(
    "no_automatic_connection",
    "A message to a configured but unconnected peer must be dropped, not dialed.",
  )
}

pub fn start_refuses_wrong_boots_and_credentials_test() {
  proves(
    "start_refusals",
    "Conflicting flags, a mismatched or writable options file, and bad "
      <> "credential files must each be refused with distribution off.",
  )
}

pub fn start_launches_epmd_when_none_answers_test() {
  proves(
    "start_launches_epmd",
    "A VM booted without a node name starts no epmd itself, so start must "
      <> "launch one and register the node with it.",
  )
}

pub fn start_without_an_epmd_reports_the_port_not_credentials_test() {
  proves(
    "epmd_unavailable",
    "When nothing answers on the epmd port and none can be started, start "
      <> "must report EpmdUnavailable for that port and stay non-distributed.",
  )
  let message = distribution.describe(distribution.EpmdUnavailable(4369))
  assert string.contains(message, "epmd")
  assert string.contains(message, "4369")
  assert string.contains(message, "ERL_EPMD_PORT")
  assert string.contains(message, "ERL_EPMD_ADDRESS")
  assert !string.contains(message, "credential")
}

pub fn a_listen_port_that_is_taken_is_a_start_failure_not_credentials_test() {
  proves(
    "start_failed",
    "When epmd answers but the listen port is taken, start must report "
      <> "StartFailed and stay non-distributed.",
  )
  let message = distribution.describe(distribution.StartFailed)
  assert string.contains(message, "listen_port")
  assert !string.contains(message, "credential")
}

pub fn start_epmd_false_is_honoured_test() {
  proves(
    "start_epmd_false",
    "With -start_epmd false the operator manages epmd, so start must not "
      <> "launch one when none answers.",
  )
}

pub fn directory_members_connect_visibly_from_either_end_test() {
  proves(
    "members_visible",
    "Two directory members connected through the production connect path "
      <> "must both list each other among their visible nodes.",
  )
}

pub fn directory_members_do_not_connect_transitively_test() {
  proves(
    "members_not_transitive",
    "With connect_all off, a member that reaches a second must not be joined "
      <> "to a third that reaches the same second.",
  )
}

pub fn a_member_with_connect_all_on_is_refused_test() {
  proves(
    "member_needs_connect_all_off",
    "A directory member's VM booted with connect_all on must be refused.",
  )
}

pub fn a_member_that_lost_its_disk_rejoins_and_catches_up_test() {
  proves(
    "directory_rejoin",
    "A bootstrapped cluster takes two members in as voters; a member whose "
      <> "directory is deleted while the leader writes past a snapshot rejoins, is promoted, "
      <> "and reads the last write; a cut link is made again; and a member sees "
      <> "the store running on another.",
  )
}
