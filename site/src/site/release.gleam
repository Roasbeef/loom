//// Where the site points a reader who wants Loom, and what it calls the
//// release they will get.
////
//// Publication is explicit: a version in the source tree is not proof that
//// GitHub has downloadable assets. Until an archive release exists, all
//// install actions lead to source-build instructions. Archive examples keep
//// the existing tag; they are conditional documentation, not a release claim.

import gleam/string

/// The repository. Every source link on the site starts here.
pub const repo = "https://github.com/Roasbeef/loom"

/// The branch that source links name. A link to `main` can move when a file
/// moves, so the site links to files that exist on `main` today and the
/// test suite does not follow the links.
pub const branch = "main"

/// Whether an archive release has actually been published. Change to
/// `Published` only after verifying the tagged assets on GitHub.
pub type Availability {
  /// Build from source; archive examples describe a future publication.
  SourceOnly

  /// The tag below identifies published, downloadable assets.
  Published
}

/// No archive release is published at the time of this site update.
pub const availability = SourceOnly

/// The existing version used in conditional archive examples. When publishing,
/// verify the real tag and update it together with `availability`.
pub const tag = "v0.2.1"

/// The page that lists every release.
pub const releases_url = repo <> "/releases"

/// GitHub's redirect to the newest published, non-draft release. The
/// Download button points here so that it stays correct if a newer release
/// is published before the site is rebuilt.
pub const latest_url = repo <> "/releases/latest"

/// The platforms a release is built for, as `scripts/platform.sh` names
/// them. `docs/distribution.md` ("A release targets one platform") says
/// which of these the release workflow builds.
pub const platforms = ["linux-x86_64", "macos-arm64"]

/// The version number inside archive names: the tag without its `v`.
///
/// ## Examples
///
/// ```gleam
/// assert version_of("v0.2.1") == "0.2.1"
/// ```
pub fn version_of(tag: String) -> String {
  case tag {
    "v" <> rest -> rest
    other -> other
  }
}

/// The version number of the release the site describes.
pub fn version() -> String {
  version_of(tag)
}

/// The label on the Download button.
pub fn label() -> String {
  tag
}

/// The name of the server archive for a platform.
///
/// ## Examples
///
/// ```gleam
/// assert server_archive("linux-x86_64") == "loomd-0.2.1-linux-x86_64.tar.gz"
/// ```
pub fn server_archive(platform: String) -> String {
  "loomd-" <> version() <> "-" <> platform <> ".tar.gz"
}

/// The name of the self-contained client archive for a platform.
pub fn client_archive(platform: String) -> String {
  "loom-" <> version() <> "-" <> platform <> ".tar.gz"
}

/// The name of the slim client archive, which uses the host's Erlang/OTP.
pub fn slim_archive(platform: String) -> String {
  "loom-slim-" <> version() <> "-" <> platform <> ".tar.gz"
}

/// The name of the manifest for a platform.
pub fn manifest(platform: String) -> String {
  "manifest-" <> platform <> ".json"
}

/// A link to a file in the repository, on the branch the site follows.
///
/// ## Examples
///
/// ```gleam
/// assert source("docs/updating.md")
///   == "https://github.com/Roasbeef/loom/blob/main/docs/updating.md"
/// ```
pub fn source(path: String) -> String {
  repo <> "/blob/" <> branch <> "/" <> string.trim(path)
}

/// A link to a directory in the repository, on the branch the site follows.
pub fn tree(path: String) -> String {
  repo <> "/tree/" <> branch <> "/" <> string.trim(path)
}

/// A link to a numbered pull request or issue.
pub fn pull(number: Int) -> String {
  repo <> "/pull/" <> string.inspect(number)
}

/// Fills the placeholders that a documentation page may use: `{{tag}}` for
/// the tag and `{{version}}` for the number in archive names. The pages are
/// Markdown files that the owner edits without touching Gleam, and this is
/// how a release bump reaches them.
///
/// ## Examples
///
/// ```gleam
/// assert fill("loom-{{version}}.tar.gz") == "loom-0.2.1.tar.gz"
/// ```
pub fn fill(text: String) -> String {
  text
  |> string.replace("{{tag}}", tag)
  |> string.replace("{{version}}", version())
}
