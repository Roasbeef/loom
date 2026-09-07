# Design note: background jobs

Status: **landed.** Written against `main` at `3ef6ea09` (the merged
daemon stack) and shipped in five pull requests: **#260** the pure state
and the `job/` fact (WP1), **#263** the actor, the runner, the tail and
the spill (WP2 and WP4), **#264** the tool surface, `cap/job` and the
prelude (WP3) — merged into `jobs/actor` rather than `main` and relanded
against `main` as **#267** — **#266** the shipped acceptance fixture and
this documentation (WP5), and **#269** the step-scoped abort that settles
the contradiction the fixture found.
Resolves issue #183 and settles the first cut of #186 and #71 on the way.
Converting an overrunning foreground call into a job, the second half of
#183, was deliberately deferred; see "The tool surface".

Two sections near the end are the ones to read before treating any
paragraph above as current. "What changed on contact with the code"
records where the implementation departed from this note. "What the
shipped fixture found" records the one place this note was wrong and how
it was fixed. `docs/next.md` carries the follow-ups that were left open
and the reason each was deferred.

## The problem

A model working in Loom cannot start something and come back to it. Every
`bash` call is foreground: the tool's `run` blocks its effect process for
the whole execution (`runtime/effects.gleam:252-253`), and past its budget
the call returns the literal `[command timed out]` (`tools/bash.gleam:212`)
with the process reaped. The motivating case is small and exact: start
`tail -f build.log`, keep working, every so often ask "what has it printed
since I last looked", and eventually stop it. Today the only way to watch
a long build is to block on it.

We have three things in tree that already outlive a tool call, and none
of them is addressable as "a process with output, an exit status and a
kill handle". A subagent is a strand with its own driver and lineage cell.
A code-mode satellite is a BEAM node reaped by its operation's abort. An
extension satellite lives for the session but "may compute between
invocations and may not act" (`client/extension/hosts.gleam:19-23`). So
the job is a fourth lifecycle owner, and the design question is how small
it can be while still honouring the effect plane's rules.

## What a job is

A job is a jailed process the harness started on the model's behalf, that
is allowed to outlive the tool call that started it, bounded by a wall
deadline fixed at start, owned by a strand, observable through a bounded
rolling tail plus a full spill, and killable through the same TERM then
KILL ladder a foreground call has.

That definition deliberately covers one backend, the helper `exec` path
behind `broker.clear_call`, and nothing else. Satellites (#107) and
subagents stay what they are: their durable identity is a node or a
strand, not a process handle, and folding them in would either grow jobs
a strand-shaped arm or cost subagents their lineage ledger. The seam
below is written so they can become clients later; the first cut does
not try.

## The four decisions

### 1. A job is not a machine concept

`ToolCallState` has four arms and no "running detached" one
(`machine/operation.gleam:388-405`), and WP-D's exit criterion is "every
tool call has a result". We keep that. Starting a job is an ordinary tool
call that returns a handle in band, exactly as `agent_spawn` does today;
polling it is another ordinary tool call whose result is the tail so far.
Spec §1.3 is untouched, `core`/`machine`/`prompt` learn nothing, and the
job's whole existence is a durable fact plus a live process the runtime
owns.

The consequence we accept is that the machine cannot wait on a job. A
model that wants to block on one calls `job_poll` with a wait, and a
pending job is a successful result, not a failure (the "pending is an
answer" rule `agent_wait` already follows, `client/agency.gleam:222`).

### 2. The durable record is a reserved prefix, and restart reaps

Each job has a `job/<id>` register in the session store. It is a key
prefix inside the existing `fact.custom` namespace, so it costs no
protocol change (`core/register.gleam:27-28` freezes the namespace set;
prefixes are free). It becomes the tenth reserved corner: one line in
`reserved_fact_key` (`runtime/api.gleam:1675-1685`), one row in the table
at `api.gleam:1650-1663`, written only through
`put_reserved_fact_expecting`. Creation uses the expect-absent CAS the
schedule seam uses for a named create (`client/scheduleseam.gleam:372-383`),
so two incarnations racing to start the same job cannot both land. Every
commit arm handles `LeaseLost` as reopen, never retry (protocol-change 005).

The write order is the effect sandwich applied to a spawn: commit
`Starting(spec, owner, deadline)`, then clear the call through the
broker, then commit `Running` once the helper has accepted the run, then
commit the terminal state (`Exited`, `Killed(by)` or `Lost(reason)`) with
the full `ExecResult`, `cancelled` included. That last write is where
#71's unread key finally gets a reader.

The restart rule is simpler than #183's "re-adopt or reap". A job's
process is a child of a helper, the helper is a child of the daemon VM,
and nothing in this design survives the VM. So a restart never
re-adopts: it lists `job/*`, and every job not already terminal is
committed as `Lost(vm_restart)` before the strand resumes. The model
learns this on its next poll. The same rule runs when the jobs actor
itself restarts (see decision 3), with `Lost(owner_restart)`.

Registers survive compaction (the compaction write is one entry,
`machine/internal/build.gleam:243-254`) and survive a rewind. For a job
that is the right behaviour: it is a live process, not a conversation
event, and navigating the tree must neither kill nor resurrect it. #184's
branch-blindness is a bug for fired-marks and a feature here, and the
module doc says so rather than leaving a reader to wonder. A register is
also state, not a channel (`api.gleam:1290-1293`): the model learns of a
transition by polling, never by an injected message, which keeps the jobs
actor out of the strand's turn machinery entirely.

### 3. One actor, one runner per job, weft all the way down

`client/jobs.gleam` is a `weft/actor` in the *restartable* services tier
beside `extension_hosts` (`client/serve.gleam:2619`), bound to a
reclaimable `weft/registry` address so a replacement is the same address
and no caller caches a subject. Losing it costs what losing the extension
registry costs: every runner it owned dies with it, and the reap rule
above records each job as `Lost`. That is why it does not belong among
the fatal children.

Each job is a weft managed task, the *runner*, adopted under the actor.
The runner, not the actor, calls `broker.clear_call`, for two reasons
that both come from the broker's contract. `clear_call` waits out a full
pool in the caller's process (`broker/broker.gleam:37-49`), and an actor
blocked on congestion could not answer a poll. And the relay monitors the
caller (the owner of the events subject) and cancels the execution when
that process dies (`broker.gleam:970-976`), so the caller has to be a
process that lives exactly as long as the job. The runner then folds the `CallOutput` stream
into the tail and the spill and reports `CallSettled` to the actor as a
relayed outcome. The actor matches all seven `weft.Outcome` variants and
writes the terminal fact only after that message arrives, because a weft
outcome is only reported once the worker and every owner have exited: the
scope's exit is the drain proof, and "done" is never written ahead of it.

The per-job lifecycle (`Starting | Running | Draining | terminal`) is a
pure module with no process and no `@external`, property-tested without
spawning anything; the actor applies only the transitions it accepts.
Whether the actor drives one `weft/state_machine` per job or holds a
dict of pure states is the worker's call, with one constraint either
way: the deadline belongs to the `Running` state so leaving the state
cancels it and a raced fire is dropped (`docs/weft.md:54-67`).

Asking a possibly-dead runner for status goes through a monitored call,
which weft names as its one gap (`docs/weft.md:246-249`);
`broker/internal/call.gleam:57` is the in-tree shape to copy, or the gap
gets closed in weft as part of the work.

### 4. A job's clearance carries its own identity

This is the decision that touches the most existing invariants, so it
gets the most words.

A capability token is bound to `{op_id, step_id, policy, deadline}` and
the token deadline *is* the budget deadline (`broker/token.gleam:38-45`,
`broker.gleam:857`); there is no second clock. Budget is pooled per
`{op_id, step_id}` where `step_id` is the model batch (ADR-005), the
first clearance opens the ledger with its `max_outstanding`, and a later
clearance cannot widen it (`broker.gleam:120-127`). `bash` opens that
ledger with `max_outstanding: 1` (`bash.gleam:326`). So if a job cleared
under the batch's own identity, a foreground `bash` earlier in the same
batch would cap it, and a second job in the batch would be refused
`OutstandingCapReached` while the first still ran. That is the wrong
shape: a detached job is not part of a batch's parallel width.

A job therefore clears under `{op_id, "job/" <> id}`: the real operation
that started it, and a synthetic step naming the job. Each job gets its
own ledger with `max_outstanding: 1` and a deadline equal to the job
deadline, and its own token bound to that deadline. ADR-005 said the key
stays the batch and warned against threading a new identity through it;
this is a new *kind* of caller rather than a finer grain of the same one,
and it lands as an addendum to ADR-005, not a silent edit. The alternative
(a separate ledger table for jobs) was rejected as a second accounting
path for the same resource.

What the operation binding buys us is abort semantics we do not have to
build. `broker.abort(op_id)` revokes every token of the operation and
cancels every active helper under it (`broker.gleam:677-705`). So an
operator aborting the operation that *started* a job kills that job,
which is what they meant; an abort of a later operation does not touch
it, because detachment is what the model asked for.

The wiring that makes that true is worth naming, because the operator's
abort has two halves and only one of them is the runtime's. The `abort`
command commits the cancel marker and stops the strand's live effects
through `api.abort`, and a detached job is nobody's live effect — so the
hub also sweeps the effect plane, through the `effect_abort` seam
`client/serve` fills with `broker.abort` (`client/gateway.abort`,
`client/serve`'s `hub.start`). It has to be the host that joins them:
`runtime` may not depend on `broker`, and the broker is the only thing
that holds the other half of the ledger. `client/jobs`' `ByOperationAbort`
is what the record reads afterwards, and
`an_operators_abort_of_the_operation_kills_the_job_test` in
`client/jobs_test` is what pins the whole path.

The reach is bounded by that door, and the bound is worth stating rather
than discovering. The `abort` command aborts the strand's *current*
operation, so it kills the jobs of the turn that is still running. A job
started two turns ago outlives its operation by design, and by then no
command names that operation any more — the operator stops it with
`job_kill`, or by ending the session. Nothing is lost that the broker
could have given us: the sweep is a scoped cancel an operator asks for,
and there is no operator asking once the turn is over.

Session stop reaches
every job through the actor's position in the ordered `Part` shutdown
(`instance_owner.gleam:30-50`): jobs die before `Broker` and `Helpers`
close and long before `Storage` does.

The deadline is fixed at start and never renewed. Four enforcers agree on
it by construction because they all read the same number: the token, the
relay's receive deadline, the helper's own wall timer, and the budget
ledger. Renewal at runtime would need the helper's timer to move, and
that timer is armed once from the request's own `WallSeconds` (`sandbox/internal/jail/run.go:519`),
so extending it is a new frame and a protocol change. Long-lived servers
are covered the other way round: the clamp is an operator knob, a
`[jobs]` table in `loom.toml` with `max_wall` (parsed beside the known
tables in `client/catalog.gleam:278`), so a workspace that runs a dev
server for a day says so once, and the default clamp stays an hour.

## Policy, approval and the pool

A job admits under exactly the rules a foreground `bash` does: the same
`ExecRequest`, the same `RefuseNarrowed`, the same enforcement demand,
the same escalation. The requested wall becomes the request's `wall_s`,
and if the composed policy narrows it (the default `wall_s` is 600,
`broker/policy.gleam:229`) that narrowing goes through the same refuse or
escalate path a widened `bash` would. So a thirty-minute job on a policy
that allows ten minutes is exactly the thing an operator approves, with
no new mechanism. The approval binds to the digest of the starting call's
arguments (the command, the mode, the wall), which is what the human saw,
and it authorises that one start. Killing a job needs no approval: the
owner strand may always stop what it started. The shipped-approval gap
(#243) applies unchanged.

A running job occupies one helper for its whole life, and the pool is
four to sixteen processes sized from the scheduler count
(`broker/exec.gleam:2454-2465`). That is the honest cost of the design
and the reason for a ceiling: a `tail -f` held for a session is one
fewer helper for every parallel tool batch. The ceiling is per strand,
four concurrent jobs, refused in band as a `job_ceiling` failure the way
the orchestration seam refuses `spawn_ceiling`; there is no session-wide
limit in this cut. Sixteen strands each holding four jobs would exhaust
the largest pool, so the note records the arithmetic rather than
pretending it away: if real use shows the pool starving, a dedicated
job pool is the follow-up, and it is a pool-sizing change rather than a
design change.

Jobs are not tool effects, so `tool_may_start`'s exclusivity
(`strand_runtime.gleam:2295-2311`) does not see them, and a background
job runs beside an `Exclusive` foreground call. `bash` is exclusive to
keep the model's own foreground calls from racing each other over the
workspace; a job racing a later `fs_edit` is a race the model chose when
it backgrounded the command, and the design says so instead of trying to
serialise it.

## Output: the tail and the spill

The helper already caps each stream at `output_bytes` (4 MiB by default)
and streams 32 KiB `exec_out` chunks that the broker surfaces as
`CallOutput`. Today `tool.collect_events` folds every chunk into a list
and emits nothing until settlement (`tools/tool.gleam:958-966`), which is
#186's complaint. The runner is the first consumer that keeps the stream
as a stream.

There is no rolling-tail primitive anywhere in `packages/*/src`; the
closest thing, `blob.utf8_suffix`, is private. So the first new module is
a pure, bounded, UTF-8-safe tail with a monotone byte cursor: `push`
appends a chunk and drops from the front past the cap, `since(cursor)`
returns what arrived after the cursor plus the new cursor, and if the
cursor predates the retained window the reply carries a `dropped` count
rather than pretending. Per stream, 8 KiB retained. That is what
`job_poll` returns, and it is exactly the "what has it printed since I
last looked" answer.

The spill is the whole stream. `blob.bound` is one-shot and
content-addressed over a complete body, which a running job does not have
yet, so the runner writes a per-job staging file under the blob root
(the `.ref.tag.tmp` shape `blob.gleam:139-141` already uses for atomic
writes) while the job runs, and at termination hands the complete body
to the existing content-addressed writer, records the `sha256-` ref in
the terminal fact, and unlinks the staging file. A restart that finds a
staging file with no live job unlinks it too. The model never reads the
staging file; it reads the tail while the job runs and the spill through
`fs_read` on the ref once it has ended, the same way it reads any
overflowed tool output today. Truncation by the helper's cap is reported
structurally through the existing `truncated` flags, never by a prose
notice.

This is also where #185 and #186 get their first customer. The runner
calls the spill path from one place, and a `job_output` bus event, if
#240 ever makes push worth having, is one more subscriber on the same
stream the runner already folds.

## The tool surface

Tool-surface cost is arithmetic (`client/contributions.gleam:145-152`):
every permanent definition is the byte prefix of the provider's cached
region and is paid on every request of every strand for the session. The
roster is eighteen fully wired. So the surface is one flag and three
tools, not five.

`bash` gains `mode`, a two-value enum (`"foreground"`, the default, or
`"background"`), modelled on the Gleam side as a two-variant type rather
than the `detach: Bool` that `agent_spawn` carries today and that the
no-naked-`Bool` rule would refuse. In background mode the call admits a
job and returns the handle at once: the job id, the deadline, and the
composed wall the policy allowed. Timeout follows the same clamp path as
today, against a job-specific default and clamp of one hour rather than
`bash`'s ten minutes, with `[jobs].max_wall` raising the clamp for a
workspace that needs it; §3.5 says the tool's own clamp is the wall
ceiling and policy narrows from there, and a job is a different tool
call with a different clamp.

`job_poll(job_id?, wait_ms?, since?)` returns the job's state, the tail
since the cursor for each stream, the new cursors, and the `ExecResult`
if the job is terminal (with the spill ref). With no `job_id` it lists
every job the strand owns with state and age, which is why there is no
separate `job_list`. `wait_ms` is clamped to `agency.max_wait_ms`
(30 s, `client/agency.gleam:215`) and is a `weft/poll` on the job's
state under the session clock; the deadline expiring during a wait
returns the terminal state, and a job still running returns pending as
a success.

`job_kill(job_id)` climbs the existing ladder, TERM to the payload and
its descendants then KILL of the group, and returns the terminal state,
whose `cancelled` is `true` because the helper is the only party that
knows it climbed (protocol-change 006). On Darwin the ladder is
best-effort and the execution carries `skip:darwin-process-lifecycle`,
exactly as a foreground cancel does today.

`job_send(job_id, data, eof?)` writes to the job's stdin. This is cheaper
than it looks: the helper wire already has `exec_stdin`
(`broker/framing.gleam:83`) and the broker already exposes `stdin`
(`broker.gleam:543`); today's `bash` closes stdin immediately
(`bash.gleam:112`) and nothing above the broker writes to it. A
background job leaves stdin open until `eof` or kill. It is the
difference between "watch a log" and "drive a REPL", and it ships in
the first cut.

Converting a foreground call that overruns its budget into a job (the
second half of #183) is deferred to a second cut with its own decision:
the approval that admitted a bounded call did not admit an unbounded one,
so conversion needs either an explicit opt-in on the call or a policy
rule, and neither is obvious enough to take here.

## Top-level tools versus code mode

Both surfaces open the same door. `tools/job` is the model-facing
surface for the wire tool array: the schema, the wording, the shape of
a refusal. `cap/job` is the same four operations (`start`, `poll`,
`kill`, `send`) as typed Gleam a vetted program calls from a satellite.
Both are values over one seam of closures that the host fills in,
`client/jobseam.Door`, mirroring exactly how `tools/schedule` and
`cap/schedule` land on `client/scheduleseam`. The tool owns nothing
durable and enforces nothing; the door owns the ceiling, the policy
composition, the fact writes and the actor. So a job started from a
tool call and a job started from a program are the same kind of thing
with the same `job/<id>` record, and either surface can poll or kill a
job the other started, because ownership is the strand, not the caller.

The split in *use* falls where the two surfaces already differ. A
top-level call is one round trip and one cached tool definition, so it
is what the model reaches for interactively: start the build, come back
three turns later, read the tail. A code-mode program is a loop with no
round-trip cost, so it is where the composed shapes live without the
harness having to grow them as tool features: start a server, poll
until a line matches, run the tests, kill the server, return one
result. "Wait until the output contains X" is a five-line program, not
a `job_poll` argument, and keeping it that way is what keeps the tool
surface at three definitions.

The cap routes `ServedHere` in the workspace router
(`codemode/workspace.gleam:625`, plus `serviced_caps`) rather than as a
jailed `ClearedCall`, because the operation is answered by the harness
actor and only the job's own process is jailed. It lands on
`default_cap_modules` and nowhere else so the `{cap/report}` intersection
test keeps passing (`codemode/vet/policy.gleam:79-84`), and costs one
`make gen-prelude`. The per-strand ceiling applies through the door, so
a program spawning in a loop is refused at the same count a tool call
would be, and a tight poll loop is bounded by the `wait_ms` clamp, which
is at least a slice. A program's own `within_ms` is unrelated to the
job's deadline: the satellite ends when the program returns, and the
job it started keeps running under its own token. That takes one thing
of the teardown, and it is the thing the shipped fixture found missing:
reaping a satellite sweeps the execution's own step
(`broker.abort_step`), never the operation the job shares with it.

## What the client sees

Nothing new on the wire in this cut. A job's start and terminal state are
registers, and `Cut.cells` is namespace and key addressed
(`storage/snapshot.gleam:149`), so the TUI's cut decoder can count
`job/*` cells without a type change; poll results are tool results and
already visible. `live_phase` cannot express *n* jobs because it is
derived from a strand's one open operation, which is what a `LiveOp` names (`client/gateway.gleam:3336`),
and we do not bend it: an idle strand with two jobs shows idle, with a
job count beside it once the renderer grows one. A live `job_output`
event and a jobs panel are follow-ups that #186 and #240 already own,
and under `Network` delivery today they would be pull-only anyway.

## Ceilings

| Bound | Default | Enforced by |
|---|---|---|
| concurrent jobs per strand | 4 | door admission |
| concurrent jobs per session | none in this cut | see the pool arithmetic above |
| job wall | 1 h default and clamp, `[jobs].max_wall` raises, policy narrows | token, relay, helper timer, ledger |
| tail retained per stream | 8 KiB | runner |
| spill | helper `output_bytes` cap | helper, existing |
| poll wait | `agency.max_wait_ms` | tool clamp |

## What this settles on the way

#71: the terminal fact carries `cancelled` and `job_poll` renders it, so
the sentence protocol-change 006 exists for becomes sayable; the same
one-line render lands in `bash` details. #186, partly: the runner is the
first consumer of `CallOutput` chunks as a stream. #185, adjacent: the
spill is called from one place for jobs, and the seam-level refactor for
foreground tools stays #185. #74 lands first, because the jobs work adds
variants to `ExecFailure` and today they would fall silently into
`denial_for_failure`'s `_ -> None` (`broker/broker.gleam:662`).

## Contracts touched

Spec §1.1 and §1.2 are consumed as they stand (a key prefix, the CAS
rule, the lease rule). §1.3, the machine, is untouched by decision 1.
§1.4, the helper wire, is untouched: no new frame kind, and stdin already
exists. §1.6, the client wire, is untouched by decision "nothing new on
the wire". ADR-005 gets an addendum for the per-job ledger identity.
`cap/job` regenerates the prelude. No `protocol-change/` is needed for
the first cut, which is a property of the design rather than luck: every
place a new frame or verb was tempting, the existing register, wire or
ladder already carried it.

## Testing standard

The pure state module gets property tests over every transition with no
process. The actor gets tests against a scripted helper: the ceiling
refuses loudly, the deadline kills with `Killed(Deadline)` and
`cancelled: true`, the tail stays bounded under a flood and reports
`dropped`, the spill lands past the cap, a poll with a wait returns
pending exactly, and `job_kill` observes the ladder. The restart test
reopens a store holding a `Running` job and asserts `Lost(vm_restart)`,
never a re-spawn and never a silent drop. The shipped fixture is the
motivating case in the acceptance style: `tail -f` on a workspace log,
lines appended by the test, a poll that shows exactly those lines since
the cursor, a kill, a terminal state carrying `cancelled`, and a
birth-qualified departure check as the recovery fixtures do. The fixture
fences the payload itself rather than its group, and here those are one
process: the command `exec`s into `tail`, so the shell that started the
group is gone and its leader *is* the payload. The fence is taken only
where the payload's pid is the host's — that is, where the jail has no
pid namespace — and the fixture's own `PayloadIdentity` says what stands
in for it under bwrap. Mutation checks: remove the ceiling, remove the terminal
commit, remove the cancel ladder, remove the `Lost` reap; each must fail
exactly one test.

## Work packages

All five are merged; this is the plan they were dispatched from, kept
because it says what each was for. WP4 shipped inside WP2 rather than
separately, and the step-scoped abort was found by WP5 and landed after
it. Each was closed by one Fable pass before merge, the same standard the
daemon stack met. WP1 is the pure job state and the `job/` fact codec
with its property tests. WP2 is the actor and runner: weft, broker
integration under the per-job identity, ceilings, deadline, cancel
ladder, restart reap, plus the ADR-005 addendum. WP3 is the tool surface
(`bash` mode, `job_poll`, `job_kill`, `job_send`), `cap/job` and the
prelude regeneration, and #71's render. WP4 is the tail module, the
staging spill and the cursor protocol, with the seam #186 will subscribe
to. WP5 is the shipped fixture and the docs: an `effects.md` section, the
package `CLAUDE.md`s, and `docs/next.md`. #74 lands before WP2 as its
own small change.

## What changed on contact with the code

Six departures, each argued where it landed rather than only here.

**The runner is a plain weft task, not a managed one.** Decision 3 asked
for a managed task because the design imagined a ledger of owners. The
worker discovers none: everything that outlives it is the helper's
execution, reached through the broker, whose relay is already monitoring
this very worker and whose pid the clearance seam deliberately does not
hand out. A ledger with nothing to adopt is machinery with no job.

**Starting is synchronous over the clearance.** The note left the shape
open; the door waits for the broker's answer, so a policy refusal, an
escalation and the strand's ceiling reach the starting call in the
broker's own words rather than arriving at some later poll. It is the one
door operation whose bound is the broker's rather than the actor's.

**The spill is per stream and lives in the record.** The note described
one staging file; there are two, one per stream, each promoted to its own
content address at termination and recorded in the terminal fact, because
`JobSpill` already has a field per stream and one file for both would
have had to interleave them.

**`[jobs].max_wall` is in seconds and only raises.** The note did not say
which unit or which direction. Seconds match every other duration in
`loom.toml`, and the table cannot lower the one-hour clamp: a lower
ceiling is what the session's own sandbox policy already expresses, and
expressing it twice lets the two disagree.

**`OwnerRestart` is in the vocabulary but never reported.** The sweep
says `VmRestart` for both cases it covers. Telling "the actor's first
start this session" from "a supervisor restarted it" needs state that
outlives the actor and dies with the VM — a durable cell or a second
process — bought for a word in a message nobody branches on.

**A hook may not start a job.** Not considered here at all. An extension
invocation set going by a hook event is served no jobs plane, because a
hook's operation is the one session-long operation minted for every hook
in the session: nobody sees it as a running step, so nobody can abort it,
and a `context` hook calling `job.start` on each event would leave
hour-long processes owned by `main` that the model never asked for and
cannot find. `docs/architecture/extensions.md` carries the ruling.

## What the shipped fixture found

`daemon_shipped_jobs_test` proves the motivating case and the restart
rule against the shipped daemon on a host with real enforcement. It also
found two things the unit suites could not.

The first is fixed: `job.list`'s row over the code-mode wire carried a
state name without the fields that state licenses, so `cap/job` refused
the whole listing the moment a strand held any job that had ended — which
is every strand, eventually.

The second was a real contradiction of this note, and it is fixed. "The
satellite ends when the program returns; a job it started keeps running
under its own token" was not true: a code-mode execution ended by calling
`broker.abort` on its operation to reap its satellite
(`codemode/satellite.cleanup`, `codemode/launch.destroy`), and by
decision 4 a job started by that program cleared under the same
operation — so the abort cancelled the job's helper and the record read
`Lost(HelperLoss)`. The same collision reached a `bash` background job
started in a batch that also ran a program.

The fix narrows what a teardown sweeps rather than re-keying the job,
because the job's key is load-bearing and the teardown's reach was not.
The broker already carried a `step_id` on every active call, ledger and
token binding, so `broker.abort_step(op_id, step_id:)` is the sweep it
could already express and had no public way to ask for; both teardown
sites now call it on the run phase's own step. Decision 4's abort
semantics are untouched — an operator's `abort` of the operation still
reaches the jobs it started — and what is given up is only a *routine*
teardown borrowing the operator's reach. The step needs its own sweep
counter beside the operation's, because a step sweep that bumped the
operation's counter would refuse a resumed clearance of every sibling
step, the spared job included. ADR-005's second addendum records it.

The fixture now asserts both halves: the later program finds the record
under its own id **and running**, and the payload's own identity — taken
while the first satellite was being reaped — departs only when the second
program kills it.

What the fixture deliberately does *not* cover is the operator's abort.
Every turn it drives runs to completion, and by the time the fixture can
send a command the operation that started the job has closed — so an
abort would name the next operation and correctly touch nothing. Proving
the sweep end to end there would mean a scripted turn that stalls while
the fixture aborts it, which is a scenario of its own rather than a line
added to this one. `client/jobs_test` pins the path instead, with the
real hub over the session's real open operation and only the broker
scripted.

## Settled on review

The ceiling is per strand with no session-wide limit yet; the wall
defaults to an hour with an operator knob for longer; an abort of the
starting operation kills its jobs, wired at the hub's `abort` command
(decision 4); and `job_send` ships in the first
cut. The one question still open is whether a dedicated job pool should
come before real use shows the shared pool starving.
