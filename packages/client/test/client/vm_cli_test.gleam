//// The decisions behind `loom vm`, held still: the command line, the artifact
//// manifest and its revision check, the deployment plan and the guest's own
//// configuration, the `loom-vm` command line, the scrub of a copied Git
//// configuration, and the two small records the command reads back. Nothing
//// here boots a guest; the live check does that against the built artifacts.

import client
import client/distribution_bundle
import client/distribution_plan
import client/distribution_provision
import client/vm_cli
import client/vm_spec.{Launch, Manifest, PidRecord}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
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
    == Error("loom vm needs a command: up, down or status")
  assert vm_spec.parse(["sync"]) == Error("unknown loom vm command sync")
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
  let text = vm_spec.guest_config(executor, "proj", vm_spec.GitHubOff)
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
  let text = vm_spec.guest_config(executor, "proj", vm_spec.GitHubFromGh)
  let assert Ok(document) = tom.parse(text)
  assert tom.get_string(document, ["tools", "network"]) == Ok("full")
  let assert Ok(names) = tom.get_array(document, ["tools", "env"])
  assert list.length(names) == 4

  let text = vm_spec.guest_config(executor, "proj", vm_spec.GitHubOff)
  let assert Ok(document) = tom.parse(text)
  assert result.is_error(tom.get_table(document, ["tools"]))
}

pub fn the_guest_node_line_is_the_first_one_the_guest_script_reads_test() {
  // `loom-guest-executor` takes the node's short name from the first line
  // that starts `node = "`. The peer rows below `[distribution]` have such
  // lines too, so the executor's own must come before them, and a model
  // table before it must have none.
  let #(_, executor) = bundles("dev")
  let lines =
    string.split(
      vm_spec.guest_config(executor, "proj", vm_spec.GitHubFromGh),
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
  assert vm_spec.without_userinfo("\tpushurl = https://a@b.example/x")
    == "\tpushurl = https://a@b.example/x"
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
