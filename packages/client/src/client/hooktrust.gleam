//// The hook trust record: the operator's yes, written against a hash.
////
//// An imported hook source is code the operator did not write, pointed
//// at events the harness fires — the same posture
//// `client/extension/record.gleam` holds an installed extension to, and
//// the same pattern Codex adopted for its hooks. Loom's ruling (the
//// design note's "Trust: recorded, hash-pinned, per source") is that a
//// non-managed source needs that trust *recorded* rather than implied,
//// and recorded against the **hash of the definition it was read
//// from**: `client/hookcompat.hash` over the parsed model. A changed
//// definition changes the hash, the record no longer matches, and the
//// source re-enters review — skipped until an operator trusts it again.
//// Nothing here ever widens what was approved, for the reason the
//// extension record gives: re-deriving the terms of an approval at load
//// would let an operator's yes silently follow the loader's current
//// reading of the file.
////
//// # One file per source
////
//// ```
//// <dir>/<safe-name>.json
//// ```
////
//// where `<safe-name>` is the source's label sanitized to a filename:
//// letters, digits, `_` and `-` kept, everything else collapsed to `-`.
//// A label of `user settings` is `user-settings.json`; a repo's
//// `.claude/settings.json` label arrives as something like
//// `project-.claude-settings.json` from whoever loads it. One file per
//// source keeps trust per source — revoking one source never touches
//// another, and `scan` reads a directory rather than diffing one file.
////
//// The record holds label, origin, hash and time, and nothing else.
//// Who trusted it is deliberately absent: a trust action is taken by
//// whoever can write the file, and recording a name would be theater
//// the file system cannot back. The hash is the only field a later
//// load *decides* from; the rest is prose for the operator.

import client/hookcompat.{type Config, type Origin}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import simplifile

// --- the verdict -------------------------------------------------------------

/// Whether a source may run as it currently stands.
pub type Verdict {
  /// The recorded hash equals the config's current hash: the definition
  /// an operator approved is the definition on disk.
  Trusted

  /// No record, or a record for a different definition: the source is
  /// skipped until an operator trusts it again.
  NeedsReview
}

/// Compares what was trusted for this source against what is loaded
/// now. The decision is the hash and only the hash — label and origin
/// are descriptive, and a relabelled source with an unchanged
/// definition is the same approval.
///
/// ## Examples
///
/// ```gleam
/// // after hooktrust.trust(path, config, now)
/// assert hooktrust.check(hooktrust.load(path), config) == hooktrust.Trusted
/// ```
///
pub fn check(record: Option(Record), config: Config) -> Verdict {
  case record {
    // No record is the first review, not a verdict against an empty
    // hash: an absent file and a mismatched one land in the same place
    // an operator looks, but for different reasons worth keeping
    // distinct in the type's reading.
    None -> NeedsReview

    Some(approved) ->
      case approved.hash == hookcompat.hash(config) {
        True -> Trusted
        False -> NeedsReview
      }
  }
}

// --- the record -------------------------------------------------------------

/// One recorded approval: what was trusted, from where, at which hash,
/// and when. Nothing more — the fields an operator reads when asked why
/// a source runs, and the one field a load re-derives.
pub type Record {
  Record(
    /// The source label as it was trusted, e.g. `user settings`.
    label: String,
    /// The origin's name, e.g. `user-settings`.
    origin: String,
    /// The `hookcompat.hash` of the approved definition.
    hash: String,
    /// The Unix-millisecond instant trust was recorded at.
    trusted_at_ms: Int,
  )
}

/// The origin's stable name: the vocabulary the record file and CLI
/// output carry, one word per precedence class, plugin names kept
/// inline so a plugin's record reads as its own source.
///
/// ## Examples
///
/// ```gleam
/// assert hooktrust.origin_name(hookcompat.UserSettings) == "user-settings"
/// assert hooktrust.origin_name(hookcompat.Plugin("memory"))
///   == "plugin:memory"
/// ```
///
pub fn origin_name(origin: Origin) -> String {
  case origin {
    hookcompat.UserSettings -> "user-settings"
    hookcompat.ProjectSettings -> "project-settings"
    hookcompat.LocalSettings -> "local-settings"
    hookcompat.Plugin(name) -> "plugin:" <> name
    hookcompat.LoomInline -> "loom-inline"
  }
}

/// Renders a record as the JSON written to disk. Field set frozen:
/// anything added later re-enters every record through decode.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(read) = hooktrust.load(path)
/// assert json.to_string(hooktrust.encode(read))
///   == json.to_string(hooktrust.encode(read))
/// ```
///
pub fn encode(record: Record) -> Json {
  json.object([
    #("label", json.string(record.label)),
    #("origin", json.string(record.origin)),
    #("hash", json.string(record.hash)),
    #("trusted_at_ms", json.int(record.trusted_at_ms)),
  ])
}

/// Decodes a record's JSON text. Total: every malformed document is a
/// worded error naming the field it tripped on, never a crash — the
/// same discipline `extension/record.gleam` holds its file to.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(record) = hooktrust.decode(text)
/// assert record.hash == hookcompat.hash(config)
/// ```
///
pub fn decode(text: String) -> Result(Record, String) {
  json.parse(from: text, using: record_decoder())
  |> result.map_error(describe_decode_error)
}

fn record_decoder() -> Decoder(Record) {
  use label <- decode.field("label", decode.string)
  use origin <- decode.field("origin", decode.string)
  use hash <- decode.field("hash", decode.string)
  use trusted_at_ms <- decode.field("trusted_at_ms", decode.int)

  decode.success(Record(label:, origin:, hash:, trusted_at_ms:))
}

// The refusal names the record and the path the decoder walked, so an
// operator can open the file and see the field it disagrees about.
fn describe_decode_error(error: json.DecodeError) -> String {
  case error {
    json.UnableToDecode(errors) ->
      "the hook trust record does not decode: "
      <> string.join(fields(errors), ", ")

    json.UnexpectedEndOfInput -> "the hook trust record is truncated"

    json.UnexpectedByte(byte) ->
      "the hook trust record has an unexpected byte " <> byte

    json.UnexpectedSequence(text) ->
      "the hook trust record has an unexpected sequence " <> text
  }
}

fn fields(errors: List(decode.DecodeError)) -> List(String) {
  list.map(errors, fn(error) {
    let decode.DecodeError(expected:, found:, path:) = error
    "expected "
    <> expected
    <> " but found "
    <> found
    <> " at ."
    <> string.join(path, ".")
  })
}

// --- paths ------------------------------------------------------------------

/// The record file's name for a source: the label sanitized to a
/// filename. Letters, digits, `_` and `-` are kept; every other
/// character — spaces, slashes, dots, anything a label may carry —
/// becomes `-`, so one label maps to one file and a label can never
/// escape the trust directory.
///
/// ## Examples
///
/// ```gleam
/// assert hooktrust.safe_name("user settings") == "user-settings.json"
/// assert hooktrust.safe_name("../escape") == "..-escape.json"
/// ```
///
pub fn safe_name(label: String) -> String {
  string.to_graphemes(label)
  |> list.map(sanitize_grapheme)
  |> string.concat
  <> ".json"
}

// One grapheme at a time, so a multi-byte character collapses to one
// dash rather than one per byte.
fn sanitize_grapheme(grapheme: String) -> String {
  case string.to_utf_codepoints(grapheme) {
    [codepoint] ->
      case keeps(codepoint) {
        True -> grapheme
        False -> "-"
      }

    // A grapheme cluster of several codepoints (an accent, a flag) is
    // not in the kept set by construction: it is not one letter.
    _ -> "-"
  }
}

// The kept set is ASCII letters, digits, `_` and `-` — the characters a
// filename may carry on every file system this runs on, with no case
// folding to surprise a case-insensitive volume.
fn keeps(codepoint: UtfCodepoint) -> Bool {
  let code = string.utf_codepoint_to_int(codepoint)
  { code >= 0x61 && code <= 0x7A }
  || { code >= 0x41 && code <= 0x5A }
  || { code >= 0x30 && code <= 0x39 }
  || code == 0x5F
  || code == 0x2D
}

/// The full path of a source's record inside a trust directory.
///
/// The directory a session passes is `<home>/hooktrust`, where `<home>`
/// is the operator's own `HOME` as the server read it — the same home
/// the located sources are discovered under.
///
/// ## Examples
///
/// ```gleam
/// assert hooktrust.record_path("/home/a/hooktrust", "user settings")
///   == "/home/a/hooktrust/user-settings.json"
/// ```
///
pub fn record_path(dir: String, label: String) -> String {
  dir <> "/" <> safe_name(label)
}

// --- durable file -----------------------------------------------------------

/// Reads one record file. Every failure — unreadable, unparsable, a
/// field missing or of the wrong shape — is a worded error naming the
/// path, so a broken record is a fact an operator can act on.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(record) = hooktrust.load(path)
/// assert hooktrust.check(Ok(record), config) == hooktrust.Trusted
/// ```
///
pub fn load(path: String) -> Result(Record, String) {
  use body <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(error) {
      "the hook trust record at "
      <> path
      <> " could not be read: "
      <> simplifile.describe_error(error)
    }),
  )
  decode(body)
}

/// Writes one record file, creating the trust directory if it is
/// absent. Overwrites whatever was there: re-trusting is the operator's
/// act, and the file's job is to carry the latest approval, not a
/// history of them.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(Nil) = hooktrust.save(path, record)
/// assert hooktrust.load(path) == Ok(record)
/// ```
///
pub fn save(path: String, record: Record) -> Result(Nil, String) {
  use Nil <- result.try(
    simplifile.create_directory_all(directory_of(path))
    |> result.map_error(describe_write(
      path,
      "its directory could not be created",
    )),
  )

  simplifile.write(to: path, contents: json.to_string(encode(record)))
  |> result.map_error(describe_write(path, "the file could not be written"))
}

// The directory a record path sits in: everything before the last
// slash. A path with no slash has no directory to create and the
// create is a no-op on an empty string, which simplifile accepts.
fn directory_of(path: String) -> String {
  case string.split_once(path, "/") {
    Error(Nil) -> path

    Ok(_first_and_rest) ->
      path
      |> string.split("/")
      |> drop_last
      |> string.join("/")
  }
}

fn drop_last(items: List(String)) -> List(String) {
  case items {
    [] -> []

    // A single element leaves the empty list: the file has no
    // directory component to speak of.
    [_only] -> []

    [first, ..rest] -> [first, ..drop_last(rest)]
  }
}

fn describe_write(
  path: String,
  reason: String,
) -> fn(simplifile.FileError) -> String {
  fn(error) {
    "the hook trust record at "
    <> path
    <> " could not be saved ("
    <> reason
    <> "): "
    <> simplifile.describe_error(error)
  }
}

/// Records trust for a source's current definition: the config's hash
/// as of this call, stamped with `now`.
///
/// No CLI calls this yet. `loom hooks trust` is the intended surface
/// and does not exist in the tree, so the only source that serves
/// today is the user-level file trusted on first sight
/// (`client/hookserve.trusted`).
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(Nil) = hooktrust.trust(path, config, 1_700_000_000_000)
/// assert hooktrust.check(hooktrust.load(path), config) == hooktrust.Trusted
/// ```
///
pub fn trust(path: String, config: Config, now: Int) -> Result(Nil, String) {
  let hookcompat.Config(source: hookcompat.Source(label:, origin:), ..) = config

  save(
    path,
    Record(
      label:,
      origin: origin_name(origin),
      hash: hookcompat.hash(config),
      trusted_at_ms: now,
    ),
  )
}

/// Withdraws trust by deleting the record. Absent is success — the
/// state the operator asked for is "no record for this source", and a
/// file already gone is that state — the same discipline
/// `extension/record` applies to removals.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(Nil) = hooktrust.revoke(path)
/// assert hooktrust.load(path) |> hooktrust.check(config) == NeedsReview
/// ```
///
pub fn revoke(path: String) -> Result(Nil, String) {
  case simplifile.delete(path) {
    Ok(_) -> Ok(Nil)

    Error(error) ->
      case simplifile.is_file(path) {
        // Still there: the delete genuinely failed and the error is
        // the fact an operator needs.
        Ok(True) ->
          Error(
            "the hook trust record at "
            <> path
            <> " could not be deleted: "
            <> simplifile.describe_error(error),
          )

        // Already absent: the goal state, reached twice.
        Ok(False) -> Ok(Nil)

        // Unaskable: carry the delete's error rather than invent a
        // second one for a probe that failed for its own reason.
        Error(_unaskable) ->
          Error(
            "the hook trust record at "
            <> path
            <> " could not be deleted: "
            <> simplifile.describe_error(error),
          )
      }
  }
}

/// Every well-formed record under a trust directory, in directory
/// order. A malformed file is skipped rather than crashing the scan —
/// it is data about a broken state, and `load` on that one path is
/// where its error belongs — and so is an entry that is a directory
/// rather than a record.
///
/// ## Examples
///
/// ```gleam
/// // two records and one corrupt file on disk
/// assert list.length(hooktrust.scan(dir)) == 2
/// ```
///
pub fn scan(dir: String) -> List(Record) {
  case simplifile.read_directory(dir) {
    Error(_) -> []

    Ok(entries) ->
      entries
      |> list.filter_map(fn(name) { load(dir <> "/" <> name) })
  }
}

// --- CLI prose --------------------------------------------------------------

/// A one-line summary of a record for CLI output.
///
/// ## Examples
///
/// ```gleam
/// assert hooktrust.describes(record)
///   == "user settings: trusted abcdef123456 at 2023-11-14T22:13:20Z"
/// ```
///
pub fn describes(record: Record) -> String {
  record.label
  <> ": trusted "
  <> string.slice(record.hash, 0, 12)
  <> " at "
  <> instant(record.trusted_at_ms)
}

/// Renders a Unix-millisecond instant as RFC3339 UTC, the vocabulary
/// the rest of the server writes times in.
///
/// ## Examples
///
/// ```gleam
/// assert hooktrust.instant(0) == "1970-01-01T00:00:00Z"
/// ```
///
pub fn instant(at_ms: Int) -> String {
  timestamp.from_unix_seconds(at_ms / 1000)
  |> timestamp.to_rfc3339(duration.seconds(0))
}
