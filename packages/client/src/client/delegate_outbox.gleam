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
////
//// The kinds are a namespace. Escalations, which phase 3 sends the same way, take
//// `delegate/outbox/escalation/{id}/{seq}`.
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
//// `queue_mail` → `mail_rows` → `settle_mail` → `unsent_glances` → `acknowledge`
////
//// 1. `queue_mail` writes the row a child's upward send left.
//// 2. `mail_rows` lists the rows, and `settle_mail` records the laptop's answer
////    on one.
//// 3. `unsent_glances` lists the glances the laptop has not acknowledged, and
////    `acknowledge` records one that it has.

import client/remote_mail.{type ChildRefusal, type Receipt}
import client/remote_spawn.{type Parent}
import core/glance.{type Glance}
import core/ids
import core/json.{type JsonValue}
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
  use Nil <- result.try(case string.byte_size(row.text) <= max_text_bytes {
    True -> Ok(Nil)
    False -> Error("the message is longer than a message may be")
  })
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

fn read_mail(
  runtime: api.Runtime,
  key: String,
) -> Result(Option(Mail), String) {
  use cell <- result.try(
    api.fact(runtime, key) |> result.map_error(string.inspect),
  )
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

fn acknowledged_at(runtime: api.Runtime, strand: String) -> Int {
  case api.fact(runtime, progress_prefix <> strand) {
    Ok(Some(json.Object(fields))) ->
      case list.key_find(fields, "at") {
        Ok(json.Int(at)) -> at
        Ok(_) | Error(Nil) -> 0
      }
    Ok(Some(_)) | Ok(None) | Error(_) -> 0
  }
}

fn lineage_of(
  runtime: api.Runtime,
  strand: String,
) -> Result(lineage.Lineage, Nil) {
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

fn decode_state(value: JsonValue) -> Result(State, String) {
  use fields <- result.try(object(value, "a mail state"))
  use kind <- result.try(text(fields, "kind"))
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

fn object(
  value: JsonValue,
  what: String,
) -> Result(List(#(String, JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    other -> Error("expected " <> what <> ", got " <> json.to_string(other))
  }
}

fn text(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(String, String) {
  case list.key_find(fields, name) {
    Ok(json.String(found)) -> Ok(found)
    Ok(_) -> Error("expected `" <> name <> "` to be text")
    Error(Nil) -> Error("missing `" <> name <> "`")
  }
}
