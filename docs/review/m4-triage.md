# M4 review triage — code mode (J1–J3b)

Three Opus reviewers attacked the code-mode security surface before the Go
launcher (J3c) is built: vetting soundness (`m4-vetting.md`), the cap
boundary + token + boot runtime (`m4-cap.md`), and the compile service +
satellite host (`m4-compile-host.md`).

## Bottom line

**No capability escape was found on any of the three surfaces.** A
correctly-vetted program cannot reach an effect its imports do not admit;
a submitted program cannot forge the channel, read or replace the token,
or reach another execution; the deframers are total against hostile
bytes; module-name and the token check hold; pooled budget cannot be
amplified. Every finding below is a defense-in-depth gap, a cleanup bug, a
claim that overstates what a layer does, or doc hygiene — not a
single-layer break.

The one finding that changes the security *argument* is CH-F4: the
cap-channel token does not confine a hostile `.beam` inside the jail (the
`.beam` can read it). That correction is folded into the fixes below.

## Disposition

Legend: **FIX** (this wave, failing test first), **DOC** (correct a
claim / add package docs), **DEFER** (J3c or `make e2e`, recorded).

### From vetting (`m4-vetting.md`)
- **V-F1 (MED) → FIX.** The `@external` backstop is a raw `string.contains`,
  so it rejects any program containing the literal `"@external"` in a
  string or comment (e.g. an agent grepping a codebase for FFI). Fails
  closed, so a usability bug, not a hole. Fix: scan the glexer token
  stream for an `At` token followed by `Name("external")` instead of the
  substring. This also closes **V-F2** (whitespace/comment-separated
  dangling `@external` evading the substring) and **V-F5** (other dangling
  attributes silently dropped, contradicting "fail closed on the whole
  attribute class") — a token scan sees every `@name`.
- **V-F3 (MED) → DEFER (J3c/e2e).** Vet parses with `glance`; the harness
  compiles with `gleam`. `@external` has a parser-independent backstop;
  imports do not. No divergence was exhibited. Add a lightweight import
  backstop now if cheap (a token-stream `import` sweep cross-checked
  against the AST); otherwise record a glance-vs-gleamc differential CI
  gate as deferred hardening. The live enforcement (the allowlist) is
  unaffected.
- **V-F4 (LOW) → DOC.** `vet`'s "never panics" is stronger than `glance`
  can honor — `glance.gleam:944` has a `panic` not triggered by fuzzing.
  DoS, not bypass. Soften the totality claim in the module doc to "total
  given `glance` returns" and note the residual.

### From the cap boundary (`m4-cap.md`)
- **C-F1 (MED for kept-alive; moot for L0) → FIX (guard) + DOC.** The
  channel/token live in a VM-global `persistent_term` slot that `boot`
  overwrites per execution, so a process surviving from execution N would
  read N+1's token on its next cap call. Moot for strict L0 (the node is
  killed per execution) but load-bearing for the kept-alive satellite
  mode the design describes. Fix: have `boot` refuse to re-install over a
  live slot (or reap first), and document the invariant — "the executor
  reaps every program process before re-install" — where the boundary is
  claimed (channel.gleam module doc + code-mode.md).
- **C-F3 (LOW) → FIX.** `channel.stop` abandons in-flight calls (no
  in-band settle, no cancel frame), unlike `fail`. Route `stop` through
  the `Fail` settlement path so a program blocked on a call is unblocked
  on teardown rather than relying solely on external revocation.
- **C-F2 (LOW) → DOC.** `cap/task` can orphan unlinked workers if a linked
  `cap/actor` crash kills the combinator process; they run to node
  teardown. Also the "all-for-one" claim vs per-branch fault isolation is
  imprecise. Correct the concurrency prose; the structural fix (link
  workers into the combinator) is a small follow-up, noted.
- **C-F4 (INFO) → DOC.** `cap/net` contributes no local enforcement;
  deny-by-default is entirely a broker property. The claim holds (no
  policy field exists for a program to flip). State plainly that net
  confinement is broker-side.
- **C-F5 (INFO) → DOC.** `packages/cap` has no `CLAUDE.md`/`AGENTS.md`.
  Run `/doc-gardening cap`. (`make doc-check` correctly errors on this.)

### From the compile service + host (`m4-compile-host.md`)
- **CH-F4 (MED) → DOC + FIX (test).** The cap-channel token is bind-mounted
  readable into the jail, so a hand-written `.beam` reads
  `LOOM_CAP_TOKEN_FILE` and presents a valid token. So the token does NOT
  confine that adversary; the kernel jail + the broker's per-call policy
  check do. Correct the narrative in `code-mode.md`, `channel.gleam`, and
  `satellite.gleam`: the token authenticates the channel (against a
  cross-execution or external-socket caller) and enables revocation; a
  hostile in-jail `.beam` is confined by policy + jail, not the token. Add
  the missing tabletop assertion: present the *real* token and assert the
  broker refuses a policy-forbidden call. Keep the un-tokened-denied test
  — it still proves the channel-auth property.
- **CH-F3 (MED) → FIX.** Reachable leak: the wall-deadline timer is armed
  before `launch`, so a launch that outlasts the deadline makes the host
  stop and drop the later `Connected` (carrying `connection.destroy`),
  leaking the node/socket. Fix: arm the deadline only after `Connected`,
  and destroy on a `Connected` that arrives after stop. Consider a
  monitor-based janitor mirroring the broker's fd-3 safety net.
- **CH-F1 (MED) → DOC + DEFER.** The "manifest independently closes the
  build even if vetting misses" claim is false: `cap`'s deps
  (`gleam_erlang`, `gleam_otp`, `core`) put their public modules
  (`gleam/erlang/process`, `gleam/otp/*`, `core/*`) in the program build
  graph, so they would compile if imported. Vetting rule 2 already rejects
  them (not on the allowlist), so no live hole. FIX now: add an explicit
  denylist of `gleam/erlang*` + `gleam/otp/*` to vetting as cheap
  redundant defense with a clear message. DOC: correct the
  manifest-independence claim. DEFER: physically stripping the build graph
  to cap's public surface is J3c Builder work.
- **CH-F2 (MED) → DEFER (J3c).** No `manifest.toml` lock is generated and
  `gleam_stdlib` is a wide range, and the offline build can't resolve a
  Hex stdlib without a pre-seeded cache. This is the production `Builder`'s
  job (currently injected/faked in tests). Record as J3c: generate a
  locked manifest + vendor/seed the stdlib.
- **CH-F5 (LOW) → FIX.** The host's outcome-frame decoder skips the `v`/`id`
  envelope checks every other kind gets. Apply the same validation.
- **CH-F6 (LOW) → FIX.** Each inbound `cap_call` spawns an unlinked
  collector before the budget gate. Order the gate first / link the
  collector so a flood cannot spawn unbounded collectors.
- **CH-F7 (LOW) → FIX.** A second length-prefix splitter duplicates
  `framing.push` and double-decodes non-outcome payloads. Split once, hand
  cap_call/cancel/heartbeat to `framing`, decode only the `outcome` body
  locally.
- **CH-F8 (LOW) → DOC.** `packages/codemode` has no `CLAUDE.md`/`AGENTS.md`.
  Run `/doc-gardening codemode`.

## E2e deferral (make e2e on a target-tier kernel)

Both the tabletop and hermeticity claims have halves only a real kernel
can prove, consistent with the existing sandbox degraded-mode practice.
Deferred and recorded here so nothing reads as covered when it is not:
real node death; kill of a CPU-bound zero-`cap_call` program at the
deadline; the network-off offline build; kernel confinement of a
malicious `.beam` (reaches nothing on fs/network); and the launcher
dispatching `erl` under the abortable `op_id`. These land with J3c + `make
e2e`.

## Fix-wave order

1. One Opus fix agent lands the **FIX** items across `cap`, `codemode`,
   and the narrative (`code-mode.md`), each with a failing test first
   (the standing rule). CH-F4's test and V-F1's token scan are the
   load-bearing ones.
2. `/doc-gardening` for `cap` and `codemode` (greens `make doc-check`),
   run after the type/message changes above settle.
3. Then J3c (Go launcher + production `Builder`, carrying CH-F2 and the
   CH-F1 build-graph stripping) and `make e2e` on a target kernel.
