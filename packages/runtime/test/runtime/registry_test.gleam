//// The runtime's strand catalogue must allocate references, not atoms.
////
//// The Weft suite checks individual binding lifetimes. These tests exercise
//// the actual runtime registry's allocation and ownership boundary: a
//// thousand distinct strand names must not grow the VM atom table, and
//// killing the registry must invalidate its namespace without killing a
//// recipient whose lifetime it does not own.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import runtime/registry
import weft/poll
import weft/registry as address

type Counter {
  AtomCount
}

@external(erlang, "erlang", "system_info")
fn system_count(counter: Counter) -> Int

pub fn allocating_strand_addresses_does_not_grow_atoms_test() {
  let name = process.new_name("runtime-address-catalogue")
  let assert Ok(started) = registry.start(name)
    as "the runtime registry must start"

  // Warm both the existing-key and new-key paths before measuring. The
  // service's one legacy name is allocated above, outside the strand count.
  let first = registry.ensure(started.data, "warm")
  assert registry.ensure(started.data, "warm") == first
  assert registry.lookup(started.data, "warm") == Ok(first)
  let before = system_count(AtomCount)
  int.range(from: 0, to: 1000, with: Nil, run: fn(_, index) {
    let strand = "strand-" <> int.to_string(index)
    let key = registry.ensure(started.data, strand)
    assert registry.lookup(started.data, strand) == Ok(key)
  })
  assert system_count(AtomCount) == before
  assert registry.known(started.data) |> list.length == 1001
  kill_and_join(started.pid)
}

pub fn registry_death_invalidates_routing_not_recipient_lifetime_test() {
  let name = process.new_name("runtime-address-owner")
  let assert Ok(started) = registry.start(name)
    as "the runtime registry must start"
  let key = registry.ensure(started.data, "main")
  let recipient = process.new_subject()
  assert address.register(key, recipient) == Ok(Nil)
  assert address.lookup(key) == Ok(recipient)
  kill_and_join(started.pid)

  // The namespace is linked to the runtime registry, not to the bound
  // recipient. Its death must remove routing even while this recipient lives.
  assert poll.until(within: 2000, every: 1, attempt: fn() {
      case address.lookup(key) |> result.is_error {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    == poll.Answered(Nil)
  assert process.subject_owner(recipient) == Ok(process.self())
}

fn kill_and_join(pid: process.Pid) -> Nil {
  process.unlink(pid)
  let monitor = process.monitor(pid)
  process.kill(pid)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "the test registry must exit"
  Nil
}
