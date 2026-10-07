//// Making a private session shareable runs against a real registry and a real
//// catalogue: the registry's own stop, `manager.isolate` and the registry's own
//// open, with only the assembly of a runtime faked. Each refusal is checked for
//// the state it leaves the session in, because that table is the module's
//// promise (`client/daemon/shareable`).

import broker/token
import client/daemon/domain as domain_service
import client/daemon/manager
import client/daemon/shareable
import client/internal/instance_owner as custody
import core/clock
import core/ids
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import simplifile
import storage/access
import storage/catalogue
import storage/domain
import weft/poll

const epoch = "daemon-test"

// A saved session whose scope is private, which is what a terminal creates.
fn private(store: catalogue.Catalogue, seed: Int) -> catalogue.Registration {
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed:)
  let #(id, _) = ids.mint_session(generator)
  let id = ids.session_id_to_string(id)
  let record =
    catalogue.Registration(
      id:,
      path: "/unopened-shareable-test/" <> id <> ".db",
      workspace: "/workspace/project",
      name: "session " <> int.to_string(seed),
      configuration: "",
      created_at: 1_700_000_000_000,
      request_key: "request-" <> int.to_string(seed),
      state: catalogue.Reserved,
      profile: option.None,
      executor: "",
      subtitle: option.None,
    )
  assert catalogue.reserve(store, record) == Ok(record)
  let assert Ok(record) = catalogue.confirm(store, record.id)
    as "the fixture represents initialized metadata"
  let selected =
    domain.Domain(
      domain.key(domain.WorkspacePrivate, record.workspace, record.id),
      domain.WorkspacePrivate,
      record.workspace,
      "",
      "/owner/aggregate/memory.db",
      "/owner/aggregate/search.db",
    )
  assert domain.bind(store, record.id, selected) == Ok(selected)
  record
}

// The owner and a member, with the owner's digest and the member's.
fn people(store: catalogue.Catalogue) -> #(access.Digest, access.Digest) {
  let assert Ok(owner) = access.credential_digest(string.repeat("a", 64))
    as "owner digest"
  let assert Ok(member) = access.credential_digest(string.repeat("b", 64))
    as "member digest"
  let assert Ok(_) = access.bootstrap_owner(store, "owner", "Owner", owner)
    as "owner exists"
  let assert Ok(_) = access.create_member(store, "member", "Member", member)
    as "member exists"
  #(owner, member)
}

// A registry whose `build` is called for each open, with the number of the open
// (the first is 1), so a test can let one open succeed and the next fail. The
// builder runs in the registry's own process, so the count is kept in a
// directory that each open adds one file to.
fn started(
  store: catalogue.Catalogue,
  build: fn(Int, catalogue.Registration, custody.Owner) ->
    Result(String, String),
) -> manager.Manager(String) {
  let directory =
    "build/test_db/shareable-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the open counter's directory exists"
  let assert Ok(registry) =
    manager.start(
      store,
      manager.Assembly(
        domain_build: fn(_, _, _) { Ok(domain_service.inert()) },
        build: fn(record, _domain, _services, owner, _directory) {
          let assert Ok(opened) = simplifile.read_directory(directory)
            as "the open counter reads"
          let number = list.length(opened) + 1
          let assert Ok(Nil) =
            simplifile.create_file(directory <> "/" <> int.to_string(number))
            as "the open counter counts"
          build(number, record, owner)
        },
        drain: fn(_, _) { Nil },
        fatal: fn(_) { [] },
      ),
      epoch:,
      limit: 2,
    )
    as "registry starts without invoking assembly"
  registry
}

fn running(registry: manager.Manager(String), id: String) -> Nil {
  let assert Ok(manager.Opening(operation)) = manager.open(registry, id)
    as "the session opens"
  await(registry, id, manager.Resident(operation))
}

fn await(
  registry: manager.Manager(String),
  id: String,
  expected: manager.Status,
) -> Nil {
  let outcome =
    poll.until(within: 2000, every: 1, attempt: fn() {
      case manager.get(registry, id) {
        Ok(manager.View(status:, ..)) if status == expected -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(string.inspect(error))
      }
    })
  assert outcome == poll.Answered(Nil)
}

fn is_resident(registry: manager.Manager(String), id: String) -> Bool {
  case manager.get(registry, id) {
    Ok(manager.View(status: manager.Resident(_), ..)) -> True
    _ -> False
  }
}

fn scope_of(store: catalogue.Catalogue, id: String) -> domain.Scope {
  let assert Ok(held) = domain.for_session(store, id) as "the domain is bound"
  held.scope
}

fn finish(
  registry: manager.Manager(String),
  store: catalogue.Catalogue,
) -> Nil {
  let watch = process.monitor(manager.pid(registry))
  manager.shutdown(registry)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(2000)
    as "shutdown joins every custody scope"
  assert catalogue.close(store) == Ok(Nil)
  Nil
}

// A running private session is stopped, isolated and resumed: it ends resident,
// session-only, and an invitation into it is now accepted.
pub fn a_running_private_session_is_stopped_isolated_and_resumed_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = private(store, 1301)
  let #(owner, _) = people(store)
  let registry = started(store, fn(_, record, _) { Ok(record.id) })
  running(registry, record.id)
  let invite =
    manager.Invite(
      "guest-1",
      "Guest",
      access.DigestEnrollment(owner),
      record.id,
      access.Observer,
    )
  assert manager.administer(registry, owner, epoch, invite)
    == Error(manager.IsolationRequired)

  assert shareable.make(registry, owner, epoch, "/new-state", record.id)
    == Ok(Nil)
  assert scope_of(store, record.id) == domain.SessionOnly
  assert is_resident(registry, record.id)

  // A second task finds nothing to do and leaves the session running.
  assert shareable.make(registry, owner, epoch, "/new-state", record.id)
    == Ok(Nil)
  assert is_resident(registry, record.id)
  finish(registry, store)
}

// A session nothing runs is isolated and stays saved: the task restores what it
// found, so a button that said nothing about running it never starts it.
pub fn a_saved_private_session_is_isolated_and_stays_saved_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = private(store, 1302)
  let #(owner, _) = people(store)
  let registry =
    started(store, fn(_, _, _) { panic as "a saved session is never opened" })
  assert shareable.make(registry, owner, epoch, "/new-state", record.id)
    == Ok(Nil)
  assert scope_of(store, record.id) == domain.SessionOnly
  assert manager.get(registry, record.id)
    |> result_status
    == Ok(manager.Saved)
  finish(registry, store)
}

fn result_status(
  view: Result(manager.View, manager.Error),
) -> Result(manager.Status, manager.Error) {
  case view {
    Ok(manager.View(status:, ..)) -> Ok(status)
    Error(error) -> Error(error)
  }
}

// Only the daemon's owner may ask, and a refusal before the stop leaves the
// session running and private: the stop is the first change and a member's
// credential never reaches it.
pub fn a_member_is_refused_before_anything_stops_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = private(store, 1303)
  let #(_, member) = people(store)
  let registry = started(store, fn(_, record, _) { Ok(record.id) })
  running(registry, record.id)
  assert shareable.make(registry, member, epoch, "/new-state", record.id)
    == Error(shareable.NotOwner)
  assert is_resident(registry, record.id)
  assert scope_of(store, record.id) == domain.WorkspacePrivate
  finish(registry, store)
}

pub fn an_unknown_session_is_not_found_and_changes_nothing_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let #(owner, _) = people(store)
  let registry = started(store, fn(_, record, _) { Ok(record.id) })
  assert shareable.make(
      registry,
      owner,
      epoch,
      "/new-state",
      "0198a2f4-7c3b-7e10-8d5a-3f9b2c4e6a71",
    )
    == Error(shareable.NotFound)
  finish(registry, store)
}

// A session that is already session-only has nothing to do: it is not stopped.
pub fn a_shareable_session_is_left_running_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = private(store, 1304)
  let #(owner, _) = people(store)
  let registry = started(store, fn(_, record, _) { Ok(record.id) })
  assert shareable.make(registry, owner, epoch, "/new-state", record.id)
    == Ok(Nil)
  running(registry, record.id)
  assert shareable.make(registry, owner, epoch, "/new-state", record.id)
    == Ok(Nil)
  assert is_resident(registry, record.id)
  finish(registry, store)
}

// The registry refuses isolation for a stale epoch after the session was
// stopped. The task puts the session back as it found it: running, private, and
// the refusal says it could not move.
pub fn a_refused_isolation_restores_a_running_session_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = private(store, 1305)
  let #(owner, _) = people(store)
  let registry = started(store, fn(_, record, _) { Ok(record.id) })
  running(registry, record.id)
  assert shareable.make(registry, owner, "a-previous-daemon", "/s", record.id)
    == Error(shareable.NotMoved)
  assert scope_of(store, record.id) == domain.WorkspacePrivate
  assert is_resident(registry, record.id)
  finish(registry, store)
}

// Isolation succeeded and the second open fails: the session is session-only and
// saved, which the refusal says, and an open from the home page finishes the job.
pub fn a_failed_resume_leaves_a_shareable_saved_session_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = private(store, 1306)
  let #(owner, _) = people(store)
  let registry =
    started(store, fn(open, record, _) {
      case open {
        1 -> Ok(record.id)
        _ -> Error("the runtime did not assemble")
      }
    })
  running(registry, record.id)
  assert shareable.make(registry, owner, epoch, "/new-state", record.id)
    == Error(shareable.NotResumed)
  assert scope_of(store, record.id) == domain.SessionOnly
  await(registry, record.id, manager.Saved)
  finish(registry, store)
}

// Isolation refused and the session would not start again either: stopped and
// private, which is the one state the owner must resume by hand.
pub fn a_refusal_that_cannot_restore_the_session_is_stranded_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = private(store, 1307)
  let #(owner, _) = people(store)
  let registry =
    started(store, fn(open, record, _) {
      case open {
        1 -> Ok(record.id)
        _ -> Error("the runtime did not assemble")
      }
    })
  running(registry, record.id)
  assert shareable.make(registry, owner, "a-previous-daemon", "/s", record.id)
    == Error(shareable.Stranded)
  assert scope_of(store, record.id) == domain.WorkspacePrivate
  await(registry, record.id, manager.Saved)
  finish(registry, store)
}

// Two presses at once both stop the session, and the second isolation is refused
// because the first one made the change. Both tasks answer as done, and the
// session ends session-only and running; neither reports a failure to move.
pub fn two_tasks_at_once_both_succeed_test() {
  let assert Ok(store) = catalogue.open(":memory:") as "catalogue opens"
  let record = private(store, 1308)
  let #(owner, _) = people(store)
  let registry = started(store, fn(_, record, _) { Ok(record.id) })
  running(registry, record.id)
  let answers = process.new_subject()
  list.each([1, 2], fn(_) {
    let _ =
      process.spawn_unlinked(fn() {
        process.send(
          answers,
          shareable.make(registry, owner, epoch, "/new-state", record.id),
        )
      })
  })
  let assert Ok(first) = process.receive(answers, 10_000)
    as "the first task answers"
  let assert Ok(second) = process.receive(answers, 10_000)
    as "the second task answers"
  assert first == Ok(Nil)
  assert second == Ok(Nil)
  assert scope_of(store, record.id) == domain.SessionOnly
  assert is_resident(registry, record.id)
  finish(registry, store)
}
