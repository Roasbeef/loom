# Loom

Loom is a coding agent harness written in Gleam and running on the BEAM. A
session is a supervision tree over a write-once conversation store: every
step an agent takes — the prompt it received, the tool call it made, the
result that came back, the tokens it spent — is committed to a per-session
SQLite file before anything else can depend on it, so killing the OS
process at any instant loses no work and re-runs no side effect. Everything
the model influences executes outside the harness virtual machine, in
kernel-sandboxed OS processes reached through a single capability-checked
broker. Three existing harnesses supply the parts: the durability model
comes from pi, the sandbox posture from Codex CLI, and the tool surface
from omp. The BEAM supplies what none of them have, because a harness is
already an actor system — strands, subagents, tool executions, and stream
parsers are processes, and crash recovery is a supervisor plus durable
state rather than defensive code. It is also why code mode is worth
building: an agent-written Gleam program that fans out, races two
strategies, and holds stateful actors gets real concurrency from a runtime
built for it. That part is designed and not yet written; see Status.

## Rule Zero

BEAM processes give fault isolation, not security isolation. Any process in
the virtual machine can call `os:cmd/1`, open any file the OS user can
open, and dial the network; there is no capability model inside the VM to
lean on. So the harness leans on the kernel instead:

> **Rule Zero: model-influenced execution never runs in the harness VM.**
> The BEAM node orchestrates. Untrusted work — shell commands,
> agent-written programs, third-party language servers and Model Context
> Protocol servers — runs in OS-sandboxed external processes under
> kernel-enforced policy. The kernel isolates threats; the BEAM isolates
> faults; the two are never confused.

Every effect leaves through the ToolBroker, which composes a policy,
refuses or narrows it, mints a capability token bound to one operation
step, and guarantees the caller exactly one settlement whatever happens
downstream. The sandbox policy is a typed, versioned value stored durably
with the execution intent, so the transcript records which jail each
command ran in. A denial surfaces as a structured escalation carrying the
exact policy difference — "wants: network to registry.npmjs.org" — and an
approval buys one re-execution, recorded. Prompts are a user interface,
never a control.

## Status

The design is complete; the implementation is partway through it. Three
milestones are built, tested, and documented as-built:

- **M0 — durability plane.** Three stores (entries, registers, usage), one
  atomic commit primitive with compare-and-swap expectations, two
  interchangeable backends, a fenced writer lease, and a segmented branch
  index.
- **M1 — orchestration plane.** A pure state machine whose entire surface
  is `next_action(op, state, inputs) -> Action`, and an OTP runtime that
  carries the decisions out: one storage writer as the serialization point,
  strands as processes, recovery that reads five registers and resumes.
- **M2 — effect plane.** The broker, a framed msgpack wire protocol, a
  small Go helper that restricts itself and then execs the target, and a
  tool set — bash, hash-anchored reads and edits, grep — whose correctness
  does not depend on the model behaving. A stale edit anchor is rejected
  before it can corrupt a file, and a tool failure comes back as data the
  model can read rather than as a crash.

**M3 is in progress**: the event bus and projections, the client gateway
protocol, a Go TUI that drives a session entirely through that protocol,
forks and compaction, and a multi-strand demo where a parent and two
subagents collaborate through durable messaging. The `events`, `client`,
and `tui` packages are skeletons today.

Code mode (M4), the LSP and DAP tools (M5), and the extension promotion
ladder (M6) are specified in the design and spec documents and not yet
written. macOS Seatbelt and the Windows sandbox are likewise designed and
unbuilt; the Linux jail is the one that exists.

### What "tested" means here

- **Storage conformance.** One suite, parameterized over a backend
  constructor and run against both the in-memory and the SQLite backend,
  defines what "correct backend" means: atomicity, seq ordering, the
  expectation matrix, branch scans, catch-up reads, and a branching torture
  script that re-scans every entry ever written to its root path after
  every commit. Three further checks are SQLite-only — the writer-lease
  duel, `EXPLAIN QUERY PLAN` assertions, and branch-index invariants. A
  10,000-entry session scans its newest 50 entries with a median of about
  2 ms in the development container, against a target of 5 ms.
- **Crash exploration by enumeration.** The storage writer exposes a seam
  that runs after a commit is durable but before the committer learns of
  it — precisely the state a crash leaves behind. Five scenarios run once
  to fix their commit counts, then once per boundary with the kill armed
  there: **42 crashed runs**, each of which must converge on the same
  terminal outcome, the same projected context, and the same ledger total,
  with no replay-unsafe tool executed twice. A run armed to crash must also
  have crashed, so the loop cannot pass vacuously.
- **Crash exploration by generation.** Enumeration is only as good as its
  hand-written list, so a deterministic simulation runner replaces the list
  with a seed. One integer splits into a *script* (what the session is
  asked to do) and a *schedule* (what goes wrong while it does it); the
  script runs clean and then faulted, and the pair is held to named checks.
  Every fault in the taxonomy is transparent by construction — crashes at
  commit boundaries and during live effects, refused and stale commits,
  read faults, lease theft, dropped and delayed doorbells, slow and dying
  effects, torn frames — so anything that legitimately changes the outcome
  lives in the script and happens in both runs. Failing schedules shrink,
  and cases that found real defects are pinned as hand-built regressions
  rather than as seeds. Its honest limits are in
  `docs/architecture/simulation.md`: real processes rather than a simulated
  scheduler, so BEAM message interleaving is not reproducible; one backend,
  one strand, one session; no real effect plane.
- **A jailed end-to-end.** A scripted provider drives the real broker, the
  real executor pool, and the freshly built Go helper against a real
  workspace: prompt, tool calls, sandboxed bash and edits, byte-exact file,
  exact ledger, and a crash rider over the integrated stack.
- **A sandbox self-test that reports what the kernel actually gave it.**
  `loom-exec --self-test` runs seven probes through the real jail path —
  writing outside the writable roots, writing to a protected path, creating
  a socket under network-off, reading a non-allowlisted environment
  variable, a fork bomb against the pids cap, an output flood, and an
  orphaned grandchild. A probe whose layer the environment cannot provide
  prints `SKIPPED` with the reason; a probe whose layer is available must
  enforce or the run fails. Enforced and skipped are summarized separately,
  so a green self-test in a neutered container cannot be mistaken for a
  verified sandbox. The development container enforces four of the seven;
  bubblewrap, Landlock, and delegated cgroups need a fuller kernel.

## The three planes

The planes are strictly layered: the durability plane knows nothing about
agents, and the orchestration plane knows nothing about sandboxes. Each
package belongs to exactly one of them.

**Durability plane** — stores rows, answers queries, decides nothing.

| Package | What it holds |
|---|---|
| `core` | Ids, entries, registers, transactions, and total decoders. Pure. |
| `storage` | The storage interface, the in-memory and SQLite backends, the fenced lease. |
| `session` | The session and repository layer, tree views, the branch index, forks. |

**Orchestration plane** — decides what happens next and what must be
durable before it happens.

| Package | What it holds |
|---|---|
| `machine` | Operation types, `next_action`, classification order. Pure; no I/O, no state between calls. |
| `runtime` | The storage writer, the strand supervisor, the driver loop, recovery. |
| `events` | The event bus, rebuildable projections, search. In progress. |

**Effect plane** — everything that touches the world.

| Package | What it holds |
|---|---|
| `provider` | Typed provider clients, streaming, retries, role-based routing with fallback chains. |
| `broker` | The ToolBroker: policies, capability tokens, budgets, escalation. |
| `sandbox` | The `loom-exec` helper binary and platform drivers. Go. |
| `tools` | bash, hash-anchored filesystem reads and edits, grep. |

**Clients and tests.**

| Package | What it holds |
|---|---|
| `client` | The client gateway protocol and server. In progress. |
| `tui` | A thin terminal client speaking that protocol. Go; in progress. |
| `conformance` | The shared suites: storage conformance, wiring, the interleave harness, the simulation runner, the jailed end-to-end. |

## Building it

You need Gleam 1.11 or newer, Erlang/OTP 27 or newer, and Go 1.24 or newer
for the sandbox helper and the TUI. Nothing is published to Hex; the
packages are monorepo-internal and are built where they sit.

```
make check      # the full gate: format check, warning-free build, all tests
make selftest   # build the helper, then report ENFORCED/SKIPPED per probe
make e2e        # the jailed end-to-end against a freshly built helper
make soak       # the long simulation run (SOAK_SEEDS=n SOAK_FROM=n)
make help       # everything else
```

`make check` is exactly what CI runs, and `make check-<package>` narrows it
to one package. Run `make selftest` on the kernel you actually intend to
run agents on: the sandbox is only as strong as the layers that machine
provides, and the self-test is how you find out which ones those are.

## Reading further

- `docs/architecture/` — the system as built, one document per plane
  (`durability.md`, `orchestration.md`, `effects.md`) plus
  `simulation.md` for the crash-exploration runner. Start here to
  understand the code that exists.
- `docs/loom-design.md` — the intent: why the BEAM, the three planes, Rule
  Zero, the two-channel doctrine, code mode, and the staged trust pipeline.
- `docs/loom-implementation-spec.md` — the work packages, the frozen
  interface contracts, and the milestone acceptance criteria. Changing a
  frozen interface takes a proposal in `protocol-change/`, never silent
  drift.
- `docs/gleam-style.md` — a language tour and the house style. Gleam is
  young enough that habits from other languages mislead; read this before
  contributing.
- `docs/notebook.md` — the running lab log: what was decided, what broke,
  and what is in flight, newest entry first.
