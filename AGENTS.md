# Loom

Loom is a BEAM-native coding agent harness written in Gleam. Sessions are
supervision trees over a durable, write-once conversation store; all effects
flow through a capability-checked broker into kernel-enforced sandboxes.

## Start here

**`docs/next.md`** is the handoff: where the tree actually is, what to work
on next, the design rulings already made, and what is deliberately left
open. Read it before planning anything, and rewrite it when you finish a
body of work — it is worth more than any status comment.

**`docs/execution.md`** is how work gets done here: planning a wave,
briefing and monitoring sub-agents, the verification standard, and the
hazards that have already cost real time. Read it before dispatching a
sub-agent or trusting a green gate.

## Required reading

Before writing any code, read these in order:

1. **`docs/gleam-style.md`** — code style, idiomatic Gleam, and a brief
   language tour. Gleam is a new language; do not carry habits over from
   other languages. Pay particular attention to Part III (idioms: error
   handling, type design, actors, FFI) and Part IV (Loom-specific policy:
   total decoders, no panics outside tests, FFI confinement, purity
   layering).
2. **`docs/loom-design.md`** — the high-level design: the three planes
   (durability, orchestration, effect), Rule Zero (model-influenced code
   never runs in the harness VM), the two-channel doctrine, and code mode.
3. **`docs/loom-implementation-spec.md`** — work packages, frozen interface
   contracts (Part 1), and normative conventions (§0.2). Where the spec and
   design doc conflict, the spec wins on mechanics, the design doc on
   intent.

## Literate code

Comments are part of Loom's design, not decoration added after the code. A
reader should be able to follow a module's ownership model, state transitions,
and failure behavior by reading its prose in order. Start every module with
`////` documentation that explains why the boundary exists and how work moves
through it. Document every public type, constructor field, variant, and
function with `///`, including an `## Examples` section for functions.

Write the reasoning the syntax cannot show. Explain the invariant being
preserved, the failure or race which shaped the code, and why this mechanism
owns the responsibility. Before a selector, recursive loop, or subtle `case`
arm, state what event or transition it represents. Do not narrate the next
line: `// Send the message` above `process.send` adds nothing. Prefer `// The
acknowledgement transfers restart custody before work begins`, which tells the
reader what ordering would break if the send moved.

Prose a reader cannot find is prose that was not written, so the layout is
part of the rule. **A comment has a blank line above it** — inside a
function body, between `case` arms, and between the variants of a custom
type; that blank line is what turns a footnote on the line above into the
heading of the stanza below. **R10 gates**, so a welded comment fails the
build. And **a body does not run more than about eight statements without
a break**, because a body with no paragraphs has nowhere to put the prose
(R11, a warning). `docs/gleam-style.md` Part II, "Stanzas: how code
breathes", has the two places `gleam format` deletes a blank line and so
exempts — the top of a block, and between a constructor's fields — and the
shapes that are tables rather than paragraphs.

Treat missing explanatory prose as unfinished work when reviewing a change.
`docs/gleam-style.md` Part III, "Doc comments" and "Plain comments: the
literate register", gives the complete conventions and examples.

## Ground rules

- Design priorities, in order: security & isolation, correctness,
  robustness, performance, capability.
- Gleam >= 1.18, Erlang/OTP >= 29. All code passes `gleam format --check`
  and compiles warning-free before commit.
- Interfaces in spec Part 1 are frozen. Changing one requires a
  `protocol-change/NNN.md` proposal, never silent drift. There are twelve
  (`protocol-change/001`–`012`); `001` and `006` are the format precedent —
  the problem, what was considered, the decision, and what it costs.
- Pure packages (`core`, `machine`, `prompt`) perform no I/O. Every
  durability/wire boundary uses total decoders.
- `core`, `machine` and `prompt` additionally hold no `@external` — of any
  target — and no `gleam_erlang` or `gleam_otp`, in source or in
  `gleam.toml`. That is a rule rather than a coincidence, and lint R6 gates
  on it at error level. Two properties rest on it: the operation state space
  stays property-testable without spawning processes, and those three stay
  compilable to the JavaScript target. One external closes both, however
  deterministic the function behind it is. Portable there means *decide but
  not act* — replay a conversation tree, validate a transcript with the
  server's own total decoders, run `next_action` over fetched state — and
  never the harness in a browser: `gleam_otp` has no JavaScript target, Rule
  Zero is kernel-enforced, and the two-channel doctrine needs processes on
  both sides. `docs/gleam-style.md` Part IV §5 has the whole argument.
- **No naked `Bool`** in a function parameter or a record field. `Bool`
  carries no domain meaning, so `render(document, True)` names nothing at
  the call site and a field typed `Bool` makes every reader carry the
  polarity of its name; model the question with a two-variant type named
  for the domain. Return position is outside the rule — `is_empty(xs) ->
  Bool` is the predicate the language is built to consume. Lint R9
  counts them; `docs/gleam-style.md` Part III, "No naked `Bool`", has the
  three escapes, one of which is that a frozen Part-1 field costs a
  `protocol-change/NNN.md` rather than an edit.
- **Process machinery goes through weft.** A deadline-bounded spawn, a
  phase machine written as mutually recursive functions, a timer whose
  handler checks for a stale fire, a list of waiters flushed on a state
  change, an ad-hoc ledger of monitored pids, a poll-until-deadline loop:
  each is a weft primitive (`weft` runs and managed tasks, `weft/actor`,
  `weft/state_machine`, `weft/poll`), and a hand-rolled copy is a review
  finding. `docs/weft.md` says which shape maps to which primitive, the
  standing rejections (`core`/`machine`/`prompt` never import it; `pg`
  fan-outs, untrappable-kill janitors, per-key deadline tables and
  logical-clock loops stay hand-rolled), and the rules a port is held to.
  Weft is the sibling checkout `../weft`; extending it is part of the job,
  not a workaround.
- Chain fallible steps with `use` + `result.try`, or a small `or_*`
  combinator where the two sides are not both `Result`; `case` is for
  ADT dispatch, never for stacking `Result`s — and never buy a shallower
  shape with a catch-all `_ ->`. Watch the eager ones: `bool.guard`'s
  `return:` and every `unwrap` fallback are ordinary arguments, computed
  on every call, so anything that recurses or allocates belongs in the
  `lazy_*` form. `docs/gleam-style.md` Part III has the whole of it.

## Working in the repo

`make help` lists the common commands. `make check` is the full gate —
format check, warning-free build, tests across every package, and the lint
— and is exactly what CI runs; `make check-<package>` narrows it to one.
Other regulars: `make fmt` before committing, `make selftest` to see which
sandbox enforcement layers the current kernel actually provides, `make
e2e` for the jailed end-to-end against a freshly built helper, and `make
e2e-codemode` for the code-mode pipeline against a real toolchain and a
real satellite (`make codemode-seed` prepares the offline cache it needs).
`make release` builds the self-contained server, `make release-smoke` boots
it with no `erl` on `PATH` and proves code mode registers from the bundled
toolchain, and `make dist` packages both plus the TUI —
`docs/distribution.md` says what a release carries and why.

**Verify a gate by its own exit code.** Backgrounding
`make check > log; echo $?; tail log` reports `tail`'s status, not `make`'s,
and has twice produced a confident false "green" here. Capture `make`'s
status directly and then read the log for failures. To check a commit
independently of uncommitted work, add a git worktree — but **not under
`/tmp`**, where code mode correctly refuses a cap socket because the jail
replaces `/tmp` with the scratch tmpfs. `docs/execution.md` §4 has the rest.

`make lint` is Loom's own house-rule lint over the Gleam sources, and it
runs at the end of `make check`. Twelve rules: R0 unparseable source, R1
eager fallbacks, R2 `case` nesting depth, R3 catch-all patterns, R4
`panic` and `let assert` in `src`, R5 O(n) answers to bounded questions,
R6 the portable subset `core`, `machine` and `prompt` are held to, R7 a
`let assert` carrying no `as "message"`, R8 a one-caller function wide
enough to be a moved pyramid, R9 a naked `Bool` in a parameter or field,
R10 a comment with no blank line above it, R11 a body written as one
undivided block. **R0, R2, R4, R6 and R10 fail the build**; the other
seven warn and cost nothing. R3 and R8 are censuses and will never gate:
both over-report by construction, which is the point of measuring rather
than refusing.
A rule reaches the error tier by a census that is zero, decidable and
argued — the staging lives in `finding.error_by_default`, and
`packages/lint/CLAUDE.md` says what each rule is for. `make lint-<package>`
narrows it. Read the warnings: they are the reason the gating rules could
be promoted, and they are only useful if somebody looks at them.

Two committed artifacts are generated and gated rather than regenerated
by the build. `make gen-prelude` re-renders
`packages/tools/src/tools/prelude.gleam` — the capability prelude's public
surface, which the `code_mode` description carries — from `packages/cap`,
and needs `gleam` and `python3`;
`make prelude-check` is the digest comparison `make check` runs and needs
neither. `make gen-sql` is the same arrangement for the generated SQL
modules. Change `packages/cap`'s public surface and you must regenerate,
or the gate fails naming the file that moved.

Gleam ships godoc-style documentation tooling of its own. Run inside a
package, `gleam docs build` renders the `////`/`///` doc comments into
HTML under `build/dev/docs/<package>`, and `gleam export
package-interface --out <file>` emits the compiler's machine-readable
account of the public API as JSON — the artifact `make gen-prelude`
renders the `code_mode` description from. (`gleam export
package-information` is the same treatment for `gleam.toml`.) Reach for
these to read an API as the compiler sees it rather than as a stale
comment claims it.

`gleam lsp` is the third one and it is **not** wired up here. It is a
language server meant to be driven by an editor over stdio, so it answers
nothing from a shell, and Claude Code's own LSP tool has no Gleam server
configured — asking it for a hover returns "No LSP server available for
file type: .gleam". Do not plan a task around go-to-definition or
find-references. `ast-grep` does not know Gleam either (`gleam is not
supported!`), so structural search over these sources is grep, or a
throwaway `glance` walk in `packages/lint` when the question is really
about the AST. For the public API surface, `gleam export
package-interface` is the answer and is exact.

`main` is the primary branch. Work happens on short-lived topic branches
named for the work itself — `storage/branch-index-repair`,
`fix/hashline-replay`, `wp-j/vetting-lint` — never for the tool or agent
that produced it. One work package or one fix per branch; merge to `main`
once its exit criteria pass.

## Where decisions live

A decision is only settled once it is written where the next reader will
look for it. Five places, and they are not interchangeable:

- **`docs/adr/NNN-*.md`** — architecture decisions with consequences that
  outlive one change: the SQLite binding, msgpack, budget pooling
  granularity. An ADR is amended by an **addendum inside it**, never by a
  silent edit; ADR-005's addendum on batch-versus-execution identity is the
  precedent.
- **`protocol-change/NNN.md`** — the only way to change an interface frozen
  in spec Part 1. Never silent drift. `001` and `006` are the format.
- **`docs/issue-plan.md`** — the plan of record behind the GitHub issues,
  including what each phase means and what gates what. Issues carry
  `phase:N` labels; `phase:debt` means found work with no phase gate.
- **The issue itself** — when measurement contradicts an issue's diagnosis,
  the correction goes *on the issue* as a comment. This happens often here
  (see `docs/execution.md` §6) and the next reader will find the filing
  before they find the commit.
- **The code** — a rule that can be checked belongs in `make lint`,
  `make doc-check` or a test, not in prose. Prose that a gate could enforce
  will drift; a gate will not.

Design intent lives in `docs/loom-design.md`, mechanics in
`docs/loom-implementation-spec.md`. **Where they conflict, the spec wins on
mechanics and the design doc on intent.** Where either conflicts with the
code, measure before believing the doc — the doc has usually been the stale
one.

## The documentation map

- **Orientation** — `README.md`, `docs/code-tour.md` (a guided read of the
  tree), `docs/notebook.md`.
- **Design and spec** — `docs/loom-design.md`,
  `docs/loom-implementation-spec.md`, `docs/spec-gaps.md`.
- **Architecture, per plane and subsystem** — `docs/architecture/`:
  `durability`, `orchestration`, `effects`, `code-mode`, `mcp`,
  `extensions`, `messaging`, `compaction`, `events`, `client`, `models`,
  `simulation`.
- **Decisions** — `docs/adr/`, `protocol-change/`.
- **Design notes** (explorations, not commitments) — `docs/design-notes/`.
- **Review waves** — `docs/review/`, one file per wave with its triage.
- **Operations** — `docs/distribution.md` (what a release carries and why),
  `docs/execution.md` (how work gets done), `docs/next.md` (what to do next).
- **Concurrency** — `docs/weft.md` (when and why a process is built on
  weft, the in-tree ports to copy from, and how to extend the library).
- **Style** — `docs/gleam-style.md`.

## Per-package docs

Each package with source carries a `CLAUDE.md` — purpose, key types, real
dependency edges, its actor/register/wire traffic with concrete type
names, and the invariants that break things when violated. Read the one
for the package you are about to change; it is denser and more current
than this file about that package.

`AGENTS.md` beside it is a byte-identical mirror, produced by `cp`, never
hand-edited. `make doc-check` enforces coverage and the mirror, and warns
when a package's source has been committed more recently than its docs.
The `/doc-gardening` skill (`.claude/skills/doc-gardening/`) is what grows
and refreshes the graph; run it for a package after changing its types,
messages, or dependencies.

## Commits

Make incremental, atomic commits that each tell one part of the story.
**Every commit is authored by the repository owner** — the repo-local
`user.name`/`user.email` (Olaoluwa Osuntokun <laolu32@gmail.com>) —
never by a tool or agent identity, and commit messages carry no
AI co-author trailers. Authorship is part of the no-tool-names rule:
check `git config user.name` before the first commit of a session and
fix it rather than committing under a default.
Format: `subsystem: imperative summary under 50 chars`, then a body in
natural prose explaining the why more than the what (no bullet-point
dumps). Prefixes: package name for single-package changes (`core:`),
`pkg1+pkg2:` or `multi:` across packages, `docs:`, `build:`, `ci:`,
`test:`. Lock files, generated files, and vendored code get their own
commits.
