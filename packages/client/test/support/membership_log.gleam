//// Logs for the membership ledger tests: a builder that applies each entry to
//// a ledger as it is appended, the pool of names a generated log draws from,
//// and a model of the fold.
////
//// The builder pushes one entry at a time through the real fold, so a log it
//// holds is valid by construction. Choosing which entries to push is the
//// property test's job (`membership_ledger_property_test` drives it with
//// `statem`); `model` restates the fold apart from the ledger so a test can
//// compare the two.

import client/membership_entry.{
  type Entry, type Kind, type Member, type SignedEntry, Genesis, Member,
  NotInDirectory, Revoke, Upsert,
}
import client/membership_ledger.{type Ledger}
import gleam/dict.{type Dict}
import gleam/list
import gleam/result
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

// --- the names a generated log draws from -----------------------------------

const names = [
  "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
]

/// The names a generated log draws from, in the order the generator indexes
/// them.
pub fn pool() -> List(String) {
  names
}

// --- a model written from the wording of 086 ----------------------------------

// What the model remembers. `records` holds each active member exactly as its
// last entry wrote it, together with the incarnation of every name it linked
// to at that moment. `revokes` counts the revokes applied to each name, so the
// incarnation of a name is the number of times it has been revoked.
type Model {
  Model(records: Dict(String, Record), revokes: Dict(String, Int))
}

type Record {
  Record(member: Member, listed: List(#(String, Int)))
}

fn incarnation(model: Model, name: String) -> Int {
  result.unwrap(dict.get(model.revokes, name), 0)
}

fn fold_model(entries: List(SignedEntry)) -> Model {
  list.fold(entries, Model(dict.new(), dict.new()), fn(model, signed) {
    case signed.entry.kind {
      Genesis(..) -> model
      Upsert(member:) -> {
        let listed =
          list.map(member.links, fn(link) { #(link, incarnation(model, link)) })
        Model(
          ..model,
          records: dict.insert(
            model.records,
            member.name,
            Record(member:, listed:),
          ),
        )
      }
      Revoke(name:, ..) ->
        Model(
          records: dict.delete(model.records, name),
          revokes: dict.insert(
            model.revokes,
            name,
            incarnation(model, name) + 1,
          ),
        )
    }
  })
}

// A link is live while its target is active and has not been revoked since the
// link was written.
fn is_live(model: Model, link: #(String, Int)) -> Bool {
  let #(target, written) = link
  dict.has_key(model.records, target) && incarnation(model, target) == written
}

/// A model of the fold, written from the wording of 086 and not from the
/// ledger's code, so a test compares two independent statements of the rule.
///
/// The ledger prunes a revoked name from the stored `links` of every other
/// member as it applies the revoke. The model stores nothing of the kind: it
/// keeps each member as its last entry wrote it, and tags every link with how
/// many times its target had been revoked when the link was written. A link is
/// live at query time only if its target is active and has been revoked no more
/// often since, which is the sentence in 086's fold: a name enrolled again holds
/// no edge it was not given anew. A model which merely filtered `links` against
/// the active set would give a re-enrolled name its old edges back, which 086
/// forbids.
///
/// Returns the active members ordered by name, with the live links only.
pub fn model(entries: List(SignedEntry)) -> List(Member) {
  let model = fold_model(entries)
  dict.values(model.records)
  |> list.map(fn(record) {
    let live = list.filter(record.listed, is_live(model, _))
    Member(..record.member, links: list.map(live, fn(link) { link.0 }))
  })
  |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
}

/// The number of links, among the active members, whose target is active now
/// but was revoked after the link was written. These are the edges the ledger
/// must have pruned and a re-enrollment must not revive; a test uses the count
/// to show a log exercises the rule.
pub fn stale_edges(entries: List(SignedEntry)) -> Int {
  let model = fold_model(entries)
  dict.values(model.records)
  |> list.flat_map(fn(record) { record.listed })
  |> list.count(fn(link) {
    dict.has_key(model.records, link.0) && !is_live(model, link)
  })
}

/// The names of the members the node `name` accepts, ordered, per the model:
/// the active members other than itself that it lists, that list it, or that
/// share a directory standing with it. A name that is not active accepts none.
pub fn model_peers(entries: List(SignedEntry), name: String) -> List(String) {
  let members = model(entries)
  case list.find(members, fn(member) { member.name == name }) {
    Error(Nil) -> []
    Ok(own) ->
      list.filter(members, fn(other) {
        other.name != name
        && {
          list.contains(own.links, other.name)
          || list.contains(other.links, name)
          || {
            own.directory != NotInDirectory && other.directory != NotInDirectory
          }
        }
      })
      |> list.map(fn(other) { other.name })
  }
}
