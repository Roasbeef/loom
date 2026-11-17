//// The microVM executor tier end to end through the product path (issue #85,
//// ADR-022): `loom vm up` with no `--link` boots a standing guest on the
//// untrusted link (protocol-change/109) and enrolls it in an orchestrator's
//// configuration, a scripted model drives a real `bash` call in the guest, and
//// `loom vm down` followed by `loom vm up` resumes the same guest.
////
//// ## What it proves
////
//// - `loom vm up` with no `--link` mints the link credentials, writes
////   `[executor_link]` and the guest's `trust = "untrusted"` row into a
////   `loom.toml` and no `[distribution]` table, stages a root with an
////   `[executor_listener]` and no cookie anywhere, clones the guest root, boots
////   `loom-vm run --forward` with no node in the host's epmd, and reports that
////   the executor serves over the untrusted link, with nothing in the fixture
////   standing in for any of those steps.
//// - `sessions.create` with `executor: <name>, workspace: "repo"` settles
////   `resident`, so the orchestrator dialled the guest, passed the pinned
////   handshake both ways, and attached a scope there.
//// - The model's `bash` call runs on the guest's Linux kernel, not the host's
////   (the host is macOS), under `loom-exec` (no-new-privileges is set), and
////   writes into the guest's copy of the checkout.
//// - Model code in the guest cannot read the key of the executor's listener,
////   which ADR-022 D2 rests on: the jail keeps model code out of the node's
////   secrets inside the same guest. The certificate beside it is public and is
////   read, which shows the key would have been readable without the mask.
//// - GitHub access goes through the credential proxy. The jailed shell holds
////   only the placeholder `GH_TOKEN`; the fake token the test gave `loom vm up`
////   appears nowhere in the tool result and nowhere under the guest's files on
////   the host. With `LOOM_VM_GITHUB_LIVE=1` the test also reaches
////   `api.github.com` from the jail: an unauthenticated `/zen` answers 200, and
////   `/user` with the placeholder answers 401, which shows the proxy replaced
////   the placeholder with the (fake, so rejected) token before GitHub saw it.
//// - `--allow` and `--provision` work together. The first `up` allows one public
////   host (`deb.debian.org`, whose addresses are stable; example.com
////   rotates its own and was unreachable) and runs a script that appends a line to a file in
////   the guest root as root. A jailed `bash` call reads that file, so the
////   script ran before the executor served. With `LOOM_VM_GITHUB_LIVE=1` the
////   script itself reaches the host over HTTP (direct, port 80) and HTTPS (the
////   credential proxy), and the jailed call reaches it over HTTPS and is
////   refused another host. The host records the allowed host in
////   `<vm home>/<name>/allow`, `status` lists it, `up --provision` on the
////   guest the script already provisioned is refused naming `--fresh`, and the
////   `up` that resumes with neither flag keeps the allowed host and does not
////   run the script again: the file still holds one line.
//// - The daily verbs work on the running guest. `vm list` names it with its
////   link and workspace, `vm logs` prints the console's end, and `vm rm`
////   refuses it naming `vm down`. A commit a jailed call makes on a new `loom/*` branch
////   arrives through `vm sync` as `refs/remotes/vm/*` in the checkout `up`
////   recorded and in a scratch checkout named with `--checkout`. After a
////   jailed call plants a hostile `.git/config` and hook in the guest's copy
////   (`core.fsmonitor`, `core.hooksPath`, `core.sshCommand`,
////   `uploadpack.packObjectsHook`, a credential helper, each a command that
////   touches a marker on the host), `vm sync` still succeeds and no marker
////   appears; a control repository shows the markers would have been writable.
////   A stopped guest brought up with a second directory registers both
////   workspaces, and a session in each runs in its own copy. A host commit made
////   after `up` reaches the guest through `vm sync --to-guest`, and a jailed `git fetch` of the bundle reads it back.
//// - A failing `--provision` script fails `up` with the script's output and
////   leaves no guest running, and `vm rm` undoes that guest's enrolment.
////   Without `--yes` the removal lists the workspaces and changes nothing; with
////   it, the guest's row leaves its file and `[executor_link]` stays there,
////   because other guests are still on the link. The guest removed last takes
////   `[executor_link]` and the vm home's link credentials with it.
//// - A kept root from another revision is upgraded in place. The step rewrites
////   the fixture's manifest to name the running build's commit and its
////   `root-revision` record to name an older one, which simulates the revision
////   change a new loom brings (the fixture has one build, not two). `up` then
////   prints the upgrade line, replaces the root, keeps the workspace copy with
////   the guest's earlier commit and a link inside it, keeps the state disk
////   file, runs the provisioning script again from the host's copy, and a
////   session on the guest still works.
//// - A killed launcher is survivable. The step sends SIGKILL to the pid the
////   pid file records, `status` says `not running`, and `up` either resumes or,
////   when the VM monitor outlived its launcher, refuses naming that runner's
////   pid; stopping it lets `up` resume, and a session works.
//// - A guest resumes. After `loom vm down` the guest process is gone and
////   `status` names the link and its recorded port; the next `loom vm up`
////   without `--fresh` keeps the port, the row and the root, so the marker
////   written by the first turn is still in the checkout and the state disk is
////   still there, and a new session on the resumed guest, through the
////   orchestrator that never stopped, reads the marker back.
//// - A second guest, made with no flag in a configuration of its own, serves
////   what the broker tunnel carries (protocol-change/117), through the daemon's
////   own session assembly. After a jailed `bash` call edits a tracked file and
////   adds one, the session's stored `session/git-start` is a revision and not
////   `unavailable`, the `worktree_diff` observation is a ready board listing
////   both paths, and a goal pinned with a check that tests for the new file
////   records that check at exit status 0 with the guest's own output and
////   workspace path. The step does not wait for the goal to complete, and
////   clears it before the session stops. On a tree without the tunnel the
////   baseline is `unavailable`, the board is `failed` with the broker's
////   refusal, and the check is refused. Hooks stay refused there and no step
////   observes it: that needs a trust record fixture, and
////   `untrusted_end_to_end_test` covers it. The same step brings a third guest
////   up beside a running orchestrator, which reads it through
////   `executors.reload` (protocol-change/116), and refuses
////   `--link distribution`.
//// - `loom vm ensure` with no `--config` and the default vm home
////   (`~/.loom/vm` of the isolated home), which is what `loom --vm` runs,
////   boots a guest beside a daemon already running on that home's default
////   `loom.toml` with no `[executor_link]`, ends with its `executor=NAME
////   workspace=NAME` line, and that same daemon process takes the new table
////   and lists the guest without a restart, through `executors.reload`. A
////   second `ensure` takes the fast path, and `rm` of that vm home's last guest
////   takes the row, `[executor_link]` and the link credentials out again with
////   the daemon still running. The step runs only when the launcher's home is
////   the fixture's own (`isolated_home`).
//// - A guest an older loom made as a distribution peer is refused. Its
////   host-side traces are fabricated under the isolated vm home (bundles in
////   `deploy/`, and for a second one a `link` record saying `distribution`;
////   neither is booted), and `vm up` and `vm ensure` each refuse it naming
////   `loom vm sync`, `loom vm rm --yes` and `loom vm up`, and change no file;
////   `vm rm --yes` then removes it, taking the `up` guest's `[distribution]`
////   table and trusted row out of a file that also holds an untrusted row,
////   which stays with every other line.
////
//// ## Running it
////
//// ```sh
//// make server-shipment tui-shipment sandbox vmm vmm-runner vmm-firmware vmm-guest-root
//// install -m 0755 packages/sandbox/loom-exec bin/loom-exec
//// export LOOM_BOOTSTRAP_E2E_SERVER=$PWD/bin/loomd
//// export LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key
//// export LOOM_VM=$PWD/packages/vmm/build/loom-vm
//// export LOOM_VM_RUNNER=$PWD/packages/vmm/build/go-microvm-runner
//// export LOOM_VM_LIB_DIR=/opt/homebrew/lib
//// export LOOM_VM_FIRMWARE_DIR=$PWD/packages/vmm/build/firmware
//// export LOOM_VM_GUEST_ROOT=$PWD/packages/vmm/build/guest-root
//// export LOOM_VM_GITHUB_LIVE=1   # optional: reach api.github.com
//// bash scripts/test.sh client --match 'client@daemon_shipped_microvm_test:'
//// ```
////
//// Without those variables, or on a host whose `loom-vm probe` fails, the
//// test prints a skip line and passes. The token is always a fake one made up
//// by the test; the test never runs `gh auth token`.
////
//// ## Flow
////
//// - `daemon_shipped_microvm_test_` gates and calls `fixture`.
//// - `fixture` lays out the private directory, runs `drive` under a deadline,
////   then tears down outside it (`vm down`, retire the orchestrator, delete
////   the directory only when the body completed).
//// - `drive` installs the artifact manifest (`install_artifacts`), runs `vm up`
////   (`up`), starts the orchestrator on the configuration `vm up` wrote, takes
////   the first scripted turn, then `vm down`, `vm up` again and the second turn,
////   the daily verbs, the upgrade and the killed launcher. Then the failing
////   script (`failing_script_fails_up`, `guests_are_removed`), the refused
////   distribution guests (`old_guests_are_refused`), the second guest
////   (`untrusted_guest`), the guest the default daemon reads
////   (`default_daemon_reads_the_guest`) and last the removal of the first
////   guest (`last_guest_takes_the_link`).
//// - `assert_first_turn`, `assert_never_on_host`, `assert_resumed` and
////   `assert_link_files` hold the assertions.

import broker/token
import client/executor_reload
import client/session_git
import client/tui_e2e_test.{type EunitTest, Timeout}
import client/vm_spec
import core/json
import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import host/bootstrap as native
import host/endpoint
import simplifile
import support/internal/ffi_proc
import support/provider_http as provider
import support/remote_daemons
import support/remote_pair
import weft
import weft/poll

const label = "shipped microvm executor"

// The guests' prefix. Each name has a random suffix, so two runs on one host
// never share a guest directory or a row.
const guest_prefix = "e2e"

const first_prompt = "run it in the guest"

const first_answer = "ran in the guest"

const second_prompt = "read it back on the resumed guest"

const second_answer = "read it back"

const marker = "marker.txt"

const marker_content = "placed-in-guest\n"

// The one host the guest is allowed to reach, and a public one it is not.
const allowed_host = "deb.debian.org"

const security_host = "security.debian.org"

// Refused: on the same infrastructure as the allowed host and reachable from
// the host, so a refusal can only be the allowlist.
const denied_host = "ftp.debian.org"

// Where the provisioning script writes inside the guest. The file gains a
// line each time the script runs, so its length counts the runs.
const runs_file = "/etc/loom-e2e-runs"

// Where `loom vm up` puts the executor node inside the guest.
const node_dir = "/srv/loom-node"

// Where the guest's checkouts are, relative to its root.
const workspaces_dir = "/srv/workspaces"

// The artifacts the host provides, named by the environment.
type Artifacts {
  Artifacts(
    /// The `loom-vm` binary.
    launcher: String,
    /// The signed `go-microvm-runner`.
    runner: String,
    /// The directory holding libkrun.
    lib_dir: String,
    /// The directory holding the Landlock `libkrunfw`.
    firmware_dir: String,
    /// The exported guest root.
    guest_root: String,
  )
}

// Everything the commands of one run share.
type Run {
  Run(
    directory: String,
    artifacts: Artifacts,
    orchestrator: remote_daemons.Layout,
    /// `LOOM_VM_HOME` of this run, private to the fixture.
    vm_home: String,
    /// The guest's name.
    name: String,
    /// The throwaway repository `vm up` copies into the guest.
    repository: String,
    /// The made-up token `vm up` reads from `LOOM_VM_GITHUB_TOKEN`.
    token: String,
    /// The host path of the provisioning script `vm up --provision` copies.
    script: String,
    /// The name of the guest whose provisioning script fails.
    failing_name: String,
    /// The name of the distribution guest whose traces the migration step
    /// fabricates for `up`.
    old_name: String,
    /// The name of the second guest that serves sessions, in a configuration
    /// of its own.
    untrusted_name: String,
    /// The orchestrator that dials that guest, with a configuration of its
    /// own.
    untrusted: remote_daemons.Layout,
  )
}

// A tool result carries every observation of one command, each line labelled.
// The key is read on purpose: the mask makes the read fail (observed on the
// untrusted step: `Permission denied`), and its status is printed so a refusal
// is still a successful tool result the script can match. The certificate
// beside it is public and prints its header. The two `curl` lines run only when
// the operator allows this test to reach GitHub.
fn first_command(reach: Reach) -> String {
  let local =
    "echo \"kernel=$(uname -r)\"; grep -E '^NoNewPrivs:' /proc/self/status; "
    <> "echo placed-in-guest > "
    <> marker
    <> "; cat "
    <> node_dir
    <> "/creds/key.pem; echo key_status=$?; head -c 27 "
    <> node_dir
    <> "/creds/cert.pem; echo; "
    <> home_listing()
    <> "echo \"gh_token=$GH_TOKEN\"; "
    <> "echo \"provisioned=$(cat "
    <> runs_file
    <> ")\"; echo \"runs=$(wc -l < "
    <> runs_file
    <> " | tr -d ' ')\""
  case reach {
    OffHost -> local
    GitHub ->
      local
      <> "; curl -sS --max-time 30 -o /dev/null -w 'allowed=%{http_code}\\n' "
      <> "https://"
      <> allowed_host
      <> "/debian/"
      <> "; curl -sS --max-time 30 -o /dev/null -w 'denied=%{http_connect}\\n' "
      <> "https://"
      <> denied_host
      <> " || true"
      <> "; echo \"jq=$(jq --version)\""
      <> "; curl -sS --max-time 30 -o /dev/null -w 'zen=%{http_code}\\n' "
      <> "https://api.github.com/zen"
      <> "; curl -sS --max-time 30 -o /dev/null -w 'user=%{http_code}\\n' "
      <> "-H \"Authorization: token $GH_TOKEN\" https://api.github.com/user"
  }
}

// The resumed call also reaches the allowed host when the operator allows
// network assertions, which shows the recorded list was launched again.
fn second_command(reach: Reach) -> String {
  let local =
    "cat "
    <> marker
    <> "; echo \"kernel=$(uname -r)\"; echo \"runs=$(wc -l < "
    <> runs_file
    <> " | tr -d ' ')\""
  case reach {
    OffHost -> local
    GitHub ->
      local
      <> "; curl -sS --max-time 30 -o /dev/null -w 'allowed=%{http_code}\\n' "
      <> "https://"
      <> allowed_host
      <> "/debian/"
  }
}

/// Boots a standing guest with `loom vm up`, runs scripted `bash` calls through
/// registered sessions, and resumes the guest across `loom vm down` and `up`.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_microvm_test:'`.
pub fn daemon_shipped_microvm_test_() -> EunitTest {
  // The runner scales EUnit timeouts by ten: 1500 seconds around a body of
  // 1300, which clones a guest root and boots a VM for every step, starts an
  // orchestrator, and runs a turn on each guest.
  Timeout(150, fn() {
    case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
      Error(Nil) ->
        io.println_error(
          "SKIP " <> label <> ": LOOM_BOOTSTRAP_E2E_SERVER is unset",
        )

      Ok(_server) ->
        case artifacts() {
          Error(reason) -> io.println_error("SKIP " <> label <> ": " <> reason)
          Ok(artifacts) -> fixture(artifacts)
        }
    }
  })
}

// The artifacts this host provides, or the first reason to skip.
fn artifacts() -> Result(Artifacts, String) {
  use launcher <- result.try(
    native.getenv("LOOM_VM") |> result.replace_error("LOOM_VM is unset"),
  )
  use runner <- result.try(
    native.getenv("LOOM_VM_RUNNER")
    |> result.replace_error("LOOM_VM_RUNNER is unset"),
  )
  use lib_dir <- result.try(
    native.getenv("LOOM_VM_LIB_DIR")
    |> result.replace_error("LOOM_VM_LIB_DIR is unset"),
  )
  use guest_root <- result.try(
    native.getenv("LOOM_VM_GUEST_ROOT")
    |> result.replace_error("LOOM_VM_GUEST_ROOT is unset"),
  )

  // The broker demands the landlock layer on Linux, which the stock
  // libkrunfw kernel lacks, so a guest on it refuses every jailed call
  // (ADR-022 D3). A host without the tier's kernel skips instead of failing.
  use firmware_dir <- result.try(
    native.getenv("LOOM_VM_FIRMWARE_DIR")
    |> result.replace_error(
      "LOOM_VM_FIRMWARE_DIR is unset (the tier needs `make vmm-firmware`)",
    ),
  )

  // The links the build directory holds must name absolute targets, and the
  // tests run from packages/client.
  use launcher <- result.try(absolute(launcher))
  use runner <- result.try(absolute(runner))
  use lib_dir <- result.try(absolute(lib_dir))
  use firmware_dir <- result.try(absolute(firmware_dir))
  use guest_root <- result.try(absolute(guest_root))

  // A probe that fails names what this host lacks: a hypervisor, the runner.
  case ffi_proc.run(launcher, ["probe"], in: ".") {
    Ok(#(0, _)) ->
      Ok(Artifacts(launcher:, runner:, lib_dir:, firmware_dir:, guest_root:))
    Ok(#(_, output)) -> Error("loom-vm probe: " <> string.trim(output))
    Error(_) -> Error("loom-vm could not be run")
  }
}

fn absolute(path: String) -> Result(String, String) {
  native.absolute_path(path)
}

fn fixture(artifacts: Artifacts) -> Nil {
  let directory = "/var/tmp/loom-vm-" <> hex(4)
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the fixture's state stays private"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the daemons receive absolute paths"
  io.println_error(label <> " fixture: " <> directory)

  let vm_home = directory <> "/vmh"
  let assert Ok(Nil) = native.ensure_private_directory(vm_home)
    as "the guest's home is private"
  let run =
    Run(
      directory:,
      artifacts:,
      orchestrator: remote_daemons.layout(directory, "orchestrator"),
      vm_home:,
      name: guest_prefix <> hex(3),
      repository: directory <> "/" <> remote_pair.workspace_name,
      token: "ghp_loomvm" <> hex(18),
      script: directory <> "/provision.sh",
      failing_name: guest_prefix <> hex(3),
      old_name: guest_prefix <> hex(3),
      untrusted_name: guest_prefix <> hex(3),
      untrusted: remote_daemons.layout(directory, "untrusted"),
    )

  let outcomes =
    weft.new([
      fn() {
        drive(run)
        Ok(Nil)
      },
    ])
    |> weft.deadline(1_300_000)
    |> weft.start

  // Teardown runs outside the body's deadline, so a body that failed midway
  // still stops the guest it started and retires the orchestrator.
  let _stopped = vm(run, ["down", "--name", run.name])
  let _failing_stopped = vm(run, ["down", "--name", run.failing_name])
  let _untrusted_stopped = vm(run, ["down", "--name", run.untrusted_name])
  let _second_stopped = vm(run, ["down", "--name", second_untrusted_name(run)])
  default_teardown(run)
  remote_daemons.retire(run.untrusted.paths)
  remote_daemons.retire(run.orchestrator.paths)
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the microvm body completes before native teardown"

  // The guest root clone keeps the export's read-only directories, which
  // would make the removal fail silently and leave the fixture behind.
  let assert Ok(chmod) = ffi_proc.which("chmod") as "chmod is on PATH"
  let _writable = ffi_proc.run(chmod, ["-R", "u+w", directory], in: ".")
  let _removed = simplifile.delete_all([directory])
  Nil
}

fn drive(run: Run) -> Nil {
  make_repository(run)
  install_artifacts(run)
  write_provision_script(run)

  let script = [
    provider.ToolUseExchange(
      first_prompt,
      "guest-call",
      "bash",
      json.Object([#("command", json.String(first_command(reach())))]),
    ),
    provider.ComputedExchange(provider.AwaitToolResult("guest-call"), fn(_seen) {
      provider.ReplyText(first_answer)
    }),
    provider.ToolUseExchange(
      second_prompt,
      "resume-call",
      "bash",
      json.Object([#("command", json.String(second_command(reach())))]),
    ),
    provider.ComputedExchange(
      provider.AwaitToolResult("resume-call"),
      fn(_seen) { provider.ReplyText(second_answer) },
    ),
    ..list.append(daily_exchanges(run), upgrade_exchanges())
  ]

  let #(Nil, report) =
    provider.with_server_for(script, provider.OnlySuccessful, 840_000, fn(url) {
      let first_up =
        up(run, [
          "--allow",
          allowed_host,
          "--allow",
          security_host,
          "--provision",
          run.script,
        ])
      // The file did not exist, so it holds only what `up` wrote.
      let guest = guest_directory(run)
      let port = untrusted_port(guest)
      assert_serves(first_up, port)
      assert_link_files(run, run.orchestrator.config, run.name, guest, port, "")

      // `vm up` wrote `[executor_link]` and `[executors.<name>]`; the
      // orchestrator also needs a model, which the scripted provider serves.
      // It reads the untrusted row at its start, so it needs no distribution
      // options file and no cookie.
      let orchestrator = run.orchestrator
      let installed = read_file(orchestrator.config)
      let assert Ok(Nil) =
        simplifile.write(
          orchestrator.config,
          installed <> "\n" <> remote_daemons.model_table(url),
        )
        as "the model table is appended to the installed configuration"

      let running = remote_daemons.start_plain(orchestrator)
      let control = remote_daemons.open_control(running)
      let #(session, settled) =
        remote_daemons.create_and_settle(
          control,
          1,
          "e2e-microvm",
          run.name,
          remote_pair.workspace_name,
        )
      assert remote_daemons.settled_state(settled) == "resident"
      remote_pair.converse_for(
        remote_pair.Opened(orchestrator: running, control:, session:),
        first_prompt,
        [first_answer],
      )
      remote_daemons.stop_session(running, control, 100, session)

      // Stop the guest, check that it is gone, and bring it back with the same
      // flags and no `--fresh`.
      let down = vm(run, ["down", "--name", run.name])
      assert string.contains(down.output, "Stopped the guest " <> run.name)
      let status = vm(run, ["status", "--name", run.name])
      assert string.contains(status.output, "process:    not running")
        as { "status after down says not running:\n" <> status.output }
      assert string.contains(
        status.output,
        "link:       untrusted, TLS to 127.0.0.1:" <> port,
      )
        as { "status after down names the link:\n" <> status.output }
      assert !string.contains(status.output, "epmd:")
        as { "status names no epmd entry:\n" <> status.output }

      // The guest was provisioned, so a script given now is refused before
      // anything changes, and the refusal names the way to run a new one.
      let refused =
        vm(run, ["up", "--name", run.name, "--provision", run.script])
      assert refused.status != 0
      assert string.contains(refused.output, "--fresh")

      // The allowed host is recorded and `status` lists it, with the script's
      // state.
      assert read_allow(run) == allowed_host <> "\n" <> security_host <> "\n"
      assert string.contains(
        status.output,
        "allowed:    " <> allowed_host <> ", " <> security_host,
      )
      assert string.contains(status.output, "provision:  done")

      // Neither flag: the resume keeps the allowed host and skips the script,
      // and keeps the port and the row, so the orchestrator that never
      // stopped dials the same address.
      let before_resume = read_file(orchestrator.config)
      let second_up = up(run, [])
      assert_serves(second_up, port)
      assert string.contains(second_up, "already as this guest needs it")
        as { "the resume leaves the row as it was:\n" <> second_up }
      assert read_file(orchestrator.config) == before_resume
      assert_resumed(run)

      let #(resumed, settled) =
        remote_daemons.create_and_settle(
          control,
          200,
          "e2e-microvm-resumed",
          run.name,
          remote_pair.workspace_name,
        )
      assert remote_daemons.settled_state(settled) == "resident"
      remote_pair.converse_for(
        remote_pair.Opened(orchestrator: running, control:, session: resumed),
        second_prompt,
        [second_answer],
      )
      remote_daemons.stop_session(running, control, 300, resumed)

      daily_verbs(run, running, control)
      upgrade_in_place(run, running, control)
      killed_launcher(run, running, control)
      remote_pair.close_daemons([running])
    })

  let assert Ok(requests) = report
    as "both scripted turns completed with a successful tool result"
  let first = remote_daemons.result_text(requests, "guest-call")
  io.println_error(label <> " tool result:\n" <> first)
  assert_first_turn(run, first)
  assert_never_on_host(run)

  let second = remote_daemons.result_text(requests, "resume-call")
  io.println_error(label <> " resumed tool result:\n" <> second)
  assert string.contains(second, marker_content)

  // The script ran once, on the first boot, and not on the resume.
  assert string.contains(second, "runs=1")
  case reach() {
    OffHost -> Nil
    GitHub -> {
      assert string.contains(second, "allowed=200")
    }
  }
  assert read_allow(run) == allowed_host <> "\n" <> security_host <> "\n"
  assert_script_ran_once(run)

  assert_daily_results(run, requests)
  assert_upgrade_results(requests)

  failing_script_fails_up(run)
  guests_are_removed(run)
  old_guests_are_refused(run)
  untrusted_guest(run)
  default_daemon_reads_the_guest(run)

  // Last, because the first guest is the one that keeps `[executor_link]` and
  // the link credentials in place for the removals above.
  last_guest_takes_the_link(run)
}

// Whether the guest's jailed shell calls api.github.com.
type Reach {
  // Nothing leaves the host; the guest's two curl calls are left out.
  OffHost
  // `LOOM_VM_GITHUB_LIVE=1`: the calls run.
  GitHub
}

fn reach() -> Reach {
  case native.getenv("LOOM_VM_GITHUB_LIVE") {
    Ok("1") -> GitHub
    _ -> OffHost
  }
}

// --- the daily verbs ---------------------------------------------------------

// The branch the jailed commit is made on, and the three prompts the daily
// steps add to the scripted provider. Each call prints its facts and ends with
// `true`, so the tool result is a successful one whatever Git said.
const commit_branch = "loom/e2e-sync"

const commit_prompt = "commit in the guest"

const commit_answer = "committed in the guest"

const hostile_prompt = "plant a hostile configuration in the guest"

const hostile_answer = "planted in the guest"

const fetch_prompt = "fetch the host commits in the guest"

const fetch_answer = "fetched in the guest"

// The command `vm sync --to-guest` prints for the copy this fixture's guest
// holds, which the jailed call then runs word for word.
const where_prompt_repo = "where is the first workspace"

const where_answer_repo = "first workspace found"

const where_prompt_other = "where is the second workspace"

const where_answer_other = "second workspace found"

const guest_fetch =
  "git fetch /srv/host-refs/repo.bundle '+refs/heads/*:refs/remotes/host/*'"

// A directory on the host that every command of the hostile configuration
// would write a marker into. It exists, so a command that ran would leave one.
fn marker_dir(run: Run) -> String {
  run.directory <> "/hostile-markers"
}

// The hooks directory `core.hooksPath` names: a host path, like every other
// setting, whose `reference-transaction` hook touches a marker.
fn hostile_hooks(run: Run) -> String {
  run.directory <> "/hostile-hooks"
}

fn commit_command() -> String {
  let identity = "-c user.name=guest -c user.email=guest@loom.invalid "
  "git "
  <> identity
  <> "checkout -q -b "
  <> commit_branch
  <> " 2>&1 && echo guest-work > guest.txt && git add guest.txt && git "
  <> identity
  <> "commit -q -m guest-commit 2>&1; echo \"guest_sha=$(git rev-parse HEAD)\"; "
  <> "echo \"guest_branch=$(git rev-parse --abbrev-ref HEAD)\"; true"
}

// A guest's `.git/config` and hooks as model-influenced code could leave them:
// every setting that runs a command on a host names a command that touches a
// marker there.
fn hostile_command(run: Run) -> String {
  let mark = marker_dir(run)
  "printf '[core]\\n\\tfsmonitor = touch "
  <> mark
  <> "/fsmonitor\\n\\thooksPath = "
  <> hostile_hooks(run)
  <> "\\n\\tsshCommand = touch "
  <> mark
  <> "/ssh\\n\\tpager = touch "
  <> mark
  <> "/pager\\n[uploadpack]\\n\\tpackObjectsHook = touch "
  <> mark
  <> "/packhook\\n[credential]\\n\\thelper = !touch "
  <> mark
  <> "/credential\\n' >> .git/config; echo hostile_planted=$(grep -c touch .git/config); true"
}

// Names the copy the call runs in, and what it holds.
fn where_command() -> String {
  "echo \"cwd=$(pwd)\"; head -n 1 README.md; true"
}

fn fetch_command() -> String {
  guest_fetch
  <> " 2>&1; echo \"fetch_status=$?\"; "
  <> "echo \"host_main=$(git rev-parse refs/remotes/host/main)\"; true"
}

// The three scripted calls the daily steps drive, appended to the script.
fn daily_exchanges(run: Run) -> List(provider.Exchange) {
  [
    bash_exchange(commit_prompt, "commit-call", commit_command()),
    reply_after("commit-call", commit_answer),
    bash_exchange(hostile_prompt, "hostile-call", hostile_command(run)),
    reply_after("hostile-call", hostile_answer),
    bash_exchange(fetch_prompt, "fetch-call", fetch_command()),
    reply_after("fetch-call", fetch_answer),
    bash_exchange(where_prompt_repo, "where-repo-call", where_command()),
    reply_after("where-repo-call", where_answer_repo),
    bash_exchange(where_prompt_other, "where-other-call", where_command()),
    reply_after("where-other-call", where_answer_other),
  ]
}

fn bash_exchange(
  prompt: String,
  call: String,
  command: String,
) -> provider.Exchange {
  provider.ToolUseExchange(
    prompt,
    call,
    "bash",
    json.Object([#("command", json.String(command))]),
  )
}

fn reply_after(call: String, answer: String) -> provider.Exchange {
  provider.ComputedExchange(provider.AwaitToolResult(call), fn(_seen) {
    provider.ReplyText(answer)
  })
}

// One jailed turn on the guest: a new session, the prompt, and the session
// stopped again. `id` is the first control command id the creation may use.
fn jailed_turn(
  run: Run,
  running: remote_daemons.Running,
  control: remote_daemons.Control,
  id: Int,
  workspace: String,
  key: String,
  prompt: String,
  answer: String,
) -> Nil {
  let #(session, settled) =
    remote_daemons.create_and_settle(control, id, key, run.name, workspace)
  assert remote_daemons.settled_state(settled) == "resident"
  remote_pair.converse_for(
    remote_pair.Opened(orchestrator: running, control:, session:),
    prompt,
    [answer],
  )
  remote_daemons.stop_session(running, control, id + 100, session)
}

// --- upgrading a kept root, and a killed launcher ----------------------------

const upgrade_prompt = "read the workspace on the upgraded guest"

const upgrade_answer = "read on the upgraded guest"

const killed_prompt = "read the workspace after the launcher was killed"

const killed_answer = "read after the launcher was killed"

// An older revision than any real build, in the form a manifest records.
const old_revision = "0123456789abcdef0123456789abcdef01234567"

// The two scripted calls the steps below drive, appended to the script. Each
// prints what the guest holds and ends with `true`.
fn upgrade_exchanges() -> List(provider.Exchange) {
  let read =
    "cat guest.txt; cat "
    <> marker
    <> "; echo \"runs=$(wc -l < "
    <> runs_file
    <> " | tr -d ' ')\"; true"
  [
    bash_exchange(upgrade_prompt, "upgrade-call", read),
    reply_after("upgrade-call", upgrade_answer),
    bash_exchange(killed_prompt, "killed-call", read),
    reply_after("killed-call", killed_answer),
  ]
}

fn assert_upgrade_results(requests: List(provider.ObservedRequest)) -> Nil {
  let upgraded = remote_daemons.result_text(requests, "upgrade-call")
  assert string.contains(upgraded, "guest-work")
  assert string.contains(upgraded, marker_content)
  assert string.contains(upgraded, "runs=1")
  let killed = remote_daemons.result_text(requests, "killed-call")
  assert string.contains(killed, "guest-work")
  assert string.contains(killed, marker_content)
  Nil
}

// The commit of the build the shipped server was made from, which is what
// `up` compares the manifest's revision with. The shipment's launcher script
// records it, and so does nothing else the test can read without running Git.
fn build_commit() -> Result(String, String) {
  use server <- result.try(
    native.getenv("LOOM_BOOTSTRAP_E2E_SERVER")
    |> result.replace_error("LOOM_BOOTSTRAP_E2E_SERVER is unset"),
  )
  use text <- result.try(
    simplifile.read(server)
    |> result.replace_error(server <> " is unreadable"),
  )
  case string.split(text, "LOOM_BUILD_COMMIT=\"") {
    [_, rest, ..] ->
      case string.split(rest, "\"") {
        [commit, ..] ->
          case string.length(commit) == 40 {
            True -> Ok(commit)
            False -> Error("the build commit is " <> commit)
          }
        _ -> Error("the build commit is unterminated")
      }
    _ -> Error("the launcher records no build commit")
  }
}

fn guest_directory(run: Run) -> String {
  run.vm_home <> "/" <> run.name
}

fn workspace_copy(run: Run) -> String {
  guest_directory(run)
  <> "/root"
  <> workspaces_dir
  <> "/"
  <> remote_pair.workspace_name
}

// A new loom is simulated, because the fixture has one build and not two. The
// manifest is rewritten to name the running build's commit, so `check_revision`
// passes, and the root-revision record is rewritten to name an older one, which
// is what a root cloned by the previous release would hold. `up` must then
// replace the root in place: the old root's marker is gone, the workspace copy
// with the guest's earlier commit and a link inside it survives, the state disk
// is the same file, the provisioning script ran again on the new root, and a
// session on the guest still works.
fn upgrade_in_place(
  run: Run,
  running: remote_daemons.Running,
  control: remote_daemons.Control,
) -> Nil {
  case build_commit() {
    Error(reason) ->
      io.println_error("SKIP " <> label <> " upgrade in place: " <> reason)
    Ok(commit) -> {
      let down = vm(run, ["down", "--name", run.name])
      assert string.contains(down.output, "Stopped the guest " <> run.name)

      // What the upgrade must keep or replace, observed before it runs.
      let copy = workspace_copy(run)
      let branch_ref = copy <> "/.git/refs/heads/" <> commit_branch
      let assert Ok(sha) = simplifile.read(branch_ref)
        as "the guest's commit is a loose ref in its copy"
      let assert Ok(Nil) =
        simplifile.create_symlink(
          to: "../nowhere",
          from: copy <> "/inside-link",
        )
        as "a link inside the workspace copy"
      let old_marker = guest_directory(run) <> "/root/old-root-marker"
      let assert Ok(Nil) = simplifile.write(old_marker, "old\n")
        as "a file only the old root holds"
      let disk = guest_directory(run) <> "/state.img"
      let assert Ok(disk_before) = simplifile.file_info(disk)
        as "the state disk is there"

      let manifest = run.vm_home <> "/manifest.json"
      let assert Ok(text) = simplifile.read(manifest)
        as "the manifest is readable"
      let revised =
        string.replace(
          text,
          "\"revision\": \"dev\"",
          "\"revision\": \"" <> commit <> "\"",
        )
      assert revised != text
      let assert Ok(Nil) = simplifile.write(manifest, revised)
        as "the manifest names the running build's commit"
      let assert Ok(Nil) =
        simplifile.write(
          guest_directory(run) <> "/root-revision",
          old_revision <> "\n",
        )
        as "the root-revision record names an older build"

      let output = up(run, [])
      assert string.contains(
        output,
        "Upgrading the guest " <> run.name <> " in place",
      )

      // The old root is gone, the new one is recorded, and nothing of the
      // upgrade is left beside it.
      assert simplifile.is_file(old_marker) == Ok(False)
      let assert Ok(recorded) =
        simplifile.read(guest_directory(run) <> "/root-revision")
        as "up recorded the new root's revision"
      assert recorded == commit <> "\n"
      assert simplifile.is_directory(guest_directory(run) <> "/root.next")
        == Ok(False)

      // The workspace copy moved whole: the committed file and ref, and a link
      // inside it still a link.
      assert simplifile.read(branch_ref) == Ok(sha)
      assert simplifile.read(copy <> "/guest.txt") == Ok("guest-work\n")
      let assert Ok(link) = simplifile.link_info(copy <> "/inside-link")
        as "the link is still there"
      assert simplifile.file_info_type(link) == simplifile.Symlink
      assert read_marker(run) == marker_content

      // The disk is kept, and the script ran on the new root.
      let assert Ok(disk_after) = simplifile.file_info(disk)
        as "the state disk is still there"
      assert disk_after.inode == disk_before.inode
      assert simplifile.is_file(
          guest_directory(run) <> "/root/etc/loom-vm/provisioned",
        )
        == Ok(True)
      assert_script_ran_once(run)

      jailed_turn(
        run,
        running,
        control,
        1400,
        remote_pair.workspace_name,
        "e2e-upgrade",
        upgrade_prompt,
        upgrade_answer,
      )
    }
  }
}

// A launcher killed by SIGKILL leaves a pid file for a process that is gone.
// `status` must say the guest is not running. The VM monitor is a separate
// process and may outlive its launcher; when it does, `up` must refuse with
// its pid and how to stop it, and once it is stopped `up` resumes the guest.
fn killed_launcher(
  run: Run,
  running: remote_daemons.Running,
  control: remote_daemons.Control,
) -> Nil {
  let assert Ok(record) =
    simplifile.read(guest_directory(run) <> "/loom-vm.pid")
    as "the running guest has a pid file"
  let assert [pid, ..] = string.split(record, "\n")
  signal(["-KILL", pid])

  // The kill is immediate, but the process table is read, not assumed.
  let assert poll.Answered(Nil) =
    poll.until(within: 30_000, every: 100, attempt: fn() {
      let status = vm(run, ["status", "--name", run.name])
      case string.contains(status.output, "process:    not running") {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "status reports the guest with a killed launcher as not running"

  // When the runner outlived its launcher, `status` names it, `down` does not
  // call the guest stopped and `rm` refuses to delete what it holds.
  let status = vm(run, ["status", "--name", run.name])
  case string.contains(status.output, "runner:     ") {
    False -> Nil
    True -> {
      assert string.contains(status.output, "kill ")
      let down = vm(run, ["down", "--name", run.name])
      assert down.status != 0
      assert string.contains(down.output, "kill ")
      let removal = vm(run, ["rm", "--name", run.name, "--yes"])
      assert removal.status != 0
      assert string.contains(removal.output, "kill ")
      assert simplifile.is_directory(guest_directory(run) <> "/root")
        == Ok(True)
    }
  }

  // The runner of the killed launcher is the guest's second process.
  let first = vm(run, up_arguments(run))
  case first.status {
    0 -> io.println_error(label <> " the runner did not outlive its launcher")
    _ -> {
      assert string.contains(first.output, "still holds its root")
      let assert [_, after_kill] =
        string.split(first.output, "Stop it with `kill ")
      let assert [runner, ..] = string.split(after_kill, "`")
      io.println_error(label <> " stranded runner " <> runner <> " refused up")

      // The runner belongs to this fixture's guest, and its pid came from the
      // refusal `up` built from the process table.
      signal([runner])
      let assert poll.Answered(Nil) =
        poll.until(within: 30_000, every: 100, attempt: fn() {
          let assert Ok(kill) = ffi_proc.which("kill")
          case ffi_proc.run(kill, ["-0", runner], in: ".") {
            Ok(#(0, _)) -> poll.Retry
            _ -> poll.Done(Nil)
          }
        })
        as "the stranded runner exits"
      Nil
    }
  }

  let resumed = case first.status {
    0 -> first.output
    _ -> up(run, [])
  }
  assert_serves(resumed, untrusted_port(guest_directory(run)))
  jailed_turn(
    run,
    running,
    control,
    1600,
    remote_pair.workspace_name,
    "e2e-killed",
    killed_prompt,
    killed_answer,
  )
}

fn signal(arguments: List(String)) -> Nil {
  let assert Ok(kill) = ffi_proc.which("kill") as "kill is on PATH"
  let assert Ok(#(0, _)) = ffi_proc.run(kill, arguments, in: ".")
    as "the signal is delivered"
  Nil
}

// The arguments `up` takes in the fixture's own guest, which `up` composes
// with a status check of its own.
fn up_arguments(run: Run) -> List(String) {
  [
    "up",
    "--name",
    run.name,
    "--workspace",
    run.repository,
    "--config",
    run.orchestrator.config,
    "--github",
    "env",
  ]
}

// `list`, `logs` and a refused `rm` on the guest that is up; then the commit, the
// syncs, the hostile configuration and the bundle to the guest.
fn daily_verbs(
  run: Run,
  running: remote_daemons.Running,
  control: remote_daemons.Control,
) -> Nil {
  list_logs_and_refused_removal(run)
  assert_markers_would_fire(run)

  // A commit made by a jailed call arrives in the checkout `up` recorded, and
  // again in a scratch checkout named by `--checkout`.
  jailed_turn(
    run,
    running,
    control,
    400,
    remote_pair.workspace_name,
    "e2e-commit",
    commit_prompt,
    commit_answer,
  )
  let synced = expect_ok(vm(run, ["sync", "--name", run.name]), "loom vm sync")
  io.println_error(label <> " vm sync:\n" <> synced)
  assert string.contains(synced, "refs/remotes/vm/")
  assert string.contains(
    vm_refs(run.repository),
    "refs/remotes/vm/" <> commit_branch,
  )

  let scratch = run.directory <> "/scratch"
  git_in(run.directory, ["clone", "-q", run.repository, scratch])
  let _ =
    expect_ok(
      vm(run, ["sync", "--name", run.name, "--checkout", scratch]),
      "loom vm sync --checkout",
    )
  assert string.contains(vm_refs(scratch), "refs/remotes/vm/" <> commit_branch)

  // A jailed call plants a hostile configuration and hook. The sync still
  // succeeds, and nothing the configuration names ran on the host.
  jailed_turn(
    run,
    running,
    control,
    600,
    remote_pair.workspace_name,
    "e2e-hostile",
    hostile_prompt,
    hostile_answer,
  )
  let hostile_sync =
    expect_ok(
      vm(run, ["sync", "--name", run.name, "--checkout", scratch]),
      "loom vm sync after the hostile configuration",
    )
  io.println_error(label <> " hostile vm sync:\n" <> hostile_sync)
  assert simplifile.read_directory(marker_dir(run)) == Ok([])

  // A host commit made after `up` reaches the guest through a bundle, which a
  // jailed `git fetch` reads back.
  git_in(run.repository, [
    "-c",
    "user.name=Loom Fixture",
    "-c",
    "user.email=fixture@loom.invalid",
    "commit",
    "-q",
    "--allow-empty",
    "-m",
    "host-work",
  ])
  let bundled =
    expect_ok(
      vm(run, ["sync", "--name", run.name, "--to-guest"]),
      "loom vm sync --to-guest",
    )
  io.println_error(label <> " vm sync --to-guest:\n" <> bundled)
  assert string.contains(bundled, guest_fetch)
  assert simplifile.is_file(
      run.vm_home <> "/" <> run.name <> "/root/srv/host-refs/repo.bundle",
    )
    == Ok(True)
  jailed_turn(
    run,
    running,
    control,
    800,
    remote_pair.workspace_name,
    "e2e-fetch",
    fetch_prompt,
    fetch_answer,
  )
  both_workspaces(run, running, control)
}

// A stopped guest brought up with another directory serves both: the host's
// `checkouts` record keeps the first copy registered, so a session in each
// workspace settles and runs in its own copy.
fn both_workspaces(
  run: Run,
  running: remote_daemons.Running,
  control: remote_daemons.Control,
) -> Nil {
  let other = run.directory <> "/other"
  let assert Ok(Nil) = simplifile.create_directory_all(other)
    as "the second repository directory is created"
  let assert Ok(Nil) = simplifile.write(other <> "/README.md", "the other\n")
    as "the second repository has a file"
  git_in(other, ["init", "-q", "-b", "main"])
  git_in(other, ["add", "README.md"])
  git_in(other, [
    "-c",
    "user.name=Loom Fixture",
    "-c",
    "user.email=fixture@loom.invalid",
    "commit",
    "-q",
    "-m",
    "initial",
  ])

  let down = vm(run, ["down", "--name", run.name])
  assert string.contains(down.output, "Stopped the guest " <> run.name)
  let resumed = up(run, ["--workspace", other])
  assert string.contains(
    resumed,
    "loom --executor " <> run.name <> " --workspace other",
  )
  let status = expect_ok(vm(run, ["status", "--name", run.name]), "vm status")
  assert string.contains(status, "workspaces: other, repo")

  jailed_turn(
    run,
    running,
    control,
    1000,
    remote_pair.workspace_name,
    "e2e-ws-repo",
    where_prompt_repo,
    where_answer_repo,
  )
  jailed_turn(
    run,
    running,
    control,
    1200,
    "other",
    "e2e-ws-other",
    where_prompt_other,
    where_answer_other,
  )
  Nil
}

// `vm list` shows the running guest with its workspace, `vm logs` shows the end
// of its console without a terminal escape, and `vm rm` refuses a running guest
// naming `vm down`.
fn list_logs_and_refused_removal(run: Run) -> Nil {
  // The link column is padded to the width of `distribution`.
  let listed = expect_ok(vm(run, ["list"]), "loom vm list")
  assert string.contains(
    listed,
    run.name <> "  running  untrusted     " <> remote_pair.workspace_name,
  )
    as { "vm list names the guest, its link and workspace:\n" <> listed }

  let logs =
    expect_ok(
      vm(run, ["logs", "--name", run.name, "--lines", "100000"]),
      "loom vm logs",
    )
  assert string.contains(logs, "LOOM-EXECUTOR-READY")
  assert !string.contains(logs, "\u{1b}")
  let few =
    expect_ok(
      vm(run, ["logs", "--name", run.name, "--lines", "3"]),
      "loom vm logs --lines 3",
    )
  assert list.length(string.split(string.trim_end(few), "\n")) <= 3

  let refused =
    vm(run, [
      "rm",
      "--name",
      run.name,
      "--config",
      run.orchestrator.config,
      "--yes",
    ])
  assert refused.status != 0
  assert string.contains(refused.output, "loom vm down --name " <> run.name)
  assert simplifile.is_directory(run.vm_home <> "/" <> run.name) == Ok(True)
  Nil
}

// The control for the hostile configuration: a repository whose
// `core.fsmonitor` is a command that touches a marker really does write it
// when Git runs there. Without this, an empty marker directory would show only
// that the directory was unwritable.
fn assert_markers_would_fire(run: Run) -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all(marker_dir(run))
    as "the marker directory is created"
  let control = run.directory <> "/control-repo"
  let assert Ok(Nil) = simplifile.create_directory_all(control)
    as "the control repository directory is created"
  git_in(control, ["init", "-q", "-b", "main"])
  git_in(control, [
    "config",
    "core.fsmonitor",
    "touch " <> marker_dir(run) <> "/control",
  ])
  git_in(control, ["status", "--short"])
  assert simplifile.is_file(marker_dir(run) <> "/control") == Ok(True)
  let assert Ok(Nil) = simplifile.delete(marker_dir(run) <> "/control")
    as "the control marker is removed"

  // The same for the hooks directory the hostile configuration names: a commit
  // in the control repository runs its `reference-transaction` hook.
  let hooks = hostile_hooks(run)
  let assert Ok(Nil) = simplifile.create_directory_all(hooks)
    as "the hostile hooks directory is created"
  let hook = hooks <> "/reference-transaction"
  let assert Ok(Nil) =
    simplifile.write(
      hook,
      "#!/bin/sh\ntouch " <> marker_dir(run) <> "/hook-reference-transaction\n",
    )
    as "the hook is written"
  let assert Ok(Nil) = simplifile.set_permissions_octal(hook, 0o755)
    as "the hook is executable"
  git_in(control, ["config", "--unset", "core.fsmonitor"])
  git_in(control, ["config", "core.hooksPath", hooks])
  git_in(control, [
    "-c",
    "user.name=Loom Fixture",
    "-c",
    "user.email=fixture@loom.invalid",
    "commit",
    "-q",
    "--allow-empty",
    "-m",
    "control",
  ])
  let marker = marker_dir(run) <> "/hook-reference-transaction"
  assert simplifile.is_file(marker) == Ok(True)
  let assert Ok(Nil) = simplifile.delete(marker)
    as "the control hook marker is removed"
  Nil
}

// What the jailed calls printed, read after the scripted turns are over: the
// commit's sha is the one now in `refs/remotes/vm/*` of both checkouts, the
// hostile configuration was planted, and the bundle fetched in the jail holds
// the host's commit.
fn assert_daily_results(
  run: Run,
  requests: List(provider.ObservedRequest),
) -> Nil {
  let committed = remote_daemons.result_text(requests, "commit-call")
  io.println_error(label <> " commit tool result:\n" <> committed)
  let sha = line_value(committed, "guest_sha=")
  assert string.length(sha) == 40
  assert line_value(committed, "guest_branch=") == commit_branch
  let ref = "refs/remotes/vm/" <> commit_branch
  assert string.trim(git_output(run.repository, ["rev-parse", ref])) == sha
  assert string.trim(
      git_output(run.directory <> "/scratch", ["rev-parse", ref]),
    )
    == sha

  let hostile = remote_daemons.result_text(requests, "hostile-call")
  assert line_value(hostile, "hostile_planted=") != "0"

  // Each session ran in its own workspace's copy of the guest.
  let in_repo = remote_daemons.result_text(requests, "where-repo-call")
  assert string.contains(in_repo, "cwd=/srv/workspaces/repo")
  assert string.contains(in_repo, "the host's checkout of the repository")
  let in_other = remote_daemons.result_text(requests, "where-other-call")
  assert string.contains(in_other, "cwd=/srv/workspaces/other")
  assert string.contains(in_other, "the other")

  // The jail read the bundle under its default read scope and fetched the host
  // commit made after `up`.
  let fetched = remote_daemons.result_text(requests, "fetch-call")
  io.println_error(label <> " fetch tool result:\n" <> fetched)

  // The planted configuration was live in the guest: Git there ran the
  // `fsmonitor` command, which cannot touch a host path from inside the guest.
  assert string.contains(fetched, "hostile-markers/fsmonitor")
  assert string.contains(fetched, "fetch_status=0")
  let host_sha =
    string.trim(git_output(run.repository, ["rev-parse", "refs/heads/main"]))
  assert line_value(fetched, "host_main=") == host_sha
  Nil
}

// The value after `prefix` on the first line that starts with it.
fn line_value(text: String, prefix: String) -> String {
  let found =
    string.split(text, "\n")
    |> list.find(fn(line) { string.starts_with(string.trim(line), prefix) })
  case found {
    Ok(line) ->
      string.trim(string.drop_start(string.trim(line), string.length(prefix)))
    Error(Nil) -> ""
  }
}

// The remote-tracking refs a checkout holds under `refs/remotes/vm`.
fn vm_refs(directory: String) -> String {
  git_output(directory, [
    "for-each-ref",
    "--format=%(refname)",
    "refs/remotes/vm",
  ])
}

fn git_in(directory: String, arguments: List(String)) -> Nil {
  let assert Ok(git) = ffi_proc.which("git") as "git is on PATH"
  let assert Ok(#(0, _)) = ffi_proc.run(git, arguments, in: directory)
    as "git runs in the fixture's own directory"
  Nil
}

fn git_output(directory: String, arguments: List(String)) -> String {
  let assert Ok(git) = ffi_proc.which("git") as "git is on PATH"
  let assert Ok(#(0, output)) = ffi_proc.run(git, arguments, in: directory)
    as "git answers in the fixture's own directory"
  output
}

// --- removing guests ---------------------------------------------------------

fn read_file(path: String) -> String {
  let assert Ok(text) = simplifile.read(path) as { path <> " is readable" }
  text
}

// The failing-script step's guest is removed after a refusal that lists its
// workspaces. Its row leaves its own file, and `[executor_link]` stays there,
// because the first guest is still on the link and `rm` takes the table only
// with the last untrusted guest. Every file named is inside the fixture.
fn guests_are_removed(run: Run) -> Nil {
  let fail_config = run.directory <> "/fail.toml"
  let guest = run.vm_home <> "/" <> run.failing_name

  let listed = expect_ok(vm(run, ["list"]), "loom vm list")
  assert string.contains(listed, run.failing_name <> "  stopped  untrusted")
    as { "vm list names the stopped failing guest:\n" <> listed }

  // Without `--yes` the removal lists what it would lose and changes nothing.
  let config_before = read_file(fail_config)
  let refusal =
    vm(run, ["rm", "--name", run.failing_name, "--config", fail_config])
  assert refusal.status != 0
  assert string.contains(refusal.output, "Deleting the guest")
    as { "rm without --yes says what it deletes:\n" <> refusal.output }
  assert string.contains(refusal.output, "It holds:\n  repo\n")
    as { "rm without --yes lists the workspaces:\n" <> refusal.output }
  assert string.contains(refusal.output, "--yes")
  assert simplifile.is_directory(guest) == Ok(True)
  assert read_file(fail_config) == config_before

  // With it, the guest and its row go, and the link table stays.
  let removed =
    expect_ok(
      vm(run, [
        "rm",
        "--name",
        run.failing_name,
        "--config",
        fail_config,
        "--yes",
      ]),
      "rm failing",
    )
  io.println_error(label <> " vm rm (failing):\n" <> removed)
  assert simplifile.is_directory(guest) == Ok(False)
  let emptied = read_file(fail_config)
  assert !string.contains(emptied, "[executors." <> run.failing_name <> "]")
    as { "the failing guest's row is gone:\n" <> emptied }
  assert string.contains(emptied, "[executor_link]")
    as { "the link table stays while other guests use it:\n" <> emptied }
  assert !string.contains(emptied, "[distribution")
  assert simplifile.is_directory(run.vm_home <> "/link") == Ok(True)

  let remaining = expect_ok(vm(run, ["list"]), "loom vm list")
  assert !string.contains(remaining, run.failing_name)
  Nil
}

// --- a failing provisioning script -------------------------------------------

// A script that exits 3 fails `up`: the refusal names the console line and
// carries the script's own output, the guest root holds the script and no
// marker, and no guest is left running. The guest's row goes into a scratch
// `loom.toml` of its own.
fn failing_script_fails_up(run: Run) -> Nil {
  let script = run.directory <> "/fail.sh"
  let assert Ok(Nil) =
    simplifile.write(script, "#!/bin/sh\necho failing-script-output\nexit 3\n")
    as "the failing script is written"

  let outcome =
    vm(run, [
      "up",
      "--name",
      run.failing_name,
      "--workspace",
      run.repository,
      "--config",
      run.directory <> "/fail.toml",
      "--github",
      "off",
      "--mem",
      "1024",
      "--cpus",
      "2",
      "--provision",
      script,
    ])
  io.println_error(label <> " vm up (failing script):\n" <> outcome.output)
  assert outcome.status != 0
  assert string.contains(outcome.output, "LOOM-PROVISION-FAILED status=3")
    as { "up names the failed script:\n" <> outcome.output }
  assert string.contains(outcome.output, "failing-script-output")
    as { "up carries the script's output:\n" <> outcome.output }

  // The script is staged and the marker is not, so the next `up` retries.
  let root = run.vm_home <> "/" <> run.failing_name <> "/root/etc/loom-vm"
  assert simplifile.is_file(root <> "/provision") == Ok(True)
  assert simplifile.is_file(root <> "/provisioned") == Ok(False)

  // `up` stopped the guest it started: nothing runs and no pid is kept.
  let status = vm(run, ["status", "--name", run.failing_name])
  assert string.contains(status.output, "process:    not running")
    as { "the failing guest is not running:\n" <> status.output }
  assert string.contains(status.output, "provision:  pending")
    as { "the failing guest's script is pending:\n" <> status.output }
  assert simplifile.is_file(
      run.vm_home <> "/" <> run.failing_name <> "/loom-vm.pid",
    )
    == Ok(False)
  Nil
}

// --- guests made over distribution ---------------------------------------------

// What a guest an older loom made over distribution leaves on the host, as
// `vm_link.settle` reads it: bundles under `deploy/`, and optionally a `link`
// record. The guest is never booted, and nothing of its root exists; the
// refusal comes from these files alone.
fn fabricate_old_guest(
  run: Run,
  name: String,
  record: option.Option(String),
) -> Nil {
  let guest = run.vm_home <> "/" <> name
  let assert Ok(Nil) = simplifile.create_directory_all(guest <> "/deploy")
    as { "the old guest " <> name <> "'s deploy directory is made" }
  case record {
    option.None -> Nil
    option.Some(text) -> {
      let assert Ok(Nil) = simplifile.write(guest <> "/link", text)
        as "the old guest's link record is written"
      Nil
    }
  }
}

// Every path under the vm home with its size, sorted, which is what "changes
// nothing" is compared on: a file written, a directory made or a record
// rewritten shows up. The guest roots are not under the old guests, and the
// running first guest's console log grows, so only the old guests' own
// directories and the top of the vm home are listed.
fn old_guest_snapshot(run: Run, names: List(String)) -> String {
  let assert Ok(find) = ffi_proc.which("find") as "find is on PATH"
  let assert Ok(#(0, top)) =
    ffi_proc.run(find, [run.vm_home, "-maxdepth", "1"], in: run.directory)
    as "find lists the vm home"
  let guests =
    list.map(names, fn(name) {
      let assert Ok(#(0, found)) =
        ffi_proc.run(
          find,
          [run.vm_home <> "/" <> name, "-exec", "ls", "-ld", "{}", ";"],
          in: run.directory,
        )
        as { "find lists the old guest " <> name }
      found
    })
  string.split(string.join([top, ..guests], "\n"), "\n")
  |> list.sort(string.compare)
  |> string.join("\n")
}

// A guest made over distribution is refused by `up` and by `ensure` before
// anything is written, booted or sent, with one message naming the three
// commands in the order a developer needs them, and `rm --yes` removes it with
// the distribution teardown `rm` keeps. The `up` guest has bundles and no
// record, the shape every such guest has; the `ensure` guest is the one
// `ensure` names after the repository, with a `link` record that says
// `distribution` as well.
fn old_guests_are_refused(run: Run) -> Nil {
  let config = run.directory <> "/old.toml"
  let up_name = run.old_name
  let ensure_name = vm_spec.guest_name_for(run.repository)

  // The file holds what a minted distribution guest installed, its
  // `[distribution]` table and trusted row under the node names `up` gave it,
  // beside an untrusted row of another guest, which must not keep the
  // deployment's table alive once its guest is removed.
  let names = vm_spec.names(up_name)
  let kept_text =
    remote_daemons.model_table("http://127.0.0.1:9")
    <> "\n[executors.newer]\ntrust = \"untrusted\"\n"
    <> "address = \"127.0.0.1:9\"\npin = \""
    <> string.repeat("ab", 32)
    <> "\"\n"
  let old_tables =
    "\n[distribution]\nnode = \""
    <> names.orchestrator_node
    <> "\"\n\n[executors."
    <> up_name
    <> "]\nnode = \""
    <> names.executor_node
    <> "\"\n"
  let model = kept_text <> old_tables
  let assert Ok(Nil) = simplifile.write(config, model)
    as "the old guests' configuration is written"
  fabricate_old_guest(run, up_name, option.None)
  fabricate_old_guest(run, ensure_name, option.Some("distribution\n"))
  let before = old_guest_snapshot(run, [up_name, ensure_name])

  // `up`, with the flags a developer would give it.
  let refused =
    vm(run, [
      "up",
      "--name",
      up_name,
      "--workspace",
      run.repository,
      "--config",
      config,
      "--github",
      "off",
    ])
  io.println_error(label <> " vm up (old guest):\n" <> refused.output)
  assert refused.status == 1
    as { "up of an old guest exits 1:\n" <> refused.output }
  assert_names_the_way_on(run, refused.output, up_name)

  // `ensure`, which is what `loom --vm` runs: the same refusal with status 1
  // and no answer line, so the launcher reads it as a failure.
  let ensured =
    vm(run, [
      "ensure",
      "--workspace",
      run.repository,
      "--config",
      config,
      "--github",
      "off",
    ])
  io.println_error(label <> " vm ensure (old guest):\n" <> ensured.output)
  assert ensured.status == 1
    as { "ensure of an old guest exits 1:\n" <> ensured.output }
  assert_names_the_way_on(run, ensured.output, ensure_name)
  assert !string.contains(ensured.output, "executor=")
    as { "ensure prints no answer line:\n" <> ensured.output }

  // Neither wrote anything: no record, no credentials, no row, no lock.
  assert old_guest_snapshot(run, [up_name, ensure_name]) == before
    as {
      "the refusals changed the vm home; before:\n"
      <> before
      <> "\nafter:\n"
      <> old_guest_snapshot(run, [up_name, ensure_name])
    }
  assert read_file(config) == model

  // `status` and `list` say these are distribution guests.
  let status = vm(run, ["status", "--name", up_name])
  assert string.contains(status.output, "link:       distribution, retired")
    as { "status names the old link:\n" <> status.output }
  // The name column is as wide as the longest name, which the `ensure` guest's
  // is, so the old guest's line is found by its name.
  let listed = expect_ok(vm(run, ["list"]), "loom vm list")
  let line =
    string.split(listed, "\n")
    |> list.find(string.starts_with(_, up_name <> " "))
  assert case line {
    Ok(found) -> string.contains(found, "  stopped  distribution")
    Error(Nil) -> False
  }
    as { "vm list names the old guest's link:\n" <> listed }

  // `rm --yes` removes each one with the distribution teardown. The `up`
  // guest's two tables leave the file; the untrusted row, the model table and
  // every other line stay, because an untrusted row does not need
  // `[distribution]`. The `ensure` guest has no table in it.
  list.each([up_name, ensure_name], fn(name) {
    let removed =
      expect_ok(
        vm(run, ["rm", "--name", name, "--config", config, "--yes"]),
        "loom vm rm of the old guest " <> name,
      )
    io.println_error(label <> " vm rm (old guest " <> name <> "):\n" <> removed)
    assert simplifile.is_directory(run.vm_home <> "/" <> name) == Ok(False)
      as { "rm removed the old guest " <> name <> ":\n" <> removed }
  })
  let after = read_file(config)
  assert !string.contains(after, "[distribution]")
    as { "the old guest's [distribution] left the file:\n" <> after }
  assert !string.contains(after, "[executors." <> up_name <> "]")
    as { "the old guest's row left the file:\n" <> after }
  list.each(string.split(kept_text, "\n"), fn(line) {
    assert string.contains(after, line)
      as { "rm kept the line " <> line <> ":\n" <> after }
  })
}

// The refusal says why, and names `sync`, `rm` and `up` for the guest, in that
// order.
fn assert_names_the_way_on(run: Run, output: String, name: String) -> Nil {
  assert string.contains(output, "trusted distribution peer of your daemon")
    as { "the refusal says why:\n" <> output }
  let copies = run.vm_home <> "/" <> name <> "/root/srv/workspaces/"
  let sync = "`loom vm sync --name " <> name <> "`"
  let rm = "`loom vm rm --name " <> name <> " --yes`"
  let up = "`loom vm up --name " <> name <> "`"
  let assert [_, after_sync] = string.split(output, sync)
    as { "the refusal names " <> sync <> " once:\n" <> output }
  let assert [between, after_rm] = string.split(after_sync, rm)
    as { "the refusal names " <> rm <> " after sync:\n" <> output }

  // Between them, the real directory of the guest's copies and the `down` a
  // running guest needs.
  assert string.contains(between, copies)
    as { "the refusal names " <> copies <> ":\n" <> output }
  assert string.contains(between, "`loom vm down --name " <> name <> "`")
    as { "the refusal names `loom vm down`:\n" <> output }
  assert string.contains(after_rm, up)
    as { "the refusal names " <> up <> " last:\n" <> output }
}

// --- a guest the default daemon reads by a reload ----------------------------------

// The isolated home the shipped launcher exports, if the step may act in it.
// `HOME` is the launcher script's own variable, so the daemon and `vm ensure`
// live under this directory and never under the developer's real `~/.loom`.
// The directory must be one the fixture made under `build/shipped-home-`, and
// must not be the process's own `HOME`.
fn isolated_home(run: Run) -> Result(String, String) {
  let home = run.orchestrator.home
  let real = native.getenv("HOME") |> result.unwrap("")
  let fixture_made = string.contains(home, "/build/shipped-home-")

  // A home that is the real one, or that is not the fixture's, is a path this
  // step must never write under.
  case fixture_made && home != real && real != "" {
    True -> Ok(home)
    False ->
      Error("the launcher's home " <> home <> " is not the fixture's own")
  }
}

// The default state directory's paths in the isolated home, which is where
// `ensure` looks for the user's daemon.
fn default_paths(home: String) -> endpoint.Paths {
  let assert Ok(paths) = endpoint.paths(home <> "/.loom")
    as "the isolated home's default state directory is private"
  paths
}

// The workspace the default-daemon step's guest serves: a repository of its
// own, so its guest is not the migration step's.
fn default_workspace(run: Run) -> String {
  run.directory <> "/defaultws"
}

// The run as the default-daemon step sees it: the vm home is the isolated
// home's `~/.loom/vm`, the default every `loom --vm` user has. A daemon that
// started with no `[executor_link]` takes a proposed table on a reload only
// when its files are under that directory or the state root's `vm`
// (`executor_reload.link_rule`), so a vm home elsewhere, like the fixture's
// own, would be refused the reload by design.
fn default_run(run: Run, home: String) -> Run {
  Run(..run, vm_home: home <> "/.loom/vm")
}

// What every `loom --vm` takes: `loomd vm ensure` with no `--config` and the
// default vm home, against the default `loom.toml` of a daemon that already
// runs and holds no `[executor_link]`. `ensure` mints the link credentials,
// boots the guest, writes `[executor_link]` and its row into that file, finds
// the daemon through its endpoint record, sees that it does not list the
// guest, and asks it to reload (protocol-change/116). The step checks the
// answer line, that the reload was not refused, that the same daemon process
// still runs (its fence is the pid and birth marker it started with), that it
// now lists the guest, and that `rm` of this vm home's last guest takes the
// row, `[executor_link]` and the credentials out again with the daemon
// running. It runs only when the launcher's home is the fixture's own.
fn default_daemon_reads_the_guest(run: Run) -> Nil {
  case isolated_home(run) {
    Error(reason) ->
      io.println_error("SKIP " <> label <> " default daemon: " <> reason)
    Ok(home) -> {
      let run = default_run(run, home)
      let assert Ok(Nil) = native.ensure_private_directory(run.vm_home)
        as "the default vm home is private"
      setup_manifest(run)

      let workspace = default_workspace(run)
      let assert Ok(Nil) = simplifile.create_directory_all(workspace)
        as "the default step's repository directory is created"
      let assert Ok(Nil) =
        simplifile.write(workspace <> "/README.md", "the default step\n")
        as "the default step's repository has a file"
      git_in(workspace, ["init", "-q", "-b", "main"])
      git_in(workspace, ["add", "README.md"])
      git_in(workspace, [
        "-c",
        "user.name=Loom Fixture",
        "-c",
        "user.email=fixture@loom.invalid",
        "commit",
        "-q",
        "-m",
        "initial",
      ])
      let name = vm_spec.guest_name_for(workspace)

      // The daemon reads the default file, which holds a model it never calls
      // and no `[executor_link]`.
      let paths = default_paths(home)
      let config = home <> "/.loom/loom.toml"
      let assert Ok(Nil) =
        simplifile.write(
          config,
          remote_daemons.model_table("http://127.0.0.1:9"),
        )
        as "the default daemon has a configuration"
      let layout =
        remote_daemons.Layout(
          ..run.orchestrator,
          label: "default",
          paths:,
          config:,
        )
      let running = remote_daemons.start_plain(layout)
      let control = remote_daemons.open_control(running)
      let assert endpoint.Ready(fence:, ..) = running.connected.record
        as "the default daemon published its endpoint"

      // `ensure` with no `--config`, as the launcher runs it.
      let ensured =
        vm(run, ["ensure", "--workspace", workspace, "--github", "off"])
      io.println_error(
        label <> " vm ensure (default daemon):\n" <> ensured.output,
      )
      assert ensured.status == 0 as { "ensure exits 0:\n" <> ensured.output }
      assert !string.contains(ensured.output, "refused to reload")
        as { "the daemon took the reload:\n" <> ensured.output }
      let answer = vm_spec.ensure_line(name, "defaultws")
      assert list.contains(
        string.split(ensured.output, "\n") |> list.map(string.trim),
        answer,
      )
        as { "ensure ends with " <> answer <> ":\n" <> ensured.output }
      let written = read_file(config)
      assert string.contains(written, "[executors." <> name <> "]")
        as {
          "ensure wrote the guest's row into the default file:\n" <> written
        }
      assert string.contains(written, "[executor_link]")
        as { "ensure wrote the link table into the default file:\n" <> written }

      // The same process runs, and it reads the row without a restart.
      assert endpoint.is_present(fence) == Ok(True)
        as "the default daemon was not stopped or restarted"
      let shown =
        string.inspect(remote_daemons.command(
          control,
          10,
          "deployment.status",
          json.Object([]),
        ))
      assert string.contains(shown, name)
        as { "the running daemon lists the guest:\n" <> shown }

      // A second `ensure` finds the guest serving and touches nothing.
      let again =
        vm(run, ["ensure", "--workspace", workspace, "--github", "off"])
      assert again.status == 0
        as { "the second ensure exits 0:\n" <> again.output }
      assert string.contains(again.output, "already serving")
        as { "the second ensure takes the fast path:\n" <> again.output }

      // `rm` of the vm home's last guest takes its row, `[executor_link]` and
      // the link credentials out, and asks the same daemon to drop the link.
      let down = vm(run, ["down", "--name", name])
      assert string.contains(down.output, "Stopped the guest " <> name)
        as { "the default step's guest stops:\n" <> down.output }
      let removed =
        expect_ok(
          vm(run, ["rm", "--name", name, "--yes"]),
          "loom vm rm of the default step's guest",
        )
      io.println_error(label <> " vm rm (default daemon):\n" <> removed)
      let after_rm = read_file(config)
      assert !string.contains(after_rm, "[executors." <> name <> "]")
        as { "rm took the row out of the default file:\n" <> after_rm }
      assert !string.contains(after_rm, "[executor_link]")
        as { "rm took the link table out with the last guest:\n" <> after_rm }
      assert simplifile.is_directory(run.vm_home <> "/link") == Ok(False)
        as "rm took the default vm home's link credentials"
      assert endpoint.is_present(fence) == Ok(True)
        as "the default daemon still runs after rm"
      let after =
        string.inspect(remote_daemons.command(
          control,
          20,
          "deployment.status",
          json.Object([]),
        ))
      assert !string.contains(after, name)
        as { "the daemon no longer lists the guest:\n" <> after }
      remote_pair.close_daemons([running])
      remote_daemons.retire(paths)
    }
  }
}

// What a failed default-daemon step can leave on the isolated home: its guest
// running under the default vm home, its daemon, and the vm home itself, which
// holds a guest root of read-only directories and is outside the fixture's
// own directory.
fn default_teardown(run: Run) -> Nil {
  case isolated_home(run) {
    Error(_) -> Nil
    Ok(home) -> {
      let run = default_run(run, home)
      let name = vm_spec.guest_name_for(default_workspace(run))
      let _stopped = vm(run, ["down", "--name", name])
      remote_daemons.retire(default_paths(home))
      let assert Ok(chmod) = ffi_proc.which("chmod") as "chmod is on PATH"
      let _writable = ffi_proc.run(chmod, ["-R", "u+w", run.vm_home], in: ".")
      let _removed = simplifile.delete_all([run.vm_home])
      Nil
    }
  }
}

// --- the last guest ------------------------------------------------------------

// The first guest is the last on the link, so removing it takes
// `[executor_link]` out of its file and the vm home's link credentials with it.
fn last_guest_takes_the_link(run: Run) -> Nil {
  let down = vm(run, ["down", "--name", run.name])
  assert string.contains(down.output, "Stopped the guest " <> run.name)
    as { "the first guest stops:\n" <> down.output }
  let removed =
    expect_ok(
      vm(run, [
        "rm",
        "--name",
        run.name,
        "--config",
        run.orchestrator.config,
        "--yes",
      ]),
      "loom vm rm of the last guest",
    )
  io.println_error(label <> " vm rm (last guest):\n" <> removed)
  let after = read_file(run.orchestrator.config)
  assert !string.contains(after, "[executors." <> run.name <> "]")
    as { "the last guest's row is gone:\n" <> after }
  assert !string.contains(after, "[executor_link]")
    as { "the link table went with the last guest:\n" <> after }
  assert string.contains(after, "[models.")
  assert simplifile.is_directory(guest_directory(run)) == Ok(False)
  assert simplifile.is_directory(run.vm_home <> "/link") == Ok(False)
    as "the link credentials went with the last guest"
}

// --- the fixture's inputs ----------------------------------------------------

// A repository with one commit, which is what a developer's checkout is.
fn make_repository(run: Run) -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all(run.repository)
    as "the repository directory is created"
  let assert Ok(Nil) =
    simplifile.write(
      run.repository <> "/README.md",
      "the host's checkout of the repository\n",
    )
    as "the repository has a file"
  git(run, ["init", "-q", "-b", "main"])
  git(run, ["add", "README.md"])
  git(run, [
    "-c",
    "user.name=Loom Fixture",
    "-c",
    "user.email=fixture@loom.invalid",
    "commit",
    "-q",
    "-m",
    "initial",
  ])
}

fn git(run: Run, arguments: List(String)) -> Nil {
  let assert Ok(git) = ffi_proc.which("git") as "git is on PATH"
  let assert Ok(#(0, _)) = ffi_proc.run(git, arguments, in: run.repository)
    as "git prepares the throwaway repository"
  Nil
}

// Writes the artifact manifest the way a developer's `make vmm-install-dev`
// does: `loom-vm setup --from-build` over a build tree. The tree is a
// directory of links to the artifacts the environment names, so the test needs
// no layout from the host beyond those paths. The guest root is deliberately a
// link: `loom vm up` must clone what it names and never boot the export.
fn install_artifacts(run: Run) -> Nil {
  let build = run.directory <> "/build"
  let assert Ok(Nil) = simplifile.create_directory_all(build)
    as "the build tree directory is created"
  link(run.artifacts.runner, build <> "/go-microvm-runner")
  link(run.artifacts.firmware_dir, build <> "/firmware")
  link(run.artifacts.guest_root, build <> "/guest-root")
  setup_manifest(run)
}

// Writes the manifest of the build tree `install_artifacts` made into the run's
// vm home, with `loom-vm setup --from-build`. A run with another vm home calls
// this again for its own.
fn setup_manifest(run: Run) -> Nil {
  let output =
    expect_ok(
      vm_launcher(run, [
        "setup",
        "--from-build",
        run.directory <> "/build",
        "--lib-dir",
        run.artifacts.lib_dir,
      ]),
      "loom-vm setup --from-build",
    )
  io.println_error(label <> " manifest (" <> run.vm_home <> "):\n" <> output)
}

fn link(target: String, path: String) -> Nil {
  let assert Ok(Nil) = simplifile.create_symlink(to: target, from: path)
    as { "the build tree links " <> path }
  Nil
}

// --- the commands ------------------------------------------------------------

// What a command printed, and how it ended.
type Outcome {
  Outcome(status: Int, output: String)
}

// Runs `program` with the run's `LOOM_VM_HOME` and its made-up token.
fn with_environment(
  run: Run,
  program: String,
  arguments: List(String),
) -> Outcome {
  let assert Ok(env) = ffi_proc.which("env") as "env is on PATH"
  let assert Ok(#(status, output)) =
    ffi_proc.run(
      env,
      list.append(
        [
          "LOOM_VM_HOME=" <> run.vm_home,
          "LOOM_VM_GITHUB_TOKEN=" <> run.token,
          program,
        ],
        arguments,
      ),
      in: run.directory,
    )
    as "the command runs"
  Outcome(status:, output:)
}

// `loom-vm`'s own commands, which `setup` is.
fn vm_launcher(run: Run, arguments: List(String)) -> Outcome {
  with_environment(run, run.artifacts.launcher, arguments)
}

// `loom vm`, through the shipped server beside LOOM_BOOTSTRAP_E2E_SERVER. The
// launcher script gives it the orchestrator's isolated home, so a default
// daemon `up` might look for is never the developer's own.
fn vm(run: Run, arguments: List(String)) -> Outcome {
  with_environment(
    run,
    run.orchestrator.launcher,
    list.prepend(arguments, "vm"),
  )
}

fn expect_ok(outcome: Outcome, what: String) -> String {
  case outcome.status {
    0 -> outcome.output
    status ->
      panic as {
        what <> " exited " <> int.to_string(status) <> ":\n" <> outcome.output
      }
  }
}

// Runs `loom vm up` for the run's guest, with GitHub through the environment's
// token and the given further flags, and answers what it printed.
fn up(run: Run, flags: List(String)) -> String {
  let started = native.monotonic_time_ms()
  let output =
    expect_ok(
      vm(
        run,
        list.append(
          [
            "up",
            "--name",
            run.name,
            "--workspace",
            run.repository,
            "--config",
            run.orchestrator.config,
            "--github",
            "env",
          ],
          flags,
        ),
      ),
      "loom vm up",
    )

  // The time from the command to a serving executor is the tier's cold start
  // (or its resume), which an operator weighs against a host executor.
  io.println_error(
    label
    <> " vm up took "
    <> int.to_string(native.monotonic_time_ms() - started)
    <> " ms:\n"
    <> output,
  )
  output
}

// --- the assertions ----------------------------------------------------------

fn assert_first_turn(run: Run, result: String) -> Nil {
  // No-new-privileges is set by loom-exec's stage 2 for every jailed call.
  assert string.contains(result, "NoNewPrivs:\t1")

  // The tier's own kernel (ADR-022 D3) names itself in the release, which no
  // host kernel does, so this proves both that the call ran in the guest and
  // that it ran where the broker's landlock demand holds.
  assert string.contains(result, "-loom-landlock")

  // The listener's key stays out of model code's reach inside the guest, and
  // there is no cookie for it to reach. The key is read from the host's copy
  // of the guest's root, where the bash call looked, so its absence from the
  // result says the mask held and not that the file was missing. The read's
  // exit status is not asserted: a masked file can be bound to /dev/null,
  // which `cat` reads successfully as empty.
  let key =
    read_file(guest_directory(run) <> "/root" <> node_dir <> "/creds/key.pem")
  assert_key_masked(key, result)

  // The provisioning script ran as root before the executor served, so the
  // jailed call reads the line it appended, once.
  assert string.contains(result, "provisioned=run")
  assert string.contains(result, "runs=1")

  // The jailed shell holds the proxy's placeholder, never the token.
  assert string.contains(result, "gh_token=loomvm_")
  assert !string.contains(result, run.token)

  // With GitHub reachable: an unauthenticated read succeeds, and the proxy
  // replaced the placeholder with the made-up token, which GitHub refuses.
  case reach() {
    OffHost -> Nil
    GitHub -> {
      assert string.contains(result, "allowed=200")
      assert string.contains(result, "denied=403")

      // The script installed jq as root and the jail, whose PATH holds
      // /usr/bin, runs it.
      assert string.contains(result, "jq=jq-")
      assert string.contains(result, "zen=200")
      assert string.contains(result, "user=401")
    }
  }

  // The write landed in the guest's copy of the checkout.
  let written = read_marker(run)
  assert written == marker_content
}

// The made-up token is a secret of the host. It must be nowhere in the files
// the guest could read or write: its root, its state disk and its log. `grep`
// exits 1 when nothing matches, and prints a name for each file that does.
fn assert_never_on_host(run: Run) -> Nil {
  let guest = run.vm_home <> "/" <> run.name
  let assert Ok(grep) = ffi_proc.which("grep") as "grep is on PATH"
  let assert Ok(#(status, output)) =
    ffi_proc.run(grep, ["-rFl", run.token, guest], in: run.directory)
    as "grep runs over the guest's files"
  assert output == ""
  assert status == 1
  Nil
}

// What a second `up` without `--fresh` leaves: the guest's own root, not a
// link to the export, the checkout the first turn wrote into, and the state
// disk.
fn assert_resumed(run: Run) -> Nil {
  let guest = run.vm_home <> "/" <> run.name
  let assert Ok(info) = simplifile.link_info(guest <> "/root")
    as "the guest has a root"
  assert simplifile.file_info_type(info) == simplifile.Directory
  assert read_marker(run) == marker_content
  assert simplifile.is_file(guest <> "/state.img") == Ok(True)
  Nil
}

// The script the developer would write. It appends one line per run, and with
// network access it reaches the allowed host as root two ways: over HTTP,
// directly, as `apt` does, and over HTTPS through the credential proxy, whose
// address root's environment holds because the init sources the proxy's file.
fn write_provision_script(run: Run) -> Nil {
  let reach = case reach() {
    OffHost -> ""
    GitHub ->
      "curl -fsS --max-time 30 -o /dev/null http://"
      <> allowed_host
      <> "/debian/"
      <> "\ncurl -fsS --max-time 30 -o /dev/null https://"
      <> allowed_host
      <> "/debian/"
      <> "\napt-get update\n"
      <> "apt-get install -y --no-install-recommends jq\n"
  }
  let assert Ok(Nil) =
    simplifile.write(
      run.script,
      "#!/bin/sh\nset -eu\n" <> reach <> "echo run >> " <> runs_file <> "\n",
    )
    as "the provisioning script is written"
  Nil
}

// The text of the guest's allow file on the host.
fn read_allow(run: Run) -> String {
  let assert Ok(text) =
    simplifile.read(run.vm_home <> "/" <> run.name <> "/allow")
    as "vm up recorded the allowed hosts"
  text
}

// The script's own file, read from the guest root on the host, holds one line
// after the resume: the init did not run the script again.
fn assert_script_ran_once(run: Run) -> Nil {
  let runs = run.vm_home <> "/" <> run.name <> "/root" <> runs_file
  let assert Ok(text) = simplifile.read(runs)
    as "the script's file is in the guest root"
  assert text == "run\n"
  Nil
}

fn read_marker(run: Run) -> String {
  let path =
    run.vm_home
    <> "/"
    <> run.name
    <> "/root"
    <> workspaces_dir
    <> "/"
    <> remote_pair.workspace_name
    <> "/"
    <> marker
  let assert Ok(text) = simplifile.read(path)
    as "the first turn wrote the marker into the guest's checkout"
  text
}

// --- a guest reached over the untrusted link -----------------------------------

const untrusted_prompt = "run it in the untrusted guest"

const untrusted_answer = "ran in the untrusted guest"

// What the jailed call reports. The key is read on purpose: the mask makes the
// read fail (observed: `Permission denied`), so the key's text never reaches
// the result, and the certificate beside it is public and prints its header,
// which shows the call could have read the key had it not been masked.
fn untrusted_command() -> String {
  "echo \"kernel=$(uname -r)\"; grep -E '^NoNewPrivs:' /proc/self/status; "
  <> "cat "
  <> node_dir
  <> "/creds/key.pem; "
  <> "head -c 27 "
  <> node_dir
  <> "/creds/cert.pem; echo; "
  <> home_listing()
  <> "true"
}

// Lists the node's home on one line and prints the listing's status first, so
// a failed `ls` is seen as a failure and not as a home with nothing in it.
fn home_listing() -> String {
  "entries=$(ls -A "
  <> node_dir
  <> "/home 2>&1); echo \"home_status=$?\"; "
  <> "echo \"home_entries=$(printf '%s' \"$entries\" | tr '\\n' ' ')\"; "
}

// A second guest made with no flag, in a configuration of its own. `up` writes
// the link tables beside the model table the step gave the file, an
// orchestrator started on that file serves a session on the guest, and a jailed
// call settles on the guest's kernel. What the guest holds is checked as for
// the first: no cookie anywhere in its root, no `[distribution]` table in its
// configuration, no node in the host's epmd, and a jailed read of the
// executor's key that returns nothing. The broker tunnel's three services are
// observed on its session. The step ends with the daily verbs of such a guest:
// a resume that changes nothing, a refused `--link distribution`, and a
// removal that takes its row and leaves the link table to the first guest.
fn untrusted_guest(run: Run) -> Nil {
  let layout = run.untrusted
  let name = run.untrusted_name
  let flags = [
    "--name",
    name,
    "--workspace",
    run.repository,
    "--config",
    layout.config,
    "--github",
    "off",
    "--mem",
    "1024",
    "--cpus",
    "2",
  ]
  let exchanges = [
    bash_exchange(placed_prompt, "placed-call", leaf_digest_command()),
    reply_after("placed-call", placed_answer),
    bash_exchange(untrusted_prompt, "untrusted-call", untrusted_command()),
    reply_after("untrusted-call", untrusted_answer),
    bash_exchange(tunnel_prompt, "tunnel-call", tunnel_command()),
    reply_after("tunnel-call", tunnel_answer),
  ]

  // `goal_set` is refused unless the server routes an advisor, so the config
  // names one. Its provider has an empty script because the step never waits
  // for a review: only the check, which runs before any feed, is under test.
  let #(#(#(key, digests), report), _reviewer) =
    provider.with_watched_server(
      [],
      provider.OnlySuccessful,
      600_000,
      fn(reviewer_url, _reviewer_watch) {
        provider.with_server_for(
          exchanges,
          provider.OnlySuccessful,
          580_000,
          fn(url) {
            // The file starts with only the model tables a daemon needs, which
            // is what a developer's own file would hold.
            let assert Ok(Nil) =
              simplifile.write(
                layout.config,
                remote_pair.models(url, option.Some(reviewer_url)),
              )
              as "the orchestrator's configuration is written"
            let model = read_file(layout.config)

            let output = expect_ok(vm(run, ["up", ..flags]), "loom vm up")
            io.println_error(label <> " vm up (untrusted):\n" <> output)
            let guest = run.vm_home <> "/" <> name
            let port = untrusted_port(guest)
            assert_serves(output, port)
            assert_link_files(run, layout.config, name, guest, port, model)

            // An orchestrator started on that file reads the rows and dials
            // the guest, with no distribution options file and no cookie.
            let running = remote_daemons.start_plain(layout)
            let control = remote_daemons.open_control(running)
            let #(session, settled) =
              remote_daemons.create_and_settle(
                control,
                1,
                "untrusted-guest",
                name,
                remote_pair.workspace_name,
              )
            assert remote_daemons.settled_state(settled) == "resident"

            // The daemon's deployment read lists the untrusted row by name,
            // which is how `ensure` tells that a daemon has read the row.
            let shown =
              string.inspect(remote_daemons.command(
                control,
                20,
                "deployment.status",
                json.Object([]),
              ))
            io.println_error(
              label <> " deployment.status (untrusted):\n" <> shown,
            )
            assert string.contains(shown, name)

            let digests =
              second_guest_after_reload(run, flags, name, running, control)

            let opened =
              remote_pair.Opened(orchestrator: running, control:, session:)
            remote_pair.converse_for(opened, untrusted_prompt, [
              untrusted_answer,
            ])

            // The three things the broker tunnel serves, on this session. A
            // second turn edits the guest's checkout, and the transcript
            // carries both answers.
            remote_pair.converse_for(opened, tunnel_prompt, [
              untrusted_answer,
              tunnel_answer,
            ])
            let observed = tunnel_serves(run, opened)

            remote_daemons.stop_session(running, control, 100, session)
            remote_pair.close_daemons([running])
            remote_daemons.retire(layout.paths)

            // Asserted only now, so a failed assertion cannot leave the
            // session open on a guest the fixture then takes down.
            assert_tunnel(observed)

            // The key is read now, because the removal below deletes the root.
            let key =
              read_file(guest <> "/root" <> node_dir <> "/creds/key.pem")
            untrusted_daily_verbs(run, guest, port, flags)
            #(key, digests)
          },
        )
      },
    )

  let assert Ok(requests) = report
    as "the scripted turns on the untrusted guests completed"

  // The session placed on the further guest ran there: its jailed call saw
  // that guest's own leaf and not the step's first guest's.
  let placed = remote_daemons.result_text(requests, "placed-call")
  io.println_error(label <> " further guest tool result:\n" <> placed)
  assert string.contains(placed, digests.own)
    as { "the further guest's call saw its own leaf:\n" <> placed }
  assert !string.contains(placed, digests.other)
    as { "the further guest's call saw the first guest's leaf:\n" <> placed }

  let result = remote_daemons.result_text(requests, "untrusted-call")
  io.println_error(label <> " untrusted tool result:\n" <> result)
  assert_untrusted_turn(key, result)
  let edited = remote_daemons.result_text(requests, "tunnel-call")
  io.println_error(label <> " tunnel edit tool result:\n" <> edited)
  assert string.contains(edited, "edit_status=0")
}

// The guest `second_guest_after_reload` brings up beside the second one.
fn second_untrusted_name(run: Run) -> String {
  run.untrusted_name <> "b"
}

// A further guest, brought up while the daemon of the step's first still runs
// (protocol-change/116), with `--link untrusted` spelled out, which scripts of
// the opt-in weeks pass and which changes nothing. The step's configuration is
// not the default file, so `up` cannot find this daemon and the test sends the
// command itself: the reply must list the new guest `started` and the first
// `unchanged`, and a session on the new guest must be resident with no second
// daemon start and no restart, and its jailed call must run in that guest. The
// guest is stopped and removed here, before the step's daily verbs. It answers
// the digests of the two guests' leaves, which the caller holds the call's
// output against once the provider's script has ended.
fn second_guest_after_reload(
  run: Run,
  flags: List(String),
  first: String,
  running: remote_daemons.Running,
  control: remote_daemons.Control,
) -> Digests {
  let second = second_untrusted_name(run)
  let second_flags =
    list.map(flags, fn(flag) {
      case flag == first {
        True -> second
        False -> flag
      }
    })
  let output =
    expect_ok(
      vm(run, ["up", "--link", "untrusted", ..second_flags]),
      "loom vm up --link untrusted (second guest)",
    )
  io.println_error(label <> " vm up (second untrusted guest):\n" <> output)

  // The daemon has not read the new row until it is asked to.
  let reply =
    remote_daemons.command(control, 30, "executors.reload", json.Object([]))
  io.println_error(label <> " executors.reload:\n" <> string.inspect(reply))
  let assert Ok(decoded) =
    executor_reload.decode(remote_daemons.field(reply, "body"))
    as "the reload reply decodes"
  let changes =
    list.map(decoded.executors, fn(entry) {
      #(entry.name, executor_reload.change_word(entry.change))
    })
  assert list.contains(changes, #(second, "started"))
  assert list.contains(changes, #(first, "unchanged"))

  // The daemon that served the first guest serves the second one now.
  let #(session, settled) =
    remote_daemons.create_and_settle(
      control,
      31,
      "untrusted-guest-second",
      second,
      remote_pair.workspace_name,
    )
  assert remote_daemons.settled_state(settled) == "resident"

  // A jailed call on that session prints the digest of the leaf the guest it
  // runs in presents, which only that guest's root holds.
  remote_pair.converse_for(
    remote_pair.Opened(orchestrator: running, control:, session:),
    placed_prompt,
    [placed_answer],
  )
  let digests =
    Digests(
      own: leaf_digest(run.vm_home <> "/" <> second),
      other: leaf_digest(run.vm_home <> "/" <> first),
    )
  assert digests.own != digests.other

  // The session is stopped while its guest still answers. A session whose
  // executor has gone cannot close its scope, and the daemon would then wait
  // on it when the step retires the daemon.
  remote_daemons.stop_session(running, control, 32, session)

  let _stopped = vm(run, ["down", "--name", second])
  let _removed =
    expect_ok(
      vm(run, [
        "rm",
        "--name",
        second,
        "--yes",
        "--config",
        run.untrusted.config,
      ]),
      "loom vm rm (second guest)",
    )

  // The row is gone from the file, and a second reload stops its link, which
  // would otherwise dial the removed guest for as long as the daemon lived.
  let after =
    remote_daemons.command(control, 33, "executors.reload", json.Object([]))
  io.println_error(
    label <> " executors.reload (after rm):\n" <> string.inspect(after),
  )
  let assert Ok(removed) =
    executor_reload.decode(remote_daemons.field(after, "body"))
    as "the second reload reply decodes"
  let after_changes =
    list.map(removed.executors, fn(entry) {
      #(entry.name, executor_reload.change_word(entry.change))
    })
  assert list.contains(after_changes, #(second, "stopped"))
  assert list.contains(after_changes, #(first, "unchanged"))
  digests
}

const placed_prompt = "which guest runs this session"

const placed_answer = "the further guest"

// The SHA-256 of the certificate the executor presents, as `sha256sum` prints
// it in the guest. The file is public; it names the guest because each guest
// has its own leaf.
fn leaf_digest_command() -> String {
  "sha256sum " <> node_dir <> "/creds/cert.pem; true"
}

// The leaf digests of the guest a session was placed on and of another guest.
type Digests {
  Digests(own: String, other: String)
}

// The lowercase hexadecimal SHA-256 of a guest's staged certificate, read from
// the host's copy of its root.
fn leaf_digest(guest: String) -> String {
  let path = guest <> "/root" <> node_dir <> "/creds/cert.pem"
  let assert Ok(bits) = simplifile.read_bits(path) as { path <> " is readable" }
  crypto.hash(crypto.Sha256, bits)
  |> bit_array.base16_encode
  |> string.lowercase
}

// The host port the guest's row names, as `link-port` records it.
fn untrusted_port(guest: String) -> String {
  string.trim(read_file(guest <> "/link-port"))
}

// The line `up` prints for a guest that serves over the untrusted link, at the
// port its `link-port` record names.
fn assert_serves(output: String, port: String) -> Nil {
  assert string.contains(
    output,
    "serves its executor over the untrusted link at 127.0.0.1:" <> port,
  )
    as { "up reports the executor serving at port " <> port <> ":\n" <> output }
}

// What `up` with no `--link` leaves, read from the host. `config` is the file
// `up` wrote into and `before` what it held first. The guest's root is
// untrusted input, but these files are the ones `up` staged before the boot,
// and a guest that never held a cookie has none to write.
fn assert_link_files(
  run: Run,
  config_path: String,
  name: String,
  guest: String,
  port: String,
  before: String,
) -> Nil {
  let root = guest <> "/root"
  let config = read_file(config_path)

  // The host's file gained the two tables beside what it held, and no
  // deployment: nothing here was provisioned, joined or sealed.
  assert string.starts_with(config, string.trim_end(before))
    as { "up kept what the file held:\n" <> config }
  assert string.contains(config, "[executor_link]")
    as { "up wrote the link table:\n" <> config }
  assert string.contains(config, "[executors." <> name <> "]")
    as { "up wrote the guest's row:\n" <> config }
  assert string.contains(config, "trust = \"untrusted\"")
  assert string.contains(config, "address = \"127.0.0.1:" <> port <> "\"")
    as { "the row names the recorded port " <> port <> ":\n" <> config }
  assert !string.contains(config, "[distribution]")
    as { "up wrote no distribution table:\n" <> config }
  assert simplifile.is_directory(guest <> "/deploy") == Ok(False)
  assert simplifile.is_directory(run.vm_home <> "/authority") == Ok(False)
    as "no authority key was sealed"

  // The guest's configuration has the listener and no `[distribution]`, and
  // admits the one pin of the orchestrator's leaf.
  let staged = read_file(root <> node_dir <> "/loom.toml")
  assert string.contains(staged, "[executor_listener]")
    as { "the guest has a listener:\n" <> staged }
  assert string.contains(staged, "listen = \"0.0.0.0:4370\"")
  assert !string.contains(staged, "[distribution]")
    as { "the guest has no distribution table:\n" <> staged }
  assert !string.contains(staged, "cookie")

  // No cookie anywhere in the root, which is what a takeover of the guest
  // would otherwise carry to the host daemon.
  let assert Ok(find) = ffi_proc.which("find") as "find is on PATH"
  let assert Ok(#(_, cookies)) =
    ffi_proc.run(find, [root, "-name", ".erlang.cookie"], in: run.directory)
    as "find runs over the guest's root"
  assert cookies == ""

  // The credentials are private on the host, and the guest holds its own key
  // and not the orchestrator's or the authority's.
  let link = run.vm_home <> "/link"
  list.each(["ca.key", "ca.pem", "orchestrator.key", "orchestrator.pem"], fn(f) {
    assert simplifile.is_file(link <> "/" <> f) == Ok(True)
  })
  assert mode_of(link) == 0o700
  assert mode_of(link <> "/ca.key") == 0o600
  assert mode_of(link <> "/orchestrator.key") == 0o600
  let key = read_file(root <> node_dir <> "/creds/key.pem")
  assert !string.contains(key, string.trim(read_file(link <> "/ca.key")))
  assert !string.contains(
    key,
    string.trim(read_file(link <> "/orchestrator.key")),
  )

  // Neither host key is anywhere in the root, under any name: a body line of
  // each is searched for over every file, as for the authority key the
  // distribution guests sealed. `grep` exits 1 when nothing matches. No Git
  // runs in a guest root.
  let assert Ok(grep) = ffi_proc.which("grep") as "grep is on PATH"
  list.each(["ca.key", "orchestrator.key"], fn(file) {
    let assert [_, body, ..] =
      string.split(read_file(link <> "/" <> file), "\n")
      as { file <> " has a body line" }
    let assert Ok(#(status, output)) =
      ffi_proc.run(grep, ["-rFla", body, root], in: run.directory)
      as "grep runs over the guest's root"
    assert output == "" && status == 1
      as { "the guest's root holds " <> file <> ": " <> output }
  })

  // The host's epmd has no node for the guest: it was forwarded, not
  // published.
  let assert Ok(epmd) = ffi_proc.which("epmd") as "epmd is on PATH"
  let assert Ok(#(_, names)) = ffi_proc.run(epmd, ["-names"], in: run.directory)
    as "epmd lists its names"
  assert !string.contains(names, "loom_vm_" <> name)

  // `status` names the link and the address in place of the epmd line.
  let status = expect_ok(vm(run, ["status", "--name", name]), "loom vm status")
  assert string.contains(
    status,
    "link:       untrusted, TLS to 127.0.0.1:" <> port,
  )
  assert !string.contains(status, "epmd:")
  assert string.contains(status, "process:    running")
  let listed = expect_ok(vm(run, ["list"]), "loom vm list")
  assert string.contains(listed, name)
  Nil
}

fn mode_of(path: String) -> Int {
  let assert Ok(info) = simplifile.file_info(path) as { path <> " is there" }
  int.bitwise_and(info.mode, 0o777)
}

// The jailed call ran in the guest, under the jail, and could not read the key
// that the executor's own configuration names.
fn assert_untrusted_turn(key: String, result: String) -> Nil {
  // The tier's own kernel, under loom-exec, as in the first guest's turn.
  assert string.contains(result, "NoNewPrivs:\t1")
  assert string.contains(result, "-loom-landlock")
  assert_key_masked(key, result)
}

// The key the executor presents, read from the host's copy of the guest's
// root, is nowhere in what a jailed call printed, and the certificate beside it,
// which is public, was read. Nothing in the node's home is a cookie: the line is
// printed whole, so a file the daemon made there would be named in it.
fn assert_key_masked(key: String, result: String) -> Nil {
  let assert [_header, body, ..] = string.split(key, "\n")
    as "the staged key has a body line"
  assert body != ""
  assert !string.contains(result, body)
    as { "the jailed call read the listener's key:\n" <> result }
  assert !string.contains(result, "PRIVATE KEY")
    as { "the jailed call printed a private key:\n" <> result }
  assert string.contains(result, "-----BEGIN CERTIFICATE-----")
    as { "the jailed call read the public certificate:\n" <> result }
  assert string.contains(result, "home_status=0")
    as { "the jailed call could list the node's home:\n" <> result }
  assert string.contains(result, "home_entries=")
    as { "the jailed call listed the node's home:\n" <> result }
  assert !string.contains(result, "erlang.cookie")
    as { "the node's home holds a cookie:\n" <> result }
  Nil
}

// The verbs a developer uses on the guest afterwards. The orchestrator is gone,
// so the guest is stopped and the host's files can be compared byte for byte.
fn untrusted_daily_verbs(
  run: Run,
  guest: String,
  port: String,
  flags: List(String),
) -> Nil {
  let name = run.untrusted_name
  let config = run.untrusted.config
  let down = vm(run, ["down", "--name", name])
  assert string.contains(down.output, "Stopped the guest " <> name)

  // No command makes a distribution guest: the flag is refused, saying why,
  // before anything is read, and nothing changes.
  let before = read_file(config)
  let refused =
    vm(run, ["up", "--link", "distribution", "--name", name, "--config", config])
  assert refused.status != 0
  assert string.contains(refused.output, "--link distribution is retired")
    as { "the parser refuses --link distribution:\n" <> refused.output }
  assert read_file(config) == before
  assert untrusted_port(guest) == port

  // A resume boots the same port and changes no file of the host's: the
  // daemon has nothing new to read.
  let resumed =
    expect_ok(
      vm(run, ["up", ..flags]),
      "loom vm up resumes the untrusted guest",
    )
  io.println_error(label <> " vm up (untrusted resume):\n" <> resumed)
  assert string.contains(resumed, "already as this guest needs it")
  assert !string.contains(resumed, "Your daemon")
  assert !string.contains(resumed, "must restart")
  assert_serves(resumed, port)
  assert read_file(config) == before
  assert untrusted_port(guest) == port
  let stopped = vm(run, ["down", "--name", name])
  assert string.contains(stopped.output, "Stopped the guest " <> name)

  // `rm` lists what it would remove and changes nothing without `--yes`, then
  // removes the row, and there is nothing to revoke. The first guest is still
  // on the link, so `[executor_link]` and the credentials stay for it.
  let listing = vm(run, ["rm", "--name", name, "--config", config])
  assert listing.status != 0
  assert string.contains(listing.output, "[executors." <> name <> "]")
    as { "rm without --yes names the row:\n" <> listing.output }
  assert read_file(config) == before
  let removed =
    expect_ok(
      vm(run, ["rm", "--name", name, "--config", config, "--yes"]),
      "loom vm rm of the untrusted guest",
    )
  io.println_error(label <> " vm rm (untrusted):\n" <> removed)
  let after = read_file(config)
  assert !string.contains(after, "[executors." <> name <> "]")
    as { "the guest's row is gone:\n" <> after }
  assert string.contains(after, "[executor_link]")
    as { "the link table stays while the first guest uses it:\n" <> after }
  assert string.contains(after, "[models.fixture]")
  assert simplifile.is_directory(guest) == Ok(False)
  assert simplifile.is_directory(run.vm_home <> "/link") == Ok(True)
    as "the link credentials stay while the first guest uses them"
  Nil
}

// --- what the broker tunnel serves (protocol-change/117) -----------------------

const tunnel_prompt = "edit the checkout of the untrusted guest"

const tunnel_answer = "edited in the untrusted guest"

// The file the jailed edit creates and the goal's check looks for. README.md is
// tracked in the guest's copy (the daily steps read its first line), so
// appending to it is a change to a tracked file.
const tunnel_file = "tunnel-check.txt"

const tunnel_word = "tunnel-check-passed"

const tunnel_objective = "check the checkout of the untrusted guest"

// The edit prints what it did and what Git there says about it, and ends with
// `true`, so the tool result is a successful one whatever a step reported.
fn tunnel_command() -> String {
  "echo tunnel-edit >> README.md; echo edit_status=$?; "
  <> "echo tunnel-target > "
  <> tunnel_file
  <> "; echo file_status=$?; git status --short 2>&1; true"
}

fn tunnel_check() -> String {
  "test -f " <> tunnel_file <> " && echo " <> tunnel_word <> " $(pwd)"
}

// What the session showed, read while it was live and asserted after it
// stopped: the stored baseline, the worktree board, and the goal board with
// the check's result (or the last board read when no check appeared).
type Observed {
  Observed(
    baseline: option.Option(json.JsonValue),
    board: json.JsonValue,
    goal: Result(json.JsonValue, json.JsonValue),
  )
}

// The three things a session on an untrusted executor gets through the broker
// tunnel, each observed the way the product observes it: the baseline in the
// orchestrator's store, the Changes tab through the session socket's
// `worktree_diff`, and the goal check through `goal_set` and `goal_get`. The
// jailed edit has already run, and the session is idle. The goal is cleared
// before this returns, so the session holds none when it is stopped.
fn tunnel_serves(run: Run, opened: remote_pair.Opened) -> Observed {
  let baseline = tunnel_baseline(run, opened.session)

  let socket = remote_pair.session_socket(opened)
  let board = tunnel_board(socket)

  let socket = tunnel_pin_goal(socket)
  let goal = tunnel_await_check(socket, 900, json.Null)

  // The goal stays active whether or not its check ran, so it is cleared the
  // way a client clears one, and the acknowledgement is read.
  let #(cleared, _socket) =
    remote_pair.session_command(socket, "goal_clear", json.Object([]))
  assert remote_daemons.field(cleared, "event") != json.String("error")
    as { "the goal is cleared, answered " <> json.to_string(cleared) }
  Observed(baseline:, board:, goal:)
}

fn assert_tunnel(observed: Observed) -> Nil {
  assert_tunnel_baseline(observed.baseline)
  assert_tunnel_board(observed.board)
  assert_tunnel_check(observed.goal)
}

// The baseline fact as the orchestrator stored it, read from a copy of its
// store.
fn tunnel_baseline(run: Run, session: String) -> option.Option(json.JsonValue) {
  let pair =
    remote_pair.Pair(
      directory: run.directory,
      orchestrator: run.untrusted,
      executor: run.untrusted,
      checkout: "",
    )
  remote_pair.session_fact(pair, session, session_git.key)
}

// Without the tunnel the probe's answer is refused, so the stored baseline is
// `unavailable` with the refusal's text, and `kind` is not `revision`.
fn assert_tunnel_baseline(baseline: option.Option(json.JsonValue)) -> Nil {
  let assert option.Some(start) = baseline
    as "the orchestrator stored a baseline for the session"
  let shown = json.to_string(start)
  io.println_error(label <> " session baseline: " <> shown)
  assert remote_daemons.field(start, "kind") == json.String("revision")
    as { "the session's baseline is a revision, stored as " <> shown }
  let assert json.String(revision) = remote_daemons.field(start, "value")
    as { "the revision is a string, stored as " <> shown }
  assert string.length(revision) == 40
    as { "the revision is a commit id, stored as " <> shown }
  Nil
}

// The worktree observation answers its command with a pending board and pushes
// the finished one, which is `ready` or `failed`. Both end the wait, so a
// refusal is read as a refusal and not as a timeout.
fn tunnel_board(socket: remote_pair.SessionSocket) -> json.JsonValue {
  let #(acknowledged, socket) =
    remote_pair.session_command(socket, "worktree_diff", json.Object([]))
  let pending =
    remote_daemons.field(remote_daemons.field(acknowledged, "body"), "board")
  assert remote_daemons.field(pending, "status") == json.String("pending")
    as { "the observation is accepted, answered " <> json.to_string(pending) }
  next_final_board(socket, 20)
}

fn next_final_board(
  socket: remote_pair.SessionSocket,
  remaining: Int,
) -> json.JsonValue {
  assert remaining > 0
    as "the worktree board arrives in a bounded run of frames"
  let board = case remote_pair.next_frame(socket) {
    json.Object(fields) ->
      case list.key_find(fields, "body") {
        Ok(json.Object(body)) -> list.key_find(body, "board")
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
  case board {
    Ok(json.Object(fields) as found) ->
      case list.key_find(fields, "status") {
        Ok(json.String("ready")) | Ok(json.String("failed")) -> found
        _ -> next_final_board(socket, remaining - 1)
      }
    _ -> next_final_board(socket, remaining - 1)
  }
}

// Without the tunnel the board is `failed`, with the broker's refusal as its
// message, and lists no entry.
fn assert_tunnel_board(board: json.JsonValue) -> Nil {
  let shown = json.to_string(board)
  io.println_error(label <> " worktree board: " <> shown)
  assert remote_daemons.field(board, "status") == json.String("ready")
    as { "the Changes tab is a ready board, read " <> shown }
  let assert json.Array(entries) = remote_daemons.field(board, "entries")
    as { "the board lists entries, read " <> shown }
  let paths =
    list.filter_map(entries, fn(entry) {
      case remote_daemons.field(entry, "path") {
        json.String(path) -> Ok(path)
        _ -> Error(Nil)
      }
    })
  assert list.contains(paths, "README.md")
    as { "the tracked file the jail edited is listed, read " <> shown }
  assert list.contains(paths, tunnel_file)
    as { "the file the jail created is listed, read " <> shown }
  Nil
}

fn tunnel_pin_goal(
  socket: remote_pair.SessionSocket,
) -> remote_pair.SessionSocket {
  let #(reply, socket) =
    remote_pair.session_command(
      socket,
      "goal_set",
      json.Object([
        #("objective", json.String(tunnel_objective)),
        #("token_budget", json.Int(100_000)),
        #("check", json.String(tunnel_check())),
      ]),
    )
  assert remote_daemons.field(reply, "event") != json.String("error")
    as { "the goal is pinned, answered " <> json.to_string(reply) }
  socket
}

// Reads the goal until it carries a check result, up to `remaining` reads a
// tenth of a second apart. The check runs before any reviewer feed, and a
// pinned goal's feed need not follow within the wait, so the goal's status is
// not waited on. A goal with no result in time answers the last board.
fn tunnel_await_check(
  socket: remote_pair.SessionSocket,
  remaining: Int,
  last: json.JsonValue,
) -> Result(json.JsonValue, json.JsonValue) {
  case remaining > 0 {
    False -> Error(last)
    True -> {
      let #(reply, socket) =
        remote_pair.session_command(socket, "goal_get", json.Object([]))
      let board =
        remote_daemons.field(remote_daemons.field(reply, "body"), "board")
      case remote_daemons.field(board, "last_check") {
        json.Null -> {
          process.sleep(100)
          tunnel_await_check(socket, remaining - 1, board)
        }
        _ -> Ok(board)
      }
    }
  }
}

// Without the tunnel the check is refused: no result appears, or `status` is
// not 0 and `not_finished` names the refusal. The workspace path is the one the
// daily steps assert (`cwd=/srv/workspaces/repo`), built from `workspaces_dir`.
fn assert_tunnel_check(goal: Result(json.JsonValue, json.JsonValue)) -> Nil {
  let assert Ok(board) = goal
    as {
      "the goal records a check result; the last board read was "
      <> case goal {
        Error(last) -> json.to_string(last)
        Ok(_) -> ""
      }
    }
  let shown = json.to_string(board)
  io.println_error(label <> " goal board: " <> shown)
  let ran = remote_daemons.field(board, "last_check")
  assert remote_daemons.field(ran, "command") == json.String(tunnel_check())
    as { "the check that ran is the one pinned, read " <> shown }
  assert remote_daemons.field(ran, "status") == json.Int(0)
    as { "the check passed on the guest, read " <> shown }
  assert remote_daemons.field(ran, "not_finished") == json.Null
    as { "the check settled, read " <> shown }
  let assert json.String(output) = remote_daemons.field(ran, "output")
    as { "the check carries its output, read " <> shown }
  assert string.contains(output, tunnel_word)
    as { "the check's output is the guest's, read " <> shown }
  assert string.contains(
    output,
    workspaces_dir <> "/" <> remote_pair.workspace_name,
  )
    as { "the check ran in the guest's workspace copy, read " <> shown }
  Nil
}

fn hex(bytes: Int) -> String {
  token.production_entropy()(bytes)
  |> bit_array.base16_encode
  |> string.lowercase
}
