//// The standing rules, and configuration edits, a model has proposed and a
//// person has yet to decide: the daemon's board, decoded totally, and the words
//// both hosts use for a row (protocol-change/086 and 092).
////
//// A model calls its `propose` tool when it notices a correction worth
//// keeping. The daemon queues the suggestion and writes nothing; a person
//// reads the proposal, sees the exact edit as a diff, and approves or rejects
//// it. This module is the client's half of that exchange. The daemon answers
//// a `proposals_get` read, and a `proposal_decide`, with one board, so a
//// decision costs one round trip and redraws the list from the reply.
////
//// Every string in a board is text a model wrote, and a person is about to
//// turn it into a rule. The words here pass the displayed fields through
//// `text_hygiene`, and a host draws them as text. A row of a kind or state
//// this client does not know is kept and shown as such, so a daemon ahead of
//// this client does not close the lane, but it is never offered an action:
//// only a `Pending` row can change, and only the daemon decides what a
//// decision does.
////
//// The board is a snapshot, not a ledger. It holds the rows the daemon kept
//// within its byte cap, newest first, the count of every row still pending,
//// and how many rows the daemon left out to stay within the cap.

import core/json
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/diff_view
import session_view/text_hygiene

/// The most rows a board carries; the daemon's bound, which is the most it
/// holds pending (64) and the most decided rows it keeps (100). A longer list
/// is cut rather than refused, because a daemon ahead of this client must not
/// be able to close the lane with a board it could not draw.
pub const row_limit = 164

/// The sentence a reviewer is told about what an approval of a rule reaches.
/// Kept for a host that draws the generic sentence; `reach_words` is the one
/// that says the right thing for the row's own kind.
pub const applies_words =
  "A rule applies to new sessions only. A configuration edit reopens each session that loads the file once it is idle."

/// What an approval of this row reaches, in one sentence. A rule binds the
/// sessions opened after it; a configuration edit reopens the sessions that
/// load the file, since a session reads its configuration once at open. A kind
/// this client does not know says only what it can: nothing it can state.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.reach_words(config_row)
///   == "Applies when a session loads loom.toml next; each session that loads it reopens once idle."
/// ```
pub fn reach_words(proposal: Proposal) -> String {
  case proposal.kind {
    Config ->
      "Applies when a session loads "
      <> target_label(proposal.target)
      <> " next; each session that loads it reopens once idle."
    Rule ->
      "Applies to new sessions only. A running session keeps the rules it started with."
    Unrecognized(_) -> applies_words
  }
}

/// The words a host shows when the board holds no rows.
pub const empty_words =
  "No proposals. The agent proposes a rule when it notices a correction worth keeping."

/// The words a host shows while the board has not been read.
pub const loading_words = "Reading proposals..."

/// The words under an approval, which say where the edit lands.
///
/// ## Examples
///
/// ```gleam
/// assert string.starts_with(proposals.approve_words(rule_row), "Approving writes this rule")
/// ```
pub fn approve_words(row: Proposal) -> String {
  case row.kind {
    Config ->
      "Approving writes this edit to "
      <> row.target
      <> " if the result still loads; each session that loads it reopens once idle."
    Rule | Unrecognized(_) ->
      "Approving writes this rule to loom-rules.md, which sessions opened afterwards read. The workspace's AGENTS.md is never edited."
  }
}

/// The proposals the daemon holds.
pub type Board {
  Board(
    /// The rows, newest first.
    proposals: List(Proposal),
    /// How many proposals, of all the daemon holds, are still pending. It
    /// can exceed the rows a board lists.
    pending: Int,
    /// The most proposals that may be pending at once.
    limit: Int,
    /// How many older rows the daemon left out of `proposals` to keep the
    /// board within its byte cap. Zero when the daemon sent none, which is
    /// also what a daemon that predates the field means.
    omitted: Int,
  )
}

/// One proposed edit to the rules file.
pub type Proposal {
  Proposal(
    /// The proposal's identity, `prop-` and ten hexadecimal digits.
    id: String,
    /// What the proposal edits.
    kind: Kind,
    /// The rules file's name for a rule, or the configuration's absolute path
    /// for a configuration edit.
    target: String,
    /// The digest of the target file when the proposal was judged.
    base_digest: String,
    /// Existing rule text to replace. Empty means the proposal appends.
    old: String,
    /// The rule text.
    new: String,
    /// Why, in the model's words.
    rationale: String,
    /// Where the proposal came from.
    source: Source,
    /// When it was proposed, in Unix milliseconds.
    created_ms: Int,
    /// Whether it still waits.
    state: State,
  )
}

/// What a proposal edits.
pub type Kind {
  /// One standing rule in the harness-owned rules file.
  Rule

  /// An edit to the `loom.toml` the proposing session loaded.
  Config

  /// A kind this client does not know, as the daemon named it.
  Unrecognized(kind: String)
}

/// Where in its life a proposal is. Only `Pending` can change.
pub type State {
  /// Waiting for a person.
  Pending

  /// A person approved it and the rules file was written.
  Approved

  /// A person rejected it.
  Rejected

  /// A person approved it, but the rules file had moved, so nothing was
  /// written.
  Stale

  /// A state this client does not know, as the daemon named it.
  Other(state: String)
}

/// The session, and the entry in it, that prompted a proposal.
pub type Source {
  Source(
    /// The proposing session's identity.
    session: String,
    /// The entry that prompted the proposal, when the model named one.
    entry: Option(String),
  )
}

/// What a person decides about a pending proposal.
pub type Decision {
  /// Write the rule.
  Approve

  /// Record the refusal and write nothing.
  Reject
}

/// Decodes the board of a `proposals` snapshot. Total: a malformed board is
/// an error, and a row of an unfamiliar kind or state is not.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.decode(json.Object([])) |> result.is_error
/// ```
pub fn decode(value: json.JsonValue) -> Result(Board, String) {
  use fields <- result.try(object(value, "board"))
  use raw <- result.try(case list.key_find(fields, "proposals") {
    Ok(json.Array(raw)) -> Ok(raw)
    Ok(_) | Error(Nil) -> Error("missing proposals")
  })
  use rows <- result.try(list.try_map(list.take(raw, row_limit), decode_row))
  use pending <- result.try(count(fields, "pending"))
  use limit <- result.try(count(fields, "limit"))
  use omitted <- result.try(case list.key_find(fields, "omitted") {
    Error(Nil) -> Ok(0)
    Ok(json.Int(held)) if held >= 0 -> Ok(held)
    Ok(_) -> Error("invalid omitted count")
  })
  Ok(Board(proposals: rows, pending:, limit:, omitted:))
}

fn decode_row(value: json.JsonValue) -> Result(Proposal, String) {
  use fields <- result.try(object(value, "proposal"))
  use id <- result.try(text(fields, "id"))
  use kind <- result.try(text(fields, "kind"))
  use target <- result.try(text(fields, "target"))
  use base_digest <- result.try(text(fields, "base_digest"))
  use old <- result.try(text_or_empty(fields, "old"))
  use new <- result.try(text_or_empty(fields, "new"))
  use rationale <- result.try(text_or_empty(fields, "rationale"))
  use source <- result.try(decode_source(fields))
  use created_ms <- result.try(case list.key_find(fields, "created_ms") {
    Ok(json.Int(at)) if at >= 0 -> Ok(at)
    _ -> Error("invalid proposal time")
  })
  use state <- result.try(text(fields, "state"))
  Ok(
    Proposal(
      id: text_hygiene.single_line(id),
      kind: case kind {
        "rule" -> Rule
        "config" -> Config
        other -> Unrecognized(text_hygiene.single_line(other))
      },
      target: text_hygiene.single_line(target),
      base_digest: text_hygiene.single_line(base_digest),
      old: text_hygiene.multiline(old),
      new: text_hygiene.multiline(new),
      rationale: text_hygiene.multiline(rationale),
      source:,
      created_ms:,
      state: case state {
        "pending" -> Pending
        "approved" -> Approved
        "rejected" -> Rejected
        "stale" -> Stale
        other -> Other(text_hygiene.single_line(other))
      },
    ),
  )
}

fn decode_source(
  fields: List(#(String, json.JsonValue)),
) -> Result(Source, String) {
  use source <- result.try(case list.key_find(fields, "source") {
    Ok(json.Object(source)) -> Ok(source)
    Ok(_) | Error(Nil) -> Error("missing proposal source")
  })
  use session <- result.try(text(source, "session"))
  let entry = case list.key_find(source, "entry") {
    Ok(json.String(entry)) if entry != "" ->
      Some(text_hygiene.single_line(entry))
    _ -> None
  }
  Ok(Source(session: text_hygiene.single_line(session), entry:))
}

/// Whether a person can still decide the proposal: only a pending row of a
/// kind this client knows can. A row of an unknown kind is shown and never
/// offered an action, because this client cannot say what approving it writes.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.decidable(pending_row)
/// assert !proposals.decidable(stale_row)
/// ```
pub fn decidable(proposal: Proposal) -> Bool {
  case proposal.kind, proposal.state {
    Unrecognized(_), _ -> False
    Rule, Pending | Config, Pending -> True
    _, Approved | _, Rejected | _, Stale | _, Other(_) -> False
  }
}

/// The row with this identity, if the board lists it.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.find(board, "prop-0123456789") == Ok(row)
/// ```
pub fn find(board: Board, id: String) -> Result(Proposal, Nil) {
  list.find(board.proposals, fn(row) { row.id == id })
}

/// The word for a row's state.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.state_words(proposals.Stale) == "stale"
/// ```
pub fn state_words(state: State) -> String {
  case state {
    Pending -> "pending"
    Approved -> "approved"
    Rejected -> "rejected"
    Stale -> "stale"
    Other(state:) -> "unknown (" <> state <> ")"
  }
}

/// The sentence that says what a row's state means for the file it edits,
/// for a row a person can no longer act on.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.settled_words(approved_rule) == "Approved and written to loom-rules.md."
/// ```
pub fn settled_words(row: Proposal) -> String {
  case row.kind, row.state {
    Unrecognized(_), _ ->
      "This client does not know this kind, so it offers no action."
    _, Pending -> "Waiting for a decision."
    _, Approved -> "Approved and written to " <> row.target <> "."
    _, Rejected -> "Rejected. Nothing was written."
    _, Stale ->
      "Stale: "
      <> row.target
      <> " changed after this was proposed, so nothing was written."
    _, Other(_) ->
      "This client does not know this state, so it offers no action."
  }
}

/// The word for what a proposal edits.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.kind_words(proposals.Rule) == "rule"
/// ```
pub fn kind_words(kind: Kind) -> String {
  case kind {
    Rule -> "rule"
    Config -> "setting"
    Unrecognized(kind:) -> "unknown (" <> kind <> ")"
  }
}

/// The first line of a row's rationale, cut to `width` characters with a
/// mark, for a list row. A model that gave no rationale has none to show.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.headline("It failed twice.\nMore.", 40) == "It failed twice."
/// ```
pub fn headline(rationale: String, width: Int) -> String {
  let first = case string.split(string.trim(rationale), "\n") {
    [line, ..] -> string.trim(line)
    [] -> ""
  }
  case first {
    "" -> "(no rationale given)"
    _ ->
      case string.length(first) > width {
        True -> string.slice(first, 0, int.max(0, width - 1)) <> "…"
        False -> first
      }
  }
}

/// The proposing session's identity shortened for a list row, the way a
/// session is shortened elsewhere: its first eight characters.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.short_session("0198c0de-0000-7000") == "0198c0de"
/// ```
pub fn short_session(session: String) -> String {
  string.slice(session, 0, 8)
}

/// How long ago a proposal was made, from the host's own clock. A clock that
/// stepped back reads as just now.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.age(0, 7_300_000) == "2h ago"
/// ```
pub fn age(created_ms: Int, now_ms: Int) -> String {
  let seconds = int.max(0, now_ms - created_ms) / 1000
  case seconds {
    _ if seconds < 60 -> "just now"
    _ if seconds < 3600 -> int.to_string(seconds / 60) <> "m ago"
    _ if seconds < 86_400 -> int.to_string(seconds / 3600) <> "h ago"
    _ -> int.to_string(seconds / 86_400) <> "d ago"
  }
}

/// The edit a proposal makes, as diff lines: the text `old` replaces removed
/// and `new` added. An empty `old` appends, so only added lines show.
///
/// A configuration edit is drawn as the change it is, not as two whole
/// texts: the lines the two texts share around the edit are kept as context
/// and everything else is one removed run followed by one added run. A
/// replaced value and its replacement therefore sit on adjacent rows, which
/// is the thing a reader is deciding. A rule edit shares nothing to recover,
/// because `old` and `new` are different rules rather than two versions of
/// one; there the two runs are simply adjacent, as they always were.
///
/// The line numbers are left blank. The proposal's lines are not positions in
/// the target file, and a number there would claim a place the daemon never
/// named.
///
/// ## Examples
///
/// ```gleam
/// assert list.length(proposals.diff_lines(row)) == 2
/// ```
pub fn diff_lines(proposal: Proposal) -> List(diff_view.Line) {
  edit_lines(proposal.old, proposal.new)
}

/// The edit an `old`/`new` pair makes, as diff lines, for a host that holds
/// the two texts without a queued proposal: the transcript's own row for the
/// `propose` call that asked for one. `diff_lines` is this over a stored row,
/// so a review and the transcript cannot disagree about what the edit is.
///
/// ## Examples
///
/// ```gleam
/// assert list.length(proposals.edit_lines("", "a rule")) == 1
/// ```
pub fn edit_lines(old: String, new: String) -> List(diff_view.Line) {
  case old {
    "" ->
      rows_of(
        diff_view.Added,
        lines_of_text(new) |> list.take(diff_view.max_lines),
      )
    old ->
      diff_view.Line(diff_view.Removed, None, None, old)
      |> pair_lines(diff_view.Line(diff_view.Added, None, None, new))
  }
}

// The two texts as one diff: the lines they share at their head and at their
// tail are context, and what is left between them is one removed run followed
// by one added run.
//
// Only those two shared runs are found, and that is enough. A proposal is a
// few lines changed in a text a person already knows, so what a reader needs
// is the change shown against its surroundings rather than the smallest edit
// script there is. Finding every shared run in the middle as well would cost a
// quadratic scan to redraw a proposal nobody would read differently. A
// whole-file replacement shares nothing and falls out as the removed run and
// the added run, which is what it is.
fn pair_lines(
  removed: diff_view.Line,
  added: diff_view.Line,
) -> List(diff_view.Line) {
  let before = lines_of_text(removed.text)
  let after = lines_of_text(added.text)
  let #(head, before_rest, after_rest) = agreed(before, after, [])

  // The tail is found by running the same walk over both texts reversed, so
  // the lines the edit did not touch stay context on both sides of it and a
  // reader sees the change against its surroundings rather than in isolation.
  // That walk reads its inputs backwards, so both middles come back backwards
  // with them and are reversed here: without this the removed and added runs
  // would each draw bottom to top.
  let #(tail, before_middle, after_middle) =
    agreed(list.reverse(before_rest), list.reverse(after_rest), [])
  let before_middle = list.reverse(before_middle)
  let after_middle = list.reverse(after_middle)

  list.flatten([
    rows_of(diff_view.Context, head),
    rows_of(diff_view.Removed, before_middle),
    rows_of(diff_view.Added, after_middle),
    rows_of(diff_view.Context, tail),
  ])
  |> list.take(diff_view.max_lines)
}

// The lines two texts share from their start, in order, with what each text
// has left once those lines are taken. The accumulator is reversed on the way
// out so the caller reads the lines in the order the texts hold them.
fn agreed(
  before: List(String),
  after: List(String),
  kept: List(String),
) -> #(List(String), List(String), List(String)) {
  case before, after {
    [first, ..before_rest], [second, ..after_rest] if first == second ->
      agreed(before_rest, after_rest, [first, ..kept])
    _, _ -> #(list.reverse(kept), before, after)
  }
}

// A text's lines. The empty text is no line at all rather than one empty line:
// a run drawn from nothing must contribute nothing to the diff or to the count
// beside it.
fn lines_of_text(text: String) -> List(String) {
  case text {
    "" -> []
    _ -> string.split(text, "\n")
  }
}

// One row per line of a run. The lines are already the text's own, so a row
// never splits anything further: the kind decides only how it is drawn.
fn rows_of(kind: diff_view.Kind, lines: List(String)) -> List(diff_view.Line) {
  list.map(lines, fn(line) {
    diff_view.Line(kind:, old: None, new: None, text: line)
  })
}

/// The file an approval would write, named the way a person can read at a
/// glance: the last segment of an absolute path, and the target as it stands
/// for anything else. The complete path is still the row's `target`, which a
/// host may draw in full where it has the room.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.target_label("/home/me/.loom/loom.toml") == "loom.toml"
/// assert proposals.target_label("loom-rules.md") == "loom-rules.md"
/// ```
pub fn target_label(target: String) -> String {
  case
    string.split(target, "/")
    |> list.reverse
    |> list.find(fn(segment) { segment != "" })
  {
    Ok(name) -> name
    Error(Nil) -> target
  }
}

/// How many lines an approval would remove and add, as `+2 -1`, for a host to
/// draw beside the edit. A count of the diff lines rather than of the two
/// texts: the shared lines stay context, so they are counted as neither.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.change_counts(replacing) == "+1 -1"
/// ```
pub fn change_counts(proposal: Proposal) -> String {
  edit_counts(proposal.old, proposal.new)
}

/// The same count over two texts a host holds without a queued proposal, so
/// the transcript's row for the `propose` call that asked for the edit says
/// the same number the review does.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.edit_counts("a", "b") == "+1 -1"
/// ```
pub fn edit_counts(old: String, new: String) -> String {
  let counts =
    list.fold(edit_lines(old, new), #(0, 0), fn(total, line) {
      case line.kind {
        diff_view.Removed -> #(total.0, total.1 + 1)
        diff_view.Added -> #(total.0 + 1, total.1)
        _ -> total
      }
    })
  case counts {
    #(0, 0) -> "no change"
    #(0, removed) -> "-" <> int.to_string(removed)
    #(added, 0) -> "+" <> int.to_string(added)
    #(added, removed) ->
      "+" <> int.to_string(added) <> " -" <> int.to_string(removed)
  }
}

/// The edit as the text a host renders when it draws diffs from text rather
/// than from `diff_view.Line`s: one row per line, prefixed with the sign its
/// kind carries, and with a space for a line both texts share.
///
/// The transcript's patch renderer, which already draws an edit's own diff,
/// takes this; the review's scrollable detail takes `diff_lines` and colours
/// the rows itself. Both therefore show the same lines in the same order.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.diff_text("a", "b") == "-a\n+b"
/// ```
pub fn diff_text(old: String, new: String) -> String {
  edit_lines(old, new)
  |> list.map(fn(line) {
    case line.kind {
      diff_view.Removed -> "-" <> line.text
      diff_view.Added -> "+" <> line.text
      _ -> " " <> line.text
    }
  })
  |> string.join("\n")
}

/// The wire word for a decision.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.decision_word(proposals.Approve) == "approve"
/// ```
pub fn decision_word(decision: Decision) -> String {
  case decision {
    Approve -> "approve"
    Reject -> "reject"
  }
}

/// One line for a heading: how many proposals wait.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.summary(1) == "1 proposal pending"
/// ```
pub fn summary(pending: Int) -> String {
  case pending {
    0 -> "No proposals pending"
    1 -> "1 proposal pending"
    n -> int.to_string(n) <> " proposals pending"
  }
}

/// The line a host draws under the rows when the daemon left some out, or
/// nothing when it did not.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.omitted_words(3) == Some("3 older proposals not shown")
/// assert proposals.omitted_words(0) == None
/// ```
pub fn omitted_words(omitted: Int) -> Option(String) {
  case omitted {
    0 -> None
    1 -> Some("1 older proposal not shown")
    n if n > 1 -> Some(int.to_string(n) <> " older proposals not shown")
    _ -> None
  }
}

/// The pending count a badge shows, or nothing when none wait. A badge is a
/// reminder, so a host draws it only when there is something to review.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.badge(None) == None
/// ```
pub fn badge(board: Option(Board)) -> Option(Int) {
  case board {
    Some(Board(pending:, ..)) if pending > 0 -> Some(pending)
    Some(_) | None -> None
  }
}

/// The words for a command the daemon refused, by its error code. A code this
/// client does not know is shown with the daemon's own message.
///
/// ## Examples
///
/// ```gleam
/// assert proposals.refusal_words("forbidden", "") == "Only the daemon's owner can review proposals."
/// ```
pub fn refusal_words(code: String, message: String) -> String {
  case code {
    "forbidden" -> "Only the daemon's owner can review proposals."
    "unsupported" -> "This daemon keeps no proposal queue."
    "conflict" ->
      "That proposal was already decided, so nothing changed. The list has been read again."
    "bad_request" ->
      "That proposal no longer exists. The list has been read again."
    "internal" ->
      "The rules file could not be read or written. The proposal stays pending."
    _ -> code <> ": " <> text_hygiene.single_line(message)
  }
}

fn object(
  value: json.JsonValue,
  what: String,
) -> Result(List(#(String, json.JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("expected a proposals " <> what <> " object")
  }
}

fn text(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Result(String, String) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) if value != "" -> Ok(value)
    _ -> Error("missing proposal text: " <> name)
  }
}

fn text_or_empty(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Result(String, String) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    _ -> Error("missing proposal text: " <> name)
  }
}

fn count(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Result(Int, String) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) if value >= 0 -> Ok(value)
    _ -> Error("invalid proposals count: " <> name)
  }
}
