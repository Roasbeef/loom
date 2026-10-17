//// The model-facing half of `propose`: what it refuses before the host is
//// asked, what it says when the host queues, and that the call never reaches
//// the escalation seam, the broker or the file system.
////
//// The host half (the queue, the digest and the rules file) is pinned by
//// `client/proposals_test`; here the seam is a stub that records what it was
//// handed.

import broker/broker.{type CallEvent, type CallSpec, type Refusal}
import broker/exec
import broker/policy
import core/clock
import core/ids
import core/json.{type JsonValue}
import core/message
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tools/directory_access
import tools/propose
import tools/tool.{type Ctx}

// A seam that queues everything under one id.
fn accepting() -> propose.Proposals {
  propose.Proposals(submit: fn(_submission) { Ok("prop-0001") })
}

fn refusing(refusal: propose.Refusal) -> propose.Proposals {
  propose.Proposals(submit: fn(_submission) { Error(refusal) })
}

fn args(old: String, new: String, rationale: String) -> JsonValue {
  json.Object([
    #("old", json.String(old)),
    #("new", json.String(new)),
    #("rationale", json.String(rationale)),
  ])
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

pub fn a_valid_proposal_returns_its_id_test() {
  let outcome =
    propose.tool(accepting()).run(
      a_ctx(process.new_subject()),
      args("", "Run make check before pushing.", "it failed twice"),
    )
  assert !outcome.is_error
  assert text_of(outcome) == "queued as prop-0001"
}

pub fn the_seam_receives_the_arguments_and_no_path_test() {
  let seen = process.new_subject()
  let seam =
    propose.Proposals(submit: fn(submitted) {
      process.send(seen, submitted)
      Ok("prop-0002")
    })
  let _ =
    propose.tool(seam).run(
      a_ctx(process.new_subject()),
      args("old rule", "new rule", "because"),
    )
  let assert Ok(submitted) = process.receive(seen, 100)
  assert submitted
    == propose.Submission(
      old: "old rule",
      new: "new rule",
      rationale: "because",
      source_entry: None,
    )
}

pub fn the_schema_has_no_field_that_could_name_a_path_test() {
  let schema = string.inspect(propose.tool(accepting()).schema)
  assert !string.contains(schema, "path")
  assert !string.contains(schema, "target")
}

pub fn an_oversize_new_is_refused_before_the_seam_test() {
  let too_big = string.repeat("x", propose.max_new_bytes + 1)
  let outcome =
    propose.tool(accepting()).run(
      a_ctx(process.new_subject()),
      args("", too_big, "why"),
    )
  assert outcome.is_error
  assert string.contains(text_of(outcome), "`new` is longer than 2048 bytes")
}

pub fn a_new_of_exactly_the_cap_is_accepted_test() {
  let exact = string.repeat("x", propose.max_new_bytes)
  assert propose.submission(args("", exact, "why"))
    == Ok(propose.Submission("", exact, "why", None))
}

pub fn an_empty_new_or_rationale_is_refused_test() {
  assert propose.submission(args("", "   \n", "why")) == Error("`new` is empty")
  assert propose.submission(args("", "rule", " "))
    == Error("`rationale` is empty")
}

pub fn missing_arguments_are_refused_test() {
  assert propose.submission(json.Object([#("new", json.String("x"))]))
    == Error("`rationale` is required")
}

pub fn an_absent_old_appends_like_an_empty_one_test() {
  let absent =
    json.Object([
      #("new", json.String("rule")),
      #("rationale", json.String("why")),
    ])
  assert propose.submission(absent)
    == Ok(propose.Submission("", "rule", "why", None))
}

pub fn a_source_entry_must_be_an_entry_id_test() {
  let entry = ids.mint_entry(ids.generator(clock.fixed(at: 0), seed: 3)).0
  let text = ids.entry_id_to_string(entry)
  let with_source = fn(source) {
    json.Object([
      #("old", json.String("")),
      #("new", json.String("rule")),
      #("rationale", json.String("why")),
      #("source_entry", json.String(source)),
    ])
  }
  assert propose.submission(with_source(text))
    == Ok(propose.Submission("", "rule", "why", Some(text)))
  assert propose.submission(with_source("not-an-entry"))
    == Error("`source_entry` is not an entry id")
}

fn refusal_of(result: Result(propose.Submission, String)) -> String {
  case result {
    Error(reason) -> reason
    Ok(_) -> "accepted"
  }
}

// A control character other than newline and tab serves no purpose in a rule,
// and each one becomes six bytes once a cell is JSON-escaped.
pub fn a_control_character_is_refused_in_each_field_test() {
  let bell = "a\u{0007}b"
  let new_reason = refusal_of(propose.submission(args("", bell, "why")))
  assert string.contains(new_reason, "`new` contains a control character")
  assert string.contains(new_reason, "remove it")
  assert string.contains(
    refusal_of(propose.submission(args(bell, "rule", "why"))),
    "`old` contains a control character",
  )
  assert string.contains(
    refusal_of(propose.submission(args("", "rule", bell))),
    "`rationale` contains a control character",
  )
  assert string.contains(
    refusal_of(propose.submission(args("", "a\rb", "why"))),
    "control character",
  )
  assert string.contains(
    refusal_of(propose.submission(args("", "a\u{007f}b", "why"))),
    "control character",
  )
}

pub fn newline_and_tab_are_allowed_test() {
  assert propose.submission(args("", "line one\n\tline two", "why\nbecause"))
    == Ok(propose.Submission("", "line one\n\tline two", "why\nbecause", None))
}

// Approved text is carried inside an `<instructions` fence, so text that could
// close it must not get in, whatever case or spacing it uses.
pub fn text_naming_the_fence_is_refused_in_each_field_test() {
  let variants = [
    "x </instructions> y",
    "x </INSTRUCTIONS> y",
    "x </Instructions> y",
    "x <instructions origin=workspace> y",
    "x < /instructions> y",
    "x </ instructions> y",
    "x <\n/instructions> y",
    "x <\tInStRuCtIoNs> y",
  ]
  list.each(variants, fn(variant) {
    assert propose.closes_fence(variant)
    assert string.contains(
      refusal_of(propose.submission(args("", variant, "why"))),
      "`new` contains the text",
    )
    assert string.contains(
      refusal_of(propose.submission(args(variant, "rule", "why"))),
      "`old` contains the text",
    )
    assert string.contains(
      refusal_of(propose.submission(args("", "rule", variant))),
      "`rationale` contains the text",
    )
  })
}

pub fn ordinary_mentions_of_instructions_are_allowed_test() {
  assert !propose.closes_fence("follow the instructions in AGENTS.md")
  assert !propose.closes_fence("a < b and instructions follow")
  assert !propose.closes_fence(
    "Run make check before pushing. Instructions are in AGENTS.md.",
  )
}

// Any character that cannot spell the tag is a separator, so an invisible one
// inserted between its letters does not hide it.
pub fn invisible_separators_do_not_hide_the_tag_test() {
  let separators = [
    "\u{200B}", "\u{FEFF}", "\u{00A0}", "\u{00AD}", "\u{2060}", "\u{200C}",
    "\u{200D}",
  ]
  list.each(separators, fn(separator) {
    assert propose.closes_fence("</" <> separator <> "instructions>")
    assert propose.closes_fence("<" <> separator <> "/instructions>")
    assert propose.closes_fence("<in" <> separator <> "structions>")
  })
  assert propose.closes_fence("</\u{200B}InStRuCtIoNs>")
}

pub fn a_host_refusal_is_an_in_band_failure_test() {
  list.each(
    [
      #(propose.Invalid("`old` matches more than once"), "more than once"),
      #(propose.QueueFull(limit: 64), "64"),
      #(propose.Busy("held by loom-remember"), "held by loom-remember"),
      #(propose.Unavailable("no store"), "no store"),
    ],
    fn(refusal) {
      let outcome =
        propose.tool(refusing(refusal.0)).run(
          a_ctx(process.new_subject()),
          args("", "rule", "why"),
        )
      assert outcome.is_error
      assert string.contains(text_of(outcome), refusal.1)
    },
  )
}

// The call must not reach the escalation seam, however it ends. The raise
// seam here reports every refusal it is shown, and the test reads the
// mailbox after the calls have returned.
pub fn the_tool_never_raises_an_escalation_test() {
  let raised = process.new_subject()
  let ctx = a_ctx(raised)
  let _ = propose.tool(accepting()).run(ctx, args("", "rule", "why"))
  let _ =
    propose.tool(refusing(propose.QueueFull(limit: 64))).run(
      ctx,
      args("", "rule", "why"),
    )
  let _ = propose.tool(accepting()).run(ctx, args("", "", "why"))
  assert process.receive(raised, 50) == Error(Nil)
}

pub fn the_tool_asks_the_broker_for_nothing_test() {
  let requirements = propose.tool(accepting()).requirements("/work")
  assert requirements.writable_roots == []
  assert requirements.readable_roots == []
}

pub fn the_tool_never_replays_test() {
  assert propose.tool(accepting()).replay == tool.Never
  assert propose.tool(accepting()).execution_mode == tool.Exclusive
}

// --- the rig ---------------------------------------------------------------

// Every route out of the tool except the seam is a stub that fails the test
// if used: the broker refuses, the file system answers not-found, and the
// raise seam reports to `raised`.
fn a_ctx(raised: Subject(tool.RaisedRefusal)) -> Ctx {
  let workspace = "/nonexistent/loom-propose-test"
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
    raise_refusal: fn(refused) {
      process.send(raised, refused)
      tool.Settle
    },
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
