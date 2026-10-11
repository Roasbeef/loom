//// The owner's fact access: the fence around the two namespaces a
//// workspace may touch, and the local adapter over a live runtime.
////
//// The fence is the property worth testing hardest. A workspace reaches the
//// session's store only through `FactAccess`, and a remote workspace is the
//// less trusted side, so a key outside `client/working_directory/` and
//// `job/` must be refused by every operation before any store is consulted.
//// The tests use suppliers which are never bound for that half, so a fence
//// which let a key through would answer `StoreAbsent` instead of
//// `NotServed`, and the difference is visible.

import client/escalate
import client/gateway_test
import client/notice
import client/owner_services.{type FactAccess}
import client/wiring
import core/clock
import core/ids
import core/json
import gleam/list
import gleam/option.{None, Some}
import runtime/api

// Suppliers which never find a writer, so an operation which gets past the
// fence says so by reporting an absent store.
fn unbound() -> FactAccess {
  owner_services.local_facts(handle: fn() { Error(Nil) }, runtime: fn() {
    Error(Nil)
  })
}

// Reserved keys the harness uses for other things, an ordinary fact key, and
// near misses of the served prefixes. None may be served.
const unserved_keys = [
  "client/directory_access", "client/permission_grants",
  "client/action_grants/abc", "client/notice/job/x", "client/working_directory",
  "client/working_directories/main", "job", "jobs/x", "advisor/state",
  "an/ordinary/fact", "",
]

pub fn only_the_two_reserved_namespaces_are_served_test() {
  assert owner_services.served_prefixes()
    == ["client/working_directory/", "job/"]
}

pub fn every_operation_refuses_a_key_outside_the_served_prefixes_test() {
  let facts = unbound()
  list.each(unserved_keys, fn(key) {
    let refused = owner_services.NotServed(key:)
    assert facts.cell(key) == Error(refused)
    assert facts.put(key, json.Null, None) == Error(refused)
    assert facts.put_blind(key, json.Null) == Error(refused)
    assert facts.delete(key) == Error(refused)
    assert facts.list(key) == Error(refused)
  })
}

pub fn a_served_key_reaches_the_store_and_finds_none_bound_test() {
  let facts = unbound()
  let key = "job/01JQ8"
  assert facts.cell(key) == Error(owner_services.StoreAbsent)
  assert facts.put(key, json.Null, None) == Error(owner_services.StoreAbsent)
  assert facts.put_blind(key, json.Null) == Error(owner_services.StoreAbsent)
  assert facts.delete(key) == Error(owner_services.StoreAbsent)
  assert facts.list("job/") == Error(owner_services.StoreAbsent)
  let directory = "client/working_directory/main"
  assert facts.cell(directory) == Error(owner_services.StoreAbsent)
}

pub fn a_listing_must_name_a_served_prefix_itself_test() {
  // `client/` is reserved but is not a served namespace, and a listing of it
  // would expose every other reserved record.
  let facts = unbound()
  assert facts.list("client/")
    == Error(owner_services.NotServed(key: "client/"))
  assert facts.list("") == Error(owner_services.NotServed(key: ""))
  assert facts.list("client/working_directory/")
    == Error(owner_services.StoreAbsent)
}

pub fn the_local_adapter_distinguishes_a_lost_race_from_success_test() {
  let id = ids.mint_session(ids.generator(clock.fixed(1000), 697)).0
  let harness = gateway_test.reserved_fixture(id)
  let facts =
    owner_services.local_facts(
      handle: fn() { Ok(api.fact_handle(harness.runtime)) },
      runtime: fn() { Ok(harness.runtime) },
    )
  let key = "job/01JQ8"

  // An absent cell reads as absent, and the claim of an absent cell wins.
  assert facts.cell(key) == Ok(None)
  let assert Ok(first) = facts.put(key, json.String("starting"), None)
    as "the first claim of an absent cell lands"

  // A second claim of the same cell expecting absence loses, and says so
  // as a conflict rather than as a generic failure.
  assert facts.put(key, json.String("rival"), None)
    == Error(owner_services.Conflict)
  assert facts.cell(key)
    == Ok(Some(api.FactCell(json.String("starting"), first)))

  // Advancing from the sequence it read succeeds, a stale sequence loses.
  let assert Ok(second) = facts.put(key, json.String("running"), Some(first))
    as "the cell advances from the sequence the caller read"
  assert facts.put(key, json.String("stale"), Some(first))
    == Error(owner_services.Conflict)

  // A blind write replaces without comparing, and the listing sees it.
  assert facts.put_blind(key, json.String("exited")) == Ok(Nil)
  assert facts.list("job/") == Ok([#(key, json.String("exited"))])
  assert second != first

  // Deleting retires the cell, and deleting it again is not an error.
  assert facts.delete(key) == Ok(Nil)
  assert facts.delete(key) == Ok(Nil)
  assert facts.cell(key) == Ok(None)
  assert api.close(harness.runtime) == Ok(Nil)
}

pub fn the_working_directory_namespace_is_served_the_same_way_test() {
  let id = ids.mint_session(ids.generator(clock.fixed(1000), 698)).0
  let harness = gateway_test.reserved_fixture(id)
  let facts =
    owner_services.local_facts(
      handle: fn() { Ok(api.fact_handle(harness.runtime)) },
      runtime: fn() { Ok(harness.runtime) },
    )
  let key = owner_services.working_directory_prefix <> "main"
  let assert Ok(_) = facts.put(key, json.String("/work"), None)
    as "the first write of a strand's directory lands"
  assert facts.list(owner_services.working_directory_prefix)
    == Ok([#(key, json.String("/work"))])
  assert api.close(harness.runtime) == Ok(Nil)
}

pub fn the_local_record_answers_an_unreachable_runtime_the_same_way_test() {
  // Every function which needs the runtime says the same thing when none
  // can be borrowed, and the jobs subset shares the record's fact access.
  let services =
    owner_services.local(
      handle: fn() { Error(Nil) },
      runtime: fn() { Error(Nil) },
      escalate: fn(_refused) { escalate.Settle },
      output: wiring.unobserved(),
      capability: owner_services.no_capability,
      holds: fn(_caller, _tool) { Ok(Nil) },
    )
  assert services.notify("main", notice.Job(id: "x"), "text")
    == Error(owner_services.unavailable)
  assert services.strand_activity("main") == Error(owner_services.unavailable)
  assert services.wake("main", "text") == Error(owner_services.unavailable)
  let jobs = owner_services.jobs_owner(services)
  assert jobs.facts.cell("job/x") == Error(owner_services.StoreAbsent)
  assert jobs.strand_activity("main") == Error(owner_services.unavailable)
}
