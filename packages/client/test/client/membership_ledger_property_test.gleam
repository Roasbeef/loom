//// Laws of the membership ledger (protocol-change/086, "What it costs"),
//// checked over generated histories rather than hand-picked ones.
////
//// A history is a list of commands, driven by `statem`. Most commands append
//// an entry: enroll a name that is not active, amend an active member, renew
//// its pin, or revoke it. They refer to names by an index taken modulo the
//// model's active or inactive names, so deleting a command while shrinking
//// leaves later ones meaningful. The model is only the active names with the
//// generation of each one's pin, and the number of entries appended. The system
//// under test is the real fold, held as a `membership_log.Log` plus the ledger
//// after each prefix.
////
//// Three families of command share the history:
////
//// - **Appends** must be accepted, and the state they leave is held to every
////   law below that is stated of a ledger. This is stronger than the old
////   generator, which kept whatever the fold accepted: here the model says an
////   entry is valid and the fold has to agree.
//// - **Refusals** are entries a signer could write which break one rule of the
////   fold: a node taken by another member, a pin taken, a link to a name that
////   is not active or to the member itself, a revoke of a name that is not
////   active. Each must be refused with exactly that rule.
//// - **Probes** change nothing in the model. They offer the ledger an entry it
////   should not apply (a duplicate, a gap, a fork) or damage the log in one
////   place (a flipped bit, two swapped entries, a removed entry, a truncated
////   line, a mutated body signed afresh), and say where the refusal must come.
////
//// After every command `observe` checks the laws of a ledger: the active names
//// equal the model's, the members equal what `membership_log.model` derives
//// from the entries alone, each name's pin table equals
//// `membership_log.model_peers`, links between active members are symmetric,
//// and no table holds the pin of a name that is revoked or never enrolled.
//// When a history ends, `finish` checks the laws of a whole log: replaying it
//// equals applying it entry by entry and equals the states the builder saw,
//// every prefix is valid, a log split anywhere gives the same ledger, three
//// nodes that heard it by different routes hold the same state, and every entry
//// survives encoding. Each law carries its own violation tag, so shrinking
//// keeps a failure on the law that first broke.
////
//// The tests that are not sequences stay plain `qcheck`: the decoder is total
//// over arbitrary bytes and over JSON-shaped fragments, an arbitrary
//// well-formed entry round trips, every bit of one short line is refused, and
//// a node on one branch never applies the other.
////
//// A passing property says nothing if the generator never reaches the case a
//// law is about, so `the_histories_reach_every_case_the_laws_need_test` counts
//// what `statem.commands` draws over the same runs and fails if revokes, links,
//// pruned edges, refusals or any probe go missing.

import client/distribution_plan.{type Role, Executor, Orchestrator}
import client/membership_entry.{
  type DirectoryStanding, type Entry, type Kind, type Member, type SignedEntry,
  Entry, Genesis, Learner, Member, NotInDirectory, Revoke, Upsert, Voter,
}
import client/membership_ledger.{type Ledger, Applied, Duplicate, Fork, Gap}
import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import qcheck
import statem
import support/membership_fixture as fixture
import support/membership_log as history

// --- the campaign -----------------------------------------------------------

// The seed of the one campaign. It is the proposal's number, so a reader who
// has to pick another has no reason to.
const campaign_seed = 86

// How many histories the campaign runs. The generator that came before drew
// forty logs; this is the same figure.
const runs = 40

// The most commands in one history. A history is as long as `statem` draws it,
// up to this, and about two in three of its commands append an entry, so the
// logs hold about as many entries as the generator before this one drew.
const longest = 80

// How many cases the plain `qcheck` properties draw, and the seed they share.
const arbitrary_runs = 3000

const arbitrary_seed = 17

fn config() -> statem.Config {
  statem.default_config(seed: campaign_seed)
  |> statem.with_test_count(runs)
  |> statem.with_max_commands(longest)
}

// --- commands ---------------------------------------------------------------

// A link to another active member, by position among them. A type of its own
// so a shape prints as `Link(2)` and not as a string of the integer's codepoint.
type Link {
  Link(index: Int)
}

// How an enrolled or amended member differs from the fixture default. Every
// field shrinks toward the default: no links, an executor, no directory
// standing, no listening port. `links` are indices into the other active
// members, resolved when the command runs and at most three of them kept.
type Shape {
  Shape(
    links: List(Link),
    role: Role,
    directory: DirectoryStanding,
    port: Option(Int),
  )
}

// The rule an entry written to be refused breaks.
type Fault {
  // A member that takes the node of another active member.
  NodeTaken

  // A member that takes the pin of another active member.
  PinTaken

  // A link to a name that is not active.
  LinkInactive

  // A member that lists itself.
  LinkSelf

  // A revoke of a name that is not active.
  RevokeInactive
}

type Command {
  // Enrolls the `slot`-th name that is not active, which may be a name that
  // was revoked earlier.
  JoinNew(slot: Int, shape: Shape)

  // Rewrites the `member`-th active member, keeping its pin.
  Amend(member: Int, shape: Shape)

  // Rewrites the `member`-th active member under a new pin.
  Renew(member: Int, shape: Shape)

  // Revokes the `member`-th active member.
  Leave(member: Int)

  // Offers an entry that breaks `fault`. `member` and `other` choose the
  // names it involves, each modulo the names that fit.
  Refuse(fault: Fault, member: Int, other: Int)

  // Offers the ledger a line it already holds, counted from the newest.
  Redeliver(line: Int)

  // Offers the ledger a line two ahead of its head.
  Skip

  // Offers the ledger a different signed entry at the sequence number of a line
  // it holds, counted from the newest.
  Rival(line: Int)

  // Flips one bit of one line of the log, counted from the newest.
  Flip(line: Int, position: Int, bit: Int)

  // Swaps two lines of the log. `first` counts the later one from the newest
  // and `gap` how far before it the other is.
  Swap(first: Int, gap: Int)

  // Removes one line from the middle of the log, counted from the newest.
  Drop(line: Int)

  // Cuts one line short, after the genesis, counted from the newest.
  Truncate(line: Int, cut: Int)

  // Overwrites one byte of an entry's body, counted from the newest, and signs
  // the result afresh.
  Mutate(line: Int, position: Int, byte: Int)
}

// --- the model --------------------------------------------------------------

// An active member and the generation of its pin. A renewal is a new
// generation, so the pin differs; an amendment keeps it.
type Holder {
  Holder(name: String, generation: Int)
}

// The active members in name order, and how many entries follow the genesis.
type Model {
  Model(active: List(Holder), appended: Int)
}

fn initial() -> Model {
  Model(active: [], appended: 0)
}

// The names of the active members.
fn names_of(holders: List(Holder)) -> List(String) {
  list.map(holders, fn(holder) { holder.name })
}

// The names of the pool that are not active.
fn inactive(model: Model) -> List(String) {
  let active = names_of(model.active)
  list.filter(history.pool(), fn(name) { !list.contains(active, name) })
}

// The `index`-th item, wrapping, or `Error` when there are none. Indices are
// never negative, because every generator below starts at zero.
fn pick(items: List(a), index: Int) -> Result(a, Nil) {
  case list.length(items) {
    0 -> Error(Nil)
    size -> list.drop(items, index % size) |> list.first
  }
}

fn held(model: Model, name: String) -> Option(Holder) {
  list.find(model.active, fn(holder) { holder.name == name })
  |> option.from_result
}

// The model with `holder` active, in name order.
fn hold(model: Model, holder: Holder) -> Model {
  let others =
    list.filter(model.active, fn(other) { other.name != holder.name })
  let active =
    list.sort([holder, ..others], fn(a, b) { string.compare(a.name, b.name) })
  Model(active:, appended: model.appended + 1)
}

fn release(model: Model, name: String) -> Model {
  Model(
    active: list.filter(model.active, fn(holder) { holder.name != name }),
    appended: model.appended + 1,
  )
}

// What a command means in a model: an entry the fold must accept and the model
// after it, an entry it must refuse by a named rule, or a probe that changes
// nothing in the model. `Error` means the command names something that does not
// exist yet, and the precondition rejects it.
type Plan {
  Appends(kind: Kind, next: Model)
  Refuses(kind: Kind, rule: membership_ledger.Rule)
  Probes
}

fn plan(model: Model, command: Command) -> Result(Plan, Nil) {
  case command {
    JoinNew(slot:, shape:) -> {
      use name <- result.try(pick(inactive(model), slot))
      let holder = Holder(name:, generation: model.appended + 1)
      let links = resolve_links(shape.links, names_of(model.active))
      Ok(Appends(
        kind: Upsert(member_of(name, shape, links, holder.generation)),
        next: hold(model, holder),
      ))
    }

    Amend(member:, shape:) -> {
      use holder <- result.try(pick(model.active, member))
      Ok(rewrite(model, holder, shape, holder.generation))
    }

    Renew(member:, shape:) -> {
      use holder <- result.try(pick(model.active, member))
      Ok(rewrite(model, holder, shape, model.appended + 1))
    }

    Leave(member:) -> {
      use holder <- result.try(pick(model.active, member))
      Ok(Appends(
        kind: Revoke(
          name: holder.name,
          pin: fixture.pin_for(holder.name, holder.generation),
          reason: "rotated out",
        ),
        next: release(model, holder.name),
      ))
    }

    Refuse(fault:, member:, other:) -> refusal(model, fault, member, other)

    Redeliver(..) | Skip | Rival(..) | Flip(..) | Mutate(..) -> Ok(Probes)

    // These need entries after the genesis to have anything to damage: a
    // pair to swap, a middle entry to remove, a line past the genesis to cut.
    Swap(..) | Truncate(..) ->
      case model.appended >= 1 {
        True -> Ok(Probes)
        False -> Error(Nil)
      }

    Drop(..) ->
      case model.appended >= 2 {
        True -> Ok(Probes)
        False -> Error(Nil)
      }
  }
}

// An entry that rewrites `holder` with `shape`, linking only to the other
// active members, under the pin of `generation`.
fn rewrite(
  model: Model,
  holder: Holder,
  shape: Shape,
  generation: Int,
) -> Plan {
  let others =
    names_of(model.active) |> list.filter(fn(name) { name != holder.name })
  let links = resolve_links(shape.links, others)
  let renewed = Holder(..holder, generation:)
  Appends(
    kind: Upsert(member_of(holder.name, shape, links, generation)),
    next: hold(model, renewed),
  )
}

// The entry that breaks `fault`, and the rule the fold must name.
fn refusal(
  model: Model,
  fault: Fault,
  member: Int,
  other: Int,
) -> Result(Plan, Nil) {
  case fault {
    NodeTaken -> {
      use #(subject, rival) <- result.try(two_active(model, member, other))
      let node = fixture.member(rival.name, []).node
      let base = plain_member(subject)
      Ok(Refuses(
        kind: Upsert(Member(..base, node:)),
        rule: membership_ledger.NodeInUse(node:),
      ))
    }

    PinTaken -> {
      use #(subject, rival) <- result.try(two_active(model, member, other))
      let pin = fixture.pin_for(rival.name, rival.generation)
      Ok(Refuses(
        kind: Upsert(Member(..plain_member(subject), pin:)),
        rule: membership_ledger.PinInUse,
      ))
    }

    // The subject is any name of the pool, so the entry is sometimes an
    // enrollment and sometimes an amendment. The target is a name that is not
    // active, or one that was never enrolled.
    LinkInactive -> {
      use name <- result.try(pick(history.pool(), member))
      let targets =
        list.append(list.filter(inactive(model), fn(each) { each != name }), [
          "stranger",
        ])
      use target <- result.try(pick(targets, other))
      let generation = case held(model, name) {
        Some(holder) -> holder.generation
        None -> model.appended + 1
      }
      let base = fixture.member(name, [target])
      Ok(Refuses(
        kind: Upsert(Member(..base, pin: fixture.pin_for(name, generation))),
        rule: membership_ledger.UnknownLink(name: target),
      ))
    }

    LinkSelf -> {
      use subject <- result.try(pick(model.active, member))
      let base = fixture.member(subject.name, [subject.name])
      Ok(Refuses(
        kind: Upsert(
          Member(..base, pin: fixture.pin_for(subject.name, subject.generation)),
        ),
        rule: membership_ledger.UnknownLink(name: subject.name),
      ))
    }

    RevokeInactive -> {
      use name <- result.try(pick(
        list.append(inactive(model), ["stranger"]),
        member,
      ))
      Ok(Refuses(
        kind: Revoke(name:, pin: fixture.pin_for(name, 0), reason: "never held"),
        rule: membership_ledger.NotActive(name:),
      ))
    }
  }
}

// Two different active members: the subject and a rival chosen among the rest.
fn two_active(
  model: Model,
  member: Int,
  other: Int,
) -> Result(#(Holder, Holder), Nil) {
  use subject <- result.try(pick(model.active, member))
  let rest = list.filter(model.active, fn(each) { each.name != subject.name })
  use rival <- result.try(pick(rest, other))
  Ok(#(subject, rival))
}

// The member as the fixture writes it, keeping the pin it holds.
fn plain_member(holder: Holder) -> Member {
  Member(
    ..fixture.member(holder.name, []),
    pin: fixture.pin_for(holder.name, holder.generation),
  )
}

fn member_of(
  name: String,
  shape: Shape,
  links: List(String),
  generation: Int,
) -> Member {
  Member(
    ..fixture.member(name, links),
    role: shape.role,
    directory: shape.directory,
    listen_port: shape.port,
    pin: fixture.pin_for(name, generation),
  )
}

// The names the indices pick among `candidates`, without repeats, at most
// three, in the order they were drawn.
fn resolve_links(links: List(Link), candidates: List(String)) -> List(String) {
  list.filter_map(links, fn(link) { pick(candidates, link.index) })
  |> list.unique
  |> list.take(3)
}

// --- generating commands ----------------------------------------------------

// A small non-negative index. Every command that names a thing by position
// draws one, and the driver wraps it modulo how many things there are.
fn index() -> qcheck.Generator(Int) {
  qcheck.bounded_int(0, 63)
}

// A byte position in a line or a body. Lines are a few hundred bytes, so the
// range is wide enough that the modulo reaches the signature half of a line,
// where only the verifier can notice a damaged bit.
fn position() -> qcheck.Generator(Int) {
  qcheck.bounded_int(0, 2047)
}

fn bit() -> qcheck.Generator(Int) {
  qcheck.bounded_int(0, 7)
}

fn byte() -> qcheck.Generator(Int) {
  qcheck.bounded_int(0, 255)
}

fn role() -> qcheck.Generator(Role) {
  qcheck.bounded_int(0, 1)
  |> qcheck.map(fn(pick) {
    case pick {
      0 -> Executor
      _ -> Orchestrator
    }
  })
}

// The directory standings, with the absence of one twice as likely as either
// kind, so most members are linked by `links` and a few by the directory.
fn directory() -> qcheck.Generator(DirectoryStanding) {
  qcheck.bounded_int(0, 3)
  |> qcheck.map(fn(pick) {
    case pick {
      0 | 1 -> NotInDirectory
      2 -> Voter
      _ -> Learner
    }
  })
}

fn port() -> qcheck.Generator(Option(Int)) {
  qcheck.bounded_int(0, 2)
  |> qcheck.map(fn(pick) {
    case pick {
      0 -> None
      1 -> Some(4369)
      _ -> Some(40_000)
    }
  })
}

fn shape() -> qcheck.Generator(Shape) {
  qcheck.map4(
    qcheck.generic_list(qcheck.map(index(), Link), qcheck.bounded_int(0, 3)),
    role(),
    directory(),
    port(),
    fn(links, role, directory, port) { Shape(links:, role:, directory:, port:) },
  )
}

fn refuse(fault: Fault) -> qcheck.Generator(Command) {
  qcheck.map2(index(), index(), fn(member, other) {
    Refuse(fault:, member:, other:)
  })
}

type Weighted =
  List(#(Int, qcheck.Generator(Command)))

// Only the commands that mean something in the model are offered, weighted
// toward the ones that grow the log. The precondition still checks each draw,
// because a shrink candidate is replayed against it.
fn command(model: Model) -> qcheck.Generator(Command) {
  let weighted =
    list.flatten([
      always(),
      when_inactive(model),
      when_active(model),
      when_two_active(model),
      when_appended(model),
      when_two_appended(model),
    ])
  case weighted {
    [first, ..rest] -> qcheck.from_weighted_generators(first, rest)
    [] -> qcheck.constant(Skip)
  }
}

// The commands that mean something in every model, with the refusals that
// need no member: a link to a name that is not active, and a revoke of one.
fn always() -> Weighted {
  [
    #(3, refuse(LinkInactive)),
    #(3, refuse(RevokeInactive)),
    #(3, qcheck.map(index(), Redeliver)),
    #(2, qcheck.constant(Skip)),
    #(4, qcheck.map(index(), Rival)),
    #(5, qcheck.map3(index(), position(), bit(), Flip)),
    #(3, qcheck.map3(index(), position(), byte(), Mutate)),
  ]
}

fn when_inactive(model: Model) -> Weighted {
  case inactive(model) {
    [] -> []
    [_, ..] -> [#(30, qcheck.map2(index(), shape(), JoinNew))]
  }
}

fn when_active(model: Model) -> Weighted {
  case model.active {
    [] -> []
    [_, ..] -> [
      #(16, qcheck.map2(index(), shape(), Amend)),
      #(12, qcheck.map2(index(), shape(), Renew)),
      #(14, qcheck.map(index(), Leave)),
      #(3, refuse(LinkSelf)),
    ]
  }
}

fn when_two_active(model: Model) -> Weighted {
  case model.active {
    [] | [_] -> []
    [_, _, ..] -> [#(3, refuse(NodeTaken)), #(3, refuse(PinTaken))]
  }
}

fn when_appended(model: Model) -> Weighted {
  case model.appended {
    0 -> []
    _ -> [
      #(3, qcheck.map2(index(), index(), Swap)),
      #(3, qcheck.map2(index(), position(), Truncate)),
    ]
  }
}

fn when_two_appended(model: Model) -> Weighted {
  case model.appended {
    0 | 1 -> []
    _ -> [#(3, qcheck.map(index(), Drop))]
  }
}

// --- the system under test --------------------------------------------------

// The log the builder holds, and the ledger after every prefix of it, newest
// first like the log's own entries.
type Sut {
  Sut(log: history.Log, states: List(Ledger))
}

fn new_sut() -> Sut {
  let log = history.genesis()
  Sut(log:, states: [log.ledger])
}

fn violation(tag: String, detail: String) -> statem.Violation {
  statem.Violation(tag:, detail:)
}

// Compares what the ledger did with what the law says, and names the law.
fn agree(tag: String, got: a, wanted: a) -> Result(Nil, statem.Violation) {
  case got == wanted {
    True -> Ok(Nil)
    False ->
      Error(violation(
        tag,
        "expected "
          <> string.inspect(wanted)
          <> " but got "
          <> string.inspect(got),
      ))
  }
}

// The `index`-th item, wrapping. An empty list cannot happen: every probe is
// admitted only when the log holds what it names.
fn nth(items: List(a), index: Int) -> Result(a, statem.Violation) {
  pick(items, index)
  |> result.replace_error(violation("probe", "the log holds nothing to damage"))
}

// The integers from `start` up to, and not including, `stop`.
fn numbers(start: Int, stop: Int) -> List(Int) {
  int.range(from: start, to: stop, with: [], run: fn(all, number) {
    [number, ..all]
  })
  |> list.reverse
}

// The position of the line `offset` places from the newest of `size` lines.
// Probes name lines from the newest, so deleting commands from the front of a
// history while shrinking leaves them aimed at the entry written last, and the
// shortest history that breaks a law keeps its damaged line.
fn back(size: Int, offset: Int) -> Int {
  size - 1 - offset % int.max(size, 1)
}

fn sut_size(sut: Sut) -> Int {
  list.length(sut.log.entries)
}

fn chronological(log: history.Log) -> List(SignedEntry) {
  list.reverse(log.entries)
}

fn execute(
  sut: Sut,
  model: Model,
  command: Command,
) -> Result(Sut, statem.Violation) {
  case plan(model, command) {
    Error(Nil) -> Error(violation("unresolved", string.inspect(command)))
    Ok(Appends(kind:, next:)) -> append(sut, kind, next)
    Ok(Refuses(kind:, rule:)) -> refuse_entry(sut, kind, rule)
    Ok(Probes) -> probe(sut, command)
  }
}

// The fold must accept what the model says is valid, and `check`, the signer's
// pre-flight, must say the same. The state it leaves is held to every law.
fn append(sut: Sut, kind: Kind, next: Model) -> Result(Sut, statem.Violation) {
  case history.push(sut.log, kind) {
    Error(refusal) ->
      Error(violation(
        "accepted",
        "the fold refused an entry the model says is valid: "
          <> string.inspect(refusal),
      ))

    Ok(log) -> {
      use Nil <- result.try(agree(
        "check",
        membership_ledger.check(
          sut.log.ledger,
          history.next_entry(sut.log, kind),
        ),
        Ok(log.ledger),
      ))
      let moved = Sut(log:, states: [log.ledger, ..sut.states])
      use Nil <- result.try(observe(moved, next))
      Ok(moved)
    }
  }
}

// The fold must refuse an entry that breaks a rule, with that rule, and the
// ledger the caller keeps is the one it had.
fn refuse_entry(
  sut: Sut,
  kind: Kind,
  rule: membership_ledger.Rule,
) -> Result(Sut, statem.Violation) {
  let wanted = membership_ledger.Invalid(rule:)
  use Nil <- result.try(agree(
    "refused",
    result.map(history.push(sut.log, kind), fn(_) { Nil }),
    Error(wanted),
  ))
  use Nil <- result.try(agree(
    "check",
    result.map(
      membership_ledger.check(sut.log.ledger, history.next_entry(sut.log, kind)),
      fn(_) { Nil },
    ),
    Error(wanted),
  ))
  Ok(sut)
}

// --- the laws of a ledger, after every command ------------------------------

// The names a test asks a ledger about: every name the generator draws from,
// and one it never enrolls.
fn probes() -> List(String) {
  ["stranger", ..history.pool()]
}

fn observe(sut: Sut, model: Model) -> Result(Nil, statem.Violation) {
  let ledger = sut.log.ledger
  let entries = chronological(sut.log)
  let members = membership_ledger.members(ledger)

  use Nil <- result.try(agree(
    "active",
    list.map(members, fn(member) { member.name }),
    names_of(model.active),
  ))
  use Nil <- result.try(agree(
    "head",
    membership_ledger.head(ledger).seq,
    model.appended,
  ))

  // The ledger holds what a model that reads only the entries derives, with
  // the revoke's pruning stated in a different shape from the ledger's.
  use Nil <- result.try(agree("model", members, history.model(entries)))
  use Nil <- result.try(pin_tables(ledger, entries))
  use Nil <- result.try(symmetric(ledger, members))
  ghost_pins(ledger, entries)
}

// The table of every probed name names the peers the model derives from the
// entries alone.
fn pin_tables(
  ledger: Ledger,
  entries: List(SignedEntry),
) -> Result(Nil, statem.Violation) {
  list.try_each(probes(), fn(name) {
    let table = membership_ledger.pin_table(ledger, name)
    agree(
      "pin-table",
      list.map(membership_ledger.peers(table), fn(peer) { peer.name }),
      history.model_peers(entries, name),
    )
  })
}

fn is_peer(table: membership_ledger.PinTable, pin: BitArray) -> Bool {
  case membership_ledger.lookup_pin(table, pin) {
    Ok(_) -> True
    Error(Nil) -> False
  }
}

// For two active members, a accepts the pin of b exactly when b accepts the
// pin of a, because TLS needs both ends to agree.
fn symmetric(
  ledger: Ledger,
  members: List(Member),
) -> Result(Nil, statem.Violation) {
  list.try_each(list.combination_pairs(members), fn(pair) {
    let #(a, b) = pair
    agree(
      "symmetric",
      is_peer(membership_ledger.pin_table(ledger, a.name), b.pin),
      is_peer(membership_ledger.pin_table(ledger, b.name), a.pin),
    )
  })
}

// Every pin a name has been given in a prefix of a log, by an enrollment or
// by the revoke that removed it.
fn pins_given_to(entries: List(SignedEntry), name: String) -> List(BitArray) {
  list.filter_map(entries, fn(signed) {
    case signed.entry.kind {
      Upsert(member) if member.name == name -> Ok(member.pin)
      Revoke(name: revoked, pin:, ..) if revoked == name -> Ok(pin)
      Genesis(..) | Upsert(_) | Revoke(..) -> Error(Nil)
    }
  })
}

// No table holds the pin of a name that is revoked or was never enrolled.
fn ghost_pins(
  ledger: Ledger,
  entries: List(SignedEntry),
) -> Result(Nil, statem.Violation) {
  list.try_each(not_enrolled(ledger), fn(name) {
    list.try_each(pins_given_to(entries, name), fn(pin) {
      list.try_each(probes(), fn(node) {
        let table = membership_ledger.pin_table(ledger, node)
        agree("ghost-pin", is_peer(table, pin), False)
      })
    })
  })
}

// The probed names the ledger says are revoked or were never enrolled.
fn not_enrolled(ledger: Ledger) -> List(String) {
  list.filter(probes(), fn(name) {
    case membership_ledger.enrollment(ledger, name) {
      membership_ledger.Enrolled(..) -> False
      membership_ledger.Revoked | membership_ledger.NotEnrolled -> True
    }
  })
}

// --- probes -----------------------------------------------------------------

fn probe(sut: Sut, command: Command) -> Result(Sut, statem.Violation) {
  let lines = history.lines(sut.log)
  let states = list.reverse(sut.states)
  let outcome = case command {
    Redeliver(line:) -> redeliver(sut, lines, line)
    Skip -> skip(sut)
    Rival(line:) -> rival(sut, line)
    Flip(line:, position:, bit:) -> flip_one(lines, states, line, position, bit)
    Swap(first:, gap:) -> swap(lines, first, gap)
    Drop(line:) -> drop_one(lines, line)
    Truncate(line:, cut:) -> truncate(lines, states, line, cut)
    Mutate(line:, position:, byte:) -> mutate(sut, line, position, byte)
    JoinNew(..) | Amend(..) | Renew(..) | Leave(..) | Refuse(..) ->
      Error(violation("probe", "not a probe: " <> string.inspect(command)))
  }
  result.map(outcome, fn(_) { sut })
}

// A line the ledger holds is a duplicate, whichever one it is.
fn redeliver(
  sut: Sut,
  lines: List(BitArray),
  line: Int,
) -> Result(Nil, statem.Violation) {
  use held <- result.try(nth(lines, back(list.length(lines), line)))
  agree(
    "duplicate",
    membership_ledger.accept(sut.log.ledger, held, fixture.verifier()),
    Ok(Duplicate),
  )
}

// A line two past the head cannot be applied yet, and is no refusal.
fn skip(sut: Sut) -> Result(Nil, statem.Violation) {
  let head = membership_ledger.head(sut.log.ledger)
  let ahead =
    fixture.line(fixture.entry(
      head.seq + 2,
      head.id,
      Upsert(fixture.member("skipped", [])),
    ))
  agree(
    "gap",
    membership_ledger.accept(sut.log.ledger, ahead, fixture.verifier()),
    Ok(Gap(head:)),
  )
}

// A node that holds entries 0..head is shown a different signed entry at a
// sequence number it already holds. The refusal names both identities, and
// the ledger the caller keeps is the one it had: the next command applies to
// it, which is the proof that the refusal changed nothing.
fn rival(sut: Sut, line: Int) -> Result(Nil, statem.Violation) {
  use held <- result.try(nth(chronological(sut.log), back(sut_size(sut), line)))
  let rival = fixture.seal(Entry(..held.entry, time: fixture.other_stamp))
  agree(
    "fork",
    membership_ledger.accept(
      sut.log.ledger,
      membership_entry.line(rival),
      fixture.verifier(),
    ),
    Error(Fork(seq: held.entry.seq, ours: held.id, theirs: rival.id)),
  )
}

fn flip(
  line: BitArray,
  position: Int,
  bit: Int,
) -> Result(BitArray, statem.Violation) {
  case line {
    <<before:bytes-size(position), byte, after:bytes>> -> {
      let flipped =
        int.bitwise_exclusive_or(byte, int.bitwise_shift_left(1, bit))
      Ok(<<before:bits, flipped, after:bits>>)
    }
    _ -> Error(violation("probe", "the position is outside the line"))
  }
}

fn replace_at(items: List(a), index: Int, item: a) -> List(a) {
  list.index_map(items, fn(existing, position) {
    case position == index {
      True -> item
      False -> existing
    }
  })
}

fn replay(
  lines: List(BitArray),
) -> Result(Ledger, membership_ledger.ReplayError) {
  membership_ledger.replay(lines, fixture.verifier())
}

// A replay stops at the damaged line and nowhere earlier.
fn stops_at(
  tag: String,
  lines: List(BitArray),
  wanted: Int,
) -> Result(Nil, statem.Violation) {
  case replay(lines) {
    Error(membership_ledger.ReplayError(index:, ..)) ->
      agree(tag, index, wanted)
    Ok(_) -> Error(violation(tag, "the damaged log replayed without a refusal"))
  }
}

// One bit of one line is flipped. The ledger that holds the lines before it
// refuses the damaged one, and a replay of the whole file stops there.
fn flip_one(
  lines: List(BitArray),
  states: List(Ledger),
  line: Int,
  position: Int,
  bit: Int,
) -> Result(Nil, statem.Violation) {
  let index = back(list.length(lines), line)
  use original <- result.try(nth(lines, index))
  let place = position % bit_array.byte_size(original)
  use flipped <- result.try(flip(original, place, bit))
  use Nil <- result.try(agree(
    "flip-applied",
    refused_after(states, index, flipped),
    True,
  ))
  stops_at("flip-replay", replace_at(lines, index, flipped), index)
}

// Whether the ledger that holds the first `index` lines refuses `line`. For
// the first line there is no ledger yet, and `begin` must fail.
fn refused_after(states: List(Ledger), index: Int, line: BitArray) -> Bool {
  case index, list.drop(states, index - 1) {
    0, _ ->
      case membership_ledger.begin(line, fixture.verifier()) {
        Error(_) -> True
        Ok(_) -> False
      }
    _, [ledger, ..] ->
      case membership_ledger.accept(ledger, line, fixture.verifier()) {
        Error(_) -> True
        Ok(Applied(..)) | Ok(Duplicate) | Ok(Gap(_)) -> False
      }
    _, [] -> False
  }
}

// Two lines trade places. The replay stops at the earlier of the two.
fn swap(
  lines: List(BitArray),
  first: Int,
  gap: Int,
) -> Result(Nil, statem.Violation) {
  let size = list.length(lines)
  let later = 1 + back(size - 1, first)
  let earlier = back(later, gap)
  use one <- result.try(nth(lines, earlier))
  use other <- result.try(nth(lines, later))
  let swapped = lines |> replace_at(earlier, other) |> replace_at(later, one)
  stops_at("swap", swapped, earlier)
}

// A line leaves the middle of the log. The line after it no longer follows its
// predecessor, and the replay stops there.
fn drop_one(lines: List(BitArray), line: Int) -> Result(Nil, statem.Violation) {
  let removed = 1 + back(list.length(lines) - 2, line)
  let without =
    list.append(list.take(lines, removed), list.drop(lines, removed + 1))
  stops_at("drop", without, removed)
}

// A line after the genesis is cut short, and the ledger that holds the lines
// before it never accepts the stump.
fn truncate(
  lines: List(BitArray),
  states: List(Ledger),
  line: Int,
  cut: Int,
) -> Result(Nil, statem.Violation) {
  let index = 1 + back(list.length(lines) - 1, line)
  use original <- result.try(nth(lines, index))
  use stump <- result.try(
    bit_array.slice(original, 0, cut % bit_array.byte_size(original))
    |> result.replace_error(violation("probe", "the cut is outside the line")),
  )
  agree("truncate", refused_after(states, index, stump), True)
}

// The body of an entry is overwritten at one byte and signed afresh, so the
// signature is no obstacle and the decoder sees what a valid signer might have
// written. It decodes or it is refused, and what it decodes re-encodes.
fn mutate(
  sut: Sut,
  line: Int,
  position: Int,
  byte: Int,
) -> Result(Nil, statem.Violation) {
  use original <- result.try(nth(
    chronological(sut.log),
    back(sut_size(sut), line),
  ))
  let place = position % bit_array.byte_size(original.body)
  case original.body {
    <<before:bytes-size(place), _, after:bytes>> ->
      case
        membership_entry.read(
          signed_line_of(<<before:bits, byte, after:bits>>),
          fixture.verifier(),
        )
      {
        Error(_) -> Ok(Nil)
        Ok(signed) -> reencodes("mutated-body", signed.entry)
      }
    _ -> Error(violation("probe", "the position is outside the body"))
  }
}

fn signed_line_of(body: BitArray) -> BitArray {
  case fixture.signer()(membership_entry.signing_input(body)) {
    Ok(signature) -> membership_entry.frame_line(body, signature)
    Error(_) -> body
  }
}

// An entry the decoder accepted is one the encoder writes back to the same
// entry.
fn reencodes(tag: String, entry: Entry) -> Result(Nil, statem.Violation) {
  agree(
    tag,
    membership_entry.decode_body(membership_entry.encode_body(entry)),
    Ok(entry),
  )
}

// --- the laws of a whole log, when a history ends ---------------------------

// Applies lines in order through `accept`, requiring each to extend the chain,
// and returns every ledger on the way, oldest first, after the one it began
// with.
fn apply_lines(
  ledger: Ledger,
  lines: List(BitArray),
) -> Result(List(Ledger), statem.Violation) {
  list.try_fold(lines, [], fn(reached, line) {
    let from = case reached {
      [latest, ..] -> latest
      [] -> ledger
    }
    case membership_ledger.accept(from, line, fixture.verifier()) {
      Ok(Applied(ledger: next, ..)) -> Ok([next, ..reached])
      Ok(Duplicate) | Ok(Gap(_)) | Error(_) ->
        Error(violation(
          "extends",
          "a line of a valid log did not extend the chain",
        ))
    }
  })
  |> result.map(list.reverse)
}

fn start_of(line: BitArray) -> Result(Ledger, statem.Violation) {
  membership_ledger.begin(line, fixture.verifier())
  |> result.map_error(fn(refusal) {
    violation("genesis", "the genesis was refused: " <> string.inspect(refusal))
  })
}

fn whole(lines: List(BitArray)) -> Result(Ledger, statem.Violation) {
  replay(lines)
  |> result.map_error(fn(error) {
    violation("replay", "a valid log did not replay: " <> string.inspect(error))
  })
}

fn finish(sut: Sut, _model: Model) -> Result(Nil, statem.Violation) {
  let lines = history.lines(sut.log)
  let states = list.reverse(sut.states)
  use #(first, rest) <- result.try(case lines {
    [first, ..rest] -> Ok(#(first, rest))
    [] -> Error(violation("genesis", "the log holds no genesis"))
  })
  use start <- result.try(start_of(first))

  // Replaying the file, applying it entry by entry, and the states the
  // builder saw are three accounts of one log.
  use replayed <- result.try(whole(lines))
  use Nil <- result.try(agree("replay", replayed, sut.log.ledger))
  use stepped <- result.try(apply_lines(start, rest))
  use Nil <- result.try(agree("stepwise", [start, ..stepped], states))
  use Nil <- result.try(prefixes_are_valid(lines, states))
  use Nil <- result.try(split_anywhere(lines, sut.log.ledger))
  use Nil <- result.try(converge(start, rest, replayed, sut.log.ledger))
  list.try_each(chronological(sut.log), round_trips)
}

// Every prefix of a valid log is valid, is the state the builder saw after it,
// and has the head it should.
fn prefixes_are_valid(
  lines: List(BitArray),
  states: List(Ledger),
) -> Result(Nil, statem.Violation) {
  list.try_each(list.zip(numbers(0, list.length(lines)), states), fn(pair) {
    let #(index, state) = pair
    use prefix <- result.try(whole(list.take(lines, index + 1)))
    use Nil <- result.try(agree("prefix", prefix, state))
    agree("prefix-head", membership_ledger.head(prefix).seq, index)
  })
}

// A log split anywhere gives the same ledger: replay the first part, apply the
// rest.
fn split_anywhere(
  lines: List(BitArray),
  last: Ledger,
) -> Result(Nil, statem.Violation) {
  list.try_each(numbers(1, list.length(lines) + 1), fn(prefix_length) {
    use prefix <- result.try(whole(list.take(lines, prefix_length)))
    use reached <- result.try(apply_lines(
      prefix,
      list.drop(lines, prefix_length),
    ))
    let from = case list.last(reached) {
      Ok(ledger) -> ledger
      Error(Nil) -> prefix
    }
    agree("split", from, last)
  })
}

// Three nodes reach the head by different routes: one replays the file, one is
// the builder that appended the entries as it signed them, and one hears the
// log in a worse order, each line preceded by the one after it (a gap) and
// followed by itself again (a duplicate). None of them holds anything else.
fn converge(
  start: Ledger,
  rest: List(BitArray),
  replayed: Ledger,
  built: Ledger,
) -> Result(Nil, statem.Violation) {
  use untidy <- result.try(hear_untidily(start, rest))

  // What a node acts on is its own table and its own standing, so those are
  // compared first, name by name, and a divergence is reported there. The
  // whole-ledger equality after them is stronger and implies them; it also
  // covers state that no table shows, such as the identity applied at each
  // sequence number.
  use Nil <- result.try(
    list.try_each(probes(), fn(name) {
      let expected = membership_ledger.pin_table(replayed, name)
      let standing = membership_ledger.enrollment(replayed, name)
      use Nil <- result.try(agree(
        "converge-table",
        membership_ledger.pin_table(built, name),
        expected,
      ))
      use Nil <- result.try(agree(
        "converge-table",
        membership_ledger.pin_table(untidy, name),
        expected,
      ))
      use Nil <- result.try(agree(
        "converge-standing",
        membership_ledger.enrollment(built, name),
        standing,
      ))
      agree(
        "converge-standing",
        membership_ledger.enrollment(untidy, name),
        standing,
      )
    }),
  )
  use Nil <- result.try(agree("converge", built, replayed))
  agree("converge", untidy, replayed)
}

fn hear_untidily(
  start: Ledger,
  rest: List(BitArray),
) -> Result(Ledger, statem.Violation) {
  list.index_fold(rest, Ok(start), fn(heard, line, index) {
    use ledger <- result.try(heard)
    let ahead = list.drop(rest, index + 1)
    use Nil <- result.try(case ahead {
      [later, ..] ->
        agree(
          "untidy-gap",
          result.map(
            membership_ledger.accept(ledger, later, fixture.verifier()),
            outcome_kind,
          ),
          Ok(WasGap),
        )
      [] -> Ok(Nil)
    })
    use next <- result.try(apply_lines(ledger, [line]))
    let latest = case next {
      [one] -> one
      [] | [_, _, ..] -> ledger
    }
    use Nil <- result.try(agree(
      "untidy-duplicate",
      result.map(
        membership_ledger.accept(latest, line, fixture.verifier()),
        outcome_kind,
      ),
      Ok(WasDuplicate),
    ))
    Ok(latest)
  })
}

// What an acceptance came to, without the ledger it may carry.
type Reached {
  WasApplied
  WasDuplicate
  WasGap
}

fn outcome_kind(outcome: membership_ledger.Outcome) -> Reached {
  case outcome {
    Applied(..) -> WasApplied
    Duplicate -> WasDuplicate
    Gap(_) -> WasGap
  }
}

// An entry survives encoding, and its line reads back to the same signed
// entry.
fn round_trips(signed: SignedEntry) -> Result(Nil, statem.Violation) {
  use Nil <- result.try(reencodes("round-trip", signed.entry))
  agree(
    "round-trip-line",
    membership_entry.read(membership_entry.line(signed), fixture.verifier()),
    Ok(signed),
  )
}

// --- the property -----------------------------------------------------------

fn spec() -> statem.Spec(Model, Command, Sut) {
  statem.Spec(
    initial: initial(),
    command:,
    precondition: fn(model, command) {
      case plan(model, command) {
        Ok(_) -> statem.Admit
        Error(Nil) -> statem.Reject
      }
    },
    next_model: fn(model, command) {
      case plan(model, command) {
        Ok(Appends(next:, ..)) -> next
        Ok(Refuses(..)) | Ok(Probes) | Error(Nil) -> model
      }
    },
    new_sut:,
    execute:,
    finish:,
    teardown: fn(_) { Nil },
  )
}

fn describe(command: Command) -> String {
  string.inspect(command)
}

pub fn the_ledger_keeps_its_laws_over_generated_histories_test() {
  case statem.check(spec(), config()) {
    Ok(Nil) -> Nil

    // EUnit clips a long panic message, so the whole report also goes to
    // standard error, which EUnit does not capture.
    Error(failure) -> {
      let report = statem.report(failure, describe)
      io.println_error(report)
      panic as report
    }
  }
}

// --- the generator is worth testing with ------------------------------------

// The log after each command that appended an entry, as the ledger and the
// entries that produced it. The commands are replayed through `plan` and the
// builder, which is the arithmetic `execute` runs, without the laws.
fn prefixes_of(commands: List(Command)) -> List(#(Ledger, List(SignedEntry))) {
  let start = history.genesis()
  let #(_, _, reached) =
    list.fold(
      commands,
      #(initial(), start, [#(start.ledger, [])]),
      fn(state, command) {
        let #(model, log, reached) = state
        case plan(model, command) {
          Ok(Appends(kind:, next:)) ->
            case history.push(log, kind) {
              Ok(grown) -> #(next, grown, [
                #(grown.ledger, chronological(grown)),
                ..reached
              ])
              Error(_) -> state
            }
          Ok(Refuses(..)) | Ok(Probes) | Error(Nil) -> state
        }
      },
    )
  list.reverse(reached)
}

fn drawn() -> List(List(Command)) {
  list.map(numbers(0, runs), fn(run) { statem.commands(spec(), config(), run) })
}

// How many of the commands break `wanted`.
fn faults(commands: List(Command), wanted: Fault) -> Int {
  list.count(commands, fn(command) {
    case command {
      Refuse(fault:, ..) -> fault == wanted
      JoinNew(..)
      | Amend(..)
      | Renew(..)
      | Leave(..)
      | Redeliver(..)
      | Skip
      | Rival(..)
      | Flip(..)
      | Swap(..)
      | Drop(..)
      | Truncate(..)
      | Mutate(..) -> False
    }
  })
}

// How many of the commands are the named constructor.
fn labelled(commands: List(Command), name: String) -> Int {
  list.count(commands, fn(command) {
    string.starts_with(string.inspect(command), name <> "(")
    || string.inspect(command) == name
  })
}

pub fn the_histories_reach_every_case_the_laws_need_test() {
  let sequences = drawn()
  let commands = list.flatten(sequences)
  let every = list.flat_map(sequences, prefixes_of)

  // About as many logs as the old generator drew, as long.
  let finished = list.map(sequences, fn(run) { prefixes_of(run) |> list.last })
  let sizes =
    list.map(finished, fn(last) {
      case last {
        Ok(#(_, held)) -> list.length(held)
        Error(Nil) -> 0
      }
    })
  assert int.sum(sizes) > runs * 20

  // The kinds of entry a law is about, in the logs that were built.
  let last_entries =
    list.filter_map(finished, fn(last) { result.map(last, fn(pair) { pair.1 }) })
  let last_kinds =
    list.flat_map(last_entries, fn(held) {
      list.map(held, fn(signed) { signed.entry.kind })
    })
  assert list.count(last_kinds, is_revoke) > runs
  assert list.count(last_kinds, has_links) > runs
  assert list.count(last_kinds, has_directory) > runs

  // The pin table is non-empty in many prefixes, so the model test above
  // cannot pass for want of a case.
  let nonempty =
    list.flat_map(every, fn(prefix) {
      list.map(probes(), fn(name) { history.model_peers(prefix.1, name) != [] })
    })
    |> list.count(fn(present) { present })
  assert nonempty > runs * 30

  // A log shows the pruning rule only if some member lists a name that is
  // revoked and then enrolled again; counted over every prefix, the model
  // finds such stale edges in many of them.
  assert list.count(every, fn(prefix) { history.stale_edges(prefix.1) > 0 })
    > runs

  // Both answers of the symmetry law occur often, so neither side of the
  // equivalence is vacuous.
  let connected =
    list.flat_map(every, fn(prefix) {
      let #(ledger, _) = prefix
      list.map(
        list.combination_pairs(membership_ledger.members(ledger)),
        fn(pair) {
          is_peer(
            membership_ledger.pin_table(ledger, { pair.0 }.name),
            { pair.1 }.pin,
          )
        },
      )
    })
  assert list.count(connected, fn(yes) { yes }) > runs * 30
  assert list.count(connected, fn(yes) { !yes }) > runs * 30

  // Revoked names with pins are common, so the ghost-pin law ran.
  let ghosts =
    list.flat_map(every, fn(prefix) {
      let #(ledger, entries) = prefix
      list.flat_map(not_enrolled(ledger), pins_given_to(entries, _))
    })
  assert list.length(ghosts) > runs * 30

  // Every refusal and every probe is drawn often enough to matter.
  assert faults(commands, NodeTaken) > runs / 2
  assert faults(commands, PinTaken) > runs / 2
  assert faults(commands, LinkInactive) > runs / 2
  assert faults(commands, LinkSelf) > runs / 2
  assert faults(commands, RevokeInactive) > runs / 2
  assert labelled(commands, "Redeliver") > runs / 2
  assert labelled(commands, "Skip") > runs / 2
  assert labelled(commands, "Rival") > runs / 2
  assert labelled(commands, "Flip") > runs / 2
  assert labelled(commands, "Swap") > runs / 2
  assert labelled(commands, "Drop") > runs / 2
  assert labelled(commands, "Truncate") > runs / 2
  assert labelled(commands, "Mutate") > runs / 2
}

fn is_revoke(kind: Kind) -> Bool {
  case kind {
    Revoke(..) -> True
    Genesis(..) | Upsert(_) -> False
  }
}

fn has_links(kind: Kind) -> Bool {
  case kind {
    Upsert(member) -> member.links != []
    Genesis(..) | Revoke(..) -> False
  }
}

fn has_directory(kind: Kind) -> Bool {
  case kind {
    Upsert(member) -> member.directory != NotInDirectory
    Genesis(..) | Revoke(..) -> False
  }
}

// --- single entries and arbitrary bytes -------------------------------------

fn seeded() -> qcheck.Config {
  qcheck.default_config()
  |> qcheck.with_test_count(arbitrary_runs)
  |> qcheck.with_seed(qcheck.seed(arbitrary_seed))
}

fn result_is_refused(
  outcome: Result(membership_ledger.Outcome, membership_ledger.Refusal),
) -> Bool {
  case outcome {
    Error(_) -> True
    Ok(Applied(..)) | Ok(Duplicate) | Ok(Gap(_)) -> False
  }
}

pub fn every_single_bit_flip_of_one_line_is_refused_test() {
  // Exhaustive over one short line: each of its bits, one at a time.
  let log = history.enroll(history.genesis(), "hub", [])
  let assert [genesis, line] = history.lines(log)
    as "the log holds a genesis and one enrollment"
  let assert Ok(ledger) = membership_ledger.begin(genesis, fixture.verifier())
    as "the fixture genesis is valid"
  list.each(numbers(0, bit_array.byte_size(line)), fn(position) {
    list.each(numbers(0, 8), fn(bit) {
      let assert Ok(flipped) = flip(line, position, bit)
        as "the position is inside the line"
      assert result_is_refused(membership_ledger.accept(
        ledger,
        flipped,
        fixture.verifier(),
      ))
    })
  })
}

pub fn a_node_on_one_branch_never_applies_the_other_test() {
  // Two logs share their first entries and then diverge: a different member
  // is enrolled at the same sequence number.
  let base =
    history.genesis()
    |> history.enroll("hub", [])
  let left = history.enroll(base, "left", ["hub"])
  let right = history.enroll(base, "right", ["hub"])
  let assert [left_entry, ..] = left.entries as "the left log has entries"
  let assert [right_entry, ..] = right.entries as "the right log has entries"
  assert left_entry.id != right_entry.id

  // The left node refuses the right branch's entry, and the entries that
  // build on it fail the chain check there.
  let assert Error(Fork(..)) =
    membership_ledger.accept(
      left.ledger,
      membership_entry.line(right_entry),
      fixture.verifier(),
    )
    as "the other branch's entry at a held sequence number is a fork"
  let right_next =
    history.next_entry(right, Upsert(fixture.member("more", ["hub"])))
  assert membership_ledger.accept(
      left.ledger,
      fixture.line(right_next),
      fixture.verifier(),
    )
    == Error(membership_ledger.Chain)
}

// An entry drawn from the whole space the encoder accepts: any sequence
// number, a genesis, a revoke or a member with up to 63 links, a port past the
// valid range, and either role and directory standing.
fn entry_generator() -> qcheck.Generator(Entry) {
  qcheck.map2(kind_generator(), qcheck.bounded_int(0, 10_000), fn(kind, seq) {
    Entry(
      seq:,
      prev: membership_entry.id_of_body(<<seq:size(64)>>),
      time: fixture.stamp,
      kind:,
    )
  })
}

fn kind_generator() -> qcheck.Generator(Kind) {
  qcheck.from_weighted_generators(
    #(1, qcheck.constant(fixture.genesis_kind())),
    [
      #(1, qcheck.map(qcheck.bounded_int(0, 299), revoke_of)),
      #(
        2,
        qcheck.map5(
          qcheck.bounded_int(0, 299),
          qcheck.bounded_int(0, 63),
          qcheck.bounded_int(0, 69_999),
          role(),
          directory(),
          member_kind,
        ),
      ),
    ],
  )
}

fn revoke_of(index: Int) -> Kind {
  let name = "n" <> int.to_string(index)
  Revoke(
    name:,
    pin: fixture.pin_for(name, index),
    reason: string.repeat("r", index % 200),
  )
}

fn member_kind(
  index: Int,
  link_count: Int,
  port: Int,
  role: Role,
  directory: DirectoryStanding,
) -> Kind {
  let name = "n" <> int.to_string(index)
  Upsert(Member(
    name:,
    node: "loom@" <> name <> ".example.net",
    host: name <> ".example.net",
    listen_port: case port > 65_535 {
      True -> None
      False -> Some(port)
    },
    role:,
    directory:,
    links: list.map(numbers(1, link_count + 1), fn(link) {
      "l" <> int.to_string(link)
    }),
    pin: fixture.pin_for(name, index),
  ))
}

pub fn arbitrary_well_formed_entries_round_trip_test() {
  qcheck.run(seeded(), entry_generator(), fn(entry) {
    assert membership_entry.decode_body(membership_entry.encode_body(entry))
      == Ok(entry)
  })
}

// The characters a line is made of and a few arbitrary bytes, so many of the
// drawn byte strings get past the shape check and into the decoder.
const alphabet =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_..=+/ \n"

fn byte_generator() -> qcheck.Generator(Int) {
  let codes =
    string.to_utf_codepoints(alphabet) |> list.map(string.utf_codepoint_to_int)
  qcheck.from_weighted_generators(
    #(
      3,
      qcheck.bounded_int(0, list.length(codes) - 1)
        |> qcheck.map(fn(at) {
          case list.drop(codes, at) {
            [code, ..] -> code
            [] -> 0
          }
        }),
    ),
    [#(1, qcheck.bounded_int(0, 255))],
  )
}

fn bytes_generator() -> qcheck.Generator(BitArray) {
  qcheck.generic_list(byte_generator(), qcheck.bounded_int(0, 199))
  |> qcheck.map(fn(bytes) {
    list.fold(bytes, <<>>, fn(all, byte) { <<all:bits, byte>> })
  })
}

pub fn arbitrary_bytes_are_refused_without_crashing_test() {
  let ledger = history.genesis().ledger
  qcheck.run(seeded(), bytes_generator(), fn(bytes) {
    assert result_is_refused(membership_ledger.accept(
      ledger,
      bytes,
      fixture.verifier(),
    ))
    let _ = membership_entry.decode_body(bytes)
    let _ = membership_entry.parse_line(bytes)
    Nil
  })
}

// Fragments of JSON, some of them the format's own keys, joined at random.
const fragments = [
  "{", "}", "[", "]", ",", ":", "null", "true", "1", "-1", "1.5", "1e999",
  "99999999999999999999999999999", "\"\"", "\"a\"", "\"format\"",
  "\"loom-membership-ledger/1\"", "\"seq\"", "\"prev\"", "\"time\"", "\"kind\"",
  "\"member\"", "\"revoke\"", "\"genesis\"", "\"name\"", "\"node\"", "\"pin\"",
  "\"links\"", "\"reason\"", "\\u0000", "\"\\ud800\"",
]

fn text_generator() -> qcheck.Generator(String) {
  let pieces =
    qcheck.bounded_int(0, list.length(fragments) - 1)
    |> qcheck.map(fn(at) {
      case list.drop(fragments, at) {
        [piece, ..] -> piece
        [] -> ""
      }
    })
  qcheck.generic_list(pieces, qcheck.bounded_int(0, 39))
  |> qcheck.map(string.concat)
}

pub fn a_signed_body_of_any_shape_decodes_or_is_refused_test() {
  qcheck.run(seeded(), text_generator(), fn(text) {
    case
      membership_entry.read(
        signed_line_of(bit_array.from_string(text)),
        fixture.verifier(),
      )
    {
      Error(_) -> Nil
      Ok(signed) -> {
        let assert Ok(Nil) = reencodes("signed-body", signed.entry)
          as "an entry the decoder accepted re-encodes"
        Nil
      }
    }
  })
}
