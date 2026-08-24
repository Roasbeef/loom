//// The operation script: what a simulated session is *asked* to do.
////
//// A script is the semantic half of a simulation. It says which
//// settlement each assistant turn produces, what each tool returns,
//// whether the context overflows or a threshold trips, when the user
//// steers or aborts, and which operations run on the strand. It says
//// nothing about crashes or storage misbehaviour — those live in
//// `simulation/fault`, and the point of the split is that a script's
//// outcome is what every fault schedule over it must converge to.
////
//// Scripts are generated, not hand-written. Five fixed scenarios cover
//// what five people thought of; a generator covers what the shape of the
//// state space contains, which is the whole reason this runner exists.
////
//// Turns are keyed by *phase*, never by a counter: the number of
//// assistant messages in the projected context, plus a hundred once a
//// summary is in it. Errored, aborted, and deferred responses never
//// enter a projection, so a phase is the same on a crashed run as on a
//// clean one — which is what makes a script mean the same thing under
//// every schedule.

import conformance/simulation/random.{type Rng}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import machine/operation.{type ReplayPolicy, ReplayNever, ReplaySafe}

/// The marker every generated summary starts with, so a projection can
/// be asked whether it has been compacted without reading the store.
pub const summary_marker = "[summary]"

/// One tool call an assistant turn asks for.
pub type Call {
  Call(id: String, tool: String)
}

/// How one assistant turn settles.
pub type Settle {
  /// A final answer that ends the turn.
  Answer(text: String, tokens: Int)
  /// A tool-use response.
  Calls(calls: List(Call), tokens: Int)
  /// A retryable provider failure: drives the retry ladder.
  Transient
  /// A deferred stop with a valid handle: drives the poll path.
  Defer
  /// A length stop below the intended output limit: classified as
  /// overflow, which drives compaction and the resume one-shot.
  Overflow
}

/// What one tool execution returns.
pub type ToolBehavior {
  /// An ordinary result.
  ToolOk(text: String)
  /// An in-band error result.
  ToolErr(text: String)
}

/// How structural work (compaction and summarized navigation) is done.
pub type Structural {
  /// The decision hook supplies the summary itself; no provider request.
  Supplied
  /// The decision hook selects generation; `split` asks for a second
  /// nested request before the summary is produced.
  Generated(split: Bool)
}

/// Where a concurrent user action lands. Triggers name durable
/// positions, never dispatch counters: an effect index shifts when a
/// crash re-runs an effect, but "the generation request made with two
/// assistant messages in context" and "the execution of call c0read"
/// name the same moment on a crashed run as on a clean one. Each
/// intervention fires exactly once per session, guarded by a counter
/// that outlives the tree.
pub type Trigger {
  /// While the generation request at `turn` assistant messages of
  /// projected context is in flight.
  DuringTurn(turn: Int)
  /// While the tool execution for this call id is in flight.
  DuringCall(call: String)
  /// From the writer, immediately after the terminal transaction is
  /// durable and before its committer learns of it: the §4.6
  /// abort-versus-finish race.
  AtTerminalCommit
}

/// A concurrent user action, placed so that it races the strand rather
/// than queueing ahead of it.
pub type Intervention {
  /// Admit a steer item.
  Steer(trigger: Trigger, text: String)
  /// Admit a follow-up item.
  FollowUp(trigger: Trigger, text: String)
  /// Request durable cancellation.
  Abort(trigger: Trigger)
}

/// One operation the script runs on the strand, in order.
pub type Op {
  /// A conversational run.
  RunOp(prompt: String, settles: List(Settle), post: Settle)
  /// A standalone compaction operation.
  CompactOp
  /// A navigation to an earlier entry, optionally summarized.
  NavigateOp(summarize: Bool)
}

/// A whole simulated session's worth of intent.
pub type Script {
  Script(
    /// The tool registry: name to replay policy.
    registry: List(#(String, ReplayPolicy)),
    /// What each registered tool returns.
    tools: List(#(String, ToolBehavior)),
    /// The operations, run one after another.
    ops: List(Op),
    /// Trip the compaction threshold once the projection holds at least
    /// this many assistant messages and no summary.
    threshold_after: Option(Int),
    /// How structural work is performed.
    structural: Structural,
    /// Concurrent user actions.
    interventions: List(Intervention),
    /// What a deferred poll settles with.
    poll_answer: Settle,
  )
}

/// Whether this script can end in an aborted operation, in which case
/// how far the transcript got is a race and only the outcome kind and
/// the placement invariants are asserted.
///
/// ## Examples
///
/// ```gleam
/// // script.aborts(script) == False
/// ```
///
pub fn aborts(script: Script) -> Bool {
  list.any(script.interventions, fn(intervention) {
    case intervention {
      Abort(..) -> True
      Steer(..) | FollowUp(..) -> False
    }
  })
}

/// The settlement for a generation request at `turn` assistant messages
/// with `summaries` summaries in its projected context. Past the end of
/// the scripted turns — and after any compaction — the run answers and
/// finishes, so every script terminates.
///
/// ## Examples
///
/// ```gleam
/// // script.settle_for(op, turn: 0, summaries: 0)
/// ```
///
pub fn settle_for(op: Op, turn turn: Int, summaries summaries: Int) -> Settle {
  case op {
    RunOp(settles:, post:, ..) ->
      case summaries > 0 {
        True -> post
        False ->
          case list.drop(settles, turn) {
            [settle, ..] -> settle
            [] -> Answer(text: "settled", tokens: 3)
          }
      }
    CompactOp | NavigateOp(..) -> Answer(text: "settled", tokens: 3)
  }
}

/// How many summaries a projected context holds, counted by the marker
/// every generated summary carries.
///
/// ## Examples
///
/// ```gleam
/// // script.summaries_in(["user:[summary] ...", "assistant:stop:hi"]) == 1
/// ```
///
pub fn summaries_in(texts: List(String)) -> Int {
  list.fold(texts, 0, fn(count, text) {
    case string.contains(text, summary_marker) {
      True -> count + 1
      False -> count
    }
  })
}

/// A one-line description, printed with a failing seed so the shape of
/// the failing case is legible without re-running it.
///
/// ## Examples
///
/// ```gleam
/// // script.describe(script)
/// ```
///
pub fn describe(script: Script) -> String {
  let ops =
    script.ops
    |> list.map(describe_op)
    |> string.join(" then ")
  let structural = case script.structural {
    Supplied -> "supplied"
    Generated(split: False) -> "generated"
    Generated(split: True) -> "generated/split"
  }
  let threshold = case script.threshold_after {
    None -> "no threshold"
    Some(n) -> "threshold@" <> int.to_string(n)
  }
  ops
  <> " | "
  <> threshold
  <> " | "
  <> structural
  <> " | "
  <> string.join(list.map(script.interventions, describe_intervention), ",")
}

fn describe_op(op: Op) -> String {
  case op {
    RunOp(settles:, ..) ->
      "run(" <> string.join(list.map(settles, describe_settle), ">") <> ")"
    CompactOp -> "compact"
    NavigateOp(summarize: True) -> "navigate/summarized"
    NavigateOp(summarize: False) -> "navigate"
  }
}

fn describe_settle(settle: Settle) -> String {
  case settle {
    Answer(..) -> "answer"
    Calls(calls:, ..) -> "calls" <> int.to_string(list.length(calls))
    Transient -> "transient"
    Defer -> "defer"
    Overflow -> "overflow"
  }
}

fn describe_intervention(intervention: Intervention) -> String {
  case intervention {
    Steer(trigger:, ..) -> "steer@" <> describe_trigger(trigger)
    FollowUp(trigger:, ..) -> "followup@" <> describe_trigger(trigger)
    Abort(trigger:) -> "abort@" <> describe_trigger(trigger)
  }
}

fn describe_trigger(trigger: Trigger) -> String {
  case trigger {
    DuringTurn(turn:) -> "turn" <> int.to_string(turn)
    DuringCall(call:) -> "call:" <> call
    AtTerminalCommit -> "terminal"
  }
}

/// The intervention's trigger.
///
/// ## Examples
///
/// ```gleam
/// // script.trigger_of(script.Abort(script.AtTerminalCommit))
/// ```
///
pub fn trigger_of(intervention: Intervention) -> Trigger {
  case intervention {
    Steer(trigger:, ..) | FollowUp(trigger:, ..) | Abort(trigger:) -> trigger
  }
}

// --- generation -----------------------------------------------------------

/// The tool names a generated script may use, with their replay
/// policies. `never` is the interesting one: an interrupted call of it
/// must never be re-executed.
pub const registry = [
  #("read", ReplaySafe),
  #("write", ReplayNever),
  #("probe", ReplaySafe),
]

/// Draws a script. Weights favour shapes that reach the recovery paths
/// the enumerated harness could not: deferred polls, compaction,
/// structural generation, navigation, and interventions that land while
/// an effect is live.
///
/// ## Examples
///
/// ```gleam
/// // let #(script, rng) = script.generate(rng)
/// ```
///
pub fn generate(rng: Rng) -> #(Script, Rng) {
  // A run continues only while its turns keep asking for more, so the
  // shape is: some number of continuing turns, then one that ends it.
  let #(continuing_count, rng) =
    random.weighted(rng, [#(3, 0), #(4, 1), #(2, 2)], 0)
  // At most one deferred turn per script: the poll settlement is one
  // scripted value, so two polls would reuse its call ids and a call id
  // must name exactly one call in the tree.
  let #(defer_at, rng) = random.int_between(rng, 0, continuing_count)
  let #(continuing, rng) = fold_turns(rng, 0, continuing_count, defer_at, [])
  let #(final, rng) = terminal_settle(rng)
  let #(post_tokens, rng) = random.int_between(rng, 1, 9)
  let #(extra_ops, rng) =
    random.weighted(
      rng,
      [
        #(5, []),
        #(2, [CompactOp]),
        #(2, [NavigateOp(summarize: False)]),
        #(3, [NavigateOp(summarize: True)]),
      ],
      [],
    )
  let #(threshold_turns, rng) = random.int_between(rng, 1, 2)
  let #(threshold, rng) =
    random.weighted(rng, [#(6, None), #(4, Some(threshold_turns))], None)
  let #(structural, rng) =
    random.weighted(
      rng,
      [
        #(4, Supplied),
        #(3, Generated(split: False)),
        #(2, Generated(split: True)),
      ],
      Supplied,
    )
  let #(tools, rng) = tool_table(rng)
  let #(interventions, rng) = interventions(rng)
  let #(poll_answer, rng) = poll_settle(rng)
  #(
    Script(
      registry:,
      tools:,
      ops: [
        RunOp(
          prompt: "task",
          settles: list.append(continuing, [final]),
          post: Answer(text: "after compaction", tokens: post_tokens),
        ),
        ..extra_ops
      ],
      threshold_after: threshold,
      structural:,
      interventions:,
      poll_answer:,
    ),
    rng,
  )
}

// The continuing turns, in order: the one at `defer_at` (if any) is the
// deferred turn, the rest are tool batches. Call ids carry their turn, so
// no two calls in a script share an id.
fn fold_turns(
  rng: Rng,
  turn: Int,
  count: Int,
  defer_at: Int,
  acc: List(Settle),
) -> #(List(Settle), Rng) {
  case turn >= count {
    True -> #(list.reverse(acc), rng)
    False ->
      case turn == defer_at {
        True -> fold_turns(rng, turn + 1, count, defer_at, [Defer, ..acc])
        False -> {
          let #(settle, rng) = calls(rng, "t" <> int.to_string(turn))
          fold_turns(rng, turn + 1, count, defer_at, [settle, ..acc])
        }
      }
  }
}

fn calls(rng: Rng, prefix: String) -> #(Settle, Rng) {
  let #(count, rng) = random.int_between(rng, 1, 2)
  let #(names, rng) =
    random.list_of(rng, count, fn(rng) {
      random.pick(rng, ["read", "write", "probe"], "read")
    })
  let #(tokens, rng) = random.int_between(rng, 1, 9)
  let calls =
    list.index_map(names, fn(name, index) {
      Call(id: prefix <> int.to_string(index) <> name, tool: name)
    })
  #(Calls(calls:, tokens:), rng)
}

// A turn that ends the run, one way or another.
fn terminal_settle(rng: Rng) -> #(Settle, Rng) {
  let #(tokens, rng) = random.int_between(rng, 1, 9)
  let #(kind, rng) = random.int_between(rng, 1, 100)
  case kind {
    n if n <= 60 -> #(Answer(text: "answered", tokens:), rng)
    n if n <= 80 -> #(Transient, rng)
    _ -> #(Overflow, rng)
  }
}

// What a deferred poll settles with: an answer that ends the turn, or a
// tool batch that keeps the run going past the poll.
fn poll_settle(rng: Rng) -> #(Settle, Rng) {
  let #(tokens, rng) = random.int_between(rng, 1, 9)
  let #(with_calls, rng) = random.chance(rng, 35)
  case with_calls {
    True -> calls(rng, "poll")
    False -> #(Answer(text: "deferred answer", tokens:), rng)
  }
}

fn tool_table(rng: Rng) -> #(List(#(String, ToolBehavior)), Rng) {
  list.fold(["read", "write", "probe"], #([], rng), fn(acc, name) {
    let #(table, rng) = acc
    let #(errored, rng) = random.chance(rng, 20)
    let behavior = case errored {
      True -> ToolErr(text: "tool " <> name <> " refused")
      False -> ToolOk(text: "out:" <> name)
    }
    #([#(name, behavior), ..table], rng)
  })
}

fn interventions(rng: Rng) -> #(List(Intervention), Rng) {
  let #(count, rng) = random.weighted(rng, [#(4, 0), #(4, 1), #(2, 2)], 0)
  random.list_of(rng, count, intervention)
}

fn intervention(rng: Rng) -> #(Intervention, Rng) {
  let #(trigger, rng) = trigger(rng)
  let #(kind, rng) = random.int_between(rng, 1, 100)
  case kind {
    n if n <= 40 -> #(Steer(trigger:, text: "steered"), rng)
    n if n <= 65 -> #(FollowUp(trigger:, text: "followed up"), rng)
    _ -> #(Abort(trigger:), rng)
  }
}

fn trigger(rng: Rng) -> #(Trigger, Rng) {
  let #(turn, rng) = random.int_between(rng, 0, 2)
  let #(index, rng) = random.int_between(rng, 0, 1)
  let #(name, rng) = random.pick(rng, ["read", "write", "probe"], "read")
  let #(kind, rng) = random.int_between(rng, 1, 100)
  case kind {
    n if n <= 45 -> #(DuringTurn(turn:), rng)
    n if n <= 72 -> #(
      DuringCall(
        call: "t" <> int.to_string(turn) <> int.to_string(index) <> name,
      ),
      rng,
    )
    _ -> #(AtTerminalCommit, rng)
  }
}
