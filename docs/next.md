# Next

**Read this first.** It is the handoff between sessions: where the tree
actually is, what to do next, and the decisions already taken so you do not
re-litigate them.

Keep it current. When you finish a body of work, rewrite this file — it is
worth more than any status comment.

---

## State, as of the head of `bridge/workspace-caps`

Two bodies of work are complete and merged or ready to merge.

**#106 — MCP through code mode — is done and on `main`** (merged at
`0f4dfac`'s lineage): generated per-server capability modules, wired end
to end, proved against a real server process, documented in
`docs/architecture/mcp.md`, closed on the issue with the rulings. Its
follow-ups are filed: #108 (HTTP+OAuth), #109 (the server-jail decision,
undesigned), #110 (wild-server e2e), #111 (elicitation), #112
(listChanged), and #107 (async code mode, with the state-machine
argument and Claude Code's replay-continuation prior art on the issue).

**#16 + #105 + #91 item 1 — the harness-side capability bridge — is
complete on this branch.** All eight workspace capabilities route:
`fs.read`, `fs.list`, `fs.write`, `fs.edit`, `kv.get`/`set`/`delete`
and `report.emit`, as `satellite.ServedHere` through
`codemode/workspace` — a seam record of injected closures wrapped in
front of the MCP arm and `satellite.default_router`, zero broker
changes, no `CallSpec` anywhere on the path. The closures are built
from `tools/fs`'s own boundaries: reads through `resolve_real` +
`read_text_file`, writes through `resolve_writable` — `resolve_real`
plus the protected-path refusal #105 added to the shared write path, so
the model's own `fs_write` gained it in the same commit and a satellite
write to `.git/hooks/post-checkout` is refused in band (proved through
a real jailed program, with the mutation run leaving the hook on disk
when the policy entry is removed). `kv.*` is `client/scratch`,
ephemeral and bounded three ways; `report.emit` is `codemode/artifact`,
one closure on **both** seams (#91 item 1) with a 1 MiB per-emit bound
and a 64-admission ceiling, content-addressed into the session's one
blob store — which the base policy now protects from jailed
pre-planting.

**The `fs.edit` ruling is made and implemented** (recorded in
`codemode/workspace`'s module doc): honest whole-file find/replace —
each `find` exactly once (zero → `StaleContent`, which now means "the
file no longer contains your text"; several → refused ambiguous), in
order, all-or-nothing, read-apply-write inside one served call. The
harness editor's anchor discipline was **not** synthesised on the
program's behalf; `cap/fs.Replacement`'s doc stopped lying. Real pins
remain open as a later layer.

The branch went through a full adversarial-review cycle (review →
verified fixes → re-verify by the same reviewer). Its findings are
worth knowing: a relative `protected` entry used to fail open on the
harness path (now refused in band *and* at boot via
`serve.base_policy_fault`); the component-prefix predicate existed as
three copies (now one public `policy.covers`); blobs are now
established by atomic rename, never direct write. `make check` passes
end to end at the head.

`main` holds phases 1 and 2 plus #106. **Phase 3 remaining: #14+#19,
#15, #27, #28/#29 — and #91 items 2–5 are still open** (item 1 closed
with the bridge).

---

## Start here: the phase-3 remainder

In dependency order rather than numeric:

- **#14** — the wiring seam's four model-routing questions. **#19** (replace
  `provider`'s two shipped stubs) is adjacent: routing that cannot walk a
  fallback chain to a real provider is not routing.
- **#15** — a canonical session id in `core`.
- **#106** — **MCP through code mode: the first increment is done.**
  `docs/architecture/mcp.md` is the living account; the rulings and their
  reasons are on the issue. The shape: generated per-server capability
  modules (`import cap/mcp/github`), never registered harness tools and
  never a generic dispatcher; `[mcp.<name>]` in `loom.toml`, file only;
  `packages/mcp` holds the protocol codecs, the stdio client actor, the
  façade generator and the value interchange; `client/mcp` starts one
  client per configured server at boot, widens the workspace seam's
  allowlist/description/generated-table/router as one field, and answers
  `mcp.<server>` as `ServedHere`; `codemode.execute` narrows the generated
  table to the vetted program's own imports before the builder vendors
  them into the prelude — fifty configured servers cost an unimporting
  program nothing. A checked-in `escript` fixture proves it against a real
  server process over a real pipe, wire names byte-identical end to end,
  including the `isError` leg and OS-pid teardown. The hostile-`tools/list`
  corpus is **built, not owed**: mangling digests on any change and a
  collision refuses the server; description text is stripped of every
  control/direction codepoint and a `glexer`-shaped `@` backstop asserts
  the cage held; schema reading is three-tier and total with nothing
  silently dropped; tool count, surface bytes, listing pages, result size
  and result depth are all capped with worded refusals.

  Still open on #106, deliberately: the **jail decision** for MCP server
  processes — `mcp/transport.PortTransport` spawns unjailed and the seam
  is where jailing would attach; this is undesigned, not merely unbuilt —
  an e2e against a third-party server from the wild, and the deliberate
  v1 cuts with their reversal triggers (HTTP transport, OAuth,
  elicitation, `listChanged`, restart supervision; see the architecture
  doc). **#107** (filed this increment) is the async-code-mode question —
  kept-alive satellite versus continuation handles versus a
  replay-with-memoized-effects shape; its comments carry the
  state-machine-expansion argument and the prior art.

  The finding carried into phase 5 held: the MCP stdio client **is** the
  supervised long-lived stdio substrate #25 needs, and it now exists
  (`mcp/client` + `mcp/transport`), so phase 5 starts from something
  rather than nothing.
- **#27** — triggered rules (TTSR).
- **#28**, **#29** — memory M1 and M2.

**Phase 5** is the language-service tier: **#25** (`lsp_*` over a sandboxed
per-project client) and **#26** (`dap_*` over the same port seam). Both need
a long-lived stateful stdio peer that phase 3 deliberately does not build.

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
- **MCP is code-mode only** (#106): generated per-server modules, never a
  generic `cap/tools.invoke` dispatcher. A generic dispatcher does not
  falsify the vetting theorem — it collapses its discriminating power, since
  the bound becomes "the whole registry, for every program", leaving one
  layer where code mode was built to have two. The bound is per *server*, not
  per tool, and that is deliberate: a human trusts a server. The
  once-unanswered question — `tools/list` is attacker-controlled JSON
  compiled into allowlisted source — is now answered structurally in
  `mcp/codegen`: server text reaches a module only as sanitized comments
  and escaped literals, names mangle with a digest and collide into
  refusal, and a backstop scan proves per module that the cage held.
  `docs/architecture/mcp.md` carries the whole argument.
- **R3 and R8 will never gate.** Both over-report by construction; they are
  censuses, and measuring rather than refusing is the point.

---

## Known-open, deliberately

- **CI has never completed a run** (#99) — all jobs die in under four seconds.
  This is owner-action; local `make check` is the real gate today.
- **`make lint` reports ~322 warnings at 0 errors.** That is the designed
  state. R5's promotion is five one-line fixes away (#73 names the files);
  the growth over the old ~306 is the mcp work's R3 census entries, the
  same `_ ->`-over-`JsonValue` shape `client/protocol` carries.
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

Three skills now live in `.claude/skills/` and earned their keep on the
#106 work: `/advisor` (a read-only design consult before code), `/advisor-review`
(the closing gate — one independent top-tier pass over a pinned diff:
invariants, simplification, live variants of the shapes just fixed; verify
every finding yourself, fix, then re-verify through the *same* reviewer),
and `/technical-writing` (read all six references before writing prose).
The two review cycles on this branch each returned real findings — a
quadratic over attacker-controlled schema input, an invisible-character
gap, servers spawned that nothing could reach — that same-author review
had read past. Treat the closing review as part of finishing, not polish.
