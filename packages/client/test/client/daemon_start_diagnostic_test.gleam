//// Session startup errors survive fast retirement as classified log records.
//// The production assembly resolves a deliberately missing helper, while the
//// real domain uses maintenance-off configuration and never calls a provider.

import client/daemon/main
import client/daemon/manager
import client/daemon/root
import client/internal/ffi_os
import client/owned_assembly_test
import client/serve
import core/clock
import core/ids
import filepath
import gleam/erlang/process
import gleam/int
import gleam/string
import host/bootstrap
import session/session
import simplifile
import storage/domain
import storage/sqlite
import telemetry/field
import telemetry/level
import telemetry/log
import telemetry/record

pub fn daemon_start_diagnostic_classifies_missing_helper_without_raw_error_test() {
  let settings = owned_assembly_test.settings()
  let directory = filepath.directory_name(settings.session_path)
  let workspace = directory <> "-workspace"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(workspace)
    as "fixture workspace is outside protected daemon state"
  let configuration = workspace <> "/loom.toml"
  let assert Ok(Nil) =
    simplifile.write(
      configuration,
      "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"UNUSED_TEST_KEY\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n[roles]\nmain = [\"fixture\"]\n[memory]\ndistill = \"off\"\n",
    )
    as "domain maintenance cannot consume environment provider credentials"
  let private_detail = "diagnostic-private-path-detail"
  let assert Ok(config) =
    main.parse([
      "--state-dir",
      directory,
      "--helper",
      workspace <> "/" <> private_detail <> "/missing-helper",
    ])
    as "helper existence is checked only at explicit session startup"
  let events = process.new_subject()
  let logger = log.new(sink: log.to_subject(events), threshold: level.Error)
  let assert Ok(daemon) = main.prepare(config, logger)
    as "production daemon root is prepared without session effects"
  let assert Ok(ready) = root.ready(daemon, within: 5000)
    as "catalogue restoration does not resolve the missing helper"

  // Retain the original root until cleanup completes even if the expected
  // diagnostic never arrives. Assertions below cannot strand a live domain.
  let created =
    manager.create_scoped(
      ready.registry,
      manager.Creation("missing-helper", workspace, "Fixture", configuration),
      directory: ready.sessions_directory,
      generator: ids.generator(clock.fixed(1000), 992),
      scope: domain.WorkspacePrivate,
      configuration: configuration,
    )
  let observed = process.receive(events, 5000)
  let retired = root.shutdown(daemon, within: 10_000)
  assert retired == Ok(Nil)
  let assert Ok(view) = created as "explicit creation reserves one identity"
  let assert Ok(event) = observed
    as "fast assembly failure emits a diagnostic before its cause is forgotten"
  assert event.level == level.Error
  assert event.event == "daemon.session_start_failed"
  assert event.fields
    == [
      field.ident("session", view.registration.id),
      field.text("stage", "settings_resolution"),
      field.text("class", "helper_unavailable"),
    ]
  assert !string.contains(record.render(event), private_detail)
  assert !string.contains(record.render(event), workspace)
}

// A SIGKILL cannot run the lease release, so the row the dead writer wrote
// stays in the file with its original expiry and the next boot is refused by
// its own predecessor. Take that refusal from a real second open rather than
// building a `LeaseHeld` by hand: the expiry has to be the one the file
// actually holds for the classified detail to be worth logging.
fn held_lease_refusal() -> #(String, Int) {
  let assert Ok(here) = simplifile.current_directory() as "fixture root exists"
  let root =
    here
    <> "/build/lease-diagnostic-"
    <> int.to_string(ffi_os.system_time_ms())
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let assert Ok(Nil) = bootstrap.ensure_private_directory(root)
    as "fixture session directory is private to this run"
  let path = root <> "/session.db"
  let at = 1_700_000_000_000
  let ttl = 60_000
  let assert Ok(#(_held, _retire, _transfer)) =
    session.open_sqlite_custody(
      path:,
      owner: "loomd-incarnation-that-was-killed",
      lease_ttl_ms: ttl,
      clock: clock.fixed(at),
    )
    as "the first writer takes the lease the kill will strand"

  // The replacement daemon's open, with the stranded lease still unexpired.
  let assert Error(refused) =
    session.open_sqlite_custody(
      path:,
      owner: "loomd-replacement",
      lease_ttl_ms: ttl,
      clock: clock.fixed(at),
    )
    as "an unexpired lease refuses the replacement rather than stealing it"
  #(serve.storage_open_refusal(refused), at + ttl)
}

pub fn daemon_start_diagnostic_names_the_lease_expiry_test() {
  let #(refusal, expires_at_ms) = held_lease_refusal()

  // The class an operator can act on, and the instant that is the whole of
  // the action: before this change every storage refusal collapsed into
  // `storage_open_failed` with nothing to wait for.
  assert main.start_class(main.RuntimeAssembly, refusal)
    == #("runtime_assembly", "lease_held", [
      field.count("lease_expires_at_ms", expires_at_ms),
    ])
}

pub fn daemon_start_diagnostic_keeps_other_storage_failures_opaque_test() {
  let unclassified =
    serve.storage_open_refusal(
      session.SqliteOpenFailed(sqlite.OpenFailed("/private/path/session.db")),
    )
  assert main.start_class(main.RuntimeAssembly, unclassified)
    == #("runtime_assembly", "storage_open_failed", [])
}
