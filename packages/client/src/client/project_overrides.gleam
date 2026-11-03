//// A project's own settings: the values that take precedence over the
//// `[project]` table for one project (protocol-change/106, "Settings held per
//// project").
////
//// The table in `loom.toml` is the daemon's default for every project. A
//// project that needs another `check` or `setup` holds its own, in its ledger,
//// and the effective value of a key is the project's own, else the table's,
//// else the built-in default. Five keys can be held this way: `check`,
//// `setup`, `publish`, `max_workers` and `protected_paths`. `token_ceiling`
//// and the event sources stay daemon-wide, because nothing about one project
//// changes what they bound.
////
//// This module is pure. It owns the shape of an override, the precedence rule
//// and the question "where did this value come from", and it checks a value
//// with the same functions that check the file (`project_settings`), so a
//// value is refused for the same reason and in the same words in both places.
//// The actor that holds the overrides, and the ledger record that makes them
//// durable, are in `client/daemon/project_host`.
////
//// ## Flow
////
//// `parse` → `with` → `effective` → `source_of`

import client/project_settings.{type PublishMode, type Settings}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// One of the five keys a project can hold for itself.
pub type Key {
  /// The command run against a worker's head.
  CheckKey

  /// The command that makes the project's template.
  SetupKey

  /// Whether the host may push and open pull requests.
  PublishKey

  /// General worker slots.
  MaxWorkersKey

  /// The paths whose change keeps the check from running.
  ProtectedPathsKey
}

/// Every key, in the order a client lists them.
pub const keys = [
  CheckKey,
  SetupKey,
  PublishKey,
  MaxWorkersKey,
  ProtectedPathsKey,
]

/// A checked value for one key. It can only be built by `parse`, which applies
/// the same rules as the file.
pub type Override {
  /// The project's own check command.
  CheckIs(command: String)

  /// The project's own setup command.
  SetupIs(command: String)

  /// The project's own publish mode.
  PublishIs(mode: PublishMode)

  /// The project's own number of general worker slots.
  MaxWorkersIs(count: Int)

  /// The project's own protected path patterns.
  ProtectedPathsAre(patterns: List(String))
}

/// The values a project holds for itself. A key that is `None` is inherited.
pub type Overrides {
  Overrides(
    /// The project's own check command.
    check: Option(String),
    /// The project's own setup command.
    setup: Option(String),
    /// The project's own publish mode.
    publish: Option(PublishMode),
    /// The project's own number of general worker slots.
    max_workers: Option(Int),
    /// The project's own protected path patterns.
    protected_paths: Option(List(String)),
  )
}

/// A project that holds nothing and so inherits every key.
pub const none =
  Overrides(
    check: None,
    setup: None,
    publish: None,
    max_workers: None,
    protected_paths: None,
  )

/// The five keys with a value each: what the file gives, or what is in force.
pub type Values {
  Values(
    /// The check command, or none.
    check: Option(String),
    /// The setup command, or none.
    setup: Option(String),
    /// Whether the host may publish.
    publish: PublishMode,
    /// General worker slots.
    max_workers: Int,
    /// The protected path patterns.
    protected_paths: List(String),
  )
}

/// The five keys of the `[project]` table, with their defaults filled in.
///
/// ## Examples
///
/// ```gleam
/// assert project_overrides.file_values(project_settings.defaults).max_workers == 4
/// ```
pub fn file_values(file: Settings) -> Values {
  Values(
    check: file.check,
    setup: file.setup,
    publish: file.publish,
    max_workers: file.max_workers,
    protected_paths: file.protected_paths,
  )
}

/// Where an effective value came from.
pub type Source {
  /// The project holds the value itself.
  FromProject

  /// The `[project]` table sets it, to something other than the default.
  FromFile

  /// Nobody set it, so the built-in default applies.
  FromDefault
}

/// The word for a key, as the wire and `loom project set` spell it.
///
/// ## Examples
///
/// ```gleam
/// assert project_overrides.key_word(project_overrides.CheckKey) == "check"
/// ```
pub fn key_word(key: Key) -> String {
  case key {
    CheckKey -> "check"
    SetupKey -> "setup"
    PublishKey -> "publish"
    MaxWorkersKey -> "max_workers"
    ProtectedPathsKey -> "protected_paths"
  }
}

/// The key a word names, or a refusal that lists the five.
///
/// ## Examples
///
/// ```gleam
/// assert project_overrides.key_from_word("setup") == Ok(project_overrides.SetupKey)
/// ```
pub fn key_from_word(word: String) -> Result(Key, String) {
  case list.find(keys, fn(key) { key_word(key) == word }) {
    Ok(key) -> Ok(key)
    Error(Nil) ->
      Error(
        "a project holds check, setup, publish, max_workers and "
        <> "protected_paths, not `"
        <> word
        <> "`",
      )
  }
}

/// The word for a source.
///
/// ## Examples
///
/// ```gleam
/// assert project_overrides.source_word(project_overrides.FromFile) == "file"
/// ```
pub fn source_word(source: Source) -> String {
  case source {
    FromProject -> "project"
    FromFile -> "file"
    FromDefault -> "default"
  }
}

/// Checks the words a client sent for one key. A single-valued key takes one
/// word, and `protected_paths` takes any number, including none.
///
/// ## Examples
///
/// ```gleam
/// assert project_overrides.parse(project_overrides.MaxWorkersKey, ["6"])
///   == Ok(project_overrides.MaxWorkersIs(6))
/// assert result.is_error(project_overrides.parse(project_overrides.MaxWorkersKey, ["0"]))
/// ```
pub fn parse(key: Key, values: List(String)) -> Result(Override, String) {
  case key, values {
    CheckKey, [text] ->
      project_settings.command_text("check", text) |> result.map(CheckIs)
    SetupKey, [text] ->
      project_settings.command_text("setup", text) |> result.map(SetupIs)
    PublishKey, [word] ->
      project_settings.publish_word(word) |> result.map(PublishIs)
    MaxWorkersKey, [word] ->
      int.parse(word)
      |> result.replace_error("project.max_workers must be an integer in range")
      |> result.try(project_settings.worker_count)
      |> result.map(MaxWorkersIs)
    ProtectedPathsKey, patterns ->
      project_settings.path_patterns(patterns) |> result.map(ProtectedPathsAre)
    _, _ -> Error("project." <> key_word(key) <> " takes exactly one value")
  }
}

/// The key and the words an override was parsed from, which is what the ledger
/// keeps and the wire shows.
///
/// ## Examples
///
/// ```gleam
/// assert project_overrides.words(project_overrides.CheckIs("make"))
///   == #(project_overrides.CheckKey, ["make"])
/// ```
pub fn words(override: Override) -> #(Key, List(String)) {
  case override {
    CheckIs(command) -> #(CheckKey, [command])
    SetupIs(command) -> #(SetupKey, [command])
    PublishIs(mode) -> #(PublishKey, [project_settings.publish_mode_word(mode)])
    MaxWorkersIs(count) -> #(MaxWorkersKey, [int.to_string(count)])
    ProtectedPathsAre(patterns) -> #(ProtectedPathsKey, patterns)
  }
}

/// The overrides with one more value held.
///
/// ## Examples
///
/// ```gleam
/// let held = project_overrides.with(project_overrides.none, project_overrides.CheckIs("make"))
/// assert held.check == option.Some("make")
/// ```
pub fn with(held: Overrides, override: Override) -> Overrides {
  case override {
    CheckIs(command) -> Overrides(..held, check: Some(command))
    SetupIs(command) -> Overrides(..held, setup: Some(command))
    PublishIs(mode) -> Overrides(..held, publish: Some(mode))
    MaxWorkersIs(count) -> Overrides(..held, max_workers: Some(count))
    ProtectedPathsAre(patterns) ->
      Overrides(..held, protected_paths: Some(patterns))
  }
}

/// The overrides with one key given back to the file's value.
///
/// ## Examples
///
/// ```gleam
/// let held = project_overrides.with(project_overrides.none, project_overrides.CheckIs("make"))
/// assert project_overrides.without(held, project_overrides.CheckKey) == project_overrides.none
/// ```
pub fn without(held: Overrides, key: Key) -> Overrides {
  case key {
    CheckKey -> Overrides(..held, check: None)
    SetupKey -> Overrides(..held, setup: None)
    PublishKey -> Overrides(..held, publish: None)
    MaxWorkersKey -> Overrides(..held, max_workers: None)
    ProtectedPathsKey -> Overrides(..held, protected_paths: None)
  }
}

/// The settings in force: the project's own value for each key it holds, else
/// the file's, which is the default when the file says nothing.
///
/// ## Examples
///
/// ```gleam
/// let file = project_overrides.file_values(project_settings.defaults)
/// assert project_overrides.effective(file, project_overrides.none) == file
/// ```
pub fn effective(file: Values, held: Overrides) -> Values {
  Values(
    check: option.or(held.check, file.check),
    setup: option.or(held.setup, file.setup),
    publish: option.unwrap(held.publish, file.publish),
    max_workers: option.unwrap(held.max_workers, file.max_workers),
    protected_paths: option.unwrap(held.protected_paths, file.protected_paths),
  )
}

/// Where the effective value of a key came from. The file counts as the
/// source only when it differs from the built-in default, since a value equal
/// to the default is the default whoever wrote it.
///
/// ## Examples
///
/// ```gleam
/// let file = project_overrides.file_values(project_settings.defaults)
/// assert project_overrides.source_of(file, project_overrides.none, project_overrides.CheckKey)
///   == project_overrides.FromDefault
/// ```
pub fn source_of(file: Values, held: Overrides, key: Key) -> Source {
  let defaults = file_values(project_settings.defaults)

  // For the key asked about: whether the project holds it, and whether the
  // file sets it to something other than the default.
  let #(own, file_differs) = case key {
    CheckKey -> #(option.is_some(held.check), file.check != defaults.check)
    SetupKey -> #(option.is_some(held.setup), file.setup != defaults.setup)
    PublishKey -> #(
      option.is_some(held.publish),
      file.publish != defaults.publish,
    )
    MaxWorkersKey -> #(
      option.is_some(held.max_workers),
      file.max_workers != defaults.max_workers,
    )
    ProtectedPathsKey -> #(
      option.is_some(held.protected_paths),
      file.protected_paths != defaults.protected_paths,
    )
  }

  // The project's own value outranks the file's, and the file's outranks the
  // default.
  case own, file_differs {
    True, _ -> FromProject
    False, True -> FromFile
    False, False -> FromDefault
  }
}

/// One requested change to a project's own settings.
pub type Change {
  /// Hold a value for the project.
  Hold(override: Override)

  /// Give a key back to the `[project]` table.
  Release(key: Key)
}

/// One key as a client reads it: the value in force, where it came from, and
/// when the project last changed it.
pub type Entry {
  Entry(
    /// The key.
    key: Key,
    /// The words of the value in force. A check or setup that nobody set has
    /// none, and so does a `protected_paths` of nothing.
    values: List(String),
    /// Where the value came from.
    source: Source,
    /// Who last changed the project's own value, and when, in milliseconds
    /// since the epoch. Both are absent for a key never changed.
    changed: Option(#(String, Int)),
  )
}

/// A project's settings as `projects.settings` replies.
pub type View {
  View(
    /// How many changes the project has had. A write names the revision it
    /// read, and a write that read an older one is refused as stale.
    revision: Int,
    /// The five keys, in the order of `keys`.
    entries: List(Entry),
    /// The URL a verified branch would be published to, when the project has
    /// a remote. Turning `publish` on names it.
    publish_url: Option(String),
  )
}

/// The words of the value of one key.
///
/// ## Examples
///
/// ```gleam
/// let file = project_overrides.file_values(project_settings.defaults)
/// assert project_overrides.value_words(file, project_overrides.MaxWorkersKey) == ["4"]
/// ```
pub fn value_words(values: Values, key: Key) -> List(String) {
  case key {
    CheckKey ->
      option.to_result(values.check, Nil)
      |> result.map(fn(c) { [c] })
      |> result.unwrap([])
    SetupKey ->
      option.to_result(values.setup, Nil)
      |> result.map(fn(c) { [c] })
      |> result.unwrap([])
    PublishKey -> [project_settings.publish_mode_word(values.publish)]
    MaxWorkersKey -> [int.to_string(values.max_workers)]
    ProtectedPathsKey -> values.protected_paths
  }
}
