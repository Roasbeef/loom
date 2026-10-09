//// Provisioning and installing a distribution deployment: the plan, the
//// bundles, the installer, the commands, and the proof that matters, two real
//// emulators connected over TLS with the files `install` wrote.
////
//// Every certificate under test is minted by the production code, and the
//// facts about it (its pin, its names) are recomputed with OTP's `public_key`
//// directly in the fixture, so a test does not trust the code it checks.

import client
import client/catalog
import client/daemon/distribution_cli
import client/directory/settings as directory_settings
import client/distribution
import client/distribution_bundle
import client/distribution_install.{Options}
import client/distribution_plan.{
  Executor, JsonPlan, Orchestrator, TomlPlan, Workspace,
}
import client/distribution_provision.{RefuseExisting, ReplaceExisting}
import client/executors
import client/internal/ffi_os
import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import tom

// --- fixtures ----------------------------------------------------------------

@external(erlang, "client_distribution_fixture_ffi", "certificate_facts")
fn certificate_facts(pem: String) -> #(BitArray, List(String))

@external(erlang, "client_distribution_fixture_ffi", "free_port")
fn free_port() -> Int

type Mode {
  Accept
  Refuse
}

@external(erlang, "client_distribution_fixture_ffi", "installed")
fn run_installed(
  orchestrator: #(String, String, String),
  executor: #(String, String, String),
  peer: #(String, Int),
  mode: Mode,
) -> Result(Nil, String)

fn scratch(label: String) -> String {
  let directory =
    "build/provision-"
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

// Four nodes: two orchestrators and two executors. `laptop` uses both
// executors and `desk` uses one, so the edges are not a single star. The
// workspace name with a space exercises quoting in the generated tables.
fn plan_toml(base: String) -> String {
  "[[node]]
name = \"laptop\"
role = \"orchestrator\"
erlang_node = \"loom@laptop.example\"
host = \"laptop.example\"
listen_port = 4370
bundle_dir = \"" <> base <> "/laptop\"
executors = [\"devbox\", \"buildbox\"]

[[node]]
name = \"desk\"
role = \"orchestrator\"
erlang_node = \"loom@desk.example\"
bundle_dir = \"" <> base <> "/desk\"
executors = [\"buildbox\"]

[[node]]
name = \"devbox\"
role = \"executor\"
erlang_node = \"loom@devbox.example\"
host = \"devbox.example\"
listen_port = 4371
bundle_dir = \"" <> base <> "/devbox\"
[node.workspaces]
repo = \"/home/me/src/loom\"
docs = \"/home/me/src/docs\"

[[node]]
name = \"buildbox\"
role = \"executor\"
erlang_node = \"loom@buildbox.example\"
bundle_dir = \"" <> base <> "/buildbox\"
[node.workspaces]
\"my repo\" = \"/srv/my repo\"
"
}

fn plan_json(base: String) -> String {
  "{\"node\": [
  {\"name\": \"laptop\", \"role\": \"orchestrator\",
   \"erlang_node\": \"loom@laptop.example\", \"host\": \"laptop.example\",
   \"listen_port\": 4370, \"bundle_dir\": \"" <> base <> "/laptop\",
   \"executors\": [\"devbox\", \"buildbox\"]},
  {\"name\": \"desk\", \"role\": \"orchestrator\",
   \"erlang_node\": \"loom@desk.example\", \"bundle_dir\": \"" <> base <> "/desk\",
   \"executors\": [\"buildbox\"]},
  {\"name\": \"devbox\", \"role\": \"executor\",
   \"erlang_node\": \"loom@devbox.example\", \"host\": \"devbox.example\",
   \"listen_port\": 4371, \"bundle_dir\": \"" <> base <> "/devbox\",
   \"workspaces\": {\"repo\": \"/home/me/src/loom\", \"docs\": \"/home/me/src/docs\"}},
  {\"name\": \"buildbox\", \"role\": \"executor\",
   \"erlang_node\": \"loom@buildbox.example\", \"bundle_dir\": \"" <> base <> "/buildbox\",
   \"workspaces\": {\"my repo\": \"/srv/my repo\"}}
]}"
}

fn refused_plan(text: String, fragment: String) {
  let assert Error(reason) = distribution_plan.parse(text, TomlPlan)
    as "The plan must be refused."
  assert string.contains(reason, fragment)
}

// Provisions the standard plan under `base`, writing the bundles to
// `base/out`.
fn provisioned(base: String) -> distribution_provision.Deployment {
  let assert Ok(plan) = distribution_plan.parse(plan_toml(base), TomlPlan)
  let assert Ok(deployment) = distribution_provision.provision(plan)
  let assert Ok(_) =
    distribution_provision.write(deployment, base <> "/out", RefuseExisting)
  deployment
}

fn bundle_named(
  deployment: distribution_provision.Deployment,
  name: String,
) -> distribution_bundle.Bundle {
  let assert Ok(bundle) =
    list.find(deployment.bundles, fn(bundle) { bundle.name == name })
  bundle
}

fn options_for(
  base: String,
  name: String,
  overwrite: distribution_provision.Overwrite,
) -> distribution_install.Options {
  let home = base <> "/home-" <> name
  Options(home:, config: home <> "/.loom/loom.toml", overwrite:)
}

fn bundle_text(base: String, name: String) -> String {
  let assert Ok(text) =
    simplifile.read(base <> "/out/" <> name <> ".loombundle")
  text
}

fn install_node(
  base: String,
  name: String,
  overwrite: distribution_provision.Overwrite,
) -> Result(distribution_install.Installed, String) {
  distribution_install.install(
    bundle_text(base, name),
    options_for(base, name, overwrite),
  )
}

fn mode_of(path: String) -> Int {
  let assert Ok(info) = simplifile.file_info(path)
  int.bitwise_and(info.mode, 0o777)
}

fn read(path: String) -> String {
  let assert Ok(text) = simplifile.read(path)
  text
}

// --- the plan ----------------------------------------------------------------

pub fn toml_and_json_plans_parse_to_the_same_plan_test() {
  let assert Ok(from_toml) = distribution_plan.parse(plan_toml("/b"), TomlPlan)
  let assert Ok(from_json) = distribution_plan.parse(plan_json("/b"), JsonPlan)
  assert from_toml == from_json
  assert list.map(from_toml.nodes, fn(node) { node.name })
    == ["laptop", "desk", "devbox", "buildbox"]

  // The host defaults to the host part of the Erlang node name.
  let assert Ok(desk) = list.find(from_toml.nodes, fn(n) { n.name == "desk" })
  assert desk.host == "desk.example"
  assert desk.listen_port == None
  let assert Ok(buildbox) =
    list.find(from_toml.nodes, fn(n) { n.name == "buildbox" })
  assert buildbox.workspaces == [Workspace("my repo", "/srv/my repo")]
}

pub fn the_format_follows_the_extension_test() {
  assert distribution_plan.format_of("p.toml") == Ok(TomlPlan)
  assert distribution_plan.format_of("/a/p.json") == Ok(JsonPlan)
  assert result.is_error(distribution_plan.format_of("p.yaml"))
}

pub fn the_example_plan_is_a_valid_plan_test() {
  let assert Ok(plan) =
    distribution_plan.parse(distribution_plan.example, TomlPlan)
  assert list.length(plan.nodes) == 2
}

pub fn peers_are_symmetric_and_follow_the_executors_in_use_test() {
  let assert Ok(plan) = distribution_plan.parse(plan_toml("/b"), TomlPlan)
  let peers = fn(name) {
    let assert Ok(node) = list.find(plan.nodes, fn(n) { n.name == name })
    list.map(distribution_plan.peers(plan, node), fn(peer) { peer.name })
  }
  assert peers("laptop") == ["desk", "devbox", "buildbox"]
  assert peers("desk") == ["laptop", "buildbox"]
  assert peers("devbox") == ["laptop"]
  assert peers("buildbox") == ["laptop", "desk"]
}

pub fn a_plan_that_breaks_a_rule_is_refused_by_name_test() {
  let base = plan_toml("/b")
  refused_plan("", "at least one [[node]]")
  refused_plan("[[nod]]\n", "unknown key `nod`")
  refused_plan(
    string.replace(base, "name = \"desk\"", "name = \"laptop\""),
    "share a name",
  )
  refused_plan(
    string.replace(base, "loom@desk.example", "loom@laptop.example"),
    "share an erlang_node",
  )
  refused_plan(
    string.replace(base, "name = \"desk\"", "name = \"Desk\""),
    "name must be lowercase",
  )
  refused_plan(
    string.replace(base, "loom@desk.example", "desk"),
    "erlang_node must be a full node name",
  )
  refused_plan(
    string.replace(base, "\"orchestrator\"", "\"boss\""),
    "role must be",
  )
  refused_plan(
    string.replace(base, "listen_port = 4371", "listen_port = 70000"),
    "listen_port must be between 1 and 65535",
  )
  refused_plan(
    string.replace(base, "listen_port = 4371", "listen_port = \"4371\""),
    "listen_port must be a whole number",
  )
  refused_plan(
    string.replace(base, "bundle_dir = \"/b/desk\"", "bundle_dir = \"desk\""),
    "bundle_dir must be an absolute path",
  )
  refused_plan(
    string.replace(base, "host = \"devbox.example\"", "host = \"dev box\""),
    "host must be a DNS name",
  )
}

pub fn the_executor_and_workspace_rules_are_enforced_test() {
  let base = plan_toml("/b")

  // executors only on orchestrators, and only naming executors.
  refused_plan(
    string.replace(
      base,
      "[node.workspaces]\nrepo",
      "executors = [\"laptop\"]\n[node.workspaces]\nrepo",
    ),
    "executors belong on an orchestrator",
  )
  refused_plan(
    string.replace(base, "[\"buildbox\"]", "[\"desk\"]"),
    "which is not an executor",
  )
  refused_plan(
    string.replace(base, "[\"buildbox\"]", "[\"nobody\"]"),
    "which is not a node",
  )
  refused_plan(
    string.replace(
      base,
      "[\"devbox\", \"buildbox\"]",
      "[\"devbox\", \"devbox\"]",
    ),
    "executors lists a node twice",
  )

  // workspaces only on executors, with the registered-workspace grammar and
  // absolute roots.
  refused_plan(
    string.replace(
      base,
      "executors = [\"buildbox\"]",
      "executors = [\"buildbox\"]\n[node.workspaces]\nx = \"/x\"",
    ),
    "workspaces belong on an executor",
  )
  refused_plan(
    string.replace(base, "repo = \"/home/me/src/loom\"", "repo = \"src/loom\""),
    "workspaces.repo must be an absolute path",
  )
  refused_plan(
    string.replace(base, "repo = ", "\"a/b\" = "),
    "workspace name \"a/b\"",
  )
}

pub fn an_unused_executor_or_a_peerless_orchestrator_is_refused_test() {
  let base = plan_toml("/b")
  refused_plan(
    string.replace(
      base,
      "executors = [\"devbox\", \"buildbox\"]",
      "executors = [\"buildbox\"]",
    ),
    "no orchestrator uses this executor",
  )
  let alone =
    "[[node]]\nname = \"solo\"\nrole = \"orchestrator\"\nerlang_node = \"loom@solo.example\"\n"
  refused_plan(alone, "has no peers")
}

pub fn json_plans_are_strict_too_test() {
  let assert Error(unknown) =
    distribution_plan.parse("{\"node\": [], \"nodes\": 1}", JsonPlan)
  assert string.contains(unknown, "unknown key `nodes`")
  let assert Error(typed) =
    distribution_plan.parse(
      "{\"node\": [{\"name\": 1, \"role\": \"executor\"}]}",
      JsonPlan,
    )
  assert string.contains(typed, "name must be a string")
  assert result.is_error(distribution_plan.parse("{", JsonPlan))
  assert result.is_error(distribution_plan.parse("{\"node\": 1.5}", JsonPlan))
}

// --- provisioning ------------------------------------------------------------

pub fn provisioning_writes_private_bundles_and_a_description_test() {
  let base = scratch("write")
  let deployment = provisioned(base)

  // One bundle per node, mode 0600, in a directory only the owner can enter.
  assert mode_of(base <> "/out") == 0o700
  list.each(["laptop", "desk", "devbox", "buildbox"], fn(name) {
    assert mode_of(base <> "/out/" <> name <> ".loombundle") == 0o600
  })
  assert simplifile.is_file(base <> "/out/system.json") == Ok(True)

  // Each bundle on disk decodes to the bundle that was minted.
  list.each(deployment.bundles, fn(bundle) {
    assert distribution_bundle.decode(bundle_text(base, bundle.name))
      == Ok(bundle)
  })

  // A second run into the same directory is refused, and --force writes new
  // material over it.
  let assert Ok(plan) = distribution_plan.parse(plan_toml(base), TomlPlan)
  let assert Ok(second) = distribution_provision.provision(plan)
  let assert Error(refusal) =
    distribution_provision.write(second, base <> "/out", RefuseExisting)
  assert string.contains(refusal, "is not empty")
  let assert Ok(_) =
    distribution_provision.write(second, base <> "/out", ReplaceExisting)
  assert bundle_text(base, "laptop")
    != distribution_bundle.encode(bundle_named(deployment, "laptop"))
  discard(base)
}

pub fn the_description_round_trips_and_holds_nothing_private_test() {
  let base = scratch("system")
  let deployment = provisioned(base)
  let text = read(base <> "/out/system.json")
  assert distribution_provision.system_from_json(text) == Ok(deployment.system)

  // No PEM, no key and no cookie, but every pin and every edge.
  assert !string.contains(text, "BEGIN")
  assert !string.contains(text, "PRIVATE")
  list.each(deployment.bundles, fn(bundle) {
    assert !string.contains(text, bundle.cookie)
    assert !string.contains(text, string.slice(bundle.key, 40, 40))
  })
  let assert Ok(laptop) =
    list.find(deployment.system.nodes, fn(node) { node.name == "laptop" })
  assert laptop.peers == ["desk", "devbox", "buildbox"]
  assert laptop.executors == ["devbox", "buildbox"]
  assert string.length(laptop.pin) == 64
  let table = distribution_provision.render(deployment.system)
  assert string.contains(table, "devbox")
  assert string.contains(table, "laptop trusts desk, devbox, buildbox")
  assert result.is_error(distribution_provision.system_from_json("{}"))
  discard(base)
}

pub fn certificates_carry_the_exact_node_name_and_the_pins_match_test() {
  let base = scratch("pins")
  let deployment = provisioned(base)
  let facts = fn(name) {
    certificate_facts(bundle_named(deployment, name).certificate)
  }

  // The leaf's DNS names are exactly the node name, with its at sign, and the
  // host. No other name has an at sign.
  list.each(deployment.bundles, fn(bundle) {
    let #(_, names) = facts(bundle.name)
    assert list.sort(names, string.compare)
      == list.sort(
        list.unique([bundle.erlang_node, bundle.host]),
        string.compare,
      )
    assert list.count(names, string.contains(_, "@")) == 1
  })

  // Every pin in every bundle is the SHA-256 of the DER of that peer's
  // certificate, recomputed here.
  list.each(deployment.bundles, fn(bundle) {
    list.each(bundle.peers, fn(peer) {
      let assert Ok(owner) =
        list.find(deployment.bundles, fn(b) { b.erlang_node == peer.node })
      let #(digest, _) = facts(owner.name)
      assert peer.sha256 == digest
    })
  })

  // One cookie for the whole deployment, in the daemon's alphabet.
  let cookies =
    list.map(deployment.bundles, fn(bundle) { bundle.cookie })
    |> list.unique
  assert list.length(cookies) == 1
  discard(base)
}

// --- install -----------------------------------------------------------------

const catalogue =
  "[models.one]\ndialect = \"anthropic\"\napi_key_env = \"KEY\"\nmodel_id = \"m-1\"\ncontext_window = 1000\nmax_output_tokens = 100\n[roles]\nmain = [\"one\"]\n"

pub fn install_writes_a_configuration_the_daemon_accepts_test() {
  let base = scratch("install")
  let deployment = provisioned(base)

  list.each(deployment.bundles, fn(bundle) {
    let assert Ok(installed) = install_node(base, bundle.name, RefuseExisting)
    let options = options_for(base, bundle.name, RefuseExisting)
    let directory = base <> "/" <> bundle.name
    let config = read(options.config)

    // The daemon's own parsers accept the file: `[distribution]` with its
    // peers, `[executors.*]` against them, and for an orchestrator the whole
    // catalogue parser. An executor's `[workspaces.*]` rows are another
    // slice's table, so the catalogue parser is given everything before them.
    let assert Ok(Some(settings)) = distribution.parse(config)
    assert list.length(distribution.peer_nodes(settings))
      == list.length(bundle.peers)
    let assert Ok(_) =
      catalog.parse(
        catalogue
        <> {
          let assert [before, ..] = string.split(config, "\n[workspaces.")
          before
        },
      )

    // Credentials: a private directory, a 0600 key, and the cookie exactly as
    // the daemon wants it, at the VM's own HOME, with no trailing newline.
    assert mode_of(directory) == 0o700
    assert mode_of(directory <> "/key.pem") == 0o600
    assert mode_of(directory <> "/dist.options") == 0o600
    assert read(options.home <> "/.erlang.cookie") == bundle.cookie
    assert mode_of(options.home <> "/.erlang.cookie") == 0o600
    assert read(directory <> "/key.pem") == bundle.key
    assert read(directory <> "/dist.options")
      == distribution.tls_options(settings)

    // The installer says how to start the daemon and never says a secret.
    assert string.contains(installed.start, "LOOM_DISTRIBUTION_OPTFILE=")
    assert string.contains(installed.start, directory <> "/dist.options")
    assert !string.contains(string.inspect(installed.steps), bundle.cookie)
  })

  // The role tables follow the role.
  let laptop = read(base <> "/home-laptop/.loom/loom.toml")
  assert string.contains(laptop, "[executors.devbox]")
  assert string.contains(laptop, "[executors.buildbox]")
  assert !string.contains(laptop, "[workspaces")
  assert string.contains(laptop, "listen_port = 4370")
  let buildbox = read(base <> "/home-buildbox/.loom/loom.toml")
  assert string.contains(buildbox, "[workspaces.\"my repo\"]")
  assert string.contains(buildbox, "root = \"/srv/my repo\"")
  assert !string.contains(buildbox, "[executors")
  discard(base)
}

pub fn the_peer_pins_in_an_installed_config_are_the_peers_certificates_test() {
  let base = scratch("installed-pins")
  let deployment = provisioned(base)
  list.each(deployment.bundles, fn(bundle) {
    let assert Ok(_) = install_node(base, bundle.name, RefuseExisting)
  })

  list.each(deployment.bundles, fn(bundle) {
    let config = read(base <> "/home-" <> bundle.name <> "/.loom/loom.toml")
    let assert Ok(document) = tom.parse(config)
    let assert Ok(tom.Table(section)) = dict.get(document, "distribution")
    let assert Ok(tom.ArrayOfTables(rows)) = dict.get(section, "peers")
    list.each(rows, fn(row) {
      let assert Ok(tom.String(node)) = dict.get(row, "node")
      let assert Ok(tom.String(hex)) = dict.get(row, "sha256")
      let assert Ok(owner) =
        list.find(deployment.bundles, fn(b) { b.erlang_node == node })

      // The peer's certificate as that peer's own machine installed it.
      let #(digest, _) =
        certificate_facts(read(base <> "/" <> owner.name <> "/cert.pem"))
      assert bit_array.base16_encode(digest) == string.uppercase(hex)
    })
  })
  discard(base)
}

pub fn installing_twice_changes_nothing_test() {
  let base = scratch("idempotent")
  let _ = provisioned(base)
  let assert Ok(first) = install_node(base, "laptop", RefuseExisting)
  assert list.all(first.steps, fn(step) {
    step.outcome == distribution_install.Created
  })
  let options = options_for(base, "laptop", RefuseExisting)
  let before = [
    read(options.config),
    read(options.home <> "/.erlang.cookie"),
    read(base <> "/laptop/dist.options"),
    read(base <> "/laptop/key.pem"),
  ]

  let assert Ok(second) = install_node(base, "laptop", RefuseExisting)
  assert list.all(second.steps, fn(step) {
    step.outcome == distribution_install.Unchanged
  })
  assert before
    == [
      read(options.config),
      read(options.home <> "/.erlang.cookie"),
      read(base <> "/laptop/dist.options"),
      read(base <> "/laptop/key.pem"),
    ]
  discard(base)
}

pub fn install_merges_beside_unrelated_tables_test() {
  let base = scratch("merge")
  let _ = provisioned(base)
  let options = options_for(base, "laptop", RefuseExisting)
  let assert Ok(Nil) = simplifile.create_directory_all(options.home <> "/.loom")
  let mine =
    "# my notes\n"
    <> catalogue
    <> "\n[executors.mine]\nnode = \"loom@devbox.example\"\n"
  let assert Ok(Nil) = simplifile.write(options.config, mine)

  let assert Ok(installed) = install_node(base, "laptop", RefuseExisting)
  let assert Ok(step) =
    list.find(installed.steps, fn(step) { step.what == "daemon configuration" })
  assert step.outcome == distribution_install.Merged
  let merged = read(options.config)
  assert string.starts_with(merged, mine)
  assert string.contains(merged, "[executors.devbox]")
  let assert Ok(_) = catalog.parse(merged)

  // And again: the merge is a no-op the second time.
  let assert Ok(_) = install_node(base, "laptop", RefuseExisting)
  assert read(options.config) == merged
  discard(base)
}

pub fn a_different_cookie_is_refused_until_forced_test() {
  let base = scratch("cookie")
  let deployment = provisioned(base)
  let options = options_for(base, "devbox", RefuseExisting)
  let assert Ok(Nil) = simplifile.create_directory_all(options.home)
  let assert Ok(Nil) =
    simplifile.write(
      options.home <> "/.erlang.cookie",
      "another_cookie_0123456789",
    )

  let assert Error(reason) = install_node(base, "devbox", RefuseExisting)
  assert string.contains(reason, "already holds a different cookie")
  assert string.contains(reason, "--force")

  // A refusal leaves nothing behind: no configuration and no credentials.
  assert simplifile.is_file(options.config) == Ok(False)
  assert simplifile.is_directory(base <> "/devbox") == Ok(False)
  assert read(options.home <> "/.erlang.cookie") == "another_cookie_0123456789"

  let assert Ok(_) = install_node(base, "devbox", ReplaceExisting)
  assert read(options.home <> "/.erlang.cookie")
    == bundle_named(deployment, "devbox").cookie
  discard(base)
}

pub fn a_conflicting_table_is_refused_until_forced_test() {
  let base = scratch("conflict")
  let _ = provisioned(base)
  let options = options_for(base, "laptop", RefuseExisting)
  let assert Ok(Nil) = simplifile.create_directory_all(options.home <> "/.loom")
  let existing =
    catalogue
    <> "\n[distribution]\nnode = \"other@elsewhere.example\"\n# stale\n"
  let assert Ok(Nil) = simplifile.write(options.config, existing)

  let assert Error(reason) = install_node(base, "laptop", RefuseExisting)
  assert string.contains(reason, "already has [distribution]")
  assert read(options.config) == existing
  assert simplifile.is_directory(base <> "/laptop") == Ok(False)

  // Forced, exactly the bundle's sections are replaced and the rest stays.
  let assert Ok(_) = install_node(base, "laptop", ReplaceExisting)
  let merged = read(options.config)
  assert !string.contains(merged, "other@elsewhere.example")
  assert string.contains(merged, "[models.one]")
  let assert Ok(_) = catalog.parse(merged)

  // A conflicting executor row is a conflict of its own.
  let assert Ok(Nil) =
    simplifile.write(
      options.config,
      string.replace(
        read(options.config),
        "[executors.devbox]\nnode = \"loom@devbox.example\"",
        "[executors.devbox]\nnode = \"loom@buildbox.example\"",
      ),
    )
  let assert Error(row) = install_node(base, "laptop", RefuseExisting)
  assert string.contains(row, "[executors.devbox]")
  discard(base)
}

pub fn a_different_credential_file_is_refused_until_forced_test() {
  let base = scratch("credential")
  let _ = provisioned(base)
  let assert Ok(Nil) = simplifile.create_directory_all(base <> "/desk")
  let assert Ok(Nil) = simplifile.write(base <> "/desk/key.pem", "not mine")

  let assert Error(reason) = install_node(base, "desk", RefuseExisting)
  assert string.contains(reason, "key.pem")
  assert string.contains(reason, "--force")
  assert read(base <> "/desk/key.pem") == "not mine"

  let assert Ok(_) = install_node(base, "desk", ReplaceExisting)
  assert read(base <> "/desk/key.pem") != "not mine"
  discard(base)
}

// --- tampered bundles --------------------------------------------------------

fn refused_bundle(bundle: distribution_bundle.Bundle, fragment: String) -> Nil {
  let assert Error(reason) =
    distribution_bundle.decode(distribution_bundle.encode(bundle))
    as "The bundle must be refused."
  assert string.contains(reason, fragment)
  Nil
}

pub fn a_tampered_bundle_is_refused_and_installs_nothing_test() {
  let base = scratch("tamper")
  let deployment = provisioned(base)
  let laptop = bundle_named(deployment, "laptop")
  let desk = bundle_named(deployment, "desk")
  let devbox = bundle_named(deployment, "devbox")

  // Malformed PEM in each of the three files.
  refused_bundle(distribution_bundle.Bundle(..laptop, ca: "not a pem"), "ca")
  refused_bundle(
    distribution_bundle.Bundle(
      ..laptop,
      certificate: "-----BEGIN CERTIFICATE-----\nAAAA\n",
    ),
    "certificate",
  )
  refused_bundle(
    distribution_bundle.Bundle(..laptop, key: string.slice(laptop.key, 0, 60)),
    "key",
  )

  // Credentials that do not belong together.
  refused_bundle(
    distribution_bundle.Bundle(..laptop, key: desk.key),
    "key is not the private key of its certificate",
  )
  refused_bundle(
    distribution_bundle.Bundle(
      ..laptop,
      certificate: desk.certificate,
      key: desk.key,
    ),
    "bundle certificate must carry loom@laptop.example",
  )

  // A role carrying the other role's tables.
  refused_bundle(
    distribution_bundle.Bundle(..devbox, executors: [
      executors.plain("devbox", "loom@laptop.example"),
    ]),
    "executors belong on an orchestrator",
  )
  refused_bundle(
    distribution_bundle.Bundle(..laptop, workspaces: [
      Workspace("repo", "/srv/repo"),
    ]),
    "workspaces belong on an executor",
  )
  refused_bundle(
    distribution_bundle.Bundle(..laptop, executors: [
      executors.plain("ghost", "loom@ghost.example"),
    ]),
    "which is not one of its peers",
  )
  assert distribution_plan.role_word(laptop.role) == "orchestrator"
  assert laptop.role == Orchestrator
  assert devbox.role == Executor

  // Cookie and pin rules are the daemon's.
  refused_bundle(
    distribution_bundle.Bundle(..laptop, cookie: "short"),
    "cookie must be 16 to 128",
  )
  refused_bundle(
    distribution_bundle.Bundle(..laptop, peers: [
      distribution.PeerPin("loom@desk.example", <<1, 2>>),
    ]),
    "64 hexadecimal",
  )

  // The JSON itself: a wrong marker, a missing field, an unknown key, a type
  // error and a cut-off file.
  let text = distribution_bundle.encode(laptop)
  let refused_text = fn(text, fragment) {
    let assert Error(reason) = distribution_bundle.decode(text)
    assert string.contains(reason, fragment)
  }
  refused_text(
    string.replace(
      text,
      "loom-distribution-bundle/1",
      "loom-distribution-bundle/2",
    ),
    "is not a loom-distribution-bundle/1 bundle",
  )
  refused_text("{\"format\": \"loom-distribution-bundle/1\"}", "name")
  refused_text(
    string.replace(text, "\"cookie\":", "\"biscuit\":"),
    "unknown key `biscuit`",
  )
  refused_text(
    string.replace(text, "\"role\":\"orchestrator\"", "\"role\":3"),
    "role",
  )
  refused_text(string.slice(text, 0, 80), "not complete JSON")
  refused_text(string.replace(text, "orchestrator", "overlord"), "role must be")

  // Installing a tampered bundle writes nothing.
  let tampered =
    distribution_bundle.encode(
      distribution_bundle.Bundle(..laptop, key: desk.key),
    )
  let options = options_for(base, "laptop", RefuseExisting)
  let assert Error(_) = distribution_install.install(tampered, options)
  assert simplifile.is_file(options.config) == Ok(False)
  assert simplifile.is_directory(base <> "/laptop") == Ok(False)
  assert simplifile.is_file(options.home <> "/.erlang.cookie") == Ok(False)
  discard(base)
}

// --- the commands ------------------------------------------------------------

pub fn init_writes_one_plan_and_never_overwrites_it_test() {
  let base = scratch("init")
  let path = base <> "/plan.toml"
  let assert Ok(message) = distribution_cli.run(["init", path])
  assert string.contains(message, path)
  assert read(path) == distribution_plan.example

  let assert Error(refusal) = distribution_cli.run(["init", path])
  assert string.contains(refusal, "already exists")
  assert read(path) == distribution_plan.example
  discard(base)
}

pub fn the_commands_provision_show_and_install_a_deployment_test() {
  let base = scratch("commands")
  let plan = base <> "/plan.json"
  let assert Ok(Nil) = simplifile.write(plan, plan_json(base))

  let assert Ok(summary) =
    distribution_cli.run(["provision", plan, base <> "/out"])
  assert string.contains(summary, "Provisioned 4 nodes")
  assert string.contains(summary, "loom distribution install")
  let secrets = read(base <> "/out/laptop.loombundle")
  let assert Ok(laptop) = distribution_bundle.decode(secrets)
  assert !string.contains(summary, laptop.cookie)
  assert !string.contains(summary, "PRIVATE")

  // A second provision into the same directory needs --force.
  let assert Error(refusal) =
    distribution_cli.run(["provision", plan, base <> "/out"])
  assert string.contains(refusal, "--force")
  let assert Ok(_) =
    distribution_cli.run(["provision", plan, base <> "/out", "--force"])

  let assert Ok(shown) = distribution_cli.run(["show", base <> "/out"])
  assert string.contains(shown, "buildbox")
  assert !string.contains(shown, "BEGIN")

  let assert Ok(report) =
    distribution_cli.run([
      "install",
      base <> "/out/devbox.loombundle",
      "--home",
      base <> "/home",
      "--config",
      base <> "/home/loom.toml",
    ])
  assert string.contains(
    report,
    "Installed devbox (executor, loom@devbox.example)",
  )
  assert string.contains(
    report,
    "LOOM_DISTRIBUTION_OPTFILE=" <> base <> "/devbox/dist.options",
  )
  assert string.contains(report, "--config " <> base <> "/home/loom.toml")
  let devbox = read(base <> "/out/devbox.loombundle")
  let assert Ok(bundle) = distribution_bundle.decode(devbox)
  assert !string.contains(report, bundle.cookie)

  // The same install again reports every file unchanged.
  let assert Ok(again) =
    distribution_cli.run([
      "install",
      base <> "/out/devbox.loombundle",
      "--home",
      base <> "/home",
      "--config",
      base <> "/home/loom.toml",
    ])
  assert !string.contains(again, "created")
  assert !string.contains(again, "replaced")

  // Wrong usage is usage.
  assert distribution_cli.run(["provision", plan])
    == Error(distribution_cli.usage)
  assert distribution_cli.run(["install", "--nonsense"])
    == Error("unknown option --nonsense")
  assert distribution_cli.run(["provision", base <> "/plan.yaml", base <> "/o2"])
    |> result.is_error
  discard(base)
}

pub fn dist_is_short_for_distribution_test() {
  let full = client.help_for(["distribution", "--help"])
  assert full == Some(distribution_cli.usage)
  assert client.help_for(["dist", "--help"]) == full
  assert client.help_for(["dist", "-h"]) == full
  assert client.help_for(["help", "dist"]) == full
  assert client.help_for(["help", "distribution"]) == full
  assert string.contains(distribution_cli.usage, "`dist` for short")
  let assert Some(top) = client.help_for(["--help"])
  assert string.contains(top, "`dist` is short")
}

// --- two real emulators, with the files `install` wrote ----------------------

// Provisions two nodes on loopback, installs both bundles into scratch homes,
// and returns the paths the emulators boot from.
fn installed_pair(
  base: String,
) -> #(
  #(String, String, String),
  #(String, String, String),
  #(String, Int),
  distribution_provision.Deployment,
) {
  let tag = int.to_string(ffi_os.unique_positive_integer())
  let port = free_port()
  let plan = "{\"node\": [
      {\"name\": \"orch\", \"role\": \"orchestrator\",
       \"erlang_node\": \"loom_o" <> tag <> "@127.0.0.1\",
       \"bundle_dir\": \"" <> base <> "/orch\", \"executors\": [\"exec\"]},
      {\"name\": \"exec\", \"role\": \"executor\",
       \"erlang_node\": \"loom_e" <> tag <> "@127.0.0.1\",
       \"listen_port\": " <> int.to_string(port) <> ",
       \"bundle_dir\": \"" <> base <> "/exec\",
       \"workspaces\": {\"repo\": \"/srv/repo\"}}
    ]}"
  let assert Ok(parsed) = distribution_plan.parse(plan, JsonPlan)
  let assert Ok(deployment) = distribution_provision.provision(parsed)
  let assert Ok(_) =
    distribution_provision.write(deployment, base <> "/out", RefuseExisting)
  let assert Ok(_) = install_node(base, "orch", RefuseExisting)
  let assert Ok(_) = install_node(base, "exec", RefuseExisting)
  let node = fn(name) {
    let options = options_for(base, name, RefuseExisting)
    #(options.home, options.config, base <> "/" <> name <> "/dist.options")
  }
  #(
    node("orch"),
    node("exec"),
    #("loom_e" <> tag <> "@127.0.0.1", port),
    deployment,
  )
}

pub fn installed_bundles_connect_with_their_pins_checked_test() {
  let base = scratch("emulators")
  let #(orchestrator, executor, peer, _) = installed_pair(base)
  let assert Ok(Nil) = run_installed(orchestrator, executor, peer, Accept)
    as "Two nodes installed from provisioned bundles must connect hidden over TLS with pins checked, on the executor's fixed port."
  discard(base)
}

pub fn a_changed_peer_pin_refuses_the_connection_test() {
  let base = scratch("mutation")
  let #(orchestrator, executor, peer, deployment) = installed_pair(base)

  // Mutate the executor's pin in the orchestrator's installed configuration:
  // flip one hex digit. The options file is regenerated from the changed
  // configuration, because the daemon refuses an options file that does not
  // match it, so the only thing that differs is the pin.
  let #(_, config, options_file) = orchestrator
  let assert Ok(executor_node) =
    list.find(deployment.system.nodes, fn(node) { node.name == "exec" })
  let pin = executor_node.pin
  let flipped = case string.first(pin) {
    Ok("0") -> "1" <> string.drop_start(pin, 1)
    _ -> "0" <> string.drop_start(pin, 1)
  }
  let before = read(config)
  assert string.contains(before, pin)
  let assert Ok(Nil) =
    simplifile.write(config, string.replace(before, pin, flipped))
  assert read(config) != before
  let assert Ok(_) = distribution_cli.run(["options", config, options_file])

  let assert Ok(Nil) = run_installed(orchestrator, executor, peer, Refuse)
    as "A peer pin that is not the executor's certificate must be refused."
  discard(base)
}

pub fn the_unmutated_pair_still_connects_after_the_options_are_regenerated_test() {
  // The control for the mutation above: regenerating the options file from the
  // unchanged configuration must not by itself break the connection, so the
  // refusal there is the pin and nothing else.
  let base = scratch("control")
  let #(orchestrator, executor, peer, _) = installed_pair(base)
  let #(_, config, options_file) = orchestrator
  let assert Ok(_) = distribution_cli.run(["options", config, options_file])
  let assert Ok(Nil) = run_installed(orchestrator, executor, peer, Accept)
  discard(base)
}

// --- the directory (protocol-change/080) --------------------------------------

fn directory_plan(base: String) -> String {
  "directory = [\"laptop\", \"desk\", \"devbox\"]\n\n" <> plan_toml(base)
}

pub fn directory_members_peer_with_each_other_test() {
  let assert Ok(plan) = distribution_plan.parse(directory_plan("/b"), TomlPlan)
  let peers = fn(name) {
    let assert Ok(node) = list.find(plan.nodes, fn(n) { n.name == name })
    list.map(distribution_plan.peers(plan, node), fn(peer) { peer.name })
  }

  // devbox and desk do not use each other, but both are members, so they peer.
  assert peers("devbox") == ["laptop", "desk"]
  assert peers("desk") == ["laptop", "devbox", "buildbox"]
  assert peers("buildbox") == ["laptop", "desk"]
}

pub fn a_member_bundle_writes_a_directory_table_the_daemon_accepts_test() {
  let assert Ok(plan) = distribution_plan.parse(directory_plan("/b"), TomlPlan)
  let assert Ok(deployment) = distribution_provision.provision(plan)
  let files =
    distribution.CredentialFiles(
      ca: "/c/ca.pem",
      certificate: "/c/cert.pem",
      key: "/c/key.pem",
      cookie: "/c/.erlang.cookie",
    )
  let members = [
    "loom@laptop.example", "loom@desk.example", "loom@devbox.example",
  ]
  let devbox = bundle_named(deployment, "devbox")
  assert devbox.directory == members
  let text = distribution_bundle.config_text(devbox, files)
  assert string.contains(text, "[directory]\nmembers = [")
  let assert Ok(Some(found)) = directory_settings.parse(text)
    as "the daemon's own reader accepts the written table"
  assert found.members == members

  // A node outside the directory carries no table and no bundle key.
  let buildbox = bundle_named(deployment, "buildbox")
  assert buildbox.directory == []
  assert !string.contains(
    distribution_bundle.config_text(buildbox, files),
    "[directory]",
  )
  assert !string.contains(distribution_bundle.encode(buildbox), "directory")
  assert distribution_bundle.decode(distribution_bundle.encode(devbox))
    == Ok(devbox)
}

pub fn a_directory_that_breaks_a_rule_is_refused_test() {
  let base = plan_toml("/b")
  refused_plan(
    "directory = [\"laptop\", \"desk\"]\n" <> base,
    "between 3 and 7",
  )
  refused_plan(
    "directory = [\"laptop\", \"desk\", \"desk\"]\n" <> base,
    "lists a node twice",
  )
  refused_plan(
    "directory = [\"laptop\", \"desk\", \"nobody\"]\n" <> base,
    "\"nobody\", which is not a node",
  )

  // A member orchestrator refuses an [orchestrators.<name>] peer that is not a
  // member, so a plan that leaves an orchestrator out would write a bundle its
  // daemon refuses at startup.
  refused_plan(
    "directory = [\"laptop\", \"devbox\", \"buildbox\"]\n" <> base,
    "every orchestrator; \"desk\" is missing",
  )
}
