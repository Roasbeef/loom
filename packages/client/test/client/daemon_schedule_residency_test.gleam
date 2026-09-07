//// Schedules belong to resident runtimes, not attached terminals.
//// This fixture uses actual daemon ownership, SQLite and a credited socket,
//// with a scripted provider and an overdue one-shot instead of a fake clock.
//// It proves durable one-shot progress across detach, stop and lazy restart;
//// recurring cursor arithmetic remains covered by the scanner unit tests.

import client/catalog
import client/daemon/main as daemon_main
import client/daemon/manager
import client/daemon/root
import client/daemon/session_socket
import client/daemon_server_test as wire
import client/gateway
import client/internal/ffi_os
import client/jobs
import client/owned_assembly_test
import client/schedule
import client/schedulescan
import client/serve
import client/session_socket_test
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/clock
import core/entry
import core/ids
import core/message
import core/register
import core/tx
import filepath
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import provider/http
import provider/secret
import runtime/api
import session/session
import simplifile
import storage/catalogue
import storage/domain
import storage/storage
import support/internal/ffi_ws
import support/provider as provider_test
import telemetry/log
import weft
import weft/poll

fn settings() {
  let settings = owned_assembly_test.settings()
  let assert Ok(here) = simplifile.current_directory()
    as "the real helper is relative to the client package"
  let provider =
    catalog.gateway(
      settings.catalog,
      transport: provider_test.transport(fn(_, events) {
        process.send(events, http.ResponseStatus(200, []))
        process.send(
          events,
          http.ResponseChunk(bit_array.from_string(
            "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"scheduled\",\"model\":\"test\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n"
            <> "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
            <> "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Scheduled answer.\"}}\n\n"
            <> "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
            <> "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n"
            <> "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
          )),
        )
        process.send(events, http.ResponseEnd)
      }),
      secrets: secret.from_list([#("UNUSED", "fixture-only")]),
      clock: clock.fixed(0),
    )
  serve.Settings(
    ..settings,
    gateway: provider,
    helper_path: here <> "/../../bin/loom-exec",
    schedule_policy: schedule.ModelSchedulesWake,
    jobs_policy: jobs.default_policy,
  )
}

fn start(settings: serve.Settings) {
  let directory = filepath.directory_name(settings.session_path)
  let assert Ok(config) =
    daemon_main.parse(["--state-dir", directory <> "/daemon"])
    as "the root is stable across daemon incarnations"
  let assert Ok(daemon) =
    root.start(
      root.Config(config.state_root, "Owner", 2),
      manager.Assembly(
        fn(selected, sources, owner) {
          serve.build_domain(selected, sources, log.discard(), owner)
        },
        fn(record, selected, services, owner) {
          let assert Ok(id) = ids.parse_session_id(record.id)
            as "the catalogue supplies a canonical identity"
          assert bootstrap.ensure_private_directory(filepath.directory_name(
              selected.memory_path,
            ))
            == Ok(Nil)
          serve.assemble_in_domain(
            serve.Settings(
              ..settings,
              session_path: record.path,
              session_id: record.id,
              workspace: record.workspace,
              base_policy: serve.base_policy(record.workspace),
              domain_paths: Some(serve.DomainPaths(
                selected.memory_path,
                selected.index_path,
              )),
            ),
            id,
            log.discard(),
            owner,
            services,
          )
        },
        serve.instance_children,
      ),
    )
    as "the original root owns actual session and domain resources"
  let assert Ok(serving) =
    daemon_main.listen(config, daemon, fn(request, attachment) {
      session_socket.upgrade(
        daemon,
        request,
        attachment,
        attachment.instance.gateway,
      )
    })
    as "the production authenticated listener starts"
  serving
}

fn await(check: fn() -> Bool) {
  assert poll.until(within: 10_000, every: 5, attempt: fn() {
      case check() {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    == poll.Answered(Nil)
    as "the lifecycle condition settles within its deadline"
}

fn resident(serving: daemon_main.Serving(serve.Instance), id) {
  await(fn() {
    case manager.get(serving.ready.registry, id) {
      Ok(manager.View(status: manager.Resident(_), ..)) -> True
      _ -> False
    }
  })
  let assert Ok(instance) = manager.resolve(serving.ready.registry, id)
    as "a resident session resolves its original runtime"
  instance
}

fn planted(name) {
  schedule.Schedule(
    name: name,
    target: "main",
    owner: schedule.StrandOwned("main"),
    timing: schedule.OneShot(0),
    wake: schedule.WakesIdle,
    body: "scheduled-" <> name,
  )
}

fn config_key(name) {
  schedule.config_key(strand: "main", name: name)
}

fn fired(store, name) {
  storage.get_register(
    store,
    register.FactCustom,
    schedule.fired_key(strand: "main", name: name, occurrence: 0),
  )
}

fn transcript(store) {
  let assert Ok(entries) =
    storage.scan_entries(
      store,
      storage.entry_scan() |> storage.entry_limit(100),
    )
    as "the bounded fixture transcript is readable"
  assert list.length(entries) < 100
    as "the fixture did not silently truncate history"
  entries
}

fn prompts(store, name) {
  transcript(store)
  |> list.filter(fn(item) {
    case item {
      entry.MessageEntry(message: message.UserMessage(content:, ..), ..) ->
        list.any(content, fn(block) {
          case block {
            message.UserText(text, _) ->
              string.contains(text, "scheduled-" <> name)
            _ -> False
          }
        })
      _ -> False
    }
  })
  |> list.length
}

fn completed(store, count) {
  transcript(store)
  |> list.filter(fn(item) {
    case item {
      entry.MessageEntry(message: message.AssistantMessage(..), ..) -> True
      _ -> False
    }
  })
  |> list.length
  == count
}

fn poke(instance: serve.Instance) {
  let assert Some(scanner) = instance.schedulescan
    as "model scheduling keeps the real scanner resident"
  schedulescan.poke(scanner)
}

fn first_phase(
  serving: daemon_main.Serving(serve.Instance),
  settings: serve.Settings,
) {
  let configuration = serving.ready.state_root <> "/maintenance-off.toml"
  assert simplifile.write(
      configuration,
      "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"UNUSED\"\nmodel_id = \"fixture\"\ncontext_window = 1000\nmax_output_tokens = 100\n[roles]\nmain = [\"fixture\"]\n[memory]\ndistill = \"off\"\n",
    )
    == Ok(Nil)
  assert bootstrap.ensure_private_directory(settings.workspace) == Ok(Nil)
  let assert Ok(created) =
    manager.create_scoped(
      serving.ready.registry,
      manager.Creation(
        "schedule-residency",
        settings.workspace,
        "Schedules",
        "",
      ),
      directory: serving.ready.sessions_directory,
      generator: ids.generator(clock.fixed(1), 62),
      scope: domain.SessionOnly,
      configuration:,
    )
    as "the session has explicit isolated paths and no domain maintenance"
  let record = created.registration
  let instance = resident(serving, record.id)
  let assert Ok(bearer) = root.listener_credential(serving.daemon)
    as "the owner credential authenticates only the fixture socket"
  let #(socket, response) =
    wire.connect(
      serving.listener.port,
      bearer,
      "/v2/sessions/" <> record.id <> "/ws",
    )
  assert string.contains(response, "101 Switching Protocols")
  let #(_, transfer) = session_socket_test.begin(socket, record.id)
  let _ = session_socket_test.drain(socket, transfer, 0, [], 32)
  assert gateway.attached(instance.gateway) == 1
  let _ = ffi_ws.tcp_close(socket)
  await(fn() { gateway.attached(instance.gateway) == 0 })

  // No terminal is attached when the scanner admits this first prompt.
  assert api.put_reserved_fact(
      instance.runtime,
      config_key("first"),
      schedule.encode(planted("first")),
    )
    == Ok(Nil)
  poke(instance)
  let store = instance.runtime.session.store
  await(fn() { prompts(store, "first") == 1 && completed(store, 1) })
  let assert Ok(Some(first_mark)) = fired(store, "first")
    as "actual scheduled admission commits its durable occurrence mark"
  assert gateway.attached(instance.gateway) == 0
  let assert Ok(manager.Stopping(_)) =
    manager.stop_session(serving.ready.registry, record.id)
    as "explicit stop begins original custody retirement"
  await(fn() {
    case
      manager.get(serving.ready.registry, record.id),
      manager.summary(serving.ready.registry)
    {
      Ok(manager.View(status: manager.Saved, ..)), Ok(summary) ->
        summary.domain_occupied == 0
      _, _ -> False
    }
  })
  Ok(#(record, first_mark))
}

fn saved_snapshot(record: catalogue.Registration, seed_second) {
  let assert Ok(#(opened, retire)) =
    session.open_sqlite_owned(
      path: record.path,
      owner: "schedule-fixture-offline",
      lease_ttl_ms: 30_000,
      clock: clock.from_function(ffi_os.system_time_ms),
    )
    as "a Saved session releases its original SQLite writer lease"
  let outcomes =
    weft.new([
      fn() {
        case seed_second {
          SeedSecond -> {
            let assert Ok(_) =
              storage.commit(
                opened.store,
                tx.Tx(
                  [
                    tx.SetRegister(
                      register.FactCustom,
                      config_key("second"),
                      register.value(schedule.encode(planted("second"))),
                    ),
                  ],
                  [],
                ),
              )
              as "normal storage commits a second overdue schedule without a runtime"
            Nil
          }
          InspectOnly -> Nil
        }
        assert prompts(opened.store, "first") == 1
        assert prompts(opened.store, "second") == 0
        assert fired(opened.store, "second") == Ok(None)
        Ok(transcript(opened.store))
      },
    ])
    |> weft.deadline(5000)
    |> weft.start
  assert retire() == Ok(Nil)
    as "the offline writer actually retires before any reopen"
  let assert [entries] = weft.values(outcomes)
    as "offline assertions succeeded after cleanup"
  entries
}

type OfflineAction {
  SeedSecond
  InspectOnly
}

fn second_phase(
  serving: daemon_main.Serving(serve.Instance),
  record: catalogue.Registration,
  first_mark,
  saved_entries,
) {
  let assert Ok(#(_, [manager.View(status: manager.Saved, ..)])) =
    manager.page(serving.ready.registry, after: "")
    as "daemon restart and catalogue listing do not recreate a runtime"
  assert manager.resolve(serving.ready.registry, record.id)
    == Error(manager.Unavailable)
  assert saved_snapshot(record, InspectOnly) == saved_entries
    as "neither the previous prompt nor the newly overdue one runs while Saved"
  let assert Ok(manager.Opening(_)) =
    manager.open(serving.ready.registry, record.id)
    as "only explicit open admits the deferred schedule"
  let instance = resident(serving, record.id)
  poke(instance)
  let store = instance.runtime.session.store
  await(fn() { prompts(store, "second") == 1 && completed(store, 2) })
  assert prompts(store, "first") == 1
  assert fired(store, "first") == Ok(Some(first_mark))
    as "the original fired cell including its sequence is preserved"
  let assert Ok(Some(_)) = fired(store, "second")
    as "the deferred schedule commits one new occurrence"
  assert gateway.attached(instance.gateway) == 0
  Ok(Nil)
}

/// Exercises real detach, Saved inactivity and explicit schedule resumption.
///
/// ## Examples
///
/// `scripts/test.sh client --match daemon_schedule_residency` runs this case.
pub fn daemon_schedule_residency_survives_detach_and_lazy_restart_test_() -> EunitTest {
  Timeout(9, fn() {
    let settings = settings()
    let first = start(settings)
    let outcomes =
      weft.new([fn() { first_phase(first, settings) }])
      |> weft.deadline(25_000)
      |> weft.start
    assert root.shutdown(first.daemon, within: 20_000) == Ok(Nil)
      as "the first original root retires even when phase assertions fail"
    let assert [#(record, first_mark)] = weft.values(outcomes)
      as "the detached scheduled run and explicit stop succeeded"
    let saved_entries = saved_snapshot(record, SeedSecond)
    let second = start(settings)
    let resumed =
      weft.new([
        fn() { second_phase(second, record, first_mark, saved_entries) },
      ])
      |> weft.deadline(20_000)
      |> weft.start
    assert root.shutdown(second.daemon, within: 20_000) == Ok(Nil)
      as "the replacement root joins all original session and domain owners"
    assert weft.values(resumed) == [Nil]
      as "residency and durable one-shot progress survive daemon restart"
  })
}
