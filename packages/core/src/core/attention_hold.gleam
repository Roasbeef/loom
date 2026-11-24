//// What an open ask does to the strand that made it (protocol-change/119,
//// "Addendum 2026-11-23: an open ask holds the strand").
////
//// An ask ends the run and the answer arrives later as a new user message, so
//// until then the strand is idle with a question outstanding. Two decisions
//// follow from that state, and both need the same answer to one question:
//// which asks of this strand are still waiting on the owner? The runtime asks
//// it before it lets an automatic input start a run, and the daemon asks it
//// before every provider request to word a reminder. This module answers it
//// from the stored cells, so the two readers cannot disagree about it.
////
//// ## Flow
////
//// `holding` → `reminder`
////
//// 1. `holding` takes the cells under `attention/ask/`, decodes each one,
////    and keeps the open asks that this strand made and routed to the owner,
////    oldest first.
//// 2. `reminder` words those asks as the fixed text a request carries, or
////    nothing when there are none.
////
//// ## What this module does not decide
////
//// It reads no store and holds nothing. It does not know whether an answer is
//// in flight: the daemon delivers an answer before it settles the record, so a
//// request built in that gap still sees the ask open, and the caller removes
//// it with `core/attention_answer.is_answer_to` over the messages it holds.

import core/attention.{type Ask, AskOpen, ToOwner}
import core/attention_answer
import core/glance
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/string

/// The most asks the reminder names. A session may hold 32 open asks, and a
/// reminder that listed them all would be most of a request.
pub const max_listed = 4

/// The longest head of a question the reminder shows, in bytes.
pub const head_bytes = 100

/// The line that opens the reminder, which a reader can search a request for.
pub const lead = "[open ask: the owner has not answered]"

/// The line that closes it.
pub const trail = "[end open ask]"

/// The open asks of `strand` that wait on the owner, oldest first.
///
/// A cell that does not decode is left out, as it is from every other
/// listing of asks, and so is the guard cell that shares the prefix. An ask
/// routed to another strand is not waiting on the owner, and an ask another
/// strand made is not this strand's to wait for.
///
/// ## Examples
///
/// ```gleam
/// // attention_hold.holding(cells, "main") == [ask]
/// ```
pub fn holding(cells: List(#(String, JsonValue)), strand: String) -> List(Ask) {
  cells
  |> list.filter_map(fn(cell) {
    attention.decode_ask(cell.1) |> result.replace_error(Nil)
  })
  |> list.filter(fn(ask) {
    ask.state == AskOpen
    && ask.header.routing == ToOwner
    && ask.header.strand == strand
  })
  |> list.sort(by: fn(left, right) {
    case int.compare(left.header.created_at, right.header.created_at) {
      order.Eq -> string.compare(left.header.id, right.header.id)
      other -> other
    }
  })
}

/// Removes the asks whose answer is already among `texts`.
///
/// `texts` are the user messages of the request. The daemon delivers an
/// answer and then settles the record, so a run the answer starts can read the
/// record before it is settled, and the reminder would tell the model that the
/// ask it has just been answered is still open. The answer's own text names
/// the ask, which is how the two are matched.
///
/// ## Examples
///
/// ```gleam
/// // attention_hold.unanswered(asks, ["Answer to your ask ask-3f9c01a2b4.\n\n..."])
/// ```
pub fn unanswered(asks: List(Ask), texts: List(String)) -> List(Ask) {
  list.filter(asks, fn(ask) {
    !list.any(texts, attention_answer.is_answer_to(_, ask.header.id))
  })
}

/// The reminder a request carries while `asks` are open, or `Error(Nil)` when
/// there are none and the request carries nothing.
///
/// The text names each ask by id and by its first question, tells the model
/// that the owner has not answered, and says what that forbids and what it
/// leaves alone. It is fixed apart from the asks it names, so it is the same
/// bytes on every request while the same asks are open.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(text) = attention_hold.reminder([ask])
/// assert string.contains(text, "ask-3f9c01a2b4")
/// ```
pub fn reminder(asks: List(Ask)) -> Result(String, Nil) {
  case asks {
    [] -> Error(Nil)
    _ -> {
      let listed = list.take(asks, max_listed)
      let more = list.length(asks) - list.length(listed)
      Ok(string.join(
        [
          lead,
          "You asked the owner, and the owner has not answered:",
          string.join(list.map(listed, line), "\n") <> unlisted(more),
          "A message that does not begin \"Answer to your ask\" is not the answer, so \"continue\" or any other message from someone else does not decide what you asked. Do not do what the answer decides. You may do other work that does not depend on it, and you may say what you are waiting for. If you have nothing else to do, end your turn.",
          trail,
        ],
        "\n",
      ))
    }
  }
}

/// One ask as a line: its id, its first question, and how many more it has.
fn line(ask: Ask) -> String {
  let first = case ask.questions {
    [question, ..] -> glance.clip(question.prompt, head_bytes)
    [] -> ""
  }
  let rest = case list.length(ask.questions) - 1 {
    0 -> ""
    1 -> " (and 1 more question)"
    count -> " (and " <> int.to_string(count) <> " more questions)"
  }
  "- " <> ask.header.id <> ": " <> first <> rest
}

/// The line that says how many open asks the reminder left out.
fn unlisted(more: Int) -> String {
  case more {
    0 -> ""
    1 -> "\n- and 1 more open ask"
    count -> "\n- and " <> int.to_string(count) <> " more open asks"
  }
}
