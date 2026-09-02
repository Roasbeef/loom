//// Where an extension comes from, and the one URL a fetch is allowed to
//// ask for.
////
//// **Placeholder.** This module is the seam the install pipeline is
//// written against; the branch that owns it (`ext/archive`) replaces the
//// whole file. The signatures here are the agreed ones, so a merge is a
//// wholesale replacement rather than a reconciliation.
////
//// There is no git client, deliberately. `git clone` is a large, remotely
//// driven attack surface — a hostile remote chooses the pack, the refs,
//// the attributes and the submodules — and nothing about installing an
//// extension needs a git session: it needs a tree. So a source is a local
//// path, an `https://` URL naming a `.tar.gz`, or a GitHub repository URL
//// that resolves to one. `git://`, `ssh://`, scp-style and `file://`
//// sources are refused by the decoder rather than handled.

import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

/// The GitHub host whose archive URL shape this module knows.
pub const github_host = "github.com"

/// Where an extension's tree comes from.
pub type Source {
  /// A directory on this host, copied rather than fetched.
  LocalPath(path: String)

  /// An `https://` URL naming a gzipped tarball.
  ArchiveUrl(url: String)

  /// A GitHub repository, resolved to that host's archive URL.
  GitHub(owner: String, repo: String)
}

/// Reads a source from what the operator typed.
///
/// Anything that is not `https://` and not a GitHub URL is a local path,
/// which is why the refusals are stated as *schemes*: a bare word with a
/// slash in it is a directory, and a `git://` URL is not.
///
/// ## Examples
///
/// ```gleam
/// assert source.parse("./weather") == Ok(source.LocalPath("./weather"))
/// ```
///
/// ```gleam
/// assert source.parse("https://github.com/o/r")
///   == Ok(source.GitHub(owner: "o", repo: "r"))
/// ```
///
pub fn parse(text: String) -> Result(Source, String) {
  case scheme_of(text) {
    Ok("https") -> parse_https(text)
    Ok(other) ->
      Error(
        "the "
        <> other
        <> ":// scheme is refused; an extension source is a local path, an "
        <> "https:// .tar.gz, or an https://github.com/<owner>/<repo> URL",
      )
    Error(Nil) ->
      case text {
        "" -> Error("an extension source cannot be empty")
        _ -> Ok(LocalPath(path: text))
      }
  }
}

fn parse_https(url: String) -> Result(Source, String) {
  use host <- result.try(host(url))
  case host == github_host {
    True -> parse_github(url)
    False ->
      case string.ends_with(url, ".tar.gz") || string.ends_with(url, ".tgz") {
        True -> Ok(ArchiveUrl(url:))
        False ->
          Error(
            "an https:// source must name a .tar.gz; " <> url <> " does not",
          )
      }
  }
}

fn parse_github(url: String) -> Result(Source, String) {
  case segments(url) {
    [owner, repo, ..] ->
      case owner == "" || repo == "" {
        True -> Error("a GitHub source needs an owner and a repository")
        False -> Ok(GitHub(owner:, repo: string.replace(repo, ".git", "")))
      }
    _ ->
      Error(
        "a GitHub source is https://github.com/<owner>/<repo>; "
        <> url
        <> " is not",
      )
  }
}

/// The single URL a fetch is permitted to ask for, or the reason there is
/// none.
///
/// `rev` names a commit, tag or branch; without one the host's default
/// branch is asked for by name (`HEAD`), which GitHub resolves. A local
/// path has no URL at all, and saying so as an error is the point: the
/// caller must have taken the copy path instead.
///
/// ## Examples
///
/// ```gleam
/// assert source.archive_url(source.GitHub("o", "r"), None)
///   == Ok("https://github.com/o/r/archive/HEAD.tar.gz")
/// ```
///
pub fn archive_url(
  source: Source,
  rev rev: Option(String),
) -> Result(String, String) {
  case source {
    ArchiveUrl(url:) -> Ok(url)
    GitHub(owner:, repo:) ->
      Ok(
        "https://"
        <> github_host
        <> "/"
        <> owner
        <> "/"
        <> repo
        <> "/archive/"
        <> option.unwrap(rev, "HEAD")
        <> ".tar.gz",
      )
    LocalPath(path:) ->
      Error("a local path is copied rather than fetched: " <> path)
  }
}

/// The host of an `https://` URL, for the one-host fetch policy.
///
/// ## Examples
///
/// ```gleam
/// assert source.host("https://example.com/a.tar.gz") == Ok("example.com")
/// ```
///
pub fn host(url: String) -> Result(String, String) {
  case string.split_once(url, "://") {
    Error(Nil) -> Error(url <> " is not a URL")
    Ok(#(_scheme, rest)) ->
      case string.split_once(rest, "/") {
        Ok(#(authority, _path)) -> named_host(authority, url)
        Error(Nil) -> named_host(rest, url)
      }
  }
}

fn named_host(authority: String, url: String) -> Result(String, String) {
  // Credentials in the authority are refused rather than stripped: a URL
  // carrying them is one whose host a reader and a fetcher could read
  // differently, which is the whole class of confusion a one-host policy
  // exists to close.
  case string.contains(authority, "@") || authority == "" {
    True -> Error(url <> " does not name a host this fetch may ask for")
    False -> Ok(authority)
  }
}

/// Renders a source for a record or a log line.
///
/// ## Examples
///
/// ```gleam
/// assert source.describe(source.LocalPath("./w")) == "./w"
/// ```
///
pub fn describe(source: Source) -> String {
  case source {
    LocalPath(path:) -> path
    ArchiveUrl(url:) -> url
    GitHub(owner:, repo:) ->
      "https://" <> github_host <> "/" <> owner <> "/" <> repo
  }
}

// The scheme of a URL, or `Error(Nil)` when the text names none. A colon
// only counts when it introduces `//`, so a Windows-shaped path or a
// scp-style `host:path` is not mistaken for a scheme — the scp shape is
// then refused as a directory that does not exist rather than fetched.
fn scheme_of(text: String) -> Result(String, Nil) {
  case string.split_once(text, "://") {
    Error(Nil) -> Error(Nil)
    Ok(#(scheme, _rest)) ->
      case scheme == "" || string.contains(scheme, "/") {
        True -> Error(Nil)
        False -> Ok(scheme)
      }
  }
}

fn segments(url: String) -> List(String) {
  case string.split_once(url, "://") {
    Error(Nil) -> []
    Ok(#(_scheme, rest)) ->
      case string.split(rest, "/") {
        [_authority, ..parts] -> list.filter(parts, fn(part) { part != "" })
        [] -> []
      }
  }
}
