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
////
//// # The other half: what an approval relaxed
////
//// A report of the layers a kernel applied answers "what confined this",
//// but only against the policy that was composed. An execution re-run
//// under an approved escalation composed a *wider* policy than the one
//// its session base would have given it, and an operator reading the
//// record has to be able to see that — a widening nobody can find in the
//// record is a widening nobody reviews.
////
//// `Widening` is that fact, and it is deliberately a peer of
//// `Enforcement` rather than a field inside it. `Reported.entries` is the
//// helper's ground truth, verbatim; folding a harness-side decision into
//// that list would put a claim about what Loom did where a reader expects
//// a claim about what the kernel did, which is the exact confusion the
//// applied/skipped split exists to prevent. Two facts, side by side on
//// `codemode.Execution`: what the kernel enforced, and what an approval
//// relaxed before it was asked to.

import broker/broker
import broker/exec.{type ExecResult}
import broker/policy.{type Grant}
import gleam/int
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

/// What an approved escalation widened about one execution, or why it
/// widened nothing.
///
/// Two states and no third: either a set of grants composed into the
/// policy some stage of this execution actually ran under, or they did
/// not, with the reason said out loud. There is no silence for a reader
/// to fill in, which is the same discipline `Report` keeps about a stage
/// that made no report.
pub type Widening {
  /// Nothing about this execution was widened. `reason` distinguishes the
  /// two ways that happens — no approval was attributed to it at all, or
  /// one was and no stage ever reached the point of composing it — because
  /// an operator reviewing an approval needs to know whether it was spent.
  NotWidened(reason: String)

  /// The run phase composed these grants: the satellite node's own
  /// clearance and every capability call the program made were cleared
  /// under `base ⊕ requirements ⊕ grants` rather than under the meet
  /// alone.
  ///
  /// The hermetic build is never among them — `codemode/identity` drops
  /// the grants when it derives the build phase — so this is always a
  /// statement about the program's execution and never about the build
  /// that produced it.
  Widened(grants: List(Grant))
}

/// The widening a phase that ran composed, from the grants it carried.
///
/// An empty list is `NotWidened`, not `Widened([])`: claiming a widening
/// over no grants would put a line in the record for every ordinary
/// execution and teach a reader to skip it.
///
/// ## Examples
///
/// ```gleam
/// // enforcement.widened(by: []) == enforcement.NotWidened(reason: "...")
/// ```
///
pub fn widened(by grants: List(Grant)) -> Widening {
  case grants {
    [] -> NotWidened(reason: nothing_attributed)
    _granted -> Widened(grants:)
  }
}

/// The widening an execution carried but never got to spend: grants were
/// attributed to it, and it settled before any stage composed them.
///
/// `because` is a clause naming what settled it, so the record reads as
/// one sentence. Carrying nothing reads exactly like any other unwidened
/// execution — there is no approval whose fate a reader would be chasing.
///
/// ## Examples
///
/// ```gleam
/// // enforcement.unspent(carrying: grants, because: "the program did not compile")
/// ```
///
pub fn unspent(
  carrying grants: List(Grant),
  because reason: String,
) -> Widening {
  case grants {
    [] -> NotWidened(reason: nothing_attributed)
    _granted ->
      NotWidened(
        reason: "an approved escalation was attributed to this execution, but "
        <> reason,
      )
  }
}

// Said the same way wherever it is true, so the two paths that reach it
// cannot drift into two different sentences for one fact.
const nothing_attributed = "no approved escalation was attributed to this execution"

/// One grant as a short line an operator can read: what it widened, and
/// to what.
///
/// Rendering lives beside the report rather than in `broker/policy`
/// because a `Grant` is an instruction to a composer, and what a person
/// needs from it here is a diff line. Kept total and kept small — every
/// variant renders, so a new one cannot go unmentioned in a record.
///
/// ## Examples
///
/// ```gleam
/// assert enforcement.grant_label(policy.GrantEnv(name: "CC")) == "env=CC"
/// ```
///
pub fn grant_label(grant: Grant) -> String {
  case grant {
    policy.GrantWritableRoot(path:) -> "writable-root=" <> path
    policy.GrantReadableRoot(path:) -> "readable-root=" <> path
    policy.GrantNetwork(network:) -> "network=" <> network_label(network)
    policy.GrantEnv(name:) -> "env=" <> name
    policy.GrantLimit(field:, value:) ->
      "limit:" <> limit_label(field) <> "=" <> int.to_string(value)
    policy.GrantScratch(scratch: policy.ScratchTmpfs) -> "scratch=tmpfs"
    policy.GrantScratch(scratch: policy.ScratchPath(path:)) ->
      "scratch=" <> path
  }
}

fn network_label(network: policy.NetworkPolicy) -> String {
  case network {
    policy.NetworkOff -> "off"
    policy.NetworkFull -> "full"
    policy.NetworkProxy(allow:, proxy: _) ->
      "proxy(" <> string.join(allow, ",") <> ")"
  }
}

fn limit_label(field: policy.LimitField) -> String {
  case field {
    policy.CpuSeconds -> "cpu_s"
    policy.WallSeconds -> "wall_s"
    policy.MemBytes -> "mem_bytes"
    policy.Pids -> "pids"
    policy.FsizeBytes -> "fsize_bytes"
    policy.OutputBytes -> "output_bytes"
  }
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
