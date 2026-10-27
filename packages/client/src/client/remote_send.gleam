//// The sends a parent session owes a child on another orchestrator
//// (protocol-change/084, phase 2).
////
//// A model's `agent_send` to a remote child is attempted at once, and an
//// orchestrator that does not answer leaves the model with a message it was told
//// is queued. The row in this module is what makes that true. It is written
//// before the model is answered, under the reserved prefix
//// `runtime/api.remote_send_fact_prefix` as `remote-send/{message id}`, and the
//// remote drainer (`client/remote_drain`) sends it again at each pass until the
//// orchestrator answers.
////
//// ## Only an answer settles it
////
//// The message id is the sending call site's digest, and the orchestrator stores
//// a receipt under it (`delegate/receipt/{id}`), so a resend after a lost reply
//// delivers nothing twice and is answered `Admitted`. That is why the drainer
//// needs no receipt of its own and the row needs no state: it exists until an
//// answer arrives, whether the answer is a landing or a refusal, and then it is
//// removed. A row has no time to live, for the reason a stub has none
//// (`client/remote_drain`): the child it concerns is bounded by its own deadline
//// on the other orchestrator, and a row for a child that is gone is answered
//// with a refusal that removes it.
////
//// ## Flow
////
//// `queue` → `all` → `settle`
////
//// 1. `queue` writes the row, or finds the one an earlier attempt of the same
////    call site wrote.
//// 2. `all` lists the rows the drainer owes.
//// 3. `settle` removes a row once the orchestrator has answered.

import core/ids
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/api
import tools/agent.{type Handle}

/// A message waiting to be delivered to a child.
pub type Row {
  Row(
    /// The message's identity: the sending call site's digest.
    id: String,
    /// The `[orchestrators.<name>]` the child runs on.
    orchestrator: String,
    /// The parent strand that sent it.
    parent_strand: String,
    /// The child, as its stub recorded it.
    child: Handle,
    /// What the parent said.
    text: String,
  )
}

/// The most text a row holds, in bytes. The message is a model's, and the row is
/// stored and sent.
pub const max_text_bytes = 32_768

/// The key of the row for one message.
///
/// ## Examples
///
/// ```gleam
/// assert remote_send.key("7b1c") == "remote-send/7b1c"
/// ```
pub fn key(id: String) -> String {
  api.remote_send_fact_prefix <> id
}

/// Writes the row for a message unless one is there.
///
/// The write expects the cell to be absent, so a replay of the same call site
/// finds the row its first attempt wrote and leaves it. A row with other content
/// under the same id is the id reused for a different message and is refused.
///
/// ## Examples
///
/// ```gleam
/// // remote_send.queue(runtime, remote_send.Row(id:, orchestrator: "box", parent_strand: "main", child:, text: "hello"))
/// ```
pub fn queue(runtime: api.Runtime, row: Row) -> Result(Nil, String) {
  // This match resolves string.byte_size(row.text) <= max_text_bytes before the enclosing validation continues.
  use Nil <- result.try(case string.byte_size(row.text) <= max_text_bytes {
    True -> Ok(Nil)
    False -> Error("the message is longer than a message may be")
  })

  // This branch resolves the queue decision before the operation proceeds.
  case
    api.put_reserved_fact_expecting(
      runtime,
      key(row.id),
      encode(row),
      expected: None,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(api.FactConflict(..)) -> {
      use found <- result.try(read(runtime, key(row.id)))

      // This match resolves found before the surrounding protocol step continues.
      // This match resolves found before the enclosing validation continues.
      case found {
        Some(held) if held == row -> Ok(Nil)
        Some(_) | None ->
          Error("the message id was already used for a different message")
      }
    }
    Error(error) -> Error(string.inspect(error))
  }
}

/// Every row the session owes, in key order. A cell that does not decode is left
/// out: a corrupt row is a message nobody can send, and listing it as owed would
/// keep the drainer ticking for ever.
///
/// ## Examples
///
/// ```gleam
/// // remote_send.all(runtime) == Ok([row])
/// ```
pub fn all(runtime: api.Runtime) -> Result(List(Row), String) {
  use cells <- result.map(
    api.reserved_facts(runtime, prefix: api.remote_send_fact_prefix)
    |> result.map_error(string.inspect),
  )
  list.filter_map(cells, fn(cell) {
    decode(cell.1) |> result.replace_error(Nil)
  })
}

/// Removes the row for a message the orchestrator has answered.
///
/// ## Examples
///
/// ```gleam
/// // remote_send.settle(runtime, "7b1c")
/// ```
pub fn settle(runtime: api.Runtime, id: String) -> Result(Nil, String) {
  api.delete_reserved_fact(runtime, key(id))
  |> result.map_error(string.inspect)
}

/// Read keeps this client operation’s decoding or state decision in one place.
fn read(runtime: api.Runtime, at: String) -> Result(Option(Row), String) {
  use cell <- result.try(
    api.fact(runtime, at) |> result.map_error(string.inspect),
  )

  // This match resolves cell before the surrounding protocol step continues.
  // This match resolves cell before the enclosing validation continues.
  case cell {
    None -> Ok(None)
    Some(value) -> decode(value) |> result.map(Some)
  }
}

/// A row as the value its cell holds.
///
/// ## Examples
///
/// ```gleam
/// // remote_send.decode(remote_send.encode(row)) == Ok(row)
/// ```
pub fn encode(row: Row) -> JsonValue {
  json.Object([
    #("id", json.String(row.id)),
    #("orchestrator", json.String(row.orchestrator)),
    #("parent", json.String(row.parent_strand)),
    #("child", json.String(row.child.strand)),
    #("operation", json.String(ids.op_id_to_string(row.child.operation))),
    #("text", json.String(row.text)),
  ])
}

/// Decodes a row. Total: anything malformed is an error that names what was
/// wrong, never a crash.
///
/// ## Examples
///
/// ```gleam
/// assert remote_send.decode(json.Null) == Error("expected a send row, got null")
/// ```
pub fn decode(value: JsonValue) -> Result(Row, String) {
  // This match resolves value before the surrounding protocol step continues.
  // This match resolves value before the enclosing validation continues.
  case value {
    json.Object(fields) -> {
      use id <- result.try(text(fields, "id"))
      use orchestrator <- result.try(text(fields, "orchestrator"))
      use parent_strand <- result.try(text(fields, "parent"))
      use strand <- result.try(text(fields, "child"))
      use raw <- result.try(text(fields, "operation"))
      use operation <- result.try(
        ids.parse_op_id(raw)
        |> result.map_error(fn(_) {
          "expected `operation` to be an operation id"
        }),
      )
      use body <- result.map(text(fields, "text"))
      Row(
        id:,
        orchestrator:,
        parent_strand:,
        child: agent.Handle(strand:, operation:),
        text: body,
      )
    }
    other -> Error("expected a send row, got " <> json.to_string(other))
  }
}

/// Text keeps this client operation’s decoding or state decision in one place.
fn text(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(String, String) {
  // This match resolves list.key_find(fields, name) before the surrounding protocol step continues.
  // This match resolves list.key_find(fields, name) before the enclosing validation continues.
  case list.key_find(fields, name) {
    Ok(json.String(found)) -> Ok(found)
    Ok(_) -> Error("expected `" <> name <> "` to be text")
    Error(Nil) -> Error("missing `" <> name <> "`")
  }
}
