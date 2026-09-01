# Dependency evaluation — seven Gleam/BEAM library candidates

Source-level evaluation of seven candidates against Loom's needs as of
M0–M2 complete (2026-08-24). Method: each library's full source, tests,
and metadata were read from a checkout; each was built with the project
toolchain (Gleam 1.18.1, OTP 28.5); for parrot, the load-bearing question
(query-plan preservation) was settled empirically by running the pinned
sqlc binary over Loom's actual branch-segment SQL and schema.

Design priorities apply here as everywhere: security & isolation first.
A dependency in the harness VM is TCB surface; the bar for runtime deps
is much higher than for dev-time tools.

**2026-08-31 addendum.** The etch verdict below remains the historical verdict
on etch itself, but it no longer describes Loom's TUI. Issue #114 evaluated
etui instead, and Loom adopted the native `packages/tui_gleam` client after
raising the repository floor to Gleam 1.18 and OTP 29. The legacy Go client has
been retired. See `docs/design-notes/etui-client.md` for the measured decision
and its remaining approval and reconnect debts.

## Verdict table

| Library | Does | Maturity | Verdict | Milestone |
|---|---|---|---|---|
| gleamy_bench | comparative micro-benchmarks, table output | 0.6.0, Feb 2025, 261 LOC, trivial tests | SKIP | — |
| bath | generic resource pool (checkout/keep/discard) | 6.0.0, Feb 2026, well-tested, maintained | DEFER | M7 (follow-up 1, remote executor pools) |
| carpenter | typed ETS bindings | 0.3.1, Apr 2024, stale, pre-1.0 gleam_erlang pin | SKIP → VENDOR-MINI (~120 LOC own FFI) | M3 (WP-K) |
| lifeguard | actor pool (route messages to pooled workers) | 4.0.0, Jun 2025, thin tests | SKIP | — |
| spectator | BEAM/OTP observer web UI (processes, ETS, dashboards) | 2.1.2, Apr 2026, active, 3.6k LOC | ADOPT as standalone dev tool, never a dep | M3 |
| etch | terminal backend (crossterm-level: raw mode, cursor, styling) | 1.4.0, Jun 2026, solo author, thin tests | SKIP — keep Go/bubbletea TUI | — |
| parrot | sqlc-style typed SQL codegen from .sql files | 2.3.0, Jun 2026, single maintainer, integration-tested | ADOPT (gated pilot) | M3 (WP-K pilot), then incremental retrofit |

## gleamy_bench — SKIP

Single 261-line module (Apache-2.0, Hex 0.6.0, stdlib-only deps, compiles
clean; last commit 2025-02) that runs functions for a wall-clock duration
and prints an IPS/percentile table. It is built for interactive
comparative benchmarking, not CI assertion: `run` returns reps you could
post-process, but the value-add over what we have is nil. The conformance
perf smoke already measures with `erlang:monotonic_time` via a confined
FFI module and asserts p50 < 5 ms over 20 runs — ~30 lines,
assertion-oriented, part of the M0 acceptance evidence. Replacing that
with a duration-driven harness would make the CI contract *less* precise
(non-deterministic rep counts). Internally it also leans on `let assert`
/`panic` — harmless in a dev-dep, but nothing here justifies even that.
If comparative micro-benchmarks are ever wanted (e.g. tuning the DST
runner), it is a fine throwaway dev-dep; do not adopt it now.

## bath — DEFER to M7 (remote executor pools); our pool stays

Bath (MIT, Hex 6.0.0, Pevensie, last commit 2026-02) is the generic
*resource* pool: `apply(pool, timeout, fn(resource) { ... keep()/discard() })`,
FIFO/LIFO checkout, lazy/eager creation, caller-Pid monitoring so a
crashed borrower's resource is reclaimed, `supervised` child specs, and a
genuinely good test suite (21 tests including caller-crash, waiter-crash
dequeue, and discard-respawn cases). It compiles clean on our toolchain
and its deps (gleam_otp/erlang 1.x, deque, logging) are compatible with
ours. On semantics it is the right *shape* for the helper pool — but it
does not beat `broker/exec`'s pool on the semantics we actually need:
our pool retires dead helpers automatically at checkout/checkin by
probing helper liveness (bath only discards when the borrower says
`discard()` or crashes — a helper that died *between* leases would be
handed out and fail at use), and our whole pool is ~140 already-tested
lines with zero added deps inside the security-critical broker. Swapping
it would add TCB surface to gain nothing (and bath's `apply_blocking`
panics on timeout, where our `CheckoutError` is typed). Where bath earns
its keep is Part 5 follow-up 1 — remote executor pools with registration,
health, and affinity — where pooling stops being trivial. Reevaluate
there; it is the strongest external pooling candidate.

## carpenter — SKIP now; VENDOR-MINI our own ETS module at M3

Carpenter (MPL-2.0, Hex 0.3.1) is a thin typed wrapper over `ets` (set /
ordered_set, insert/lookup/take/give_away). It is effectively abandoned
— last commit April 2024 — and pinned to `gleam_erlang ~> 0.24`, a
pre-1.0 line that cannot resolve alongside our `gleam_erlang >= 1.0`
tree, so it is unusable as-is regardless of merit. Its API also lacks
what the projections/cache work will actually want (`select`/match
specs, `update_counter`, `foldl`), and its "typed" tables are unchecked
coercions on read — exactly the partial-decoding style Loom bans at
boundaries. Loom's ETS needs arrive with WP-K at M3 (cache tier,
projection state, the branch-index ETS path for small sessions). When
they do, write our own `internal/ffi_ets.gleam` confined per the FFI
policy — the carpenter source is a useful crib and the whole surface we
need is ~120–150 LOC, tested against our own invariants. Its MPL-2.0
license would also be the odd one out in an MIT/Apache tree; vendoring a
fresh implementation avoids the question entirely.

## lifeguard — SKIP

Lifeguard (MIT, Hex 4.0.0, also Pevensie, last commit 2025-06) is the
*actor* pool: workers are gleam_otp actors with pool-managed state, and
the API is `send`/`call`/`broadcast` — each call checks out a worker,
delivers one message, checks it back in. That is the wrong shape for the
helper pool, where a borrower owns a whole helper across a multi-frame
exec conversation (spawn → policy → stdin frames → exit), and equally
wrong for future remote pools (same reason). The Pevensie split is:
lifeguard pools *processing* (message-per-checkout), bath pools
*possession* (resource-per-checkout). Loom needs possession. Bath
supersedes it for every use we have; its tests are also much thinner
than bath's (162 LOC). Nothing wrong with the library — it just answers
a question we are not asking.

## spectator — ADOPT as a standalone dev tool at M3 (never as a dep)

Spectator (MIT, Hex 2.1.2, last commit 2026-04, actively maintained) is
a BEAM observer written in Gleam that understands gleam_otp processes:
sortable process table, OTP state inspection, suspend/resume, ETS table
browsing, ports, dashboards. For the M3 multi-strand work — parent + two
subagents, event bus, projections — visual inspection of the supervision
tree will pay for itself the first time a strand wedges. But it must not
enter the dependency tree: it drags mist, lustre, gleam_http, and
gleam_json into the build, i.e. an HTTP server and a frontend framework
inside a harness whose security posture is "no listeners by default"
(spec §3.3.5). The saving grace is that spectator explicitly supports
running as a *standalone* escript/docker app that attaches to a target
node over Erlang distribution. Use it exactly that way, in development
only: dev runs opt into `-sname`+cookie (distribution stays off in
production per the security invariants), and the spectator escript stays
in the developer's toolbox, not in `gleam.toml`. Note the monorepo
checkout does not build from its subdirectory (its docs config reaches
above the package root — `paths must not contain .. segments`); the Hex
release is the artifact to use. Zero integration cost, real M3 payoff.

## etch — SKIP; the Go/bubbletea TUI decision stands

Etch (MIT, Hex 1.4.0, last commit 2026-06, active) is an honest,
zero-dependency terminal *backend* — crossterm, not bubbletea: raw mode,
alternate screen, cursor control, keyboard/mouse events, styling, a
command queue (~2,000 LOC, compiles clean for the Erlang target; raw
mode and input need the companion `etch_erlang` package with its own
Erlang FFI). The WP-L decision it would have to reopen was not "Gleam
lacks ANSI escape codes"; it was that the TUI needs a mature *framework*
layer — components (bubbles), layout/styling (lipgloss), markdown
rendering (glamour), and years of terminal-quirk hardening — coupled to
the harness only through the Part 1.6 protocol. Etch supplies none of
that layer; adopting it means writing a widget toolkit, a layout engine,
and a markdown renderer from scratch on a young (v1.4.0, solo-author,
~490 LOC of tests, JS-first packaging) foundation. To reopen a
deliberate decision the challenger must be clearly stronger than the
incumbent stack; etch is several ecosystem-years away. Keep the Go TUI.
Worth a bookmark for Follow-up 9 (thin clients) if a Gleam TUI framework
ever grows on top of it.

## parrot — ADOPT, gated: pilot on WP-K, retrofit storage incrementally

Parrot (Apache-2.0, Hex 2.3.0, last commit 2026-06, listed as a
community project on the sqlc site) generates Gleam from `.sql` files
via a pinned sqlc binary. The critical question was whether it can carry
the branch-index queries whose `EXPLAIN QUERY PLAN` output is a CI
contract. Settled empirically: sqlc 1.31.1 (parrot's pinned version) was
run over Loom's actual schema (WITHOUT ROWID tables included) and the
exact `segment_sql_desc` text — `CROSS JOIN` driving from
`branch_entries`, `?1..?4` numbered params — and it parses, types the
params correctly (TEXT/INTEGER/INTEGER/limit), and **emits the SQL
byte-for-byte**: parrot generates `let sql = "<verbatim text>"` and
returns `#(sql, params, decoder)`, so the plans are preserved by
construction, and `"EXPLAIN QUERY PLAN " <> sql` still composes because
the generated function hands you the text. It is sqlight-compatible by
design (driver-agnostic tuples plus a documented ten-line
`Param -> sqlight.Value` wrapper), so ADR-002 is untouched.

Honest liabilities: it is a single-maintainer project with thin unit
tests (~145 LOC; the real coverage is per-engine integration suites);
its runtime module `parrot/dev` is small (~124 LOC of param types and
decoders) but generated code imports it, so parrot becomes a *full*
dependency of `storage` and drags its codegen deps (gleam_httpc,
gleam_crypto, simplifile, spinner, etc.) into the resolution tree even
though only codegen uses them; and codegen fetches the sqlc binary over
the network — mitigated well (version pinned in source, per-platform
SHA-256 verified before use, integrity re-checked on every run), and
avoidable in CI by pre-provisioning the binary at the pinned path. The
codegen flow needs a throwaway SQLite file built from our DDL (parrot
pulls schema from a live db via the sqlite3 CLI) — a ten-line script.

**What we do now**: adopt, but do not flag-day the proven backend.
(1) Record this as ADR-004. (2) Pilot parrot on the next *new* SQL
surface — WP-K's FTS5 search database at M3 — where there is no
regression risk and the workflow (schema script, codegen step, wrapper)
gets proven. (3) Then retrofit `storage/sqlite`'s straightforward
statements (the CRUD inserts/selects) in a mechanical commit series,
moving the plan-asserted segment queries last; the CI plan assertions
stay exactly as they are and arbitrate every step. PRAGMAs, schema DDL,
and dynamically-composed statements stay hand-written — parrot is for
named static queries, which is most of them. If the dependency weight in
`storage` ever becomes unacceptable, the fallback is documented here:
`parrot/dev` is 124 LOC and could be vendored with a post-generation
import rewrite — friction we accept only if forced.

## Recommended actions

**Now (before/at M3 kickoff):**

1. **parrot**: write ADR-004; add the schema-dump + codegen script;
   pilot on WP-K's FTS database; begin incremental retrofit of
   `storage/sqlite` behind the untouched plan assertions.
2. **spectator**: add the escript to the dev workflow notes for M3
   multi-strand debugging; dev nodes opt into distribution, production
   never does. No gleam.toml change.
3. **carpenter's job**: schedule a ~120–150 LOC confined
   `internal/ffi_ets.gleam` inside WP-K when the ETS cache/projection
   tier lands; do not adopt carpenter.

**Later:**

4. **bath**: reevaluate at M7 follow-up 1 (remote executor pools) — the
   strongest external pooling library, currently beaten by our
   purpose-built pool on dead-helper retirement, TCB weight, and fit.
5. **etch**: no action; revisit only if a full Gleam TUI framework
   materializes on top of it (Follow-up 9 at the earliest).
6. **gleamy_bench / lifeguard**: no action; both skipped on fit, not on
   quality.
