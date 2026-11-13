//// The decisions behind `loom --vm`, held still: how a workspace names its
//// guest, which GitHub access a resume keeps, and what `ensure` does for each
//// combination of facts about the guest.
////
//// Every function under test is pure, so the tables and properties here need
//// no guest, no daemon and no file. The properties draw from fixed seeds, so a
//// red run is the same red run everywhere.

import client/vm_spec
import core/json as core_json
import gleam/bit_array
import gleam/crypto
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import qcheck

// The seed every property here draws from, and how many cases each checks.
const seed = 1113

const cases = 300

// --- what ensure does for each combination of facts -----------------------------

fn facts(
  state: vm_spec.GuestState,
  manifest: Result(vm_spec.ManifestAction, String),
  enrolment: vm_spec.EnrolmentNeed,
  daemon: vm_spec.DaemonFact,
) -> vm_spec.EnsureFacts {
  vm_spec.EnsureFacts(
    name: "proj-1a2b3c",
    state:,
    manifest:,
    enrolment:,
    daemon:,
  )
}

const use_it =
  Ok(
    vm_spec.UseManifest(
      vm_spec.Manifest(
        revision: "dev",
        loom_vm: "/l",
        runner: "/r",
        lib_dir: "/d",
        firmware_dir: None,
        guest_root: "/g",
      ),
    ),
  )

pub fn a_serving_guest_is_never_touched_test() {
  // Whatever else is wrong, a guest that serves answers first: the manifest is
  // not even readable here and the daemon is down.
  assert vm_spec.ensure_step(facts(
      vm_spec.GuestServing(7),
      Error("unreadable"),
      vm_spec.JoinsLedger,
      vm_spec.DaemonStopped,
    ))
    == vm_spec.AlreadyServing
}

pub fn a_guest_that_runs_but_is_not_registered_is_refused_test() {
  let assert vm_spec.Refuse(reason) =
    vm_spec.ensure_step(facts(
      vm_spec.GuestStarting(7),
      use_it,
      vm_spec.NeedsNoDaemon,
      vm_spec.DaemonRunning,
    ))
  assert string.contains(reason, "process 7")
  assert string.contains(reason, "loom vm down --name proj-1a2b3c")
}

pub fn a_stopped_guest_with_a_usable_manifest_boots_test() {
  assert vm_spec.ensure_step(facts(
      vm_spec.GuestStopped,
      use_it,
      vm_spec.NeedsNoDaemon,
      vm_spec.DaemonStopped,
    ))
    == vm_spec.Boot
  assert vm_spec.ensure_step(facts(
      vm_spec.GuestStopped,
      use_it,
      vm_spec.JoinsLedger,
      vm_spec.DaemonRunning,
    ))
    == vm_spec.Boot
}

pub fn a_stopped_guest_with_no_current_manifest_boots_and_up_sets_up_test() {
  // Setup is not a step of its own: `bring_up` installs a missing or stale
  // manifest as `up` does, so the step is a boot.
  assert vm_spec.ensure_step(facts(
      vm_spec.GuestStopped,
      Ok(vm_spec.InstallRelease("stale")),
      vm_spec.NeedsNoDaemon,
      vm_spec.DaemonStopped,
    ))
    == vm_spec.Boot
}

pub fn a_join_without_a_daemon_is_reported_before_any_setup_test() {
  // Setup writes the manifest and the artifacts, and the answer must leave the
  // disk as it was, so the daemon is asked for first.
  assert vm_spec.ensure_step(facts(
      vm_spec.GuestStopped,
      Ok(vm_spec.InstallRelease("stale")),
      vm_spec.JoinsLedger,
      vm_spec.DaemonStopped,
    ))
    == vm_spec.NeedsDaemon
  assert vm_spec.ensure_step(facts(
      vm_spec.GuestStopped,
      use_it,
      vm_spec.JoinsLedger,
      vm_spec.DaemonStopped,
    ))
    == vm_spec.NeedsDaemon
}

pub fn a_refused_or_unreadable_manifest_is_refused_whatever_the_daemon_test() {
  assert vm_spec.ensure_step(facts(
      vm_spec.GuestStopped,
      Ok(vm_spec.RefuseManifest("dev build")),
      vm_spec.JoinsLedger,
      vm_spec.DaemonStopped,
    ))
    == vm_spec.Refuse("dev build")
  assert vm_spec.ensure_step(facts(
      vm_spec.GuestStopped,
      Error("bad json"),
      vm_spec.NeedsNoDaemon,
      vm_spec.DaemonRunning,
    ))
    == vm_spec.Refuse("bad json")
}

pub fn a_guest_is_serving_only_with_a_process_and_a_registration_test() {
  assert vm_spec.guest_state(Some(7), vm_spec.Registered)
    == vm_spec.GuestServing(7)
  assert vm_spec.guest_state(Some(7), vm_spec.Unregistered)
    == vm_spec.GuestStarting(7)
  assert vm_spec.guest_state(None, vm_spec.Registered) == vm_spec.GuestStopped
  assert vm_spec.guest_state(None, vm_spec.Unregistered) == vm_spec.GuestStopped
}

pub fn the_last_line_names_the_executor_and_the_workspace_test() {
  assert vm_spec.ensure_line("proj-1a2b3c", "proj")
    == "executor=proj-1a2b3c workspace=proj"
  assert vm_spec.daemon_required_line == "daemon=required"
  assert vm_spec.daemon_required_status == 75
}

pub fn a_restart_is_asked_only_of_a_daemon_left_running_test() {
  assert vm_spec.restart_refusal(vm_spec.NoDaemon) == Ok(Nil)
  assert vm_spec.restart_refusal(vm_spec.Stopped) == Ok(Nil)

  let assert Error(busy) = vm_spec.restart_refusal(vm_spec.Holding(4242, 3))
  assert string.contains(busy, "holds 3 sessions")
  assert string.contains(busy, "restart once to enable microVMs")
  assert string.contains(busy, "kill -TERM 4242")
  assert !string.contains(busy, "\n")

  let assert Error(one) = vm_spec.restart_refusal(vm_spec.Holding(4242, 1))
  assert string.contains(one, "holds 1 session ")

  assert result.is_error(vm_spec.restart_refusal(vm_spec.NotStopped(9, "slow")))
  assert result.is_error(vm_spec.restart_refusal(vm_spec.Unasked(9)))
}

pub fn ensure_reads_a_subset_of_up_s_flags_test() {
  let assert Ok(vm_spec.Ensure(options)) =
    vm_spec.parse([
      "ensure", "--workspace", "/src/proj", "--github", "off", "--allow",
      "deb.debian.org", "--config", "/tmp/loom.toml",
    ])
  assert options.workspace == Some("/src/proj")
  assert options.github == Some(vm_spec.GitHubOff)
  assert options.allow == ["deb.debian.org"]
  assert options.config == Some("/tmp/loom.toml")

  // A bare ensure is the current directory, with nothing chosen.
  let assert Ok(vm_spec.Ensure(bare)) = vm_spec.parse(["ensure"])
  assert bare.workspace == None
  assert bare.github == None
}

pub fn ensure_refuses_what_would_break_the_guest_per_workspace_rule_test() {
  list.each(["--name", "--mem", "--cpus", "--provision"], fn(flag) {
    let assert Error(reason) = vm_spec.parse(["ensure", flag, "x"])
    assert string.contains(reason, flag <> " is not an ensure option")
  })
  let assert Error(reason) = vm_spec.parse(["ensure", "--fresh"])
  assert string.contains(reason, "--fresh is not an ensure option")

  // A value that looks like a refused flag is still a value.
  let assert Ok(_) = vm_spec.parse(["ensure", "--workspace", "--fresh"])
  assert result.is_error(vm_spec.parse(["ensure", "--bogus", "x"]))
}

// --- setup for a missing or stale manifest ------------------------------------

const commit = "abc1234def5678abc1234def5678abc1234def56"

fn manifest_at(revision: String) -> vm_spec.Manifest {
  vm_spec.Manifest(
    revision:,
    loom_vm: "/h/loom-vm",
    runner: "/h/runner",
    lib_dir: "/h/lib",
    firmware_dir: None,
    guest_root: "/h/root",
  )
}

fn action(
  found: Option(vm_spec.Manifest),
  version: String,
) -> vm_spec.ManifestAction {
  vm_spec.manifest_action(found, version, commit, "/h/manifest.json")
}

pub fn a_release_build_installs_what_is_missing_or_stale_test() {
  let assert vm_spec.InstallRelease(missing) = action(None, "0.3.2")
  assert string.contains(missing, "No microVM artifacts are installed")
  assert string.contains(missing, "loom vm setup")

  // The words for a stale manifest name both revisions.
  let assert vm_spec.InstallRelease(stale) =
    action(Some(manifest_at("1111111")), "0.3.2")
  assert string.contains(stale, "1111111")
  assert string.contains(stale, commit)
  assert string.contains(stale, "loom vm setup")
}

pub fn a_release_build_uses_a_manifest_that_matches_test() {
  let current = manifest_at(commit)
  assert action(Some(current), "0.3.2") == vm_spec.UseManifest(current)

  // An abbreviation of seven characters or more is the same commit, and a
  // development tree's `dev` is accepted by every build.
  let short = manifest_at("abc1234")
  assert action(Some(short), "0.3.2") == vm_spec.UseManifest(short)
  let dev = manifest_at("dev")
  assert action(Some(dev), "0.3.2") == vm_spec.UseManifest(dev)
}

pub fn a_development_build_keeps_its_refusals_test() {
  let assert vm_spec.RefuseManifest(missing) = action(None, "dev")
  assert string.contains(missing, "make vmm-install-dev")

  let assert vm_spec.RefuseManifest(stale) =
    action(Some(manifest_at("1111111")), "dev")
  assert string.contains(stale, "make vmm-install-dev")
  assert vm_spec.manifest_action(
      Some(manifest_at("dev")),
      "dev",
      "unknown",
      "/h/manifest.json",
    )
    == vm_spec.UseManifest(manifest_at("dev"))
}

// --- the GitHub access a resume keeps -----------------------------------------

fn accesses() -> List(vm_spec.GitHubAccess) {
  [vm_spec.GitHubFromGh, vm_spec.GitHubFromEnv, vm_spec.GitHubOff]
}

pub fn github_record_round_trips_test() {
  assert list.all(accesses(), fn(access) {
    vm_spec.decode_github(vm_spec.encode_github(access)) == Ok(access)
  })
}

pub fn github_record_is_read_strictly_test() {
  assert vm_spec.decode_github("  off \n") == Ok(vm_spec.GitHubOff)
  assert result.is_error(vm_spec.decode_github(""))
  assert result.is_error(vm_spec.decode_github("on\n"))
  assert result.is_error(vm_spec.decode_github("gh\nenv\n"))
  assert result.is_error(vm_spec.decode_github("GH\n"))
}

// Every combination of given, recorded and freshness, as a table.
pub fn effective_github_table_test() {
  let none = None
  let off = Some(vm_spec.GitHubOff)
  let env = Some(vm_spec.GitHubFromEnv)

  // A flag given wins over the record, whatever the freshness.
  assert vm_spec.effective_github(env, off, vm_spec.Resume)
    == vm_spec.GitHubFromEnv
  assert vm_spec.effective_github(env, off, vm_spec.Fresh)
    == vm_spec.GitHubFromEnv

  // With no flag a resume keeps the record, and a guest with none gets gh.
  assert vm_spec.effective_github(none, off, vm_spec.Resume)
    == vm_spec.GitHubOff
  assert vm_spec.effective_github(none, none, vm_spec.Resume)
    == vm_spec.GitHubFromGh

  // `--fresh` forgets the record.
  assert vm_spec.effective_github(none, off, vm_spec.Fresh)
    == vm_spec.GitHubFromGh
}

// --- naming a guest after its workspace ---------------------------------------

// The six digits an independent computation of the digest gives, which the name
// must end with.
fn digest_tail(path: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(path))
  |> bit_array.base16_encode
  |> string.lowercase
  |> string.slice(0, 6)
}

pub fn guest_name_is_the_slug_and_the_digest_test() {
  let name = vm_spec.guest_name_for("/Users/me/src/Loom")
  assert name == "loom-" <> digest_tail("/Users/me/src/Loom")
}

pub fn guest_name_drops_what_a_name_cannot_hold_test() {
  // Characters outside the grammar are dropped, not replaced, and a name must
  // start with a letter.
  assert string.starts_with(
    vm_spec.guest_name_for("/src/My Proj.v2"),
    "myprojv2-",
  )
  assert string.starts_with(vm_spec.guest_name_for("/src/2fast"), "w2fast-")
  assert string.starts_with(vm_spec.guest_name_for("/src/_x"), "w_x-")
  assert string.starts_with(vm_spec.guest_name_for("/src/.."), "w-")
  assert string.starts_with(vm_spec.guest_name_for("/"), "w-")
  assert string.starts_with(vm_spec.guest_name_for(""), "w-")
}

pub fn guest_name_is_cut_to_the_limit_test() {
  let long = "/src/" <> string.repeat("a", 90)
  let name = vm_spec.guest_name_for(long)
  assert string.byte_size(name) == vm_spec.name_limit
  assert string.ends_with(name, "-" <> digest_tail(long))
}

pub fn guest_name_always_passes_valid_name_test() {
  qcheck.default_config()
  |> qcheck.with_test_count(cases)
  |> qcheck.with_seed(qcheck.seed(seed))
  |> qcheck.run(qcheck.string(), fn(path) {
    let name = vm_spec.guest_name_for(path)
    assert vm_spec.valid_name(name) == Ok(Nil)
    assert name == vm_spec.guest_name_for(path)
    assert string.ends_with(name, "-" <> digest_tail(path))
  })
}

pub fn guests_of_same_named_directories_differ_test() {
  // Two directories under different parents with one last segment, which is
  // the case a bare slug would fold into one guest.
  qcheck.default_config()
  |> qcheck.with_test_count(cases)
  |> qcheck.with_seed(qcheck.seed(seed + 1))
  |> qcheck.run(
    qcheck.tuple3(qcheck.string(), qcheck.string(), qcheck.string()),
    fn(drawn) {
      let #(parent_a, parent_b, segment) = drawn
      let first = "/" <> parent_a <> "/" <> segment
      let second = "/" <> parent_b <> "/" <> segment

      // Only a pair whose digests differ in the digits kept can be told apart.
      case digest_tail(first) == digest_tail(second) {
        True -> Nil
        False -> {
          assert vm_spec.guest_name_for(first) != vm_spec.guest_name_for(second)
          Nil
        }
      }
    },
  )
}

pub fn guest_names_never_collide_with_the_authority_directory_test() {
  // The authority directory is a sibling of every guest, so a guest name must
  // never equal it; the digest suffix guarantees that.
  assert list.all(["/authority", "/src/authority", "/x"], fn(path) {
    vm_spec.guest_name_for(path) != vm_spec.authority_dir
  })
  assert result.is_ok(
    vm_spec.valid_name(vm_spec.guest_name_for("/src/authority")),
  )
}

// --- a first guest in a home that has a cookie ---------------------------------

pub fn a_home_with_a_cookie_is_refused_before_anything_is_written_test() {
  assert vm_spec.mint_check(vm_spec.NoHomeCookie, "/h/.erlang.cookie")
    == Ok(Nil)
  let assert Error(reason) =
    vm_spec.mint_check(vm_spec.HomeCookieThere, "/h/.erlang.cookie")

  // The refusal says nothing was written, and says what the choice costs.
  assert string.contains(reason, "/h/.erlang.cookie already exists")
  assert string.contains(reason, "nothing was written")
  assert string.contains(reason, "every distributed node this user starts")
  assert string.contains(reason, "relies on that cookie")
}

pub fn bundles_kept_from_a_refused_install_are_installed_not_checked_test() {
  // No deployment in the file: the earlier install was refused, so a missing
  // row would be a false report.
  assert vm_spec.kept_step(Ok(vm_spec.NoDeployment)) == vm_spec.InstallKept
  assert vm_spec.kept_step(Ok(vm_spec.LedgerDeployment("/l")))
    == vm_spec.CheckKeptRow
  assert vm_spec.kept_step(Ok(vm_spec.StaticDeployment)) == vm_spec.CheckKeptRow
  assert vm_spec.kept_step(Error("bad toml")) == vm_spec.CheckKeptRow
}

// --- whether the daemon has read the deployment ----------------------------------

pub fn a_daemon_that_says_none_has_no_distribution_test() {
  assert vm_spec.lacks_distribution(
    core_json.Object([#("distribution", core_json.String("none"))]),
  )
  assert !vm_spec.lacks_distribution(
    core_json.Object([#("distribution", core_json.String("configured"))]),
  )

  // A reply that says nothing is not read as lacking it.
  assert !vm_spec.lacks_distribution(core_json.Object([]))
  assert !vm_spec.lacks_distribution(core_json.String("none"))
}

pub fn another_configuration_is_named_in_its_refusal_test() {
  let reason = vm_spec.other_config_refusal("/c/loom.toml")
  assert string.contains(reason, "/c/loom.toml")
  assert string.contains(reason, "restart that daemon once")
}

// --- a serving guest from another release ----------------------------------------------

pub fn a_serving_guest_from_another_release_is_refused_test() {
  let long = "def5678def5678def5678def5678def5678def5"
  let assert Error(reason) =
    vm_spec.serving_release_refusal("g-1", Some("abc1234"), long, Some(long))
  assert string.contains(reason, "revision abc1234")
  assert string.contains(reason, "loom vm down --name g-1")
  assert string.contains(reason, "upgrades its root")

  // A root from before the record has no revision to name.
  let assert Error(none) =
    vm_spec.serving_release_refusal("g-1", None, long, Some(long))
  assert string.contains(none, "recorded none")
}

pub fn a_serving_guest_of_this_build_is_left_alone_test() {
  let long = "def5678def5678def5678def5678def5678def5"
  assert vm_spec.serving_release_refusal("g", Some("def5678"), long, Some(long))
    == Ok(Nil)
  assert vm_spec.serving_release_refusal("g", Some(long), long, None) == Ok(Nil)
}

pub fn a_development_manifest_or_an_unknown_commit_keeps_a_root_test() {
  let long = "def5678def5678def5678def5678def5678def5"
  assert vm_spec.serving_release_refusal(
      "g",
      Some("abc1234"),
      long,
      Some("dev"),
    )
    == Ok(Nil)
  assert vm_spec.serving_release_refusal("g", None, "unknown", Some("abc1234"))
    == Ok(Nil)
}

// --- runners of a guest started from an older release ------------------------------

pub fn a_runner_in_the_cache_is_stranded_whichever_release_it_came_from_test() {
  let listing =
    "  42     1 /vm/cache/v1/go-microvm-runner {\"root_path\":\"/vm/g/root\"}\n"
    <> "  43     1 /elsewhere/runner {\"root_path\":\"/vm/g/root\"}\n"

  // The current manifest names another release; the old guest's runner lives
  // under the cache and still holds the root.
  assert vm_spec.stranded_runners_under(
      listing,
      "/vm/g/root",
      "/vm/g/state.img",
      Some(["/vm/cache/v2/go-microvm-runner ", "/vm/cache/"]),
    )
    == [42]

  // With the cache prefix absent only the manifest's runner would match.
  assert vm_spec.stranded_runners_under(
      listing,
      "/vm/g/root",
      "/vm/g/state.img",
      Some(["/vm/cache/v2/go-microvm-runner "]),
    )
    == []
}
