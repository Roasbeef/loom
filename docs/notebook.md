# Lab notebook

Running log of project state, decisions, and open threads. Newest entry
first. Each entry is written so that work can resume from it alone: what
exists, what was decided, what is in flight, what to do next. Companion
references: `docs/spec-gaps.md` (interpretation log), `protocol-change/`
(frozen-interface amendments), `docs/adr/` (bootstrap decisions),
`docs/architecture/` (as-built descriptions).

---

## 2026-08-24 — M0–M2 complete; review wave and dependency triage

### State of the world

M0 (durability), M1 (state machine + runtime), and M2 (effect plane) are
implemented, tested, documented, and pushed on
`claude/gleam-style-guide-docs-9ulhiu` (~62 commits). Gate:
`scripts/check.sh` — 547 Gleam tests across core/storage/session/machine/
runtime/provider/broker/tools/conformance plus the Go sandbox suite, all
green, format-clean, warning-free.

Milestone acceptance evidence:
- M0: conformance suite green on both backends; 10k-entry branch scan
  p50 ≈ 2 ms (target < 5 ms); query-plan assertions in CI.
- M1: interleave harness — 42 kill points across 5 scenarios, all
  convergent; pi §0.5 crash-mid-tool reproduced live; 11-run session
  cold-opens from its SQLite file alone.
- M2: jailed end-to-end in `conformance` — scripted provider, real
  broker/pool/Go helper, bash + hashline read/edit, byte-exact file,
  exact ledger, crash rider on the integrated stack. Container enforces
  seccomp-net/rlimits/pgroup/truncation; bwrap/Landlock/cgroup are
  construction-tested only (degraded mode) — full matrix needs an
  unrestricted kernel.

Toolchain (installed in-container, not in repo): Gleam 1.18.1
(`/usr/local/bin/gleam`), Erlang/OTP 28.5 (hex.pm build,
`/usr/local/otp`), rebar3, Go 1.24. Reference checkouts:
`/home/user/earendil-works/pi` (harness spec at
`packages/agent/docs/harness.md` — the fidelity source),
`/home/user/roasbeef/claude-files` (skills: incremental-commit,
technical-writing).

### Decisions this entry

- **protocol-change/001 (BranchSummaryEntry.from_id → Option): ACCEPTED**
  and implemented. Adversarial case for rejection considered (keep the
  field total; represent root-sourced summaries with a sentinel or first
  entry id) and dismissed: a sentinel lies about provenance, pi's data
  model allows null, and the format-4 import would otherwise have to
  reject real transcripts. No invariant weakens: nothing dereferences
  `from_id` today, and `None` reads as "summarized from the root".
- **protocol-change/002 (Fault action variant; Tx-carrying actions):
  ACCEPTED** as implemented. Adversarial alternative considered
  (`Result(Action, CorruptionReport)` return) and dismissed as
  isomorphic-but-worse: it double-cases every call site and suggests the
  caller can "handle" corruption; Fault is a directive like the other
  five. Spec Part 1.3 text updated to match.
- **Deferred**: hoisting `SettledAssistantMessage` into core (WP-F gap 1
  + M2 gap 3, model facts on ModelIdentity) — one combined
  protocol-change candidate, deliberately after the adversarial review
  in case review findings touch the same types.

### Dependency triage (user-supplied candidates)

Cloned to scratchpad `deps-eval/` for source-level evaluation; verdicts
recorded in the entry below once the evaluation agent reports. Prior
stance from our own build: broker already contains a purpose-built helper
pool (checkout/lend semantics, dead-helper retirement) — general pool
libraries (bath, lifeguard) must beat it on semantics we actually need,
not genericity. parrot (sqlc-style typed SQL codegen) is attractive for
`storage/sqlite`'s hand-written SQL, with the hard constraint that the
branch-index queries are EXPLAIN-plan-asserted: any port must keep the
exact SQL text or re-prove the plans.

### Deterministic simulation testing (DST) position

What exists is DST-shaped on one axis: all time, entropy, and effects are
injected seams; the interleave harness deterministically enumerates every
commit-boundary crash and replays scripted effect outcomes; scenario
scripts key on stable features (tool-result counts), not minted ids.
What full DST adds and we lack: (1) a seeded randomized explorer
(schedules, effect outcome permutations, clock skew) with printed seeds
and exact replay; (2) simulated-time integration so timers fire logically
rather than by wall clock; (3) fault injection beyond kill (torn frames,
lease theft mid-run, slow effects). Plan: a WP-T "simulation runner" atop
the existing seams — the expensive part (injectable everything) is
already built. Scheduled after the review-fix wave.

### In flight

- Adversarial review wave: four reviewers (durability; machine+runtime;
  broker+sandbox security; provider+tools+wiring) — findings to
  `docs/review/` (created by the wave), triaged into a fix commit series.
- Dependency evaluation agent over `deps-eval/` checkouts.

### Next after review

1. Fix wave from review findings (severity-ordered).
2. Record dependency verdicts here + ADR-004 if parrot is adopted.
3. DST simulation runner (WP-T extension).
4. M3 kickoff: WP-C-full (forks, compaction projection, transform hook),
   WP-K events, WP-L client gateway + Go TUI, multi-strand demo,
   macOS Seatbelt (deferred: no macOS in this environment — flag).

### How to resume from nothing

Read `CLAUDE.md`, then this file top entry, then `docs/spec-gaps.md`.
Verify the gate: `scripts/check.sh`. The task graph lives in the session
task list but this notebook is authoritative on disk. Reference clones
(pi, claude-files) re-clone via anonymous git reads if missing.
