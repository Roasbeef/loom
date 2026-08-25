//// What the running kernel actually enforced on a code-mode execution's
//// two jailed stages — the hermetic build and the satellite node.
////
//// A jail is only as strong as the kernel under it, so every stage that
//// runs reports the layers the helper really applied (`exec_exit`'s
//// `enforcement` list, the broker's ground truth), and every stage that
//// does not run says why. Those are the only two states: there is no
//// silence to misread as confinement.
////
//// # Why this is a return value rather than a callback
////
//// The report used to travel as a side-channel — a `fn(entries, degraded)`
//// the build and the launcher called when their execution settled — and
//// the satellite's arrived, if at all, after `destroy` had already aborted
//// the operation and the host had already reported its outcome. A healthy
//// run therefore reported the build's layers and *nothing* for the node,
//// which the tool had to render as "a stage that made no report", making
//// the strongest claim the sandbox has depend on winning a race
//// (spec-gaps WP-J 14, issue #5).
////
//// So the report is a value threaded back out of every stage instead:
//// `compile.Compiled` carries the build's, `satellite.Run` carries the
//// node's, and `codemode.Execution` carries both. Nothing can produce an
//// outcome without also producing the two reports, which is what makes
//// honest reporting structural rather than probable.

import broker/broker
import broker/exec.{type ExecResult}
import gleam/list
import gleam/string
import tools/tool

/// What one jailed stage's helper reported about the layers it actually
/// applied — or why no such report exists. `Unreported` is never a claim
/// that the stage was confined.
pub type Report {
  /// The helper's ground truth. `entries` is `exec_exit`'s enforcement
  /// list verbatim, so a layer the policy called for but the kernel could
  /// not provide appears as its own `skip:` entry rather than going
  /// unmentioned.
  Reported(entries: List(String), degraded: Bool)
  /// No report exists for this stage, and this is why: it was never
  /// dispatched, it died before the helper could report, or its
  /// settlement never arrived.
  Unreported(reason: String)
}

/// Both jailed stages of one execution. A record rather than a list so
/// that neither stage can go unmentioned: naming one and omitting the
/// other is exactly the failure this type exists to prevent.
pub type Enforcement {
  Enforcement(build: Report, node: Report)
}

/// The report a settled clearance carries.
///
/// `CallExited` carries the helper's ground truth, and so does the one
/// failure that is *about* enforcement: a `FullEnforcement` demand
/// refusing a degraded result attaches the very list it refused, and
/// dropping it would report nothing for precisely the run that most needs
/// saying out loud. Every other failure is a stage that died before its
/// helper reported anything.
///
/// ## Examples
///
/// Every reason here is a stage-free clause — "it was refused before it
/// ran" — because every renderer names the stage itself; a reason that
/// named it again would read twice.
///
/// ## Examples
///
/// ```gleam
/// // enforcement.of_call(broker.CallExited(result:))
/// //   == enforcement.Reported(entries: result.enforcement, degraded: ...)
/// ```
///
pub fn of_call(outcome: broker.CallOutcome) -> Report {
  case outcome {
    broker.CallExited(result:) -> of_result(result)
    broker.CallFailed(failure: exec.DegradedExecution(result:)) ->
      of_result(result)
    broker.CallFailed(failure:) ->
      Unreported(
        "it did not settle with an exec_exit: "
        <> tool.exec_failure_text(failure),
      )
  }
}

/// The report an `exec_exit` carries, with the broker's own degraded rule
/// applied: any `skip:` entry means a layer the policy called for was not
/// applied, which is a degraded run whether or not the helper's bool says
/// so (the bool tracks only the bwrap layer).
///
/// ## Examples
///
/// ```gleam
/// // enforcement.of_result(result).degraded
/// //   == result.degraded || has_a_skip(result.enforcement)
/// ```
///
pub fn of_result(result: ExecResult) -> Report {
  Reported(
    entries: result.enforcement,
    degraded: result.degraded || list.any(result.enforcement, is_skip),
  )
}

/// The layers a report says were applied, and the ones it says were
/// skipped, separated — so a skipped layer can never be rendered as an
/// enforced one. `Unreported` has neither.
///
/// ## Examples
///
/// ```gleam
/// // enforcement.layers(enforcement.Reported(["bwrap", "skip:landlock: x"], True))
/// //   == #(["bwrap"], ["landlock: x"])
/// ```
///
pub fn layers(report: Report) -> #(List(String), List(String)) {
  case report {
    Unreported(reason: _) -> #([], [])
    Reported(entries:, degraded: _) -> #(
      list.filter(entries, fn(entry) { !is_skip(entry) }),
      list.filter_map(entries, fn(entry) {
        case is_skip(entry) {
          True -> Ok(string.drop_start(entry, string.length(skip_prefix)))
          False -> Error(Nil)
        }
      }),
    )
  }
}

/// The prefix the helper puts on a layer it did not apply
/// (`packages/sandbox/internal/jail/run.go`, `skip:` + the reason).
pub const skip_prefix = "skip:"

fn is_skip(entry: String) -> Bool {
  string.starts_with(entry, skip_prefix)
}
