//// Session startup errors survive fast retirement as classified log records.
//// The production assembly resolves a deliberately missing helper, while the
//// real domain uses maintenance-off configuration and never calls a provider.

import client/daemon/main
import client/daemon/manager
import client/daemon/root
import client/owned_assembly_test
import core/clock
import core/ids
import filepath
import gleam/erlang/process
import gleam/string
import host/bootstrap
import simplifile
import storage/domain
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
