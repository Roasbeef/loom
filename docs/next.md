# Next

**Read this first.** It is the handoff between sessions: where the tree
actually is, what to do next, and the decisions already taken so you do not
re-litigate them.

Keep it current. When you finish a body of work, rewrite this file — it is
worth more than any status comment.

---

## State, as of `8b08ed6`

`main` is green and pushed. `make check` passes end to end (format, warning-free
build, every package's tests, and the lint at 0 errors). `make dist` builds a
58 MB release tree / 21 MB tarball whose smoke test boots with no `erl` on
`PATH` and registers `code_mode` from the bundled toolchain.

**Phases 1 and 2 are done.** Phase 2's orchestration seam landed, and the debt
wave behind it closed #73, #75, #87, #88, #90, #95, #102, #103 and #104.

**Phase 3 is open and unstarted.**

---

## Start here: the harness-side capability bridge

Phase 3's first body of work is #16, and **it is smaller than its filing
says**. The correction is a comment on the issue; the summary:

Counting modules that actually reach the harness through `dispatch.call` —
rather than modules on an allowlist — four of the nine need no router work at
all. `cap/git` composes `proc.run` inside the satellite and has worked since
the day `proc.run` was routed; `cap/task` and `cap/actor` are in-satellite
concurrency with no dispatch; `cap/proc` is already routed. The real surface
is **thirteen capability names across five modules**: `fs` (4), `kv` (3),
`lsp` (4), `net` (1), `report` (1).

Of those, `lsp.*` is blocked on a real language-server client (#25) and cannot
be argv-shaped — it is a protocol over a long-lived stdio peer, so no widening
of `proc.run`'s one-shot exec reaches it. `net.request` is blocked on the
egress proxy. **That leaves `fs.*`, `kv.*` and `report.emit` — eight names
across three modules, and they are one mechanism, not eight units of work.**

### The ruling, already made

An advisor settled the design; the argument is on #16 in full. The decisions:

**Route them as `satellite.ServedHere`, not through `clear_call`.** The
mechanism already exists and is in production for all six `strand.*` caps.
Build a workspace router shaped like `codemode/orchestration.gleam`, with a
seam record of injected closures, wired through `client/codemode.surface_router`.

**Zero broker changes.** `CallSpec` stays frozen — not one field, not one
variant, not one refusal arm. Forcing a harness-side read through a machine
built for jailed argv would compose a `SandboxPolicy` that *nothing enforces*,
because its enforcer is the jail and there is no jail here. It would also add
eight new `CallSpec` construction sites to the most security-sensitive dispatch
in the tree; `ServedHere` builds none, which is why the orchestration seam
chose it.

**Build the closures out of `tools/fs`'s own functions** — `resolve_real`, its
refusal vocabulary, its size caps — never a parallel path resolution. This is
the condition the ruling rests on. The orchestration seam's rule applies:
nothing about the authorization model is re-derived.

**Budget:** the pooled outstanding-effect cap and the wall deadline already
apply to every admitted call including `ServedHere`, so `fs.*` needs no new
budget. `report.emit` is the one member that earns a #88-style lifetime
ceiling — it mints a durable artifact per call — plus a per-emit byte bound.
`kv` gets a store-side byte cap with eviction, not an admission ceiling. Note
that `client/codemode.gleam`'s comment saying the workspace seam declares no
ceilings becomes **false** the day `report.emit` routes.

**Cut from the first implementation:** durable kv (keep it ephemeral,
byte-capped, gone on restart), per-call journalling, any escalation door from
the bridge, streaming reads, and `fs.edit`.

### Settle #105 before the write arms

`grep -rn protected packages/tools/src` returns **zero**. `base_policy.protected`
— the never-writable `.git`/`.env` list — is unioned during policy composition
and enforced *only inside jails*. The harness's own `fs_write` checks workspace
containment and nothing else, so `.git/hooks/post-checkout` is writable today.

Human supervision is the only thing containing that. Bridge `fs.write` to a
satellite loop and a vetted program holds **strictly more filesystem authority
than its own `proc.run`**, whose jail honours the list. The fix belongs in the
shared harness-side write path so the model's own `fs_write` gains it too, and
it must be checked *after* `resolve_real` or a symlink walks through it.

`fs.read`, `fs.list`, `kv.*` and `report.emit` do not depend on this. The
`fs.write`/`fs.edit` arms do.

### `fs.edit` lands second and alone

The two contracts do not line up, and it is a real design decision rather than
plumbing. The satellite side is `Replacement(find, replace_with)` — no anchors,
no digest. The harness `fs_edit` is anchor-and-digest-bound: hunks reference
`{line, anchor}` pairs from `fs_read`, plus a whole-file digest, and staleness
rejects the whole edit.

A satellite **cannot construct a harness-shaped hunk**, because `cap/fs.read`
returns plain string contents rather than anchored windows. So bridging `edit`
means the bridge synthesises anchors and a digest on the program's behalf —
inventing the safety property rather than checking one the caller committed to.
And `StaleContent` has no meaning when nothing was ever pinned.

Note that `cap/fs.Replacement`'s doc comment already claims the broker "applies
replacements with the same anchor discipline as the harness `fs_edit` tool",
which nothing can currently honour. Resolving that is part of this work.

---

## After the bridge

Phase 3's remaining issues, in dependency order rather than numeric:

- **#14** — the wiring seam's four model-routing questions. **#19** (replace
  `provider`'s two shipped stubs) is adjacent: routing that cannot walk a
  fallback chain to a real provider is not routing.
- **#15** — a canonical session id in `core`.
- **#25** — `lsp_*` over a sandboxed per-project language-server client. This
  unblocks the `lsp.*` arm of #16, so doing #16's `lsp` row *first* would mean
  stubbing it twice.
- **#26** — `dap_*` over the same port seam.
- **#27** — triggered rules (TTSR).
- **#28**, **#29** — memory M1 and M2.

Phase 4 is the promotion ladder (#30–#33, #100) and is built directly on the
router being real, which is why #16 gates it.

---

## Reading the issue tracker

Every open issue carries exactly one `phase:` label. **`phase:debt` is the
largest bucket and that is correct** — it means found work with no phase
gate, picked up in a debt wave between phases, and most of this tracker is
review-wave findings rather than planned milestone work. Do not read a
thin `phase:3` as a light phase; read it as an honest one.

*(Housekeeping: `phase:debt` was created implicitly by first use, so it has
GitHub's default grey and no description. Someone with web access should set
them.)*

### The dependency edges that matter

- **#99 is the root of the phase-1 subtree.** A check that has never
  completed cannot be made required (#1), and CI is the only environment
  likely to have a Landlock-capable kernel (#62).
- **#16's thirteen names are not equally blocked.** `#105` blocks only the
  `fs.write`/`fs.edit` arms; `#25` blocks the four `lsp.*` names; the egress
  proxy blocks `net.request`. **Nine of the thirteen are unblocked today.**
- **#16 blocks #30**, and therefore the whole phase-4 ladder — a skill that
  can only call `proc.run` is not a capability. This is the phase-3 → phase-4
  seam.
- **#30 → #31 → #32 → #33** in order, and #32 does not close until #33 does.
  **#100's classification work belongs before or during #32**, not after: it
  exists to shape the hook vocabulary while #32 is designing it.
- **#80 blocks #81** — the full-argument pager must render through #80's
  sanitiser, or a 40 KB model-controlled blob pages straight into a terminal.
- **#73's rule-A fix gates #74's census** — the fixes are independent, the
  measurement is not.
- **#89 is a soft prerequisite for #30**: L1 re-vets from source on every
  invocation, so a stored skill using a dialect the vetter misparses can
  never be invoked.

Decide-together pairs: **#77 + #82** (same single-latched door, spend site
and raise site). **#66 + #79** (bounding retries trades capability for
security with nowhere for capability to go until the session-widening valve
exists). **#58 + #69** (same harness; #69 is a live candidate cause for the
shape #58 presents as).

### Known-stale filings — re-scope before picking up

- **#42's scope shrank** when #35 landed; it may now be a few log calls
  rather than an events-plane addition.
- **#91 item 1 overlaps #16**: both cover `report.emit` being unrouted, on
  the orchestration and workspace seams. Service both seams in one change or
  each issue half-fixes it.
- **#73's baseline numbers are already moving.** Re-measure; do not trust
  the header.
- **#98 is a research record whose question is settled**, carried forward
  into #100. It will sit in the phase-4 bucket looking like a task.

**A general warning, learned twice this week.** An issue's own severity note
can be stale in either direction. #68 was filed as "benign today, fix it when
#65 lands"; #65 landed, and a plausible reading said #68 had therefore become
live and urgent. The code said otherwise — it had been fixed inside #65 and
never closed, with a test named for it. **Read the code before acting on a
filing's self-assessment, including when the filing sounds alarming.**

## Standing decisions — do not re-litigate

- **The ledger keys on `{op_id, step_id}`; paths key on
  `{op_id, step_id, source_index}`.** The pair is the *batch* identity the
  broker pools on; the triple is the *execution* identity. `source_index` is
  deliberately absent from `ExecIdentity`, whose exports feed ledger keys —
  adding it would mint one ledger per `code_mode` call and read the pooled cap
  as a per-call cap by another door. ADR-005's addendum has the argument.
- **The abort-epoch table is measured, not pruned.** Pruning is unsafe in both
  directions and the dangerous one is silent. See #104.
- **A host missing a code-mode prerequisite registers no `code_mode` tool at
  all**, deliberately: a tool definition is a byte prefix of the provider's
  cached region, paid on every request of every strand for the session's life.
  The *reason* it is missing is what got better, not the mechanism.
- **Code mode ships in the main release artifact**, with `DIST_CODEMODE=0` as
  the opt-out. See `docs/distribution.md` and #102.
- **R3 and R8 will never gate.** Both over-report by construction; they are
  censuses, and measuring rather than refusing is the point.

---

## Known-open, deliberately

- **CI has never completed a run** (#99) — all jobs die in under four seconds.
  This is owner-action; local `make check` is the real gate today.
- **`make lint` reports ~306 warnings at 0 errors.** That is the designed
  state. R5's promotion is five one-line fixes away (#73 names the files).
- **Jail and sandbox tests degrade in this container** — no cgroup v2, no
  Landlock. `make selftest` says what the host actually enforces. Failures
  there are environmental until run on a real host; #62 is that nobody has
  ever run Landlock.

---

## How to work here

Read `docs/execution.md` before dispatching sub-agents. It carries the wave
pattern, the briefing checklist, the verification standard, and the hazards
that have already cost time — including the two that will catch you first: a
verification worktree under `/tmp` breaks code mode, and `make check > log;
echo $?` reports the exit code of `tail`, not of `make`.
