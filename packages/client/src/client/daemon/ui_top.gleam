//// What the web view asks of another orchestrator, and what it makes of the
//// answers (protocol-change/094, the placement revamp's slice S2b).
////
//// The relayed session page (`web_view/home` showing `Pane` `Relayed`) never
//// touches a connection. `client/remote/top_relay` is the sending end of the
//// orchestrator port: it dials on demand, decodes each answer with a total
//// decoder and resends a create or a message with the same identities. This
//// module sits between that relay and the page's vocabulary
//// (`web_view/relayed`). Every function here is a plain function of a relay, so
//// the socket (`client/daemon/ui_socket`) decides where it runs, in a task of its
//// own, and a test can drive it against a real port on this node.
////
//// ## Re-judging on this side
////
//// The box judges every request against its own `[spawners.<name>.top_level]`
//// table. This module judges first, from a fresh read of the box, so that a page
//// can ask the box for nothing it did not draw:
////
//// - A decision is built from the request as the box lists it now. The page names
////   a request by its identity and the revision the card showed, and this module
////   finds that request in a fresh page of the box's sessions and builds the
////   approval from the box's own `action` digest and the grants its ceiling
////   admitted. A request that is gone, or whose question moved, is refused here.
//// - A create is checked against a fresh `Placements` answer (`create`): the
////   folder, the executor and workspace, the pool, the profile and the model must
////   each be one the box offers now. The composer's lists were drawn from an
////   earlier read, and the box's table may have changed since.
////
//// ## Untrusted text
////
//// A request's tool, preview and grants were written on the box, some by a model.
//// They become the page's words through the same rules a local approval card
//// follows (`session_view/approval.presentation`), as literal text, and nothing
//// here builds a path, a class or a key from them.
////
//// ## Flow
////
//// `read` → `row_of` → `need_of` → `send` / `stop` / `archive` → `decide` →
//// `judge` → `create`
////
//// 1. `read` asks for the session's row and its newest transcript page.
//// 2. `row_of` and `need_of` turn what the box listed into the page's types.
//// 3. `send`, `stop` and `archive` relay the three plain actions.
//// 4. `decide` finds the request afresh and relays the decision.
//// 5. `judge` checks a create against the offers, and `create` asks for fresh
////    offers, judges, and creates.

import broker/policy
import client/protocol.{type EscalationRecord}
import client/remote/top_relay.{type Failure, type Relay}
import client/remote_escalation
import client/remote_top
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/approval
import session_view/remote_transcript
import web_view/listing
import web_view/relayed

/// Why a create did not reach the box.
pub type CreateRefusal {
  /// The box does not offer what the page asked for, now. Nothing was sent.
  NotOffered(
    /// What kind of thing it is.
    what: remote_top.Offered,
    /// The name the page gave.
    name: String,
  )

  /// The offers could not be read, or the box refused or did not answer the
  /// create.
  Failed(
    /// Why.
    failure: Failure,
  )
}

/// Reads the session's row from the box's list and, if the list holds it, the
/// newest page of its transcript. A list that cannot be read is `Unreached`; a
/// transcript that cannot be read leaves the row and says why in its place.
///
/// ## Examples
///
/// ```gleam
/// // ui_top.read(relay, "box", "0198c0de-0000-7000-8000-000000000001")
/// ```
pub fn read(
  relay: Relay,
  orchestrator: String,
  session: String,
) -> relayed.Read {
  case top_relay.all_sessions(relay, orchestrator) {
    Error(failure) -> relayed.Unreached(top_relay.describe(failure))
    Ok(rows) ->
      case list.find(rows, fn(row) { row.session_id == session }) {
        Error(Nil) ->
          relayed.Heard(row: None, history: relayed.Unreadable(why: ""))
        Ok(found) ->
          relayed.Heard(
            row: Some(row_of(orchestrator, found)),
            history: history(relay, orchestrator, session),
          )
      }
  }
}

fn history(
  relay: Relay,
  orchestrator: String,
  session: String,
) -> relayed.History {
  case
    top_relay.history(
      relay,
      orchestrator,
      session,
      0,
      remote_transcript.max_entries,
    )
  {
    Ok(page) -> relayed.Shown(page:)
    Error(failure) -> relayed.Unreadable(why: top_relay.describe(failure))
  }
}

/// A box's row as the page's row.
///
/// ## Examples
///
/// ```gleam
/// // ui_top.row_of("box", row)
/// ```
pub fn row_of(orchestrator: String, row: remote_top.Row) -> relayed.Row {
  relayed.Row(
    name: row.name,
    code: code_of(row.placement),
    activity: activity_of(row.activity),
    updated_ms: row.updated_at,
    needs: list.map(row.requests, need_of(orchestrator, _)),
    more_needs: row.more,
  )
}

fn code_of(placement: remote_top.Placement) -> listing.Code {
  case placement {
    remote_top.Folder(path:) -> listing.Folder(path:)
    remote_top.Workspace(executor:, name:) ->
      listing.Registered(executor:, workspace: name)
    remote_top.Pooled(pool:, name:) -> listing.Pooled(pool:, workspace: name)
  }
}

// The box does not list an archived session, so `Archived` is not sent; it reads
// as quiet if one arrives.
fn activity_of(activity: remote_top.Activity) -> relayed.Activity {
  case activity {
    remote_top.NeedsYou -> relayed.NeedsYou
    remote_top.Working -> relayed.Working
    remote_top.Idle | remote_top.Archived -> relayed.Idle
  }
}

// The grants a request wants and the part of them the box's ceiling admitted.
fn wanted(record: EscalationRecord) -> List(policy.Grant) {
  case record.denial {
    Some(denial) -> denial.wanted
    None -> []
  }
}

fn admitted(record: EscalationRecord) -> List(policy.Grant) {
  option.unwrap(record.admitted, [])
}

// The request as the terminal's approval card holds it: the same review the
// local card is drawn from, so the words, the 16 KiB bound and the
// rememberable rule are the ones a local request has.
fn review_of(
  orchestrator: String,
  record: EscalationRecord,
) -> approval.Review {
  let allowed = admitted(record)
  let permission = case record.action, allowed {
    "", _ -> approval.Unavailable("approval has no captured action digest")
    _, [] ->
      approval.Unavailable(
        "the spawner's approval ceiling admits none of what was asked",
      )
    action, grants ->
      approval.Exact(action, list.map(grants, protocol.encode_grant))
  }
  let outside =
    wanted(record)
    |> list.filter(fn(grant) { !list.contains(allowed, grant) })
    |> list.map(protocol.encode_grant)

  approval.Review(
    id: record.escalation_id,
    seq: record.seq,
    status: approval.Pending,
    tool: record.tool,
    preview: record.preview,
    origin: None,
    permission:,
    strand: Some(record.strand),
    remote: Some(approval.Remote(orchestrator:, child: record.strand, outside:)),
  )
}

/// A request the box lists as the page's card. A request whose whole authority
/// cannot be shown (too large, or no digest, or nothing the ceiling admits)
/// becomes a card that says why and offers no button.
///
/// ## Examples
///
/// ```gleam
/// // ui_top.need_of("box", record)
/// ```
pub fn need_of(orchestrator: String, record: EscalationRecord) -> relayed.Need {
  let review = review_of(orchestrator, record)
  let outside =
    approval.outside_lines(review)
    |> list.map(string.drop_start(_, 2))

  case approval.presentation(review) {
    Ok(shown) ->
      relayed.Need(
        escalation: record.escalation_id,
        seq: record.seq,
        strand: record.strand,
        tool: record.tool,
        question: shown.question,
        action: shown.action,
        authority: list.map(shown.authority, string.drop_start(_, 2)),
        outside:,
        ability: relayed.Decidable,
        remember: case approval.rememberable(review) {
          Ok(Nil) -> relayed.Rememberable
          Error(_) -> relayed.OnceOnly
        },
      )
    Error(reason) ->
      relayed.Need(
        escalation: record.escalation_id,
        seq: record.seq,
        strand: record.strand,
        tool: record.tool,
        question: "This request cannot be approved from the page: " <> reason,
        action: record.preview,
        authority: [],
        outside:,
        ability: relayed.ViewOnly,
        remember: relayed.OnceOnly,
      )
  }
}

// A failure as the outcome of a press: a refusal when nothing happened, and an
// unknown outcome when the box may have done it.
fn outcome_of(failure: Failure) -> relayed.Outcome {
  case top_relay.outcome_unknown(failure) {
    True -> relayed.Unknown(why: top_relay.describe(failure))
    False -> relayed.Refusal(why: top_relay.describe(failure))
  }
}

/// Delivers a reply to the session's main strand under the page's message
/// identity. The relay resends it with the same identity if the answer is lost,
/// so the box delivers it once.
///
/// ## Examples
///
/// ```gleam
/// // ui_top.send(relay, "box", session, message_id, "hello")
/// ```
pub fn send(
  relay: Relay,
  orchestrator: String,
  session: String,
  message_id: String,
  text: String,
) -> relayed.Outcome {
  case top_relay.send(relay, orchestrator, session, message_id, text) {
    Ok(_) -> relayed.Done
    Error(failure) -> outcome_of(failure)
  }
}

/// Stops the session's current run.
///
/// ## Examples
///
/// ```gleam
/// // ui_top.stop(relay, "box", session)
/// ```
pub fn stop(
  relay: Relay,
  orchestrator: String,
  session: String,
) -> relayed.Outcome {
  case top_relay.stop(relay, orchestrator, session) {
    Ok(Nil) -> relayed.Done
    Error(failure) -> outcome_of(failure)
  }
}

/// Archives the session.
///
/// ## Examples
///
/// ```gleam
/// // ui_top.archive(relay, "box", session)
/// ```
pub fn archive(
  relay: Relay,
  orchestrator: String,
  session: String,
) -> relayed.Outcome {
  case top_relay.archive(relay, orchestrator, session) {
    Ok(Nil) -> relayed.Done
    Error(failure) -> outcome_of(failure)
  }
}

/// Decides a request the page drew. The request is found in a fresh read of the
/// box's list, by the identity and the revision the card showed, and the decision
/// is built from what the box lists now: its action digest and the grants its
/// ceiling admitted. A request that is gone, one whose question moved, one with
/// nothing the ceiling admits, and an allow-for-session for a request that cannot
/// be remembered are refused here, and nothing is sent.
///
/// ## Examples
///
/// ```gleam
/// // ui_top.decide(relay, "box", session, decider, "ask-1", 4, relayed.Allow)
/// ```
pub fn decide(
  relay: Relay,
  orchestrator: String,
  session: String,
  decider: remote_escalation.Decider,
  escalation: String,
  seq: Int,
  choice: relayed.Choice,
) -> relayed.Outcome {
  case pending(relay, orchestrator, session, escalation, seq) {
    Error(outcome) -> outcome
    Ok(record) ->
      case decision(orchestrator, record, choice) {
        Error(why) -> relayed.Refusal(why:)
        Ok(chosen) ->
          case
            top_relay.resolve(
              relay,
              orchestrator,
              session,
              escalation,
              chosen,
              seq,
              decider,
            )
          {
            Ok(remote_escalation.Decided(..))
            | Ok(remote_escalation.Forgotten) -> relayed.Done
            Ok(refused) ->
              relayed.Refusal(why: remote_escalation.describe_refusal(refused))
            Error(failure) -> outcome_of(failure)
          }
      }
  }
}

// The request the page named, in a fresh read of the box's list.
fn pending(
  relay: Relay,
  orchestrator: String,
  session: String,
  escalation: String,
  seq: Int,
) -> Result(EscalationRecord, relayed.Outcome) {
  use rows <- result.try(
    top_relay.all_sessions(relay, orchestrator)
    |> result.map_error(outcome_of),
  )
  let found = {
    use row <- result.try(
      list.find(rows, fn(row) { row.session_id == session }),
    )
    list.find(row.requests, fn(record) {
      record.escalation_id == escalation && record.seq == seq
    })
  }

  found
  |> result.replace_error(relayed.Refusal(
    why: "that request is no longer pending, or its question changed",
  ))
}

// What the person chose, as the decision the box judges. Approving carries the
// grants the ceiling admitted and the action digest the card was drawn with.
fn decision(
  orchestrator: String,
  record: EscalationRecord,
  choice: relayed.Choice,
) -> Result(remote_escalation.Decision, String) {
  case choice {
    relayed.Deny -> Ok(remote_escalation.Deny)
    relayed.Allow -> approving(record, remote_escalation.Once)
    relayed.AllowForSession ->
      case approval.rememberable(review_of(orchestrator, record)) {
        Ok(Nil) -> approving(record, remote_escalation.Session)
        Error(reason) -> Error(reason)
      }
  }
}

fn approving(
  record: EscalationRecord,
  scope: remote_escalation.Scope,
) -> Result(remote_escalation.Decision, String) {
  case record.action, admitted(record) {
    "", _ -> Error("the request carries no action digest to approve")
    _, [] -> Error(remote_escalation.outside_the_ceiling)
    action, grants -> Ok(remote_escalation.Approve(grants:, action:, scope:))
  }
}

/// Whether the box offers what a create asks for: the placement is a folder it
/// remembers, a workspace of an executor it lists (any name, when the executor
/// reported no workspaces), or a workspace of a pool it lists; the profile is one
/// of its profiles; and the model, if one is chosen, is one of its models. It
/// answers the first thing that is not offered.
///
/// ## Examples
///
/// ```gleam
/// assert ui_top.judge(remote_top.no_offers(), remote_top.Folder("/w"), "default", None)
///   == Error(ui_top.NotOffered(remote_top.OfferedFolder, "/w"))
/// ```
pub fn judge(
  offers: remote_top.Offers,
  placement: remote_top.Placement,
  profile: String,
  model: Option(String),
) -> Result(Nil, CreateRefusal) {
  use Nil <- result.try(placed(offers, placement))
  use Nil <- result.try(case list.contains(offers.profiles, profile) {
    True -> Ok(Nil)
    False -> Error(NotOffered(remote_top.OfferedProfile, profile))
  })

  case model {
    None -> Ok(Nil)
    Some(key) ->
      case list.contains(offers.models, key) {
        True -> Ok(Nil)
        False -> Error(NotOffered(remote_top.OfferedModel, key))
      }
  }
}

fn placed(
  offers: remote_top.Offers,
  placement: remote_top.Placement,
) -> Result(Nil, CreateRefusal) {
  case placement {
    remote_top.Folder(path:) ->
      case list.any(offers.folders, fn(offer) { offer.path == path }) {
        True -> Ok(Nil)
        False -> Error(NotOffered(remote_top.OfferedFolder, path))
      }
    remote_top.Workspace(executor:, name:) ->
      case list.find(offers.executors, fn(offer) { offer.name == executor }) {
        Error(Nil) -> Error(NotOffered(remote_top.OfferedExecutor, executor))
        Ok(offer) -> named(offer.workspaces, name, remote_top.OfferedExecutor)
      }
    remote_top.Pooled(pool:, name:) ->
      case list.find(offers.pools, fn(offer) { offer.name == pool }) {
        Error(Nil) -> Error(NotOffered(remote_top.OfferedPool, pool))
        Ok(offer) -> named(offer.workspaces, name, remote_top.OfferedPool)
      }
  }
}

// A workspace name must be one the machine registered, unless it registered none
// and the page asks for a name.
fn named(
  workspaces: List(String),
  name: String,
  what: remote_top.Offered,
) -> Result(Nil, CreateRefusal) {
  case workspaces {
    [] -> Ok(Nil)
    listed ->
      case list.contains(listed, name) {
        True -> Ok(Nil)
        False -> Error(NotOffered(what, name))
      }
  }
}

/// Starts a session on the box: asks for its offers afresh, judges the create
/// against them, and only then creates. The request identity is the page's, one
/// for each submit, and the relay resends it until the box answers or the window
/// ends. The answer is the session's identity there.
///
/// ## Examples
///
/// ```gleam
/// // ui_top.create(relay, "box", request_id, remote_top.Folder("/w"), "default", None)
/// ```
pub fn create(
  relay: Relay,
  orchestrator: String,
  request_id: String,
  placement: remote_top.Placement,
  profile: String,
  model: Option(String),
) -> Result(String, CreateRefusal) {
  use offers <- result.try(
    top_relay.placements(relay, orchestrator) |> result.map_error(Failed),
  )
  use Nil <- result.try(judge(offers, placement, profile, model))

  top_relay.create(relay, orchestrator, request_id, placement, profile, model)
  |> result.map_error(Failed)
}
