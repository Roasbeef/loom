//// The `context_remaining` tool: what it says about a window, how it
//// floors a boundary already passed, what it reports when a host
//// compacts nothing, and whose strand it answers for.

import broker/broker.{type CallEvent, type CallSpec, type Refusal}
import broker/exec
import broker/policy
import core/clock
import core/ids
import core/json
import core/message
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{Some}
import gleam/string
import tools/context
import tools/tool.{type Ctx}

fn report(used: Int, boundary: context.Boundary) -> context.Report {
  context.Report(
    strand: "main",
    window: 2,
    context_window: 200_000,
    used_tokens: used,
    boundary:,
    notes: 7,
  )
}

pub fn the_tool_declares_a_safe_concurrent_read_test() {
  let definition = context.tool(unreachable())
  assert definition.name == "context_remaining"
  assert definition.replay == tool.Safe
  assert definition.execution_mode == tool.Concurrent
}

pub fn the_answer_names_the_window_the_use_and_the_room_left_test() {
  let text =
    context.render(report(
      143_000,
      context.CheckpointAt(tokens: 183_616, keep_recent_tokens: 20_000),
    ))
  assert string.starts_with(text, "Context window 2 of strand `main`")
  assert string.contains(text, "about 143000 of 200000 tokens in use")
  assert string.contains(text, "About 40616 tokens remain")
  assert string.contains(text, "checkpoint at 183616")
  assert string.contains(text, "newest ~20000 tokens")
  assert string.contains(text, "(7 written so far)")
  assert string.contains(text, "agent_note")
  assert string.contains(text, "history_search")
}

// A context the threshold has already passed at this checkpoint reads as
// no room, never as a negative count.
pub fn a_passed_boundary_reads_as_no_room_test() {
  let passed =
    report(
      190_000,
      context.CheckpointAt(tokens: 183_616, keep_recent_tokens: 1),
    )
  assert context.remaining(passed) == 0
  assert string.contains(context.render(passed), "About 0 tokens remain")
}

pub fn a_host_with_compaction_off_says_so_test() {
  let text = context.render(report(50_000, context.NoCheckpoint))
  assert string.contains(text, "Compaction is off on this host")
  assert string.contains(text, "checkpoint at") == False
  assert context.remaining(report(50_000, context.NoCheckpoint)) == 150_000
}

// The seam's worded refusal reaches the model as the in-band failure.
pub fn a_seam_that_cannot_answer_fails_in_band_test() {
  let registry =
    tool.registry([
      context.tool(
        context.Context(report: fn(_strand) {
          Error("the strand's branch could not be read")
        }),
      ),
    ])
  let outcome =
    tool.dispatch(registry, a_ctx(), context.tool_name, json.Object([]))
  assert outcome.is_error
  assert string.contains(text_of(outcome), "could not be read")
}

// The strand the tool answers for is the caller's own, from the harness's
// coordinates, never an argument the model supplies.
pub fn the_tool_answers_for_the_calling_strand_test() {
  let registry =
    tool.registry([
      context.tool(
        context.Context(report: fn(strand) {
          Ok(
            context.Report(
              ..report(10, context.NoCheckpoint),
              strand:,
              context_window: 1000,
            ),
          )
        }),
      ),
    ])
  let outcome =
    tool.dispatch(
      registry,
      a_ctx(),
      context.tool_name,
      json.Object([#("strand", json.String("someone-else"))]),
    )
  assert outcome.is_error == False
  assert string.contains(text_of(outcome), "of strand `main`")
  let assert Some(json.Object(details)) = outcome.details
  assert list.key_find(details, "remaining_tokens") == Ok(json.Int(990))
}

// --- fixtures --------------------------------------------------------------

fn unreachable() -> context.Context {
  context.Context(report: fn(_strand) { Error("not asked in this test") })
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

fn a_ctx() -> Ctx {
  let workspace = "/nonexistent/loom-context-test"
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
