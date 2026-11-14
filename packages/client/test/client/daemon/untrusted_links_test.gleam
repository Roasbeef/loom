//// The untrusted link registry (protocol-change/115), observed through the
//// name each link registers.
////
//// The registry starts, replaces and stops processes that register
//// `untrusted_link.name_for(executor)`. These tests give it a `Links` whose
//// start spawns a process that only registers that name and waits, so every
//// case runs in milliseconds and is observed the way placement observes a link:
//// by asking who holds the name. The end-to-end behaviour with real links is in
//// `remote/untrusted_reload_test`.

import client/daemon/untrusted_links.{type Registry, Wanted}
import client/executor_reload.{Failed, Restarted, Started, Stopped, Unchanged}
import client/executors.{type Executor}
import client/internal/ffi_os
import client/internal/ffi_tls_stream.{type Credentials, Credentials}
import client/remote/untrusted_link
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{Some}
import telemetry/log

fn credentials() -> Credentials {
  Credentials(ca: "/vm/ca.pem", certificate: "/vm/c.pem", key: "/vm/k.pem")
}

// A name no other test uses, so the registered atoms never collide.
fn unique(label: String) -> String {
  label <> "-" <> int.to_string(ffi_os.unique_positive_integer())
}

fn untrusted(name: String, port: Int) -> Executor {
  executors.Executor(
    ..executors.plain(name, ""),
    trust: executors.Untrusted(host: "127.0.0.1", port:, pin: <<1>>),
  )
}

// A process that holds the link's name and waits, as a started link does.
fn hold(name: String) -> Result(Pid, String) {
  let ready = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let assert Ok(Nil) =
        process.register(process.self(), untrusted_link.name_for(name))
        as "the name is free"
      process.send(ready, Nil)
      process.sleep_forever()
    })
  case process.receive(ready, 1000) {
    Ok(Nil) -> Ok(pid)
    Error(Nil) -> Error("the holder did not register")
  }
}

fn fake_links() -> untrusted_links.Links {
  untrusted_links.Links(
    start: fn(row, _credentials) { hold(row.name) },
    holder: fn(name) { process.named(untrusted_link.name_for(name)) },
  )
}

fn registry(links: untrusted_links.Links) -> Registry {
  let assert Ok(started) = untrusted_links.start(links, log.discard())
    as "the registry starts"
  started
}

fn reload(registry: Registry, rows: List(Executor)) {
  untrusted_links.reconcile(registry, fn() {
    Ok(Wanted(rows:, credentials: Some(credentials())))
  })
}

fn changes(reply) -> List(#(String, executor_reload.Change)) {
  let assert Ok(executor_reload.Reply(entries)) = reply
    as "the reconcile answered"
  list.map(entries, fn(entry) { #(entry.name, entry.change) })
}

fn holder_of(name: String) -> Result(Pid, Nil) {
  process.named(untrusted_link.name_for(name))
}

pub fn a_new_row_starts_a_link_under_its_name_test() {
  let name = unique("added")
  let links = registry(fake_links())

  assert changes(reload(links, [untrusted(name, 7000)])) == [#(name, Started)]
  let assert Ok(pid) = holder_of(name) as "the link holds the name"
  assert process.is_alive(pid)
  assert list.map(untrusted_links.rows(links), fn(row) { row.name }) == [name]
}

pub fn an_unchanged_live_row_keeps_its_process_test() {
  let name = unique("steady")
  let links = registry(fake_links())
  let _ = reload(links, [untrusted(name, 7000)])
  let assert Ok(before) = holder_of(name) as "the link holds the name"

  assert changes(reload(links, [untrusted(name, 7000)])) == [#(name, Unchanged)]
  assert holder_of(name) == Ok(before)
}

pub fn a_changed_address_replaces_the_link_test() {
  let name = unique("moved")
  let links = registry(fake_links())
  let _ = reload(links, [untrusted(name, 7000)])
  let assert Ok(before) = holder_of(name) as "the link holds the name"

  assert changes(reload(links, [untrusted(name, 7001)])) == [#(name, Restarted)]
  let assert Ok(after) = holder_of(name) as "the new link holds the name"
  assert after != before
  assert !process.is_alive(before)
  let assert [row] = untrusted_links.rows(links) as "one row is held"
  assert row.trust == executors.Untrusted("127.0.0.1", 7001, <<1>>)
}

pub fn a_removed_row_stops_its_link_test() {
  let name = unique("gone")
  let links = registry(fake_links())
  let _ = reload(links, [untrusted(name, 7000)])
  let assert Ok(before) = holder_of(name) as "the link holds the name"

  assert changes(reload(links, [])) == [#(name, Stopped)]
  assert holder_of(name) == Error(Nil)
  assert !process.is_alive(before)
  assert untrusted_links.rows(links) == []
}

pub fn a_link_that_died_is_started_again_test() {
  let name = unique("died")
  let links = registry(fake_links())
  let _ = reload(links, [untrusted(name, 7000)])
  let assert Ok(before) = holder_of(name) as "the link holds the name"
  process.kill(before)

  assert changes(reload(links, [untrusted(name, 7000)])) == [#(name, Restarted)]
  let assert Ok(after) = holder_of(name) as "the new link holds the name"
  assert after != before
  assert process.is_alive(after)
}

pub fn a_stranger_holding_the_name_is_replaced_test() {
  let name = unique("taken")
  let assert Ok(stranger) = hold(name) as "the stranger registers"
  let links = registry(fake_links())

  assert changes(reload(links, [untrusted(name, 7000)])) == [#(name, Started)]
  let assert Ok(link) = holder_of(name) as "a link holds the name"
  assert link != stranger
  assert !process.is_alive(stranger)
}

pub fn a_refused_load_changes_nothing_test() {
  let name = unique("kept")
  let links = registry(fake_links())
  let _ = reload(links, [untrusted(name, 7000)])
  let assert Ok(before) = holder_of(name) as "the link holds the name"

  assert untrusted_links.reconcile(links, fn() { Error("the file is bad") })
    == Error(untrusted_links.Refused("the file is bad"))
  assert holder_of(name) == Ok(before)
  assert list.length(untrusted_links.rows(links)) == 1
}

pub fn more_rows_than_the_cap_is_refused_test() {
  let links = registry(fake_links())
  let rows =
    list.repeat(0, executor_reload.max_rows + 1)
    |> list.index_map(fn(_zero, index) {
      untrusted("cap-" <> int.to_string(index), 7000)
    })

  let assert Error(untrusted_links.Refused(_)) = reload(links, rows)
    as "the reload is refused"
  assert untrusted_links.rows(links) == []
}

pub fn a_start_that_fails_leaves_the_row_out_test() {
  let name = unique("broken")
  let links =
    registry(
      untrusted_links.Links(
        start: fn(_row, _credentials) { Error("no listener") },
        holder: fn(name) { holder_of(name) },
      ),
    )

  assert changes(reload(links, [untrusted(name, 7000)])) == [#(name, Failed)]
  assert untrusted_links.rows(links) == []
}

pub fn a_row_not_reached_in_time_is_failed_and_kept_test() {
  let first = unique("wedged-a")
  let second = unique("wedged-b")

  // A name that is held again as soon as it is freed: the wait for it never
  // ends, which is what the three seconds are for.
  let squatter = process.spawn_unlinked(fn() { process.sleep_forever() })
  let wedged =
    untrusted_links.Links(
      start: fn(row, _credentials) { hold(row.name) },
      holder: fn(_name) { Ok(squatter) },
    )
  let links = registry(wedged)
  let started_at = ffi_os.system_time_ms()

  let reply = reload(links, [untrusted(first, 7000), untrusted(second, 7000)])
  let elapsed = ffi_os.system_time_ms() - started_at
  assert changes(reply) == [#(first, Failed), #(second, Failed)]

  // The wait for a name stops a link start's timeout before the deadline, so a
  // start that could not finish is never begun.
  assert elapsed >= untrusted_links.reconcile_ms - 1100
  assert elapsed < untrusted_links.reconcile_ms
  assert untrusted_links.rows(links) == []
}

pub fn a_slow_load_uses_the_budget_and_the_caller_still_gets_a_reply_test() {
  let kept = unique("slow-a")
  let fresh = unique("slow-b")
  let links = registry(fake_links())
  let _ = reload(links, [untrusted(kept, 7000)])
  let assert Ok(before) = holder_of(kept) as "the link holds the name"
  let started_at = ffi_os.system_time_ms()

  // The read of the file takes most of the turn's deadline. What is left is
  // less than a link start's timeout, so no row is attempted.
  let reply =
    untrusted_links.reconcile(links, fn() {
      process.sleep(untrusted_links.reconcile_ms - 500)
      Ok(Wanted(
        rows: [untrusted(kept, 7001), untrusted(fresh, 7000)],
        credentials: Some(credentials()),
      ))
    })
  let elapsed = ffi_os.system_time_ms() - started_at

  // The caller has an answer and not `Unavailable`, with every row failed.
  assert changes(reply) == [#(kept, Failed), #(fresh, Failed)]
  assert elapsed < untrusted_links.reconcile_ms + 500

  // A row whose replacement was not attempted keeps the link it had.
  assert holder_of(kept) == Ok(before)
  assert process.is_alive(before)
  assert holder_of(fresh) == Error(Nil)
  let assert [row] = untrusted_links.rows(links) as "only the old row is held"
  assert row.trust == executors.Untrusted("127.0.0.1", 7000, <<1>>)
}
