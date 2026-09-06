//// Root ownership tests use real private files, SQLite, and kernel locks.
//// Assembly remains controlled so a test can separate requested drain from
//// its original witness. Every wait has an explicit finite reporting budget.

import broker/token
import client/daemon/domain as domain_service
import client/daemon/manager
import client/daemon/root
import client/internal/instance_owner as custody
import core/clock
import core/ids
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/string
import host/bootstrap
import simplifile
import storage/catalogue
import storage/domain
import weft/poll

fn directory(name: String) {
  let path =
    "build/test_db/daemon-root-"
    <> name
    <> "-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(Nil) = bootstrap.ensure_private_directory(path)
    as "a distinct private fixture directory exists"
  let assert Ok(canonical) = bootstrap.canonical_directory(path)
    as "fixture paths are canonical"
  canonical
}

fn configuration(path: String) {
  root.Config(state_root: path, owner_display_name: "Local owner", capacity: 2)
}

fn assembly(
  build: fn(catalogue.Registration, custody.Owner) -> Result(String, String),
) {
  manager.Assembly(
    domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
    build: fn(record, _domain, _services, owner) { build(record, owner) },
    fatal: fn(_) { [] },
  )
}

fn inert() {
  assembly(fn(record, _) { Ok(record.id) })
}

fn start(path: String, assembly: manager.Assembly(String)) {
  let assert Ok(daemon) = root.start(configuration(path), assembly)
    as "root preparation returns an inert owned handle"
  let assert Ok(ready) = root.ready(daemon, within: 10_000)
    as "root boot establishes stable ownership before readiness"
  #(daemon, ready)
}

fn saved(path: String) {
  let assert Ok(store) = catalogue.open(path <> "/catalogue.db")
    as "fixture opens metadata before any root exists"
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(0), 1))
  let id = ids.session_id_to_string(id)
  let record =
    catalogue.Registration(
      id:,
      path: path <> "/sessions/" <> id <> ".db",
      workspace: path,
      name: "restored",
      configuration: "",
      created_at: 0,
      request_key: "saved",
      state: catalogue.Reserved,
    )
  // Explicit opens require the same durable domain mapping as production
  // creation, even though this fixture's domain owns no native resources.
  let selected =
    domain.Domain(
      domain.key(domain.WorkspacePrivate, record.workspace, record.id),
      domain.WorkspacePrivate,
      record.workspace,
      "",
      path <> "/domain/memory.db",
      path <> "/domain/search.db",
    )
  assert domain.reserve_session(store, record, selected) == Ok(record)
  let assert Ok(record) = catalogue.confirm(store, record.id)
    as "fixture marks metadata saved without creating a conversation file"
  assert catalogue.close(store) == Ok(Nil)
  record
}

fn wait_down(watch: process.Monitor) {
  let assert Ok(down) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(5000)
    as "the original process monitor settles within the test budget"
  down
}

fn released_lock(path: String) {
  let assert poll.Answered(lock) =
    poll.until(within: 2000, every: 5, attempt: fn() {
      case bootstrap.try_launch_lock(path <> "/daemon.lock") {
        Ok(lock) -> poll.Done(lock)
        Error("busy") -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })
    as "kernel lock release becomes observable"
  bootstrap.release_launch_lock(lock)
}

pub fn restored_catalogue_is_ready_without_opening_any_session_test() {
  let path = directory("restore")
  let record = saved(path)
  let builds = process.new_subject()
  let #(daemon, ready) =
    start(
      path,
      assembly(fn(record, _) {
        process.send(builds, record.id)
        Ok(record.id)
      }),
    )
  assert ready.state_root == path
  assert ready.sessions_directory == path <> "/sessions"
  assert string.length(ready.epoch) == 64
  assert manager.get(ready.registry, record.id)
    == Ok(manager.View(record, manager.Saved))
  assert process.receive(builds, 0) == Error(Nil)
  assert simplifile.is_file(record.path) == Ok(False)
  assert bootstrap.try_launch_lock(path <> "/daemon.lock") == Error("busy")
  assert root.shutdown(daemon, within: 5000) == Ok(Nil)
  released_lock(path)
}

pub fn durable_token_and_owner_survive_root_restart_test() {
  let path = directory("restart")
  let #(first, first_ready) = start(path, inert())
  let assert Ok(first_token) = root.listener_credential(first)
    as "only the explicit listener capability returns a credential"
  assert string.length(first_token) == 64
  assert root.shutdown(first, within: 5000) == Ok(Nil)
  released_lock(path)
  let #(second, second_ready) = start(path, inert())
  let assert Ok(second_token) = root.listener_credential(second)
    as "restart rereads the private durable token"
  assert first_token == second_token
  assert first_ready.owner == second_ready.owner
  assert first_ready.epoch != second_ready.epoch
  assert root.shutdown(second, within: 5000) == Ok(Nil)
}

pub fn missing_or_malformed_owner_token_never_resets_identity_test() {
  let path = directory("missing-token")
  let #(first, _) = start(path, inert())
  assert root.shutdown(first, within: 5000) == Ok(Nil)
  released_lock(path)
  assert simplifile.delete_file(path <> "/owner.token") == Ok(Nil)
  let assert Ok(missing) = root.start(configuration(path), inert())
    as "the caller retains partial-startup cleanup ownership"
  let assert Error(_) = root.ready(missing, within: 5000)
    as "an existing owner does not mint a replacement for a lost token"
  assert !bootstrap.path_exists(path <> "/owner.token")
  assert root.shutdown(missing, within: 5000) == Ok(Nil)
  released_lock(path)

  assert bootstrap.atomic_write_private(path <> "/owner.token", "malformed")
    == Ok(Nil)
  let assert Ok(malformed) = root.start(configuration(path), inert())
    as "malformed token startup remains owned"
  let assert Error(_) = root.ready(malformed, within: 5000)
    as "malformed private tokens fail closed"
  assert root.shutdown(malformed, within: 5000) == Ok(Nil)
  assert bootstrap.read_private_bounded(path <> "/owner.token", 64)
    == Ok(<<"malformed":utf8>>)
}

// Readiness is a bounded query and nothing else. It is asked on the
// unauthenticated HTTP path before a bearer is even read, and again on every
// inbound session frame, both with a one-second budget — and it answered its
// own timeout by casting `Stop`, which drains the whole daemon. A caller's
// budget stops the caller's wait; the server's cleanup belongs to `main`,
// which calls `shutdown` itself when startup readiness never arrives.
pub fn a_timed_out_readiness_query_leaves_the_root_serving_test() {
  let path = directory("ready-timeout")
  let assert Ok(daemon) = root.start(configuration(path), inert())
    as "root preparation returns an inert owned handle"

  // The first readiness request starts the ladder and is postponed until the
  // root serves, so a one-millisecond budget cannot be answered inside it —
  // the shortest honest way to make a caller's wait expire against a root that
  // is perfectly healthy.
  assert root.ready(daemon, within: 1) == Error("daemon root request timed out")

  let assert Ok(ready) = root.ready(daemon, within: 10_000)
    as "an expired caller budget does not retire the root it asked"
  assert ready.state_root == path
  assert bootstrap.try_launch_lock(path <> "/daemon.lock") == Error("busy")
  assert root.shutdown(daemon, within: 5000) == Ok(Nil)
  released_lock(path)
}

pub fn second_root_cannot_take_the_live_lifetime_lock_test() {
  let path = directory("exclusive")
  let #(first, _) = start(path, inert())
  let assert Ok(second) = root.start(configuration(path), inert())
    as "a competing root may prepare but cannot claim ownership"
  assert root.ready(second, within: 5000) == Error("busy")
  assert root.shutdown(second, within: 5000) == Ok(Nil)
  let assert Ok(_) = root.ready(first, within: 1000)
    as "failed competitor does not disturb the original owner"
  assert root.shutdown(first, within: 5000) == Ok(Nil)
}

fn draining_assembly(arrivals: process.Subject(process.Subject(Nil))) {
  assembly(fn(record, owner) {
    let assert Ok(Nil) =
      custody.publish(owner, custody.Storage, fn() {
        let permit = process.new_subject()
        process.send(arrivals, permit)
        let assert Ok(Nil) = process.receive(permit, 5000)
          as "the test eventually allows retained cleanup to finish"
        Ok(Nil)
      })
      as "cleanup is published before assembly returns"
    Ok(record.id)
  })
}

fn opened(ready: root.Ready(String), record: catalogue.Registration) {
  let assert Ok(manager.Opening(_)) = manager.open(ready.registry, record.id)
    as "authorized explicit opening begins the controlled assembly"
  let assert poll.Answered(Nil) =
    poll.until(within: 2000, every: 1, attempt: fn() {
      case manager.resolve(ready.registry, record.id) {
        Ok(_) -> poll.Done(Nil)
        Error(_) -> poll.Retry
      }
    })
    as "assembly is resident before shutdown"
}

pub fn shutdown_timeout_preserves_lock_until_original_drain_test() {
  let path = directory("drain")
  let record = saved(path)
  let arrivals = process.new_subject()
  let #(daemon, ready) = start(path, draining_assembly(arrivals))
  opened(ready, record)
  let #(http, pending_upgrade) = acquired(daemon, root.Operator)
  let http_watch = process.monitor(http)
  let watch = process.monitor(root.pid(daemon))
  assert root.shutdown(daemon, within: 20)
    == Error("daemon root request timed out")
  let assert Ok(permit) = process.receive(arrivals, 1000)
    as "shutdown requested the already-published cleanup"
  assert bootstrap.try_launch_lock(path <> "/daemon.lock") == Error("busy")
  let assert Error(_) = root.ready(daemon, within: 1000)
    as "draining is not readiness"
  assert wait_down(http_watch).reason == process.Killed
  let assert Error(_) = root.acquire(daemon, root.Control, within: 1000)
    as "draining refuses new parser reservations"
  let assert Error(_) = root.transfer(daemon, pending_upgrade, within: 1000)
    as "an initializer cannot transfer admission after shutdown starts"
  process.send(permit, Nil)
  assert wait_down(watch).reason == process.Normal
  released_lock(path)
}

pub fn caller_death_requests_drain_without_releasing_lock_early_test() {
  let path = directory("caller")
  let record = saved(path)
  let arrivals = process.new_subject()
  let published = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      let #(daemon, ready) = start(path, draining_assembly(arrivals))
      opened(ready, record)
      process.send(published, daemon)
      process.sleep_forever()
    })
  let assert Ok(daemon) = process.receive(published, 10_000)
    as "the original caller publishes its root for the death test"
  let watch = process.monitor(root.pid(daemon))
  process.kill(caller)
  let assert Ok(permit) = process.receive(arrivals, 1000)
    as "caller DOWN requests the same transitive drain"
  assert bootstrap.try_launch_lock(path <> "/daemon.lock") == Error("busy")
  process.send(permit, Nil)
  assert wait_down(watch).reason == process.Normal
  released_lock(path)
}

pub fn lost_aggregate_proof_blocks_readiness_and_retains_lock_test() {
  let path = directory("proof-loss")
  let #(daemon, ready) = start(path, inert())
  process.kill(manager.pid(ready.registry))
  let assert poll.Answered(Nil) =
    poll.until(within: 2000, every: 1, attempt: fn() {
      case root.ready(daemon, within: 1000) {
        Error(_) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
      }
    })
    as "lost aggregate proof removes readiness"
  let assert Error(_) = root.shutdown(daemon, within: 1000)
    as "missing original proof never becomes a successful close"
  assert bootstrap.try_launch_lock(path <> "/daemon.lock") == Error("busy")

  // Deliberately exercise the documented boundary, not a production recovery:
  // KILL discards the lock port while this BEAM VM still lives. The eventual
  // launcher must refuse replacement using its OS-process identity fence.
  let watch = process.monitor(root.pid(daemon))
  process.kill(root.pid(daemon))
  assert wait_down(watch).reason == process.Killed
  released_lock(path)
  assert root.ready(daemon, within: 1000) == Error("daemon root is unavailable")
  let assert Error(_) = root.shutdown(daemon, within: 1000)
    as "a dead root cannot supply fresh retirement proof"
}

pub fn symbolic_link_state_root_is_refused_before_metadata_creation_test() {
  let target = directory("target")
  let parent = directory("symlink")
  let alias = parent <> "/alias"
  assert simplifile.create_symlink(to: target, from: alias) == Ok(Nil)
  let assert Ok(daemon) = root.start(configuration(alias), inert())
    as "inert root creation does not touch an unverified path"
  let assert Error(_) = root.ready(daemon, within: 5000)
    as "the final state-directory symlink is rejected"
  assert !bootstrap.path_exists(target <> "/catalogue.db")
  assert root.shutdown(daemon, within: 5000) == Ok(Nil)
}

fn acquired(daemon: root.Root(String), class: root.ConnectionClass) {
  let arrivals = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      process.send(arrivals, root.acquire(daemon, class, within: 1000))
      process.sleep_forever()
    })
  let assert Ok(Ok(permit)) = process.receive(arrivals, 2000)
    as "the HTTP handler reserves before upgrade"
  #(owner, permit)
}

fn transferred(daemon: root.Root(String), permit: root.Permit) {
  let arrivals = process.new_subject()
  let websocket =
    process.spawn_unlinked(fn() {
      process.send(arrivals, root.transfer(daemon, permit, within: 1000))
      process.sleep_forever()
    })
  let assert Ok(Ok(Nil)) = process.receive(arrivals, 2000)
    as "the actual WebSocket initializer obtains transfer acknowledgement"
  websocket
}

pub fn admitted_connection_count_is_bounded_and_shutdown_joins_owners_test() {
  let #(daemon, _) = start(directory("connection-cap"), inert())
  let slots =
    list.map(list.repeat(Nil, root.max_connections), fn(_) {
      let #(owner, permit) = acquired(daemon, root.Control)
      #(owner, permit, process.monitor(owner))
    })
  let assert Error(_) = root.acquire(daemon, root.Control, within: 1000)
    as "a sixty-fifth connection is refused before parser activation"
  assert root.shutdown(daemon, within: 5000) == Ok(Nil)
  list.each(slots, fn(slot) {
    assert wait_down(slot.2).reason == process.Killed
  })
}

pub fn transferred_weight_survives_http_death_and_late_release_test() {
  let #(daemon, _) = start(directory("connection-weight"), inert())
  let #(http, permit) = acquired(daemon, root.Operator)
  let websocket = transferred(daemon, permit)
  let watch = process.monitor(websocket)
  root.release(daemon, permit)
  process.kill(http)
  let _others =
    list.map(list.repeat(Nil, 3), fn(_) { acquired(daemon, root.Operator) })
  let assert Error(_) = root.acquire(daemon, root.Operator, within: 1000)
    as "late HTTP cancellation cannot free a live WebSocket's 40MiB charge"
  let assert Error(_) = root.acquire(daemon, root.Observer, within: 1000)
    as "four operators fill the entire 160MiB accounted payload budget"
  let assert Error(_) = root.acquire(daemon, root.Control, within: 1000)
    as "even control cannot exceed the aggregate limit"
  process.kill(websocket)
  assert wait_down(watch).reason == process.Killed
  let assert poll.Answered(replacement) =
    poll.until(within: 2000, every: 1, attempt: fn() {
      case root.acquire(daemon, root.Operator, within: 1000) {
        Ok(permit) -> poll.Done(permit)
        Error(_) -> poll.Retry
      }
    })
    as "actual WebSocket DOWN releases exactly its weight"
  root.release(daemon, replacement)
  assert root.shutdown(daemon, within: 5000) == Ok(Nil)
}

pub fn observer_delivery_allowance_is_charged_before_upgrade_test() {
  let #(daemon, _) = start(directory("observer-weight"), inert())
  let _observers =
    list.map(list.repeat(Nil, 19), fn(_) { acquired(daemon, root.Observer) })
  let assert Error(_) = root.acquire(daemon, root.Observer, within: 1000)
    as "twenty observers exceed 160MiB with delivery payload included"
  let assert Ok(control) = root.acquire(daemon, root.Control, within: 1000)
    as "nineteen observers still leave room for bounded control traffic"
  root.release(daemon, control)
  assert root.shutdown(daemon, within: 5000) == Ok(Nil)
}

pub fn multiplayer_operators_observer_and_controls_fit_budget_test() {
  let #(daemon, _) = start(directory("multiplayer-budget"), inert())
  let _operators =
    list.map(list.repeat(Nil, 3), fn(_) { acquired(daemon, root.Operator) })
  let _observer = acquired(daemon, root.Observer)
  let _controls =
    list.map(list.repeat(Nil, 4), fn(_) { acquired(daemon, root.Control) })
  let assert Error(_) = root.acquire(daemon, root.Operator, within: 1000)
    as "another full-size operator exceeds the remaining aggregate capacity"
  assert root.shutdown(daemon, within: 5000) == Ok(Nil)
}

pub fn duplicate_pid_and_timed_out_requests_do_not_leak_reservations_test() {
  let #(daemon, _) = start(directory("connection-cancel"), inert())
  let assert Ok(first) = root.acquire(daemon, root.Observer, within: 1000)
    as "the calling HTTP handler obtains its first permit"
  let assert Error(_) = root.acquire(daemon, root.Operator, within: 1000)
    as "one PID cannot accumulate duplicate reservations or escalate its class"
  root.release(daemon, first)
  list.each(list.repeat(Nil, 16), fn(_) {
    case root.acquire(daemon, root.Operator, within: 0) {
      Ok(permit) -> root.release(daemon, permit)
      Error(_) -> Nil
    }
  })

  // Requests and their exact cancellations come from one sender. This query
  // is an ordered barrier, proving any delayed acquisitions were reclaimed.
  let assert Ok(_) = root.ready(daemon, within: 1000)
    as "all queued timeout cancellations are processed"
  let _slots =
    list.map(list.repeat(Nil, 4), fn(_) { acquired(daemon, root.Operator) })
  assert root.shutdown(daemon, within: 5000) == Ok(Nil)
}

pub fn dead_http_owner_cannot_transfer_an_upgrade_test() {
  let #(daemon, _) = start(directory("connection-parent"), inert())
  let #(http, permit) = acquired(daemon, root.Operator)
  let watch = process.monitor(http)
  process.kill(http)
  assert wait_down(watch).reason == process.Killed
  let outcomes = process.new_subject()
  let _websocket =
    process.spawn_unlinked(fn() {
      process.send(outcomes, root.transfer(daemon, permit, within: 1000))
    })
  let assert Ok(Error(_)) = process.receive(outcomes, 2000)
    as "a late WebSocket initializer cannot reclaim a dead parent's permit"
  let _slots =
    list.map(list.repeat(Nil, 4), fn(_) { acquired(daemon, root.Operator) })
  assert root.shutdown(daemon, within: 5000) == Ok(Nil)
}

pub fn shutdown_joins_actual_websocket_pid_not_only_http_parent_test() {
  let #(daemon, _) = start(directory("connection-stop"), inert())
  let #(http, permit) = acquired(daemon, root.Control)
  let websocket = transferred(daemon, permit)
  let websocket_watch = process.monitor(websocket)
  process.kill(http)
  assert root.shutdown(daemon, within: 5000) == Ok(Nil)
  assert wait_down(websocket_watch).reason == process.Killed
}
