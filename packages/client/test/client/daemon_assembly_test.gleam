//// The real daemon registry assembles independent SQLite-backed sessions and
//// restores only their catalogue after restart. Assembly barriers make lazy
//// opening and concurrent admission observable without relying on sleeps.
//// This is registry-to-runtime integration, not WebSocket or TUI coverage.

import client/catalog
import client/daemon/domain as domain_service
import client/daemon/lifetime
import client/daemon/manager
import client/history
import client/owned_assembly_test
import client/serve
import core/clock
import core/ids
import core/message
import filepath
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import machine/operation
import provider/http
import provider/secret
import runtime/api
import simplifile
import storage/catalogue
import storage/sqlite
import support/provider as provider_test
import telemetry/log
import weft/poll
import weft/registry as address

type Arrival =
  #(String, process.Subject(Nil))

fn start(
  store: catalogue.Catalogue,
  settings: serve.Settings,
  arrivals: process.Subject(Arrival),
  domains: process.Subject(List(#(String, process.Pid))),
  epoch: String,
) -> lifetime.Lifetime(serve.Instance) {
  let assert Ok(daemon) =
    lifetime.start(
      store,
      manager.Assembly(
        domain_build: fn(selected, sources, owner) {
          let assert Ok(Nil) =
            bootstrap.ensure_private_directory(filepath.directory_name(
              selected.index_path,
            ))
            as "the domain owns its projection directory"
          let assert Ok(services) =
            domain_service.build(
              domain_service.Config(
                history: history.SharedConfig(
                  selected.index_path,
                  sources,
                  5000,
                  100,
                ),
                maintenance: fn(_) { Ok(None) },
              ),
              owner,
            )
            as "real shared history starts without external maintenance"
          process.send(domains, domain_service.children(services))
          Ok(services)
        },
        build: fn(record, selected, services, owner) {
          let permit = process.new_subject()
          process.send(arrivals, #(record.id, permit))
          let assert Ok(Nil) = process.receive(permit, 5000)
            as "the test releases assembly within its deadline"
          let assert Ok(id) = ids.parse_session_id(record.id)
            as "the catalogue supplies a canonical reserved identity"
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
            ),
            id,
            log.discard(),
            owner,
            services,
          )
        },
        fatal: serve.instance_children,
      ),
      epoch:,
      limit: 2,
    )
    as "the outer lifetime owns the real registry"
  daemon
}

fn create(
  registry: manager.Manager(serve.Instance),
  settings: serve.Settings,
  seed: Int,
) -> manager.View {
  let request =
    manager.Creation(
      request_key: "request-" <> string.inspect(seed),
      workspace: settings.workspace,
      name: "session " <> string.inspect(seed),
      configuration: "",
    )
  let assert Ok(view) =
    manager.create(
      registry,
      request,
      directory: filepath.directory_name(settings.session_path) <> "/sessions",
      generator: ids.generator(clock.fixed(at: 1_700_000_000_000), seed:),
    )
    as "creation reserves one identity before beginning assembly"
  view
}

fn resident(
  registry: manager.Manager(serve.Instance),
  id: String,
  operation: String,
) -> serve.Instance {
  let answer =
    poll.until(within: 10_000, every: 5, attempt: fn() {
      case manager.get(registry, id) {
        Ok(manager.View(status: manager.Resident(found), ..))
          if found == operation
        -> poll.Done(Nil)
        Ok(manager.View(status: manager.Opening(_), ..)) -> poll.Retry
        other -> poll.Fail(string.inspect(other))
      }
    })
  assert answer == poll.Answered(Nil)
  let assert Ok(instance) = manager.resolve(registry, id)
    as "a resident operation resolves its sole instance"
  instance
}

fn stop(daemon: lifetime.Lifetime(serve.Instance)) -> Nil {
  let monitor = process.monitor(lifetime.witness(daemon))
  lifetime.shutdown(daemon)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(10_000)
    as "the original outer witness confirms every instance drained"
  assert !process.is_alive(manager.pid(lifetime.registry(daemon)))
}

fn assert_persisted(record: catalogue.Registration) -> Nil {
  let assert Ok(#(Some(identity), _parent)) = sqlite.identity(record.path)
    as "the real session database has its durable identity"
  assert identity == record.id
}

fn complete_turn(instance: serve.Instance) -> Nil {
  let prompt =
    message.UserMessage(
      content: [message.UserText("finish this turn", text_signature: None)],
      timestamp: 0,
      origin: None,
    )
  let assert Ok(op) = api.prompt(instance.runtime, [prompt])
    as "the real runtime accepts a provider turn"
  let assert Ok(operation.RunLastResult(outcome: operation.RunCompleted(_), ..)) =
    api.await_result(instance.runtime, op, within_ms: 5000)
    as "the production provider wiring durably completes the turn"
  Nil
}

fn completed_settings(requests: process.Subject(Nil)) -> serve.Settings {
  let settings = owned_assembly_test.settings()
  let gateway =
    catalog.gateway(
      settings.catalog,
      transport: provider_test.transport(fn(_request, events) {
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
            "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"daemon\",\"model\":\"test\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n"
            <> "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
            <> "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"finished\"}}\n\n"
            <> "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n"
            <> "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
          )),
        )
        process.send(events, http.ResponseEnd)
      }),
      secrets: secret.from_list([#("UNUSED", "fixture-key")]),
      clock: clock.fixed(at: 0),
    )
  serve.Settings(..settings, gateway:)
}

pub fn real_registry_restores_catalogue_then_lazily_opens_one_session_test() {
  process.trap_exits(True)
  let requests = process.new_subject()
  let settings = completed_settings(requests)
  let root = filepath.directory_name(settings.session_path)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the daemon owns its metadata directory"
  let path = root <> "/catalogue.db"
  let assert Ok(store) = catalogue.open(path) as "real catalogue opens"
  let arrivals = process.new_subject()
  let domains = process.new_subject()
  let daemon = start(store, settings, arrivals, domains, "before-restart")
  let registry = lifetime.registry(daemon)
  let assert manager.View(first, manager.Opening(first_op)) =
    create(registry, settings, 1)
    as "the first reserved session begins opening"
  let assert manager.View(second, manager.Opening(second_op)) =
    create(registry, settings, 2)
    as "the second reserved session begins opening"
  assert first.id != second.id
  assert first.path != second.path
  let assert Ok(#(_, permit_one)) = process.receive(arrivals, 1000)
    as "first reserved assembly arrives"
  let assert Ok(#(_, permit_two)) = process.receive(arrivals, 1000)
    as "second reserved assembly arrives independently"
  process.send(permit_one, Nil)
  process.send(permit_two, Nil)

  let first_instance = resident(registry, first.id, first_op)
  let second_instance = resident(registry, second.id, second_op)
  let assert Ok([#("history", shared_history)]) = process.receive(domains, 1000)
    as "two real instances share one original history coordinator"
  assert process.receive(domains, 0) == Error(Nil)
  assert ids.session_id_to_string(api.session_id(first_instance.runtime))
    == first.id
  assert ids.session_id_to_string(api.session_id(second_instance.runtime))
    == second.id
  assert address.owner(first_instance.namespace)
    != address.owner(second_instance.namespace)
  complete_turn(first_instance)
  complete_turn(second_instance)
  assert process.receive(requests, 1000) == Ok(Nil)
  assert process.receive(requests, 1000) == Ok(Nil)
  let assert Ok(_) = manager.set_default(registry, first.workspace, first.id)
    as "the workspace default is persisted separately from liveness"
  let assert Ok(_) = manager.stop_session(registry, first.id)
    as "one instance can retire while its peer retains the domain"
  assert poll.until(within: 5000, every: 5, attempt: fn() {
      case manager.get(registry, first.id) {
        Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(string.inspect(error))
      }
    })
    == poll.Answered(Nil)
  assert process.is_alive(shared_history)
  stop(daemon)
  assert !process.is_alive(shared_history)
  assert !process.is_alive(first_instance.runtime.tree.supervisor)
  assert !process.is_alive(second_instance.runtime.tree.supervisor)
  assert catalogue.close(store) == Ok(Nil)
  assert_persisted(first)
  assert_persisted(second)

  // A fresh registry must not enter assembly while restoring metadata or
  // answering listing/default queries. Thus no effects can acquire here.
  let assert Ok(restored) = catalogue.open(path) as "catalogue survives restart"
  let restarted = start(restored, settings, arrivals, domains, "after-restart")
  let registry = lifetime.registry(restarted)
  let saved_first = catalogue.Registration(..first, state: catalogue.Saved)
  let saved_second = catalogue.Registration(..second, state: catalogue.Saved)
  assert manager.get(registry, first.id)
    == Ok(manager.View(saved_first, manager.Saved))
  assert manager.get(registry, second.id)
    == Ok(manager.View(saved_second, manager.Saved))
  assert manager.workspace_default(registry, first.workspace)
    == Ok(manager.View(saved_first, manager.Saved))
  let assert Ok(#(_revision, views)) = manager.page(registry, after: "")
    as "listing restores both saved metadata records"
  assert list.length(views) == 2
  assert list.contains(views, manager.View(saved_first, manager.Saved))
  assert list.contains(views, manager.View(saved_second, manager.Saved))
  assert manager.resolve(registry, first.id) == Error(manager.Unavailable)
  assert process.receive(arrivals, 0) == Error(Nil)
  assert process.receive(requests, 0) == Error(Nil)
  assert process.receive(domains, 0) == Error(Nil)

  // Hold the admitted builder while two independent callers open the same
  // identity. Both must observe one operation and only one assembly arrival.
  let answers = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(answers, manager.open(registry, first.id))
    })
  let _ =
    process.spawn_unlinked(fn() {
      process.send(answers, manager.open(registry, first.id))
    })
  let assert Ok(Ok(manager.Opening(reopened))) = process.receive(answers, 1000)
    as "first concurrent caller admits one new incarnation"
  assert process.receive(answers, 1000) == Ok(Ok(manager.Opening(reopened)))
  assert reopened != first_op
  let assert Ok(#(opened_id, release)) = process.receive(arrivals, 1000)
    as "the explicit open reaches assembly exactly once"
  assert opened_id == first.id
  assert process.receive(arrivals, 0) == Error(Nil)
  process.send(release, Nil)
  let reopened_instance = resident(registry, first.id, reopened)
  let assert Ok([#("history", reopened_history)]) =
    process.receive(domains, 1000)
    as "explicit admission creates a fresh original history owner"
  assert reopened_history != shared_history
  assert api.session_id(reopened_instance.runtime)
    == api.session_id(first_instance.runtime)
  assert reopened_instance.runtime.tree.supervisor
    != first_instance.runtime.tree.supervisor
  assert manager.get(registry, second.id)
    == Ok(manager.View(saved_second, manager.Saved))
  assert manager.resolve(registry, second.id) == Error(manager.Unavailable)
  complete_turn(reopened_instance)
  assert process.receive(requests, 1000) == Ok(Nil)
  stop(restarted)
  assert !process.is_alive(reopened_history)
  assert catalogue.close(restored) == Ok(Nil)
  process.trap_exits(False)
}
