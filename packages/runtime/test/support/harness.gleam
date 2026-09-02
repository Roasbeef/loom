//// The interleave harness: run a scenario to completion, optionally
//// killing the session tree after its N-th commit, and report a
//// structural fingerprint of what the session converged to.
////
//// The crash scheduler is the writer's `after_commit` seam: the armed
//// recorder counts every commit made after arming and the chosen one
//// kills the writer *before the committer observes the commit* — the
//// exact "crash between TX_n and TX_{n+1}" state. The rest-for-one
//// supervisor then reboots the tree and recovery drives the same
//// scripted effects to completion.
////
//// Fingerprints are structural (roles, texts, call ids, stop kinds) —
//// never minted ids or timestamps, which legitimately differ between
//// runs of the same scenario.

import core/clock
import core/entry
import core/ids
import core/message.{
  type AgentMessage, AssistantMessage, AssistantText, AssistantThinking,
  AssistantToolCall, CustomMessage, ToolResultImage, ToolResultMessage,
  ToolResultText, UserImage, UserMessage, UserText,
}
import core/register
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import machine/operation.{type LastResult, type ReplayPolicy}
import machine/strand.{ModelIdentity, StrandConfiguration, ThinkingOff}
import runtime/api
import runtime/effects
import runtime/supervisor
import session/session.{type Session}
import storage/storage
import support/fake
import support/recorder
import weft
import weft/poll

/// One interleave scenario.
pub type Scenario {
  Scenario(
    name: String,
    /// Tool registry: name to replay policy.
    registry: List(#(String, ReplayPolicy)),
    /// The provider script (also sees the recorder for conditionals).
    provider: fn(Subject(recorder.Message), effects.RequestSpec) ->
      fake.ProviderResult,
    /// The tool script.
    tool: fn(Subject(recorder.Message), effects.ToolRun) -> fake.ToolResult,
    /// The run's prompt messages.
    prompt: List(AgentMessage),
    /// A steer admitted (quietly) after acceptance, before driving.
    steer: Option(AgentMessage),
    /// When present, the harness pumps abort requests whenever the
    /// condition holds until the run terminates.
    abort_when: Option(fn(Subject(recorder.Message)) -> Bool),
  )
}

/// What one scenario run converged to.
pub type Report {
  Report(
    outcome: LastResult,
    /// Fingerprint lines of the final projected context.
    projection: List(String),
    /// Ledger total tokens.
    usage_total: Int,
    /// Commits counted from arming (the crash-boundary count `C`).
    commits: Int,
    rec: Subject(recorder.Message),
  )
}

/// The strand configuration scenarios run under.
pub fn configuration() -> strand.StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: ThinkingOff,
    active_tool_names: ["read", "write", "slow"],
  )
}

/// Runs a scenario over a fresh memory session, killing the tree after
/// armed commit `kill_at` (0 = never). Panics if the scenario does not
/// converge — non-convergence is the failure the harness exists to catch.
///
/// A run whose numbering drifted is discarded and started over on a fresh
/// session; `attempts` bounds that. See `attempt_run`.
pub fn run(scenario: Scenario, kill_at: Int) -> Report {
  attempt_run(scenario, kill_at, attempts: 5)
}

fn attempt_run(
  scenario: Scenario,
  kill_at: Int,
  attempts attempts: Int,
) -> Report {
  let rec = recorder.start()
  let assert Ok(sess) =
    session.open_memory(clock.stepping(from: 1_000_000, by: 7))
    as "the memory session must open"
  let eff =
    fake.effects(
      rec,
      clock.stepping(from: 2_000_000, by: 25),
      scenario.registry,
      fn(spec) { scenario.provider(rec, spec) },
      fn(tool_run) { scenario.tool(rec, tool_run) },
    )
  let base = api.default_options(configuration())
  let options =
    api.Options(
      ..base,
      retry_policy: operation.NormalizedRetryPolicy(
        max_attempts: 3,
        base_delay_ms: 30,
      ),
      poll_interval_ms: 250,
      tolerance: supervisor.Tolerance(intensity: 10_000, period: 10),
      after_commit: fn(_) {
        case recorder.on_commit(rec) {
          // Crash between this commit and the next: the commit is
          // durable, the committer never learns it succeeded.
          True -> process.kill(process.self())
          False -> Nil
        }
      },
    )
  let assert Ok(rt) = api.open(sess, eff, options)
    as "the session tree must boot"

  case open_run(rt, scenario, rec, kill_at) {
    Ready(op:) -> drive_run(rt, sess, op, scenario, rec, kill_at)

    // This session's opening is not the scenario's, and no arithmetic can
    // put it back: the boundaries the crash is counted from are already
    // spent, or the run is already past the point the steer belongs at.
    // Drop the tree and start over on a fresh one.
    Spoiled(why:) -> {
      process.kill(rt.tree.supervisor)
      case attempts > 1 {
        True -> attempt_run(scenario, kill_at, attempts: attempts - 1)
        False ->
          panic as {
            "the " <> scenario.name <> " opening kept drifting: " <> why
          }
      }
    }
  }
}

/// Whether an attempt's opening is the one its scenario describes.
type Opening {
  /// The admissions landed with nothing of the run committed beside them,
  /// so the next commit is boundary one and the run may proceed.
  Ready(
    /// The accepted run's operation.
    op: ids.OpId,
  )

  /// A drive got in among the admissions. Not an error in the runtime and
  /// not something to crash on — just a session this scenario can no
  /// longer be told from.
  Spoiled(
    /// What the harness saw, for the message it gives up with.
    why: String,
  )
}

// The admissions go first and the bomb is armed behind them, which is what
// keeps the test's own writes out of the run. Arming ahead of them and
// skipping a count could not: the recorder saw commits, not committers, so
// a drive that landed between acceptance and steer ate a skip, the steer
// became boundary one, and the bomb went off inside the very call that was
// admitting it. That is both macOS reds this harness has produced — a
// steer admission that failed, and a projection that diverged because the
// crash landed on the wrong side of the steer.
//
// Acceptance itself cannot be spoiled: the strand is idle and has no
// operation, so there is nothing for a drive to commit before it.
fn open_run(
  rt: api.Runtime,
  scenario: Scenario,
  rec: Subject(recorder.Message),
  kill_at: Int,
) -> Opening {
  let assert Ok(op) = api.accept_quietly(rt, scenario.prompt)
    as "acceptance must succeed on an idle strand"
  let admissions = case scenario.steer {
    Some(_) -> 2
    None -> 1
  }
  case admit_steer(rt, scenario) {
    Error(why) -> Spoiled(why:)
    Ok(Nil) ->
      case recorder.arm(rec, at: kill_at, after: admissions) {
        recorder.Clean -> Ready(op:)
        recorder.Drifted(boundaries:) ->
          Spoiled(
            why: int.to_string(boundaries)
            <> " boundaries were committed during the admissions",
          )
      }
  }
}

// A steer is admitted onto an *open* run, so a drive that got ahead of this
// call can close the window by finishing the turn the scenario steers into.
// The refusal is the runtime behaving correctly about a run that is no
// longer the scenario's.
fn admit_steer(rt: api.Runtime, scenario: Scenario) -> Result(Nil, String) {
  case scenario.steer {
    None -> Ok(Nil)
    Some(message) ->
      case api.steer_quietly(rt, message) {
        Ok(_entry) -> Ok(Nil)
        Error(_reason) -> Error("the run closed before the steer was admitted")
      }
  }
}

// The run proper, once its numbering is known to start where the scenario
// says it does.
fn drive_run(
  rt: api.Runtime,
  sess: Session,
  op: ids.OpId,
  scenario: Scenario,
  rec: Subject(recorder.Message),
  kill_at: Int,
) -> Report {
  api.nudge(rt)

  // The pump is started before the wait and stopped before the tree, so no
  // abort request can outlive the runtime it addresses.
  let pump = start_abort_pump(rt, scenario, rec)
  let outcome = wait_terminal(sess, op)
  stop_abort_pump(pump)

  // A run armed to crash must actually have crashed: a bomb that never
  // fired would make the interleave loop vacuous.
  case kill_at > 0 {
    True ->
      case recorder.fired(rec) {
        True -> Nil
        False -> panic as "the armed crash bomb never fired"
      }
    False -> Nil
  }
  let commits = recorder.commit_count(rec)
  let projection = final_projection(sess)
  let usage_total = ledger_total(sess)
  assert_placement_invariants(sess)
  process.kill(rt.tree.supervisor)
  Report(outcome:, projection:, usage_total:, commits:, rec:)
}

// The budget is wall-clock, which is the whole reason this is a `weft/poll`
// and not a sleep-and-recurse. The loop it replaced subtracted its own
// nominal sleep from a counter, so twenty thousand meant twenty thousand
// sleeps of ten milliseconds plus every storage read and every scheduling
// delay between them; on a loaded two-core runner that stretched past
// eunit's own per-test timeout, which then reported the stack of whichever
// poll it interrupted instead of this function's diagnosis. A wedged run
// now says so itself.
fn wait_terminal(sess: Session, op: ids.OpId) -> LastResult {
  let settled =
    poll.until(within: 20_000, every: 10, attempt: fn() {
      case session.last_result(sess, "main") {
        Ok(Some(session.Cell(value: last, ..))) ->
          case last_operation(last) == op {
            True -> poll.Done(last)
            False -> poll.Retry
          }

        // No terminal result yet, or a read that raced a restart: both are
        // ordinary mid-run states, and the budget is what ends the wait.
        Ok(None) -> poll.Retry
        Error(_reason) -> poll.Retry
      }
    })
  case settled {
    poll.Answered(last) -> last
    poll.Expired -> panic as "the scenario did not converge to a terminal result"

    // The probe never reports `Fail`; the arm is exhaustiveness.
    poll.Failed(Nil) ->
      panic as "the scenario did not converge to a terminal result"
  }
}

// One pump process for the whole wait, when the scenario asks for aborts at
// all. The abort itself still runs in a disposable process — a request made
// through a mid-restart strand panics, and that must not kill the pump any
// more than it may kill the test — but it is a weft task, joined before the
// tick returns, rather than a fresh unlinked process every ten milliseconds
// that nothing ever reaps. Those outlived `run`, and the storm of exit
// reports they raised against a tree the harness had already killed is what
// buried the real diagnosis in the CI log.
fn start_abort_pump(
  rt: api.Runtime,
  scenario: Scenario,
  rec: Subject(recorder.Message),
) -> Option(process.Pid) {
  case scenario.abort_when {
    None -> None
    Some(condition) ->
      Some(process.spawn_unlinked(fn() { pump_aborts(rt, condition, rec) }))
  }
}

fn pump_aborts(
  rt: api.Runtime,
  condition: fn(Subject(recorder.Message)) -> Bool,
  rec: Subject(recorder.Message),
) -> Nil {
  case condition(rec) {
    True -> {
      let _outcomes =
        weft.new([fn() { Ok(api.abort(rt)) }])
        |> weft.start
      Nil
    }
    False -> Nil
  }
  process.sleep(10)
  pump_aborts(rt, condition, rec)
}

// Asked to stop before the tree is killed, so the last request it made is
// against a runtime that was still there to receive it.
fn stop_abort_pump(pump: Option(process.Pid)) -> Nil {
  case pump {
    None -> Nil
    Some(pid) -> process.kill(pid)
  }
}

fn last_operation(last: LastResult) -> ids.OpId {
  case last {
    operation.RunLastResult(operation: op, ..) -> op
    operation.CompactionLastResult(operation: op, ..) -> op
    operation.NavigationLastResult(operation: op, ..) -> op
  }
}

// --- reporting ------------------------------------------------------------

/// The fingerprint of the final projected context from the strand's leaf.
pub fn final_projection(sess: Session) -> List(String) {
  let leaf = case session.strand_leaf(sess, "main") {
    Ok(Some(session.Cell(value: leaf, ..))) -> leaf
    _ -> None
  }
  let assert Ok(messages) = session.project_context(sess, leaf)
    as "the final projection must read cleanly"
  list.map(messages, fingerprint)
}

/// One message's structural fingerprint.
pub fn fingerprint(message: AgentMessage) -> String {
  case message {
    UserMessage(content:, ..) ->
      "user:"
      <> string.join(
        list.map(content, fn(block) {
          case block {
            UserText(text:, ..) -> text
            UserImage(..) -> "<image>"
          }
        }),
        "|",
      )
    AssistantMessage(content:, stop_reason:, ..) ->
      "assistant:"
      <> stop_tag(stop_reason)
      <> ":"
      <> string.join(
        list.map(content, fn(block) {
          case block {
            AssistantText(text:, ..) -> text
            AssistantThinking(..) -> "<thinking>"
            AssistantToolCall(call:) -> "call(" <> call.id <> ")" <> call.name
          }
        }),
        "|",
      )
    ToolResultMessage(tool_name:, tool_call_id:, content:, is_error:, ..) ->
      "tool:"
      <> tool_name
      <> ":"
      <> tool_call_id
      <> ":"
      <> case is_error {
        True -> "err"
        False -> "ok"
      }
      <> ":"
      <> string.join(
        list.map(content, fn(block) {
          case block {
            ToolResultText(text:, ..) -> text
            ToolResultImage(..) -> "<image>"
          }
        }),
        "|",
      )
    CustomMessage(schema:, ..) -> "custom:" <> schema
  }
}

fn stop_tag(stop: message.StopReason) -> String {
  case stop {
    message.Pending -> "pending"
    message.Stop -> "stop"
    message.Length -> "length"
    message.ToolUse -> "tool_use"
    message.Errored -> "error"
    message.Aborted -> "aborted"
    message.Deferred -> "deferred"
  }
}

/// The ledger's total token count.
pub fn ledger_total(sess: Session) -> Int {
  let assert Ok(rows) = storage.scan_usage(sess.store, storage.usage_scan())
    as "the ledger must read cleanly"
  list.fold(rows, 0, fn(total, row) { total + row.usage.total_tokens })
}

/// The placement invariant at a terminal boundary: no operation-owned or
/// pending registers survive, the strand is idle, and every tool call in
/// the tree has exactly one result entry.
pub fn assert_placement_invariants(sess: Session) -> Nil {
  assert_empty_ns(sess, register.OpMeta)
  assert_empty_ns(sess, register.OpState)
  assert_empty_ns(sess, register.OpToolArgs)
  assert_empty_ns(sess, register.OpPreparation)
  assert_empty_ns(sess, register.PendingEntry)
  let assert Ok(Some(session.Cell(value: strand_state, ..))) =
    session.strand_state(sess, "main")
    as "the strand state must exist at a terminal boundary"
  assert strand_state.current_operation == None
  assert_calls_answered(sess)
}

fn assert_empty_ns(sess: Session, ns: register.RegisterNs) -> Nil {
  let assert Ok(cells) = storage.list_registers(sess.store, ns, None)
    as "register listings must read cleanly"
  assert cells == []
  Nil
}

// Every tool call block in an assistant entry has a matching tool-result
// entry ("every tool call has a result" — pi invariant).
fn assert_calls_answered(sess: Session) -> Nil {
  let assert Ok(entries) =
    storage.scan_entries(sess.store, storage.entry_scan())
    as "the entry inventory must read cleanly"
  let messages =
    list.filter_map(entries, fn(row) {
      case row {
        entry.MessageEntry(message:, ..) -> Ok(message)
        _ -> Error(Nil)
      }
    })
  let answered =
    list.filter_map(messages, fn(message) {
      case message {
        ToolResultMessage(tool_call_id:, ..) -> Ok(tool_call_id)
        _ -> Error(Nil)
      }
    })
  let called =
    list.flat_map(messages, fn(message) {
      case message {
        AssistantMessage(content:, ..) ->
          list.filter_map(content, fn(block) {
            case block {
              AssistantToolCall(call:) -> Ok(call.id)
              _ -> Error(Nil)
            }
          })
        _ -> []
      }
    })
  list.each(called, fn(id) {
    case list.contains(answered, id) {
      True -> Nil
      False -> panic as { "tool call " <> id <> " has no result entry" }
    }
  })
}

/// Whether two projections match, allowing a crashed run's tool-result
/// line to be the synthetic interruption for the same call — the one
/// legitimate transcript divergence commit-boundary crashes can produce
/// for `replay: Never` tools.
pub fn converged_with_tool_allowance(
  base: List(String),
  crashed: List(String),
) -> Bool {
  case base, crashed {
    [], [] -> True
    [b, ..base_rest], [c, ..crashed_rest] ->
      case b == c || interrupted_variant(b, c) {
        True -> converged_with_tool_allowance(base_rest, crashed_rest)
        False -> False
      }
    _, _ -> False
  }
}

// Same tool and call id, but the crashed line is an error result (the
// synthetic interruption) where the base line is the scripted result.
fn interrupted_variant(base: String, crashed: String) -> Bool {
  case string.split(base, ":"), string.split(crashed, ":") {
    ["tool", name_b, id_b, ..], ["tool", name_c, id_c, "err", ..] ->
      name_b == name_c && id_b == id_c
    _, _ -> False
  }
}

/// Runs the whole interleave loop for a scenario: the uninterrupted run
/// fixes the commit count `C`, then every `k` in `1..C` runs fresh, is
/// killed after commit `k`, and must satisfy `check(base, crashed)`.
pub fn interleave(
  scenario: Scenario,
  check: fn(Report, Report, Int) -> Nil,
) -> Report {
  let base = run(scenario, 0)
  assert base.commits > 0
  int.range(from: 1, to: base.commits + 1, with: Nil, run: fn(_, k) {
    let crashed = run(scenario, k)
    check(base, crashed, k)
  })
  base
}

/// A run-completed outcome's shape check.
pub fn assert_completed(outcome: LastResult) -> Nil {
  case outcome {
    operation.RunLastResult(outcome: operation.RunCompleted(..), ..) -> Nil
    _ -> panic as "expected a completed run outcome"
  }
}

/// A run-aborted outcome's shape check.
pub fn assert_aborted(outcome: LastResult) -> Nil {
  case outcome {
    operation.RunLastResult(outcome: operation.RunAborted, ..) -> Nil
    _ -> panic as "expected an aborted run outcome"
  }
}

/// Formats a scenario/k context for assertion messages.
pub fn context(name: String, k: Int) -> String {
  name <> " (killed after commit " <> int.to_string(k) <> ")"
}
