//// A bounded page of one session's timeline cards, as Home holds it
//// (protocol-change/134, `docs/design-notes/session-timeline.md`, section 5).
////
//// The daemon answers `sessions.timeline` with this: the cards the cut made of
//// the session's main strand, the newest page of them, a cursor for the older
//// ones, and the span still open. This module is the types, the one total
//// decoder from that reply and the encoder the resident answers with, so the two
//// halves of the wire are written in one place and a round trip tests them
//// together. It draws nothing and performs no I/O.
////
//// ## Flow
////
//// `of_card` → `to_json` → `decode` → `card` → `file`
////
//// 1. `of_card` wraps a cut's card, whose strings are session text, in the types
////    below, where each string is `Untrusted`.
//// 2. `to_json` is the reply the resident builds, and `decode` is its inverse.
//// 3. `decode` keeps the cards that read, through `card` and `file`, so one
////    damaged card is absent and the rest still draw.
////
//// ## What is session text
////
//// A path, a command, a child's purpose and the first words of a prompt or an
//// answer are text that an agent, a tool or a person wrote. They are wrapped in
//// `session_brief.Untrusted`, so a page must say `session_brief.untrusted_text`
//// to read one and draws it as a text node, never as markup, an attribute, a key
//// or a path. The kind word, the times and the numbers are the harness's own.

import core/ids
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/timeline
import web_view/session_brief.{type Untrusted}

/// The most cards one reply carries.
pub const max_cards = 20

/// The cards a reply carries when the request names no limit.
pub const default_limit = 10

/// The encoded size a reply never exceeds, in bytes. The resident sheds the
/// oldest cards until it fits.
pub const feed_bytes = 32_000

/// A file a card names, with the lines its edits added and removed.
pub type File {
  File(path: Untrusted, added: Int, removed: Int)
}

/// A command a card ran, reduced to its executable and subcommand, and the exit
/// status its result recorded.
pub type Command {
  Command(text: Untrusted, exit: Int)
}

/// One span of the strand.
pub type Card {
  Card(
    kind: timeline.Kind,
    /// The sequence of the prompt that began the turn, or 0.
    turn_seq: Int,
    /// The sequence of the span's first and last records.
    from_seq: Int,
    to_seq: Int,
    /// The id of the span's last record, as text.
    last: String,
    /// Unix milliseconds of the first and last records.
    started_at: Int,
    ended_at: Int,
    /// Tool calls in the span, how many only read, and how many failed.
    steps: Int,
    reads: Int,
    failed: Int,
    /// The first files the span wrote, and how many it wrote in all.
    files: List(File),
    files_total: Int,
    command: Option(Command),
    spawned: List(Untrusted),
    peers: Int,
    tokens_before: Option(Int),
    excerpt: Option(Untrusted),
  )
}

/// A page of cards.
pub type Feed {
  Feed(
    /// The cards, oldest first.
    cards: List(Card),
    /// The `from_seq` to ask `before` for the older cards, when there are some.
    older: Option(Int),
    /// What has happened since the last closed card, when anything has.
    now: Option(Card),
  )
}

/// What the page holds of a session's timeline.
pub type Seen {
  /// The daemon answered with this page.
  Seen(feed: Feed)

  /// The daemon refused or did not answer. The words are its fixed ones.
  Unseen(words: String)
}

/// A cut's card in the wire's types, each string marked as session text.
///
/// ## Examples
///
/// ```gleam
/// // timeline_feed.of_card(card).steps == card.facts.steps
/// ```
pub fn of_card(card: timeline.Card) -> Card {
  let facts = card.facts

  Card(
    kind: card.kind,
    turn_seq: card.turn_seq,
    from_seq: card.from_seq,
    to_seq: card.to_seq,
    last: ids.entry_id_to_string(card.last),
    started_at: card.started_at,
    ended_at: card.ended_at,
    steps: facts.steps,
    reads: facts.reads,
    failed: facts.failed,
    files: list.map(facts.files, fn(file) {
      File(session_brief.untrusted(file.path), file.added, file.removed)
    }),
    files_total: facts.files_total,
    command: option.map(facts.command, fn(command) {
      Command(session_brief.untrusted(command.text), command.exit)
    }),
    spawned: list.map(facts.spawned, session_brief.untrusted),
    peers: facts.peers,
    tokens_before: facts.tokens_before,
    excerpt: option.map(facts.excerpt, session_brief.untrusted),
  )
}

/// The timeline of a reply `{"timeline": {...}}`, or nothing for a reply that is
/// not one. A damaged card is left out and the others are kept.
///
/// ## Examples
///
/// ```gleam
/// assert timeline_feed.decode(json.Null) == Error(Nil)
/// ```
pub fn decode(value: JsonValue) -> Result(Feed, Nil) {
  use fields <- result.try(object(value))
  use inner <- result.try(list.key_find(fields, "timeline"))
  use inner <- result.map(object(inner))

  Feed(
    cards: items(inner, "cards"),
    older: option.from_result(whole(inner, "older")),
    now: member(inner, "now"),
  )
}

/// The reply a resident answers with: `{"timeline": {...}}`. An absent cursor and
/// an absent open span are left out.
///
/// ## Examples
///
/// ```gleam
/// assert timeline_feed.decode(timeline_feed.to_json(feed)) == Ok(feed)
/// ```
pub fn to_json(feed: Feed) -> JsonValue {
  json.Object([
    #(
      "timeline",
      json.Object(
        list.flatten([
          [#("cards", json.Array(list.map(feed.cards, card_json)))],
          case feed.older {
            Some(older) -> [#("older", json.Int(older))]
            None -> []
          },
          case feed.now {
            Some(now) -> [#("now", card_json(now))]
            None -> []
          },
        ]),
      ),
    ),
  ])
}

// --- reading ----------------------------------------------------------------

/// The open span, when it is one object that reads.
fn member(fields: List(#(String, JsonValue)), name: String) -> Option(Card) {
  list.key_find(fields, name)
  |> result.try(object)
  |> result.try(card)
  |> option.from_result
}

/// A list of cards, keeping the ones that read.
fn items(fields: List(#(String, JsonValue)), name: String) -> List(Card) {
  // A section that is not a list is no cards.
  case list.key_find(fields, name) {
    Ok(json.Array(raw)) ->
      list.filter_map(raw, fn(value) { object(value) |> result.try(card) })
    Ok(_) | Error(Nil) -> []
  }
}

/// One card, or nothing when a required member is missing or of the wrong type.
fn card(fields: List(#(String, JsonValue))) -> Result(Card, Nil) {
  use kind <- result.try(
    text(fields, "kind") |> result.try(timeline.kind_of_word),
  )
  use turn_seq <- result.try(whole(fields, "turn_seq"))
  use from_seq <- result.try(whole(fields, "from_seq"))
  use to_seq <- result.try(whole(fields, "to_seq"))
  use last <- result.try(text(fields, "last"))
  use started_at <- result.try(whole(fields, "started_at"))
  use ended_at <- result.try(whole(fields, "ended_at"))

  Ok(counted(
    fields,
    Card(
      kind:,
      turn_seq:,
      from_seq:,
      to_seq:,
      last:,
      started_at:,
      ended_at:,
      steps: 0,
      reads: 0,
      failed: 0,
      files: [],
      files_total: 0,
      command: None,
      spawned: [],
      peers: 0,
      tokens_before: None,
      excerpt: None,
    ),
  ))
}

/// The optional facts of a card. A missing or damaged one is left at its empty
/// value, so a card from a daemon that knows fewer facts still draws.
fn counted(fields: List(#(String, JsonValue)), base: Card) -> Card {
  Card(
    ..base,
    steps: option.unwrap(option.from_result(whole(fields, "steps")), 0),
    reads: option.unwrap(option.from_result(whole(fields, "reads")), 0),
    failed: option.unwrap(option.from_result(whole(fields, "failed")), 0),
    files: list_of(fields, "files", file),
    files_total: option.unwrap(
      option.from_result(whole(fields, "files_total")),
      0,
    ),
    command: option.from_result(
      list.key_find(fields, "command")
      |> result.try(object)
      |> result.try(command),
    ),
    spawned: list.map(strings(fields, "spawned"), session_brief.untrusted),
    peers: option.unwrap(option.from_result(whole(fields, "peers")), 0),
    tokens_before: option.from_result(whole(fields, "tokens_before")),
    excerpt: option.map(
      option.from_result(text(fields, "excerpt")),
      session_brief.untrusted,
    ),
  )
}

/// A list of objects, keeping the items that read.
fn list_of(
  fields: List(#(String, JsonValue)),
  name: String,
  read: fn(List(#(String, JsonValue))) -> Result(item, Nil),
) -> List(item) {
  // A section that is not a list holds nothing.
  case list.key_find(fields, name) {
    Ok(json.Array(raw)) ->
      list.filter_map(raw, fn(value) { object(value) |> result.try(read) })
    Ok(_) | Error(Nil) -> []
  }
}

/// The strings of a list member, skipping any that is not one.
fn strings(fields: List(#(String, JsonValue)), name: String) -> List(String) {
  // A section that is not a list holds nothing.
  case list.key_find(fields, name) {
    Ok(json.Array(raw)) ->
      list.filter_map(raw, fn(value) {
        // Only a string is a word.
        case value {
          json.String(word) -> Ok(word)
          json.Array(_)
          | json.Object(_)
          | json.Int(_)
          | json.Float(_)
          | json.Bool(_)
          | json.Null -> Error(Nil)
        }
      })
    Ok(_) | Error(Nil) -> []
  }
}

/// One file a card names.
fn file(fields: List(#(String, JsonValue))) -> Result(File, Nil) {
  use path <- result.try(text(fields, "path"))
  use added <- result.try(whole(fields, "added"))
  use removed <- result.map(whole(fields, "removed"))
  File(path: session_brief.untrusted(path), added:, removed:)
}

/// A command and its exit status. The status may be negative, as a signal is.
fn command(fields: List(#(String, JsonValue))) -> Result(Command, Nil) {
  use words <- result.try(text(fields, "text"))

  // The status is an integer of either sign.
  case list.key_find(fields, "exit") {
    Ok(json.Int(exit)) -> Ok(Command(session_brief.untrusted(words), exit))
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

/// The fields of an object.
fn object(value: JsonValue) -> Result(List(#(String, JsonValue)), Nil) {
  // Only an object has fields.
  case value {
    json.Object(fields) -> Ok(fields)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(Nil)
  }
}

/// A string field.
fn text(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(String, Nil) {
  // Only a string is text.
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

/// A whole non-negative number: a time, a sequence or a count.
fn whole(fields: List(#(String, JsonValue)), name: String) -> Result(Int, Nil) {
  // A negative number is not a count.
  case list.key_find(fields, name) {
    Ok(json.Int(value)) if value >= 0 -> Ok(value)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

// --- writing ----------------------------------------------------------------

/// One card as the wire carries it. Its strings are marked untrusted.
fn card_json(card: Card) -> JsonValue {
  json.Object(
    list.flatten([
      [
        #("kind", json.String(timeline.kind_word(card.kind))),
        #("turn_seq", json.Int(card.turn_seq)),
        #("from_seq", json.Int(card.from_seq)),
        #("to_seq", json.Int(card.to_seq)),
        #("last", json.String(card.last)),
        #("started_at", json.Int(card.started_at)),
        #("ended_at", json.Int(card.ended_at)),
        #("trust", json.String("untrusted")),
        #("steps", json.Int(card.steps)),
        #("reads", json.Int(card.reads)),
        #("failed", json.Int(card.failed)),
        #("files", json.Array(list.map(card.files, file_json))),
        #("files_total", json.Int(card.files_total)),
        #(
          "spawned",
          json.Array(
            list.map(card.spawned, fn(word) {
              json.String(session_brief.untrusted_text(word))
            }),
          ),
        ),
        #("peers", json.Int(card.peers)),
      ],
      optional("command", option.map(card.command, command_json)),
      optional("tokens_before", option.map(card.tokens_before, json.Int)),
      optional(
        "excerpt",
        option.map(card.excerpt, fn(words) {
          json.String(session_brief.untrusted_text(words))
        }),
      ),
    ]),
  )
}

/// A member that is present only when it has a value.
fn optional(
  name: String,
  value: Option(JsonValue),
) -> List(#(String, JsonValue)) {
  // An absent value leaves the member out.
  case value {
    Some(found) -> [#(name, found)]
    None -> []
  }
}

/// One file as the wire carries it.
fn file_json(file: File) -> JsonValue {
  json.Object([
    #("path", json.String(session_brief.untrusted_text(file.path))),
    #("added", json.Int(file.added)),
    #("removed", json.Int(file.removed)),
  ])
}

/// A command as the wire carries it.
fn command_json(command: Command) -> JsonValue {
  json.Object([
    #("text", json.String(session_brief.untrusted_text(command.text))),
    #("exit", json.Int(command.exit)),
  ])
}
