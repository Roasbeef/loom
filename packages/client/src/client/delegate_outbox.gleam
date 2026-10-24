//// What a delegate session owes the parent that started its children, as rows in
//// its own store (protocol-change/084, phase 2).
////
//// A delegate session exists on the remote to serve the children of one parent
//// on the laptop. Those children talk to the parent in two ways that the laptop
//// did not ask for: a child's `agent_send` to its parent is mail, and what a
//// child is doing is progress. Both travel box to laptop, over a connection the
//// laptop made and keeps up (`client/remote/link_keeper`), and the box never
//// dials. This module is what the session keeps so that a laptop that is asleep,
//// away or restarting costs nothing but a delay, and the pass that sends it is
//// `client/delegate_drain`. The Agency writes rows here, so this module sits
//// below it and imports nothing of the drainer.
////
//// ## The keys
////
//// Everything lives under the reserved prefix `delegate/outbox/{kind}/{key}`,
//// so deleting the delegate session removes it with the session.
////
//// | Key | What it is |
//// | --- | --- |
//// | `delegate/outbox/mail/{message id}` | one message a child sent its parent, with the state it is in |
//// | `delegate/outbox/progress/{strand}` | the `at` of the newest glance the laptop acknowledged for a child |
//// | `delegate/outbox/escalation/{id}/{seq}` | a child's request for more authority, raised at that `seq` (protocol-change/089) |
////
//// ## A request outlives its answer by one send
////
//// An escalation row differs from a mail row. Mail is settled by the laptop's
//// answer and kept. A request is a question about a record that the box owns and
//// that changes: the row says only which record and which `seq` the box raised it
//// at, and the pass builds what it sends from the record as it is then. The row
//// is `NotAcknowledged` until the laptop acknowledges that `seq`, then `Acknowledged`. It is
//// deleted once the record has been decided and the decided state was sent, or
//// once a newer raise superseded it, or once its answer window closed
//// (`answer_window_ms` past the call's park). Nothing on the laptop depends on
//// the row after that.
////
//// ## A row settles on an answer, never on age
////
//// The weaker guarantee the owner accepted is that a child's upward send answers
//// `queued` while the laptop is away, and that a later delivery which finds the
//// parent idle is refused and recorded. So a mail row is `Pending` until the
//// laptop answers, and then it is exactly one of `Answered(Delivered)`,
//// `Answered(Declined(..))`, or `Refused(..)` when the laptop said it would never
//// admit the message. A silent laptop leaves the row where it is, and so does
//// `ParentSessionNotOpen`, the one refusal that is worth asking again. A row
//// has no time to live: the message is a fact about a child that is itself
//// bounded by its deadline, and an hour's patience for peer mail does not apply
//// to a laptop that was shut for a weekend.
////
//// A settled row stays. It is the record the child can read back, it is small,
//// and it goes with the session.
////
//// ## Progress has no row
////
//// A glance is a view and not a fact the parent acts on, and the delegate
//// session already keeps the newest one for each strand in `client/glance/`.
//// `unsent_glances` is the newest glance of each child whose `at` is above the
//// last one the laptop acknowledged, and `acknowledge` records the acknowledged
//// `at` under the `progress` key. A glance the child replaced while the laptop
//// was away is never sent, which is the cost of not queueing views.
////
//// ## Flow
////
//// `queue_mail` → `mail_rows` → `settle_mail` → `unsent_glances` → `acknowledge` →
//// `announce` → `queue_question` → `question_rows` → `settle_question` → `drop_question`
////
//// 1. `queue_mail` writes the row a child's upward send left.
//// 2. `mail_rows` lists the rows, and `settle_mail` records the laptop's answer
////    on one.
//// 3. `unsent_glances` lists the glances the laptop has not acknowledged, and
////    `acknowledge` records one that it has.
//// 4. `queue_question` writes the row a raised request left, `question_rows`
////    lists them, `settle_question` marks one acknowledged and `drop_question`
////    removes one that has served.

import client/approval_ceiling.{type Ceiling}
import client/protocol.{type EscalationRecord}
import client/remote_mail.{type ChildRefusal, type Receipt}
import client/remote_spawn.{type Parent}
import core/glance.{type Glance}
import core/ids
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/api
import runtime/lineage
import tools/agent.{type Handle}

/// Where the delegate session's parent is, as the session learned it when it
/// opened: the parent session and the node of the spawner that started the
/// children. The node comes from the `[spawners.<name>]` row the delegate session
/// was made for, never from a message.
pub type SpawnerLink {
  SpawnerLink(
    /// The canonical identity of the parent session, on the laptop.
    parent_session: String,
    /// The `[spawners.<name>]` the session serves.
    spawner: String,
    /// The laptop's full node name.
    node: String,
    /// What the spawner's operator may approve (protocol-change/089), or `None`
    /// when the table sets no ceiling, and then a delegate session is unattended
    /// and takes no decision from the spawner.
    ceiling: Option(Ceiling),
  )
}

/// How a session reaches its parent's orchestrator, as functions so that a test
/// plays the laptop (`client/remote/remote_spawner.laptop_over` fills it).
pub type Laptop {
  Laptop(
    /// Whether the laptop's node is connected now. It dials nothing.
    connected: fn() -> Bool,
    /// Sends one child's mail: the parent, the child, the message's identity and
    /// its text. `Error(Nil)` is silence, and the same mail can be sent again.
    mail: fn(Parent, Handle, String, String) ->
      Result(Result(Receipt, ChildRefusal), Nil),
    /// Sends one child's glance. `Error(Nil)` is silence.
    progress: fn(Parent, Handle, Glance) ->
      Result(Result(Nil, ChildRefusal), Nil),
    /// Sends one child's request for more authority. `Error(Nil)` is silence.
    escalation: fn(Parent, Handle, EscalationRecord) ->
      Result(Result(Nil, ChildRefusal), Nil),
  )
}

/// A laptop that is never connected, for a session that has no spawner link.
///
/// ## Examples
///
/// ```gleam
/// assert !delegate_outbox.absent().connected()
/// ```
pub fn absent() -> Laptop {
  Laptop(
    connected: fn() { False },
    mail: fn(_parent, _child, _id, _text) { Error(Nil) },
    progress: fn(_parent, _child, _glance) { Error(Nil) },
    escalation: fn(_parent, _child, _record) { Error(Nil) },
  )
}

/// One message a child sent its parent.
pub type Mail {
  Mail(
    /// The message's identity: the child's call-site digest. The laptop keys its
    /// receipt on it, so a resend steers the parent once.
    id: String,
    /// The parent strand the child reports to, in the parent session.
    parent_strand: String,
    /// The child that sent it. Only its strand names it on the laptop.
    child: Handle,
    /// What the child said.
    text: String,
    /// How far the message has got.
    state: State,
  )
}

/// How far a mail row has got.
pub type State {
  /// The laptop has not answered, or asked to be asked again.
  Pending

  /// The laptop admitted the message, or declined it with a reason.
  Answered(receipt: Receipt)

  /// The laptop said it would never admit the message.
  Refused(reason: String)
}

/// One child's glance that the laptop has not acknowledged.
pub type Unsent {
  Unsent(
    /// The parent strand the child reports to, from its lineage cell.
    parent_strand: String,
    /// The child, with the operation its glance describes.
    child: Handle,
    /// What it is doing.
    glance: Glance,
  )
}

/// The most text one row holds, in bytes. A child's message is a model's, so the
/// row, which is stored and sent, is bounded.
pub const max_text_bytes = 32_768

const mail_prefix = "delegate/outbox/mail/"

const progress_prefix = "delegate/outbox/progress/"

/// The key of a mail row.
///
/// ## Examples
///
/// ```gleam
/// assert delegate_outbox.mail_key("7b1c") == "delegate/outbox/mail/7b1c"
/// ```
pub fn mail_key(id: String) -> String {
  mail_prefix <> id
}

/// Writes the row a child's upward send left.
///
/// The write expects the cell to be absent, so a replay of the same call site,
/// which derives the same id, finds the row its first attempt wrote and leaves it
/// alone. A row that exists with other content is the same id reused for a
/// different message, and is refused rather than overwritten.
///
/// ## Examples
///
/// ```gleam
/// // delegate_outbox.queue_mail(runtime, delegate_outbox.Mail(id:, parent_strand: "main", child:, text: "done", state: delegate_outbox.Pending))
/// ```
pub fn queue_mail(runtime: api.Runtime, row: Mail) -> Result(Nil, String) {
  // Validate text byte length against maximum allowed size before inserting.
  use Nil <- result.try(case string.byte_size(row.text) <= max_text_bytes {
    True -> Ok(Nil)
    False -> Error("the message is longer than a message may be")
  })

  // Store mail row expecting no prior fact to detect duplicate message identity.
  case
    api.put_reserved_fact_expecting(
      runtime,
      mail_key(row.id),
      encode_mail(row),
      expected: None,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(api.FactConflict(..)) -> {
      use found <- result.try(read_mail(runtime, mail_key(row.id)))

      // Verify whether the conflict is an idempotent resend or a colliding message ID.
      case found {
        Some(held) if held.text == row.text && held.child == row.child -> Ok(Nil)
        Some(_) | None ->
          Error("the message id was already used for a different message")
      }
    }
    Error(error) -> Error(string.inspect(error))
  }
}

/// Every mail row in the session, with its key, in key order.
///
/// A cell that does not decode is left out: a corrupt row is a message nobody
/// can send, and listing it as owed would keep the drainer ticking for ever.
///
/// ## Examples
///
/// ```gleam
/// // delegate_outbox.mail_rows(runtime) == Ok([#(delegate_outbox.mail_key(id), row)])
/// ```
pub fn mail_rows(
  runtime: api.Runtime,
) -> Result(List(#(String, Mail)), String) {
  use cells <- result.map(
    api.reserved_facts(runtime, prefix: mail_prefix)
    |> result.map_error(string.inspect),
  )
  list.filter_map(cells, fn(cell) {
    decode_mail(cell.1)
    |> result.map(fn(row) { #(cell.0, row) })
    |> result.replace_error(Nil)
  })
}

/// Records the laptop's answer on a row. A write that fails leaves the row
/// pending, so the next pass sends the mail again and the laptop answers from its
/// receipt.
///
/// ## Examples
///
/// ```gleam
/// // delegate_outbox.settle_mail(runtime, key, delegate_outbox.Mail(..row, state: delegate_outbox.Answered(remote_mail.Delivered)))
/// ```
pub fn settle_mail(
  runtime: api.Runtime,
  key: String,
  row: Mail,
) -> Result(Nil, String) {
  api.put_reserved_fact(runtime, key, encode_mail(row))
  |> result.map_error(string.inspect)
}

/// Reads and decodes a persisted mail row from the runtime store.
fn read_mail(
  runtime: api.Runtime,
  key: String,
) -> Result(Option(Mail), String) {
  use cell <- result.try(
    api.fact(runtime, key) |> result.map_error(string.inspect),
  )

  // Branch on whether the fact exists in storage and decode into Mail record.
  case cell {
    None -> Ok(None)
    Some(value) -> decode_mail(value) |> result.map(Some)
  }
}

// --- progress ------------------------------------------------------------------

/// The newest glance of each child whose `at` is above the last one the laptop
/// acknowledged for it, in key order.
///
/// A glance is a child's when its strand has a lineage cell, which is what tells
/// a child from the session's own `main`. A cell that does not decode, or that
/// describes an operation that is not a real one, is left out.
///
/// ## Examples
///
/// ```gleam
/// // delegate_outbox.unsent_glances(runtime) == Ok([delegate_outbox.Unsent(parent_strand: "main", child:, glance:)])
/// ```
pub fn unsent_glances(runtime: api.Runtime) -> Result(List(Unsent), String) {
  use cells <- result.map(
    api.reserved_facts(runtime, prefix: glance.key_prefix)
    |> result.map_error(string.inspect),
  )
  list.filter_map(cells, fn(cell) {
    use strand <- result.try(glance.strand_of(cell.0))
    use child <- result.try(lineage_of(runtime, strand))
    use seen <- result.try(glance.decode(cell.1) |> result.replace_error(Nil))
    use operation <- result.try(
      ids.parse_op_id(seen.operation) |> result.replace_error(Nil),
    )

    // Keep only glances newer than the acknowledged timestamp for this strand.
    case seen.at > acknowledged_at(runtime, strand) {
      True ->
        Ok(Unsent(
          parent_strand: string.drop_start(
            child.parent,
            string.length(api.parent_reference_prefix),
          ),
          child: agent.Handle(strand:, operation:),
          glance: seen,
        ))
      False -> Error(Nil)
    }
  })
}

/// Records that the laptop acknowledged a child's glance, so the pass does not
/// send it again. The cursor moves forward only: an `at` that is not newer than
/// the recorded one is ignored.
///
/// ## Examples
///
/// ```gleam
/// // delegate_outbox.acknowledge(runtime, "sub:^main/build-1a2b", 1_700_000_000_000)
/// ```
pub fn acknowledge(
  runtime: api.Runtime,
  strand: String,
  at: Int,
) -> Result(Nil, String) {
  // This branch resolves at acknowledged_at runtime strand before the operation continues.
  case at > acknowledged_at(runtime, strand) {
    False -> Ok(Nil)
    True ->
      api.put_reserved_fact(
        runtime,
        progress_prefix <> strand,
        json.Object([#("at", json.Int(at))]),
      )
      |> result.map_error(string.inspect)
  }
}

/// Retrieves the acknowledged progress timestamp recorded for the strand.
fn acknowledged_at(runtime: api.Runtime, strand: String) -> Int {
  // This branch resolves api fact runtime progress_prefix strand before the operation continues.
  case api.fact(runtime, progress_prefix <> strand) {
    Ok(Some(json.Object(fields))) ->
      // This branch resolves list key_find fields at before the operation continues.
      case list.key_find(fields, "at") {
        Ok(json.Int(at)) -> at
        Ok(_) | Error(Nil) -> 0
      }

    Ok(Some(_)) | Ok(None) | Error(_) -> 0
  }
}

/// Loads and decodes lineage metadata for a child strand.
fn lineage_of(
  runtime: api.Runtime,
  strand: String,
) -> Result(lineage.Lineage, Nil) {
  // This branch resolves api fact runtime lineage register_key strand before the operation continues.
  case api.fact(runtime, lineage.register_key(strand)) {
    Ok(Some(value)) -> lineage.decode(value) |> result.replace_error(Nil)
    Ok(None) | Error(_) -> Error(Nil)
  }
}

// --- the codec -----------------------------------------------------------------

/// A mail row as the value its cell holds.
///
/// ## Examples
///
/// ```gleam
/// // delegate_outbox.decode_mail(delegate_outbox.encode_mail(row)) == Ok(row)
/// ```
pub fn encode_mail(row: Mail) -> JsonValue {
  json.Object([
    #("id", json.String(row.id)),
    #("parent", json.String(row.parent_strand)),
    #("child", json.String(row.child.strand)),
    #("operation", json.String(ids.op_id_to_string(row.child.operation))),
    #("text", json.String(row.text)),

    // This branch resolves row state before the operation continues.
    #("state", case row.state {
      Pending -> json.Object([#("kind", json.String("pending"))])
      Answered(receipt:) ->
        json.Object([
          #("kind", json.String("answered")),
          #("receipt", remote_mail.encode_receipt(receipt)),
        ])
      Refused(reason:) ->
        json.Object([
          #("kind", json.String("refused")),
          #("reason", json.String(reason)),
        ])
    }),
  ])
}

/// Decodes a mail row. Total: anything malformed is an error that names what was
/// wrong, never a crash.
///
/// ## Examples
///
/// ```gleam
/// assert delegate_outbox.decode_mail(json.Null)
///   == Error("expected a mail row, got null")
/// ```
pub fn decode_mail(value: JsonValue) -> Result(Mail, String) {
  use fields <- result.try(object(value, "a mail row"))
  use id <- result.try(text(fields, "id"))
  use parent_strand <- result.try(text(fields, "parent"))
  use strand <- result.try(text(fields, "child"))
  use raw_operation <- result.try(text(fields, "operation"))
  use operation <- result.try(
    ids.parse_op_id(raw_operation)
    |> result.map_error(fn(_) { "expected `operation` to be an operation id" }),
  )
  use body <- result.try(text(fields, "text"))
  use state <- result.try(
    list.key_find(fields, "state")
    |> result.replace_error("missing `state`")
    |> result.try(decode_state),
  )
  Ok(Mail(
    id:,
    parent_strand:,
    child: agent.Handle(strand:, operation:),
    text: body,
    state:,
  ))
}

/// Decodes the mail lifecycle state from its JSON representation.
fn decode_state(value: JsonValue) -> Result(State, String) {
  use fields <- result.try(object(value, "a mail state"))
  use kind <- result.try(text(fields, "kind"))

  // Decode payload based on kind discriminator field.
  case kind {
    "pending" -> Ok(Pending)
    "answered" ->
      list.key_find(fields, "receipt")
      |> result.replace_error("missing `receipt`")
      |> result.try(remote_mail.decode_receipt)
      |> result.map(Answered)
    "refused" -> text(fields, "reason") |> result.map(Refused)
    other -> Error("unknown mail state `" <> other <> "`")
  }
}

/// Decodes a JSON object and extracts its key-value fields.
fn object(
  value: JsonValue,
  what: String,
) -> Result(List(#(String, JsonValue)), String) {
  // This branch resolves value before the operation continues.
  case value {
    json.Object(fields) -> Ok(fields)
    other -> Error("expected " <> what <> ", got " <> json.to_string(other))
  }
}

/// Extracts a required text property from parsed JSON object fields.
fn text(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(String, String) {
  // This branch resolves the input state before the operation continues.

  // This branch resolves the input state before the operation continues.
  case list.key_find(fields, name) {
    Ok(json.String(found)) -> Ok(found)
    Ok(_) -> Error("expected `" <> name <> "` to be text")
    Error(Nil) -> Error("missing `" <> name <> "`")
  }
}

// --- requests for more authority (protocol-change/089) -------------------------

const question_prefix = "delegate/outbox/escalation/"

/// How far a request's row has got.
pub type Sending {
  /// The laptop has not acknowledged this `seq`.
  NotAcknowledged

  /// The laptop acknowledged this `seq`. The row stays until the record leaves
  /// `pending`, so that the decided state is sent once.
  Acknowledged
}

/// One request a child raised, as the box owes it to the parent's operator.
pub type Question {
  Question(
    /// The record's identity on this box.
    id: String,
    /// The record's `seq` when the child raised it.
    seq: Int,
    /// The parent strand the child reports to.
    parent_strand: String,
    /// The child whose call raised the request. It waits on the record only
    /// for the park's short grace; the row outlives that.
    child: Handle,
    /// When the box stops asking, on the session's clock in milliseconds:
    /// `answer_window_ms` past the instant the child's call stopped parking.
    /// After it the row is dropped and the record waits for the box's owner.
    until: Int,
    /// How far it has got.
    sending: Sending,
  )
}

/// The key of a request's row.
///
/// ## Examples
///
/// ```gleam
/// assert delegate_outbox.question_key("policy-ab", 3)
///   == "delegate/outbox/escalation/policy-ab/3"
/// ```
pub fn question_key(id: String, seq: Int) -> String {
  question_prefix <> id <> "/" <> int.to_string(seq)
}

/// Writes the row a raised request left. A row that exists is left alone, so a
/// raise that is repeated at the same `seq` costs nothing.
///
/// ## Examples
///
/// ```gleam
/// // delegate_outbox.queue_question(runtime, delegate_outbox.Question(id:, seq: 3, parent_strand: "main", child:, until:, sending: delegate_outbox.NotAcknowledged))
/// ```
pub fn queue_question(
  runtime: api.Runtime,
  row: Question,
) -> Result(Nil, String) {
  case
    api.put_reserved_fact_expecting(
      runtime,
      question_key(row.id, row.seq),
      encode_question(row),
      expected: None,
    )
  {
    Ok(_) | Error(api.FactConflict(..)) -> Ok(Nil)
    Error(error) -> Error(string.inspect(error))
  }
}

/// Every request row, with its key, in key order. A cell that does not decode is
/// left out, as a mail row is: a row nobody can send must not keep the pass
/// owing for ever.
///
/// ## Examples
///
/// ```gleam
/// // delegate_outbox.question_rows(runtime) == Ok([#(key, row)])
/// ```
pub fn question_rows(
  runtime: api.Runtime,
) -> Result(List(#(String, Question)), String) {
  use cells <- result.map(
    api.reserved_facts(runtime, prefix: question_prefix)
    |> result.map_error(string.inspect),
  )
  list.filter_map(cells, fn(cell) {
    decode_question(cell.1)
    |> result.map(fn(row) { #(cell.0, row) })
    |> result.replace_error(Nil)
  })
}

/// Records that the laptop acknowledged the row's `seq`.
///
/// ## Examples
///
/// ```gleam
/// // delegate_outbox.settle_question(runtime, key, delegate_outbox.Question(..row, sending: delegate_outbox.Acknowledged))
/// ```
pub fn settle_question(
  runtime: api.Runtime,
  key: String,
  row: Question,
) -> Result(Nil, String) {
  api.put_reserved_fact(runtime, key, encode_question(row))
  |> result.map_error(string.inspect)
}

/// Removes a row that has served, or that a newer raise superseded.
///
/// ## Examples
///
/// ```gleam
/// // delegate_outbox.drop_question(runtime, key)
/// ```
pub fn drop_question(runtime: api.Runtime, key: String) -> Result(Nil, String) {
  api.delete_reserved_fact(runtime, key) |> result.map_error(string.inspect)
}

/// A request row as the value its cell holds.
///
/// ## Examples
///
/// ```gleam
/// // delegate_outbox.decode_question(delegate_outbox.encode_question(row)) == Ok(row)
/// ```
pub fn encode_question(row: Question) -> JsonValue {
  json.Object([
    #("id", json.String(row.id)),
    #("seq", json.Int(row.seq)),
    #("parent", json.String(row.parent_strand)),
    #("child", json.String(row.child.strand)),
    #("operation", json.String(ids.op_id_to_string(row.child.operation))),
    #("until", json.Int(row.until)),

    // This branch resolves row sending before the operation continues.
    #("sending", case row.sending {
      NotAcknowledged -> json.String("unsent")
      Acknowledged -> json.String("sent")
    }),
  ])
}

/// Decodes a request row. Total: anything malformed is an error naming what was
/// wrong.
///
/// ## Examples
///
/// ```gleam
/// assert delegate_outbox.decode_question(json.Null)
///   == Error("expected a request row, got null")
/// ```
pub fn decode_question(value: JsonValue) -> Result(Question, String) {
  use fields <- result.try(object(value, "a request row"))
  use id <- result.try(text(fields, "id"))
  use seq <- result.try(whole(fields, "seq"))
  use parent_strand <- result.try(text(fields, "parent"))
  use strand <- result.try(text(fields, "child"))
  use raw_operation <- result.try(text(fields, "operation"))
  use operation <- result.try(
    ids.parse_op_id(raw_operation)
    |> result.map_error(fn(_) { "expected `operation` to be an operation id" }),
  )
  use until <- result.try(whole(fields, "until"))

  // Decode acknowledgment sending state from string enum field.
  use sending <- result.try(case text(fields, "sending") {
    Ok("unsent") -> Ok(NotAcknowledged)
    Ok("sent") -> Ok(Acknowledged)
    Ok(other) -> Error("unknown sending state `" <> other <> "`")
    Error(reason) -> Error(reason)
  })

  Ok(Question(
    id:,
    seq:,
    parent_strand:,
    child: agent.Handle(strand:, operation:),
    until:,
    sending:,
  ))
}

/// Extracts a nonnegative integer field from parsed JSON object fields.
fn whole(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(Int, String) {
  // This branch resolves list key_find fields name before the operation continues.
  case list.key_find(fields, name) {
    Ok(json.Int(found)) if found >= 0 -> Ok(found)
    Ok(_) -> Error("expected `" <> name <> "` to be a nonnegative integer")
    Error(Nil) -> Error("missing `" <> name <> "`")
  }
}

/// How long after a child's call stops parking the box keeps asking the
/// spawner's operator, in milliseconds: five minutes.
///
/// The call itself parks only for the short grace `client/escalate` gives every
/// refusal (five seconds), then settles in band and leaves the record pending.
/// The record stays decidable after that: a decision commits it,
/// `escalate.notify_spawner_decision` steers the child if its run is still
/// open and otherwise opens one within the child's deadline, where re-issuing
/// the call spends it. Ending the row with the
/// park would end the question for the laptop while the box still accepts its
/// answer, and a request whose first send did not land inside five seconds would
/// never be shown at all. Five minutes is the window protocol-change/089 was
/// built around, when a call parked that long: it bounds how long the drainer
/// ticks for a question nobody answers, and a record still pending after it is
/// the box owner's, as one outside the ceiling is.
///
/// ## Examples
///
/// ```gleam
/// assert delegate_outbox.answer_window_ms == 300_000
/// ```
pub const answer_window_ms = 300_000

/// Writes the row for a request a child has just raised and is about to wait on.
///
/// `until` is the instant the child's call stops parking, and the row is kept
/// `answer_window_ms` past it. The record is read as it is, so the row names the
/// `seq` the child will be parked at. The parent strand comes from the child's lineage, which names it as
/// a reference (`^main`). A record that names no call, or a call whose strand has
/// no lineage, is not a child's and gets no row: nobody on the laptop could
/// answer it for a parent.
///
/// ## Examples
///
/// ```gleam
/// // delegate_outbox.announce(runtime, "policy-ab", until: 1_700_000_300_000)
/// ```
pub fn announce(
  runtime: api.Runtime,
  id: String,
  until until: Int,
) -> Result(Nil, String) {
  use cell <- result.try(
    api.escalation_cell(runtime, id) |> result.map_error(string.inspect),
  )
  use scope <- result.try(option.to_result(
    cell.record.scope,
    "the request names no call",
  ))
  use child <- result.try(
    lineage_of(runtime, scope.strand)
    |> result.replace_error("the request is not a child's"),
  )
  queue_question(
    runtime,
    Question(
      id:,
      seq: cell.seq,
      parent_strand: string.drop_start(
        child.parent,
        string.length(api.parent_reference_prefix),
      ),
      child: agent.Handle(strand: scope.strand, operation: scope.operation),
      until: until + answer_window_ms,
      sending: NotAcknowledged,
    ),
  )
}

/// Whether the party that could answer a delegate session's request is there to
/// be asked now: the spawner's table sets an approval ceiling and its node is
/// connected. It is the second half of what makes a delegate session attended,
/// beside the clients attached to its hub (protocol-change/089), and it is read
/// afresh on every poll of a parked call, so a laptop that goes away un-parks
/// the call at the next slice. Nothing is dialed: the box does not reach its
/// spawner, it only notices that the spawner has reached it.
///
/// ## Examples
///
/// ```gleam
/// assert !delegate_outbox.answers(option.None, option.None)
/// ```
pub fn answers(link: Option(SpawnerLink), laptop: Option(Laptop)) -> Bool {
  // This branch resolves link laptop before the operation continues.
  case link, laptop {
    Some(SpawnerLink(ceiling: Some(_), ..)), Some(found) -> found.connected()
    _, _ -> False
  }
}
