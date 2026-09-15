//// Release metadata is decoded before any archive is acquired or installed.
////
//// A manifest binds one platform's artifacts to a full source commit. Its
//// digest fields establish byte equality; authenticity comes separately from
//// the transport and, when required, a signature made by an operator-trusted key.

import core/json
import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/result
import gleam/string

/// One downloadable component with its expected extraction root.
pub type Artifact {
  Artifact(
    /// The component selected by the installation shape.
    component: String,
    /// A basename, never a URL or filesystem path.
    name: String,
    /// The sole top-level directory the archive must contain.
    root: String,
    /// Exact compressed byte length, checked before extraction.
    size: Int,
    /// Lowercase SHA-256 of the compressed archive.
    sha256: String,
  )
}

/// A completely decoded release selection.
pub type Manifest {
  Manifest(
    /// GitHub owner and repository bound by the selection policy.
    repository: String,
    /// Published release tag, including commit-addressed builds.
    tag: String,
    /// The application version reported by the build.
    version: String,
    /// Full lowercase source commit, never an ambiguous abbreviation.
    commit: String,
    /// Native operating system and architecture.
    platform: String,
    /// Exactly the server, bundled client and slim client artifacts.
    artifacts: List(Artifact),
  )
}

/// Decodes bounded metadata with duplicate keys refused by the shared parser.
///
/// ## Examples
///
/// ```gleam
/// manifest.decode("{}") // Error("release manifest lacks schema")
/// ```
pub fn decode(input: String) -> Result(Manifest, String) {
  use <- bool.guard(
    bit_array.byte_size(<<input:utf8>>) > 262_144,
    Error("release manifest exceeds 256 KiB"),
  )
  use document <- result.try(
    json.parse(input) |> result.map_error(fn(_) { "invalid release JSON" }),
  )
  use schema <- result.try(integer(document, "schema"))
  use <- bool.guard(schema != 1, Error("unsupported release manifest schema"))
  use repository <- result.try(text(document, "repository"))
  use tag <- result.try(text(document, "tag"))
  use version <- result.try(text(document, "version"))
  use commit <- result.try(text(document, "commit"))
  use platform <- result.try(text(document, "platform"))
  use <- bool.guard(!hexadecimal(commit, 40), Error("invalid release commit"))
  use <- bool.guard(
    !basename(tag) || !basename(version) || !valid_platform(platform),
    Error("invalid release identity"),
  )
  use entries <- result.try(field(document, "artifacts"))
  use artifacts <- result.try(decode_artifacts(entries))
  Ok(Manifest(repository, tag, version, commit, platform, artifacts))
}

fn valid_platform(platform) {
  list.contains(
    ["linux-x86_64", "linux-arm64", "macos-x86_64", "macos-arm64"],
    platform,
  )
}

fn decode_artifacts(value) {
  use entries <- result.try(case value {
    json.Array([first, second, third]) -> Ok([first, second, third])
    json.Array(_) -> Error("release must contain exactly three components")
    _ -> Error("release artifacts must be an array")
  })
  use artifacts <- result.try(list.try_map(entries, decode_artifact))
  let components = list.map(artifacts, fn(item) { item.component })
  use <- bool.guard(
    !list.all(["server", "client", "slim"], fn(name) {
      list.contains(components, name)
    }),
    Error("release components must be server, client and slim"),
  )
  use <- bool.guard(
    list.length(list.unique(list.map(artifacts, fn(item) { item.name }))) != 3,
    Error("release artifact names must be distinct"),
  )
  Ok(artifacts)
}

fn decode_artifact(value) {
  use component <- result.try(text(value, "component"))
  use name <- result.try(text(value, "name"))
  use root <- result.try(text(value, "root"))
  use size <- result.try(integer(value, "size"))
  use sha256 <- result.try(text(value, "sha256"))
  use <- bool.guard(
    !basename(name) || !basename(root) || name != root <> ".tar.gz",
    Error("invalid release artifact path"),
  )
  use <- bool.guard(
    size <= 0 || size > 536_870_912 || !hexadecimal(sha256, 64),
    Error("invalid release artifact size or digest"),
  )
  Ok(Artifact(component, name, root, size, sha256))
}

/// Accepts one conservative ASCII basename without shell or path syntax.
///
/// ## Examples
///
/// ```gleam
/// manifest.basename("loom-0.2.0-linux-arm64") // True
/// manifest.basename("../loom") // False
/// ```
pub fn basename(value: String) -> Bool {
  string.length(value) > 0
  && string.length(value) <= 200
  && value != "."
  && value != ".."
  && list.all(string.to_utf_codepoints(value), fn(point) {
    let code = string.utf_codepoint_to_int(point)
    code >= 48
    && code <= 57
    || code >= 65
    && code <= 90
    || code >= 97
    && code <= 122
    || code == 45
    || code == 46
    || code == 95
  })
}

/// Checks exact-width lowercase hexadecimal identities.
///
/// ## Examples
///
/// ```gleam
/// manifest.hexadecimal("abc123", 6) // True
/// ```
pub fn hexadecimal(value: String, width: Int) -> Bool {
  bit_array.byte_size(<<value:utf8>>) == width
  && list.all(string.to_utf_codepoints(value), fn(point) {
    let code = string.utf_codepoint_to_int(point)
    code >= 48 && code <= 57 || code >= 97 && code <= 102
  })
}

fn field(value, key) {
  case value {
    json.Object(fields) ->
      list.key_find(fields, key)
      |> result.map_error(fn(_) { "release manifest lacks " <> key })
    _ -> Error("release manifest member must be an object")
  }
}

fn text(value, key) {
  use value <- result.try(field(value, key))
  case value {
    json.String(text) -> Ok(text)
    _ -> Error("release manifest " <> key <> " must be a string")
  }
}

fn integer(value, key) {
  use value <- result.try(field(value, key))
  case value {
    json.Int(number) -> Ok(number)
    _ -> Error("release manifest " <> key <> " must be an integer")
  }
}
