//// A join over children that run in different sessions of one parent
//// (protocol-change/107, slice 4b).
////
//// Every session is a stub that records what it was asked, and the return is a
//// stub that records which entries it settled and whether it was given the
//// session's record of its workspace. What the tests look at is routing, order,
//// concurrency and when a child's session is ended.

import client/agency
import client/child_join.{Joining}
import client/delegate_host
import client/remote_spawn.{type Joined, type Parent, Parent}
import client/session_states
import client/spawn_return
import client/spawners.{type Spawner}
import client/state_transfer
import core/clock
import core/ids
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import support/cell.{type Cell}
import tools/agent.{type Handle}
import weft/poll

fn spawner() -> Spawner {
  let text =
    "[distribution]
node = \"box@100.64.0.9\"
ca = \"/etc/loom/ca.pem\"
certificate = \"/etc/loom/cert.pem\"
key = \"/etc/loom/key.pem\"
cookie = \"/home/loom/.erlang.cookie\"

[[distribution.peers]]
node = \"laptop@100.64.0.5\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000001\"

[profiles.cheap-review.roles]
main = [\"fast\"]

[spawners.laptop]
node = \"laptop@100.64.0.5\"
profile = \"cheap-review\"
directory = \"/srv/loom/scratch\"
"
  let assert Ok([found]) = spawners.parse(text) as "the table parses"
  found
}

fn parent() -> Parent {
  Parent(session: "0198c0de-0000-7000-8000-000000000001", strand: "main")
}

fn handle(strand: String) -> Handle {
  let #(op, _) = ids.mint_op(ids.generator(clock.fixed(at: 1), seed: 9))
  agent.Handle(strand: "sub:^main/" <> strand, operation: op)
}

fn ready(found: Handle, owed: Int) -> Joined {
  remote_spawn.Ready(
    handle: found,
    outcome: agent.Completed,
    report: "done",
    result: agent.NoResultAsked,
    notes: [],
    usage: remote_spawn.ChildUsage(
      input: 1,
      output: 1,
      cache_read: 0,
      cache_write: 0,
      cost: 0.0,
    ),
    owed:,
    state: None,
  )
}

// What the stubs saw.
type Event {
  Asked(session: String)
  Settled(strand: String, with_workspace: Bool)
  Released(name: String)
}

type Rig {
  Rig(journal: Cell(List(Event)), together: Cell(Int))
}

fn rig() -> Rig {
  Rig(journal: cell.new([]), together: cell.new(0))
}

fn record(rig: Rig, event: Event) -> Nil {
  cell.update(rig.journal, fn(held) { list.append(held, [event]) })
}

fn events(rig: Rig) -> List(Event) {
  cell.get(rig.journal)
}

// A session whose join answers each handle with `answer`, after saying it was
// asked. A session with a record of its workspace carries one.
fn session(
  rig: Rig,
  name: String,
  answer: fn(Handle) -> Joined,
  meeting: Int,
) -> agency.DelegateEndpoint {
  agency.DelegateEndpoint(
    fresh: fn() { True },
    states: Some(
      session_states.SessionStates(
        executor: "runner",
        link: unreachable_link(),
        fit: Ok(Nil),
        apply: fn(_state) { Error(session_states.Final("not under test")) },
        capture: fn(_basis, _content) {
          Error(session_states.Final("not under test"))
        },
      ),
    ),
    spawn: fn(_delegation, _site, _request) { Error(unused()) },
    join: fn(_parent, handles, _within_ms) {
      record(rig, Asked(name))

      // Sessions that are asked together wait for each other here, so a join
      // that asked them in turn would find the second never came.
      case meeting > 1 {
        True -> meet(rig, meeting)
        False -> Nil
      }
      Ok(list.map(handles, answer))
    },
    run_ended: fn(_operation) { Ok(0) },
    release: fn() { Ok(0) },
    send: fn(_parent, _child, _id, _text) { Error(unused()) },
    history: fn(_parent, _child, _cursor, _limit) { Error(unused()) },
    occupancy: fn() { agency.Vacant },
    resolve: fn(_parent, _child, _id, _decision, _seq, _decider) {
      Error(unused())
    },
  )
}

fn meet(rig: Rig, others: Int) -> Nil {
  cell.update(rig.together, fn(held) { held + 1 })
  let _ =
    poll.until(within: 5000, every: 5, attempt: fn() {
      case cell.get(rig.together) >= others {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
  Nil
}

// A link no one answers, which a join never uses.
fn unreachable_link() -> state_transfer.Link {
  state_transfer.Link(
    stage: fn(_hash) { Error(Nil) },
    piece: fn(_piece) { Error(Nil) },
    fetch: fn(_hash, _offset) { Error(Nil) },
  )
}

fn unused() -> remote_spawn.SpawnRefusal {
  remote_spawn.StoreFailure(reason: "not under test")
}

// The return: children named in `own` have a session of their own; every entry it
// settles is recorded with whether it was given a workspace record.
fn returning(rig: Rig, own: List(#(String, String))) -> spawn_return.Returning {
  let names = dict.from_list(own)
  spawn_return.Returning(
    remember: fn(_spawner, _parent, _site, _state, _handle) { Nil },
    settle: fn(_spawner, _parent, entry, states) {
      let strand = case entry {
        remote_spawn.Ready(handle:, ..) -> handle.strand
        remote_spawn.Pending(handle:, ..) -> handle.strand
      }
      record(rig, Settled(strand, option.is_some(states)))
      entry
    },
    session_of: fn(_spawner, _parent, found) {
      option.from_result(dict.get(names, found.strand))
    },
  )
}

fn children(
  rig: Rig,
  sessions: List(#(String, agency.DelegateEndpoint)),
) -> delegate_host.ChildSessions {
  let held = dict.from_list(sessions)
  delegate_host.ChildSessions(
    resolve: fn(_spawner, _parent, _name) { Error(unused()) },
    open: fn(_spawner, _parent, name) {
      Ok(option.from_result(dict.get(held, name)))
    },
    live: fn(_spawner, _parent) { Ok([]) },
    release: fn(_spawner, _parent, name) {
      record(rig, Released(name))
      Ok(0)
    },
  )
}

fn joining(
  rig: Rig,
  pair: agency.DelegateEndpoint,
  sessions: List(#(String, agency.DelegateEndpoint)),
  own: List(#(String, String)),
) -> child_join.Joining {
  Joining(
    spawner: spawner(),
    parent: parent(),
    pair: fn() { Ok(pair) },
    children: children(rig, sessions),
    returning: returning(rig, own),
  )
}

fn strand_of(entry: Joined) -> String {
  case entry {
    remote_spawn.Ready(handle:, ..) -> handle.strand
    remote_spawn.Pending(handle:, ..) -> handle.strand
  }
}

fn eventually_events(rig: Rig, expected: List(Event)) -> Bool {
  case
    poll.until(within: 5000, every: 10, attempt: fn() {
      case events(rig) == expected {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
  {
    poll.Answered(Nil) -> True
    poll.Failed(_) | poll.Expired -> False
  }
}

pub fn a_join_with_no_seeded_child_asks_the_pairs_session_once_test() {
  let rig = rig()
  let one = handle("one")
  let two = handle("two")
  let pair = session(rig, "pair", ready(_, 0), 1)
  let found = joining(rig, pair, [], [])

  // Both handles go to the pair's session in one question, each entry is settled
  // with no record of a workspace, and nothing is ended.
  let assert Ok(entries) = child_join.join(found, [one, two], 1000)
  assert list.map(entries, strand_of) == [one.strand, two.strand]
  assert events(rig)
    == [
      Asked("pair"),
      Settled(one.strand, False),
      Settled(two.strand, False),
    ]
}

pub fn handles_are_answered_in_the_order_asked_whichever_session_holds_them_test() {
  let rig = rig()
  let a = handle("a")
  let b = handle("b")
  let c = handle("c")
  let d = handle("d")
  let pair = session(rig, "pair", ready(_, 0), 1)
  let sessions = [
    #("seed-a", session(rig, "seed-a", ready(_, 0), 2)),
    #("seed-c", session(rig, "seed-c", ready(_, 0), 2)),
  ]
  let own = [#(a.strand, "seed-a"), #(c.strand, "seed-c")]
  let found = joining(rig, pair, sessions, own)

  // The pair serves b and d, the children serve a and c, and the answer lists
  // them as the question did. The two children were asked together: each waited
  // in its join for the other, which a join that went one after the other could
  // not have survived.
  let assert Ok(entries) = child_join.join(found, [a, b, c, d], 1000)
  assert list.map(entries, strand_of)
    == [a.strand, b.strand, c.strand, d.strand]
  assert list.all(entries, fn(entry) {
    case entry {
      remote_spawn.Ready(..) -> True
      remote_spawn.Pending(..) -> False
    }
  })

  // A child's entry was settled with its session's record of its workspace, and
  // the pair's with none.
  let settled = events(rig)
  assert list.contains(settled, Settled(a.strand, True))
  assert list.contains(settled, Settled(c.strand, True))
  assert list.contains(settled, Settled(b.strand, False))
  assert list.contains(settled, Settled(d.strand, False))
}

pub fn a_session_is_ended_when_its_child_is_finished_and_owes_nothing_test() {
  let rig = rig()
  let a = handle("a")
  let b = handle("b")
  let c = handle("c")
  let pair = session(rig, "pair", ready(_, 0), 1)

  // a is finished and owes nothing; b is finished and still owes the parent two
  // messages; c has not finished.
  let sessions = [
    #("seed-a", session(rig, "seed-a", ready(_, 0), 1)),
    #("seed-b", session(rig, "seed-b", ready(_, 2), 1)),
    #(
      "seed-c",
      session(rig, "seed-c", fn(found) { remote_spawn.Pending(found, 5) }, 1),
    ),
  ]
  let own = [
    #(a.strand, "seed-a"),
    #(b.strand, "seed-b"),
    #(c.strand, "seed-c"),
  ]
  let found = joining(rig, pair, sessions, own)
  let assert Ok(_entries) = child_join.join(found, [a, b, c], 1000)

  // Only the one that is done and owes nothing has its session ended, and ending
  // it again changes nothing, so a join that repeats the question repeats it.
  assert list.filter(events(rig), fn(event) {
      case event {
        Released(..) -> True
        _ -> False
      }
    })
    == [Released("seed-a")]
  assert eventually_events(rig, events(rig))
}

pub fn a_child_with_no_session_makes_the_join_refuse_and_makes_none_test() {
  let rig = rig()
  let a = handle("a")
  let pair = session(rig, "pair", ready(_, 0), 1)
  let found = joining(rig, pair, [], [#(a.strand, "seed-a")])
  assert child_join.join(found, [a], 1000)
    == Error(remote_spawn.InvalidArgument(
      reason: "this orchestrator holds no such child for that parent",
    ))
  assert events(rig) == []
}

pub fn a_refusal_from_any_group_is_the_joins_refusal_test() {
  let rig = rig()
  let a = handle("a")
  let b = handle("b")
  let pair = session(rig, "pair", ready(_, 0), 1)
  let found =
    Joining(..joining(rig, pair, [], [#(a.strand, "seed-a")]), pair: fn() {
      Error(remote_spawn.CapReached(remote_spawn.MaxSessions, 4))
    })
  let sessions = [#("seed-a", session(rig, "seed-a", ready(_, 0), 1))]
  let found = Joining(..found, children: children(rig, sessions))
  assert child_join.join(found, [a, b], 1000)
    == Error(remote_spawn.CapReached(remote_spawn.MaxSessions, 4))
}
