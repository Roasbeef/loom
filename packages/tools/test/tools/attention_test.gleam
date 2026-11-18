//// The model-facing half of `ask` and `notice`: every bound in
//// protocol-change/119, what each refusal says, that a recorded ask ends the
//// run while a refused one and a notice do not, and what the description
//// promises the model.
////
//// The host half (the records, the bounds that need the store, the guard) is
//// pinned by `client/attention_test`; here the seam is a stub that records
//// what it was handed.

import broker/broker.{type CallEvent, type CallSpec, type Refusal}
import broker/exec
import broker/policy
import core/attention as records
import core/clock
import core/ids
import core/json.{type JsonValue}
import core/message
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tools/attention
import tools/directory_access
import tools/tool.{type Ctx}

fn seam() -> attention.Attention {
  attention.Attention(
    ask: fn(_caller, _request) { Ok("ask-0123456789") },
    notice: fn(_caller, _request) { Ok("find-0123456789") },
  )
}

fn ask_tool() -> tool.Tool {
  let assert Ok(found) =
    list.find(attention.tools(seam()), fn(t) { t.name == "ask" })
  found
}

fn notice_tool() -> tool.Tool {
  let assert Ok(found) =
    list.find(attention.tools(seam()), fn(t) { t.name == "notice" })
  found
}

fn text_of(outcome: tool.ToolOutcome) -> String {
  outcome.content
  |> list.map(fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> text
      message.ToolResultImage(..) -> ""
    }
  })
  |> string.join("\n")
}

fn field(name: String, value: JsonValue) -> #(String, JsonValue) {
  #(name, value)
}

fn confirm(prompt: String) -> JsonValue {
  json.Object([
    field("prompt", json.String(prompt)),
    field("kind", json.String("confirm")),
  ])
}

fn option(label: String) -> JsonValue {
  json.Object([field("label", json.String(label))])
}

fn options(count: Int) -> List(JsonValue) {
  list.repeat(Nil, count)
  |> list.index_map(fn(_, index) { option(int.to_string(index)) })
}

fn choice(options: List(JsonValue)) -> JsonValue {
  json.Object([
    field("prompt", json.String("Which?")),
    field("kind", json.String("choice")),
    field("options", json.Array(options)),
  ])
}

fn ask_args(questions: List(JsonValue)) -> JsonValue {
  json.Object([field("questions", json.Array(questions))])
}

fn refused_with(args: JsonValue, fragment: String) -> Nil {
  let outcome = ask_tool().run(a_ctx(), args)
  assert outcome.is_error
  assert outcome.terminate == tool.ContinueRun
  assert string.contains(text_of(outcome), fragment)
}

// --- the tools' contract ---------------------------------------------------

pub fn the_two_tools_are_registered_ask_first_test() {
  assert list.map(attention.tools(seam()), fn(t) { t.name })
    == ["ask", "notice"]
}

pub fn ask_never_replays_and_runs_alone_and_notice_never_replays_and_runs_beside_others_test() {
  assert ask_tool().replay == tool.Never
  assert ask_tool().execution_mode == tool.Exclusive
  assert notice_tool().replay == tool.Never
  assert notice_tool().execution_mode == tool.Concurrent
}

pub fn the_description_forbids_asking_for_a_secret_test() {
  let description = ask_tool().description
  assert string.contains(description, "never request a secret")
  assert string.contains(description, "grants and approvals")
}

pub fn the_description_tells_the_model_to_stop_and_how_the_answer_arrives_test() {
  let description = ask_tool().description
  assert string.contains(description, "your turn ends")
  assert string.contains(description, "message from the person")
  assert string.contains(description, "fenced")
  assert string.contains(description, "Other")
}

pub fn the_description_states_the_bounds_it_checks_test() {
  let description = ask_tool().description
  assert string.contains(description, "Put up to 4 questions")
  assert string.contains(description, "2 to 8 options")
  assert string.contains(description, "At most 32 asks")
  assert string.contains(notice_tool().description, "At most 128 notices")
  assert string.contains(notice_tool().description, "300 characters")
}

pub fn no_schema_field_takes_markup_or_a_question_identifier_test() {
  let schema = string.inspect(ask_tool().schema)
  assert !string.contains(schema, "\"html\"")
  assert !string.contains(schema, "\"markdown\"")
  assert !string.contains(schema, "\"id\"")
  assert !string.contains(schema, "\"key\"")
  assert !string.contains(schema, "password")
  assert !string.contains(schema, "secret\"")
}

// --- ask: success ----------------------------------------------------------

pub fn a_recorded_ask_returns_its_id_and_ends_the_run_test() {
  let outcome = ask_tool().run(a_ctx(), ask_args([confirm("Retry?")]))
  assert !outcome.is_error
  assert string.starts_with(text_of(outcome), "asked as ask-0123456789")
  assert string.contains(text_of(outcome), "End your turn now")
  assert outcome.terminate == tool.TerminateRun
  assert outcome.details
    == Some(json.Object([field("id", json.String("ask-0123456789"))]))
}

pub fn the_seam_receives_keys_assigned_by_position_test() {
  let seen = process.new_subject()
  let spying =
    attention.Attention(
      ask: fn(caller, request) {
        process.send(seen, #(caller.strand, request))
        Ok("ask-0000000001")
      },
      notice: fn(_caller, _request) { Ok("find-0000000001") },
    )
  let assert [ask, ..] = attention.tools(spying)
  let args =
    json.Object([
      field("to", json.String("sub:main/a")),
      field("why", json.String("Because.")),
      field(
        "questions",
        json.Array([
          confirm("One?"),
          json.Object([
            field("prompt", json.String("Two?")),
            field("kind", json.String("multiple")),
            field(
              "options",
              json.Array([option("a"), option("b"), option("c")]),
            ),
            field("min", json.Int(0)),
            field("max", json.Int(2)),
          ]),
          json.Object([
            field("prompt", json.String("Three?")),
            field("kind", json.String("fill")),
            field("format", json.String("number")),
          ]),
        ]),
      ),
    ])
  let _ = ask.run(a_ctx(), args)
  let assert Ok(#(strand, request)) = process.receive(seen, 100)
  assert strand == "main"
  assert request.to == Some("sub:main/a")
  assert request.why == Some("Because.")
  assert list.map(request.questions, fn(q) { q.key }) == ["q1", "q2", "q3"]
  let assert [one, two, three] = request.questions
  assert one.kind == records.Confirm
  assert two.kind == records.Multiple(min: 0, max: 2)
  assert three.kind == records.Fill(format: records.Number)
}

pub fn multiple_defaults_to_one_through_all_and_fill_to_text_test() {
  let assert Ok(request) =
    attention.ask_request(
      ask_args([
        json.Object([
          field("prompt", json.String("Which?")),
          field("kind", json.String("multiple")),
          field("options", json.Array([option("a"), option("b"), option("c")])),
        ]),
        json.Object([
          field("prompt", json.String("Why?")),
          field("kind", json.String("fill")),
        ]),
      ]),
    )
  let assert [multiple, fill] = request.questions
  assert multiple.kind == records.Multiple(min: 1, max: 3)
  assert fill.kind == records.Fill(format: records.ShortText)
}

pub fn a_checklist_and_a_recommended_option_are_accepted_test() {
  let assert Ok(request) =
    attention.ask_request(
      ask_args([
        json.Object([
          field("prompt", json.String("Which?")),
          field("kind", json.String("checklist")),
          field(
            "options",
            json.Array([
              json.Object([
                field("label", json.String("a")),
                field("note", json.String("Does a.")),
                field("recommended", json.Bool(True)),
              ]),
              option("b"),
            ]),
          ),
        ]),
      ]),
    )
  let assert [question] = request.questions
  let assert [first, second] = question.options
  assert first
    == records.Alternative(
      label: "a",
      note: Some("Does a."),
      emphasis: records.Recommended,
    )
  assert second
    == records.Alternative(label: "b", note: None, emphasis: records.Plain)
}

// --- ask: refusals ---------------------------------------------------------

pub fn no_questions_or_too_many_are_refused_test() {
  refused_with(json.Object([]), "`questions` is required")
  refused_with(ask_args([]), "needs at least one question")
  refused_with(ask_args(list.repeat(confirm("x?"), 5)), "at most 4 questions")
  refused_with(
    json.Object([field("questions", json.String("x"))]),
    "`questions` must be an array",
  )
}

pub fn four_questions_are_accepted_test() {
  assert result_ok(
    attention.ask_request(ask_args(list.repeat(confirm("x?"), 4))),
  )
}

pub fn a_prompt_past_its_bound_is_refused_and_the_bound_itself_is_not_test() {
  assert result_ok(
    attention.ask_request(ask_args([confirm(string.repeat("p", 300))])),
  )
  refused_with(
    ask_args([confirm(string.repeat("p", 301))]),
    "question 1: `prompt` is longer than 300 characters",
  )
  refused_with(ask_args([confirm("  ")]), "question 1: `prompt` is empty")
}

pub fn a_why_past_its_bound_is_refused_test() {
  let long = json.String(string.repeat("w", 201))
  refused_with(
    json.Object([
      field("questions", json.Array([confirm("x?")])),
      field("why", long),
    ]),
    "`why` is longer than 200 characters",
  )
  assert result_ok(
    attention.ask_request(
      json.Object([
        field("questions", json.Array([confirm("x?")])),
        field("why", json.String(string.repeat("w", 200))),
      ]),
    ),
  )
}

pub fn an_option_count_outside_two_to_eight_is_refused_test() {
  refused_with(
    ask_args([choice([option("only")])]),
    "question 1: a `choice` question needs 2 to 8 `options`, got 1",
  )
  refused_with(ask_args([choice(options(9))]), "got 9")
  assert result_ok(attention.ask_request(ask_args([choice(options(8))])))
  refused_with(
    ask_args([
      json.Object([
        field("prompt", json.String("Which?")),
        field("kind", json.String("choice")),
      ]),
    ]),
    "got 0",
  )
}

pub fn options_on_confirm_or_fill_are_refused_test() {
  refused_with(
    ask_args([
      json.Object([
        field("prompt", json.String("Sure?")),
        field("kind", json.String("confirm")),
        field("options", json.Array([option("a"), option("b")])),
      ]),
    ]),
    "a `confirm` question takes no `options`",
  )
  refused_with(
    ask_args([
      json.Object([
        field("prompt", json.String("Name?")),
        field("kind", json.String("fill")),
        field("options", json.Array([option("a"), option("b")])),
      ]),
    ]),
    "a `fill` question takes no `options`",
  )
}

pub fn a_label_past_its_bound_or_repeated_is_refused_test() {
  refused_with(
    ask_args([choice([option(string.repeat("l", 61)), option("b")])]),
    "question 1, option 1: `label` is longer than 60 characters",
  )
  assert result_ok(
    attention.ask_request(
      ask_args([choice([option(string.repeat("l", 60)), option("b")])]),
    ),
  )
  refused_with(
    ask_args([choice([option("a"), option("a")])]),
    "two options share a label",
  )
}

pub fn a_note_past_its_bound_is_refused_test() {
  let noted = fn(length) {
    json.Object([
      field("label", json.String("a")),
      field("note", json.String(string.repeat("n", length))),
    ])
  }
  refused_with(
    ask_args([choice([noted(141), option("b")])]),
    "`note` is longer than 140 characters",
  )
  assert result_ok(
    attention.ask_request(ask_args([choice([noted(140), option("b")])])),
  )
}

pub fn labels_differing_only_in_surrounding_space_are_refused_test() {
  refused_with(
    ask_args([choice([option("a"), option(" a ")])]),
    "two options share a label",
  )
}

pub fn the_path_schema_states_its_bound_in_bytes_test() {
  assert string.contains(
    string.inspect(notice_tool().schema),
    "at most 512 bytes",
  )
}

pub fn two_recommended_options_are_refused_test() {
  let recommended = fn(label) {
    json.Object([
      field("label", json.String(label)),
      field("recommended", json.Bool(True)),
    ])
  }
  refused_with(
    ask_args([choice([recommended("a"), recommended("b")])]),
    "at most one option may be `recommended`",
  )
}

pub fn min_and_max_are_checked_against_the_option_count_test() {
  let multiple = fn(min, max) {
    ask_args([
      json.Object([
        field("prompt", json.String("Which?")),
        field("kind", json.String("multiple")),
        field("options", json.Array([option("a"), option("b")])),
        field("min", json.Int(min)),
        field("max", json.Int(max)),
      ]),
    ])
  }
  assert result_ok(attention.ask_request(multiple(0, 2)))
  assert result_ok(attention.ask_request(multiple(2, 2)))
  refused_with(multiple(-1, 2), "1 <= max <= the number of options (2)")
  refused_with(multiple(2, 1), "got min 2 and max 1")
  refused_with(multiple(0, 3), "got min 0 and max 3")

  // A `multiple` that may pick at most none is a question nobody can answer.
  refused_with(multiple(0, 0), "got min 0 and max 0")
}

pub fn min_max_and_format_are_refused_on_other_kinds_test() {
  let with_extra = fn(kind, key, value) {
    ask_args([
      json.Object([
        field("prompt", json.String("x?")),
        field("kind", json.String(kind)),
        field(key, value),
      ]),
    ])
  }
  refused_with(
    with_extra("confirm", "min", json.Int(1)),
    "`min` does not apply to a `confirm` question",
  )
  refused_with(
    with_extra("fill", "max", json.Int(1)),
    "`max` does not apply to a `fill` question",
  )
  refused_with(
    with_extra("confirm", "format", json.String("text")),
    "`format` does not apply",
  )
}

pub fn an_unknown_kind_or_format_is_refused_and_no_format_names_a_password_test() {
  refused_with(
    ask_args([
      json.Object([
        field("prompt", json.String("x?")),
        field("kind", json.String("slider")),
      ]),
    ]),
    "`kind` is `confirm`, `choice`",
  )
  refused_with(
    ask_args([
      json.Object([
        field("prompt", json.String("Token?")),
        field("kind", json.String("fill")),
        field("format", json.String("password")),
      ]),
    ]),
    "`format` is `text`, `long_text`, `path`, `number` or `url`",
  )
}

pub fn a_question_identifier_or_any_unknown_field_is_refused_test() {
  refused_with(
    ask_args([
      json.Object([
        field("prompt", json.String("x?")),
        field("kind", json.String("confirm")),
        field("key", json.String("q9")),
      ]),
    ]),
    "unknown field `key`",
  )
  refused_with(
    ask_args([
      json.Object([
        field("prompt", json.String("x?")),
        field("kind", json.String("confirm")),
        field("html", json.String("<b>x</b>")),
      ]),
    ]),
    "unknown field `html`",
  )
  refused_with(
    ask_args([
      choice([
        json.Object([
          field("label", json.String("a")),
          field("markup", json.String("<b/>")),
        ]),
        option("b"),
      ]),
    ]),
    "unknown field `markup`",
  )
}

pub fn a_refusal_from_the_host_continues_the_run_and_says_which_bound_test() {
  let refusing =
    attention.Attention(
      ask: fn(_caller, _request) { Error(attention.Full("asks", 32)) },
      notice: fn(_caller, _request) { Error(attention.Full("finds", 128)) },
    )
  let assert [ask, notice] = attention.tools(refusing)
  let asked = ask.run(a_ctx(), ask_args([confirm("x?")]))
  assert asked.is_error
  assert asked.terminate == tool.ContinueRun
  assert string.contains(text_of(asked), "32 asks are already open")
  let noticed =
    notice.run(
      a_ctx(),
      json.Object([
        field("kind", json.String("bug")),
        field("text", json.String("x")),
      ]),
    )
  assert noticed.is_error
  assert string.contains(text_of(noticed), "128 finds are already open")
}

pub fn an_unknown_strand_is_worded_for_the_model_test() {
  let outcome = attention.refusal_outcome(attention.NoSuchStrand("nobody"))
  assert outcome.is_error
  assert string.contains(text_of(outcome), "`nobody`, which is not a strand")
}

// --- notice ----------------------------------------------------------------

fn notice_args(fields: List(#(String, JsonValue))) -> JsonValue {
  json.Object(list.append(
    [field("kind", json.String("risk")), field("text", json.String("Hazard."))],
    fields,
  ))
}

fn notice_refused(args: JsonValue, fragment: String) -> Nil {
  let outcome = notice_tool().run(a_ctx(), args)
  assert outcome.is_error
  assert outcome.terminate == tool.ContinueRun
  assert string.contains(text_of(outcome), fragment)
}

pub fn a_notice_returns_its_id_and_carries_on_test() {
  let outcome = notice_tool().run(a_ctx(), notice_args([]))
  assert !outcome.is_error
  assert text_of(outcome) == "noted as find-0123456789"
  assert outcome.terminate == tool.ContinueRun
  assert outcome.details
    == Some(json.Object([field("id", json.String("find-0123456789"))]))
}

pub fn every_find_kind_is_accepted_and_others_are_not_test() {
  list.each(["risk", "idea", "bug", "question"], fn(kind) {
    assert result_ok(
      attention.notice_request(
        json.Object([
          field("kind", json.String(kind)),
          field("text", json.String("x")),
        ]),
      ),
    )
  })
  notice_refused(
    json.Object([
      field("kind", json.String("praise")),
      field("text", json.String("x")),
    ]),
    "`kind` is `risk`, `idea`, `bug` or `question`",
  )
}

pub fn the_text_is_bounded_at_three_hundred_characters_test() {
  assert result_ok(
    attention.notice_request(
      notice_args([field("text", json.String(string.repeat("t", 300)))]),
    ),
  )
  notice_refused(
    json.Object([
      field("kind", json.String("bug")),
      field("text", json.String(string.repeat("t", 301))),
    ]),
    "`text` is longer than 300 characters",
  )
  notice_refused(
    json.Object([
      field("kind", json.String("bug")),
      field("text", json.String(" ")),
    ]),
    "`text` is empty",
  )
}

pub fn a_path_must_be_relative_without_dot_dot_test() {
  let with_path = fn(path) {
    json.Object([
      field("kind", json.String("bug")),
      field("text", json.String("x")),
      field("path", json.String(path)),
    ])
  }
  assert result_ok(attention.notice_request(with_path("src/a.gleam")))
  assert result_ok(attention.notice_request(with_path("a..b/c")))
  notice_refused(with_path("/etc/passwd"), "must be relative to the workspace")
  notice_refused(with_path("../x"), "must not contain `..`")
  notice_refused(with_path("a/../../x"), "must not contain `..`")
  notice_refused(with_path(""), "`path` is empty")
}

pub fn a_path_is_checked_trimmed_and_bounded_test() {
  let with_path = fn(path) {
    json.Object([
      field("kind", json.String("bug")),
      field("text", json.String("x")),
      field("path", json.String(path)),
    ])
  }

  // A leading space cannot hide the slash, and what is kept is trimmed.
  notice_refused(with_path(" /etc/passwd"), "must be relative to the workspace")
  notice_refused(with_path(" ../x"), "must not contain `..`")
  notice_refused(with_path("   "), "`path` is empty")
  let assert Ok(request) = attention.notice_request(with_path(" src/a.gleam "))
  assert request.path == Some("src/a.gleam")

  // 512 bytes pass and 513 do not.
  assert result_ok(attention.notice_request(with_path(string.repeat("p", 512))))
  notice_refused(
    with_path(string.repeat("p", 513)),
    "`path` is longer than 512 bytes",
  )
}

pub fn a_line_needs_a_path_and_is_at_least_one_test() {
  let with_line = fn(path, line) {
    json.Object(
      list.append(
        [
          field("kind", json.String("bug")),
          field("text", json.String("x")),
          field("line", json.Int(line)),
        ],
        case path {
          Some(path) -> [field("path", json.String(path))]
          None -> []
        },
      ),
    )
  }
  assert result_ok(attention.notice_request(with_line(Some("a.gleam"), 1)))
  notice_refused(with_line(None, 3), "`line` needs a `path`")
  notice_refused(with_line(Some("a.gleam"), 0), "`line` is at least 1")
  notice_refused(with_line(Some("a.gleam"), -4), "`line` is at least 1")
}

pub fn the_notice_description_says_it_never_stops_work_and_is_not_an_ask_test() {
  let description = notice_tool().description
  assert string.contains(description, "never stops your work")
  assert string.contains(description, "is an `ask`, not a notice")
  assert string.contains(description, "Never put a secret")
}

fn result_ok(result: Result(a, e)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

// --- context ---------------------------------------------------------------

fn a_ctx() -> Ctx {
  let workspace = "/nonexistent/loom-attention-test"
  let #(op_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 17))
  tool.Ctx(
    directory_access: directory_access.none(),
    workspace:,
    strand: "main",
    op_id:,
    step_id: "step-1",
    source_index: 0,
    base_policy: policy.workspace_default(workspace),
    grants: [],
    demand: exec.FullEnforcement,
    env: [],
    clock: clock.fixed(at: 1000),
    filesystem: dead_filesystem(),
    blob_root: workspace <> "/.blobs",
    clear_call: dead_broker,
    raise_refusal: fn(_refused) { tool.Settle },
    observe_output: tool.ignore_output(),
  )
}

fn dead_broker(
  _spec: CallSpec,
  _events: Subject(CallEvent),
) -> Result(tool.RunningCall, Refusal) {
  Error(broker.BrokerUnavailable)
}

fn dead_filesystem() -> tool.FileSystem {
  tool.FileSystem(
    read: fn(path) { Error(tool.FsNotFound(path:)) },
    write: fn(path, _bytes) { Error(tool.FsNotFound(path:)) },
    create_directory_all: fn(path) { Error(tool.FsNotFound(path:)) },
    is_file: fn(_path) { Ok(False) },
    read_link: fn(_path) { Ok(tool.LinkMissing) },
    rename: fn(from, _to) { Error(tool.FsNotFound(path: from)) },
  )
}
