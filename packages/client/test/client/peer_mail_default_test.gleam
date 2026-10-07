//// Default peer links against real runtimes (protocol-change/077).
////
//// Under `[peers] default_links = "same_owner"` a session is admitted from
//// the owner's other sessions without a grant, and the one place that
//// decides it is `peer_mail`'s admission. These tests drive that admission,
//// and the listings that must agree with it, through `peer_mail.handle_with`,
//// the call the Agency actor makes, with the eligibility check the daemon
//// supplies replaced by a fixed list.

import client/gateway_test
import client/peer_mail.{
  BusyOnly, Defaults, MayWake, NoDefaultLinks, Policy, SameOwner,
}
import client/peers
import core/clock
import core/ids
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option
import runtime/api

fn session_id(seed: Int) -> ids.SessionId {
  let #(id, _) =
    ids.mint_session(ids.generator(clock.stepping(1_756_000_000_000, 1), seed))
  id
}

fn name(id: ids.SessionId) -> String {
  ids.session_id_to_string(id)
}

fn same_owner(
  wake: peer_mail.Wake,
  eligible: List(String),
) -> peer_mail.Defaults {
  Defaults(Policy(SameOwner, wake), fn() { eligible })
}

fn call(
  runtime: api.Runtime,
  defaults: peer_mail.Defaults,
  command: peer_mail.Command,
) -> Result(JsonValue, String) {
  peer_mail.handle_with(runtime, clock.fixed(0), defaults, command)
}

fn send(
  runtime: api.Runtime,
  defaults: peer_mail.Defaults,
  from: String,
  strand: String,
  id: String,
) -> Result(JsonValue, String) {
  call(
    runtime,
    defaults,
    peer_mail.Deliver(
      peer_mail.Source(from, "main", json.Null),
      strand,
      id,
      "hello",
    ),
  )
}

fn field(value: JsonValue, key: String) -> JsonValue {
  let assert json.Object(fields) = value as "the row is an object"
  let assert Ok(found) = list.key_find(fields, key) as "the row has the field"
  found
}

fn rows(value: Result(JsonValue, String)) -> List(JsonValue) {
  let assert Ok(json.Array(rows)) = value as "the listing is an array"
  rows
}

pub fn off_admits_nothing_without_a_grant_test() {
  let mine = session_id(601)
  let other = session_id(602)
  let runtime = gateway_test.reserved_fixture(mine).runtime
  let defaults =
    Defaults(Policy(NoDefaultLinks, MayWake), fn() { [name(mine), name(other)] })
  assert send(runtime, defaults, name(other), "main", "m1")
    == Error("no directional peer grant")
  assert send(runtime, peer_mail.no_defaults, name(other), "main", "m2")
    == Error("no directional peer grant")
}

pub fn same_owner_admits_between_sessions_the_owner_holds_alone_test() {
  let mine = session_id(603)
  let other = session_id(604)
  let runtime = gateway_test.reserved_fixture(mine).runtime
  let defaults = same_owner(MayWake, [name(mine), name(other)])
  let assert Ok(receipt) = send(runtime, defaults, name(other), "main", "m1")
    as "the default link admits the message"
  assert field(receipt, "admitted") == json.Bool(True)
}

pub fn a_retry_of_an_admitted_default_message_returns_the_same_receipt_test() {
  let mine = session_id(605)
  let other = session_id(606)
  let runtime = gateway_test.reserved_fixture(mine).runtime
  let defaults = same_owner(MayWake, [name(mine), name(other)])
  let assert Ok(first) = send(runtime, defaults, name(other), "main", "m1")
  assert send(runtime, defaults, name(other), "main", "m1") == Ok(first)
}

pub fn a_session_with_a_claimed_member_is_not_reached_test() {
  let mine = session_id(607)
  let other = session_id(608)
  let runtime = gateway_test.reserved_fixture(mine).runtime

  // The recipient has a member, so the daemon does not list it.
  assert send(
      runtime,
      same_owner(MayWake, [name(other)]),
      name(other),
      "main",
      "m1",
    )
    == Error("no directional peer grant")

  // The sender has a member, so the daemon does not list it either.
  assert send(
      runtime,
      same_owner(MayWake, [name(mine)]),
      name(other),
      "main",
      "m2",
    )
    == Error("no directional peer grant")
}

pub fn a_default_link_never_joins_a_strand_other_than_main_test() {
  let mine = session_id(609)
  let other = session_id(610)
  let runtime = gateway_test.reserved_fixture(mine).runtime
  let defaults = same_owner(MayWake, [name(mine), name(other)])
  assert send(runtime, defaults, name(other), "reviewer", "m1")
    == Error("no directional peer grant")
  assert call(
      runtime,
      defaults,
      peer_mail.Deliver(
        peer_mail.Source(name(other), "reviewer", json.Null),
        "main",
        "m2",
        "hello",
      ),
    )
    == Error("no directional peer grant")
}

pub fn a_session_is_not_linked_to_itself_by_default_test() {
  let mine = session_id(611)
  let runtime = gateway_test.reserved_fixture(mine).runtime
  let defaults = same_owner(MayWake, [name(mine)])
  assert send(runtime, defaults, name(mine), "main", "m1")
    == Error("no directional peer grant")
}

pub fn the_default_wake_permission_applies_to_the_default_link_test() {
  let mine = session_id(612)
  let other = session_id(613)
  let runtime = gateway_test.reserved_fixture(mine).runtime

  // The recipient's main strand is idle, so a busy-only link cannot deliver.
  let busy = same_owner(BusyOnly, [name(mine), name(other)])
  let assert Error("QueueRejected(NoActiveRun)") =
    send(runtime, busy, name(other), "main", "m1")
    as "busy_only refuses an idle recipient"
  let waking = same_owner(MayWake, [name(mine), name(other)])
  let assert Ok(_) = send(runtime, waking, name(other), "main", "m2")
    as "may_wake starts a run"
}

pub fn an_explicit_grant_overrides_the_default_wake_test() {
  let mine = session_id(614)
  let other = session_id(615)
  let runtime = gateway_test.reserved_fixture(mine).runtime
  let defaults = same_owner(MayWake, [name(mine), name(other)])
  let assert Ok(_) =
    call(
      runtime,
      defaults,
      peer_mail.Allow(peer_mail.Grant(name(other), "main", "main", BusyOnly)),
    )
  let assert Error("QueueRejected(NoActiveRun)") =
    send(runtime, defaults, name(other), "main", "m1")
    as "the explicit busy-only grant refuses an idle recipient"
}

pub fn an_explicit_unlink_ends_the_default_for_that_direction_test() {
  let mine = session_id(616)
  let other = session_id(617)
  let third = session_id(618)
  let runtime = gateway_test.reserved_fixture(mine).runtime
  let defaults = same_owner(MayWake, [name(mine), name(other), name(third)])
  let assert Ok(_) = send(runtime, defaults, name(other), "main", "m1")

  // Revoking records a denial, though no grant was ever recorded.
  let assert Ok(_) =
    call(
      runtime,
      defaults,
      peer_mail.Revoke(peer_mail.Grant(name(other), "main", "main", BusyOnly)),
    )
  assert send(runtime, defaults, name(other), "main", "m2")
    == Error("no directional peer grant")

  // The denial is for that one direction and that one session.
  let assert Ok(_) = send(runtime, defaults, name(third), "main", "m3")

  // Granting the pair again lifts the denial.
  let assert Ok(_) =
    call(
      runtime,
      defaults,
      peer_mail.Allow(peer_mail.Grant(name(other), "main", "main", MayWake)),
    )
  let assert Ok(_) = send(runtime, defaults, name(other), "main", "m4")
}

pub fn the_roster_lists_default_peers_and_drops_denied_ones_test() {
  let mine = session_id(619)
  let other = session_id(620)
  let runtime = gateway_test.reserved_fixture(mine).runtime
  let defaults = same_owner(MayWake, [name(mine), name(other)])

  // The recipient answers the sender's roster with the strand it exports.
  let listed =
    rows(call(runtime, defaults, peer_mail.Roster(name(other), "main")))
  assert list.length(listed) == 1
  let assert [row] = listed
  assert field(row, "strand") == json.String("main")
  assert field(row, "wake") == json.String("may_wake")

  // Off, a non-main sender and an ineligible sender each list nothing.
  assert rows(call(
      runtime,
      peer_mail.no_defaults,
      peer_mail.Roster(name(other), "main"),
    ))
    == []
  assert rows(call(runtime, defaults, peer_mail.Roster(name(other), "reviewer")))
    == []
  assert rows(call(
      runtime,
      same_owner(MayWake, [name(mine)]),
      peer_mail.Roster(name(other), "main"),
    ))
    == []
  let assert Ok(_) =
    call(
      runtime,
      defaults,
      peer_mail.Revoke(peer_mail.Grant(name(other), "main", "main", BusyOnly)),
    )
  assert rows(call(runtime, defaults, peer_mail.Roster(name(other), "main")))
    == []
}

pub fn outgoing_links_list_default_peers_marked_as_default_test() {
  let mine = session_id(621)
  let other = session_id(622)
  let third = session_id(623)
  let runtime = gateway_test.reserved_fixture(mine).runtime
  let defaults = same_owner(MayWake, [name(mine), name(other), name(third)])
  let listed = rows(call(runtime, defaults, peer_mail.Links("main")))
  assert list.map(listed, fn(row) { field(row, "session") })
    == [json.String(name(other)), json.String(name(third))]
  assert list.all(listed, fn(row) { field(row, "default") == json.Bool(True) })

  // A recorded link to a session replaces its default row, and an unlink
  // leaves the pair out.
  let assert Ok(_) =
    call(runtime, defaults, peer_mail.Link("main", name(other), "main"))
  let listed = rows(call(runtime, defaults, peer_mail.Links("main")))
  assert list.length(listed) == 2
  let assert Ok(explicit) =
    list.find(listed, fn(row) {
      field(row, "session") == json.String(name(other))
    })
  let assert json.Object(fields) = explicit
  assert list.key_find(fields, "default") == Error(Nil)
  let assert Ok(_) =
    call(runtime, defaults, peer_mail.Unlink("main", name(third), "main"))
  let listed = rows(call(runtime, defaults, peer_mail.Links("main")))
  assert list.map(listed, fn(row) { field(row, "session") })
    == [json.String(name(other))]

  // Off and an ineligible source list only what was recorded.
  assert list.length(
      rows(call(runtime, peer_mail.no_defaults, peer_mail.Links("main"))),
    )
    == 1
  assert list.length(
      rows(call(
        runtime,
        same_owner(MayWake, [name(other), name(third)]),
        peer_mail.Links("main"),
      )),
    )
    == 1
  assert rows(call(runtime, defaults, peer_mail.Links("reviewer"))) == []
}

pub fn incoming_grants_list_default_sources_marked_as_default_test() {
  let mine = session_id(624)
  let other = session_id(625)
  let runtime = gateway_test.reserved_fixture(mine).runtime
  let defaults = same_owner(BusyOnly, [name(mine), name(other)])
  let listed = rows(call(runtime, defaults, peer_mail.Grants("main")))
  assert list.length(listed) == 1
  let assert [row] = listed
  assert field(row, "source_session") == json.String(name(other))
  assert field(row, "source_strand") == json.String("main")
  assert field(row, "target_strand") == json.String("main")
  assert field(row, "wake") == json.String("busy_only")
  assert field(row, "default") == json.Bool(True)
  assert rows(call(runtime, peer_mail.no_defaults, peer_mail.Grants("main")))
    == []

  // An explicit grant takes the pair's place, without the default mark.
  let assert Ok(_) =
    call(
      runtime,
      defaults,
      peer_mail.Allow(peer_mail.Grant(name(other), "main", "main", MayWake)),
    )
  let listed = rows(call(runtime, defaults, peer_mail.Grants("main")))
  let assert [row] = listed
  assert field(row, "wake") == json.String("may_wake")
  let assert json.Object(fields) = row
  assert list.key_find(fields, "default") == Error(Nil)
}

// Two real runtimes, each answering through its own `handle_with`, and the
// daemon-style directory that resolves one to the other: the path the model's
// roster and send tools take.
fn pair(
  defaults: peer_mail.Defaults,
) -> #(ids.SessionId, ids.SessionId, peers.Wiring, peers.Wiring) {
  let first = session_id(630)
  let second = session_id(631)
  let first_runtime = gateway_test.reserved_fixture(first).runtime
  let second_runtime = gateway_test.reserved_fixture(second).runtime
  let first_endpoint =
    peer_mail.Endpoint(name(first), fn(command) {
      peer_mail.handle_with(first_runtime, clock.fixed(0), defaults, command)
    })
  let second_endpoint =
    peer_mail.Endpoint(name(second), fn(command) {
      peer_mail.handle_with(second_runtime, clock.fixed(0), defaults, command)
    })
  let directory =
    peers.Directory(
      resolve: fn(id) {
        case id == name(first), id == name(second) {
          True, _ -> Ok(first_endpoint)
          _, True -> Ok(second_endpoint)
          _, _ -> Error("unknown")
        }
      },
      describe: fn(id) { Ok(json.Object([#("id", json.String(id))])) },
    )
  #(
    first,
    second,
    peers.Wiring(first_endpoint, json.Null, option.Some(directory)),
    peers.Wiring(second_endpoint, json.Null, option.Some(directory)),
  )
}

pub fn the_model_lists_and_messages_a_default_peer_with_no_grant_test() {
  let first = session_id(630)
  let second = session_id(631)
  let both = [name(first), name(second)]
  let defaults = Defaults(Policy(SameOwner, MayWake), fn() { both })
  let #(first, second, from_first, _) = pair(defaults)
  let assert Ok(json.Array([listed])) = peers.roster(from_first, "main")
    as "the roster lists the one other session"
  assert field(listed, "session") == json.String(name(second))
  let assert Ok(receipt) =
    peers.send(from_first, "main", name(second), "main", "m1", "hello")
    as "the send path admits it with no grant recorded"
  assert field(receipt, "admitted") == json.Bool(True)

  // A session that is not listed cannot be addressed.
  let assert Error(_) =
    peers.send(from_first, "main", name(first), "main", "m2", "hello")
    as "a session is not its own default peer"
}

pub fn inspection_marks_default_rows_in_both_directions_test() {
  let first = name(session_id(630))
  let second = name(session_id(631))
  let defaults = Defaults(Policy(SameOwner, BusyOnly), fn() { [first, second] })
  let #(_, _, from_first, _) = pair(defaults)
  let assert Ok(inspected) =
    peers.inspect(from_first, "main", option.None, 60_000)
    as "inspection answers"
  let assert json.Array([outgoing]) = field(inspected, "outgoing")
  assert field(outgoing, "session") == json.String(second)
  assert field(outgoing, "wake") == json.String("busy_only")
  assert field(outgoing, "default") == json.Bool(True)
  let assert json.Array([incoming]) = field(inspected, "incoming")
  assert field(incoming, "source_session") == json.String(second)
  assert field(incoming, "default") == json.Bool(True)
}

pub fn a_closed_default_peer_is_listed_as_not_running_and_refuses_a_send_test() {
  let first = session_id(632)
  let closed = session_id(633)
  let defaults =
    Defaults(Policy(SameOwner, MayWake), fn() { [name(first), name(closed)] })
  let runtime = gateway_test.reserved_fixture(first).runtime
  let endpoint =
    peer_mail.Endpoint(name(first), fn(command) {
      peer_mail.handle_with(runtime, clock.fixed(0), defaults, command)
    })

  // Only the first session is resident; the directory cannot resolve the other.
  let directory =
    peers.Directory(
      resolve: fn(id) {
        case id == name(first) {
          True -> Ok(endpoint)
          False -> Error("session is saved, not open")
        }
      },
      describe: fn(id) { Ok(json.Object([#("id", json.String(id))])) },
    )
  let wiring = peers.Wiring(endpoint, json.Null, option.Some(directory))
  let assert Ok(json.Array([listed])) = peers.roster(wiring, "main")
    as "the closed session is still listed"
  assert field(listed, "session") == json.String(name(closed))
  assert field(listed, "running") == json.Bool(False)
  assert field(listed, "exported_strands") == json.Null

  // Sending is refused in words the model can act on, and opens nothing.
  assert peers.send(wiring, "main", name(closed), "main", "m1", "hello")
    == Error(peers.not_running)
}

pub fn the_roster_marks_a_resident_default_peer_as_running_test() {
  let first = session_id(630)
  let second = session_id(631)
  let both = [name(first), name(second)]
  let defaults = Defaults(Policy(SameOwner, BusyOnly), fn() { both })
  let #(_, _, from_first, _) = pair(defaults)
  let assert Ok(json.Array([listed])) = peers.roster(from_first, "main")
  assert field(listed, "running") == json.Bool(True)
}

pub fn default_entries_share_the_explicit_link_bound_test() {
  let first = session_id(634)
  let runtime = gateway_test.reserved_fixture(first).runtime
  let many =
    int.range(from: 1, to: 81, with: [], run: fn(acc, n) {
      [name(session_id(700 + n)), ..acc]
    })
  let defaults =
    Defaults(Policy(SameOwner, BusyOnly), fn() { [name(first), ..many] })
  let listed = rows(call(runtime, defaults, peer_mail.Links("main")))
  assert list.length(listed) == peer_mail.outgoing_link_limit
}
