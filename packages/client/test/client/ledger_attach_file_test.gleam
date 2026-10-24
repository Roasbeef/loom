//// `loom distribution attach-file` (protocol-change/096), run against a real
//// `provision` output as `ledger_cli_test` runs the other operator commands:
//// a sealed authority key, real certificates, and a hub daemon that is a ledger
//// process in this VM.
////
//// The properties pinned here are the ones a tool's operator depends on. The
//// five files exist with the key and cookie private, the options file is the
//// plain one `distribution_attach` renders, the ledger gains a `tool` member
//// linked to the daemon and nothing else, and everything that would make a
//// tool look like a daemon is refused before anything is signed.

import client/daemon/ledger_cli
import client/distribution_attach
import client/ledger_control.{type Handle}
import client/membership_ledger
import client/membership_signing
import client/remote/orchestrator_port.{Held}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string
import simplifile
import support/ledger_deployment as deployment

fn attach_args(deployed: deployment.Deployed, extra: List(String)) {
  list.flatten([
    [
      "inspector",
      "--node",
      "inspector@127.0.0.1",
      "--links",
      "hub",
      "--out",
      deployed.base <> "/attach",
      "--wait",
      "0",
    ],
    deployment.signing(deployed),
    extra,
  ])
}

fn hub(deployed) -> Handle {
  deployment.serve(deployed, "hub", "hub", "loom@hub.example")
  |> fn(handle) {
    ledger_control.asking(handle, fn(_node) {
      Ok(Held(sessions: 0, placed: []))
    })
  }
}

fn offline(deployed, extra) {
  ledger_cli.run_with("attach-file", attach_args(deployed, extra), fn(_) {
    deployment.nobody()
  })
}

fn mode_of(path: String) -> Int {
  let assert Ok(info) = simplifile.file_info(path)
  int.bitwise_and(info.mode, 0o777)
}

fn copy_of(deployed: deployment.Deployed) -> List(String) {
  deployment.lines(deployment.authority_directory(deployed) <> "/ledger.log")
}

pub fn attach_file_enrolls_a_tool_and_writes_the_five_files_test() {
  let deployed = deployment.provision("attach-writes", deployment.plan_text)
  let assert Ok(report) = offline(deployed, [])
  assert string.contains(
    report,
    "Enrolled inspector (tool, inspector@127.0.0.1)",
  )
  assert string.contains(report, "as entry 3")

  // The report is the recipe: the standard flags, the tool's node name and the
  // daemon it was linked to, and nothing that is specific to Loom.
  assert string.contains(report, "-proto_dist inet_tls -ssl_dist_optfile")
  assert string.contains(report, "-name inspector@127.0.0.1")
  assert string.contains(report, "-remsh loom@hub.example")

  let files = distribution_attach.files_in(deployed.base <> "/attach")
  let assert Ok(options) = simplifile.read(files.options)
  assert Ok(options) == distribution_attach.options(files)
  let assert Ok(key) = simplifile.read(files.key)
  assert string.contains(key, "PRIVATE KEY")
  let assert Ok(cookie) = simplifile.read(files.cookie)
  assert !string.ends_with(cookie, "\n")
  assert simplifile.read(files.node) == Ok("inspector@127.0.0.1\n")
  assert string.contains(report, "pickglass attach --node loom@hub.example")

  // The directory is private, and the key and cookie are readable by the
  // owner alone.
  assert mode_of(files.directory) == 0o700
  assert mode_of(files.key) == 0o600
  assert mode_of(files.cookie) == 0o600

  // The daemon trusts the tool through the tool's own link, and the tool
  // trusts only that daemon.
  let assert Ok(ca) = simplifile.read(files.ca)
  let assert Ok(verify) = membership_signing.verifier(ca)
  let assert Ok(ledger) =
    membership_ledger.replay(
      list.map(copy_of(deployed), bit_array.from_string),
      verify,
    )
  let names = fn(owner) {
    membership_ledger.pin_table(ledger, owner)
    |> membership_ledger.peers
    |> list.map(fn(peer) { peer.name })
  }
  assert list.contains(names("hub"), "inspector")
  assert names("inspector") == ["hub"]
  assert !list.contains(names("devbox"), "inspector")

  // The ledger copy grew by the one entry and names the role.
  assert list.length(copy_of(deployed)) == 4
  let assert Ok(log) =
    ledger_cli.run_with("log", ["--home", deployed.home], fn(_) {
      deployment.nobody()
    })
  assert string.contains(log, "inspector")
  assert string.contains(log, " tool ")
}

pub fn the_daemon_takes_the_entry_and_the_tool_is_linked_to_it_test() {
  let deployed = deployment.provision("attach-daemon", deployment.plan_text)
  let handle = hub(deployed)
  let assert Ok(report) =
    ledger_cli.run_with("attach-file", attach_args(deployed, []), fn(_) {
      deployment.daemon_over(handle)
    })
  assert string.contains(report, "Handed to")
  assert string.contains(report, "confirmed")
}

pub fn a_tool_with_no_link_or_a_link_to_a_tool_is_refused_before_signing_test() {
  let deployed = deployment.provision("attach-refused", deployment.plan_text)
  let assert Ok(_) = offline(deployed, [])
  let refused = fn(arguments, fragment) {
    let assert Error(reason) =
      ledger_cli.run_with("attach-file", arguments, fn(_) {
        deployment.nobody()
      })
    assert string.contains(reason, fragment)
    assert list.length(copy_of(deployed)) == 4
  }
  let with = fn(name, node, links, out) {
    list.flatten([
      [
        name,
        "--node",
        node,
        "--links",
        links,
        "--out",
        deployed.base <> "/" <> out,
        "--wait",
        "0",
      ],
      deployment.signing(deployed),
    ])
  }

  refused(with("second", "second@127.0.0.1", "", "second"), "no --links")
  refused(
    with("third", "third@127.0.0.1", "inspector", "third"),
    "that is a tool",
  )
  refused(with("fourth", "fourth@127.0.0.1", "ghost", "fourth"), "ghost")
}

pub fn nothing_may_list_a_tool_and_a_tool_is_not_renewed_test() {
  let deployed = deployment.provision("attach-lists", deployment.plan_text)
  let assert Ok(_) = offline(deployed, [])
  let assert Error(reason) =
    ledger_cli.run_with(
      "enroll",
      list.flatten([
        [
          "laptop2",
          "--node",
          "loom@laptop2.example.net",
          "--role",
          "orchestrator",
          "--links",
          "hub,inspector",
          "--out",
          deployed.base <> "/bundles",
          "--wait",
          "0",
        ],
        deployment.signing(deployed),
      ]),
      fn(_) { deployment.nobody() },
    )
  assert string.contains(reason, "nothing lists a tool")

  let assert Error(reason) =
    ledger_cli.run_with(
      "renew",
      [
        "inspector",
        "--wait",
        "0",
        "--out",
        deployed.base,
        ..deployment.signing(deployed)
      ],
      fn(_) { deployment.nobody() },
    )
  assert string.contains(reason, "`revoke` it and run `attach-file` again")
}

pub fn existing_credentials_are_kept_without_force_and_a_tool_is_revocable_test() {
  let deployed = deployment.provision("attach-force", deployment.plan_text)
  let handle = hub(deployed)
  let daemon = fn(_) { deployment.daemon_over(handle) }
  let assert Ok(_) =
    ledger_cli.run_with("attach-file", attach_args(deployed, []), daemon)
  let files = distribution_attach.files_in(deployed.base <> "/attach")
  let assert Ok(before) = simplifile.read(files.key)

  let assert Error(reason) =
    ledger_cli.run_with("attach-file", attach_args(deployed, []), daemon)
  assert string.contains(reason, "is not empty")
  let assert Ok(unchanged) = simplifile.read(files.key)
  assert unchanged == before

  // A tool holds no sessions, so it is revoked without --force once the
  // orchestrators answer, and attached again with --force over its files.
  let assert Ok(report) =
    ledger_cli.run_with(
      "revoke",
      ["inspector", "--wait", "0", ..deployment.signing(deployed)],
      daemon,
    )
  assert string.contains(report, "Revoked inspector")
  assert string.contains(report, "holds no sessions")
  let assert Ok(_) =
    ledger_cli.run_with(
      "attach-file",
      attach_args(deployed, ["--force"]),
      daemon,
    )
  let assert Ok(after) = simplifile.read(files.key)
  assert after != before
}

pub fn a_directory_that_holds_anything_is_refused_without_force_test() {
  let deployed = deployment.provision("attach-occupied", deployment.plan_text)
  let directory = deployed.base <> "/attach"
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let cookie = directory <> "/.erlang.cookie"
  let assert Ok(Nil) = simplifile.write(cookie, "mine")
  let assert Ok(Nil) = simplifile.set_permissions_octal(directory, 0o755)

  // One of the five names, or any other file, makes the directory occupied:
  // nothing is signed, nothing is replaced, and the mode is not changed.
  let assert Error(reason) = offline(deployed, [])
  assert string.contains(reason, "is not empty")
  assert string.contains(reason, "--force")
  assert simplifile.read(cookie) == Ok("mine")
  assert mode_of(directory) == 0o755
  assert list.length(copy_of(deployed)) == 3
}

pub fn a_home_with_no_authority_key_names_where_the_key_lives_test() {
  let deployed = deployment.provision("attach-no-key", deployment.plan_text)
  let assert Error(reason) =
    ledger_cli.run_with(
      "attach-file",
      [
        "inspector",
        "--node",
        "inspector@127.0.0.1",
        "--links",
        "hub",
        "--out",
        deployed.base <> "/attach-no-key",
        "--home",
        deployed.base <> "/empty-home",
      ],
      fn(_) { deployment.nobody() },
    )

  // The sentence names the option that points at the right account and says
  // why enrolling anywhere else cannot work.
  assert string.contains(reason, "no authority key is kept under")
  assert string.contains(reason, "--home")
  assert string.contains(reason, "only on the machine")
}
