---
name: doc-gardening
description: >
  Maintain the per-package documentation graph (CLAUDE.md/AGENTS.md) and the
  architecture roll-up (docs/architecture/) after code changes. Use when a new
  package was created, types/actor messages/dependencies changed significantly,
  after a large refactor, or when make doc-check fails.
argument-hint: "[package or 'all']"
allowed-tools: Read, Grep, Glob, Bash(make doc-check), Bash(git diff *), Bash(git log *), Bash(find *), Bash(cp *), Bash(ls *), Bash(awk *)
---

# Doc Gardening

Maintain Loom's per-package documentation graph after code changes. This
skill handles both **generating docs for a new package** and **updating
stale docs** for an existing one.

`$ARGUMENTS` is a package name (`core`, `broker`, `sandbox`) or `all` /
empty for a whole-repo sweep. Packages live at `packages/<name>/`; the
Gleam ones have `src/<name>/*.gleam`, and `sandbox` and `tui` are Go
modules.

Accuracy beats coverage. These files are read by humans and by agents
mid-task, so a wrong dependency edge or an invented invariant is worse
than a missing section. Read the actual source; never infer from a file
name.

## Phase 1: Detect what needs attention

**Scoped run** — read the package's `src` modules and its existing
`CLAUDE.md`, and decide new versus stale.

**Full run** (`all` or no argument):

```bash
# Gleam packages with source but no CLAUDE.md
find packages -mindepth 1 -maxdepth 1 -type d | while read d; do
  ls "$d"/src/*/*.gleam >/dev/null 2>&1 || continue
  [ -f "$d/CLAUDE.md" ] || echo "MISSING: $d"
done

# Go modules (sandbox, tui) with source but no CLAUDE.md
find packages -name go.mod -not -path '*/build/*' | while read m; do
  d=$(dirname "$m")
  find "$d" -name '*.go' | grep -q . || continue
  [ -f "$d/CLAUDE.md" ] || echo "MISSING: $d"
done

# Packages touched on this branch
git diff --name-only main...HEAD -- '*.gleam' '*.go' \
  | sed 's|^packages/\([^/]*\)/.*|\1|' | sort -u
```

Classify each package:

- **New** — has `src` modules but no `CLAUDE.md`.
- **Stale** — has `CLAUDE.md`, but `src/` has a newer last commit
  (`make doc-check` prints these as warnings; see Phase 6).
- **Scaffold** — the package directory exists but `src` is empty
  (`events`, `client`, `tui` at various times). Write nothing, or a
  two-line stub explicitly marked as scaffold. Do not describe a package
  from its `gleam.toml` alone.

## Phase 2: Read the package's sources

Gleam has no `go doc`, and `gleam docs build` requires a compile that may
race other agents — **reading source is primary**. For each package
gather:

1. **Module docs** (`////` at the top of each `src/**/*.gleam`). This
   repo's module docs were written to state contracts and invariants; they
   are the richest material available and usually carry the load-bearing
   half of the CLAUDE.md.
2. **Public declarations** — `pub type`, `pub opaque type`, `pub fn`,
   `pub const`, plus the `///` doc comments on them and on individual
   constructors.
3. **Imports** — these are the real dependency edges. `gleam.toml`'s
   `[dependencies]` gives the declared edges; cross-check both against the
   spec's DAG (`docs/loom-implementation-spec.md` §0.1), and report — do
   not silently "fix" — any divergence.
4. **FFI modules** — `src/*/internal/ffi_*.gleam`. Every `@external` in
   the package is confined there (spec §0.2), so the list of FFI modules
   is the list of the package's impurities. Always name them.
5. **Go packages** — the `// Package x ...` doc comment above `package x`,
   and the doc comments above exported types.

A fast sweep that gets module docs, imports, and public surface at once:

```bash
for f in packages/<pkg>/src/<pkg>/**/*.gleam; do
  echo "### $f"
  awk '/^\/\/\/\//{print;next} /^import /{print} /^pub (type|opaque|fn|const)/{print}' "$f"
done
```

Then read whole modules for anything the sweep leaves unclear.

## Phase 3: Trace the traffic

The template's traffic section is where a per-package doc earns its keep.
Loom has three kinds, and each wants **concrete Gleam type names**, not
prose:

**Actor messages.** Find `pub opaque type Message` / `Msg` / `PoolMsg` and
list one line per variant family; a variant with a `reply: Subject(...)`
field is a call, one without is a cast. Then find the *senders*:

```bash
grep -rn 'process\.send\|process\.call\|actor\.send\|actor\.call' packages/*/src
```

Name both ends — `runtime/writer.Commit(tx, reply)` sent by
`runtime/strand_runtime` and `runtime/api`, not "sends commits to the
writer".

**Durable-store traffic.** Almost every package's real interface is what
it commits and what registers it reads. Record:

- the `core/tx.Write` variants it builds (`InsertEntry`, `InsertUsage`,
  `SetRegister`, `DeleteRegister`) and through which path
  (`runtime/writer.commit`, `session` boot seeding, ...);
- the register namespaces it reads or writes, by their wire names —
  `strand.leaf`, `strand.config`, `strand.state`, `strand.last_result`,
  `op.meta`, `op.state`, `op.tool_args`, `op.preparation`,
  `pending.entry`, `fact.name`, `fact.label`, `fact.custom`;
- the CAS expectations it relies on (`SeqExpectation`), since those are
  the concurrency contract.

**Wire boundaries.** Name the frame kinds or event types crossing them:
the effect-plane `broker/framing.Frame` kinds (`hello`, `exec_start`,
`exec_stdin`, `exec_out`, `exec_exit`, `cap_call`, `cap_result`,
`cancel`, `heartbeat`, `error`), the provider's
`provider/stream.StreamEvent` (`Delta`, `Settled`, `Failed`) and its SSE
event names, `provider/http.HttpEvent`.

## Phase 4: Generate or update CLAUDE.md

Follow [template.md](template.md).

- **New package** — write from scratch against the template.
- **Stale package** — read the existing file, diff it against current
  source, and change only what actually moved. Do not rewrite prose that
  is still true; the file's stability is what makes its history readable.

Never name an assistant, an AI, or an authoring tool in generated
content. The file is documentation of the package, nothing else.

## Phase 5: Mirror to AGENTS.md

Every `CLAUDE.md` has a byte-identical `AGENTS.md` beside it:

```bash
cp packages/<pkg>/CLAUDE.md packages/<pkg>/AGENTS.md
```

Copy, never hand-edit the mirror — `make doc-check` compares them byte
for byte.

## Phase 6: Architecture roll-up

Check whether the change belongs in the as-built docs:

- `docs/architecture/{durability,orchestration,effects,simulation}.md`
  each end with a **Where the code lives** table. A new or renamed module
  belongs in the right one.
- A newly recorded interpretation of the spec belongs in
  `docs/spec-gaps.md`, and a frozen-interface change in
  `protocol-change/NNN.md` — never a silent edit to a per-package doc.
- Root `CLAUDE.md` keeps only the one **Per-package docs** pointer; the
  detail lives in the graph.

## Phase 7: Validate

```bash
make doc-check
```

`scripts/doc_check.sh` enforces three things:

1. **Coverage** — every package with `src` modules (Gleam or Go) has a
   `CLAUDE.md`. Failure.
2. **Mirror** — `AGENTS.md` exists and is byte-identical to its
   `CLAUDE.md`. Failure.
3. **Staleness** — the last commit touching `src/` is newer than the last
   commit touching `CLAUDE.md`. **Warning, not failure**: source moves
   faster than prose by design, and a warning is the queue this skill
   works from. Mtimes are meaningless in a fresh git checkout, so the
   comparison uses `git log -1 --format=%ct` on each path.

The script runs no builds and needs no toolchain, so it stays usable
while other work is compiling.

Fix every error before finishing, and report what was created, updated,
and left warning.

## Notes

- Skip `build/` entirely — it holds vendored dependency sources.
- Prefer the module doc's own words for an invariant; they were written
  to state one.
- Invariants are things that break if violated. "Hashline plans are
  digest-bound; re-apply always rejects" is an invariant. "Uses `Result`
  for errors" is not.
- For CI: `make doc-check` is the check-mode gate (coverage + mirror);
  the staleness warnings are the work queue for a `/doc-gardening all`
  pass, which commits its updates under a `docs:` prefix.
