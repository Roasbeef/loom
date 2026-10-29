//// The sending end of a page that starts and drives sessions on another
//// orchestrator (protocol-change/094).
////
//// The receiving end serves the placements and top-level session operations
//// from `client/top_host` through `client/remote/peer_service`. This module is
//// how the laptop's daemon asks for a page of its web view. It has no screen
//// in it: the web view calls these functions and draws what they return.
////
//// ## Dial on demand, and nothing kept
////
//// Each call connects to the orchestrator's pinned peer if it is not connected
//// and asks that peer's stable endpoint, so no connection is held between
//// calls and a laptop that sleeps costs the next call one reconnect. Each
//// attempt discovers the supported revision and serving epoch, then fences
//// dispatch to that epoch within the original call deadline. The orchestrator is a configured `[orchestrators.<name>]`
//// key and a name that is not configured is a definitive failure, so nothing
//// the page sends is turned into a node. `Placements` is asked on every call,
//// because the composer must show what the box allows now, and nothing here
//// remembers an answer.
////
//// ## What a lost link does to each call
////
//// The box keeps running a session whatever happens to the link, and these
//// calls are idempotent by the identities they carry, so what a call does when
//// the link fails depends on whether anything could have happened:
////
//// - A call that cannot connect fails at once with `Unreachable`. A create is
////   never queued.
//// - A create or a message that did connect and then lost its answer is sent
////   again, with the same request id or message id, for up to
////   `retry_window_ms`, pausing 500 ms and doubling to 4 s. The box answers the
////   same session for a request id it has seen, and the same landing for a
////   message id, so a resend cannot make a second session or deliver twice.
////   If the window ends without an answer the call fails with `Silent`: the
////   outcome is unknown, and the next page of sessions names the session if it
////   was made (`session_for_request`).
//// - A read, a stop, an archive and a decision are asked once. A decision is
////   not resent, because the person decides again from the next page, and the
////   box judges the sequence they were shown, so the first decision wins.
////
//// A first refusal is definitive except `NotYetOpen` and `StoreFailure`, which
//// a create or a message retries. A create may already have reserved its
//// identity before either refusal, so neither proves that nothing changed. Once
//// an attempt has no conclusive answer, a later refusal or failed dial cannot
//// prove what happened to it; the relay keeps the outcome unknown.
////
//// ## A port that disappears
////
//// A missing stable endpoint means unsupported, not a particular old build.
//// After dispatch, the endpoint may have forwarded a request before it died,
//// and that independent recipient can still complete it. A monitor firing at
//// that point therefore means `Silent`, just as a lost answer does.
////
//// ## Flow
////
//// `over` → `dial` → `once` → `resending` → `placements` → `create` →
//// `sessions` → `describe`
////
//// 1. `over` builds the relay of a daemon over its membership and its
////    configured orchestrators.
//// 2. `dial` resolves a name to its pinned peer and connects.
//// 3. `once` asks one question once, and `resending` asks it again with the
////    same identities until it is answered or the window ends.
//// 4. `placements`, `create`, `sessions` and the calls beside them are the
////    page's API, each decoding the answer with a total decoder.
//// 5. `describe` words a failure for the person at the page.

import client/distribution.{type Membership}
import client/orchestrators.{type Orchestrator}
import client/remote/address
import client/remote/peer_client
import client/remote/peer_service
import client/remote/peer_top
import client/remote_escalation.{type Answer, type Decider, type Decision}
import client/remote_mail
import client/remote_top.{type Offers, type Placement, type SessionsPage}
import client/roster.{type Roster}
import core/json
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import session_view/remote_transcript
import weft/poll

/// How long a create or a message is resent for, in milliseconds, counted from
/// the first try.
pub const retry_window_ms = 30_000

/// How long a create waits for one answer, in milliseconds. It is the longest
/// call because the box writes its catalogue and makes the session's store.
pub const create_ms = 30_000

/// How long every other call waits for one answer, in milliseconds.
pub const call_ms = 7000

/// The bound on connecting to a peer that is not connected yet. It is shorter
/// than a call so that an unreachable host costs the page little.
pub const connect_ms = 1500

/// The first pause between the tries of a resend, in milliseconds. It doubles up
/// to `longest_pause_ms`.
pub const first_pause_ms = 500

/// The longest pause between the tries of a resend, in milliseconds.
pub const longest_pause_ms = 4000

/// How long each part of a call may take. `production` is what a daemon uses;
/// a test shortens it so that a resend window can end inside a test.
pub type Timing {
  Timing(
    /// How long a create or a message is resent for.
    retry_window_ms: Int,
    /// How long a create waits for one answer.
    create_ms: Int,
    /// How long every other call waits for one answer.
    call_ms: Int,
    /// The first pause between the tries of a resend.
    first_pause_ms: Int,
    /// The longest pause between the tries of a resend.
    longest_pause_ms: Int,
  )
}

/// The timing a daemon uses.
///
/// ## Examples
///
/// ```gleam
/// assert top_relay.production().retry_window_ms == 30_000
/// ```
pub fn production() -> Timing {
  Timing(
    retry_window_ms:,
    create_ms:,
    call_ms:,
    first_pause_ms:,
    longest_pause_ms:,
  )
}

/// How a name becomes a connected port, or why it did not: the production
/// answer connects to the orchestrator's pinned peer (`over`), and a test
/// supplies its own.
pub type Dial =
  fn(String) -> Result(address.Address(peer_service.Message), Failure)

/// A daemon's way of reaching the orchestrators it lists.
pub opaque type Relay {
  Relay(dial: Dial, timing: Timing)
}

/// Why a call did not give the page its answer.
pub type Failure {
  /// No `[orchestrators.<name>]` has this name. Nothing was sent.
  NotConfigured(
    /// The name the page used.
    name: String,
  )

  /// The orchestrator could not be connected to. Nothing was sent, and a create
  /// is not queued.
  Unreachable

  /// The orchestrator was connected and did not answer, or answered only
  /// silence for the whole resend window. The thing may have happened.
  Silent

  /// A legacy build mismatch report. A port's disappearance alone cannot
  /// establish this, so the production relay does not infer it from a monitor.
  OlderBuild

  /// The orchestrator refused, and said why.
  Refused(
    /// The refusal.
    refusal: remote_top.Refusal,
  )

  /// The peer does not advertise the required operation.
  Unsupported

  /// The peer changed incarnation before dispatch.
  PeerChanged

  /// Feature negotiation returned malformed or mismatched data.
  InvalidPeer

  /// The request exceeds the operation envelope before dispatch.
  RequestTooLarge

  /// The orchestrator answered and the answer would not read. Nothing of it is
  /// used.
  Unreadable(
    /// What was wrong with it.
    reason: String,
  )
}

/// Words a failure for the person at the page.
///
/// ## Examples
///
/// ```gleam
/// assert top_relay.describe(top_relay.Unreachable)
///   == "the orchestrator is not reachable"
/// ```
pub fn describe(failure: Failure) -> String {
  // This match resolves failure before the surrounding protocol step continues.
  // This match resolves failure before the enclosing validation continues.
  case failure {
    NotConfigured(name:) -> name <> " is not one of this daemon's orchestrators"
    Unreachable -> "the orchestrator is not reachable"
    Silent ->
      "the orchestrator did not answer, so it is not known whether it happened"
    OlderBuild -> "the orchestrator runs an older Loom"
    Unsupported -> "the orchestrator does not support this operation"
    PeerChanged -> "the orchestrator changed while negotiating; try again"
    InvalidPeer -> "the orchestrator's feature response could not be read"
    RequestTooLarge -> "the request exceeds the peer operation size limit"
    Refused(refusal:) -> remote_top.describe_refusal(refusal)
    Unreadable(reason:) ->
      "the orchestrator's answer could not be read: " <> reason
  }
}

/// The relay of a daemon over its membership and its configured orchestrators.
///
/// ## Examples
///
/// ```gleam
/// // top_relay.over(membership, orchestrators)
/// ```
pub fn over(membership: Membership, configured: Roster(Orchestrator)) -> Relay {
  Relay(dial: dial(membership, configured, _), timing: production())
}

/// A relay that reaches ports by `dial`, with the given timing. It is how a test
/// plays the network, and how a daemon with its own way of connecting would
/// plug in.
///
/// ## Examples
///
/// ```gleam
/// // top_relay.through(fn(_name) { Ok(port) }, top_relay.production())
/// ```
pub fn through(dial: Dial, timing: Timing) -> Relay {
  Relay(dial:, timing:)
}

// --- the page's calls --------------------------------------------------------------

/// What the orchestrator offers the page now: its folders, the executors and
/// pools its table lists with their health and workspaces, and its profiles and
/// models. It is asked on every call and remembered by no one.
///
/// ## Examples
///
/// ```gleam
/// // top_relay.placements(relay, "box")
/// ```
pub fn placements(relay: Relay, name: String) -> Result(Offers, Failure) {
  use json <- result.try(once(relay, name, "094.placements.1", json.Array([])))
  remote_top.decode_offers(json) |> result.map_error(Unreadable)
}

/// Starts a session on the orchestrator and answers its identity. The request id
/// is the page's, one per submit, and the same id is sent again until the box
/// answers or the window ends, so a lost answer cannot make a second session.
///
/// ## Examples
///
/// ```gleam
/// // top_relay.create(relay, "box", request_id, remote_top.Folder("/srv/work"), "default", None)
/// ```
pub fn create(
  relay: Relay,
  name: String,
  request_id: String,
  placement: Placement,
  profile: String,
  model: Option(String),
) -> Result(String, Failure) {
  let body =
    json.Array([
      json.String(request_id),
      remote_top.encode_placement(placement),
      json.String(profile),
      case model {
        Some(value) -> json.String(value)
        None -> json.Null
      },
    ])
  use value <- result.try(resending(
    relay,
    name,
    "094.create.1",
    body,
    relay.timing.create_ms,
  ))

  // A successful create must return the session's identity.
  case value {
    json.String(session) -> Ok(session)
    json.Object(_)
    | json.Array(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(Unreadable("invalid create reply"))
  }
}

/// One page of the sessions this daemon's page started on the orchestrator,
/// newest first. `after` is the last session of the page before, or the empty
/// text for the first.
///
/// ## Examples
///
/// ```gleam
/// // top_relay.sessions(relay, "box", "", remote_top.max_rows)
/// ```
pub fn sessions(
  relay: Relay,
  name: String,
  after: String,
  limit: Int,
) -> Result(SessionsPage, Failure) {
  use json <- result.try(once(
    relay,
    name,
    "094.sessions.1",
    json.Array([json.String(after), json.Int(limit)]),
  ))
  remote_top.decode_page(json) |> result.map_error(Unreadable)
}

/// The most pages `all_sessions` reads. The box lists only sessions that are not
/// archived, and a spawner holds at most 64 of them (`max_sessions`), so the
/// listing fits one page and the bound only stops a box that never says it is
/// done.
pub const max_pages = 8

/// Every session of this daemon's page on the orchestrator, newest first, read
/// a page at a time until the box says there are no more or `max_pages` pages
/// have been read. A page that fails ends the read with its failure, and nothing
/// of the pages before it is returned, so the list a page draws is one read of
/// the box and not a join of two.
///
/// ## Examples
///
/// ```gleam
/// // top_relay.all_sessions(relay, "box")
/// ```
pub fn all_sessions(
  relay: Relay,
  name: String,
) -> Result(List(remote_top.Row), Failure) {
  read_pages(relay, name, "", max_pages, [])
}

/// Read pages keeps this client operation’s decoding or state decision in one place.
fn read_pages(
  relay: Relay,
  name: String,
  after: String,
  pages_left: Int,
  read: List(remote_top.Row),
) -> Result(List(remote_top.Row), Failure) {
  use page <- result.try(sessions(relay, name, after, remote_top.max_rows))
  let read = list.append(read, page.rows)

  // This match resolves page.more, list.last(page.rows), pages_left before the surrounding protocol step continues.
  // This match resolves page.more, list.last(page.rows), pages_left before the enclosing validation continues.
  case page.more, list.last(page.rows), pages_left {
    remote_top.Last, _, _ | remote_top.Further, Error(Nil), _ -> Ok(read)
    remote_top.Further, Ok(_), 1 -> Ok(read)
    remote_top.Further, Ok(last), _ ->
      read_pages(relay, name, last.session_id, pages_left - 1, read)
  }
}

/// One bounded page of a session's transcript.
///
/// ## Examples
///
/// ```gleam
/// // top_relay.history(relay, "box", session, 0, 50)
/// ```
pub fn history(
  relay: Relay,
  name: String,
  session: String,
  cursor: Int,
  limit: Int,
) -> Result(remote_transcript.Page, Failure) {
  use json <- result.try(once(
    relay,
    name,
    "094.history.1",
    json.Array([json.String(session), json.Int(cursor), json.Int(limit)]),
  ))
  remote_transcript.decode(json) |> result.map_error(Unreadable)
}

/// Delivers a message to a session's main strand and answers how it landed. The
/// message id is the page's, and the same id is sent again until the box answers
/// or the window ends, so a lost answer cannot deliver it twice.
///
/// ## Examples
///
/// ```gleam
/// // top_relay.send(relay, "box", session, message_id, "hello")
/// ```
pub fn send(
  relay: Relay,
  name: String,
  session: String,
  message_id: String,
  text: String,
) -> Result(remote_mail.Landing, Failure) {
  use json <- result.try(resending(
    relay,
    name,
    "094.send.1",
    json.Array([
      json.String(session),
      json.String(message_id),
      json.String(text),
    ]),
    relay.timing.call_ms,
  ))
  remote_mail.decode_landing(json) |> result.map_error(Unreadable)
}

/// Stops a session's current run.
///
/// ## Examples
///
/// ```gleam
/// // top_relay.stop(relay, "box", session)
/// ```
pub fn stop(
  relay: Relay,
  name: String,
  session: String,
) -> Result(Nil, Failure) {
  use value <- result.try(once(
    relay,
    name,
    "094.stop.1",
    json.Array([json.String(session)]),
  ))

  // A stop acknowledgement has no additional payload.
  case value {
    json.Null -> Ok(Nil)
    json.Object(_)
    | json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_) -> Error(Unreadable("invalid stop reply"))
  }
}

/// Archives a session. There is no delete: deleting is done on the
/// orchestrator's own page.
///
/// ## Examples
///
/// ```gleam
/// // top_relay.archive(relay, "box", session)
/// ```
pub fn archive(
  relay: Relay,
  name: String,
  session: String,
) -> Result(Nil, Failure) {
  use value <- result.try(once(
    relay,
    name,
    "094.archive.1",
    json.Array([json.String(session)]),
  ))

  // An archive acknowledgement has no additional payload.
  case value {
    json.Null -> Ok(Nil)
    json.Object(_)
    | json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_) -> Error(Unreadable("invalid archive reply"))
  }
}

/// Sends the person's decision about a session's request. It is asked once: a
/// decision made while the link is down is refused with the reason, the request
/// stays pending on the box, and the person decides again from the next page.
/// The box judges the sequence the person was shown, so the first decision wins
/// wherever it was made.
///
/// ## Examples
///
/// ```gleam
/// // top_relay.resolve(relay, "box", session, "policy-ab", decision, 3, decider)
/// ```
pub fn resolve(
  relay: Relay,
  name: String,
  session: String,
  escalation_id: String,
  decision: Decision,
  expected_seq: Int,
  decided_by: Decider,
) -> Result(Answer, Failure) {
  let body =
    json.Array([
      json.String(session),
      json.String(escalation_id),
      peer_top.encode_decision(decision),
      json.Int(expected_seq),
      json.String(decided_by.principal),
      json.String(decided_by.name),
    ])
  use value <- result.try(once(relay, name, "094.resolve.1", body))
  peer_top.decode_answer(value) |> result.map_error(Unreadable)
}

/// The session a create made, found in a page of the orchestrator's sessions by
/// the request id the create carried. This is how a page whose create ended
/// `Silent` learns whether the session was made: the box lists every session
/// with the request id that made it.
///
/// ## Examples
///
/// ```gleam
/// assert top_relay.session_for_request(remote_top.empty_page(), "id") == None
/// ```
pub fn session_for_request(
  page: SessionsPage,
  request_id: String,
) -> Option(String) {
  list.find(page.rows, fn(row) { row.request_id == request_id })
  |> result.map(fn(row) { row.session_id })
  |> option.from_result
}

// --- asking ----------------------------------------------------------------------------

// Connects to the pinned peer of a configured orchestrator, so that the port is
// reached on a connection that exists. A name the roster does not hold is the
// one definitive failure, and every way of not reaching the node is
// `Unreachable`.
/// Dial keeps this client operation’s decoding or state decision in one place.
fn dial(
  membership: Membership,
  configured: Roster(Orchestrator),
  name: String,
) -> Result(address.Address(peer_service.Message), Failure) {
  use orchestrator <- result.try(
    orchestrators.find(roster.rows(configured), name)
    |> result.replace_error(NotConfigured(name:)),
  )
  use peer <- result.try(
    distribution.peer(membership, orchestrator.node)
    |> result.replace_error(Unreachable),
  )
  use Nil <- result.try(
    distribution.connect(peer, connect_ms) |> result.replace_error(Unreachable),
  )
  Ok(address.Address(
    node: distribution.node(peer),
    name: peer_service.default(),
  ))
}

/// Uses one budget for feature discovery and the fenced operation.
fn once(
  relay: Relay,
  name: String,
  revision: String,
  body: json.JsonValue,
) -> Result(json.JsonValue, Failure) {
  use at <- result.try(relay.dial(name))
  peer_client.call(at, revision, body, relay.timing.call_ms)
  |> result.map_error(peer_failure)
  |> result.try(fn(answer) { answer |> result.map_error(Refused) })
}

/// Converts negotiation outcomes without implying an unsupported peer's age.
fn peer_failure(failure: peer_client.Failure) -> Failure {
  case failure {
    peer_client.Unsupported -> Unsupported
    peer_client.Unavailable -> Unreachable
    peer_client.Stale -> PeerChanged
    peer_client.InvalidFeatures -> InvalidPeer
    peer_client.RequestTooLarge -> RequestTooLarge
    peer_client.ReplyLost -> Silent
    peer_client.ReplyTooLarge ->
      Unreadable("the peer response exceeds the size limit")
    peer_client.Unreadable -> Unreadable("the peer reply could not be read")
  }
}

// A resend remembers whether an earlier attempt may have changed remote state.
type Tries {
  Fresh
  After
}

// One question, asked until the box answers or the window ends. `ask` is given
// the address and the longest it may wait, which is what is left of the window,
// so a slow answer cannot stretch it. The first try that cannot connect fails at
// once, because nothing was sent and the link was already down; a later one
// that cannot connect is a link that dropped after a send, and the thing may
// have happened, so it is tried again.
/// Resending keeps this client operation’s decoding or state decision in one place.
fn resending(
  relay: Relay,
  name: String,
  revision: String,
  body: json.JsonValue,
  call_ms: Int,
) -> Result(json.JsonValue, Failure) {
  let clock = poll.monotonic()
  let started = clock.now()
  let folded =
    poll.fold_until(
      clock:,
      within: relay.timing.retry_window_ms,
      every: poll.Doubling(
        from: relay.timing.first_pause_ms,
        to: relay.timing.longest_pause_ms,
      ),
      from: Fresh,
      attempt: fn(tries) {
        let left =
          int.max(0, relay.timing.retry_window_ms - { clock.now() - started })

        // A later dial cannot settle the effect of an unanswered attempt.
        case relay.dial(name), tries {
          Error(failure), Fresh -> poll.Broken(failure)
          Error(NotConfigured(_)), After -> poll.Broken(Silent)
          Error(_), After -> poll.Pending(After)
          Ok(at), _ ->
            case peer_client.call(at, revision, body, int.min(call_ms, left)) {
              Ok(Ok(answer)) -> poll.Settled(answer)
              Ok(Error(refusal)) ->
                case remote_top.retryable(refusal), tries {
                  True, _ -> poll.Pending(After)
                  False, Fresh -> poll.Broken(Refused(refusal))
                  False, After -> poll.Broken(Silent)
                }
              Error(peer_client.ReplyLost) -> poll.Pending(After)
              Error(peer_client.Unreadable) ->
                poll.Broken(Unreadable("the peer reply could not be read"))
              Error(peer_client.ReplyTooLarge) ->
                poll.Broken(Unreadable(
                  "the peer response exceeds the size limit",
                ))
              Error(failure) ->
                case tries {
                  Fresh -> poll.Broken(peer_failure(failure))
                  After -> poll.Broken(Silent)
                }
            }
        }
      },
    )

  // Expiry after any uncertain attempt retains that uncertainty.
  case folded {
    poll.Answer(value:) -> Ok(value)
    poll.Failure(error:) -> Error(error)
    poll.RanOut(state: After) | poll.RanOut(state: Fresh) -> Error(Silent)
  }
}

/// Whether a failure leaves a dispatched change possibly done, so that a page
/// keeps what it sent and reconciles instead of asking again blindly. An
/// unreadable send landing may follow delivery; the same failure on a read
/// means only that the returned data could not be used.
///
/// ## Examples
///
/// ```gleam
/// assert top_relay.outcome_unknown(top_relay.Silent)
/// assert !top_relay.outcome_unknown(top_relay.Unreachable)
/// ```
pub fn outcome_unknown(failure: Failure) -> Bool {
  // This match resolves failure before the surrounding protocol step continues.
  // This match resolves failure before the enclosing validation continues.
  case failure {
    Silent | Unreadable(_) | Refused(remote_top.StoreFailure(_)) -> True
    NotConfigured(_)
    | Unreachable
    | OlderBuild
    | Unsupported
    | PeerChanged
    | InvalidPeer
    | RequestTooLarge
    | Refused(_) -> False
  }
}
