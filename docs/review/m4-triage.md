# M4 review triage — code mode (J1–J3b)

Three Opus reviewers attacked the code-mode security surface before the Go
launcher (J3c) was built: vetting soundness (`m4-vetting.md`), the cap
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

## Where this stands

The fix wave and J3c have both landed. Every **FIX** and every **DOC**
item below is done except the two package-doc items, which the doc pass
following J3c closes, and CH-F7, which landed in part for a reason the
entry records. The deferrals that remain are the ones needing a kernel
this machine does not have, plus two structural follow-ups (C-F2's linked
workers, V-F4's fail-closed parser boundary) that are recorded work, not
open holes.

## Disposition

Legend: **FIX** (this wave, failing test first), **DOC** (correct a
claim / add package docs), **DEFER** (J3c or `make e2e`, recorded). Each
entry opens with what happened to it.

### From vetting (`m4-vetting.md`)
- **V-F1 (MED) → FIX. DONE.** The `@external` backstop was a raw
  `string.contains`, so it rejected any program containing the literal
  `"@external"` in a string or comment (e.g. an agent grepping a codebase
  for FFI). Fails closed, so a usability bug, not a hole. The backstop now
  scans the `glexer` token stream for an `At` token followed by a `Name`
  (`vet.dangling_attribute_backstop`). That also closed **V-F2**
  (whitespace- or comment-separated dangling `@external` evading the
  substring — whitespace and comments are discarded before the scan) and
  **V-F5** (other dangling attributes silently dropped: the scan collects
  every `@name` and subtracts the ones the AST accounted for).
- **V-F3 (MED) → DEFER (J3c/e2e). DONE — the backstop was built.** Vet
  parses with `glance`; the harness compiles with `gleam`. `@external` had
  a parser-independent backstop; imports did not. No divergence was ever
  exhibited. `vet.unseen_import_backstop` now sweeps the token stream for
  `import` paths, subtracts the ones `glance` surfaced, and rejects the
  remainder, so a future parser disagreement fails closed instead of
  silently admitting a module. `vet.token_imports` is public so the
  scanner half of the cross-check can be tested directly.
- **V-F4 (LOW) → DOC. DONE.** `vet`'s "never panics" was stronger than
  `glance` can honor — `glance.gleam:944` has a `panic` not triggered by
  fuzzing. DoS, not bypass. The module doc now claims totality only
  "given `glance` returns" and names the residual. A fail-closed parser
  boundary remains deferred hardening.

### From the cap boundary (`m4-cap.md`)
- **C-F1 (MED for kept-alive; moot for L0) → FIX (guard) + DOC. DONE.**
  The channel and token live in a VM-global `persistent_term` slot that
  `boot` overwrote per execution, so a process surviving from execution N
  would read N+1's token on its next cap call. Moot for strict L0 (the
  node is killed per execution) but load-bearing for the kept-alive
  satellite mode the design describes. `dispatch.install_exclusive` now
  refuses to overwrite a slot whose channel actor is still alive, and the
  invariant — the executor reaps every program process before re-install —
  is stated in `channel.gleam` and in `code-mode.md`.
- **C-F3 (LOW) → FIX. DONE.** `channel.stop` abandoned in-flight calls (no
  in-band settle, no cancel frame), unlike `fail`. Teardown now settles
  in-flight calls through the same path `Fail` uses, so a program blocked
  on a call unblocks at once instead of waiting out its deadline.
- **C-F2 (LOW) → DOC. DONE (doc); structural fix still owed.** `cap/task`
  can orphan unlinked workers if a linked `cap/actor` crash kills the
  combinator process; they run to node teardown. The "all-for-one" claim
  was also imprecise. `task.gleam` now says where the structure ends,
  `actor.gleam` says what the link actually propagates (spawner, not
  program root, so a branch-spawned actor is fault-isolated rather than
  all-for-one), and `code-mode.md` carries both. Linking workers into a
  per-combinator sub-supervisor is a recorded follow-up.
- **C-F4 (INFO) → DOC. DONE.** `cap/net` contributes no local enforcement;
  deny-by-default is entirely a broker property. The claim holds (no
  policy field exists for a program to flip). `net.gleam` and
  `code-mode.md` now say plainly that net confinement is broker-side.
- **C-F5 (INFO) → DOC. DONE.** `packages/cap` had no
  `CLAUDE.md`/`AGENTS.md`; the post-J3c doc pass wrote them, and
  `make doc-check` is green.

### From the compile service + host (`m4-compile-host.md`)
- **CH-F4 (MED) → DOC + FIX (test). DONE.** The cap-channel token is
  readable inside the jail, so a hand-written `.beam` reads
  `LOOM_CAP_TOKEN_FILE` and presents a valid token. So the token does NOT
  confine that adversary; the kernel jail + the broker's per-call policy
  check do. The narrative is corrected in `code-mode.md`, `channel.gleam`,
  and `satellite.gleam`: the token authenticates the channel (against a
  cross-execution or external-socket caller) and enables revocation; a
  hostile in-jail `.beam` is confined by policy + jail. The tabletop now
  carries both halves — an unauthenticated `cap_call` denied, *and* the
  genuine token presented against a policy-forbidden call and refused.
  The kernel half of the same argument has since been built as well: see
  "What the self-test now proves about a hostile `.beam`" below.
- **CH-F3 (MED) → FIX. DONE, including (b).** Reachable leak: the
  wall-deadline timer was armed before `launch`, so a launch that
  outlasted the deadline made the host stop and drop the later `Connected`
  (carrying `connection.destroy`), leaking the node and socket. The
  deadline is now armed on `Connected`, and `hand_over` monitors the host
  so a `Connected` that arrives after the host died is destroyed rather
  than dropped. (b) is built too: `launch.start_janitor` spawns an
  unlinked process monitoring the host and running the same teardown
  whenever it dies, mirroring the broker's fd-3 safety net, so a host
  killed from outside leaves no node, socket, or token file behind.
- **CH-F1 (MED) → DOC + DEFER. DONE, both halves.** The "manifest
  independently closes the build even if vetting misses" claim was false:
  `cap`'s deps (`gleam_erlang`, `gleam_otp`, `core`) put their public
  modules in the program build graph, so they would compile if imported.
  Vetting rule 2 already rejected them, so there was no live hole. The
  redundant denylist landed (`vet/policy.is_denied`, consulted before the
  allowlist, with its own message). The build-graph half landed with J3c
  rather than being deferred: the production builder compiles with
  `--warnings-as-errors`, which turns Gleam's "transitive dependency
  imported" warning into a hard error, so `gleam/erlang/*`, `gleam/otp/*`,
  and `core/*` are now refused by the *compiler*. `make e2e-codemode`
  proves it with a program that vets on purpose and fails the build. Two
  limits stay: `gleam_stdlib` is a direct dependency, so vetting's
  allowlist is still the only gate on `gleam/io` and friends, and every
  module present remains loadable at run time by a hand-written `.beam`,
  which is the jail's problem.
- **CH-F2 (MED) → DEFER (J3c). DONE.** No `manifest.toml` lock was
  generated and `gleam_stdlib` was a wide range, and an offline build
  cannot resolve a Hex stdlib without a pre-seeded cache.
  `compile.stdlib_version` now pins one exact version, and `codemode/seed`
  builds a seed project once, online, whose resolved `manifest.toml` and
  package cache every build root is cloned from. The prelude is vendored
  *inside* the build root at a fixed relative path, because Gleam records
  a local dependency's path relative to the project root and re-resolves
  on a mismatch. `seed.verify` refuses a seed whose dependency table is
  not byte-identical to the generated one, and a build that reaches for
  Hex anyway is reported as a broken seed rather than a broken program.
- **CH-F5 (LOW) → FIX. DONE.** The host's outcome-frame decoder skipped
  the `v`/`id` envelope checks every other kind gets. Every payload now
  goes through `framing.decode_payload` first; the host reads the
  `outcome` body only after `framing` has validated the envelope and
  reported the kind as unknown.
- **CH-F6 (LOW) → FIX. DONE.** Each inbound `cap_call` spawned an unlinked
  collector before the budget gate. The pooled outstanding-effect cap is
  now checked in the host actor before any collector exists, so a refused
  call costs no process.
- **CH-F7 (LOW) → FIX. PARTIAL, and deliberately so.** The double *decode*
  is gone: `framing.decode_payload` is the only decoder, and the host
  reads only the `outcome` body itself. The local length-prefix splitter
  stays, because `framing.push` decodes as it splits and hands back
  nothing but the id and kind for a kind it does not know — and `outcome`
  is exactly such a kind, so its body would be discarded. `broker/framing`
  is frozen (spec Part 1.4), so carrying a raw body needs a
  protocol-change proposal rather than a fix. The duplication is confined
  to the u32 length read and the shared `framing.max_frame_bytes` guard.
- **CH-F8 (LOW) → DOC. DONE.** `packages/codemode` now has
  `CLAUDE.md`/`AGENTS.md`.

## What J3c also turned up

Not a review finding, but the launcher work surfaced a gap worth the same
visibility: **`SandboxPolicyV1` has no vocabulary for binding a path into
the jail at all.** The cap socket and the token file are reachable today
only because the helper's base view ro-binds the entire host filesystem
and Landlock grants `RODirs("/")`. Two consequences —
`readable_roots` does not actually restrict reads (only `protected` does),
and a path under a `protected` entry or, with tmpfs scratch, under `/tmp`
is *invisible* in the jail — are written up in
`protocol-change/004-sandbox-policy-explicit-mounts.md` (PROPOSED, not
implemented). The launcher meanwhile expresses both paths as
`readable_roots` and refuses up front the cases the vocabulary cannot
represent.

## What `make e2e-codemode` now proves

Four scenarios run the real pipeline — real vetting, a real
`gleam build --warnings-as-errors` inside a network-off jail, a real `erl`
node behind a real AF_UNIX cap socket, and a real `broker.clear_call`
behind the capability:

- The happy path: a program's `proc.run` reaches `/bin/echo` in a second
  jail and its output comes back in the structured `Outcome`, nothing
  scraped from stdout. Repeating it over the same build root reproduces
  the outcome and the manifest hash, and clears a planted stale `.beam`.
- The build-graph gate: a program that vets on purpose but imports
  `core/msgpack` fails the build naming a `direct dependency` (CH-F1).
- Real node death at the deadline: a CPU-bound program that makes no
  capability call settles as `DeadlineExceeded` after at least five of its
  six seconds — so the kill is the deadline, not a node that never
  booted — and the cap socket and private token file are both gone after.
- The type checker as argument validator: a mistyped capability call
  returns `Type mismatch` in band before any node spins up.

## Still deferred to a target-tier kernel (`make e2e`)

The claims with halves only a real kernel can prove, consistent with the
existing sandbox degraded-mode practice. The development container has no
bubblewrap binary, no Landlock, and no delegated cgroup v2 hierarchy, so
`make e2e-codemode` prints the helper's honest enforcement report and says
in as many words when network-off was not enforced:

- **The build's hermeticity.** It runs offline; that it *could not* have
  reached the network needs seccomp or a network namespace.
- **Memory and process-count ceilings**, which need cgroup v2.
- **`connect(2)` on the cap socket through a bubblewrap `--ro-bind`.**
  Reasoned from `sb_permission` (sockets are exempt from `EROFS`) and
  Landlock's rights model, and never observed, because no run so far has
  had bubblewrap to bind with.

The items this section used to list that are now covered — real node
death at the deadline, the launcher dispatching `erl` under the abortable
`op_id`, and kernel confinement of a malicious `.beam` — moved into the
sections above and below.

## What the self-test now proves about a hostile `.beam`

CH-F4's correction ended with a claim that had no observation behind it:
that what confines a hostile `.beam` is the kernel jail, not the cap
token. The broker's half of that had a test; the kernel's half was
reasoning. It is now the sandbox self-test's `unvetted beam denied host
write, secret, and network` probe, which the jail CI job declares
`required` in `.github/enforcement-expectations`.

The adversary is `packages/sandbox/internal/selftest/loom_hostile.erl`:
Erlang, not Gleam, compiled by `erlc` and dropped straight into a jailed
node's code path. It never passes vetting (which reads Gleam source),
never passes the compile service, and never uses the cap channel. It
calls `file:write_file/2`, `file:read_file/1` and `gen_tcp:connect/4` on
its own behalf — which is what a Gleam `@external` compiles to anyway.
Confined, it gets `erofs` on the write outside every writable root,
`enoent` on the protected path, and `eperm` on the connection to a live
loopback listener the probe is holding open.

Three denials in a row are also what a module that never loaded looks
like, so the probe refuses to read containment out of silence. The
adversary announces that it loaded and that it finished; it performs two
effects the policy *allows* and reports them, so a run of pure denials is
a probe failure rather than a pass; and the identical module is run
unjailed first, with the probe skipping if the escape does not succeed
even there. The permanent record of the other direction is a test in
`packages/sandbox/internal/selftest` that runs the same adversary through
the same jail with those three mechanisms granted instead of withheld,
and insists it reaches all three.

What is **not** proved, and is deliberately not claimed: "reaches nothing
on the filesystem". The helper's base view is `--ro-bind / /` and
Landlock grants `RODirs("/")`, so an unprotected host path is readable
from inside the jail. `readable_roots` narrows nothing; only `protected`
removes a path from the view. That is
`protocol-change/004-sandbox-policy-explicit-mounts.md`'s gap, not this
probe's, and until it closes the honest sentence is "an unvetted `.beam`
cannot write outside its writable roots, cannot see a protected path, and
cannot reach the network" rather than the broader one M4 originally
wrote.
