//// Opaque identifiers and the injected UUIDv7 generator.
////
//// Every durable id in Loom — entry, usage row, operation, session — is a
//// UUIDv7:
//// 48 bits of Unix-millisecond mint time, the version nibble `7`, 12 random
//// bits, the RFC variant bits `10`, and 62 more random bits. The time
//// prefix makes every reference self-describing and time-sortable; the
//// canonical text form sorts lexicographically in mint-time order.
////
//// Minting is pure. Both inputs are injected: time comes from a
//// `core/clock` `Clock` and randomness from a seeded deterministic
//// generator, so the same `Generator` value always mints the same ids. The
//// runtime seeds the generator from a real entropy source; tests seed it
//// with a constant.
////
//// Minting rules (pi harness spec §1.2, rules 1–3):
////
//// 1. Ids are minted with the clock's `now` when their committing operation
////    begins.
//// 2. Tool-result ids inherit their assistant id's 48-bit timestamp with a
////    fresh random tail (`mint_follower`), so a call-and-results group is
////    time-cohesive under id order even across a midnight boundary.
//// 3. Synthetic settlements write under already-reserved ids — followers
////    and reserved ids go through the same constructors, no special case.
////
//// The four id types are distinct opaque wrappers around the same UUID
//// shape, so an `EntryId` can never be passed where an `OpId` is expected.
//// `SessionId` (`protocol-change/008`) names a whole session rather than a
//// row inside one: it is minted once at session creation, persisted in the
//// session's own store, and is what the event bus keys by and what a
//// forked session records as its parent.

import core/clock.{type Clock}
import core/corruption.{type CorruptionReport}
import gleam/int
import gleam/string

/// A storage-assigned sequence number: strictly increasing per session,
/// gaps legal. Assigned by storage at commit, never minted here.
pub type Seq =
  Int

/// The 128 bits of a UUIDv7, kept as fields so the time prefix is directly
/// readable. Invariants: `0 <= ms < 2^48`, `0 <= rand_a < 2^12`,
/// `0 <= rand_b < 2^62`. Enforced by the minting and parsing constructors.
type Uuid {
  Uuid(ms: Int, rand_a: Int, rand_b: Int)
}

/// Identity of a conversation-tree entry. A UUIDv7; see the module doc.
pub opaque type EntryId {
  /// Invariant: `uuid` satisfies the `Uuid` field invariants.
  EntryId(uuid: Uuid)
}

/// Identity of a usage-ledger row. A UUIDv7; see the module doc.
pub opaque type UsageId {
  /// Invariant: `uuid` satisfies the `Uuid` field invariants.
  UsageId(uuid: Uuid)
}

/// Identity of an operation. A UUIDv7; see the module doc.
pub opaque type OpId {
  /// Invariant: `uuid` satisfies the `Uuid` field invariants.
  OpId(uuid: Uuid)
}

/// Identity of a whole session. A UUIDv7; see the module doc.
///
/// Distinct from the three row ids on purpose: a session outlives every
/// row in it, exists before its first entry, and survives a precise
/// rewrite that erases entries — so no entry, usage or operation id can
/// stand in for one (`protocol-change/008`).
pub opaque type SessionId {
  /// Invariant: `uuid` satisfies the `Uuid` field invariants.
  SessionId(uuid: Uuid)
}

/// A deterministic UUIDv7 minting capability: a clock plus a pseudo-random
/// state, both threaded through every mint. Two generators built from the
/// same clock and seed mint identical id sequences.
pub opaque type Generator {
  /// Invariant: `state` is the current 64-bit state of the internal
  /// pseudo-random sequence, always masked to 64 bits.
  Generator(clock: Clock, state: Int)
}

/// Builds a generator from an injected clock and random seed. The runtime
/// seeds from real entropy; tests pass a constant for reproducible ids.
///
/// ## Examples
///
/// ```gleam
/// let generator = ids.generator(clock.fixed(at: 0), seed: 42)
/// let #(first, _generator) = ids.mint_entry(generator)
/// let #(same, _generator) =
///   ids.mint_entry(ids.generator(clock.fixed(at: 0), seed: 42))
/// assert first == same
/// ```
///
pub fn generator(clock: Clock, seed seed: Int) -> Generator {
  Generator(clock:, state: int.bitwise_and(seed, mask_64))
}

/// Mints a fresh `EntryId` at the generator's current time (minting rule 1).
/// Returns the id and the successor generator, which must be threaded.
///
/// ## Examples
///
/// ```gleam
/// let generator = ids.generator(clock.fixed(at: 1000), seed: 1)
/// let #(id, _generator) = ids.mint_entry(generator)
/// assert ids.entry_id_timestamp_ms(id) == 1000
/// ```
///
pub fn mint_entry(generator: Generator) -> #(EntryId, Generator) {
  let #(uuid, generator) = mint_uuid(generator)
  #(EntryId(uuid:), generator)
}

/// Mints a fresh `UsageId` at the generator's current time (minting rule 1).
///
/// ## Examples
///
/// ```gleam
/// let generator = ids.generator(clock.fixed(at: 1000), seed: 1)
/// let #(id, _generator) = ids.mint_usage(generator)
/// assert ids.usage_id_timestamp_ms(id) == 1000
/// ```
///
pub fn mint_usage(generator: Generator) -> #(UsageId, Generator) {
  let #(uuid, generator) = mint_uuid(generator)
  #(UsageId(uuid:), generator)
}

/// Mints a fresh `OpId` at the generator's current time (minting rule 1).
///
/// ## Examples
///
/// ```gleam
/// let generator = ids.generator(clock.fixed(at: 1000), seed: 1)
/// let #(id, _generator) = ids.mint_op(generator)
/// assert ids.op_id_timestamp_ms(id) == 1000
/// ```
///
pub fn mint_op(generator: Generator) -> #(OpId, Generator) {
  let #(uuid, generator) = mint_uuid(generator)
  #(OpId(uuid:), generator)
}

/// Mints a fresh `SessionId` at the generator's current time (minting
/// rule 1). Minted once, when a session is created; every later open of
/// that session reads the persisted id back rather than minting again.
///
/// ## Examples
///
/// ```gleam
/// let generator = ids.generator(clock.fixed(at: 1000), seed: 1)
/// let #(id, _generator) = ids.mint_session(generator)
/// assert ids.session_id_timestamp_ms(id) == 1000
/// ```
///
pub fn mint_session(generator: Generator) -> #(SessionId, Generator) {
  let #(uuid, generator) = mint_uuid(generator)
  #(SessionId(uuid:), generator)
}

/// Mints an `EntryId` that inherits the 48-bit time prefix of `leader` with
/// a fresh random tail (minting rule 2). Used for tool-result ids, which
/// share their assistant id's timestamp so the call-and-results group stays
/// contiguous under id order.
///
/// ## Examples
///
/// ```gleam
/// let generator = ids.generator(clock.fixed(at: 1000), seed: 1)
/// let #(leader, generator) = ids.mint_entry(generator)
/// let #(follower, _generator) = ids.mint_follower(generator, of: leader)
/// assert ids.entry_id_timestamp_ms(follower)
///   == ids.entry_id_timestamp_ms(leader)
/// ```
///
pub fn mint_follower(
  generator: Generator,
  of leader: EntryId,
) -> #(EntryId, Generator) {
  let EntryId(uuid: Uuid(ms:, ..)) = leader
  let #(uuid, generator) = mint_uuid_at(generator, ms)
  #(EntryId(uuid:), generator)
}

/// Formats an `EntryId` in canonical lowercase UUID text form.
///
/// ## Examples
///
/// ```gleam
/// let generator = ids.generator(clock.fixed(at: 0), seed: 9)
/// let #(id, _generator) = ids.mint_entry(generator)
/// assert string.length(ids.entry_id_to_string(id)) == 36
/// ```
///
pub fn entry_id_to_string(id: EntryId) -> String {
  uuid_to_string(id.uuid)
}

/// Formats a `UsageId` in canonical lowercase UUID text form.
///
/// ## Examples
///
/// ```gleam
/// let generator = ids.generator(clock.fixed(at: 0), seed: 9)
/// let #(id, _generator) = ids.mint_usage(generator)
/// assert string.length(ids.usage_id_to_string(id)) == 36
/// ```
///
pub fn usage_id_to_string(id: UsageId) -> String {
  uuid_to_string(id.uuid)
}

/// Formats an `OpId` in canonical lowercase UUID text form.
///
/// ## Examples
///
/// ```gleam
/// let generator = ids.generator(clock.fixed(at: 0), seed: 9)
/// let #(id, _generator) = ids.mint_op(generator)
/// assert string.length(ids.op_id_to_string(id)) == 36
/// ```
///
pub fn op_id_to_string(id: OpId) -> String {
  uuid_to_string(id.uuid)
}

/// Formats a `SessionId` in canonical lowercase UUID text form — the
/// durable form: what the session's `session/id` cell holds, what the
/// SQLite catalog row records, and what the event bus and the search
/// index key by.
///
/// ## Examples
///
/// ```gleam
/// let generator = ids.generator(clock.fixed(at: 0), seed: 9)
/// let #(id, _generator) = ids.mint_session(generator)
/// assert string.length(ids.session_id_to_string(id)) == 36
/// ```
///
pub fn session_id_to_string(id: SessionId) -> String {
  uuid_to_string(id.uuid)
}

/// Parses an `EntryId` from UUID text form. Case-insensitive; the canonical
/// form emitted by `entry_id_to_string` is lowercase. Total: anything that
/// is not a well-formed UUIDv7 with the RFC variant is a corruption report,
/// never a crash.
///
/// ## Examples
///
/// ```gleam
/// let generator = ids.generator(clock.fixed(at: 0), seed: 9)
/// let #(id, _generator) = ids.mint_entry(generator)
/// assert ids.parse_entry_id(ids.entry_id_to_string(id)) == Ok(id)
/// ```
///
/// ```gleam
/// let assert Error(_report) = ids.parse_entry_id("not-a-uuid")
/// ```
///
pub fn parse_entry_id(text: String) -> Result(EntryId, CorruptionReport) {
  case parse_uuid(text) {
    Ok(uuid) -> Ok(EntryId(uuid:))
    Error(report) -> Error(report)
  }
}

/// Parses a `UsageId` from UUID text form. Same rules as `parse_entry_id`.
///
/// ## Examples
///
/// ```gleam
/// let generator = ids.generator(clock.fixed(at: 0), seed: 9)
/// let #(id, _generator) = ids.mint_usage(generator)
/// assert ids.parse_usage_id(ids.usage_id_to_string(id)) == Ok(id)
/// ```
///
pub fn parse_usage_id(text: String) -> Result(UsageId, CorruptionReport) {
  case parse_uuid(text) {
    Ok(uuid) -> Ok(UsageId(uuid:))
    Error(report) -> Error(report)
  }
}

/// Parses an `OpId` from UUID text form. Same rules as `parse_entry_id`.
///
/// ## Examples
///
/// ```gleam
/// let generator = ids.generator(clock.fixed(at: 0), seed: 9)
/// let #(id, _generator) = ids.mint_op(generator)
/// assert ids.parse_op_id(ids.op_id_to_string(id)) == Ok(id)
/// ```
///
pub fn parse_op_id(text: String) -> Result(OpId, CorruptionReport) {
  case parse_uuid(text) {
    Ok(uuid) -> Ok(OpId(uuid:))
    Error(report) -> Error(report)
  }
}

/// Parses a `SessionId` from UUID text form — the total decoder for the
/// durable form. Same rules as `parse_entry_id`: anything that is not a
/// well-formed UUIDv7 with the RFC variant is a corruption report, never
/// a crash.
///
/// ## Examples
///
/// ```gleam
/// let generator = ids.generator(clock.fixed(at: 0), seed: 9)
/// let #(id, _generator) = ids.mint_session(generator)
/// assert ids.parse_session_id(ids.session_id_to_string(id)) == Ok(id)
/// ```
///
pub fn parse_session_id(text: String) -> Result(SessionId, CorruptionReport) {
  case parse_uuid(text) {
    Ok(uuid) -> Ok(SessionId(uuid:))
    Error(report) -> Error(report)
  }
}

/// Reads the 48-bit mint-time prefix of an `EntryId` as Unix milliseconds.
///
/// ## Examples
///
/// ```gleam
/// let generator = ids.generator(clock.fixed(at: 77), seed: 9)
/// let #(id, _generator) = ids.mint_entry(generator)
/// assert ids.entry_id_timestamp_ms(id) == 77
/// ```
///
pub fn entry_id_timestamp_ms(id: EntryId) -> Int {
  id.uuid.ms
}

/// Reads the 48-bit mint-time prefix of a `UsageId` as Unix milliseconds.
///
/// ## Examples
///
/// ```gleam
/// let generator = ids.generator(clock.fixed(at: 77), seed: 9)
/// let #(id, _generator) = ids.mint_usage(generator)
/// assert ids.usage_id_timestamp_ms(id) == 77
/// ```
///
pub fn usage_id_timestamp_ms(id: UsageId) -> Int {
  id.uuid.ms
}

/// Reads the 48-bit mint-time prefix of an `OpId` as Unix milliseconds.
///
/// ## Examples
///
/// ```gleam
/// let generator = ids.generator(clock.fixed(at: 77), seed: 9)
/// let #(id, _generator) = ids.mint_op(generator)
/// assert ids.op_id_timestamp_ms(id) == 77
/// ```
///
pub fn op_id_timestamp_ms(id: OpId) -> Int {
  id.uuid.ms
}

/// Reads the 48-bit mint-time prefix of a `SessionId` as Unix
/// milliseconds — when the session was created.
///
/// ## Examples
///
/// ```gleam
/// let generator = ids.generator(clock.fixed(at: 77), seed: 9)
/// let #(id, _generator) = ids.mint_session(generator)
/// assert ids.session_id_timestamp_ms(id) == 77
/// ```
///
pub fn session_id_timestamp_ms(id: SessionId) -> Int {
  id.uuid.ms
}

// --- internal: minting --------------------------------------------------

const mask_64 = 0xFFFFFFFFFFFFFFFF

const mask_48 = 0xFFFFFFFFFFFF

fn mint_uuid(generator: Generator) -> #(Uuid, Generator) {
  let #(now, next_clock) = clock.read(generator.clock)
  mint_uuid_at(Generator(..generator, clock: next_clock), now)
}

// Shared by `mint_uuid` (reads the clock) and `mint_follower` (reuses a
// leader's timestamp instead), so the two id-shapes draw randomness through
// one path and differ only in where `ms` comes from.
fn mint_uuid_at(generator: Generator, ms: Int) -> #(Uuid, Generator) {
  let #(a, state) = next_random(generator.state)
  let #(b, state) = next_random(state)
  let uuid =
    Uuid(
      ms: int.bitwise_and(ms, mask_48),
      rand_a: int.bitwise_and(a, 0xFFF),
      rand_b: int.bitwise_and(b, 0x3FFFFFFFFFFFFFFF),
    )
  #(uuid, Generator(..generator, state:))
}

// The SplitMix64 sequence: a tiny, well-studied 64-bit generator. Chosen
// because it is a handful of masked integer operations, has full 2^64
// period, and makes minting fully deterministic from the injected seed.
fn next_random(state: Int) -> #(Int, Int) {
  let state = int.bitwise_and(state + 0x9E3779B97F4A7C15, mask_64)
  let z = state
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 30))
        * 0xBF58476D1CE4E5B9,
      mask_64,
    )
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 27))
        * 0x94D049BB133111EB,
      mask_64,
    )
  let z = int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 31))
  #(z, state)
}

// --- internal: text form ------------------------------------------------

fn uuid_to_string(uuid: Uuid) -> String {
  let Uuid(ms:, rand_a:, rand_b:) = uuid
  // Layout: time_high(32) - time_low(16) - ver(4)+rand_a(12) -
  // var(2)+rand_b_high(14) - rand_b_low(48).
  let group_3 = int.bitwise_or(0x7000, rand_a)
  let group_4 = int.bitwise_or(0x8000, int.bitwise_shift_right(rand_b, 48))
  let group_5 = int.bitwise_and(rand_b, mask_48)
  hex(int.bitwise_shift_right(ms, 16), 8)
  <> "-"
  <> hex(int.bitwise_and(ms, 0xFFFF), 4)
  <> "-"
  <> hex(group_3, 4)
  <> "-"
  <> hex(group_4, 4)
  <> "-"
  <> hex(group_5, 12)
}

fn hex(value: Int, width: Int) -> String {
  value
  |> int.to_base16
  |> string.lowercase
  |> string.pad_start(to: width, with: "0")
}

fn parse_uuid(text: String) -> Result(Uuid, CorruptionReport) {
  let malformed = fn(expected: String) {
    corruption.report(
      at: "core/ids.parse",
      on: "uuid text",
      expected:,
      context: text,
    )
  }
  case string.split(text, on: "-") {
    [group_1, group_2, group_3, group_4, group_5] -> {
      case
        parse_hex(group_1, 8),
        parse_hex(group_2, 4),
        parse_hex(group_3, 4),
        parse_hex(group_4, 4),
        parse_hex(group_5, 12)
      {
        Ok(time_high), Ok(time_low), Ok(g3), Ok(g4), Ok(g5) -> {
          let version = int.bitwise_shift_right(g3, 12)
          let variant = int.bitwise_shift_right(g4, 14)
          case version == 7, variant == 0b10 {
            True, True ->
              Ok(Uuid(
                ms: int.bitwise_or(
                  int.bitwise_shift_left(time_high, 16),
                  time_low,
                ),
                rand_a: int.bitwise_and(g3, 0xFFF),
                rand_b: int.bitwise_or(
                  int.bitwise_shift_left(int.bitwise_and(g4, 0x3FFF), 48),
                  g5,
                ),
              ))
            False, _ -> Error(malformed("uuid version 7"))
            True, False -> Error(malformed("rfc uuid variant bits 10"))
          }
        }
        _, _, _, _, _ ->
          Error(malformed("groups of 8-4-4-4-12 hexadecimal digits"))
      }
    }
    _ -> Error(malformed("five dash-separated groups"))
  }
}

// Parses exactly `width` hexadecimal digits. Stricter than
// `int.base_parse`, which would accept signs and mixed lengths.
fn parse_hex(text: String, width: Int) -> Result(Int, Nil) {
  parse_hex_loop(string.to_graphemes(text), width, 0)
}

// The width is counted down through the digits rather than measured
// first. `list.length` walks the whole string to answer a question about
// its first `width` characters, and this runs per parsed id; counting
// down settles both ways of being wrong — a place missing, or a digit
// past the width — at the bound itself.
fn parse_hex_loop(
  digits: List(String),
  remaining: Int,
  accumulator: Int,
) -> Result(Int, Nil) {
  case digits, remaining {
    [], 0 -> Ok(accumulator)
    // Short: the text ran out with places still owed.
    [], _ -> Error(Nil)
    // Long: a digit sits past the width, which the length check caught
    // and a bare fold would have silently consumed.
    [_, ..], 0 -> Error(Nil)
    [digit, ..rest], _ ->
      case hex_digit_value(digit) {
        Ok(value) ->
          parse_hex_loop(rest, remaining - 1, accumulator * 16 + value)
        Error(Nil) -> Error(Nil)
      }
  }
}

fn hex_digit_value(digit: String) -> Result(Int, Nil) {
  case digit {
    "0" -> Ok(0)
    "1" -> Ok(1)
    "2" -> Ok(2)
    "3" -> Ok(3)
    "4" -> Ok(4)
    "5" -> Ok(5)
    "6" -> Ok(6)
    "7" -> Ok(7)
    "8" -> Ok(8)
    "9" -> Ok(9)
    "a" | "A" -> Ok(10)
    "b" | "B" -> Ok(11)
    "c" | "C" -> Ok(12)
    "d" | "D" -> Ok(13)
    "e" | "E" -> Ok(14)
    "f" | "F" -> Ok(15)
    _ -> Error(Nil)
  }
}
