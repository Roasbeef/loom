//// GitHub's REST answers, read totally and translated into the project
//// engine's triggers (protocol-change/106, "Sources").
////
//// Everything in a GitHub answer is untrusted data. A login, a title, a
//// comment and a check run's name were written by someone the owner may not
//// know, so this module treats each field as text to be bounded and checked,
//// never as a command or an address. Its decoders are total: a page that is
//// not a JSON array is an error the poller records, an item that does not
//// decode is counted and left out, and nothing here panics on any input.
////
//// ## What is decided here, and what is not
////
//// This module decides a trigger's inputs and nothing else. It classifies the
//// sender from the owner's literal lists (`Person`, `ListedBot`, `Unlisted`),
//// reads whether the text names the agent, finds the first matching rule, and
//// gives the trigger an identity that GitHub's own id determines. It never
//// decides strength: `project/gate` does that from these inputs, in the
//// engine, where a model cannot reach it. `Owner` is never produced here,
//// because the owner is whoever types in the composer and not whoever has the
//// owner's GitHub login.
////
//// ## Identity and idempotence
////
//// A trigger's id is a function of GitHub's id for the item, so reading the
//// same page twice produces the same triggers and the engine stores each
//// once. A thread is `model.github_thread` of the issue or pull request
//// number. Because the agent's own comments must never come back as input,
//// the account's login is dropped here, before anything is stored, and the
//// engine drops it again from the bot identity it is given.
////
//// ## Text
////
//// A body longer than `stored_chars` is cut with a marker, and what reaches a
//// worker is cut at `inline_chars` with a pointer to the ledger, where the
//// stored text can be read in full. Control characters other than the newline
//// and the tab are replaced with spaces, so a terminal escape sequence in a
//// comment never reaches a screen.

import client/project_sources.{type Rule}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import project/model.{
  type ActorId, type Trigger, ActorId, Addressed, Unaddressed,
}

/// The most code points of a comment the ledger stores.
pub const stored_chars = 32_768

/// The most code points of a comment a worker or the router is handed inline.
pub const inline_chars = 4000

/// The most code points of a title, a check's name or a path kept in a text.
const short_chars = 200

/// What the poller knows when it translates a page. The host builds it from
/// the engine's state and the owner's configuration before each poll.
pub type Context {
  Context(
    /// The agent's own login. Its messages are dropped.
    account: String,
    /// Logins of people on the allow list.
    allow: List(String),
    /// Logins of bots on the allow list.
    bots: List(String),
    /// The rules, in file order.
    rules: List(Rule),
    /// For each thread a ticket's pull request opened, the generation a
    /// trigger on it carries.
    generations: Dict(String, Int),
    /// System time in milliseconds when the poll began.
    now_ms: Int,
  )
}

/// A trigger with the text the engine does not hold.
pub type Arrival {
  Arrival(
    /// The trigger, with the gate's inputs filled in.
    trigger: Trigger,
    /// The agent's identity, which the engine compares the actor with.
    bot: ActorId,
    /// The text as stored, at most `stored_chars` code points.
    body: String,
  )
}

/// What one page of items came to.
pub type Page {
  Page(
    /// The triggers, oldest first.
    arrivals: List(Arrival),
    /// The newest `created_at` among the items that decoded, or none.
    newest: Option(String),
    /// Items that did not decode, or whose login or time was not plain.
    skipped: Int,
    /// Items the agent wrote itself, dropped before the engine saw them.
    own: Int,
  )
}

/// The kinds of conversation item a poll reads.
pub type Kind {
  /// A newly opened issue.
  IssueOpened

  /// A pull request, which GitHub lists among the issues. Its conversation
  /// arrives as comments, so it makes no trigger, but its time still moves the
  /// cursor.
  PullListed

  /// A comment on an issue or a pull request.
  IssueComment
  /// A comment on a line of a pull request's diff.
  ReviewComment
}

/// One item of a page, once its fields are known to be well formed.
type Note {
  Note(
    kind: Kind,
    id: Int,
    number: Int,
    login: String,
    created_at: String,
    text: String,
  )
}

/// What a pull request's state came to.
pub type PullState {
  PullState(
    /// The pull request's number.
    number: Int,
    /// Whether it is still open.
    open: PullOpen,
    /// The commit its head names.
    head: String,
  )
}

/// A pull request's life, in the words the engine's outcomes use.
pub type PullOpen {
  /// Still open.
  StillOpen
  /// Closed by merging.
  WasMerged
  /// Closed without merging.
  WasClosed
}

/// One failed check run on a commit.
pub type Failure {
  Failure(
    /// GitHub's id for the check run.
    id: Int,
    /// The check's name, made plain and capped.
    name: String,
    /// The `completed_at` time, the cursor's unit.
    completed_at: String,
    /// The app that ran it, or `ci`.
    app: String,
    /// The commit it ran against.
    commit: String,
  )
}

// --- reading a page -----------------------------------------------------------

/// Reads a page of the repository's issues and translates the new ones.
/// Pull requests appear in this listing too and are skipped, because their
/// conversation arrives as comments.
///
/// ## Examples
///
/// ```gleam
/// assert project_github.issues("not json", ctx, None) |> result.is_error
/// ```
pub fn issues(
  text: String,
  context: Context,
  since: Option(String),
) -> Result(Page, String) {
  use items <- result.map(array(text))
  page(items, issue_decoder(), context, since)
}

/// Reads a page of the repository's issue and pull request comments.
///
/// ## Examples
///
/// ```gleam
/// assert project_github.comments("[]", ctx, None) |> result.is_ok
/// ```
pub fn comments(
  text: String,
  context: Context,
  since: Option(String),
) -> Result(Page, String) {
  use items <- result.map(array(text))
  page(items, comment_decoder(IssueComment, "issue_url"), context, since)
}

/// Reads a page of the repository's pull request review comments.
///
/// ## Examples
///
/// ```gleam
/// assert project_github.review_comments("[]", ctx, None) |> result.is_ok
/// ```
pub fn review_comments(
  text: String,
  context: Context,
  since: Option(String),
) -> Result(Page, String) {
  use items <- result.map(array(text))
  page(
    items,
    comment_decoder(ReviewComment, "pull_request_url"),
    context,
    since,
  )
}

/// The elements of a JSON array, each left undecoded so that one malformed
/// element cannot take the page with it.
fn array(text: String) -> Result(List(Dynamic), String) {
  json.parse(text, decode.list(decode.dynamic))
  |> result.replace_error("GitHub answered something that is not a JSON array")
}

/// Decodes and translates each item of a page, keeping count of what was left
/// out and which `created_at` is the newest.
fn page(
  items: List(Dynamic),
  decoder: decode.Decoder(Note),
  context: Context,
  since: Option(String),
) -> Page {
  let notes =
    list.map(items, fn(item) {
      decode.run(item, decoder) |> result.replace_error(Nil)
    })
  let good = list.filter_map(notes, fn(each) { each })
  let skipped = list.length(notes) - list.length(good)

  // Only items at or after the cursor are new; the engine's dedupe takes the
  // ones read twice.
  let fresh =
    list.filter(good, fn(note) { at_or_after(note.created_at, since) })
  let newest = newest_of(good)
  let own =
    list.count(fresh, fn(note) { same_login(note.login, context.account) })
  let arrivals = list.filter_map(fresh, fn(note) { arrival(context, note) })
  Page(arrivals:, newest:, skipped:, own:)
}

/// Whether a `created_at` is at or after the cursor. With no cursor every item
/// is.
fn at_or_after(created_at: String, since: Option(String)) -> Bool {
  case since {
    None -> True
    Some(cursor) -> string.compare(created_at, cursor) != order.Lt
  }
}

// The newest of the items' creation times. ISO 8601 times in one zone sort as
// text, which is why `plain_time` requires that exact shape.
fn newest_of(notes: List(Note)) -> Option(String) {
  list.fold(notes, None, fn(best, note) {
    case best {
      None -> Some(note.created_at)
      Some(held) ->
        case string.compare(note.created_at, held) == order.Gt {
          True -> Some(note.created_at)
          False -> Some(held)
        }
    }
  })
}

// --- decoding one item --------------------------------------------------------

fn issue_decoder() -> decode.Decoder(Note) {
  use id <- decode.field("id", decode.int)
  use number <- decode.field("number", decode.int)
  use login <- decode.subfield(["user", "login"], decode.string)
  use created_at <- decode.field("created_at", decode.string)
  use title <- decode.field("title", decode.string)
  use body <- decode.optional_field(
    "body",
    None,
    decode.optional(decode.string),
  )
  use pull <- decode.optional_field(
    "pull_request",
    None,
    decode.optional(decode.dynamic),
  )
  let text =
    "New issue #"
    <> int.to_string(number)
    <> ": "
    <> shortened(title)
    <> "\n\n"
    <> option.unwrap(body, "")
  let kind = case pull {
    Some(_) -> PullListed
    None -> IssueOpened
  }
  well_formed(kind, id, number, login, created_at, text)
}

fn comment_decoder(kind: Kind, link: String) -> decode.Decoder(Note) {
  use id <- decode.field("id", decode.int)
  use login <- decode.subfield(["user", "login"], decode.string)
  use created_at <- decode.field("created_at", decode.string)
  use url <- decode.field(link, decode.string)
  use body <- decode.optional_field(
    "body",
    None,
    decode.optional(decode.string),
  )
  let number = last_number(url)
  let heading = case kind {
    IssueComment -> "Comment on #"
    ReviewComment -> "Review comment on pull request #"
    IssueOpened | PullListed -> "Issue #"
  }
  let text =
    heading <> int.to_string(number) <> ":\n\n" <> option.unwrap(body, "")
  well_formed(kind, id, number, login, created_at, text)
}

/// Checks an item's identity fields. A decoder that fails here fails with
/// the reason, and the page counts the item as skipped.
fn well_formed(
  kind: Kind,
  id: Int,
  number: Int,
  login: String,
  created_at: String,
  text: String,
) -> decode.Decoder(Note) {
  let usable =
    id > 0
    && number > 0
    && plain_time(created_at)
    && result.is_ok(project_sources.plain_login(login, "login"))

  case usable {
    True ->
      decode.success(Note(kind:, id:, number:, login:, created_at:, text:))
    False ->
      decode.failure(
        Note(kind:, id: 0, number: 0, login: "", created_at: "", text: ""),
        "a well formed item",
      )
  }
}

/// The trailing number of a URL such as `.../issues/12`, or 0.
fn last_number(url: String) -> Int {
  case list.last(string.split(url, "/")) {
    Ok(tail) -> result.unwrap(int.parse(tail), 0)
    Error(Nil) -> 0
  }
}

// --- translating one item -----------------------------------------------------

/// Turns a note into an arrival, or says there is none: the agent's own
/// message is dropped here.
fn arrival(context: Context, note: Note) -> Result(Arrival, Nil) {
  case note.kind, same_login(note.login, context.account) {
    PullListed, _ -> Error(Nil)
    _, True -> Error(Nil)
    IssueOpened, False | IssueComment, False | ReviewComment, False ->
      Ok(build(context, note))
  }
}

fn build(context: Context, note: Note) -> Arrival {
  let thread = model.github_thread(note.number)
  let body = bounded(note.text)
  let matched = project_sources.matching(context.rules, "github", body)
  let generation = result.unwrap(dict.get(context.generations, thread.value), 0)
  let addressing = case mentions(body, context.account) {
    True -> Addressed
    False -> Unaddressed
  }
  let trigger =
    model.Trigger(
      id: model.TriggerId(trigger_id(note.kind, note.id)),
      source: model.SourceId("github"),
      thread:,
      actor: ActorId(note.login),
      inputs: model.Inputs(
        sender: sender_of(context, note.login),
        addressing:,
        rule: option.map(matched, fn(rule) {
          model.RuleMatch(model.RuleId(rule.name), rule.approvals)
        }),
      ),
      generation:,
      at_ms: context.now_ms,
    )
  Arrival(trigger:, bot: ActorId(context.account), body:)
}

/// A trigger's id: a kind word and GitHub's own id.
///
/// ## Examples
///
/// ```gleam
/// assert project_github.trigger_id(project_github.IssueComment, 9) == "gh-c-9"
/// ```
pub fn trigger_id(kind: Kind, id: Int) -> String {
  case kind {
    IssueOpened -> "gh-i-" <> int.to_string(id)
    PullListed -> "gh-p-" <> int.to_string(id)
    IssueComment -> "gh-c-" <> int.to_string(id)
    ReviewComment -> "gh-r-" <> int.to_string(id)
  }
}

/// The sender's class from the owner's literal lists. The comparison ignores
/// case, because GitHub logins do. `Owner` is never returned.
fn sender_of(context: Context, login: String) -> model.Sender {
  case listed(context.allow, login), listed(context.bots, login) {
    True, _ -> model.Person
    False, True -> model.ListedBot
    False, False -> model.Unlisted
  }
}

fn listed(logins: List(String), login: String) -> Bool {
  list.any(logins, fn(each) { same_login(each, login) })
}

fn same_login(a: String, b: String) -> Bool {
  string.lowercase(a) == string.lowercase(b)
}

// --- the text -----------------------------------------------------------------

/// Whether `text` holds `@<account>` as a whole mention: the character before
/// the `@` is not part of a word, so an address such as `me@host` is not one,
/// and the character after the name is not part of a login. The scan splits on
/// `@` and reads each piece once, without a pattern.
///
/// ## Examples
///
/// ```gleam
/// assert project_github.mentions("hey @loom-bot, look", "loom-bot")
/// ```
///
/// ```gleam
/// assert !project_github.mentions("mail loom-bot@example.com", "loom-bot")
/// ```
///
/// ```gleam
/// assert !project_github.mentions("@loom-bot2 look", "loom-bot")
/// ```
pub fn mentions(text: String, account: String) -> Bool {
  case string.split(text, "@") {
    [] -> False
    [first, ..rest] -> mentioned(first, rest, string.lowercase(account))
  }
}

/// Reads the pieces after each `@`, carrying the piece before it so that the
/// character in front of the `@` can be checked.
fn mentioned(before: String, rest: List(String), account: String) -> Bool {
  case rest {
    [] -> False
    [piece, ..later] ->
      case starts_the_name(before, piece, account) {
        True -> True
        False -> mentioned(piece, later, account)
      }
  }
}

fn starts_the_name(before: String, piece: String, account: String) -> Bool {
  let size = string.byte_size(account)
  let named = string.lowercase(string.slice(piece, 0, size)) == account
  let after = string.slice(piece, size, 1)
  named && !login_character(after) && !word_character(string.last(before))
}

/// The last character of the text before the `@`, or an empty string.
fn word_character(last: Result(String, Nil)) -> Bool {
  case last {
    Ok(character) -> login_character(character)
    Error(Nil) -> False
  }
}

fn login_character(character: String) -> Bool {
  character != ""
  && string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_",
    character,
  )
}

/// The stored form of a text: controls other than the newline and the tab
/// become spaces, and a text over `stored_chars` is cut with a marker.
///
/// ## Examples
///
/// ```gleam
/// assert project_github.bounded("a\u{1b}b") == "a b"
/// ```
pub fn bounded(text: String) -> String {
  let plain =
    text
    |> string.to_utf_codepoints
    |> list.map(fn(point) {
      let code = string.utf_codepoint_to_int(point)
      case code < 0x20 && code != 0x0a && code != 0x09, code == 0x7f {
        True, _ | _, True -> " "
        False, False -> string.from_utf_codepoints([point])
      }
    })
    |> string.concat
  cut(plain, stored_chars, "\n[the text was cut at the ledger's limit]")
}

/// The text a worker or the router is handed: at most `inline_chars` code
/// points, then a pointer to the trigger's full text in the ledger.
///
/// ## Examples
///
/// ```gleam
/// assert project_github.inline("short", "gh-c-1") == "short"
/// ```
pub fn inline(text: String, trigger: String) -> String {
  cut(
    text,
    inline_chars,
    "\n[the rest of this text is in the project ledger; read it with project_read trigger:"
      <> trigger
      <> "]",
  )
}

/// Cuts `text` to `limit` code points and appends `marker` when it was cut.
fn cut(text: String, limit: Int, marker: String) -> String {
  let points = string.to_utf_codepoints(text)

  // Text within the limit is returned as it was.
  case list.length(points) > limit {
    False -> text
    True -> string.from_utf_codepoints(list.take(points, limit)) <> marker
  }
}

/// A title, a name or a path made short and single-line.
fn shortened(text: String) -> String {
  bounded(text)
  |> string.replace("\n", " ")
  |> string.to_utf_codepoints
  |> list.take(short_chars)
  |> string.from_utf_codepoints
}

// --- replies ------------------------------------------------------------------

/// The most words a reply of a purpose holds when it goes to GitHub. An
/// acknowledgement is short on purpose: the design counts a person's attention
/// as the scarce resource, and a long one is noise.
///
/// ## Examples
///
/// ```gleam
/// assert project_github.reply_words("acknowledge") == 40
/// ```
pub fn reply_words(purpose: String) -> Int {
  case purpose {
    "clarify" | "decline" -> 100
    _ -> 40
  }
}

/// The comment body for a reply: the router's words made safe, cut to the
/// purpose's word cap, then a blank line and the marker that makes the post
/// idempotent.
///
/// A reply is model text written after reading hostile text, and a comment
/// notifies people. So no `@` survives (each becomes the full-width form,
/// which GitHub does not read as a mention), no `<` or `>` (so there is no raw
/// HTML), no `#` (so there is no issue reference that would notify another
/// thread), and no control or invisible character that could hide or reorder
/// text. The marker is the host's own line and is appended after the cut.
///
/// ## Examples
///
/// ```gleam
/// assert project_github.reply_body("ping @everyone <b>now</b>", "acknowledge", "<!-- m -->")
///   == "ping ＠everyone ‹b›now‹/b›\n\n<!-- m -->"
/// ```
pub fn reply_body(text: String, purpose: String, marker: String) -> String {
  let safe = neutered(text)
  let limit = reply_words(purpose)
  let kept =
    string.split(safe, "\n")
    |> list.fold(#([], 0), fn(acc, line) {
      let #(lines, used) = acc
      let words = list.filter(string.split(line, " "), fn(w) { w != "" })
      let room = int.max(limit - used, 0)
      #(
        [string.join(list.take(words, room), " "), ..lines],
        used + room_used(words, room),
      )
    })
  let body = string.join(list.reverse(kept.0), "\n") |> string.trim
  body <> "\n\n" <> marker
}

/// How many of a line's words a reply used.
fn room_used(words: List(String), room: Int) -> Int {
  int.min(list.length(words), room)
}

/// A text with every code point that could notify, link, embed HTML or hide
/// text replaced or removed.
fn neutered(text: String) -> String {
  text
  |> string.to_utf_codepoints
  |> list.filter_map(fn(point) {
    let code = string.utf_codepoint_to_int(point)
    case code {
      0x40 -> Ok("\u{ff20}")
      0x3c -> Ok("\u{2039}")
      0x3e -> Ok("\u{203a}")
      0x23 -> Ok("\u{ff03}")
      0x0a -> Ok("\n")
      _ if code < 0x20 || code == 0x7f -> Ok(" ")
      _ if code >= 0x80 && code <= 0x9f -> Ok(" ")
      _ if code >= 0x200b && code <= 0x200f -> Error(Nil)
      _ if code >= 0x2028 && code <= 0x202e -> Error(Nil)
      _ if code >= 0x2060 && code <= 0x206f -> Error(Nil)
      0xfeff -> Error(Nil)
      _ -> Ok(string.from_utf_codepoints([point]))
    }
  })
  |> string.concat
}

// --- check runs and pull requests ---------------------------------------------

/// Reads a check-runs answer and returns the failures completed at or after
/// the cursor. A run is a failure when its conclusion is `failure` or
/// `timed_out`.
///
/// ## Examples
///
/// ```gleam
/// assert project_github.failures("{\"check_runs\":[]}", None) == Ok([])
/// ```
pub fn failures(
  text: String,
  since: Option(String),
) -> Result(List(Failure), String) {
  let decoder = {
    use runs <- decode.field("check_runs", decode.list(decode.dynamic))
    decode.success(runs)
  }
  use runs <- result.map(
    json.parse(text, decoder)
    |> result.replace_error("GitHub answered no check_runs list"),
  )
  runs
  |> list.filter_map(fn(run) {
    decode.run(run, failure_decoder()) |> result.replace_error(Nil)
  })
  |> list.filter(fn(failure) { at_or_after(failure.completed_at, since) })
}

fn failure_decoder() -> decode.Decoder(Failure) {
  use id <- decode.field("id", decode.int)
  use name <- decode.field("name", decode.string)
  use conclusion <- decode.field("conclusion", decode.string)
  use completed_at <- decode.field("completed_at", decode.string)
  use commit <- decode.field("head_sha", decode.string)
  use app <- decode.optional_field(
    "app",
    None,
    decode.optional(decode.at(["slug"], decode.string)),
  )
  let failed = conclusion == "failure" || conclusion == "timed_out"
  let usable = id > 0 && plain_time(completed_at) && plain_hex(commit)

  // A run that passed, or one with fields we cannot trust, is not a failure.
  case failed && usable {
    True ->
      decode.success(Failure(
        id:,
        name: shortened(name),
        completed_at:,
        app: plain_app(option.unwrap(app, "ci")),
        commit:,
      ))
    False ->
      decode.failure(
        Failure(id: 0, name: "", completed_at: "", app: "ci", commit: ""),
        "a failed check run",
      )
  }
}

/// The app's slug when it is a plain login, and `ci` otherwise.
fn plain_app(app: String) -> String {
  case project_sources.plain_login(app, "app") {
    Ok(plain) -> plain
    Error(_) -> "ci"
  }
}

/// A failure as a trigger. `thread` is where the failure belongs: the
/// default branch's own thread, or the thread of the pull request the
/// ticket published.
///
/// ## Examples
///
/// ```gleam
/// // project_github.failure_arrival(ctx, failure, model.github_thread(7), "main")
/// ```
pub fn failure_arrival(
  context: Context,
  failure: Failure,
  thread: model.ThreadId,
  where: String,
) -> Arrival {
  let body =
    "CI failure: check "
    <> failure.name
    <> " failed on "
    <> where
    <> " at commit "
    <> string.slice(failure.commit, 0, 12)
    <> "."
  let matched = project_sources.matching(context.rules, "github", body)
  let generation = result.unwrap(dict.get(context.generations, thread.value), 0)
  let trigger =
    model.Trigger(
      id: model.TriggerId("gh-ci-" <> int.to_string(failure.id)),
      source: model.SourceId("github"),
      thread:,
      actor: ActorId(failure.app),
      inputs: model.Inputs(
        sender: model.CiFailure,
        addressing: Unaddressed,
        rule: option.map(matched, fn(rule) {
          model.RuleMatch(model.RuleId(rule.name), rule.approvals)
        }),
      ),
      generation:,
      at_ms: context.now_ms,
    )
  Arrival(trigger:, bot: ActorId(context.account), body:)
}

/// Reads a pull request's state.
///
/// ## Examples
///
/// ```gleam
/// assert project_github.pull_state("{}") |> result.is_error
/// ```
pub fn pull_state(text: String) -> Result(PullState, String) {
  let decoder = {
    use number <- decode.field("number", decode.int)
    use state <- decode.field("state", decode.string)
    use merged <- decode.optional_field("merged", False, decode.bool)
    use head <- decode.subfield(["head", "sha"], decode.string)
    decode.success(#(number, state, merged, head))
  }
  use #(number, state, merged, head) <- result.try(
    json.parse(text, decoder)
    |> result.replace_error("GitHub answered no pull request"),
  )

  // The words GitHub uses are open and closed, and a closed one merged or not.
  case state, merged, plain_hex(head) {
    "open", _, True -> Ok(PullState(number, StillOpen, head))
    "closed", True, True -> Ok(PullState(number, WasMerged, head))
    "closed", False, True -> Ok(PullState(number, WasClosed, head))
    _, _, _ -> Error("GitHub answered a pull request state we do not read")
  }
}

/// The repository's default branch name, read from its description.
///
/// ## Examples
///
/// ```gleam
/// assert project_github.default_branch("{\"default_branch\":\"main\"}") == Ok("main")
/// ```
pub fn default_branch(text: String) -> Result(String, String) {
  let decoder = {
    use branch <- decode.field("default_branch", decode.string)
    decode.success(branch)
  }
  json.parse(text, decoder)
  |> result.replace_error("GitHub gave no default branch")
  |> result.try(fn(branch) {
    case plain_ref(branch) {
      True -> Ok(branch)
      False -> Error("GitHub gave a default branch we do not use")
    }
  })
}

/// The login the credentials belong to.
///
/// ## Examples
///
/// ```gleam
/// assert project_github.login("{\"login\":\"loom-bot\"}") == Ok("loom-bot")
/// ```
pub fn login(text: String) -> Result(String, String) {
  let decoder = {
    use login <- decode.field("login", decode.string)
    decode.success(login)
  }
  json.parse(text, decoder)
  |> result.replace_error("GitHub did not say who the credentials are")
  |> result.try(project_sources.plain_login(_, "the account"))
}

// --- plain values -------------------------------------------------------------

/// A time in the exact shape `2026-11-02T10:30:00Z`. The shape is what lets
/// two times be compared as text and a time be passed to the API as a
/// parameter, so anything else is refused.
///
/// ## Examples
///
/// ```gleam
/// assert project_github.plain_time("2026-11-02T10:30:00Z")
/// ```
///
/// ```gleam
/// assert !project_github.plain_time("yesterday")
/// ```
pub fn plain_time(text: String) -> Bool {
  let characters = string.to_graphemes(text)
  list.length(characters) == 20
  && list.index_map(characters, fn(character, position) {
    case position {
      4 | 7 -> character == "-"
      10 -> character == "T"
      13 | 16 -> character == ":"
      19 -> character == "Z"
      _ -> string.contains("0123456789", character)
    }
  })
  |> list.all(fn(ok) { ok })
}

fn plain_hex(text: String) -> Bool {
  text != ""
  && string.byte_size(text) <= 64
  && list.all(string.to_graphemes(text), fn(character) {
    string.contains("0123456789abcdefABCDEF", character)
  })
}

fn plain_ref(text: String) -> Bool {
  text != ""
  && string.byte_size(text) <= 100
  && list.all(string.to_graphemes(text), fn(character) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./",
      character,
    )
  })
}
