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
//// ## What the composer and the sidebar read
////
//// The composer's Agent chip and the sidebar's relayed rows are drawn from two
//// more reads, `offers` and `listing`, and a create is `found`: it creates, and
//// then delivers the first message. Each answers in the page's vocabulary
//// (`web_view/orchestrators`) and never fails to answer: a box that cannot be
//// reached is a `Withheld`, a `Missed` or a `Refused` with the relay's words, which
//// is what a page draws. `listing` drops a row whose session identity is not in
//// canonical text, so a link built from a row held by the page names a session the
//// router will accept.
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
//// `judge` → `create` → `offers` → `listing` → `found`
////
//// 1. `read` asks for the session's row and its newest transcript page.
//// 2. `row_of` and `need_of` turn what the box listed into the page's types.
//// 3. `send`, `stop` and `archive` relay the three plain actions.
//// 4. `decide` finds the request afresh and relays the decision.
//// 5. `judge` checks a create against the offers, and `create` asks for fresh
////    offers, judges, and creates.
//// 6. `offers` and `listing` read what the composer and the sidebar draw, and
////    `found` creates a session and sends its first message.

import broker/policy
import client/protocol.{type EscalationRecord}
import client/remote/top_relay.{type Failure, type Relay}
import client/remote_escalation
import client/remote_top
import core/ids
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/approval
import session_view/remote_transcript
import web_view/creations
import web_view/listing
import web_view/orchestrators
import web_view/placements
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

  /// The page chose no profile and the box offers none to start a session with.
  NoProfile

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
  // This branch resolves top_relay all_sessions relay orchestrator before the operation continues.
  case top_relay.all_sessions(relay, orchestrator) {
    Error(failure) -> relayed.Unreached(read_failure(failure))
    Ok(rows) ->
      // This branch resolves the input state before the operation continues.

      // This branch resolves the input state before the operation continues.
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

/// Words a failed read without implying that an action may have run. Silence
/// describes the missing answer; other failures retain the relay's detail.
fn read_failure(failure: Failure) -> String {
  case failure {
    top_relay.Silent -> "the orchestrator did not answer"
    top_relay.NotConfigured(..)
    | top_relay.Unreachable
    | top_relay.OlderBuild
    | top_relay.Refused(..)
    | top_relay.Unreadable(..) -> top_relay.describe(failure)
  }
}

/// Fetches remote transcript history for a session through the top relay.
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
    Error(failure) -> relayed.Unreadable(why: read_failure(failure))
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

/// Converts remote placement descriptions into UI listing code representations.
fn code_of(placement: remote_top.Placement) -> listing.Code {
  // This branch resolves placement before the operation continues.
  case placement {
    remote_top.Folder(path:) -> listing.Folder(path:)
    remote_top.Workspace(executor:, name:) ->
      listing.Registered(executor:, workspace: name)
    remote_top.Pooled(pool:, name:) -> listing.Pooled(pool:, workspace: name)
  }
}

/// Maps remote session activity states to relayed page activity markers.
fn activity_of(activity: remote_top.Activity) -> relayed.Activity {
  // This branch resolves activity before the operation continues.
  case activity {
    remote_top.NeedsYou -> relayed.NeedsYou
    remote_top.Working -> relayed.Working
    remote_top.Idle | remote_top.Archived -> relayed.Idle
  }
}

// The grants a request wants and the part of them the box's ceiling admitted.
/// Wanted keeps this client decision explicit for its callers.
fn wanted(record: EscalationRecord) -> List(policy.Grant) {
  // This branch resolves record denial before the operation continues.
  case record.denial {
    Some(denial) -> denial.wanted
    None -> []
  }
}

fn admitted(record: EscalationRecord) -> List(policy.Grant) {
  option.unwrap(record.admitted, [])
}

/// Constructs a client approval review record from an escalation record.
fn review_of(
  orchestrator: String,
  record: EscalationRecord,
) -> approval.Review {
  let allowed = admitted(record)

  // Determine approval permission based on captured action digest and admitted grants.
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

  // Format presentation review card or render approval error view.
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
        // This branch resolves approval rememberable review before the operation continues.
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
/// Outcome of keeps this client decision explicit for its callers.
fn outcome_of(failure: Failure) -> relayed.Outcome {
  // This branch resolves top_relay outcome_unknown failure before the operation continues.
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
  // This branch resolves top_relay send relay orchestrator session message_id text before the operation continues.
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
  // This branch resolves top_relay stop relay orchestrator session before the operation continues.
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
  // This branch resolves top_relay archive relay orchestrator session before the operation continues.
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
  // This branch resolves pending relay orchestrator session escalation seq before the operation continues.
  case pending(relay, orchestrator, session, escalation, seq) {
    Error(outcome) -> outcome
    Ok(record) ->
      // This branch resolves the input state before the operation continues.

      // This branch resolves the input state before the operation continues.
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

/// Retrieves the matching pending escalation record from a fresh session listing.
fn pending(
  relay: Relay,
  orchestrator: String,
  session: String,
  escalation: String,
  seq: Int,
) -> Result(EscalationRecord, relayed.Outcome) {
  use rows <- result.try(
    top_relay.all_sessions(relay, orchestrator)
    |> result.map_error(fn(failure) {
      relayed.Refusal(why: read_failure(failure))
    }),
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

/// Constructs a remote escalation decision from user choice selection.
fn decision(
  orchestrator: String,
  record: EscalationRecord,
  choice: relayed.Choice,
) -> Result(remote_escalation.Decision, String) {
  // This branch resolves choice before the operation continues.
  case choice {
    relayed.Deny -> Ok(remote_escalation.Deny)
    relayed.Allow -> approving(record, remote_escalation.Once)
    relayed.AllowForSession ->
      // This branch resolves approval rememberable review_of orchestrator record before the operation continues.
      case approval.rememberable(review_of(orchestrator, record)) {
        Ok(Nil) -> approving(record, remote_escalation.Session)
        Error(reason) -> Error(reason)
      }
  }
}

/// Formulates an Approve decision verifying that an action digest was recorded.
fn approving(
  record: EscalationRecord,
  scope: remote_escalation.Scope,
) -> Result(remote_escalation.Decision, String) {
  // This branch resolves record action admitted record before the operation continues.
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

  // Verify that the requested profile is present in orchestrator offers.
  use Nil <- result.try(case list.contains(offers.profiles, profile) {
    True -> Ok(Nil)
    False -> Error(NotOffered(remote_top.OfferedProfile, profile))
  })

  // Validate model selection against advertised orchestrator models.
  case model {
    None -> Ok(Nil)
    Some(key) ->
      // This branch resolves list contains offers models key before the operation continues.
      case list.contains(offers.models, key) {
        True -> Ok(Nil)
        False -> Error(NotOffered(remote_top.OfferedModel, key))
      }
  }
}

/// Validates that placement configuration is supported by the orchestrator offers.
fn placed(
  offers: remote_top.Offers,
  placement: remote_top.Placement,
) -> Result(Nil, CreateRefusal) {
  // This branch resolves placement before the operation continues.
  case placement {
    remote_top.Folder(path:) ->
      // This branch resolves list any offers folders fn offer offer path path before the operation continues.
      case list.any(offers.folders, fn(offer) { offer.path == path }) {
        True -> Ok(Nil)
        False -> Error(NotOffered(remote_top.OfferedFolder, path))
      }

    remote_top.Workspace(executor:, name:) ->
      // This branch resolves list find offers executors fn offer offer name executor before the operation continues.
      case list.find(offers.executors, fn(offer) { offer.name == executor }) {
        Error(Nil) -> Error(NotOffered(remote_top.OfferedExecutor, executor))
        Ok(offer) -> named(offer.workspaces, name, remote_top.OfferedExecutor)
      }

    remote_top.Pooled(pool:, name:) ->
      // This branch resolves list find offers pools fn offer offer name pool before the operation continues.
      case list.find(offers.pools, fn(offer) { offer.name == pool }) {
        Error(Nil) -> Error(NotOffered(remote_top.OfferedPool, pool))
        Ok(offer) -> named(offer.workspaces, name, remote_top.OfferedPool)
      }
  }
}

/// Validates that workspace name exists in machine offers unless none were registered.
fn named(
  workspaces: List(String),
  name: String,
  what: remote_top.Offered,
) -> Result(Nil, CreateRefusal) {
  // This branch resolves workspaces before the operation continues.
  case workspaces {
    [] -> Ok(Nil)
    listed ->
      // This branch resolves list contains listed name before the operation continues.
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
/// A page that chose no profile gets the first one the box offers now, in the
/// order its operator wrote them, because the box has no profile of that name and
/// a create must name one; a box that offers none is `NoProfile`.
///
/// ## Examples
///
/// ```gleam
/// // ui_top.create(relay, "box", request_id, remote_top.Folder("/w"), Some("default"), None)
/// ```
pub fn create(
  relay: Relay,
  orchestrator: String,
  request_id: String,
  placement: remote_top.Placement,
  profile: Option(String),
  model: Option(String),
) -> Result(String, CreateRefusal) {
  use profile <- result.try(prepare_create(
    relay,
    orchestrator,
    placement,
    profile,
    model,
  ))
  top_relay.create(relay, orchestrator, request_id, placement, profile, model)
  |> result.map_error(Failed)
}

/// Checks the requested placement and model against fresh offers and chooses a
/// profile before any create dispatch, so a lost read cannot imply a create ran.
fn prepare_create(
  relay: Relay,
  orchestrator: String,
  placement: remote_top.Placement,
  profile: Option(String),
  model: Option(String),
) -> Result(String, CreateRefusal) {
  use offers <- result.try(
    top_relay.placements(relay, orchestrator) |> result.map_error(Failed),
  )

  // An explicit choice must be judged as given; only an omitted profile takes
  // the first offered one, and no offer means no create may be dispatched.
  use selected <- result.try(case profile, offers.profiles {
    Some(chosen), _ -> Ok(chosen)
    None, [first, ..] -> Ok(first)
    None, [] -> Error(NoProfile)
  })

  use Nil <- result.try(judge(offers, placement, selected, model))
  Ok(selected)
}

// --- what the composer and the sidebar read ----------------------------------------

/// What the box offers a new session, as the page's offers. A box that cannot be
/// reached, or that refused this daemon, or whose answer would not read, is
/// `Withheld` with the relay's words.
///
/// ## Examples
///
/// ```gleam
/// // ui_top.offers(relay, "box")
/// ```
pub fn offers(relay: Relay, orchestrator: String) -> orchestrators.OffersRead {
  // This branch resolves top_relay placements relay orchestrator before the operation continues.
  case top_relay.placements(relay, orchestrator) {
    Ok(offered) -> orchestrators.Offered(offers: offers_of(offered))
    Error(failure) -> orchestrators.Withheld(why: read_failure(failure))
  }
}

/// The box's offers as the page's: folders as paths and executors and pools as
/// the cards the Code list draws.
///
/// An executor is drawn with the state and workspaces the box reported. The box
/// says how many machines of a pool can take a session and not which, and the Code
/// list only asks whether any can, so a pool's report holds that many placeholder
/// names and no more.
///
/// ## Examples
///
/// ```gleam
/// assert ui_top.offers_of(remote_top.no_offers()).folders == []
/// ```
pub fn offers_of(offered: remote_top.Offers) -> orchestrators.Offers {
  orchestrators.Offers(
    folders: list.map(offered.folders, fn(folder) { folder.path }),
    cards: placements.Cards(
      placements: placements.Placements(
        executors: list.map(offered.executors, executor_card),
        pools: list.map(offered.pools, pool_card),
      ),
      readiness: placements.Checked,
    ),
    profiles: offered.profiles,
    models: offered.models,
  )
}

/// Builds placement card summary representation for an executor offer.
fn executor_card(offer: remote_top.ExecutorOffer) -> placements.Executor {
  placements.Executor(
    name: offer.name,
    report: Some(placements.Report(
      // This branch resolves offer state before the operation continues.
      state: case offer.state {
        remote_top.Ready -> placements.Ready
        remote_top.Degraded -> placements.Degraded
        remote_top.Full -> placements.Full
        remote_top.Down -> placements.Down
      },
      platform: None,
      enforcement: None,
      toolchains: [],
      free_scopes: offer.free_scopes,
      workspaces: offer.workspaces,
      contradiction: None,
    )),
  )
}

/// Builds placement card summary representation for a pool offer.
fn pool_card(offer: remote_top.PoolOffer) -> placements.Pool {
  placements.Pool(
    name: offer.name,
    report: Some(placements.PoolReport(
      executors: [],
      eligible: list.repeat("ready", offer.ready),
      workspaces: offer.workspaces,
    )),
  )
}

/// The first page of the sessions the box lists for this daemon's page, for the
/// sidebar. Only the first page is read, newest first, which is every session of
/// a spawner at the default cap (`remote_top.max_rows` is the cap's own bound).
/// An archived session is not drawn, and neither is a row whose session identity
/// is not in canonical text, since the page builds a link from it.
///
/// ## Examples
///
/// ```gleam
/// // ui_top.listing(relay, "box")
/// ```
pub fn listing(relay: Relay, orchestrator: String) -> orchestrators.ListRead {
  // This branch resolves top_relay sessions relay orchestrator remote_top max_rows before the operation continues.
  case top_relay.sessions(relay, orchestrator, "", remote_top.max_rows) {
    Ok(page) -> orchestrators.Heard(rows: list.filter_map(page.rows, listed_of))
    Error(failure) -> orchestrators.Missed(why: read_failure(failure))
  }
}

/// One of the box's rows as a sidebar row, or nothing for an archived session or
/// one whose identity is not canonical.
///
/// ## Examples
///
/// ```gleam
/// // ui_top.listed_of(row)
/// ```
pub fn listed_of(row: remote_top.Row) -> Result(orchestrators.Listed, Nil) {
  // This branch resolves row activity canonical row session_id before the operation continues.
  case row.activity, canonical(row.session_id) {
    remote_top.Archived, _ | _, False -> Error(Nil)
    _, True ->
      Ok(orchestrators.Listed(
        session: row.session_id,
        name: row.name,
        code: code_of(row.placement),
        activity: activity_of(row.activity),
        updated_ms: row.updated_at,
      ))
  }
}

// Whether an identity is a session identity in the text the daemon writes it in.
/// Canonical keeps this client decision explicit for its callers.
fn canonical(identity: String) -> Bool {
  // This branch resolves ids parse_session_id identity before the operation continues.
  case ids.parse_session_id(identity) {
    Ok(parsed) -> ids.session_id_to_string(parsed) == identity
    Error(_) -> False
  }
}

/// Creates a session on the box for the page and delivers its first message when
/// there is one. The place must be one the page drew from the box's offers: a
/// folder it listed, or a workspace of an executor or pool, never a typed path,
/// which this daemon cannot judge for another machine. `create` judges the rest
/// against a fresh read of the box.
///
/// A session that was made and did not take its first message is `Unsent`: the
/// message may have arrived, so the page offers the session and does not make
/// another. A create whose outcome is unknown is `Refused` in the words that say
/// so.
///
/// ## Examples
///
/// ```gleam
/// // ui_top.found(relay, "box", request_id, message_id, creations.Drawn("/w"), creations.default_roles, "fix it")
/// ```
pub fn found(
  relay: Relay,
  orchestrator: String,
  request_id: String,
  message_id: String,
  place: creations.Place,
  roles: creations.Roles,
  prompt: String,
) -> orchestrators.Founding {
  // This branch resolves made relay orchestrator request_id place roles before the operation continues.
  case made(relay, orchestrator, request_id, place, roles) {
    Error(why) -> orchestrators.Refused(why:)
    Ok(session) ->
      first_message(relay, orchestrator, session, message_id, prompt)
  }
}

/// Creates a remote session after validating placement parameters.
fn made(
  relay: Relay,
  orchestrator: String,
  request_id: String,
  place: creations.Place,
  roles: creations.Roles,
) -> Result(String, String) {
  use placement <- result.try(
    placement_of(place)
    |> result.replace_error(
      "A folder typed here cannot be used on another machine. Choose one it offers.",
    ),
  )
  use profile <- result.try(
    prepare_create(relay, orchestrator, placement, roles.profile, roles.model)
    |> result.map_error(fn(refusal) {
      case refusal {
        Failed(failure) -> read_failure(failure)
        NotOffered(..) | NoProfile -> refusal_words(refusal)
      }
    }),
  )
  use session <- result.try(
    top_relay.create(
      relay,
      orchestrator,
      request_id,
      placement,
      profile,
      roles.model,
    )
    |> result.map_error(top_relay.describe),
  )

  // Validate that returned session identity complies with canonical syntax.
  case canonical(session) {
    True -> Ok(session)
    False ->
      Error(
        orchestrator
        <> " answered with a session identity this page cannot use.",
      )
  }
}

/// Delivers optional initial message after session creation has completed.
fn first_message(
  relay: Relay,
  orchestrator: String,
  session: String,
  message_id: String,
  prompt: String,
) -> orchestrators.Founding {
  // This branch resolves prompt before the operation continues.
  case prompt {
    "" -> orchestrators.Founded(session:)
    text ->
      // This branch resolves send relay orchestrator session message_id text before the operation continues.
      case send(relay, orchestrator, session, message_id, text) {
        relayed.Done -> orchestrators.Founded(session:)
        relayed.Refusal(_) | relayed.Unknown(_) ->
          orchestrators.Unsent(session:)
      }
  }
}

/// Maps UI place configurations to backend remote placement requests.
fn placement_of(place: creations.Place) -> Result(remote_top.Placement, Nil) {
  // This branch resolves place before the operation continues.
  case place {
    creations.Drawn(path) -> Ok(remote_top.Folder(path:))
    creations.Registered(executor, workspace) ->
      Ok(remote_top.Workspace(executor:, name: workspace))
    creations.Pooled(pool, workspace) ->
      Ok(remote_top.Pooled(pool:, name: workspace))
    creations.Typed(_) -> Error(Nil)
  }
}

/// A create's refusal in words for the person.
///
/// ## Examples
///
/// ```gleam
/// assert ui_top.refusal_words(ui_top.NoProfile)
///   == "The orchestrator offers no profile to start a session with."
/// ```
pub fn refusal_words(refusal: CreateRefusal) -> String {
  // This branch resolves refusal before the operation continues.
  case refusal {
    NotOffered(what:, name:) ->
      remote_top.describe_refusal(remote_top.NotOffered(what:, name:))
    NoProfile -> "The orchestrator offers no profile to start a session with."
    Failed(failure:) -> top_relay.describe(failure)
  }
}
