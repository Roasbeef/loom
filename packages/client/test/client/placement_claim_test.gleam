//// Sessions of one orchestrator that open together must not all choose the
//// first executor of a pool. A session is resident only after its attach, so
//// the registry keeps a claim for each session still being built and adds the
//// claims to the resident counts in the turn that records the next claim
//// (`manager.claim_placement`). These tests run a real registry whose builds
//// wait for the test, so that sessions stay in the building phase while others
//// ask.

import client/daemon/domain as domain_service
import client/daemon/manager
import client/executors
import client/pools
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/string
import host/bootstrap
import simplifile
import storage/access
import storage/catalogue
import support/held_catalogue
import weft/poll

// How long a build waits for the test to release or fail it. It only bounds a
// test that forgot to, and the tests release every build they start.
const build_wait_ms = 15_000

// A registry whose builds wait for the test. A build ends when the file
// `<id>.go` appears, which makes the session resident, or when `<id>.fail`
// appears, which makes the build return an error.
fn start() -> #(manager.Manager(String), catalogue.Catalogue, String) {
  let assert Ok(directory) =
    bootstrap.absolute_path("build/placement-claim-" <> int.to_string(unique()))
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let assert Ok(store) = catalogue.open(":memory:")
  let assert Ok(owner) = access.credential_digest(string.repeat("a", 64))
  let assert Ok(_) = access.bootstrap_owner(store, "owner", "Owner", owner)
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, _owner, _directory) {
          gated(directory, record.id)
        },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
      epoch: "claim-test",
      limit: 16,
    )
    as "the registry starts"
  #(registry, store, directory)
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(a)) -> Int

fn unique() -> Int {
  int.absolute_value(unique_integer([]))
}

fn gated(directory: String, id: String) -> Result(String, String) {
  let answer =
    poll.until(within: build_wait_ms, every: 5, attempt: fn() {
      case
        simplifile.is_file(directory <> "/" <> id <> ".go"),
        simplifile.is_file(directory <> "/" <> id <> ".fail")
      {
        Ok(True), _ -> poll.Done(Ok(id))
        _, Ok(True) -> poll.Done(Error("the test failed this build"))
        _, _ -> poll.Retry
      }
    })
  case answer {
    poll.Answered(done) -> done
    _ -> Error("the test never released this build")
  }
}

// Registers `count` confirmed sessions and opens each, so that every one of them
// has a slot whose builder is waiting for the test.
fn building(
  registry: manager.Manager(String),
  store: catalogue.Catalogue,
  directory: String,
  count: Int,
) -> List(String) {
  let ids = held_catalogue.registered_n(store, directory, "", count)
  list.each(ids, fn(id) {
    let assert Ok(manager.Opening(_)) = manager.open(registry, id)
  })
  ids
}

fn release(directory: String, id: String) -> Nil {
  let assert Ok(Nil) = simplifile.write(directory <> "/" <> id <> ".go", "")
  Nil
}

fn fail(directory: String, id: String) -> Nil {
  let assert Ok(Nil) = simplifile.write(directory <> "/" <> id <> ".fail", "")
  Nil
}

fn resident(registry: manager.Manager(String), id: String) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 5000, every: 5, attempt: fn() {
      case manager.get(registry, id) {
        Ok(manager.View(status: manager.Resident(_), ..)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "the released session becomes resident"
  Nil
}

fn saved(registry: manager.Manager(String), id: String) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 5000, every: 5, attempt: fn() {
      case manager.get(registry, id) {
        Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "the failed build leaves the session saved"
  Nil
}

fn boxes(count: Int) -> List(executors.Executor) {
  list.repeat(Nil, count)
  |> list.index_map(fn(_each, number) {
    let name = "e" <> int.to_string(number)
    executors.plain(name, name <> "@10.0.0." <> int.to_string(number + 2))
  })
}

// The chooser an open passes: the pool's spread order. It also tells the test
// what counts the registry gave it.
fn spread_and_tell(
  pool: List(executors.Executor),
  seen: Subject(Dict(String, Int)),
) -> fn(Dict(String, Int)) -> List(String) {
  fn(held) {
    process.send(seen, held)
    pools.spread(pool, held) |> list.map(fn(executor) { executor.name })
  }
}

fn claim(
  registry: manager.Manager(String),
  id: String,
  pool: List(executors.Executor),
  seen: Subject(Dict(String, Int)),
) -> List(String) {
  manager.claim_placement(registry, id, dict.new(), spread_and_tell(pool, seen))
}

fn held_when_asked(seen: Subject(Dict(String, Int))) -> Dict(String, Int) {
  let assert Ok(held) = process.receive(seen, 1000)
    as "the chooser ran in the registry's turn"
  held
}

pub fn eight_sessions_asking_together_fill_four_executors_evenly_test() {
  let #(registry, store, directory) = start()
  let ids = building(registry, store, directory, 8)
  let seen = process.new_subject()
  let heads = process.new_subject()

  // Each session asks from a process of its own, all at once.
  list.each(ids, fn(id) {
    process.spawn(fn() {
      let ordered = claim(registry, id, boxes(4), seen)
      process.send(heads, list.first(ordered))
    })
  })
  let chosen =
    list.map(ids, fn(_id) {
      let assert Ok(Ok(head)) = process.receive(heads, 5000)
        as "every session is answered"
      head
    })

  list.each(["e0", "e1", "e2", "e3"], fn(name) {
    assert list.count(chosen, fn(head) { head == name }) == 2
  })
  list.each(ids, release(directory, _))
}

pub fn a_claim_stops_counting_when_its_session_is_resident_test() {
  let #(registry, store, directory) = start()
  let assert [first, second, third] = building(registry, store, directory, 3)
  let seen = process.new_subject()
  assert claim(registry, first, boxes(2), seen) == ["e0", "e1"]
  assert held_when_asked(seen) == dict.new()
  assert claim(registry, second, boxes(2), seen) == ["e1", "e0"]
  assert held_when_asked(seen) == dict.from_list([#("e0", 1)])

  // The first session's attach finished. The catalogue's resident counts speak
  // for it from now on, so its claim must not be counted a second time.
  release(directory, first)
  resident(registry, first)
  let _ = claim(registry, third, boxes(2), seen)
  assert held_when_asked(seen) == dict.from_list([#("e1", 1)])
  release(directory, second)
  release(directory, third)
}

pub fn a_claim_of_a_failed_build_is_not_left_behind_test() {
  let #(registry, store, directory) = start()
  let assert [failing, other] = building(registry, store, directory, 2)
  let seen = process.new_subject()
  let _ = claim(registry, failing, boxes(2), seen)
  let _ = held_when_asked(seen)
  fail(directory, failing)
  saved(registry, failing)

  // The failed session holds no scope, so it holds nothing against e0.
  let _ = claim(registry, other, boxes(2), seen)
  assert held_when_asked(seen) == dict.new()
  release(directory, other)
}

pub fn asking_again_replaces_a_sessions_claim_and_never_adds_to_it_test() {
  let #(registry, store, directory) = start()
  let assert [first, second] = building(registry, store, directory, 2)
  let seen = process.new_subject()
  let _ = claim(registry, first, boxes(2), seen)
  let _ = held_when_asked(seen)

  // Its own earlier claim is not counted against it, so it gets the same answer.
  assert claim(registry, first, boxes(2), seen) == ["e0", "e1"]
  assert held_when_asked(seen) == dict.new()

  // And it counts once for everyone else.
  let _ = claim(registry, second, boxes(2), seen)
  assert held_when_asked(seen) == dict.from_list([#("e0", 1)])
  release(directory, first)
  release(directory, second)
}

pub fn the_executor_that_took_the_scope_replaces_the_claim_test() {
  let #(registry, store, directory) = start()
  let assert [first, second] = building(registry, store, directory, 2)
  let seen = process.new_subject()
  let _ = claim(registry, first, boxes(2), seen)
  let _ = held_when_asked(seen)

  // e0 declined, and the attach to e1 succeeded. The next claim, sent by the
  // same process and so ordered after this one, counts e1 and not e0.
  manager.seed_executor(registry, first, "e1")
  let _ = claim(registry, second, boxes(2), seen)
  assert held_when_asked(seen) == dict.from_list([#("e1", 1)])
  release(directory, first)
  release(directory, second)
}
