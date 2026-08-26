# Loom

Loom is a BEAM-native coding agent harness written in Gleam. Sessions are
supervision trees over a durable, write-once conversation store; all effects
flow through a capability-checked broker into kernel-enforced sandboxes.

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

## Ground rules

- Design priorities, in order: security & isolation, correctness,
  robustness, performance, capability.
- Gleam >= 1.11, Erlang/OTP >= 27. All code passes `gleam format --check`
  and compiles warning-free before commit.
- Interfaces in spec Part 1 are frozen. Changing one requires a
  `protocol-change/NNN.md` proposal, never silent drift.
- Pure packages (`core`, `machine`) perform no I/O. Every
  durability/wire boundary uses total decoders.
- Chain fallible steps with `use` + `result.try`, or a small `or_*`
  combinator where the two sides are not both `Result`; `case` is for
  ADT dispatch, never for stacking `Result`s — and never buy a shallower
  shape with a catch-all `_ ->`. Watch the eager ones: `bool.guard`'s
  `return:` and every `unwrap` fallback are ordinary arguments, computed
  on every call, so anything that recurses or allocates belongs in the
  `lazy_*` form. `docs/gleam-style.md` Part III has the whole of it.

## Working in the repo

`make help` lists the common commands. `make check` is the full gate —
format check, warning-free build, and tests across every package — and is
exactly what CI runs; `make check-<package>` narrows it to one. Other
regulars: `make fmt` before committing, `make selftest` to see which
sandbox enforcement layers the current kernel actually provides, and
`make e2e` for the jailed end-to-end against a freshly built helper.

`main` is the primary branch. Work happens on short-lived topic branches
named for the work itself — `storage/branch-index-repair`,
`fix/hashline-replay`, `wp-j/vetting-lint` — never for the tool or agent
that produced it. One work package or one fix per branch; merge to `main`
once its exit criteria pass.

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
Format: `subsystem: imperative summary under 50 chars`, then a body in
natural prose explaining the why more than the what (no bullet-point
dumps). Prefixes: package name for single-package changes (`core:`),
`pkg1+pkg2:` or `multi:` across packages, `docs:`, `build:`, `ci:`,
`test:`. Lock files, generated files, and vendored code get their own
commits.
