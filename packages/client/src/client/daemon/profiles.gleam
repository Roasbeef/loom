//// The model profiles a daemon's configuration defines, as session creation and
//// the web home read them (protocol-change/076).
////
//// A profile is chosen when a session is created and applied when the session's
//// builder loads its configuration (`client/serve.resolve_managed`), so the
//// daemon never holds a role table of its own: each session resolves its roles
//// from the file and the profile name its registration stores. What the daemon
//// does need, before it reserves a registration, is the answer to one question:
//// does the configuration this session will load define the profile it names?
//// Without the check a mistyped name would be stored and the session would fail
//// to start, with its identity already minted. This module answers it, and
//// lists the names for the web form.
////
//// The file is read each time and nothing is cached, because the daemon's
//// configuration is an ordinary file the operator may edit between creations and
//// a resume must see it as it then stands. The file is small and creation is
//// rare, so the read costs nothing that matters.
////
//// ## Flow
////
//// `effective` → `names` → `check`
////
//// 1. `effective` picks the configuration path a creation will load: the one it
////    names, or else the daemon's own.
//// 2. `names` reads that file and returns the profile names it defines, sorted.
//// 3. `check` is `names` plus the refusal that names the profiles that exist.

import client/catalog
import gleam/list
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
  case configuration {
    "" -> Ok([])
    path -> {
      use text <- result.try(
        simplifile.read(path)
        |> result.map_error(fn(error) {
          "the config file "
          <> path
          <> " is unreadable: "
          <> string.inspect(error)
        }),
      )
      use parsed <- result.map(
        catalog.parse(text)
        |> result.map_error(fn(reason) { path <> ": " <> reason }),
      )
      catalog.profile_names(parsed)
    }
  }
}

/// Whether the configuration defines the named profile. The refusal is the
/// sentence a person reads: it names the profile asked for and the ones that
/// exist, or says there are none.
///
/// ## Examples
///
/// ```gleam
/// assert profiles.check("", "deepseek")
///   == Error("unknown profile \"deepseek\"; the configuration defines no profiles")
/// ```
pub fn check(configuration: String, name: String) -> Result(Nil, String) {
  use known <- result.try(names(configuration))
  case list.contains(known, name) {
    True -> Ok(Nil)
    False -> Error(catalog.unknown_profile(known, name))
  }
}
