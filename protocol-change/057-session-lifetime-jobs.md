# protocol-change/057: explicit session-lifetime jobs

**Status**: Implemented and independently reviewed; hosted signoff required
before landing.
**Affects**: background Bash arguments, code-mode permissions and `cap/job`,
and the deadline interpretation of broker budgets and tokens.

## Problem

A passive `substrate watch` or `gh pr checks --watch` can outlive the session's
600-second default sandbox wall. Each timeout produces a completion notice;
a Stop hook can then ask the model to launch another watcher. A quiet overnight
session consequently incurs inference costs every ten minutes.

The job owner requests one hour by default, but its captured sandbox policy
narrows that to ten minutes. `[jobs].max_wall` raises the finite job ceiling,
not sandbox authority. Raising a finite timeout only postpones renewal.

A separate cancellation defect compounded the notices. The broker relay and
job runner read the clock before a potentially long selective receive, then
anchored cancellation grace to that old instant. After a quiet wall expired,
the grace could already have expired too, discarding a real exit report and
reporting helper loss. Grace now starts at a fresh read after the wait or caller
death that initiates cancellation.

## Decision

Finite lifetime remains the default. Bash accepts `lifetime: "session"` only
with `mode: "background"` and no `timeout_ms`. A zero or negative finite timeout
remains invalid. Explicit finite background timeouts request missing wall
authority through the same approval path.

Code mode exposes `cap/job.start_for_session(command)`. Its outer invocation
must declare `permissions.wall_s: 0` when its base policy is finite. The
`job.start` capability request carries `lifetime: "session"` and no `wall_ms`.
A zero finite `wall_ms` or conflicting lifetime and wall is refused. Approval
is bound to the launching tool action and precedes execution; the job captures
only that invocation's authority. A declined or incomplete approval launches
nothing. The satellite's own build and execution walls remain finite.

Internally, zero `deadline_ms` denotes no temporal expiry for the detached
job's budget, token, record and streaming receive. Zero `wall_ms` and `wall_s`
carry the same meaning in its admission receipt and sandbox policy. Finite
deadlines retain their absolute-clock meaning and are never renewed. This
extends the frozen budget/token interpretation without changing their fields
or the effect frame format. The public `Started` fields document zero.

Session lifetime removes only the wall deadline. The outstanding-job ceiling,
CPU, memory, process, output, filesystem and network limits remain enforced.
Clearance and cancellation drain retain finite bounds. The execution's relay
still watches its runner, and the runner remains owned by the session. Explicit
kill, session shutdown and abort of the originating operation cancel the job.
A later operation does not own that earlier job. A VM restart declares it lost;
there is no restart or shell-command replay.

Quiet waiting produces no paid turn. Normal completion retains existing owner
notification, and heartbeat remains separately opt-in. Explicit stops and
session shutdown remain silent. Settlement revokes and prunes session tokens,
which would otherwise have no expiry at which to reclaim them.

## What was considered

A larger finite default still expires while a watcher is useful. Automatic
restart would replay arbitrary shell effects and obscure ownership. Suppressing
all failures would conceal a watcher that actually ended. An explicit lifetime
uses the existing authority, custody and cancellation boundaries instead.

## Cost and limits

Session jobs retain a helper and outstanding slot while live. They survive a
tool return and a code-mode satellite teardown, not a daemon restart. A command
that exits on its own still ends the job. The host neither edits Substrate's
Stop hook nor interprets its signal text as a reason to restart. Existing live
jobs keep their original finite walls; a fresh authorized invocation is needed.

Timeout notices explain `lifetime: "session"` and higher `timeout_ms`; the
initial tool schema advertises the option before a costly timeout occurs.
