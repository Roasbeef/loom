//// Publishing a verified ticket: pushing its commit to the remote and opening
//// a pull request for it (protocol-change/106, "Done means verified").
////
//// Only the machine that owns a session pushes, with that machine's own
//// credentials, and a worker has none and no way to ask for any. So this runs
//// in the daemon's process, as the daemon's user, and it is the one place in
//// project mode that does. Two rules follow from that, and the module is
//// written to them.
////
//// - **Nothing a model wrote is a command.** Every program runs through
////   `ffi_os.run_capture`, which starts an executable with an argument list and
////   no shell. The branch is `model.branch_name`, derived from the ticket's id.
////   The commit is a hexadecimal object name Git printed. The title is the one
////   piece of model text, and it travels as a single `-f title=...` argument
////   after `title` has been capped and stripped of everything that could
////   mention a person, close an issue or break a line (`title`). The body is
////   built from ledger facts and quotes no model text at all (`body`).
//// - **Nothing is opened twice.** A crash after the pull request was requested
////   and before the host recorded it leaves the publish job to run again, so
////   the second run looks for an open pull request from the branch before it
////   creates one, and returns the URL of what it finds.
////
//// ## Flow
////
//// `publish` → `push` → `existing` → `create`
////
//// 1. `publish` reads the remote's URL and the repository's owner and name
////    from it, and says `Unavailable` when there is no remote or no gh command.
//// 2. `push` sends the commit to `refs/heads/<branch>` of the remote, without
////    force and without the repository's hooks.
//// 3. `existing` asks the REST API for an open pull request from that branch.
//// 4. `create` opens one when there is none. It reads the repository's default
////    branch first, because the pull request needs a base.
////
//// ## The API
////
//// Only REST is used, through `gh api`. GraphQL is rate limited and shared
//// across everything that runs as the same user, and a project must not spend
//// that budget. Merging is never done here or anywhere in project mode.
////
//// ## What this does not defend against
////
//// The repository's `.git/config` is a file the worker's sandbox may be able to
//// write, because a worktree shares its repository's configuration. The
//// remote's URL, a credential helper or an SSH command set there would run, or
//// be trusted, in this process. `push` turns the repository's hooks off, and
//// reading the URL here is the only use of the configuration beyond Git's own.
//// Pinning the remote's URL when the project is created would close the rest,
//// and is left for the slice that gives workers other machines.

import client/host_git
import client/internal/ffi_os
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The most code points of a ticket's title that a pull request's title keeps.
pub const max_title_chars = 60

/// How long a Git push may take, in milliseconds.
pub const push_within_ms = 120_000

/// How long a `gh api` call or a Git query may take, in milliseconds.
pub const query_within_ms = 60_000

/// What the host's check established about the commit being published.
pub type Verified {
  /// The project's check passed at the commit.
  Passed(
    /// The digest of the check command.
    digest: String,
    /// The ledger entry that records the run.
    entry: String,
  )

  /// A person published the commit past the check.
  Overridden(
    /// The principal who did.
    by: String,
  )
}

/// Everything a pull request's body is built from. Each field is a fact the
/// ledger holds; none is text a worker or the router wrote.
pub type Facts {
  Facts(
    /// The ticket's id.
    ticket: String,
    /// The commit published.
    commit: String,
    /// What established it.
    verified: Verified,
  )
}

/// The programs a publish runs, resolved once on the host.
pub type Tools {
  Tools(
    /// The `git` binary, see `host_git.program`.
    git: String,
    /// `env`, which sets the variables that keep a prompt from waiting for a
    /// person who is not there.
    env: String,
    /// The `gh` binary, or none on a machine without it.
    gh: Option(String),
  )
}

/// Where the commit is pushed from and to.
pub type Repository {
  Repository(
    /// The project's checkout, whose object store holds the commit.
    directory: String,
    /// The remote's name, such as `origin`.
    remote: String,
  )
}

/// Why nothing was published.
pub type Failure {
  /// Trying again will not help: there is no remote, or no `gh`. A person is
  /// told why.
  Unavailable(
    /// The reason, in the host's words.
    why: String,
  )

  /// The step failed in a way that may pass.
  Failed(
    /// The reason, in the host's words.
    why: String,
  )
}

/// The pull request's title: the ticket's id, then the ticket's title between
/// quotation marks, cut to `max_title_chars` code points.
///
/// The title is the router's, written about hostile text, so it is made safe
/// for a place people read and notifications fire from. Control characters,
/// including line breaks, and the characters that make a reference, a mention,
/// a link or markup are dropped, and so are the invisible characters that
/// reorder text. What remains cannot start a line of its own, mention anyone,
/// close an issue or hide in the title, and the ticket's id in front says whose
/// work it is.
///
/// ## Examples
///
/// ```gleam
/// assert project_publish.title("t-c1", "Fix the flaky test")
///   == "[loom t-c1] \"Fix the flaky test\""
/// ```
///
/// ```gleam
/// assert project_publish.title("t-c1", "ping @everyone\nfixes #12")
///   == "[loom t-c1] \"ping everyone fixes 12\""
/// ```
pub fn title(ticket: String, text: String) -> String {
  let kept =
    text
    |> string.to_utf_codepoints
    |> list.filter_map(fn(point) {
      let code = string.utf_codepoint_to_int(point)

      // A control becomes a space, a refused code point goes, and the rest stay.
      case control(code), allowed(code) {
        True, _ -> Ok(" ")
        False, True -> Ok(string.from_utf_codepoints([point]))
        False, False -> Error(Nil)
      }
    })
    |> string.concat
    |> string.split(" ")
    |> list.filter(fn(word) { word != "" })
    |> string.join(" ")
    |> string.to_utf_codepoints
    |> list.take(max_title_chars)
    |> string.from_utf_codepoints
    |> string.trim

  // A title with nothing left says so instead of showing a pair of marks.
  case kept {
    "" -> "[loom " <> ticket <> "]"
    _ -> "[loom " <> ticket <> "] \"" <> kept <> "\""
  }
}

/// Whether a code point may appear in a title. The refused ones are the C0 and
/// C1 controls, the characters that make GitHub link, mention, reference or
/// format (`@ # ` < > [ ] \ " |`), and the invisible ones that reorder or hide
/// text: the zero-width and bidirectional marks, the isolates, the byte order
/// mark and the line and paragraph separators.
fn allowed(code: Int) -> Bool {
  let marked =
    list.contains(
      [0x40, 0x23, 0x60, 0x3c, 0x3e, 0x5b, 0x5d, 0x5c, 0x22, 0x7c],
      code,
    )
  let invisible =
    { code >= 0x200b && code <= 0x200f }
    || { code >= 0x2028 && code <= 0x202e }
    || { code >= 0x2060 && code <= 0x206f }
    || code == 0xfeff

  !marked && !invisible
}

/// The C0 and C1 controls, which a title turns into spaces so that the words
/// either side of a line break stay apart.
fn control(code: Int) -> Bool {
  code < 0x20 || { code >= 0x7f && code <= 0x9f }
}

/// The pull request's body, built from the ledger's facts alone.
///
/// ## Examples
///
/// ```gleam
/// let facts = project_publish.Facts("t-c1", "abc123", project_publish.Overridden("owner"))
/// assert string.contains(project_publish.body(facts), "published past the check by owner")
/// ```
pub fn body(facts: Facts) -> String {
  // A pass names the digest and the entry that record it, and a person's
  // publish names the person.
  let check = case facts.verified {
    Passed(digest:, entry:) ->
      "- Check: passed. Command digest `"
      <> digest
      <> "`, recorded as ledger entry `"
      <> entry
      <> "`."
    Overridden(by:) ->
      "- Check: none passed. The commit was published past the check by "
      <> by
      <> "."
  }

  "Opened by Loom for ticket `"
  <> facts.ticket
  <> "`.\n\n- Commit: `"
  <> facts.commit
  <> "`\n"
  <> check
  <> "\n\nThe worker that wrote this commit had no access to the remote. Merging is left to a person.\n"
}

/// Resolves the programs on this machine: the Git the daemon uses everywhere,
/// `env` and `gh` as found on `PATH`.
///
/// ## Examples
///
/// ```gleam
/// // project_publish.tools()
/// ```
pub fn tools() -> Tools {
  Tools(
    git: host_git.program(),
    env: result.unwrap(ffi_os.find_executable("env"), "/usr/bin/env"),
    gh: option.from_result(ffi_os.find_executable("gh")),
  )
}

/// Pushes `commit` to `branch` of the repository's remote and opens a pull
/// request for it, or finds the one already open, and answers its URL.
///
/// The push is never forced and runs without the repository's hooks, so a
/// remote branch that holds something else refuses it and a hook a worker
/// wrote does not run with this process's credentials. A pull request found by
/// `existing` is returned as it is.
///
/// ## Examples
///
/// ```gleam
/// // project_publish.publish(tools, repository, "project/t-c1", commit, title, body)
/// ```
pub fn publish(
  tools: Tools,
  repository: Repository,
  branch: String,
  commit: String,
  title: String,
  body: String,
) -> Result(String, Failure) {
  use gh <- result.try(option.to_result(
    tools.gh,
    Unavailable("the gh command is not installed on this machine"),
  ))
  use url <- result.try(remote_url(tools, repository))
  use #(owner, name) <- result.try(
    repository_of(url)
    |> result.map_error(fn(_) {
      Unavailable(
        "the remote "
        <> repository.remote
        <> " has no GitHub owner and name in its URL",
      )
    }),
  )
  use Nil <- result.try(push(tools, repository, branch, commit))
  use found <- result.try(existing(tools, gh, owner, name, branch))

  // A pull request from this branch is already open, so there is nothing to
  // create. This is the step that keeps a crash between the request and its
  // record from opening a second one.
  case found {
    Some(opened) -> Ok(opened)
    None -> create(tools, gh, owner, name, branch, title, body)
  }
}

/// The owner and name in a remote's URL, for `https://github.com/o/r.git`,
/// `git@github.com:o/r.git` and `ssh://git@github.com/o/r`, and for any path
/// whose last two parts are two names. Each name is letters, digits, `.`, `_`
/// and `-`, and the URL's own text reaches the API only through them.
///
/// ## Examples
///
/// ```gleam
/// assert project_publish.repository_of("git@github.com:o/r.git") == Ok(#("o", "r"))
/// ```
///
/// ```gleam
/// assert project_publish.repository_of("https://github.com/o/r/") == Ok(#("o", "r"))
/// ```
///
/// ```gleam
/// assert project_publish.repository_of("r") == Error(Nil)
/// ```
pub fn repository_of(url: String) -> Result(#(String, String), Nil) {
  let parts =
    string.trim(url)
    |> without_suffix("/")
    |> without_suffix(".git")
    |> string.replace(":", "/")
    |> string.split("/")
    |> list.filter(fn(part) { part != "" })

  // The last two parts are the owner and the repository's name.
  case list.reverse(parts) {
    [name, owner, ..] ->
      case plain_name(owner) && plain_name(name) {
        True -> Ok(#(owner, name))
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// The text without a trailing suffix, or the text as it was.
fn without_suffix(text: String, suffix: String) -> String {
  // A suffix that is there is cut; text without it is kept.
  case string.ends_with(text, suffix) {
    True -> string.drop_end(text, string.length(suffix))
    False -> text
  }
}

/// A name that is safe to put in an API path: letters, digits and `._-`, and
/// not a dot component.
fn plain_name(name: String) -> Bool {
  name != ""
  && name != "."
  && name != ".."
  && list.all(string.to_graphemes(name), fn(each) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-",
      each,
    )
  })
}

/// The URL of the repository's remote, or why there is none.
fn remote_url(tools: Tools, repository: Repository) -> Result(String, Failure) {
  case
    run(
      tools,
      tools.git,
      ["-C", repository.directory, "remote", "get-url", "--", repository.remote],
      query_within_ms,
    )
  {
    Ok(#(0, output)) -> Ok(string.trim(output))
    Ok(#(_, _)) ->
      Error(Unavailable(
        "the repository has no remote named " <> repository.remote,
      ))
    Error(reason) -> Error(Failed("could not read the remote: " <> reason))
  }
}

/// The push. `--no-verify` skips the repository's pre-push hook and
/// `core.hooksPath` points every other hook at nothing. The refspec names the
/// commit itself, so the branch it creates holds exactly what was verified even
/// if the worker's own branch has moved on since.
fn push(
  tools: Tools,
  repository: Repository,
  branch: String,
  commit: String,
) -> Result(Nil, Failure) {
  case
    run(
      tools,
      tools.git,
      [
        "-C",
        repository.directory,
        "-c",
        "core.hooksPath=/dev/null",
        "push",
        "--no-verify",
        "--",
        repository.remote,
        commit <> ":refs/heads/" <> branch,
      ],
      push_within_ms,
    )
  {
    Ok(#(0, _)) -> Ok(Nil)
    Ok(#(status, _)) ->
      Error(Failed(
        "git push exited with status "
        <> string.inspect(status)
        <> "; the daemon's log has Git's message",
      ))
    Error(reason) -> Error(Failed("git push did not run: " <> reason))
  }
}

/// The URL of an open pull request from the branch, if there is one.
fn existing(
  tools: Tools,
  gh: String,
  owner: String,
  name: String,
  branch: String,
) -> Result(Option(String), Failure) {
  use output <- result.try(
    api(tools, gh, [
      "api",
      "--method",
      "GET",
      "repos/" <> owner <> "/" <> name <> "/pulls",
      "-f",
      "head=" <> owner <> ":" <> branch,
      "-f",
      "state=open",
    ]),
  )

  // The first open pull request is the answer, and an empty list is none.
  case json.parse(output, decode.list(url_decoder())) {
    Ok([first, ..]) -> Ok(Some(first))
    Ok([]) -> Ok(None)
    Error(_) -> Error(Failed("gh api answered something that is not a list"))
  }
}

/// Opens the pull request against the repository's default branch.
fn create(
  tools: Tools,
  gh: String,
  owner: String,
  name: String,
  branch: String,
  title: String,
  body: String,
) -> Result(String, Failure) {
  use described <- result.try(
    api(tools, gh, [
      "api",
      "--method",
      "GET",
      "repos/" <> owner <> "/" <> name,
    ]),
  )
  use base <- result.try(
    json.parse(described, {
      use base <- decode.field("default_branch", decode.string)
      decode.success(base)
    })
    |> result.replace_error(Failed("gh api gave no default branch")),
  )
  use created <- result.try(
    api(tools, gh, [
      "api",
      "--method",
      "POST",
      "repos/" <> owner <> "/" <> name <> "/pulls",
      "-f",
      "title=" <> title,
      "-f",
      "head=" <> branch,
      "-f",
      "base=" <> base,
      "-f",
      "body=" <> body,
    ]),
  )
  json.parse(created, url_decoder())
  |> result.replace_error(Failed("gh api gave no pull request URL"))
}

/// The `html_url` of a pull request.
fn url_decoder() -> decode.Decoder(String) {
  use url <- decode.field("html_url", decode.string)
  decode.success(url)
}

/// One `gh` call, answering what it printed when it exited zero.
fn api(
  tools: Tools,
  gh: String,
  arguments: List(String),
) -> Result(String, Failure) {
  case run(tools, gh, arguments, query_within_ms) {
    Ok(#(0, output)) -> Ok(output)
    Ok(#(status, _)) ->
      Error(Failed(
        "gh api exited with status "
        <> string.inspect(status)
        <> "; the daemon's log has its message",
      ))
    Error(reason) -> Error(Failed("gh did not run: " <> reason))
  }
}

/// Runs a program under `env`, which turns off the prompts that would wait for a
/// terminal nobody is at. The arguments are whole arguments: nothing parses
/// them, so nothing in them is split or expanded.
fn run(
  tools: Tools,
  program: String,
  arguments: List(String),
  within_ms: Int,
) -> Result(#(Int, String), String) {
  ffi_os.run_capture(
    tools.env,
    [
      "GIT_TERMINAL_PROMPT=0",
      "GH_PROMPT_DISABLED=1",
      "GH_NO_UPDATE_NOTIFIER=1",
      program,
      ..arguments
    ],
    within_ms,
  )
}
