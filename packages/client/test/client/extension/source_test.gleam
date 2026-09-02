//// Tests for the install-source grammar.
////
//// The refusals matter more than the acceptances here: every transport
//// that would need a git client, or that would carry a tree over an
//// unauthenticated channel, has a test that names it.

import client/extension/source
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// --- parsing ---------------------------------------------------------------

pub fn github_url_test() {
  assert source.parse("https://github.com/roasbeef/loom-web-search")
    == Ok(source.GitHub(owner: "roasbeef", repo: "loom-web-search"))
}

pub fn github_url_with_git_suffix_test() {
  assert source.parse("https://github.com/roasbeef/loom.git")
    == Ok(source.GitHub(owner: "roasbeef", repo: "loom"))
}

pub fn github_url_with_trailing_slash_test() {
  assert source.parse("https://github.com/roasbeef/loom/")
    == Ok(source.GitHub(owner: "roasbeef", repo: "loom"))
}

pub fn github_host_is_case_insensitive_test() {
  assert source.parse("https://GitHub.COM/roasbeef/loom")
    == Ok(source.GitHub(owner: "roasbeef", repo: "loom"))
}

pub fn github_deep_path_is_not_a_repository_test() {
  let assert Error(message) =
    source.parse("https://github.com/roasbeef/loom/tree/main")
    as "a tree url names a directory, not a repository"

  assert string.contains(message, "https://github.com/<owner>/<repo>")
}

pub fn github_name_alphabet_test() {
  let assert Error(_message) = source.parse("https://github.com/roas beef/loom")
    as "a space is outside github's own alphabet"
}

/// `.` and `..` are legal in github's own alphabet and neither is a
/// repository, but both are path components in the codeload url they
/// would be pasted into.
pub fn github_dot_names_test() {
  let refused = [
    "https://github.com/../..",
    "https://github.com/roasbeef/..",
    "https://github.com/./loom",
  ]

  list.each(refused, fn(text) {
    let assert Error(_message) = source.parse(text)
      as "a dot name cannot become a codeload path component"
  })
}

pub fn archive_url_test() {
  assert source.parse("https://example.com/ext/hello-1.0.0.tar.gz")
    == Ok(source.ArchiveUrl(url: "https://example.com/ext/hello-1.0.0.tar.gz"))
}

pub fn tgz_url_test() {
  assert source.parse("https://example.com/hello.tgz")
    == Ok(source.ArchiveUrl(url: "https://example.com/hello.tgz"))
}

pub fn https_url_that_is_not_a_tarball_test() {
  let assert Error(message) = source.parse("https://example.com/hello.zip")
    as "an install fetches a gzipped tar and nothing else"

  assert string.contains(message, ".tar.gz")
}

pub fn local_path_test() {
  assert source.parse("./extensions/hello")
    == Ok(source.LocalPath(path: "./extensions/hello"))
}

pub fn absolute_local_path_test() {
  assert source.parse("/srv/ext/hello")
    == Ok(source.LocalPath(path: "/srv/ext/hello"))
}

pub fn surrounding_whitespace_is_trimmed_test() {
  assert source.parse("  /srv/ext/hello \n")
    == Ok(source.LocalPath(path: "/srv/ext/hello"))
}

pub fn empty_source_test() {
  let assert Error(_message) = source.parse("   ")
    as "an empty source names nothing"
}

/// Each of these would need a git client, or would carry the tree over
/// a channel nothing authenticates.
pub fn refused_transports_test() {
  let refused = [
    "git://github.com/roasbeef/loom.git",
    "ssh://git@github.com/roasbeef/loom.git",
    "git+ssh://git@github.com/roasbeef/loom.git",
    "git@github.com:roasbeef/loom.git",
    "file:///srv/ext/hello",
    "http://example.com/hello.tar.gz",
  ]

  list.each(refused, fn(text) {
    let assert Error(message) = source.parse(text) as "the transport is refused"

    assert string.contains(message, "an install takes a local directory")
  })
}

pub fn scp_form_does_not_swallow_a_path_test() {
  assert source.parse("./mail@archive/hello")
    == Ok(source.LocalPath(path: "./mail@archive/hello"))
}

// --- archive urls ----------------------------------------------------------

pub fn github_archive_url_defaults_to_head_test() {
  assert source.archive_url(source.GitHub(owner: "a", repo: "b"), None)
    == Ok("https://codeload.github.com/a/b/tar.gz/HEAD")
}

pub fn github_archive_url_with_rev_test() {
  assert source.archive_url(
      source.GitHub(owner: "a", repo: "b"),
      Some("v1.2.0"),
    )
    == Ok("https://codeload.github.com/a/b/tar.gz/v1.2.0")
}

pub fn github_archive_url_with_branch_rev_test() {
  assert source.archive_url(
      source.GitHub(owner: "a", repo: "b"),
      Some("release/1.2"),
    )
    == Ok("https://codeload.github.com/a/b/tar.gz/release/1.2")
}

pub fn rev_may_not_climb_test() {
  let assert Error(message) =
    source.archive_url(source.GitHub(owner: "a", repo: "b"), Some("../../etc"))
    as "a revision is pasted into a url path and may not climb out of it"

  assert string.contains(message, "no '..'")
}

pub fn rev_alphabet_test() {
  let refused = ["", "/main", "-main", "main?x=1", "main#frag", "ma in"]

  list.each(refused, fn(rev) {
    let assert Error(_message) =
      source.archive_url(source.GitHub(owner: "a", repo: "b"), Some(rev))
      as "the revision is outside the alphabet"
  })
}

pub fn archive_url_passes_through_test() {
  assert source.archive_url(
      source.ArchiveUrl(url: "https://example.com/hello.tar.gz"),
      None,
    )
    == Ok("https://example.com/hello.tar.gz")
}

pub fn rev_with_an_archive_url_is_an_error_test() {
  let assert Error(message) =
    source.archive_url(
      source.ArchiveUrl(url: "https://example.com/hello.tar.gz"),
      Some("v1"),
    )
    as "an archive url already names exactly one tree"

  assert string.contains(message, "github")
}

pub fn local_path_has_no_archive_url_test() {
  let assert Error(message) =
    source.archive_url(source.LocalPath(path: "./hello"), None)
    as "a local path is copied rather than fetched"

  assert string.contains(message, "copied")
}

// --- hosts -----------------------------------------------------------------

pub fn host_is_lowercased_test() {
  assert source.host("https://CODELOAD.GitHub.com/a/b/tar.gz/HEAD")
    == Ok("codeload.github.com")
}

pub fn host_without_a_path_test() {
  assert source.host("https://example.com") == Ok("example.com")
}

pub fn host_drops_the_port_test() {
  assert source.host("https://example.com:8443/x.tar.gz") == Ok("example.com")
}

pub fn host_refuses_userinfo_test() {
  let assert Error(message) = source.host("https://github.com@evil.example/x")
    as "userinfo reads as the host to a hurried operator"

  assert string.contains(message, "userinfo")
}

pub fn host_refuses_a_non_https_url_test() {
  let assert Error(_message) = source.host("http://example.com/x.tar.gz")
    as "the fetch policy only ever sees https urls"
}

pub fn host_refuses_an_empty_authority_test() {
  let assert Error(_message) = source.host("https:///x.tar.gz")
    as "an empty authority names no host"
}

// --- descriptions ----------------------------------------------------------

pub fn describe_test() {
  assert source.describe(source.GitHub(owner: "a", repo: "b"))
    == "the github repository a/b"
  assert source.describe(source.LocalPath(path: "./hello"))
    == "the local directory ./hello"
  assert source.describe(source.ArchiveUrl(url: "https://x/y.tar.gz"))
    == "the archive at https://x/y.tar.gz"
}
