//// The model-facing scheduling door: the argument schema, the
//// exactly-one-timing rule, and the two expiry arguments a one-shot
//// refuses.
////
//// Every *bound* these tools state is enforced on the far side of the
//// seam (`client/scheduleseam`), and `test/client/scheduleseam_test`
//// pins those. What is testable here is the half this module owns — what
//// the model is shown and what it is refused before a call ever reaches
//// a store — so the seam is a stub whose only job is to record the
//// `Request` it was handed.

import broker/broker.{type CallEvent, type CallSpec, type Refusal}
import broker/exec
import broker/policy
import core/clock
import core/ids
import core/json.{type JsonValue}
import core/message
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import tools/schedule
import tools/tool.{type Ctx}

// --- the rig ---------------------------------------------------------------

// The bounds a host would supply, with distinct numbers so a description
// that renders the wrong one is visible rather than plausible.
fn limits() -> schedule.Limits {
  schedule.Limits(
    min_interval_seconds: 60,
    default_max_fires: 1000,
    max_schedules: 16,
    max_in_seconds: 604_800,
    max_max_fires: 1000,
    max_expires_after_s: 604_800,
  )
}

// A seam that accepts everything and echoes the request back through
// `Created`, so a test can see which timing arrived by reading `when`.
fn accepting() -> schedule.Schedules {
  schedule.Schedules(
    create: fn(ctx: tool.Ctx, request: schedule.Request) {
      Ok(schedule.Created(
        name: request.name,
        target: ctx.strand,
        when: describe(request),
        wake: request.wake,
      ))
    },
    list: fn(_ctx) { Ok([]) },
    cancel: fn(_ctx, _name, _target) { Ok(Nil) },
  )
}

// The request as this stub renders it: which timing, and what the two
// expiry arguments were. Not the seam's real rendering — that lives in
// `client/scheduleseam.describe_timing` — just enough to read back.
fn describe(request: schedule.Request) -> String {
  let timing = case request.timing {
    schedule.Every(seconds:) -> "every " <> to_text(Some(seconds))
    schedule.Cron(expression:) -> "cron " <> expression
    schedule.At(instant:) -> "at " <> instant
    schedule.In(seconds:) -> "in " <> to_text(Some(seconds))
  }
  timing
  <> " fires="
  <> to_text(request.max_fires)
  <> " window="
  <> to_text(request.expires_after_s)
}

fn to_text(value: Option(Int)) -> String {
  case value {
    None -> "-"
    Some(number) -> string.inspect(number)
  }
}

fn create_tool() -> tool.Tool {
  let assert Ok(found) =
    list.find(schedule.tools(accepting(), limits()), fn(candidate: tool.Tool) {
      candidate.name == schedule.create_tool_name
    })
    as "the creation tool must be registered"
  found
}

// The same shape `history_test` builds: nothing here reaches the
// filesystem or the broker, so both are stubs that refuse.
fn a_ctx() -> Ctx {
  let workspace = "/nonexistent/loom-schedule-test"
  let #(op_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 11))
  tool.Ctx(
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
    raise_refusal: tool.no_raise(),
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

fn run(args: List(#(String, JsonValue))) -> tool.ToolOutcome {
  let registry = tool.registry(schedule.tools(accepting(), limits()))
  tool.dispatch(registry, a_ctx(), schedule.create_tool_name, json.Object(args))
}

fn text_of(outcome: tool.ToolOutcome) -> String {
  outcome.content
  |> list.filter_map(fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> Ok(text)
      message.ToolResultImage(..) -> Error(Nil)
    }
  })
  |> string.join("\n")
}

fn schema_text() -> String {
  json.to_string(create_tool().schema)
}

// --- the schema names every argument ---------------------------------------

// A golden would pin the whole wording and break on every edit; what
// matters is that each argument the model may write is actually declared,
// since an undeclared one is invisible to a provider however carefully
// the description mentions it.
pub fn the_schema_declares_all_four_timings_test() {
  let schema = schema_text()
  assert string.contains(schema, "\"every_seconds\"")
  assert string.contains(schema, "\"cron\"")
  assert string.contains(schema, "\"at\"")
  assert string.contains(schema, "\"in_seconds\"")
}

pub fn the_schema_declares_the_expiry_bounds_test() {
  let schema = schema_text()
  assert string.contains(schema, "\"max_fires\"")
  assert string.contains(schema, "\"expires_after_s\"")
}

// Only `name` and `body` are required: the timing is one of four, which
// a JSON-schema `required` list cannot express, so it is checked in the
// tool and worded there.
pub fn only_the_name_and_body_are_required_test() {
  let schema = schema_text()
  assert string.contains(schema, "\"required\":[\"name\",\"body\"]")
}

// The three facts a model cannot work out for itself and would get
// wrong: that `in_seconds` exists because it has no clock, that cron is
// UTC, and that the day fields are ORed.
pub fn the_descriptions_say_what_a_model_cannot_infer_test() {
  let schema = schema_text()
  assert string.contains(schema, "you have no clock")
  assert string.contains(schema, "All times are UTC")
  assert string.contains(schema, "ORed, not ANDed")
  assert string.contains(schema, "no seconds field")
}

pub fn the_cron_description_names_what_it_refuses_test() {
  let schema = schema_text()
  assert string.contains(schema, "JAN")
  assert string.contains(schema, "MON")
  assert string.contains(schema, "L, W, ? and #")
}

// --- exactly one timing ----------------------------------------------------

pub fn each_single_timing_reaches_the_seam_test() {
  let base = [#("name", json.String("poll")), #("body", json.String("look"))]
  let cases = [
    #(#("every_seconds", json.Int(60)), "every 60"),
    #(#("cron", json.String("0 9 * * 1-5")), "cron 0 9 * * 1-5"),
    #(#("at", json.String("2026-09-01T09:00:00Z")), "at 2026-09-01T09:00:00Z"),
    #(#("in_seconds", json.Int(2700)), "in 2700"),
  ]
  list.each(cases, fn(one) {
    let #(argument, expected) = one
    let outcome = run(list.append(base, [argument]))
    assert !outcome.is_error as "one timing on its own must succeed"
    assert string.contains(text_of(outcome), expected)
  })
}

pub fn no_timing_at_all_is_refused_test() {
  let outcome =
    run([#("name", json.String("poll")), #("body", json.String("look"))])
  assert outcome.is_error as "a request with no timing must be refused"
  assert string.contains(text_of(outcome), "in_seconds")
  assert string.contains(text_of(outcome), "every_seconds")
  assert string.contains(text_of(outcome), "cron")
}

// The refusal names the two the model actually wrote, which is the whole
// reason the count is taken here rather than at the seam.
pub fn two_timings_are_refused_naming_both_test() {
  let outcome =
    run([
      #("name", json.String("poll")),
      #("body", json.String("look")),
      #("cron", json.String("0 9 * * *")),
      #("in_seconds", json.Int(600)),
    ])
  assert outcome.is_error as "two timings must be refused"
  assert string.contains(text_of(outcome), "in_seconds and cron")
}

// --- the expiry bounds are licensed by a recurring timing ------------------

pub fn the_bounds_pass_through_beside_a_recurring_timing_test() {
  let outcome =
    run([
      #("name", json.String("poll")),
      #("body", json.String("look")),
      #("every_seconds", json.Int(60)),
      #("max_fires", json.Int(4)),
      #("expires_after_s", json.Int(3600)),
    ])
  assert !outcome.is_error as "a bounded recurring request must succeed"
  assert string.contains(text_of(outcome), "fires=4")
  assert string.contains(text_of(outcome), "window=3600")
}

pub fn the_bounds_pass_through_beside_a_cron_timing_test() {
  let outcome =
    run([
      #("name", json.String("standup")),
      #("body", json.String("look")),
      #("cron", json.String("0 9 * * *")),
      #("max_fires", json.Int(7)),
    ])
  assert !outcome.is_error as "a bounded cron request must succeed"
  assert string.contains(text_of(outcome), "fires=7")
}

pub fn a_bound_beside_a_one_shot_is_refused_test() {
  let at =
    run([
      #("name", json.String("window")),
      #("body", json.String("look")),
      #("at", json.String("2026-09-01T09:00:00Z")),
      #("max_fires", json.Int(4)),
    ])
  assert at.is_error as "max_fires beside at must be refused"
  assert string.contains(text_of(at), "only valid beside every_seconds or cron")
  assert string.contains(text_of(at), "at fires exactly once")

  let relative =
    run([
      #("name", json.String("recheck")),
      #("body", json.String("look")),
      #("in_seconds", json.Int(600)),
      #("expires_after_s", json.Int(3600)),
    ])
  assert relative.is_error as "expires_after_s beside in_seconds is refused"
  assert string.contains(text_of(relative), "in_seconds fires exactly once")
}

// Absent bounds are absent, not zero: the seam reads `None` as "the
// host's default", and a request that never mentioned them must not
// arrive carrying a number.
pub fn absent_bounds_stay_absent_test() {
  let outcome =
    run([
      #("name", json.String("poll")),
      #("body", json.String("look")),
      #("every_seconds", json.Int(60)),
    ])
  assert !outcome.is_error as "an unbounded recurring request must succeed"
  assert string.contains(text_of(outcome), "fires=- window=-")
}
