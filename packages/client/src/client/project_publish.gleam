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
//// 1. `publish` reads the repository's owner and name from the pinned URL, and
////    says `Unavailable` when the URL has none or there is no gh command.
//// 2. `push` sends the commit to `refs/heads/<branch>` of the pinned URL,
////    without force and without the repository's hooks.
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
//// ## What the push trusts
////
//// The push runs in the project's host repository (`client/project_repo`),
//// which only host code writes, so its configuration is the host's. It names
//// the remote by the URL that was pinned from the owner's checkout when the
//// project was created, literally on the command line and never by a remote
//// name, so a `remote.origin.url`, `pushurl` or `url.*.insteadOf` in any clone
//// is not consulted. The owner's own global Git configuration still applies to
//// this one command, which is how their SSH and credential setup reaches it;
//// the system configuration, replacement objects and every variable that
//// redirects Git to another repository are switched off or cleared.

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
    /// The project's host repository, whose object store holds the commit.
    directory: String,
    /// The URL pinned for the project's pushes. It is passed to Git as it is,
    /// and no remote name stands for it.
    url: String,
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

/// Pushes `commit` to `branch` of the pinned URL and opens a pull request for
/// it, or finds the one already open, and answers its URL.
///
/// The push is never forced and runs without the repository's hooks, so a
/// remote branch that holds something else refuses it. A pull request found by
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
  use #(owner, name) <- result.try(
    repository_of(repository.url)
    |> result.map_error(fn(_) {
      Unavailable("the pinned remote URL has no GitHub owner and name")
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

/// The owner and name a GitHub remote names, for `https://github.com/o/r`,
/// `git@github.com:o/r` and `ssh://git@github.com/o/r`, each with an optional
/// `.git` and an optional trailing `/`, and with the host in any letter case.
///
/// Anything else is not a GitHub remote and answers `Error(Nil)`: another
/// host, a path on this machine, an address with a user, a port or extra path
/// parts, and a name outside letters, digits, `.`, `_` and `-`. A local path
/// whose last two parts look like an owner and a name would otherwise be read
/// as a GitHub repository, and the owner's credentials would be used against a
/// repository the project's origin never named. The URL's own text reaches the
/// API only through the two names. GitHub Enterprise hosts are not recognised.
///
/// ## Examples
///
/// ```gleam
/// assert project_publish.repository_of("git@github.com:o/r.git") == Ok(#("o", "r"))
/// ```
///
/// ```gleam
/// assert project_publish.repository_of("HTTPS://GitHub.com/o/r/") == Ok(#("o", "r"))
/// ```
///
/// ```gleam
/// assert project_publish.repository_of("/tmp/x/remote.git") == Error(Nil)
/// ```
pub fn repository_of(url: String) -> Result(#(String, String), Nil) {
  let trimmed = string.trim(url)

  // The host sits in one of three fixed prefixes, and what follows must be
  // exactly an owner and a name.
  use rest <- result.try(
    list.find_map(github_prefixes, fn(prefix) { after_prefix(trimmed, prefix) }),
  )
  let parts =
    rest
    |> without_suffix("/")
    |> without_suffix(".git")
    |> string.split("/")

  // Two plain names and nothing else, so an extra part does not slip through.
  case parts {
    [owner, name] ->
      case plain_name(owner) && plain_name(name) {
        True -> Ok(#(owner, name))
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// The three spellings of a GitHub remote's start, before the owner.
const github_prefixes = [
  "https://github.com/",
  "git@github.com:",
  "ssh://git@github.com/",
]

/// What follows `prefix` in `text`, comparing the prefix without regard to
/// letter case, or an error when the text does not begin with it.
fn after_prefix(text: String, prefix: String) -> Result(String, Nil) {
  let size = string.length(prefix)

  // A host name is case-insensitive, so only the lowercased start is compared.
  case string.lowercase(string.slice(text, 0, size)) == prefix {
    True -> Ok(string.drop_start(text, size))
    False -> Error(Nil)
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

/// The push. `--no-verify` skips the repository's pre-push hook and
/// `core.hooksPath` points every other hook at nothing. The destination is the
/// pinned URL itself. The refspec names the commit itself, so the branch it
/// creates holds exactly what was verified even if the worker's own branch has
/// moved on since.
fn push(
  tools: Tools,
  repository: Repository,
  branch: String,
  commit: String,
) -> Result(Nil, Failure) {
  case
    run_git(
      tools,
      [
        "-C",
        repository.directory,
        "-c",
        "core.hooksPath=/dev/null",
        "push",
        "--no-verify",
        "--",
        repository.url,
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

/// The variables that point Git at a repository, a work tree or an object store
/// other than the one a command names, or add configuration from outside any
/// file. A daemon started from a shell inside a repository may carry them.
const redirecting_variables = [
  "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
  "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_NAMESPACE",
  "GIT_PREFIX", "GIT_CONFIG", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS",
  "GIT_REPLACE_REF_BASE", "GIT_GRAFT_FILE",
]

/// Runs Git for the host: the redirecting variables are removed, the system
/// configuration and replacement objects are off, and no prompt can wait. The
/// owner's global configuration is not touched, because the push needs it.
fn run_git(
  tools: Tools,
  arguments: List(String),
  within_ms: Int,
) -> Result(#(Int, String), String) {
  ffi_os.run_capture(
    tools.env,
    list.flatten([
      list.flat_map(redirecting_variables, fn(name) { ["-u", name] }),
      [
        "GIT_CONFIG_NOSYSTEM=1",
        "GIT_NO_REPLACE_OBJECTS=1",
        "GIT_TERMINAL_PROMPT=0",
        tools.git,
      ],
      arguments,
    ]),
    within_ms,
  )
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
