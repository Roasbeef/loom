//// Release resolution binds GitHub metadata to the manifest's repository,
//// tag, native platform and full source commit. A commit without a published
//// build is an error; resolution never compiles downloaded source implicitly.

import core/json
import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/result
import gleam/string
import host/bootstrap as host
import simplifile
import tui/update/files
import tui/update/manifest
import tui/update/options

/// Whether a requested resource exists at the source.
pub type Presence {
  /// A complete response was written to the requested private destination.
  Present

  /// The source explicitly reported absence, such as HTTP 404.
  Absent
}

/// Bounded acquisition supplied by the transport adapter.
pub type Fetch =
  fn(String, String, Int) -> Result(Presence, String)

/// A verified manifest and the source directory or URL containing its assets.
pub type Release {
  Release(
    /// Fully decoded metadata, authenticated when signature policy requires it.
    manifest: manifest.Manifest,
    /// HTTPS download base, or an absolute local distribution path.
    base: String,
    /// Whether the successfully verified manifest carried a signature.
    signature: Presence,
  )
}

/// Resolves metadata and verifies its signature and requested identity.
///
/// ## Examples
///
/// ```gleam
/// // source.resolve(options, platform, private_stage, fetch)
/// ```
pub fn resolve(
  choices: options.Options,
  platform: String,
  stage: String,
  fetch: Fetch,
) -> Result(Release, String) {
  use #(base, tag, commit) <- result.try(resolve_base(
    choices,
    platform,
    stage,
    fetch,
  ))
  let name = "manifest-" <> platform <> ".json"
  let path = stage <> "/" <> name
  use presence <- result.try(acquire(base <> "/" <> name, path, 262_144, fetch))
  use <- bool.guard(
    presence == Absent,
    Error("selected release has no manifest for " <> platform),
  )
  use signature <- result.try(acquire(
    base <> "/" <> name <> ".asc",
    path <> ".asc",
    65_536,
    fetch,
  ))
  use Nil <- result.try(verify_signature(signature, choices, path, stage))
  use bytes <- result.try(host.read_bounded(path, 262_144))
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.replace_error("release manifest is not UTF-8"),
  )
  use document <- result.try(manifest.decode(text))
  use Nil <- result.try(bind(document, platform, tag, commit, choices.selection))
  Ok(Release(document, base, signature))
}

fn resolve_base(choices: options.Options, platform, stage, fetch) {
  case choices.from, choices.mirror {
    "", "" -> github_base(choices, stage, fetch)
    "", mirror -> {
      let suffix = "/manifest-" <> platform <> ".json"
      use <- bool.guard(
        !string.starts_with(mirror, "https://")
          || !string.ends_with(mirror, suffix),
        Error("mirror must be an HTTPS URL ending in " <> suffix),
      )
      Ok(#(string.drop_end(mirror, string.length(suffix)), "", ""))
    }
    _, "" -> {
      use directory <- result.try(host.canonical_directory(choices.from))
      Ok(#(directory, "", ""))
    }
    _, _ -> Error("select either --from or --manifest-url")
  }
}

fn github_base(choices: options.Options, stage, fetch) {
  case choices.from {
    "" -> {
      use #(tag, commit) <- result.try(resolve_selection(
        choices.selection,
        stage,
        fetch,
      ))
      Ok(#(
        "https://github.com/Roasbeef/loom/releases/download/" <> tag,
        tag,
        commit,
      ))
    }
    directory -> {
      use directory <- result.try(host.canonical_directory(directory))
      Ok(#(directory, "", ""))
    }
  }
}

fn resolve_selection(selection, stage, fetch) {
  case selection {
    options.Tag(tag) -> Ok(#(tag, ""))
    options.Latest -> {
      use document <- result.try(api("releases/latest", stage, fetch))
      use tag <- result.try(json_string(document, "tag_name"))
      use <- bool.guard(
        !manifest.basename(tag),
        Error("latest release has an invalid tag"),
      )
      Ok(#(tag, ""))
    }
    options.Commit(requested) -> {
      use document <- result.try(api("commits/" <> requested, stage, fetch))
      use commit <- result.try(json_string(document, "sha"))
      use <- bool.guard(
        !manifest.hexadecimal(commit, 40)
          || !string.starts_with(commit, requested),
        Error("GitHub resolved a different source commit"),
      )
      Ok(#("commit-" <> commit, commit))
    }
  }
}

fn api(path, stage, fetch) {
  let destination = stage <> "/github.json"
  use presence <- result.try(fetch(
    "https://api.github.com/repos/Roasbeef/loom/" <> path,
    destination,
    1_048_576,
  ))
  use <- bool.guard(
    presence == Absent,
    Error("no published release or source commit found"),
  )
  use bytes <- result.try(host.read_bounded(destination, 1_048_576))
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.replace_error("GitHub metadata is not UTF-8"),
  )
  json.parse(text) |> result.replace_error("invalid GitHub release metadata")
}

fn json_string(document, key) {
  use fields <- result.try(case document {
    json.Object(fields) -> Ok(fields)
    _ -> Error("GitHub metadata is not an object")
  })
  use value <- result.try(
    list.key_find(fields, key)
    |> result.map_error(fn(_) { "GitHub metadata lacks " <> key }),
  )
  case value {
    json.String(value) -> Ok(value)
    _ -> Error("GitHub metadata has an invalid " <> key)
  }
}

fn bind(document: manifest.Manifest, platform, tag, commit, selection) {
  use <- bool.guard(
    document.repository != "Roasbeef/loom" || document.platform != platform,
    Error("release repository or platform differs from selection"),
  )
  use <- bool.guard(
    tag != ""
      && document.tag != tag
      || commit != ""
      && document.commit != commit,
    Error("release tag or commit differs from resolved selection"),
  )
  case selection {
    options.Latest -> Ok(Nil)
    options.Tag(tag) ->
      case document.tag == tag {
        True -> Ok(Nil)
        False -> Error("release tag differs from requested tag")
      }
    options.Commit(commit) ->
      case string.starts_with(document.commit, commit) {
        True -> Ok(Nil)
        False -> Error("release commit differs from requested commit")
      }
  }
}

fn verify_signature(presence, choices: options.Options, path, stage) {
  case presence, choices.signature {
    Absent, options.Optional -> Ok(Nil)
    Absent, options.Required ->
      Error("release manifest is unsigned; a signature is required")
    Present, _ -> {
      use <- bool.guard(
        choices.keyring == "",
        Error(
          "signed manifest needs --keyring with locally trusted release keys",
        ),
      )
      use keyring <- result.try(host.canonical_path(choices.keyring))
      use verifier <- result.try(host.find_executable("gpgv"))
      let home = stage <> "/verification"
      use Nil <- result.try(host.ensure_private_directory(home))
      files.run(verifier, [
        "--homedir",
        home,
        "--keyring",
        keyring,
        "--",
        path <> ".asc",
        path,
      ])
    }
  }
}

/// Acquires one bounded resource from HTTPS or a local distribution directory.
///
/// ## Examples
///
/// ```gleam
/// // source.acquire(source, private_destination, maximum_bytes, fetch)
/// ```
pub fn acquire(
  source: String,
  destination: String,
  limit: Int,
  fetch: Fetch,
) -> Result(Presence, String) {
  case string.starts_with(source, "https://") {
    True -> fetch(source, destination, limit)
    False ->
      case host.path_kind(source) {
        host.NoEntry -> Ok(Absent)
        host.OtherEntry -> Error("release source is not a regular file")
        host.RegularFile -> {
          use bytes <- result.try(host.read_bounded(source, limit))
          use Nil <- result.try(
            simplifile.write_bits(destination, bytes)
            |> result.replace_error("cannot stage release download"),
          )
          Ok(Present)
        }
      }
  }
}
