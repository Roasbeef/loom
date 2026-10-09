//// Peer discovery and delivery through resident-only daemon routing.
////
//// A link is an operator decision, independent of lineage, child custody,
//// repository similarity, or permission to join. The sender's durable index
//// bounds discovery; the recipient's grant remains the delivery authority.
//// Saved sessions are described without opening their conversation stores,
//// and a message to a saved session waits in the sender's outbox until its
//// owner opens it. Nothing here opens a session.
////
//// ## Flow
////
//// `routed` → `link` → `send` → `record_attempt` → `attempt` → `deliver` → `roster`
////
//// 1. `routed` and `described` turn a session identity into the recipient's
////    endpoint and its catalogue description, here or on the owning
////    orchestrator.
//// 2. `link` and `unlink` change an exact directional link, the recipient's
////    grant first.
//// 3. `send` records the message in the sender's outbox, then `record_attempt`
////    asks the recipient once through `attempt` and `deliver`, and writes down
////    whether it was admitted, refused, or has to wait. `resend` is the same
////    attempt for the drainer.
//// 4. `roster` and `inspect` list what the sender may address, asking each
////    recipient's owner for its description and its strands.
//// 5. `router` serves the same operations to a program, with the launching
////    strand's identity.

import broker/framing
import broker/policy
import client/peer_mail
import client/peer_outbox
import client/session_directory
import codemode/internal/args
import codemode/satellite
import core/json.{type JsonValue}
import core/msgpack
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import tools/tool

/// Narrow lookups over the daemon manager, evaluated outside its mailbox.
pub type Directory {
  Directory(
    /// Looks up only a currently resident endpoint; never opens a session. A
    /// session that its owner holds saved is `NotOpen`, and one no catalogue
    /// holds is `Refused`.
    resolve: fn(String) -> Result(peer_mail.Endpoint, peer_mail.Failure),
    /// Current catalogue metadata and lifecycle, without opening a session.
    describe: fn(String) -> Result(JsonValue, String),
  )
}

/// A `Directory.resolve` that finds a recipient on any orchestrator.
///
/// A session resident here is answered by `local`, with no question to anyone:
/// residency is proof that this orchestrator owns it. Only a miss consults
/// `sessions`, and only to learn where the session lives. An owner that is
/// another orchestrator gets the endpoint `sessions.reach` builds, so every
/// operation in this module reaches it exactly as it reaches a local one. An
/// owner that could not be asked is `Unreachable`, because the session may
/// live on exactly the machine that did not answer. `Here` and `Unknown` leave
/// `local`'s failure standing, and `local` is what knows which it is: `NotOpen`
/// when this catalogue holds the session and it is not resident, `Refused`
/// when it exists nowhere.
///
/// ## Examples
///
/// ```gleam
/// // peers.Directory(resolve: peers.routed(local, sessions), describe: describe)
/// ```
pub fn routed(
  local: fn(String) -> Result(peer_mail.Endpoint, peer_mail.Failure),
  sessions: session_directory.Directory,
) -> fn(String) -> Result(peer_mail.Endpoint, peer_mail.Failure) {
  fn(session) {
    case local(session) {
      Ok(endpoint) -> Ok(endpoint)
      Error(refusal) ->
        case sessions.lookup(session) {
          Ok(session_directory.Elsewhere(orchestrator: owner)) ->
            Ok(sessions.reach(owner, session))
          Error(session_directory.Unreachable(..)) ->
            Error(peer_mail.Unreachable)
          Ok(session_directory.Here) | Error(session_directory.Unknown) ->
            Error(refusal)
        }
    }
  }
}

/// A `Directory.describe` that finds a session on any orchestrator.
///
/// A session this catalogue describes is answered by `local`, with no question
/// to anyone. Only a miss consults `sessions`, as `routed` does, and an owner
/// that is another orchestrator describes the session from its own catalogue
/// (`sessions.describe`), so a saved session on another orchestrator is
/// described without being opened, exactly as a local one is. An owner that
/// could not be asked is `owner unreachable`, which the roster shows as the
/// row's `unavailable` metadata. `Here` and `Unknown` leave `local`'s error
/// standing.
///
/// ## Examples
///
/// ```gleam
/// // peers.Directory(resolve: resolve, describe: peers.described(local, sessions))
/// ```
pub fn described(
  local: fn(String) -> Result(JsonValue, String),
  sessions: session_directory.Directory,
) -> fn(String) -> Result(JsonValue, String) {
  fn(session) {
    case local(session) {
      Ok(view) -> Ok(view)
      Error(refusal) ->
        case sessions.lookup(session) {
          Ok(session_directory.Elsewhere(orchestrator: owner)) ->
            sessions.describe(owner, session)
          Error(session_directory.Unreachable(..)) ->
            Error(peer_mail.unreachable_reason)
          Ok(session_directory.Here) | Error(session_directory.Unknown) ->
            Error(refusal)
        }
    }
  }
}

/// The source session's authenticated endpoint and optional daemon directory.
pub type Wiring {
  Wiring(
    /// Bound by session assembly, never selected by tool arguments.
    own: peer_mail.Endpoint,
    /// Local fallback metadata for an embedded session.
    metadata: JsonValue,
    /// The daemon's resident-only directory, absent in an embedded host.
    directory: Option(Directory),
  )
}

/// Changes an exact directional link after owner authorization by the control
/// server. Creation writes recipient permission before publishing discovery;
/// revocation removes discovery before removing recipient permission. A failed
/// half is reported and the same operation can be retried idempotently.
///
/// ## Examples
///
/// ```gleam
/// // peers.link(source, recipient, "main", "reviewer", peer_mail.BusyOnly)
/// ```
pub fn link(
  source: peer_mail.Endpoint,
  recipient: peer_mail.Endpoint,
  from: String,
  to: String,
  wake: peer_mail.Wake,
) -> Result(JsonValue, String) {
  use _ <- result.try(
    recipient.call(
      peer_mail.Allow(peer_mail.Grant(source.session, from, to, wake)),
    )
    |> peer_mail.plain,
  )
  source.call(peer_mail.Link(from, recipient.session, to)) |> peer_mail.plain
}

/// Removes one exact directional link; unrelated grants retain their policy.
///
/// ## Examples
///
/// ```gleam
/// // peers.unlink(source, recipient, "main", "reviewer")
/// ```
pub fn unlink(
  source: peer_mail.Endpoint,
  recipient: peer_mail.Endpoint,
  from: String,
  to: String,
) -> Result(JsonValue, String) {
  use _ <- result.try(
    source.call(peer_mail.Unlink(from, recipient.session, to))
    |> peer_mail.plain,
  )
  case
    recipient.call(
      peer_mail.Revoke(peer_mail.Grant(
        source.session,
        from,
        to,
        peer_mail.BusyOnly,
      )),
    )
  {
    Ok(value) -> Ok(value)

    // The source link is already gone. Preserve that outcome so the operator
    // can retry revocation without mistaking this for a full refusal. A
    // recipient on an orchestrator that does not answer lands here too.
    Error(failure) ->
      Ok(
        json.Object([
          #("outgoing_link_removed", json.Bool(True)),
          #(
            "recipient_grant",
            json.String("revoke failed: " <> peer_mail.reason(failure)),
          ),
        ]),
      )
  }
}

/// Removes one exact directional link, by the recipient's identity, when the
/// recipient may not be resident.
///
/// A resident recipient is revoked as `unlink` does. One that is not resident
/// cannot be reached to revoke its grant, so only the outgoing link is removed
/// and the answer says that no outgoing authority remains. The control
/// command and the web page both remove links through this function, so they
/// cannot disagree about a recipient that is saved.
///
/// ## Examples
///
/// ```gleam
/// // peers.unlink_session(directory, source, "main", target_session, "reviewer")
/// ```
pub fn unlink_session(
  directory: Directory,
  source: peer_mail.Endpoint,
  from: String,
  target_session: String,
  to: String,
) -> Result(JsonValue, String) {
  case directory.resolve(target_session) {
    Ok(recipient) -> unlink(source, recipient, from, to)
    Error(_) ->
      source.call(peer_mail.Unlink(from, target_session, to))
      |> peer_mail.plain
      |> result.replace(
        json.Object([
          #("outgoing_link_removed", json.Bool(True)),
          #(
            "recipient_grant",
            json.String("unavailable; no outgoing authority remains"),
          ),
        ]),
      )
  }
}

/// The refusal for a recipient that no catalogue holds, and the words every
/// other refusal to find a recipient uses. Sending never opens a session: that
/// would let one model start another session's runtime, schedules and resumed
/// operations, which is a larger grant than adding a prompt to a running one
/// (protocol-change/077). A recipient that is saved is not refused; it is
/// queued (`queued_unopened_note`).
pub const not_running = "that session is not running; the owner has to open it"

/// What the model is told when a send could not reach the recipient's owner.
/// The message is recorded and will be delivered, so the model must not send
/// it again under a new id.
pub const queued_note =
  "queued: the recipient's owner is not reachable. Delivery is retried, at first about every 5 seconds, for up to 1 hour. Do not send it again under a new message_id; sending it again with the same message_id returns the receipt once the message is admitted."

/// What the model is told when the recipient is saved and not open. Only the
/// owner opens a session, so the message waits for that, and the attempts
/// become less frequent the longer it does.
pub const queued_unopened_note =
  "queued: the recipient session is saved and not open, and only its owner can open it. The message is delivered when it is opened. Delivery is retried, less often the longer it waits, for up to 1 hour. Do not send it again under a new message_id; sending it again with the same message_id returns the receipt once the message is admitted."

/// Sends using a stable caller-chosen request identity. Reusing the identity
/// for different content is refused by the recipient, even after a restart.
///
/// The message is recorded in the sender's outbox (`client/peer_outbox`)
/// before the recipient is asked, and delivery is attempted once inline. A
/// receipt is returned as it always was. A definitive refusal is returned as
/// an error as it always was, and the row records it. When nobody answers for
/// the recipient (`peer_mail.Unreachable`) the row stays pending, the
/// outbox drainer (`client/peer_outbox_drain`) keeps attempting it, and the
/// answer is `{"state": "queued", ...}`. So it is when the recipient's owner
/// answers that the session is saved and not open (`peer_mail.NotOpen`): the
/// message is delivered once, when the owner next opens the session, and an
/// hour without that refuses it. A recipient that no catalogue holds is still
/// refused.
///
/// ## Examples
///
/// ```gleam
/// // peers.send(wiring, "main", target_session, "main", "review-1", "finding")
/// ```
pub fn send(
  wiring: Wiring,
  strand: String,
  session: String,
  target: String,
  id: String,
  text: String,
) -> Result(JsonValue, String) {
  use links <- result.try(links(wiring, strand))
  use Nil <- result.try(
    case
      list.any(links, fn(link) {
        field(link, "session") == Ok(json.String(session))
        && field(link, "strand") == Ok(json.String(target))
      })
    {
      True -> Ok(Nil)
      False -> Error("no operator-authorized outgoing link")
    },
  )

  // The row is written before the recipient is asked, so a crash between the
  // recipient's commit and our reply leaves a row to retry, and the retry
  // gets the recipient's stored receipt back.
  use claimed <- result.try(own_call(
    wiring,
    peer_mail.OutboxClaim(wiring.own.session, strand, session, target, id, text),
  ))
  case field(claimed, "state") {
    Ok(json.String("admitted")) -> field(claimed, "receipt")
    _ ->
      case record_attempt(wiring, strand, session, target, id, text) {
        peer_outbox.Receipt(receipt:) -> Ok(receipt)
        peer_outbox.Rejected(reason:) -> Error(reason)
        peer_outbox.Unanswered -> Ok(queued(session, id))
        peer_outbox.NotOpen -> Ok(queued_unopened(session, id))
      }
  }
}

/// Attempts one pending outbox row again and records the outcome. The outbox
/// drainer calls this for each row the sender's Agency reports as due, through
/// the same `Directory.resolve` seam `send` uses, so a recipient that has
/// moved to another node is reached with no change here. A row that is not
/// pending is already settled and is not attempted.
///
/// ## Examples
///
/// ```gleam
/// // peers.resend(wiring, row)
/// ```
pub fn resend(wiring: Wiring, row: peer_outbox.Row) -> peer_outbox.Outcome {
  case row.state {
    peer_outbox.Pending(text:, ..) ->
      record_attempt(
        wiring,
        row.strand,
        row.session,
        row.target_strand,
        row.message_id,
        text,
      )
    peer_outbox.Admitted(receipt:) -> peer_outbox.Receipt(receipt)
    peer_outbox.Refused(reason:) -> peer_outbox.Rejected(reason)
  }
}

/// The answer for a message that is recorded and not yet delivered.
///
/// ## Examples
///
/// ```gleam
/// assert peers.is_queued(peers.queued("s2", "m1"))
/// ```
pub fn queued(session: String, id: String) -> JsonValue {
  queued_with(session, id, queued_note)
}

/// The answer for a message that is recorded and waits for its saved recipient
/// to be opened.
///
/// ## Examples
///
/// ```gleam
/// assert peers.is_queued(peers.queued_unopened("s2", "m1"))
/// ```
pub fn queued_unopened(session: String, id: String) -> JsonValue {
  queued_with(session, id, queued_unopened_note)
}

fn queued_with(session: String, id: String, note: String) -> JsonValue {
  json.Object([
    #("state", json.String("queued")),
    #("session", json.String(session)),
    #("message_id", json.String(id)),
    #("note", json.String(note)),
  ])
}

/// Whether a send's answer is the queued one rather than a receipt.
///
/// ## Examples
///
/// ```gleam
/// assert !peers.is_queued(json.Null)
/// ```
pub fn is_queued(answer: JsonValue) -> Bool {
  field(answer, "state") == Ok(json.String("queued"))
}

// One delivery attempt and its record. A failed record is not an error of the
// send: the row stays pending, the drainer attempts it again, and the
// recipient answers the repeat with the receipt it already stored.
fn record_attempt(
  wiring: Wiring,
  strand: String,
  session: String,
  target: String,
  id: String,
  text: String,
) -> peer_outbox.Outcome {
  let outcome = attempt(wiring, strand, session, target, id, text)
  let _recorded =
    own_call(wiring, peer_mail.OutboxSettle(strand, session, id, outcome))
  outcome
}

// Asks the recipient once. `peer_mail.Unreachable` means nobody answered and
// `peer_mail.NotOpen` means its owner answered that the session is saved; the
// row waits in both cases. A `Refused` is the recipient's own refusal, or a
// refusal made here, and retrying it unchanged cannot succeed.
fn attempt(
  wiring: Wiring,
  strand: String,
  session: String,
  target: String,
  id: String,
  text: String,
) -> peer_outbox.Outcome {
  case deliver(wiring, strand, session, target, id, text) {
    Ok(receipt) -> peer_outbox.Receipt(receipt)
    Error(peer_mail.Unreachable) -> peer_outbox.Unanswered
    Error(peer_mail.NotOpen) -> peer_outbox.NotOpen
    Error(peer_mail.Refused(reason:)) -> peer_outbox.Rejected(reason)
  }
}

fn deliver(
  wiring: Wiring,
  strand: String,
  session: String,
  target: String,
  id: String,
  text: String,
) -> Result(JsonValue, peer_mail.Failure) {
  use destination <- result.try(
    resolve(wiring, session) |> result.map_error(recipient_failure),
  )
  use Nil <- result.try(case destination.session == session {
    True -> Ok(Nil)
    False -> Error(peer_mail.Refused("peer directory identity mismatch"))
  })
  use catalogue <- result.try(
    describe(wiring, wiring.own.session) |> peer_mail.refused,
  )
  use activity <- result.try(wiring.own.call(peer_mail.Activity(strand)))
  let metadata =
    json.Object([#("catalogue", catalogue), #("activity", activity)])
  destination.call(peer_mail.Deliver(
    peer_mail.Source(wiring.own.session, strand, metadata),
    target,
    id,
    text,
  ))
}

// A directory that cannot reach the session's owner says `Unreachable`, and one
// whose owner holds the session saved says `NotOpen`; the message waits for
// either. Any other failure to find the session means that nothing holds it,
// and the model is told it is not running.
fn recipient_failure(failure: peer_mail.Failure) -> peer_mail.Failure {
  case failure {
    peer_mail.Unreachable -> peer_mail.Unreachable
    peer_mail.NotOpen -> peer_mail.NotOpen
    peer_mail.Refused(..) -> peer_mail.Refused(not_running)
  }
}

/// Lists only explicitly linked sessions and exported strands. An unavailable
/// recipient remains visible with catalogue lifecycle; discovery never opens it.
/// A recipient on another orchestrator is listed as a local one is: its owner
/// describes it from its catalogue and lists the strands it granted this
/// session, and a recipient the owner holds saved is `running: false` with no
/// strands.
///
/// ## Examples
///
/// ```gleam
/// // peers.roster(wiring, "main")
/// ```
pub fn roster(wiring: Wiring, strand: String) -> Result(JsonValue, String) {
  use links <- result.try(links(wiring, strand))
  use rows <- result.try(
    list.try_map(links, fn(link) {
      use session <- result.try(text(link, "session"))
      use target <- result.try(text(link, "strand"))
      let metadata = case describe(wiring, session) {
        Ok(value) -> value
        Error(reason) -> json.Object([#("unavailable", json.String(reason))])
      }

      // The recipient is resolved once: for a session on another
      // orchestrator, resolving asks that orchestrator's port. Such a session
      // resolves whether or not it is resident there, so the owner's answer
      // to the roster command is what says that it is saved.
      let #(running, strands) = case resolve(wiring, session) {
        Error(_) -> #(False, json.Null)
        Ok(endpoint) ->
          case endpoint.call(peer_mail.Roster(wiring.own.session, strand)) {
            Ok(rows) -> #(True, rows)
            Error(peer_mail.NotOpen) -> #(False, json.Null)
            Error(failure) -> #(
              True,
              json.Object([
                #("unavailable", json.String(peer_mail.reason(failure))),
              ]),
            )
          }
      }
      Ok(
        json.Object([
          #("session", json.String(session)),
          #("target_strand", json.String(target)),
          #("running", json.Bool(running)),
          #("metadata", metadata),
          #("exported_strands", strands),
        ]),
      )
    }),
  )
  Ok(json.Array(rows))
}

/// Reads one resident strand's outgoing links and incoming operator grants.
/// Saved recipients remain visible as unavailable rows; inspection never
/// resolves them into a running session.
///
/// ## Examples
///
/// ```gleam
/// // peers.inspect(wiring, "main", None, 59000)
/// ```
pub fn inspect(
  wiring: Wiring,
  strand: String,
  after: Option(String),
  body_budget: Int,
) -> Result(JsonValue, String) {
  use _ <- result.try(own_call(wiring, peer_mail.Activity(strand)))
  use outgoing <- result.try(links(wiring, strand))
  use incoming <- result.try(own_call(wiring, peer_mail.Grants(strand)))
  use outgoing <- result.try(
    list.try_map(outgoing, fn(link) {
      use session <- result.try(text(link, "session"))
      use target <- result.try(text(link, "strand"))
      let metadata = case describe(wiring, session) {
        Ok(value) -> value
        Error(reason) -> json.Object([#("unavailable", json.String(reason))])
      }
      let wake = case resolve(wiring, session) {
        Error(_) -> json.Null
        Ok(endpoint) ->
          case endpoint.call(peer_mail.Roster(wiring.own.session, strand)) {
            Error(_) -> json.Null
            Ok(json.Array(rows)) ->
              case
                list.find(rows, fn(row) {
                  field(row, "strand") == Ok(json.String(target))
                })
              {
                Error(Nil) -> json.Null
                Ok(row) -> field(row, "wake") |> result.unwrap(json.Null)
              }
            Ok(_) -> json.Null
          }
      }

      // A link the owner's `[peers]` default supplies is marked, so the
      // owner can tell it from a grant (protocol-change/077). A recorded
      // link carries no mark.
      let basis = case field(link, "default") {
        Ok(json.Bool(True)) -> [#("default", json.Bool(True))]
        _ -> []
      }
      Ok(InspectRow(
        inspect_key("o", session, target),
        OutgoingRow,
        json.Object(list.append(
          [
            #("session", json.String(session)),
            #("target_strand", json.String(target)),
            #("wake", wake),
            #("metadata", metadata),
          ],
          basis,
        )),
      ))
    }),
  )
  use incoming <- result.try(case incoming {
    json.Array(rows) ->
      list.try_map(rows, fn(row) {
        use source <- result.try(text(row, "source_session"))
        use source_strand <- result.try(text(row, "source_strand"))
        let metadata = case describe(wiring, source) {
          Ok(value) -> value
          Error(reason) -> json.Object([#("unavailable", json.String(reason))])
        }
        case row {
          json.Object(fields) ->
            Ok(InspectRow(
              inspect_key("i", source, source_strand),
              IncomingRow,
              json.Object([#("metadata", metadata), ..fields]),
            ))
          _ -> Error("invalid incoming peer grant")
        }
      })
    _ -> Error("invalid incoming peer grants")
  })
  let rows =
    list.sort(list.append(outgoing, incoming), fn(a, b) {
      string.compare(a.key, b.key)
    })
  let rows = case after {
    None -> rows
    Some(cursor) ->
      list.filter(rows, fn(row) { string.compare(row.key, cursor) == order.Gt })
  }
  page_inspection(wiring, strand, rows, [], [], None, body_budget)
}

type InspectKind {
  OutgoingRow
  IncomingRow
}

type InspectRow {
  InspectRow(key: String, kind: InspectKind, value: JsonValue)
}

fn inspect_key(direction: String, session: String, strand: String) -> String {
  direction
  <> ":"
  <> json.to_string(json.Array([json.String(session), json.String(strand)]))
}

fn inspection_body(
  wiring: Wiring,
  strand: String,
  outgoing: List(JsonValue),
  incoming: List(JsonValue),
  next: Option(String),
) -> JsonValue {
  json.Object([
    #("source_session", json.String(wiring.own.session)),
    #("source_strand", json.String(strand)),
    #("metadata", wiring.metadata),
    #("outgoing", json.Array(list.reverse(outgoing))),
    #("incoming", json.Array(list.reverse(incoming))),
    #("next", case next {
      Some(cursor) -> json.String(cursor)
      None -> json.Null
    }),
  ])
}

fn page_inspection(
  wiring: Wiring,
  strand: String,
  rows: List(InspectRow),
  outgoing: List(JsonValue),
  incoming: List(JsonValue),
  last: Option(String),
  budget: Int,
) -> Result(JsonValue, String) {
  case rows {
    [] -> {
      let body = inspection_body(wiring, strand, outgoing, incoming, None)
      case string.byte_size(json.to_string(body)) <= budget {
        True -> Ok(body)
        False -> Error("metadata_too_large")
      }
    }
    [row, ..rest] -> {
      let #(outgoing_next, incoming_next) = case row.kind {
        OutgoingRow -> #([row.value, ..outgoing], incoming)
        IncomingRow -> #(outgoing, [row.value, ..incoming])
      }
      let candidate =
        inspection_body(
          wiring,
          strand,
          outgoing_next,
          incoming_next,
          Some(row.key),
        )
      case string.byte_size(json.to_string(candidate)) <= budget {
        True ->
          page_inspection(
            wiring,
            strand,
            rest,
            outgoing_next,
            incoming_next,
            Some(row.key),
            budget,
          )
        False ->
          case last {
            None -> Error("metadata_too_large")
            Some(_) ->
              Ok(inspection_body(wiring, strand, outgoing, incoming, last))
          }
      }
    }
  }
}

fn links(wiring: Wiring, strand: String) -> Result(List(JsonValue), String) {
  use value <- result.try(own_call(wiring, peer_mail.Links(strand)))
  case value {
    json.Array(links) ->
      case list.length(links) <= peer_mail.outgoing_link_limit {
        True -> Ok(links)
        False -> Error("peer roster exceeds the 64-link bound")
      }
    _ -> Error("invalid outgoing peer index")
  }
}

fn resolve(
  wiring: Wiring,
  session: String,
) -> Result(peer_mail.Endpoint, peer_mail.Failure) {
  case session == wiring.own.session, wiring.directory {
    True, _ -> Ok(wiring.own)
    False, Some(directory) -> directory.resolve(session)
    False, None ->
      Error(peer_mail.Refused(
        "this embedded session has no daemon peer directory",
      ))
  }
}

// The caller's own endpoint is always a local one and always answers, so its
// failure is a text.
fn own_call(
  wiring: Wiring,
  command: peer_mail.Command,
) -> Result(JsonValue, String) {
  wiring.own.call(command) |> peer_mail.plain
}

fn describe(wiring: Wiring, session: String) -> Result(JsonValue, String) {
  case wiring.directory {
    Some(directory) -> directory.describe(session)
    None ->
      case session == wiring.own.session {
        True -> Ok(wiring.metadata)
        False -> Error("unknown peer session")
      }
  }
}

/// Model-facing discovery and messaging, with no grant-management operation.
///
/// ## Examples
///
/// ```gleam
/// // peers.tools(wiring)
/// ```
pub fn tools(wiring: Wiring) -> List(tool.Tool) {
  [
    tool.Tool(
      name: "peer_describe",
      description: "Set your own peer-discovery description (at most 2048 bytes). It is labeled as a model claim and grants no authority.",
      prompt_snippet: None,
      schema: tool.object_schema(
        [
          #(
            "description",
            tool.string_property("model-authored self-description"),
          ),
        ],
        ["description"],
      ),
      replay: tool.Safe,
      execution_mode: tool.Concurrent,
      requirements: requirements,
      run: fn(ctx, args) {
        use description <- tool.with_arg(tool.required_string(
          args,
          "description",
        ))
        outcome(own_call(wiring, peer_mail.Describe(ctx.strand, description)))
      },
    ),
    tool.Tool(
      name: "peer_roster",
      description: "List linked sessions and exported strands, each marked running or not (you cannot open a session that is not running; a message to one waits until its owner opens it). At most 64 links are listed; the rest are not addressable until the owner removes some. Repository similarity does not grant access. Model self-description is not authority.",
      prompt_snippet: None,
      schema: tool.object_schema([], []),
      replay: tool.Safe,
      execution_mode: tool.Concurrent,
      requirements: requirements,
      run: fn(ctx, _) { outcome(roster(wiring, ctx.strand)) },
    ),
    tool.Tool(
      name: "peer_send",
      description: "Send to an operator-linked strand in another session. Supply a stable message_id and reuse it only when retrying the same message. The receipt proves durable admission, not consumption or completion. Idle recipients wake only when the operator granted it. If the recipient is saved or its owner cannot be reached, the answer is queued: the message is delivered later, once, and you must not send it again under a new message_id.",
      prompt_snippet: None,
      schema: tool.object_schema(
        [
          #("session", tool.string_property("canonical recipient session ID")),
          #(
            "strand",
            tool.string_property("explicitly exported recipient strand"),
          ),
          #(
            "message_id",
            tool.string_property("stable request identity, at most 128 bytes"),
          ),
          #("text", tool.string_property("message body, at most 32768 bytes")),
        ],
        ["session", "strand", "message_id", "text"],
      ),
      replay: tool.Safe,
      execution_mode: tool.Concurrent,
      requirements: requirements,
      run: fn(ctx, args) {
        use session <- tool.with_arg(tool.required_string(args, "session"))
        use strand <- tool.with_arg(tool.required_string(args, "strand"))
        use id <- tool.with_arg(tool.required_string(args, "message_id"))
        use text <- tool.with_arg(tool.required_string(args, "text"))
        outcome(send(wiring, ctx.strand, session, strand, id, text))
      },
    ),
  ]
}

fn requirements(workspace: String) -> policy.SandboxPolicy {
  let base = policy.workspace_default(workspace)
  policy.SandboxPolicy(
    ..base,
    readable_roots: [],
    writable_roots: [],
    env_allow: [],
  )
}

fn outcome(answer: Result(JsonValue, String)) -> tool.ToolOutcome {
  case answer {
    Ok(value) -> tool.success(json.to_string(value)) |> tool.with_details(value)
    Error(reason) -> tool.failure(reason)
  }
}

fn field(value: JsonValue, key: String) -> Result(JsonValue, String) {
  case value {
    json.Object(fields) ->
      list.key_find(fields, key) |> result.replace_error("missing peer field")
    _ -> Error("expected peer object")
  }
}

fn text(value: JsonValue, key: String) -> Result(String, String) {
  use value <- result.try(field(value, key))
  case value {
    json.String(value) -> Ok(value)
    _ -> Error("expected peer text")
  }
}

/// The peer calls this router services on every installed program mode.
pub const serviced_caps = [
  "peer.roster", "peer.send", "peer.inbox", "peer.inbox_get", "peer.history",
  "peer.received", "peer.received_get", "peer.sent_receipt",
]

/// Routes peer calls with the launching strand's authenticated identity.
/// No argument can select a different sending session or strand.
///
/// ## Examples
///
/// ```gleam
/// // peers.router(wiring, request.strand, fallback)
/// ```
pub fn router(
  wiring: Wiring,
  strand: String,
  fallback: satellite.CapRouter,
) -> satellite.CapRouter {
  fn(request: satellite.CapRequest) {
    use <- bool.guard(
      when: list.contains(serviced_caps, request.cap) && request.ordinal >= 128,
      return: Error(satellite.CapDenial(
        "admission_ceiling",
        "peer capability admission ceiling reached",
      )),
    )
    case request.cap {
      "peer.inbox" -> {
        use after <- result.try(args.string(request.args, "after"))
        use limit <- result.try(args.int(request.args, "limit"))
        Ok(
          satellite.ServedHere(fn() {
            wire_answer(own_call(wiring, peer_mail.Inbox(strand, after, limit)))
          }),
        )
      }
      "peer.inbox_get" -> {
        use id <- result.try(args.string(request.args, "id"))
        Ok(
          satellite.ServedHere(fn() {
            wire_answer(own_call(wiring, peer_mail.InboxGet(strand, id)))
          }),
        )
      }
      "peer.history" -> {
        use before <- result.try(args.int(request.args, "before"))
        use limit <- result.try(args.int(request.args, "limit"))
        Ok(
          satellite.ServedHere(fn() {
            wire_answer(own_call(
              wiring,
              peer_mail.History(strand, before, limit),
            ))
          }),
        )
      }
      "peer.received" -> {
        use after <- result.try(args.string(request.args, "after"))
        use limit <- result.try(args.int(request.args, "limit"))
        Ok(
          satellite.ServedHere(fn() {
            wire_answer(own_call(
              wiring,
              peer_mail.Received(strand, after, limit),
            ))
          }),
        )
      }
      "peer.received_get" -> {
        use session <- result.try(args.string(request.args, "source_session"))
        use source <- result.try(args.string(request.args, "source_strand"))
        use id <- result.try(args.string(request.args, "message_id"))
        Ok(
          satellite.ServedHere(fn() {
            wire_answer(own_call(
              wiring,
              peer_mail.ReceivedGet(strand, session, source, id),
            ))
          }),
        )
      }
      "peer.sent_receipt" -> {
        use session <- result.try(args.string(request.args, "session"))
        use id <- result.try(args.string(request.args, "message_id"))
        Ok(
          satellite.ServedHere(fn() {
            wire_answer(sent_receipt(wiring, strand, session, id))
          }),
        )
      }
      "peer.roster" ->
        Ok(satellite.ServedHere(fn() { wire_answer(roster(wiring, strand)) }))
      "peer.send" -> {
        use session <- result.try(args.string(request.args, "session"))
        use target <- result.try(args.string(request.args, "strand"))
        use id <- result.try(args.string(request.args, "message_id"))
        use body <- result.try(args.string(request.args, "text"))
        Ok(
          satellite.ServedHere(fn() {
            send_answer(send(wiring, strand, session, target, id, body))
          }),
        )
      }
      _ -> fallback(request)
    }
  }
}

// A program's `peer.send` is typed to return a receipt, so a queued message
// reaches it as the denial `peer_queued` with the model-facing note, which the
// program can tell apart from a refusal by its code. The note is the answer's
// own, because an unreachable owner and a saved recipient are told different
// things.
fn send_answer(answer: Result(JsonValue, String)) {
  case answer {
    Ok(value) ->
      case is_queued(value) {
        True ->
          framing.CapErr("peer_queued", case text(value, "note") {
            Ok(note) -> note
            Error(_) -> queued_note
          })
        False -> wire_answer(Ok(value))
      }
    Error(_) -> wire_answer(answer)
  }
}

fn wire_answer(answer: Result(JsonValue, String)) {
  case answer {
    Ok(value) -> framing.CapOk(msgpack.StringValue(json.to_string(value)))
    Error(reason) -> framing.CapErr("peer_refused", reason)
  }
}

// Source identity comes from this host and its launching strand, not from the
// program. An outgoing link is still required to reach a resident recipient.
//
// The sender's own outbox row is read first. It holds the receipt of a message
// this session sent, including one that was delivered by the drainer long
// after `peer_send` returned `queued`, and it answers while the recipient's
// owner is unreachable. Any other state falls through to the recipient, which
// remains the authority: it may hold a receipt whose reply was lost.
fn sent_receipt(
  wiring: Wiring,
  strand: String,
  session: String,
  id: String,
) -> Result(JsonValue, String) {
  use links <- result.try(links(wiring, strand))
  use Nil <- result.try(
    case
      list.any(links, fn(link) {
        field(link, "session") == Ok(json.String(session))
      })
    {
      True -> Ok(Nil)
      False -> Error("no operator-authorized outgoing link")
    },
  )
  case own_call(wiring, peer_mail.OutboxReceipt(strand, session, id)) {
    Ok(json.Null) | Error(_) -> {
      use destination <- result.try(resolve(wiring, session) |> peer_mail.plain)
      use Nil <- result.try(case destination.session == session {
        True -> Ok(Nil)
        False -> Error("peer directory identity mismatch")
      })
      destination.call(peer_mail.SentReceipt(wiring.own.session, strand, id))
      |> peer_mail.plain
    }
    Ok(receipt) -> Ok(receipt)
  }
}
