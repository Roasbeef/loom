//// What a session answers to the spawner whose page started it
//// (protocol-change/094).
////
//// A relayed session is an ordinary session of this daemon that another
//// orchestrator's page asked for. The orchestrator port receives that page's
//// messages, `client/top_host` judges the sender against its
//// `[spawners.<name>.top_level]` table and finds the session, and this module is
//// the step between: the questions the session itself answers once it is
//// resident. They are read from the session's own runtime, so the daemon needs
//// no second copy of anything the session already keeps.
////
//// ## One endpoint per session
////
//// `Endpoint` is a record of closures, as `agency.DelegateEndpoint` is, so that
//// a resident session publishes it to the registry without publishing its
//// runtime graph. The assembly fills it (`endpoint`): the reads and the send run
//// against a runtime borrowed from the session's holder, and the two actions
//// that belong to the session's hub, stopping the run and judging a decision,
//// are closures the assembly closes over the hub's address. A session built
//// without one (`refusing`) answers every question as not relayed.
////
//// ## What a read reports
////
//// `overview` states what the sidebar needs: what the session is doing, when it
//// last changed, its pending requests in the protocol's own record shape with
//// `admitted` set from the spawner's approval ceiling, and its children on other
//// orchestrators. The requests carry the seq the box holds, which is what the
//// page's decision names back, so a decision is judged against the question the
//// person saw. A session that is not resident cannot be read this way, and the
//// host reports it idle without opening it.
////
//// ## What a send does
////
//// `send` delivers a message to the main strand and stores a receipt under the
//// message's identity in the same commit, so a message the page sends again is
//// answered from the receipt and reaches the strand once. A strand with an open
//// run takes the message as a steer, and an idle one starts a run. The receipt
//// is a fact under the client's reserved prefix, so no tool can write it.
////
//// ## Flow
////
//// `endpoint` → `overview` → `pending` → `send` → `history_page` → `refusing`
////
//// 1. `endpoint` closes the reads over a runtime supplier and the actions over
////    the hub.
//// 2. `overview` assembles a row's live part from `peer_mail.standing`, the
////    pending records and the stubs.
//// 3. `pending` reads the pending escalation records of the session with their
////    seq and the part the ceiling admits.
//// 4. `send` delivers once, and `history_page` reads one bounded page of the
////    main strand's branch.
//// 5. `refusing` is the endpoint of a session that answers nothing.

import client/approval_ceiling.{type Ceiling}
import client/escalation_view
import client/peer_mail
import client/protocol.{type EscalationRecord}
import client/remote_child
import client/remote_escalation.{type Answer, type Decider, type Decision}
import client/remote_mail
import client/remote_send
import client/remote_top.{type Refusal}
import core/clock
import core/json.{type JsonValue}
import core/message
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/api
import runtime/escalation as durable
import runtime/writer
import session_view/remote_agent.{type RemoteAgent}
import session_view/remote_transcript
import storage/storage

/// The strand a relayed session's page talks to.
pub const main_strand = "main"

/// The reserved prefix a send's receipt is stored under. It is under the
/// client's fact prefix, which `api.put_fact` refuses, so no tool can write one.
const receipt_prefix = "client/relay/receipt/"

/// The most bytes a message identity may have.
const max_message_id_bytes = 128

/// The figures of a spawner's table that a decision is judged by: whose
/// provenance it carries and what it may grant.
pub type Terms {
  Terms(
    /// The `[spawners.<name>]` key, kept as the provenance of a remembered
    /// grant.
    spawner: String,
    /// What a decision may grant. `None` means the page may decide nothing.
    ceiling: Option(Ceiling),
  )
}

/// What a resident session says of itself for a page of the sidebar.
pub type Overview {
  Overview(
    /// What the session is doing.
    doing: peer_mail.Doing,
    /// When the main strand's branch last grew, in Unix milliseconds on the
    /// session's clock, or `None` for a session with no message yet.
    updated_at: Option(Int),
    /// Every pending request, in the protocol's record shape.
    pending: List(EscalationRecord),
    /// The session's children on other orchestrators.
    children: List(RemoteAgent),
  )
}

/// The questions a relayed session answers, as closures its assembly closes.
pub type Endpoint {
  Endpoint(
    /// What the session is doing, given the ceiling that decides which grants a
    /// request shows as admitted.
    overview: fn(Option(Ceiling)) -> Result(Overview, Refusal),
    /// Delivers a message to the main strand, given its identity and text, and
    /// answers how it landed (`remote_mail.encode_landing`).
    send: fn(String, String) -> Result(JsonValue, Refusal),
    /// Reads one page of the main strand's branch, given the sequence it reads
    /// below and the most entries, and answers the encoded page.
    history: fn(Int, Int) -> Result(JsonValue, Refusal),
    /// Stops the main strand's current run, on the session's hub. A session
    /// with no run is not an error.
    stop: fn() -> Result(Nil, Refusal),
    /// Judges and commits a decision on the session's hub, given the spawner's
    /// terms, the record's identity, the decision, the seq the person was shown
    /// and who decided.
    resolve: fn(Terms, String, Decision, Int, Decider) ->
      Result(Answer, Refusal),
  )
}

/// The endpoint of a session that answers nothing, as every session is until
/// its assembly fills one.
///
/// ## Examples
///
/// ```gleam
/// assert relayed_session.refusing().stop() == Error(remote_top.NotRelayed)
/// ```
pub fn refusing() -> Endpoint {
  Endpoint(
    overview: fn(_ceiling) { Error(remote_top.NotRelayed) },
    send: fn(_id, _text) { Error(remote_top.NotRelayed) },
    history: fn(_cursor, _limit) { Error(remote_top.NotRelayed) },
    stop: fn() { Error(remote_top.NotRelayed) },
    resolve: fn(_terms, _id, _decision, _seq, _decider) {
      Error(remote_top.NotRelayed)
    },
  )
}

/// The endpoint of one session. `borrow` lends the session's runtime, as the
/// Agency's holder does, and answers `Error(Nil)` when the session is not up.
/// `stop` and `resolve` are the hub's, closed over its address by the assembly.
///
/// ## Examples
///
/// ```gleam
/// // relayed_session.endpoint(agency.runtime_supplier(config), stop, resolve)
/// ```
pub fn endpoint(
  borrow: fn() -> Result(api.Runtime, Nil),
  stop: fn() -> Result(Nil, Refusal),
  resolve: fn(Terms, String, Decision, Int, Decider) -> Result(Answer, Refusal),
) -> Endpoint {
  let with = fn(use_runtime: fn(api.Runtime) -> Result(a, Refusal)) {
    case borrow() {
      Ok(runtime) -> use_runtime(runtime)
      Error(Nil) ->
        Error(remote_top.NotYetOpen(reason: "the session is not up"))
    }
  }
  Endpoint(
    overview: fn(ceiling) { with(overview(_, ceiling)) },
    send: fn(message_id, text) { with(send(_, message_id, text)) },
    history: fn(cursor, limit) { with(history_page(_, cursor, limit)) },
    stop:,
    resolve:,
  )
}

/// Reads what the session is doing, its pending requests and its children.
///
/// ## Examples
///
/// ```gleam
/// // relayed_session.overview(runtime, option.None)
/// ```
pub fn overview(
  runtime: api.Runtime,
  ceiling: Option(Ceiling),
) -> Result(Overview, Refusal) {
  use #(doing, _approvals) <- result.try(
    peer_mail.standing(runtime) |> result.map_error(store_failure),
  )
  use pending <- result.try(pending(runtime, ceiling))
  let #(now, _clock) = clock.read(runtime.effects.clock)
  let children = case remote_child.all(runtime) {
    Ok(kept) -> remote_child.agents(kept, now)
    Error(_) -> []
  }
  Ok(Overview(doing:, updated_at: updated_at(runtime), pending:, children:))
}

/// The session's pending requests with the seq each holds now. `admitted` is the
/// part of what a request wanted that the ceiling admits, which is all an
/// approval may carry, and is empty when there is no ceiling.
///
/// ## Examples
///
/// ```gleam
/// // relayed_session.pending(runtime, option.None) == Ok([])
/// ```
pub fn pending(
  runtime: api.Runtime,
  ceiling: Option(Ceiling),
) -> Result(List(EscalationRecord), Refusal) {
  use records <- result.try(
    api.escalations(runtime)
    |> result.map_error(fn(error) { store_failure(string.inspect(error)) }),
  )
  records
  |> list.filter(fn(record) { record.status == durable.Pending })
  |> list.try_map(fn(record) {
    use cell <- result.map(
      api.escalation_cell(runtime, record.id)
      |> result.map_error(fn(error) { store_failure(string.inspect(error)) }),
    )
    shown(cell, ceiling)
  })
}

// The record as the page is told it: the protocol's own shape and, for a
// pending one, the part of what was asked that the ceiling admits.
fn shown(
  cell: api.EscalationCell,
  ceiling: Option(Ceiling),
) -> EscalationRecord {
  let view = escalation_view.view(cell.record, cell.seq)
  let wanted = case view.denial {
    Some(denial) -> denial.wanted
    None -> []
  }
  protocol.EscalationRecord(
    ..view,
    admitted: Some(case ceiling {
      Some(ceiling) -> approval_ceiling.admitted(ceiling, wanted)
      None -> []
    }),
  )
}

// When the main strand's branch last grew: the timestamp of its leaf. A session
// with no leaf, or one whose leaf cannot be read, has no time, and the host
// falls back to the session's creation.
fn updated_at(runtime: api.Runtime) -> Option(Int) {
  case api.leaf(api.on_strand(runtime, main_strand)) {
    Ok(Some(id)) ->
      case writer.get_entries(runtime.tree.writer, [id]) {
        Ok(found) ->
          dict.get(found, id)
          |> result.map(fn(leaf) { leaf.ts })
          |> option.from_result
        Error(_) -> None
      }
    Ok(None) | Error(_) -> None
  }
}

/// Delivers one message to the main strand, once.
///
/// The message id keys a receipt that is written in the commit that delivers, so
/// a message the page sends again is answered `Admitted` and reaches the strand
/// once. A strand with an open run takes the message as a steer, and an idle one
/// starts a run. An id reused for other text is refused, because the id is not a
/// proof of what was said.
///
/// ## Examples
///
/// ```gleam
/// // relayed_session.send(runtime, "7b1c", "hello")
/// // == Ok(remote_mail.encode_landing(remote_mail.Started(op, None)))
/// ```
pub fn send(
  runtime: api.Runtime,
  message_id: String,
  text: String,
) -> Result(JsonValue, Refusal) {
  use Nil <- result.try(
    case
      message_id != ""
      && string.byte_size(message_id) <= max_message_id_bytes
      && string.byte_size(text) <= remote_send.max_text_bytes
      && text != ""
    {
      True -> Ok(Nil)
      False ->
        Error(remote_top.InvalidArgument(
          reason: "the message id or the text is empty or exceeds its bound",
        ))
    },
  )
  let key = receipt_prefix <> message_id
  let request = json.Object([#("text", json.String(text))])
  use existing <- result.try(
    api.fact(runtime, key)
    |> result.map_error(fn(error) { store_failure(string.inspect(error)) }),
  )
  use landing <- result.map(case existing {
    Some(held) -> same_send(held, request)
    None -> deliver(runtime, key, request, text)
  })
  remote_mail.encode_landing(landing)
}

fn deliver(
  runtime: api.Runtime,
  key: String,
  request: JsonValue,
  text: String,
) -> Result(remote_mail.Landing, Refusal) {
  let #(now, _clock) = clock.read(runtime.effects.clock)
  let payload =
    message.UserMessage(
      content: [message.UserText(text:, text_signature: None)],
      timestamp: now,
      origin: None,
    )
  let mark = api.Mark(key:, value: json.Object([#("request", request)]))
  case
    api.send_to_strand_marking(
      runtime,
      to: main_strand,
      message: payload,
      mark:,
    )
  {
    Ok(api.Steered(entry:)) -> Ok(remote_mail.Steered(entry:))
    Ok(api.Started(operation:)) ->
      Ok(remote_mail.Started(operation:, remaining_ms: None))

    // A twin of this message committed between the read and the write. Its
    // receipt is the answer.
    Error(api.FactConflict(..)) ->
      case api.fact(runtime, key) {
        Ok(Some(held)) -> same_send(held, request)
        Ok(None) | Error(_) ->
          Error(store_failure("the send's receipt moved under the write"))
      }
    Error(error) -> Error(store_failure(string.inspect(error)))
  }
}

// A receipt answers a repeat only if it is a receipt for this message. An id
// reused for other content is refused and never answered with the first
// message's receipt.
fn same_send(
  held: JsonValue,
  request: JsonValue,
) -> Result(remote_mail.Landing, Refusal) {
  case held {
    json.Object(fields) ->
      case list.key_find(fields, "request") == Ok(request) {
        True -> Ok(remote_mail.Admitted)
        False ->
          Error(remote_top.InvalidArgument(
            reason: "the message id was already used for different content",
          ))
      }
    _ -> Error(store_failure("the send's receipt is corrupt"))
  }
}

/// Reads one page of the main strand's branch: the entries on the path from its
/// leaf down its parent links, newest first from the store and oldest first on
/// the page, at most `limit` of them and within the page's byte bound.
/// `cursor` is the sequence the page reads below, zero for the newest page.
///
/// ## Examples
///
/// ```gleam
/// // relayed_session.history_page(runtime, 0, 50) == Ok(remote_transcript.encode(page))
/// ```
pub fn history_page(
  runtime: api.Runtime,
  cursor: Int,
  limit: Int,
) -> Result(JsonValue, Refusal) {
  use Nil <- result.try(
    case cursor >= 0 && limit >= 1 && limit <= remote_transcript.max_entries {
      True -> Ok(Nil)
      False ->
        Error(remote_top.InvalidArgument(
          reason: "the cursor or the limit is out of bounds",
        ))
    },
  )
  use leaf <- result.try(
    api.leaf(api.on_strand(runtime, main_strand))
    |> result.map_error(fn(error) { store_failure(string.inspect(error)) }),
  )
  case leaf {
    None ->
      Ok(
        remote_transcript.encode(remote_transcript.Page(
          child: main_strand,
          entries: [],
          omitted: 0,
          next: None,
        )),
      )

    // One more entry than the page holds is read, so the page can say whether
    // older entries exist without a second read.
    Some(leaf) -> {
      let query = storage.branch_scan(leaf) |> storage.branch_limit(limit + 1)
      let query = case cursor {
        0 -> query
        before -> storage.branch_cursor(query, before)
      }
      use scanned <- result.map(
        storage.scan_branch(runtime.session.store, query)
        |> result.map_error(fn(_error) {
          store_failure("the session's branch could not be read")
        }),
      )
      remote_transcript.encode(remote_transcript.page_of(
        main_strand,
        scanned,
        limit,
      ))
    }
  }
}

fn store_failure(reason: String) -> Refusal {
  remote_top.StoreFailure(reason:)
}
