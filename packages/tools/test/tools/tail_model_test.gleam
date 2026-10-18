//// Model-based test of `tools/tail`, the bounded rolling window with a
//// monotone byte cursor.
////
//// `tail_test` pins the window with worked examples. This module checks the
//// part the examples cannot reach: cursors that were handed out by earlier
//// answers, asked again after the window has rolled over them, against a
//// chunk sequence cut at awkward places. `statem` generates and shrinks the
//// sequences, so a failure is reported as the few pushes and polls that
//// break a rule.
////
//// ## The model
////
//// The model is the whole stream, every byte ever pushed, and a count of how
//// many answers have been given. The system under test is the `Tail` plus
//// the cursors its earlier answers returned, kept inside the system because
//// they are its outputs: a `Since` command names a cursor by position among
//// those answers (modulo how many there are), or by a position in the
//// stream, and so stays meaningful when shrinking deletes earlier commands.
////
//// ## What is checked
////
//// Each rule has its own `Violation` tag. The stated rules are in the module
//// doc of `tools/tail` and in `packages/tools/CLAUDE.md`:
////
//// - `tail.received` — `received` is the total number of bytes ever pushed.
//// - `tail.pure` — `since` is a read: asking twice answers the same.
//// - `tail.cursor` — "Always at or after the cursor that was asked with",
////   never beyond what has been received.
//// - `tail.span` — "the reported missed count plus the returned bytes equal
////   the suffix": the answer's `dropped` bytes followed by its `bytes` are
////   exactly the stream after the (clamped) cursor, and the new cursor sits
////   at the end of them.
//// - `tail.bounded` — the window never holds more than `capacity` bytes; a
////   reader loses bytes only once more than `capacity` have arrived, and
////   resumes within three bytes (one character's continuation run) of
////   `received - capacity`.
//// - `tail.boundary` — the trailing edge holds back exactly an incomplete
////   final character and nothing else, so consecutive slices concatenate to
////   the stream, and binary output is never held back.
//// - `tail.front` — "the retained window never begins mid-character" on a
////   text stream.
//// - `tail.decodes` — on a text stream a slice that starts on a character
////   boundary decodes as UTF-8 by itself.
////
//// ## Capacities
////
//// The edge rules assume the window is wider than the longest held-back
//// character run, so the capacities under test start at eight bytes. Chunks
//// run from empty to wider than the window, which exercises both the
//// append-and-trim path and the chunk-alone-fills-the-window path.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import qcheck
import statem.{type Spec, type Violation, Admit, Spec, Violation}
import tools/tail.{type Tail}

// --- configuration -----------------------------------------------------------

/// Fixed so a red gate is the same red gate on every machine.
const seed = 20_261_018

/// Sequences per capacity.
const test_count = 200

/// The longest sequence; greedy shrinking is quadratic in this.
const max_commands = 24

/// The capacities run. All at least eight so a window is wider than a
/// character; they differ in how often a chunk alone overflows the window.
const capacities = [8, 11, 24]

// --- commands ----------------------------------------------------------------

/// What one push carries.
type Chunk {
  /// Whole characters, by index into the pool (modulo its size).
  Whole(atoms: List(Int))

  /// The first `cut` bytes of one character, the start of a split. The
  /// rest of the character becomes the model's pending remainder.
  Head(atom: Int, cut: Int)

  /// The pending remainder of the last split, or nothing when there is none:
  /// the end of a split, so that most streams stay valid text.
  Remainder

  /// Arbitrary bytes, drawn from a pool of lead, continuation and invalid
  /// values, so the stream is sometimes not UTF-8 at all.
  Raw(bytes: List(Int))
}

/// Which cursor a poll asks with.
type Cursor {
  /// What an earlier answer returned: position `index` modulo the number of
  /// answers so far, or zero before any.
  Earlier(index: Int)

  /// This byte position, clamped by the tail; may land mid-character.
  At(position: Int)

  /// This many bytes before the end of the stream.
  Behind(bytes: Int)

  /// Past the end by this much, which the tail must clamp.
  Ahead(bytes: Int)

  /// Below zero by this much, which the tail must clamp.
  Below(bytes: Int)
}

/// One step of a sequence.
type Cmd {
  /// Append a chunk.
  Push(chunk: Chunk)

  /// Ask what arrived after a cursor.
  Poll(cursor: Cursor)
}

fn describe(cmd: Cmd) -> String {
  string.inspect(cmd)
}

// A one-, two-, three- and four-byte character, a newline and a letter.
fn pool() -> List(String) {
  ["a", "é", "€", "😀", "\n", "z"]
}

fn pool_atom(index: Int) -> BitArray {
  let assert Ok(position) = int.modulo(index, list.length(pool()))
    as "the pool is not empty"
  case list.drop(pool(), position) {
    [text, ..] -> bit_array.from_string(text)
    [] -> <<>>
  }
}

// Valid and invalid pieces of UTF-8, plain ASCII, and the 0xFF that no
// stream contains.
fn raw_pool() -> List(Int) {
  [0x41, 0xC3, 0xA9, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0xFF, 0x80]
}

fn raw_bytes(values: List(Int)) -> BitArray {
  list.fold(values, <<>>, fn(bytes, value) {
    let assert Ok(position) = int.modulo(value, list.length(raw_pool()))
      as "the pool is not empty"
    case list.drop(raw_pool(), position) {
      [byte, ..] -> bit_array.append(bytes, <<byte>>)
      [] -> bytes
    }
  })
}

fn bytes_of(model: Model, chunk: Chunk) -> BitArray {
  case chunk {
    Whole(atoms) ->
      list.fold(atoms, <<>>, fn(bytes, atom) {
        bit_array.append(bytes, pool_atom(atom))
      })
    Head(atom, cut) -> slice(pool_atom(atom), 0, cut)
    Remainder -> model.pending
    Raw(values) -> raw_bytes(values)
  }
}

// A range of `bytes`, cut short where the bytes end rather than refused.
fn slice(bytes: BitArray, from: Int, length: Int) -> BitArray {
  let available = bit_array.byte_size(bytes) - from
  case bit_array.slice(bytes, from, int.clamp(length, min: 0, max: available)) {
    Ok(found) -> found
    Error(Nil) -> <<>>
  }
}

fn atoms_gen() -> qcheck.Generator(List(Int)) {
  qcheck.generic_list(
    elements_from: qcheck.bounded_int(from: 0, to: 5),
    length_from: qcheck.bounded_int(from: 0, to: 9),
  )
}

fn chunk_gen() -> qcheck.Generator(Chunk) {
  qcheck.from_weighted_generators(#(6, qcheck.map(atoms_gen(), Whole)), [
    #(
      2,
      qcheck.map2(
        qcheck.bounded_int(from: 1, to: 5),
        qcheck.bounded_int(from: 1, to: 3),
        Head,
      ),
    ),
    #(3, qcheck.return(Remainder)),
    #(
      1,
      qcheck.map(
        qcheck.generic_list(
          elements_from: qcheck.bounded_int(from: 0, to: 9),
          length_from: qcheck.bounded_int(from: 0, to: 6),
        ),
        Raw,
      ),
    ),
  ])
}

fn cursor_gen() -> qcheck.Generator(Cursor) {
  qcheck.from_weighted_generators(
    #(5, qcheck.map(qcheck.bounded_int(from: 0, to: 9), Earlier)),
    [
      #(2, qcheck.map(qcheck.bounded_int(from: 0, to: 80), At)),
      #(2, qcheck.map(qcheck.bounded_int(from: 0, to: 40), Behind)),
      #(1, qcheck.map(qcheck.bounded_int(from: 1, to: 5), Ahead)),
      #(1, qcheck.map(qcheck.bounded_int(from: 1, to: 5), Below)),
    ],
  )
}

fn command(_model: Model) -> qcheck.Generator(Cmd) {
  qcheck.from_weighted_generators(#(3, qcheck.map(chunk_gen(), Push)), [
    #(2, qcheck.map(cursor_gen(), Poll)),
  ])
}

// --- the model and the system ------------------------------------------------

/// Everything ever pushed, the unpushed rest of the last split character,
/// and how many polls have been answered.
type Model {
  Model(stream: BitArray, pending: BitArray, answers: Int)
}

/// The tail, and the cursors its answers returned, newest first.
type System {
  System(tail: Tail, cursors: List(Int))
}

fn next_model(model: Model, cmd: Cmd) -> Model {
  case cmd {
    Push(chunk) -> {
      let stream = bit_array.append(model.stream, bytes_of(model, chunk))
      let pending = case chunk {
        Head(atom, cut) -> {
          let whole = pool_atom(atom)
          slice(whole, cut, bit_array.byte_size(whole) - cut)
        }
        Remainder -> <<>>
        Whole(_) | Raw(_) -> model.pending
      }
      Model(..model, stream:, pending:)
    }
    Poll(_) -> Model(..model, answers: model.answers + 1)
  }
}

fn resolve(system: System, model: Model, cursor: Cursor) -> Int {
  let received = bit_array.byte_size(model.stream)
  case cursor {
    At(position) -> position
    Behind(bytes) -> received - bytes
    Ahead(bytes) -> received + bytes
    Below(bytes) -> 0 - bytes
    Earlier(index) ->
      case int.modulo(index, int.max(list.length(system.cursors), 1)) {
        Ok(position) ->
          case list.drop(list.reverse(system.cursors), position) {
            [found, ..] -> found
            [] -> 0
          }
        Error(Nil) -> 0
      }
  }
}

// --- UTF-8, stated independently of the module -------------------------------

fn byte_list(bytes: BitArray) -> List(Int) {
  case bytes {
    <<byte, rest:bytes>> -> [byte, ..byte_list(rest)]
    _ -> []
  }
}

fn is_continuation(byte: Int) -> Bool {
  byte >= 0x80 && byte < 0xC0
}

// How many bytes a lead byte announces, or nothing for a byte that leads no
// character.
fn announced(byte: Int) -> Result(Int, Nil) {
  case byte {
    _ if byte < 0x80 -> Ok(1)
    _ if byte >= 0xC2 && byte <= 0xDF -> Ok(2)
    _ if byte >= 0xE0 && byte <= 0xEF -> Ok(3)
    _ if byte >= 0xF0 && byte <= 0xF4 -> Ok(4)
    _ -> Error(Nil)
  }
}

// The length of the incomplete character a stream ends in, or zero: a lead
// byte followed by fewer continuation bytes than it announces, and nothing
// after them. A byte that leads nothing is binary and is never incomplete.
fn held_length(stream: BitArray) -> Int {
  let size = bit_array.byte_size(stream)
  let last = byte_list(slice(stream, int.max(size - 3, 0), 3))
  let have = list.length(last)
  let incomplete = fn(length: Int) {
    case length <= have, list.drop(last, have - length) {
      True, [lead, ..rest] ->
        list.all(rest, is_continuation)
        && case announced(lead) {
          Ok(width) -> width > length
          Error(Nil) -> False
        }
      _, _ -> False
    }
  }
  case list.find([1, 2, 3], incomplete) {
    Ok(length) -> length
    Error(Nil) -> 0
  }
}

fn is_text(bytes: BitArray) -> Bool {
  case bit_array.to_string(bytes) {
    Ok(_) -> True
    Error(Nil) -> False
  }
}

// --- the rules ---------------------------------------------------------------

fn broken(tag: String, detail: String) -> Result(Nil, Violation) {
  Error(Violation(tag, detail))
}

fn check_received(system: System, model: Model) -> Result(Nil, Violation) {
  let want = bit_array.byte_size(model.stream)
  use <- bool.guard(when: tail.received(system.tail) == want, return: Ok(Nil))
  broken(
    "tail.received",
    "received "
      <> int.to_string(tail.received(system.tail))
      <> " but "
      <> int.to_string(want)
      <> " bytes were pushed",
  )
}

fn check_pure(system: System, cursor: Int) -> Result(Nil, Violation) {
  let first = tail.since(system.tail, cursor)
  use <- bool.guard(
    when: tail.since(system.tail, cursor) == first,
    return: Ok(Nil),
  )
  broken("tail.pure", "asking twice gave different answers")
}

fn check_cursor(
  answer: tail.Since,
  asked: Int,
  received: Int,
) -> Result(Nil, Violation) {
  use <- bool.guard(
    when: answer.cursor >= asked
      && answer.cursor <= received
      && answer.dropped >= 0,
    return: Ok(Nil),
  )
  broken(
    "tail.cursor",
    "asked "
      <> int.to_string(asked)
      <> " of "
      <> int.to_string(received)
      <> " and was sent to "
      <> int.to_string(answer.cursor),
  )
}

fn check_span(
  answer: tail.Since,
  stream: BitArray,
  asked: Int,
) -> Result(Nil, Violation) {
  let from = asked + answer.dropped
  let size = bit_array.byte_size(answer.bytes)
  use <- bool.guard(
    when: answer.cursor == from + size
      && slice(stream, from, size) == answer.bytes,
    return: Ok(Nil),
  )
  broken(
    "tail.span",
    "after cursor "
      <> int.to_string(asked)
      <> ": dropped "
      <> int.to_string(answer.dropped)
      <> ", bytes "
      <> string.inspect(answer.bytes)
      <> ", next cursor "
      <> int.to_string(answer.cursor)
      <> "; the stream there is "
      <> string.inspect(slice(stream, from, size)),
  )
}

fn check_poll(
  system: System,
  model: Model,
  capacity: Int,
  cursor: Int,
) -> Result(tail.Since, Violation) {
  let answer = tail.since(system.tail, cursor)
  let received = bit_array.byte_size(model.stream)
  let asked = int.clamp(cursor, min: 0, max: received)
  let from = asked + answer.dropped
  let held = held_length(model.stream)
  let complete = slice(model.stream, 0, received - held)

  use Nil <- result.try(check_pure(system, cursor))
  use Nil <- result.try(check_cursor(answer, asked, received))
  use Nil <- result.try(check_span(answer, model.stream, asked))
  use Nil <- result.try(check_bounded(answer, received, capacity, from))
  use Nil <- result.try(check_boundary(answer, received, held, from))
  use Nil <- result.try(check_front(answer, complete, from))
  use Nil <- result.map(check_decodes(answer, complete, from))
  answer
}

fn check_bounded(
  answer: tail.Since,
  received: Int,
  capacity: Int,
  from: Int,
) -> Result(Nil, Violation) {
  let size = bit_array.byte_size(answer.bytes)
  let lost = answer.dropped > 0
  let fits = size <= capacity && from >= received - capacity
  let loss_is_overflow = !lost || received > capacity
  let resumes_near = !lost || from <= received - capacity + 3
  use <- bool.guard(
    when: fits && loss_is_overflow && resumes_near,
    return: Ok(Nil),
  )
  broken(
    "tail.bounded",
    "capacity "
      <> int.to_string(capacity)
      <> ", received "
      <> int.to_string(received)
      <> ", resumed at "
      <> int.to_string(from)
      <> " with "
      <> int.to_string(size)
      <> " bytes, dropped "
      <> int.to_string(answer.dropped),
  )
}

// The answer ends where the stream's incomplete final character begins, or
// at the end of the stream when it has none. A cursor that landed inside
// that final character is asking from the middle of it, and any answer that
// goes nowhere backwards is fine there.
fn check_boundary(
  answer: tail.Since,
  received: Int,
  held: Int,
  from: Int,
) -> Result(Nil, Violation) {
  let want = received - held
  use <- bool.guard(when: from > want || answer.cursor == want, return: Ok(Nil))
  broken(
    "tail.boundary",
    "the answer ends at "
      <> int.to_string(answer.cursor)
      <> " but the stream's complete characters end at "
      <> int.to_string(want)
      <> " (holding back "
      <> int.to_string(held)
      <> ")",
  )
}

// A reader that fell behind resumes at the window's front, which on text is
// a character boundary: never a continuation byte.
fn check_front(
  answer: tail.Since,
  complete: BitArray,
  from: Int,
) -> Result(Nil, Violation) {
  let starts_inside = case byte_list(slice(answer.bytes, 0, 1)) {
    [byte] -> is_continuation(byte)
    _ -> False
  }
  use <- bool.guard(
    when: answer.dropped == 0 || !is_text(complete) || !starts_inside,
    return: Ok(Nil),
  )
  broken(
    "tail.front",
    "the window resumes mid-character at " <> int.to_string(from),
  )
}

fn check_decodes(
  answer: tail.Since,
  complete: BitArray,
  from: Int,
) -> Result(Nil, Violation) {
  let on_boundary = case byte_list(slice(complete, from, 1)) {
    [byte] -> !is_continuation(byte)
    _ -> True
  }
  use <- bool.guard(
    when: !is_text(complete) || !on_boundary || is_text(answer.bytes),
    return: Ok(Nil),
  )
  broken("tail.decodes", "a slice of a text stream does not decode alone")
}

fn execute(
  capacity: Int,
) -> fn(System, Model, Cmd) -> Result(System, Violation) {
  fn(system, model, cmd) {
    case cmd {
      Push(chunk) -> {
        let pushed =
          System(..system, tail: tail.push(system.tail, bytes_of(model, chunk)))
        let after = next_model(model, cmd)
        use Nil <- result.try(check_received(pushed, after))
        Ok(pushed)
      }
      Poll(cursor) -> {
        let asked = resolve(system, model, cursor)
        use answer <- result.try(check_poll(system, model, capacity, asked))
        Ok(System(..system, cursors: [answer.cursor, ..system.cursors]))
      }
    }
  }
}

fn spec(capacity: Int) -> Spec(Model, Cmd, System) {
  Spec(
    initial: Model(stream: <<>>, pending: <<>>, answers: 0),
    command: command,
    precondition: fn(_, _) { Admit },
    next_model: next_model,
    new_sut: fn() { System(tail: tail.new(capacity:), cursors: []) },
    execute: execute(capacity),
    finish: check_received,
    teardown: fn(_) { Nil },
  )
}

fn config() -> statem.Config {
  statem.default_config(seed:)
  |> statem.with_test_count(test_count)
  |> statem.with_max_commands(max_commands)
}

// --- the tests ---------------------------------------------------------------

pub fn the_tail_keeps_its_rules_at_every_capacity_test() {
  list.each(capacities, fn(capacity) {
    case statem.check(spec(capacity), config()) {
      Ok(Nil) -> Nil
      Error(failure) ->
        panic as {
          "capacity "
          <> int.to_string(capacity)
          <> "\n"
          <> statem.report(failure, describe)
        }
    }
  })
}

/// What a walk met, so a test can say the sequences reach the cases the
/// rules are about.
type Fact {
  /// A poll was told bytes fell out of the window.
  Lossy

  /// A poll left a trailing partial character behind.
  HeldBack

  /// A poll asked with a cursor an earlier answer had returned, after more
  /// had been pushed.
  StaleCursor

  /// A poll asked from inside a character.
  MidCharacter

  /// A poll over a stream that is not UTF-8.
  Binary

  /// A push wider than the window.
  OverflowingChunk

  /// A poll over the clamped ends.
  Clamped

  /// A poll that was told of a loss, on a stream whose complete part is
  /// valid UTF-8, so the front and decoding rules were actually in force.
  TextLossy
}

fn facts(capacity: Int) -> List(Fact) {
  let sequence = spec(capacity)

  counting(0, test_count - 1)
  |> list.flat_map(fn(run) {
    let #(_, _, seen) =
      list.fold(
        statem.commands(sequence, config(), run),
        #(Model(<<>>, <<>>, 0), System(tail.new(capacity:), []), []),
        fn(state, cmd) {
          let #(model, system, seen) = state
          let after = next_model(model, cmd)

          case cmd {
            Push(chunk) -> {
              let wide = bit_array.byte_size(bytes_of(model, chunk)) > capacity
              let pushed = tail.push(system.tail, bytes_of(model, chunk))
              let seen = case wide {
                True -> [OverflowingChunk, ..seen]
                False -> seen
              }
              #(after, System(..system, tail: pushed), seen)
            }
            Poll(cursor) -> {
              let asked = resolve(system, model, cursor)
              let received = bit_array.byte_size(model.stream)
              let answer = tail.since(system.tail, asked)

              let clamped = int.clamp(asked, min: 0, max: received)
              let held = held_length(model.stream)
              let landed = slice(model.stream, clamped, 1)

              // Each fact is noted when this poll showed it.
              let noted = [
                #(Lossy, answer.dropped > 0),
                #(
                  TextLossy,
                  answer.dropped > 0
                    && is_text(slice(model.stream, 0, received - held)),
                ),
                #(HeldBack, held > 0 && answer.cursor == received - held),
                #(StaleCursor, case cursor {
                  Earlier(_) -> asked < received && system.cursors != []
                  At(_) | Behind(_) | Ahead(_) | Below(_) -> False
                }),
                #(MidCharacter, case byte_list(landed) {
                  [byte] -> is_continuation(byte)
                  _ -> False
                }),
                #(Binary, !is_text(model.stream)),
                #(Clamped, asked != clamped),
              ]
              let seen =
                list.fold(noted, seen, fn(seen, note) {
                  case note.1 {
                    True -> [note.0, ..seen]
                    False -> seen
                  }
                })
              let system =
                System(..system, cursors: [answer.cursor, ..system.cursors])
              #(after, system, seen)
            }
          }
        },
      )
    seen
  })
}

// A property over sequences that never meet a lossy poll, a held-back
// character or a stale cursor would be green for no reason.
pub fn the_generated_sequences_meet_the_edges_the_rules_are_about_test() {
  list.each(capacities, fn(capacity) {
    let met = facts(capacity)
    list.each(
      [
        Lossy,
        HeldBack,
        StaleCursor,
        MidCharacter,
        Binary,
        OverflowingChunk,
        Clamped,
        TextLossy,
      ],
      fn(fact) {
        assert list.contains(met, fact)
      },
    )
  })
}

// `from..to` ascending and inclusive.
fn counting(from: Int, to: Int) -> List(Int) {
  list.repeat(Nil, int.max(to - from + 1, 0))
  |> list.index_map(fn(_, offset) { from + offset })
}
