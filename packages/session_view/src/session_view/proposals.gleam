//// The standing rules, and configuration edits, a model has proposed and a
//// person has yet to decide: the daemon's board, decoded totally, and the words
//// both hosts use for a row (protocol-change/086 and 089).
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

/// The sentence a reviewer is told about what an approval reaches.
pub const applies_words =
  "A rule applies to new sessions only. A configuration edit reopens each session that loads the file once it is idle."

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

/// The edit a proposal makes, as diff lines: the replaced text removed and
/// the new text added. An empty `old` appends, so only added lines show.
///
/// The line numbers are left blank. The proposal's lines are not positions in
/// the rules file, and a number there would claim a place the daemon never
/// named.
///
/// ## Examples
///
/// ```gleam
/// assert list.length(proposals.diff_lines(row)) == 2
/// ```
pub fn diff_lines(proposal: Proposal) -> List(diff_view.Line) {
  let removed = case proposal.old {
    "" -> []
    old -> lines_of(diff_view.Removed, old)
  }
  list.append(removed, lines_of(diff_view.Added, proposal.new))
}

fn lines_of(kind: diff_view.Kind, text: String) -> List(diff_view.Line) {
  string.split(text, "\n")
  |> list.take(diff_view.max_lines)
  |> list.map(fn(line) {
    diff_view.Line(kind:, old: None, new: None, text: line)
  })
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
