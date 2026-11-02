//// The GitHub poller: one bounded pass over a repository's REST API
//// (protocol-change/106, "Sources").
////
//// A pass reads what is new since the last one and returns it as data. It
//// writes nothing to the ledger and starts no process of its own: the project
//// actor runs it in a task, takes its answer as a message, and is the only
//// writer. That keeps each question in one place. This module knows GitHub
//// and the API's limits, and the actor knows the ledger.
////
//// ## Flow
////
//// `poll` → `pass` → `read_stream` → `ci_on_default_branch` → `one_pull_request`
////
//// 1. `poll` resolves the agent's account when the owner named none, then runs
////    `pass`.
//// 2. `pass` reads new issues, issue comments and pull request review
////    comments through `read_stream`, each from its own cursor. A cursor that
////    does not exist yet is set to the present and nothing is read, so a
////    project that starts watching does not ingest a repository's history.
//// 3. `ci_on_default_branch` reads failed check runs on the default branch.
//// 4. `one_pull_request` runs for each pull request a ticket opened: it
////    reports one that merged or closed, and reads the failed check runs on
////    the head of one that is still open.
////
//// ## Only REST, only `gh api`
////
//// Every call is `gh api` on the REST interface, run with no shell and with
//// the owner's credentials, in the daemon. GraphQL is never used: its quota is
//// shared by every agent running as the same user and has run out before. Each
//// call asks for `--include`, so the status line and the rate-limit headers
//// come back with the body, and a failed call (which `gh` exits non-zero on)
//// still carries them.
////
//// ## Rate limits
////
//// A 403 or 429 with `retry-after`, or with `x-ratelimit-remaining: 0`, stops
//// the pass and returns `Limited` with the time the headers name. A success
//// that leaves `low_remaining` calls or fewer returns `Limited` until the
//// reset too, so the next pass does not spend the last of them. With no reset
//// to read, the wait is `fallback_wait_ms`.
////
//// ## Read positions
////
//// A cursor is the newest `created_at` that decoded. A pass asks for items
//// from that time on, and the engine's dedupe takes the ones it already has.
//// A cursor moves only after the page it came from was read, so a pass that
//// stops at a rate limit repeats the stream it stopped in and loses nothing.
//// A failure in one stream does not stop the others; the pass is `Broken` only
//// when no call of it succeeded.

import client/internal/ffi_os
import client/project_github.{type Arrival, type Context}
import client/project_publish
import client/project_sources.{type Rule}
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import project/model

/// How long one `gh` call may take, in milliseconds.
pub const call_within_ms = 60_000

/// The most items one page asks for.
pub const page_size = 100

/// The most pull requests one pass reads. The rest wait for the next pass.
pub const max_watched = 20

/// The remaining calls at or below which a pass defers the next one to the
/// reset, instead of spending the last of the allowance.
pub const low_remaining = 5

/// How long a rate limit with no usable header waits, in milliseconds.
pub const fallback_wait_ms = 60_000

/// The longest a rate limit may defer the next pass, in milliseconds.
pub const longest_wait_ms = 3_900_000

/// Runs `gh` with the arguments of one call and answers its exit status and
/// what it printed. It is a closure so that a test can drive the pass with a
/// fake executable, or with none.
pub type Runner =
  fn(List(String)) -> Result(#(Int, String), String)

/// The repository a project publishes to.
pub type Repository {
  Repository(
    /// The owner's login or the organization.
    owner: String,
    /// The repository's name.
    name: String,
  )
}

/// A pull request a ticket opened, whose state and CI the pass reads.
pub type Watched {
  Watched(
    /// The ticket.
    ticket: String,
    /// The pull request's number.
    number: Int,
  )
}

/// Everything one pass needs.
pub type Request {
  Request(
    /// Runs `gh`.
    run: Runner,
    /// The repository to read.
    repository: Repository,
    /// The agent's login, or none to ask GitHub.
    account: Option(String),
    /// Logins on the allow list.
    allow: List(String),
    /// Logins of listed bots.
    bots: List(String),
    /// The configured rules.
    rules: List(Rule),
    /// The generation a trigger on each project-opened thread carries.
    generations: Dict(String, Int),
    /// The stored read positions.
    cursors: Dict(String, String),
    /// The pull requests to read.
    watched: List(Watched),
    /// System time in milliseconds.
    now_ms: Int,
  )
}

/// A ticket whose pull request is no longer open.
pub type Conclusion {
  Conclusion(
    /// The ticket.
    ticket: String,
    /// How the pull request ended.
    outcome: model.Outcome,
  )
}

/// How the pass left GitHub's allowance.
pub type Health {
  /// The pass ran to the end.
  Healthy

  /// GitHub's limit stopped it, or came close. The next pass waits.
  Limited(
    /// System time in milliseconds before which no pass runs.
    until_ms: Int,
  )

  /// Nothing the pass asked for could be read.
  Broken(
    /// What went wrong, in words fit for a board.
    reason: String,
  )
}

/// What a pass found.
pub type Polled {
  Polled(
    /// New triggers.
    arrivals: List(Arrival),
    /// Tickets whose pull request merged or closed.
    conclusions: List(Conclusion),
    /// Read positions to store, replacing the stored ones.
    cursors: List(#(String, String)),
    /// The agent's login, resolved. Empty when it could not be.
    account: String,
    /// What the pass skipped or could not read, one line each.
    notes: List(String),
    /// How the pass ended.
    health: Health,
  )
}

/// What a single call came to.
type Reply {
  Reply(status: Int, headers: List(#(String, String)), body: String)
}

/// Why a single call gave no body.
type Refusal {
  Rate(until_ms: Int)
  Failed(reason: String)
}

/// The pass's running total. Lists are built newest first and reversed once.
type Pass {
  Pass(
    arrivals: List(Arrival),
    conclusions: List(Conclusion),
    cursors: List(#(String, String)),
    notes: List(String),
    succeeded: Int,
    limited: Option(Int),
    remaining: Option(Int),
    reset_s: Option(Int),
  )
}

/// A conversation stream: where its cursor lives, which endpoint it reads,
/// the extra query fields, and the page reader.
type Stream {
  Stream(
    key: String,
    path: String,
    extra: List(#(String, String)),
    parse: fn(String, Context, Option(String)) ->
      Result(project_github.Page, String),
  )
}

const issues_key = "github:issues"

const comments_key = "github:comments"

const reviews_key = "github:reviews"

const default_ci_key = "github:ci:default"

/// The cursor of a pull request's CI, by its number.
fn pull_key(number: Int) -> String {
  "github:ci:pr-" <> int.to_string(number)
}

/// The key of every cursor a pass reads, for the caller to look up before it
/// builds the request: the three conversation streams, CI on the default
/// branch, and one per pull request the pass will read.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(project_poller.cursor_keys([]), "github:issues")
/// ```
pub fn cursor_keys(watched: List(Watched)) -> List(String) {
  list.flatten([
    [issues_key, comments_key, reviews_key, default_ci_key],
    list.take(watched, max_watched)
      |> list.map(fn(each) { pull_key(each.number) }),
  ])
}

// --- running gh ---------------------------------------------------------------

/// The runner for the real `gh`, or none on a machine without it. The command
/// runs under `env` with the variables that keep a prompt from waiting for a
/// person who is not there, and its arguments are whole arguments that no
/// shell parses.
///
/// ## Examples
///
/// ```gleam
/// // project_poller.runner(project_publish.tools())
/// ```
pub fn runner(tools: project_publish.Tools) -> Option(Runner) {
  option.map(tools.gh, fn(gh) {
    fn(arguments) {
      ffi_os.run_capture(
        tools.env,
        [
          "GIT_TERMINAL_PROMPT=0",
          "GH_PROMPT_DISABLED=1",
          "GH_NO_UPDATE_NOTIFIER=1",
          gh,
          ..arguments
        ],
        call_within_ms,
      )
    }
  })
}

/// One GET, with its fields as query parameters. The path is built from
/// validated names and numbers only, and a field is one whole argument.
fn get(
  request: Request,
  path: String,
  fields: List(#(String, String)),
) -> Result(Reply, Refusal) {
  send(request.run, request.now_ms, "GET", path, fields)
}

/// One call with a method, a path and its fields. For a GET the fields are
/// query parameters and for a POST they are the body's fields; either way each
/// is one whole argument.
fn send(
  run: Runner,
  now_ms: Int,
  method: String,
  path: String,
  fields: List(#(String, String)),
) -> Result(Reply, Refusal) {
  let parameters =
    list.flat_map(fields, fn(field) { ["-f", field.0 <> "=" <> field.1] })
  let arguments =
    list.flatten([["api", "--include", "--method", method, path], parameters])

  case run(arguments) {
    Error(reason) -> Error(Failed("gh did not run: " <> reason))
    Ok(#(status, output)) -> classify(now_ms, status, output)
  }
}

/// Reads a call's output. A status of 200 to 299 is a reply. 403 and 429 are
/// a rate limit when a header says so. Everything else is a failure.
fn classify(
  now_ms: Int,
  exit_status: Int,
  output: String,
) -> Result(Reply, Refusal) {
  case parse_reply(output) {
    Error(Nil) ->
      Error(Failed(
        "gh printed no HTTP headers (exit status "
        <> int.to_string(exit_status)
        <> "); is it signed in?",
      ))
    Ok(reply) ->
      case reply.status >= 200 && reply.status < 300 {
        True -> Ok(reply)
        False -> Error(refusal_of(now_ms, reply))
      }
  }
}

/// A non-success reply as a rate limit or a failure.
fn refusal_of(now_ms: Int, reply: Reply) -> Refusal {
  let limited = reply.status == 429 || reply.status == 403

  // Only 403 and 429 can be a limit, and only with a header that says so.
  case limited, limit_until(now_ms, reply.headers) {
    True, Some(until) -> Rate(until)
    _, _ -> Failed("GitHub answered " <> int.to_string(reply.status))
  }
}

/// Splits `gh api --include` output into its status, headers and body. The
/// header block ends at the first blank line, which is `\r\n\r\n` on the wire.
fn parse_reply(output: String) -> Result(Reply, Nil) {
  let normal = string.replace(output, "\r\n", "\n")
  use #(head, body) <- result.try(string.split_once(normal, "\n\n"))

  // The first line is the status and the rest are headers.
  case string.split(head, "\n") {
    [status_line, ..lines] -> {
      use status <- result.map(status_code(status_line))
      Reply(status:, headers: headers_of(lines), body:)
    }
    [] -> Error(Nil)
  }
}

/// The code of a status line such as `HTTP/2.0 200 OK`.
fn status_code(line: String) -> Result(Int, Nil) {
  case string.starts_with(line, "HTTP/"), string.split(line, " ") {
    True, [_, code, ..] -> int.parse(code)
    _, _ -> Error(Nil)
  }
}

/// Header lines as lowercase names and trimmed values.
fn headers_of(lines: List(String)) -> List(#(String, String)) {
  list.filter_map(lines, fn(line) {
    use #(name, value) <- result.map(string.split_once(line, ":"))
    #(string.lowercase(string.trim(name)), string.trim(value))
  })
}

fn header(headers: List(#(String, String)), name: String) -> Option(String) {
  list.key_find(headers, name) |> option.from_result
}

fn header_int(headers: List(#(String, String)), name: String) -> Option(Int) {
  option.then(header(headers, name), fn(text) {
    int.parse(text) |> option.from_result
  })
}

/// When the next call may be made, from the headers of a refused one. A
/// `retry-after` counts seconds from now and a reset names an epoch second.
/// A refusal that says the allowance is spent and names no time waits
/// `fallback_wait_ms`. One that says neither is not a rate limit.
///
/// ## Examples
///
/// ```gleam
/// assert project_poller.limit_until(1000, [#("retry-after", "30")]) == Some(31_000)
/// ```
///
/// ```gleam
/// assert project_poller.limit_until(1000, []) == None
/// ```
pub fn limit_until(
  now_ms: Int,
  headers: List(#(String, String)),
) -> Option(Int) {
  let spent = header(headers, "x-ratelimit-remaining") == Some("0")
  let retry = header_int(headers, "retry-after")
  let reset = header_int(headers, "x-ratelimit-reset")

  // A retry-after wins, then a reset when the allowance is spent.
  case retry, reset, spent {
    Some(seconds), _, _ -> Some(waited(now_ms, now_ms + seconds * 1000))
    None, Some(at), True -> Some(waited(now_ms, at * 1000))
    None, None, True -> Some(now_ms + fallback_wait_ms)
    None, Some(_), False | None, None, False -> None
  }
}

/// A wait of at least a second and at most `longest_wait_ms`.
fn waited(now_ms: Int, until_ms: Int) -> Int {
  int.min(int.max(until_ms, now_ms + 1000), now_ms + longest_wait_ms)
}

// --- the pass -----------------------------------------------------------------

/// Runs one pass.
///
/// ## Examples
///
/// ```gleam
/// // project_poller.poll(request)
/// ```
pub fn poll(request: Request) -> Polled {
  case resolve_account(request) {
    Error(refusal) -> unresolved(refusal)
    Ok(account) -> {
      let context =
        project_github.Context(
          account:,
          allow: request.allow,
          bots: request.bots,
          rules: request.rules,
          generations: request.generations,
          now_ms: request.now_ms,
        )
      finished(request, account, pass(request, context))
    }
  }
}

/// The answer of a pass that could not learn who the agent is.
fn unresolved(refusal: Refusal) -> Polled {
  let health = case refusal {
    Rate(until_ms) -> Limited(until_ms)
    Failed(reason) -> Broken(reason)
  }
  Polled(
    arrivals: [],
    conclusions: [],
    cursors: [],
    account: "",
    notes: [],
    health:,
  )
}

/// The agent's login: the configured one, or whoever the credentials are.
fn resolve_account(request: Request) -> Result(String, Refusal) {
  case request.account {
    Some(configured) -> Ok(configured)
    None -> {
      use reply <- result.try(get(request, "user", []))
      project_github.login(reply.body) |> result.map_error(Failed)
    }
  }
}

/// The three conversation streams, then CI on the default branch, then the
/// pull requests. A rate limit anywhere ends the pass with what it had.
fn pass(request: Request, context: Context) -> Pass {
  let base = base_path(request)
  let streams = [
    Stream(
      issues_key,
      base <> "/issues",
      [#("state", "all")],
      project_github.issues,
    ),
    Stream(
      comments_key,
      base <> "/issues/comments",
      [],
      project_github.comments,
    ),
    Stream(
      reviews_key,
      base <> "/pulls/comments",
      [],
      project_github.review_comments,
    ),
  ]
  let read =
    list.fold(streams, empty_pass(), fn(acc, stream) {
      read_stream(request, context, acc, stream)
    })
  let checked = ci_on_default_branch(request, context, read)
  list.take(request.watched, max_watched)
  |> list.fold(checked, fn(acc, watched) {
    one_pull_request(request, context, acc, watched)
  })
}

fn base_path(request: Request) -> String {
  "repos/" <> request.repository.owner <> "/" <> request.repository.name
}

fn empty_pass() -> Pass {
  Pass(
    arrivals: [],
    conclusions: [],
    cursors: [],
    notes: [],
    succeeded: 0,
    limited: None,
    remaining: None,
    reset_s: None,
  )
}

/// Puts a pass in the order it ran and names how it ended.
fn finished(request: Request, account: String, total: Pass) -> Polled {
  Polled(
    arrivals: list.reverse(total.arrivals),
    conclusions: list.reverse(total.conclusions),
    cursors: total.cursors,
    account:,
    notes: list.reverse(total.notes),
    health: health_of(request.now_ms, total),
  )
}

/// A limit wins, then a pass in which nothing succeeded but something failed,
/// then an allowance nearly spent.
fn health_of(now_ms: Int, total: Pass) -> Health {
  case total.limited, total.notes, total.succeeded {
    Some(until), _, _ -> Limited(until)
    None, [failure, ..], 0 -> Broken(failure)
    None, _, _ -> allowance(now_ms, total)
  }
}

fn allowance(now_ms: Int, total: Pass) -> Health {
  case total.remaining, total.reset_s {
    Some(left), Some(reset) if left <= low_remaining ->
      Limited(waited(now_ms, reset * 1000))
    _, _ -> Healthy
  }
}

// --- one stream ---------------------------------------------------------------

/// Reads one conversation stream from its cursor. With no cursor yet the
/// cursor is set to the present and nothing is read.
fn read_stream(
  request: Request,
  context: Context,
  total: Pass,
  stream: Stream,
) -> Pass {
  case total.limited, dict.get(request.cursors, stream.key) {
    Some(_), _ -> total
    None, Error(Nil) -> store(total, stream.key, iso_from_ms(request.now_ms))
    None, Ok(since) -> fetch_stream(request, context, total, stream, since)
  }
}

fn fetch_stream(
  request: Request,
  context: Context,
  total: Pass,
  stream: Stream,
  since: String,
) -> Pass {
  let fields =
    list.append(stream.extra, [
      #("sort", "created"),
      #("direction", "asc"),
      #("since", since),
      #("per_page", int.to_string(page_size)),
    ])

  // A reply that parses moves the cursor; one that does not, or that was
  // refused, is a note and leaves the cursor where it was.
  case get(request, stream.path, fields) {
    Error(refusal) -> refused(total, stream.key, refusal)
    Ok(reply) ->
      case stream.parse(reply.body, context, Some(since)) {
        Error(reason) -> noted(total, stream.key <> ": " <> reason)
        Ok(page) -> taken(counted(total, reply), stream.key, since, page)
      }
  }
}

/// Adds a page's arrivals and moves the cursor to the page's newest time.
fn taken(
  total: Pass,
  key: String,
  since: String,
  page: project_github.Page,
) -> Pass {
  let reported = case page.skipped {
    0 -> total
    skipped ->
      noted(
        total,
        key <> ": skipped " <> int.to_string(skipped) <> " unreadable items",
      )
  }
  let moved = case page.newest {
    Some(newest) -> store(reported, key, later(since, newest))
    None -> reported
  }
  Pass(
    ..moved,
    arrivals: list.append(list.reverse(page.arrivals), moved.arrivals),
  )
}

/// The later of two times in the plain shape.
fn later(a: String, b: String) -> String {
  case string.compare(a, b) {
    order.Gt -> a
    order.Eq | order.Lt -> b
  }
}

// --- CI -----------------------------------------------------------------------

/// Failed check runs on the default branch. The first pass only sets the
/// cursor, as every stream does.
fn ci_on_default_branch(
  request: Request,
  context: Context,
  total: Pass,
) -> Pass {
  case total.limited, dict.get(request.cursors, default_ci_key) {
    Some(_), _ -> total
    None, Error(Nil) ->
      store(total, default_ci_key, iso_from_ms(request.now_ms))
    None, Ok(cursor) -> default_failures(request, context, total, cursor)
  }
}

fn default_failures(
  request: Request,
  context: Context,
  total: Pass,
  cursor: String,
) -> Pass {
  case get(request, base_path(request), []) {
    Error(refusal) -> refused(total, default_ci_key, refusal)
    Ok(described) ->
      case project_github.default_branch(described.body) {
        Error(reason) -> noted(total, "the default branch: " <> reason)
        Ok(branch) ->
          failures_on(
            request,
            context,
            counted(total, described),
            Failures(
              path: base_path(request) <> "/commits/" <> branch <> "/check-runs",
              since: Some(cursor),
              thread: model.ThreadId("gh-ci-" <> branch),
              where: "the default branch " <> branch,
              key: default_ci_key,
            ),
          )
      }
  }
}

/// Where a check-runs read looks and what its failures belong to.
type Failures {
  Failures(
    path: String,
    since: Option(String),
    thread: model.ThreadId,
    where: String,
    key: String,
  )
}

/// Reads the failed check runs at one path and adds them as triggers on the
/// thread. The cursor moves to the newest completion time seen.
fn failures_on(
  request: Request,
  context: Context,
  total: Pass,
  target: Failures,
) -> Pass {
  case get(request, target.path, [#("per_page", int.to_string(page_size))]) {
    Error(refusal) -> refused(total, target.key, refusal)
    Ok(reply) ->
      case project_github.failures(reply.body, target.since) {
        Error(reason) -> noted(total, target.key <> ": " <> reason)
        Ok(found) -> failed(counted(total, reply), context, found, target)
      }
  }
}

fn failed(
  total: Pass,
  context: Context,
  found: List(project_github.Failure),
  target: Failures,
) -> Pass {
  let arrivals =
    list.map(found, fn(each) {
      project_github.failure_arrival(context, each, target.thread, target.where)
    })
  let newest =
    list.fold(found, option.unwrap(target.since, ""), fn(best, each) {
      later(best, each.completed_at)
    })

  // No cursor is written for a read that found nothing and had none.
  let moved = case newest {
    "" -> total
    _ -> store(total, target.key, newest)
  }
  Pass(..moved, arrivals: list.append(list.reverse(arrivals), moved.arrivals))
}

// --- pull requests a ticket opened --------------------------------------------

/// Reads one pull request: it concludes its ticket when it is no longer open,
/// and its failed checks become triggers while it is.
fn one_pull_request(
  request: Request,
  context: Context,
  total: Pass,
  watched: Watched,
) -> Pass {
  let key = pull_key(watched.number)
  let path = base_path(request) <> "/pulls/" <> int.to_string(watched.number)

  // A rate limit already ended the pass; nothing more is asked.
  case total.limited, get(request, path, []) {
    Some(_), _ -> total
    None, Error(refusal) -> refused(total, key, refusal)
    None, Ok(reply) ->
      case project_github.pull_state(reply.body) {
        Error(reason) -> noted(total, key <> ": " <> reason)
        Ok(state) ->
          pull_request_read(
            request,
            context,
            counted(total, reply),
            watched,
            state,
          )
      }
  }
}

fn pull_request_read(
  request: Request,
  context: Context,
  total: Pass,
  watched: Watched,
  state: project_github.PullState,
) -> Pass {
  let key = pull_key(watched.number)
  case state.open {
    project_github.WasMerged -> ended(total, watched, model.Merged)
    project_github.WasClosed -> ended(total, watched, model.Closed)
    project_github.StillOpen ->
      failures_on(
        request,
        context,
        total,
        Failures(
          path: base_path(request) <> "/commits/" <> state.head <> "/check-runs",
          since: option.from_result(dict.get(request.cursors, key)),
          thread: model.github_thread(watched.number),
          where: "the pull request's branch",
          key:,
        ),
      )
  }
}

fn ended(total: Pass, watched: Watched, outcome: model.Outcome) -> Pass {
  Pass(..total, conclusions: [
    Conclusion(watched.ticket, outcome),
    ..total.conclusions
  ])
}

// --- the running total ---------------------------------------------------------

fn noted(total: Pass, line: String) -> Pass {
  Pass(..total, notes: [line, ..total.notes])
}

/// Replaces a cursor in the total.
fn store(total: Pass, key: String, value: String) -> Pass {
  let kept = list.filter(total.cursors, fn(entry) { entry.0 != key })
  Pass(..total, cursors: [#(key, value), ..kept])
}

/// Notes a refused call: a rate limit stops the pass, a failure is a note.
fn refused(total: Pass, key: String, refusal: Refusal) -> Pass {
  case refusal {
    Rate(until) -> Pass(..total, limited: Some(until))
    Failed(reason) -> noted(total, key <> ": " <> reason)
  }
}

/// Counts a successful call and remembers the allowance it reported.
fn counted(total: Pass, reply: Reply) -> Pass {
  Pass(
    ..total,
    succeeded: total.succeeded + 1,
    remaining: option.or(
      header_int(reply.headers, "x-ratelimit-remaining"),
      total.remaining,
    ),
    reset_s: option.or(
      header_int(reply.headers, "x-ratelimit-reset"),
      total.reset_s,
    ),
  )
}

// --- replies ------------------------------------------------------------------

/// What posting a reply came to.
pub type Posting {
  /// The comment is on the issue, whether this call put it there or an
  /// earlier attempt did.
  Posted

  /// GitHub's limit stopped it. Try again after this system time.
  PostLimited(until_ms: Int)

  /// It failed in a way that may pass.
  PostFailed(reason: String)
}

/// Posts a reply to an issue or pull request as a comment, once. The body
/// carries a marker line that names the reply, and before posting the call
/// looks through the comments written since `since_ms` for that marker: a
/// reply whose request was lost after GitHub took it is found, not posted
/// again. This is the idempotence the outbox row relies on, because a row that
/// is performed twice must put one comment on the issue.
///
/// ## Examples
///
/// ```gleam
/// // project_poller.post_reply(run, repository, 12, "<!-- loom-reply:k -->", body, since_ms, now_ms)
/// ```
pub fn post_reply(
  run: Runner,
  repository: Repository,
  number: Int,
  marker: String,
  body: String,
  since_ms: Int,
  now_ms: Int,
) -> Posting {
  let path =
    "repos/"
    <> repository.owner
    <> "/"
    <> repository.name
    <> "/issues/"
    <> int.to_string(number)
    <> "/comments"
  let listing = [
    #("since", iso_from_ms(since_ms)),
    #("per_page", int.to_string(page_size)),
  ]

  // A marker already on the issue means the reply is done. A listing that
  // fails is not taken as proof of absence, so nothing is posted blind.
  case send(run, now_ms, "GET", path, listing) {
    Error(refusal) -> posting_refused(refusal)
    Ok(reply) ->
      case holds_marker(reply.body, marker) {
        True -> Posted
        False -> create_comment(run, now_ms, path, body)
      }
  }
}

fn create_comment(
  run: Runner,
  now_ms: Int,
  path: String,
  body: String,
) -> Posting {
  case send(run, now_ms, "POST", path, [#("body", body)]) {
    Ok(_) -> Posted
    Error(refusal) -> posting_refused(refusal)
  }
}

fn posting_refused(refusal: Refusal) -> Posting {
  case refusal {
    Rate(until_ms) -> PostLimited(until_ms)
    Failed(reason) -> PostFailed(reason)
  }
}

/// Whether any comment of a listing has the marker in its body. A listing
/// that is not an array holds none.
fn holds_marker(listing: String, marker: String) -> Bool {
  let bodies = {
    use text <- decode.field("body", decode.optional(decode.string))
    decode.success(option.unwrap(text, ""))
  }
  case json.parse(listing, decode.list(decode.dynamic)) {
    Error(_) -> False
    Ok(items) ->
      list.any(items, fn(item) {
        case decode.run(item, bodies) {
          Ok(text) -> string.contains(text, marker)
          Error(_) -> False
        }
      })
  }
}

// --- time ---------------------------------------------------------------------

/// A system time in milliseconds as `YYYY-MM-DDTHH:MM:SSZ`, the shape the
/// cursors and GitHub's `since` parameter use.
///
/// ## Examples
///
/// ```gleam
/// assert project_poller.iso_from_ms(0) == "1970-01-01T00:00:00Z"
/// ```
///
/// ```gleam
/// assert project_poller.iso_from_ms(1_793_613_000_000) == "2026-11-02T09:50:00Z"
/// ```
pub fn iso_from_ms(ms: Int) -> String {
  let seconds = int.max(ms, 0) / 1000
  let days = seconds / 86_400
  let of_day = seconds % 86_400

  // Howard Hinnant's days-to-civil algorithm, for dates from 1970 on.
  let shifted = days + 719_468
  let era = shifted / 146_097
  let day_of_era = shifted - era * 146_097
  let year_of_era =
    {
      day_of_era
      - day_of_era
      / 1460
      + day_of_era
      / 36_524
      - day_of_era
      / 146_096
    }
    / 365
  let day_of_year =
    day_of_era - { 365 * year_of_era + year_of_era / 4 - year_of_era / 100 }
  let shifted_month = { 5 * day_of_year + 2 } / 153
  let day = day_of_year - { 153 * shifted_month + 2 } / 5 + 1
  let month = case shifted_month < 10 {
    True -> shifted_month + 3
    False -> shifted_month - 9
  }
  let year = year_of_era + era * 400 + january_or_february(month)

  pad(year, 4)
  <> "-"
  <> pad(month, 2)
  <> "-"
  <> pad(day, 2)
  <> "T"
  <> pad(of_day / 3600, 2)
  <> ":"
  <> pad(of_day % 3600 / 60, 2)
  <> ":"
  <> pad(of_day % 60, 2)
  <> "Z"
}

/// The calendar year starts in March in the algorithm above, so January and
/// February belong to the next year.
fn january_or_february(month: Int) -> Int {
  case month <= 2 {
    True -> 1
    False -> 0
  }
}

fn pad(value: Int, width: Int) -> String {
  string.pad_start(int.to_string(value), width, "0")
}
