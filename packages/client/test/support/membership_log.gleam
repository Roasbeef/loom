//// Logs for the membership ledger tests: a builder that applies each entry to
//// a ledger as it is appended, and a seeded generator of valid random logs.
////
//// The generator is a linear congruential generator over big integers, so a
//// failing seed reproduces exactly and no test depends on a clock or on the
//// system's random bytes. It draws operations at random and keeps those the
//// real fold accepts, so what it builds is valid by construction; `model`
//// restates the fold apart from the ledger so a test can compare the two.

import client/distribution_plan.{Executor, Orchestrator}
import client/membership_entry.{
  type Entry, type Kind, type Member, type SignedEntry, Genesis, Learner, Member,
  NotInDirectory, Revoke, Upsert, Voter,
}
import client/membership_ledger.{type Ledger}
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import support/membership_fixture as fixture

// --- a log under construction ------------------------------------------------

/// A ledger together with the signed entries that produced it, newest first.
pub type Log {
  Log(ledger: Ledger, entries: List(SignedEntry))
}

/// A log holding only the genesis entry.
pub fn genesis() -> Log {
  let signed =
    fixture.seal(fixture.entry(
      0,
      membership_entry.genesis_prev(),
      fixture.genesis_kind(),
    ))
  let assert Ok(ledger) = membership_ledger.start(signed)
    as "the fixture genesis is valid"
  Log(ledger:, entries: [signed])
}

/// The entry of the given kind that comes next after the log's head.
pub fn next_entry(log: Log, kind: Kind) -> Entry {
  let head = membership_ledger.head(log.ledger)
  fixture.entry(head.seq + 1, head.id, kind)
}

/// Appends an entry of the given kind, or says why the fold refused it.
pub fn push(log: Log, kind: Kind) -> Result(Log, membership_ledger.Refusal) {
  let signed = fixture.seal(next_entry(log, kind))
  case membership_ledger.apply(log.ledger, signed) {
    Ok(membership_ledger.Applied(ledger:, entry:)) ->
      Ok(Log(ledger:, entries: [entry, ..log.entries]))
    Ok(membership_ledger.Duplicate) | Ok(membership_ledger.Gap(_)) ->
      panic as "an entry built at head plus one is neither a duplicate nor a gap"
    Error(refusal) -> Error(refusal)
  }
}

/// Appends an entry that the fold must accept.
pub fn must_push(log: Log, kind: Kind) -> Log {
  let assert Ok(next) = push(log, kind) as "the fixture entry is valid"
  next
}

/// Enrolls a default member.
pub fn enroll(log: Log, name: String, links: List(String)) -> Log {
  must_push(log, Upsert(fixture.member(name, links)))
}

/// Revokes a default member.
pub fn revoke(log: Log, name: String) -> Log {
  must_push(log, fixture.revoke_kind(name))
}

/// The lines of a log in order, oldest first.
pub fn lines(log: Log) -> List(BitArray) {
  list.reverse(log.entries) |> list.map(membership_entry.line)
}

// --- seeded generation -------------------------------------------------------

/// The state of the generator.
pub type Seed {
  Seed(state: Int)
}

fn step(seed: Seed) -> Seed {
  Seed(int.bitwise_and(
    seed.state * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407,
    0xFFFFFFFFFFFFFFFF,
  ))
}

/// A number in `0..bound-1` and the next seed. A bound under 1 yields 0.
pub fn below(seed: Seed, bound: Int) -> #(Int, Seed) {
  let next = step(seed)
  let high = int.bitwise_shift_right(next.state, 24)
  case bound < 1 {
    True -> #(0, next)
    False -> #(high % bound, next)
  }
}

fn pick(seed: Seed, options: List(a)) -> #(a, Seed) {
  let #(index, next) = below(seed, list.length(options))
  let assert [chosen, ..] = list.drop(options, index)
    as "the index is below the length"
  #(chosen, next)
}

const names = [
  "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
]

fn random_member(
  seed: Seed,
  ledger: Ledger,
  name: String,
  generation: Int,
) -> #(Member, Seed) {
  let active =
    membership_ledger.members(ledger)
    |> list.map(fn(member) { member.name })
    |> list.filter(fn(other) { other != name })
  let #(links, seed) = random_subset(seed, active, 3)
  let #(role, seed) = pick(seed, [Executor, Orchestrator])
  let #(directory, seed) =
    pick(seed, [NotInDirectory, NotInDirectory, Voter, Learner])
  let #(port, seed) = pick(seed, [None, Some(4369), Some(40_000)])
  let base = fixture.member(name, links)
  #(
    Member(
      ..base,
      role:,
      directory:,
      listen_port: port,
      pin: fixture.pin_for(name, generation),
    ),
    seed,
  )
}

fn random_subset(
  seed: Seed,
  options: List(String),
  limit: Int,
) -> #(List(String), Seed) {
  list.fold(options, #([], seed), fn(state, option) {
    let #(chosen, seed) = state
    let #(roll, seed) = below(seed, 3)
    case roll == 0 && list.length(chosen) < limit {
      True -> #([option, ..chosen], seed)
      False -> #(chosen, seed)
    }
  })
}

/// A valid log built by choosing random operations against the real fold and
/// keeping those it accepts: enrolling, amending, renewing, revoking and
/// re-enrolling members from a small pool of names. The result holds at most
/// `length` entries after genesis.
///
/// The second value is the ledger after each prefix, oldest first, so a test
/// can compare a replay with the state the builder saw.
pub fn random_log(seed: Seed, length: Int) -> #(Log, List(Ledger)) {
  let start = genesis()
  grow(seed, start, [start.ledger], length * 4, length, 1)
}

fn grow(
  seed: Seed,
  log: Log,
  states: List(Ledger),
  attempts: Int,
  wanted: Int,
  generation: Int,
) -> #(Log, List(Ledger)) {
  case attempts <= 0 || list.length(log.entries) > wanted {
    True -> #(log, list.reverse(states))
    False -> {
      let #(kind, seed) = random_kind(seed, log.ledger, generation)
      case push(log, kind) {
        Ok(next) ->
          grow(
            seed,
            next,
            [next.ledger, ..states],
            attempts - 1,
            wanted,
            generation + 1,
          )
        Error(_) ->
          grow(seed, log, states, attempts - 1, wanted, generation + 1)
      }
    }
  }
}

fn random_kind(seed: Seed, ledger: Ledger, generation: Int) -> #(Kind, Seed) {
  let #(roll, seed) = below(seed, 10)
  let #(name, seed) = pick(seed, names)
  case roll < 3, membership_ledger.member(ledger, name) {
    // A revoke of an active member, with the pin it holds.
    True, Ok(held) -> #(
      Revoke(name:, pin: held.pin, reason: "rotated out"),
      seed,
    )

    // An amendment keeps the pin, or a renewal changes it.
    False, Ok(held) -> {
      let #(candidate, seed) = random_member(seed, ledger, name, generation)
      let #(renew, seed) = below(seed, 3)
      case renew == 0 {
        True -> #(Upsert(candidate), seed)
        False -> #(Upsert(Member(..candidate, pin: held.pin)), seed)
      }
    }

    // An enrollment, or a re-enrollment of a revoked name.
    _, Error(Nil) -> {
      let #(candidate, seed) = random_member(seed, ledger, name, generation)
      #(Upsert(candidate), seed)
    }
  }
}

/// The names the generator draws from.
pub fn pool() -> List(String) {
  names
}

/// A model of the fold that reads only the entries: the active members after
/// the entries in order, with links to a revoked name removed. It is written
/// apart from the ledger so a test compares two statements of the rule.
pub fn model(entries: List(SignedEntry)) -> List(Member) {
  list.fold(entries, dict.new(), fn(active, signed) {
    case signed.entry.kind {
      Genesis(..) -> active
      Upsert(member:) -> dict.insert(active, member.name, member)
      Revoke(name:, ..) ->
        dict.delete(active, name)
        |> dict.map_values(fn(_, member) {
          Member(
            ..member,
            links: list.filter(member.links, fn(link) { link != name }),
          )
        })
    }
  })
  |> dict.values
  |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
}
