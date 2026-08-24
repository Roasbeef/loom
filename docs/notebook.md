# Lab notebook

Running log of project state, decisions, and open threads. Newest entry
first. Each entry is written so that work can resume from it alone: what
exists, what was decided, what is in flight, what to do next. Companion
references: `docs/spec-gaps.md` (interpretation log), `protocol-change/`
(frozen-interface amendments), `docs/adr/` (bootstrap decisions),
`docs/architecture/` (as-built descriptions).

---

## 2026-08-24 — M3 complete: multi-strand, events, gateway, TUI

### State of the world

M3's acceptance holds and everything is on `main`: **717 Gleam tests
across eleven packages plus two Go suites**, gate ~40 s, tree clean.
The acceptance flow — prompt, streamed deltas, a subagent strand created
and reporting back durably, an escalation approved over the wire with
typed grants, fork, navigate, compact, catch-up replay from seq 1 —
runs purely through the public protocol as a test in `make check-client`,
and `gleam run -m client/demo` performs it live (the crash reports at
its tail are the documented close-is-a-controlled-crash teardown, exit
0). The parent-plus-two-subagents kill/reboot variant lives at runtime
level in `multi_strand_test`.

### What landed, per package

- **session**: forks (branch/tree, zeroed ledger, pi's fact rules),
  full projection with orphan healing at request construction, precise
  rewrite passing a raw-bytes erase audit, migrate-on-open.
- **events**: pg bus (hints), projection driver with the frontier rule
  (its own lost-event test found the two-scan high-water bug before it
  shipped), FTS5 search with parrot-generated SQL — the ADR-004 pilot
  verdict is positive, with an upstream byte-offset bug documented.
- **machine/runtime**: all five deferred triage items implemented;
  multi-strand recovery converges on "list the store, start what's
  missing"; escalations are consumed-before-dispatch registers.
- **client**: gateway hub whose event seqs ARE storage seqs (durable
  across restarts by construction; catch-up and paging fall out free),
  mist server, byte-identical conformance with the TUI's 32 fixtures.
- **tui**: Go bubbletea client with reconnect-exactly-once hammer tests
  and a --demo mode; its protocol.md is the normative body spec.

### Judgement notes

Two agent runs died to connection errors (provider earlier, gateway
this wave); both resumed from their own transcripts rather than
restarting, and both finished clean. On the first resume I asserted a
broken state that was actually another package's error surfacing
through the dependency tree — on the second I told the agent to assess
its own state instead. The second way is right.

The TUI-defines/gateway-implements order worked well: the client wrote
the normative body spec and fixtures first, the server then had a
conformance corpus and eight concrete questions to answer instead of a
blank page.

### Open threads for the next session

1. **M3 residue** (spec-gaps WP-L): escalation records need op/strand
   attribution; api.compact/api.navigate would deduplicate acceptance-
   plan building; optional-brief create_strand; queued-vs-placed acks.
2. **Adversarial review + soak over the M3 surface** — the M2 pattern
   (review wave → triage → fix wave) earned its keep; the new gateway
   and multi-strand code deserve the same treatment before M4.
3. **M4 — code mode**: cap/* prelude, vetting lint, hermetic compile
   service, satellite nodes, cells. The README already promises the
   programming model; M4 makes it true. Most security-sensitive work
   remaining; plan an adversarial vetting corpus from day one.
4. Standing: GitHub default-branch flip + stale branch delete (proxy
   refuses); `make selftest` on a target-tier kernel; periodic
   `make soak`.

### How to resume from nothing

Read `CLAUDE.md`, this entry, `docs/spec-gaps.md`. Gate: `make check`.
The doc graph (`packages/*/CLAUDE.md`) was refreshed after this wave.

---

## 2026-08-24 (end of day) — soak hardening; the runner found its own bug

### State

`main` green: `make check` — **610 tests**, ~38 s. Tree clean. Soak
verified clean over 1500+ seeds after the fixes below.

### Two defects in the soak path, both mine to own

**1. `make soak` could never run its own default.** EUnit imposes a
per-test timeout of about a minute and reports an overrun as a Timeout
with a stack trace pointing at wherever the runner happened to be — 60
seeds passed, 100 failed at 66 s, so the documented default of 2000
would always have died looking exactly like a hang in admission. The
target now chunks (`SOAK_CHUNK`, default 50), echoes each seed range,
and stops at the first failing chunk.

Process note: the first soak's completion arrived as **exit 0** and I
nearly took it at face value. `make` had returned Error 1; the `tail` at
the end of my own pipeline supplied the zero. Check the log, not the
pipeline's exit code.

**2. The runner could swallow its own scheduled crash** (found by the
soak at seed 5377, `run/crash-fired`). A commit is durable, and its
terminal result readable, *before* the writer runs its post-commit seam
— so the pump could take the result and gather the report while the
crash was still pending. My diagnosis (nondeterministic commit count
from terminal-racing steers) was **wrong on mechanism**: the count is
deterministically 6 in every run and the crash was armed on the last
commit. What widened the window from microseconds to two seconds was a
self-deadlock — a terminal intervention applied through a call that
waits, fired from inside the writer, whose admission then queued behind
the seam waiting for it.

Fix: the seam is observable, and no terminal result is accepted while
one is open (a crash counts as the seam closing, since the writer died
inside it). General — it holds whatever holds the seam open. Terminal
interventions are now detached; effect-process ones still wait, because
there the ordering is the whole point. `run/crash-fired` untouched: I
told the agent explicitly not to weaken it, and verified by diff that
the pre-existing carve-out was not newly added.

### Judgement worth keeping

Twice today a green-looking signal hid a real one (the e2e "failure"
that was the digest fix working; the exit-0 soak) and once a red one was
the runner catching itself. A check that refuses to count a vacuous run
is worth more than a check that passes — the temptation to relax
`run/crash-fired` was the wrong fix and was ruled out up front.

Also: the agent corrected my diagnosis with instrumentation rather than
accepting it. Subagent reports deserve the same skepticism as code, in
both directions.

### Next

M3 kickoff: WP-C-full (forks, compaction projection, transform hook),
WP-K events + parrot pilot (ADR-004), WP-L client gateway + Go TUI,
multi-strand demo. Standing items: `make selftest` on a target-tier
kernel; periodic `make soak`; GitHub default-branch flip and stale
branch delete (proxy refuses push-deletes).

---

## 2026-08-24 (later still) — DST simulation runner landed; it found a bug

### State of the world

The deterministic simulation runner is built, green, and pushed on
`main`. Gate: `make check` — **609 tests**, whole run in ~38 seconds.
Conformance grew 24→37; machine 67→68 (the regression test below).

### What it is

One seed splits two streams: one draws a session *script* (what turns
settle with, what tools return, when the user steers or aborts), the
other draws a *fault schedule*. The script runs twice against the real
tree — clean, then faulted — and the pair is held to named checks. The
split is the load-bearing idea: semantics live in the script so they
happen in both runs, which makes "every schedule converges" a claim
rather than a tautology with exceptions.

Requests are answered by the **phase of the projected context**, never a
counter, so a synthetic settlement written during recovery cannot shift
what comes next. That is what makes a seed reproduce exactly.

Fault taxonomy: crash at any commit boundary, crash *during* a live
effect, refused/stale commits, read faults, lease theft, dropped and
delayed doorbells, slow effects in logical time, effects that die or
time out, plus torn/corrupted frames against the framing decoders.

### The bug it found

**An orphaned deferred poll faulted the strand forever.** After a crash
left a poll pending with no live continuation, the planner asked for
identity resolution, then matched only the orphan report — so the
resolution answer it had itself requested fell through to the unknown
observation path and faulted. Every restart faulted again; the poll was
never replaced; the operation could never terminate. One-pattern fix;
the code's own comment already stated the intent.

This is exactly the row ORCH-H1 named as having zero crash coverage.
Deferring that finding to the runner instead of writing four scenarios
by hand was the right call, and this is the evidence.

Second, cosmetic: effect settlements raised at a strand name a reboot
had unregistered. Harmless (the message was always droppable) but noisy.

### Verification I did myself

Reverted the planner fix; the pinned machine-level regression test fails
with a pattern-match error on exactly that path; restored, green. Don't
take a fix report's word for a test's discriminating power.

### Honest limits (also in `docs/architecture/simulation.md`)

It drives **real processes, not a simulated scheduler**, so BEAM message
interleaving is not reproducible: a failure depending on a rare
interleaving may not reproduce on demand. Making that reproducible means
putting the whole runtime on an injected scheduler — a much bigger
change, not attempted. Also: one backend, one strand, one session; no
real effect plane (wire faults cover only framing); shallow scripts; a
monotone, non-adversarial clock.

Shrinking is real and validated (with the fix reverted, a three-fault
schedule shrinks to the single fault that still fails). Scripts are not
shrunk, deliberately: a turn's settlement depends on the phase its
predecessors produced, so dropping a turn yields a *different* session,
not a smaller one — a "minimal script" that way would be a fiction.

### API change other packages must know

`runtime/effects.Effects` gained a `Timers` field (`real_timers()` in
production). Every construction site must supply it; the two that
existed are updated. This is also the structural fix for the M2 clock-era
drift — one clock now serves store, driver, effects, and id minting in a
simulated session.

### Next

M3 kickoff: WP-C-full (forks, compaction projection, transform hook),
WP-K events + the parrot pilot per ADR-004, WP-L client gateway + Go
TUI, multi-strand demo. macOS Seatbelt deferred (no macOS here). Also
outstanding: run `make selftest` on a target-tier kernel to verify the
sandbox enforcement matrix, and `make soak` periodically.

---

## 2026-08-24 (later) — review-fix wave landed; branch is now `main`

### State of the world

All 18 triaged review fixes are landed and pushed on **`main`** (the
branch was renamed from the old agent-generated name; topic branches are
now named for the work, per CLAUDE.md). Gate: `make check` — **595 Gleam
tests** across the nine packages plus the Go sandbox suite, all green,
format-clean, warning-free. Working tree clean.

Test counts moved: core 88→95, storage 24→25, provider 79→86, broker
104→119, tools 140→157, conformance 23→24. Every increase is a
regression test for a specific finding.

### What was fixed (all confirmed by tests that failed before)

- **Critical**: anchored edit plans now carry a digest of the content
  they were computed against. Per-line staleness could not distinguish
  "unchanged line" from "identical sibling shifted into place", so a
  replayed edit double-applied on duplicate or blank lines — corrupting
  files through the very crash-recovery path the harness exists to make
  safe. `fs_edit` stays `replay: Safe`, now with a sound argument.
- **Security**: the pooled budget was inert (ledger discarded every
  call, cap never fired); proxy network mode granted unrestricted egress
  while reporting full enforcement — now fails closed at both broker and
  helper; `skip:` enforcement entries now fail a full-enforcement demand
  on their own; workspace symlinks no longer escape the root (real-path
  resolution, since these tools run harness-side with no jail behind
  them).
- **Untrusted input**: SSE carry is bounded with a scan offset (was
  unbounded + quadratic); usage counts clamp at the wire boundary (an
  out-of-range count produced an undurable durable object); both codecs
  bound nesting depth and reject duplicate keys (the two disagreed on
  precedence, which desyncs against the Go helper's last-wins encoder).
- **Durability**: negative scan limits settled (sqlite read them as
  unbounded); branch-metadata test was vacuous and is rebuilt around a
  compaction; query-plan assertion strengthened from a substring check.

Beyond the review, agents found: a token left live when checkout failed,
and an unmonitored relay that leaked its helper and call record forever
on crash. Both fixed.

### Where the reviews were wrong

Worth remembering when weighing future review output. DUR-02 claimed the
lease-fencing path untested; it was covered in a file outside the
reviewer's scope, and the implementation proved correct. My own report of
"provider broken mid-refactor" was a misread: the build error was in
`core/json.gleam` (another agent's in-flight edit) surfaced while
compiling provider's dependency tree, with the file header cut off by
`tail`. Reviews and orchestrator alike need the same skepticism the code
gets.

### Deferred (reasons in `docs/review/triage.md`)

ORCH-H1 (interleave harness never crash-tests deferred/compaction/
structural/navigation recovery) → folded into the DST runner rather than
patched with four hand-written scenarios. ORCH-M2/M3 and three LOW items
→ M3. Live-kernel enforcement verification → CI requirement on a
target-tier kernel (`make selftest`).

### Decisions recorded

`protocol-change/001` and `002` both ACCEPTED (each records the
adversarial case that was considered and rejected). `ADR-004` adopts
parrot for typed SQL, gated: pilot on WP-K's search database at M3, then
retrofit storage's CRUD with the plan assertions arbitrating each step.
Dependency verdicts for all seven candidates in `docs/deps-eval.md`.

### Next

1. **DST simulation runner** (WP-T extension) — the immediate next item.
   Seeded randomized explorer over schedules, effect-outcome
   permutations, and clock skew, with printed seeds and exact replay;
   simulated time so timers fire logically; fault injection beyond kill
   (torn frames, lease theft mid-run, slow effects). Subsumes ORCH-H1.
   The expensive precondition — every effect, clock, and entropy source
   already injected — is built.
2. M3 kickoff: WP-C-full (forks, compaction projection, transform hook),
   WP-K events + parrot pilot, WP-L client gateway + Go TUI, multi-strand
   demo. macOS Seatbelt deferred: no macOS in this environment.

### Operational notes

`main` is primary. Two things need a human in the GitHub UI: set the
repo default branch to `main`, and delete the stale
`claude/gleam-style-guide-docs-9ulhiu` remote branch (the proxy refuses
push-deletes with 403). `make help` lists the common commands.

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
