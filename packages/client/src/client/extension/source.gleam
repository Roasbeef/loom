//// Where an extension comes from, and the one URL an install is
//// allowed to fetch from it.
////
//// ## Why this boundary exists
////
//// `docs/design-notes/extension-architecture.md`, "Hardening the
//// install", rules that an install **needs a tree fetched, not a git
//// session**. `git clone` hands a hostile remote a large, remotely
//// driven attack surface — it chooses the pack, the refs, the
//// attributes and the submodules — and nothing about installing an
//// extension needs any of it. So there is no git client anywhere in
//// the install path, and this module is what stands in its place: it
//// turns whatever the operator typed into one of three sources, and
//// turns a source plus an optional revision into exactly one `https://`
//// URL for the fetch policy to allow.
////
//// The refusals are the substance. `git://` and `ssh://` would need a
//// git client; `file://` would smuggle a local read past the local-path
//// source's own confinement; the scp-style `git@host:path` form is a
//// git session wearing a shorthand; and `http://` is an unauthenticated
//// transport for a tree the operator is about to compile. Each is
//// refused by name, with a message that says what is accepted, because
//// an operator who typed a clone URL out of habit needs to be told the
//// form rather than merely told no.
////
//// ## The grammar, exactly
////
//// - `https://github.com/<owner>/<repo>`, with an optional `.git`
////   suffix and an optional trailing slash, is a `GitHub` source.
////   `<owner>` and `<repo>` are non-empty and drawn from
////   `[A-Za-z0-9._-]`, which is GitHub's own alphabet for both.
//// - Any other `https://` URL whose path ends in `.tar.gz` or `.tgz`
////   is an `ArchiveUrl`, fetched as it stands.
//// - Anything with no scheme and no scp-style `user@host:` prefix is a
////   `LocalPath`, copied rather than fetched.
////
//// A revision belongs only to a `GitHub` source, because that is the
//// only source whose URL is derived rather than given: `--rev` with an
//// archive URL is an operator asking for something the URL cannot
//// express, and answering it by ignoring the revision would pin an
//// install to a tree nobody chose. Revisions are drawn from
//// `[A-Za-z0-9._/-]` and may not contain `..`, so a revision cannot
//// climb out of the archive path it is pasted into.

import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Where an extension's source tree is fetched or copied from.
pub type Source {
  /// A directory on the operator's own machine, copied into staging by
  /// `client/extension/archive.from_directory` under the same
  /// confinement an archive gets.
  LocalPath(path: String)

  /// An `https://` URL naming a gzipped tar, fetched as it stands.
  ArchiveUrl(url: String)

  /// A GitHub repository, whose archive URL is derived from the owner,
  /// the repository and the revision.
  GitHub(owner: String, repo: String)
}

/// Reads what the operator typed.
///
/// The error is the message to show them: it names the form that was
/// refused and the forms that are accepted, so an operator who pasted a
/// clone URL learns what to paste instead.
///
/// ## Examples
///
/// ```gleam
/// assert source.parse("https://github.com/roasbeef/loom-web-search")
///   == Ok(source.GitHub(owner: "roasbeef", repo: "loom-web-search"))
/// ```
///
/// ```gleam
/// assert source.parse("./extensions/hello")
///   == Ok(source.LocalPath(path: "./extensions/hello"))
/// ```
///
pub fn parse(text: String) -> Result(Source, String) {
  let trimmed = string.trim(text)

  use <- bool.guard(when: trimmed == "", return: Error(empty_source))

  use <- bool.lazy_guard(when: is_refused_scheme(trimmed), return: fn() {
    Error(refused(trimmed))
  })

  case string.contains(trimmed, "://") {
    False -> Ok(LocalPath(path: trimmed))

    True -> parse_https(trimmed)
  }
}

/// The single URL an install may fetch for this source.
///
/// A `GitHub` source resolves to codeload's archive endpoint for the
/// revision, defaulting to `HEAD` — the design note's "without it the
/// default branch head is resolved once". The response's pax global
/// header then carries the commit that head actually was, which is what
/// turns an unpinned install into a pinned record.
///
/// A `LocalPath` has no URL at all, and an `ArchiveUrl` has no room for
/// a revision; both answer with the message to show the operator.
///
/// ## Examples
///
/// ```gleam
/// assert source.archive_url(source.GitHub("a", "b"), None)
///   == Ok("https://codeload.github.com/a/b/tar.gz/HEAD")
/// ```
///
/// ```gleam
/// assert source.archive_url(source.GitHub("a", "b"), Some("v1.2.0"))
///   == Ok("https://codeload.github.com/a/b/tar.gz/v1.2.0")
/// ```
///
pub fn archive_url(
  source: Source,
  rev: Option(String),
) -> Result(String, String) {
  case source {
    LocalPath(path:) ->
      Error(
        "the local path "
        <> path
        <> " is copied rather than fetched, so it has no archive url",
      )

    ArchiveUrl(url:) ->
      case rev {
        None -> Ok(url)

        Some(_named) ->
          Error(
            "a revision applies only to a github source; the archive url "
            <> url
            <> " already names exactly one tree",
          )
      }

    GitHub(owner:, repo:) -> {
      let named = option.unwrap(rev, default_rev)

      use <- bool.lazy_guard(when: !is_legal_rev(named), return: fn() {
        Error(
          "the revision "
          <> named
          <> " is refused; a revision is a non-empty run of letters, digits,"
          <> " '.', '_', '-' or '/' with no '..' and no leading '/' or '-'",
        )
      })

      Ok(
        "https://codeload.github.com/"
        <> owner
        <> "/"
        <> repo
        <> "/tar.gz/"
        <> named,
      )
    }
  }
}

/// The lowercase host of an `https://` URL, which is what the fetch
/// policy allows and what a redirect is checked against.
///
/// Userinfo is refused rather than stripped: `https://github.com@evil`
/// reads as GitHub to a hurried operator and resolves to `evil`, and
/// nothing an install fetches needs credentials in a URL. A port is not
/// part of the host, so it is dropped; the policy allows a host, and a
/// redirect to the same host on another port is the same host.
///
/// ## Examples
///
/// ```gleam
/// assert source.host("https://CODELOAD.github.com/a/b") 
///   == Ok("codeload.github.com")
/// ```
///
pub fn host(url: String) -> Result(String, String) {
  use rest <- or_bad_url(strip_prefix(url, https_scheme), url)

  let authority = case string.split_once(rest, "/") {
    Ok(#(before, _path)) -> before

    Error(Nil) -> rest
  }

  use <- bool.lazy_guard(when: string.contains(authority, "@"), return: fn() {
    Error(
      "the url " <> url <> " carries userinfo before its host, which is refused",
    )
  })

  let name = case string.split_once(authority, ":") {
    Ok(#(before, _port)) -> before

    Error(Nil) -> authority
  }

  let lowered = string.lowercase(name)

  use <- bool.lazy_guard(when: !is_legal_host(lowered), return: fn() {
    Error("the url " <> url <> " does not name a host")
  })

  Ok(lowered)
}

/// A one-line, operator-facing account of a source.
///
/// ## Examples
///
/// ```gleam
/// assert source.describe(source.GitHub("a", "b")) == "the github repository a/b"
/// ```
///
pub fn describe(source: Source) -> String {
  case source {
    LocalPath(path:) -> "the local directory " <> path

    ArchiveUrl(url:) -> "the archive at " <> url

    GitHub(owner:, repo:) -> "the github repository " <> owner <> "/" <> repo
  }
}

// --- parsing ---------------------------------------------------------------

const https_scheme = "https://"

const github_host = "github.com"

const default_rev = "HEAD"

const empty_source = "no source was given"

const refused_schemes = ["git://", "ssh://", "file://", "http://", "git+ssh://"]

/// The accepted forms, appended to every refusal so the operator never
/// has to go looking for them.
const accepted_forms = "an install takes a local directory, an https:// url ending in .tar.gz or .tgz, or an https://github.com/<owner>/<repo> url"

fn refused(text: String) -> String {
  "the source " <> text <> " is refused: " <> accepted_forms
}

/// Whether the text opens with a transport an install will not speak.
///
/// The scp-style `user@host:path` is included because it is a git
/// session written without a scheme, and it is recognised by an `@`
/// followed by a `:` before any `/` — the shape that distinguishes it
/// from a relative path that merely contains an `@`.
fn is_refused_scheme(text: String) -> Bool {
  let lowered = string.lowercase(text)
  let schemed = list.any(refused_schemes, string.starts_with(lowered, _))

  schemed || is_scp_form(lowered)
}

fn is_scp_form(text: String) -> Bool {
  let before_slash = case string.split_once(text, "/") {
    Ok(#(head, _rest)) -> head

    Error(Nil) -> text
  }

  case string.split_once(before_slash, "@") {
    Error(Nil) -> False

    Ok(#(user, rest)) -> user != "" && string.contains(rest, ":")
  }
}

fn parse_https(text: String) -> Result(Source, String) {
  use rest <- or_refused(strip_prefix(text, https_scheme), text)
  use name <- result.try(host(text))

  case name == github_host {
    True -> parse_github(rest, text)

    False -> parse_archive(text)
  }
}

fn parse_github(rest: String, text: String) -> Result(Source, String) {
  let segments =
    rest
    |> drop_query
    |> trim_trailing_slashes
    |> string.split("/")
    |> list.drop(1)

  case segments {
    [owner, repo] -> github_source(owner, repo, text)

    _wrong_shape -> Error(refused(text))
  }
}

fn github_source(
  owner: String,
  repo: String,
  text: String,
) -> Result(Source, String) {
  let name = drop_suffix(repo, ".git")

  use <- bool.lazy_guard(
    when: !is_legal_name(owner) || !is_legal_name(name),
    return: fn() { Error(refused(text)) },
  )

  Ok(GitHub(owner:, repo: name))
}

fn parse_archive(text: String) -> Result(Source, String) {
  let path = drop_query(text)
  let tarball =
    string.ends_with(path, ".tar.gz") || string.ends_with(path, ".tgz")

  use <- bool.lazy_guard(when: !tarball, return: fn() { Error(refused(text)) })

  Ok(ArchiveUrl(url: text))
}

// --- the alphabets ---------------------------------------------------------

/// GitHub's own alphabet for an owner and a repository name.
///
/// `.` and `..` are refused on top of it. They are legal graphemes here
/// and neither is a repository, but both are path components in the
/// codeload URL the two are pasted into, so admitting them would let
/// `GitHub("..", "..")` render a URL that climbs out of the archive
/// path — the same climb `archive_url` already refuses a revision for.
fn is_legal_name(name: String) -> Bool {
  let shaped = name != "" && name != "." && name != ".."

  shaped && string.to_graphemes(name) |> list.all(is_name_grapheme)
}

fn is_name_grapheme(grapheme: String) -> Bool {
  is_alphanumeric(grapheme) || list.contains([".", "_", "-"], grapheme)
}

/// A revision: a commit, a tag or a branch, so `/` is in the alphabet
/// for `release/1.2`. `..` is refused because the revision is pasted
/// into a URL path, and a leading `/` or `-` because neither can begin
/// any of the three.
fn is_legal_rev(rev: String) -> Bool {
  let shaped =
    rev != ""
    && !string.contains(rev, "..")
    && !string.starts_with(rev, "/")
    && !string.starts_with(rev, "-")

  shaped && string.to_graphemes(rev) |> list.all(is_rev_grapheme)
}

fn is_rev_grapheme(grapheme: String) -> Bool {
  is_name_grapheme(grapheme) || grapheme == "/"
}

fn is_legal_host(name: String) -> Bool {
  let shaped =
    name != "" && !string.starts_with(name, ".") && !string.ends_with(name, ".")

  shaped && string.to_graphemes(name) |> list.all(is_host_grapheme)
}

fn is_host_grapheme(grapheme: String) -> Bool {
  is_lower_alphanumeric(grapheme) || grapheme == "." || grapheme == "-"
}

fn is_alphanumeric(grapheme: String) -> Bool {
  is_lower_alphanumeric(string.lowercase(grapheme))
}

fn is_lower_alphanumeric(grapheme: String) -> Bool {
  let digits = string.contains("0123456789", grapheme)

  digits || string.contains("abcdefghijklmnopqrstuvwxyz", grapheme)
}

// --- small shared helpers --------------------------------------------------

fn or_bad_url(
  stripped: Result(String, Nil),
  url: String,
  then: fn(String) -> Result(a, String),
) -> Result(a, String) {
  case stripped {
    Error(Nil) -> Error("the url " <> url <> " is not an https:// url")

    Ok(rest) -> then(rest)
  }
}

fn or_refused(
  stripped: Result(String, Nil),
  text: String,
  then: fn(String) -> Result(a, String),
) -> Result(a, String) {
  case stripped {
    Error(Nil) -> Error(refused(text))

    Ok(rest) -> then(rest)
  }
}

fn strip_prefix(text: String, prefix: String) -> Result(String, Nil) {
  case string.starts_with(string.lowercase(text), prefix) {
    True -> Ok(string.drop_start(text, string.length(prefix)))

    False -> Error(Nil)
  }
}

fn drop_suffix(text: String, suffix: String) -> String {
  case string.ends_with(text, suffix) {
    True -> string.drop_end(text, string.length(suffix))

    False -> text
  }
}

/// A query string or fragment is not part of the path a `.tar.gz`
/// suffix is judged on, and neither belongs in a repository URL.
fn drop_query(text: String) -> String {
  case string.split_once(text, "?") {
    Ok(#(before, _query)) -> before

    Error(Nil) ->
      case string.split_once(text, "#") {
        Ok(#(before, _fragment)) -> before

        Error(Nil) -> text
      }
  }
}

fn trim_trailing_slashes(text: String) -> String {
  case string.ends_with(text, "/") {
    True -> trim_trailing_slashes(string.drop_end(text, 1))

    False -> text
  }
}
