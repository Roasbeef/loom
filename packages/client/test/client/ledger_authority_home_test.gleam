//// How `attach-file` finds the sealed authority key and where `--for pickglass`
//// puts the files, both of which read the process environment.
////
//// Every run passes `ledger_cli.run_in` an environment whose `HOME` and
//// `PICKGLASS_ATTACH_HOME` are scratch directories, so no test reads or touches
//// a real home and none changes the variables of the VM.

import client/authority_home
import client/daemon/ledger_cli
import gleam/list
import gleam/string
import simplifile
import support/ledger_deployment as deployment

// The environment of a scratch machine: a HOME with no authority in it and a
// pickglass attach root of its own.
fn environment(base: String) -> fn(String) -> Result(String, Nil) {
  fn(name) {
    case name {
      "HOME" -> Ok(base <> "/fakehome")
      "PICKGLASS_ATTACH_HOME" -> Ok(base <> "/attach-root")
      _ -> Error(Nil)
    }
  }
}

fn deployment_id(deployed: deployment.Deployed) -> String {
  let directory = deployment.authority_directory(deployed)
  let assert Ok(id) = list.last(string.split(directory, "/"))
  id
}

// Installs the deployment's ledger and CA the way `install` leaves them, under
// a state directory of its own, and returns that state directory.
fn installed(deployed: deployment.Deployed) -> String {
  let state = deployed.base <> "/state"
  let assert Ok(Nil) = simplifile.create_directory_all(state <> "/distribution")
  let authority = deployment.authority_directory(deployed)
  let assert Ok(Nil) =
    simplifile.copy_file(
      authority <> "/ca.pem",
      state <> "/distribution/ca.pem",
    )
  let assert Ok(Nil) =
    simplifile.copy_file(
      authority <> "/ledger.log",
      state <> "/distribution/ledger.log",
    )
  state
}

fn attach(deployed: deployment.Deployed, state: String, extra: List(String)) {
  ledger_cli.run_in(
    "attach-file",
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
        "--state-dir",
        state,
        "--passphrase-file",
        deployed.passphrase_file,
      ],
      extra,
    ]),
    fn(_) { deployment.nobody() },
    environment(deployed.base),
  )
}

pub fn a_missing_key_error_names_the_deployment_and_the_flags_test() {
  let deployed = deployment.provision("home-error", deployment.plan_text)
  let state = installed(deployed)
  let id = deployment_id(deployed)
  let assert Error(reason) = attach(deployed, state, [])
  assert string.contains(reason, "no authority key is kept under")
  assert string.contains(reason, id)
  assert string.contains(reason, "<home>/.loom/authority/" <> id)
  assert string.contains(reason, "--home DIR")
  assert string.contains(reason, "--passphrase-file PATH")
}

pub fn a_home_recorded_beside_the_ledger_is_used_when_it_holds_the_key_test() {
  let deployed = deployment.provision("home-hint", deployment.plan_text)
  let state = installed(deployed)
  let assert Ok(Nil) =
    authority_home.write_hint(state <> "/distribution", deployed.home)
  let assert Ok(report) = attach(deployed, state, [])
  assert string.contains(report, "Enrolled inspector")
}

pub fn a_recorded_home_without_the_key_is_not_trusted_test() {
  let deployed = deployment.provision("home-hint-empty", deployment.plan_text)
  let state = installed(deployed)
  let assert Ok(Nil) =
    authority_home.write_hint(
      state <> "/distribution",
      deployed.base <> "/nowhere",
    )
  let assert Error(reason) = attach(deployed, state, [])
  assert string.contains(reason, deployment_id(deployed))
}

pub fn provision_records_its_home_and_install_copies_it_test() {
  let deployed = deployment.provision("home-record", deployment.plan_text)
  assert authority_home.hinted_home(deployed.out) == Ok(deployed.home)
  let target = deployed.base <> "/target"
  let assert Ok(Nil) = simplifile.create_directory_all(target)
  let assert Ok(Nil) = authority_home.copy_hint(deployed.out, target)
  assert authority_home.hinted_home(target) == Ok(deployed.home)

  // A directory with no hint is not an error, and records nothing.
  let bare = deployed.base <> "/bare"
  let assert Ok(Nil) = simplifile.create_directory_all(bare)
  let other = deployed.base <> "/other"
  let assert Ok(Nil) = simplifile.create_directory_all(other)
  assert authority_home.copy_hint(bare, other) == Ok(Nil)
  assert authority_home.hinted_home(other) == Error(Nil)
}

pub fn for_pickglass_defaults_the_directory_below_the_attach_root_test() {
  let deployed = deployment.provision("for-pickglass", deployment.plan_text)
  let root = deployed.base <> "/attach-root"
  let assert Ok(report) = pickglass(deployed, "inspector", "pickglass")
  assert simplifile.is_file(root <> "/inspector/tool.key") == Ok(True)
  assert string.contains(
    report,
    "pickglass attach --node loom@hub.example --attach inspector",
  )
  assert string.contains(report, "--attach-dir '" <> root <> "/inspector'")

  // Pickglass attaches to nothing by itself, so no line may say it does.
  assert !string.contains(report, "pickglass attach --node loom@hub.example\n")
  assert !string.contains(report, "alone")
}

pub fn for_pickglass_refuses_other_tools_and_path_names_test() {
  let deployed = deployment.provision("for-refused", deployment.plan_text)
  let assert Error(other) = pickglass(deployed, "inspector", "observer")
  assert string.contains(other, "--for takes pickglass")
  let assert Error(_) = pickglass(deployed, "../x", "pickglass")
}

fn pickglass(deployed: deployment.Deployed, name: String, flag: String) {
  ledger_cli.run_in(
    "attach-file",
    list.flatten([
      [
        name,
        "--node",
        "x@127.0.0.1",
        "--links",
        "hub",
        "--for",
        flag,
        "--wait",
        "0",
      ],
      deployment.signing(deployed),
    ]),
    fn(_) { deployment.nobody() },
    environment(deployed.base),
  )
}
