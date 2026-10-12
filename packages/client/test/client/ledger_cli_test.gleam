//// The operator commands `enroll`, `revoke`, `renew`, `log` and `import`
//// (protocol-change/086), run as production runs them against a real
//// `provision` output: a sealed ECDSA authority key, real node certificates and
//// a ledger signed by that key.
////
//// The daemon a command talks to is a ledger process in this VM, reached
//// through the same three functions the socket would give (`run_with`), so the
//// sequence of work in the commands is the production one and only the transport
//// differs. The socket itself is `daemon_ledger_test`, and a real daemon pair
//// is `ledger_operator_live_test`.

import client/daemon/ledger_cli
import client/distribution_bundle
import client/distribution_install.{Options}
import client/distribution_provision.{ReplaceExisting}
import client/ledger_control.{type Handle}
import client/ledger_service
import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import support/ledger_deployment as deployment

fn enroll_laptop(deployed: deployment.Deployed, extra: List(String)) {
  list.flatten([
    [
      "laptop2",
      "--node",
      "loom@laptop2.example.net",
      "--role",
      "orchestrator",
      "--links",
      "hub,devbox",
      "--out",
      deployed.base <> "/bundles",
      "--wait",
      "0",
    ],
    deployment.signing(deployed),
    extra,
  ])
}

fn copy_of(deployed: deployment.Deployed) -> List(String) {
  deployment.lines(deployment.authority_directory(deployed) <> "/ledger.log")
}

fn hub(deployed) {
  deployment.serve(deployed, "hub", "hub", "loom@hub.example")
}

fn head_of(handle: Handle) -> Int {
  let assert Ok(head) = ledger_service.head(handle.service, 5000)
  head.seq
}

pub fn an_enrollment_with_no_daemon_stays_in_the_copy_and_says_how_to_carry_it_test() {
  let deployed = deployment.provision("cli-offline", deployment.plan_text)
  let assert Ok(report) =
    ledger_cli.run_with("enroll", enroll_laptop(deployed, []), fn(_) {
      deployment.nobody()
    })
  assert string.contains(report, "Enrolled laptop2")
  assert string.contains(report, "as entry 3")
  assert string.contains(report, "No daemon took the entry")
  assert string.contains(report, "loom distribution import")

  // The copy grew by the one entry, and the bundle carries all four lines.
  let lines = copy_of(deployed)
  assert list.length(lines) == 4
  let assert Ok(text) =
    simplifile.read(deployed.base <> "/bundles/laptop2.loombundle")
  let assert Ok(bundle) = distribution_bundle.decode(text)
  assert bundle.trust == distribution_bundle.SignedLedger(lines)

  // The new laptop is an orchestrator that uses the executor it was linked to.
  assert bundle.name == "laptop2"
  assert list.map(bundle.executors, fn(row) { row.name }) == ["devbox"]
}

pub fn an_enrollment_reaches_the_daemon_and_the_report_says_who_holds_it_test() {
  let deployed = deployment.provision("cli-online", deployment.plan_text)
  let handle = hub(deployed)
  let assert Ok(report) =
    ledger_cli.run_with("enroll", enroll_laptop(deployed, []), fn(_) {
      deployment.daemon_over(handle)
    })
  assert head_of(handle) == 3
  assert string.contains(report, "Handed to")
  assert string.contains(report, "hub")
  assert string.contains(report, "confirmed")

  // Only the daemon's own node has reported. The executor and the node that
  // has not started yet are pending, and the report says so.
  assert string.contains(report, "pending (has not reported)")
  assert string.contains(report, "1 of 3 members hold it")
}

pub fn a_refused_enrollment_signs_nothing_test() {
  let deployed = deployment.provision("cli-refused", deployment.plan_text)
  let refused = fn(arguments, fragment) {
    let assert Error(reason) =
      ledger_cli.run_with("enroll", arguments, fn(_) { deployment.nobody() })
    assert string.contains(reason, fragment)
    assert list.length(copy_of(deployed)) == 3
  }

  // A name that is a member already is renewed, not enrolled.
  refused(
    [
      "hub",
      "--node",
      "loom@other.example",
      "--role",
      "executor",
      "--wait",
      "0",
      "--out",
      deployed.base <> "/bundles",
      ..deployment.signing(deployed)
    ],
    "already a member",
  )

  // A node another member holds, a link to nobody, and a directory standing
  // the ledger cannot carry yet.
  refused(
    enroll_laptop(deployed, ["--node", "loom@hub.example"])
      |> drop_flag("--node", "loom@laptop2.example.net"),
    "already belongs to another member",
  )
  refused(
    enroll_laptop(deployed, ["--links", "ghost"])
      |> drop_flag("--links", "hub,devbox"),
    "ghost cannot be linked",
  )
  refused(enroll_laptop(deployed, ["--directory", "voter"]), "must be none")
  refused(
    enroll_laptop(deployed, ["--role", "wizard"])
      |> drop_flag("--role", "orchestrator"),
    "role must be",
  )
  refused(enroll_laptop(deployed, ["--bogus", "1"]), "unknown option --bogus")
  refused(
    enroll_laptop(deployed, ["--wait", "9999"]) |> drop_flag("--wait", "0"),
    "--wait takes",
  )
}

// Removes a flag and its value, so a test can replace it with another.
fn drop_flag(arguments: List(String), flag: String, value: String) {
  case arguments {
    [] -> []
    [word, given, ..rest] if word == flag && given == value -> rest
    [word, ..rest] -> [word, ..drop_flag(rest, flag, value)]
  }
}

pub fn a_wrong_passphrase_signs_nothing_test() {
  let deployed = deployment.provision("cli-passphrase", deployment.plan_text)
  let wrong = deployed.base <> "/wrong"
  let assert Ok(Nil) = simplifile.write(wrong, "not the right passphrase\n")
  let assert Ok(Nil) = simplifile.set_permissions_octal(wrong, 0o600)
  let assert Error(reason) =
    ledger_cli.run_with(
      "enroll",
      enroll_laptop(deployed, [])
        |> drop_flag("--passphrase-file", deployed.passphrase_file)
        |> list.append(["--passphrase-file", wrong]),
      fn(_) { deployment.nobody() },
    )
  assert string.contains(reason, "passphrase is wrong")
  assert list.length(copy_of(deployed)) == 3
  assert simplifile.is_file(deployed.base <> "/bundles/laptop2.loombundle")
    == Ok(False)
}

pub fn a_bundle_that_exists_is_not_replaced_without_force_test() {
  let deployed = deployment.provision("cli-exists", deployment.plan_text)
  let assert Ok(Nil) =
    simplifile.create_directory_all(deployed.base <> "/bundles")
  let assert Ok(Nil) =
    simplifile.write(deployed.base <> "/bundles/laptop2.loombundle", "old")
  let assert Error(reason) =
    ledger_cli.run_with("enroll", enroll_laptop(deployed, []), fn(_) {
      deployment.nobody()
    })
  assert string.contains(reason, "already exists")
  assert list.length(copy_of(deployed)) == 3
  let assert Ok(_) =
    ledger_cli.run_with("enroll", enroll_laptop(deployed, ["--force"]), fn(_) {
      deployment.nobody()
    })
  assert list.length(copy_of(deployed)) == 4
}

pub fn a_revoke_that_orphans_an_executor_needs_force_test() {
  let deployed = deployment.provision("cli-revoke", deployment.plan_text)
  let handle = hub(deployed)
  let arguments = ["hub", "--wait", "0", ..deployment.signing(deployed)]

  // The hub is the only orchestrator the devbox is linked to.
  let assert Error(reason) =
    ledger_cli.run_with("revoke", arguments, fn(_) {
      deployment.daemon_over(handle)
    })
  assert string.contains(reason, "devbox would have no orchestrator")
  assert string.contains(reason, "Nothing was signed")
  assert list.length(copy_of(deployed)) == 3
  assert head_of(handle) == 2

  let assert Ok(report) =
    ledger_cli.run_with(
      "revoke",
      list.append(arguments, ["--force", "--reason", "lost"]),
      fn(_) { deployment.daemon_over(handle) },
    )
  assert string.contains(report, "Revoked hub as entry 3")
  assert string.contains(report, "owns sessions")
  assert head_of(handle) == 3
  assert list.length(copy_of(deployed)) == 4
}

pub fn a_revoke_of_a_leaf_member_needs_no_force_test() {
  let deployed = deployment.provision("cli-leaf", deployment.plan_text)
  let handle = hub(deployed)
  let assert Ok(_) =
    ledger_cli.run_with("enroll", enroll_laptop(deployed, []), fn(_) {
      deployment.daemon_over(handle)
    })
  let assert Ok(report) =
    ledger_cli.run_with(
      "revoke",
      ["laptop2", "--wait", "0", ..deployment.signing(deployed)],
      fn(_) { deployment.daemon_over(handle) },
    )
  assert string.contains(report, "Revoked laptop2 as entry 4")

  // The name can be enrolled again, which is an ordinary entry.
  let assert Ok(report) =
    ledger_cli.run_with("enroll", enroll_laptop(deployed, ["--force"]), fn(_) {
      deployment.daemon_over(handle)
    })
  assert string.contains(report, "as entry 5")

  // A name that is not a member cannot be revoked.
  let assert Error(reason) =
    ledger_cli.run_with(
      "revoke",
      ["ghost", ..deployment.signing(deployed)],
      fn(_) { deployment.daemon_over(handle) },
    )
  assert string.contains(reason, "ghost is not a member")
}

pub fn a_renewal_replaces_the_pin_and_writes_a_bundle_that_installs_test() {
  let deployed = deployment.provision("cli-renew", deployment.plan_text)
  let handle = hub(deployed)
  let assert Ok(report) =
    ledger_cli.run_with(
      "renew",
      [
        "devbox",
        "--out",
        deployed.base <> "/renewed",
        "--wait",
        "0",
        ..deployment.signing(deployed)
      ],
      fn(_) { deployment.daemon_over(handle) },
    )
  assert string.contains(report, "Renewed devbox as entry 3")
  assert head_of(handle) == 3

  // The new bundle carries the new certificate, and the old one is not the
  // ledger's pin any longer.
  let assert Ok(old_text) =
    simplifile.read(deployed.out <> "/devbox.loombundle")
  let assert Ok(old) = distribution_bundle.decode(old_text)
  let assert Ok(new_text) =
    simplifile.read(deployed.base <> "/renewed/devbox.loombundle")
  let assert Ok(new) = distribution_bundle.decode(new_text)
  assert new.certificate != old.certificate
  assert new.key != old.key
  assert new.cookie == old.cookie
  assert new.executors == []

  // It installs over the node's old install, and the node starts from it.
  let options =
    Options(
      home: deployed.base <> "/devbox-home",
      config: deployed.base <> "/devbox-home/.loom/loom.toml",
      overwrite: ReplaceExisting,
    )
  let assert Ok(_) = distribution_install.install(old_text, options)
  let assert Ok(installed) = distribution_install.install(new_text, options)
  assert installed.snapshot |> option.map(fn(snapshot) { snapshot.seq })
    == Some(3)
}

pub fn a_copy_behind_the_daemon_catches_up_before_it_signs_test() {
  let deployed = deployment.provision("cli-behind", deployment.plan_text)
  let handle = hub(deployed)

  // A second machine holding the same key and copy enrolls first.
  let second = second_machine(deployed)
  let assert Ok(_) =
    ledger_cli.run_with(
      "enroll",
      [
        "first",
        "--node",
        "loom@first.example",
        "--role",
        "executor",
        "--out",
        deployed.base <> "/bundles",
        "--wait",
        "0",
        ..deployment.signing(second)
      ],
      fn(_) { deployment.daemon_over(handle) },
    )
  assert head_of(handle) == 3

  // This machine's copy still ends at entry 2. It pulls entry 3 from the daemon
  // and signs entry 4, so the two never use one sequence number twice.
  let assert Ok(report) =
    ledger_cli.run_with("enroll", enroll_laptop(deployed, []), fn(_) {
      deployment.daemon_over(handle)
    })
  assert string.contains(report, "as entry 4")
  assert head_of(handle) == 4
  assert list.length(copy_of(deployed)) == 5
}

pub fn a_copy_that_disagrees_with_the_daemon_refuses_to_sign_test() {
  let deployed = deployment.provision("cli-fork", deployment.plan_text)
  let handle = hub(deployed)
  let second = second_machine(deployed)

  // Two machines each sign an entry 3, and only the second reaches the daemon.
  let assert Ok(_) =
    ledger_cli.run_with("enroll", enroll_laptop(deployed, []), fn(_) {
      deployment.nobody()
    })
  let assert Ok(_) =
    ledger_cli.run_with(
      "enroll",
      [
        "other",
        "--node",
        "loom@other.example",
        "--role",
        "executor",
        "--out",
        deployed.base <> "/bundles",
        "--wait",
        "0",
        ..deployment.signing(second)
      ],
      fn(_) { deployment.daemon_over(handle) },
    )
  let before = copy_of(deployed)
  let assert Error(reason) =
    ledger_cli.run_with(
      "revoke",
      ["laptop2", "--wait", "0", ..deployment.signing(deployed)],
      fn(_) { deployment.daemon_over(handle) },
    )
  assert string.contains(reason, "one of them is a fork")
  assert copy_of(deployed) == before
}

// A second operator machine: the same authority directory under another home.
fn second_machine(deployed: deployment.Deployed) -> deployment.Deployed {
  let directory = deployment.authority_directory(deployed)
  let assert Ok(entries) = simplifile.read_directory(directory)
  let id = case string.split(directory, "/") |> list.last {
    Ok(id) -> id
    Error(Nil) -> ""
  }
  let home = deployed.base <> "/second"
  let copied = home <> "/.loom/authority/" <> id
  let assert Ok(Nil) = simplifile.create_directory_all(copied)
  let assert Ok(Nil) = simplifile.set_permissions_octal(copied, 0o700)
  list.each(entries, fn(file) {
    let assert Ok(Nil) =
      simplifile.copy_file(directory <> "/" <> file, copied <> "/" <> file)
    let assert Ok(Nil) =
      simplifile.set_permissions_octal(copied <> "/" <> file, 0o600)
    Nil
  })
  deployment.Deployed(..deployed, home:)
}

pub fn log_prints_every_entry_and_what_the_daemon_reports_test() {
  let deployed = deployment.provision("cli-log", deployment.plan_text)
  let handle = hub(deployed)
  let assert Ok(text) =
    ledger_cli.run_with("log", ["--home", deployed.home], fn(_) {
      deployment.daemon_over(handle)
    })
  assert string.contains(text, "genesis")
  assert string.contains(text, "member   hub  orchestrator  loom@hub.example")
  assert string.contains(text, "member   devbox  executor")
  assert string.contains(text, "head entry 2")
  assert string.contains(text, "hub             entry 2")
  assert string.contains(text, "devbox          has not reported")
  assert string.contains(text, "Last refusal: none.")

  // Without a daemon the entries still print, and the report says why the
  // members' heads are missing.
  let assert Ok(text) =
    ledger_cli.run_with("log", ["--home", deployed.home], fn(_) {
      deployment.nobody()
    })
  assert string.contains(text, "No daemon answered")

  let assert Ok(text) =
    ledger_cli.run_with("log", ["--json", "--home", deployed.home], fn(_) {
      deployment.nobody()
    })
  let assert Ok(json.Object(fields)) = json.parse(text)
  let assert Ok(json.Array(entries)) = list.key_find(fields, "entries")
  assert list.length(entries) == 3
  assert list.key_find(fields, "daemon") == Ok(json.Null)
}

pub fn import_feeds_a_ledger_file_to_the_daemon_test() {
  let deployed = deployment.provision("cli-import", deployment.plan_text)
  let handle = hub(deployed)
  let assert Ok(_) =
    ledger_cli.run_with("enroll", enroll_laptop(deployed, []), fn(_) {
      deployment.nobody()
    })
  assert head_of(handle) == 2
  let file = deployment.authority_directory(deployed) <> "/ledger.log"
  let assert Ok(report) =
    ledger_cli.run_with("import", [file], fn(_) {
      deployment.daemon_over(handle)
    })
  assert string.contains(report, "Applied 1 new entries")
  assert string.contains(report, "is at entry 3")
  assert head_of(handle) == 3

  // The same file again changes nothing.
  let assert Ok(report) =
    ledger_cli.run_with("import", [file], fn(_) {
      deployment.daemon_over(handle)
    })
  assert string.contains(report, "Applied 0 new entries")

  // A file the daemon refuses says which step, and a file with no lines is not
  // sent at all.
  let broken = deployed.base <> "/broken"
  let assert Ok(Nil) = simplifile.write(broken, "not a line\n")
  let assert Error(reason) =
    ledger_cli.run_with("import", [broken], fn(_) {
      deployment.daemon_over(handle)
    })
  assert string.contains(reason, "ledger_invalid: malformed")
  let empty = deployed.base <> "/empty"
  let assert Ok(Nil) = simplifile.write(empty, "\n")
  let assert Error(reason) =
    ledger_cli.run_with("import", [empty], fn(_) {
      deployment.daemon_over(handle)
    })
  assert string.contains(reason, "holds no ledger lines")
}

pub fn the_decoded_status_the_commands_use_is_the_daemons_test() {
  let deployed = deployment.provision("cli-status", deployment.plan_text)
  let handle = hub(deployed)
  let assert Ok(status) = deployment.daemon_over(handle).status()
  assert status.self_name == "hub"
  assert status.standing == ledger_control.Enrolled
  assert status.last_refusal == None
}
