//// A join over children that run in different sessions of one parent
//// (protocol-change/107, slice 4b).
////
//// Every session is a stub that records what it was asked, and the return is a
//// stub that records which entries it settled and whether it was given the
//// session's record of its workspace. What the tests look at is routing, order,
//// concurrency, when a child's session is ended, and that a join asked again after
//// the session is gone gets the answer the first one did. The registry's release
//// really removes the session here, so a repeated question reaches no session and
//// is answered from what the return kept.

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
import telemetry/log
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
  Rig(
    journal: Cell(List(Event)),
    together: Cell(Int),
    // The entries the return kept, by strand.
    kept: Cell(dict.Dict(String, Joined)),
    // The sessions that exist. A release removes one.
    held: Cell(dict.Dict(String, agency.DelegateEndpoint)),
    // Whether keeping an entry fails, and whether a kept entry cannot be read.
    keep_fails: Cell(Bool),
    kept_unreadable: Cell(Bool),
  )
}

fn rig() -> Rig {
  Rig(
    journal: cell.new([]),
    together: cell.new(0),
    kept: cell.new(dict.new()),
    held: cell.new(dict.new()),
    keep_fails: cell.new(False),
    kept_unreadable: cell.new(False),
  )
}

// What the registry says of a session that has been released: it is gone, or it is
// being released and refuses as its run having ended.
type Departure {
  Gone
  Releasing
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
    fresh: fn() { session_states.Fresh },
    states: Some(
      session_states.SessionStates(
        executor: "runner",
        branch: "loom/session",
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
      // that asked them in turn would find the second never came, and its
      // question fails.
      let met = case meeting > 1 {
        True -> meet(rig, meeting)
        False -> True
      }
      case met {
        True -> Ok(list.map(handles, answer))
        False -> Error(remote_spawn.StoreFailure(reason: "never met"))
      }
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

fn meet(rig: Rig, others: Int) -> Bool {
  cell.update(rig.together, fn(held) { held + 1 })
  case
    poll.until(within: 1500, every: 5, attempt: fn() {
      case cell.get(rig.together) >= others {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
  {
    poll.Answered(Nil) -> True
    poll.Failed(_) | poll.Expired -> False
  }
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
fn returning(
  rig: Rig,
  own: List(#(String, String)),
  unreadable: List(String),
) -> spawn_return.Returning {
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
      case
        list.contains(unreadable, found.strand),
        dict.get(names, found.strand)
      {
        True, _ -> spawn_return.Unreadable
        False, Ok(name) -> spawn_return.OwnSession(name:)
        False, Error(Nil) -> spawn_return.Unseeded
      }
    },
    keep: fn(_spawner, _parent, entry) {
      case cell.get(rig.keep_fails) {
        True -> Error(Nil)
        False -> {
          cell.update(rig.kept, fn(held) {
            dict.insert(held, strand_of(entry), entry)
          })
          Ok(Nil)
        }
      }
    },
    kept: fn(_spawner, _parent, found) {
      case
        cell.get(rig.kept_unreadable),
        dict.get(cell.get(rig.kept), found.strand)
      {
        True, _ -> spawn_return.KeptUnreadable
        False, Ok(entry) -> spawn_return.AnswerKept(entry:)
        False, Error(Nil) -> spawn_return.NothingKept
      }
    },
  )
}

fn children(
  rig: Rig,
  sessions: List(#(String, agency.DelegateEndpoint)),
  after: Departure,
) -> delegate_host.ChildSessions {
  cell.update(rig.held, fn(_held) { dict.from_list(sessions) })
  let departed = cell.new([])
  delegate_host.ChildSessions(
    resolve: fn(_spawner, _parent, _name) { Error(unused()) },
    open: fn(_spawner, _parent, name) {
      case
        dict.get(cell.get(rig.held), name),
        list.contains(cell.get(departed), name),
        after
      {
        Ok(found), _, _ -> Ok(Some(found))

        // The registry refuses a session that is being released as its run having
        // ended, and has none for one that is gone.
        Error(Nil), True, Releasing -> Error(remote_spawn.ParentRunEnded)
        Error(Nil), _, _ -> Ok(None)
      }
    },
    resident: fn(_spawner, _parent, name) {
      Ok(option.from_result(dict.get(cell.get(rig.held), name)))
    },
    live: fn(_spawner, _parent) { Ok([]) },
    release: fn(_spawner, _parent, name) {
      record(rig, Released(name))
      cell.update(rig.held, fn(held) { dict.delete(held, name) })
      cell.update(departed, fn(names) { [name, ..names] })
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
    children: children(rig, sessions, Gone),
    returning: returning(rig, own, []),
    logger: log.discard(),
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

fn ready_of(entry: Joined) -> Bool {
  case entry {
    remote_spawn.Ready(..) -> True
    remote_spawn.Pending(..) -> False
  }
}

pub fn a_child_with_no_session_and_no_kept_answer_is_told_it_is_unknown_test() {
  let rig = rig()
  let a = handle("a")
  let pair = session(rig, "pair", ready(_, 0), 1)
  let found = joining(rig, pair, [], [#(a.strand, "seed-a")])

  // The child's own answer says why, and no session is made for it.
  let assert Ok([entry]) = child_join.join(found, [a], 1000)
  let assert remote_spawn.Ready(outcome: agent.Failed(reason:), ..) = entry
  assert reason == "this orchestrator holds no such child for that parent"
  assert events(rig) == []
}

pub fn the_pairs_refusal_is_the_joins_and_a_seeded_childs_is_the_childs_test() {
  let rig = rig()
  let a = handle("a")
  let b = handle("b")
  let pair = session(rig, "pair", ready(_, 0), 1)
  let found =
    Joining(..joining(rig, pair, [], [#(a.strand, "seed-a")]), pair: fn() {
      Error(remote_spawn.CapReached(remote_spawn.MaxSessions, 4))
    })
  let sessions = [#("seed-a", session(rig, "seed-a", ready(_, 0), 1))]
  let found = Joining(..found, children: children(rig, sessions, Gone))

  // The pair's group answers for handles it does not name, so its refusal is the
  // whole join's, as it always was.
  assert child_join.join(found, [a, b], 1000)
    == Error(remote_spawn.CapReached(remote_spawn.MaxSessions, 4))
}

pub fn one_bad_handle_in_the_pairs_group_does_not_settle_the_others_test() {
  let rig = rig()
  let a = handle("a")
  let b = handle("b")
  let c = handle("c")
  let refusing =
    agency.DelegateEndpoint(
      ..session(rig, "pair", ready(_, 0), 1),
      join: fn(_parent, _handles, _within_ms) {
        Error(remote_spawn.InvalidArgument(reason: "b is not a descendant"))
      },
    )
  let sessions = [#("seed-a", session(rig, "seed-a", ready(_, 0), 1))]
  let found =
    Joining(
      ..joining(rig, refusing, sessions, [#(a.strand, "seed-a")]),
      children: children(rig, sessions, Gone),
    )

  // The pair's group names b and c and refuses for b. Marking both failed would
  // settle c's stub on b's account, so the refusal is the join's.
  assert child_join.join(found, [a, b, c], 1000)
    == Error(remote_spawn.InvalidArgument(reason: "b is not a descendant"))
}

pub fn a_seeded_childs_refusal_is_that_childs_by_whether_it_clears_test() {
  let rig = rig()
  let a = handle("a")
  let b = handle("b")
  let pair = session(rig, "pair", ready(_, 0), 1)
  let refusing = fn(refusal) {
    agency.DelegateEndpoint(
      ..session(rig, "seed-a", ready(_, 0), 1),
      join: fn(_parent, _handles, _within_ms) { Error(refusal) },
    )
  }
  let one = fn(refusal) {
    let sessions = [
      #("seed-a", refusing(refusal)),
      #("seed-b", session(rig, "seed-b", ready(_, 0), 1)),
    ]
    let found =
      Joining(
        ..joining(rig, pair, sessions, [
          #(a.strand, "seed-a"),
          #(b.strand, "seed-b"),
        ]),
        children: children(rig, sessions, Gone),
      )
    let assert Ok([first, second]) = child_join.join(found, [a, b], 1000)
    assert ready_of(second)
    first
  }

  // A refusal that never clears is the child's failure with its reason.
  let assert remote_spawn.Ready(outcome: agent.Failed(reason:), ..) =
    one(remote_spawn.StoreFailure(reason: "the session cannot recover"))
  assert reason != ""
  let assert remote_spawn.Ready(outcome: agent.Failed(..), ..) =
    one(remote_spawn.CapReached(remote_spawn.MaxSessions, 4))

  // One that asks to come again leaves the child unfinished.
  let assert remote_spawn.Pending(..) =
    one(remote_spawn.NotYetOpen(reason: "the session is opening"))
}

pub fn an_entry_that_could_not_be_kept_leaves_its_session_where_it_is_test() {
  let rig = rig()
  let a = handle("a")
  let pair = session(rig, "pair", ready(_, 0), 1)
  let sessions = [#("seed-a", session(rig, "seed-a", ready(_, 0), 1))]
  let found = joining(rig, pair, sessions, [#(a.strand, "seed-a")])
  cell.update(rig.keep_fails, fn(_) { True })

  // The join is answered, and the session stays, so that a repeat reaches it and
  // is answered from it and not refused with nothing to answer from.
  let assert Ok([first]) = child_join.join(found, [a], 1000)
  assert first == ready(a, 0)
  assert dict.size(cell.get(rig.held)) == 1
  let assert Ok([again]) = child_join.join(found, [a], 1000)
  assert again == first
}

pub fn a_kept_entry_that_cannot_be_read_is_not_a_refusal_test() {
  let rig = rig()
  let a = handle("a")
  let pair = session(rig, "pair", ready(_, 0), 1)
  let found = joining(rig, pair, [], [#(a.strand, "seed-a")])
  cell.update(rig.kept_unreadable, fn(_) { True })

  // The child settled and its answer is there and does not read: the join says it
  // is still finishing, and does not say the orchestrator holds no such child.
  let assert Ok([entry]) = child_join.join(found, [a], 1000)
  let assert remote_spawn.Pending(..) = entry
}

pub fn a_join_asked_again_after_its_session_was_released_gets_the_same_answer_test() {
  let rig = rig()
  let a = handle("a")
  let pair = session(rig, "pair", ready(_, 0), 1)
  let sessions = [#("seed-a", session(rig, "seed-a", ready(_, 0), 1))]
  let found = joining(rig, pair, sessions, [#(a.strand, "seed-a")])

  // The first join answers from the session and ends it, which really removes it.
  let assert Ok([first]) = child_join.join(found, [a], 1000)
  assert first == ready(a, 0)
  assert dict.size(cell.get(rig.held)) == 0

  // Asked again, and as often as it is asked, the join reaches no session and
  // answers what it did, and ends nothing a second time.
  let assert Ok([again]) = child_join.join(found, [a], 1000)
  let assert Ok([third]) = child_join.join(found, [a], 1000)
  assert again == first
  assert third == first
  assert list.length(
      list.filter(events(rig), fn(event) {
        case event {
          Released(..) -> True
          _ -> False
        }
      }),
    )
    == 1
}

pub fn a_session_being_released_answers_from_the_kept_entry_too_test() {
  let rig = rig()
  let a = handle("a")
  let pair = session(rig, "pair", ready(_, 0), 1)
  let sessions = [#("seed-a", session(rig, "seed-a", ready(_, 0), 1))]
  let found =
    Joining(
      ..joining(rig, pair, sessions, [#(a.strand, "seed-a")]),
      children: children(rig, sessions, Releasing),
    )

  // After the release the registry refuses the session as its run having ended,
  // and the join still answers what the first did.
  let assert Ok([first]) = child_join.join(found, [a], 1000)
  let assert Ok([again]) = child_join.join(found, [a], 1000)
  assert again == first
}

pub fn a_second_wait_for_eight_children_is_answered_whichever_settled_first_test() {
  let rig = rig()
  let strands = ["h1", "h2", "h3", "h4", "h5", "h6", "h7", "h8"]
  let handles = list.map(strands, handle)
  let pair = session(rig, "pair", ready(_, 0), 1)

  // h1 has finished and owes nothing; the other seven are still running. Each
  // child has a session of its own.
  let sessions =
    list.map(handles, fn(each) {
      let name = "seed-" <> each.strand
      let answer = case each.strand == handle("h1").strand {
        True -> ready(_, 0)
        False -> fn(found) { remote_spawn.Pending(found, 5) }
      }
      #(name, session(rig, name, answer, 1))
    })
  let own =
    list.map(handles, fn(each) { #(each.strand, "seed-" <> each.strand) })
  let found = joining(rig, pair, sessions, own)

  // The first wait settles h1 and ends its session.
  let assert Ok(first) = child_join.join(found, handles, 1000)
  assert list.map(first, ready_of)
    == [True, False, False, False, False, False, False, False]

  // The second wait names all eight again. h1 has no session now, and it must
  // not fail the wait for the seven that are still running.
  let assert Ok(second) = child_join.join(found, handles, 1000)
  assert list.map(second, strand_of)
    == list.map(handles, fn(each) { each.strand })
  assert list.map(second, ready_of)
    == [True, False, False, False, False, False, False, False]
  assert list.first(second) == list.first(first)
}

pub fn a_child_whose_record_cannot_be_read_is_not_finished_and_not_refused_test() {
  let rig = rig()
  let a = handle("a")
  let b = handle("b")
  let pair = session(rig, "pair", ready(_, 0), 1)
  let found =
    Joining(
      ..joining(rig, pair, [], []),
      returning: returning(rig, [], [a.strand]),
    )

  // a is left out of every group and answered Pending, and b is answered.
  let assert Ok(entries) = child_join.join(found, [a, b], 1000)
  assert list.map(entries, ready_of) == [False, True]
}
