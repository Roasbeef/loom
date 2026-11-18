//// The `ask` and `notice` tools: a model's two doors into the attention
//// inbox (protocol-change/119).
////
//// ## Flow
////
//// `tools` → `run_ask` → `ask_request` → seam → `ask_outcome`
////
//// 1. `tools` builds both definitions over the host's `Attention` seam.
//// 2. `run_ask` decodes the arguments with `ask_request`, which refuses
////    anything a person could not be shown: a question count, an option
////    count, a label or prompt past its bound, a duplicate label, an
////    unknown field.
//// 3. The seam records the ask and answers its id, or a `Refusal`.
//// 4. `ask_outcome` replies `asked as <id>` and ends the run. A refusal is an
////    ordinary in-band failure that continues it.
////
//// The notice tool takes the same path through `run_notice`, `notice_request`
//// and `notice_outcome`, and never ends the run.
////
//// ## Two tools, two different promises
////
//// An `ask` records a question and stops the model, because the answer is a
//// person's and can take hours. A call held open that long would keep a tool
//// effect process and the call's budget deadline alive, so the tool returns at
//// once and `TerminateRun` ends the run. The planner ends a run only if every
//// call in the batch terminates, and `Exclusive` only keeps the scheduler from
//// starting another call beside this one, so the reply also tells the model
//// to end its turn, which stops a mixed batch too.
////
//// A `notice` is a note the model leaves while it works. It never waits and
//// never ends anything. It is `Concurrent`, so two in one batch may run
//// together, which is why the host checks the open-finds bound inside the
//// commit that writes the record rather than before it.
////
//// ## A seam of closures
////
//// `tools` cannot reach a session, so the durable side is a closure the host
//// fills in (`client/attention`). The same closures are handed to the
//// code-mode door, so a program's `attention.ask` goes through one
//// implementation of the bound checks and the record writes. The checks that
//// depend on the arguments alone are made here, from constants in
//// `core/attention`, so the description and the check cannot disagree.
////
//// ## No secrets
////
//// The tool cannot tell whether a prompt's words ask for a secret, and does
//// not claim to. It tells the model, in its description, that an ask must
//// never request one and that credentials go through grants and approvals.
//// No `fill` format names a password, and the page draws none.

import broker/policy.{type SandboxPolicy}
import core/attention.{
  type Alternative, type Kind, type Question, Alternative, Plain, Question,
  Recommended,
}
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import tools/agent.{type Caller}
import tools/tool.{type Tool, type ToolOutcome}

/// The `ask` tool's name.
pub const ask_name = "ask"

/// The `notice` tool's name.
pub const notice_name = "notice"

/// What the model asked: to whom, why, and up to four questions with their
/// keys already assigned by position.
///
/// Constructor invariants: `questions` holds one to `attention.max_questions`
/// entries keyed `q1`, `q2` and so on in order; each question's options,
/// bounds and format agree with its kind; `why` is at most
/// `attention.max_why_chars` characters; `to` is a non-empty strand name.
pub type AskRequest {
  AskRequest(
    /// A strand of this session, or `None` for the owner.
    to: Option(String),
    /// Why the model is asking, for the person.
    why: Option(String),
    /// The questions, keyed by position.
    questions: List(Question),
  )
}

/// What the model noticed.
///
/// Constructor invariants: `text` is non-empty and at most
/// `attention.max_find_chars` characters; `path` is workspace-relative, with
/// no `..` segment; `line` is at least 1 and present only with `path`.
pub type NoticeRequest {
  NoticeRequest(
    /// What kind of find this is.
    kind: attention.FindKind,
    /// What was seen.
    text: String,
    /// A workspace-relative path the find is about.
    path: Option(String),
    /// A line in `path`.
    line: Option(Int),
  )
}

/// Why the host did not record a request.
pub type Refusal {
  /// The host would not accept the request as it stands.
  Invalid(reason: String)

  /// `to` names no strand of this session.
  NoSuchStrand(name: String)

  /// The session already has `limit` open records of this kind.
  Full(records: String, limit: Int)

  /// The store could not be read or written.
  Unavailable(reason: String)
}

/// The host's side of both tools.
///
/// Constructor invariants: each closure is total, returning a `Refusal`
/// rather than crashing. On success it has durably recorded one record
/// and returns its id, and has written nothing else. Neither blocks on a
/// person. The caller is the driver's own identity, never the model's.
pub type Attention {
  Attention(
    /// Records an ask and returns its id.
    ask: fn(Caller, AskRequest) -> Result(String, Refusal),
    /// Records a find and returns its id.
    notice: fn(Caller, NoticeRequest) -> Result(String, Refusal),
  )
}

/// Both tools over one seam, `ask` first.
///
/// ## Examples
///
/// ```gleam
/// // tool.registry(attention.tools(seam))
/// ```
pub fn tools(seam: Attention) -> List(Tool) {
  [ask_tool(seam.ask), notice_tool(seam.notice)]
}

// --- ask -------------------------------------------------------------------

/// The `ask` tool over one recording closure.
fn ask_tool(ask: fn(Caller, AskRequest) -> Result(String, Refusal)) -> Tool {
  tool.Tool(
    name: ask_name,
    description: ask_description(),
    prompt_snippet: Some(
      "`ask` puts up to four questions with options to the owner and ends "
      <> "your turn; the answer comes back as a message.",
    ),
    schema: tool.object_schema(
      [
        #("questions", questions_property()),
        #(
          "to",
          tool.string_property(
            "a strand of this session to ask instead of the owner; leave it "
            <> "out to ask the owner",
          ),
        ),
        #(
          "why",
          tool.string_property(
            "why you are asking, for the person, at most "
            <> int.to_string(attention.max_why_chars)
            <> " characters",
          ),
        ),
      ],
      ["questions"],
    ),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_ask(ask, ctx, args) },
  )
}

/// The model-facing description of `ask`.
fn ask_description() -> String {
  "Put up to "
  <> int.to_string(attention.max_questions)
  <> " questions to the owner and wait for the answer, when a decision "
  <> "belongs to them. Each question has a `kind`: `confirm` (yes or no), "
  <> "`choice` (one option), `multiple` (between `min` and `max` options), "
  <> "`checklist` (any subset) or `fill` (text, with a `format` of `text`, "
  <> "`long_text`, `path`, `number` or `url`). Give "
  <> int.to_string(attention.min_options)
  <> " to "
  <> int.to_string(attention.max_options)
  <> " options for the first three, with a short `note` saying what each "
  <> "does and `recommended` on the one you suggest. Every question also "
  <> "accepts a free-text Other, so do not add an option for it. An ask must "
  <> "never request a secret: credentials, tokens and keys go through "
  <> "grants and approvals, not through a question. The call records the "
  <> "ask and returns at once, and your turn ends: after asking, say "
  <> "nothing more and do no further work on what the answer decides. The "
  <> "answer arrives later as a message from the person holding one fenced "
  <> "JSON object, with the ask's id, an `answers` value for each question "
  <> "(`null` where they used Other) and an `other` object holding the "
  <> "text of each Other. At most "
  <> int.to_string(attention.max_open_asks)
  <> " asks may be open at once."
}

/// The schema of the `questions` argument, spelling out every field so a
/// provider that validates tool arguments accepts the nested shape.
fn questions_property() -> JsonValue {
  json.Object([
    #("type", json.String("array")),
    #("minItems", json.Int(1)),
    #("maxItems", json.Int(attention.max_questions)),
    #("items", question_schema()),
    #(
      "description",
      json.String(
        "one to "
        <> int.to_string(attention.max_questions)
        <> " questions, answered together",
      ),
    ),
  ])
}

/// The schema of one question.
fn question_schema() -> JsonValue {
  json.Object([
    #("type", json.String("object")),
    #(
      "properties",
      json.Object([
        #(
          "prompt",
          tool.string_property(
            "the question, at most "
            <> int.to_string(attention.max_prompt_chars)
            <> " characters",
          ),
        ),
        #(
          "kind",
          tool.enum_property(
            ["confirm", "choice", "multiple", "checklist", "fill"],
            "what the person gives",
          ),
        ),
        #("options", options_property()),
        #(
          "min",
          tool.integer_property(
            "multiple only: the fewest options to pick; default 1",
          ),
        ),
        #(
          "max",
          tool.integer_property(
            "multiple only: the most options to pick; default all of them",
          ),
        ),
        #(
          "format",
          tool.enum_property(
            ["text", "long_text", "path", "number", "url"],
            "fill only: what the text is; default `text`",
          ),
        ),
      ]),
    ),
    #("required", json.Array([json.String("prompt"), json.String("kind")])),
    #("additionalProperties", json.Bool(False)),
  ])
}

/// The schema of a question's `options`.
fn options_property() -> JsonValue {
  json.Object([
    #("type", json.String("array")),
    #("minItems", json.Int(attention.min_options)),
    #("maxItems", json.Int(attention.max_options)),
    #(
      "items",
      json.Object([
        #("type", json.String("object")),
        #(
          "properties",
          json.Object([
            #(
              "label",
              tool.string_property(
                "what the person sees and the answer carries, at most "
                <> int.to_string(attention.max_label_chars)
                <> " characters, unique within the question",
              ),
            ),
            #(
              "note",
              tool.string_property(
                "what choosing it does, at most "
                <> int.to_string(attention.max_note_chars)
                <> " characters",
              ),
            ),
            #(
              "recommended",
              tool.boolean_property(
                "true on the option you suggest; at most one per question",
              ),
            ),
          ]),
        ),
        #("required", json.Array([json.String("label")])),
        #("additionalProperties", json.Bool(False)),
      ]),
    ),
    #(
      "description",
      json.String(
        "required for choice, multiple and checklist; not allowed for "
        <> "confirm or fill",
      ),
    ),
  ])
}

/// Runs one `ask` call: decode, record, and end the run on success.
fn run_ask(
  ask: fn(Caller, AskRequest) -> Result(String, Refusal),
  ctx: tool.Ctx,
  args: JsonValue,
) -> ToolOutcome {
  use request <- tool.with_arg(ask_request(args))
  use id <- tool.or_outcome(ask(agent.caller(ctx), request), refusal_outcome)
  ask_outcome(id)
}

/// The outcome of a recorded ask: its id, and the end of the run.
///
/// `TerminateRun` is what makes the strand idle with an open ask. The planner
/// ends a run only if every call in the batch terminates, so the text also
/// says to end the turn, for a batch that held another call.
///
/// ## Examples
///
/// ```gleam
/// assert attention.ask_outcome("ask-0123456789").terminate == tool.TerminateRun
/// ```
pub fn ask_outcome(id: String) -> ToolOutcome {
  let recorded =
    tool.success(
      "asked as "
      <> id
      <> ". End your turn now; the answer arrives later as a message from the person.",
    )
    |> tool.with_details(json.Object([#("id", json.String(id))]))
  tool.ToolOutcome(..recorded, terminate: tool.TerminateRun)
}

/// Decodes and bounds the arguments of an `ask`, with the reason a bad one is
/// refused. The code-mode door calls this too, so a program's call and a
/// model's call are held to the same words.
///
/// ## Examples
///
/// ```gleam
/// assert attention.ask_request(json.Object([])) == Error("`questions` is required")
/// ```
pub fn ask_request(args: JsonValue) -> Result(AskRequest, String) {
  use to <- result.try(strand_name(args))
  use why <- result.try(bounded_optional(args, "why", attention.max_why_chars))
  use held <- result.try(
    tool.optional_value(args, "questions")
    |> result.try(option.to_result(_, "`questions` is required")),
  )

  // The argument has to be an array before its length means anything.
  use items <- result.try(case held {
    json.Array(items) -> Ok(items)
    json.Object(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("`questions` must be an array")
  })

  use <- bool.guard(
    when: items == [],
    return: Error("`questions` needs at least one question"),
  )
  use <- bool.lazy_guard(
    when: list.length(items) > attention.max_questions,
    return: fn() {
      Error(
        "`questions` holds at most "
        <> int.to_string(attention.max_questions)
        <> " questions; put the rest in a later ask",
      )
    },
  )
  use questions <- result.map(
    list.index_map(items, fn(item, index) { question(item, index + 1) })
    |> result.all,
  )
  AskRequest(to:, why:, questions:)
}

/// The `to` argument: absent for the owner, else a non-empty strand name.
fn strand_name(args: JsonValue) -> Result(Option(String), String) {
  use named <- result.try(tool.optional_string(args, "to"))

  // A name that is only spaces is a mistake, not the owner: the owner is
  // asked by leaving `to` out, so a blank one is refused rather than guessed.
  case named {
    None -> Ok(None)
    Some(name) ->
      case string.trim(name) {
        "" -> Error("`to` is empty; leave it out to ask the owner")
        trimmed -> Ok(Some(trimmed))
      }
  }
}

/// An optional string argument, at most `limit` characters. An empty one is
/// the same as an absent one.
fn bounded_optional(
  args: JsonValue,
  key: String,
  limit: Int,
) -> Result(Option(String), String) {
  use found <- result.try(tool.optional_string(args, key))

  // A blank string says nothing, so it is the same as leaving the argument
  // out; anything else is held to the bound.
  case found {
    None -> Ok(None)
    Some(text) ->
      case string.trim(text) {
        "" -> Ok(None)
        _ ->
          bound(text, key, limit)
          |> result.map(Some)
      }
  }
}

/// `text` when it is at most `limit` characters, else the refusal.
fn bound(text: String, what: String, limit: Int) -> Result(String, String) {
  case string.length(text) > limit {
    True ->
      Error(
        "`"
        <> what
        <> "` is longer than "
        <> int.to_string(limit)
        <> " characters",
      )
    False -> Ok(text)
  }
}

/// Decodes question number `number`, naming it in every refusal so the model
/// knows which of several to fix.
fn question(item: JsonValue, number: Int) -> Result(Question, String) {
  let name = "question " <> int.to_string(number)
  use fields <- result.try(object_fields(item, name))
  use Nil <- result.try(known_fields(
    fields,
    ["prompt", "kind", "options", "min", "max", "format"],
    name,
  ))
  use prompt <- result.try(required_text(
    fields,
    "prompt",
    attention.max_prompt_chars,
    name,
  ))
  use kind_name <- result.try(required_text(fields, "kind", 20, name))
  use options <- result.try(alternatives(fields, name))
  use kind <- result.try(kind_of(kind_name, fields, options, name))
  Ok(Question(key: "q" <> int.to_string(number), prompt:, kind:, options:))
}

/// Builds a question's kind from its name, checking that the options and
/// parameters present are the ones that kind takes and no others.
fn kind_of(
  kind: String,
  fields: List(#(String, JsonValue)),
  options: List(Alternative),
  name: String,
) -> Result(Kind, String) {
  use Nil <- result.try(allowed_parameters(kind, fields, name))

  // The kind decides which options and parameters are required, optional or
  // refused, and a kind outside the closed set is refused with the list.
  case kind {
    "confirm" ->
      no_options(options, kind, name) |> result.replace(attention.Confirm)
    "choice" -> counted(options, kind, name) |> result.replace(attention.Choice)
    "checklist" ->
      counted(options, kind, name) |> result.replace(attention.Checklist)
    "multiple" -> {
      use Nil <- result.try(counted(options, kind, name))
      use min <- result.try(integer(fields, "min", 1, name))
      use max <- result.try(integer(fields, "max", list.length(options), name))
      use <- bool.lazy_guard(
        when: min < 0 || min > max || max < 1 || max > list.length(options),
        return: fn() {
          Error(
            name
            <> ": `multiple` needs 0 <= min <= max, 1 <= max <= the number of options ("
            <> int.to_string(list.length(options))
            <> "), got min "
            <> int.to_string(min)
            <> " and max "
            <> int.to_string(max),
          )
        },
      )
      Ok(attention.Multiple(min:, max:))
    }
    "fill" -> {
      use Nil <- result.try(no_options(options, kind, name))
      use format <- result.try(format_of(fields, name))
      Ok(attention.Fill(format:))
    }
    _ ->
      Error(
        name
        <> ": `kind` is `confirm`, `choice`, `multiple`, `checklist` or `fill`",
      )
  }
}

/// Which of `min`, `max` and `format` a kind accepts. A parameter given to a
/// kind that has no use for it is a mistake the model should hear about.
fn allowed_parameters(
  kind: String,
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(Nil, String) {
  let stray =
    list.filter(["min", "max", "format"], fn(key) {
      list.key_find(fields, key) |> result.is_ok
      && !parameter_allowed(kind, key)
    })

  // The first stray parameter is named, which is enough for the model to fix
  // the call and hear about any other on the next one.
  case stray {
    [] -> Ok(Nil)
    [key, ..] ->
      Error(
        name
        <> ": `"
        <> key
        <> "` does not apply to a `"
        <> kind
        <> "` question",
      )
  }
}

/// Whether a kind takes the parameter.
fn parameter_allowed(kind: String, key: String) -> Bool {
  case kind, key {
    "multiple", "min" | "multiple", "max" | "fill", "format" -> True
    _, _ -> False
  }
}

/// Refuses options on a kind that has none.
fn no_options(
  options: List(Alternative),
  kind: String,
  name: String,
) -> Result(Nil, String) {
  case options {
    [] -> Ok(Nil)
    [_, ..] -> Error(name <> ": a `" <> kind <> "` question takes no `options`")
  }
}

/// Refuses an option count outside two to eight.
fn counted(
  options: List(Alternative),
  kind: String,
  name: String,
) -> Result(Nil, String) {
  let count = list.length(options)

  // Two to eight options, so a person has a real choice and the page has room.
  case count < attention.min_options || count > attention.max_options {
    True ->
      Error(
        name
        <> ": a `"
        <> kind
        <> "` question needs "
        <> int.to_string(attention.min_options)
        <> " to "
        <> int.to_string(attention.max_options)
        <> " `options`, got "
        <> int.to_string(count),
      )
    False -> Ok(Nil)
  }
}

/// The fill format, defaulting to `text`.
fn format_of(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(attention.Format, String) {
  case list.key_find(fields, "format") {
    Error(Nil) | Ok(json.Null) -> Ok(attention.ShortText)
    Ok(json.String(text)) ->
      attention.parse_format(text)
      |> result.map_error(fn(_) {
        name <> ": `format` is `text`, `long_text`, `path`, `number` or `url`"
      })
    Ok(_) -> Error(name <> ": `format` must be a string")
  }
}

/// An integer parameter with a default.
fn integer(
  fields: List(#(String, JsonValue)),
  key: String,
  default: Int,
  name: String,
) -> Result(Int, String) {
  case list.key_find(fields, key) {
    Error(Nil) | Ok(json.Null) -> Ok(default)
    Ok(json.Int(number)) -> Ok(number)
    Ok(_) -> Error(name <> ": `" <> key <> "` must be an integer")
  }
}

/// A question's options, empty when it gave none. Labels must be unique and at
/// most one may be recommended.
fn alternatives(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(List(Alternative), String) {
  // Options are optional here and required by the kind, which `kind_of`
  // checks, so an absent list is the empty one.
  case list.key_find(fields, "options") {
    Error(Nil) | Ok(json.Null) -> Ok([])
    Ok(json.Array(items)) -> {
      use options <- result.try(
        list.index_map(items, fn(item, index) {
          alternative(item, name <> ", option " <> int.to_string(index + 1))
        })
        |> result.all,
      )
      use Nil <- result.try(distinct_labels(options, name))
      use Nil <- result.map(one_recommendation(options, name))
      options
    }
    Ok(_) -> Error(name <> ": `options` must be an array")
  }
}

/// Decodes one option.
fn alternative(item: JsonValue, name: String) -> Result(Alternative, String) {
  use fields <- result.try(object_fields(item, name))
  use Nil <- result.try(known_fields(
    fields,
    ["label", "note", "recommended"],
    name,
  ))
  use label <- result.try(required_text(
    fields,
    "label",
    attention.max_label_chars,
    name,
  ))

  // The note is optional, bounded text.
  use note <- result.try(case list.key_find(fields, "note") {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.String(text)) ->
      bound(text, "note", attention.max_note_chars)
      |> result.map(Some)
      |> result.map_error(fn(reason) { name <> ": " <> reason })
    Ok(_) -> Error(name <> ": `note` must be a string")
  })

  // Only an explicit true recommends an option; false and absent are the same.
  use emphasis <- result.map(case list.key_find(fields, "recommended") {
    Error(Nil) | Ok(json.Null) | Ok(json.Bool(False)) -> Ok(Plain)
    Ok(json.Bool(True)) -> Ok(Recommended)
    Ok(_) -> Error(name <> ": `recommended` must be a boolean")
  })

  Alternative(label:, note:, emphasis:)
}

/// Refuses two options with one label, since the answer carries the label.
fn distinct_labels(
  options: List(Alternative),
  name: String,
) -> Result(Nil, String) {
  let labels = list.map(options, fn(choice) { choice.label })

  // A repeated label would make an answer ambiguous, since it carries the label.
  case set.size(set.from_list(labels)) == list.length(labels) {
    True -> Ok(Nil)
    False -> Error(name <> ": two options share a label; labels must be unique")
  }
}

/// Refuses a question with more than one recommended option.
fn one_recommendation(
  options: List(Alternative),
  name: String,
) -> Result(Nil, String) {
  let marked =
    list.count(options, fn(choice) { choice.emphasis == Recommended })

  // A page highlights one suggestion, so two are refused rather than ranked.
  case marked > 1 {
    True -> Error(name <> ": at most one option may be `recommended`")
    False -> Ok(Nil)
  }
}

/// The fields of a JSON object, or the refusal naming what was not one.
fn object_fields(
  item: JsonValue,
  name: String,
) -> Result(List(#(String, JsonValue)), String) {
  case item {
    json.Object(fields) -> Ok(fields)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(name <> " must be an object")
  }
}

/// Refuses a field outside `allowed`. The schema declares no identifier and no
/// markup field, so a model that sends one hears that it was not taken.
fn known_fields(
  fields: List(#(String, JsonValue)),
  allowed: List(String),
  name: String,
) -> Result(Nil, String) {
  case list.find(fields, fn(entry) { !list.contains(allowed, entry.0) }) {
    Error(Nil) -> Ok(Nil)
    Ok(#(key, _)) ->
      Error(
        name <> ": unknown field `" <> key <> "`; there is no such argument",
      )
  }
}

/// A required, non-blank string field of at most `limit` characters.
fn required_text(
  fields: List(#(String, JsonValue)),
  key: String,
  limit: Int,
  name: String,
) -> Result(String, String) {
  case list.key_find(fields, key) {
    Ok(json.String(text)) ->
      case string.trim(text) {
        "" -> Error(name <> ": `" <> key <> "` is empty")
        _ ->
          bound(text, key, limit)
          |> result.map_error(fn(reason) { name <> ": " <> reason })
      }
    Ok(_) -> Error(name <> ": `" <> key <> "` must be a string")
    Error(Nil) -> Error(name <> ": `" <> key <> "` is required")
  }
}

// --- notice ----------------------------------------------------------------

/// The `notice` tool over one recording closure.
fn notice_tool(
  notice: fn(Caller, NoticeRequest) -> Result(String, Refusal),
) -> Tool {
  tool.Tool(
    name: notice_name,
    description: "Leave a note for the owner about something you saw outside "
      <> "your task, and carry on: it never stops your work and the owner "
      <> "reads it later. `kind` is `risk` (a hazard), `idea` (an "
      <> "improvement), `bug` (a defect that is not yours to fix now) or "
      <> "`question` (something you wonder about and will not stop to ask). "
      <> "`text` is at most "
      <> int.to_string(attention.max_find_chars)
      <> " characters. Give `path`, relative to the workspace, and `line` "
      <> "when the note is about one place in the code. You cannot edit or "
      <> "close a note; the owner does. A question you need answered before "
      <> "you can continue is an `ask`, not a notice. Never put a secret in "
      <> "one. At most "
      <> int.to_string(attention.max_open_finds)
      <> " notices may be open at once.",
    prompt_snippet: Some(
      "`notice` leaves the owner a note about a risk, idea or bug you saw "
      <> "outside your task, and does not stop your work.",
    ),
    schema: tool.object_schema(
      [
        #(
          "kind",
          tool.enum_property(
            ["risk", "idea", "bug", "question"],
            "what sort of note this is",
          ),
        ),
        #(
          "text",
          tool.string_property(
            "what you saw, at most "
            <> int.to_string(attention.max_find_chars)
            <> " characters",
          ),
        ),
        #(
          "path",
          tool.string_property("a path relative to the workspace, with no `..`"),
        ),
        #("line", tool.integer_property("a line in `path`, from 1")),
      ],
      ["kind", "text"],
    ),
    replay: tool.Never,
    execution_mode: tool.Concurrent,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_notice(notice, ctx, args) },
  )
}

/// Runs one `notice` call: decode, record, and carry on.
fn run_notice(
  notice: fn(Caller, NoticeRequest) -> Result(String, Refusal),
  ctx: tool.Ctx,
  args: JsonValue,
) -> ToolOutcome {
  use request <- tool.with_arg(notice_request(args))
  use id <- tool.or_outcome(notice(agent.caller(ctx), request), refusal_outcome)
  notice_outcome(id)
}

/// The outcome of a recorded find: its id, and the run carries on.
///
/// ## Examples
///
/// ```gleam
/// assert attention.notice_outcome("find-0123456789").terminate
///   == tool.ContinueRun
/// ```
pub fn notice_outcome(id: String) -> ToolOutcome {
  tool.success("noted as " <> id)
  |> tool.with_details(json.Object([#("id", json.String(id))]))
}

/// Decodes and bounds the arguments of a `notice`, with the reason a bad one
/// is refused.
///
/// ## Examples
///
/// ```gleam
/// assert attention.notice_request(json.Object([])) == Error("`kind` is required")
/// ```
pub fn notice_request(args: JsonValue) -> Result(NoticeRequest, String) {
  use kind <- result.try(tool.required_string(args, "kind"))
  use kind <- result.try(
    attention.parse_find_kind(kind)
    |> result.map_error(fn(_) {
      "`kind` is `risk`, `idea`, `bug` or `question`"
    }),
  )
  use text <- result.try(tool.required_string(args, "text"))
  use <- bool.guard(string.trim(text) == "", Error("`text` is empty"))
  use text <- result.try(bound(text, "text", attention.max_find_chars))
  use path <- result.try(tool.optional_string(args, "path"))
  use line <- result.try(tool.optional_int(args, "line"))

  // A path is checked only when one is given.
  use path <- result.try(case path {
    None -> Ok(None)
    Some(found) -> relative_path(found) |> result.map(Some)
  })

  // A line locates a place in a file, so it needs the file and starts at one.
  use Nil <- result.try(case path, line {
    None, Some(_) -> Error("`line` needs a `path`")
    _, Some(number) if number < 1 -> Error("`line` is at least 1")
    _, _ -> Ok(Nil)
  })

  Ok(NoticeRequest(kind:, text:, path:, line:))
}

/// The most bytes a `path` may carry. A path is a locator, and the record is
/// shown to a person, so this is far above any real workspace path.
const max_path_bytes = 512

/// A workspace-relative path: non-empty, at most `max_path_bytes`, not
/// absolute, no `..` segment. The check is on the trimmed text, so a leading
/// space cannot hide a leading slash, and the trimmed text is what is kept.
fn relative_path(given: String) -> Result(String, String) {
  let path = string.trim(given)
  let segments = string.split(path, on: "/")
  let oversize = byte_size(path) > max_path_bytes

  // Empty, absolute and parent-escaping paths are refused, each with its own
  // words, because each is a different mistake.
  case path, string.starts_with(path, "/"), list.contains(segments, "..") {
    "", _, _ -> Error("`path` is empty")
    _, _, _ if oversize -> Error("`path` is longer than 512 bytes")
    _, True, _ ->
      Error("`path` must be relative to the workspace, not absolute")
    _, _, True -> Error("`path` must not contain `..`")
    _, False, False -> Ok(path)
  }
}

fn byte_size(text: String) -> Int {
  bit_array.byte_size(<<text:utf8>>)
}

// --- refusals --------------------------------------------------------------

/// Renders a seam refusal as the in-band failure the model reads.
///
/// ## Examples
///
/// ```gleam
/// assert attention.refusal_outcome(attention.Full("asks", 32)).is_error
/// ```
pub fn refusal_outcome(refusal: Refusal) -> ToolOutcome {
  tool.failure(describe(refusal))
  |> tool.with_details(
    json.Object([
      #("error", json.String(refusal_code(refusal))),
      #("reason", json.String(describe(refusal))),
    ]),
  )
}

/// The stable machine code of a refusal, which the code-mode door carries as
/// its capability error code.
///
/// ## Examples
///
/// ```gleam
/// assert attention.refusal_code(attention.Full("asks", 32)) == "attention_full"
/// ```
pub fn refusal_code(refusal: Refusal) -> String {
  case refusal {
    Invalid(..) -> "attention_invalid"
    NoSuchStrand(..) -> "attention_no_such_strand"
    Full(..) -> "attention_full"
    Unavailable(..) -> "attention_unavailable"
  }
}

/// The words of a refusal, which say which bound was reached and its value.
///
/// ## Examples
///
/// ```gleam
/// assert attention.describe(attention.Full("asks", 32))
///   == "32 asks are already open in this session, which is the most "
///   <> "allowed. Carry on; a person will answer some"
/// ```
pub fn describe(refusal: Refusal) -> String {
  case refusal {
    Invalid(reason:) -> "that could not be recorded: " <> reason
    NoSuchStrand(name:) ->
      "`to` names `"
      <> name
      <> "`, which is not a strand of this session; leave `to` out to ask "
      <> "the owner"
    Full(records:, limit:) ->
      int.to_string(limit)
      <> " "
      <> records
      <> " are already open in this session, which is the most allowed. "
      <> "Carry on; a person will answer some"
    Unavailable(reason:) ->
      "that could not be recorded: " <> reason <> ". Carry on without it"
  }
}

// The tools ask the broker for nothing: they touch no path and start no
// process, and the host writes the record itself.
fn empty_requirements(workspace: String) -> SandboxPolicy {
  let base = tool.read_requirements(workspace)
  policy.SandboxPolicy(..base, readable_roots: [])
}
