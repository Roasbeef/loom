//// One page of a remote child's transcript, from the orchestrator that runs
//// it to the host that draws it (protocol-change/090).
////
//// A child on another orchestrator keeps its conversation in a session of
//// that orchestrator. When the spawner's table there says
//// `transcript = "visible"`, the parent's daemon may ask for it with
//// `ChildHistory`, and the answer is one page of the child's branch: the
//// entries on the path from the child's leaf down its parent links, at most
//// `max_entries` of them and at most `page_bytes_limit` bytes of encoded
//// entries. The parent's daemon decodes the page here, totally and within
//// those bounds, and sends it on to the client that asked as the board of a
//// `child_history` observation, which the client decodes here again.
////
//// The page is built on the orchestrator that runs the child, from the
//// entries its store returns newest first (`page_of`). An entry whose
//// encoding alone is over the byte bound is not sent and is counted as
//// omitted, so one large tool result cannot stall the paging. `next` is the
//// sequence below which the next older page starts, and is `None` once the
//// page reaches the child's first entry.
////
//// What a host draws is `said`: one line of words for each entry, in the
//// order they were recorded. It is model text from another machine and is
//// never an instruction or markup, so a host draws every line as a text node
//// under the framing `strand_framing.transcript_head` and `transcript_foot`
//// give it, and never parses it as Markdown or HTML.
////
//// ## Flow
////
//// `page_of` → `encode` → `decode` → `decode_observation` → `receive` → `said`
////
//// 1. `page_of` cuts a page from the entries a store returned, on the
////    orchestrator that runs the child.
//// 2. `encode` and `decode` are the page's wire form on both hops.
//// 3. `decode_observation` reads the board of a transcript observation,
////    and `open`, `sent` and `receive` keep a host's one pending peek.
//// 4. `said` turns the page's entries into the words a host draws.

import core/codec
import core/entry.{type Entry}
import core/json.{type JsonValue}
import core/message
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/strand_framing
import session_view/text_hygiene

/// The most entries one page carries, and the most a request may ask for.
pub const max_entries = 50

/// The most bytes of encoded entries one page carries.
pub const page_bytes_limit = 262_144

/// The most bytes one `child_history` board may be on the client's hop: a page
/// at its bound and the observation's own fields.
pub const board_bytes_limit = 300_000

/// The most characters of one entry a host draws. The page is bounded by bytes
/// already; this keeps one long answer from filling a drawer.
pub const said_limit = 4000

/// One page of a child's branch.
pub type Page {
  Page(
    /// The child's strand name on the orchestrator that runs it.
    child: String,
    /// The entries, oldest first.
    entries: List(Entry),
    /// How many entries in the page's span were too large to send.
    omitted: Int,
    /// The sequence the next older page reads below, or `None` when this page
    /// reaches the child's first entry.
    next: Option(Int),
  )
}

/// Cuts one page from the entries a branch read returned, newest first.
///
/// `scanned` holds at most `limit + 1` entries, the extra one saying that
/// older entries exist. The page keeps entries, newest first, while their
/// encoded bytes stay within `page_bytes_limit`, and counts an entry that is
/// over the bound alone as omitted. It stops before the entry that would carry
/// it past the bound. `next` is then the sequence of the oldest entry the page
/// took or omitted, so the following read starts with the entry that did not
/// fit, and a page always takes or omits at least one entry.
///
/// ## Examples
///
/// ```gleam
/// // remote_transcript.page_of("sub:^main/build-1a2b", newest_first, 20)
/// // == Page(child: "sub:^main/build-1a2b", entries: oldest_first, omitted: 0, next: None)
/// ```
pub fn page_of(child: String, scanned: List(Entry), limit: Int) -> Page {
  let limit = int.clamp(limit, min: 1, max: max_entries)
  let more = list.length(scanned) > limit
  let #(kept, omitted, oldest, full) =
    take(list.take(scanned, limit), [], 0, None, 0)
  let next = case more || full {
    True -> oldest
    False -> None
  }
  Page(child:, entries: kept, omitted:, next:)
}

// Walks the entries newest first. `kept` is built oldest first by prepending,
// `oldest` is the sequence of the last entry taken or omitted, and the fourth
// element says whether the walk stopped at the byte bound.
fn take(
  entries: List(Entry),
  kept: List(Entry),
  omitted: Int,
  oldest: Option(Int),
  bytes: Int,
) -> #(List(Entry), Int, Option(Int), Bool) {
  case entries {
    [] -> #(kept, omitted, oldest, False)
    [record, ..rest] -> {
      let size = encoded_bytes(record)
      case size > page_bytes_limit, bytes + size > page_bytes_limit {
        True, _ -> take(rest, kept, omitted + 1, Some(record.seq), bytes)
        False, True -> #(kept, omitted, oldest, True)
        False, False ->
          take(rest, [record, ..kept], omitted, Some(record.seq), bytes + size)
      }
    }
  }
}

fn encoded_bytes(record: Entry) -> Int {
  string.byte_size(json.to_string(codec.encode_entry(record)))
}

/// A page as its wire object.
///
/// ## Examples
///
/// ```gleam
/// // remote_transcript.encode(page)
/// // == {"child": "sub:^main/build-1a2b", "entries": [..], "omitted": 0, "next": null}
/// ```
pub fn encode(page: Page) -> JsonValue {
  json.Object([
    #("child", json.String(page.child)),
    #("entries", json.Array(list.map(page.entries, codec.encode_entry))),
    #("omitted", json.Int(page.omitted)),
    #("next", case page.next {
      Some(seq) -> json.Int(seq)
      None -> json.Null
    }),
  ])
}

/// A page from its wire object, within the page's bounds. More than
/// `max_entries` entries, an entry the shared codec cannot read, a negative
/// count or a cursor that is not a positive sequence is an error, so a page is
/// read whole or refused.
///
/// ## Examples
///
/// ```gleam
/// assert remote_transcript.decode(remote_transcript.encode(page)) == Ok(page)
/// ```
pub fn decode(value: JsonValue) -> Result(Page, String) {
  use fields <- result.try(object(value, "a transcript page"))
  decode_fields(fields)
}

fn decode_fields(fields: List(#(String, JsonValue))) -> Result(Page, String) {
  use child <- result.try(case list.key_find(fields, "child") {
    Ok(json.String(child)) if child != "" ->
      case string.byte_size(child) > 512 {
        True -> Error("the page's child name is over its bound")
        False -> Ok(child)
      }
    Ok(_) | Error(Nil) -> Error("the page's child must be a nonempty string")
  })
  use items <- result.try(case list.key_find(fields, "entries") {
    Ok(json.Array(items)) ->
      case list.length(items) > max_entries {
        True -> Error("the page holds more entries than its bound")
        False -> Ok(items)
      }
    Ok(_) | Error(Nil) -> Error("the page's entries must be an array")
  })
  use entries <- result.try(
    list.try_map(items, fn(item) {
      codec.decode_entry(item)
      |> result.map_error(fn(report) { "an entry: " <> report.expected })
    }),
  )
  use omitted <- result.try(case list.key_find(fields, "omitted") {
    Ok(json.Int(count)) if count >= 0 -> Ok(count)
    Ok(_) | Error(Nil) ->
      Error("the page's omitted count must be a nonnegative integer")
  })
  use next <- result.map(case list.key_find(fields, "next") {
    Ok(json.Null) -> Ok(None)
    Ok(json.Int(seq)) if seq >= 1 -> Ok(Some(seq))
    Ok(_) | Error(Nil) -> Error("the page's cursor must be a sequence or null")
  })
  Page(child:, entries:, omitted:, next:)
}

fn object(
  value: JsonValue,
  place: String,
) -> Result(List(#(String, JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error(place <> " must be an object")
  }
}

// --- a host's peek ------------------------------------------------------------

/// What a `child_history` observation board says. Both the acknowledgement and
/// the completion carry the request they answer.
pub type Event {
  /// The daemon admitted the read and will push its outcome.
  Pending(id: Int)

  /// The page arrived.
  Ready(id: Int, page: Page)

  /// The read failed, with the reason in words for a person.
  Failed(id: Int, reason: String)
}

/// A host's one peek at a remote child's transcript.
pub type State {
  /// No peek is open.
  Closed

  /// A peek is open and its page has not arrived.
  Loading(
    /// The child's strand name on the orchestrator that runs it.
    child: String,
    /// The orchestrator it runs on.
    orchestrator: String,
    /// The request the page will answer, once it has been sent.
    request: Option(Int),
  )

  /// A page arrived for the open peek.
  Shown(child: String, orchestrator: String, page: Page)

  /// The open peek's read failed.
  Unavailable(child: String, orchestrator: String, reason: String)
}

/// A `child_history` observation board, within `board_bytes_limit`.
///
/// ## Examples
///
/// ```gleam
/// // remote_transcript.decode_observation(board) == Ok(remote_transcript.Pending(7))
/// ```
pub fn decode_observation(value: JsonValue) -> Result(Event, String) {
  use <- bool.guard(
    string.byte_size(json.to_string(value)) > board_bytes_limit,
    Error("the transcript observation is over its bound"),
  )
  use fields <- result.try(object(value, "a transcript observation"))
  use id <- result.try(case list.key_find(fields, "request_id") {
    Ok(json.Int(id)) -> Ok(id)
    Ok(_) | Error(Nil) -> Error("request_id must be an integer")
  })
  case list.key_find(fields, "status") {
    Ok(json.String("pending")) -> Ok(Pending(id))
    Ok(json.String("ready")) ->
      decode_fields(fields) |> result.map(Ready(id, _))
    Ok(json.String("failed")) ->
      case list.key_find(fields, "message") {
        Ok(json.String(reason)) -> Ok(Failed(id, reason))
        Ok(_) | Error(Nil) -> Error("a failed observation must say why")
      }
    Ok(_) | Error(Nil) -> Error("unknown transcript observation status")
  }
}

/// Opens a peek at a child, replacing any peek that was open.
///
/// ## Examples
///
/// ```gleam
/// assert remote_transcript.open("sub:^main/build-1a2b", "box")
///   == remote_transcript.Loading("sub:^main/build-1a2b", "box", option.None)
/// ```
pub fn open(child: String, orchestrator: String) -> State {
  Loading(child:, orchestrator:, request: None)
}

/// Records the request a loading peek was sent as. Any other state is kept,
/// since only a loading peek is waiting for a page.
///
/// ## Examples
///
/// ```gleam
/// // remote_transcript.sent(remote_transcript.open(child, "box"), 7)
/// ```
pub fn sent(state: State, id: Int) -> State {
  case state {
    Loading(child:, orchestrator:, ..) ->
      Loading(child:, orchestrator:, request: Some(id))
    Closed | Shown(..) | Unavailable(..) -> state
  }
}

/// Applies an observation to the open peek. Only the answer to the request the
/// peek was sent as is applied, and only a page for the child the peek is
/// open on, so an answer that arrives after the peek moved on is ignored.
///
/// ## Examples
///
/// ```gleam
/// // remote_transcript.receive(loading, remote_transcript.Ready(7, page))
/// ```
pub fn receive(state: State, event: Event) -> State {
  case state {
    Loading(child:, orchestrator:, request: Some(expected)) ->
      case event {
        Pending(_) -> state
        Ready(id, page) if id == expected && page.child == child ->
          Shown(child:, orchestrator:, page:)
        Ready(id, _) if id == expected ->
          Unavailable(
            child:,
            orchestrator:,
            reason: "the page belongs to another child",
          )
        Failed(id, reason) if id == expected ->
          Unavailable(child:, orchestrator:, reason:)
        Ready(..) | Failed(..) -> state
      }

    // A peek that has not been sent, or that already has its answer, is not
    // waiting for one, so a late or stray observation changes nothing.
    Loading(request: None, ..) | Closed | Shown(..) | Unavailable(..) -> state
  }
}

/// The lines a text host draws for a peek, oldest first and as plain text: the
/// framing head, each entry's speaker and words, how much of the page was left
/// out, the framing foot, and how to close the peek. A closed peek draws
/// nothing. The words are data, and a host draws each line as text, never
/// through its Markdown renderer.
///
/// ## Examples
///
/// ```gleam
/// // remote_transcript.lines(shown)
/// // == ["[transcript of sub:^main/build-1a2b on box]", "", "asked: check the build", ..]
/// ```
pub fn lines(state: State) -> List(String) {
  let close = "/peek close"
  case state {
    Closed -> []
    Loading(child:, orchestrator:, ..) -> [
      strand_framing.transcript_head(child, orchestrator),
      "Reading the transcript from " <> orchestrator <> "…",
      close,
    ]
    Unavailable(child:, orchestrator:, reason:) -> [
      strand_framing.transcript_head(child, orchestrator),
      "Transcript unavailable: " <> text_hygiene.single_line(reason),
      close,
    ]
    Shown(child:, orchestrator:, page:) ->
      list.flatten([
        [strand_framing.transcript_head(child, orchestrator), ""],
        case page.next {
          Some(_) -> ["(older entries are not shown)", ""]
          None -> []
        },
        list.flat_map(said(page), fn(line) {
          [speaker_word(line.speaker) <> ": " <> line.text, ""]
        }),
        case page.omitted {
          0 -> []
          count -> [
            int.to_string(count) <> " entries too large to show were left out",
          ]
        },
        [strand_framing.transcript_foot, close],
      ])
  }
}

/// Who an entry's words belong to.
pub type Speaker {
  /// A message to the child: its brief, or a message its parent sent.
  Asked

  /// The child's own answer.
  Answered

  /// A tool the child called.
  Called

  /// What a tool returned to the child.
  Returned

  /// A note the child's store recorded, such as a compaction.
  Noted
}

/// One line a host draws.
pub type Said {
  Said(
    /// Whose words they are.
    speaker: Speaker,
    /// The words, cut to `said_limit` characters, with control characters
    /// other than the newline removed.
    text: String,
  )
}

/// The words a host draws for a page, oldest first. Reasoning blocks and
/// images are not drawn: a reasoning block is the provider's and an image's
/// bytes are not words. A message framed by the Agency loses its framing, as a
/// local strand's does, since the host frames the whole page itself.
///
/// ## Examples
///
/// ```gleam
/// // remote_transcript.said(page)
/// // == [Said(Asked, "check the build"), Said(Called, "bash"), Said(Answered, "it passes")]
/// ```
pub fn said(page: Page) -> List(Said) {
  list.flat_map(page.entries, entry_said)
}

/// The words a host's speaker label shows.
///
/// ## Examples
///
/// ```gleam
/// assert remote_transcript.speaker_word(remote_transcript.Called) == "tool"
/// ```
pub fn speaker_word(speaker: Speaker) -> String {
  case speaker {
    Asked -> "asked"
    Answered -> "answer"
    Called -> "tool"
    Returned -> "result"
    Noted -> "note"
  }
}

fn entry_said(record: Entry) -> List(Said) {
  case record {
    entry.MessageEntry(message:, ..) -> message_said(message)
    entry.CompactionEntry(..) -> [said_as(Noted, "context compacted")]
    entry.BranchSummaryEntry(summary:, ..) -> [said_as(Noted, summary)]
    entry.CustomEntry(..) -> []
  }
}

fn message_said(sent: message.AgentMessage) -> List(Said) {
  case sent {
    message.UserMessage(content:, origin:, ..) -> {
      let text =
        content
        |> list.filter_map(fn(block) {
          case block {
            message.UserText(text:, ..) -> Ok(text)
            message.UserImage(..) -> Error(Nil)
          }
        })
        |> string.join("\n")

      // A child on another orchestrator is briefed and messaged by a parent the
      // receiving host records as a peer, framed under the parent's reference.
      let body = case origin {
        Some(message.StrandOrigin(strand:)) ->
          strand_framing.strip(text, strand).body
        Some(message.PeerOrigin(strand:, ..)) ->
          strand_framing.strip(text, "^" <> strand).body
        Some(message.Origin(..)) | None -> text
      }
      case body {
        "" -> []
        body -> [said_as(Asked, body)]
      }
    }
    message.AssistantMessage(content:, ..) ->
      list.filter_map(content, fn(block) {
        case block {
          message.AssistantText(text: "", ..) -> Error(Nil)
          message.AssistantText(text:, ..) -> Ok(said_as(Answered, text))
          message.AssistantToolCall(call:) -> Ok(said_as(Called, call.name))
          message.AssistantThinking(..) -> Error(Nil)
        }
      })
    message.ToolResultMessage(tool_name:, content:, ..) -> {
      let text =
        content
        |> list.filter_map(fn(block) {
          case block {
            message.ToolResultText(text:, ..) -> Ok(text)
            message.ToolResultImage(..) -> Error(Nil)
          }
        })
        |> string.join("\n")
      [said_as(Returned, tool_name <> ": " <> text)]
    }
    message.CustomMessage(..) -> []
  }
}

fn said_as(speaker: Speaker, text: String) -> Said {
  Said(
    speaker:,
    text: text_hygiene.multiline(text) |> string.slice(0, said_limit),
  )
}
