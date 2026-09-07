//// The translation between the background-jobs door and the two
//// model-facing surfaces built over it.
////
//// `client/jobseam.Door` speaks `client/jobs`' vocabulary, which is the
//// harness's: opaque `JobId`s, `client/jobstate.JobState`, the actor's
//// own refusals. `tools/job` speaks the model's: id strings, a lifecycle
//// restated in `tools`' terms, refusal codes a `job_poll` result carries
//// and a `cap/job` program branches on. Neither package may depend on
//// the other — `tools` may reach only `core` and `broker` — so something
//// has to sit between them, and this is it.
////
//// It is the same arrangement `client/scheduleseam` reaches by the
//// opposite route. That door was written directly in `tools/schedule`'s
//// vocabulary, so its translation is nothing; this one was written in
//// the actor's, because WP2 had to name the actor's states before a tool
//// surface existed to name them for. The cost is this module, and what
//// it buys is that the actor's state space and the model's wording can
//// each change without dragging the other with it.
////
//// ## Two callers, one translation
////
//// Both surfaces land here. `seam` is the `job_*` tools' filling, keyed
//// on a `tools/tool.Ctx` because a tool call has one. `capability_door`
//// is the code-mode router's, keyed on the strand and the operation the
//// execution belongs to, because a capability call has no `Ctx`. They
//// differ in nothing else: a job started by a program and one started by
//// a tool call are the same record with the same owner, and either
//// surface polls or kills what the other started.
////
//// ## Where the identities come from, and why the operation travels
////
//// A job clears under `{op_id, "job/" <> id}` — the operation that
//// started it, and a synthetic step naming the job (ADR-005's addendum).
//// The operation is what `broker.abort` addresses, so it decides whether
//// an operator's abort reaches a running job, and it therefore has to be
//// the *caller's real operation* rather than anything invented here.
//// That is why both entry points take one and neither derives one.
////
//// Ownership is the strand and nothing else. Both entry points bind it
//// from the caller rather than from an argument, so no tool call and no
//// program can name the strand its authority comes from.

import client/jobs
import client/jobseam
import client/jobstate
import codemode/workspace
import core/ids.{type OpId}
import gleam/list
import gleam/result
import tools/job
import tools/tool.{type Ctx}

/// The `job_*` tools' seam over one door.
///
/// ## Examples
///
/// ```gleam
/// // jobtools.seam(jobseam.door(wiring))
/// ```
///
pub fn seam(door: jobseam.Door) -> job.Jobs {
  job.Jobs(
    start: fn(ctx: Ctx, command, wall_ms) {
      door.start(ctx.strand, ctx.op_id, command, wall_ms)
      |> translate(started)
    },
    poll: fn(ctx: Ctx, id, wait_ms, cursors) {
      door.poll(ctx.strand, id, wait_ms, seam_cursors(cursors))
      |> translate(polled)
    },
    list: fn(ctx: Ctx) {
      door.list(ctx.strand)
      |> translate(list.map(_, listed))
    },
    kill: fn(ctx: Ctx, id) { door.kill(ctx.strand, id) |> translate(nothing) },
    send: fn(ctx: Ctx, id, data, end) {
      door.send(ctx.strand, id, data, seam_end(end))
      |> translate(nothing)
    },
    max_wait_ms: jobseam.max_wait_ms,
  )
}

/// The five closures the code-mode workspace router calls, bound to one
/// execution's strand and operation.
///
/// The strand is bound here and never travels over the capability
/// channel, exactly as a schedule's owner is: a program reaches the jobs
/// its own strand owns and nothing else, whatever it writes in an
/// argument.
///
/// ## Examples
///
/// ```gleam
/// // jobtools.capability_door(door, strand: "main", operation: op_id)
/// ```
///
pub fn capability_door(
  door: jobseam.Door,
  strand strand: String,
  operation operation: OpId,
) -> workspace.JobDoor {
  workspace.JobDoor(
    start: fn(command, wall_ms) {
      door.start(strand, operation, command, wall_ms)
      |> translate(started)
    },
    poll: fn(id, wait_ms, cursors) {
      door.poll(strand, id, wait_ms, seam_cursors(cursors))
      |> translate(polled)
    },
    list: fn() {
      door.list(strand)
      |> translate(list.map(_, listed))
    },
    kill: fn(id) { door.kill(strand, id) |> translate(nothing) },
    send: fn(id, data, end) {
      door.send(strand, id, data, seam_end(end))
      |> translate(nothing)
    },
    max_wait_ms: jobseam.max_wait_ms,
  )
}

// --- one refusal vocabulary into the other ----------------------------------

// Every mapping below is total on both sides by construction: each arm
// names one constructor, so a variant added to either vocabulary fails to
// compile here rather than silently becoming something else.
fn translate(
  answer: Result(a, jobs.Refusal),
  with render: fn(a) -> b,
) -> Result(b, job.Refusal) {
  answer
  |> result.map(render)
  |> result.map_error(refusal)
}

fn nothing(_answer: Nil) -> Nil {
  Nil
}

/// The model-facing refusal one door refusal becomes.
///
/// Public so a caller rendering a refusal outside a `ToolOutcome` — the
/// code-mode bridge, which puts the code on the capability wire — reaches
/// the same mapping the tools do rather than a second one.
///
/// ## Examples
///
/// ```gleam
/// // jobtools.refusal(jobs.CeilingReached(limit: 4))
/// //   == job.CeilingReached(limit: 4)
/// ```
///
pub fn refusal(refused: jobs.Refusal) -> job.Refusal {
  case refused {
    jobs.CeilingReached(limit:) -> job.CeilingReached(limit:)
    jobs.NotFound(id:) -> job.NotFound(id:)
    jobs.Invalid(reason:) -> job.Invalid(reason:)
    jobs.ClearanceRefused(reason:) -> job.ClearanceRefused(reason:)
    jobs.Unavailable(reason:) -> job.Unavailable(reason:)
  }
}

/// The model-facing start answer one door answer becomes.
///
/// ## Examples
///
/// ```gleam
/// // jobtools.started(jobs.Started(id:, deadline_ms: 1, wall_ms: 1)).id
/// ```
///
pub fn started(from: jobs.Started) -> job.Started {
  job.Started(
    id: jobstate.job_id_to_string(from.id),
    deadline_ms: from.deadline_ms,
    wall_ms: from.wall_ms,
  )
}

/// The model-facing poll answer one door answer becomes.
///
/// ## Examples
///
/// ```gleam
/// // jobtools.polled(answer).state
/// ```
///
pub fn polled(from: jobs.Polled) -> job.Polled {
  job.Polled(
    id: jobstate.job_id_to_string(from.id),
    state: state(from.state),
    age_ms: from.age_ms,
    deadline_ms: from.deadline_ms,
    stdout: streamed(from.stdout),
    stderr: streamed(from.stderr),
    spill: job.JobSpill(
      stdout_ref: from.spill.stdout_ref,
      stderr_ref: from.spill.stderr_ref,
    ),
  )
}

/// The model-facing listing row one door row becomes.
///
/// ## Examples
///
/// ```gleam
/// // jobtools.listed(row).id
/// ```
///
pub fn listed(from: jobs.Listed) -> job.Listed {
  job.Listed(
    id: jobstate.job_id_to_string(from.id),
    state: state(from.state),
    age_ms: from.age_ms,
    deadline_ms: from.deadline_ms,
  )
}

fn streamed(from: jobs.Streamed) -> job.Streamed {
  job.Streamed(bytes: from.bytes, cursor: from.cursor, dropped: from.dropped)
}

// The lifecycle, one vocabulary into the other. The `ExecResult` is
// carried across unchanged rather than restated: it is `broker/exec`'s,
// and both packages depend on `broker`, so a third statement of an exit
// report would be a third thing to keep in step for nothing.
fn state(from: jobstate.JobState) -> job.JobState {
  case from {
    jobstate.Starting -> job.Starting
    jobstate.Running -> job.Running
    jobstate.Draining(by:) -> job.Draining(by: cause(by))
    jobstate.Exited(result:) -> job.Exited(result:)
    jobstate.Killed(by:, result:) -> job.Killed(by: cause(by), result:)
    jobstate.Lost(reason:) -> job.Lost(reason: loss(reason))
  }
}

fn cause(from: jobstate.KillCause) -> job.StopCause {
  case from {
    jobstate.ByOwner -> job.ByOwner
    jobstate.ByDeadline -> job.ByDeadline
    jobstate.BySessionStop -> job.BySessionStop
    jobstate.ByOperationAbort -> job.ByOperationAbort
  }
}

fn loss(from: jobstate.LossReason) -> job.LostReason {
  case from {
    jobstate.VmRestart -> job.VmRestart
    jobstate.OwnerRestart -> job.OwnerRestart
    jobstate.HelperLoss -> job.HelperLoss
  }
}

// --- the other direction ----------------------------------------------------

fn seam_cursors(from: job.Cursors) -> jobs.Cursors {
  jobs.Cursors(stdout: from.stdout, stderr: from.stderr)
}

fn seam_end(from: job.StdinEnd) -> jobs.StdinEnd {
  case from {
    job.CloseStdin -> jobs.CloseStdin
    job.KeepStdinOpen -> jobs.KeepStdinOpen
  }
}
