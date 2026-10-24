//// The page's governed-evolution tab: what the page holds besides the board,
//// and the question each change asks before it sends (protocol-change/099).
////
//// A session proposes an extension, a program or a prompt, tests it, and the
//// daemon waits for a person to approve it and to select it as the generation
//// a session runs. The board the daemon sends, and the words both hosts draw
//// for a row, are `session_view/evolution`; this module is the page's own
//// part, and it answers three questions that the board alone does not.
////
//// *What may this page offer on a row?* `offers` turns a candidate and the
//// board into the changes the page can describe: an approval, a selection, a
//// revocation, and the earlier generations a live row could roll back to. An
//// owner's page is offered every row. A member operator's page is offered only
//// the rows of this session's own scope, which is the store's own rule, and
//// the daemon refuses anything else on its own account, so the offer is a
//// convenience and never the gate. While a selection is staging the daemon
//// holds one active job and refuses a second with `Busy:`, so a selection or a
//// rollback is not offered until the first has finished.
////
//// *What does a press send?* Approving, selecting, revoking and rolling back
//// are two presses. The first arms an `Armed`: the candidate, the evidence and
//// the generation exactly as the page drew them, and it sends nothing. The
//// second is the question's confirm, and it sends the request built from what
//// was armed. A press never decides a row that was not on screen, and the
//// confirm looks the offer up in the board the page holds now, so a board that
//// moved while the question was open sends nothing: the generation the person
//// agreed to replace is no longer the one on the board.
////
//// *What does the reason say?* A selection, a rollback and a revocation carry a
//// reason that the audit journal keeps. The question draws a one-line field
//// with a sentence already in it, and `reason_for` takes what the field held:
//// a blank field is the sentence, and a long one is cut at `reason_limit`.
////
//// The board stays fresh by the daemon's `evolution_changed` push, which the
//// shared lane turns into a read, and by the lane's own backstop and staging
//// polls (`session_view/surfaces.evolution_due`). The page only says that it
//// wants the board (`component.want_evolution`).
////
//// ## Flow
////
//// `offers` lists what a row may do. `arm` opens the question for one of them,
//// `asking` says whether a row's offer is the one open, `request` builds what
//// the confirm sends, and `disarm` closes the question. `waiting` counts what
//// needs a person, for the tab's badge.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/evolution
import session_view/evolution_pending

/// The most characters of a reason the page sends. The daemon keeps its own
/// bound; this one keeps the field to a line.
pub const reason_limit = 200

/// What a person may do to a candidate, which is also what its question asks.
pub type Act {
  /// Approve the candidate on one piece of its passing evidence.
  Approving

  /// Select the candidate as the next generation of its name.
  Selecting

  /// Select an earlier approved candidate again.
  RollingBack

  /// Withdraw the candidate's approval.
  Revoking
}

/// A question the page has opened: the change as the page drew it. Every field
/// comes from the board the page held when the button was drawn, never from
/// the browser.
pub type Armed {
  Armed(
    /// What the confirm will ask the daemon to do.
    act: Act,
    /// The candidate it applies to: the one selected, or approved, or revoked,
    /// or the earlier one a rollback selects again.
    candidate_id: String,
    /// The name the candidate runs under, for the words.
    name: String,
    /// The evidence the approval rests on, or the approval's own evidence
    /// when revoking.
    evidence_id: String,
    /// The generation the board showed as current for a selection or a
    /// rollback, which the daemon compares with its own so a board that has
    /// moved is refused. Zero where the act has none.
    expected_generation: Int,
  )
}

/// What the page holds besides the board, which is part of the session's
/// shared record.
pub type State {
  State(
    /// The question that is open, if any. Only one row asks at a time.
    armed: Option(Armed),
  )
}

/// Whose rows the page may offer a change on.
pub type Reach {
  /// Every row the board holds: the owner's page, whose authority the daemon
  /// derives from the principal.
  Everywhere

  /// This session's own rows only: a member operator's page.
  OwnSession
}

/// Whether a selection is on its way, which holds back a second.
pub type Staging {
  /// A selection or a rollback has been accepted and has not finished.
  InFlight

  /// None has.
  Settled
}

/// The changes a page may offer on one candidate.
pub type Offers {
  Offers(
    /// Approve the candidate, when it has passing evidence and no approval.
    approve: Option(Armed),
    /// Select the candidate, when it is approved and not the selected one.
    select: Option(Armed),
    /// Withdraw its approval, when it has one.
    revoke: Option(Armed),
    /// The earlier approved candidates of this name that a live row could
    /// roll back to, newest selection first.
    rollbacks: List(Armed),
  )
}

/// A page that has asked nothing.
///
/// ## Examples
///
/// ```gleam
/// assert evolving.new().armed == None
/// ```
pub fn new() -> State {
  State(armed: None)
}

/// Opens the question for one change, replacing any other.
///
/// ## Examples
///
/// ```gleam
/// assert evolving.arm(evolving.new(), armed).armed == Some(armed)
/// ```
pub fn arm(_state: State, armed: Armed) -> State {
  State(armed: Some(armed))
}

/// Closes the question without sending anything.
///
/// ## Examples
///
/// ```gleam
/// assert evolving.disarm(evolving.new()).armed == None
/// ```
pub fn disarm(_state: State) -> State {
  State(armed: None)
}

/// Whether the question is open for exactly this change.
///
/// ## Examples
///
/// ```gleam
/// assert !evolving.asking(evolving.new(), armed)
/// ```
pub fn asking(state: State, armed: Armed) -> Bool {
  state.armed == Some(armed)
}

/// Whether the page may offer a change on this candidate at all.
///
/// ## Examples
///
/// ```gleam
/// assert evolving.within(evolving.Everywhere, board, candidate)
/// ```
pub fn within(
  reach: Reach,
  board: evolution.Board,
  candidate: evolution.Candidate,
) -> Bool {
  case reach {
    Everywhere -> True
    OwnSession -> candidate.scope == evolution.SessionScope(board.session)
  }
}

/// Whether a selection is on its way, from the lane's own tracker or from the
/// board's list of the transitions the daemon holds. A second selection waits
/// for the first, because the daemon runs one at a time.
///
/// ## Examples
///
/// ```gleam
/// assert evolving.staging_of(evolution_pending.new(), board) == evolving.Settled
/// ```
pub fn staging_of(
  tracker: evolution_pending.Tracker,
  board: evolution.Board,
) -> Staging {
  case evolution_pending.active(tracker), board.pending {
    0, [] -> Settled
    _, _ -> InFlight
  }
}

/// What a page may offer on a candidate: nothing outside its reach, and
/// otherwise what `session_view/evolution` can describe. A candidate of a kind
/// this client cannot name, or whose approval or evidence it could not read,
/// offers nothing, because the daemon decides what an action does and the page
/// only offers what it can describe.
///
/// A selection and a rollback wait while another is staging.
///
/// ## Examples
///
/// ```gleam
/// assert evolving.offers(evolving.Everywhere, evolving.Settled, board, candidate).approve == None
/// ```
pub fn offers(
  reach: Reach,
  staging: Staging,
  board: evolution.Board,
  candidate: evolution.Candidate,
) -> Offers {
  case within(reach, board, candidate) {
    False -> Offers(approve: None, select: None, revoke: None, rollbacks: [])
    True ->
      Offers(
        approve: approval_offer(candidate),
        select: selection_offer(staging, board, candidate),
        revoke: revocation_offer(candidate),
        rollbacks: rollback_offers(staging, board, candidate),
      )
  }
}

fn approval_offer(candidate: evolution.Candidate) -> Option(Armed) {
  case evolution.approval_target(candidate) {
    Ok(evidence_id) ->
      Some(Armed(
        act: Approving,
        candidate_id: candidate.candidate_id,
        name: candidate.name,
        evidence_id:,
        expected_generation: 0,
      ))
    Error(Nil) -> None
  }
}

fn selection_offer(
  staging: Staging,
  board: evolution.Board,
  candidate: evolution.Candidate,
) -> Option(Armed) {
  case staging, evolution.selection_target(board, candidate) {
    Settled, Ok(target) ->
      Some(Armed(
        act: Selecting,
        candidate_id: candidate.candidate_id,
        name: candidate.name,
        evidence_id: target.evidence_id,
        expected_generation: target.expected_generation,
      ))
    InFlight, _ | _, Error(Nil) -> None
  }
}

// A revocation is offered on any candidate whose approval the page read. The
// approval's own evidence is what the question names.
fn revocation_offer(candidate: evolution.Candidate) -> Option(Armed) {
  case candidate.approval {
    Some(approval) ->
      Some(Armed(
        act: Revoking,
        candidate_id: candidate.candidate_id,
        name: candidate.name,
        evidence_id: approval.evidence_id,
        expected_generation: 0,
      ))
    None -> None
  }
}

// A rollback belongs to the row that is selected now: it selects an earlier
// approved candidate of the same name again, and echoes the generation the
// selected row shows.
fn rollback_offers(
  staging: Staging,
  board: evolution.Board,
  candidate: evolution.Candidate,
) -> List(Armed) {
  case staging, candidate.selected {
    Settled, Some(chosen) ->
      evolution.rollback_choices(board, candidate)
      |> list.filter_map(fn(earlier) {
        case earlier.approval {
          Some(approval) ->
            Ok(Armed(
              act: RollingBack,
              candidate_id: earlier.candidate_id,
              name: earlier.name,
              evidence_id: approval.evidence_id,
              expected_generation: chosen.generation,
            ))
          None -> Error(Nil)
        }
      })
    InFlight, _ | _, None -> []
  }
}

/// Every change a candidate offers, in the order a row draws them.
///
/// ## Examples
///
/// ```gleam
/// assert evolving.all(evolving.Offers(None, None, None, [])) == []
/// ```
pub fn all(offers: Offers) -> List(Armed) {
  list.flatten([
    option.values([offers.approve, offers.select]),
    offers.rollbacks,
    option.values([offers.revoke]),
  ])
}

/// The candidate and the offer on it that a change refers to, found in the
/// board the page holds now, or nothing when the board no longer offers exactly
/// that change. This is what both the first press and the confirm check, so a
/// change the page did not draw, or that the board has since moved past,
/// sends nothing.
///
/// ## Examples
///
/// ```gleam
/// assert evolving.find_offer(evolving.Everywhere, evolving.Settled, board, armed) == Error(Nil)
/// ```
pub fn find_offer(
  reach: Reach,
  staging: Staging,
  board: evolution.Board,
  armed: Armed,
) -> Result(Armed, Nil) {
  board.candidates
  |> list.flat_map(fn(candidate) {
    all(offers(reach, staging, board, candidate))
  })
  |> list.find(fn(offered) { offered == armed })
}

/// What the confirm sends for a change, with the reason the field held for the
/// acts that carry one.
///
/// ## Examples
///
/// ```gleam
/// assert evolving.request(armed_approval, "") == evolution.Approve("c", "e")
/// ```
pub fn request(armed: Armed, reason: String) -> evolution.Request {
  case armed.act {
    Approving -> evolution.Approve(armed.candidate_id, armed.evidence_id)
    Revoking ->
      evolution.Revoke(armed.candidate_id, reason_for(armed.act, reason))
    Selecting ->
      evolution.Select(
        candidate_id: armed.candidate_id,
        name: armed.name,
        evidence_id: armed.evidence_id,
        expected_generation: armed.expected_generation,
        reason: reason_for(armed.act, reason),
      )
    RollingBack ->
      evolution.Rollback(
        candidate_id: armed.candidate_id,
        name: armed.name,
        evidence_id: armed.evidence_id,
        expected_generation: armed.expected_generation,
        reason: reason_for(armed.act, reason),
      )
  }
}

/// The sentence the question's field starts with, which a blank field sends.
///
/// ## Examples
///
/// ```gleam
/// assert evolving.default_reason(evolving.Selecting) == "selected from the web page"
/// ```
pub fn default_reason(act: Act) -> String {
  case act {
    Approving -> "approved from the web page"
    Selecting -> "selected from the web page"
    RollingBack -> "rolled back from the web page"
    Revoking -> "revoked from the web page"
  }
}

/// The reason to send for what a field held: the field's text without the
/// whitespace around it, cut to `reason_limit`, or the act's own sentence when
/// the field was blank.
///
/// ## Examples
///
/// ```gleam
/// assert evolving.reason_for(evolving.Revoking, "  flaky ") == "flaky"
/// assert evolving.reason_for(evolving.Revoking, "   ") == "revoked from the web page"
/// ```
pub fn reason_for(act: Act, text: String) -> String {
  case string.trim(text) {
    "" -> default_reason(act)
    kept -> string.slice(kept, 0, reason_limit)
  }
}

/// How many candidates and selections wait for a person, for the tab's badge:
/// the candidates the page may approve and the selections still staging.
///
/// ## Examples
///
/// ```gleam
/// assert evolving.waiting(evolving.OwnSession, board) == 0
/// ```
pub fn waiting(reach: Reach, board: evolution.Board) -> Int {
  let approvable =
    list.count(board.candidates, fn(candidate) {
      within(reach, board, candidate)
      && evolution.approval_target(candidate) != Error(Nil)
    })
  approvable + list.length(board.pending)
}

/// The label of the button that opens an approval's question.
pub const approve_label = "Approve"

/// The label of the button that opens a revocation's question.
pub const revoke_label = "Revoke"

/// The label of a question's way out.
pub const keep_label = "Keep waiting"
