//// The shared raw MessagePack walk for fixed native and retained-report profiles.
////
//// The profile is private: callers choose a named boundary rather than supplying
//// resource knobs. Every sibling returns the remaining node budget, including map
//// keys. Payload lengths are checked before the ordinary decoder allocates terms.

import core/corruption.{type CorruptionReport}
import gleam/bit_array
import gleam/result

type Profile {
  Profile(
    at: String,
    bytes: Int,
    depth: Int,
    container_depth: Int,
    nodes: Int,
    array_entries: Int,
    map_entries: Int,
    string_bytes: Int,
    binary_bytes: Int,
  )
}

/// Scans the unchanged native remote wire profile.
///
/// ## Examples
///
/// ```gleam
/// assert msgpack_scan.native(<<0xc0>>) == Ok(Nil)
/// ```
pub fn native(bytes: BitArray) -> Result(Nil, CorruptionReport) {
  check(
    bytes,
    Profile(
      "core/bounded_msgpack.decode",
      262_144,
      16,
      17,
      2048,
      128,
      128,
      8192,
      131_072,
    ),
  )
}

/// Scans one terminal body before any complete-report term decoding.
/// The Outcome map occupies the first container level, leaving 254 value levels.
///
/// ## Examples
///
/// ```gleam
/// assert msgpack_scan.terminal(<<0xc0>>) == Ok(Nil)
/// ```
pub fn terminal(bytes: BitArray) -> Result(Nil, CorruptionReport) {
  check(
    bytes,
    Profile(
      "core/report_value.terminal",
      16_777_216,
      255,
      255,
      65_536,
      65_536,
      32_768,
      16_777_216,
      16_777_216,
    ),
  )
}

/// Scans the closed owner metadata's independent fixed profile.
///
/// ## Examples
///
/// ```gleam
/// assert msgpack_scan.metadata(<<0xc0>>) == Ok(Nil)
/// ```
pub fn metadata(bytes: BitArray) -> Result(Nil, CorruptionReport) {
  check(
    bytes,
    Profile(
      "core/report_value.metadata",
      262_144,
      16,
      16,
      8192,
      128,
      128,
      8192,
      0,
    ),
  )
}

fn check(bytes: BitArray, profile: Profile) -> Result(Nil, CorruptionReport) {
  use Nil <- result.try(
    case
      bit_array.byte_size(bytes) > 0
      && bit_array.byte_size(bytes) <= profile.bytes
      && bit_array.bit_size(bytes) % 8 == 0
    {
      True -> Ok(Nil)
      False -> Error(fail(profile))
    },
  )
  use parsed <- result.try(scan(bytes, 0, profile.nodes, profile))
  case parsed.0 == <<>> {
    True -> Ok(Nil)
    False -> Error(fail(profile))
  }
}

fn scan(
  bytes: BitArray,
  depth: Int,
  nodes: Int,
  profile: Profile,
) -> Result(#(BitArray, Int), CorruptionReport) {
  // Count this node before reading its tag, including empty containers.
  use Nil <- result.try(case depth <= profile.depth && nodes > 0 {
    True -> Ok(Nil)
    False -> Error(fail(profile))
  })

  // Container children consume the same budget as their parent and siblings.
  case bytes {
    <<tag, _rest:bits>>
      if depth >= profile.container_depth
      && {
        { tag >= 0x80 && tag <= 0x9f }
        || tag == 0xdc
        || tag == 0xdd
        || tag == 0xde
        || tag == 0xdf
      }
    -> Error(fail(profile))
    <<tag, rest:bits>>
      if tag <= 0x7f || tag >= 0xe0 || tag == 0xc0 || tag == 0xc2 || tag == 0xc3
    -> Ok(#(rest, nodes - 1))
    <<tag, rest:bits>> if tag >= 0xa0 && tag <= 0xbf ->
      skip(rest, tag - 0xa0, nodes - 1, profile.string_bytes, profile)
    <<tag, rest:bits>> if tag >= 0x90 && tag <= 0x9f ->
      scan_many(rest, tag - 0x90, depth + 1, nodes - 1, profile)
    <<tag, rest:bits>> if tag >= 0x80 && tag <= 0x8f ->
      scan_many(rest, { tag - 0x80 } * 2, depth + 1, nodes - 1, profile)
    <<0xdc, n:size(16), rest:bits>> if n <= profile.array_entries ->
      scan_many(rest, n, depth + 1, nodes - 1, profile)
    <<0xdd, n:size(32), rest:bits>> if n <= profile.array_entries ->
      scan_many(rest, n, depth + 1, nodes - 1, profile)
    <<0xde, n:size(16), rest:bits>> if n <= profile.map_entries ->
      scan_many(rest, n * 2, depth + 1, nodes - 1, profile)
    <<0xdf, n:size(32), rest:bits>> if n <= profile.map_entries ->
      scan_many(rest, n * 2, depth + 1, nodes - 1, profile)
    <<0xd9, n, rest:bits>> ->
      skip(rest, n, nodes - 1, profile.string_bytes, profile)
    <<0xda, n:size(16), rest:bits>> ->
      skip(rest, n, nodes - 1, profile.string_bytes, profile)
    <<0xdb, n:size(32), rest:bits>> ->
      skip(rest, n, nodes - 1, profile.string_bytes, profile)
    <<0xc4, n, rest:bits>> ->
      skip(rest, n, nodes - 1, profile.binary_bytes, profile)
    <<0xc5, n:size(16), rest:bits>> ->
      skip(rest, n, nodes - 1, profile.binary_bytes, profile)
    <<0xc6, n:size(32), rest:bits>> ->
      skip(rest, n, nodes - 1, profile.binary_bytes, profile)
    <<tag, rest:bits>> if tag == 0xcc || tag == 0xd0 ->
      skip(rest, 1, nodes - 1, 8, profile)
    <<tag, rest:bits>> if tag == 0xcd || tag == 0xd1 ->
      skip(rest, 2, nodes - 1, 8, profile)
    <<tag, rest:bits>> if tag == 0xce || tag == 0xd2 ->
      skip(rest, 4, nodes - 1, 8, profile)
    <<tag, rest:bits>> if tag == 0xcf || tag == 0xd3 || tag == 0xcb ->
      skip(rest, 8, nodes - 1, 8, profile)
    _ -> Error(fail(profile))
  }
}

fn skip(
  bytes: BitArray,
  count: Int,
  nodes: Int,
  maximum: Int,
  profile: Profile,
) -> Result(#(BitArray, Int), CorruptionReport) {
  // A declared payload must both fit its field limit and exist in the input.
  case bytes {
    <<_:bytes-size(count), rest:bits>> if count <= maximum -> Ok(#(rest, nodes))
    _ -> Error(fail(profile))
  }
}

fn scan_many(
  bytes: BitArray,
  count: Int,
  depth: Int,
  nodes: Int,
  profile: Profile,
) -> Result(#(BitArray, Int), CorruptionReport) {
  // The returned remainder transfers the shared node budget to the next sibling.
  case count {
    0 -> Ok(#(bytes, nodes))
    _ -> {
      use parsed <- result.try(scan(bytes, depth, nodes, profile))
      scan_many(parsed.0, count - 1, depth, parsed.1, profile)
    }
  }
}

fn fail(profile: Profile) -> CorruptionReport {
  case profile.at {
    "core/bounded_msgpack.decode" ->
      corruption.report(
        at: profile.at,
        on: "remote value",
        expected: "one complete MessagePack value within the fixed remote bounds",
        context: "",
      )
    _ ->
      corruption.report(
        at: profile.at,
        on: "bounded value",
        expected: "one complete MessagePack value within its fixed profile",
        context: "",
      )
  }
}
