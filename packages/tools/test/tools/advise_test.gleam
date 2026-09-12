//// The `advise` tool: what it decodes, what it refuses, and what the
//// seam is handed.
////
//// Decoding is the larger half, because the verdict and its text are a
//// pair a model can get wrong in four ways and every one of them must
//// be an in-band error rather than a crash. The run path is the smaller
//// half and pins the load-bearing fact: the strand name reaching
//// `judge` is the driver's `Ctx.strand` and never anything in the
//// model's arguments.

import broker/broker.{type CallEvent, type CallSpec, type Refusal}
import broker/exec
import broker/policy
import core/clock
import core/ids.{type OpId}
import core/json.{type JsonValue}
import core/message
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/string
import tools/advise
import tools/tool.{type Ctx}

// --- fixtures --------------------------------------------------------------

fn an_op() -> OpId {
  let #(op, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 7))
  op
}

fn ctx_for(strand: String) -> Ctx {
  let workspace = "/nonexistent/loom-advise-test"
  tool.Ctx(
    workspace:,
    strand:,
    op_id: an_op(),
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

// A seam whose acknowledgement is derived from what it was handed, so an
// assertion on the rendered text is an assertion on the arguments that
// crossed it.
fn echoing_advice() -> advise.Advice {
  advise.Advice(judge: fn(strand, verdict) {
    Ok(advise.Delivered(how: strand <> "/" <> verdict_text(verdict)))
  })
}

// A seam that answers the same acknowledgement whatever it is asked, for
// the tests about rendering rather than about arguments.
fn answering(ack: advise.Ack) -> advise.Advice {
  advise.Advice(judge: fn(_strand, _verdict) { Ok(ack) })
}

// A seam that refuses. The refusal is the host's own words and the tool
// must not dress them up.
fn refusing(reason: String) -> advise.Advice {
  advise.Advice(judge: fn(_strand, _verdict) { Error(reason) })
}

fn verdict_text(verdict: advise.Verdict) -> String {
  case verdict {
    advise.Quiet -> "quiet"
    advise.Nudge(text:) -> "nudge:" <> text
    advise.Block(text:) -> "block:" <> text
  }
}

fn verdict_arguments(word: String) -> JsonValue {
  json.Object([#("verdict", json.String(word))])
}

fn verdict_and_text(word: String, text: String) -> JsonValue {
  json.Object([
    #("verdict", json.String(word)),
    #("text", json.String(text)),
  ])
}

fn run(
  advice: advise.Advice,
  strand: String,
  arguments: JsonValue,
) -> tool.ToolOutcome {
  let built = advise.tool(advice)
  built.run(ctx_for(strand), arguments)
}

fn text_of(outcome: tool.ToolOutcome) -> String {
  outcome.content
  |> list.filter_map(fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> string.join("\n")
}

// --- decoding --------------------------------------------------------------

pub fn quiet_decodes_without_text_test() {
  assert advise.decode_verdict(verdict_arguments("quiet")) == Ok(advise.Quiet)
}

pub fn quiet_decodes_with_empty_text_test() {
  assert advise.decode_verdict(verdict_and_text("quiet", ""))
    == Ok(advise.Quiet)
}

pub fn quiet_carrying_text_is_refused_test() {
  let assert Error(reason) =
    advise.decode_verdict(verdict_and_text("quiet", "one more thing"))
    as "a quiet verdict with something to say is a contradiction"
  assert string.contains(reason, "must be absent or empty")
}

pub fn nudge_decodes_with_text_test() {
  assert advise.decode_verdict(verdict_and_text("nudge", "name the test"))
    == Ok(advise.Nudge(text: "name the test"))
}

pub fn nudge_without_text_is_refused_test() {
  assert advise.decode_verdict(verdict_arguments("nudge"))
    == Error("`text` is required when verdict is nudge")
}

pub fn nudge_with_empty_text_is_refused_test() {
  assert advise.decode_verdict(verdict_and_text("nudge", ""))
    == Error("`text` is required when verdict is nudge")
}

pub fn block_decodes_with_text_test() {
  assert advise.decode_verdict(verdict_and_text("block", "that deletes data"))
    == Ok(advise.Block(text: "that deletes data"))
}

pub fn block_without_text_is_refused_test() {
  assert advise.decode_verdict(verdict_arguments("block"))
    == Error("`text` is required when verdict is block")
}

pub fn an_unknown_verdict_is_refused_by_name_test() {
  let assert Error(reason) = advise.decode_verdict(verdict_arguments("halt"))
    as "a fourth word must be refused rather than guessed at"
  assert string.contains(reason, "\"quiet\", \"nudge\" or \"block\"")
  assert string.contains(reason, "halt")
}

pub fn a_missing_verdict_is_refused_test() {
  assert advise.decode_verdict(json.Object([]))
    == Error("`verdict` is required")
}

pub fn a_non_string_verdict_is_refused_test() {
  assert advise.decode_verdict(json.Object([#("verdict", json.Int(1))]))
    == Error("`verdict` must be a string")
}

pub fn non_object_arguments_are_refused_test() {
  assert advise.decode_verdict(json.Null)
    == Error("the arguments must be a JSON object")
  assert advise.decode_verdict(json.Array([json.String("quiet")]))
    == Error("the arguments must be a JSON object")
  assert advise.decode_verdict(json.String("quiet"))
    == Error("the arguments must be a JSON object")
}

// --- the run path ----------------------------------------------------------

pub fn the_calling_strand_and_the_verdict_reach_the_seam_test() {
  let outcome =
    run(echoing_advice(), "advisor", verdict_and_text("block", "stop"))
  assert text_of(outcome) == "block delivered: advisor/block:stop"
  assert !outcome.is_error
}

pub fn a_quiet_verdict_reaches_the_seam_too_test() {
  // Quiet emits nothing, but the seam is still told: the cursor and the
  // guard both move on an answered feed, whatever the answer was.
  let outcome = run(echoing_advice(), "advisor", verdict_arguments("quiet"))
  assert text_of(outcome) == "block delivered: advisor/quiet"
}

pub fn each_acknowledgement_renders_its_own_line_test() {
  let arguments = verdict_and_text("block", "stop")
  let delivered = advise.Delivered(how: "steered the primary's current run")
  assert text_of(run(answering(delivered), "advisor", arguments))
    == "block delivered: steered the primary's current run"
  assert text_of(run(answering(advise.Queued), "advisor", arguments))
    == "nudge queued for the primary's next run start"

  let downgraded = advise.Downgraded(reason: "in cooldown")
  assert text_of(run(answering(downgraded), "advisor", arguments))
    == "block downgraded to a nudge: in cooldown"

  let dropped = advise.Dropped(reason: "duplicate")
  assert text_of(run(answering(dropped), "advisor", arguments))
    == "nothing was emitted: duplicate"
  assert text_of(run(answering(advise.Acknowledged), "advisor", arguments))
    == "quiet recorded; nothing was sent"
}

pub fn a_guarded_acknowledgement_is_still_a_success_test() {
  // A dropped duplicate and a downgraded block are the guard working,
  // not the call failing: marking them `is_error` would teach the model
  // to retry against a window that has not moved.
  let arguments = verdict_and_text("block", "stop")
  let dropped = run(answering(advise.Dropped(reason: "dup")), "a", arguments)
  assert !dropped.is_error

  let downgraded =
    run(answering(advise.Downgraded(reason: "cooldown")), "a", arguments)
  assert !downgraded.is_error
}

pub fn a_refusal_renders_as_an_error_outcome_in_the_hosts_words_test() {
  let outcome =
    run(refusing("no primary to advise"), "advisor", verdict_arguments("quiet"))
  assert outcome.is_error
  assert text_of(outcome) == "no primary to advise"
}

pub fn invalid_arguments_never_reach_the_seam_test() {
  // The seam crashes the test if it is called at all, which is the whole
  // assertion: decoding refuses before anything can be emitted.
  let never =
    advise.Advice(judge: fn(_strand, _verdict) {
      panic as "invalid arguments must be refused before the seam"
    })
  let outcome = run(never, "advisor", verdict_arguments("halt"))
  assert outcome.is_error
  assert string.starts_with(text_of(outcome), "invalid arguments: ")
}

// --- the tool definition ---------------------------------------------------

pub fn the_tool_is_never_replayed_and_runs_alone_test() {
  let built = advise.tool(echoing_advice())
  assert built.name == advise.name
  assert built.name == "advise"

  // A landed verdict cannot be re-executed: the block was delivered and
  // the cooldown was paid for the first time.
  assert built.replay == tool.Never
  assert built.execution_mode == tool.Exclusive
}

pub fn the_tool_asks_the_broker_for_nothing_test() {
  let built = advise.tool(echoing_advice())
  let requirements = built.requirements("/work")
  assert requirements.readable_roots == []
  assert requirements.writable_roots == []
  assert requirements.env_allow == []
}
