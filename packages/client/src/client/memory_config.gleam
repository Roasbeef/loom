//// The `[memory]` table of `loom.toml`: what memory a run starts with.
////
//// ## Flow
////
//// `parse` → `memory_table` → `known_keys` → `retired_keys` → `inject_of`
////
//// 1. `parse` reads the document and finds the `[memory]` table; an absent
////    table is the default posture.
//// 2. `memory_table` checks the keys first, so a typo is refused rather than
////    ignored, then decodes the one live key.
//// 3. `retired_keys` lists the settings of the removed distillation pass
////    that the file still carries. They are read and do nothing.
//// 4. `inject_of` decodes the one setting left.
////
//// # Why the old keys are accepted
////
//// `distill`, `distill_wall_ms` and `inject = "digest"` named an optional
//// background job that was removed. None of them is a safety setting, so
//// refusing them would only break a daemon upgrade over a file that loaded
//// the day before. Each is accepted with any value and reported back in
//// `Options.retired`, so the caller can warn once per key that it is ignored
//// and can be deleted; `inject = "digest"` also counts as the default,
//// `notes`. The leftover `loom-memory.digest` file and any distillate rows
//// in `loom-memory.db` stay on disk untouched and are never read. A key
//// that never existed is still an error.
////
//// The top-level key `memory` must also be in `client/catalog`'s allowed
//// list, which is where this document's table names are checked.

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import tom

/// What is injected into each run, from the `[memory]` table's `inject`
/// key.
///
/// A variant per thing injected rather than a flag, because a flag would
/// leave every reader carrying the polarity of its name.
pub type Injection {
  /// No memory message reaches any run, and no run-start hook that reads a
  /// sidecar is installed. The store and sidecars stay protected from
  /// jailed writes regardless.
  InjectsNothing

  /// The default. Each run starts with the notes index attached as a
  /// message: one line per note, newest first, about a kilobyte. A
  /// repository with no notes sees no message.
  InjectsNotes
}

/// The `[memory]` table, decoded.
pub type Options {
  Options(
    /// What each run starts with.
    inject: Injection,
    /// The retired settings the file still carries, by name and in the
    /// order they are listed here: `distill`, `distill_wall_ms`, and
    /// `inject` when its value is `"digest"`. They have no effect; the host
    /// warns about each so the operator can delete the line.
    retired: List(String),
  )
}

/// The posture of a host whose configuration says nothing: the notes index is
/// injected.
///
/// ## Examples
///
/// ```gleam
/// assert memory_config.default_options().inject == memory_config.InjectsNotes
/// ```
///
pub fn default_options() -> Options {
  Options(inject: InjectsNotes, retired: [])
}

/// Decodes the `[memory]` table out of a `loom.toml` document.
///
/// Total, and strict about what it will accept: an unknown key in the table
/// is a refusal rather than a silently ignored line. An absent table is the
/// default posture. The retired settings (`distill` and `distill_wall_ms`
/// with any value, and `inject = "digest"`) are accepted, do nothing, and
/// are named in `Options.retired`.
///
/// ## Examples
///
/// ```gleam
/// assert memory_config.parse("") == Ok(memory_config.default_options())
/// ```
///
/// ```gleam
/// assert memory_config.parse("[memory]\ninject = \"off\"\n")
///   == Ok(memory_config.Options(
///     inject: memory_config.InjectsNothing,
///     retired: [],
///   ))
/// ```
///
pub fn parse(text: String) -> Result(Options, String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(fn(error) {
      "the configuration is not valid TOML: " <> string.inspect(error)
    }),
  )
  from_document(document)
}

/// Reads memory options from the catalogue's already parsed document.
/// The standalone `parse` retains its TOML error wording; both doors use
/// the same table validation and defaults.
///
/// ## Examples
///
/// ```gleam
/// assert memory_config.from_document(dict.new()) == Ok(memory_config.default_options())
/// ```
@internal
pub fn from_document(
  document: Dict(String, tom.Toml),
) -> Result(Options, String) {
  case dict.get(document, "memory") {
    Error(Nil) -> Ok(default_options())
    Ok(tom.Table(fields)) -> memory_table(fields)
    Ok(_other) -> Error("[memory] must be a table")
  }
}

fn memory_table(fields: Dict(String, tom.Toml)) -> Result(Options, String) {
  use Nil <- result.try(known_keys(fields))
  use inject <- result.map(inject_of(fields))
  Options(inject:, retired: retired_keys(fields))
}

/// Parses known keys while rejecting unsupported memory configuration fields.
fn known_keys(fields: Dict(String, tom.Toml)) -> Result(Nil, String) {
  let allowed = ["distill", "distill_wall_ms", "inject"]

  // known keys handles the list.find(dict.keys(fields), fn(key) outcomes before continuing the operation.
  case list.find(dict.keys(fields), fn(key) { !list.contains(allowed, key) }) {
    Error(Nil) -> Ok(Nil)
    Ok(unknown) ->
      Error(
        "unknown key `"
        <> unknown
        <> "` in the [memory] table (allowed: "
        <> string.join(allowed, ", ")
        <> ")",
      )
  }
}

// The value is never read: a retired key means the same whatever it says,
// which is that nothing consults it.
/// Parses retired keys while rejecting unsupported memory configuration fields.
fn retired_keys(fields: Dict(String, tom.Toml)) -> List(String) {
  // retired keys handles the the selected value outcomes before continuing the operation.
  let digest = case dict.get(fields, "inject") {
    Ok(tom.String("digest")) -> ["inject"]
    _ -> []
  }

  list.append(
    list.filter(["distill", "distill_wall_ms"], dict.has_key(fields, _)),
    digest,
  )
}

/// Parses inject of while rejecting unsupported memory configuration fields.
fn inject_of(fields: Dict(String, tom.Toml)) -> Result(Injection, String) {
  case dict.get(fields, "inject") {
    Error(Nil) -> Ok(InjectsNotes)
    Ok(tom.String("off")) -> Ok(InjectsNothing)
    Ok(tom.String("notes")) -> Ok(InjectsNotes)

    // The digest was the retired pass's product, so the nearest live
    // posture is the default.
    Ok(tom.String("digest")) -> Ok(InjectsNotes)
    Ok(_other) ->
      Error(
        "memory.inject must be one of \"off\" or \"notes\": \"notes\" (the "
        <> "default) attaches the index of remembered notes to each run, and "
        <> "\"off\" attaches nothing",
      )
  }
}
