//// The microVM executor tier end to end through the product path (issue #85,
//// ADR-022): `loom vm up` boots a standing guest and enrolls it in an
//// orchestrator's configuration, a scripted model drives a real `bash` call in
//// the guest, and `loom vm down` followed by `loom vm up` resumes the same
//// guest.
////
//// ## What it proves
////
//// - `loom vm up` provisions the two-node deployment, installs the
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
//// - An idle daemon is stopped. With a daemon running on the isolated home's
////   own `.loom` and holding no session, `vm up` for a second guest with no
////   `--config` installs into that home's default `loom.toml`, says it stopped
////   the daemon, and the daemon's process is gone. The step runs only when the
////   launcher's home is the fixture's own (`isolated_home`), and skips with a
////   line otherwise.
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
import client/tui_e2e_test.{type EunitTest, Timeout}
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
  // The runner scales EUnit timeouts by ten: 1100 seconds around a body of
  // 900, which clones a guest root and boots a VM twice, starts an
  // orchestrator, and runs two turns.
  Timeout(110, fn() {
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
    )

  let outcomes =
    weft.new([
      fn() {
        drive(run)
        Ok(Nil)
      },
    ])
    |> weft.deadline(900_000)
    |> weft.start

  // Teardown runs outside the body's deadline, so a body that failed midway
  // still stops the guest it started and retires the orchestrator.
  let _stopped = vm(run, ["down", "--name", run.name])
  let _idle_stopped = vm(run, ["down", "--name", run.idle_name])
  let _failing_stopped = vm(run, ["down", "--name", run.failing_name])
  retire_default_daemon(run)
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

  // Last, because it replaces the cookie the assertions above compare with.
  idle_daemon_is_stopped(run)
  failing_script_fails_up(run)
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

fn hex(bytes: Int) -> String {
  token.production_entropy()(bytes)
  |> bit_array.base16_encode
  |> string.lowercase
}
