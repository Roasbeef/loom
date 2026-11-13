//// The decisions behind `loom vm`, held still: the command line, the artifact
//// manifest and its revision check, the deployment plan and the guest's own
//// configuration, the `loom-vm` command line, the scrub of a copied Git
//// configuration, and the two small records the command reads back. Nothing
//// here boots a guest; the live check does that against the built artifacts.

import broker/token
import client
import client/authority_key
import client/daemon/admin
import client/daemon/ledger_cli
import client/distribution
import client/distribution_bundle
import client/distribution_install
import client/distribution_plan
import client/distribution_provision
import client/ledger_operator
import client/ledger_sync
import client/membership_entry
import client/membership_ledger
import client/membership_signing
import client/vm_cli
import client/vm_spec.{Launch, Manifest, PidRecord}
import core/json
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import simplifile
import tom

// --- the command line --------------------------------------------------------

pub fn up_takes_its_defaults_test() {
  let assert Ok(vm_spec.Up(options)) = vm_spec.parse(["up"])
  assert options.name == "vm"
  assert options.workspace == None
  assert options.memory_mib == 2048
  assert options.cpus == 4
  assert options.config == None
  assert options.github == vm_spec.GitHubFromGh
  assert options.freshness == vm_spec.Resume
  assert options.allow == []
  assert options.provision == None
}

pub fn up_reads_github_access_and_fresh_test() {
  let assert Ok(vm_spec.Up(options)) =
    vm_spec.parse(["up", "--github", "off", "--fresh", "--name", "dev"])
  assert options.github == vm_spec.GitHubOff
  assert options.freshness == vm_spec.Fresh
  assert options.name == "dev"

  let assert Ok(vm_spec.Up(options)) = vm_spec.parse(["up", "--github", "env"])
  assert options.github == vm_spec.GitHubFromEnv

  let assert Error(reason) = vm_spec.parse(["up", "--github", "ssh"])
  assert string.contains(reason, "gh, env or off")
}

pub fn up_reads_every_flag_in_any_order_test() {
  let assert Ok(vm_spec.Up(options)) =
    vm_spec.parse([
      "up", "--cpus", "2", "--workspace", "/src/proj", "--name", "dev", "--mem",
      "4096", "--config", "/tmp/loom.toml",
    ])
  assert options.name == "dev"
  assert options.workspace == Some("/src/proj")
  assert options.memory_mib == 4096
  assert options.cpus == 2
  assert options.config == Some("/tmp/loom.toml")
}

pub fn down_and_status_take_only_a_name_test() {
  assert vm_spec.parse(["down"]) == Ok(vm_spec.Down("vm"))
  assert vm_spec.parse(["status", "--name", "dev"]) == Ok(vm_spec.Status("dev"))
  assert result.is_error(vm_spec.parse(["down", "--mem", "512"]))
  assert result.is_error(vm_spec.parse(["status", "extra"]))
}

pub fn a_bad_command_line_is_refused_with_its_reason_test() {
  assert vm_spec.parse([])
    == Error(
      "loom vm needs a command: setup, up, down, status, logs, list, rm or sync",
    )
  assert vm_spec.parse(["shell"]) == Error("unknown loom vm command shell")
  assert vm_spec.parse(["up", "--bogus", "1"])
    == Error("unknown option --bogus")
  assert vm_spec.parse(["up", "--mem"]) == Error("--mem needs a value")
  assert vm_spec.parse(["up", "stray"]) == Error("unexpected argument stray")
  assert result.is_error(vm_spec.parse(["up", "--mem", "12"]))
  assert result.is_error(vm_spec.parse(["up", "--cpus", "0"]))
  assert result.is_error(vm_spec.parse(["up", "--cpus", "many"]))
}

pub fn a_name_must_make_valid_plan_names_test() {
  assert vm_spec.valid_name("dev-box_2") == Ok(Nil)
  assert result.is_error(vm_spec.valid_name("Dev"))
  assert result.is_error(vm_spec.valid_name(""))
  assert result.is_error(vm_spec.parse(["up", "--name", "has space"]))

  // The orchestrator's plan name adds `-host`, so the longest name is five
  // characters short of the plan-name limit of 32.
  let longest = string.repeat("a", vm_spec.name_limit)
  assert vm_spec.valid_name(longest) == Ok(Nil)
  assert result.is_error(vm_spec.valid_name(longest <> "a"))
}

pub fn a_workspace_name_is_one_safe_path_segment_test() {
  assert vm_spec.valid_workspace_name("proj-2.git_x") == Ok(Nil)
  assert result.is_error(vm_spec.valid_workspace_name(""))
  assert result.is_error(vm_spec.valid_workspace_name("."))
  assert result.is_error(vm_spec.valid_workspace_name(".."))
  assert result.is_error(vm_spec.valid_workspace_name("my proj"))
  assert result.is_error(vm_spec.valid_workspace_name("a/b"))
}

pub fn vm_is_a_command_of_both_binaries_test() {
  let assert Some(text) = client.help_for(["vm", "--help"])
  assert text == vm_cli.usage
  assert string.contains(
    client.help_for(["--help"]) |> option.unwrap(""),
    "vm <command>",
  )
  assert result.is_error(vm_cli.run([]))
  assert result.is_error(vm_cli.run(["up", "--bogus", "1"]))
}

pub fn the_installers_force_advice_is_left_out_test() {
  assert vm_spec.without_force_hint(
      "c.toml already has [distribution] with different values; pass --force to replace the tables this bundle owns",
    )
    == "c.toml already has [distribution] with different values"
  assert vm_spec.without_force_hint(
      "/h/.erlang.cookie already holds a different cookie. Erlang reads it. Pass --force to replace it, or give the daemon its own home with --home DIR",
    )
    == "/h/.erlang.cookie already holds a different cookie. Erlang reads it."
  assert vm_spec.without_force_hint("something else") == "something else"
}

// --- the manifest ------------------------------------------------------------

fn manifest_json(
  revision: String,
  firmware: String,
  version: String,
) -> String {
  "{\"version\": "
  <> version
  <> ", \"revision\": \""
  <> revision
  <> "\", \"loom_vm\": \"/o/loom-vm\", \"runner\": \"/o/runner\", "
  <> "\"lib_dir\": \"/o/lib\", \"firmware_dir\": \""
  <> firmware
  <> "\", \"guest_root\": \"/o/guest-root\"}"
}

fn manifest(revision: String) -> vm_spec.Manifest {
  Manifest(
    revision:,
    loom_vm: "/o/loom-vm",
    runner: "/o/runner",
    lib_dir: "/o/lib",
    firmware_dir: Some("/o/firmware"),
    guest_root: "/o/guest-root",
  )
}

pub fn the_manifest_decodes_test() {
  let assert Ok(found) =
    vm_spec.decode_manifest(manifest_json("dev", "/o/firmware", "1"))
  assert found == manifest("dev")
}

pub fn an_empty_firmware_directory_means_the_stock_kernel_test() {
  let assert Ok(found) = vm_spec.decode_manifest(manifest_json("dev", "", "1"))
  assert found.firmware_dir == None
}

pub fn a_malformed_manifest_is_refused_naming_the_field_test() {
  let assert Error(version) =
    vm_spec.decode_manifest(manifest_json("dev", "", "2"))
  assert string.contains(version, "version 2")

  let assert Error(missing) = vm_spec.decode_manifest("{\"version\": 1}")
  assert string.contains(missing, "revision")

  let assert Error(relative) =
    vm_spec.decode_manifest(string.replace(
      manifest_json("dev", "", "1"),
      "/o/runner",
      "runner",
    ))
  assert relative == "runner must be an absolute path"

  assert result.is_error(vm_spec.decode_manifest("not json"))
  assert result.is_error(vm_spec.decode_manifest("[]"))
}

pub fn a_tree_build_matches_any_running_build_test() {
  assert vm_spec.check_revision(manifest("dev"), "unknown") == Ok(Nil)
  assert vm_spec.check_revision(manifest("dev"), "4c266dde0000") == Ok(Nil)
}

pub fn the_same_commit_matches_abbreviated_or_not_test() {
  let full = "4c266dde0123456789abcdef0123456789abcdef"
  assert vm_spec.check_revision(manifest(full), full) == Ok(Nil)
  assert vm_spec.check_revision(manifest("4c266dd"), full) == Ok(Nil)
  assert vm_spec.check_revision(manifest(full), "4c266dd") == Ok(Nil)
}

pub fn another_release_is_refused_with_the_way_out_test() {
  let assert Error(reason) =
    vm_spec.check_revision(manifest("4c266dd"), "0123456789ab")
  assert string.contains(reason, "4c266dd")
  assert string.contains(reason, "crashes the host")
  assert string.contains(reason, "loom vm setup")
  assert string.contains(reason, "make vmm-install-dev")
}

pub fn an_unknown_running_build_matches_no_commit_test() {
  assert result.is_error(vm_spec.check_revision(manifest("4c266dd"), "unknown"))
  assert result.is_error(vm_spec.check_revision(manifest("4c266dd"), ""))

  // A prefix too short to mean anything is no match.
  assert result.is_error(vm_spec.check_revision(manifest("4c2"), "4c266dd"))
}

// --- the deployment ----------------------------------------------------------

pub fn the_node_names_are_loopback_and_unique_per_guest_test() {
  let names = vm_spec.names("dev")
  assert names.executor_node == "loom_vm_dev_exec@127.0.0.1"
  assert names.executor_short == "loom_vm_dev_exec"
  assert names.orchestrator_node == "loom_vm_dev_orch@127.0.0.1"
  assert names.orchestrator == "dev-host"
  assert vm_spec.names("a").executor_node != vm_spec.names("b").executor_node
}

fn plan_of(name: String) -> distribution_plan.Plan {
  let assert Ok(plan) =
    vm_spec.deployment_plan(vm_spec.names(name), "/vm/" <> name <> "/orch")
  plan
}

pub fn the_plan_is_one_orchestrator_using_one_executor_test() {
  let plan = plan_of("dev")
  let assert [orchestrator, executor] = plan.nodes
  assert orchestrator.role == distribution_plan.Orchestrator
  assert orchestrator.executors == ["dev"]
  assert orchestrator.bundle_dir == Some("/vm/dev/orch")
  assert orchestrator.host == "127.0.0.1"
  assert executor.role == distribution_plan.Executor
  assert executor.name == "dev"
  assert executor.host == "127.0.0.1"
  assert executor.listen_port == Some(vm_spec.guest_port)
  assert executor.workspaces == []
}

pub fn the_longest_name_still_plans_test() {
  let name = string.repeat("a", vm_spec.name_limit)
  assert result.is_ok(vm_spec.deployment_plan(vm_spec.names(name), "/vm/orch"))
}

fn bundles(
  name: String,
) -> #(distribution_bundle.Bundle, distribution_bundle.Bundle) {
  let assert Ok(deployment) = distribution_provision.provision(plan_of(name))
  let assert Ok(orchestrator) =
    list.find(deployment.bundles, fn(bundle) { bundle.name == name <> "-host" })
  let assert Ok(executor) =
    list.find(deployment.bundles, fn(bundle) { bundle.name == name })
  #(orchestrator, executor)
}

pub fn each_node_trusts_the_other_and_the_orchestrator_names_the_row_test() {
  let #(orchestrator, executor) = bundles("dev")
  let assert [row] = orchestrator.executors
  assert row.name == "dev"
  assert row.node == "loom_vm_dev_exec@127.0.0.1"
  assert orchestrator.cookie == executor.cookie
  let assert distribution_bundle.StaticPeers([orchestrator_peer]) =
    orchestrator.trust
  assert orchestrator_peer.node == "loom_vm_dev_exec@127.0.0.1"
  let assert distribution_bundle.StaticPeers([executor_peer]) = executor.trust
  assert executor_peer.node == "loom_vm_dev_orch@127.0.0.1"
}

pub fn the_guest_configuration_names_guest_paths_only_test() {
  let #(_, executor) = bundles("dev")
  let text = vm_spec.guest_config(executor, ["proj"], vm_spec.GitHubOff, [])
  let assert Ok(document) = tom.parse(text)

  let assert Ok(distribution) = tom.get_table(document, ["distribution"])
  assert tom.get_string(distribution, ["node"])
    == Ok("loom_vm_dev_exec@127.0.0.1")
  assert tom.get_string(distribution, ["ca"])
    == Ok("/srv/loom-node/creds/ca.pem")
  assert tom.get_string(distribution, ["key"])
    == Ok("/srv/loom-node/creds/key.pem")
  assert tom.get_string(distribution, ["cookie"])
    == Ok("/srv/loom-node/home/.erlang.cookie")
  assert tom.get_int(distribution, ["listen_port"]) == Ok(4370)
  assert tom.get_string(document, ["workspaces", "proj", "root"])
    == Ok("/srv/workspaces/proj")

  // No credential's content reaches a configuration.
  assert !string.contains(text, executor.cookie)
  assert !string.contains(text, "PRIVATE KEY")
}

pub fn github_access_opens_the_jail_to_the_proxy_test() {
  // With GitHub access the executor's jail has the network, bounded by the
  // guest's egress allowlist, and passes the proxy's names through; without
  // it there is no [tools] table and the jail keeps the network off.
  let #(_, executor) = bundles("dev")
  let text = vm_spec.guest_config(executor, ["proj"], vm_spec.GitHubFromGh, [])
  let assert Ok(document) = tom.parse(text)
  assert tom.get_string(document, ["tools", "network"]) == Ok("full")
  let assert Ok(names) = tom.get_array(document, ["tools", "env"])
  assert list.length(names) == 4

  let text = vm_spec.guest_config(executor, ["proj"], vm_spec.GitHubOff, [])
  let assert Ok(document) = tom.parse(text)
  assert result.is_error(tom.get_table(document, ["tools"]))
}

pub fn allowed_hosts_open_the_jail_without_the_proxy_names_test() {
  // `--github off --allow HOST` has no proxy, so the jail needs the network
  // and no environment names; with neither there is still no [tools] table.
  let #(_, executor) = bundles("dev")
  let text =
    vm_spec.guest_config(executor, ["proj"], vm_spec.GitHubOff, ["example.com"])
  let assert Ok(document) = tom.parse(text)
  assert tom.get_string(document, ["tools", "network"]) == Ok("full")
  assert result.is_error(tom.get_array(document, ["tools", "env"]))

  // With GitHub access the table is the same whatever `--allow` adds.
  let with_github =
    vm_spec.guest_config(executor, ["proj"], vm_spec.GitHubFromEnv, [
      "example.com",
    ])
  assert with_github
    == vm_spec.guest_config(executor, ["proj"], vm_spec.GitHubFromEnv, [])
}

pub fn the_guest_node_line_is_the_first_one_the_guest_script_reads_test() {
  // `loom-guest-executor` takes the node's short name from the first line
  // that starts `node = "`. The peer rows below `[distribution]` have such
  // lines too, so the executor's own must come before them, and a model
  // table before it must have none.
  let #(_, executor) = bundles("dev")
  let lines =
    string.split(
      vm_spec.guest_config(executor, ["proj"], vm_spec.GitHubFromGh, []),
      "\n",
    )
    |> list.filter(string.starts_with(_, "node = \""))
  assert list.first(lines) == Ok("node = \"loom_vm_dev_exec@127.0.0.1\"")
}

// --- launching ---------------------------------------------------------------

fn launch(firmware: option.Option(String)) -> vm_spec.Launch {
  Launch(
    manifest: Manifest(..manifest("dev"), firmware_dir: firmware),
    names: vm_spec.names("dev"),
    root: "/vm/dev/root",
    memory_mib: 3072,
    cpus: 2,
    host_port: 47_011,
    state_disk: "/vm/dev/state.img",
    github: vm_spec.GitHubOff,
    allow: [],
  )
}

pub fn the_launch_runs_the_guest_script_on_the_node_directory_test() {
  let arguments = vm_spec.launch_arguments(launch(Some("/o/firmware")))
  assert list.take(arguments, 3) == ["run", "--name", "dev"]
  assert list.drop(arguments, list.length(arguments) - 5)
    == [
      "--", "/usr/local/sbin/loom-guest-executor", "/srv/loom-node",
      "--state-device", "/dev/vda",
    ]
  assert string.join(arguments, " ")
    == "run --name dev --root-dir /vm/dev/root --runner /o/runner "
    <> "--lib-dir /o/lib --firmware-dir /o/firmware --cpus 2 --mem 3072 "
    <> "--timeout 0 --state-disk /vm/dev/state.img "
    <> "--publish loom_vm_dev_exec:47011:4370 -- "
    <> "/usr/local/sbin/loom-guest-executor /srv/loom-node "
    <> "--state-device /dev/vda"
}

pub fn no_firmware_directory_means_no_flag_test() {
  let arguments = vm_spec.launch_arguments(launch(None))
  assert !list.contains(arguments, "--firmware-dir")
}

pub fn a_standing_guest_is_not_left_to_the_default_timeout_test() {
  // `loom-vm run` stops the guest after ten minutes unless told otherwise;
  // zero runs it until `loom vm down` stops it.
  let arguments = vm_spec.launch_arguments(launch(None))
  assert string.contains(string.join(arguments, " "), "--timeout 0 ")
}

pub fn github_access_starts_the_proxy_on_the_github_hosts_test() {
  let arguments =
    vm_spec.launch_arguments(
      vm_spec.Launch(..launch(None), github: vm_spec.GitHubFromGh),
    )
  let line = string.join(arguments, " ")
  assert string.contains(line, "--github-token-from gh")
  assert string.contains(line, "--allow github.com")
  assert string.contains(line, "--allow api.github.com")
  assert string.contains(line, "--allow uploads.github.com")

  // Without GitHub access the guest has no allowlisted host at all.
  let line = string.join(vm_spec.launch_arguments(launch(None)), " ")
  assert !string.contains(line, "--allow")
  assert !string.contains(line, "--github-token-from")
}

pub fn allowed_hosts_follow_the_github_ones_and_are_never_injected_test() {
  // The hosts are `--allow` entries after GitHub's own, in the order given.
  let arguments =
    vm_spec.launch_arguments(
      vm_spec.Launch(..launch(None), github: vm_spec.GitHubFromEnv, allow: [
        "deb.debian.org",
        "*.golang.org",
      ]),
    )
  let line = string.join(arguments, " ")
  assert string.contains(
    line,
    "--allow uploads.github.com --allow deb.debian.org --allow *.golang.org -- ",
  )

  // `--allow` widens reachability only: no injection host is ever named, so
  // the proxy's built-in three stay the only hosts that get a credential.
  assert !list.contains(arguments, "--inject-host")
}

pub fn allowed_hosts_are_the_whole_list_without_github_test() {
  let arguments =
    vm_spec.launch_arguments(
      vm_spec.Launch(..launch(None), allow: ["example.com"]),
    )
  let line = string.join(arguments, " ")
  assert string.contains(line, "--allow example.com -- ")
  assert !string.contains(line, "github")
  assert !list.contains(arguments, "--github-token-from")
  assert !list.contains(arguments, "--inject-host")
}

pub fn the_clone_is_copy_on_write_on_both_hosts_test() {
  assert vm_spec.copy_arguments(vm_spec.Macos, "/a", "/b")
    == ["-cRp", "/a", "/b"]
  assert vm_spec.copy_arguments(vm_spec.Linux, "/a", "/b")
    == ["-a", "--reflink=auto", "/a", "/b"]
}

pub fn only_macos_and_linux_are_hosts_test() {
  assert vm_spec.platform_of("Darwin\n") == Ok(vm_spec.Macos)
  assert vm_spec.platform_of("Linux") == Ok(vm_spec.Linux)
  assert result.is_error(vm_spec.platform_of("FreeBSD"))
}

// --- the egress allowlist ----------------------------------------------------

pub fn up_reads_each_allowed_host_in_order_without_repeats_test() {
  let assert Ok(vm_spec.Up(options)) =
    vm_spec.parse([
      "up", "--allow", "deb.debian.org", "--allow", "*.golang.org", "--allow",
      "deb.debian.org", "--github", "off",
    ])
  assert options.allow == ["deb.debian.org", "*.golang.org"]
  assert options.github == vm_spec.GitHubOff
}

pub fn an_allowed_host_follows_the_rule_machine_spec_applies_test() {
  // Bare hostnames and `*.` over two labels or more.
  assert vm_spec.valid_host("example.com") == Ok(Nil)
  assert vm_spec.valid_host("localhost") == Ok(Nil)
  assert vm_spec.valid_host("*.example.com") == Ok(Nil)

  // Each refusal names the entry, and `up` puts the flag before it.
  let assert Error(reason) = vm_spec.parse(["up", "--allow", "*.com"])
  assert string.starts_with(
    reason,
    "--allow \"*.com\" covers a whole top-level",
  )
  assert !string.contains(reason, "\n")

  list.each(
    ["", "*.", "https://example.com", "a@b.com", "a b.com", "a:443", "a*b.com"],
    fn(host) {
      let assert Error(_) = vm_spec.parse(["up", "--allow", host])
    },
  )
}

pub fn the_allow_file_round_trips_and_refuses_a_bad_line_test() {
  let hosts = ["deb.debian.org", "*.golang.org"]
  assert vm_spec.decode_allow(vm_spec.encode_allow(hosts)) == Ok(hosts)
  assert vm_spec.decode_allow("") == Ok([])
  assert vm_spec.decode_allow("\n a.example.com \n\na.example.com\n")
    == Ok(["a.example.com"])

  let assert Error(reason) = vm_spec.decode_allow("a.example.com\n*.com\n")
  assert string.starts_with(reason, "line 2: ")
}

pub fn given_hosts_replace_the_recorded_ones_and_fresh_clears_them_test() {
  let recorded = ["old.example.com"]
  let given = ["new.example.com"]
  assert vm_spec.effective_allow(given, recorded, vm_spec.Resume) == given
  assert vm_spec.effective_allow(given, recorded, vm_spec.Fresh) == given
  assert vm_spec.effective_allow([], recorded, vm_spec.Resume) == recorded
  assert vm_spec.effective_allow([], recorded, vm_spec.Fresh) == []
}

// --- the provisioning script -------------------------------------------------

pub fn up_reads_the_provisioning_script_test() {
  let assert Ok(vm_spec.Up(options)) =
    vm_spec.parse(["up", "--provision", "setup.sh"])
  assert options.provision == Some("setup.sh")

  let assert Error(reason) = vm_spec.parse(["up", "--provision"])
  assert string.contains(reason, "needs a value")
  assert result.is_error(vm_spec.parse(["up", "--provision", ""]))
}

pub fn a_script_runs_on_a_new_guest_and_a_failed_one_runs_again_test() {
  let script = Some("/host/setup.sh")
  assert vm_spec.provision_plan(script, vm_spec.NeverProvisioned, None)
    == Ok(vm_spec.StageScript("/host/setup.sh"))

  // A failed run left a script and no marker, so a new one replaces it.
  assert vm_spec.provision_plan(script, vm_spec.FailedBefore, None)
    == Ok(vm_spec.StageScript("/host/setup.sh"))

  // Without a host copy the script the root holds is retried; with one, the
  // copy is staged, because the root's script is whatever the last boot left.
  assert vm_spec.provision_plan(None, vm_spec.FailedBefore, None)
    == Ok(vm_spec.RetryStaged)
  assert vm_spec.provision_plan(
      None,
      vm_spec.FailedBefore,
      Some("/vm/provision"),
    )
    == Ok(vm_spec.StageScript("/vm/provision"))
}

pub fn a_resume_skips_a_script_that_succeeded_and_refuses_a_new_one_test() {
  assert vm_spec.provision_plan(None, vm_spec.AlreadyProvisioned, None)
    == Ok(vm_spec.NoScript)
  assert vm_spec.provision_plan(None, vm_spec.NeverProvisioned, None)
    == Ok(vm_spec.NoScript)

  let assert Error(reason) =
    vm_spec.provision_plan(
      Some("/host/setup.sh"),
      vm_spec.AlreadyProvisioned,
      None,
    )
  assert string.contains(reason, "--fresh")
}

pub fn a_script_gets_the_long_boot_budget_test() {
  assert vm_spec.boot_budget_ms(vm_spec.NoScript) == vm_spec.ready_budget_ms
  assert vm_spec.boot_budget_ms(vm_spec.RetryStaged)
    == vm_spec.provision_budget_ms
  assert vm_spec.boot_budget_ms(vm_spec.StageScript("/s"))
    == vm_spec.provision_budget_ms
  assert vm_spec.provision_budget_ms > vm_spec.ready_budget_ms
}

pub fn the_usage_documents_both_flags_test() {
  assert string.contains(vm_cli.usage, "[--allow HOST]... [--provision SCRIPT]")
  assert string.contains(vm_cli.usage, "--fresh")
}

// --- the copied Git configuration --------------------------------------------

const config =
  "[core]
\trepositoryformatversion = 0
\tfilemode = true
[remote \"origin\"]
\turl = git@github.com:me/proj.git
\tfetch = +refs/heads/*:refs/remotes/origin/*
[credential]
\thelper = osxkeychain
[credential \"https://github.com\"]
\thelper = !gh auth git-credential
\tusername = me
[url \"git@github.com:\"]
\tinsteadOf = https://github.com/
\tpushInsteadOf = https://github.com/
[http \"https://github.com/\"]
\textraheader = AUTHORIZATION: basic c2VjcmV0
\tsslverify = true
[branch \"main\"]
\tremote = origin
"

pub fn the_scrub_drops_credentials_and_rewrites_test() {
  let scrubbed = vm_spec.scrub_git_config(config)
  assert !string.contains(scrubbed, "credential")
  assert !string.contains(scrubbed, "osxkeychain")
  assert !string.contains(scrubbed, "username")
  assert !string.contains(string.lowercase(scrubbed), "insteadof")
  assert !string.contains(scrubbed, "c2VjcmV0")
}

pub fn the_scrub_keeps_everything_else_as_written_test() {
  let scrubbed = vm_spec.scrub_git_config(config)
  assert string.contains(scrubbed, "[core]\n\trepositoryformatversion = 0")
  assert string.contains(scrubbed, "\turl = git@github.com:me/proj.git")
  assert string.contains(scrubbed, "\tsslverify = true")
  assert string.contains(scrubbed, "[branch \"main\"]\n\tremote = origin\n")

  // The `[url]` header stays, so a later key of the section still has one.
  assert string.contains(scrubbed, "[url \"git@github.com:\"]")
}

pub fn the_scrub_is_idempotent_and_leaves_a_clean_file_alone_test() {
  let clean =
    "[core]\n\tbare = false\n[branch \"main\"]\n\tmerge = refs/heads/main\n"
  assert vm_spec.scrub_git_config(clean) == clean
  let once = vm_spec.scrub_git_config(config)
  assert vm_spec.scrub_git_config(once) == once
}

pub fn the_scrub_ends_a_dropped_section_at_the_next_header_test() {
  let text = "[credential]\n\thelper = store\n[user]\n\tname = Me\n"
  assert vm_spec.scrub_git_config(text) == "[user]\n\tname = Me\n"
}

pub fn the_scrub_reads_section_and_key_names_without_case_test() {
  let text = "[Credential]\n\tHelper = store\n[URL \"x\"]\n\tINSTEADOF = y\n"
  let scrubbed = vm_spec.scrub_git_config(text)
  assert !string.contains(scrubbed, "store")
  assert !string.contains(string.lowercase(scrubbed), "insteadof")
}

pub fn the_scrub_handles_a_setting_on_the_header_line_test() {
  let text =
    "[url \"x\"] insteadOf = y\n[credential] helper = store\n[user]\n\tname = Me\n"
  let scrubbed = vm_spec.scrub_git_config(text)
  assert scrubbed == "[url \"x\"]\n[user]\n\tname = Me\n"
}

// --- the pid file and the epmd listing ---------------------------------------

pub fn the_pid_record_round_trips_test() {
  let record =
    PidRecord(pid: 4242, birth: "darwin:utc:Sat Nov  1 10:00:00 2026")
  assert vm_spec.decode_pid(vm_spec.encode_pid(record)) == Ok(record)
}

pub fn a_damaged_pid_file_names_no_process_test() {
  assert result.is_error(vm_spec.decode_pid(""))
  assert result.is_error(vm_spec.decode_pid("4242\n"))
  assert result.is_error(vm_spec.decode_pid("abc\nbirth\n"))
  assert result.is_error(vm_spec.decode_pid("1\nbirth\n"))
  assert result.is_error(vm_spec.decode_pid("4242\nbirth\nextra\n"))
}

pub fn the_epmd_listing_names_the_host_port_test() {
  let listing =
    "epmd: up and running on port 4369 with data:\n"
    <> "name loom_vm_dev_orch at port 50123\n"
    <> "name loom_vm_dev_exec at port 47011\n"
  assert vm_spec.registered_port(listing, "loom_vm_dev_exec") == Some(47_011)
  assert vm_spec.registered_port(listing, "loom_vm_dev_orch") == Some(50_123)
  assert vm_spec.registered_port(listing, "loom_vm_dev") == None
  assert vm_spec.registered_port("epmd: nothing\n", "x") == None
}

pub fn a_log_tail_keeps_the_end_test() {
  assert vm_spec.tail("abcdef\n", 3) == "...def"
  assert vm_spec.tail("abc", 3) == "abc"
}

// --- review follow-ups -------------------------------------------------------

pub fn a_remote_url_loses_its_userinfo_test() {
  // A token embedded in a remote URL would otherwise reach the guest's copy,
  // which model code can read under the default read scope.
  let text =
    "[remote \"origin\"]\n\turl = https://x:ghp_secret@github.com/o/r.git\n"
    <> "\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
    <> "[remote \"mirror\"]\n\turl = git@github.com:o/r.git\n"
  let scrubbed = vm_spec.scrub_git_config(text)
  assert !string.contains(scrubbed, "ghp_secret")
  assert string.contains(scrubbed, "\turl = https://github.com/o/r.git")
  assert string.contains(scrubbed, "\turl = git@github.com:o/r.git")
  assert string.contains(scrubbed, "fetch = +refs/heads/*")
}

pub fn a_url_without_userinfo_is_left_alone_test() {
  assert vm_spec.without_userinfo("\turl = https://github.com/o/r")
    == "\turl = https://github.com/o/r"
  assert vm_spec.without_userinfo("\tname = https://a@b.example/x")
    == "\tname = https://a@b.example/x"
}

pub fn a_push_url_and_a_url_header_lose_their_tokens_test() {
  // An authenticated push URL and a rewrite header are the two other places
  // a token is commonly written in a Git configuration.
  let text =
    "[remote \"origin\"]\n\tpushurl = https://x:ghp_push@github.com/o/r\n"
    <> "[url \"https://x:ghp_header@github.com/\"]\n"
    <> "\tinsteadOf = https://github.com/\n"
    <> "[core]\n\tbare = false\n"
  let scrubbed = vm_spec.scrub_git_config(text)
  assert !string.contains(scrubbed, "ghp_push")
  assert !string.contains(scrubbed, "ghp_header")
  assert string.contains(scrubbed, "\tpushurl = https://github.com/o/r")
  assert string.contains(scrubbed, "[core]\n\tbare = false")
}

pub fn a_commented_header_does_not_take_the_listener_test() {
  let text =
    "[models.x]\n#[distribution]\nmodel_id = \"m\"\n\n[distribution]\nnode = \"a\"\n"
  let bound = vm_spec.with_loopback_listener(text)
  assert string.contains(bound, "#[distribution]\nmodel_id = \"m\"\n")
  assert string.contains(
    bound,
    "\n[distribution]\nlisten_address = \"127.0.0.1\"\nnode = \"a\"\n",
  )
}

pub fn the_orchestrator_listener_is_bound_to_loopback_test() {
  // A newly enrolled orchestrator is never dialled, so its distribution
  // listener need not face the network (protocol-change/106).
  let text =
    "[models.x]\nmodel_id = \"m\"\n\n[distribution]\nnode = \"a@127.0.0.1\"\n"
  let bound = vm_spec.with_loopback_listener(text)
  assert string.contains(
    bound,
    "[distribution]\nlisten_address = \"127.0.0.1\"\nnode = \"a@127.0.0.1\"\n",
  )

  // An address the user chose stays, and a file without the table is left as
  // it is.
  let chosen = "[distribution]\nlisten_address = \"127.0.0.2\"\n"
  assert vm_spec.with_loopback_listener(chosen) == chosen
  assert vm_spec.with_loopback_listener("[models.x]\n") == "[models.x]\n"
}

// --- setup -------------------------------------------------------------------

pub fn setup_reads_its_source_test() {
  assert vm_spec.parse(["setup"]) == Ok(vm_spec.Setup(vm_spec.OwnRelease))
  assert vm_spec.parse(["setup", "--release", "v0.3.0"])
    == Ok(vm_spec.Setup(vm_spec.ReleaseTag("v0.3.0")))
  assert vm_spec.parse(["setup", "--from-build", "/b"])
    == Ok(vm_spec.Setup(vm_spec.BuildTree("/b")))
}

pub fn setup_refuses_two_sources_and_stray_words_test() {
  let both = "setup takes one of --release TAG and --from-build DIR"
  assert vm_spec.parse(["setup", "--release", "v1", "--from-build", "/b"])
    == Error(both)
  assert vm_spec.parse(["setup", "--from-build", "/b", "--release", "v1"])
    == Error(both)
  assert vm_spec.parse(["setup", "--release", "v1", "--release", "v2"])
    == Error(both)
  assert vm_spec.parse(["setup", "--release"])
    == Error("--release needs a value")
  assert vm_spec.parse(["setup", "--bogus", "1"])
    == Error("unknown option --bogus")
  assert vm_spec.parse(["setup", "stray"]) == Error("unexpected argument stray")
}

fn nightly() -> String {
  string.repeat("0123456789", 4)
}

pub fn a_release_build_tries_its_nightly_tag_then_its_version_tag_test() {
  assert vm_spec.release_candidates("0.3.2", nightly())
    == Ok(["commit-" <> nightly(), "v0.3.2"])
}

pub fn a_short_or_unknown_commit_names_no_nightly_test() {
  assert vm_spec.release_candidates("0.3.2", "unknown") == Ok(["v0.3.2"])
  assert vm_spec.release_candidates("0.3.2", "4c266dde") == Ok(["v0.3.2"])
  assert vm_spec.release_candidates("0.3.2", string.repeat("a", 41))
    == Ok(["v0.3.2"])
  assert vm_spec.release_candidates("0.3.2", string.repeat("A", 40))
    == Ok(["v0.3.2"])
  assert vm_spec.release_candidates("0.3.2", "") == Ok(["v0.3.2"])
}

pub fn a_development_build_has_no_release_and_names_the_make_target_test() {
  let assert Error(reason) = vm_spec.release_candidates("dev", nightly())
  assert string.contains(reason, "make vmm-install-dev")
  assert result.is_error(vm_spec.release_candidates("", nightly()))
  assert result.is_error(vm_spec.setup_attempts(
    vm_spec.OwnRelease,
    "dev",
    nightly(),
    "/h/vm",
  ))
}

pub fn the_running_builds_release_is_one_attempt_per_candidate_test() {
  let assert Ok([first, second]) =
    vm_spec.setup_attempts(vm_spec.OwnRelease, "0.3.2", nightly(), "/h/vm")
  assert first.name == "commit-" <> nightly()

  // Each guessed tag is told the running commit, so `loom-vm` refuses an image
  // of another commit before it writes anything.
  assert first.arguments
    == [
      "setup",
      "--home",
      "/h/vm",
      "--release",
      "commit-" <> nightly(),
      "--revision",
      nightly(),
    ]
  assert second.arguments
    == [
      "setup",
      "--home",
      "/h/vm",
      "--release",
      "v0.3.2",
      "--revision",
      nightly(),
    ]
}

pub fn an_unknown_commit_passes_no_revision_test() {
  let assert Ok([attempt]) =
    vm_spec.setup_attempts(vm_spec.OwnRelease, "0.3.2", "unknown", "/h")
  assert attempt.arguments == ["setup", "--home", "/h", "--release", "v0.3.2"]

  let assert Ok([short]) =
    vm_spec.setup_attempts(vm_spec.OwnRelease, "0.3.2", "4c266dd", "/h")
  assert list.contains(short.arguments, "--revision")

  let assert Ok([tiny]) =
    vm_spec.setup_attempts(vm_spec.OwnRelease, "0.3.2", "4c2", "/h")
  assert !list.contains(tiny.arguments, "--revision")
}

pub fn a_named_release_or_tree_is_one_attempt_without_a_revision_test() {
  let assert Ok([release]) =
    vm_spec.setup_attempts(vm_spec.ReleaseTag("v0.2.0"), "dev", "unknown", "/h")
  assert release.arguments == ["setup", "--home", "/h", "--release", "v0.2.0"]

  let assert Ok([tree]) =
    vm_spec.setup_attempts(vm_spec.BuildTree("/b"), "dev", "unknown", "/h")
  assert tree.arguments == ["setup", "--home", "/h", "--from-build", "/b"]
}

pub fn a_failed_setup_names_each_tag_with_its_reason_in_one_line_test() {
  let text =
    vm_spec.setup_failure(vm_spec.OwnRelease, [
      #("commit-abc", "loom-vm setup exited with status 1\n"),
      #("v0.3.2", "it holds revision def, not this build's abc"),
    ])
  assert string.contains(text, "commit-abc: loom-vm setup exited with status 1")
  assert string.contains(text, "v0.3.2: it holds revision def")
  assert string.contains(text, "may not be published for this build yet")
  assert string.contains(text, "loom vm setup --release TAG")
  assert !string.contains(text, "\n")

  let named = vm_spec.setup_failure(vm_spec.ReleaseTag("v1"), [#("v1", "x")])
  assert !string.contains(named, "may not be published")
}

pub fn a_missing_manifest_names_the_way_to_make_one_test() {
  let release = vm_spec.missing_manifest("/h/manifest.json", "0.3.2")
  assert string.contains(release, "/h/manifest.json does not exist")
  assert string.contains(release, "`loom vm setup`")

  let development = vm_spec.missing_manifest("/h/manifest.json", "dev")
  assert string.contains(development, "make vmm-install-dev")
  assert !string.contains(development, "`loom vm setup`")
}

// --- a linked worktree's repository ------------------------------------------

fn commit() -> String {
  string.repeat("ab", 20)
}

pub fn a_branch_head_keeps_its_ref_and_commit_test() {
  assert vm_spec.head_target("refs/heads/feature/x\n", commit() <> "\n")
    == Ok(vm_spec.OnBranch("refs/heads/feature/x", commit()))
  assert vm_spec.head_arguments(vm_spec.OnBranch("refs/heads/m", commit()))
    == [
      ["update-ref", "refs/heads/m", commit()],
      ["symbolic-ref", "HEAD", "refs/heads/m"],
    ]
}

pub fn a_detached_head_keeps_its_commit_test() {
  assert vm_spec.head_target("HEAD\n", commit())
    == Ok(vm_spec.Detached(commit()))
  assert vm_spec.head_arguments(vm_spec.Detached(commit()))
    == [["update-ref", "--no-deref", "HEAD", commit()]]
}

pub fn an_odd_head_is_refused_not_passed_to_git_test() {
  assert result.is_error(vm_spec.head_target("refs/tags/v1", commit()))
  assert result.is_error(vm_spec.head_target("refs/heads/a b", commit()))
  assert result.is_error(vm_spec.head_target("HEAD", "not-a-commit"))
  assert result.is_error(vm_spec.head_target("HEAD", string.repeat("a", 39)))
  assert result.is_error(vm_spec.head_target("HEAD", string.repeat("A", 40)))
}

pub fn the_clone_checks_out_nothing_and_links_nothing_test() {
  assert vm_spec.clone_arguments("/w", "/s")
    == ["clone", "--quiet", "--no-checkout", "--no-local", "/w", "/s"]
}

pub fn origin_is_the_sources_own_or_none_test() {
  assert vm_spec.origin_arguments("https://github.com/o/r\n")
    == ["remote", "set-url", "origin", "https://github.com/o/r"]
  assert vm_spec.origin_arguments("\n") == ["remote", "remove", "origin"]
  assert vm_spec.origin_arguments("") == ["remote", "remove", "origin"]
}

pub fn a_git_failure_is_one_line_that_names_the_worktree_test() {
  let reason = vm_spec.git_refusal("/w/proj", "git exited with status 128")
  assert string.contains(reason, "/w/proj")
  assert string.contains(reason, "status 128")
  assert !string.contains(reason, "\n")
}

// --- the daemon that was running ---------------------------------------------

pub fn the_session_count_is_the_status_replys_occupied_test() {
  assert vm_spec.occupied_sessions(
      json.Object([#("resident", json.Int(0)), #("occupied", json.Int(3))]),
    )
    == Ok(3)
  assert result.is_error(vm_spec.occupied_sessions(json.Object([])))
  assert result.is_error(
    vm_spec.occupied_sessions(json.Object([#("occupied", json.Int(-1))])),
  )
  assert result.is_error(
    vm_spec.occupied_sessions(json.Object([#("occupied", json.String("2"))])),
  )
  assert result.is_error(vm_spec.occupied_sessions(json.Int(2)))
}

pub fn only_a_daemon_that_counts_none_is_stopped_test() {
  assert vm_spec.daemon_step(7, vm_spec.Counted(0)) == vm_spec.StopIt
}

pub fn a_daemon_with_sessions_is_never_stopped_test() {
  // The decision is where it is made: any count above zero leaves the daemon
  // alone, whatever the count.
  assert vm_spec.daemon_step(7, vm_spec.Counted(1))
    == vm_spec.LeaveAlone(vm_spec.Holding(7, 1))
  assert vm_spec.daemon_step(7, vm_spec.Counted(40))
    == vm_spec.LeaveAlone(vm_spec.Holding(7, 40))
}

pub fn a_daemon_that_said_nothing_is_never_stopped_test() {
  assert vm_spec.daemon_step(9, vm_spec.Uncounted)
    == vm_spec.LeaveAlone(vm_spec.Unasked(9))
}

pub fn a_stopped_daemon_is_said_to_restart_with_the_next_loom_test() {
  let text = string.join(vm_spec.daemon_note(vm_spec.Stopped), "\n")
  assert string.contains(text, "was stopped")
  assert string.contains(text, "next `loom` command starts it")
  assert !string.contains(text, "kill")
}

pub fn an_idle_daemon_that_would_not_stop_gets_the_command_test() {
  let text =
    vm_spec.daemon_note(vm_spec.NotStopped(7, "still running"))
    |> string.join("\n")
  assert string.contains(text, "still running")
  assert string.contains(text, "kill -TERM 7")
}

pub fn a_daemon_with_sessions_gets_the_command_and_a_count_test() {
  let text =
    vm_spec.daemon_note(vm_spec.Holding(7, 2))
    |> string.join("\n")
  assert string.contains(text, "holds 2 sessions")
  assert string.contains(text, "left running")
  assert string.contains(text, "kill -TERM 7")
  assert string.contains(
    string.join(vm_spec.daemon_note(vm_spec.Holding(7, 1)), ""),
    "holds 1 session,",
  )
}

pub fn a_daemon_that_said_nothing_is_left_running_test() {
  let text =
    vm_spec.daemon_note(vm_spec.Unasked(9))
    |> string.join("\n")
  assert string.contains(text, "left running")
  assert string.contains(text, "kill -TERM 9")
}

pub fn no_daemon_means_the_next_loom_starts_one_test() {
  let text =
    vm_spec.daemon_note(vm_spec.NoDaemon)
    |> string.join("\n")
  assert string.contains(text, "next `loom` command starts the daemon")
  assert !string.contains(text, "kill")
}

// --- links in the guest root ---------------------------------------------------

// A scratch directory with a guest root and a directory outside it, both real.
fn scratch_root() -> #(String, String, String) {
  let name =
    token.production_entropy()(4) |> bit_array.base16_encode |> string.lowercase
  let scratch = "/var/tmp/loom-vm-inside-" <> name
  let root = scratch <> "/root"
  let outside = scratch <> "/outside"
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) = simplifile.create_directory_all(outside)
  #(scratch, root, outside)
}

pub fn directories_under_a_real_root_are_made_test() {
  let #(scratch, root, _) = scratch_root()
  assert vm_cli.make_inside(root, "/srv/loom-node/home") == Ok(Nil)
  assert simplifile.is_directory(root <> "/srv/loom-node/home") == Ok(True)

  // Making them again is not an error.
  assert vm_cli.make_inside(root, "/srv/loom-node/home") == Ok(Nil)
  let assert Ok(Nil) = simplifile.delete_all([scratch])
}

pub fn a_link_out_of_the_root_is_refused_and_the_target_untouched_test() {
  let #(scratch, root, outside) = scratch_root()

  // A link where a middle component belongs: nothing below it may be made.
  let assert Ok(Nil) = simplifile.create_symlink(outside, root <> "/srv")
  let assert Error(reason) = vm_cli.make_inside(root, "/srv/loom-node/home")
  assert string.contains(reason, root <> "/srv")
  assert string.contains(reason, "--fresh")
  assert simplifile.read_directory(outside) == Ok([])

  // A link at the last component, with the parents real.
  let assert Ok(Nil) = simplifile.delete(root <> "/srv")
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/etc")
  let assert Ok(Nil) =
    simplifile.create_symlink(outside, root <> "/etc/loom-vm")
  let assert Error(reason) = vm_cli.make_inside(root, "/etc/loom-vm")
  assert string.contains(reason, "--fresh")
  assert simplifile.read_directory(outside) == Ok([])

  // A link to nothing is refused as well.
  let assert Ok(Nil) = simplifile.delete(root <> "/etc/loom-vm")
  let assert Ok(Nil) =
    simplifile.create_symlink(scratch <> "/absent", root <> "/etc/loom-vm")
  assert result.is_error(vm_cli.make_inside(root, "/etc/loom-vm"))
  assert simplifile.read_directory(outside) == Ok([])

  let assert Ok(Nil) = simplifile.delete_all([scratch])
}

// --- logs, list, rm and sync: the command line -------------------------------

pub fn logs_takes_a_name_and_a_line_count_test() {
  assert vm_spec.parse(["logs"]) == Ok(vm_spec.Logs("vm", 100))
  assert vm_spec.parse(["logs", "--lines", "5", "--name", "dev"])
    == Ok(vm_spec.Logs("dev", 5))
  assert result.is_error(vm_spec.parse(["logs", "--lines", "0"]))
  assert result.is_error(vm_spec.parse(["logs", "--lines", "100001"]))
  assert result.is_error(vm_spec.parse(["logs", "--lines", "many"]))
  assert vm_spec.parse(["logs", "--lines"]) == Error("--lines needs a value")
  assert vm_spec.parse(["logs", "--follow"]) == Error("--follow needs a value")
}

pub fn list_takes_nothing_test() {
  assert vm_spec.parse(["list"]) == Ok(vm_spec.Guests)
  assert vm_spec.parse(["list", "--name", "x"])
    == Error("unexpected argument --name")
}

pub fn rm_needs_yes_to_be_confirmed_test() {
  assert vm_spec.parse(["rm"])
    == Ok(vm_spec.Remove("vm", None, vm_spec.Unconfirmed))
  assert vm_spec.parse(["rm", "--yes", "--name", "dev", "--config", "/c.toml"])
    == Ok(vm_spec.Remove("dev", Some("/c.toml"), vm_spec.Confirmed))
  assert result.is_error(vm_spec.parse(["rm", "--name", "Bad Name"]))
  assert vm_spec.parse(["rm", "--config"]) == Error("--config needs a value")
}

pub fn sync_reads_its_flags_test() {
  let assert Ok(vm_spec.Sync(options)) = vm_spec.parse(["sync"])
  assert options == vm_spec.SyncOptions("vm", None, None, vm_spec.FromGuest)

  let assert Ok(vm_spec.Sync(options)) =
    vm_spec.parse([
      "sync", "--to-guest", "--workspace", "proj", "--checkout", "/src/proj",
      "--name", "dev",
    ])
  assert options
    == vm_spec.SyncOptions(
      "dev",
      Some("proj"),
      Some("/src/proj"),
      vm_spec.ToGuest,
    )
  assert result.is_error(vm_spec.parse(["sync", "--workspace", "../x"]))
  assert result.is_error(vm_spec.parse(["sync", "--exec", "ls"]))
}

pub fn usage_names_the_daily_verbs_test() {
  assert string.contains(vm_cli.usage, "loom vm logs [--name NAME] [--lines N]")
  assert string.contains(vm_cli.usage, "loom vm list")
  assert string.contains(vm_cli.usage, "loom vm rm [--name NAME]")
  assert string.contains(vm_cli.usage, "[--to-guest]")
  assert !string.contains(vm_cli.usage, "loom vm shell")
}

// --- text a guest wrote ------------------------------------------------------

pub fn printable_text_loses_terminal_controls_test() {
  // An escape sequence, a carriage return, a bell, DEL, a C1 control and a
  // right-to-left override all go; a newline stays and a tab becomes a space.
  assert vm_spec.printable("a\u{1b}[31mb\rc\u{7}d\u{7f}e\u{9b}f\u{202e}g\nh\ti")
    == "a[31mbcdefg\nh i"
  assert vm_spec.printable("loom/session-é") == "loom/session-é"
}

// --- where a workspace came from ---------------------------------------------

pub fn the_checkouts_record_round_trips_test() {
  let entries = [#("proj", "/src/proj"), #("other", "/src/other dir")]
  assert vm_spec.decode_checkouts(vm_spec.encode_checkouts(entries))
    == Ok(entries)
  assert vm_spec.decode_checkouts("") == Ok([])
}

pub fn the_checkouts_record_is_total_and_strict_test() {
  // A later line for a workspace replaces the earlier one.
  assert vm_spec.decode_checkouts("a\t/x\n\na\t/y\n") == Ok([#("a", "/y")])

  let assert Error(reason) = vm_spec.decode_checkouts("a /x\n")
  assert string.contains(reason, "line 1")
  let assert Error(reason) = vm_spec.decode_checkouts("a\t/x\n../x\t/y\n")
  assert string.contains(reason, "line 2")
  assert result.is_error(vm_spec.decode_checkouts("a\trelative\n"))
  assert result.is_error(vm_spec.decode_checkouts("a\t/x\u{1b}[2J\n"))
}

pub fn a_checkout_path_must_be_recordable_test() {
  assert vm_spec.valid_checkout_path("/src/my proj") == Ok(Nil)
  assert result.is_error(vm_spec.valid_checkout_path("src"))
  assert result.is_error(vm_spec.valid_checkout_path("/src/a\nb"))
  assert result.is_error(vm_spec.valid_checkout_path("/src/a\tb"))
}

pub fn recording_a_checkout_replaces_that_workspace_only_test() {
  let entries = [#("a", "/x"), #("b", "/y")]
  assert vm_spec.record_checkout(entries, "a", "/z")
    == [#("b", "/y"), #("a", "/z")]
  assert vm_spec.checkout_of(entries, "b") == Some("/y")
  assert vm_spec.checkout_of(entries, "c") == None
}

// --- sync --------------------------------------------------------------------

pub fn the_fetch_runs_in_the_developers_checkout_with_the_copy_as_remote_test() {
  let copy = "/vm/dev/root/srv/workspaces/proj"
  let arguments = vm_spec.fetch_arguments("/src/proj", copy)

  // The repository is the developer's checkout and nothing else is `-C`.
  assert list.take(arguments, 2) == ["-C", "/src/proj"]
  assert list.count(arguments, fn(argument) { argument == "-C" }) == 1

  // The copy is only the remote, followed by the one refspec into
  // `refs/remotes/vm/*`.
  assert list.drop(arguments, list.length(arguments) - 2)
    == [copy, "+refs/heads/*:refs/remotes/vm/*"]
  assert list.count(arguments, fn(argument) { string.contains(argument, copy) })
    == 1

  // The hardening the guest's untrusted objects and configuration call for.
  assert list.contains(arguments, "transfer.fsckObjects=true")
  assert list.contains(arguments, "fetch.fsckObjects=true")
  assert list.contains(arguments, "core.hooksPath=/dev/null")
  assert list.contains(arguments, "--no-tags")
  assert list.contains(arguments, "--no-recurse-submodules")
  assert !list.contains(arguments, "--recurse-submodules")

  // The file transport is allowed for a plain fetch, so the override that
  // would also allow it from a submodule is not given.
  assert !string.contains(string.join(arguments, " "), "protocol.file.allow")
}

pub fn the_bundle_is_made_in_the_developers_checkout_test() {
  assert vm_spec.bundle_arguments("/src/proj", "/vm/dev/to-guest.bundle")
    == [
      "-C", "/src/proj", "bundle", "create", "--quiet",
      "/vm/dev/to-guest.bundle", "--branches",
    ]
  assert vm_spec.bundle_guest_path("proj") == "/srv/host-refs/proj.bundle"
  assert vm_spec.guest_fetch_command("proj")
    == "git fetch /srv/host-refs/proj.bundle '+refs/heads/*:refs/remotes/host/*'"
}

pub fn sync_picks_the_only_workspace_or_asks_test() {
  assert vm_spec.only_workspace(["proj"], None) == Ok("proj")
  assert vm_spec.only_workspace(["a", "b"], Some("b")) == Ok("b")

  let assert Error(reason) = vm_spec.only_workspace(["a", "b"], None)
  assert string.contains(reason, "--workspace")
  assert string.contains(reason, "a, b")
  let assert Error(reason) = vm_spec.only_workspace(["a"], Some("z"))
  assert string.contains(reason, "no workspace z")
  assert result.is_error(vm_spec.only_workspace([], None))
}

pub fn the_removal_refusal_lists_the_workspaces_test() {
  let text = vm_spec.removal_refusal("dev", Ok(["proj", "other\u{1b}[2J"]))
  assert string.contains(text, "  proj")
  assert string.contains(text, "  other[2J")
  assert !string.contains(text, "\u{1b}")
  assert string.contains(
    text,
    "Fetch committed work first with `loom vm sync`; uncommitted edits cannot be fetched. Run again with --yes to delete it.",
  )
  assert string.contains(
    vm_spec.removal_refusal("dev", Ok([])),
    "no workspace copy",
  )
  assert string.contains(
    vm_spec.removal_refusal("dev", Error("a link")),
    "unreadable (a link)",
  )
}

// --- the deployment is a membership ledger -----------------------------------

fn minted_ledger(name: String) -> distribution_provision.Provisioned {
  let assert Ok(made) =
    distribution_provision.provision_ledger(
      plan_of(name),
      timestamp.system_time(),
    )
  made
}

fn bundle_of(
  made: distribution_provision.Provisioned,
  name: String,
) -> distribution_bundle.Bundle {
  let assert Ok(bundle) =
    list.find(made.deployment.bundles, fn(bundle) { bundle.name == name })
  bundle
}

fn installed_files(directory: String) -> distribution.CredentialFiles {
  distribution.CredentialFiles(
    ca: directory <> "/ca.pem",
    certificate: directory <> "/cert.pem",
    key: directory <> "/key.pem",
    cookie: "/h/.erlang.cookie",
  )
}

pub fn no_distribution_table_is_no_deployment_test() {
  assert vm_spec.deployment_state("") == Ok(vm_spec.NoDeployment)
  assert vm_spec.deployment_state("[models.m]\nmodel_id = \"x\"\n")
    == Ok(vm_spec.NoDeployment)

  // A commented header is not a table, which a substring match would miss.
  assert vm_spec.deployment_state("# [distribution]\nledger = \"/x\"\n")
    == Ok(vm_spec.NoDeployment)
}

pub fn a_ledger_key_makes_a_ledger_deployment_test() {
  let made = minted_ledger("dev")
  let orchestrator = bundle_of(made, "dev-host")
  let text =
    distribution_bundle.config_text(
      orchestrator,
      installed_files("/vm/dev/orch"),
    )
  assert vm_spec.deployment_state(text)
    == Ok(vm_spec.LedgerDeployment("/vm/dev/orch/ledger.log"))
}

pub fn listed_peers_make_a_static_deployment_test() {
  let #(orchestrator, _) = bundles("dev")
  let text =
    distribution_bundle.config_text(
      orchestrator,
      installed_files("/vm/dev/orch"),
    )
  assert string.contains(text, "[[distribution.peers]]")
  assert vm_spec.deployment_state(text) == Ok(vm_spec.StaticDeployment)
}

pub fn a_table_the_daemon_would_refuse_is_an_error_test() {
  assert result.is_error(vm_spec.deployment_state("[distribution\n"))
  assert result.is_error(vm_spec.deployment_state(
    "[distribution]\nnode = \"not a node\"\n",
  ))
}

pub fn the_guest_enrols_as_an_executor_linked_to_the_orchestrator_test() {
  let request = vm_spec.guest_enrollment(vm_spec.names("dev"), "laptop")
  assert request.name == "dev"
  assert request.node == "loom_vm_dev_exec@127.0.0.1"
  assert request.role == distribution_plan.Executor
  assert request.host == Some("127.0.0.1")
  assert request.listen_port == Some(vm_spec.guest_port)
  assert request.links == ["laptop"]
  assert request.workspaces == []
  assert request.bundle_dir == None
  assert request.directory == membership_entry.NotInDirectory
  assert ledger_operator.check_enrollment(request) == Ok(Nil)
}

pub fn an_enrolment_without_the_orchestrator_link_is_refused_test() {
  let request = vm_spec.guest_enrollment(vm_spec.names("dev"), "laptop")
  let linkless = ledger_operator.Enrollment(..request, links: [])
  assert result.is_error(ledger_operator.check_enrollment(linkless))
}

pub fn a_ledger_deployment_installs_a_ledger_table_test() {
  let made = minted_ledger("dev")
  let orchestrator = bundle_of(made, "dev-host")
  assert orchestrator.trust != distribution_bundle.StaticPeers([])
  let assert distribution_bundle.SignedLedger(lines) = orchestrator.trust
  assert lines != []

  // The table names the ledger and lists no peer, and the executor row the
  // plan gave the orchestrator is still written.
  let text =
    distribution_bundle.config_text(
      orchestrator,
      installed_files("/vm/dev/orch"),
    )
  assert string.contains(text, "ledger = \"/vm/dev/orch/ledger.log\"")
  assert !string.contains(text, "[[distribution.peers]]")
  let assert Ok(document) = tom.parse(text)
  assert tom.get_string(document, ["executors", "dev", "node"])
    == Ok("loom_vm_dev_exec@127.0.0.1")

  // The loopback listener lands in the same table and the daemon still reads
  // it as a ledger table.
  let bound = vm_spec.with_loopback_listener(text)
  let assert Ok(bound_document) = tom.parse(bound)
  assert tom.get_string(bound_document, ["distribution", "listen_address"])
    == Ok("127.0.0.1")
  assert vm_spec.deployment_state(bound)
    == Ok(vm_spec.LedgerDeployment("/vm/dev/orch/ledger.log"))
}

pub fn the_guest_configuration_names_the_ledger_beside_its_credentials_test() {
  let made = minted_ledger("dev")
  let text =
    vm_spec.guest_config(
      bundle_of(made, "dev"),
      ["proj"],
      vm_spec.GitHubOff,
      [],
    )
  let assert Ok(document) = tom.parse(text)
  assert tom.get_string(document, ["distribution", "ledger"])
    == Ok("/srv/loom-node/creds/ledger.log")
  assert result.is_error(tom.get_array(document, ["distribution", "peers"]))
}

pub fn no_bundle_holds_the_authority_key_test() {
  let made = minted_ledger("dev")
  assert string.contains(made.authority.key, "PRIVATE KEY")
  list.each(made.deployment.bundles, fn(bundle) {
    let text = distribution_bundle.encode(bundle)
    assert !string.contains(text, made.authority.key)
    assert !string.contains(text, string.trim(made.authority.key))
  })

  // The executor's configuration, which goes into the guest, holds neither.
  let configuration =
    vm_spec.guest_config(bundle_of(made, "dev"), [], vm_spec.GitHubOff, [])
  assert !string.contains(configuration, "PRIVATE KEY")
}

pub fn a_bundle_names_its_deployment_only_in_ledger_mode_test() {
  let made = minted_ledger("dev")
  assert vm_spec.bundle_deployment(bundle_of(made, "dev"))
    == Ok(made.authority.deployment)
  let #(_, static) = bundles("dev")
  assert vm_spec.bundle_deployment(static) == Error(Nil)
}

pub fn a_guest_cannot_be_called_authority_test() {
  assert result.is_error(vm_spec.valid_name(vm_spec.authority_dir))
  assert result.is_error(vm_spec.parse(["up", "--name", "authority"]))
  assert vm_spec.authority_directory("/h/vm", "3f9c") == "/h/vm/authority/3f9c"
}

// A scratch vm home below /var/tmp, which no jail replaces.
fn scratch_home() -> String {
  let name =
    token.production_entropy()(4) |> bit_array.base16_encode |> string.lowercase
  let home = "/var/tmp/loom-vm-home-" <> name
  let assert Ok(Nil) = simplifile.create_directory_all(home)
  home
}

pub fn the_key_is_sealed_under_a_generated_passphrase_file_test() {
  let home = scratch_home()
  let made = minted_ledger("dev")
  let directory = vm_spec.authority_directory(home, made.authority.deployment)
  assert vm_cli.seal_authority(directory, made) == Ok(Nil)

  // The passphrase file is private to its owner and a terminal is not needed
  // to read it back and open the key.
  let file = directory <> "/" <> vm_spec.passphrase_file
  let assert Ok(info) = simplifile.file_info(file)
  assert int.bitwise_and(simplifile.file_info_permissions_octal(info), 0o777)
    == 0o600
  let assert Ok(passphrase) = authority_key.passphrase_from_file(file)
  assert authority_key.load(directory, made.authority.deployment, passphrase)
    == Ok(made.authority.key)

  // The ledger copy and the cookie are kept beside the key.
  assert authority_key.is_kept(directory)
  assert authority_key.cookie(directory) == Ok(made.authority.cookie)

  // A second guest gets a passphrase of its own.
  let other = minted_ledger("dev")
  let other_directory =
    vm_spec.authority_directory(home, other.authority.deployment)
  assert vm_cli.seal_authority(other_directory, other) == Ok(Nil)
  let assert Ok(first) = simplifile.read(file)
  let assert Ok(second) =
    simplifile.read(other_directory <> "/" <> vm_spec.passphrase_file)
  assert first != second
  let assert Ok(Nil) = simplifile.delete_all([home])
}

fn write_guest(
  home: String,
  name: String,
  deployment: distribution_provision.Deployment,
) -> Nil {
  let assert Ok(_) =
    distribution_provision.write(
      deployment,
      home <> "/" <> name <> "/deploy",
      distribution_provision.RefuseExisting,
    )
  Nil
}

pub fn removing_a_guest_finds_the_key_it_sealed_test() {
  let home = scratch_home()
  let made = minted_ledger("dev")
  let directory = vm_spec.authority_directory(home, made.authority.deployment)
  write_guest(home, "dev", made.deployment)
  assert vm_cli.removable_authority(home, "dev") == None
  assert vm_cli.seal_authority(directory, made) == Ok(Nil)
  assert vm_cli.removable_authority(home, "dev") == Some(directory)

  // Another guest with its own deployment does not hold it, and a guest with
  // no bundles has nothing.
  let other = minted_ledger("other")
  write_guest(home, "other", other.deployment)
  assert vm_cli.removable_authority(home, "dev") == Some(directory)
  assert vm_cli.removable_authority(home, "absent") == None
  let assert Ok(Nil) = simplifile.delete_all([home])
}

pub fn a_guest_minted_statically_has_no_key_to_remove_test() {
  let home = scratch_home()
  let assert Ok(static) = distribution_provision.provision(plan_of("dev"))
  write_guest(home, "dev", static)
  assert vm_cli.removable_authority(home, "dev") == None
  let assert Ok(Nil) = simplifile.delete_all([home])
}

pub fn the_ledger_is_staged_once_beside_the_credentials_test() {
  let #(scratch, root, _) = scratch_root()
  let made = minted_ledger("dev")
  let executor = bundle_of(made, "dev")
  let assert Ok(Nil) = vm_cli.make_inside(root, "/srv/loom-node/creds")
  let path = root <> "/srv/loom-node/creds/ledger.log"
  let assert distribution_bundle.SignedLedger(lines) = executor.trust

  assert vm_cli.stage_ledger(root, executor, None) == Ok(Nil)
  assert simplifile.read(path) == Ok(string.join(lines, "\n") <> "\n")

  // A file the executor has since extended is never written over.
  let assert Ok(Nil) = simplifile.write(path, "synced\n")
  assert vm_cli.stage_ledger(root, executor, None) == Ok(Nil)
  assert simplifile.read(path) == Ok("synced\n")

  // A static bundle stages no ledger.
  let #(_, static) = bundles("dev")
  let assert Ok(Nil) = simplifile.delete(path)
  assert vm_cli.stage_ledger(root, static, None) == Ok(Nil)
  assert simplifile.is_file(path) == Ok(False)
  let assert Ok(Nil) = simplifile.delete_all([scratch])
}

// --- joining a deployment ----------------------------------------------------

pub fn the_daemon_is_found_in_the_installed_ledger_test() {
  let made = minted_ledger("dev")
  let assert Ok(membership) =
    vm_spec.orchestrator_membership(
      made.authority.certificate,
      made.ledger,
      "loom_vm_dev_orch@127.0.0.1",
    )
  assert membership.deployment == made.authority.deployment
  assert membership.member == "dev-host"

  // The executor is a member too, but a guest links to an orchestrator.
  let assert Error(reason) =
    vm_spec.orchestrator_membership(
      made.authority.certificate,
      made.ledger,
      "loom_vm_dev_exec@127.0.0.1",
    )
  assert string.contains(reason, "only an orchestrator")
  assert result.is_error(vm_spec.orchestrator_membership(
    made.authority.certificate,
    made.ledger,
    "nobody@127.0.0.1",
  ))

  // A ledger of another authority does not replay.
  let other = minted_ledger("dev")
  assert result.is_error(vm_spec.orchestrator_membership(
    other.authority.certificate,
    made.ledger,
    "loom_vm_dev_orch@127.0.0.1",
  ))
}

pub fn a_joined_guest_takes_nothing_from_the_configuration_test() {
  let teardown = vm_spec.joined_teardown()
  assert teardown.tables == []
  assert teardown.cookie == vm_spec.KeepCookie
  let assert [line] = teardown.left
  assert string.contains(line, "[distribution] and the cookie")
}

// A deployment with two executors, `dev` (which also minted it) and `other`,
// both written under the vm home the way a mint and a join leave them.
fn two_guest_deployment() -> distribution_provision.Provisioned {
  let dev = vm_spec.names("dev")
  let other = vm_spec.names("other")
  let node = fn(name, role, erlang_node, port, uses) {
    distribution_plan.Node(
      name:,
      role:,
      erlang_node:,
      host: "127.0.0.1",
      listen_port: port,
      bundle_dir: None,
      executors: uses,
      workspaces: [],
    )
  }
  let assert Ok(plan) =
    distribution_plan.validate(
      distribution_plan.Plan(
        nodes: [
          node(
            dev.orchestrator,
            distribution_plan.Orchestrator,
            dev.orchestrator_node,
            None,
            ["dev", "other"],
          ),
          node(
            "dev",
            distribution_plan.Executor,
            dev.executor_node,
            Some(4370),
            [],
          ),
          node(
            "other",
            distribution_plan.Executor,
            other.executor_node,
            Some(4371),
            [],
          ),
        ],
        directory: [],
      ),
    )
  let assert Ok(made) =
    distribution_provision.provision_ledger(plan, timestamp.system_time())
  made
}

pub fn the_key_stays_while_a_guest_of_its_deployment_remains_test() {
  let home = scratch_home()
  let made = two_guest_deployment()
  let directory = vm_spec.authority_directory(home, made.authority.deployment)
  write_guest(home, "dev", made.deployment)
  write_guest(home, "other", made.deployment)
  assert vm_cli.seal_authority(directory, made) == Ok(Nil)

  // Each guest's executor bundle names the same deployment, so neither takes
  // the key with it while the other is there.
  assert vm_cli.removable_authority(home, "dev") == None
  assert vm_cli.removable_authority(home, "other") == None

  // The last one takes it.
  let assert Ok(Nil) = simplifile.delete_all([home <> "/dev"])
  assert vm_cli.removable_authority(home, "other") == Some(directory)
  let assert Ok(Nil) = simplifile.delete_all([home])
}

// Runs the first `count` steps of an upgrade in a scratch directory whose old
// root holds the real workspace and whose clone holds a shipped one, and says
// where the workspace is and what `up` would do next.
fn upgrade_stopped_after(count: Int) -> #(Bool, Bool, vm_spec.RootStep) {
  let #(scratch, root, _) = scratch_root()
  let building = scratch <> "/root.building"
  let next = scratch <> "/root.next"
  let assert Ok(Nil) =
    simplifile.create_directory_all(root <> "/srv/workspaces/real")
  let assert Ok(Nil) =
    simplifile.create_directory_all(building <> "/srv/workspaces/shipped")
  let steps =
    vm_cli.upgrade_steps(Some(root <> "/srv/workspaces"), building, next)
  list.take(steps, count)
  |> list.each(fn(step) {
    assert step() == Ok(Nil)
  })

  let in_old =
    simplifile.is_directory(root <> "/srv/workspaces/real") == Ok(True)
  let in_next =
    simplifile.is_directory(next <> "/srv/workspaces/real") == Ok(True)

  // What `up` reads: the layout is the evidence that the workspaces moved.
  let moved = case simplifile.is_directory(next <> "/srv/workspaces") {
    Ok(True) -> vm_spec.Present
    _ -> vm_spec.Absent
  }
  let step =
    vm_spec.root_step(
      vm_spec.Resume,
      vm_spec.RootLayout(vm_spec.Present, moved),
      Some("aaaaaaa"),
      "bbbbbbb",
    )
  let assert Ok(Nil) = simplifile.delete_all([scratch])
  #(in_old, in_next, step)
}

pub fn an_upgrade_never_strands_the_workspaces_between_steps_test() {
  // Stopped after each step, the workspaces are in the old root or in the new
  // one, never in the directory the clone is built in, and `up` finishes only
  // once they are in the new root. The old order moved them into the clone
  // first, so a stop after that step had them in neither place.
  list.each([0, 1, 2, 3], fn(count) {
    let #(in_old, in_next, step) = upgrade_stopped_after(count)
    assert in_old != in_next
    assert step == vm_spec.UpgradeRoot(Some("aaaaaaa"))
  })
  let #(in_old, in_next, step) = upgrade_stopped_after(4)
  assert !in_old
  assert in_next
  assert step == vm_spec.FinishUpgrade
}

pub fn a_stop_after_the_clone_is_an_upgrade_again_not_a_finish_test() {
  // `root.next` is absent while the clone is `root.building`, so the layout
  // is the one of a root that has not moved its workspaces.
  let layout = vm_spec.RootLayout(vm_spec.Present, vm_spec.Absent)
  assert vm_spec.root_step(vm_spec.Resume, layout, Some("aaaaaaa"), "bbbbbbb")
    == vm_spec.UpgradeRoot(Some("aaaaaaa"))
  let moved = vm_spec.RootLayout(vm_spec.Present, vm_spec.Present)
  assert vm_spec.root_step(vm_spec.Resume, moved, Some("aaaaaaa"), "bbbbbbb")
    == vm_spec.FinishUpgrade
}

pub fn a_root_with_no_workspace_copy_carries_nothing_test() {
  // A first `up` that stopped between the clone and the workspace copy left
  // no record and no directory, and that root is replaced without a move.
  assert vm_spec.carry_over([], vm_spec.Missing) == vm_spec.CarryNothing

  // Workspaces that are there always move, whatever the record says.
  assert vm_spec.carry_over([], vm_spec.Movable) == vm_spec.CarryWorkspaces
  assert vm_spec.carry_over(["app"], vm_spec.Movable) == vm_spec.CarryWorkspaces
}

pub fn an_unfinished_root_is_not_announced_as_an_upgrade_test() {
  // The upgrade line promises that workspaces are kept, which says the wrong
  // thing about a root that never had any.
  let line = vm_spec.unfinished_line("dev")
  assert string.contains(line, "guest dev")
  assert string.contains(line, "nothing to keep")
  assert !string.contains(line, "Upgrading")
}

pub fn recorded_workspaces_that_are_gone_refuse_the_upgrade_test() {
  // The host's record says a copy was made, so a missing directory is not a
  // first run: the upgrade would delete a root something already emptied.
  let assert vm_spec.RefuseCarry(reason) =
    vm_spec.carry_over(["app"], vm_spec.Missing)
  assert string.contains(reason, "srv/workspaces is gone")

  // A link or a file is refused with its own reason under either record.
  assert vm_spec.carry_over(["app"], vm_spec.Unsafe("x is a link"))
    == vm_spec.RefuseCarry("x is a link")
  assert vm_spec.carry_over([], vm_spec.Unsafe("x is a link"))
    == vm_spec.RefuseCarry("x is a link")
}

pub fn an_upgrade_with_nothing_to_carry_never_reads_as_a_finished_move_test() {
  // The clone ships an `srv/workspaces` of its own. With no workspaces to
  // move there is no last rename, so the new root must end with none, or the
  // next `up` would read it as a finished move.
  let #(scratch, _, _) = scratch_root()
  let building = scratch <> "/root.building"
  let next = scratch <> "/root.next"
  let assert Ok(Nil) =
    simplifile.create_directory_all(building <> "/srv/workspaces/shipped")

  let steps = vm_cli.upgrade_steps(None, building, next)
  assert list.length(steps) == 3
  list.each(steps, fn(step) {
    assert step() == Ok(Nil)
  })

  assert simplifile.is_directory(next <> "/srv") == Ok(True)
  assert simplifile.is_directory(next <> "/srv/workspaces") != Ok(True)
  assert simplifile.is_directory(building) != Ok(True)
  let assert Ok(Nil) = simplifile.delete_all([scratch])
}

pub fn a_host_copy_with_no_staged_script_is_staged_again_test() {
  // The root has neither marker nor script but the host keeps a copy: `up`
  // stopped between the clone and the staging.
  assert vm_spec.provision_plan(
      None,
      vm_spec.NeverProvisioned,
      Some("/vm/provision"),
    )
    == Ok(vm_spec.StageScript("/vm/provision"))
  assert vm_spec.provision_plan(None, vm_spec.NeverProvisioned, None)
    == Ok(vm_spec.NoScript)
  assert vm_spec.provision_plan(
      None,
      vm_spec.AlreadyProvisioned,
      Some("/vm/provision"),
    )
    == Ok(vm_spec.NoScript)
}

pub fn the_daemons_installed_ledger_is_staged_only_when_it_vouches_for_the_guest_test() {
  let made = minted_ledger("dev")
  let executor = bundle_of(made, "dev")
  let assert distribution_bundle.SignedLedger(lines) = executor.trust

  // Nothing installed, or the same ledger, gives the bundle's lines.
  assert vm_spec.ledger_to_stage(executor, None) == lines
  assert vm_spec.ledger_to_stage(executor, Some(made.ledger)) == lines

  // A ledger of another authority does not replay against the guest's, so the
  // bundle's lines are kept.
  let other = minted_ledger("dev")
  assert vm_spec.ledger_to_stage(executor, Some(other.ledger)) == lines

  // A static bundle stages nothing.
  let #(_, static) = bundles("dev")
  assert vm_spec.ledger_to_stage(static, Some(made.ledger)) == []
}

pub fn a_guests_standing_is_read_from_a_ledger_test() {
  let made = minted_ledger("dev")
  let ca = made.authority.certificate
  assert vm_spec.standing(ca, made.ledger, "dev")
    == Ok(membership_ledger.Enrolled(member_of(made, "dev")))
  assert vm_spec.standing(ca, made.ledger, "nobody")
    == Ok(membership_ledger.NotEnrolled)
  let other = minted_ledger("dev")
  assert vm_spec.standing(other.authority.certificate, made.ledger, "dev")
    == Error(Nil)
}

fn member_of(
  made: distribution_provision.Provisioned,
  name: String,
) -> membership_entry.Member {
  let assert Ok(verifier) =
    membership_signing.verifier(made.authority.certificate)
  let lines =
    string.split(made.ledger, "\n")
    |> list.filter(fn(line) { line != "" })
    |> list.map(bit_array.from_string)
  let assert Ok(ledger) = membership_ledger.replay(lines, verifier)
  let assert Ok(member) = membership_ledger.member(ledger, name)
  member
}

pub fn removal_words_its_revoke_refusal_without_force_test() {
  let refusal =
    "revoking x may strand sessions:\n  1 session\n"
    <> "Nothing was signed. Pass --force to revoke anyway."
  let worded = vm_spec.rm_revoke_refusal(refusal)
  assert !string.contains(worded, "--force")
  assert string.ends_with(worded, "Nothing was signed and nothing was removed.")
}

pub fn an_undelivered_entry_fails_the_join_and_names_the_way_on_test() {
  assert vm_spec.undelivered_refusal(
      Ok("the daemon"),
      "/b/vm2.loombundle",
      "vm2",
    )
    == Ok(Nil)
  let assert Error(reason) =
    vm_spec.undelivered_refusal(
      Error("no daemon took entry 3; run `loom distribution import FILE`."),
      "/b/vm2.loombundle",
      "vm2",
    )
  assert string.contains(reason, "/b/vm2.loombundle")
  assert string.contains(reason, "loom distribution import")
  assert string.contains(reason, "loom vm up --name vm2")
  assert string.contains(reason, "No guest was booted")
}

pub fn a_guest_the_daemon_has_not_learned_or_has_revoked_does_not_resume_test() {
  let enrolled =
    membership_ledger.Enrolled(member: member_of(minted_ledger("dev"), "dev"))
  assert vm_spec.resume_refusal("vm2", "/h/loom.toml", Ok(enrolled)) == Ok(Nil)
  assert vm_spec.resume_refusal("vm2", "/h/loom.toml", Error(Nil)) == Ok(Nil)

  let assert Error(revoked) =
    vm_spec.resume_refusal("vm2", "/h/loom.toml", Ok(membership_ledger.Revoked))
  assert string.contains(revoked, "loom vm rm --name vm2")

  // The entry never reached the daemon: import, then up again.
  let assert Error(unknown) =
    vm_spec.resume_refusal(
      "vm2",
      "/h/loom.toml",
      Ok(membership_ledger.NotEnrolled),
    )
  assert string.contains(unknown, "loom distribution import")
  assert string.contains(unknown, "loom vm up --name vm2")
}

pub fn a_member_the_copy_records_as_revoked_is_done_test() {
  let home = scratch_home()
  let made = two_guest_deployment()
  let directory = vm_spec.authority_directory(home, made.authority.deployment)
  assert vm_cli.seal_authority(directory, made) == Ok(Nil)
  let assert Ok(authority) =
    ledger_cli.unlock_at(directory, Some(directory <> "/passphrase"))
  assert !ledger_cli.is_revoked(authority, "other")

  // A daemon that answers nothing: the entry goes to the copy alone.
  let silent = fn(_) {
    ledger_sync.Daemon(
      status: fn() { Error("no daemon") },
      entries: fn(_, _) { Error("no daemon") },
      append: fn(_) { Error("no daemon") },
      holdings: fn() { Error("no daemon") },
    )
  }
  let assert Ok(_) =
    ledger_cli.revoke_member(
      authority,
      "other",
      "test",
      ledger_cli.Forced,
      admin.ThisHost(""),
      silent,
    )
  assert ledger_cli.is_revoked(authority, "other")
  assert !ledger_cli.is_revoked(authority, "dev")

  // The copy's text, read the way the daemon's installed ledger is, says the
  // same: revoked for the one, enrolled for the other.
  let assert Ok(text) = simplifile.read(directory <> "/ledger.log")
  assert vm_spec.standing(made.authority.certificate, text, "other")
    == Ok(membership_ledger.Revoked)
  let assert Ok(membership_ledger.Enrolled(..)) =
    vm_spec.standing(made.authority.certificate, text, "dev")
  let assert Ok(Nil) = simplifile.delete_all([home])
}

// --- undoing an enrolment ----------------------------------------------------

const orch_node = "loom_vm_dev_orch@127.0.0.1"

const exec_node = "loom_vm_dev_exec@127.0.0.1"

fn enrolled_text(extra: String) -> String {
  "# the user's own comment\n[models.m]\nmodel_id = \"x\"\n\n[distribution]\nnode = \""
  <> orch_node
  <> "\"\nca = \"/c/ca.pem\"\n\n[[distribution.peers]]\nnode = \""
  <> exec_node
  <> "\"\nsha256 = \"ab\"\n\n[executors.dev]\nnode = \""
  <> exec_node
  <> "\"\n"
  <> extra
}

pub fn the_guests_enrolment_is_read_from_the_configuration_test() {
  let assert Ok(found) =
    vm_spec.read_enrolment(
      enrolled_text("\n[executors.other]\nnode = \"o@h\"\n"),
      "dev",
    )
  assert found.executor_node == Some(exec_node)
  assert found.distribution_node == Some(orch_node)
  assert found.other_executors == ["other"]

  let assert Ok(empty) = vm_spec.read_enrolment("", "dev")
  assert empty == vm_spec.Enrolment(None, None, [])
  assert result.is_error(vm_spec.read_enrolment("[executors\n", "dev"))
}

pub fn a_lone_guest_takes_its_tables_and_cookie_with_it_test() {
  let assert Ok(found) = vm_spec.read_enrolment(enrolled_text(""), "dev")
  let plan =
    vm_spec.plan_teardown(vm_spec.names("dev"), found, vm_spec.CookieOurs)
  assert plan.tables == [["executors", "dev"], ["distribution"]]
  assert plan.cookie == vm_spec.RemoveCookie
  assert plan.left == []
}

pub fn another_executor_keeps_the_shared_tables_and_cookie_test() {
  let assert Ok(found) =
    vm_spec.read_enrolment(
      enrolled_text("\n[executors.other]\nnode = \"o@h\"\n"),
      "dev",
    )
  let plan =
    vm_spec.plan_teardown(vm_spec.names("dev"), found, vm_spec.CookieOurs)
  assert plan.tables == [["executors", "dev"]]
  assert plan.cookie == vm_spec.KeepCookie
  let assert [line] = plan.left
  assert string.contains(line, "[executors.other]")
  assert string.contains(line, "[distribution] and the cookie stay")
}

pub fn a_deployment_that_is_not_the_guests_is_left_test() {
  let text =
    "[distribution]\nnode = \"mine@host\"\n\n[executors.dev]\nnode = \"mine-exec@host\"\n"
  let assert Ok(found) = vm_spec.read_enrolment(text, "dev")
  let plan =
    vm_spec.plan_teardown(vm_spec.names("dev"), found, vm_spec.CookieOther)

  // Neither table is this guest's, so nothing goes and each is named.
  assert plan.tables == []
  assert plan.cookie == vm_spec.KeepCookie
  assert list.length(plan.left) == 2
}

pub fn a_cookie_that_differs_stays_when_the_tables_go_test() {
  let assert Ok(found) = vm_spec.read_enrolment(enrolled_text(""), "dev")
  let plan =
    vm_spec.plan_teardown(vm_spec.names("dev"), found, vm_spec.CookieOther)
  assert plan.tables == [["executors", "dev"], ["distribution"]]
  assert plan.cookie == vm_spec.KeepCookie
  let assert [line] = plan.left
  assert string.contains(line, ".erlang.cookie")
}

pub fn the_cookie_is_compared_with_the_deployments_test() {
  assert vm_spec.cookie_state(None, Some("c")) == vm_spec.CookieAbsent
  assert vm_spec.cookie_state(Some("c"), Some("c")) == vm_spec.CookieOurs
  assert vm_spec.cookie_state(Some("c"), Some("d")) == vm_spec.CookieOther

  // Without the bundle there is nothing to compare with.
  assert vm_spec.cookie_state(Some("c"), None) == vm_spec.CookieOther
}

pub fn removing_tables_keeps_every_other_byte_test() {
  let text =
    enrolled_text(
      "\n[executors.other]\nnode = \"o@h\"\n# the other executor's comment\n",
    )
  let assert Ok(without) =
    distribution_install.without_tables(
      text,
      [["executors", "dev"], ["distribution"]],
      "/h/loom.toml",
    )

  // The user's comment and tables survive exactly, the removed sections are
  // gone with the peers table below `[distribution]`, and the text still
  // parses.
  assert string.starts_with(
    without,
    "# the user's own comment\n[models.m]\nmodel_id = \"x\"\n\n",
  )
  assert string.ends_with(
    without,
    "[executors.other]\nnode = \"o@h\"\n# the other executor's comment\n",
  )
  assert !string.contains(without, "[distribution")
  assert !string.contains(without, "[executors.dev]")
  let assert Ok(_) = tom.parse(without)

  // Nothing to remove is the same text.
  assert distribution_install.without_tables(text, [], "/h/loom.toml")
    == Ok(text)
}

pub fn a_table_that_cannot_be_removed_by_line_refuses_the_rewrite_test() {
  // A dotted key at the top of the file defines the table without a header.
  let dotted = "executors.dev.node = \"x@h\"\n"
  let assert Error(reason) =
    distribution_install.without_tables(
      dotted,
      [["executors", "dev"]],
      "/h/loom.toml",
    )
  assert string.contains(reason, "remove it by hand")

  // Text that is not TOML is refused before anything is judged.
  let assert Error(reason) =
    distribution_install.without_tables(
      "[executors\n",
      [["executors", "dev"]],
      "/h/loom.toml",
    )
  assert string.contains(reason, "is not valid TOML")
}

pub fn every_recorded_workspace_is_registered_once_test() {
  assert vm_spec.registered_workspaces(["b", "a"], "c") == ["a", "b", "c"]
  assert vm_spec.registered_workspaces(["a"], "a") == ["a"]

  // A guest with no record registers the current copy, as before.
  assert vm_spec.registered_workspaces([], "proj") == ["proj"]
}

pub fn the_guest_configuration_has_a_row_for_each_workspace_test() {
  let #(_, executor) = bundles("dev")
  let text = vm_spec.guest_config(executor, ["a", "b"], vm_spec.GitHubOff, [])
  let assert Ok(document) = tom.parse(text)
  let assert Ok("/srv/workspaces/a") =
    tom.get_string(document, ["workspaces", "a", "root"])
  let assert Ok("/srv/workspaces/b") =
    tom.get_string(document, ["workspaces", "b", "root"])
}

pub fn logs_cap_their_bytes_before_the_capture_test() {
  assert string.contains(vm_spec.log_tail_script(), "| tail -c 4194304 |")
  assert string.contains(vm_spec.log_tail_script(), "tail -n \"$1\" \"$2\"")
  assert string.contains(vm_spec.log_tail_script(), "iconv -c")
}

pub fn git_versions_are_read_from_their_output_test() {
  assert vm_spec.git_version("git version 2.54.0 (Apple Git-155)\n")
    == Ok(#(2, 54, 0))
  assert vm_spec.git_version("git version 2.46.0.windows.1") == Ok(#(2, 46, 0))
  assert vm_spec.git_version("git version 2.45") == Ok(#(2, 45, 0))
  assert vm_spec.git_version("git version 2.47.0-rc1") == Ok(#(2, 47, 0))
  assert vm_spec.git_version("not git") == Error(Nil)
  assert vm_spec.git_version("git version next") == Error(Nil)
}

pub fn sync_needs_a_git_with_the_lazy_fetch_fix_test() {
  assert vm_spec.check_git_version("git version 2.45.1\n") == Ok(Nil)
  assert vm_spec.check_git_version("git version 2.54.0 (Apple Git-155)")
    == Ok(Nil)
  assert vm_spec.check_git_version("git version 3.0.0") == Ok(Nil)

  let assert Error(old) = vm_spec.check_git_version("git version 2.45.0")
  assert string.contains(old, "git 2.45.0")
  assert string.contains(old, "2.45.1")
  assert vm_spec.check_git_version("git version 2.39.5 (Apple Git-154)")
    == Ok(Nil)
  assert vm_spec.check_git_version("git version 2.44.1") == Ok(Nil)
  assert vm_spec.check_git_version("git version 2.46.0") == Ok(Nil)
  let assert Error(_) = vm_spec.check_git_version("git version 2.44.0")
  let assert Error(old) = vm_spec.check_git_version("git version 2.39.3")
  assert string.contains(old, "git 2.39.3")
  let assert Error(unknown) = vm_spec.check_git_version("garbage\n")
  assert string.contains(unknown, "garbage")
  assert string.contains(unknown, "2.45.1")
}

// --- the root's revision and the upgrade in place ----------------------------

pub fn root_revision_record_round_trips_test() {
  assert vm_spec.encode_root_revision("abc1234") == "abc1234\n"
  assert vm_spec.decode_root_revision("abc1234\n") == Some("abc1234")
  assert vm_spec.decode_root_revision("abc1234\nextra\n") == Some("abc1234")
}

pub fn damaged_root_revision_record_is_unknown_test() {
  assert vm_spec.decode_root_revision("") == None
  assert vm_spec.decode_root_revision("\n") == None
  assert vm_spec.decode_root_revision("a\u{1b}[31mb\n") == None
}

fn layout(
  root: vm_spec.Presence,
  moved: vm_spec.Presence,
) -> vm_spec.RootLayout {
  vm_spec.RootLayout(root:, moved:)
}

pub fn matching_root_is_kept_test() {
  let whole = layout(vm_spec.Present, vm_spec.Absent)
  assert vm_spec.root_step(vm_spec.Resume, whole, Some("abc1234"), "abc1234")
    == vm_spec.KeepRoot

  // Either commit may be abbreviated, as `check_revision` allows.
  assert vm_spec.root_step(vm_spec.Resume, whole, Some("abc1234ff"), "abc1234")
    == vm_spec.KeepRoot
}

pub fn root_of_another_revision_is_upgraded_test() {
  let whole = layout(vm_spec.Present, vm_spec.Absent)
  assert vm_spec.root_step(vm_spec.Resume, whole, Some("abc1234"), "def5678")
    == vm_spec.UpgradeRoot(Some("abc1234"))
}

pub fn root_with_no_record_is_upgraded_test() {
  let whole = layout(vm_spec.Present, vm_spec.Absent)
  assert vm_spec.root_step(vm_spec.Resume, whole, None, "def5678")
    == vm_spec.UpgradeRoot(None)
}

pub fn only_a_development_manifest_keeps_a_stale_root_test() {
  let whole = layout(vm_spec.Present, vm_spec.Absent)
  assert vm_spec.root_step(vm_spec.Resume, whole, Some("abc1234"), "dev")
    == vm_spec.KeepRoot
  assert vm_spec.root_step(vm_spec.Resume, whole, Some("dev"), "dev")
    == vm_spec.KeepRoot
  assert vm_spec.root_step(vm_spec.Resume, whole, None, "dev")
    == vm_spec.KeepRoot

  // A root recorded as `dev` under a release manifest is the mismatch the
  // upgrade closes.
  assert vm_spec.root_step(vm_spec.Resume, whole, Some("dev"), "def5678")
    == vm_spec.UpgradeRoot(Some("dev"))
}

pub fn fresh_and_missing_roots_are_cloned_test() {
  let whole = layout(vm_spec.Present, vm_spec.Absent)
  let gone = layout(vm_spec.Absent, vm_spec.Absent)
  assert vm_spec.root_step(vm_spec.Fresh, whole, Some("abc1234"), "def5678")
    == vm_spec.CloneRoot
  assert vm_spec.root_step(vm_spec.Resume, gone, None, "def5678")
    == vm_spec.CloneRoot
}

pub fn a_completed_rename_is_finished_not_repeated_test() {
  // The workspaces are in `root.next`, so only the swap remains, whether the
  // old root is hollow or already gone.
  let hollow = layout(vm_spec.Present, vm_spec.Present)
  let swapping = layout(vm_spec.Absent, vm_spec.Present)
  assert vm_spec.root_step(vm_spec.Resume, hollow, Some("abc1234"), "def5678")
    == vm_spec.FinishUpgrade
  assert vm_spec.root_step(vm_spec.Resume, swapping, Some("abc1234"), "def5678")
    == vm_spec.FinishUpgrade
}

pub fn a_guest_that_moves_its_workspaces_does_not_finish_an_upgrade_test() {
  // The step reads nothing the guest writes: a partial `root.next` and an old
  // root whose `srv/workspaces` the guest moved away show `moved` absent, so
  // the upgrade runs again from a clean `root.next`.
  let partial = layout(vm_spec.Present, vm_spec.Absent)
  assert vm_spec.root_step(vm_spec.Resume, partial, Some("abc1234"), "def5678")
    == vm_spec.UpgradeRoot(Some("abc1234"))
}

pub fn the_workspaces_slot_is_cleared_before_the_rename_test() {
  let base = "/var/tmp/loom-vm-cli-test-" <> hex_name()
  let next = base <> "/root.next"

  // An export that ships `srv/workspaces`, with something in it.
  let assert Ok(Nil) =
    simplifile.create_directory_all(next <> "/srv/workspaces/x")
  assert clear_slot(next) == Ok(Nil)
  assert simplifile.is_directory(next <> "/srv/workspaces") == Ok(False)
  assert simplifile.is_directory(next <> "/srv") == Ok(True)

  // One that ships nothing there is left alone.
  assert clear_slot(next) == Ok(Nil)
  let _ = simplifile.delete_all([base])
  Nil
}

fn clear_slot(next: String) -> Result(Nil, String) {
  vm_cli.clear_workspaces_slot(next)
}

fn hex_name() -> String {
  token.production_entropy()(4)
  |> bit_array.base16_encode
  |> string.lowercase
}

pub fn upgrade_line_is_one_line_naming_both_revisions_test() {
  let line = vm_spec.upgrade_line("vm", Some("abc1234"), "def5678")
  assert !string.contains(line, "\n")
  assert string.contains(line, "Upgrading the guest vm in place")
  assert string.contains(line, "abc1234")
  assert string.contains(line, "def5678")
  assert string.contains(line, "/home/loom, /work and tools installed by hand")
  assert string.contains(vm_spec.upgrade_line("vm", None, "def5678"), "none")
}

pub fn upgrade_refusal_names_fresh_test() {
  let reason = vm_spec.upgrade_refusal("/vm/root/srv is not a directory")
  assert string.contains(reason, "--fresh")
  assert string.contains(reason, "/vm/root/srv is not a directory")
}

pub fn new_root_is_provisioned_from_the_host_copy_test() {
  assert vm_spec.new_root_provision(
      None,
      Some("/vm/provision"),
      vm_spec.AlreadyProvisioned,
    )
    == Ok(vm_spec.StageScript("/vm/provision"))
  assert vm_spec.new_root_provision(
      Some("/s.sh"),
      Some("/vm/provision"),
      vm_spec.AlreadyProvisioned,
    )
    == Ok(vm_spec.StageScript("/s.sh"))
  assert vm_spec.new_root_provision(None, None, vm_spec.NeverProvisioned)
    == Ok(vm_spec.NoScript)
}

pub fn provisioned_root_with_no_copy_cannot_be_upgraded_test() {
  let refused =
    vm_spec.new_root_provision(None, None, vm_spec.AlreadyProvisioned)
  let assert Error(reason) = refused
  assert string.contains(reason, "--provision")
  assert string.contains(reason, "--fresh")
  assert result.is_error(vm_spec.new_root_provision(
    None,
    None,
    vm_spec.FailedBefore,
  ))
}

pub fn stranded_runner_is_found_by_its_root_or_disk_test() {
  let runner =
    "{\"root_path\":\"/vm/m/root\",\"disks\":[{\"block_id\":\"state\","
    <> "\"path\":\"/vm/m/state.img\"}]}"
  let listing =
    "16329     1 /bin/loom-vm run --root-dir /vm/m/root --state-disk /vm/m/state.img\n"
    <> "16333     1 /build/go-microvm-runner "
    <> runner
    <> "\n"
    <> "  200     1 /build/go-microvm-runner {\"root_path\":\"/vm/other/root\"}\n"
    <> "  300     1 tail -f /vm/m/root/log\n"

  // Only the runner names the root in its JSON specification: the launcher's
  // own flags and an unrelated reader of a file under the root are not it.
  assert vm_spec.stranded_runners(
      listing,
      "/vm/m/root",
      "/vm/m/state.img",
      None,
    )
    == [16_333]
  assert vm_spec.stranded_runners("", "/vm/m/root", "/vm/m/state.img", None)
    == []
  assert vm_spec.stranded_runners(
      "garbage line\n",
      "/vm/m/root",
      "/vm/m/state.img",
      None,
    )
    == []
}

pub fn a_process_that_is_not_the_manifests_runner_is_not_stranded_test() {
  // A jailed tool can put the same JSON in its own arguments; the manifest's
  // runner path decides when the manifest is at hand.
  let json = "{\"root_path\":\"/vm/m/root\"}"
  let listing =
    "  500     1 /usr/bin/printf "
    <> json
    <> "\n"
    <> "  501     1 /build/go-microvm-runner "
    <> json
    <> "\n"
    <> "  502     1 /build/go-microvm-runner-extra "
    <> json
    <> "\n"
  assert vm_spec.stranded_runners(
      listing,
      "/vm/m/root",
      "/vm/m/state.img",
      Some("/build/go-microvm-runner"),
    )
    == [501]
  assert vm_spec.stranded_runners(
      listing,
      "/vm/m/root",
      "/vm/m/state.img",
      None,
    )
    == [500, 501, 502]
}

pub fn stranded_refusal_names_the_pid_and_how_to_stop_it_test() {
  let up =
    vm_spec.stranded_refusal("vm", [42], vm_spec.Certain, vm_spec.BlocksUp)
  assert string.contains(up, "kill 42")
  assert string.contains(up, "`loom vm up` again")
  assert !string.contains(up, "may be")

  let removal =
    vm_spec.stranded_refusal(
      "vm",
      [4, 5],
      vm_spec.Possible,
      vm_spec.BlocksRemoval,
    )
  assert string.contains(removal, "kill 4 and kill 5")
  assert string.contains(removal, "loom vm rm --name vm --yes")
  assert string.contains(removal, "may be")
}

pub fn down_and_status_say_a_runner_holds_the_files_test() {
  let note = vm_spec.stranded_note([42], vm_spec.Certain)
  assert string.contains(note, "kill 42")
  assert string.contains(note, "still holds")
  assert string.contains(
    vm_spec.stranded_note([42], vm_spec.Possible),
    "may be",
  )
}
