//// The attention inbox's two durable records, an ask and a find, with their
//// bounds and their one total codec (protocol-change/119).
////
//// An ask is a question a model puts to the owner, with a closed set of
//// answer kinds so a page can draw it with fixed components. A find is
//// something the model saw outside its task. The `ask` and `notice` tools
//// write them, the daemon keeps them as reserved `fact.custom` registers in
//// the session store, and the feed that a later phase adds reads them back.
//// That is a writer in `client`, two tools in `tools` and readers in
//// `session_view` and `web_view`, which share only this package, so the
//// shape lives here.
////
//// ## Why `core`
////
//// `core` holds no `@external` and no process, so the same codec compiles for
//// the JavaScript target the web view's page runs on, and the record the tool
//// validates is the record the page decodes, not a second reading of the
//// JSON. The tools package may not depend on `client`, and a record type that
//// lived in `client` would have forced the tools' seam to speak untyped JSON.
//// `core/glance` and `core/todo_list` are the precedents.
////
//// ## Flow
////
//// `ask_key` → `encode_ask` → `decode_ask` → `retired`
////
//// 1. The host mints an id with `mint_ask_id` and names the cell with
////    `ask_key`.
//// 2. `encode_ask` is the stored payload. Its status is open until an answer
////    arrives and answered after it.
//// 3. A reader scans the prefix, runs `decode_ask` on each cell and drops the
////    ones that come back `Error`, so a damaged cell is left out of every
////    count and listing.
//// 4. `retired` names the settled records a commit removes, by age or by
////    count, and never an open one.
////
//// A find follows the same path through `find_key`, `encode_find` and
//// `decode_find`.
////
//// ## Bounds are the writer's
////
//// `decode_ask` and `decode_find` check shape, not size. A record written by
//// a future build with a longer prompt still reads back, and a reader clips
//// to its own width rather than dropping something a person may need to
//// answer. The bounds live here as constants because the tool's description,
//// the tool's check and the tests must name one number.

import core/corruption.{type CorruptionReport}
import core/ids.{type OpId}
import core/json.{type JsonValue}
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string

/// The reserved prefix an ask's cell lives under.
pub const ask_prefix = "attention/ask/"

/// The reserved prefix a find's cell lives under.
pub const find_prefix = "attention/find/"

/// The most questions one ask may carry.
pub const max_questions = 4

/// The fewest options a `choice`, `multiple` or `checklist` question carries.
pub const min_options = 2

/// The most options a question carries.
pub const max_options = 8

/// The longest a question's prompt may be, in characters.
pub const max_prompt_chars = 300

/// The longest an ask's `why` may be, in characters.
pub const max_why_chars = 200

/// The longest an option's label may be, in characters.
pub const max_label_chars = 60

/// The longest an option's note may be, in characters.
pub const max_note_chars = 140

/// The longest a find's text may be, in characters.
pub const max_find_chars = 300

/// How many asks a session may have open at once.
pub const max_open_asks = 32

/// How many finds a session may have open at once.
pub const max_open_finds = 128

/// How many settled records of one prefix are kept before the oldest go.
pub const max_settled = 200

/// How old a settled record is allowed to get, in milliseconds: seven days.
pub const max_settled_age_ms = 604_800_000

/// What a person gives to answer one question. A closed set, so a page draws
/// each with a fixed component and the model never supplies markup.
pub type Kind {
  /// Yes or no.
  Confirm

  /// One of the options.
  Choice

  /// Between `min` and `max` of the options.
  Multiple(min: Int, max: Int)

  /// Any subset of the items, possibly none.
  Checklist

  /// Text of the stated format.
  Fill(format: Format)
}

/// What a `fill` question expects the text to be. No format names a secret.
pub type Format {
  /// A short line of text. The default.
  ShortText

  /// A paragraph.
  LongText

  /// A file path.
  FilePath

  /// A number, carried as the text the person typed.
  Number

  /// A URL.
  Url
}

/// Whether an option is the one the model suggests.
pub type Emphasis {
  /// The model's suggestion. At most one option of a question has it.
  Recommended

  /// An option with no suggestion attached.
  Plain
}

/// One option of a `choice`, `multiple` or `checklist` question.
pub type Alternative {
  Alternative(
    /// What the person sees and what the answer carries. Unique within its
    /// question.
    label: String,
    /// Says what choosing the option does.
    note: Option(String),
    /// Whether the model recommends it.
    emphasis: Emphasis,
  )
}

/// One question of an ask.
pub type Question {
  Question(
    /// `q1` to `q4`, assigned by position. The model supplies no identifiers.
    key: String,
    /// What is being asked.
    prompt: String,
    /// What the person gives.
    kind: Kind,
    /// The options, empty for `confirm` and `fill`.
    options: List(Alternative),
  )
}

/// Who a record is for.
pub type Routing {
  /// The owner. A find is always for the owner.
  ToOwner

  /// A named strand of the session. Stored as the strand's name, which cannot
  /// be `owner`: a spawned strand's name begins with `sub:` and the primary is
  /// `main`.
  ToStrand(name: String)
}

/// The call that wrote a record, in the driver's own durable coordinates, so
/// a reader can resolve it to a transcript position.
pub type Anchor {
  Anchor(operation: OpId, step_id: String, source_index: Int)
}

/// The fields an ask and a find share.
pub type Header {
  Header(
    /// `ask-` or `find-` and ten lower-case hexadecimal digits. Repeated in
    /// the payload so a scan needs no key parsing.
    id: String,
    /// Unix milliseconds on the call's clock. Never monotonic time, which is
    /// negative on the BEAM.
    created_at: Int,
    /// Who the record is for.
    routing: Routing,
    /// The call that wrote it.
    anchor: Anchor,
    /// The strand that made the call.
    strand: String,
    /// That strand's parents, nearest first. Empty for `main`.
    parents: List(String),
  )
}

/// A person's answer to one question.
pub type Value {
  /// A `confirm` answered yes.
  Yes

  /// A `confirm` answered no.
  No

  /// A `choice`: the label of the option picked.
  Picked(label: String)

  /// A `multiple` or `checklist`: the labels picked.
  PickedMany(labels: List(String))

  /// A `fill`: the text typed.
  Typed(text: String)

  /// Any question, answered by the Other free text instead of an option.
  Other(text: String)
}

/// A recorded answer.
pub type Answer {
  Answer(
    /// One value per question key.
    values: List(#(String, Value)),
    /// Who answered, as the gateway admitted them.
    by: String,
  )
}

/// Where an ask stands. An ask is never closed.
pub type AskState {
  /// Waiting for an answer.
  AskOpen

  /// Answered at `at`, in Unix milliseconds.
  Answered(at: Int, answer: Answer)
}

/// A question, or up to four, put to the owner or to a strand.
pub type Ask {
  Ask(
    header: Header,
    /// Why the model is asking, for the person.
    why: Option(String),
    /// One to four questions.
    questions: List(Question),
    state: AskState,
  )
}

/// What a find is.
pub type FindKind {
  /// A hazard the agent saw.
  Risk

  /// An improvement the agent thought of.
  Idea

  /// A defect outside the agent's task.
  Bug

  /// Something the agent wonders about and will not stop to ask. Spelled
  /// `question` on the wire.
  Wondering
}

/// How a person settled a find.
pub type Closure {
  Fixed
  Filed
  Dismissed
}

/// Where a find stands. Only a person closes one.
pub type FindState {
  /// Not yet dealt with.
  FindOpen

  /// Closed at `at`, in Unix milliseconds, by `by`.
  Closed(at: Int, closure: Closure, by: String)
}

/// Something the agent saw outside its task.
pub type Find {
  Find(
    header: Header,
    kind: FindKind,
    /// What was seen.
    text: String,
    /// A workspace-relative path, if the find is about one.
    path: Option(String),
    /// A line in `path`, at least 1.
    line: Option(Int),
    state: FindState,
  )
}

/// A settled record's identity and age, which is all `retired` needs.
pub type Settled {
  Settled(id: String, at: Int)
}

// --- names -----------------------------------------------------------------

/// The cell an ask lives in.
///
/// ## Examples
///
/// ```gleam
/// assert attention.ask_key("ask-3f9c01a2b4") == "attention/ask/ask-3f9c01a2b4"
/// ```
pub fn ask_key(id: String) -> String {
  ask_prefix <> id
}

/// The cell a find lives in.
///
/// ## Examples
///
/// ```gleam
/// assert attention.find_key("find-3f9c01a2b4")
///   == "attention/find/find-3f9c01a2b4"
/// ```
pub fn find_key(id: String) -> String {
  find_prefix <> id
}

/// The cell that serializes the insertion of records under `prefix`.
///
/// Every insertion reads this cell, counts the open records, and commits the
/// new record together with a replacement of this cell guarded by the seq it
/// read. Two writers that counted the same open records therefore cannot both
/// commit: the second finds the cell moved. Its suffix is not an id, so a scan
/// of the prefix skips it.
///
/// ## Examples
///
/// ```gleam
/// assert attention.guard_key(attention.ask_prefix) == "attention/ask/guard"
/// ```
pub fn guard_key(prefix: String) -> String {
  prefix <> "guard"
}

/// An ask's id from forty bits of entropy: `ask-` and ten lower-case
/// hexadecimal digits.
///
/// ## Examples
///
/// ```gleam
/// assert attention.mint_ask_id(255) == "ask-00000000ff"
/// ```
pub fn mint_ask_id(entropy: Int) -> String {
  "ask-" <> ten_digits(entropy)
}

/// A find's id from forty bits of entropy: `find-` and ten lower-case
/// hexadecimal digits.
///
/// ## Examples
///
/// ```gleam
/// assert attention.mint_find_id(255) == "find-00000000ff"
/// ```
pub fn mint_find_id(entropy: Int) -> String {
  "find-" <> ten_digits(entropy)
}

/// Whether `text` has the shape of an ask id. A wire value is checked with
/// this before it names a cell, so a client cannot address another key.
///
/// ## Examples
///
/// ```gleam
/// assert attention.is_ask_id("ask-0123456789")
/// assert !attention.is_ask_id("ask-../x")
/// ```
pub fn is_ask_id(text: String) -> Bool {
  has_id_shape(text, "ask-")
}

/// Whether `text` has the shape of a find id.
///
/// ## Examples
///
/// ```gleam
/// assert attention.is_find_id("find-0123456789")
/// assert !attention.is_find_id("ask-0123456789")
/// ```
pub fn is_find_id(text: String) -> Bool {
  has_id_shape(text, "find-")
}

/// Forty bits of an entropy value as ten lower-case hexadecimal digits.
fn ten_digits(entropy: Int) -> String {
  int.bitwise_and(entropy, 0xFFFFFFFFFF)
  |> int.to_base16
  |> string.lowercase
  |> string.pad_start(to: 10, with: "0")
}

/// Whether `text` is `prefix` and ten lower-case hexadecimal digits.
fn has_id_shape(text: String, prefix: String) -> Bool {
  case string.split_once(text, prefix) {
    Ok(#("", digits)) ->
      string.drop_start(digits, 9) != ""
      && string.drop_start(digits, 10) == ""
      && list.all(string.to_graphemes(digits), fn(digit) {
        string.contains("0123456789abcdef", digit)
      })
    Ok(_) | Error(Nil) -> False
  }
}

/// A question kind's wire name.
///
/// ## Examples
///
/// ```gleam
/// assert attention.kind_name(attention.Confirm) == "confirm"
/// ```
pub fn kind_name(kind: Kind) -> String {
  case kind {
    Confirm -> "confirm"
    Choice -> "choice"
    Multiple(..) -> "multiple"
    Checklist -> "checklist"
    Fill(..) -> "fill"
  }
}

/// A fill format's wire name.
///
/// ## Examples
///
/// ```gleam
/// assert attention.format_name(attention.ShortText) == "text"
/// ```
pub fn format_name(format: Format) -> String {
  case format {
    ShortText -> "text"
    LongText -> "long_text"
    FilePath -> "path"
    Number -> "number"
    Url -> "url"
  }
}

/// The fill format a wire name denotes.
///
/// ## Examples
///
/// ```gleam
/// assert attention.parse_format("path") == Ok(attention.FilePath)
/// assert attention.parse_format("password") == Error(Nil)
/// ```
pub fn parse_format(name: String) -> Result(Format, Nil) {
  case name {
    "text" -> Ok(ShortText)
    "long_text" -> Ok(LongText)
    "path" -> Ok(FilePath)
    "number" -> Ok(Number)
    "url" -> Ok(Url)
    _ -> Error(Nil)
  }
}

/// A find kind's wire name.
///
/// ## Examples
///
/// ```gleam
/// assert attention.find_kind_name(attention.Wondering) == "question"
/// ```
pub fn find_kind_name(kind: FindKind) -> String {
  case kind {
    Risk -> "risk"
    Idea -> "idea"
    Bug -> "bug"
    Wondering -> "question"
  }
}

/// The find kind a wire name denotes.
///
/// ## Examples
///
/// ```gleam
/// assert attention.parse_find_kind("bug") == Ok(attention.Bug)
/// assert attention.parse_find_kind("praise") == Error(Nil)
/// ```
pub fn parse_find_kind(name: String) -> Result(FindKind, Nil) {
  case name {
    "risk" -> Ok(Risk)
    "idea" -> Ok(Idea)
    "bug" -> Ok(Bug)
    "question" -> Ok(Wondering)
    _ -> Error(Nil)
  }
}

// --- pruning ---------------------------------------------------------------

/// The settled records a commit removes: every one older than
/// `max_settled_age_ms`, and the oldest beyond `max_settled`, whichever is
/// more, oldest first. An open record is not in the input, so it is never
/// named here.
///
/// ## Examples
///
/// ```gleam
/// let old = attention.Settled("ask-0000000001", 0)
/// let fresh = attention.Settled("ask-0000000002", 900_000_000)
/// assert attention.retired([fresh, old], now: 900_000_000)
///   == ["ask-0000000001"]
/// ```
pub fn retired(settled: List(Settled), now now: Int) -> List(String) {
  let oldest_first =
    list.sort(settled, fn(left, right) {
      case int.compare(left.at, right.at) {
        order.Eq -> string.compare(left.id, right.id)
        order.Lt -> order.Lt
        order.Gt -> order.Gt
      }
    })
  let aged =
    list.count(oldest_first, fn(row) { now - row.at >= max_settled_age_ms })
  let excess = int.max(0, list.length(oldest_first) - max_settled)
  oldest_first
  |> list.take(int.max(aged, excess))
  |> list.map(fn(row) { row.id })
}

// --- encoding --------------------------------------------------------------

/// Encodes an ask as the JSON stored in its cell.
///
/// ## Examples
///
/// ```gleam
/// assert attention.decode_ask(attention.encode_ask(ask)) == Ok(ask)
/// ```
pub fn encode_ask(ask: Ask) -> JsonValue {
  let content =
    json.Object([
      #("why", optional_string(ask.why)),
      #("questions", json.Array(list.map(ask.questions, encode_question))),
    ])
  json.Object(
    list.flatten([
      encode_header(ask.header, "ask"),
      [#("status", json.String(ask_status(ask.state)))],
      [#("content", content)],
      ask_settlement(ask.state),
    ]),
  )
}

/// Encodes a find as the JSON stored in its cell.
///
/// ## Examples
///
/// ```gleam
/// assert attention.decode_find(attention.encode_find(find)) == Ok(find)
/// ```
pub fn encode_find(find: Find) -> JsonValue {
  let content =
    json.Object([
      #("find_kind", json.String(find_kind_name(find.kind))),
      #("text", json.String(find.text)),
      #("path", optional_string(find.path)),
      #("line", case find.line {
        Some(line) -> json.Int(line)
        None -> json.Null
      }),
    ])
  json.Object(
    list.flatten([
      encode_header(find.header, "find"),
      [#("status", json.String(find_status(find.state)))],
      [#("content", content)],
      find_settlement(find.state),
    ]),
  )
}

/// The header fields, led by the record's kind.
fn encode_header(header: Header, kind: String) -> List(#(String, JsonValue)) {
  [
    #("id", json.String(header.id)),
    #("kind", json.String(kind)),
    #("created_at", json.Int(header.created_at)),
    #("routing", case header.routing {
      ToOwner -> json.String("owner")
      ToStrand(name:) -> json.String(name)
    }),
    #(
      "anchor",
      json.Object([
        #(
          "operation",
          json.String(ids.op_id_to_string(header.anchor.operation)),
        ),
        #("step_id", json.String(header.anchor.step_id)),
        #("source_index", json.Int(header.anchor.source_index)),
      ]),
    ),
    #("strand", json.String(header.strand)),
    #("parents", json.Array(list.map(header.parents, json.String))),
  ]
}

/// The stored `status` of an ask.
fn ask_status(state: AskState) -> String {
  case state {
    AskOpen -> "open"
    Answered(..) -> "answered"
  }
}

/// The stored `status` of a find.
fn find_status(state: FindState) -> String {
  case state {
    FindOpen -> "open"
    Closed(..) -> "closed"
  }
}

/// The `settled_at` and `answer` fields an answered ask adds.
fn ask_settlement(state: AskState) -> List(#(String, JsonValue)) {
  case state {
    AskOpen -> []
    Answered(at:, answer:) -> [
      #("settled_at", json.Int(at)),
      #("answer", encode_answer(answer)),
    ]
  }
}

/// The `settled_at` and `closure` fields a closed find adds.
fn find_settlement(state: FindState) -> List(#(String, JsonValue)) {
  case state {
    FindOpen -> []
    Closed(at:, closure:, by:) -> [
      #("settled_at", json.Int(at)),
      #(
        "closure",
        json.Object([
          #("how", json.String(closure_name(closure))),
          #("by", json.String(by)),
        ]),
      ),
    ]
  }
}

/// A closure's wire name.
fn closure_name(closure: Closure) -> String {
  case closure {
    Fixed -> "fixed"
    Filed -> "filed"
    Dismissed -> "dismissed"
  }
}

/// `String` or `null`.
fn optional_string(value: Option(String)) -> JsonValue {
  case value {
    Some(text) -> json.String(text)
    None -> json.Null
  }
}

/// Encodes one question.
fn encode_question(question: Question) -> JsonValue {
  json.Object(
    list.flatten([
      [
        #("key", json.String(question.key)),
        #("prompt", json.String(question.prompt)),
        #("kind", json.String(kind_name(question.kind))),
      ],
      kind_parameters(question.kind),
      [#("options", json.Array(list.map(question.options, encode_alternative)))],
    ]),
  )
}

/// The fields only some kinds carry: `min` and `max`, or `format`.
fn kind_parameters(kind: Kind) -> List(#(String, JsonValue)) {
  case kind {
    Multiple(min:, max:) -> [#("min", json.Int(min)), #("max", json.Int(max))]
    Fill(format:) -> [#("format", json.String(format_name(format)))]
    Confirm | Choice | Checklist -> []
  }
}

/// Encodes one option. `recommended` is written as the boolean the tool's
/// schema takes.
fn encode_alternative(choice: Alternative) -> JsonValue {
  json.Object([
    #("label", json.String(choice.label)),
    #("note", optional_string(choice.note)),
    #("recommended", case choice.emphasis {
      Recommended -> json.Bool(True)
      Plain -> json.Bool(False)
    }),
  ])
}

/// Encodes an answer in the shape the model reads: `answers` has a key per
/// question and `null` where Other was used, and `other` carries the text of
/// each Other, with who answered beside them.
fn encode_answer(answer: Answer) -> JsonValue {
  let others =
    list.filter_map(answer.values, fn(entry) {
      case entry.1 {
        Other(text:) -> Ok(#(entry.0, json.String(text)))
        Yes | No | Picked(..) | PickedMany(..) | Typed(..) -> Error(Nil)
      }
    })
  json.Object([
    #(
      "answers",
      json.Object(
        list.map(answer.values, fn(entry) { #(entry.0, encode_value(entry.1)) }),
      ),
    ),
    #("other", json.Object(others)),
    #("by", json.String(answer.by)),
  ])
}

/// One answer value as the model reads it.
fn encode_value(value: Value) -> JsonValue {
  case value {
    Yes -> json.Bool(True)
    No -> json.Bool(False)
    Picked(label:) -> json.String(label)
    PickedMany(labels:) -> json.Array(list.map(labels, json.String))
    Typed(text:) -> json.String(text)
    Other(..) -> json.Null
  }
}

// --- decoding --------------------------------------------------------------

/// Decodes a stored ask. Total: anything `encode_ask` did not produce is a
/// `CorruptionReport` naming the first field that is wrong.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = attention.decode_ask(json.String("not an ask"))
/// ```
pub fn decode_ask(value: JsonValue) -> Result(Ask, CorruptionReport) {
  use header <- result.try(decode_header(value, "ask"))
  use content <- result.try(object_field(value, "content"))
  use why <- result.try(optional_string_field(content, "why"))
  use questions <- result.try(array_field(content, "questions"))
  use questions <- result.try(list.try_map(questions, decode_question))
  use status <- result.try(string_field(value, "status"))
  use state <- result.map(decode_ask_state(value, status, questions))
  Ask(header:, why:, questions:, state:)
}

/// Decodes a stored find. Total, as `decode_ask` is.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = attention.decode_find(json.Null)
/// ```
pub fn decode_find(value: JsonValue) -> Result(Find, CorruptionReport) {
  use header <- result.try(decode_header(value, "find"))
  use content <- result.try(object_field(value, "content"))
  use kind <- result.try(string_field(content, "find_kind"))
  use kind <- result.try(
    parse_find_kind(kind)
    |> result.map_error(fn(_) { corrupt("a known `find_kind`", content) }),
  )
  use text <- result.try(string_field(content, "text"))
  use path <- result.try(optional_string_field(content, "path"))
  use line <- result.try(optional_int_field(content, "line"))
  use status <- result.try(string_field(value, "status"))
  use state <- result.map(decode_find_state(value, status))
  Find(header:, kind:, text:, path:, line:, state:)
}

/// Decodes the shared header and checks the record's `kind` and id prefix.
fn decode_header(
  value: JsonValue,
  kind: String,
) -> Result(Header, CorruptionReport) {
  use found <- result.try(string_field(value, "kind"))
  use <- bool.lazy_guard(when: found != kind, return: fn() {
    Error(corrupt("kind `" <> kind <> "`", value))
  })
  use id <- result.try(string_field(value, "id"))

  // An ask's id and a find's id differ in their prefix, so each kind of
  // record is held to its own shape and a find cannot pass as an ask.
  let shaped = case kind {
    "ask" -> is_ask_id(id)
    _ -> is_find_id(id)
  }

  use <- bool.lazy_guard(when: !shaped, return: fn() {
    Error(corrupt("an id of the " <> kind <> " shape", value))
  })
  use created_at <- result.try(int_field(value, "created_at"))
  use routing <- result.try(string_field(value, "routing"))
  use anchor <- result.try(decode_anchor(value))
  use strand <- result.try(string_field(value, "strand"))
  use parents <- result.try(array_field(value, "parents"))
  use parents <- result.map(list.try_map(parents, as_string(_, "parents")))

  // `owner` is the one routing that names no strand, and no strand can be
  // called `owner`, so every other text is a strand's name.
  let routing = case routing {
    "owner" -> ToOwner
    name -> ToStrand(name)
  }

  Header(id:, created_at:, routing:, anchor:, strand:, parents:)
}

/// Decodes the call coordinates.
fn decode_anchor(value: JsonValue) -> Result(Anchor, CorruptionReport) {
  use anchor <- result.try(object_field(value, "anchor"))
  use operation <- result.try(string_field(anchor, "operation"))
  use operation <- result.try(ids.parse_op_id(operation))
  use step_id <- result.try(string_field(anchor, "step_id"))
  use source_index <- result.map(int_field(anchor, "source_index"))
  Anchor(operation:, step_id:, source_index:)
}

/// Decodes one question, checking that its fields agree with its kind.
fn decode_question(value: JsonValue) -> Result(Question, CorruptionReport) {
  use key <- result.try(string_field(value, "key"))
  use prompt <- result.try(string_field(value, "prompt"))
  use kind <- result.try(decode_kind(value))
  use options <- result.try(array_field(value, "options"))
  use options <- result.map(list.try_map(options, decode_alternative))
  Question(key:, prompt:, kind:, options:)
}

/// Decodes a question's kind and the parameters that go with it.
fn decode_kind(value: JsonValue) -> Result(Kind, CorruptionReport) {
  use name <- result.try(string_field(value, "kind"))

  // The kind's name says which parameters to read: `multiple` its bounds and
  // `fill` its format, and the others none.
  case name {
    "confirm" -> Ok(Confirm)
    "choice" -> Ok(Choice)
    "checklist" -> Ok(Checklist)
    "multiple" -> {
      use min <- result.try(int_field(value, "min"))
      use max <- result.map(int_field(value, "max"))
      Multiple(min:, max:)
    }
    "fill" -> {
      use format <- result.try(string_field(value, "format"))
      parse_format(format)
      |> result.map(Fill)
      |> result.map_error(fn(_) { corrupt("a known fill `format`", value) })
    }
    _ -> Error(corrupt("a known question `kind`", value))
  }
}

/// Decodes one option.
fn decode_alternative(
  value: JsonValue,
) -> Result(Alternative, CorruptionReport) {
  use label <- result.try(string_field(value, "label"))
  use note <- result.try(optional_string_field(value, "note"))

  // The flag is always written, so an absent or non-boolean one is damage
  // rather than a default.
  use marked <- result.try(case field(value, "recommended") {
    Ok(json.Bool(True)) -> Ok(Recommended)
    Ok(json.Bool(False)) -> Ok(Plain)
    Ok(_) | Error(Nil) -> Error(corrupt("a boolean `recommended`", value))
  })

  Ok(Alternative(label:, note:, emphasis: marked))
}

/// Reads `status` and the answer an `answered` ask carries.
fn decode_ask_state(
  value: JsonValue,
  status: String,
  questions: List(Question),
) -> Result(AskState, CorruptionReport) {
  // Only an answered ask carries a settlement; an open one carries none, and
  // an ask is never closed.
  case status {
    "open" -> Ok(AskOpen)
    "answered" -> {
      use at <- result.try(int_field(value, "settled_at"))
      use answer <- result.try(object_field(value, "answer"))
      use answer <- result.map(decode_answer(answer, questions))
      Answered(at:, answer:)
    }
    _ -> Error(corrupt("an ask `status` of open or answered", value))
  }
}

/// Reads `status` and the closure a `closed` find carries.
fn decode_find_state(
  value: JsonValue,
  status: String,
) -> Result(FindState, CorruptionReport) {
  // Only a closed find carries a settlement, and only a person closes one.
  case status {
    "open" -> Ok(FindOpen)
    "closed" -> {
      use at <- result.try(int_field(value, "settled_at"))
      use closure <- result.try(object_field(value, "closure"))
      use how <- result.try(string_field(closure, "how"))
      use by <- result.try(string_field(closure, "by"))
      use how <- result.map(
        parse_closure(how)
        |> result.map_error(fn(_) { corrupt("a known closure", closure) }),
      )
      Closed(at:, closure: how, by:)
    }
    _ -> Error(corrupt("a find `status` of open or closed", value))
  }
}

/// The closure a wire name denotes.
fn parse_closure(name: String) -> Result(Closure, Nil) {
  case name {
    "fixed" -> Ok(Fixed)
    "filed" -> Ok(Filed)
    "dismissed" -> Ok(Dismissed)
    _ -> Error(Nil)
  }
}

/// Reads an answer back against the questions it answers. A key outside the
/// ask is corruption, since the host validated the submission before storing
/// it. The question's kind is what tells a `choice`'s label from a `fill`'s
/// text, which are both strings on the wire.
fn decode_answer(
  value: JsonValue,
  questions: List(Question),
) -> Result(Answer, CorruptionReport) {
  use answers <- result.try(fields_field(value, "answers"))
  use other <- result.try(object_field(value, "other"))
  use by <- result.try(string_field(value, "by"))
  use values <- result.map(
    list.try_map(answers, fn(entry) {
      use question <- result.try(
        list.find(questions, fn(question) { question.key == entry.0 })
        |> result.map_error(fn(_) {
          corrupt("an answer to a question of the ask", value)
        }),
      )
      use value <- result.map(decode_value(entry.1, question, other))
      #(entry.0, value)
    }),
  )
  Answer(values:, by:)
}

/// Reads one answer value. `null` is Other, whose text sits beside it.
fn decode_value(
  value: JsonValue,
  question: Question,
  other: JsonValue,
) -> Result(Value, CorruptionReport) {
  case value, question.kind {
    json.Null, _ -> string_field(other, question.key) |> result.map(Other)
    json.Bool(True), Confirm -> Ok(Yes)
    json.Bool(False), Confirm -> Ok(No)
    json.String(label), Choice -> Ok(Picked(label))
    json.String(text), Fill(..) -> Ok(Typed(text))
    json.Array(items), Multiple(..) | json.Array(items), Checklist ->
      list.try_map(items, as_string(_, "answers"))
      |> result.map(PickedMany)
    _, _ -> Error(corrupt("an answer value of the question's kind", value))
  }
}

// --- field access ----------------------------------------------------------

/// A string element of an array.
fn as_string(
  value: JsonValue,
  key: String,
) -> Result(String, CorruptionReport) {
  case value {
    json.String(text) -> Ok(text)
    json.Object(_)
    | json.Array(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(corrupt("strings in `" <> key <> "`", value))
  }
}

/// A required string field.
fn string_field(
  value: JsonValue,
  key: String,
) -> Result(String, CorruptionReport) {
  case field(value, key) {
    Ok(json.String(text)) -> Ok(text)
    Ok(_) | Error(Nil) ->
      Error(corrupt("a string `" <> key <> "` field", value))
  }
}

/// A string field that may be `null` or absent.
fn optional_string_field(
  value: JsonValue,
  key: String,
) -> Result(Option(String), CorruptionReport) {
  case field(value, key) {
    Ok(json.String(text)) -> Ok(Some(text))
    Ok(json.Null) | Error(Nil) -> Ok(None)
    Ok(_) -> Error(corrupt("a string or null `" <> key <> "` field", value))
  }
}

/// A required integer field.
fn int_field(value: JsonValue, key: String) -> Result(Int, CorruptionReport) {
  case field(value, key) {
    Ok(json.Int(number)) -> Ok(number)
    Ok(_) | Error(Nil) ->
      Error(corrupt("an integer `" <> key <> "` field", value))
  }
}

/// An integer field that may be `null` or absent.
fn optional_int_field(
  value: JsonValue,
  key: String,
) -> Result(Option(Int), CorruptionReport) {
  case field(value, key) {
    Ok(json.Int(number)) -> Ok(Some(number))
    Ok(json.Null) | Error(Nil) -> Ok(None)
    Ok(_) -> Error(corrupt("an integer or null `" <> key <> "` field", value))
  }
}

/// A required array field.
fn array_field(
  value: JsonValue,
  key: String,
) -> Result(List(JsonValue), CorruptionReport) {
  case field(value, key) {
    Ok(json.Array(items)) -> Ok(items)
    Ok(_) | Error(Nil) ->
      Error(corrupt("an array `" <> key <> "` field", value))
  }
}

/// A required object field, as the list of its fields.
fn fields_field(
  value: JsonValue,
  key: String,
) -> Result(List(#(String, JsonValue)), CorruptionReport) {
  case field(value, key) {
    Ok(json.Object(fields)) -> Ok(fields)
    Ok(_) | Error(Nil) ->
      Error(corrupt("an object `" <> key <> "` field", value))
  }
}

/// A required object field.
fn object_field(
  value: JsonValue,
  key: String,
) -> Result(JsonValue, CorruptionReport) {
  case field(value, key) {
    Ok(json.Object(fields)) -> Ok(json.Object(fields))
    Ok(_) | Error(Nil) ->
      Error(corrupt("an object `" <> key <> "` field", value))
  }
}

/// Builds a corruption report when an expected field is missing or ill-typed.
fn corrupt(expected: String, seen: JsonValue) -> CorruptionReport {
  corruption.report(
    at: "core/attention",
    on: "attention record",
    expected:,
    context: json.to_string(seen),
  )
}

/// Looks up a field in a JSON object by key. The first occurrence wins,
/// matching `core/json`'s tiebreak for hand-built objects.
fn field(value: JsonValue, key: String) -> Result(JsonValue, Nil) {
  case value {
    json.Object(fields) -> list.key_find(fields, key)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(Nil)
  }
}
