//// Joined daemon containment over real roots, session runtimes, and SQLite.
//// The provider transport is scripted but retains an original monitorable
//// owner. This tests runtime drain, not a network provider or WebSocket client.
//// A managed test scope retains the root before readiness, including when an
//// assertion crashes. The parked transport has a separate finite safety exit;
//// only an explicitly requested release can satisfy the success assertions.

import client/catalog
import client/daemon/domain as domain_service
import client/daemon/manager
import client/daemon/root
import client/history
import client/internal/ffi_os
import client/internal/instance_owner as custody
import client/owned_assembly_test
import client/serve
import core/clock
import core/ids
import core/message
import filepath
import gleam/bit_array
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import machine/operation
import provider/http
import provider/secret
import runtime/api
import session/session
import storage/catalogue
import storage/domain
import storage/sqlite
import support/provider as provider_test
import telemetry/log
import weft
import weft/actor
import weft/poll

type Release {
  ExplicitRelease
  SafetyRelease
}

type Started =
  #(process.Pid, process.Subject(Release))

fn held_transport(
  started: process.Subject(Started),
  cancelled: process.Subject(Nil),
  released: process.Subject(Release),
) -> http.Transport {
  http.Transport(prepare_streaming: fn(_request, _events) {
    let assert Ok(owner) =
      actor.new(Nil)
      |> actor.on_message(fn(_state, reason) {
        process.send(released, reason)
        actor.stop()
      })
      |> actor.idle_timeout(15_000, SafetyRelease)
      |> actor.unlinked
      |> actor.start
      as "the original transport owner is parked before publication"
    Ok(
      http.PreparedRequest(
        running: http.RunningRequest(owner: owner.pid, cancel: fn() {
          process.send(cancelled, Nil)
        }),
        begin: fn() { process.send(started, #(owner.pid, owner.data)) },
      ),
    )
  })
}

fn completed_transport(requests: process.Subject(Nil)) -> http.Transport {
  provider_test.transport(fn(_request, events) {
    process.send(requests, Nil)
    process.send(
      events,
      http.ResponseStatus(200, [
        #("content-type", "text/event-stream"),
      ]),
    )
    process.send(
      events,
      http.ResponseChunk(bit_array.from_string(
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"containment\",\"model\":\"test\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n"
        <> "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
        <> "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"peer settled\"}}\n\n"
        <> "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n"
        <> "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
      )),
    )
    process.send(events, http.ResponseEnd)
  })
}

fn assembly(
  settings: serve.Settings,
  held: http.Transport,
  completed: http.Transport,
  owners: process.Subject(#(String, custody.Owner)),
) -> manager.Assembly(serve.Instance) {
  manager.Assembly(
    domain_build: fn(selected, sources, owner) {
      let assert Ok(Nil) =
        bootstrap.ensure_private_directory(filepath.directory_name(
          selected.index_path,
        ))
        as "the independent projection directory exists"
      domain_service.build(
        domain_service.Config(
          history: history.SharedConfig(selected.index_path, sources, 5000, 100),
          maintenance: fn(_) { Ok(None) },
        ),
        owner,
      )
    },
    build: fn(record, selected, services, owner) {
      process.send(owners, #(record.id, owner))
      let transport = case record.name {
        "A" -> held
        _ -> completed
      }
      let gateway =
        catalog.gateway(
          settings.catalog,
          transport:,
          secrets: secret.from_list([#("UNUSED", "fixture-key")]),
          clock: clock.fixed(at: 0),
        )
      let assert Ok(identity) = ids.parse_session_id(record.id)
        as "the reserved identity is canonical"
      serve.assemble_in_domain(
        serve.Settings(
          ..settings,
          session_path: record.path,
          session_id: record.id,
          workspace: record.workspace,
          domain_paths: Some(serve.DomainPaths(
            selected.memory_path,
            selected.index_path,
          )),
          base_policy: serve.base_policy(record.workspace),
          gateway:,
        ),
        identity,
        log.discard(),
        owner,
        services,
      )
    },
    fatal: serve.instance_children,
  )
}

fn create(
  ready: root.Ready(serve.Instance),
  workspace: String,
  name: String,
  seed: Int,
) -> catalogue.Registration {
  let assert Ok(manager.View(record, manager.Opening(_))) =
    manager.create_scoped(
      ready.registry,
      manager.Creation(name, workspace, name, ""),
      directory: ready.sessions_directory,
      generator: ids.generator(clock.fixed(at: 1_700_000_000_000), seed:),
      scope: domain.SessionOnly,
      configuration: "",
    )
    as "admission reserves an independent session-only domain"
  record
}

fn resident(registry: manager.Manager(serve.Instance), id: String) {
  let assert poll.Answered(instance) =
    poll.until(within: 5000, every: 5, attempt: fn() {
      case manager.resolve(registry, id) {
        Ok(instance) -> poll.Done(instance)
        Error(manager.Unavailable) -> poll.Retry
        Error(error) -> poll.Fail(string.inspect(error))
      }
    })
    as "the real session assembly becomes resident"
  instance
}

fn prompt(instance: serve.Instance) {
  api.prompt(instance.runtime, [
    message.UserMessage(
      content: [message.UserText("finish this turn", text_signature: None)],
      timestamp: 0,
      origin: None,
    ),
  ])
}

fn normal(watch: process.Monitor) {
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(5000)
    as "the original resource, not a timeout or replacement, retired normally"
  Nil
}

fn lease_held(path: String) -> Bool {
  case
    session.open_sqlite_owned(
      path:,
      owner: "containment-probe",
      lease_ttl_ms: 60_000,
      clock: clock.from_function(ffi_os.system_time_ms),
    )
  {
    Error(session.SqliteOpenFailed(sqlite.LeaseHeld(..))) -> True
    Error(_) -> False

    // Even a failing assertion must not abandon an unexpectedly admitted probe.
    Ok(#(_session, retire)) -> {
      let _ = retire()
      False
    }
  }
}

fn exercise(ledger: weft.Ledger) -> Result(Nil, String) {
  let settings = owned_assembly_test.settings()
  let started = process.new_subject()
  let cancelled = process.new_subject()
  let released = process.new_subject()
  let requests = process.new_subject()
  let owners = process.new_subject()
  let assert Ok(daemon) =
    root.start(
      root.Config(
        filepath.directory_name(settings.session_path) <> "/daemon",
        "Containment owner",
        2,
      ),
      assembly(
        settings,
        held_transport(started, cancelled, released),
        completed_transport(requests),
        owners,
      ),
    )
    as "the real root is prepared without effects"
  let assert weft.Adopted =
    weft.adopt(ledger, owner: root.pid(daemon), cancel: fn() {
      root.request_shutdown(daemon)
    })
    as "managed cleanup retains the original root before readiness"
  let assert Ok(ready) = root.ready(daemon, within: 10_000)
    as "catalogue and manager ownership are established"

  let first = create(ready, settings.workspace, "A", 781)
  let a = resident(ready.registry, first.id)
  let assert Ok(#(first_id, owner)) = process.receive(owners, 1000)
    as "the test observes A's existing published custody"
  assert first_id == first.id
  let second = create(ready, settings.workspace, "B", 782)
  let b = resident(ready.registry, second.id)
  let assert Ok(#(second_id, _)) = process.receive(owners, 1000)
    as "B has independently published custody"
  assert second_id == second.id
  assert a.storage_owner != b.storage_owner

  let assert Ok(_) = prompt(a) as "A starts a real runtime operation"
  let assert Ok(#(provider, release)) = process.receive(started, 5000)
    as "the provider's original owner is retained before the request begins"
  let provider_watch = process.monitor(provider)
  let storage_watch = process.monitor(a.storage_owner)
  let owner_watch = process.monitor(custody.owner(owner))
  let assert Ok(manager.Stopping(_)) =
    manager.stop_session(ready.registry, first.id)
    as "stopping A requests drain without claiming it completed"
  assert custody.close(owner, within_ms: 20) == custody.StillClosing
  assert process.receive(cancelled, 5000) == Ok(Nil)

  let assert Ok(operation_id) = prompt(b)
    as "B remains usable while A's original provider has not retired"
  let assert Ok(operation.RunLastResult(outcome: operation.RunCompleted(_), ..)) =
    api.await_result(b.runtime, operation_id, within_ms: 5000)
    as "B's actual provider turn settles through the production runtime"
  assert process.receive(requests, 1000) == Ok(Nil)
  assert process.is_alive(provider)
  assert process.is_alive(a.storage_owner)
  assert process.is_alive(custody.owner(owner))
  assert lease_held(first.path)
  let assert Error(_) = manager.open(ready.registry, first.id)
    as "A cannot reopen while original drain remains unconfirmed"
  assert process.receive(released, 0) == Error(Nil)

  // The safety timeout is only failure cleanup. It cannot satisfy this proof:
  // every blocked-state assertion precedes release and its cause is checked.
  process.send(release, ExplicitRelease)
  assert process.receive(released, 1000) == Ok(ExplicitRelease)
  normal(provider_watch)
  normal(storage_watch)
  normal(owner_watch)
  assert poll.until(within: 5000, every: 5, attempt: fn() {
      case
        manager.get(ready.registry, first.id),
        manager.summary(ready.registry)
      {
        Ok(manager.View(status: manager.Saved, ..)), Ok(summary)
          if summary.domain_occupied == 1
        -> poll.Done(Nil)
        _, _ -> poll.Retry
      }
    })
    == poll.Answered(Nil)
  let assert Ok(manager.Opening(_)) = manager.open(ready.registry, first.id)
    as "only confirmed session and private-domain retirement permit reopening"
  let replacement = resident(ready.registry, first.id)
  assert replacement.storage_owner != a.storage_owner
  assert api.session_id(replacement.runtime) == api.session_id(a.runtime)
  assert root.shutdown(daemon, within: 10_000) == Ok(Nil)
  Ok(Nil)
}

pub fn blocked_provider_retirement_preserves_peer_progress_and_lease_test() {
  let running =
    weft.new_prepared([weft.managed(exercise)])
    |> weft.deadline(30_000)
    |> weft.start_detached
  let assert weft.PulledOutcome(weft.Completed(0, Nil)) =
    weft.pull(running, within: 40_000)
    as "the managed integration body succeeds only after original root drain"
  assert weft.pull(running, within: 1000) == weft.AllDelivered
}
