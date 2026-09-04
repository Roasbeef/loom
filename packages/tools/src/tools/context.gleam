//// The `context_remaining` tool: how full the calling strand's context
//// window is, asked by the model rather than told to it.
////
//// # Why a tool, and why it costs almost nothing
////
//// A model cannot see its own context size. Loom compacts a window by
//// replacing the older part of it with the strand's own notes
//// (`client/checkpoint`), so a model that knows a boundary is near can
//// write what it will need — and a model that does not has only the
//// near-limit reminder the harness appends inside the last reserve. This
//// tool is the model's own door onto the same arithmetic the threshold
//// reads: which window it is in, how many tokens are in use, how many
//// remain before the checkpoint, and how many notes it has written.
////
//// It is a read over durable state, priced the way the compaction
//// threshold prices a context, and it runs harness-side through a seam
//// the host fills (`client/checkpoint.remaining_seam`) — this package
//// cannot see a session store, exactly as `tools/history` cannot see the
//// search index. It starts no process and touches no path, so it asks
//// the broker for nothing and composes with any session base. `replay:
//// Safe`: re-running a read after a crash repeats no effect, and the
//// answer it gives is about the moment it is asked.
////
//// # What the answer is, and is not
////
//// The numbers are the harness's estimate — the newest provider-reported
//// usage plus a characters-over-four count for everything after it — so
//// they are what the threshold will act on, not a promise about the
//// provider's own tokenizer. The answer says where the boundary is and
//// what survives it; it does not move the boundary, and there is no
//// tool that asks for a checkpoint early. The model's lever is the
//// notes.

import broker/policy.{type SandboxPolicy}
import core/json.{type JsonValue}
import gleam/int
import gleam/option.{Some}
import tools/tool.{type Tool, type ToolOutcome}

/// The tool name, as a constant because the host registers it by name
/// and a test asserts on registration rather than on a spelling.
pub const tool_name = "context_remaining"

/// Where the window's boundary is, as the strand's compaction settings
/// put it.
pub type Boundary {
  /// Compaction is on: the threshold compacts once the context passes
  /// `tokens`, keeping the newest `keep_recent_tokens` verbatim.
  CheckpointAt(tokens: Int, keep_recent_tokens: Int)

  /// Compaction is off on this host. Nothing is cut; a request that
  /// outgrows the window is refused by the provider instead.
  NoCheckpoint
}

/// One answer: the calling strand's window as the harness measures it.
///
/// Constructor invariants: `window` is the one-based ordinal of the
/// window the strand is in, so a strand that has never compacted is in
/// window one; `used_tokens` is the threshold's own estimate of the
/// current context; `notes` counts the strand's blackboard cells.
pub type Report {
  Report(
    /// The strand the answer is about.
    strand: String,
    /// Which window this is, counting from one.
    window: Int,
    /// The strand's context window, in tokens.
    context_window: Int,
    /// What the context costs now, as the threshold estimates it.
    used_tokens: Int,
    /// Where the boundary is.
    boundary: Boundary,
    /// How many `agent_note` cells the strand has written.
    notes: Int,
  )
}

/// The seam the host fills: the report for one strand, by name, or a
/// worded reason it could not be built. Total — a store that will not
/// answer is a reason, not a crash.
pub type Context {
  Context(report: fn(String) -> Result(Report, String))
}

/// The `context_remaining` tool over one seam.
///
/// ## Examples
///
/// ```gleam
/// // tool.registry([bash.tool(), context.tool(seam)])
/// ```
///
pub fn tool(context: Context) -> Tool {
  tool.Tool(
    name: tool_name,
    description: "Ask how full your context window is: the tokens in use, "
      <> "how many remain before the older part of this conversation leaves "
      <> "your context at a checkpoint, which window you are in, and how "
      <> "many notes you have written. What survives a checkpoint is your "
      <> "own notes and the newest messages, so ask before a long stretch "
      <> "of work and write down with agent_note what you will still need. "
      <> "Read-only and free of side effects; takes no arguments.",
    prompt_snippet: Some(
      "`context_remaining` says how full your context window is and how "
      <> "much room is left before a checkpoint.",
    ),
    schema: tool.object_schema([], []),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: empty_requirements,
    run: fn(ctx, _args) { run(context, ctx.strand) },
  )
}

fn run(context: Context, strand: String) -> ToolOutcome {
  use report <- tool.or_outcome(context.report(strand), tool.failure)
  tool.success(render(report))
  |> tool.with_details(details(report))
}

/// The answer as the model reads it: the numbers in a sentence, then
/// what the boundary means for what it should do now.
///
/// ## Examples
///
/// ```gleam
/// // context.render(report)
/// // |> string.starts_with("Context window 2 of strand `main`")
/// ```
///
pub fn render(report: Report) -> String {
  "Context window "
  <> int.to_string(report.window)
  <> " of strand `"
  <> report.strand
  <> "`: about "
  <> int.to_string(report.used_tokens)
  <> " of "
  <> int.to_string(report.context_window)
  <> " tokens in use. "
  <> boundary_sentence(report)
}

fn boundary_sentence(report: Report) -> String {
  case report.boundary {
    CheckpointAt(tokens:, keep_recent_tokens:) ->
      "About "
      <> int.to_string(remaining(report))
      <> " tokens remain before the checkpoint at "
      <> int.to_string(tokens)
      <> ", where everything older than the newest ~"
      <> int.to_string(keep_recent_tokens)
      <> " tokens leaves your context and is replaced by your own notes ("
      <> int.to_string(report.notes)
      <> " written so far). Write with agent_note whatever you will still "
      <> "need; the cut messages stay in the durable history that "
      <> "history_search reads."
    NoCheckpoint ->
      "Compaction is off on this host, so nothing will be cut for you: a "
      <> "request that outgrows the window is refused by the provider "
      <> "instead. You have written "
      <> int.to_string(report.notes)
      <> " notes."
  }
}

/// Tokens left below the checkpoint, floored at zero: a context the
/// threshold has already passed at this checkpoint reads as no room,
/// never as a negative count.
///
/// ## Examples
///
/// ```gleam
/// // context.remaining(report) == 40_600
/// ```
///
pub fn remaining(report: Report) -> Int {
  case report.boundary {
    CheckpointAt(tokens:, ..) -> int.max(tokens - report.used_tokens, 0)
    NoCheckpoint -> int.max(report.context_window - report.used_tokens, 0)
  }
}

fn details(report: Report) -> JsonValue {
  json.Object([
    #("strand", json.String(report.strand)),
    #("window", json.Int(report.window)),
    #("context_window", json.Int(report.context_window)),
    #("used_tokens", json.Int(report.used_tokens)),
    #("remaining_tokens", json.Int(remaining(report))),
    #("checkpoint_at", case report.boundary {
      CheckpointAt(tokens:, ..) -> json.Int(tokens)
      NoCheckpoint -> json.Null
    }),
    #("notes", json.Int(report.notes)),
  ])
}

// This tool touches no path and starts no process — the strand's
// projection is read harness-side, through the seam — so it asks the
// broker for nothing at all and composes with any session base.
fn empty_requirements(workspace: String) -> SandboxPolicy {
  let base = tool.read_requirements(workspace)
  policy.SandboxPolicy(..base, readable_roots: [])
}
