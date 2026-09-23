# The effect plane

The effect plane is the only way Loom acts on the world outside the
harness process: shell commands, file edits, searches and model requests
all leave through it. Every effect passes through the **ToolBroker**
(`broker`). A framed msgpack **wire** carries it to `loom-exec`
(`sandbox`), a small Go **jail** helper that restricts itself and then
execs the target. The **tools** (`tools`) stay correct however the model
behaves, and the **provider gateway** (`provider`) streams model output.
Orchestration drives these effects; durability is the plane below.

## The threat model, and Rule Zero

Loom defends against four threats, in increasing order of difficulty:
**accidents** (a delete in the wrong directory, a force-push, a `.env`
swept into a commit); **prompt injection** (hostile repository, web, or
tool content steering the model toward exfiltration or destruction);
**malicious generated code** (a program the model wrote attempting escape
or persistence); and **compromised third-party tools** (a malicious
language server, or a Model Context Protocol server). It does not defend
against a hostile user on their own machine, or against kernel zero-days:
surface is reduced, but machine-grade isolation waits for the microVM tier.

The defense rests on one rule, because BEAM processes provide fault
isolation, not security isolation. Any process in the virtual machine can
call `os:cmd/1`, open any file the OS user can open, and dial the
network; there is no capability model inside the VM to rely on.

> **Rule Zero: model-influenced execution never runs in the harness VM.**
> The BEAM node orchestrates. Untrusted work runs in OS-sandboxed
> external processes under kernel-enforced policy. The actor model buys
> supervision and recovery; the kernel buys isolation; the two are never
> confused.

## The one door

Every effect goes through `broker.clear_call`. It composes a policy,
refuses or narrows the call, reserves budget, mints a token, borrows a
helper, and dispatches. From the moment it dispatches, the caller is
guaranteed exactly one settlement event, whatever happens downstream.

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

### Composition and narrowing

**Composition is most-restrictive-wins, and grants are the only
widening.** `policy.compose` takes the meet of the session base and the
tool's requirements, field by field:

- Root coverage is prefix-aware. A base root `/work` covers a requested
  `/work/sub`, and the result is the *requested*, narrower root.
- The network lattice meets at `Off < Proxy < Full`.
- Each limit takes the per-field minimum, with `0` meaning unlimited.
- Environment allowlists intersect as exact strings.
- Protected paths union.
- Two different scratch choices collapse to a fresh tmpfs.
- Two proxy policies intersect their host allowlists and always keep the
  base's proxy address, because the harness owns the proxy and a tool
  must not redirect egress.

Only after the meet do approved grants apply, each one explicitly
widening one field.

Composition also reports what it took away. Every requirement the final
policy fails to satisfy becomes a `Narrowing`. `wanted_grants` turns that
list into exactly the grants that would satisfy it, and that set is the
policy diff an escalation shows a human ("wants: network to
registry.npmjs.org"). The caller chooses between two modes.
`RefuseNarrowed` turns any shortfall into a structured denial before
anything runs. `ProceedNarrowed` runs under the narrowed policy and lets
the sandbox's own denial report the problem.

### Tokens, budgets, and the helper pool

**Tokens bind and are spent once.** A token is 32 bytes from an injected
entropy source, carrying a `Binding` of `{op_id, step_id, policy,
deadline_ms}`. It travels only over the channel it authorizes and is
checked on every use; `check_for` additionally requires the token to name
exactly this operation and step. Bytes are compared in constant time, and
the vault scans every entry without an early exit, so timing reveals
neither a match's position nor how close a guess came. Refusals are
ordered: unknown, revoked, expired, wrong binding. Settlement revokes the
token, so no token is ever good twice.

**Budgets are pooled per execution, not per call.** One `Budget` carries
a cap on outstanding effects and one aggregate wall deadline, and every
effect under the token reserves against the same ledger. Pooling closes
the amplification hole: ten thousand parallel reads or fifty spawned test
runs share one account and are refused past the cap, however reasonable
each request looks alone. Settling with nothing outstanding is a no-op
rather than an error. Settlement can race a crash-driven cleanup, and a
double settlement must never underflow into free budget.

**The helper pool is a separate ceiling from the budget, and a full pool
means congestion, not refusal.** `max_outstanding` refuses amplification.
The pool size is how many jails this host can afford at once, since every
helper is an OS process running bwrap and a jail. It is sized from the
node's scheduler count, clamped to `[4, 16]`, and overridable with
`LOOM_HELPER_POOL`. It is a number, never a literal, because it is also
the real ceiling on how wide a parallel tool batch runs. A batch wider
than the pool therefore *waits* for a slot instead of handing the model a
resource error for its third call: `clear_call` retries within the
caller's own clearance budget.

The wait happens in the borrower's process, and that placement is what
makes it correct. The broker checks a helper out synchronously inside its
own message handler, and checks one back in only from `Settle`, a message
it can process only while it is not blocked. A queueing pool that
deferred its checkout reply, or a broker that blocked waiting on one,
would wait for a resource that only its own message loop could release.
Retrying from outside the broker cannot reach that state.

Nothing is held across the wait. The checkout-failure path returns the
reserved budget slot and revokes the minted token before it answers, so a
waiter owns no ledger slot, no token and no helper. Progress depends only
on running executions ending, which their wall deadlines guarantee. The
wait is bounded rather than indefinite, so a nested borrower (a code-mode
satellite holding one helper while its capability calls ask for another)
gets the refusal it always got instead of stalling.

**Every waiter leaves with a verdict.** This second property needs its
own machinery. The retry loop reserves a window in which it expects the
broker could answer, and stops rather than issue an exchange with only a
few milliseconds left. The margin exists because the broker is serial,
and a clearance it grants blocks it for a relay handshake, a helper
handshake and a checkout. The exchange itself returns an answer instead
of crashing. An ordinary `process.call` crashes its caller on a timeout
or a dead callee, and the caller here is a strand's effect process
holding the very refusal the model was meant to read. (A *strand* is a
named line of work: the main conversation, a subagent.) The cases no
margin covers, a broker slower than the caller's whole budget or one
stopped underneath a waiting caller, come back as `BrokerUnavailable`
instead of crashing the strand.

### Relay, settlement, and abort

Each dispatched call gets a **relay** process that owns the execution's
event subject. The relay forwards output, enforces the wall deadline, and
reports settlement back to the broker. Past the deadline it cancels, then
drains for a five-second grace window, relying on the helper's own cancel
ladder to produce a terminal event. If none arrives, the call settles as
`CancelEscalated`. Dispatch failures take the same path, so "exactly one
`CallSettled`" holds even when the helper refuses the work.

**Abort revokes and kills.** `broker.abort(op_id)` revokes every token of
that operation and cancels every execution under it. Cancellation reaches
the OS as a signal to the process *group*, so no orphaned `npm install`
is left behind.

### Escalation

Approval escalation is a separate pure state machine that consumes the
broker's denials. An approval may contain only grants drawn from the
denial's wanted diff. A subset is fine; a wider grant is a new decision,
not an addition to this one. `consume` yields the approved grants for
exactly *one* re-execution and refuses a second. Each transition returns
an `Event` for the runtime to record durably before acting on it, so the
transcript shows the denial, the decision, and the single retry. Widening
the session base is the caller applying approved grants explicitly, never
a silent side effect.

**Who drives that machine in production.** `client/escalate` connects a
broker refusal to a human. It wraps `Ctx.clear_call`, and a
`PolicyRefused` (only a policy refusal) files a durable record scoped to
the exact call: `{operation, strand, step, source index, call id}`. The
record's id is derived from `{strand, tool, wanted diff}`, so a retry
loop lands on the record already pending.

If the host says a client is attached, the refusal then **parks**. The
call is held open on its own effect process until the record is decided,
the window closes, or the client goes away. It never parks on the strand
driver, which must keep serving aborts. An approval is consumed by
compare-and-swap, and the same call is re-cleared once under the widened
policy. The window is the smaller of a configured timeout and the call's
own budget deadline, because the ledger refuses a reservation past that
instant. Which raised records interrupt a person is a client-surface
decision, not a runtime one.

## Session approval lifetime

The TUI automatically presents each pending request with three choices:
once only, for the session, or deny. A session approval retains only the
displayed filesystem or full-network grants. `client/permissions`
prepares their durable union, and
`runtime/api.approve_escalation_with_fact_at` writes that union and the
approval in one transaction guarded by both observed sequences. Dispatch
captures the standing authority once, without changing a running
execution's policy.

Native pre-I/O checks and declared permission preflights can identify an
exact missing grant. Raw shell syscall errors and refusals inside a
running code-mode program remain ordinary results: the executor does not
report a canonical missing grant, and replay could repeat earlier
effects. A later invocation can declare the required permissions. See
[protocol 041](../../protocol-change/041-session-approval-dialog.md).

## Session directory additions

The operator's `/add-dir` command commits a canonical directory to the
reserved session fact through `client/directories`, and `client/wiring`
captures those additions for each invocation. `tools/directory_access`
keeps native file authority separate from the jail's system read roots.
`tools/permissions` connects declared needs to existing call-bound
approvals before execution. Background jobs and code-mode capabilities
retain their captured authority. The wire and lifetime rules are in
[protocol 040](../../protocol-change/040-session-directory-access.md).

## Egress

Network access has two routes. Jailed extensions and the extension
installer get HTTPS requests made on their behalf by the broker. Shell
tools get either no network or all of it, as the operator configures.

### Brokered requests for extensions

The `Proxy` rung of the network lattice has never been enforceable.
`policy.narrow_unenforceable` turns every `NetworkProxy` into
`NetworkOff` and records a `NarrowedNetwork`. The egress proxy sidecar
the design described was never built, and the jail's own layers refuse a
socket either way.

ADR-007 does not build the sidecar either. The programs Loom needs to
give the network to are a jailed extension serving `net.request` and
`loom ext install` fetching an archive. Neither needs a socket; each
needs a request made and the response handed back. So `broker/egress`
makes the request, in the harness VM, and the jail's network namespace
stays empty. That preserves the property the proxy was meant to
preserve, without the sidecar.

An `egress.Policy` is the whole permission. It lists exact origins (no
wildcards), the permitted methods, a response size cap, and one deadline
covering connect, every redirect hop and the body. It also names which
certificate roots the handshake may chain to, and the credential
bindings.

A credential binding names an *environment variable*, a header and an
origin, the same shape as `api_key_env` one layer down. The broker reads
the value at request time and injects it only on a hop to that origin.
The key never appears in the extension's source, and no frame on the
capability channel carries it. No `Refusal` variant has a field that
could hold it, so a rendered refusal cannot leak it either.

Only `https` is allowed. Three kinds of header are refused before a
socket exists:

- a caller header that would shadow a bound credential;
- a header the client owns: `Host`, `Content-Length`,
  `Transfer-Encoding`, `Connection`;
- any header, the injected credential's included, that carries a CR, LF
  or NUL. `httpc` type-checks a header without scanning it, and those
  bytes on the wire would let the sender append headers of its own.

A character above latin-1 is refused for the mirror-image reason: `httpc`
rejects such a header itself and puts the offending *value* into the
error term, so a credential holding one would print itself into a
refusal.

A redirect is treated as a new request rather than a continuation.
Scheme, origin and method are re-checked on every hop. A 3xx is followed
only under `SameHost(n)` and only within the origin, and a 303 becomes a
bodyless `GET` that must itself be a permitted method. The size cap is
enforced while the body streams: the request is cancelled the moment the
accumulated body passes the cap, and a declared `Content-Length` over the
cap is refused before any body is read.

TLS always uses `verify_peer` with hostname verification, in tests
included. The suite runs a real loopback TLS origin whose chain is
generated at test time and pins its root, so the client's verification
path runs for real. The untrusted-certificate case uses a second,
unrelated root rather than a disabled check.

TLS session resumption is off. `ssl`'s client session cache is
node-global and keyed on host and port alone, and a resumed TLS 1.2
handshake carries no certificate. With resumption on, a session
established under other roots (by another policy, or by the provider's
own client) could carry a request past the roots it was held to. Turning
it off is also why "no path to `verify_none`" is a claim about every
request, not only the first.

Egress does not bound *what* comes back. A permitted host can hand a
jailed extension any bytes it likes: the allowlist is the trust decision,
and the cap is only a resource bound. The install path uses the same
client under `egress.one_host`, on purpose, so a cap raised for one is
raised for both.

### The shell tools: the operator's `[tools]` table

The `Full` rung of the lattice is reachable, but only by an operator. A
`[tools]` table in `loom.toml` sets `network = "off" | "full"`. The
default is off, and so is the absence of the table. Setting `full` puts
`NetworkFull` on the session base, and `bash` asks for whatever the base
allows rather than stating a network of its own
(`tool.asking_base_network`). The meet is why that indirection exists: a
tool requirement of `NetworkOff` pins a call offline however wide the
base is, so a tool that hard-coded it would make the setting reach
nothing. `grep` does not follow the base. `rg` reads files and needs no
egress, so it stays pinned off under any base.

The same table widens the shell's environment, because `gh` with egress
and no token does not work. The `env` key names host variables read at
boot, `set` (`[tools.set]`) carries literals, and `path` appends
directories after the server's own `PATH` entries. Together they let
`gh` be found and authenticate once the network is open. Every name the
table mentions also joins the base's `env_allow`, since the meet
intersects that list too.

Five names are refused from both lists: `PATH`, `HOME`, `TMPDIR`,
`LOOM_SCRATCH_DIR` and `GIT_CONFIG_GLOBAL`. The server derives `PATH`,
`HOME` and `TMPDIR` from the workspace and the discovered toolchain;
taking them from a config file could select a different compiler or
source the operator's dotfiles inside the jail.

The helper supplies `LOOM_SCRATCH_DIR` after allocating scratch, and the
variable passes through the same environment allowlist. On macOS it
names the private scratch directory. On Linux it names `/tmp` only when
bubblewrap mounted scratch. A configured host scratch path is reported as
configured. When no scratch exists the variable is absent, and
`${LOOM_SCRATCH_DIR:-$TMPDIR}` uses the existing workspace fallback.
Private scratch is removed when the execution retires; a configured host
path persists.

Git uses a generated global configuration in the tool home. Before
admitting model work, `client/git_identity` asks Git for the operator's
global `user.name` and `user.email`, including conditional includes in
the workspace context. Only those two values cross into the generated
file; credentials, hooks and other configuration do not. The read-only
query runs through the broker. Publication uses the helper's fixed
[identity operation](../../protocol-change/043-git-identity-publication.md),
which checks the original policy and walks existing directories through
descriptors without following tool-home symlinks. It creates no
mountpoints, including missing SQLite journal masks beneath writable
directories. It renames a complete temporary file over the destination,
so concurrent sessions always read a complete configuration.

The generated file sets `user.useConfigOnly=true`, so a missing identity
makes a commit fail instead of inventing an email from the hostname.
Repository-local and worktree-local overrides still win, and cherry-picks
retain their authors. Imported operator hooks use their original HOME and
global configuration.

There is deliberately no host allowlist. A host-level
`allow = ["github.com"]` needs the egress proxy this phase does not
build, and a config key that accepted hosts would promise filtering that
nothing enforces. That is the same reason `NetworkProxy` is a wire
variant nothing here can select. So the operator gets the two choices the
enforcement layers can actually honor: no egress, or all of it, per
catalogue, set by the person who stood the server up.

## The wire

One framing protocol carries every data-plane channel: executors today,
satellites and remote pools later.

```
frame    := u32_be length ++ msgpack(map)
map keys := "v":1, "id":u64, "kind":str, "body":map
kinds    :  hello, exec_start, exec_stdin, exec_out, exec_exit,
            cap_call, cap_result, cancel, heartbeat, error
```

The `id` correlates frames: `exec_out` and `exec_exit` reuse their
`exec_start`'s id. Both sides cap a payload at 16 MiB, so a corrupt
length prefix cannot make either side allocate gigabytes. The helper
sends its hello first, so the broker learns the helper's actual feature
set before committing work. The helper refuses every other frame until
the broker's hello answers it.

**Two version numbers answer different questions.** The envelope's `"v"`
versions the container (the length prefix and the four map keys) and has
never changed. The `proto` field in `hello` versions the *body*
vocabulary of the exec channel. Every protocol change to that vocabulary
bumps `proto` on both sides in the same commit. It is at 3, for
`protocol-change/006`'s required `exec_exit.cancelled` and
`protocol-change/014`'s `shutdown` frame.

Keeping the two apart makes a stale helper diagnosable rather than merely
unreadable. Its frames still decode, so the broker reads its hello, detects
which side is behind, and settles with both numbers and the remedy.
Before the split, issue #61 spent an hour on a binary whose only symptom
was a decode failure on a frame several steps later.

**Malformed and unknown are different failures.** A frame that does not
parse closes the channel, after an error frame so the effect can settle
in-band; that is security invariant 6 taken literally. A frame that
parses but names a kind the receiver does not implement gets an in-band
error, and the channel *stays open*, because the peer may be newer and
able to downgrade. Both sides implement both behaviours.

Msgpack was chosen per ADR-003, with a different implementation on each
side. The Gleam side is a self-contained codec in `core/msgpack`: pure
Gleam over bit arrays, covering exactly the subset the protocol uses. It
decodes totally, so truncation, ext tags, invalid UTF-8, trailing bytes,
and non-finite floats are all corruption reports, never crashes. It
encodes canonically in smallest form, so equal values always produce
identical bytes. The Go side uses `vmihailenco/msgpack/v5`, which is
mature and already inside trusted native code. Byte compatibility is
tested rather than assumed: **golden fixtures under
`protocol/msgpack-fixtures/` pin the canonical encoding of every value
shape**, and both suites assert byte-exact encoding and successful
decoding of the same files.

The sandbox policy travels the same way, as `SandboxPolicyV1`: a
versioned map of writable roots, readable roots, protected paths, a
network mode, limits, an environment allowlist, and a scratch choice. The
helper's decoder is strict. A version other than 1, a missing key, an
*unknown* key, a wrong type, a relative path, or trailing bytes after the
map all fail the parse. Unknown keys are refused rather than ignored
because a field the helper does not understand could be a restriction it
would silently fail to enforce.

The helper's base policy must arrive on **file descriptor 3** at spawn,
but Erlang ports cannot map arbitrary file descriptors. So the broker
writes the policy to a mode-0600 file inside a mode-0700 directory and
starts the helper through `/bin/sh -c 'exec 3<"$2" "$1"'`, with the paths
as positional parameters so no quoting is involved. The shell opens the
file as fd 3 and execs the helper. The file is unlinked as soon as the
helper's hello proves it was read. Per-execution policy still travels
inside `exec_start` and is authoritative there; fd 3 only seeds the
helper.

## The jail

`loom-exec` is one static Go binary with three roles: server mode (read
fd 3, speak the protocol on stdio), stage 2 (restrict itself and exec
the target), and `--self-test`. It runs **one execution at a time**; a
second `exec_start` gets a `busy` error. Concurrency comes from the
broker's pool running more helpers, which keeps lifecycle ownership
unambiguous. A Linux execution looks like this:

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
`/usr/bin/sandbox-exec` with a generated deny-default Seatbelt profile.
The host filesystem is readable and read-only by default. Typed writable
roots and a fresh private scratch directory are grants, and protected
logical and resolved paths are final subtractive denies. AF_UNIX stays
available for capability sockets. Internet bind and connect are absent
unless the policy says `NetworkFull`. Paths cross into SBPL (the Seatbelt
profile language) only through `-D` parameters, never string
interpolation. The fd-4 report proves that stage 2 actually started
inside the profile before `seatbelt` or its audit tags are published.

### Namespaces and mounts

**bwrap owns every namespace and mount.** The Go runtime is
multithreaded from the first instruction, and assembling namespaces with
`unshare` or fork in a multithreaded process is the problem that gave
runc its `nsexec.c`. So the helper only composes a bubblewrap argument
list (pure data, golden-tested) and stacks in-process restrictions on
itself afterward.

The argv order matters, because bwrap applies mounts in order. The helper
therefore does not leave that order to how the policy's four path lists
happen to be concatenated. It resolves the policy into an explicit,
ordered mount plan under two rules:

- **Grants first, masks last, and nothing after a mask.** The readable
  and writable binds and the scratch area widen the view. Fresh `/proc`,
  a minimal `/dev` and the protected-path masks subtract from it. A
  widening emitted after a mask undoes the mask and fails open.
- **Within a phase, the most specific region wins.** Operations sort
  parent-before-child, so a readable root nested inside a writable root
  comes out read-only, and a writable root under the scratch mount
  survives it. Masks are exempt from this rule against grants, because
  `protected` is the only subtractive verb the policy has and nothing may
  carve a hole in it.

A protected path is removed from the view whatever its inode type. A
directory, or a path that does not exist yet, is shadowed by an empty
read-only tmpfs; a file is shadowed by a read-only bind of an empty
device. Neither can be read through, written through, or created in.
Under network-off, bwrap also unshares the network namespace.

### Stage 2 and seccomp

**Stage 2 restricts itself and execs.** After changing directory it sets
`RLIMIT_FSIZE` and `RLIMIT_CPU`, applies a Landlock ruleset derived
purely from the policy, and sets `no_new_privs` unconditionally. It then
installs the seccomp filter when the network is off, writes an
enforcement report on fd 4, and calls `execve`. The order works because
Landlock domains, seccomp filters, rlimits, and `no_new_privs` all
persist across `execve` and can only tighten. The target starts inside
the jail with none of the helper's code left in its address space.

Landlock is the second filesystem layer, and the only one in degraded
mode. It has no deny rules, so it cannot carve out a protected path
nested inside a writable root. Masking those paths is bwrap's job, and
the enforcement report records whether bwrap ran.

The seccomp filter enforces network-off at the one point seccomp can
reach: **socket creation**. A filter cannot dereference the sockaddr
passed to `connect`, but it can read the integer domain argument of
`socket` and `socketpair`. A process that can never obtain an
`AF_INET`/`AF_INET6`/`AF_PACKET` socket has nothing to connect, bind, or
send with. The helper builds the child's whole fd table, so no network
descriptor can be passed in either. `AF_UNIX` stays allowed, confined by
the filesystem layers. Three further details matter:

- The program is built as pure data and unit-tested without a kernel.
- It kills the process on an unexpected audit architecture and, on
  amd64, on any x32-ABI syscall. Both are classic filter bypasses.
- Non-`AF_UNIX` socket creation fails with `EPERM` rather than a kill, so
  tools that probe for network and fall back keep working.

Installation uses `SECCOMP_FILTER_FLAG_TSYNC` so the filter binds *every*
thread of the Go runtime; without it, another thread could make the
blocked call. A partial sync is an error, not a success.

### Resource limits

Linux memory and process-count ceilings need cgroup v2, because
`RLIMIT_AS` is per-process and escaped by forking, and `RLIMIT_NPROC` is
per-user. Each execution gets its own group with `memory.max` and
`pids.max`. Descendants inherit membership, which is what makes the pids
cap hold against a fork bomb. The group's own `pids.events` counter, not
shell complaints about failed forks, is the ground truth for whether the
cap fired.

Darwin has no per-execution cgroup equivalent. Stage 2 attempts a finite
`RLIMIT_AS`; current kernels reject it with `EINVAL`, which becomes an
explicit `skip:rlimit-address-space` and therefore fails a strict demand.
`RLIMIT_NPROC` is per-user, so Loom first measures the account's live
process floor. It applies the ceiling only when that floor leaves a
16-process reserve below the request. Otherwise it reports
`skip:rlimit-processes` rather than breaking every legitimate fork on a
busy developer account. The reserve narrows, but cannot eliminate, a race
with concurrent same-user forks between the sample and `setrlimit`. This
is deliberately weaker than Linux cgroups, and the report says so.

### Environment, output, and reaping

The child's environment is **constructed, never inherited**. A variable
absent from `env_allow` is dropped even when the broker sent it, so the
policy alone documents what a jail can see.

`PATH` is an exception to "never inherited" in name only. The helper
merges its own process's inherited `PATH` (the daemon's, wherever the
operator's toolchain actually lives) with a fixed floor of system
directories. It keeps only entries that exist and do not fall under a
writable root, where the model could plant a shadowing binary. The
result then passes through the same `env_allow` gate as everything else.
A directory list carries no secret, so building `PATH` this way loses
nothing the scrub was meant to protect. It keeps `rg`, `go`, and the rest
of the toolchain reachable inside the jail's read-only view of the host
filesystem.

Output is capped per stream. Past the cap the helper keeps reading and
discarding, so the child never blocks on a full pipe. `Wait` runs in a
fixed order: reap the direct child, sweep the group with `SIGKILL`
(killing orphaned grandchildren that still hold the output pipes), then
join the output pumps. That order is why a backgrounded `sleep 30` does
not hold the execution open.

### Cancellation, and who each rung is addressed to

Cancellation is a two-rung ladder: `SIGTERM`, then `SIGKILL` two seconds
later. It runs inside a broker-side helper grace of three seconds and the
relay's five, so each layer outwaits the one below. The two rungs target
**different processes**, and that choice is the design.

Under bwrap the helper's direct child is a *supervisor*. Below it is a
second bwrap acting as init of the new PID namespace, and the payload is
below that. The supervisor is spawned `--die-with-parent`, so TERMing the
process group kills it; its death `SIGKILL`s the namespace init; and
killing a PID namespace's init kills every process in that namespace.
Measured: a payload with `trap "" TERM` died in 813 µs, by `SIGKILL`,
without ever being asked to stop. The grace period gave it nothing.

So TERM is addressed to **the payload and everything it spawned**, and
only the KILL rung takes the whole group. The payload is found by
descent, not by process group. The walk starts at the supervisor and
takes every process at depth two or more, which is exactly the jail and
what is inside it.

Selection by process group did not work. A process can leave its group
with one unprivileged `setsid(2)`, and a selection that scanned the group
came back empty for such a payload. It then fell back to signalling the
group, which is the collapse described above, on a payload nothing had
asked to stop. A process cannot leave the descent. Under `--unshare-pid`
the kernel reparents orphans onto the namespace's own init rather than
onto host pid 1, so the walk enumerates the whole jail.

Both exclusions are **structural**: the supervisor, whose pid the helper
holds because it spawned it, and that process's own direct children. An
earlier rule read `NSpid` out of `/proc` and spared anything that looked
like a namespace init, a shape `unshare -U -p -f` hands a payload for
free.

TERM is therefore **complete under bwrap and best-effort without it**. In
degraded mode there is no namespace, the group leader is the payload
itself, and a payload that calls `setsid(2)` leaves the group with
nothing to put it back. That is one more cost of a missing bwrap,
reported as degraded like the rest and bounded by the KILL rung's group
sweep.

The result records whether the ladder was climbed. `exec_exit.cancelled`
is a separate field because no other field can carry it. A cancelled run
whose payload had backgrounded its work reports `code=0 signal=0`, a
clean success for an execution that was truncated. And `code=143` is what
`sh -c 'exit 143'` reports with no cancel at all (`protocol-change/006`).

The flag reaches the model, not only `ExecResult`. `bash` renders it as a
line of the body and as `details.cancelled`, and a job poll carries it
under the same key. In both places it sits beside `timed_out`, because
the two answer different questions. `timed_out` says the wall deadline
fired; `cancelled` says the helper stopped the run rather than the run
ending on its own. A run killed by its deadline is both, and `cancelled`
without `timed_out` means the broker asked.

Darwin has no PID namespace. The helper therefore starts behind a gate,
records observed descendants with both PID and birth time, and sends TERM
and KILL both to the original process group and to the recorded set
still alive. The group delivers immediately to ordinary descendants. The
tracker covers an observed child that called `setsid(2)`, rechecking its
birth time immediately before signalling.

The Darwin tracker has two known gaps. Darwin has no stable process
handle, so the birth check is not atomic with `kill(2)`. Nor can the
tracker close the interval between process-table samples: a rapid
daemonizing double-fork can be reparented to `launchd` before its
ancestry is recorded. The helper bounds output draining, so even an
untracked process holding a pipe cannot hold the execution result open
forever.

Every Darwin execution therefore carries `skip:darwin-process-lifecycle`,
so `FullEnforcement` refuses the stronger claim. The production
`PlatformEnforcement` demand accepts this one declared lifecycle gap,
plus the two Darwin resource-limit gaps in ADR-006, only when the report
names each one. Seatbelt itself is inherited across forks. A missed
descendant stays filesystem- and network-confined, but may violate the
execution-lifetime and wall-clock cleanup guarantees.

### Enforced versus reported

A helper on a kernel that cannot provide a layer reports the gap rather
than hiding it. It lists what it has in `hello.features` and, per
execution, in an `enforcement` list and a `degraded` flag, with entries
such as `bwrap`, `mounts:ro=2,rw=1,mask=3,scratch=tmpfs,plan=…`,
`landlock:abi=5`, `seccomp-net`, `seatbelt-net`, `rlimit-cpu`, and
`skip:landlock: ...`. The broker's enforcement demand selects what to do
about the report:

- `PlatformEnforcement`, the production default, refuses a degraded
  helper and requires every layer the selected platform promises. On
  Darwin it tolerates only ADR-006's three named gaps, each reported
  explicitly. On Linux it has the same result as `FullEnforcement`.
- `FullEnforcement` rejects every gap on either platform.
- `BestEffort` accepts what is available and still hands the report to
  the caller.

**Presence is the claim, and silence is a skip.** The helper's hello
selects the platform matrix. Linux requires `bwrap`, `mounts`, `landlock`
and `no-new-privs`, plus `seccomp-net` and `cgroup-v2` when their policy
fields are active. Darwin requires `seatbelt`, `seatbelt-fs`,
`seatbelt-net`, and the requested rlimit tags. Both matrices require
`rlimit-cpu` and `rlimit-fsize`. A required layer that never appears
fails the demand exactly as a `skip:` entry does.

The earlier test was "no `skip:` entries", which a *silent* helper
passes. A stage 2 that died before writing fd 4 produced
`enforcement: ["bwrap"]`, which contains no skip, and so satisfied a
full-enforcement demand with the entire inner report missing.

Two rules keep the helper's side of that check honest. First, `bwrap`
and the `mounts:` audit are claimed **only when stage 2 reported**. That
report could not have arrived unless bubblewrap built the namespace and
exec'd into it; bwrap merely being on `PATH` proved nothing. Second, a
stage 2 that says nothing yields `skip:stage2: …` rather than an absent
inner report.

The `mounts:` entry gives the mount layer something checkable to report.
Its counts are not of operations requested, since those are identical in
a healthy plan and in one whose mask a later bind undoes. They count the
policy's own paths whose **effective view, after replaying the whole
ordered plan, is the one the policy asked for**. A defeated mask drops
out of `mask=` and emits a `skip:mounts:` naming the path and the
operation that re-exposed it. The broker holds the policy it sent, so it
can check those counts against it. The `plan=` digest is a diffing aid,
not a check, because nobody holds the expected value.

One gap is deliberately kept out of that vocabulary. A kernel missing a
layer is an *environmental* gap, and "degraded" describes it accurately.
A build with no jail for its operating system is a gap in Loom. Running
under `BestEffort` there would mean model-influenced code executing with
`network: off` in its policy and nothing enforcing it. Linux and macOS
now have phase-appropriate jails. Windows and unknown targets remain
unsupported, so the helper **refuses to serve on them** unless started
with `--allow-unenforced`. When it is asked to serve anyway,
`hello.features` carries `platform-unsupported`, every `enforcement` list
leads with `skip:jail: ...`, and `--self-test` prints
`RESULT: UNSUPPORTED PLATFORM` and exits nonzero instead of calling zero
attempted probes a pass.

### The self-test

`loom-exec --self-test` runs nine probes through the real jail path:

- write outside the writable roots;
- read or write a protected path;
- create a socket under network-off;
- read a non-allowlisted environment variable;
- fork-bomb against the pids cap;
- flood output past the cap;
- orphan a grandchild;
- escape the process group with `setsid` long enough to be observed;
- load a hostile unvetted BEAM.

The Darwin result does not generalize that observed `setsid` case into
containment of rapid reparenting; its per-execution skip records the
remaining gap. A probe whose layer the environment cannot provide prints
`SKIPPED` with the reason, neither faking a pass nor failing the run. A
probe whose layer *is* available must enforce, or the run exits nonzero.
The summary lists enforced and skipped probes separately, so a green
self-test in a stripped-down container cannot be mistaken for a verified
sandbox.

## Tools

A tool is a record: name, description, JSON schema, replay safety,
execution mode, policy-shaped requirements as a function of the workspace
root, and a `run` taking a context and the model's arguments. Tool
failures are **data**. `run` always returns an outcome whose `is_error`
marks an in-band failure, so a bad argument, a policy refusal, a dead
helper, or a stale anchor comes back as a result the model can read and
react to. An unknown tool name yields the same shape.

**Replay safety is a claim about what re-execution does to the world.**
`bash` declares `Never`: a shell command is an arbitrary external effect,
so a crash mid-execution must yield a synthetic interrupted result under
the pre-reserved id rather than run again. `fs_edit` declares `Safe`
because its anchors *consume themselves*. Applying a plan removes the
lines it referenced, so re-executing the same call against the
already-edited file is rejected as stale rather than applied twice.
Re-execution after a crash either repeats an edit that never landed or
fails in-band; it cannot double-apply. `fs_write` is `Safe` because
writing the same bytes to the same path is idempotent, and `fs_read` and
`grep` are `Safe` because they are reads.

**Hashline anchors make a stale edit impossible rather than unlikely.** A
read renders every line as `line:anchor|text`. The anchor is the first
eight lowercase hex characters of a 64-bit FNV-1a hash of the line's
UTF-8 bytes. An edit references lines as `{line, anchor}` pairs: the
anchor proves the content, and the line number disambiguates identical
lines. `apply` verifies every reference against the current content
*before* touching anything, so an edit planned against a file that has
since changed is rejected before it can corrupt the file. That is a
time-of-check to time-of-use defense across the gap between read and
write.

The rejection carries fresh anchors with two lines of context around
each stale region, so the caller can replan without a second full read.
Anchors depend only on line content, so an unrelated edit elsewhere never
invalidates them. The spec named `xxh3`; the implementation reads that as
intent (a fast 64-bit hash truncated to eight hex characters), since
anchors never outlive one read-edit round trip and are versioned
in-package. That choice is recorded as a spec gap, and it settles the
open question about anchor length and salt: eight hex characters, no
salt.

Output that would swamp the transcript **overflows to a blob store**.
Past 64 KiB the full bytes are written once under a content-addressed
name (SHA-256), and the result carries `{ref, size, head_excerpt,
tail_excerpt}`, with excerpts of at most 2 KiB trimmed to a UTF-8
boundary. Content addressing makes the write idempotent: replaying a
`Safe` tool or re-running an identical command lands the same bytes at
the same ref. `bash` and `grep` output overflow. Text returned by
`fs_read` is exempt, because windowed reads already bound it and anchors
buried inside an elided blob would defeat hashline editing.

`fs_read` also returns PNG, JPEG, GIF, and WebP files as
`ToolResultImage` blocks, with a text caption identifying the path. File
signatures select the MIME type. Images share the workspace checks and
the 8 MiB byte limit with text reads, but have no line windows or edit
anchors. The capability operation `cap/fs.read` retains its text
contract. Tool-result images in the current turn take part in vision
admission and routing, and historical image blocks become placeholders
when a later request uses a text-only model. OpenAI and Gemini serialize
tool images after the complete tool-result batch; Anthropic keeps them
inside the results. These provider projections leave durable roles and
image bytes unchanged.

The filesystem tools run **in the harness rather than through the
broker**, so they enforce their own path discipline: `resolve_path`
rejects empty paths and anything resolving outside the workspace root,
whether by `..` or by an absolute path. Under Rule Zero this is defense
in depth rather than the primary control. No model-chosen program runs
here, only Loom's own code on model-supplied arguments. The tools still
declare policy-shaped requirements, so a policy audit covers every tool
uniformly.

`bash` exercises the composition path end to end. It requires the
workspace writable, `/` readable (interpreters live outside the
workspace, and the session base determines whether to grant that),
network off, tmpfs scratch, and the environment names it actually
passes, so composition checks them against the session allowlist. It
clears with `RefuseNarrowed`: a session base that does not cover the
requirements produces an in-band structured refusal carrying the exact
wanted grants, ready for the escalation flow. Its timeout is clamped in
the tool, 120 seconds by default and 600 at most, and the wall limit
mirrors it. `grep` runs `rg --json` read-only. When the jail has no
ripgrep, it settles as a structured error suggesting `bash` instead.

## Background jobs

Every tool call described so far runs in the foreground: `run` holds its
effect process for the whole execution, and a command that outruns its
budget comes back as `[command timed out]` with the process reaped. A
**job** is the one thing in this plane allowed to outlive the call that
started it. It is a jailed process with output, an exit status and a
kill handle. It is bounded by a wall-clock limit fixed at start, owned by
a strand, and killable through the same ladder a cancelled foreground
call climbs.

`bash` starts a job with `mode: "background"` and answers with a handle.
`job_poll`, `job_kill` and `job_send` are the rest of the tool surface,
and `cap/job` offers the same four operations to a code-mode program.
Both surfaces land on one seam, `client/jobseam.Door`, so a job started
from a tool call and one started from a program are the same record with
the same owner. Either surface can read or stop what the other started.

**The actor owns the records; a runner per job owns the clearance.**
`client/jobs` is a `weft/actor` in `client/serve`'s *restartable*
services tier, beside `extension_hosts`. It is bound to a reclaimable
registry address, so a replacement answers where the original did. Each
job gets a task of its own, and that task, not the actor, calls
`broker.clear_call`. Two parts of the broker's contract require this:

- `clear_call` waits out a full helper pool in the caller's own process,
  and an actor blocked on congestion could not answer a poll.
- The relay monitors the caller and cancels the execution when that
  process dies, so the caller must be a process that lives exactly as
  long as the job.

The runner folds the `CallOutput` stream and reports the outcome, and the
actor writes the terminal fact only when that outcome arrives. A weft
outcome is reported once the worker has exited, so the scope's exit is
the proof of drain, and "finished" is never written before the process is
gone. The runner is a *plain* task rather than a managed one: a managed
task exists to witness owners a worker discovers while it runs, and this
one discovers none.

**A job clears under its own identity, not the batch's.** Budget is
pooled per `{op_id, step_id}`, where the step is the model batch
(ADR-005). `bash` opens that ledger at `max_outstanding: 1`, so a job
sharing it would be capped by a foreground command earlier in the same
batch, and a second job would be refused outright. A detached job is not
part of a batch's parallel width. It clears under `{op_id, "job/" <> id}`
instead, with its own ledger, token and deadline; ADR-005's second
addendum records why. The operation half is kept deliberately, because
it is what `broker.abort` addresses. Aborting the operation that
*started* a job kills it, which is what an operator asking for that
means. Aborting a later operation does not, because detachment is what
the model asked for.

**The deadline is fixed at start, and its four enforcers cannot
disagree** because all four read one number: the capability token, the
relay's receive deadline, the helper's own wall timer, and the budget
ledger. Renewal is not offered. The helper's timer is armed once from
`exec_start`, so moving it would need a new frame and a protocol change.
Long-lived work is served by an operator setting instead:
`[jobs].max_wall`, in **seconds**, raises the one-hour clamp and cannot
lower it. A lower ceiling is already what the session's own sandbox
policy says, and saying it twice would let the two disagree. The relay
cancels at the deadline on its own, so enforcement needs no timer in the
runner. What the runner's clock provides is *attribution*: only the party
that asked can say a settled execution was killed by its deadline rather
than having exited.

**Output is a bounded tail plus an unbounded spill.** `job_poll` returns
what each stream printed *since a cursor*, out of an 8 KiB rolling window
per stream. A reader that fell behind is told how many bytes it missed
rather than silently skipping them. While the job runs, the whole of each
stream goes to a per-stream staging file under the blob root. At
termination that file is promoted to a content-addressed ref, recorded
in the terminal fact and read with `fs_read`. A boot that finds a staging
file with no live job unlinks it. Cursors are opaque tokens the model
hands back unread.

**A restart reaps jobs; it never re-adopts them.** A job's process is a
child of a helper, and the helper is a child of the VM, so nothing here
survives the VM. Before the replacement actor serves one request, it
sweeps `job/*` and commits `Lost` for every job still live. It holds
those records in memory, so a poll answers `Lost` rather than `NotFound`.
`NotFound` is reserved for "no such job, or somebody else's", and a job
the harness lost is neither. The same sweep covers a restart of the actor
itself, which kills every runner it owned.

`daemon_shipped_jobs_test` proves this against the shipped daemon. A
SIGKILLed VM takes the payload with it, the next boot's sweep commits
`Lost`, and the model's own poll reads it. The marker the payload's first
act wrote stays gone after the fixture removes it, which only a second
process could undo.

**A hook may not start a job.** Extensions reach the same capabilities
through the same envelope whether a tool call or a hook event triggered
them, but the jobs capabilities are served only to tool calls. A tool
call's operation is the model's own run: the model reads the job in its
own transcript, can kill it, and an abort of that run reaches it. A
hook's operation is the single session-long operation minted for every
hook in the session and attributed to the root strand. Nobody sees that
operation as a running step, so nobody can abort it. A `context` hook
calling `job.start` on each event would leave hour-long processes owned
by `main` that the model never asked for and cannot find. The
capabilities stay routed for a hook, so a hook that asks gets that reason
back rather than an unknown-capability denial.

Nothing new travels on the client wire for jobs. A job's start and
terminal state are `fact.custom` registers under a `job/` prefix, and a
poll's answer is an ordinary tool result.
`docs/design-notes/background-jobs.md` carries the design and what
changed once it met the code.

## Providers

The provider gateway sends model requests. It is a typed registry plus
injected effects: an HTTP transport, a secret store, and a clock.
`resolve(role)` returns the first target in the role's ordered fallback
chain whose provider is registered; that identity is what durable state
stores.

`request` takes either a role or a resolved identity. Given a role, it
resolves the chain at dispatch and walks it, moving to the next target
only on a failure classified as *retryable*. A terminal error surfaces
immediately, an exhausted chain delivers the last real error rather than
a summary, and a settled response never falls back. The role target can
also carry a reasoning-budget overlay (`protocol-change/009`), applied to
the whole chain before the walk starts. A fallback is therefore asked
for the budget the caller asked for, not whatever its own route row
declares. Given an already-resolved identity, `request` dispatches to
exactly that identity and never walks.

The model plane, not the gateway, determines which form a live session
uses, and `docs/architecture/models.md` covers it. Role follows
identity: a generation whose captured identity heads a routable role's
chain goes out as a role and walks, while an off-route identity and every
deferred poll go out already resolved.

### Streaming

Streaming follows the sans-io shape. The parser for server-sent events
(SSE), the framing every provider streams over, is **pure**: bytes in,
events out, with carry state threaded through. Feeding it the same bytes
in any chunking yields the same events, and the whole parser is
property-tested without a single process. Each adapter composes the
parser with its own pure accumulator into a response machine, a fold over
HTTP events. Only `run` is impure: it starts a monitorable transport
owner and forwards deltas as they appear.

Composition uses a prepare-publish-begin seam. A `PreparedStream` exposes
its parked owner before route resolution, secret lookup, or transport
work starts, and the runtime grants the begin permit only after its
reaper has adopted that owner. The consumption contract is narrow enough
to depend on: zero or more `Delta` events, then exactly one `Settled` or
`Failed`, and nothing after. Deltas are ephemeral display data and prove
nothing about settlement.

### Stream ownership and cancellation

The returned `StreamHandle` carries the event subject, an idempotent
cancel capability, and an optional drain-witness pid. A minimal public
custodian owns that capability but performs no provider work. It adopts
the gateway guard, the private fallback pump, and every transport owner
before each one begins. The guard tracks the pump's current transport.
The pump owns the provider terminal race and will not start another
fallback until that transport drains.

Teardown first invokes the transport's cancellation capability, then
observes bounded owner death. If the owner does not retire, the guard
reports uncertainty while the custodian stays alive, because killing the
witness would erase the proof that native work stopped.

The production transport uses one native owner rather than another Gleam
custodian-and-worker pair. Its narrow Erlang FFI retains the exact opaque
OTP `httpc` request id and the dedicated request-handler pid. The owner
receives the raw messages itself and disables handler migration. It
captures the handler through the manager's already-published request
table in O(1), issues cancellation directly to that handler, and waits
for it to exit. It holds the first response callback inside the handler
until that monitor exists, which closes the fast-terminal deletion race.

Any indexed lookup miss falls back to a deadline-bounded recovery scan
over `httpc_handler` processes. Neither a complete scan with no match nor
an inconclusive probe may be taken as proof of drain. An unfamiliar
private layout likewise cannot produce a normal owner exit: the callback
may still supply its exact producer, and otherwise the request deadline
bounds an unprovable recovery with an abnormal exit. The request and
terminal state machines remain in Gleam. Raw OTP errors become constant
diagnostics at the boundary, so a request header cannot leak through a
durable provider error.

Each attempt has one absolute deadline from transport start through
settlement, and one 16 MiB cumulative response budget after transport
delivery. Neither valid deltas nor a sequence of small completed SSE
events renews or escapes that typed bound. Complete events accumulate in
reverse and are restored once, so a flood of valid events stays linear.
OTP `httpc` buffers non-200/206 bodies before delivery; bounding that
native error-body memory requires transport replacement or isolation and
is not claimed here (issue #147).

Inside the pure parser, a line and a single event are each capped at
4 MiB. A separate limit of 4096 fields covers empty `data:` lines, whose
list cells consume memory without adding payload bytes. Every overflow
is an in-band malformed-stream terminal, followed by the same
cancel-and-drain path as any other terminal race.

An owner-authored `ProviderCancelled` proves cancellation won. A guard or
wrapper whose inner owner stays silent for the fixed grace period
instead emits terminal `CancellationUnconfirmed`, and that uncertainty
cannot authorize a fallback or retry. The distinction is what stops the
external work, rather than merely teaching the caller to ignore a late
answer. Protocol change 010 fixes the contract and its race semantics.

### Stop reasons, overflow, and decoding

**Stop reasons map totally.** Each adapter maps the vocabulary it recognizes
and answers `Error(Nil)` for anything else, which the caller surfaces as
`Failed(UnmappedStopReason(raw))` in-band. A provider that ships a new
stop reason tomorrow degrades to a readable error, never a crash.

**The adapter computes context overflow, and the definition is written
down.** When reported input plus cache-read tokens exceed the resolved
model's context window and the output is negligible, the response
settles with stop reason `error` carrying the canonical overflow message,
with the raw stop reason preserved. The machine's classification checks
overflow before retryable error, so an oversized request compacts rather
than retrying unchanged. The spec left "negligible" open; the code sets
it at 64 output tokens or fewer, so a real answer that merely tripped a
counter is never discarded as overflow.

Decoding distinguishes an additive field from unknown content. Stream
payloads must parse as JSON, while absent usage counters read as zero
and unknown fields are ignored. The older adapters also ignore unknown
event types under their existing versioning conventions. The Responses
adapter instead rejects unknown content-bearing events and item kinds,
because silently dropping one would let the final message omit part of
the provider's answer. It explicitly recognizes harmless lifecycle
markers and verifies that deltas, completion records, and final output
agree. Malformed model arguments remain an in-band corrective tool result
under #189; conflicting wire records are `MalformedStream`.

### Secrets

**Secrets live in exactly one place.** Provider configuration holds a
secret *name*, never a value. The secret store is an injected lookup
whose only call site is gateway dispatch, which copies the value straight
into one outbound request header. Remote error diagnostics are bounded,
and the gateway scrubs the exact request key before an error leaves the
attempt.

Successful streamed content is a different boundary. Redacting a
credential fragmented across that content is still open as issue #148,
so the gateway does not claim that arbitrary successful provider output
can never contain a key. The full-turn Responses fixture checks that its
request-only key does not enter replay or durable session data. The
environment-variable backend ships now, and OS keychain backends fit the
same `fn(name) -> Result(String, Nil)` seam without touching a caller.

**Secrets never appear on a log line either.** Telemetry enforces the
same invariant: every field a log record carries passes through
`telemetry/field.scrub`. It redacts any field whose key names a
credential, and any token in free text that carries a vendor prefix or is
an unbroken run of at least 32 credential-alphabet characters. The
threshold matches what this tree holds: the broker's clearance token and
the cap channel's token are both 32 random bytes, which is 64 hex or 43
base64url characters. The Erlang formatter calls back into the same
function for lines the harness did not author, so an OTP crash report
that happened to hold a token is scrubbed too.

The exemption is typed: `field.ident` opts a value out of the *shape*
rule alone, never out of the key rule, so every waiver is deliberate and
greppable. The test plants a provider key, a clearance token and a
channel token under both a denylisted and an innocent key, renders, and
greps the bytes (`packages/telemetry/test/telemetry/redaction_test.gleam`).

## What the end-to-end proves

The M2 acceptance test runs the production wiring: the real provider
gateway over a scripted SSE transport, the real ToolBroker over the
**real Go `loom-exec` helper**, and the real tool registry. It is
feature-detected; with no Go toolchain the tests print a skip reason and
pass.

The happy path drives four settlements from one prompt:

1. `bash` writes `notes.txt` inside the jail.
2. `fs_read` returns its hashline anchors.
3. `fs_edit` applies an anchored replace scripted against those anchors.
4. A text answer completes the run.

The assertions are specific:

- the file on disk is byte-exact `alpha\nbeta improved\ngamma\n`;
- the projected transcript matches shape for shape;
- the `bash` result's details carry the helper's real exit code and
  signal, alongside its `degraded` flag and `enforcement` list;
- the read result contains exactly the anchors the scripted edit used,
  which proves the two tools agree rather than the fixture agreeing with
  itself;
- the usage ledger equals the scripted total;
- closing and reopening the session file yields a structurally identical
  transcript.

The crash rider reproduces a crash in the middle of a tool call, live. A
`bash` call runs `: > started.marker && sleep 30`. The test waits for the
marker, so the kill lands with the tool intent durable and the external
effect genuinely in flight, then kills the whole supervision tree. On
reboot from the same file, recovery finds an effect-pending call with no
live continuation. `replay: Never` forbids re-execution, so the synthetic
interrupted result settles under the reserved id, and the remaining
script completes the run. The ledger total is unchanged: each settlement
committed usage exactly once, the crash included.

Integration also found a bug no unit test could have. Budget deadlines
are computed on the tool-side clock and checked against the broker-side
clock, and nothing in the contracts required the injected clocks to
share an era. With misaligned eras, the broker refused every call as
already past its deadline. The fix is a convention the spec should
state: one clock, or at least one era, injected across runtime, tools,
and broker.

The simulation runner makes that convention structural for a simulated
session. One logical clock is shared by everything that reads time. The
driver's own delayed wakeups go through an injected timer seam
(`effects.Timers`, with `effects.real_timers()` for production), so they
run on the same time base rather than on the VM's timer wheel.

Finally, the enforcement matrix. In the development container `loom-exec`
reports `rlimits, pgroup, degraded, seccomp`: there is no bubblewrap
binary, no Landlock in the kernel, and no delegated cgroup v2 hierarchy.
Four of the seven self-test probes enforce there, and the three needing
the missing layers skip. The suites therefore run with `BestEffort` and
assert on the helper's report. Production sessions pass
`PlatformEnforcement`, which is strict on Linux, and on Darwin is strict
about the real Seatbelt boundary while admitting only ADR-006's explicit
platform gaps.

## Where the code lives

| Path | What it holds |
|---|---|
| `broker/broker.gleam` | `clear_call`, the relay, abort, settlement. |
| `broker/policy.gleam` | `SandboxPolicyV1` as a typed value; composition, grants, narrowings; the canonical codec. |
| `broker/token.gleam`, `broker/budget.gleam` | Capability tokens (minting, binding, constant-time check, revocation) and pooled per-execution ledgers. |
| `broker/escalation.gleam` | The denial → approval → single-consume machine and its events. |
| `broker/egress.gleam` | Outbound HTTPS under a per-caller policy: the origin allowlist, the reserved headers, credential injection, the redirect walk, the streamed size cap. `broker/internal/ffi_egress` performs one hop on a broker-private `httpc` profile. |
| `broker/framing.gleam`, `broker/exec.gleam` | The protocol broker-side with its pure deframer; the helper actor, fd-3 spawn, cancel ladder, and pool. |
| `sandbox/cmd/loom-exec/main.go` | Role selection by first argument: server mode, `--exec` (stage 2), `--self-test`, `--probe-socket`, and `--allow-unenforced`, which serves on a platform Loom has no jail for. |
| `client/git_identity.gleam`, `sandbox/internal/jail/git_identity.go` | Brokered identity query and the fixed, descriptor-confined publication operation. |
| `sandbox/internal/jail/platform.go` | Whether this *build* has a jail for its OS at all. That is a different question from what the running kernel provides, and the two are kept apart everywhere they surface. |
| `sandbox/internal/policy`, `.../framing`, `.../server` | The strict policy decoder, the protocol helper-side, and the frame loop. |
| `sandbox/internal/jail` | bwrap argv, stage 2, env construction, output limiter, cancel escalation, supervision. |
| `sandbox/internal/llock`, `.../seccompf`, `.../cgroup` | Landlock rules, the network-off cBPF program with its TSYNC install, and cgroup v2 groups. |
| `sandbox/internal/selftest` | The seven regression probes and the enforced/skipped report. |
| `tools/tool.gleam`, `tools/hashline.gleam` | The tool record, seams, registry, and in-band outcomes; anchors, windows, anchor-checked plans, stale rejections. |
| `tools/fs.gleam`, `tools/bash.gleam`, `tools/grep.gleam` | The filesystem tools with their path discipline, and the two jailed ones. |
| `tools/blob.gleam` | Content-addressed overflow past 64 KiB. |
| `client/jobs.gleam`, `client/jobstate.gleam`, `client/jobtail.gleam` | The background-jobs actor and its per-job runners; the pure lifecycle and the `job/` fact codec; the bounded UTF-8 tail with its cursor. |
| `client/jobseam.gleam`, `client/jobtools.gleam` | The host side of the jobs door, and the translation that fills `tools/job`'s seam and the code-mode router's. |
| `tools/job.gleam`, `cap/job.gleam` | The `job_*` tools a model calls, and the same four operations as typed Gleam for a vetted program. |
| `provider/gateway.gleam`, `provider/secret.gleam` | The registry, role resolution, and the fallback walk; the secret-name lookup seam. |
| `provider/stream.gleam` | Stream events, the pure server-sent-events parser, the transport pump. |
| `provider/adapter/anthropic.gleam`, `.../openai.gleam`, `.../gemini.gleam`, `.../responses.gleam` | Request construction, response accumulation, total stop-reason mapping, overflow. |
| `client/wiring.gleam` | The production effect record: the seam between the pure planes and this one. Its module doc is the list of mapping decisions. |
| `client/escalate.gleam` | Parking: raise on every policy refusal, hold the call while a human decides, consume the approval and re-clear once. |
| `conformance` test suites `wiring_test.gleam`, `e2e_test.gleam` | The adapter's mappings against fakes, and the M2 jailed acceptance that proves the record end to end. Both live under `packages/conformance/test/conformance/`. |
| `protocol/msgpack-fixtures/` | Golden frames both languages are pinned against. |

Each Gleam path is relative to its package's source root
(`broker/token.gleam` is `packages/broker/src/broker/token.gleam`), and
each Go path is relative to `packages/sandbox`. For the plane below this
one see `docs/architecture/durability.md`, and for the state machine and
runtime that drive these effects, `docs/architecture/orchestration.md`.
For intent and contracts,
`docs/loom-design.md` §5 covers the threat model and the two-channel
doctrine, and `docs/loom-implementation-spec.md` holds the frozen wire
protocol (Part 1.4) and the security invariants (§3.3).
`docs/adr/003-msgpack.md` records the codec decision. `docs/spec-gaps.md`
records where implementation refined the spec, including the fd-3
delivery workaround, the anchor hash, and the shared clock era.
