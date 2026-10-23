//// The one seam between evolution's authority and the machine that runs it.
////
//// Evolution splits into two halves. The authority half decides what may run:
//// the candidate catalogue, approval, selection and its generation fence, the
//// evidence records, the live owner's bookkeeping, and the hook and tool fold.
//// The execution half does the work that needs the workspace's machine:
//// reading a candidate's source, compiling it, running its author tests,
//// starting its satellite, and running a selected program. Today both halves
//// are in one VM, so nothing marks the boundary. This module marks it. The
//// authority half calls a `Machine` for everything in the second list and
//// never calls the compiler, a broker or a satellite itself, so it cannot
//// depend on where those are.
////
//// ## What a machine does
////
//// A `Machine` is a record of five functions. None of them holds the
//// catalogue. The caller passes it to each call that needs it, because the
//// catalogue is the approval authority and stays with the orchestrator
//// whichever machine runs the work. That also lets a machine be built before
//// the catalogue exists, which matters because the catalogue is opened with
//// the identity the machine reports.
////
//// - `identity` reports the toolchain, seed and seam that compile candidates.
////   The catalogue stamps this into every envelope, so evidence recorded under
////   one machine does not authorize a build on another.
//// - `snapshot` captures a candidate's source from a directory of the
////   workspace.
//// - `evaluate` runs a candidate's author tests and answers an
////   `evaluate.Report`, a verdict and its observation. It writes nothing: the
////   caller records the report with `evaluate.record` under its own catalogue.
//// - `stage` builds one approved selection into a `live.Generation` and
////   starts it.
//// - `run_program` runs a selected program once and answers the
////   `tool.ToolOutcome` its caller returns to the model.
////
//// `evaluate` and `run_program` answer plain data: a report and a tool outcome
//// hold no closure, no process and no catalogue handle. The verdict and outcome
//// mappings run beside the check, wherever the machine runs, and cross the seam
//// as values; the evidence write happens on the orchestrator's side whichever
//// machine did the work.
////
//// ## What a generation already carries
////
//// The operations a live generation serves are not separate machine
//// functions. `stage` returns a `live.Generation`, whose `tools` run an
//// invocation, whose `hooks` bus delivers promoted hook events, whose
//// `inventory` reports the helper census, whose `mode` holds a stateful
//// migration's `prepare`, and whose `retire` stops it. The live owner and the
//// hook fold call those fields as they always did. A machine that stages
//// remotely returns a generation whose fields are built over messages, and
//// nothing above the seam changes. That is why `Machine` has no `invoke`,
//// `retire` or hook function.
////
//// ## Who builds one
////
//// `machine/local` builds the machine for a workspace in this VM. It is the
//// code that was `evolution/native`, moved without rewriting. `serve` chooses
//// which machine a session holds when it assembles the session. Everything
//// below `serve` receives a `Machine` and cannot tell which kind it is.
////
//// ## What stays outside the seam
////
//// Prompt-profile trials (`serve.evolution_compare`, `rollout_host`) open a
//// whole fresh session from the source session's settings. That needs the
//// session assembly in `serve`, which a record of functions over a catalogue
//// cannot stand in for, so a trial is not a `Machine` operation yet. The
//// reviewed core upgrade already has its own seam, `evolution/control.Seam`,
//// over `upgrade/control`, and that seam is unchanged. The effect plane a
//// local machine starts for each check (`serve.evolution_plane`) is passed to
//// `machine/local` as its `open` function, because the plane is shared with
//// the session's other planes.
////
//// ## What the remote machine will add
////
//// A later change adds `machine/remote`, a `Machine` whose functions send
//// protocol-change/098's messages to the executor that holds the workspace.
//// It reads `identity` from the executor's census, sends `snapshot` and
//// `evaluate` as `EvolutionSnapshot` and `EvolutionEvaluate`, and stages by
//// `EvolutionStage`, which answers the handle and declarations a returned
//// `live.Generation` is built from. It will narrow the `tool.Ctx` argument of
//// `snapshot`, `evaluate` and `run_program` to the plain coordinates the wire
//// can carry. This module adds none of that: the local machine needs no wire
//// vocabulary, and a field only the remote side would use does not belong
//// here yet.

import client/evolution/evaluate
import client/evolution/live
import client/evolution/record
import client/evolution/store
import client/extension/archive
import core/json
import tools/tool

/// The operations evolution needs from the machine that holds a workspace.
///
/// Every function that can read or change the catalogue takes it as its first
/// argument, so a machine holds no approval state of its own.
pub type Machine {
  Machine(
    /// The compile identity this machine builds under, or the reason it
    /// cannot say. The catalogue is opened with this value.
    identity: fn() -> Result(record.Identity, String),
    /// Captures the source of `directory` as a bounded archive, using the
    /// caller's current masks. The directory is named in the workspace's own
    /// terms and is resolved by the machine, not by the orchestrator.
    snapshot: fn(tool.Ctx, String) -> Result(archive.Tree, store.Refusal),
    /// Runs one candidate's author tests behind the machine's jail and
    /// answers the report. The machine's executor is retired before the
    /// report is answered, and nothing is recorded: the caller writes the
    /// evidence with `evaluate.record`. An extension or program candidate
    /// only; a prompt candidate is compared by rollout instead.
    evaluate: fn(store.Store, tool.Ctx, record.CandidateId) ->
      Result(evaluate.Report, store.Refusal),
    /// Builds and starts an approved selection. The caller owns the returned
    /// generation's `retire` from the moment this returns `Ok`. On `Error` the
    /// machine has already retired whatever it started, or the refusal is
    /// `CleanupUnconfirmed` carrying the retry.
    stage: fn(store.Store, record.Selection) ->
      Result(live.Generation, store.Refusal),
    /// Runs the exact program the selection names, once, with the caller's
    /// input, and answers the outcome the caller returns to the model
    /// (`program.outcome`). The program's plane retires before this returns.
    run_program: fn(store.Store, record.Selection, tool.Ctx, json.JsonValue) ->
      Result(tool.ToolOutcome, store.Refusal),
  )
}
