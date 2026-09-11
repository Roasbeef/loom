//// Real session assembly retains its lease behind independently owned cleanup.
//// Native drain is tested at its transport boundary; the interrupted-assembly
//// fixture holds one published effect cleanup to expose the storage ordering.

import broker/broker
import broker/exec
import client/catalog
import client/codemode
import client/distillpass
import client/internal/ffi_os
import client/internal/instance_host as host
import client/internal/instance_owner as custody
import client/jobs
import client/schedule
import client/serve
import core/clock
import core/ids
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import machine/operation
import machine/strand
import provider/adapter/anthropic
import provider/model
import provider/secret
import runtime/api
import session/session
import simplifile
import storage/sqlite
import support/provider as provider_test
import telemetry/level
import telemetry/log
import weft/registry as address

pub fn settings() -> serve.Settings {
  let assert Ok(here) = simplifile.current_directory() as "fixture root exists"
  let root =
    here
    <> "/build/owned-assembly-"
    <> int.to_string(ffi_os.system_time_ms())
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let catalogue =
    catalog.Catalog(
      models: [
        catalog.CatalogModel(
          name: "test",
          dialect: catalog.Anthropic,
          base_url: "https://unused.test",
          api_key_env: "UNUSED",
          model_id: "test",
          context_window: 100_000,
          max_output_tokens: 4096,
          thinking: model.ThinkingOff,
          pricing: None,
        ),
      ],
      roles: [#(model.Main, ["test"])],
      mcp_servers: [],
    )
  serve.Settings(
    secrets: secret.env(),
    secret_failures: [],
    session_path: root <> "/session.db",
    domain_paths: option.None,
    bind_host: "invalid",
    bind_port: -1,
    token_path: root <> "/never-created.token",
    workspace: root <> "/work",
    base_policy: serve.base_policy(root <> "/work"),
    helper_path: here <> "/../sandbox/loom-exec",
    helper_pool_size: 2,
    session_id: "owned",
    demand: exec.BestEffort,
    gateway: catalog.gateway(
      catalogue,
      transport: provider_test.transport(fn(_request, _events) { Nil }),
      secrets: secret.from_list([]),
      clock: clock.fixed(at: 0),
    ),
    catalog: catalogue,
    system: Some("Owned assembly fixture."),
    home: Some(root <> "/absent-home"),
    model: strand.ModelIdentity(provider: "test", model_id: "test"),
    context_window: 100_000,
    max_output_tokens: 4096,
    api: anthropic.api_name,
    compaction: operation.CompactionSettings(
      enabled: True,
      reserve_tokens: 16_384,
      keep_recent_tokens: 20_000,
    ),
    codemode_seed: root <> "/absent-seed",
    codemode_seams: codemode.WorkspaceOnly,
    rules: [],
    schedules: [],
    schedule_policy: schedule.ModelSchedulesOff,
    jobs_policy: jobs.default_policy,
    deactivated_tools: [],
    memory: distillpass.no_pass(),
    tools: catalog.default_tools(),
  )
}

fn identity(seed: Int) -> ids.SessionId {
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(at: 1), seed: seed))
  id
}

fn opened(settings: serve.Settings, id: ids.SessionId) {
  let results = process.new_subject()
  let assert Ok(prepared) =
    host.prepare(
      build: fn(owner) {
        serve.assemble_owned(settings, id, log.discard(), owner)
      },
      fatal: serve.instance_children,
      results:,
      faults: process.new_subject(),
      failures: process.new_subject(),
    )
    as "manager prepares ownership before beginning assembly"
  let watch = process.monitor(host.owner(prepared))
  host.begin(prepared)
  let assert Ok(Ok(instance)) = process.receive(results, 10_000)
    as "the reserved session assembles under surviving custody"
  #(prepared, instance, watch)
}

fn lease_is_held(settings: serve.Settings) {
  let assert Error(session.SqliteOpenFailed(sqlite.LeaseHeld(..))) =
    session.open_sqlite(
      path: settings.session_path,
      owner: "probe",
      lease_ttl_ms: 60_000,
      clock: clock.from_function(ffi_os.system_time_ms),
    )
    as "the original session lease remains reserved"
  Nil
}

fn lease_is_released(settings: serve.Settings) {
  let assert Ok(#(_session, retire)) =
    session.open_sqlite_owned(
      path: settings.session_path,
      owner: "after-drain",
      lease_ttl_ms: 60_000,
      clock: clock.from_function(ffi_os.system_time_ms),
    )
    as "normal custody drain permits a fresh writer"
  assert retire() == Ok(Nil)
}

pub fn two_owned_instances_keep_reserved_ids_and_close_independently_test() {
  let first_settings = settings()
  let second_settings = settings()
  let #(first, first_instance, first_watch) =
    opened(first_settings, identity(1))
  let #(second, second_instance, second_watch) =
    opened(second_settings, identity(2))
  assert api.session_id(first_instance.runtime) == identity(1)
  assert api.session_id(second_instance.runtime) == identity(2)
  assert address.owner(first_instance.namespace)
    != address.owner(second_instance.namespace)
  lease_is_held(first_settings)
  lease_is_held(second_settings)
  assert host.close(first, within_ms: 5000) == custody.Closed
  lease_is_released(first_settings)
  assert process.is_alive(second_instance.runtime.tree.supervisor)
  lease_is_held(second_settings)
  assert host.close(second, within_ms: 5000) == custody.Closed
  lease_is_released(second_settings)
  assert simplifile.is_file(first_settings.token_path) == Ok(False)
  process.demonitor_process(first_watch)
  process.demonitor_process(second_watch)
}

pub fn builder_kill_mid_assembly_keeps_lease_until_published_effect_drains_test() {
  interrupted_assembly(Ok(Nil))
}

pub fn failed_effect_cleanup_keeps_interrupted_assembly_reserved_test() {
  interrupted_assembly(Error("effect retirement refused"))
}

pub fn complete_runtime_shutdown_keeps_lease_until_effect_retirement_test() {
  let settings = settings()
  let cleanup = process.new_subject()
  let results = process.new_subject()
  let assert Ok(prepared) =
    host.prepare(
      build: fn(owner) {
        let assert Ok(Nil) =
          custody.publish(owner, custody.Mcp, fn() {
            let release = process.new_subject()
            process.send(cleanup, release)
            process.receive_forever(release)
            Ok(Nil)
          })
          as "effect custody precedes complete runtime assembly"
        serve.assemble_owned(settings, identity(8), log.discard(), owner)
      },
      fatal: serve.instance_children,
      results:,
      faults: process.new_subject(),
      failures: process.new_subject(),
    )
    as "the host owns the complete session"
  let watch = process.monitor(host.owner(prepared))
  host.begin(prepared)
  let assert Ok(Ok(instance)) = process.receive(results, 5000)
    as "runtime assembly completed"
  host.cancel(prepared)
  let assert Ok(release) = process.receive(cleanup, 5000)
    as "runtime and services drain before the effect boundary"
  assert !process.is_alive(instance.runtime.tree.supervisor)
  lease_is_held(settings)
  process.send(release, Nil)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(5000)
    as "effect retirement precedes storage release"
  lease_is_released(settings)
}

pub fn fatal_broker_death_drains_independent_resources_and_releases_lease_test() {
  let settings = settings()
  let #(_prepared, instance, watch) = opened(settings, identity(6))
  let assert Ok(pid) = broker.pid(instance.broker)
    as "the live broker has an owner"
  process.kill(pid)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(5000)
    as "the broker leaf cannot prevent independent cleanup from proving drain"
  lease_is_released(settings)
}

pub fn fatal_service_root_kill_loses_transitive_proof_and_retains_lease_test() {
  let settings = settings()
  let #(prepared, instance, watch) = opened(settings, identity(7))
  process.kill(instance.services)
  let assert custody.RecoveryBlocked(custody.Failed(custody.Services, _reason)) =
    host.close(prepared, within_ms: 5000)
    as "killing a transitive services root cannot prove its descendants drained"
  assert process.is_alive(host.owner(prepared))
  lease_is_held(settings)
  process.demonitor_process(watch)
}

pub fn owned_assembly_refuses_another_saved_identity_before_effects_test() {
  let settings = settings()
  let assert Ok(Nil) = simplifile.create_directory_all(settings.workspace)
    as "fixture creates the session's parent directory"
  let assert Ok(#(saved, retire)) =
    session.open_sqlite_owned(
      path: settings.session_path,
      owner: "original",
      lease_ttl_ms: 60_000,
      clock: clock.from_function(ffi_os.system_time_ms),
    )
    as "fixture establishes the original saved session"
  assert session.ensure_reserved_id(saved, identity(4)) == Ok(identity(4))
  assert retire() == Ok(Nil)

  let results = process.new_subject()
  let records = process.new_subject()
  let assert Ok(prepared) =
    host.prepare(
      build: fn(owner) {
        serve.assemble_owned(
          settings,
          identity(5),
          log.new(sink: log.to_subject(records), threshold: level.Debug),
          owner,
        )
      },
      fatal: fn(_instance) { [] },
      results:,
      faults: process.new_subject(),
      failures: process.new_subject(),
    )
    as "the manager prepares custody for the attempted reopen"
  let watch = process.monitor(host.owner(prepared))
  host.begin(prepared)
  let assert Ok(Error(_reason)) = process.receive(results, 5000)
    as "a mismatched saved identity refuses assembly"
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(5000)
    as "the refusal closes storage without starting effects"
  assert process.receive(records, 0) == Error(Nil)
  let assert Ok(#(Some(id), _parent)) = sqlite.identity(settings.session_path)
    as "the original identity projection remains readable"
  assert id == ids.session_id_to_string(identity(4))
  lease_is_released(settings)
}

fn interrupted_assembly(cleanup_result: Result(Nil, String)) {
  let settings = settings()
  let reached = process.new_subject()
  let cleanup = process.new_subject()
  let logger =
    log.new(threshold: level.Info, sink: fn(record) {
      case record.event == "server.tools" {
        True -> {
          process.send(reached, Nil)
          process.receive_forever(process.new_subject())
        }
        False -> Nil
      }
    })
  let assert Ok(prepared) =
    host.prepare(
      build: fn(owner) {
        let assert Ok(Nil) =
          custody.publish(owner, custody.Mcp, fn() {
            let release = process.new_subject()
            process.send(cleanup, release)
            process.receive_forever(release)
          })
          as "the fixture effect publishes cleanup before assembly starts"
        serve.assemble_owned(settings, identity(3), logger, owner)
      },
      fatal: fn(_instance) { [] },
      results: process.new_subject(),
      faults: process.new_subject(),
      failures: process.new_subject(),
    )
    as "manager retains the original custody witness"
  let watch = process.monitor(host.owner(prepared))
  host.begin(prepared)
  assert process.receive(reached, 5000) == Ok(Nil)
  lease_is_held(settings)
  process.kill(host.builder(prepared))
  let assert Ok(release) = process.receive(cleanup, 5000)
    as "surviving custody reaches the held effect cleanup"
  lease_is_held(settings)
  assert host.close(prepared, within_ms: 20) == custody.StillClosing
  process.send(release, cleanup_result)
  case cleanup_result {
    Ok(Nil) -> {
      let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
        process.new_selector()
        |> process.select_specific_monitor(watch, fn(down) { down })
        |> process.selector_receive(5000)
        as "only successful effect drain retires original custody"
      lease_is_released(settings)
    }
    Error(reason) -> {
      assert host.close(prepared, within_ms: 1000)
        == custody.RecoveryBlocked(custody.Failed(custody.Mcp, reason))
      assert process.is_alive(host.owner(prepared))
      lease_is_held(settings)
    }
  }
  process.demonitor_process(watch)
}
