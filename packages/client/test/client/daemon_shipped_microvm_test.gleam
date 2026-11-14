//// The microVM executor tier end to end through the product path (issue #85,
//// ADR-022): `loom vm up` boots a standing guest and enrolls it in an
//// orchestrator's configuration, a scripted model drives a real `bash` call in
//// the guest, and `loom vm down` followed by `loom vm up` resumes the same
//// guest.
////
//// ## What it proves
////
//// - `loom vm up` provisions the two-node deployment in ledger mode (the
////   installed `[distribution]` table carries `ledger =` and no peer, the guest
////   root holds the ledger beside its credentials), seals the authority key
////   under `<vm home>/authority/<id>` with a passphrase file, and installs the
////   orchestrator's half into a `loom.toml`, clones the guest root, boots
////   `loom-vm run` and reports that the executor serves, with nothing in the
////   fixture standing in for any of those steps.
//// - `sessions.create` with `executor: <name>, workspace: "repo"` settles
////   `resident`, so the orchestrator dialled the guest, passed the pinned
////   handshake both ways, and attached a scope there.
//// - The model's `bash` call runs on the guest's Linux kernel, not the host's
////   (the host is macOS), under `loom-exec` (no-new-privileges is set), and
////   writes into the guest's copy of the checkout.
//// - Model code in the guest cannot read the executor node's own cookie, which
////   ADR-022 D2 rests on: the jail keeps model code out of the node's secrets
////   inside the same guest.
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
////   workspace, `vm logs` prints the console's end, and `vm rm` refuses it
////   naming `vm down`. A commit a jailed call makes on a new `loom/*` branch
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
//// - `vm rm` undoes an enrolment. A second guest in a home that holds another
////   deployment is refused naming `loom vm rm`, and removing it leaves the
////   other deployment's tables and cookie. Without `--yes` a removal lists the
////   workspaces and changes nothing. With it, the
////   idle-daemon step's guest loses its `[executors.<name>]` and
////   `[distribution]` tables but keeps a cookie that is not its own, and the
////   failing-script step's guest, whose cookie is the home's, loses that too.
////   Both run under the fixture's isolated home.
//// - An idle daemon is stopped. With a daemon running on the isolated home's
////   own `.loom` and holding no session, `vm up` for a second guest with no
////   `--config` installs into that home's default `loom.toml`, says it stopped
////   the daemon, and the daemon's process is gone. The step runs only when the
////   launcher's home is the fixture's own (`isolated_home`), and skips with a
////   line otherwise.
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
//// - A guest resumes. After `loom vm down` the guest process is gone and its
////   epmd name is withdrawn; the next `loom vm up` without `--fresh` keeps the
////   root, so the marker written by the first turn is still in the checkout and
////   the state disk is still there, and a new session on the resumed guest reads
////   the marker back.
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
////   the first scripted turn, then `vm down`, `vm up` again and the second turn.
//// - `assert_first_turn`, `assert_never_on_host` and `assert_resumed` hold the
////   assertions.

import broker/token
import client/authority_key
import client/distribution_bundle
import client/tui_e2e_test.{type EunitTest, Timeout}
import client/vm_spec
import core/json
import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
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

// The guest's name. It becomes part of the executor's node name and of the
// epmd entry `loom vm up` publishes in the host's shared epmd, so a suffix
// keeps two runs on one host from sharing it.
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
    /// The name of the second guest the idle-daemon step boots.
    idle_name: String,
    /// The name of the guest whose provisioning script fails.
    failing_name: String,
    /// The name of a third guest, refused while its home's daemon is down.
    third_name: String,
    /// The name of the guest that joins the idle guest's deployment.
    join_name: String,
    /// The name of the guest reached over the untrusted link.
    untrusted_name: String,
    /// The orchestrator that dials that guest, with a configuration of its
    /// own.
    untrusted: remote_daemons.Layout,
  )
}

// A tool result carries every observation of one command, each line labelled.
// The cookie read reports its own status, so a refusal is still a successful
// tool result the script can match. The two `curl` lines run only when the
// operator allows this test to reach GitHub.
fn first_command(reach: Reach) -> String {
  let local =
    "echo \"kernel=$(uname -r)\"; grep -E '^NoNewPrivs:' /proc/self/status; "
    <> "echo placed-in-guest > "
    <> marker
    <> "; cat "
    <> node_dir
    <> "/home/.erlang.cookie; echo cookie_status=$?; "
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
      idle_name: guest_prefix <> hex(3),
      failing_name: guest_prefix <> hex(3),
      third_name: guest_prefix <> hex(3),
      join_name: guest_prefix <> hex(3),
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
  let _idle_stopped = vm(run, ["down", "--name", run.idle_name])
  let _failing_stopped = vm(run, ["down", "--name", run.failing_name])
  let _joined_stopped = vm(run, ["down", "--name", run.join_name])
  let _untrusted_stopped = vm(run, ["down", "--name", run.untrusted_name])
  retire_default_daemon(run)
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
      assert string.contains(
        first_up,
        "serves " <> executor_node(run) <> " on host port",
      )

      // `vm up` wrote `[distribution]` and `[executors.<name>]`; the
      // orchestrator also needs a model, which the scripted provider serves.
      let orchestrator = run.orchestrator
      let assert Ok(installed) = simplifile.read(orchestrator.config)
        as "vm up installed the orchestrator's configuration"
      assert_ledger_deployment(run, installed)
      let assert Ok(Nil) =
        simplifile.write(
          orchestrator.config,
          installed <> "\n" <> remote_daemons.model_table(url),
        )
        as "the model table is appended to the installed configuration"
      remote_daemons.write_options(orchestrator)

      let running = remote_daemons.start(orchestrator)
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
      assert string.contains(status.output, "epmd:       not registered")

      // The guest is stopped, so its root is quiet while it is searched.
      let assert [id] = sealed_keys(run)
      assert_authority_stays_on_host(run, run.name, id)

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

      // Neither flag: the resume keeps the allowed host and skips the script.
      let second_up = up(run, [])
      assert string.contains(
        second_up,
        "serves " <> executor_node(run) <> " on host port",
      )
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

  // Last, because it replaces the cookie the assertions above compare with.
  idle_daemon_is_stopped(run)
  second_guest_joins(run)
  failing_script_fails_up(run)
  guests_are_removed(run)
  untrusted_guest(run)
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
  assert string.contains(
    resumed,
    "serves " <> executor_node(run) <> " on host port",
  )
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
  let listed = expect_ok(vm(run, ["list"]), "loom vm list")
  assert string.contains(
    listed,
    run.name <> "  running  " <> remote_pair.workspace_name,
  )

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

// --- the ledger deployment ---------------------------------------------------

// The deployment directories under `<vm home>/authority`, sorted.
fn sealed_keys(run: Run) -> List(String) {
  case simplifile.read_directory(run.vm_home <> "/authority") {
    Ok(entries) -> list.sort(entries, string.compare)
    Error(_) -> []
  }
}

// `vm up` mints in ledger mode: the table it installed names a ledger and no
// peer, the executor row is still written, and the guest holds the ledger
// beside its credentials, which its configuration names.
fn assert_ledger_deployment(run: Run, installed: String) -> Nil {
  assert string.contains(installed, "[distribution]")
  assert string.contains(installed, "ledger = ")
  assert !string.contains(installed, "[[distribution.peers]]")
  assert string.contains(installed, "[executors." <> run.name <> "]")

  let guest = run.vm_home <> "/" <> run.name
  assert simplifile.is_file(guest <> "/deploy/ledger.log") == Ok(True)
  assert simplifile.is_file(guest <> "/orch/ledger.log") == Ok(True)
  assert simplifile.is_file(guest <> "/root" <> node_dir <> "/creds/ledger.log")
    == Ok(True)
  let configuration = read_file(guest <> "/root" <> node_dir <> "/loom.toml")
  assert string.contains(
    configuration,
    "ledger = \"" <> node_dir <> "/creds/ledger.log\"",
  )
  assert !string.contains(configuration, "[[distribution.peers]]")

  // One key is sealed for the guest, with its passphrase file.
  let assert [id] = sealed_keys(run)
  let directory = run.vm_home <> "/authority/" <> id
  assert simplifile.is_file(directory <> "/key.enc") == Ok(True)
  assert simplifile.is_file(directory <> "/passphrase") == Ok(True)
  Nil
}

// Neither the passphrase nor the authority key reaches a guest root. The root
// is searched for the passphrase's bytes, for a body line of the key (which the
// test opens with the passphrase file) and for the key file's name. The search
// is `grep` and `find` over the files; no Git runs in a guest root.
fn assert_authority_stays_on_host(run: Run, guest: String, id: String) -> Nil {
  let directory = run.vm_home <> "/authority/" <> id
  let root = run.vm_home <> "/" <> guest <> "/root"
  let assert Ok(passphrase) =
    authority_key.passphrase_from_file(directory <> "/passphrase")
    as "the passphrase file is private and readable without a terminal"
  let assert Ok(key) = authority_key.load(directory, id, passphrase)
    as "the passphrase opens the sealed key"
  let text = string.trim(read_file(directory <> "/passphrase"))
  let assert [_, body, ..] = string.split(key, "\n")

  let assert Ok(grep) = ffi_proc.which("grep") as "grep is on PATH"
  list.each([text, body], fn(needle) {
    let assert Ok(#(status, output)) =
      ffi_proc.run(grep, ["-rFla", needle, root], in: run.directory)
      as "grep runs over the guest's root"
    assert output == ""
    assert status == 1
  })

  let assert Ok(find) = ffi_proc.which("find") as "find is on PATH"
  let assert Ok(#(0, found)) =
    ffi_proc.run(find, [root, "-name", "key.enc"], in: run.directory)
    as "find runs over the guest's root"
  assert found == ""
  Nil
}

// --- a second guest joins the deployment ------------------------------------

const node_prompt_idle = "which guest runs this"

const node_answer_idle = "the idle guest"

const node_prompt_join = "which guest runs this one"

const node_answer_join = "the joined guest"

const node_prompt_again = "which guest still runs this"

const node_answer_again = "the idle guest again"

// The executor node line of the configuration inside whichever guest the jailed
// call runs in. The file holds no secret.
fn node_command() -> String {
  "grep -m1 '^node = ' " <> node_dir <> "/loom.toml; true"
}

fn join_exchanges() -> List(provider.Exchange) {
  [
    bash_exchange(node_prompt_idle, "node-idle", node_command()),
    reply_after("node-idle", node_answer_idle),
    bash_exchange(node_prompt_join, "node-join", node_command()),
    reply_after("node-join", node_answer_join),
    bash_exchange(node_prompt_again, "node-again", node_command()),
    reply_after("node-again", node_answer_again),
  ]
}

// One session on `executor`, one scripted turn, and the session stopped again.
fn placed_turn(
  running: remote_daemons.Running,
  control: remote_daemons.Control,
  id: Int,
  executor: String,
  key: String,
  prompt: String,
  answer: String,
) -> String {
  let #(session, settled) =
    remote_daemons.create_and_settle(
      control,
      id,
      key,
      executor,
      remote_pair.workspace_name,
    )
  assert remote_daemons.settled_state(settled) == "resident"
  remote_pair.converse_for(
    remote_pair.Opened(orchestrator: running, control:, session:),
    prompt,
    [answer],
  )
  remote_daemons.stop_session(running, control, id + 100, session)
  session
}

// The idle step's guest has a ledger deployment in the isolated home's default
// configuration. A second guest joins it. The refusals come first, while the
// daemon is down: its absence, a static configuration and a key that is not on
// this machine each leave nothing behind. Then the daemon runs, the idle guest
// resumes, and `up` for a second guest enrols it through the daemon: the
// configuration does not change by a byte, the daemon derives the executor row
// without a restart, a session is placed on each guest and runs in its own,
// `rm` revokes the second guest, and the first still works.
fn second_guest_joins(run: Run) -> Nil {
  case isolated_home(run) {
    Error(reason) -> io.println_error("SKIP " <> label <> " join: " <> reason)
    Ok(home) -> {
      let config = home <> "/.loom/loom.toml"
      let guest = fn(name) { run.vm_home <> "/" <> name }
      let flags = [
        "--name",
        run.join_name,
        "--workspace",
        run.repository,
        "--github",
        "off",
        "--mem",
        "1024",
        "--cpus",
        "2",
      ]
      let before = read_file(config)
      let keys = sealed_keys(run)

      // The daemon of the configuration is not running.
      let down = vm(run, ["up", ..flags])
      assert down.status != 0
      assert string.contains(down.output, "is not running")
      assert string.contains(down.output, "loom deployment status")
      assert read_file(config) == before
      assert simplifile.is_directory(guest(run.join_name)) == Ok(False)
      assert sealed_keys(run) == keys

      // A static deployment has no key to enrol with.
      let static_config = run.directory <> "/static.toml"
      let static_text =
        "[distribution]\nnode = \"static@127.0.0.1\"\nca = \"/x/ca.pem\"\n"
        <> "certificate = \"/x/cert.pem\"\nkey = \"/x/key.pem\"\n"
        <> "cookie = \"/x/cookie\"\n\n[[distribution.peers]]\n"
        <> "node = \"peer@127.0.0.1\"\nsha256 = \""
        <> string.repeat("ab", 32)
        <> "\"\n"
      let assert Ok(Nil) = simplifile.write(static_config, static_text)
      let static_refused =
        vm(run, ["up", ..list.append(flags, ["--config", static_config])])
      assert static_refused.status != 0
      assert string.contains(static_refused.output, "static deployment")
      assert string.contains(static_refused.output, "ledger mode")
      assert read_file(static_config) == static_text
      assert simplifile.is_directory(guest(run.join_name)) == Ok(False)

      // A key that is not on this machine is named by its deployment, with the
      // command for the operator who holds it.
      let away = run.directory <> "/authority-away"
      let assert Ok(Nil) = simplifile.rename(run.vm_home <> "/authority", away)
      let missing = vm(run, ["up", ..flags])
      let assert Ok(Nil) = simplifile.rename(away, run.vm_home <> "/authority")
      assert missing.status != 0
      assert string.contains(missing.output, "loom distribution enroll")
      assert list.any(keys, fn(id) { string.contains(missing.output, id) })
      assert simplifile.is_directory(guest(run.join_name)) == Ok(False)
      assert read_file(config) == before

      // The happy path. The model table points at the scripted provider before
      // the daemon starts, and the idle guest resumes with its own flags.
      let #(Nil, report) =
        provider.with_server_for(
          join_exchanges(),
          provider.OnlySuccessful,
          600_000,
          fn(url) {
            // The idle step's configuration already has a model table, which
            // pointed at a port nobody serves; it now points at the provider.
            let assert Ok(Nil) =
              simplifile.write(
                config,
                string.replace(before, "http://127.0.0.1:9", url),
              )
            let resumed =
              expect_ok(
                vm(run, [
                  "up",
                  "--name",
                  run.idle_name,
                  "--workspace",
                  run.repository,
                  "--github",
                  "off",
                  "--mem",
                  "1024",
                  "--cpus",
                  "2",
                ]),
                "loom vm up resumes the idle guest",
              )
            assert string.contains(resumed, "serves")

            let layout =
              remote_daemons.Layout(
                ..run.orchestrator,
                label: "join",
                paths: default_paths(home),
                config:,
                options: run.directory <> "/join.options",
              )
            remote_daemons.write_options(layout)
            let running = remote_daemons.start(layout)
            let control = remote_daemons.open_control(running)
            let _idle_session =
              placed_turn(
                running,
                control,
                1,
                run.idle_name,
                "join-idle",
                node_prompt_idle,
                node_answer_idle,
              )

            // The join: the file is byte for byte what it was, the daemon is
            // not stopped, and the row is derived.
            let configured = read_file(config)
            let joined = expect_ok(vm(run, ["up", ..flags]), "loom vm up joins")
            io.println_error(label <> " vm up (join):\n" <> joined)
            assert read_file(config) == configured
            assert string.contains(joined, "derives [executors.")
            assert !string.contains(joined, "Your daemon")
            assert !string.contains(joined, "so it was stopped")
            assert !string.contains(joined, "must restart")
            assert !string.contains(configured, "executors." <> run.join_name)
            let assert endpoint.Ready(fence:, ..) = running.connected.record
              as "the daemon published its endpoint"
            let assert Ok(True) = endpoint.is_present(fence)
              as "the daemon still runs after the join"

            // The joined guest's bundle holds its own key, the CA and the
            // cookie, and nothing of the authority.
            let bundle =
              read_file(
                guest(run.join_name)
                <> "/deploy/"
                <> run.join_name
                <> ".loombundle",
              )
            let directory = authority_dir_of(run)
            let assert Ok(passphrase) =
              authority_key.passphrase_from_file(directory <> "/passphrase")
            let id = case list.last(string.split(directory, "/")) {
              Ok(segment) -> segment
              Error(Nil) -> ""
            }
            let assert Ok(key) = authority_key.load(directory, id, passphrase)
            assert !string.contains(bundle, string.trim(key))
            assert !string.contains(
              bundle,
              string.trim(read_file(directory <> "/passphrase")),
            )
            assert simplifile.is_directory(guest(run.join_name) <> "/orch")
              == Ok(False)
            assert sealed_keys(run) == keys

            // Both members are in the deployment's status.
            let status =
              remote_daemons.command(
                control,
                20,
                "deployment.status",
                json.Object([]),
              )
            let shown = string.inspect(status)
            assert string.contains(shown, run.idle_name)
            assert string.contains(shown, run.join_name)

            // A session on the new guest, with no restart, and one on the old.
            let join_session =
              placed_turn(
                running,
                control,
                30,
                run.join_name,
                "join-new",
                node_prompt_join,
                node_answer_join,
              )
            assert_authority_stays_on_host(run, run.join_name, id)

            // Removing it revokes it with the key, and the first still works.
            let stopped = vm(run, ["down", "--name", run.join_name])
            assert string.contains(stopped.output, "Stopped the guest")
            let refused = vm(run, ["rm", "--name", run.join_name])
            assert refused.status != 0
            assert string.contains(refused.output, "revokes")

            // A session saved on the guest still counts as placed on it, so the
            // revoke is refused, nothing is signed and nothing is removed.
            let blocked = vm(run, ["rm", "--name", run.join_name, "--yes"])
            assert blocked.status != 0
            assert string.contains(blocked.output, "may strand sessions")
            assert string.contains(blocked.output, "Nothing was signed")
            assert simplifile.is_directory(guest(run.join_name)) == Ok(True)

            // Deleting the session releases it.
            let deleted =
              remote_daemons.command(
                control,
                60,
                "sessions.delete",
                json.Object([
                  #("session_id", json.String(join_session)),
                  #("epoch", json.String(control.epoch)),
                ]),
              )
            assert remote_daemons.field(deleted, "event")
              == json.String("sessions.delete")
            let removed =
              expect_ok(
                vm(run, ["rm", "--name", run.join_name, "--yes"]),
                "loom vm rm of the joined guest",
              )
            io.println_error(label <> " vm rm (joined):\n" <> removed)
            assert string.contains(removed, "Revoked " <> run.join_name)
            assert simplifile.is_directory(guest(run.join_name)) == Ok(False)
            assert read_file(config) == configured
            assert sealed_keys(run) == keys
            let _again_session =
              placed_turn(
                running,
                control,
                50,
                run.idle_name,
                "join-again",
                node_prompt_again,
                node_answer_again,
              )
            let after =
              string.inspect(remote_daemons.command(
                control,
                70,
                "deployment.status",
                json.Object([]),
              ))
            assert !string.contains(after, run.join_name)
            remote_pair.close_daemons([running])
            // Closing the connection leaves the daemon; the refusals that follow
            // need it gone.
            remote_daemons.retire(layout.paths)
            let idle_down = vm(run, ["down", "--name", run.idle_name])
            assert string.contains(idle_down.output, "Stopped the guest")
            Nil
          },
        )
      let assert Ok(requests) = report as "the three scripted turns completed"
      let idle_node = "loom_vm_" <> run.idle_name <> "_exec"
      let join_node = "loom_vm_" <> run.join_name <> "_exec"
      let on_idle = remote_daemons.result_text(requests, "node-idle")
      let on_join = remote_daemons.result_text(requests, "node-join")
      let on_again = remote_daemons.result_text(requests, "node-again")
      assert string.contains(on_idle, idle_node)
      assert !string.contains(on_idle, join_node)
      assert string.contains(on_join, join_node)
      assert !string.contains(on_join, idle_node)
      assert string.contains(on_again, idle_node)
      Nil
    }
  }
}

// The authority directory of the idle guest's deployment, found from the id its
// own bundle's ledger carries.
fn authority_dir_of(run: Run) -> String {
  let text =
    read_file(
      run.vm_home
      <> "/"
      <> run.idle_name
      <> "/deploy/"
      <> run.idle_name
      <> ".loombundle",
    )
  let assert Ok(bundle) = distribution_bundle.decode(text)
    as "the idle guest's bundle decodes"
  let assert Ok(id) = vm_spec.bundle_deployment(bundle)
    as "the idle guest's bundle carries a ledger"
  run.vm_home <> "/authority/" <> id
}

// --- removing guests ---------------------------------------------------------

fn read_file(path: String) -> String {
  let assert Ok(text) = simplifile.read(path) as { path <> " is readable" }
  text
}

// Under the isolated home, a third guest is refused because the home holds
// another deployment, and removing it leaves that deployment alone. Then the
// idle-daemon step's guest is removed after a refusal that lists its branches,
// keeping a cookie that is not its own, and the failing-script step's guest is
// removed with its cookie. Every file named is inside the fixture.
fn guests_are_removed(run: Run) -> Nil {
  case isolated_home(run) {
    Error(reason) ->
      io.println_error("SKIP " <> label <> " removal: " <> reason)
    Ok(home) -> {
      let config = home <> "/.loom/loom.toml"
      let fail_config = run.directory <> "/fail.toml"
      let cookie = home <> "/.erlang.cookie"
      let guest = fn(name) { run.vm_home <> "/" <> name }

      let listed = expect_ok(vm(run, ["list"]), "loom vm list")
      assert string.contains(listed, run.idle_name <> "  stopped")
      assert string.contains(listed, run.failing_name <> "  stopped")

      // The home holds the idle guest's ledger deployment and its daemon is
      // down, so a third guest, which would be enrolled through that daemon, is
      // refused before anything is minted or written, with the command that
      // starts it.
      let config_before = read_file(config)
      let cookie_before = read_file(cookie)
      let sealed_before = sealed_keys(run)
      let third =
        vm(run, [
          "up",
          "--name",
          run.third_name,
          "--workspace",
          run.repository,
          "--github",
          "off",
        ])
      io.println_error(label <> " third up:\n" <> third.output)
      assert third.status != 0
      assert string.contains(third.output, "is not running")
      assert string.contains(third.output, "loom deployment status")
      assert read_file(config) == config_before
      assert read_file(cookie) == cookie_before
      assert simplifile.is_directory(guest(run.third_name)) == Ok(False)
      assert sealed_keys(run) == sealed_before

      // Without `--yes` the idle guest's removal lists what it would lose and
      // changes nothing.
      let refusal = vm(run, ["rm", "--name", run.idle_name])
      assert refusal.status != 0
      assert string.contains(refusal.output, "Deleting the guest")
      assert string.contains(refusal.output, "It holds:\n  repo\n")
      assert string.contains(refusal.output, "--yes")
      assert simplifile.is_directory(guest(run.idle_name)) == Ok(True)
      assert read_file(config) == config_before

      // With it, the tables go and the cookie, which is the failing guest's,
      // stays.
      let removed =
        expect_ok(vm(run, ["rm", "--name", run.idle_name, "--yes"]), "rm idle")
      io.println_error(label <> " vm rm:\n" <> removed)
      assert simplifile.is_directory(guest(run.idle_name)) == Ok(False)
      let after = read_file(config)
      assert !string.contains(after, "[distribution")
      assert !string.contains(after, "[executors.")
      assert string.contains(after, "[models.")
      assert string.contains(
        removed,
        "Removed [executors." <> run.idle_name <> "]",
      )
      assert string.contains(
        removed,
        "Left in place: the home's .erlang.cookie",
      )
      assert read_file(cookie) == cookie_before

      // The failing guest's tables are in its own file and its cookie is the
      // home's, so all of it goes.
      let removed_failing =
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
      assert simplifile.is_directory(guest(run.failing_name)) == Ok(False)
      let emptied = read_file(fail_config)
      assert !string.contains(emptied, "[distribution")
      assert !string.contains(emptied, "[executors.")
      assert string.contains(removed_failing, cookie)
      assert simplifile.is_file(cookie) == Ok(False)

      // Neither guest is listed any more.
      let remaining = expect_ok(vm(run, ["list"]), "loom vm list")
      assert !string.contains(remaining, run.idle_name)
      assert !string.contains(remaining, run.failing_name)
      Nil
    }
  }
}

// --- an idle daemon ----------------------------------------------------------

// The isolated home the shipped launcher exports, if the step may act in it.
// `HOME` is the launcher script's own variable, so the daemon, `vm up` and the
// cookie all live under this directory and never under the developer's real
// `~/.loom` or `~/.erlang.cookie`. The directory must be one the fixture
// made under `build/shipped-home-`, and must not be the process's own `HOME`.
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
// `vm up` looks for the user's daemon.
fn default_paths(home: String) -> endpoint.Paths {
  let assert Ok(paths) = endpoint.paths(home <> "/.loom")
    as "the isolated home's default state directory is private"
  paths
}

// Starts an idle daemon on the isolated home's `.loom` and runs `vm up` for a
// second guest with no `--config`. `up` finds the daemon through the endpoint
// record, sees it holds no session, stops it and says so.
fn idle_daemon_is_stopped(run: Run) -> Nil {
  case isolated_home(run) {
    Error(reason) ->
      io.println_error("SKIP " <> label <> " idle daemon: " <> reason)
    Ok(home) -> {
      let paths = default_paths(home)
      let config = home <> "/.loom/loom.toml"
      let assert Ok(Nil) =
        simplifile.write(
          config,
          remote_daemons.model_table("http://127.0.0.1:9"),
        )
        as "the idle daemon has a configuration with a model it never calls"

      // The first part of the test installed its deployment's cookie in this
      // home. A second deployment mints its own cookie, which the installer
      // refuses to put beside a different one, so the fixture's own file is
      // removed first; it is inside the isolated home asserted above.
      let assert Ok(Nil) = simplifile.delete(home <> "/.erlang.cookie")
        as "the first deployment's cookie is removed from the isolated home"

      let layout =
        remote_daemons.Layout(
          ..run.orchestrator,
          label: "idle",
          paths:,
          config:,
        )
      let idle = remote_daemons.start_plain(layout)
      let assert endpoint.Ready(fence:, ..) = idle.connected.record
        as "the idle daemon published its endpoint"
      let assert Ok(True) = endpoint.is_present(fence)
        as "the idle daemon runs before vm up"
      assert paths.root == idle.connected.paths.root

      let output =
        expect_ok(
          vm(run, [
            "up",
            "--name",
            run.idle_name,
            "--workspace",
            run.repository,
            "--github",
            "off",
            "--mem",
            "1024",
            "--cpus",
            "2",
          ]),
          "loom vm up for the second guest",
        )
      io.println_error(label <> " idle daemon vm up:\n" <> output)
      remote_pair.close_daemons([idle])

      assert string.contains(output, "so it was stopped")
      let assert poll.Answered(Nil) =
        poll.until(within: 30_000, every: 100, attempt: fn() {
          case endpoint.is_present(fence) {
            Ok(False) -> poll.Done(Nil)
            Ok(True) -> poll.Retry
            Error(reason) -> poll.Fail(reason)
          }
        })
        as "the daemon's process is gone after vm up"

      let down = vm(run, ["down", "--name", run.idle_name])
      assert string.contains(down.output, "Stopped the guest " <> run.idle_name)
      Nil
    }
  }
}

// A script that exits 3 fails `up`: the refusal names the console line and
// carries the script's own output, the guest root holds the script and no
// marker, and no guest is left running. The deployment goes into a scratch
// `loom.toml`, and the cookie the idle step installed is removed first, for
// the reason that step gives; both are inside the isolated home.
fn failing_script_fails_up(run: Run) -> Nil {
  case isolated_home(run) {
    Error(reason) ->
      io.println_error("SKIP " <> label <> " failing script: " <> reason)
    Ok(home) -> {
      let assert Ok(Nil) = simplifile.delete(home <> "/.erlang.cookie")
        as "the idle deployment's cookie is removed from the isolated home"
      let script = run.directory <> "/fail.sh"
      let assert Ok(Nil) =
        simplifile.write(
          script,
          "#!/bin/sh\necho failing-script-output\nexit 3\n",
        )
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
      assert outcome.status != 0
      assert string.contains(outcome.output, "LOOM-PROVISION-FAILED status=3")
      assert string.contains(outcome.output, "failing-script-output")

      // The script is staged and the marker is not, so the next `up` retries.
      let root = run.vm_home <> "/" <> run.failing_name <> "/root/etc/loom-vm"
      assert simplifile.is_file(root <> "/provision") == Ok(True)
      assert simplifile.is_file(root <> "/provisioned") == Ok(False)

      // `up` stopped the guest it started: nothing runs and no pid is kept.
      let status = vm(run, ["status", "--name", run.failing_name])
      assert string.contains(status.output, "process:    not running")
      assert string.contains(status.output, "provision:  pending")
      assert simplifile.is_file(
          run.vm_home <> "/" <> run.failing_name <> "/loom-vm.pid",
        )
        == Ok(False)
      Nil
    }
  }
}

// Retires a daemon the idle-daemon step left on the isolated home, by the pid
// and birth marker its own endpoint record holds.
fn retire_default_daemon(run: Run) -> Nil {
  case isolated_home(run) {
    Error(_) -> Nil
    Ok(home) -> remote_daemons.retire(default_paths(home))
  }
}

fn executor_node(run: Run) -> String {
  "loom_vm_" <> run.name <> "_exec@127.0.0.1"
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

  let output =
    expect_ok(
      vm_launcher(run, [
        "setup",
        "--from-build",
        build,
        "--lib-dir",
        run.artifacts.lib_dir,
      ]),
      "loom-vm setup --from-build",
    )
  io.println_error(label <> " manifest:\n" <> output)
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
// launcher script gives it the orchestrator's isolated home, which is where
// `up` installs the cookie the orchestrator reads.
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

  // The node's cookie stays out of model code's reach inside the guest. The
  // orchestrator's installed cookie is the deployment's, so it is the value
  // the guest's own cookie file holds.
  let assert Ok(cookie) =
    simplifile.read(run.orchestrator.home <> "/.erlang.cookie")
    as "vm up installed the deployment's cookie"
  let cookie = string.trim(cookie)
  assert cookie != ""

  // The cookie must be where the bash call looked, or its absence from the
  // result would prove nothing: the host can read the guest root directly.
  let assert Ok(staged) =
    simplifile.read(
      run.vm_home
      <> "/"
      <> run.name
      <> "/root/srv/loom-node/home/.erlang.cookie",
    )
    as "the guest's cookie is at the path the bash call read"
  assert string.trim(staged) == cookie

  // The property is that the value never reaches the model. The read's exit
  // status is not asserted: a masked file on Linux is bound to /dev/null,
  // which `cat` reads successfully as empty.
  assert !string.contains(result, cookie)

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
  <> "echo \"home_entries=$(ls -A "
  <> node_dir
  <> "/home | tr '\\n' ' ')\"; true"
}

// A second guest, reached over the untrusted link (protocol-change/109) and not
// as a distribution peer, in a configuration of its own. `up --link untrusted`
// writes the link tables beside the model table the step gave the file, an
// orchestrator started on that file serves a session on the guest, and a jailed
// call settles on the guest's kernel. What the guest holds is the point: no
// cookie anywhere in its root, no `[distribution]` table in its configuration,
// no node in the host's epmd, and a jailed read of the executor's key that
// returns nothing. The step ends with the daily verbs of such a guest: a resume
// that changes nothing, a refusal to change its link, and a removal that takes
// the tables and the credentials with it.
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
    bash_exchange(untrusted_prompt, "untrusted-call", untrusted_command()),
    reply_after("untrusted-call", untrusted_answer),
  ]
  let #(key, report) =
    provider.with_server_for(
      exchanges,
      provider.OnlySuccessful,
      600_000,
      fn(url) {
        // The file starts with only the model table a daemon needs, which is
        // what a developer's own file would hold.
        let assert Ok(Nil) =
          simplifile.write(layout.config, remote_daemons.model_table(url))
          as "the orchestrator's configuration is written"
        let model = read_file(layout.config)

        let output =
          expect_ok(
            vm(run, ["up", "--link", "untrusted", ..flags]),
            "loom vm up --link untrusted",
          )
        io.println_error(label <> " vm up (untrusted):\n" <> output)
        let guest = run.vm_home <> "/" <> name
        let port = untrusted_port(guest)
        assert string.contains(
          output,
          "serves its executor over the untrusted link at 127.0.0.1:" <> port,
        )
        assert_untrusted_files(run, guest, port, model)

        // An orchestrator started on that file reads the rows and dials the
        // guest, with no distribution options file and no cookie.
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

        // The daemon's deployment read lists the untrusted row by name, which
        // is how `ensure` tells that a daemon has read the row.
        let shown =
          string.inspect(remote_daemons.command(
            control,
            20,
            "deployment.status",
            json.Object([]),
          ))
        io.println_error(label <> " deployment.status (untrusted):\n" <> shown)
        assert string.contains(shown, name)

        remote_pair.converse_for(
          remote_pair.Opened(orchestrator: running, control:, session:),
          untrusted_prompt,
          [untrusted_answer],
        )
        remote_daemons.stop_session(running, control, 100, session)
        remote_pair.close_daemons([running])
        remote_daemons.retire(layout.paths)

        // The key is read now, because the removal below deletes the root.
        let key = read_file(guest <> "/root" <> node_dir <> "/creds/key.pem")
        untrusted_daily_verbs(run, guest, port, flags)
        key
      },
    )

  let assert Ok(requests) = report
    as "the scripted turn on the untrusted guest completed"
  let result = remote_daemons.result_text(requests, "untrusted-call")
  io.println_error(label <> " untrusted tool result:\n" <> result)
  assert_untrusted_turn(key, result)
}

// The host port the guest's row names, as `link-port` records it.
fn untrusted_port(guest: String) -> String {
  string.trim(read_file(guest <> "/link-port"))
}

// What `up --link untrusted` leaves, read from the host. The guest's root is
// untrusted input, but these files are the ones `up` staged before the boot,
// and a guest that never held a cookie has none to write.
fn assert_untrusted_files(
  run: Run,
  guest: String,
  port: String,
  model: String,
) -> Nil {
  let root = guest <> "/root"
  let config = read_file(run.untrusted.config)
  let name = run.untrusted_name

  // The host's file gained the two tables beside the model table, and no
  // deployment: nothing here was provisioned, joined or sealed.
  assert string.starts_with(config, string.trim_end(model))
  assert string.contains(config, "[executor_link]")
  assert string.contains(config, "[executors." <> name <> "]")
  assert string.contains(config, "trust = \"untrusted\"")
  assert string.contains(config, "address = \"127.0.0.1:" <> port <> "\"")
  assert !string.contains(config, "[distribution]")
  assert simplifile.is_directory(guest <> "/deploy") == Ok(False)

  // The guest's configuration has the listener and no `[distribution]`, and
  // admits the one pin of the orchestrator's leaf.
  let staged = read_file(root <> node_dir <> "/loom.toml")
  assert string.contains(staged, "[executor_listener]")
  assert string.contains(staged, "listen = \"0.0.0.0:4370\"")
  assert !string.contains(staged, "[distribution]")
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

  // The key the executor presents was read from the host's copy of the guest's
  // root, so its absence from the result says the mask held and not that the
  // file was missing. The certificate beside it is public and was read.
  let assert [_header, body, ..] = string.split(key, "\n")
  assert body != ""
  assert !string.contains(result, body)
  assert !string.contains(result, "PRIVATE KEY")
  assert string.contains(result, "-----BEGIN CERTIFICATE-----")

  // Nothing in the node's home is a cookie. The line is printed whole, so a
  // file the daemon made there would be named in it.
  assert string.contains(result, "home_entries=")
  assert !string.contains(result, "erlang.cookie")
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

  // A guest keeps its link for life: the other one is refused, naming the way
  // out, and nothing changes.
  let before = read_file(config)
  let refused =
    vm(run, ["up", "--link", "distribution", "--name", name, "--config", config])
  assert refused.status != 0
  assert string.contains(refused.output, "--fresh")
  assert string.contains(refused.output, "loom vm rm --name " <> name)
  assert read_file(config) == before
  assert untrusted_port(guest) == port

  // A resume needs no `--link`, boots the same port, and changes no file of
  // the host's: the daemon has nothing new to read.
  let resumed =
    expect_ok(
      vm(run, ["up", ..flags]),
      "loom vm up resumes the untrusted guest",
    )
  io.println_error(label <> " vm up (untrusted resume):\n" <> resumed)
  assert string.contains(resumed, "already as this guest needs it")
  assert !string.contains(resumed, "Your daemon")
  assert !string.contains(resumed, "must restart")
  assert string.contains(
    resumed,
    "serves its executor over the untrusted link at 127.0.0.1:" <> port,
  )
  assert read_file(config) == before
  assert untrusted_port(guest) == port
  let stopped = vm(run, ["down", "--name", name])
  assert string.contains(stopped.output, "Stopped the guest " <> name)

  // `rm` lists what it would remove and changes nothing without `--yes`, then
  // removes the row, the link table and the credentials, since this is the
  // last untrusted guest, and there is nothing to revoke.
  let listing = vm(run, ["rm", "--name", name, "--config", config])
  assert listing.status != 0
  assert string.contains(listing.output, "[executors." <> name <> "]")
  assert string.contains(listing.output, "[executor_link]")
  assert read_file(config) == before
  let removed =
    expect_ok(
      vm(run, ["rm", "--name", name, "--config", config, "--yes"]),
      "loom vm rm of the untrusted guest",
    )
  io.println_error(label <> " vm rm (untrusted):\n" <> removed)
  let after = read_file(config)
  assert !string.contains(after, "[executors." <> name <> "]")
  assert !string.contains(after, "[executor_link]")
  assert string.contains(after, "[models.fixture]")
  assert simplifile.is_directory(guest) == Ok(False)
  assert simplifile.is_directory(run.vm_home <> "/link") == Ok(False)
  Nil
}

fn hex(bytes: Int) -> String {
  token.production_entropy()(bytes)
  |> bit_array.base16_encode
  |> string.lowercase
}
