//// The sending end of a page that starts and drives sessions on another
//// orchestrator (protocol-change/094).
////
//// The receiving end is the orchestrator port's `Placements`, `TopCreate`,
//// `TopSessions`, `TopHistory`, `TopSend`, `TopStop`, `TopArchive` and
//// `TopResolve` (`client/remote/orchestrator_port`, served by
//// `client/top_host`). This module is how the laptop's daemon asks them for a
//// page of its web view. It has no screen in it: the web view calls these
//// functions and draws what they return.
////
//// ## Dial on demand, and nothing kept
////
//// Each call connects to the orchestrator's pinned peer if it is not connected
//// and asks that peer's port, as `client/remote/remote_spawner` does, so no
//// connection is held between calls and a laptop that sleeps costs the next
//// call one reconnect. The orchestrator is a configured `[orchestrators.<name>]`
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
//// A refusal the box makes is definitive except `NotYetOpen` and
//// `StoreFailure`, which say it could not do the thing now, and which a create
//// or a message treats as silence.
////
//// ## Older builds
////
//// Both ends must run the same build (protocol-change/078). A port that does not
//// know these messages stops on them, which a connected caller sees as the port
//// being gone. That is reported as `OlderBuild`, and when it is the answer to
//// the last try of a resend window it is what the call fails with.
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
import client/remote/orchestrator_port.{type Silence, AskTimedOut, PortGone}
import client/remote_escalation.{type Answer, type Decider, type Decision}
import client/remote_mail
import client/remote_top.{type Offers, type Placement, type SessionsPage}
import client/roster.{type Roster}
import gleam/int
import gleam/list
import gleam/option.{type Option}
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
  fn(String) -> Result(address.Address(orchestrator_port.Message), Failure)

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

  /// The orchestrator's port was gone once the connection was made, which is
  /// what a build that does not know these messages looks like.
  OlderBuild

  /// The orchestrator refused, and said why.
  Refused(
    /// The refusal.
    refusal: remote_top.Refusal,
  )

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
  case failure {
    NotConfigured(name:) -> name <> " is not one of this daemon's orchestrators"
    Unreachable -> "the orchestrator is not reachable"
    Silent ->
      "the orchestrator did not answer, so it is not known whether it happened"
    OlderBuild -> "the orchestrator runs an older Loom"
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
  use json <- result.try(
    once(relay, name, orchestrator_port.ask_placements(_, relay.timing.call_ms)),
  )
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
  resending(relay, name, fn(at, wait_ms) {
    orchestrator_port.ask_top_create(
      at,
      request_id,
      placement,
      profile,
      model,
      int.min(relay.timing.create_ms, wait_ms),
    )
  })
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
  use json <- result.try(
    once(relay, name, orchestrator_port.ask_top_sessions(
      _,
      after,
      limit,
      relay.timing.call_ms,
    )),
  )
  remote_top.decode_page(json) |> result.map_error(Unreadable)
}

/// The most pages `all_sessions` reads. A spawner holds at most 64 sessions that
/// are not archived (`max_sessions`), and archived ones are listed after them
/// for as long as they exist, so eight pages of 64 reach well past any session a
/// page still draws.
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

fn read_pages(
  relay: Relay,
  name: String,
  after: String,
  pages_left: Int,
  read: List(remote_top.Row),
) -> Result(List(remote_top.Row), Failure) {
  use page <- result.try(sessions(relay, name, after, remote_top.max_rows))
  let read = list.append(read, page.rows)
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
  use json <- result.try(
    once(relay, name, orchestrator_port.ask_top_history(
      _,
      session,
      cursor,
      limit,
      relay.timing.call_ms,
    )),
  )
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
  use json <- result.try(
    resending(relay, name, fn(at, wait_ms) {
      orchestrator_port.ask_top_send(
        at,
        session,
        message_id,
        text,
        int.min(relay.timing.call_ms, wait_ms),
      )
    }),
  )
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
  once(relay, name, orchestrator_port.ask_top_stop(
    _,
    session,
    relay.timing.call_ms,
  ))
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
  once(relay, name, orchestrator_port.ask_top_archive(
    _,
    session,
    relay.timing.call_ms,
  ))
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
  once(relay, name, orchestrator_port.ask_top_resolve(
    _,
    session,
    escalation_id,
    decision,
    expected_seq,
    decided_by,
    relay.timing.call_ms,
  ))
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
fn dial(
  membership: Membership,
  configured: Roster(Orchestrator),
  name: String,
) -> Result(address.Address(orchestrator_port.Message), Failure) {
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
    name: orchestrator_port.default(),
  ))
}

// One question, asked once.
fn once(
  relay: Relay,
  name: String,
  ask: fn(address.Address(orchestrator_port.Message)) ->
    Result(Result(a, remote_top.Refusal), Silence),
) -> Result(a, Failure) {
  use at <- result.try(relay.dial(name))
  case ask(at) {
    Ok(Ok(answer)) -> Ok(answer)
    Ok(Error(refusal)) -> Error(Refused(refusal:))
    Error(PortGone) -> Error(OlderBuild)
    Error(AskTimedOut) -> Error(Silent)
  }
}

// What a resend remembers between tries: whether anything has been sent yet, and
// how the last try failed.
type Tries {
  Fresh
  After(last: Failure)
}

// One question, asked until the box answers or the window ends. `ask` is given
// the address and the longest it may wait, which is what is left of the window,
// so a slow answer cannot stretch it. The first try that cannot connect fails at
// once, because nothing was sent and the link was already down; a later one
// that cannot connect is a link that dropped after a send, and the thing may
// have happened, so it is tried again.
fn resending(
  relay: Relay,
  name: String,
  ask: fn(address.Address(orchestrator_port.Message), Int) ->
    Result(Result(a, remote_top.Refusal), Silence),
) -> Result(a, Failure) {
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
          int.max(
            relay.timing.call_ms,
            relay.timing.retry_window_ms - { clock.now() - started },
          )
        case relay.dial(name), tries {
          Error(NotConfigured(_) as failure), _ -> poll.Broken(failure)
          Error(failure), Fresh -> poll.Broken(failure)
          Error(failure), After(_) -> poll.Pending(After(failure))
          Ok(at), _ ->
            case ask(at, left) {
              Ok(Ok(answer)) -> poll.Settled(answer)
              Ok(Error(refusal)) ->
                case remote_top.retryable(refusal) {
                  True -> poll.Pending(After(Refused(refusal:)))
                  False -> poll.Broken(Refused(refusal:))
                }
              Error(PortGone) -> poll.Pending(After(OlderBuild))
              Error(AskTimedOut) -> poll.Pending(After(Silent))
            }
        }
      },
    )
  case folded {
    poll.Answer(value:) -> Ok(value)
    poll.Failure(error:) -> Error(error)

    // The window ended on a try that failed. A refusal the box made, such as
    // "not yet open", is what it said last and is what the page is told; every
    // other failure is a lost answer and the outcome is not known.
    poll.RanOut(state: After(Refused(refusal:))) -> Error(Refused(refusal:))
    poll.RanOut(state: After(OlderBuild)) -> Error(OlderBuild)
    poll.RanOut(state: After(Unreachable))
    | poll.RanOut(state: After(Silent))
    | poll.RanOut(state: After(NotConfigured(_)))
    | poll.RanOut(state: After(Unreadable(_)))
    | poll.RanOut(state: Fresh) -> Error(Silent)
  }
}

/// Whether a failure leaves the thing possibly done, as `Silent` does, so that
/// a page keeps what it sent and reconciles instead of asking again blindly.
///
/// ## Examples
///
/// ```gleam
/// assert top_relay.outcome_unknown(top_relay.Silent)
/// assert !top_relay.outcome_unknown(top_relay.Unreachable)
/// ```
pub fn outcome_unknown(failure: Failure) -> Bool {
  case failure {
    Silent -> True
    NotConfigured(_) | Unreachable | OlderBuild | Refused(_) | Unreadable(_) ->
      False
  }
}
