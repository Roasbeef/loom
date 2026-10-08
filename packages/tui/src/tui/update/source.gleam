//// Release resolution binds GitHub metadata to the manifest's repository,
//// tag, native platform and full source commit. A commit without a published
//// build is an error; resolution never compiles downloaded source implicitly.

import core/json
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{None, Some}
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
  use <- bool.guard(
    choices.selection == options.Nightly
      && { choices.from != "" || choices.mirror != "" },
    Error(
      "--nightly selects GitHub main; it cannot use --from or --manifest-url",
    ),
  )
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
    options.Nightly -> nightly(stage, fetch)
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

// Release publication can lag main. Capture its head once and intersect its
// ordered history with published immutable builds, so a branch advance cannot
// change the history between pages. Neither draft releases nor side branches
// can authorize an update.
fn nightly(stage, fetch) {
  use document <- result.try(api("commits/main", stage, fetch))
  use head <- result.try(json_string(document, "sha"))
  use <- bool.guard(
    !manifest.hexadecimal(head, 40),
    Error("GitHub main lacks a full source commit"),
  )
  use published <- result.try(published_commits(1, [], stage, fetch))
  use <- bool.guard(
    list.is_empty(published),
    Error("no published nightly commit builds found"),
  )
  nightly_history(head, published, 1, stage, fetch)
}

// Keep the recent release window bounded even after years of daily builds.
// Selection still requires a match in the captured main history; an empty
// intersection is an error and never falls back to the stable channel.
fn published_commits(page, accumulated, stage, fetch) {
  use <- bool.guard(page > 10, Ok(accumulated))
  use document <- result.try(api(
    "releases?per_page=30&page=" <> int.to_string(page),
    stage,
    fetch,
  ))
  use releases <- result.try(json_array(document))
  let commits =
    list.append(
      accumulated,
      list.filter_map(releases, fn(release) {
        case published_commit(release) {
          Some(commit) -> Ok(commit)
          None -> Error(Nil)
        }
      }),
    )
  case list.length(releases) < 30 {
    True -> Ok(commits)
    False -> published_commits(page + 1, commits, stage, fetch)
  }
}

fn published_commit(document) {
  case document {
    json.Object(fields) -> {
      case
        list.key_find(fields, "draft"),
        list.key_find(fields, "published_at")
      {
        Ok(json.Bool(False)), Ok(json.String(published)) if published != "" -> {
          json_string(document, "tag_name")
          |> result.map(fn(tag) {
            let commit = string.drop_start(tag, 7)
            case
              string.starts_with(tag, "commit-")
              && manifest.hexadecimal(commit, 40)
            {
              True -> Some(commit)
              False -> None
            }
          })
          |> result.unwrap(None)
        }
        _, _ -> None
      }
    }
    _ -> None
  }
}

fn nightly_history(head, published, page, stage, fetch) {
  use <- bool.guard(
    page > 10,
    Error("nightly search exceeded 300 main commits"),
  )
  use document <- result.try(api(
    "commits?sha=" <> head <> "&per_page=30&page=" <> int.to_string(page),
    stage,
    fetch,
  ))
  use history <- result.try(json_array(document))
  use commits <- result.try(
    list.try_map(history, fn(commit) {
      use sha <- result.try(json_string(commit, "sha"))
      use <- bool.guard(
        !manifest.hexadecimal(sha, 40),
        Error("invalid main history SHA"),
      )
      Ok(sha)
    }),
  )
  case list.find(commits, fn(commit) { list.contains(published, commit) }) {
    Ok(commit) -> Ok(#("commit-" <> commit, commit))
    Error(_) -> {
      case list.length(history) < 30 {
        True -> Error("no published nightly build in recent main history")
        False -> nightly_history(head, published, page + 1, stage, fetch)
      }
    }
  }
}

fn json_array(document) {
  case document {
    json.Array(items) -> Ok(items)
    _ -> Error("GitHub metadata is not an array")
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
    options.Latest | options.Nightly -> Ok(Nil)
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
