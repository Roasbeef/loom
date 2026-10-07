//// Session startup errors survive fast retirement as classified log records.
//// The production assembly resolves a deliberately missing helper, while the
//// real domain uses maintenance-off configuration and never calls a provider.

import client/catalog
import client/daemon/main
import client/daemon/manager
import client/daemon/root
import client/daemon_server_test as wire
import client/internal/ffi_os
import client/owned_assembly_test
import client/serve
import core/clock
import core/glance
import core/ids
import core/json
import filepath
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response
import gleam/int
import gleam/option.{Some}
import gleam/string
import host/bootstrap
import mist
import session/session
import simplifile
import storage/domain
import storage/sqlite
import telemetry/field
import telemetry/level
import telemetry/log
import telemetry/record
import tui/daemon as terminal_control
import tui/daemon/protocol as terminal_protocol
import tui/daemon/selection
import weft/poll

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
      manager.Creation(
        "missing-helper",
        workspace,
        "Fixture",
        configuration,
        option.None,
        "",
      ),
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

pub fn daemon_start_diagnostic_classifies_rejected_domain_configuration_test() {
  rejected_configuration(MissingRoleModel)
}

pub fn malformed_toml_reaches_the_operator_with_path_and_parser_context_test() {
  rejected_configuration(MalformedToml)
}

type ConfigDefect {
  MissingRoleModel
  MalformedToml
}

fn rejected_configuration(defect: ConfigDefect) {
  let settings = owned_assembly_test.settings()
  let directory = filepath.directory_name(settings.session_path)
  let workspace = directory <> "-workspace"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(workspace)
    as "fixture workspace is outside protected daemon state"
  let private_detail = "diagnostic-private-missing-model"
  let configuration = workspace <> "/loom.toml"
  let contents = case defect {
    MissingRoleModel ->
      "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"UNUSED_TEST_KEY\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n[roles]\nmain = [\"fixture\"]\nsummarize = [\""
      <> private_detail
      <> "\"]\n[memory]\ndistill = \"off\"\n"
    MalformedToml -> "[roles\nmain = [\"fixture\"]\n"
  }
  let assert Ok(Nil) = simplifile.write(configuration, contents)
    as "the fixture rejects configuration during real domain assembly"
  let assert Ok(config) =
    main.parse(["--state-dir", directory, "--bind", "127.0.0.1:0"])
    as "metadata startup must not eagerly validate a domain catalogue"
  let events = process.new_subject()
  let logger = log.new(sink: log.to_subject(events), threshold: level.Error)
  let assert Ok(daemon) = main.prepare(config, logger)
    as "production daemon starts before explicit domain admission"
  let assert Ok(ready) = root.ready(daemon, within: 5000)
    as "the real registry is ready before creation"

  // Domain loading fails before a session builder can report anything. Keep
  // the logger's event outside that retiring owner, then join root cleanup
  // before asserting so a regression cannot strand the fixture's catalogue.
  let created =
    manager.create_scoped(
      ready.registry,
      manager.Creation(
        "invalid-domain-config",
        workspace,
        "Fixture",
        configuration,
        option.None,
        "",
      ),
      directory: ready.sessions_directory,
      generator: ids.generator(clock.fixed(1000), 993),
      scope: domain.WorkspacePrivate,
      configuration: configuration,
    )
  let observed = process.receive(events, 5000)
  let assert Ok(view) = created
    as "creation reserves identity before domain loading"
  let assert manager.Opening(operation) = view.status
    as "creation exposes the exact opening operation"
  let settled =
    poll.until(within: 5000, every: 5, attempt: fn() {
      case manager.operation(ready.registry, view.registration.id, operation) {
        Error(manager.StartFailed(reason)) -> poll.Done(reason)
        Ok(manager.View(status: manager.Opening(_), ..)) -> poll.Retry
        Ok(view) ->
          poll.Fail(
            "startup polling terminated: " <> string.inspect(view.status),
          )
        Error(error) -> poll.Fail(string.inspect(error))
      }
    })
  let assert Ok(serving) =
    main.listen(config, daemon, fn(_, _) {
      response.new(501)
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string("unused session route")),
      )
    })
    as "the real control listener serves the failed operation"
  let assert Ok(credential) = root.listener_credential(daemon)
    as "owner credential is private to the fixture"
  let #(socket, _) =
    wire.connect(serving.listener.port, credential, "/v2/control")
  let _hello = wire.frame(socket, within_ms: 1000)
  let refused =
    wire.send(
      socket,
      1,
      "operations.get",
      json.Object([
        #("session_id", json.String(view.registration.id)),
        #("operation", json.String(operation)),
        #("epoch", json.String(ready.epoch)),
      ]),
      within_ms: 1000,
    )
  let stale =
    wire.send(
      socket,
      2,
      "operations.get",
      json.Object([
        #("session_id", json.String(view.registration.id)),
        #("operation", json.String("another-operation")),
        #("epoch", json.String(ready.epoch)),
      ]),
      within_ms: 1000,
    )
  let obsolete =
    wire.send(
      socket,
      3,
      "operations.get",
      json.Object([
        #("session_id", json.String(view.registration.id)),
        #("operation", json.String(operation)),
        #("epoch", json.String("another-epoch")),
      ]),
      within_ms: 1000,
    )
  let retired = root.shutdown(daemon, within: 10_000)
  assert retired == Ok(Nil)
  assert terminal_protocol.decode(json.to_string(stale))
    == Ok(terminal_protocol.Refused(
      Some(2),
      "stale_operation",
      "request refused",
    ))
  assert terminal_protocol.decode(json.to_string(obsolete))
    == Ok(terminal_protocol.Refused(Some(3), "stale_epoch", "request refused"))
  let assert poll.Answered(reason) = settled
    as "domain failure survives slot retirement"
  let assert Error(parse_reason) = catalog.parse(contents)
    as "the catalogue provides the original diagnosis"
  assert reason == glance.clip(configuration <> ": " <> parse_reason, 2048)
  assert string.contains(reason, configuration)
  assert case defect {
    MissingRoleModel -> string.contains(reason, private_detail)
    MalformedToml -> string.contains(reason, "not valid toml")
  }
  let assert Ok(terminal_protocol.Refused(Some(1), "start_failed", delivered)) =
    terminal_protocol.decode(json.to_string(refused))
    as "the terminal decodes the same exact diagnostic"
  assert delivered == reason
  assert selection.failure(terminal_control.Refused("start_failed", delivered))
    == "session startup failed: " <> reason
  let assert Ok(event) = observed
    as "domain failure emits its class and bounded reason"
  assert event.level == level.Error
  assert event.event == "daemon.domain_start_failed"
  assert event.fields
    == [
      field.text("stage", "domain_assembly"),
      field.text("class", "configuration_rejected"),
      field.text("reason", reason),
    ]
}
