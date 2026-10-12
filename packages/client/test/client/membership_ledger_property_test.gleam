//// Laws of the membership ledger (protocol-change/086, "What it costs"),
//// checked over seeded random logs rather than hand-picked ones.
////
//// Each test draws a few dozen logs from `membership_fixture.random_log`,
//// which grows a log by trying random enrollments, amendments, renewals and
//// revokes against the real fold and keeping the ones it accepts, and then
//// states one property of the result. The seeds are fixed, so a failure
//// reproduces: the failing assertion's log is the one `seed` names.
////
//// The properties are the ones the proposal requires of the pure module:
//// replaying a whole log equals applying it entry by entry, every prefix of
//// a valid log is valid, a flipped bit or two swapped entries are refused,
//// two nodes that apply the same log hold the same pin table, a fork is
//// refused and leaves the state unchanged, an entry survives encoding, and the
//// decoder is total over arbitrary bytes.
////
//// Three more concern the pin table. It equals the one a model derives from
//// the entries alone (`membership_log.model_peers`, which states the rule on
//// revoked links in a different shape from the ledger), links are symmetric
//// between active members, and no table holds the pin of a name that is
//// revoked or was never enrolled. Each asserts a minimum count of the cases it
//// exercises, so a generator that stopped producing revokes or links would
//// fail the test and not pass it vacuously.

import client/distribution_plan.{Executor, Orchestrator}
import client/membership_entry.{
  type Entry, type Kind, Entry, Genesis, Learner, Member, NotInDirectory, Revoke,
  Upsert, Voter,
}
import client/membership_ledger.{type Ledger, Applied, Duplicate, Fork, Gap}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import support/membership_fixture as fixture
import support/membership_log as history

const runs = 40

const length = 30

fn seeds(count: Int) -> List(Int) {
  list.index_map(list.repeat(Nil, count), fn(_, index) { index })
}

fn seed_of(run: Int) -> history.Seed {
  history.Seed(run * 7919 + 17)
}

// Every log the generator draws for the fixed seeds, with the ledger after
// each prefix.
fn logs() -> List(#(Int, history.Log, List(Ledger))) {
  list.map(seeds(runs), fn(run) {
    let #(log, states) = history.random_log(seed_of(run), length)
    #(run, log, states)
  })
}

fn last(items: List(a)) -> a {
  let assert Ok(item) = list.last(items) as "the list is not empty"
  item
}

fn at(items: List(a), index: Int) -> a {
  let assert [item, ..] = list.drop(items, index) as "the index is in range"
  item
}

fn chronological(log: history.Log) -> List(membership_entry.SignedEntry) {
  list.reverse(log.entries)
}

// Applies lines in order through `accept`, requiring each to extend the chain.
fn apply_all(ledger: Ledger, lines: List(BitArray)) -> Ledger {
  list.fold(lines, ledger, fn(ledger, line) {
    let assert Ok(Applied(ledger: next, ..)) =
      membership_ledger.accept(ledger, line, fixture.verifier())
      as "a line of a valid log extends the chain"
    next
  })
}

fn replay(lines: List(BitArray)) {
  membership_ledger.replay(lines, fixture.verifier())
}

// --- the generator is worth testing with ---------------------------------------

pub fn the_generator_draws_varied_logs_test() {
  let entries =
    logs()
    |> list.flat_map(fn(drawn) {
      let #(_, log, _) = drawn
      chronological(log)
    })
  let kinds = list.map(entries, fn(signed) { signed.entry.kind })
  let revokes =
    list.count(kinds, fn(kind) {
      case kind {
        Revoke(..) -> True
        Genesis(..) | Upsert(_) -> False
      }
    })
  let linked =
    list.count(kinds, fn(kind) {
      case kind {
        Upsert(member) -> member.links != []
        Genesis(..) | Revoke(..) -> False
      }
    })
  let directory =
    list.count(kinds, fn(kind) {
      case kind {
        Upsert(member) -> member.directory != NotInDirectory
        Genesis(..) | Revoke(..) -> False
      }
    })
  assert list.length(entries) > runs * 20
  assert revokes > runs
  assert linked > runs
  assert directory > runs
}

// --- replay, prefixes and the model --------------------------------------------

pub fn replaying_a_log_equals_applying_it_entry_by_entry_test() {
  list.each(logs(), fn(drawn) {
    let #(_, log, states) = drawn
    let lines = history.lines(log)
    let assert Ok(replayed) = replay(lines)
    assert replayed == last(states)

    // One entry at a time, the states are those the builder saw.
    let assert [first, ..rest] = lines
    let assert Ok(start) = membership_ledger.begin(first, fixture.verifier())
    let stepped =
      list.scan(rest, start, fn(ledger, line) { apply_all(ledger, [line]) })
    assert [start, ..stepped] == states
  })
}

pub fn a_log_split_anywhere_gives_the_same_ledger_test() {
  list.each(logs(), fn(drawn) {
    let #(_, log, states) = drawn
    let lines = history.lines(log)
    list.index_map(lines, fn(_, index) { index + 1 })
    |> list.each(fn(prefix_length) {
      let assert Ok(prefix) = replay(list.take(lines, prefix_length))
      let rest = list.drop(lines, prefix_length)
      assert apply_all(prefix, rest) == last(states)
    })
  })
}

pub fn every_prefix_of_a_valid_log_is_valid_test() {
  list.each(logs(), fn(drawn) {
    let #(_, log, states) = drawn
    let lines = history.lines(log)
    list.index_map(lines, fn(_, index) { index })
    |> list.each(fn(index) {
      let assert Ok(ledger) = replay(list.take(lines, index + 1))
      assert ledger == at(states, index)
      assert membership_ledger.head(ledger).seq == index
    })
  })
}

pub fn the_ledger_matches_a_model_that_reads_only_the_entries_test() {
  list.each(logs(), fn(drawn) {
    let #(_, log, states) = drawn
    let entries = chronological(log)
    list.index_map(states, fn(ledger, index) { #(ledger, index + 1) })
    |> list.each(fn(state) {
      let #(ledger, count) = state
      assert membership_ledger.members(ledger)
        == history.model(list.take(entries, count))
    })
  })
}

// --- tampering -----------------------------------------------------------------

fn flip(line: BitArray, position: Int, bit: Int) -> BitArray {
  let assert <<before:bytes-size(position), byte, after:bytes>> = line
    as "the position is inside the line"
  let flipped = int.bitwise_exclusive_or(byte, int.bitwise_shift_left(1, bit))
  <<before:bits, flipped, after:bits>>
}

fn replace_at(items: List(a), index: Int, item: a) -> List(a) {
  list.index_map(items, fn(existing, position) {
    case position == index {
      True -> item
      False -> existing
    }
  })
}

pub fn a_flipped_bit_anywhere_in_a_log_is_refused_test() {
  list.each(logs(), fn(drawn) {
    let #(run, log, _) = drawn
    let lines = history.lines(log)
    list.each(seeds(3), fn(trial) {
      // One bit of one line, chosen by the seed, is flipped in the file.
      let #(index, seed) =
        history.below(seed_of(run * 100 + trial), list.length(lines))
      let line = at(lines, index)
      let #(position, seed) = history.below(seed, bit_array.byte_size(line))
      let #(bit, _) = history.below(seed, 8)
      let mutated = replace_at(lines, index, flip(line, position, bit))

      // The replay stops at the damaged line and nowhere earlier.
      let assert Error(membership_ledger.ReplayError(index: failed, ..)) =
        replay(mutated)
      assert failed == index
    })
  })
}

pub fn a_flipped_bit_in_any_line_is_refused_where_it_is_applied_test() {
  // Cheaper than a replay, so every line of every log gets several flips:
  // the damaged line is offered to the ledger that holds the lines before it.
  list.each(logs(), fn(drawn) {
    let #(run, log, states) = drawn
    let lines = history.lines(log)
    list.index_map(lines, fn(line, index) { #(line, index) })
    |> list.each(fn(entry) {
      let #(line, index) = entry
      let size = bit_array.byte_size(line)
      list.each(seeds(6), fn(trial) {
        let #(position, seed) =
          history.below(seed_of(run * 1000 + index * 10 + trial), size)
        let #(bit, _) = history.below(seed, 8)
        let flipped = flip(line, position, bit)
        assert case index {
          0 ->
            result_is_error(membership_ledger.begin(flipped, fixture.verifier()))
          _ ->
            result_is_refused(membership_ledger.accept(
              at(states, index - 1),
              flipped,
              fixture.verifier(),
            ))
        }
      })
    })
  })
}

fn result_is_error(outcome: Result(a, e)) -> Bool {
  case outcome {
    Error(_) -> True
    Ok(_) -> False
  }
}

pub fn every_single_bit_flip_of_one_line_is_refused_test() {
  // Exhaustive over one short line: each of its bits, one at a time.
  let log = history.enroll(history.genesis(), "hub", [])
  let lines = history.lines(log)
  let assert [genesis, line] = lines
  let size = bit_array.byte_size(line)
  list.each(seeds(size), fn(position) {
    list.each(seeds(8), fn(bit) {
      let flipped = flip(line, position, bit)
      assert result_is_refused(membership_ledger.accept(
        fixture_after_genesis(genesis),
        flipped,
        fixture.verifier(),
      ))
    })
  })
}

fn fixture_after_genesis(genesis: BitArray) -> Ledger {
  let assert Ok(ledger) = membership_ledger.begin(genesis, fixture.verifier())
  ledger
}

fn result_is_refused(
  outcome: Result(membership_ledger.Outcome, membership_ledger.Refusal),
) -> Bool {
  case outcome {
    Error(_) -> True
    Ok(Applied(..)) | Ok(Duplicate) | Ok(Gap(_)) -> False
  }
}

pub fn two_swapped_entries_are_refused_test() {
  list.each(logs(), fn(drawn) {
    let #(run, log, _) = drawn
    let lines = history.lines(log)
    let size = list.length(lines)
    list.each(seeds(8), fn(trial) {
      let #(first, seed) = history.below(seed_of(run * 100 + trial), size - 1)
      let #(gap, _) = history.below(seed, size - first - 1)
      let second = first + 1 + gap
      let swapped =
        lines
        |> replace_at(first, at(lines, second))
        |> replace_at(second, at(lines, first))
      let assert Error(membership_ledger.ReplayError(index: failed, ..)) =
        replay(swapped)
      assert failed == first
    })
  })
}

pub fn an_entry_removed_from_the_middle_is_refused_test() {
  list.each(logs(), fn(drawn) {
    let #(_, log, _) = drawn
    let lines = history.lines(log)
    let size = list.length(lines)
    list.each(seeds(size - 2), fn(offset) {
      let removed = offset + 1
      let without =
        list.append(list.take(lines, removed), list.drop(lines, removed + 1))
      let assert Error(membership_ledger.ReplayError(index: failed, ..)) =
        replay(without)
      assert failed == removed
    })
  })
}

pub fn a_truncated_line_is_never_accepted_test() {
  list.each(logs(), fn(drawn) {
    let #(run, log, _) = drawn
    let lines = history.lines(log)
    let assert Ok(ledger) = replay(list.take(lines, 1))
    let assert [_, line, ..] = lines
    let size = bit_array.byte_size(line)
    list.each(seeds(10), fn(trial) {
      let #(cut, _) = history.below(seed_of(run * 100 + trial), size)
      let assert Ok(prefix) = bit_array.slice(line, 0, cut)
      assert result_is_refused(membership_ledger.accept(
        ledger,
        prefix,
        fixture.verifier(),
      ))
    })
  })
}

// --- convergence ---------------------------------------------------------------

pub fn two_nodes_that_apply_the_same_log_hold_the_same_table_test() {
  list.each(logs(), fn(drawn) {
    let #(_, log, states) = drawn
    let lines = history.lines(log)

    // Three nodes reach the head by different routes: one replays the file,
    // one is the builder that appended the entries as it signed them, and one
    // hears the log in a worse order, each line preceded by the one after it
    // (a gap) and followed by itself again (a duplicate). Neither changes what
    // it holds.
    let assert Ok(replayed) = replay(lines)
    let built = last(states)
    let untidy = hear_untidily(lines)

    // What a node acts on is its own table and its own standing, so those are
    // compared first, name by name, and a divergence is reported there. The
    // whole-ledger equality after them is stronger and implies them; it also
    // covers state that no table shows, such as the identity applied at each
    // sequence number.
    list.each(probes(), fn(name) {
      let expected = membership_ledger.pin_table(replayed, name)
      assert membership_ledger.pin_table(built, name) == expected
      assert membership_ledger.pin_table(untidy, name) == expected
      let standing = membership_ledger.enrollment(replayed, name)
      assert membership_ledger.enrollment(built, name) == standing
      assert membership_ledger.enrollment(untidy, name) == standing
    })
    assert replayed == built
    assert replayed == untidy
  })
}

// The names a test asks a ledger about: every name the generator draws from,
// and one it never enrolls.
fn probes() -> List(String) {
  ["stranger", ..history.pool()]
}

// The ledger after each prefix of a log, with the entries that produced it.
fn prefixes(
  drawn: #(Int, history.Log, List(Ledger)),
) -> List(#(Ledger, List(membership_entry.SignedEntry))) {
  let #(_, log, states) = drawn
  let entries = chronological(log)
  list.index_map(states, fn(ledger, index) {
    #(ledger, list.take(entries, index + 1))
  })
}

pub fn the_pin_table_matches_a_model_of_the_links_test() {
  // The table of every probed name, after every prefix of every log, names the
  // peers the model derives from the entries alone.
  let nonempty =
    list.flat_map(logs(), prefixes)
    |> list.flat_map(fn(state) {
      let #(ledger, entries) = state
      list.map(probes(), fn(name) {
        let expected = history.model_peers(entries, name)
        let table = membership_ledger.pin_table(ledger, name)
        assert list.map(membership_ledger.peers(table), fn(peer) { peer.name })
          == expected
        expected
      })
    })
    |> list.count(fn(expected) { expected != [] })
  assert nonempty > runs * length
}

pub fn the_logs_reach_edges_that_a_revoke_must_prune_test() {
  // A log shows the pruning rule only if some member lists a name that is
  // revoked and then enrolled again. Counted over every prefix, the model
  // finds such stale edges in many of them, so the model test above cannot
  // pass for want of a case.
  let stale =
    list.flat_map(logs(), prefixes)
    |> list.count(fn(state) { history.stale_edges(state.1) > 0 })
  assert stale > runs
}

fn is_peer(table: membership_ledger.PinTable, pin: BitArray) -> Bool {
  case membership_ledger.lookup_pin(table, pin) {
    Ok(_) -> True
    Error(Nil) -> False
  }
}

pub fn links_between_active_members_are_symmetric_test() {
  // For two active members, a accepts the pin of b exactly when b accepts the
  // pin of a, because TLS needs both ends to agree.
  let accepted =
    list.flat_map(logs(), prefixes)
    |> list.flat_map(fn(state) {
      let #(ledger, _) = state
      list.combination_pairs(membership_ledger.members(ledger))
      |> list.map(fn(pair) {
        let #(a, b) = pair
        let forward =
          is_peer(membership_ledger.pin_table(ledger, a.name), b.pin)
        let backward =
          is_peer(membership_ledger.pin_table(ledger, b.name), a.pin)
        assert forward == backward
        forward
      })
    })

  // Both answers occur often, so neither side of the equivalence is vacuous.
  assert list.count(accepted, fn(connected) { connected }) > runs * length
  assert list.count(accepted, fn(connected) { !connected }) > runs * length
}

// Every pin a name has been given in a prefix of a log, by an enrollment or
// by the revoke that removed it.
fn pins_given_to(
  entries: List(membership_entry.SignedEntry),
  name: String,
) -> List(BitArray) {
  list.filter_map(entries, fn(signed) {
    case signed.entry.kind {
      Upsert(member) if member.name == name -> Ok(member.pin)
      Revoke(name: revoked, pin:, ..) if revoked == name -> Ok(pin)
      Genesis(..) | Upsert(_) | Revoke(..) -> Error(Nil)
    }
  })
}

pub fn no_table_holds_a_pin_of_a_name_that_is_not_enrolled_test() {
  let checked =
    list.flat_map(logs(), prefixes)
    |> list.flat_map(fn(state) {
      let #(ledger, entries) = state
      list.filter(probes(), fn(name) {
        membership_ledger.enrollment(ledger, name) == membership_ledger.Revoked
        || membership_ledger.enrollment(ledger, name)
        == membership_ledger.NotEnrolled
      })
      |> list.flat_map(fn(name) {
        list.map(pins_given_to(entries, name), fn(pin) {
          list.each(probes(), fn(node) {
            assert !is_peer(membership_ledger.pin_table(ledger, node), pin)
          })
        })
      })
    })

  // Revoked names with pins are common in the logs, so the loop above ran.
  assert list.length(checked) > runs * length
}

fn hear_untidily(lines: List(BitArray)) -> Ledger {
  let assert [genesis, ..rest] = lines
  let assert Ok(start) = membership_ledger.begin(genesis, fixture.verifier())
  list.index_fold(rest, start, fn(ledger, line, index) {
    let ahead = list.drop(rest, index + 1)
    let ledger = case ahead {
      [later, ..] -> {
        let assert Ok(Gap(_)) =
          membership_ledger.accept(ledger, later, fixture.verifier())
          as "a line past the next is a gap"
        ledger
      }
      [] -> ledger
    }
    let next = apply_all(ledger, [line])
    let assert Ok(Duplicate) =
      membership_ledger.accept(next, line, fixture.verifier())
      as "a line applied twice is a duplicate"
    next
  })
}

// --- forks ---------------------------------------------------------------------

pub fn a_fork_is_refused_and_leaves_the_state_unchanged_test() {
  list.each(logs(), fn(drawn) {
    let #(run, log, states) = drawn
    let entries = chronological(log)
    let lines = history.lines(log)
    let count = list.length(entries)

    list.each(seeds(count - 1), fn(applied) {
      // A node that holds entries 0..applied is shown a different signed
      // entry at a sequence number it already holds.
      let ledger = at(states, applied)
      let #(seq, _) = history.below(seed_of(run * 100 + applied), applied + 1)
      let held = at(entries, seq)
      let rival = fixture.seal(Entry(..held.entry, time: fixture.other_stamp))
      assert rival.id != held.id

      assert membership_ledger.accept(
          ledger,
          membership_entry.line(rival),
          fixture.verifier(),
        )
        == Error(Fork(seq:, ours: held.id, theirs: rival.id))

      // The node keeps what it had, and the operator's next entry applies.
      let next = at(lines, applied + 1)
      let assert Ok(Applied(ledger: after, ..)) =
        membership_ledger.accept(ledger, next, fixture.verifier())
      assert after == at(states, applied + 1)
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
  let assert [left_entry, ..] = left.entries
  let assert [right_entry, ..] = right.entries
  assert left_entry.id != right_entry.id

  // The left node refuses the right branch's entry, and the entries that
  // build on it fail the chain check there.
  let assert Error(Fork(..)) =
    membership_ledger.accept(
      left.ledger,
      membership_entry.line(right_entry),
      fixture.verifier(),
    )
  let right_next =
    history.next_entry(right, Upsert(fixture.member("more", ["hub"])))
  assert membership_ledger.accept(
      left.ledger,
      fixture.line(right_next),
      fixture.verifier(),
    )
    == Error(membership_ledger.Chain)
}

// --- encoding ------------------------------------------------------------------

pub fn every_entry_of_every_log_round_trips_test() {
  list.each(logs(), fn(drawn) {
    let #(_, log, _) = drawn
    list.each(chronological(log), fn(signed) {
      assert membership_entry.decode_body(membership_entry.encode_body(
          signed.entry,
        ))
        == Ok(signed.entry)
      assert membership_entry.read(
          membership_entry.line(signed),
          fixture.verifier(),
        )
        == Ok(signed)
    })
  })
}

fn random_entry(seed: history.Seed) -> #(Entry, history.Seed) {
  let #(seq, seed) = history.below(seed, 10_001)
  let #(shape, seed) = history.below(seed, 4)
  let #(kind, seed) = random_kind(seed, shape)
  let prev = fixture_prev(seq)
  #(Entry(seq:, prev:, time: fixture.stamp, kind:), seed)
}

fn fixture_prev(seq: Int) -> membership_entry.EntryId {
  membership_entry.id_of_body(<<seq:size(64)>>)
}

fn random_kind(seed: history.Seed, shape: Int) -> #(Kind, history.Seed) {
  case shape {
    0 -> #(fixture.genesis_kind(), seed)
    1 -> {
      let #(index, seed) = history.below(seed, 300)
      let name = "n" <> int.to_string(index)
      #(
        Revoke(
          name:,
          pin: fixture.pin_for(name, index),
          reason: string.repeat("r", index % 200),
        ),
        seed,
      )
    }
    _ -> random_member_kind(seed)
  }
}

fn random_member_kind(seed: history.Seed) -> #(Kind, history.Seed) {
  let #(index, seed) = history.below(seed, 300)
  let #(link_count, seed) = history.below(seed, 64)
  let #(port, seed) = history.below(seed, 70_000)
  let #(role, seed) = history.below(seed, 2)
  let #(directory, seed) = history.below(seed, 3)
  let name = "n" <> int.to_string(index)
  let member =
    Member(
      name:,
      node: "loom@" <> name <> ".example.net",
      host: name <> ".example.net",
      listen_port: case port {
        0 | 65_536 -> None
        other if other > 65_535 -> None
        other -> Some(other)
      },
      role: case role {
        0 -> Executor
        _ -> Orchestrator
      },
      directory: case directory {
        0 -> Voter
        1 -> Learner
        _ -> NotInDirectory
      },
      links: list.index_map(list.repeat(Nil, link_count), fn(_, link) {
        "l" <> int.to_string(link)
      }),
      pin: fixture.pin_for(name, index),
    )
  #(Upsert(member:), seed)
}

pub fn arbitrary_well_formed_entries_round_trip_test() {
  list.each(seeds(400), fn(run) {
    let #(entry, _) = random_entry(seed_of(run))
    assert membership_entry.decode_body(membership_entry.encode_body(entry))
      == Ok(entry)
  })
}

// --- totality ------------------------------------------------------------------

// Bytes drawn mostly from the characters a line is made of, so many of them
// get past the shape check and into the decoder.
fn random_bytes(seed: history.Seed, size: Int) -> #(BitArray, history.Seed) {
  let alphabet =
    bit_array.from_string(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_..=+/ \n",
    )
  list.fold(seeds(size), #(<<>>, seed), fn(state, _) {
    let #(bytes, seed) = state
    let #(pick, seed) = history.below(seed, 4)
    case pick {
      0 -> {
        let #(byte, seed) = history.below(seed, 256)
        #(<<bytes:bits, byte>>, seed)
      }
      _ -> {
        let #(index, seed) = history.below(seed, bit_array.byte_size(alphabet))
        let assert Ok(<<byte>>) = bit_array.slice(alphabet, index, 1)
        #(<<bytes:bits, byte>>, seed)
      }
    }
  })
}

pub fn arbitrary_bytes_are_refused_without_crashing_test() {
  let ledger = history.genesis().ledger
  list.each(seeds(3000), fn(run) {
    let #(size, seed) = history.below(seed_of(run), 200)
    let #(bytes, _) = random_bytes(seed, size)
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

fn random_text(seed: history.Seed, count: Int) -> #(String, history.Seed) {
  list.fold(seeds(count), #("", seed), fn(state, _) {
    let #(text, seed) = state
    let #(index, seed) = history.below(seed, list.length(fragments))
    #(text <> at(fragments, index), seed)
  })
}

fn signed_line_of(body: BitArray) -> BitArray {
  let assert Ok(signature) =
    fixture.signer()(membership_entry.signing_input(body))
  membership_entry.frame_line(body, signature)
}

pub fn a_signed_body_of_any_shape_decodes_or_is_refused_test() {
  list.each(seeds(2000), fn(run) {
    let #(count, seed) = history.below(seed_of(run), 40)
    let #(text, _) = random_text(seed, count)
    case
      membership_entry.read(
        signed_line_of(bit_array.from_string(text)),
        fixture.verifier(),
      )
    {
      Error(_) -> Nil
      Ok(signed) -> reencodes(signed.entry)
    }
  })
}

pub fn a_mutated_valid_body_signed_afresh_decodes_or_is_refused_test() {
  // The signature is no obstacle here: the body is mutated first and signed
  // after, so the decoder sees bytes a valid signer might have produced.
  list.each(logs(), fn(drawn) {
    let #(run, log, _) = drawn
    list.each(chronological(log), fn(original) {
      let size = bit_array.byte_size(original.body)
      let #(position, seed) = history.below(seed_of(run + size), size)
      let #(byte, _) = history.below(seed, 256)
      let assert <<before:bytes-size(position), _, after:bytes>> = original.body
      let body = <<before:bits, byte, after:bits>>
      case membership_entry.read(signed_line_of(body), fixture.verifier()) {
        Error(_) -> Nil
        Ok(signed) -> reencodes(signed.entry)
      }
    })
  })
}

// An entry the decoder accepted is one the encoder writes back to the same
// entry.
fn reencodes(entry: Entry) {
  assert membership_entry.decode_body(membership_entry.encode_body(entry))
    == Ok(entry)
}
