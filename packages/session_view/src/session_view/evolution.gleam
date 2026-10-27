//// The governed-evolution board and the words both hosts draw for it
//// (protocol-change/099).
////
//// A session can propose an extension, a program or a prompt, test it, and
//// have a person approve it and select it as the generation a session runs.
//// The daemon answers an `evolution` command with one JSON value. This module
//// is the client's half of that exchange: the total decoder for the `board`
//// reply, the encoding of every request a person can make, the decoder for
//// what a request answers, and the words the web view and the terminal share
//// for a row, so both draw the same candidate in the same words.
////
//// Every string in a board comes from a model or from a catalogue it wrote.
//// The words here pass the displayed fields through `text_hygiene`, and a host
//// draws them as text. A row of a kind, scope, purpose, verdict, phase or
//// event this client does not know is kept and shown as such, so a daemon
//// ahead of this client does not close the lane, but a row this client cannot
//// name is never offered an action, since the daemon decides what an action
//// does and the UI only offers what it can describe.
////
//// A row that cannot be read at all is left out and counted in
//// `Board.unread`. The reader is then told the board is not the whole of what
//// the daemon sent, and an action is never offered on a candidate whose
//// approval or evidence this client failed to decode: a missing approval read
//// as "not approved" would invite a second approval.
////
//// ## Flow
////
//// `decode_board` reads the envelope and hands each row to `decode_candidate`,
//// `decode_selection`, `decode_waiting` or `decode_event`. `read` is the entry
//// for a reply: it names the action the reply answers, because every action
//// shares one wire command, and returns a `Reply` that is never an error.
//// `arguments` is the encoder for a `Request`. The functions after them are
//// words and offers, and the board queries a host draws from.
////
//// The public surface a host uses is `decode_board`, `read`, `arguments`,
//// `action_word`, `refusal_words`, the `*_words` functions, `approval_target`,
//// `selection_target`, `rollback_choices`, `awaiting_approval` and `find`.
//// The staging of a queued selection is `session_view/evolution_pending`.

import core/json
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/text_hygiene

/// The most candidates a board is read for. The daemon sends at most 128, so
/// twice that bound is a daemon ahead of this client being cut, not refused.
pub const candidate_limit = 256

/// The most audit rows a board is read for; the daemon sends at most 64.
pub const history_limit = 128

/// The most selections, and the most waiting transitions, a board is read for.
pub const row_limit = 256

/// The most evidence rows one candidate is read for.
pub const evidence_limit = 256

/// The words a host shows while the board has not been read.
pub const loading_words = "Reading the evolution board..."

/// The words a host shows when the board holds no candidates.
pub const empty_words =
  "No candidates yet. A session proposes one when it writes an extension, a program or a prompt."

/// The sentence a host shows where core upgrades would be offered. A page
/// cannot submit them (protocol-change/099, ruling 2).
pub const core_words =
  "Core upgrades run from the terminal: loom evolution core_upgrade."

/// The evolution catalogue and the session's own selections.
pub type Board {
  Board(
    /// The wire version of the board's shape; zero when the daemon sent none.
    version: Int,
    /// The session the board describes.
    session: String,
    /// The candidates this reader may see, in the daemon's order.
    candidates: List(Candidate),
    /// The selections of the candidates the board shows.
    selections: List(Selection),
    /// The generation the session runs, or `None` when none is published.
    published: Option(Generation),
    /// The selections the daemon accepted and has not finished.
    pending: List(Waiting),
    /// The newest audit entries, newest first.
    history: List(Event),
    /// How many candidates the daemon left out to stay within its byte bound.
    omitted_candidates: Int,
    /// How many audit entries the daemon left out.
    omitted_history: Int,
    /// How many rows this client could not read or held over its own bound.
    /// Zero for a board it read in full.
    unread: Int,
  )
}

/// One immutable candidate and what has been decided about it.
pub type Candidate {
  Candidate(
    /// The content address of the candidate.
    candidate_id: String,
    /// The name the candidate would run under.
    name: String,
    /// What the candidate is.
    kind: Kind,
    /// Where a selection of it applies.
    scope: Scope,
    /// What the candidate does, in its author's words.
    description: String,
    /// The candidate this one was proposed from, if any.
    parent: Option(String),
    /// The session and strand that proposed it.
    origin: Origin,
    /// Whether the evaluator that tested it is the one the host runs now.
    identity: Freshness,
    /// The approval, when a person gave one.
    approval: Option(Approval),
    /// The evidence retained for it, newest first.
    evidence: List(Evidence),
    /// The selection of this exact candidate, when it is the selected one.
    selected: Option(Chosen),
  )
}

/// What a candidate is.
pub type Kind {
  /// A tool the session loads.
  Extension

  /// A program a workspace runs.
  Program

  /// A model prompt.
  Prompt

  /// A kind this client does not know, as the daemon named it.
  UnknownKind(kind: String)
}

/// Where a selection of a candidate applies.
pub type Scope {
  /// One session.
  SessionScope(session: String)

  /// Every session in one workspace, named as the daemon names it (a path, or
  /// `executor:node/workspace` for a remote one).
  WorkspaceScope(workspace: String)

  /// One exact model.
  ModelScope(provider: String, model: String, api: String)

  /// A scope this client does not know, as the daemon named its kind.
  UnknownScope(kind: String)
}

/// Where a candidate came from.
pub type Origin {
  Origin(
    /// The session that proposed it.
    session: String,
    /// The strand that proposed it.
    strand: String,
  )
}

/// Whether what a row recorded was recorded under the evaluator identity the
/// host runs now. A stale one is shown and not offered a selection.
pub type Freshness {
  /// The identity matches the host's.
  Current

  /// The identity differs from the host's.
  Outdated
}

/// A person's approval of a candidate.
pub type Approval {
  Approval(
    /// The evidence the approval rests on.
    evidence_id: String,
    /// The principal who approved.
    by: String,
    /// The surface it came from.
    via: Surface,
  )
}

/// Where a decision was made, as the daemon recorded it.
pub type Surface {
  /// The command line.
  Cli

  /// A browser page.
  Web

  /// The terminal.
  Terminal

  /// An entry written before surfaces were recorded.
  Unrecorded

  /// A surface this client does not know.
  OtherSurface(surface: String)
}

/// One retained observation of a candidate.
pub type Evidence {
  Evidence(
    /// The content address of the observation.
    evidence_id: String,
    /// Why it was made.
    purpose: Purpose,
    /// What it found.
    verdict: Verdict,
    /// The reason an inconclusive verdict gave, or empty.
    reason: String,
    /// When it was made, in Unix milliseconds on the daemon's clock.
    at_ms: Int,
    /// Whether it was made under the evaluator identity the host runs now.
    identity: Freshness,
  )
}

/// Why an observation was made.
pub type Purpose {
  /// The candidate's own tests.
  AuthorTests

  /// A rollout the author did not write.
  IndependentRollout

  /// A purpose this client does not know.
  UnknownPurpose(purpose: String)
}

/// What an observation found.
pub type Verdict {
  /// The checks passed.
  Passed

  /// The checks failed.
  Failed

  /// The checks could not decide; `Evidence.reason` says why.
  Inconclusive

  /// A verdict this client does not know.
  UnknownVerdict(verdict: String)
}

/// The selection of one exact candidate, as its row carries it.
pub type Chosen {
  Chosen(
    /// The generation the selection made.
    generation: Int,
    /// The evidence the selection rests on.
    evidence_id: String,
  )
}

/// The selected candidate for one scope and name.
pub type Selection {
  Selection(
    /// Where the selection applies.
    scope: Scope,
    /// The name it selects under.
    name: String,
    /// The selected candidate.
    candidate_id: String,
    /// The evidence the selection rests on.
    evidence_id: String,
    /// The selection's generation.
    generation: Int,
    /// Whether the session runs this generation now.
    liveness: Liveness,
  )
}

/// Whether a selected generation is the one the session runs.
pub type Liveness {
  /// The session runs it.
  Live

  /// It is selected and not running here.
  NotLive
}

/// The generation the session runs.
pub type Generation {
  Generation(
    /// The candidate it implements.
    candidate_id: String,
    /// The name it runs under.
    name: String,
    /// Its generation.
    generation: Int,
    /// The native helper census of its plane, untouched, or `Null`.
    inventory: json.JsonValue,
  )
}

/// A selection the daemon accepted and has not finished.
pub type Waiting {
  Waiting(
    /// The request identity the selection was submitted under.
    request_id: String,
    /// How far the daemon has taken it.
    phase: Phase,
    /// The candidate being selected.
    candidate_id: String,
    /// When the daemon stops waiting for it, in Unix milliseconds on the
    /// daemon's clock. A host never subtracts it from its own clock.
    expires_at_ms: Int,
  )
}

/// How far the daemon has taken an accepted selection.
pub type Phase {
  /// Accepted and waiting its turn.
  Queued

  /// Being staged and published now.
  Running

  /// A phase this client does not know.
  UnknownPhase(phase: String)
}

/// One decision in the audit journal.
pub type Event {
  Event(
    /// The entry's place in the journal.
    seq: Int,
    /// When it was written, in Unix milliseconds on the daemon's clock.
    at_ms: Int,
    /// What was decided.
    decision: Decision,
    /// The candidate it concerned.
    candidate_id: String,
    /// The name the candidate runs under.
    name: String,
    /// The generation a selection made, or `None`.
    generation: Option(Int),
    /// Who decided, or empty for an entry that named no one.
    principal: String,
    /// Where it was decided.
    via: Surface,
    /// The reason given, or empty.
    reason: String,
    /// The request identity of a selection, or empty.
    request_id: String,
  )
}

/// What an audit entry records.
pub type Decision {
  /// A candidate was approved.
  Approved

  /// An approval was revoked.
  Revoked

  /// A candidate was selected, or an earlier one selected again.
  Selected

  /// A decision this client does not know.
  UnknownDecision(decision: String)
}

/// A change a person asks for, or a read of one item.
///
/// A host builds one from the board it drew and hands it to the lane. A
/// `Select` and a `Rollback` carry the generation the host drew, so a board
/// that has since moved is refused by the daemon ("selection changed") rather
/// than selected over: the two-press-with-echo rule the approval card follows.
pub type Request {
  /// Approve a candidate on one piece of its evidence.
  Approve(candidate_id: String, evidence_id: String)

  /// Withdraw an approval.
  Revoke(candidate_id: String, reason: String)

  /// Select a candidate as the next generation of its name.
  Select(
    /// The candidate to select.
    candidate_id: String,
    /// Its name, for the words a host draws while it stages.
    name: String,
    /// The evidence the approval rests on.
    evidence_id: String,
    /// The generation the host drew as current, zero for none.
    expected_generation: Int,
    /// Why, in the person's words or the host's fixed sentence.
    reason: String,
  )

  /// Select an earlier approved candidate again.
  Rollback(
    /// The earlier candidate.
    candidate_id: String,
    /// Its name.
    name: String,
    /// The evidence its approval rests on.
    evidence_id: String,
    /// The generation the host drew as current.
    expected_generation: Int,
    /// Why.
    reason: String,
  )

  /// Read one candidate's envelope, first page only.
  Inspect(candidate_id: String)

  /// Read one evidence envelope, first page only.
  ReadEvidence(evidence_id: String)

  /// Read the session's core component status.
  CoreStatus
}

/// What a terminal says about itself in an audit entry. A page is known by the
/// daemon and says nothing (protocol-change/099).
pub type Via {
  /// No claim; the daemon records `cli` for a bearer and `web` for a page.
  Unclaimed

  /// The attachment is the terminal.
  ClaimsTerminal
}

/// What the daemon says about a selection, from the reply to `select` or
/// `rollback` or from a `status` poll.
pub type Report {
  /// Accepted and not finished.
  InFlight(phase: Phase)

  /// Committed and live. The generation is the committed selection's, when the
  /// reply named one.
  Done(generation: Option(Int))

  /// Committed and durable, with the generation not published yet.
  DurableOnly(generation: Option(Int))

  /// The selection failed, for this reason.
  Rejected(reason: String)

  /// The daemon holds no record of the request.
  Forgotten
}

/// A page of an inspected envelope.
pub type Page {
  /// The whole envelope, since it fit in one frame.
  Whole(value: json.JsonValue)

  /// An envelope too large for one frame. A host says to use the command
  /// line and never reassembles the fragments.
  Large(total_bytes: Int)
}

/// A page a reader opened: the action that asked for it and what came back.
pub type Opened {
  Opened(
    /// The action that asked: `inspect`, `evidence` or `core_status`.
    action: String,
    /// The first page of what the daemon answered.
    page: Page,
  )
}

/// How long a watched board may go unread before the lane reads it again,
/// in milliseconds. The push announces most changes; a generation that
/// publishes late and a session restart are announced to nobody.
pub const backstop_ms = 60_000

/// What an `evolution` command answered. Never an error: a reply this client
/// cannot read is `Unreadable`, so the lane stays open.
pub type Reply {
  /// The board.
  BoardReply(board: Board)

  /// A selection's report, from `select`, `rollback` or `status`.
  ProgressReply(report: Report)

  /// A candidate was approved.
  ApprovalReply(candidate_id: String)

  /// An approval was revoked.
  RevocationReply(candidate_id: String)

  /// One inspected envelope, an evidence envelope or the core status.
  PageReply(page: Page)

  /// The daemon answered in a shape this client could not read.
  Unreadable(reason: String)
}

// --- the board's decoder ----------------------------------------------------

/// Decodes a `board` reply. Total over its rows: a row that cannot be read is
/// left out and counted in `unread`. Only a body that is not an object is an
/// error.
///
/// ## Examples
///
/// ```gleam
/// assert evolution.decode_board(json.Object([])) |> result.is_ok
/// assert evolution.decode_board(json.Null) |> result.is_error
/// ```
pub fn decode_board(value: json.JsonValue) -> Result(Board, String) {
  // Ensure the top-level board payload is a JSON object.
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("the evolution board is not an object")
  })

  let #(candidates, bad_candidates) =
    rows(fields, "candidates", candidate_limit, decode_candidate)
  let #(selections, bad_selections) =
    rows(fields, "selections", row_limit, decode_selection)
  let #(pending, bad_pending) =
    rows(fields, "pending", row_limit, decode_waiting)
  let #(history, bad_history) =
    rows(fields, "history", history_limit, decode_event)

  // Decode the published generation if present in the board fields.
  let #(published, bad_published) = case list.key_find(fields, "published") {
    Ok(json.Object(generation)) ->
      case decode_generation(generation) {
        Ok(one) -> #(Some(one), 0)
        Error(_) -> #(None, 1)
      }
    Ok(json.Null) | Error(Nil) -> #(None, 0)
    Ok(_) -> #(None, 1)
  }

  // Extract omitted row counts when recorded.
  let omitted = case list.key_find(fields, "omitted") {
    Ok(json.Object(counts)) -> counts
    _ -> []
  }

  // Construct the decoded evolution board with aggregated unread totals.
  Ok(Board(
    version: int_or(fields, "version", 0),
    session: text_or(fields, "session", ""),
    candidates:,
    selections:,
    published:,
    pending:,
    history:,
    omitted_candidates: int_or(omitted, "candidates", 0),
    omitted_history: int_or(omitted, "history", 0),
    unread: bad_candidates
      + bad_selections
      + bad_pending
      + bad_history
      + bad_published,
  ))
}

/// Reads one array of rows. A missing array is an empty one, a row that does
/// not decode is counted, and the rows past the client's own bound are counted
/// too, so `unread` says how much of the reply the host is not drawing.
fn rows(
  fields: Fields,
  key: String,
  limit: Int,
  decode: fn(json.JsonValue) -> Result(a, String),
) -> #(List(a), Int) {
  // Extract array rows under key up to limit.
  case list.key_find(fields, key) {
    Ok(json.Array(items)) -> {
      let kept = list.take(items, limit)
      let decoded = list.map(kept, decode)
      let good = list.filter_map(decoded, fn(row) { row })
      #(good, list.length(items) - list.length(good))
    }
    Ok(json.Null) | Error(Nil) -> #([], 0)
    Ok(_) -> #([], 1)
  }
}

type Fields =
  List(#(String, json.JsonValue))

/// Decodes a candidate record from a JSON value.
fn decode_candidate(value: json.JsonValue) -> Result(Candidate, String) {
  use fields <- result.try(object(value))
  use candidate_id <- result.try(required_text(fields, "candidate_id"))
  use name <- result.try(required_text(fields, "name"))
  use kind <- result.try(required_text(fields, "kind"))
  use scope_fields <- result.try(required_object(fields, "scope"))
  use scope <- result.try(decode_scope(scope_fields))
  use identity <- result.try(freshness(fields, "identity_current"))

  // A nested row that fails to decode fails the candidate. Dropping an
  // approval or a piece of evidence would draw a different candidate from the
  // one the daemon sent, and the difference is the one a person acts on.
  use approval <- result.try(optional_row(fields, "approval", decode_approval))
  use chosen <- result.try(optional_row(fields, "selected", decode_chosen))
  use evidence <- result.try(evidence_rows(fields))

  // Extract optional candidate parent string if present.
  use parent <- result.try(case list.key_find(fields, "parent") {
    Ok(json.String(parent)) if parent != "" ->
      Ok(Some(text_hygiene.single_line(parent)))
    Ok(json.Null) | Ok(json.String(_)) | Error(Nil) -> Ok(None)
    Ok(_) -> Error("invalid candidate parent")
  })

  Ok(Candidate(
    candidate_id:,
    name:,
    kind: case kind {
      "extension" -> Extension
      "program" -> Program
      "prompt" -> Prompt
      other -> UnknownKind(other)
    },
    scope:,
    description: case list.key_find(fields, "description") {
      Ok(json.String(description)) -> text_hygiene.multiline(description)
      _ -> ""
    },
    parent:,
    origin: case list.key_find(fields, "origin") {
      Ok(json.Object(origin)) ->
        Origin(
          session: text_or(origin, "session", ""),
          strand: text_or(origin, "strand", ""),
        )
      _ -> Origin(session: "", strand: "")
    },
    identity:,
    approval:,
    evidence:,
    selected: chosen,
  ))
}

/// Decodes candidate evidence entries up to evidence_limit.
fn evidence_rows(fields: Fields) -> Result(List(Evidence), String) {
  case list.key_find(fields, "evidence") {
    Ok(json.Array(items)) ->
      list.take(items, evidence_limit) |> list.try_map(decode_evidence)
    Ok(json.Null) | Error(Nil) -> Ok([])
    Ok(_) -> Error("invalid candidate evidence")
  }
}

/// Decodes candidate scope from its fields dictionary.
fn decode_scope(fields: Fields) -> Result(Scope, String) {
  use kind <- result.try(required_text(fields, "kind"))

  // Decode scope variant based on the kind field.
  case kind {
    "session" -> {
      use session <- result.try(required_text(fields, "session"))
      Ok(SessionScope(session))
    }
    "workspace" -> {
      use workspace <- result.try(required_text(fields, "workspace"))
      Ok(WorkspaceScope(workspace))
    }
    "model" -> {
      use provider <- result.try(required_text(fields, "provider"))
      use model <- result.try(required_text(fields, "model"))
      Ok(ModelScope(provider:, model:, api: text_or(fields, "api", "")))
    }
    other -> Ok(UnknownScope(other))
  }
}

/// Decodes approval record from candidate fields dictionary.
fn decode_approval(fields: Fields) -> Result(Approval, String) {
  use evidence_id <- result.try(required_text(fields, "evidence_id"))
  Ok(Approval(
    evidence_id:,
    by: text_or(fields, "by", ""),
    via: surface(text_or(fields, "via", "")),
  ))
}

fn decode_chosen(fields: Fields) -> Result(Chosen, String) {
  use generation <- result.try(required_int(fields, "generation"))
  use evidence_id <- result.try(required_text(fields, "evidence_id"))
  Ok(Chosen(generation:, evidence_id:))
}

/// Decodes an evidence record from a JSON value.
fn decode_evidence(value: json.JsonValue) -> Result(Evidence, String) {
  use fields <- result.try(object(value))
  use evidence_id <- result.try(required_text(fields, "evidence_id"))
  use purpose <- result.try(required_text(fields, "purpose"))
  use verdict <- result.try(required_text(fields, "verdict"))
  use identity <- result.try(freshness(fields, "identity_current"))
  Ok(Evidence(
    evidence_id:,
    purpose: case purpose {
      "author_tests" -> AuthorTests
      "independent_rollout" -> IndependentRollout
      other -> UnknownPurpose(other)
    },
    verdict: case verdict {
      "passed" -> Passed
      "failed" -> Failed
      "inconclusive" -> Inconclusive
      other -> UnknownVerdict(other)
    },
    reason: text_or(fields, "reason", ""),
    at_ms: int_or(fields, "at_ms", 0),
    identity:,
  ))
}

/// Decodes a selection entry from its JSON representation.
fn decode_selection(value: json.JsonValue) -> Result(Selection, String) {
  use fields <- result.try(object(value))
  use scope_fields <- result.try(required_object(fields, "scope"))
  use scope <- result.try(decode_scope(scope_fields))
  use name <- result.try(required_text(fields, "name"))
  use candidate_id <- result.try(required_text(fields, "candidate_id"))
  use evidence_id <- result.try(required_text(fields, "evidence_id"))
  use generation <- result.try(required_int(fields, "generation"))
  Ok(
    Selection(
      scope:,
      name:,
      candidate_id:,
      evidence_id:,
      generation:,
      liveness: case list.key_find(fields, "published") {
        Ok(json.Bool(True)) -> Live
        _ -> NotLive
      },
    ),
  )
}

/// Decodes the published generation record from board fields.
fn decode_generation(fields: Fields) -> Result(Generation, String) {
  use candidate_id <- result.try(required_text(fields, "candidate_id"))
  use name <- result.try(required_text(fields, "name"))
  use generation <- result.try(required_int(fields, "generation"))
  Ok(Generation(
    candidate_id:,
    name:,
    generation:,
    inventory: result.unwrap(list.key_find(fields, "inventory"), json.Null),
  ))
}

/// Decodes an in-flight waiting selection from a JSON value.
fn decode_waiting(value: json.JsonValue) -> Result(Waiting, String) {
  use fields <- result.try(object(value))
  use request_id <- result.try(required_text(fields, "request_id"))
  use phase <- result.try(required_text(fields, "state"))
  use candidate_id <- result.try(required_text(fields, "candidate_id"))
  Ok(Waiting(
    request_id:,
    phase: phase_of(phase),
    candidate_id:,
    expires_at_ms: int_or(fields, "expires_at_ms", 0),
  ))
}

/// Maps a raw phase state string to a Phase variant.
fn phase_of(state: String) -> Phase {
  case state {
    "queued" -> Queued
    "running" -> Running
    other -> UnknownPhase(text_hygiene.single_line(other))
  }
}

/// Decodes a history audit event from a JSON value.
fn decode_event(value: json.JsonValue) -> Result(Event, String) {
  use fields <- result.try(object(value))
  use seq <- result.try(required_int(fields, "seq"))
  use decision <- result.try(required_text(fields, "event"))

  // The daemon writes an empty candidate for an audit entry whose text did not
  // parse, on purpose, so an empty one is a row to draw and not a malformed one.
  let candidate_id = text_or(fields, "candidate_id", "")
  Ok(Event(
    seq:,
    at_ms: int_or(fields, "at_ms", 0),
    decision: case decision {
      "approved" -> Approved
      "revoked" -> Revoked
      "selected" -> Selected
      other -> UnknownDecision(other)
    },
    candidate_id:,
    name: text_or(fields, "name", ""),
    generation: case list.key_find(fields, "generation") {
      Ok(json.Int(generation)) -> Some(generation)
      _ -> None
    },
    principal: text_or(fields, "principal", ""),
    via: surface(text_or(fields, "via", "")),
    reason: text_or(fields, "reason", ""),
    request_id: text_or(fields, "request_id", ""),
  ))
}

/// Maps an audit surface string to a typed Surface variant.
fn surface(word: String) -> Surface {
  case word {
    "cli" -> Cli
    "web" -> Web
    "terminal" -> Terminal
    "" -> Unrecorded
    other -> OtherSurface(other)
  }
}

// --- field readers ----------------------------------------------------------

fn object(value: json.JsonValue) -> Result(Fields, String) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("an evolution row is not an object")
  }
}

fn required_text(fields: Fields, key: String) -> Result(String, String) {
  case list.key_find(fields, key) {
    Ok(json.String(value)) if value != "" -> Ok(text_hygiene.single_line(value))
    _ -> Error("missing evolution field: " <> key)
  }
}

fn required_int(fields: Fields, key: String) -> Result(Int, String) {
  case list.key_find(fields, key) {
    Ok(json.Int(value)) -> Ok(value)
    _ -> Error("missing evolution number: " <> key)
  }
}

fn required_object(fields: Fields, key: String) -> Result(Fields, String) {
  case list.key_find(fields, key) {
    Ok(json.Object(value)) -> Ok(value)
    _ -> Error("missing evolution object: " <> key)
  }
}

fn text_or(fields: Fields, key: String, default: String) -> String {
  case list.key_find(fields, key) {
    Ok(json.String(value)) -> text_hygiene.single_line(value)
    _ -> default
  }
}

fn int_or(fields: Fields, key: String, default: Int) -> Int {
  case list.key_find(fields, key) {
    Ok(json.Int(value)) if value >= 0 -> value
    _ -> default
  }
}

/// Reads a boolean freshness flag into Current or Outdated.
fn freshness(fields: Fields, key: String) -> Result(Freshness, String) {
  case list.key_find(fields, key) {
    Ok(json.Bool(True)) -> Ok(Current)
    Ok(json.Bool(False)) -> Ok(Outdated)
    _ -> Error("missing evolution flag: " <> key)
  }
}

/// An optional nested object. Absent and null are `None`; present and
/// unreadable is an error, which fails the row that holds it.
fn optional_row(
  fields: Fields,
  key: String,
  decode: fn(Fields) -> Result(a, String),
) -> Result(Option(a), String) {
  case list.key_find(fields, key) {
    Ok(json.Object(inner)) -> result.map(decode(inner), Some)
    Ok(json.Null) | Error(Nil) -> Ok(None)
    Ok(_) -> Error("invalid evolution field: " <> key)
  }
}

// --- requests ---------------------------------------------------------------

/// Whether an action is one the lane issues. The channel names an evolution
/// request by its action and a recording replays it by that name, so both
/// accept exactly these nine.
///
/// ## Examples
///
/// ```gleam
/// assert evolution.is_action("board")
/// assert !evolution.is_action("core_upgrade")
/// ```
pub fn is_action(action: String) -> Bool {
  is_read_action(action)
  || case action {
    "approve" | "revoke" | "select" | "rollback" -> True
    _ -> False
  }
}

/// Whether an action only reads. A read may be refused without retrying it and
/// is sent by a host on its own account; every other action is a change whose
/// lost reply is an unknown outcome, never a reason to send it again.
///
/// ## Examples
///
/// ```gleam
/// assert evolution.is_read_action("status")
/// assert !evolution.is_read_action("select")
/// ```
pub fn is_read_action(action: String) -> Bool {
  case action {
    "board" | "status" | "inspect" | "evidence" | "core_status" -> True
    _ -> False
  }
}

/// The wire action a request is sent as.
///
/// ## Examples
///
/// ```gleam
/// assert evolution.action_word(evolution.CoreStatus) == "core_status"
/// ```
pub fn action_word(request: Request) -> String {
  case request {
    Approve(..) -> "approve"
    Revoke(..) -> "revoke"
    Select(..) -> "select"
    Rollback(..) -> "rollback"
    Inspect(..) -> "inspect"
    ReadEvidence(..) -> "evidence"
    CoreStatus -> "core_status"
  }
}

/// The `arguments` object of a request. A `Select` and a `Rollback` carry the
/// `request_id` the lane minted and the deadline it keeps, so the daemon
/// waits exactly as long as the lane polls. Every other request ignores them.
/// A terminal's `via` claim goes only with the four changes, because only they
/// write an audit entry, so only they have a use for it.
///
/// ## Examples
///
/// ```gleam
/// let args = evolution.arguments(evolution.Inspect("3f9a"), evolution.Unclaimed, "", 0)
/// assert args == json.Object([#("candidate_id", json.String("3f9a"))])
/// ```
pub fn arguments(
  request: Request,
  via: Via,
  request_id: String,
  deadline_ms: Int,
) -> json.JsonValue {
  // Build argument fields corresponding to the specific request variant.
  let fields = case request {
    Approve(candidate_id:, evidence_id:) -> [
      #("candidate_id", json.String(candidate_id)),
      #("evidence_id", json.String(evidence_id)),
    ]
    Revoke(candidate_id:, reason:) -> [
      #("candidate_id", json.String(candidate_id)),
      #("reason", json.String(reason)),
    ]
    Select(candidate_id:, evidence_id:, expected_generation:, reason:, ..)
    | Rollback(candidate_id:, evidence_id:, expected_generation:, reason:, ..) -> [
      #("candidate_id", json.String(candidate_id)),
      #("evidence_id", json.String(evidence_id)),
      #("expected_generation", json.Int(expected_generation)),
      #("reason", json.String(reason)),
      #("request_id", json.String(request_id)),
      #("deadline_ms", json.Int(deadline_ms)),
    ]
    Inspect(candidate_id:) -> [#("candidate_id", json.String(candidate_id))]
    ReadEvidence(evidence_id:) -> [#("evidence_id", json.String(evidence_id))]
    CoreStatus -> []
  }

  // Attach terminal surface annotation if requested and recorded.
  case via, records_surface(request) {
    ClaimsTerminal, Records ->
      json.Object(list.append(fields, [#("via", json.String("terminal"))]))
    Unclaimed, Records | _, Silent -> json.Object(fields)
  }
}

// Whether a request is one the daemon writes an audit entry for, and so reads
// `via` from. The gateway hands every action's arguments to its door as they
// came. Only the four changes record `via` in an audit entry, and
// `core_status` is the one reader with an exact shape (it accepts only an
// optional `request_id`), so a claim sent with it is refused.
type Recording {
  Records
  Silent
}

fn records_surface(request: Request) -> Recording {
  case request {
    Approve(..) | Revoke(..) | Select(..) | Rollback(..) -> Records
    Inspect(..) | ReadEvidence(..) | CoreStatus -> Silent
  }
}

// --- replies ----------------------------------------------------------------

/// Reads what an `evolution` command answered. `action` is the action the
/// lane issued, because the wire names none: every action answers with the
/// same snapshot. Total: a body this client cannot read is `Unreadable`.
///
/// ## Examples
///
/// ```gleam
/// assert evolution.read("approve", approved_body) == evolution.ApprovalReply("3f9a")
/// ```
pub fn read(action: String, body: json.JsonValue) -> Reply {
  case action {
    "board" ->
      case decode_board(body) {
        Ok(board) -> BoardReply(board)
        Error(reason) -> Unreadable(reason)
      }
    "status" | "select" | "rollback" ->
      case read_report(body) {
        Ok(report) -> ProgressReply(report)
        Error(reason) -> Unreadable(reason)
      }
    "approve" ->
      case named(body, "approved") {
        Ok(id) -> ApprovalReply(id)
        Error(reason) -> Unreadable(reason)
      }
    "revoke" ->
      case named(body, "revoked") {
        Ok(id) -> RevocationReply(id)
        Error(reason) -> Unreadable(reason)
      }
    _ -> PageReply(read_page(body))
  }
}

fn named(body: json.JsonValue, key: String) -> Result(String, String) {
  use fields <- result.try(object(body))
  required_text(fields, key)
}

/// Decodes response payload into either a whole JSON object or large page descriptor.
fn read_page(body: json.JsonValue) -> Page {
  case body {
    json.Object(fields) ->
      case list.key_find(fields, "fragment_base64") {
        Ok(_) -> Large(total_bytes: int_or(fields, "total_bytes", 0))
        Error(Nil) -> Whole(body)
      }
    _ -> Whole(body)
  }
}

/// The three actions that report a selection share one vocabulary: a `state`
/// word, or, for a selection of a global candidate that commits at once, the
/// bare committed selection.
fn read_report(body: json.JsonValue) -> Result(Report, String) {
  use fields <- result.try(object(body))

  // Extract generation from committed selection object if present.
  let committed = case list.key_find(fields, "committed") {
    Ok(json.Object(selection)) ->
      case list.key_find(selection, "generation") {
        Ok(json.Int(generation)) -> Some(generation)
        _ -> None
      }
    _ -> None
  }

  // Parse state and generation fields into report status.
  case list.key_find(fields, "state"), list.key_find(fields, "generation") {
    Ok(json.String("queued")), _ -> Ok(InFlight(Queued))
    Ok(json.String("running")), _ -> Ok(InFlight(Running))
    Ok(json.String("completed")), _ -> Ok(Done(committed))
    Ok(json.String("committed")), _ -> Ok(DurableOnly(committed))
    Ok(json.String("failed")), _ ->
      Ok(Rejected(text_or(fields, "reason", "the selection failed")))
    Ok(json.String("unknown")), _ -> Ok(Forgotten)
    Ok(json.String(other)), _ -> Ok(InFlight(UnknownPhase(other)))
    Ok(_), _ -> Error("invalid evolution state")
    Error(Nil), Ok(json.Int(generation)) -> Ok(Done(Some(generation)))
    Error(Nil), _ -> Error("an evolution reply names no state")
  }
}

// --- words ------------------------------------------------------------------

/// The word for what a candidate is.
///
/// ## Examples
///
/// ```gleam
/// assert evolution.kind_words(evolution.Program) == "program"
/// ```
pub fn kind_words(kind: Kind) -> String {
  case kind {
    Extension -> "extension"
    Program -> "program"
    Prompt -> "prompt"
    UnknownKind(kind:) -> "unknown (" <> text_hygiene.single_line(kind) <> ")"
  }
}

/// Where a selection applies, in words. The session the board describes reads
/// as "this session", and another session as its first eight characters.
///
/// ## Examples
///
/// ```gleam
/// assert evolution.scope_words(evolution.SessionScope("0198c0de-1"), "0198c0de-1") == "this session"
/// ```
pub fn scope_words(scope: Scope, session: String) -> String {
  case scope {
    SessionScope(session: id) if id == session -> "this session"
    SessionScope(session: id) -> "session " <> string.slice(id, 0, 8)
    WorkspaceScope(workspace:) -> workspace
    ModelScope(provider:, model:, api:) ->
      case api {
        "" -> provider <> "/" <> model
        _ -> provider <> "/" <> model <> " (" <> api <> ")"
      }
    UnknownScope(kind:) -> "unknown scope (" <> kind <> ")"
  }
}

/// The word for what an observation found.
///
/// ## Examples
///
/// ```gleam
/// assert evolution.verdict_words(evolution.Passed, "") == "passed"
/// ```
pub fn verdict_words(verdict: Verdict, reason: String) -> String {
  case verdict {
    Passed -> "passed"
    Failed -> "failed"
    Inconclusive ->
      case reason {
        "" -> "inconclusive"
        _ -> "inconclusive: " <> reason
      }
    UnknownVerdict(verdict:) ->
      "unknown (" <> text_hygiene.single_line(verdict) <> ")"
  }
}

/// The word for why an observation was made.
///
/// ## Examples
///
/// ```gleam
/// assert evolution.purpose_words(evolution.AuthorTests) == "author tests"
/// ```
pub fn purpose_words(purpose: Purpose) -> String {
  case purpose {
    AuthorTests -> "author tests"
    IndependentRollout -> "independent rollout"
    UnknownPurpose(purpose:) ->
      "unknown (" <> text_hygiene.single_line(purpose) <> ")"
  }
}

/// A principal's identity as the daemon names it, cut to fit a row. An owner's
/// is a long digest, so only the first characters are kept, which is enough to
/// tell two principals apart. Both hosts draw a principal through this, so a
/// history row stays on a line or two.
///
/// ## Examples
///
/// ```gleam
/// assert evolution.principal_words("member-noa") == "member-noa"
/// assert evolution.principal_words("owner-2d927c35c48e817d") == "owner-2d927c35…"
/// ```
pub fn principal_words(principal: String) -> String {
  let one_line = text_hygiene.single_line(principal)

  // Truncate long principal names with an ellipsis.
  case string.length(one_line) > 16 {
    True -> string.slice(one_line, 0, 14) <> "…"
    False -> one_line
  }
}

/// The word for where a decision was made. An entry written before surfaces
/// were recorded says nothing.
///
/// ## Examples
///
/// ```gleam
/// assert evolution.surface_words(evolution.Web) == "web"
/// ```
pub fn surface_words(surface: Surface) -> String {
  case surface {
    Cli -> "cli"
    Web -> "web"
    Terminal -> "terminal"
    Unrecorded -> ""
    OtherSurface(surface:) -> text_hygiene.single_line(surface)
  }
}

/// The word for what an audit entry records.
///
/// ## Examples
///
/// ```gleam
/// assert evolution.decision_words(evolution.Revoked) == "revoked"
/// ```
pub fn decision_words(decision: Decision) -> String {
  case decision {
    Approved -> "approved"
    Revoked -> "revoked"
    Selected -> "selected"
    UnknownDecision(decision:) ->
      "unknown (" <> text_hygiene.single_line(decision) <> ")"
  }
}

/// A candidate's address shortened for a row: its first eight characters.
///
/// ## Examples
///
/// ```gleam
/// assert evolution.short_id("3f9a0c2e1b7d") == "3f9a0c2e"
/// ```
pub fn short_id(id: String) -> String {
  string.slice(id, 0, 8)
}

/// The words for a generation, with whether the session runs it.
///
/// ## Examples
///
/// ```gleam
/// assert evolution.generation_words(3, evolution.Live) == "generation 3, live"
/// ```
pub fn generation_words(generation: Int, liveness: Liveness) -> String {
  case liveness {
    Live -> "generation " <> int.to_string(generation) <> ", live"
    NotLive -> "generation " <> int.to_string(generation)
  }
}

/// The words for a command the daemon refused. Every refusal of an evolution
/// command arrives as `bad_request` with the catalogue's own wording, so the
/// words are chosen from the message.
///
/// ## Examples
///
/// ```gleam
/// assert string.starts_with(evolution.refusal_words("bad_request", "selection changed"), "The selection changed")
/// ```
pub fn refusal_words(code: String, message: String) -> String {
  let said = text_hygiene.single_line(message)

  // Match refusal code and message against known user-friendly explanations.
  case code, said {
    "forbidden", _ ->
      "Your attachment may not do that to the evolution catalogue."
    _, "selection changed" ->
      "The selection changed since this was drawn, so nothing was selected. The board has been read again."
    _, "candidate evidence is not currently approved" ->
      "That evidence is not an approval, so nothing was selected."
    _, "candidate or evaluator identity changed" ->
      "The evaluator changed since this was tested, so it needs new evidence."
    _, "runtime evolution is unavailable for this session" ->
      "Evolution is not available for this session."
    _, "the evolution plane is unavailable" ->
      "Evolution is not available for this session."
    _, _ ->
      case
        string.starts_with(said, "authority: "),
        string.starts_with(said, "Busy:")
      {
        True, _ -> "Not allowed: " <> string.drop_start(said, 11) <> "."
        _, True -> "Another selection is still staging; wait for it."
        False, False -> "Evolution refused: " <> said
      }
  }
}

// --- offers and queries -----------------------------------------------------

/// The candidate with this identity, if the board lists it.
///
/// ## Examples
///
/// ```gleam
/// assert evolution.find(board, "3f9a") == Ok(candidate)
/// ```
pub fn find(board: Board, candidate_id: String) -> Result(Candidate, Nil) {
  list.find(board.candidates, fn(candidate) {
    candidate.candidate_id == candidate_id
  })
}

/// The evidence an approval of this candidate could rest on: the newest
/// observation that passed under the evaluator the host runs now, and for a
/// prompt only an independent rollout, since the store refuses an approval of a
/// prompt on its author's tests. A candidate
/// that is already approved, of a kind or purpose this client cannot name, or
/// tested under another identity offers none. The daemon is the gate; this is
/// what the UI can describe, so it is all the UI offers.
///
/// ## Examples
///
/// ```gleam
/// assert evolution.approval_target(candidate) == Ok("5c2e")
/// ```
pub fn approval_target(candidate: Candidate) -> Result(String, Nil) {
  case candidate.approval, candidate.identity {
    None, Current ->
      case candidate.kind {
        Extension | Program ->
          list.find(candidate.evidence, fn(found) {
            passed_and_current(found, AuthorTests)
            || passed_and_current(found, IndependentRollout)
          })
        Prompt ->
          list.find(candidate.evidence, passed_and_current(
            _,
            IndependentRollout,
          ))
        UnknownKind(..) -> Error(Nil)
      }
      |> result.map(fn(evidence) { evidence.evidence_id })
    _, _ -> Error(Nil)
  }
}

// Passing evidence made under the evaluator the host runs now, for one purpose.
// The store approves an extension or a program on either purpose and a prompt
// only on an independent rollout, since a prompt cannot be vouched for by tests
// its author wrote, and refuses the author's tests there.
fn passed_and_current(evidence: Evidence, purpose: Purpose) -> Bool {
  evidence.verdict == Passed
  && evidence.identity == Current
  && evidence.purpose == purpose
}

/// What a selection of this candidate would send: its approval's evidence and
/// the generation the board shows as current for its scope and name, which a
/// `Select` echoes. A candidate that is not approved, was tested under another
/// identity, is of a kind this client cannot name, or is already the selected
/// one offers none.
///
/// ## Examples
///
/// ```gleam
/// assert evolution.selection_target(board, candidate) == Ok(SelectTarget("5c2e", 3))
/// ```
pub fn selection_target(
  board: Board,
  candidate: Candidate,
) -> Result(SelectTarget, Nil) {
  case
    candidate.approval,
    candidate.kind,
    candidate.identity,
    candidate.selected
  {
    Some(approval), Extension, Current, None
    | Some(approval), Program, Current, None
    | Some(approval), Prompt, Current, None
    ->
      Ok(SelectTarget(
        approval.evidence_id,
        current_generation(board, candidate),
      ))
    _, _, _, _ -> Error(Nil)
  }
}

/// What a selection or a rollback echoes from the board as drawn.
pub type SelectTarget {
  SelectTarget(
    /// The evidence the candidate's approval rests on.
    evidence_id: String,
    /// The generation the board showed as current for the candidate's scope
    /// and name, zero when nothing is selected there.
    expected_generation: Int,
  )
}

/// Finds the current generation of a candidate matching by name and scope.
fn current_generation(board: Board, candidate: Candidate) -> Int {
  list.find(board.selections, fn(selection) {
    selection.name == candidate.name && selection.scope == candidate.scope
  })
  |> result.map(fn(selection) { selection.generation })
  |> result.unwrap(0)
}

/// The earlier candidates a name could roll back to: those the journal shows
/// selected for this candidate's name that the board still lists, still
/// approved and still current, newest selection first, without the candidate
/// that is selected now. A rollback selects one of them again.
///
/// ## Examples
///
/// ```gleam
/// assert list.length(evolution.rollback_choices(board, live_candidate)) == 1
/// ```
pub fn rollback_choices(board: Board, current: Candidate) -> List(Candidate) {
  board.history
  |> list.filter(fn(event) {
    event.decision == Selected && event.name == current.name
  })
  |> list.map(fn(event) { event.candidate_id })
  |> list.unique
  |> list.filter(fn(id) { id != current.candidate_id })
  |> list.filter_map(fn(id) {
    use candidate <- result.try(find(board, id))

    // Filter candidates matching current scope, approved, and current identity.
    case
      candidate.scope == current.scope,
      candidate.approval,
      candidate.identity
    {
      True, Some(_), Current -> Ok(candidate)
      _, _, _ -> Error(Nil)
    }
  })
}

/// How many candidates wait for a person: those with passing, current
/// evidence and no approval, and the selections still staging. The count a
/// host puts on its entry point.
///
/// ## Examples
///
/// ```gleam
/// assert evolution.awaiting_approval(board) == 2
/// ```
pub fn awaiting_approval(board: Board) -> Int {
  let unapproved =
    list.count(board.candidates, fn(candidate) {
      approval_target(candidate) != Error(Nil)
    })
  unapproved + list.length(board.pending)
}
