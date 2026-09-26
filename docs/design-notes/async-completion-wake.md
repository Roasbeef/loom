# Design note: completion wake, auto-background bash, and the idle heartbeat

Status: **in review** as #498 on `runtime/async-completion-wake`, rebased
onto `main` at `7b351914`.

## The problem

Loom has three kinds of work that outlive the tool call that started them:
background jobs (`bash` with `mode: "background"`, `cap/job`), async
code-mode executions (`code_mode` with `launch`, #484), and detached
strands. For the first two, the model learns that the work finished only by
asking. A job has to be read with `job_poll`, and an execution has to be read
with `check` or `join`. The `client/jobstate` module doc states this as a
ruling: "Nothing here wakes anybody. A model learns that its job exited by
polling."

Polling has two costs. A model that polls too early spends turns and tokens
on "still running". A model that forgets to poll, or that ends its run while
the work is still going, never learns the outcome until a human prompts it
again. And `bash` makes the model choose up front: a foreground call that
outruns its window is killed with `[command timed out]`, and the model has to
guess in advance which commands are long enough to background.

[unreal-agent](https://github.com/unreallabsai/unreal-agent) takes the other
position. Every tool call is asynchronous: after a one-second grace, a call
still running is shown to the model as a placeholder, the model may keep
working, and a finished call's result is appended and starts a new turn.
If the model is idle and only waiting on running calls, a heartbeat wakes it
every ten minutes with the list of what is running. This note brings the
three parts of that design that fit Loom's model.

## The three changes

### 1. A finished job or execution notifies its owner

When a job or an async execution reaches a terminal state, the service that
owns it sends one message to the owning strand. The message is harness
text in a user-role entry, the same shape `client/schedulescan` injects for
a scheduled trigger. It names the handle, the terminal state, and how to read
the result (`job_poll` or `code_mode` `join`); for a job it includes the exit
code and the last lines of each stream so the common case needs no poll.

Delivery is `runtime/api.send_to_strand_marking`: a steer if the owner has
an open run, a fresh run if it is idle. The mark is a reserved cell under
`client/notice/`, keyed by the handle, so a restarted service that re-derives
the same notice meets `FactConflict` rather than delivering a second copy.
The owner is woken when idle. That is the point of the feature and it
matches a `WakesIdle` schedule.

The one exception is a subagent. A subagent has one run, and a notice that
opened a second one after its work ended would extend the child's life
outside its parent's spawn budget: the rule `client/schedulescan` keeps for
a schedule onto a subagent and the Agency keeps for a report into a
finished parent. A notice to a subagent therefore only steers a run it
already has open, and an idle subagent's notice is withheld without
spending its mark. The heartbeat skips idle subagents for the same reason.
The advisor strand gets the same treatment, because its runs are its actor's
to open (`notice.may_wake`).

A stop somebody asked for stays silent whatever terminal state it ends in.
A killed job whose helper then goes away ends `Lost`, and a session stop
that outlives its grace leaves the record draining for the next boot's
sweep to mark lost; `Lost` carries no cause, so the silence is decided from
the state the job was in before it settled.

Not every terminal state notifies. A notice exists to tell the model
something it does not already know, so the causes the model or an operator
chose are silent:

| Terminal state | Notice |
|---|---|
| Job exited, killed by its deadline, lost to a helper or restart | yes |
| Job killed by its owner (`job_kill`) | no: the model asked |
| Job killed by an operation abort or session stop | no: an operator asked, and waking would undo an abort |
| Execution finished, lost to its deadline, idle timeout, or a worker loss | yes |
| Execution cancelled by its owner, aborted with its operation, or stopped with the session | no |

Two sources are also silent by construction:

- **A job a code-mode program started (`cap/job`).** The program is the
  job's reader. A program that starts a job and awaits it would otherwise
  produce a notice after every such call. A model that wants to hear about
  a program's job can poll it.
- **A job an auto-mode `bash` call is still waiting on.** See change 2. The
  call that is watching the job returns its result inline, so a notice
  would deliver the same result twice.

**The crash window.** The terminal commit and the notice are two
transactions: the job record is written, then the notice is admitted with
its mark. A daemon crash between the two loses the notice. The job's record
still says it finished, `job_poll` with no id lists it, and the window is two
adjacent commits in one actor, so this note accepts the loss rather than
adding a recovery scan. A scan over every terminal record on every restart
would also notify, on the first restart after upgrade, every job a session
had ever run.

### 2. `bash` runs as a job and returns a handle when it outlives its window

`bash` gains a third mode, `auto`, and `auto` becomes the default. An auto
call starts the command as a job with stdin closed (as a foreground call
closes it), then waits up to `timeout_ms` for the job to finish, streaming
the job's output to the client as a foreground call does. If the job
finishes in the window, the result is rendered exactly as a foreground
result: the same body, the same `details`, the same blob overflow. If it
does not, the call releases the job and returns its handle, and change 1
delivers the outcome later. The model never has to decide in advance which
commands are long.

`mode: "foreground"` keeps the old behaviour for a model that wants a
command killed at its timeout, and `mode: "background"` keeps returning a
handle at once.

**Attended and released.** While an auto call waits, its job is *attended*:
the jobs actor holds a flag, in memory, that suppresses the completion
notice. The call ends its wait in one of two ways. The job finishes in the
window, and the call renders it and never releases it. Or the window runs
out, and the call asks the actor to *release* the job. The actor serializes
the release against the settlement, so exactly one of two things happens: the
job is still live, becomes unattended, and will notify when it ends; or it
has already finished, and the release says so, so the call polls it once
more and renders it inline. No interleaving delivers the result twice or not at
all. The actor also monitors the waiting caller from admission, so a caller
that dies without releasing, from a driver restart or an abort that stopped
the tool call and not the job, hands the job to its owner exactly as a
release would.

Two further windows are accepted, both rarer than the ordinary path and
both leaving the record correct for a poll. A caller that dies after the
job's terminal commit but before its next look renders nothing, and nobody
is told: the call itself settles as interrupted. And a restart of the jobs
actor alone, while a call waits, makes the call render the job as lost and
the replacement's sweep announce it: the result is reported twice, and both
reports are true.

The flag is not durable. A restart kills every job and interrupts the tool
call that was waiting, which already settles as a synthetic interrupted
result (`replay: Never`); the restart sweep then notifies the owner that the
job was lost. The model reads both, which is redundant but true.

**Fallback to foreground.** An auto call falls back to the foreground path
when the jobs plane cannot take the command:

- **The strand is at its job ceiling** (`max_jobs_per_strand`, four).
  Background work already running must not make an ordinary `ls` fail.
- **The session has no jobs plane**, as in a hook context or a host built
  without one. This is `job.unavailable()`'s own refusal, `NoJobsPlane`,
  and not the `Unavailable` a live plane answers when it does not respond
  in time: that one may come from a plane already clearing the job, and a
  foreground run beside it would run the command twice, so it is reported
  in band instead.
- **The clearance refused the command.** This case is about the structured
  refusal, not about running the command anyway. The jobs door reports a
  clearance refusal as text, while the foreground path's `RefuseNarrowed`
  clearance produces the structured refusal the escalation flow reads. The
  foreground attempt meets the same policy and refuses the same way, with
  the structure an approval needs.

**The wall, and the ruling this revisits.** The background-jobs note
deferred this conversion with one objection: "the approval that admitted a
bounded call did not admit an unbounded one". An auto job is not unbounded.
It asks for no wall of its own, so the jobs plane meets the default hour
with the session policy's own wall, exactly as a background job that named
no timeout. The approval admitted the command; the session's sandbox policy
bounds how long any jailed command may run, and an auto job runs under that
bound and no other. `timeout_ms` keeps its clamp of 600 s and now means how
long the call waits in the foreground.

That has one consequence the foreground did not have. Under a session wall
shorter than `timeout_ms`, a foreground call is refused as a narrowing and
the operator is offered the longer wall; an auto job would instead run
under the short wall with nobody asked. So a call whose window exceeds the
session wall, grants included, keeps the foreground path, and the approval
flow is exactly what it was. `tui_approval_effect_test` is the fixture
that found it.

### 3. An idle heartbeat

If a strand is idle while work it owns is still running, it is woken every
ten minutes with a message listing that work. This catches a hung job the
model has stopped thinking about, and a job whose completion notice was lost
in the crash window above.

The heartbeat is sampled rather than scheduled per job. Each owning service
checks, on a periodic tick, each strand that owns live work: if the strand
has been idle continuously for the interval, the service accepts a run
carrying the listing, and the interval restarts. A strand that becomes busy
restarts its idle clock, so a heartbeat never lands on a strand that just
finished a turn. `[jobs].heartbeat_s` sets the interval in seconds; `0`
disables it.

The heartbeat uses `accept` rather than a steer. A strand with an open run is
already awake, and a heartbeat has nothing to tell a model that is working.
It carries no mark: the idle clock is volatile, and a restart that loses it
also kills every job it was counting.

## What this does not change

The tool surface stays the same size. `auto` is a value of an existing
argument, and the notice and the heartbeat are harness messages rather than
tools. No frozen interface moves: the messages ride the existing queue
admission, the marks are reserved `fact.custom` cells, and the job record's
codec is unchanged because the attended flag is volatile.

## Addendum: the job heartbeat is opt-in

The heartbeat as first shipped woke the owner of any live job. That was
wrong for the most common long job a model starts on purpose: a passive
watcher. A mail watcher, a log tail or a dev server runs until it has news
or until it is stopped, and its owner is supposed to sit idle beside it.
Each heartbeat woke the model to read a listing it already knew, and the
model's only sensible answer was to end its turn again. With a ten-minute
interval that is six paid turns an hour for nothing, and it was seen doing
exactly this in a live session.

A job now counts for the heartbeat only if the call that started it asked:
`bash` takes a `heartbeat` boolean, default false, honoured for
`mode: "background"` and for an `auto` call that outlives its window. The
choice is carried as `tools/job.IdleWake` into `client/jobs.Request` and
kept on the actor's in-memory record of the job. It is not stored in the
durable record because no job is live across a restart, so a stored value
could never be read. An owner is woken only when a job that asked is
still running, and the listing names only those jobs.

The default is quiet rather than loud because the two failures are not the
same size. Every job still sends its completion notice, and every job still
dies at its wall, so a quiet job that hangs costs a late discovery bounded
by that wall. A loud watcher costs a model turn per interval for as long as
it runs. A model that starts a build it suspects may hang can ask for the
reminder. Code-mode jobs never heartbeat, since the program that started
one is its reader. `[jobs].heartbeat_s` still sets the interval and `0`
still turns the heartbeat off for every job.

Async code-mode executions keep the heartbeat as described in section 3.
An execution is bounded by its own deadline, and it is not the passive
watcher this addendum is about.
