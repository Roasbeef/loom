# Code mode

A tool call is a round trip: the model emits one call, the harness runs
it, and the result returns as context for the next turn. Ten dependent
steps cost ten round trips, and every intermediate payload — the full
file that only wanted its line count, the directory listing that only
wanted one name — lands back in the conversation whether the model needs
it or not. Code mode collapses the round trip. Instead of one call at a
time, the model writes a **program** that composes tools locally, with
loops, conditionals, intermediate values, and concurrency, and the
harness runs the whole thing and returns one structured result. The ten
steps become one execution. The intermediate payloads stay inside the
program and never reach the context. A multi-tool workflow stops being a
scattered sequence of turns and becomes a single durable artifact —
stored, replayable, and a candidate for promotion into a reusable tool.

The language the model writes is Gleam, the same language the harness is
written in. That choice is what makes running model-written code
defensible, and the rest of this document is the argument for why. The
`codemode` and `cap` packages exist as build skeletons with their
dependencies pinned — `codemode` already pins `glance`, the Gleam parser
the vetting pass runs on — but their source is not yet written; what
follows is the design that source will realize.

## Why Gleam is safe to run

Pure Gleam cannot touch the world. It has no reflection, no `eval`, no
dynamic module lookup, and no macros. Every effect a program can have —
reading a file, spawning a process, opening a socket — enters through an
import that ultimately reaches a function declared `@external`, the one
door from Gleam to the Erlang runtime beneath it. A program with no such
import in its transitive reach can compute, but it cannot act. This gives
the property the whole design rests on:

> A Gleam program's maximal capability set is computable from its source:
> the transitive closure of its imports plus its own `@external`
> declarations.

The word *maximal* matters. Static analysis cannot decide what a program
*will* do — that is undecidable — but it does not need to. It only needs
to bound what the program *can* do, and for Gleam that bound is a set you
can read off the source without running it. A program that never imports
a networking module cannot open a socket no matter what its logic
computes, because the function that opens sockets is not in its reach and
no runtime trick can conjure it. Contrast Python, JavaScript, or Erlang
itself, where an import list tells you almost nothing: any of them can
reach the whole runtime through a string passed to `eval` or a module
resolved by name at runtime. Gleam closed those doors at the language
level, and code mode spends the result.

This turns capability control into a source-level check. The check is the
first of two defenses.

## The pipeline

A submitted program passes through two trust layers before its result
returns: a pure lint in the harness, then a kernel-enforced jail around
the running code. Vetting decides whether the program is *allowed* to
run; the jail contains it *while* it runs, so that a program which should
never have passed the lint still cannot reach anything it was not handed.

```mermaid
flowchart TD
    M[Model emits a Gleam program]
    M --> V{Vet: import and @external lint}
    V -->|rejected| R[Structured rejection, returned to the model in-band]
    V -->|pass| C[Compile against the pinned prelude]
    C --> S[Run in a fresh satellite node]
    S -->|cap_call| K[ToolBroker: token and policy check]
    K -->|cap_result| S
    S --> O[Outcome marshalled back; satellite destroyed]

    subgraph H[Harness VM — trusted]
      V
      K
    end
    subgraph J[Kernel jail — OS-sandboxed, untrusted]
      C
      S
    end
```

Vetting and the broker run in the trusted harness virtual machine.
Compilation and execution run under the kernel sandbox, on the far side
of the boundary that `docs/architecture/effects.md` describes. The only
line crossing from the jail back to the harness is the framed channel
carrying a `cap_call` to the broker and a `cap_result` back — every
effect the program has, checked one at a time. Escape from this design
requires *both* a vetting bypass and a kernel escape, which is the point
of having two layers rather than one strong one.

## Layer one: vetting

**Vetting** is a lint, not a heuristic. It parses the submitted Gleam with
`glance` and enforces three rules, each rejecting one way a program could
smuggle in a capability its imports do not admit:

1. **No `@external` in submitted source.** The `@external` attribute is
   the sole bridge from Gleam to arbitrary Erlang. Model-written source
   may not declare one. Every effect a program is allowed must arrive
   through the prelude, whose `@external` declarations the harness wrote
   and trusts.

2. **No import outside the allowlist.** A program may import the standard
   library and the capability prelude, and nothing else. An import that
   resolves anywhere else is rejected.

3. **Every dependency pinned to the prelude.** The build sees exactly the
   vendored standard library and the pinned prelude — no other package,
   at no other version.

   Rule 3 is a bound on *packages*, not on modules, and the difference
   matters. The prelude has dependencies of its own — `gleam_erlang`,
   `gleam_otp`, and the harness `core` — so their public modules sit in
   the program's build graph and would compile if a submitted program
   imported one. Rule 2 is what refuses them: they are not on the
   allowlist, and `gleam/erlang*` and `gleam/otp/*` carry an explicit
   denylist entry besides. The manifest does not independently close that
   door, and reading rule 3 as though it did credits the wrong layer.
   Narrowing the build graph to the prelude's public surface is Builder
   work still ahead.

Three adversaries motivate the three rules, and each is a real entry in
the vetting corpus that WP-J must reject before the package ships:

- **Hidden FFI through a nested dependency.** A program with clean
  top-level imports pulls in a helper package that itself declares
  `@external` and re-exports it as an innocent-looking function. Rule 1
  catches `@external` in the submitted source; rule 3 shuts the nested
  path, because a *third-party* package never enters the build, and rule 2
  refuses any module the allowlist does not carry. The theorem is stated
  over the *transitive* closure for exactly this reason: vetting reasons
  about everything the program reaches, not only the file it was handed.

- **Unicode-lookalike imports.** An import spelled with a homoglyph —
  a Cyrillic letter standing in for a Latin one — reads as `cap/fs` to a
  human but resolves to an attacker's module. The allowlist matches
  module identity exactly, so a lookalike is simply not on it and rule 2
  rejects it.

- **Prelude shadowing.** A submitted module declares its own `cap/fs`
  with a hostile `@external`, hoping to be resolved in place of the real
  one. Rule 1 forbids the `@external` outright, and rule 3 pins the name
  to the vendored prelude, so the shadow never wins.

Because the type checker runs during the same pass, it doubles as the
tool-argument validator. A call to a capability with the wrong argument
types fails at compile time, before any sandbox spins up — a cheaper loop
than discovering a malformed tool call at runtime and feeding the error
back for another turn.

Vetting is strong. It is also only layer one, and the design does not bet
the farm on a lint. A bug in the parser, a gap in the allowlist, a Gleam
release that adds a reflective escape we did not anticipate — any of these
would let a hostile program past. So the running program is jailed
regardless of how thoroughly it was vetted, and the jail assumes vetting
already failed.

## The prelude is the capability system

The **cap prelude** is the set of modules a code-mode program is allowed
to import: `cap/fs`, `cap/proc`, `cap/net`, `cap/git`, `cap/lsp`,
`cap/task`, `cap/actor`, `cap/report`, and `cap/kv`. Each is an ordinary
typed Gleam module whose functions look like local calls but whose bodies
are stubs: a call marshals its arguments and sends them as a `cap_call`
over the framed channel to the ToolBroker, carrying the execution's
capability token, and blocks for the `cap_result`. The program thinks it
is calling `fs.read`; the broker is the thing that actually reads, after
checking the call against policy.

Because effects arrive only through these imports, the import list *is*
the permission grant. A program that opens with `import cap/fs` and
`import cap/proc` can read files and run processes. It cannot open a
socket, because it did not import `cap/net`, and the socket-opening
function is therefore not in its reach — vetting confirms the absence, and
the jail guarantees no other path exists. Permissions are not a
configuration attached to the program from outside; they are visible in
the first few lines the program wrote, and enforced by the same theorem
that makes vetting sound.

## Layer two: the satellite node

A vetted program compiles and then runs in a **satellite node**: a
disposable `erl` operating-system process, launched fresh for the
execution inside the executor sandbox, and killed as a unit when the
execution ends. It is a full BEAM virtual machine, which is what gives
agent programs real concurrency, but it is a jailed one:

- **No network except the channel to the broker.** The sandbox policy
  turns networking off; the only reachable socket is the Unix-domain or
  stdio channel that carries `cap_call` traffic.

- **No distribution.** The node boots with `-proto_dist` disabled and no
  `epmd`, so the Erlang clustering that would let one node run code on
  another is simply absent. The framed data-plane channel is the node's
  only link to anything, in keeping with the two-channel doctrine in
  `docs/architecture/effects.md`: native distribution never crosses a
  trust boundary.

- **Bounded resources.** A per-process `max_heap_size`, a cgroup capping
  memory, CPU, and process count, and a wall-clock deadline. When the
  deadline passes the whole node dies, and everything it spawned dies
  with it.

A hostile `.beam` that slipped past vetting lands here, in a jail whose
only reachable effect is the one broker channel. It can burn its CPU
budget and hit its deadline; it cannot read a file the policy forbids,
reach the network, or touch another session. The exit criterion for WP-J
states this as a tabletop exercise: a hand-written malicious `.beam`,
loaded directly to bypass vetting entirely, must reach *nothing* but that
channel and must die at its deadline.

Be exact about which layer holds that line, because it is easy to credit
the wrong one. **The capability token does not confine this adversary.**
The token file is bind-mounted readable into the jail — the boot runtime
has to read it — and its path is an ordinary environment variable, so a
`.beam` that carries its own `@external` reads the file and presents the
genuine token. The check then passes, as it should. Two other things do
the confining: the **kernel jail**, which leaves the channel as the only
thing the node can reach at all, and the **broker's per-call policy
check**, which composes and checks policy on every `cap_call` whatever
token came with it. What the token adds is authentication and binding:
it refuses a peer that never read the file, it ties the channel to one
`{operation_id, step_id, deadline}` so a captured token cannot be
replayed elsewhere or later, and revoking it shuts the channel at
teardown. It is not a bearer capability, and no call gets more because it
carried a valid one.

Compilation is itself sandboxed. The compile service runs `gleam build`
hermetically inside an executor jail with no network, against the vendored
prelude and standard library, and produces a `.beam` set plus a manifest
hash. The harness compiles the source it vetted; it never loads a binary
it did not build.

Source and compiled artifacts are stored as entries, so every executed
program is auditable history and a promotion candidate — see
`docs/architecture/durability.md` for what an entry is.

## From a cap function to a broker RPC

Follow one `fs.read` from source to settlement. The program calls
`fs.read(path)`. The `cap/fs` stub encodes `{token, cap: "fs.read", args,
deadline_ms}` and writes it to the channel as a `cap_call` frame. The
**capability token** is a 32-byte random value the broker minted for this
execution, binding it to one `{operation_id, step_id, policy, deadline}`;
it travels only over the channel it authenticates and is checked on every
call. The broker validates the token against its revocation list, checks
the requested effect against the execution's policy — separately, and on
every call, so a valid token buys nothing beyond a live channel — runs the
read through the same machinery every other tool uses, and returns
`{ok, value}` or `{err, error}` as a `cap_result`. The stub decodes it and
the program resumes with an ordinary Gleam value. The broker, its tokens,
and the framed protocol are described in full in
`docs/architecture/effects.md`; code mode is one more caller at that one
door.

The type checker validated the arguments at compile time, so a `cap_call`
that reaches the broker is already well-formed. What the broker adds is
the runtime authority check: the token could have been revoked, the
policy could refuse this path, the deadline could have passed. Vetting
bounds what the program can *ask for*; the broker decides, per call, what
it *gets*.

## Concurrency

The satellite runs a full BEAM, so agent programs get real parallelism —
but through curated capabilities, never the raw process primitives. Raw
`spawn` is deliberately absent, because it would allow unbounded process
creation and messages to arbitrary registered names, including the broker
channel itself. Two modules stand in its place.

**`cap/task` gives structured concurrency.** Every task is a child of the
program root; results are awaited, or the whole tree fails together, and
killing the satellite reaps every task with it. There are no detached
processes to outlive the program.

```gleam
task.parallel_map(sites, max_concurrency: 8, fn(site) { ... })
task.race([strategy_a, strategy_b])
task.both(run_lint, run_tests)
```

Three semantics are pinned. `parallel_map` preserves input order
regardless of completion order, so result *i* always corresponds to input
*i* even when input *i* finished last. Failures aggregate by default, with
`fail_fast: True` available when the first error should abort the rest.
And cancellation is real, not advisory: when `race` has a winner, each
loser's in-flight capability calls are revoked at the broker, which kills
the executor process groups behind them. A losing branch does not run to
completion in the background wasting budget — it stops, and its work
outside the VM stops with it.

**`cap/actor` gives typed, program-scoped actors** — a constrained
`gen_server`. Spawn one with an initial state and a typed handler,
`spawn(init, handler) -> Address(msg)`, receive an unforgeable typed
address, and `send`, `call(timeout)`, or `get` against it. Actors earn
their keep for ongoing state driven by asynchronous input: watching a
build's output stream and reacting to the first error, coordinating a
debugger stepping session, running a work-stealing queue whose items
generate more items. The guardrails mirror `cap/task`. Every actor lives
under the one program-root supervisor; there is no global registration,
so no actor can be addressed by a name another program could guess; and
mailboxes are bounded, so a fast producer meets backpressure rather than
growing the heap until the node dies.

What is deliberately excluded is the rest of the OTP surface: links and
monitors with custom trap-exit logic, and self-defined supervision
strategies. The supervision policy is fixed — all-for-one under the
program root. A crash propagates up, the program fails as a unit, and the
strand that launched it sees a structured error, as
`docs/architecture/orchestration.md` describes for any failed operation.
The exotic supervision surface belongs to installed extensions, where a
human approved it; a jailed program does not get to invent its own
failure semantics.

### Budgets are pooled per execution

Concurrency reopens a hole that per-call limits would leave gaping: a
program that fans out ten thousand polite parallel reads, or spawns fifty
test runs, respects every per-call limit while amplifying its footprint a
thousandfold. Code mode closes it by pooling the budget across the whole
execution rather than metering each call. One token backs every in-flight
`cap_call`, so the limits are aggregate — a cap on outstanding effects,
one cgroup covering every fanned-out executor's combined CPU, memory, and
process count, and one wall-clock deadline over the entire program. Each
`proc.run` still gets its own jail; they all draw from one shared budget.
Fan-out buys parallelism, not extra resources.

## A worked example

Here is a small program of the kind the model would write. It searches
three packages for a stale symbol in parallel, then races two ways of
confirming the tree still builds, and reports what it found. (The exact
prelude signatures are illustrative — `cap/task`'s are pinned by WP-J, the
rest await the source.)

```gleam
import cap/fs
import cap/proc
import cap/task
import cap/report

pub fn main() {
  let dirs = ["packages/core", "packages/broker", "packages/runtime"]

  let hits =
    task.parallel_map(dirs, max_concurrency: 3, fn(dir) {
      fs.grep(dir, "deprecated_decode")
    })

  let build =
    task.race([
      fn() { proc.run("gleam", ["build"]) },
      fn() { proc.run("make", ["check-core"]) },
    ])

  report.finish(report.Summary(hits: hits, build: build))
}
```

Trace what each line is permitted to do. The four imports are the entire
permission grant: this program can read files, run processes, use
structured concurrency, and report a result. It cannot open a socket —
`cap/net` is absent — and it cannot touch git history, because `cap/git`
is absent. Vetting confirmed both absences before the program compiled.

`parallel_map` fans three `fs.grep` calls across the packages at once.
Each is a separate `cap_call` to the broker, each checked against the
policy and each drawing from the one pooled budget; whichever directory
finishes first, `hits` still lists results in `dirs` order, so `hits`
first element is always `core`'s. The three searches run under one cgroup
and one deadline.

`race` starts both build strategies together and returns the first to
finish. Say `gleam build` wins. The `make check-core` branch is now a
race loser, and its cancellation is real: its outstanding `proc.run`
`cap_call` is revoked at the broker, and the broker kills the executor
process group running `make`, so the losing build stops mid-flight instead
of grinding on and spending budget the winner already made moot. Had the
whole program overrun its wall-clock deadline instead, the satellite would
die as a unit — both searches, both builds, and the program root together
— leaving nothing behind. Whatever the program means to keep leaves
through `report.finish`; the satellite's own memory is gone the moment the
node is destroyed.

## Where code mode sits: the promotion ladder

A code-mode program is the bottom rung of a trust ladder that runs from
throwaway code to a change in Loom itself. Code mode is where that ladder
begins, and reading the whole of it explains why the same programming
model reappears at every level; `docs/loom-design.md` §7 covers it in
depth.

```
L0  code-mode program     ephemeral, satellite-jailed, dies with the call
L1  session skill         L0 saved as a durable, named, reusable entry;
                          runs at L0 privileges
L2  extension candidate   compiled against a wider but still
                          capability-stubbed prelude; runs its tests in the
                          sandbox, results attached
L3  installed extension   after explicit human approval: hot-loaded into
                          the harness ExtensionZone
L4  core change           a pull request to Loom; ordinary review and
                          release; never runtime-loaded
```

Two properties carry up the ladder. First, nothing self-promotes: the
step from a proven candidate to an installed extension requires a human
decision, recorded durably. Second, the shape of the code does not change
as it climbs. An installed extension is an OTP actor implementing a typed
behaviour — the same actor model `cap/actor` hands a jailed program at L0.
A stateful helper prototyped as a program-scoped actor, proven against its
tests, becomes a supervised citizen of the harness when it is promoted,
without being rewritten into a different thing. Code mode is not only the
fast path for a single execution; it is the first draft of a durable
capability.

Within a session, a satellite kept alive across calls carries this
further. Its actors persist between executions — the model can spawn an
indexer in one call and query it across the next several — which nothing
MCP-shaped can express. That state is ephemeral by design, though:
anything worth keeping leaves through a `report` artifact or the `cap/kv`
scratch store, and a program must tolerate finding its actor gone.

Keeping a satellite alive moves one obligation onto the executor. The
capability channel lives in a node-global slot, and each execution
installs its own, so a process that outlived execution *N* would read
execution *N+1*'s channel on its next capability call and act under
*N+1*'s token and policy. The invariant that rules this out is external
to the prelude: **the executor reaps every process a program spawned
before the next execution installs its channel.** The boot runtime keeps
that obligation from being merely assumed: it refuses to install over a
channel whose actor is still alive, so an unreaped predecessor fails the
next boot outright instead of silently lending it authority. A fresh node
per execution, the default, never reaches the case at all.

## Where the code lives

Two packages, built together under WP-J:

- **`packages/codemode`** holds the vetting lint (built on the `glance`
  parser it pins), the hermetic compile service, and the satellite runtime
  and boot protocol. It depends on `core`, `broker`, and `tools`.

- **`packages/cap`** holds the prelude — the `cap/*` modules whose bodies
  are RPC stubs over `cap_call`. It is a separate build target, depending
  only on `core` and the Erlang runtime, so it can one day be published on
  its own as the language a code-mode program is written against.

The frozen wire contracts these packages implement against — the framing,
`cap_call` and `cap_result`, the token rules, and `SandboxPolicyV1` — live
in Part 1.4 of `docs/loom-implementation-spec.md` and are shared with the
executor and satellite channels alike.
