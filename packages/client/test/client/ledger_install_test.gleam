//// Installing a `/2` bundle (protocol-change/086): the node it leaves behind
//// runs from its ledger, and the files it writes are the ones the daemon
//// reads.
////
//// The bundles come from the real `provision`, so the credentials and the
//// ledger are genuine, and the daemon's own readers judge what `install`
//// wrote: the configuration parses in ledger mode, its rows resolve against
//// the ledger, and the ledger process starts from the file.

import client/distribution
import client/distribution_install.{Options}
import client/distribution_provision.{RefuseExisting, ReplaceExisting}
import client/executors
import client/ledger_boot
import client/ledger_service
import client/ledger_trust
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/string
import simplifile
import support/ledger_deployment as deployment
import telemetry/log

fn options(
  base: String,
  name: String,
  overwrite,
) -> distribution_install.Options {
  Options(
    home: base <> "/" <> name,
    config: base <> "/" <> name <> "/.loom/loom.toml",
    overwrite:,
  )
}

pub fn a_ledger_bundle_installs_a_node_that_runs_from_its_ledger_test() {
  let deployed = deployment.provision("install", deployment.plan_text)
  let text = deployment.read(deployed.out <> "/hub.loombundle")
  let assert Ok(installed) =
    distribution_install.install(
      text,
      options(deployed.base, "hub", RefuseExisting),
    )

  // The ledger is beside the credentials, and is the operator's file.
  let directory = deployed.base <> "/hub/.loom/distribution"
  assert deployment.read(directory <> "/ledger.log")
    == deployment.read(deployed.out <> "/ledger.log")

  // The configuration names the ledger and no peer, and the daemon's reader
  // puts the node in ledger mode.
  let config = deployment.read(deployed.base <> "/hub/.loom/loom.toml")
  assert string.contains(config, "ledger = ")
  assert !string.contains(config, "[[distribution.peers]]")
  let assert Ok(Some(settings)) = distribution.parse(config)
  assert distribution.ledger_path(settings) == Some(directory <> "/ledger.log")

  // The options file is the live one: it names no pin, and the daemon's boot
  // check compares it with what the configuration generates.
  assert deployment.read(directory <> "/dist.options")
    == distribution.tls_options(settings)

  // The orchestrator's executor row resolves against the ledger, which is the
  // check the daemon makes at start.
  assert executors.parse(config)
    == Ok([executors.plain("devbox", "loom@devbox.example")])

  // The report says what the node trusts until it syncs.
  let assert Some(snapshot) = installed.snapshot
  assert snapshot.seq == 2
}

pub fn an_installed_ledger_node_starts_its_ledger_process_test() {
  let deployed = deployment.provision("install-boot", deployment.plan_text)
  let text = deployment.read(deployed.out <> "/devbox.loombundle")
  let assert Ok(_) =
    distribution_install.install(
      text,
      options(deployed.base, "devbox", RefuseExisting),
    )
  let config = deployment.read(deployed.base <> "/devbox/.loom/loom.toml")
  let assert Ok(Some(settings)) = distribution.parse(config)
  let assert Some(path) = distribution.ledger_path(settings)
  let local = distribution.local_node(settings)
  let assert Ok(service) =
    ledger_boot.open_service(
      path,
      distribution.credential_files(settings).ca,
      local,
      [ledger_trust.observer(local, log.discard())],
      log.discard(),
    )
  let assert Ok(head) = ledger_service.head(service, 5000)
  assert head.seq == 2
  process.unlink(ledger_service.pid(service))
  process.kill(ledger_service.pid(service))
}

pub fn a_second_install_of_the_same_bundle_changes_nothing_test() {
  let deployed = deployment.provision("install-twice", deployment.plan_text)
  let text = deployment.read(deployed.out <> "/hub.loombundle")
  let assert Ok(_) =
    distribution_install.install(
      text,
      options(deployed.base, "hub", RefuseExisting),
    )
  let assert Ok(again) =
    distribution_install.install(
      text,
      options(deployed.base, "hub", RefuseExisting),
    )
  assert list.all(again.steps, fn(step) {
    step.outcome == distribution_install.Unchanged
  })
}

pub fn a_different_ledger_on_the_machine_is_refused_without_force_test() {
  let deployed = deployment.provision("install-fork", deployment.plan_text)
  let text = deployment.read(deployed.out <> "/hub.loombundle")
  let directory = deployed.base <> "/hub/.loom/distribution"
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let assert Ok(Nil) = simplifile.write(directory <> "/ledger.log", "xx.yy\n")
  let assert Error(reason) =
    distribution_install.install(
      text,
      options(deployed.base, "hub", RefuseExisting),
    )
  assert string.contains(reason, "is a fork")

  // Nothing else was written, and `--force` takes the bundle's ledger.
  assert simplifile.is_file(directory <> "/ca.pem") == Ok(False)
  let assert Ok(_) =
    distribution_install.install(
      text,
      options(deployed.base, "hub", ReplaceExisting),
    )
  assert deployment.read(directory <> "/ledger.log")
    == deployment.read(deployed.out <> "/ledger.log")
}
