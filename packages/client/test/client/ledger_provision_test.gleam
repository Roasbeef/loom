//// Provisioning a deployment in ledger mode (protocol-change/086): the signed
//// ledger every bundle carries, the key the operator keeps, and the commands
//// that write both.
////
//// The property that matters is that a ledger changes how a node learns who it
//// may trust and not whom. `every_node_trusts_the_peers_the_plan_gives_it`
//// derives each node's pin table from the ledger in its bundle and compares it
//// with the peer list static provisioning writes for the same certificates.

import client/authority_key
import client/daemon/distribution_cli
import client/distribution
import client/distribution_bundle.{type Bundle}
import client/distribution_install.{Options}
import client/distribution_plan.{type Plan, Executor, Orchestrator, TomlPlan}
import client/distribution_provision.{type Provisioned, ReplaceExisting}
import client/internal/ffi_os
import client/internal/ffi_pki
import client/membership_entry.{NotInDirectory, Voter}
import client/membership_ledger
import client/membership_provision
import client/membership_signing
import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import host/bootstrap
import simplifile
import tom

fn scratch(label: String) -> String {
  let directory =
    "build/ledger-provision-"
    <> label
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let assert Ok(absolute) = bootstrap.absolute_path(directory)
  absolute
}

fn discard(directory: String) {
  let assert Ok(Nil) = simplifile.delete(directory)
  Nil
}

fn mode_of(path: String) -> Int {
  let assert Ok(info) = simplifile.file_info(path)
  int.bitwise_and(info.mode, 0o777)
}

// Two orchestrators and two executors, as the static provisioning tests use:
// `laptop` uses both executors and `desk` uses one, so the edges are not a
// single star.
const plan_text =
  "[[node]]
name = \"laptop\"
role = \"orchestrator\"
erlang_node = \"loom@laptop.example\"
host = \"laptop.example\"
listen_port = 4370
executors = [\"devbox\", \"buildbox\"]

[[node]]
name = \"desk\"
role = \"orchestrator\"
erlang_node = \"loom@desk.example\"
executors = [\"buildbox\"]

[[node]]
name = \"devbox\"
role = \"executor\"
erlang_node = \"loom@devbox.example\"
host = \"devbox.example\"
listen_port = 4371
[node.workspaces]
repo = \"/home/me/src/loom\"

[[node]]
name = \"buildbox\"
role = \"executor\"
erlang_node = \"loom@buildbox.example\"
[node.workspaces]
\"my repo\" = \"/srv/my repo\"
"

const directory_text = "directory = [\"laptop\", \"desk\", \"devbox\"]\n\n"

fn plan_of(text: String) -> Plan {
  let assert Ok(plan) = distribution_plan.parse(text, TomlPlan)
  plan
}

fn provisioned(plan: Plan) -> Provisioned {
  let assert Ok(made) =
    distribution_provision.provision_ledger(
      plan,
      timestamp.from_unix_seconds(1_760_000_000),
    )
  made
}

fn bundle_named(made: Provisioned, name: String) -> Bundle {
  let assert Ok(bundle) =
    list.find(made.deployment.bundles, fn(bundle) { bundle.name == name })
  bundle
}

fn ledger_lines(bundle: Bundle) -> List(String) {
  let assert distribution_bundle.SignedLedger(lines) = bundle.trust
    as "A ledger deployment's bundles carry the ledger."
  lines
}

// The ledger a bundle carries, replayed with a verifier built from the
// bundle's own CA, as `decode` and a booting node do.
fn replayed(bundle: Bundle) -> membership_ledger.Ledger {
  let assert Ok(verify) = membership_signing.verifier(bundle.ca)
  let assert Ok(ledger) =
    membership_ledger.replay(
      list.map(ledger_lines(bundle), bit_array.from_string),
      verify,
    )
  ledger
}

// The pin of every node, read from `system.json` and not from the code under
// test, so the equivalence check does not trust the pins it compares.
fn pins_of(made: Provisioned, plan: Plan) -> List(membership_provision.Pinned) {
  list.map(plan.nodes, fn(node) {
    let assert Ok(system) =
      list.find(made.deployment.system.nodes, fn(found) {
        found.name == node.name
      })
    let assert Ok(pin) = bit_array.base16_decode(system.pin)
    membership_provision.Pinned(node:, pin:)
  })
}

// --- the ledger -------------------------------------------------------------

pub fn a_ledger_time_is_utc_to_the_second_test() {
  assert membership_provision.time_text(timestamp.from_unix_seconds(0))
    == "1970-01-01T00:00:00Z"
  assert membership_provision.time_text(
      timestamp.from_unix_seconds_and_nanoseconds(1_760_000_000, 987_654_321),
    )
    == "2025-10-09T08:53:20Z"
}

pub fn the_ledger_starts_at_genesis_and_names_every_node_test() {
  let plan = plan_of(plan_text)
  let made = provisioned(plan)
  let laptop = bundle_named(made, "laptop")
  let ledger = replayed(laptop)
  let lines = ledger_lines(laptop)

  // One genesis and one member entry per node, newest last.
  assert list.length(lines) == 5
  assert membership_ledger.head(ledger).seq == 4
  assert list.map(membership_ledger.members(ledger), fn(member) { member.name })
    == ["buildbox", "desk", "devbox", "laptop"]

  // The genesis names this deployment and this authority.
  let assert Ok(authority) = membership_signing.authority_pin(laptop.ca)
  assert membership_ledger.authority(ledger) == authority
  assert membership_ledger.deployment(ledger) == made.authority.deployment
  assert string.length(made.authority.deployment) == 32
  assert made.authority.deployment
    == string.lowercase(made.authority.deployment)
  assert made.authority.certificate == laptop.ca
  assert result.is_ok(membership_signing.signer(made.authority.key))

  // Every bundle carries the same file, and the file is the lines with a
  // newline after each.
  assert list.all(made.deployment.bundles, fn(bundle) {
    ledger_lines(bundle) == lines
  })
  assert made.deployment.ledger == Some(string.join(lines, "\n") <> "\n")
}

pub fn the_member_entries_carry_the_plan_test() {
  let made = provisioned(plan_of(plan_text))
  let ledger = replayed(bundle_named(made, "laptop"))
  let assert Ok(devbox) = membership_ledger.member(ledger, "devbox")
  assert devbox.node == "loom@devbox.example"
  assert devbox.host == "devbox.example"
  assert devbox.listen_port == Some(4371)
  assert devbox.role == Executor
  let assert Ok(desk) = membership_ledger.member(ledger, "desk")
  assert desk.listen_port == None
  assert desk.role == Orchestrator
  let assert Ok(nodes) =
    list.try_map(made.deployment.system.nodes, fn(node) {
      let assert Ok(member) = membership_ledger.member(ledger, node.name)
      bit_array.base16_decode(node.pin)
      |> result.map(fn(pin) { member.pin == pin })
    })
  assert list.all(nodes, fn(same) { same })
}

pub fn a_node_outside_the_directory_defaults_to_none_test() {
  let made = provisioned(plan_of(plan_text))
  let ledger = replayed(bundle_named(made, "desk"))
  assert list.all(membership_ledger.members(ledger), fn(member) {
    member.directory == NotInDirectory
  })
}

pub fn the_plans_directory_members_are_voters_test() {
  let made = provisioned(plan_of(directory_text <> plan_text))
  let ledger = replayed(bundle_named(made, "buildbox"))
  let standing = fn(name) {
    let assert Ok(member) = membership_ledger.member(ledger, name)
    member.directory
  }
  assert standing("laptop") == Voter
  assert standing("desk") == Voter
  assert standing("devbox") == Voter
  assert standing("buildbox") == NotInDirectory
}

// --- the equivalence ---------------------------------------------------------

// The reason a deployment can move to a ledger without anyone deciding who
// trusts whom again: the pin table of every node equals the peer list static
// provisioning writes for it from the same certificates.
fn assert_tables_equal_the_static_peers(made: Provisioned, plan: Plan) {
  let pinned = pins_of(made, plan)
  list.each(pinned, fn(entry) {
    let table =
      membership_ledger.pin_table(
        replayed(bundle_named(made, entry.node.name)),
        entry.node.name,
      )
    let from_ledger =
      membership_ledger.peers(table)
      |> list.map(fn(peer) {
        let assert Ok(pin) = membership_ledger.lookup_node(table, peer.node)
        distribution.PeerPin(node: peer.node, sha256: pin)
      })
    let from_plan = distribution_provision.peer_pins(plan, entry.node, pinned)
    assert sorted(from_ledger) == sorted(from_plan)
    assert from_plan != [] as "Every node of these plans has a peer."
  })
}

fn sorted(peers: List(distribution.PeerPin)) -> List(distribution.PeerPin) {
  list.sort(peers, fn(a, b) { string.compare(a.node, b.node) })
}

pub fn every_node_trusts_the_peers_the_plan_gives_it_test() {
  let plan = plan_of(plan_text)
  assert_tables_equal_the_static_peers(provisioned(plan), plan)
}

pub fn the_directory_edges_are_the_same_as_the_static_ones_test() {
  let plan = plan_of(directory_text <> plan_text)
  assert_tables_equal_the_static_peers(provisioned(plan), plan)
}

pub fn a_pin_table_does_not_hold_a_node_the_plan_does_not_link_test() {
  // desk does not use devbox and neither is in a directory, so neither trusts
  // the other. A ledger that linked them would be a wider deployment than the
  // plan.
  let made = provisioned(plan_of(plan_text))
  let desk = bundle_named(made, "desk")
  let table = membership_ledger.pin_table(replayed(desk), "desk")
  assert membership_ledger.lookup_node(table, "loom@devbox.example")
    == Error(Nil)
}

// --- the bundle --------------------------------------------------------------

pub fn a_ledger_bundle_round_trips_and_states_its_format_test() {
  let made = provisioned(plan_of(plan_text))
  list.each(made.deployment.bundles, fn(bundle) {
    let text = distribution_bundle.encode(bundle)
    assert string.contains(text, "\"format\":\"loom-distribution-bundle/2\"")
    assert string.contains(text, "\"ledger\":[")
    assert !string.contains(text, "\"peers\"")
    assert distribution_bundle.decode(text) == Ok(bundle)
  })
}

fn refused_bundle(bundle: Bundle, fragment: String) {
  let assert Error(reason) =
    distribution_bundle.decode(distribution_bundle.encode(bundle))
    as "The bundle must be refused."
  assert string.contains(reason, fragment)
}

pub fn a_bundle_whose_ledger_was_changed_is_refused_test() {
  let made = provisioned(plan_of(plan_text))
  let laptop = bundle_named(made, "laptop")
  let lines = ledger_lines(laptop)

  // One character of the last member entry.
  let assert [last, ..before] = list.reverse(lines)
  let flipped = case string.first(last) {
    Ok("e") -> "f" <> string.drop_start(last, 1)
    _ -> "e" <> string.drop_start(last, 1)
  }
  refused_bundle(
    distribution_bundle.Bundle(
      ..laptop,
      trust: distribution_bundle.SignedLedger(list.reverse([flipped, ..before])),
    ),
    "bundle ledger line 5 is refused at step",
  )

  // Entries missing, swapped, or from the end of another deployment.
  let assert [genesis, first, ..] = lines
  refused_bundle(
    distribution_bundle.Bundle(
      ..laptop,
      trust: distribution_bundle.SignedLedger([genesis]),
    ),
    "does not enroll laptop",
  )

  // The laptop is enrolled first, so a ledger that stops there lists none of
  // the executors the bundle says it uses.
  refused_bundle(
    distribution_bundle.Bundle(
      ..laptop,
      trust: distribution_bundle.SignedLedger([genesis, first]),
    ),
    "which is not one of its peers",
  )
  refused_bundle(
    distribution_bundle.Bundle(
      ..laptop,
      trust: distribution_bundle.SignedLedger([first, genesis]),
    ),
    "bundle ledger line 1 is refused",
  )
  refused_bundle(
    distribution_bundle.Bundle(
      ..laptop,
      trust: distribution_bundle.SignedLedger([]),
    ),
    "bundle ledger line 1 is refused",
  )
}

pub fn a_ledger_signed_by_another_authority_is_refused_test() {
  let made = provisioned(plan_of(plan_text))
  let other = provisioned(plan_of(plan_text))
  let laptop = bundle_named(made, "laptop")

  // Another deployment's lines under this deployment's CA fail their
  // signatures, and this deployment's lines under another CA do too.
  refused_bundle(
    distribution_bundle.Bundle(
      ..laptop,
      trust: distribution_bundle.SignedLedger(
        ledger_lines(bundle_named(other, "laptop")),
      ),
    ),
    "step bad_signature",
  )
  refused_bundle(
    distribution_bundle.Bundle(..laptop, ca: other.authority.certificate),
    "step bad_signature",
  )
}

pub fn a_ledger_that_names_another_certificate_is_refused_test() {
  let made = provisioned(plan_of(plan_text))
  let laptop = bundle_named(made, "laptop")
  let desk = bundle_named(made, "desk")

  // The laptop's credentials under the desk's name, and the desk's
  // credentials under the laptop's: each entry carries the other pin.
  refused_bundle(
    distribution_bundle.Bundle(
      ..laptop,
      certificate: desk.certificate,
      key: desk.key,
    ),
    "does not match the bundle's role, node name and certificate",
  )
  refused_bundle(
    distribution_bundle.Bundle(..laptop, name: "desk", executors: []),
    "does not match the bundle's role, node name and certificate",
  )
}

pub fn a_ledger_bundle_cannot_list_peers_and_a_peer_bundle_cannot_carry_a_ledger_test() {
  let made = provisioned(plan_of(plan_text))
  let text = distribution_bundle.encode(bundle_named(made, "laptop"))

  // Both ways of saying who is trusted, in either marker.
  let with_peers =
    string.replace(text, "\"ledger\":[", "\"peers\":[],\"ledger\":[")
  let assert Error(reason) = distribution_bundle.decode(with_peers)
  assert string.contains(reason, "unknown key `peers`")

  let static = distribution_provision.provision(plan_of(plan_text))
  let assert Ok(static) = static
  let assert Ok(devbox) =
    list.find(static.bundles, fn(bundle) { bundle.name == "devbox" })
  let static_text = distribution_bundle.encode(devbox)
  let assert Error(reason) =
    distribution_bundle.decode(string.replace(
      static_text,
      "\"peers\":[",
      "\"ledger\":[],\"peers\":[",
    ))
  assert string.contains(reason, "unknown key `ledger`")

  // The key that goes with the marker is required.
  let assert Error(reason) =
    distribution_bundle.decode(string.replace(
      text,
      "\"ledger\":[",
      "\"lines\":[",
    ))
  assert string.contains(reason, "unknown key `lines`")
}

pub fn a_static_deployment_is_unchanged_test() {
  let assert Ok(static) = distribution_provision.provision(plan_of(plan_text))
  assert static.ledger == None
  list.each(static.bundles, fn(bundle) {
    let text = distribution_bundle.encode(bundle)
    assert string.contains(text, "\"format\":\"loom-distribution-bundle/1\"")
    assert string.contains(text, "\"peers\":[")
    assert !string.contains(text, "ledger")
    assert distribution_bundle.decode(text) == Ok(bundle)
  })
}

pub fn a_ledger_bundle_writes_a_ledger_key_and_no_peers_test() {
  let made = provisioned(plan_of(plan_text))
  let laptop = bundle_named(made, "laptop")
  let files =
    distribution.CredentialFiles(
      ca: "/home/me/.loom/distribution/ca.pem",
      certificate: "/home/me/.loom/distribution/cert.pem",
      key: "/home/me/.loom/distribution/key.pem",
      cookie: "/home/me/.erlang.cookie",
    )
  assert distribution_bundle.ledger_path(files)
    == "/home/me/.loom/distribution/ledger.log"
  let text = distribution_bundle.config_text(laptop, files)
  assert !string.contains(text, "peers")
  let assert Ok(document) = tom.parse(text)
  let assert Ok(table) = tom.get_table(document, ["distribution"])
  assert tom.get_string(table, ["ledger"])
    == Ok("/home/me/.loom/distribution/ledger.log")
  assert tom.get_string(table, ["node"]) == Ok("loom@laptop.example")
  assert dict.has_key(table, "peers") == False
}

// --- the plan limits ---------------------------------------------------------

pub fn a_plan_that_breaks_a_rule_of_the_ledger_is_refused_by_name_test() {
  // Sixty-five nodes are one more than a ledger may have active. The plan
  // rules allow it, so the refusal comes from the pre-flight and names the
  // node and the step.
  let executors =
    list.index_map(list.repeat(Nil, 64), fn(_, index) {
      "e" <> int.to_string(index + 1)
    })
  let node = fn(name, role, used) {
    distribution_plan.Node(
      name:,
      role:,
      erlang_node: "loom@" <> name <> ".example",
      host: name <> ".example",
      listen_port: None,
      bundle_dir: None,
      executors: used,
      workspaces: [],
    )
  }
  let plan =
    distribution_plan.Plan(
      nodes: [
        node("hub", Orchestrator, executors),
        ..list.map(executors, fn(name) { node(name, Executor, []) })
      ],
      directory: [],
    )
  let assert Error(reason) =
    distribution_provision.provision_ledger(
      plan,
      timestamp.from_unix_seconds(1_760_000_000),
    )
  assert reason == "e64 breaks a rule of the ledger at step invalid"
}

// --- the commands ------------------------------------------------------------

fn write_plan(base: String) -> String {
  let path = base <> "/plan.toml"
  let assert Ok(Nil) = simplifile.write(path, plan_text)
  path
}

fn write_passphrase(base: String, text: String) -> String {
  let path = base <> "/passphrase"
  let assert Ok(Nil) = simplifile.write(path, text)
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o600)
  path
}

pub fn provision_seals_the_key_and_writes_the_ledger_by_default_test() {
  let base = scratch("command")
  let plan = write_plan(base)
  let passphrase = write_passphrase(base, "correct horse battery\n")
  let assert Ok(report) =
    distribution_cli.run([
      "provision",
      plan,
      base <> "/out",
      "--passphrase-file",
      passphrase,
      "--home",
      base <> "/home",
    ])
  assert string.contains(report, base <> "/out/ledger.log")
  assert string.contains(report, "The authority key is sealed in")
  assert !string.contains(report, "correct horse")
  assert !string.contains(report, "PRIVATE KEY")

  // The ledger file, the bundles and the system description.
  let assert Ok(file) = simplifile.read(base <> "/out/ledger.log")
  assert string.ends_with(file, "\n")
  assert list.length(string.split(string.trim_end(file), "\n")) == 5
  assert mode_of(base <> "/out/ledger.log") == 0o600
  let assert Ok(text) = simplifile.read(base <> "/out/laptop.loombundle")
  let assert Ok(bundle) = distribution_bundle.decode(text)
  assert string.join(ledger_lines(bundle), "\n") <> "\n" == file

  // The key is where the report says, under the deployment's id, and opens
  // only with the passphrase.
  let ledger = replayed(bundle)
  let id = membership_ledger.deployment(ledger)
  let directory = authority_key.default_directory(base <> "/home", id)
  assert authority_key.is_kept(directory)
  assert mode_of(directory) == 0o700
  assert mode_of(directory <> "/key.enc") == 0o600
  assert simplifile.read(directory <> "/ledger.log") == Ok(file)
  assert simplifile.read(directory <> "/ca.pem") == Ok(bundle.ca)

  // The cookie is kept beside the key, because the bundle of every node
  // enrolled later carries the same one.
  assert mode_of(directory <> "/cookie") == 0o600
  assert authority_key.cookie(directory) == Ok(bundle.cookie)
  let assert Ok(good) = authority_key.passphrase("correct horse battery")
  let assert Ok(wrong) = authority_key.passphrase("correct horse batterz")
  assert authority_key.load(directory, id, wrong)
    == Error(authority_key.Rejected)

  // The unsealed key signs for the CA in every bundle, which is what `enroll`
  // will rely on.
  let assert Ok(sign) = authority_key.signer(directory, id, good)
  let assert Ok(signature) = sign(<<"probe":utf8>>)
  assert ffi_pki.verify(bundle.ca, <<"probe":utf8>>, signature) == Ok(Nil)
  discard(base)
}

pub fn dropping_the_authority_keeps_no_key_test() {
  let base = scratch("dropped")
  let plan = write_plan(base)
  let assert Ok(report) =
    distribution_cli.run([
      "provision",
      plan,
      base <> "/out",
      "--drop-authority",
      "--home",
      base <> "/home",
    ])
  assert string.contains(report, "This ledger can never be extended.")
  assert simplifile.is_directory(base <> "/home") == Ok(False)
  assert simplifile.is_file(base <> "/out/ledger.log") == Ok(True)
  let assert Ok(text) = simplifile.read(base <> "/out/devbox.loombundle")
  assert result.is_ok(distribution_bundle.decode(text))
  discard(base)
}

pub fn the_ledger_flags_only_mean_something_together_test() {
  let base = scratch("flags")
  let plan = write_plan(base)
  let passphrase = write_passphrase(base, "correct horse battery\n")
  let refused = fn(arguments, fragment) {
    let assert Error(reason) =
      distribution_cli.run(list.append(
        ["provision", plan, base <> "/out"],
        arguments,
      ))
    assert string.contains(reason, fragment)
  }
  refused(
    ["--static", "--drop-authority"],
    "--drop-authority cannot be combined with --static",
  )
  refused(
    ["--static", "--passphrase-file", passphrase],
    "--passphrase-file cannot be combined with --static",
  )
  refused(
    ["--drop-authority", "--passphrase-file", passphrase],
    "cannot be combined",
  )
  refused(["--passphrase-file"], "needs a value")

  // Static mode keeps no key, so a home directory has nothing to hold.
  refused(
    ["--static", "--home", base <> "/home"],
    "--home cannot be combined with --static",
  )

  // The flags belong to provision and no other command takes them.
  let assert Error(reason) =
    distribution_cli.run(["install", base <> "/node.loombundle", "--static"])
  assert string.contains(reason, "belong to provision")
  assert simplifile.is_directory(base <> "/out") == Ok(False)
  discard(base)
}

// A passphrase that is refused, or an output directory that is not empty,
// stops the command before a key exists or a file is written.
pub fn a_refusal_leaves_no_key_and_no_bundle_test() {
  let base = scratch("refused")
  let plan = write_plan(base)
  let short = write_passphrase(base, "short\n")
  let assert Error(reason) =
    distribution_cli.run([
      "provision",
      plan,
      base <> "/out",
      "--passphrase-file",
      short,
      "--home",
      base <> "/home",
    ])
  assert string.contains(reason, "at least 12 bytes")
  assert simplifile.is_directory(base <> "/out") == Ok(False)
  assert simplifile.is_directory(base <> "/home") == Ok(False)

  let good = write_passphrase(base, "correct horse battery\n")
  let assert Ok(Nil) = simplifile.create_directory_all(base <> "/out")
  let assert Ok(Nil) = simplifile.write(base <> "/out/stale", "x")
  let assert Error(reason) =
    distribution_cli.run([
      "provision",
      plan,
      base <> "/out",
      "--passphrase-file",
      good,
      "--home",
      base <> "/home",
    ])
  assert string.contains(reason, "is not empty")
  assert simplifile.is_directory(base <> "/home") == Ok(False)

  // A passphrase file anyone can read is not used.
  let readable = write_passphrase(base, "correct horse battery\n")
  let assert Ok(Nil) = simplifile.set_permissions_octal(readable, 0o644)
  let assert Error(reason) =
    distribution_cli.run([
      "provision",
      plan,
      base <> "/fresh",
      "--passphrase-file",
      readable,
      "--home",
      base <> "/home",
    ])
  assert string.contains(reason, "accessible to other users")
  assert simplifile.is_directory(base <> "/home") == Ok(False)
  discard(base)
}

pub fn the_static_command_is_unchanged_test() {
  let base = scratch("static")
  let plan = write_plan(base)
  let assert Ok(report) =
    distribution_cli.run(["provision", plan, base <> "/out", "--static"])
  assert string.contains(report, "The CA key was discarded.")
  assert simplifile.is_file(base <> "/out/ledger.log") == Ok(False)
  let assert Ok(text) = simplifile.read(base <> "/out/laptop.loombundle")
  let assert Ok(bundle) = distribution_bundle.decode(text)
  let assert distribution_bundle.StaticPeers([_, ..]) = bundle.trust

  // A static bundle installs, as before.
  let assert Ok(_) =
    distribution_install.install(
      text,
      Options(
        home: base <> "/home",
        config: base <> "/home/.loom/loom.toml",
        overwrite: ReplaceExisting,
      ),
    )
  discard(base)
}

// A plan with a session directory is provisioned in ledger mode like any other
// (protocol-change/086, phase 3). The directory members become voters in the
// ledger, and their bundles list no directory: the ledger is the only source.
pub fn a_plan_with_a_directory_is_provisioned_with_a_ledger_test() {
  let base = scratch("directory")
  let plan_path = base <> "/plan.toml"
  let assert Ok(Nil) = simplifile.write(plan_path, directory_text <> plan_text)
  let passphrase = write_passphrase(base, "correct horse battery\n")
  let assert Ok(_) =
    distribution_cli.run([
      "provision",
      plan_path,
      base <> "/out",
      "--passphrase-file",
      passphrase,
      "--home",
      base <> "/home",
    ])
  let assert Ok(text) = simplifile.read(base <> "/out/laptop.loombundle")
  let assert Ok(bundle) = distribution_bundle.decode(text)
  let assert distribution_bundle.SignedLedger(_) = bundle.trust
  assert bundle.directory == []

  // The bundle installs, and the configuration it writes has no [directory]
  // table: the daemon derives the members from the ledger.
  let assert Ok(_) =
    distribution_install.install(
      text,
      Options(
        home: base <> "/home",
        config: base <> "/home/.loom/loom.toml",
        overwrite: ReplaceExisting,
      ),
    )
  let assert Ok(config) = simplifile.read(base <> "/home/.loom/loom.toml")
  assert !string.contains(config, "[directory]")
  assert string.contains(config, "ledger =")

  // Static provisioning of the same plan is what it always was.
  let assert Ok(_) =
    distribution_cli.run([
      "provision",
      plan_path,
      base <> "/static",
      "--static",
    ])
  let assert Ok(static_text) =
    simplifile.read(base <> "/static/laptop.loombundle")
  let assert Ok(static_bundle) = distribution_bundle.decode(static_text)
  assert static_bundle.directory != []
  discard(base)
}

// A hand-written ledger bundle that also lists the members is refused, so the
// two lists can never disagree.
pub fn a_ledger_bundle_cannot_list_the_directory_beside_its_ledger_test() {
  let made = provisioned(plan_of(directory_text <> plan_text))
  refused_bundle(
    distribution_bundle.Bundle(..bundle_named(made, "laptop"), directory: [
      "loom@laptop.example",
    ]),
    "ledger bundle cannot list the directory",
  )
}
