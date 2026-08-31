# The effect plane

Everything that touches the world outside the harness process — shell
commands, file edits, searches, model requests — leaves through this
plane. It is one door with a lock (the ToolBroker), one wire (a framed
msgpack protocol), one jailer (a small Go helper that restricts itself
and then execs the target), and a tool set whose correctness does not
depend on the model behaving. What follows is the plane as built, in the
`broker`, `sandbox`, `tools`, and `provider` packages, through to the
end-to-end acceptance that runs a real helper against a real workspace.

## The threat model, and Rule Zero

Four things are defended against, in increasing difficulty: **accidents**
(a delete in the wrong directory, a force-push, a `.env` swept into a
commit); **prompt injection** (hostile repository, web, or tool content
steering the model toward exfiltration or destruction); **malicious
generated code** (a program the model wrote attempting escape or
persistence); and **compromised third-party tools** (a malicious language
server, or a Model Context Protocol server). Two are not: a hostile user
on their own machine, and kernel zero-days — surface is reduced, but
machine-grade isolation waits for the microVM tier.

The defense rests on one rule, because BEAM processes are fault isolation
and not security isolation. Any process in the virtual machine can call
`os:cmd/1`, open any file the OS user can open, and dial the network;
there is no intra-VM capability model to lean on.

> **Rule Zero: model-influenced execution never runs in the harness VM.**
> The BEAM node orchestrates. Untrusted work runs in OS-sandboxed
> external processes under kernel-enforced policy. The actor model buys
> supervision and recovery; the kernel buys isolation; the two are never
> confused.

## The one door

Every effect goes through `broker.clear_call`. It composes a policy,
refuses or narrows, reserves budget, mints a token, borrows a helper, and
dispatches — and from that moment the caller is guaranteed exactly one
settlement event, whatever happens downstream.

```
  clear_call
    ├─ compose    base ⊕ requirements ⊕ grants  ->  policy + narrowings
    ├─ validate   absolute paths, non-negative limits
    ├─ reserve    one slot against the pooled cap and deadline
    ├─ mint       32 random bytes bound to {op, step, policy, deadline}
    ├─ checkout   a helper from the pool (waiting out a full one)
    └─ dispatch   exec_start over the framing channel
                        │
   caller  <──  relay  ─┴─  exec_out ...  exec_exit
                        │
                    settle: check the helper in, revoke the token
```

**Composition is most-restrictive-wins, and grants are the only widening.**
`policy.compose` takes the meet of the session base and the tool's
requirements: root coverage is prefix-aware (a base root `/work` covers a
requested `/work/sub`, and the result is the *requested*, narrower root),
the network lattice meets at `Off < Proxy < Full`, each limit takes the
per-field minimum with `0` meaning unlimited, environment allowlists
intersect as exact strings, protected paths union, and two different
scratch choices collapse to a fresh tmpfs. Two proxy policies intersect
their host allowlists and always keep the base's proxy address, since the
harness owns the proxy and a tool must not redirect egress. Only then do
approved grants apply, each explicitly widening one field.

What composition takes away it also reports. Every requirement the final
policy fails to satisfy becomes a `Narrowing`, and `wanted_grants` turns
that list into exactly the grants that would satisfy it — which *is* the
policy diff an escalation shows a human ("wants: network to
registry.npmjs.org"). `RefuseNarrowed` turns any shortfall into a
structured denial before anything runs; `ProceedNarrowed` runs under the
narrowed policy and lets the sandbox denial speak for itself.

**Tokens bind and are spent once.** A token is 32 bytes from an injected
entropy source, carrying a `Binding` of `{op_id, step_id, policy,
deadline_ms}`. It travels only over the channel it authorizes and is
checked on every use, with `check_for` additionally requiring the token
to name exactly this operation and step. Bytes are compared in constant
time, and the vault scans every entry without an early exit, so timing
reveals neither a match's position nor how close a guess came. Refusals
are ordered — unknown, revoked, expired, wrong binding — and settlement
revokes, so no token is ever good twice.

**Budgets are pooled per execution, not per call.** One `Budget` carries
a cap on outstanding effects and one aggregate wall deadline, and every
effect under the token reserves against the same ledger. This closes the
amplification hole: ten thousand polite parallel reads or fifty spawned
test runs share one account and are refused past the cap, however
reasonable each request looks alone. Settling with nothing outstanding is
a no-op rather than an error, since settlement can race a crash-driven
cleanup and double-settling must never underflow into free budget.

**The pool is a different ceiling from the budget, and a full one is
congestion rather than a verdict.** `max_outstanding` refuses
amplification; the pool says how many jails this host can actually
afford at once, since every helper is an OS process running bwrap and a
jail. It is sized from the node's scheduler count, clamped to `[4, 16]`
and overridable with `LOOM_HELPER_POOL` — a number, never a literal,
because it is also the real ceiling on how wide a parallel tool batch
runs. A batch wider than the pool therefore *waits* for a slot instead
of handing the model a resource error for its third call: `clear_call`
retries within the caller's own clearance budget.

That wait happens in the borrower's process, and where it happens is the
whole of its correctness. The broker checks a helper out synchronously
inside its own message handler and checks one back in only from
`Settle` — a message it can process solely while it is not blocked. A
queueing pool that deferred its checkout reply, or a broker that parked
on one, would be waiting for a resource that only its own message loop
could release. Retrying from outside cannot reach that state, and
nothing is held across the wait: the checkout-failure path hands back
the reserved budget slot and revokes the minted token before it answers,
so a waiter owns no ledger slot, no token and no helper. Progress
depends only on running executions ending, which their wall deadlines
guarantee. The wait is bounded rather than indefinite, so a nested
borrower — a code-mode satellite holding one helper while its capability
calls ask for another — degrades into the refusal it always got instead
of into a stall.

**Every waiter leaves with a verdict**, which is a second property and
takes its own machinery. The loop reserves a window it believes the
broker could answer in and stops rather than issuing an exchange with a
few milliseconds left, because the broker is serial and a clearance it
grants blocks it for a relay handshake, a helper handshake and a
checkout. And the exchange itself answers instead of crashing: an
ordinary `process.call` faults its caller on a timeout and on a dead
callee, and the caller here is a strand effect process holding the very
refusal the model was meant to read. What no floor covers — a broker
slower than the caller's whole budget, or one stopped underneath a
parked waiter — comes back as `BrokerUnavailable` rather than faulting
the strand.

Each dispatched call gets a **relay** process owning the execution's
event subject: it forwards output, enforces the wall deadline, and
reports settlement back to the broker. Past the deadline it cancels and
drains for a five-second grace window, trusting the helper's own cancel
ladder to produce a terminal event; if none arrives, the call settles as
`CancelEscalated`. Dispatch failures take the same road, so "exactly one
`CallSettled`" holds even when the helper refuses the work.

**Abort revokes and kills.** `broker.abort(op_id)` revokes every token of
that operation and cancels every execution under it, and cancellation
reaches the OS as a signal to the process *group* — no orphaned
`npm install` left behind.

Approval escalation is a separate pure machine that consumes those
denials. Approval accepts only grants drawn from the denial's wanted diff
(a subset is fine; a wider grant is a new decision, not a rider), and
`consume` yields those grants for exactly *one* re-execution and refuses
a second. Each transition returns an `Event` for the runtime to record
durably before acting on it, so the transcript shows denial, decision,
and the single retry. Widening the session base is the caller applying
approved grants explicitly — never a silent side effect.

**Who drives that machine in production.** `client/escalate` is the seam
between a broker refusal and a human. It wraps `Ctx.clear_call`, so a
`PolicyRefused` — and only a policy refusal — files a durable record
scoped to the exact call (`{operation, strand, step, source index, call
id}`) under an id derived from `{strand, tool, wanted diff}`, which is
what makes a retry loop land on the record already pending. If the host
says a client is attached, the refusal then **parks**: the call is held
open on its own effect process (never on the strand driver, which must
keep serving aborts) until the record is decided, the window closes, or
the client goes away. An approval is consumed by CAS and the same call is
re-cleared once under the widened policy. The window is the smaller of a
configured timeout and the call's own budget deadline, because the
ledger refuses a reservation past that instant. Which raised records
interrupt a person is a client-surface decision, not a runtime one.

## The wire

One framing protocol carries every data-plane channel: executors today,
satellites and remote pools later.

```
frame    := u32_be length ++ msgpack(map)
map keys := "v":1, "id":u64, "kind":str, "body":map
kinds    :  hello, exec_start, exec_stdin, exec_out, exec_exit,
            cap_call, cap_result, cancel, heartbeat, error
```

The `id` correlates: `exec_out` and `exec_exit` reuse their
`exec_start`'s id. Both sides cap a payload at 16 MiB so a corrupt length
prefix cannot make anyone allocate gigabytes. The helper sends its hello
first — the broker learns the honest feature set before committing work —
and refuses every other frame until the broker's hello answers it.

**Malformed and unknown are different failures.** A frame that does not
parse closes the channel, after an error frame so the effect can settle
in-band; that is security invariant 6 taken literally. A frame that
parses but names a kind the receiver does not implement gets an in-band
error and the channel *stays open*, because the peer may be newer and
able to downgrade. Both sides implement both halves.

Msgpack was chosen per ADR-003, and chosen differently on each side. The
Gleam side is a self-contained codec in `core/msgpack`: pure Gleam over
bit arrays, covering exactly the subset the protocol uses, decoding
totally (truncation, ext tags, invalid UTF-8, trailing bytes, and
non-finite floats are all corruption reports, never crashes) and encoding
canonically, smallest-form, so equal values always produce identical
bytes. The Go side uses `vmihailenco/msgpack/v5`, mature and already
inside trusted native code. Keeping them byte-compatible is not a hope:
**golden fixtures under `protocol/msgpack-fixtures/` pin the canonical
encoding of every value shape**, and both suites assert byte-exact
encoding and successful decoding of the same files.

The sandbox policy travels the same way, as `SandboxPolicyV1` — a
versioned map of writable roots, readable roots, protected paths, a
network mode, limits, an environment allowlist, and a scratch choice. The
helper's decoder is unforgiving: a version other than 1, a missing key,
an *unknown* key, a wrong type, a relative path, or trailing bytes after
the map all fail the parse. Unknown keys are refused rather than ignored
precisely because a field we do not understand could be a restriction we
would silently fail to enforce.

One wrinkle looks like a hack until you see the constraint. The helper's
base policy must arrive on **file descriptor 3** at spawn, but Erlang
ports cannot map arbitrary file descriptors. So the broker writes the
policy to a mode-0600 file inside a mode-0700 directory and starts the
helper through `/bin/sh -c 'exec 3<"$2" "$1"'` with the paths as
positional parameters, sidestepping every quoting pitfall; the shell
opens the file as fd 3 and execs the helper. The file is unlinked the
moment the helper's hello proves it was read. Per-execution policy still
travels inside `exec_start` and remains authoritative there; fd 3 only
seeds the helper.

## The jail

`loom-exec` is one static Go binary with three roles: server mode (read
fd 3, speak the protocol on stdio), stage 2 (restrict itself and exec the
target), and `--self-test`. It runs **one execution at a time** — a
second `exec_start` gets a `busy` error, and concurrency lives in the
broker's pool, which runs more helpers, so lifecycle ownership stays
unambiguous. A Linux execution takes this shape:

```
  helper ─spawn(setsid)─▶ bwrap ─▶ loom-exec --exec ─execve─▶ target
    │                       │            │                      │
    ├ pgroup: cancel/sweep  │            ├ rlimits: CPU, FSIZE  │ starts
    ├ cgroup v2: memory.max │            ├ Landlock ruleset     │ already
    │            pids.max   │            ├ no_new_privs         │ inside
    └ output caps, wall     │            └ seccomp: network off │ the cage
                            └ namespaces + the mount view ──────┘
```

On macOS, the helper wraps the same stage 2 in the pinned
`/usr/bin/sandbox-exec` and a generated deny-default Seatbelt profile.
The host filesystem is readable and read-only by default; typed writable
roots and a fresh private scratch directory are grants, while protected
logical and resolved paths are final subtractive denies. AF_UNIX remains
available for capability sockets. Internet bind/connect is absent unless
the policy says `NetworkFull`. Paths cross into SBPL only through `-D`
parameters, never string interpolation, and the fd-4 report witnesses that
stage 2 actually started inside the profile before `seatbelt` or its audit
tags are published.

**bwrap owns every namespace and mount.** This is load-bearing, not a
preference: the Go runtime is multithreaded from the first instruction,
and `unshare`/fork-based namespace assembly in a multithreaded process is
the tar pit that gave runc its `nsexec.c`. The helper only composes a
bubblewrap argument list — pure data, golden-tested — and stacks
in-process restrictions on itself afterward. The argv order is itself
load-bearing, since bwrap applies mounts in order — so the helper does
not leave that order to how the policy's four path lists happen to be
concatenated. It resolves the policy into an explicit, ordered mount
plan under two rules. **Grants first, masks last, and nothing after a
mask**: the readable and writable binds and the scratch area widen the
view, while fresh `/proc`, a minimal `/dev` and the protected-path masks
subtract from it, and a widening emitted after a mask undoes it and fails
open. **Within a phase, the most specific region wins**: operations sort
parent-before-child, so a readable root nested inside a writable root
comes out read-only and a writable root under the scratch mount survives
it. Masks are exempt from the second rule against grants, because
`protected` is the only subtractive verb the policy has and nothing may
carve a hole in it. A protected path is removed from the view whatever
its inode type: a directory, or a path that does not exist yet, is
shadowed by an empty read-only tmpfs, and a file by a read-only bind of
an empty device — neither can be read through, written through, or
created in. Under network-off, bwrap also unshares the network
namespace.

**Stage 2 restricts itself and execs.** After changing directory it sets
`RLIMIT_FSIZE` and `RLIMIT_CPU`, applies a Landlock ruleset derived
purely from the policy, sets `no_new_privs` unconditionally, installs the
seccomp filter when the network is off, writes an enforcement report on
fd 4, and calls `execve`. That order works because Landlock domains,
seccomp filters, rlimits, and `no_new_privs` all persist across `execve`
and can only tighten: the target starts life inside the cage with none of
our code left in its address space. Landlock is the second filesystem
layer, and the only one in degraded mode; it has no deny rules, so a
protected path nested inside a writable root cannot be carved out there.
Masking those is bwrap's job, and the enforcement report tells the broker
whether bwrap ran.

The seccomp filter enforces network-off at the point seccomp can actually
reach: **socket creation**. A filter cannot dereference the sockaddr
passed to `connect`, but it can read the integer domain argument of
`socket` and `socketpair`. A process that can never obtain an
`AF_INET`/`AF_INET6`/`AF_PACKET` socket has nothing to connect, bind, or
send with, and the helper builds the child's whole fd table, so no
network descriptor can be smuggled in either. `AF_UNIX` stays allowed,
confined by the filesystem layers. Three details earn their place: the
program is built as pure data and unit-tested without a kernel; it kills
the process on an unexpected audit architecture and, on amd64, on any
x32-ABI syscall (both classic filter bypasses); and non-`AF_UNIX` socket
creation fails with `EPERM` rather than a kill, so tools that probe for
network and fall back keep working. Installation uses
`SECCOMP_FILTER_FLAG_TSYNC` so the filter binds *every* thread of the Go
runtime — without it another thread could simply make the blocked call —
and a partial sync is an error rather than a success.

Linux memory and process-count ceilings need cgroup v2, because `RLIMIT_AS` is
per-process and escaped by forking and `RLIMIT_NPROC` is per-user. Each
execution gets its own group with `memory.max` and `pids.max`, and
descendants inherit membership, which is what makes the pids cap
fork-bomb-proof. The group's own `pids.events` counter is the ground
truth for whether the cap fired, rather than shell complaints about
failed forks.

Darwin has no per-execution cgroup equivalent. Stage 2 attempts a finite
`RLIMIT_AS`; current kernels reject it with `EINVAL`, which becomes an
explicit `skip:rlimit-address-space` and therefore fails a strict demand.
`RLIMIT_NPROC` is per-user, so Loom first measures the account's live process
floor. It applies the ceiling only when that floor leaves a 16-process reserve
below the request; otherwise it reports `skip:rlimit-processes` rather than
breaking every legitimate fork on a busy developer account. The reserve
narrows, but cannot eliminate, a race with concurrent same-user forks between
the sample and `setrlimit`. This is deliberately weaker than Linux cgroups and
the report says so.

Everything else is plumbing with teeth. The child's environment is
**constructed, never inherited**: a variable absent from `env_allow` is
dropped even when the broker sent it, so the policy alone documents what
a jail could see. Output is capped per stream, and past the cap the
helper keeps reading and discarding so the child never blocks on a full
pipe. And `Wait` runs in a deliberate order: reap the direct child,
sweep the group with `SIGKILL` (killing orphaned grandchildren that still
hold the output pipes), then join the output pumps — which is why a
backgrounded `sleep 30` does not hold the execution open.

### Cancellation, and who each rung is addressed to

`SIGTERM`, then `SIGKILL` two seconds later, inside a broker-side helper
grace of three seconds and the relay's five, each layer outwaiting the
one below. The two rungs have **different addressees**, and that is the
whole of the design.

Under bwrap the helper's direct child is a *supervisor*, with a second
bwrap as the new PID namespace's init below it and the payload below
that. The supervisor is spawned `--die-with-parent`, so TERMing the
process group kills it, its death `SIGKILL`s the namespace init, and
killing a PID namespace's init kills every process in that namespace.
Measured: a payload with `trap "" TERM` died in 813 µs, by `SIGKILL`,
having never been asked to stop. The grace bought nobody anything.

So TERM is addressed to **the payload and everything it spawned**, and
only the KILL rung takes the whole group. The payload is found by
descent, not by process group: the walk starts at the supervisor and
takes everything at depth two or more, which is exactly "the cage, and
then what is inside it". A process group is something a process can
leave with one unprivileged `setsid(2)`, and a selection that scanned the
group came back empty for such a payload and fell back to signalling the
group — the collapse above, on a payload nothing had asked to stop. A
process cannot leave the descent, and under `--unshare-pid` the kernel
reparents orphans onto the namespace's own init rather than onto host
pid 1, so the walk enumerates the whole jail. Both exclusions are
**structural** — the supervisor whose pid the helper holds because it
spawned it, and that process's own direct children — because the earlier
rule read `NSpid` out of `/proc` and spared anything that looked like a
namespace init, a shape `unshare -U -p -f` hands a payload for free.

That makes TERM **complete under bwrap and best-effort without it**. In
degraded mode there is no namespace, the group leader is the payload
itself, and a payload that calls `setsid(2)` leaves the group with
nothing to put it back. One more thing a missing bwrap costs, reported
as degraded like the rest, and bounded by the KILL rung's group sweep.

The result says whether the ladder was climbed. `exec_exit.cancelled` is
a field of its own because no other one can carry it: a cancelled run
whose payload had backgrounded its work reports `code=0 signal=0`, a
clean success for an execution that was truncated, and `code=143` is
what `sh -c 'exit 143'` reports with no cancel at all
(`protocol-change/006`).

Darwin has no PID namespace. The helper therefore starts behind a gate,
records observed descendants with both PID and birth time, and sends TERM and
KILL to both the original process group and the still-live recorded set. The
group gives immediate delivery to ordinary descendants; the tracker covers an
observed child that called `setsid(2)`, rechecking its birth immediately before
signaling. Darwin has no stable process handle, so that check is not atomic
with `kill(2)`. Nor can it close the interval between process-table samples: a
rapid daemonizing double-fork can be reparented to `launchd` before its ancestry
is recorded. The helper bounds output draining, so even an untracked process
holding a pipe cannot hold the execution result open forever.
Every Darwin execution therefore carries `skip:darwin-process-lifecycle`, so
`FullEnforcement` refuses the stronger claim. The production
`PlatformEnforcement` demand accepts this one declared lifecycle gap, plus the
two Darwin resource-limit gaps in ADR-006, only when the report names each one.
Seatbelt itself is inherited across forks; a missed descendant remains
filesystem- and network-confined, but may violate execution-lifetime and
wall-clock cleanup guarantees.

### Enforced versus reported

A helper on a kernel that cannot provide a layer does not pretend. It
reports what it has in `hello.features` and, per execution, in an
`enforcement` list and a `degraded` flag: strings like `bwrap`,
`mounts:ro=2,rw=1,mask=3,scratch=tmpfs,plan=…`, `landlock:abi=5`,
`seccomp-net`, `seatbelt-net`, `rlimit-cpu`, `skip:landlock: ...`. The broker decides
what to do about it. `PlatformEnforcement`, the production default, refuses a
degraded helper and requires every layer the selected platform promises. On
Darwin it tolerates only ADR-006's three named gaps, each reported explicitly.
On Linux it has the same result as `FullEnforcement`, which rejects every gap
on either platform. `BestEffort` accepts what is available and still hands the
report to the caller.

**Presence is the claim, and silence is a skip.** The helper's hello selects
the platform matrix. Linux requires `bwrap`, `mounts`, `landlock` and
`no-new-privs`, plus `seccomp-net` and `cgroup-v2` when their policy fields
are active. Darwin requires `seatbelt`, `seatbelt-fs`, `seatbelt-net`, and
the requested rlimit tags. Both require `rlimit-cpu` and `rlimit-fsize` under
theirs. A required layer that never appears fails the demand exactly as a
`skip:` entry does. The
earlier test was "no `skip:` entries", which a *silent* helper passes: a
stage 2 that died before writing fd 4 produced `enforcement: ["bwrap"]`,
containing no skip, and satisfied a full-enforcement demand with the
entire inner report missing.

Two rules make the helper's side of that honest. `bwrap` and the
`mounts:` audit are claimed **only when stage 2 reported**, because that
report is the one thing that could not have arrived unless bubblewrap
built the namespace and exec'd into it — bwrap merely being on `PATH`
proved nothing. And a stage 2 that says nothing yields `skip:stage2: …`
rather than an absent inner report.

The `mounts:` entry is what gives the mount layer something to say at
all. Its counts are not of operations requested — those are identical in
a healthy plan and in one whose mask a later bind undoes — but of the
policy's own paths whose **effective view, after replaying the whole
ordered plan, is the one the policy asked for**. A defeated mask drops
out of `mask=` and emits a `skip:mounts:` naming the path and the
operation that re-exposed it. The broker holds the policy it sent, so
those counts are checkable against it; the `plan=` digest is a diffing
aid, not a check, because nobody holds the expected value.

One gap is deliberately not folded into that vocabulary. A kernel missing
a layer is an *environmental* gap, and degraded is the honest word for it.
A build with no jail for its operating system is a gap in Loom, and
running under `BestEffort` there would mean model-influenced code
executing with `network: off` in its policy and nothing enforcing it. Linux
and macOS now have phase-appropriate jails. Windows and unknown targets
remain unsupported, so the helper **refuses to serve on them** unless started
with `--allow-unenforced`. Where it is asked to serve anyway,
`hello.features` carries `platform-unsupported`, every
`enforcement` list leads with `skip:jail: ...`, and `--self-test` prints
`RESULT: UNSUPPORTED PLATFORM` and exits nonzero instead of calling zero
attempted probes a pass.

`loom-exec --self-test` runs nine probes through the real jail path: write
outside the writable roots, read or write a protected path, create a socket
under network-off, read a non-allowlisted environment variable, fork-bomb
against the pids cap, flood output past the cap, orphan a grandchild, escape
the process group with `setsid` long enough to be observed, and load a hostile
unvetted BEAM. The Darwin result does not generalize that observed case into
rapid-reparenting containment; its per-exec skip records the remaining gap. A probe
whose layer the environment cannot provide prints
`SKIPPED` with the reason — never faking a pass, never failing the run —
while a probe whose layer *is* available must enforce or the run exits
nonzero. The summary lists enforced and skipped separately, so a green
self-test in a neutered container cannot be mistaken for a verified
sandbox.

## Tools with correctness teeth

A tool is a record: name, description, JSON schema, replay safety,
execution mode, policy-shaped requirements as a function of the workspace
root, and a `run` taking a context and the model's arguments. Tool
failures are **data** — `run` always returns an outcome whose `is_error`
marks in-band failure, so a bad argument, a policy refusal, a dead
helper, or a stale anchor comes back as a result the model can read and
react to, and an unknown name yields the same shape.

**Replay safety is a claim about what re-execution does to the world.**
`bash` declares `Never`: a shell command is an arbitrary external effect,
so a crash mid-execution must yield a synthetic interrupted result under
the pre-reserved id rather than run again. `fs_edit` declares `Safe`, and
the reason is the interesting one — its anchors *consume themselves*.
Applying a plan removes the lines it referenced, so re-executing the same
call against the already-edited file is rejected as stale rather than
applied twice: re-execution after a crash either repeats an edit that
never landed or fails in-band, and cannot double-apply. `fs_write` is
`Safe` because writing the same bytes to the same path is idempotent, and
`fs_read` and `grep` are `Safe` because they are reads.

**Hashline anchors make a stale edit impossible rather than unlikely.** A
read renders every line as `line:anchor|text`, where the anchor is the
first eight lowercase hex characters of a 64-bit FNV-1a hash of the
line's UTF-8 bytes. An edit references lines as `{line, anchor}` pairs:
the anchor proves the content, the line number disambiguates identical
lines. `apply` verifies every reference against the current content
*before* touching anything, so an edit planned against a file that has
since changed is rejected before corruption — a time-of-check to
time-of-use defense across the gap between read and write. The rejection
carries fresh anchors with two lines of context around each stale region,
so the caller replans without a second full read, and anchors depend only
on line content, so an unrelated edit elsewhere never invalidates them.
(The spec named `xxh3`; the implementation reads that as intent — a fast
64-bit hash truncated to eight hex — since anchors never outlive one
read-edit round trip and are versioned in-package. Recorded as a spec
gap, and it settles the open question about anchor length and salt:
eight hex, no salt.)

Output that would swamp the transcript **overflows to a blob store**.
Past 64 KiB the full bytes are written once under a content-addressed
name (SHA-256), and the result carries `{ref, size, head_excerpt,
tail_excerpt}` with excerpts of at most 2 KiB trimmed to a UTF-8
boundary. Content addressing makes the write idempotent: replaying a
`Safe` tool or re-running an identical command lands the same bytes at
the same ref. `fs_read` is exempt, because windowed reads are already its
bound and anchors buried inside an elided blob would defeat hashline
editing; `bash` and `grep` output do overflow.

The filesystem tools run **harness-side rather than through the broker**,
so their path discipline is their own responsibility: `resolve_path`
rejects empty paths and anything resolving outside the workspace root,
whether by `..` or by an absolute path. Under Rule Zero this is defense
in depth rather than the primary control — no model-chosen program runs
here, only our own code on model-supplied arguments — and the tools still
declare policy-shaped requirements so a policy audit covers every tool
uniformly.

`bash` shows the composition path end to end. It requires the workspace
writable, `/` readable (interpreters live outside the workspace, and the
session base decides whether to grant that), network off, tmpfs scratch,
and the environment names actually being passed, so composition checks
them against the session allowlist. It clears with `RefuseNarrowed`: a
session base that does not cover the requirements produces an in-band
structured refusal carrying the exact wanted grants, ready for the
escalation flow. Its timeout is clamped tool-side — 120 seconds by
default, 600 as the ceiling — and the wall limit mirrors it. `grep` runs
`rg --json` read-only and, when the jail has no ripgrep, settles as a
structured error suggesting `bash` instead.

## Providers

The gateway is a typed registry plus injected effects: an HTTP transport,
a secret store, and a clock. `resolve(role)` returns the first target in
the role's ordered fallback chain whose provider is registered — the
identity durable state stores. `request` with a role resolves the chain
at dispatch and walks it, moving to the next target only on a
*retryably*-classified failure; a terminal error surfaces immediately, an
exhausted chain delivers the last real error rather than a summary, and a
settled response never falls back. The role target also carries an
optional reasoning-budget overlay (`protocol-change/009`), applied to the
whole chain before the walk starts, so a fallback is asked for the budget
the caller asked for rather than for whatever its own route row declares.
`request` with an already-resolved identity dispatches to exactly that
identity and never walks.

Which of the two a live session uses is the model plane's decision, not
the gateway's, and `docs/architecture/models.md` has it: role follows
identity, so a generation whose captured identity heads a routable role's
chain goes out as a role and walks, while an off-route identity and every
deferred poll go out already resolved.

Streaming follows the sans-io shape. The parser for server-sent events —
the framing every provider streams over — is **pure**: bytes in, events
out, carry state threaded, so feeding the same bytes in any chunking
yields the same events, and the whole parser is property-tested without a
single process. Adapters compose it with their own pure
accumulator into a response machine, a fold over HTTP events; only `run`
is impure, starting a monitorable transport owner and forwarding deltas as
they appear. Composition uses a prepare-publish-begin seam: a
`PreparedStream` exposes its parked owner before route resolution, secret
lookup, or transport work starts, and the runtime grants the begin permit only
after its reaper has adopted that owner. The consumption contract is narrow enough to
depend on: zero or more `Delta` events, then exactly one `Settled` or
`Failed`, and nothing after. Deltas are ephemeral display data and prove
nothing about settlement.

The returned `StreamHandle` carries the event subject, an idempotent cancel
capability, and an optional drain-witness pid. A minimal public custodian owns
that capability but performs no provider work. It adopts the gateway guard,
private fallback pump, and every transport owner before each begins. The guard
tracks the pump's current transport; the pump owns the provider terminal race
and will not start another fallback until that transport drains. Teardown
first invokes the transport's cancellation capability, then observes bounded
owner death. If it does not retire, the guard reports uncertainty while the
custodian remains alive; killing the witness would erase the proof that native
work stopped. The production transport uses one native owner rather than
another Gleam custodian-and-worker pair. Its narrow Erlang FFI retains the
exact opaque OTP `httpc` request id and dedicated request-handler pid. The
owner receives the raw messages itself, disables handler migration, captures
the handler through the manager's already-published request table in O(1),
issues OTP's asynchronous cancel cast, and waits for that handler to exit. It
does not scan processes or call handler diagnostics.
The request and terminal state machines remain Gleam. Raw OTP errors become
constant diagnostics at the boundary so a request header cannot leak through
a durable provider error.

An owner-authored `ProviderCancelled` proves cancellation won. A guard or
wrapper whose inner owner stays silent for the fixed grace instead emits
terminal `CancellationUnconfirmed`; uncertainty cannot authorize a fallback
or retry. This distinction is what stops the external work rather than merely
teaching the caller to ignore a late answer. Protocol change 010 fixes the
contract and its race semantics.

**Stop reasons map totally.** Each adapter maps the vocabulary it knows
and answers `Error(Nil)` for anything else, which the caller surfaces as
`Failed(UnmappedStopReason(raw))` in-band. A provider that ships a new
stop reason tomorrow degrades to a readable error, never a crash.

**The adapter computes overflow, and the definition is now written
down.** When reported input plus cache-read tokens exceed the resolved
model's context window and the output is negligible, the response settles
with stop reason `error` carrying the canonical overflow message, raw
stop reason preserved. This matters because the machine's classification
order checks overflow before retryable error: an oversized request must
compact, not retry unchanged. "Negligible" was left open by the spec and
is quantified in the code as at most 64 output tokens, so a real answer
that merely tripped a counter is never discarded as overflow.

Decoding posture here is deliberately asymmetric to the rest of the
system. Stream payloads must parse as JSON — malformed data fails the
stream in-band as a corruption report — but *fields* are read leniently:
absent counters read as zero and unknown enum values are ignored, which
is what provider versioning policies prescribe. The total-decoder
doctrine governs boundaries we own; strict decoding of a foreign
vocabulary breaks against real proxies and gains nothing.

**Secrets live in exactly one place.** Provider configuration holds a
secret *name*, never a value. The secret store is an injected lookup
whose only call site is gateway dispatch, which copies the value straight
into one outbound request header. Errors carry names and status codes and
never headers, bodies, or values, so nothing the gateway returns or
persists can embed a key; a grep-based leak test over a full session
fixture is the check. The environment-variable backend ships now, and OS
keychain backends slot into the same `fn(name) -> Result(String, Nil)`
seam without touching a caller.

**And nowhere on a log line.** The same invariant reaches telemetry, and
it is enforced rather than asked for: every field a log record carries
passes through `telemetry/field.scrub`, which redacts any field whose
key names a credential and any token in free text that carries a vendor
prefix or is an unbroken run of at least 32 credential-alphabet
characters. The threshold is chosen against what this tree holds — the
broker's clearance token and the cap channel's token are both 32 random
bytes, which is 64 hex or 43 base64url characters. The Erlang formatter
calls back into the same function for lines the harness did not author,
so an OTP crash report that happened to hold a token is scrubbed too.
The exemption is typed: `field.ident` opts a value out of the *shape*
rule alone, never out of the key rule, so every waiver is a deliberate
and greppable act. The check is a test that plants a provider key, a
clearance token and a channel token under both a denylisted and an
innocent key, renders, and greps the bytes
(`packages/telemetry/test/telemetry/redaction_test.gleam`).

## What the end-to-end actually proves

The M2 acceptance runs the production wiring: the real provider gateway
over a scripted SSE transport, the real ToolBroker over the **real Go
`loom-exec` helper**, and the real tool registry. It is feature-detected —
with no Go toolchain the tests print a skip reason and pass.

The happy path drives four settlements from one prompt. `bash` writes
`notes.txt` inside the jail; `fs_read` returns its hashline anchors;
`fs_edit` applies an anchored replace scripted against those anchors; a
text answer completes the run. The assertions are specific: the file on
disk is byte-exact `alpha\nbeta improved\ngamma\n`; the projected
transcript matches shape for shape; the `bash` result's details carry the
helper's real exit code and signal alongside its honest `degraded` flag
and `enforcement` list; the read result contains exactly the anchors the
scripted edit used, which proves the two tools agree rather than the
fixture agreeing with itself; the usage ledger equals the scripted total;
and closing and reopening the session file yields a structurally
identical transcript.

The crash rider reproduces the crash-mid-tool scenario live. A `bash`
call runs `: > started.marker && sleep 30`; the test waits for the marker
so the kill lands with the tool intent durable and the external effect
genuinely in flight, then kills the whole supervision tree. On reboot
from the same file, recovery finds an effect-pending call with no live
continuation, `replay: Never` forbids re-execution, and the synthetic
interrupted result settles under the reserved id; the remaining script
completes the run. The ledger total is unchanged — each settlement
committed usage exactly once, crash included.

Integration also found a bug no unit test could have. Budget deadlines
are computed on the tool-side clock and checked against the broker-side
clock, and nothing in the contracts required the injected clocks to share
an era; misaligned eras made the broker refuse every call as already past
its deadline. The fix is a convention the spec should state: one clock,
or at least one era, injected across runtime, tools, and broker. The
simulation runner makes that convention structural for a simulated
session: one logical clock is shared by everything that reads time, and
the driver's own delayed wakeups go through an injected timer seam
(`effects.Timers`, with `effects.real_timers()` for production) so they
run on the same time base rather than on the VM's timer wheel.

Finally, the honest enforcement matrix. In the development container
`loom-exec` reports `rlimits, pgroup, degraded, seccomp` — no bubblewrap
binary, no Landlock in the kernel, no delegated cgroup v2 hierarchy — so
four of the seven self-test probes enforce there and the three needing
the missing layers skip. The suites therefore run with `BestEffort` and
assert on the helper's honest report. Production sessions pass
`PlatformEnforcement`: strict on Linux, and strict about Darwin's real
Seatbelt boundary while admitting only ADR-006's explicit platform gaps.

## Where the code lives

| Path | What it holds |
|---|---|
| `broker/broker.gleam` | `clear_call`, the relay, abort, settlement. |
| `broker/policy.gleam` | `SandboxPolicyV1` as a typed value; composition, grants, narrowings; the canonical codec. |
| `broker/token.gleam`, `broker/budget.gleam` | Capability tokens — minting, binding, constant-time check, revocation — and pooled per-execution ledgers. |
| `broker/escalation.gleam` | The denial → approval → single-consume machine and its events. |
| `broker/framing.gleam`, `broker/exec.gleam` | The protocol broker-side with its pure deframer; the helper actor, fd-3 spawn, cancel ladder, and pool. |
| `sandbox/cmd/loom-exec/main.go` | Role selection by first argument: server mode, `--exec` (stage 2), `--self-test`, `--probe-socket`, and `--allow-unenforced`, which serves on a platform Loom has no jail for. |
| `sandbox/internal/jail/platform.go` | Whether this *build* has a jail for its OS at all — a different question from what the running kernel provides, and kept apart from it everywhere it surfaces. |
| `sandbox/internal/policy`, `.../framing`, `.../server` | The strict policy decoder, the protocol helper-side, and the frame loop. |
| `sandbox/internal/jail` | bwrap argv, stage 2, env construction, output limiter, cancel escalation, supervision. |
| `sandbox/internal/llock`, `.../seccompf`, `.../cgroup` | Landlock rules, the network-off cBPF program with its TSYNC install, and cgroup v2 groups. |
| `sandbox/internal/selftest` | The seven regression probes and the enforced/skipped report. |
| `tools/tool.gleam`, `tools/hashline.gleam` | The tool record, seams, registry, and in-band outcomes; anchors, windows, anchor-checked plans, stale rejections. |
| `tools/fs.gleam`, `tools/bash.gleam`, `tools/grep.gleam` | The filesystem tools with their path discipline, and the two jailed ones. |
| `tools/blob.gleam` | Content-addressed overflow past 64 KiB. |
| `provider/gateway.gleam`, `provider/secret.gleam` | The registry, role resolution, and the fallback walk; the secret-name lookup seam. |
| `provider/stream.gleam` | Stream events, the pure server-sent-events parser, the transport pump. |
| `provider/adapter/anthropic.gleam`, `.../openai.gleam` | Request construction, response accumulation, total stop-reason mapping, overflow. |
| `client/wiring.gleam` | The production effect record: the seam between the pure planes and this one. Its module doc is the list of mapping decisions. |
| `client/escalate.gleam` | Parking: raise on every policy refusal, hold the call while a human decides, consume the approval and re-clear once. |
| `conformance` test suites `wiring_test.gleam`, `e2e_test.gleam` | The adapter's mappings against fakes, and the M2 jailed acceptance that proves the record end to end. Both live under `packages/conformance/test/conformance/`. |
| `protocol/msgpack-fixtures/` | Golden frames both languages are pinned against. |

Each Gleam path is relative to its package's source root —
`broker/token.gleam` is `packages/broker/src/broker/token.gleam` — and
each Go path is relative to `packages/sandbox`. For the plane below this
one see `docs/architecture/durability.md`, and for the state machine and
runtime that drive these effects, `docs/architecture/orchestration.md`.
For intent and contracts, `docs/loom-design.md` §5 covers the threat
model and the two-channel doctrine, `docs/loom-implementation-spec.md`
Part 1.4 holds the frozen wire protocol and §3.3 the security invariants,
`docs/adr/003-msgpack.md` records the codec decision, and
`docs/spec-gaps.md` records where implementation refined the spec —
including the fd-3 delivery workaround, the anchor hash, and the shared
clock era.
