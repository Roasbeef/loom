//// The model profiles and model keys a daemon's configuration defines, as
//// session creation and the web home read them (protocol-change/076 and 080).
////
//// A profile is chosen when a session is created and applied when the session's
//// builder loads its configuration (`client/serve.resolve_managed`), so the
//// daemon never holds a role table of its own: each session resolves its roles
//// from the file and the profile name its registration stores. What the daemon
//// does need, before it reserves a registration, is the answer to one question:
//// does the configuration this session will load define the profile it names?
//// Without the check a mistyped name would be stored and the session would fail
//// to start, with its identity already minted. This module answers it, and
//// lists the names for the web form. A session can also be pinned to one
//// `[models.<key>]` entry for its `main` role (protocol-change/080), which is
//// the same question about a key, answered the same way.
////
//// The file is read each time and nothing is cached, because the daemon's
//// configuration is an ordinary file the operator may edit between creations and
//// a resume must see it as it then stands. The file is small and creation is
//// rare, so the read costs nothing that matters.
////
//// ## Flow
////
//// `effective` → `names` → `check` → `model_keys` → `check_model` → `check_choice`
//// → `load`
////
//// 1. `effective` picks the configuration path a creation will load: the one it
////    names, or else the daemon's own.
//// 2. `names` reads that file and returns the profile names it defines, sorted.
//// 3. `check` is `names` plus the refusal that names the profiles that exist.
//// 4. `model_keys` and `check_model` are the same two steps for the model keys
////    a creation may pin the main role to. Both reads go through one private `read`,
////    so a file is judged the same way whichever question asks.
//// 5. `check_choice` is what a creation asks: the profile it chose, if any, and
////    then the model, if any, so a creation that chose both is refused for the
////    first that fails.
//// 6. `load` is the whole parsed catalogue with a profile's roles in place, or
////    the same refusals; a live profile switch reads it (protocol-change/082).

import client/catalog
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

/// The configuration path a session created with `requested` loads: the path
/// the creation named, or the daemon's own when it named none. The empty string
/// means no file, which is the environment-only configuration.
///
/// ## Examples
///
/// ```gleam
/// assert profiles.effective("", "/etc/loom.toml") == "/etc/loom.toml"
/// assert profiles.effective("/home/o/other.toml", "/etc/loom.toml")
///   == "/home/o/other.toml"
/// ```
pub fn effective(requested: String, daemon: String) -> String {
  case requested {
    "" -> daemon
    path -> path
  }
}

/// The profile names the configuration file defines, sorted. No file defines
/// none. A file that cannot be read or does not parse is an error worded the
/// way the daemon words it at startup, because a profile cannot be offered or
/// checked against a configuration the daemon could not load.
///
/// ## Examples
///
/// ```gleam
/// assert profiles.names("") == Ok([])
/// // profiles.names("/home/o/.loom/loom.toml") -> Ok(["deepseek", "gemini"])
/// ```
pub fn names(configuration: String) -> Result(List(String), String) {
  read(configuration, catalog.profile_names)
}

/// The model keys the configuration file defines and a session may be pinned to
/// (`catalog.model_keys`), sorted. No file defines none, and an unusable file is
/// an error worded as `names` words it.
///
/// ## Examples
///
/// ```gleam
/// assert profiles.model_keys("") == Ok([])
/// // profiles.model_keys("/home/o/.loom/loom.toml") -> Ok(["flash", "opus"])
/// ```
pub fn model_keys(configuration: String) -> Result(List(String), String) {
  read(configuration, catalog.model_keys)
}

// Reads the file and lists what `pick` takes from its parsed catalogue. The file
// is read each time, so an edit made since the last creation is seen. The
// environment-only configuration, which has no file, offers neither profiles nor
// keys.
fn read(
  configuration: String,
  pick: fn(catalog.Catalog) -> List(String),
) -> Result(List(String), String) {
  case configuration {
    "" -> Ok([])
    path -> result.map(parse_file(path), pick)
  }
}

// The file parsed as a catalogue, with the daemon's startup wording for a file
// that cannot be read or does not parse.
fn parse_file(path: String) -> Result(catalog.Catalog, String) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(error) {
      "the config file " <> path <> " is unreadable: " <> string.inspect(error)
    }),
  )
  catalog.parse(text)
  |> result.map_error(fn(reason) { path <> ": " <> reason })
}

/// Why a profile or model cannot be chosen. The causes need different words and
/// different codes: a name the file does not define is the person's mistake in
/// the form, and a file the daemon cannot load is the configuration's, whatever
/// was asked for.
pub type Refusal {
  /// The configuration loads and does not define the name. The message names
  /// the profiles that exist.
  UnknownProfile(message: String)

  /// The configuration loads and does not define the model key. The message
  /// names the keys that exist.
  UnknownModel(message: String)

  /// The configuration cannot be read or does not parse, so no profile or model
  /// can be looked up in it. The message is the daemon's own startup wording,
  /// and names the offending key when that is the cause.
  UnusableConfiguration(message: String)
}

/// The sentence a person reads for a refusal.
///
/// ## Examples
///
/// ```gleam
/// assert profiles.refusal_message(profiles.UnknownProfile("no such")) == "no such"
/// ```
pub fn refusal_message(refusal: Refusal) -> String {
  case refusal {
    UnknownProfile(message:)
    | UnknownModel(message:)
    | UnusableConfiguration(message:) -> message
  }
}

/// Whether the configuration defines the named profile. The refusal says which
/// cause it was, and its message is the sentence a person reads: it names the
/// profile asked for and the ones that exist, or says there are none, or gives
/// the configuration error.
///
/// ## Examples
///
/// ```gleam
/// assert profiles.check("", "deepseek")
///   == Error(profiles.UnknownProfile(
///     "unknown profile \"deepseek\"; the configuration defines no profiles",
///   ))
/// ```
pub fn check(configuration: String, name: String) -> Result(Nil, Refusal) {
  use known <- result.try(
    names(configuration) |> result.map_error(UnusableConfiguration),
  )
  case list.contains(known, name) {
    True -> Ok(Nil)
    False -> Error(UnknownProfile(catalog.unknown_profile(known, name)))
  }
}

/// Whether the configuration defines the named model key, answered as `check`
/// answers it for a profile.
///
/// ## Examples
///
/// ```gleam
/// assert profiles.check_model("", "flash")
///   == Error(profiles.UnknownModel(
///     "unknown model \"flash\"; the configuration defines no models",
///   ))
/// ```
pub fn check_model(configuration: String, key: String) -> Result(Nil, Refusal) {
  use known <- result.try(
    model_keys(configuration) |> result.map_error(UnusableConfiguration),
  )
  case list.contains(known, key) {
    True -> Ok(Nil)
    False -> Error(UnknownModel(catalog.unknown_model(known, key)))
  }
}

/// Whether the configuration defines everything a creation chose: the profile if
/// it named one, then the model if it named one. A creation that chose neither
/// is accepted without the file being read, as a creation always was. The first
/// refusal is returned, so the profile is reported before the model.
///
/// ## Examples
///
/// ```gleam
/// assert profiles.check_choice("", None, None) == Ok(Nil)
/// assert profiles.check_choice("", Some("deepseek"), Some("flash"))
///   == profiles.check("", "deepseek")
/// ```
pub fn check_choice(
  configuration: String,
  profile: Option(String),
  model: Option(String),
) -> Result(Nil, Refusal) {
  use Nil <- result.try(case profile {
    None -> Ok(Nil)
    Some(name) -> check(configuration, name)
  })
  case model {
    None -> Ok(Nil)
    Some(key) -> check_model(configuration, key)
  }
}

/// The catalogue a session routes by when it runs under `profile`: the whole
/// parsed configuration with that profile's roles in place, or with the default
/// roles for `None`. A name the file does not define is `UnknownProfile`, and a
/// file that cannot be read is `UnusableConfiguration`, the same split `check`
/// makes.
///
/// A session with no configuration file has no profiles and no catalogue to
/// load, so it can run under the default roles it already has and nothing else.
///
/// ## Examples
///
/// ```gleam
/// assert profiles.load("", Some("deepseek"))
///   == Error(profiles.UnknownProfile(
///     "unknown profile \"deepseek\"; the configuration defines no profiles",
///   ))
/// // profiles.load("/home/o/.loom/loom.toml", Some("deepseek")) -> Ok(catalogue)
/// ```
pub fn load(
  configuration: String,
  profile: Option(String),
) -> Result(catalog.Catalog, Refusal) {
  case configuration, profile {
    "", Some(name) -> Error(UnknownProfile(catalog.unknown_profile([], name)))
    "", None ->
      Error(UnusableConfiguration(
        "this session has no configuration file, so it has only its default roles",
      ))
    path, None -> parse_file(path) |> result.map_error(UnusableConfiguration)
    path, Some(name) -> {
      use parsed <- result.try(
        parse_file(path) |> result.map_error(UnusableConfiguration),
      )
      catalog.select_profile(parsed, name)
      |> result.map_error(UnknownProfile)
    }
  }
}
