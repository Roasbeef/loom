//// The microVM executor tier end to end (issue #85, ADR-022): an orchestrator
//// on the host and an executor daemon inside a libkrun guest, joined by TLS
//// distribution, with a scripted model driving a real `bash` call.
////
//// ## What it proves
////
//// - The guest executor boots from a copied root and registers as a TLS
////   distribution member; `loom-vm run --publish` makes its unchanged node
////   name resolvable from the host.
//// - `sessions.create` with `executor: "box", workspace: "repo"` settles
////   `resident`, so the orchestrator dialled the guest, passed the pinned
////   handshake both ways, and attached a scope there.
//// - The model's `bash` call runs on the guest's Linux kernel, not the host's
////   (the host is macOS), under `loom-exec` (no-new-privileges is set), and
////   writes into the guest's copy of the checkout, which the host can read
////   only through the root directory it staged.
//// - Model code in the guest cannot read the executor node's own cookie,
////   which ADR-022 D2 rests on: the jail keeps model code out of the node's
////   secrets inside the same guest.
////
//// ## Running it
////
//// ```sh
//// make server-shipment sandbox vmm vmm-runner vmm-firmware vmm-guest-root
//// install -m 0755 packages/sandbox/loom-exec bin/loom-exec
//// export LOOM_BOOTSTRAP_E2E_SERVER=$PWD/bin/loomd
//// export LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key
//// export LOOM_VM=$PWD/packages/vmm/build/loom-vm
//// export LOOM_VM_RUNNER=$PWD/packages/vmm/build/go-microvm-runner
//// export LOOM_VM_LIB_DIR=/opt/homebrew/lib
//// export LOOM_VM_FIRMWARE_DIR=$PWD/packages/vmm/build/firmware
//// export LOOM_VM_GUEST_ROOT=$PWD/packages/vmm/build/guest-root
//// bash scripts/test.sh client --match 'client@daemon_shipped_microvm_test:'
//// ```
////
//// Without those variables, or on a host whose `loom-vm probe` fails, the
//// test prints a skip line and passes.

import broker/token
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/json
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import host/bootstrap as native
import simplifile
import support/microvm_executor
import support/provider_http as provider
import support/remote_daemons.{Trust}
import support/remote_pair
import weft

const label = "shipped microvm executor"

const prompt = "run it in the guest"

const answer = "ran in the guest"

const note = "note.txt"

// One command, so one tool result carries every observation. Each line is
// labelled, and the cookie read reports its own status, so a refusal is
// still a successful tool result the script can match.
fn command() -> String {
  "uname -sr; grep -E '^NoNewPrivs:' /proc/self/status; "
  <> "echo placed-in-guest > "
  <> note
  <> "; cat "
  <> microvm_executor.node_dir
  <> "/home/.erlang.cookie; echo cookie_status=$?"
}

/// Boots an orchestrator on the host and an executor in a microVM and runs
/// one scripted `bash` call through a registered session.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_microvm_test:'`.
pub fn daemon_shipped_microvm_test_() -> EunitTest {
  // The runner scales EUnit timeouts by ten: 600 seconds around a body of
  // 540, which copies a guest root, boots a VM and two daemons, and runs a
  // turn.
  Timeout(60, fn() {
    case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
      Error(Nil) ->
        io.println_error(
          "SKIP " <> label <> ": LOOM_BOOTSTRAP_E2E_SERVER is unset",
        )

      Ok(_server) ->
        case microvm_executor.prerequisites() {
          Error(reason) -> io.println_error("SKIP " <> label <> ": " <> reason)
          Ok(prerequisites) -> fixture(prerequisites)
        }
    }
  })
}

fn fixture(prerequisites: microvm_executor.Prerequisites) -> Nil {
  let directory = "/var/tmp/loom-vm-" <> hex(4)
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the fixture's state stays private"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the daemons receive absolute paths"
  io.println_error(label <> " fixture: " <> directory)

  let orchestrator = remote_daemons.layout(directory, "orchestrator")
  let guests = weft_cell()
  let outcomes =
    weft.new([
      fn() {
        drive(prerequisites, directory, orchestrator, guests)
        Ok(Nil)
      },
    ])
    |> weft.deadline(540_000)
    |> weft.start

  // Teardown runs outside the body's deadline, so a body that failed midway
  // still retires the orchestrator and the guest it started.
  remote_daemons.retire(orchestrator.paths)
  list.each(read_cell(guests), microvm_executor.retire)
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the microvm body completes before native teardown"
  let _removed = simplifile.delete_all([directory])
  Nil
}

fn drive(
  prerequisites: microvm_executor.Prerequisites,
  directory: String,
  orchestrator: remote_daemons.Layout,
  guests: Cell,
) -> Nil {
  // Credentials: one authority, a leaf per node, one cookie. The executor's
  // home is a host staging directory; its files are copied into the guest.
  let secrets = directory <> "/credentials"
  let assert Ok(Nil) = native.ensure_private_directory(secrets)
    as "the credentials directory is private"
  let executor_home = directory <> "/executor-home"
  let assert Ok(Nil) = native.ensure_private_directory(executor_home)
    as "the executor's staging home is private"
  let authority = remote_daemons.mint_authority(secrets)
  let suffix = hex(4)
  let orchestrator_identity =
    remote_daemons.issue(
      authority,
      secrets,
      "orchestrator",
      "loom_e2e_vmorch_" <> suffix <> "@127.0.0.1",
      orchestrator.home,
    )
  let executor_identity =
    remote_daemons.issue(
      authority,
      secrets,
      "executor",
      "loom_e2e_vmexec_" <> suffix <> "@127.0.0.1",
      executor_home,
    )
  let cookie = "loom-e2e-cookie-" <> hex(16)
  remote_daemons.write_cookie(orchestrator_identity, cookie)
  remote_daemons.write_cookie(executor_identity, cookie)

  let root =
    microvm_executor.stage(
      prerequisites,
      directory,
      authority,
      executor_identity,
      orchestrator_identity,
      remote_pair.workspace_name,
      [#("README.md", "the guest's copy of the checkout\n")],
    )

  let script = [
    provider.ToolUseExchange(
      prompt,
      "guest-call",
      "bash",
      json.Object([#("command", json.String(command()))]),
    ),
    provider.ComputedExchange(provider.AwaitToolResult("guest-call"), fn(_seen) {
      provider.ReplyText(answer)
    }),
  ]

  let #(Nil, report) =
    provider.with_server_for(script, provider.OnlySuccessful, 480_000, fn(url) {
      let assert Ok(Nil) =
        simplifile.write(
          orchestrator.config,
          string.join(
            [
              remote_daemons.model_table(url),
              remote_daemons.distribution_table(
                orchestrator_identity,
                authority,
                [Trust(executor_identity.node, executor_identity.pin)],
              ),
              remote_daemons.executor_table(
                remote_pair.executor_name,
                executor_identity.node,
              ),
            ],
            "\n",
          ),
        )
        as "the orchestrator configuration is written"
      remote_daemons.write_options(orchestrator)

      let guest =
        microvm_executor.boot(
          prerequisites,
          directory,
          root,
          executor_identity.node,
          41_000 + int.random(8000),
        )
      write_cell(guests, guest)

      let running = remote_daemons.start(orchestrator)
      let control = remote_daemons.open_control(running)
      let #(session, settled) =
        remote_daemons.create_and_settle(
          control,
          1,
          "e2e-microvm",
          remote_pair.executor_name,
          remote_pair.workspace_name,
        )
      assert remote_daemons.settled_state(settled) == "resident"

      let opened = remote_pair.Opened(orchestrator: running, control:, session:)
      remote_pair.converse_for(opened, prompt, [answer])
      remote_daemons.stop_session(running, control, 100, session)
      remote_pair.close_daemons([running])
    })

  let assert Ok(requests) = report
    as "the scripted turn completed with a successful tool result"
  let result = remote_daemons.result_text(requests, "guest-call")
  io.println_error(label <> " tool result:\n" <> result)

  // No-new-privileges is set by loom-exec's stage 2 for every jailed call.
  assert string.contains(result, "NoNewPrivs:\t1")

  // The tier's own kernel (ADR-022 D3) names itself in the release, which no
  // host kernel does, so this proves both that the call ran in the guest and
  // that it ran where the broker's landlock demand holds.
  assert string.contains(result, "-loom-landlock")

  // The node's cookie stays out of model code's reach inside the guest.
  assert !string.contains(result, cookie)
  assert !string.contains(result, "cookie_status=0")

  // The write landed in the guest's copy of the checkout.
  let written =
    remote_pair.read_file(
      root
        <> microvm_executor.workspaces_dir
        <> "/"
        <> remote_pair.workspace_name,
      note,
    )
  assert written == "placed-in-guest\n"
}

fn hex(bytes: Int) -> String {
  token.production_entropy()(bytes)
  |> bit_array.base16_encode
  |> string.lowercase
}

// The guest started inside the deadline-bounded body must be retired outside
// it, so the body sends its handle to the test process, which drains it at
// teardown whether the body finished or not.
type Cell =
  process.Subject(microvm_executor.Guest)

fn weft_cell() -> Cell {
  process.new_subject()
}

fn write_cell(cell: Cell, guest: microvm_executor.Guest) -> Nil {
  process.send(cell, guest)
}

fn read_cell(cell: Cell) -> List(microvm_executor.Guest) {
  case process.receive(cell, 0) {
    Ok(guest) -> [guest, ..read_cell(cell)]
    Error(Nil) -> []
  }
}
