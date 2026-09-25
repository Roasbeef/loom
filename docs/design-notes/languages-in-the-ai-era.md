# Design note: "Evolving programming languages in the AI era", read against Loom

Status: **note, not a work package.** A reading of José Valim's post
*Evolving programming languages in the AI era* (2026-09-24) against the
tree as it stands on `main` at `99b9060`. The post is short and mostly
questions; this note keeps only the parts that bear on a coding-agent
harness written in Gleam on the BEAM, and checks each one against the
code rather than the docs. `docs/design-notes/harness-playbook.md` is the
precedent for the shape: what the post argues, where Loom already agrees,
where it exposes a gap, where to push back, and a distillation short
enough to act on.

The short version: the post's four-tier account of guarantees is Loom's
founding doctrine in different words, and two of its concrete proposals,
a program database in place of an LSP and runtime observability in place
of a debugger, land squarely on two release-blocking issues (#25, #26)
and one open investigation (#454) that the tree is about to spend effort
on in the wrong shape. The recommendation is to reshape #25 before
building it, to let the post's argument finish the objection #26 already
records against itself, and to give the agent the BEAM introspection an
operator currently has to run by hand.

## What the post argues

The first half asks what happens to a language and its community when
humans stop writing most of the code. Three claims survive into the
second half: syntax and ergonomics matter far less to a model than to a
person, so a language "for agents" that competes on syntax is building
around a limitation that is shrinking; the trade between expressiveness
and guarantees should be re-cut in favour of guarantees, because the
tedium that justified inference and implicitness is no longer paid by a
human; and compilers are not going away, because architecture-neutral
representations and domain-specific semantics (the BEAM's process model
is the post's own example) are what a language is *for*.

The second half is the concrete one. It sorts guarantees into four tiers,
correct by construction, statically established, runtime-enforced, and
empirically validated, and says languages will differentiate on how they
combine them. Then it makes two proposals about tools:

- **Program databases over LSPs.** The Language Server Protocol is
  file-line-column shaped because editors are. A model does not track
  positions; it asks "where is `foo_bar` defined" and "who calls it".
  Expose what a language server already knows (symbols, references, call
  graphs, types) as a queryable database, so a model can compose
  questions no IDE menu offers, and so the same database can serve as a
  linter. Locality matters more, not less, under this regime: action at a
  distance defeats any index.
- **Runtime observability over debuggers.** Breakpoints and stepping are
  a human's interface. A model can instrument, trace and correlate faster
  than a person, so give it the running system's state as something to
  query. The BEAM already exposes processes, supervisors, ETS, sockets
  and message queues; the remaining work is exposing them *safely*.

## Where Loom already agrees

**The four tiers are the design's own ladder.** Read against the post's
taxonomy, `docs/loom-design.md` §1 and the ground rules in `CLAUDE.md`
are one tier each:

| Tier | Where it lives in Loom |
|---|---|
| Correct by construction | The operation state machine is a total function over ADTs (`OperationState` in `core`; design §3.2), so pi's race catalogue is unrepresentable rather than tested for. The no-naked-`Bool` rule and the two-variant-type habit push the same idea into every record. |
| Statically established | `gleam check` plus `make lint` (`packages/lint`), whose five gating rules hold censuses at zero, and `codemode/vet`, which decides whether hostile source may compile at all. R6 keeps `core`, `machine` and `prompt` free of externals so they stay property-testable and JavaScript-compilable. |
| Runtime-enforced | Rule Zero. The broker is the only door, capability tokens are unforgeable, and the kernel (Landlock, seccomp, Seatbelt, bwrap) enforces what the type system cannot. `make selftest` reports which layers the kernel actually provides. |
| Empirically validated | The conformance package's seeded simulation runner (`docs/architecture/simulation.md`), the property-checked deframer, the jailed end-to-end, and the chaos soak (#18). |

Nothing needs to change here. What the post adds is a name for the
combination and a prediction that the combination is the differentiator;
Loom's priority order (security and isolation, correctness, robustness,
performance, capability) already says so.

**Guarantees over inference.** The post's "why optimise for inference
when an agent will happily write the annotation" is already
`docs/gleam-style.md` Part III: annotate all module functions, private
ones included, and never annotate `let`. The style guide reached that
position for readability; the post supplies the second reason, that an
explicit signature is information the compiler, the lint and the next
agent can consume. Keep the rule and keep it universal.

**Locality.** The post's warning that monkey-patching, hooks and dynamic
rebinding defeat program databases is Gleam's selling point restated:
"no reflection, no dynamic dispatch, no macros" is design §1.2, and it is
why vetting can read a program's capabilities off its imports and
attributes. Rule Zero is the same argument applied to execution rather
than analysis. The one place Loom deliberately tolerates action at a
distance is the hooks-compat surface (`docs/architecture/hooks-compat.md`),
which is why it is journaled and refusable rather than ambient.

**Syntax is not where the leverage is.** Issue #446 already suspects this:
PR #433's minimal roster shrank descriptions and did not obviously make
the agent better, and the issue asks to separate roster reduction from
discovery. The post's claim that a model experiences a language as tokens
in, tokens out, and that its failures are about *knowing* the library and
not about *typing* it, says the discovery half is the one worth funding.
The `cap://` virtual read (`packages/tools/src/tools/codemode.gleam`,
"The `cap://` namespace") is the right instrument and is already
name-keyed rather than position-keyed.

**Upstreaming over reinvention.** The post worries that cheap
implementation weakens the incentive to collaborate on shared libraries.
The tree has already chosen the other side: weft is "part of the job, not
a workaround", the etui fork stack and the esqlite pin both carry
upstreaming issues (#345, #247), and `docs/weft.md` treats a hand-rolled
copy of a primitive as a review finding. That stance is worth stating as
policy rather than leaving as a pattern: when the agent can build a
library in an afternoon, the review question is whether it should have
extended the sibling one instead.

## Where the post is right and Loom has a gap

### #25 is shaped like an IDE feature and should be shaped like a database

Issue #25 (`lsp_*` tools over a sandboxed, per-project language-server
client) is the plan's headline for phase five and owns the long-lived
stdio-port seam that #26 also needs. Its acceptance criterion, a semantic
rename across the fixture repo, is right. Its *surface* is what the post
argues against, and the tree already shows the seam is the wrong shape:
`packages/cap/src/cap/lsp.gleam` is a prelude stub (allowlisted by
vetting, answered by no router, so every call returns `unsupported_cap`)
whose every request takes a `Location(path, line, character)`,
zero-based, "matching the LSP convention". A model reaching that stub
has to have read the file with `fs_read`, counted lines, and converted a
hashline anchor into a column before it can ask who calls a function. That is the position-tracking the
post says agents do not do well, moved into the prompt.

Three facts in the tree say a name-keyed query surface is cheaper than the
position-keyed one, not more expensive:

1. **The compiler already emits the database.** `gleam export
   package-interface` writes the public API of a package as JSON, and
   `make gen-prelude` already consumes it to render the `code_mode`
   description. `CLAUDE.md` tells an agent that this export, not the LSP,
   is "the answer and is exact" for the API surface. Serving it as a
   query is an indexing job, not a language-service job.
2. **The AST walker exists and is exact.** `packages/lint` is a pure
   analysis over `glance`'s AST plus `glexer` token scans, and
   `CLAUDE.md` already suggests "a throwaway `glance` walk in
   `packages/lint`" when a question is really about the AST. A
   references-and-calls index is one more walk over the same parse.
3. **The rebuildable-index pattern is built.** `events/search`
   (`docs/architecture/events.md`, "Search") keeps an FTS5 index in one
   SQLite file per repository, carries no authority, tolerates deletion
   at the cost of a re-sync, and is driven in production by
   `client/history`. A symbol index is the same shape with a different
   schema, and SQLite is the storage engine the tree already owns (ADR on
   the SQLite binding).

The proposal, then, is to split #25 in two before it is built:

- **A program database first.** A per-repository SQLite index over
  `glance` output and `package-interface` exports: modules, public and
  private functions with their annotated signatures, types and
  constructors, imports, and call edges. Exposed to the model two ways,
  matching how `cap://` is exposed today: a virtual scheme for `fs_read`
  (`sym://` or an extension of `cap://` to workspace packages) answering
  "where is X defined" and "what is X's signature", and a `cap/symbols`
  capability in code mode whose query is a small typed filter rather than
  free SQL, so a program can compose "public functions that transitively
  reach `storage.commit`" without the harness parsing SQL from a
  satellite. The index is rebuildable, carries no authority, and is
  invalidated by file digest, which is the same key `fs_edit` already
  binds hunks to.
- **The LSP client second, and narrower.** Keep the supervised, sandboxed
  stdio port for the two things only the language server can do:
  *rename* (edits, landing through the hashline path so a concurrent
  modification still rejects) and *diagnostics*. Drop references and
  go-to-definition from the `lsp_*` roster and from `cap/lsp`, since the
  database answers both by name, and re-key the stub's remaining
  requests by symbol rather than by `Location`. This change costs a
  `protocol-change/` entry if `cap/lsp` is counted as a frozen Part-1
  surface; the stub has nothing behind it, so now is the cheap moment.

This is compatible with the route `docs/design-notes/extension-architecture.md`
names for phase five, where the language server and the debug adapter
are extensions running a long-lived process in the jail through
`cap/proc`, and where the `cap/lsp` stub is retired. The database is a
harness-side projection like the search index and needs no jail at all;
the extension route keeps what needs the server. The one edit to that
route is its tool roster: `lsp_definition` and `lsp_references` should
not exist as tools when the index answers both by name, leaving
`lsp_rename` and `lsp_diagnostics` as the extension's whole surface.

The same database is a linter, which the post also predicts. Several of
`make lint`'s rules are already queries over an AST (R5, R8), and the
rules that "will never gate" because they over-report (R3, R8) are
exactly the ones a model would run as a filtered query rather than
accept as a verdict. Nothing about `make lint` should move; the point is
that a query surface makes new house rules cheap to prototype before they
earn a rule number.

Loom is a monorepo of Gleam packages that build the harness, and a
workspace the agent edits, and the two are not the same thing. The index
serves the *workspace*, whatever language it is in; Gleam is the first
language it should support because the parser and the export exist, and
because Loom's own tree is the largest Gleam codebase the agent is asked
to work in. A second language means a second front end, which is the
language-service tier's ordinary cost and no worse under this shape than
under the LSP one.

### #26 should be closed by the argument it already records

Issue #26 (`dap_*` tools) carries its own objection: nothing consumes
DAP, a breakpoint session is interactive in a harness whose core is
headless, and the acceptance test is "a test driving a debugger rather
than an engineer using one". The plan kept it because "M5 is core and
ships whole".

The post finishes that objection. Breakpoints and stepping are the
human interface to a running program; the agent-shaped interface is
instrumentation and traces, and on the BEAM that interface is native.
Erlang's trace BIFs and `dbg` can record every call into a module, every
message a process receives, and every garbage collection, with no
recompilation and no stop-the-world, and a satellite node is exactly the
place a model may be allowed to switch them on: it is disposable, jailed,
and already the process tree its program runs in. A `cap/trace`
capability that lets a code-mode program trace *its own* program root
(function calls on the modules it compiled, messages on the actors it
spawned, bounded by count and by the execution's deadline) gives the
model what a breakpoint session would, as data it can filter with the
same `cap/task` and `cap/actor` primitives it already has, and costs no
new port seam. The output is a report artifact, so it composes with
`report.emit` and with the notes door for durable analysis between
executions.

That does not reach a program under test in a foreign runtime, which is
the case #26 was written for. For those, the honest answer is the one the
plan already gives: nothing consumes it. Recommend re-labelling #26 out
of `release-blocker`, replacing its body with the BEAM-native trace
capability above, and letting a DAP adapter return if and when a phase
needs one. This is an owner's decision and the plan says so; the note
only reports that the argument for it got stronger.

### The agent cannot see the runtime it runs on

The post's second proposal is the one where Loom has the most to gain and
has, so far, gone the other way. Everything the post lists as the BEAM's
strength, processes, supervisors, ETS, message queues, memory by
allocator, is reachable from the harness VM through standard OTP calls,
and the tree uses it: `docs/design-notes/daemon-memory.md` is a hundred
lines of `erlang:memory/0`, `process_info` grouped by initial call, and
allocator carrier tables. But every one of those measurements was taken
by an operator, from a hidden probe node, through the release's
`loom-profile` arrangement, because that is the only way to reach the
daemon.

The tooling says so itself: `scripts/mem_report.erl` opens with "the
daemon needs no probe code loaded and no diagnostics endpoint", and
`docs/performance.md` is a manual for a person at a shell running
`observer`, `tprof` and `erlang:memory`. The daemon's own control surface
reports admission state and slot counts, and its resource limits are
accounting bounds, "not a measurement of BEAM heap or RSS"
(`docs/architecture/daemon.md`, "Resource limits").

Issue #454 states the consequence: "the in-session route is blocked by
design", the profile cookie is masked from every session jail, `ps` and
`top` are denied, and the census "must be run by an operator in their own
shell". The agent that could have done the attribution in one turn
instead filed a request for a human to paste tables back. That is the
exact anti-pattern the post names.

The blockage is correct as far as it goes. A cookie is full trust, an
attached node can load code, and Rule Zero forbids anything
model-influenced from running in the harness VM. But the post's framing
separates two things the current arrangement conflates: *attaching* to
the VM (which must stay operator-only) and *querying* it (which can be a
read-only, bounded, harness-authored RPC like any other broker call).
Nothing in Rule Zero forbids harness code answering "how much memory do
the processes under session S hold, grouped by initial call" and
returning the answer as data. The telemetry package already draws this
line for logging: observability only, nothing reads a record back, no
line has authority.

Concretely, an **introspection capability** with these properties:

- **Harness-authored, read-only, and bounded.** The queries are a fixed
  vocabulary implemented in the harness (`erlang:memory`, per-process
  `process_info` on a whitelisted field set, supervisor children, ETS
  info, scheduler and run-queue stats, message-queue lengths), never an
  arbitrary term to evaluate. Each answer is capped in rows and in the
  size of any term it copies, because `process_info(Pid, messages)` on a
  process with a large mailbox is itself the memory incident the census
  is looking for; `daemon-memory.md`'s "bounded probe heap" caution
  becomes a parameter of the call rather than an instruction to the
  operator.
- **Scoped by ownership.** A strand may ask about the session tree it
  belongs to and about its own satellites, and an owner-principal
  session (the `loomd access` roles in `client/daemon/admin.gleam`) may
  ask about the daemon. That is the same authority model the peer and
  link work just settled: discovery is permitted by the index, admission
  by the grant.
- **Reached two ways, like everything else.** As a `fs_read` virtual
  scheme (`runtime://`) for the one-line question, and as a `cap/observe`
  module for a code-mode program that wants to sample every second for a
  minute, fan out over the process list with `cap/task`, and reduce, which
  is the composition the post says only an agent would bother to write.
- **Two-channel, like everything else.** A satellite's own runtime is
  local to it and the program may look freely; the harness's runtime is
  reached over the capability channel and never by joining the node.

With that in place, #454's exit criteria one and two (a census pasted
back; attribution of the dominant heap group) are a code-mode program
the agent writes and runs, and the remaining hunt for the capture
boundaries in job doors, workspace closures and extension routing is the
kind of correlate-and-narrow work the post says models do faster than
people. The same capability is what the advisor strand would use to
notice a runaway mailbox before the primary does, and what a scheduled
heartbeat would use to watch a soak.

The harness's own log is thin in the same direction. Telemetry is
observability only, which is right, but the OpenTelemetry seam is
unbuilt, the `session` correlation slot is never populated, and six of
the nine impure packages (`broker`, `provider`, `tools`, `codemode`,
`cap`, `session`) write no line at all (`docs/architecture/telemetry.md`,
"Coverage"). An introspection capability answers "what is the VM doing
now"; it does not answer "what did the broker refuse an hour ago", and
that question needs the silent packages to speak before any exporter has
something to carry.

### Traces are already the record; nothing yet reads them as one

The post's line that agents will "take on more responsibilities across
the software development lifecycle, including monitoring and diagnosing
production systems" is issue #236 restated: the session file is the
trace, every turn carries a model id, tool calls and refusals are
content, and the usage ledger sits beside it. #236 is about optimising
the harness from those traces. The post suggests a nearer, cheaper use:
diagnosis. `history_search` gives a model full-text over past sessions;
it does not give it "every session on this repository where `bash`
returned a Landlock denial", or "which tool calls preceded the last three
compactions". Those are queries over structured columns the store
already has, and the events search index is the precedent for exposing a
read-only projection of them. This is a smaller item than #236 and does
not need its optimiser.

## Where to push back

**Token efficiency is not at the tail end for a harness.** The post
argues that syntax-level token savings will matter less as models get
cheaper and windows larger. For a *language* that is right. For a
harness it is not the whole story: `docs/next.md`'s first remaining item
is to measure how virtual-read discovery affects prompt size and
cached-prefix reuse, and the tool-search design note shows why: the
head's bytes decide whether the cache prefix survives a turn, and a
cache miss is a latency and cost event on every request, not a one-time
tax. Keep measuring. The post's point should change *what* is trimmed
(descriptions and rosters, not the language the model writes) rather
than whether anything is.

**The LSP is not dead for rename and diagnostics.** The database
proposal above deliberately keeps the language server for the two
operations that need the compiler's own front end: computing a rename's
edit set across re-exports, and reporting diagnostics without a full
build. A `glance` walk is exact about syntax and knows nothing about
types; `package-interface` knows public types and nothing about bodies.
The compiler is the oracle for anything semantic, and the cheapest way to
ask it a question is still to run it.

**Model checking is not free on this tree.** The post floats validating
models against implementations through generated execution traces. The
simulation runner is deterministic about decisions and explicitly not
about BEAM scheduling (`simulation.md`, "What this does not cover"), and
the runner says a reproducible-interleaving simulator "would need the
whole runtime to run on an injected scheduler". That remains true; the
post does not change the cost, only the payoff.

## The distillation

Five items, each small enough to be an issue or an issue comment:

1. **Reshape #25 before building it.** Program database first (SQLite
   over `glance` and `package-interface`, rebuildable, no authority,
   digest-invalidated), exposed as a virtual-read scheme and a typed
   `cap/symbols` query; language server second and narrowed to rename and
   diagnostics; re-key `cap/lsp` by symbol rather than by `Location`
   while the stub still has nothing behind it.
2. **Close the argument on #26.** Replace the DAP adapter with a
   satellite-local `cap/trace` over Erlang's trace BIFs, bounded by count
   and deadline, reporting through `report.emit`; move #26 out of
   `release-blocker`. Owner's call, as the plan says.
3. **Give the agent a bounded, read-only runtime introspection
   capability**, harness-authored, ownership-scoped, reached as
   `runtime://` and `cap/observe`, so #454-shaped investigations stop
   needing an operator's shell. Attachment stays operator-only.
4. **Expose structured session-trace queries** alongside `history_search`
   as a read-only projection, as the diagnostic half of #236 that needs
   no optimiser.
5. **Write the upstreaming stance down** where reviewers look: when the
   agent could build a library, the review question is whether it should
   have extended weft, etui or the sibling checkout instead.

The post's deepest claim is that a language will be chosen for how it
combines guarantees, not for how it reads. Loom made that bet in its
first paragraph. The work above is making the *tools* keep the same
promise the language does: give the model the compiler's view instead of
the editor's, and the VM's view instead of the operator's.
