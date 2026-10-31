//// Which ledger daemons hold the directory's record writes
//// (protocol-change/086, phase 3).
////
//// The writes are built once, when the daemon's services start, and a ledger
//// daemon's rows change while it runs. An orchestrator that is enrolled before
//// the executor it will use, or before the orchestrator beside it, has no rows
//// at boot. It must still hold the writes, or no session it creates afterwards
//// would be recorded for as long as the daemon lived.

import client/daemon/main
import client/distribution_plan.{Executor, Orchestrator}
import client/ledger_control.{Handle}
import client/ledger_holdings
import client/ledger_service
import client/membership_entry.{Upsert}
import client/peer_defaults
import gleam/dict
import gleam/option.{None, Some}
import support/ledger_rig as rig
import support/membership_fixture as fixture
import support/membership_log as log

const hub = "loom@hub.example.net"

fn member(name: String, role: distribution_plan.Role, links: List(String)) {
  Upsert(membership_entry.Member(..fixture.member(name, links), role:))
}

fn config(handle: ledger_control.Handle) -> main.Config {
  main.Config(
    ..main.Config(
      "",
      "127.0.0.1",
      0,
      main.BindDefault,
      8,
      "Owner",
      [],
      None,
      main.ViewOff,
      peer_defaults.off,
      [],
      [],
      [],
      [],
      None,
      None,
      [],
      None,
      None,
      dict.new(),
    ),
    ledger: Some(handle),
  )
}

fn handle_of(started: rig.Rig, name: String) -> ledger_control.Handle {
  Handle(
    service: started.service,
    local: "loom@" <> name <> ".example.net",
    name:,
    asker: ledger_holdings.silent,
  )
}

pub fn an_orchestrator_with_no_links_at_boot_still_holds_the_writes_test() {
  // The hub is enrolled alone: no executor to place sessions on and no
  // orchestrator to ask, so it derives no rows at all.
  let alone = log.genesis() |> log.must_push(member("hub", Orchestrator, []))
  let started = rig.start("ownership-boot", log.lines(alone), rig.patient, [])
  let daemon = config(handle_of(started, "hub"))
  let assert Some(before) = main.ownership_of(daemon, hub)
  assert before.node == hub

  // A peer is enrolled and linked while the daemon runs. The value built at
  // boot was already an orchestrator's, and a value built now is too.
  let linked = alone |> log.must_push(member("box", Executor, ["hub"]))
  let assert [_, _, line] = log.lines(linked)
  let assert Ok(ledger_service.Accepted(_)) =
    ledger_service.offer(started.service, line, 5000)
  let assert Some(after) = main.ownership_of(daemon, hub)
  assert after.node == hub
}

pub fn an_executor_holds_no_writes_however_it_is_linked_test() {
  let history =
    log.genesis()
    |> log.must_push(member("hub", Orchestrator, []))
    |> log.must_push(member("box", Executor, ["hub"]))
  let started = rig.start("ownership-box", log.lines(history), rig.patient, [])
  let daemon = config(handle_of(started, "box"))
  assert option.is_none(main.ownership_of(daemon, "loom@box.example.net"))
}

pub fn a_node_the_ledger_does_not_list_holds_no_writes_test() {
  let history = log.genesis() |> log.must_push(member("hub", Orchestrator, []))
  let started =
    rig.start("ownership-ghost", log.lines(history), rig.patient, [])
  let daemon = config(handle_of(started, "hub"))
  assert option.is_none(main.ownership_of(daemon, "loom@ghost.example.net"))
}
