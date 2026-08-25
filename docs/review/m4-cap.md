# M4 adversarial review — the cap prelude, token/channel seam, satellite boot runtime

**Reviewer:** Opus adversarial reviewer (read-only).
**Scope:** `packages/cap` in full (`cap/internal/{channel,dispatch,ffi_registry,ffi_transport,wire,inbound}`, `cap/runtime`, `cap_ffi.erl`, and the public modules `fs/proc/net/git/lsp/report/task/actor/kv`), the tests, plus the parts of `packages/codemode` (`vet/policy`) and `packages/core` (`msgpack`) the cap safety story leans on.
**Charter:** try to falsify the four security claims — (1) a program cannot forge/bypass the channel, read/supply/replace the token, or reach another execution's channel; (2) a `.beam` that slipped vetting finds only the one token-checked door; (3) `cap/net` is deny-by-default; (4) the boot runtime is total and cancellation is real.

## Verdict

**The core boundary holds.** I could not construct a program-reachable path to forge a `cap_call`, read or replace the 32-byte token, name the channel actor's subject, send a `cap_call` without the token, or crash/hang the boot runtime with adversarial inbound bytes. The token is held only in the channel actor's private `State`; every public door is a pure marshalling stub over `cap/internal/dispatch`; the internal modules are unreachable to a submitted program by *two* independent mechanisms (Gleam's internal-module rule and the vetting allowlist); the deframer is total against every hostile frame shape I tried; and cancellation via caller-monitor `DOWN` is correct and unsuppressible.

The findings below are **defense-in-depth gaps and latent hazards**, not breaks of the primary claim. The most substantive (F1) is a real, code-traced property of the ambient channel binding that becomes exploitable only under a kept-alive satellite whose reaping policy lives outside this package. The rest are Low/Informational.

---

## Findings

### F1 — Ambient (VM-global) channel/token binding: a surviving process picks up the *current* execution's token — Low/Medium (kept-alive only)

**Claim probed:** (1) "cannot reach another execution's channel."

**Traced path.** The channel is resolved fresh on *every* cap call, from a VM-global slot:

- `cap/fs.read` → `dispatch.call("fs.read", …)` → `dispatch.call_within` → `ffi_registry.get_channel()` (`dispatch.gleam:32`), which reads `persistent_term:get({cap, channel}, undefined)` (`cap_ffi.erl:34`).
- `cap/runtime.boot` installs the channel with `dispatch.install(channel.to_channel(handle))` (`runtime.gleam:160`) → `ffi_registry.put_channel` → `persistent_term:put({cap, channel}, Channel)`, which **overwrites** (documented at `cap_ffi.erl:26-28`: "Overwrites any prior value (a kept-alive satellite re-installs with each invocation's fresh token)").

So the binding of a process to a token is **ambient and time-of-call**, not lexical. Any process still alive from execution *N* — a leaked/detached `cap/task` worker, or a persisted `cap/actor` — will, on its *next* cap call, read execution *N+1*'s `Channel` closure and therefore emit a `cap_call` carrying execution *N+1*'s token and be checked under *N+1*'s policy.

**Why it is only Low/Medium.** For the strict L0 case (node killed per execution, the documented default in `code-mode.md` "Layer two") this is moot: nothing survives to the next execution. Exploitation additionally requires an *autonomously acting* survivor, and the cap surface makes that hard:
- `cap/actor` actors are purely message-driven (the only self-message is `Drain`, which just drains already-queued user messages — `actor.gleam:238-257`); an actor acts only when sent a message, and its `Address` is opaque and cannot be persisted across programs (it is held only in the dead execution-*N* `main` process; `cap/kv` stores `BitArray` only). So a persisted actor is effectively inert in *N+1*.
- `cap/task` workers run their thunk once; a worker that outlives `main` requires the orphaning scenario in F2.

The residual hazard is real but narrow: execution *N*'s leftover code, if it survives and loops, acts with execution *N+1*'s authority. The cap package does nothing to prevent it — there is no per-execution/per-process check that "this is *my* channel."

**Fix options.** (a) Have the executor guarantee every program-spawned process is reaped before `dispatch.install` re-runs on a kept-alive cell (the cleanest, and belongs in `codemode`/executor, not cap). (b) Stamp each installed `Channel` with an execution epoch and have `perform` refuse a call whose epoch differs from the caller's captured epoch — but this fights the whole point of `persistent_term` (cross-process sharing) and is awkward. (a) is the right layer; this finding is primarily a note that **the cap package's isolation guarantee is contingent on that external reaping**, and that contingency should be written down where the boundary is claimed.

---

### F2 — `cap/task` orphans its unlinked workers if the combinator's process is killed out from under it — Low

**Claim probed:** (4) structured concurrency / "no work outlives its call."

**Traced path.** `cap/task` workers are `process.spawn_unlinked` + monitored (`task.gleam:316-321`); cancellation is driven by the combinator's own monitors in `cancel_running` (`task.gleam:352-358`). This is correct *as long as the combinator's process stays alive to run its collect/race loop*. But a `cap/actor` spawned elsewhere in the program is *linked* to the process that called `actor.start` (`actor.gleam:134-151`, relying on `gleam_otp` `actor.start` linking). If such an actor crashes `Abnormal` while `main` is blocked inside a task combinator, the non-trapping combinator process dies immediately from the link signal — abandoning `collect_loop`/`race_loop`. Its **unlinked, monitored** workers are now orphaned: nothing kills them, and their monitors died with the parent. They run to completion, spending pooled budget, until the host kills the node.

**Why Low.** The orphaned workers can still only make token-checked cap calls, and the host's per-execution node kill reaps them shortly after the `Errored` outcome is emitted (`run_program`'s monitor turns the dead `main` into `ProgramDown` → `Errored`, `runtime.gleam:291`). So "killing the satellite reaps the lot" still holds; the violated sub-claim is the finer "no work outlives its *call*" — briefly, it can. Also note a related asymmetry worth documenting: an actor crash *inside a task branch* is contained to that branch (the branch worker dies, reported as `Crashed`), which contradicts the strict "all-for-one under the program root" wording in `actor.gleam:9-13`. Arguably a feature (fault isolation), but the docs claim otherwise.

**Fix.** If the strict guarantee is wanted, `cap/task` workers could be linked-and-trapped under a per-combinator sub-supervisor rather than unlinked+monitored, so a dying combinator reaps them structurally. Otherwise, soften the doc claims to "reaped no later than node teardown."

---

### F3 — `channel.stop` abandons in-flight calls: neither settled in-band nor cancelled at the broker — Low/Informational

**Claim probed:** (4) no in-flight call left unsettled.

**Traced path.** `Fail` correctly settles every in-flight caller `Unreachable` and drops their monitors (`channel.gleam:284-293`). `Stop`, by contrast, is just `actor.stop()` (`channel.gleam:295`) — it does **not** iterate `inflight`, so it emits no `cancel` frames to the broker *and* sends no in-band answer. `boot` calls `channel.stop(handle)` immediately after emitting the outcome (`runtime.gleam:172`), while a program's spawned actor may still have a cap call in flight. That caller then blocks in `perform`'s `process.receive` for the full `deadline_ms + reply_margin_ms` (30s + 5s, `channel.gleam:57,226`) before falling back to `Unreachable`, and the broker-side effect (e.g. a `proc.run` child pgroup) receives no cancel.

**Why Low/Informational.** End-of-execution teardown is the host revoking the token and killing the satellite/executor pgroups, not the `cancel` frame — so the broker-side effect is reaped by token revocation, and `stop`'s own doc says "killing the satellite reaps it regardless" (`channel.gleam:204-206`). No true leak *given* that teardown revokes the token. But the behavior is a sharp corner: `stop` relies entirely on external revocation where `fail` is self-sufficient. Consider having `stop` reuse the `Fail` settlement path (answer in-flight callers `Unreachable`, optionally emit cancels) so teardown is robust even if token revocation is delayed.

---

### F4 — `cap/net` carries no local enforcement; "deny-by-default" is 100% a broker property — Informational

**Claim probed:** (3) `cap/net` is deny-by-default.

**Traced path.** `cap/net.request` (`net.gleam:57-72`) is structurally identical to `cap/fs.read`: it marshals `{method,url,headers,body}` and calls `dispatch.call("net.request", …)`. There is no local refusal, no policy field, and nothing a program can toggle. The deny-by-default lives entirely in the broker, which the module docs state (`net.gleam:1-12`).

**Confirmation (the claim holds, with a caveat).** A program *cannot* flip the policy: there is no policy argument anywhere in `cap/net`, and the token/policy are broker-side. So "not a stub the program can flip on" is confirmed. The caveat worth recording: within the cap package `net` contributes **zero defense-in-depth** — if the broker ever mis-classified `net.request` as allowed under a default policy, cap would not catch it. The `map_error` only *labels* the broker's refusal (`net.gleam:104-114`); it does not create it. This is by design (broker is the trust boundary), but a reader who expects "deny-by-default" to be a property of the *prelude* is mistaken; it is a property of the *broker*.

---

### F5 — `packages/cap` has no `CLAUDE.md`/`AGENTS.md` — Informational (process)

The charter directed me to read `packages/cap/CLAUDE.md`; it does not exist (nor `AGENTS.md`). Every other source package carries one per the root `CLAUDE.md` doc-graph rule, and `make doc-check` "enforces coverage." Either doc-check is not yet wired for cap or the docs were never written. Not a security issue, but the densest per-package invariants (the ones a future editor would break) are undocumented for the most security-critical package in the repo.

---

## Attacks that correctly fail (verified defenses)

- **Read/replace/supply the token.** The 32-byte token lives only in `channel.State.token` (`channel.gleam:133-144`), a private type inside an internal module. No public API accepts or returns a token, `Channel`, `Handle`, `Msg`, or the actor's `Subject(Msg)` (confirmed by scanning every public signature; the only `Subject`s in public modules are wrapped in the opaque `Address`/`Reply` or are function-local private types). `persistent_term` holds the `Channel` *closure*, not the token; even reading the slot yields no token, and reading the slot needs `@external` (forbidden) or the internal `ffi_registry` (unreachable).
- **Forge a `Perform`/`Deliver`/name the actor's subject.** `Msg` is `pub opaque` (`channel.gleam:105-123`); only `cap/internal/channel` constructs it. A program cannot name the subject (held in the opaque `Handle` / the `persistent_term` closure) nor construct the message even if it could.
- **Import the internal seam directly.** `import cap/internal/channel` (etc.) fails to compile from a submitted program for **two** independent reasons: Gleam's default `internal_modules` glob (`cap/internal`, `cap/internal/*`; no override in `packages/cap/gleam.toml`) makes them package-private, *and* the vetting allowlist (`codemode/vet/policy.gleam:210-226`) lists only `cap/{fs,proc,net,git,lsp,report,task,actor,kv}` plus a pure stdlib subset — `cap/internal/*`, `core`, `core/msgpack`, `gleam/erlang/*`, `gleam/otp/*`, `gleam/io`, `gleam/dynamic` are all absent (and `codemode_test.gleam` category 2 asserts `gleam/erlang/process`, `gleam/otp/actor`, etc. are rejected). This closes the "raw spawn / message an arbitrary registered name / bypass `cap/task`" avenue at the vetting layer.
- **Send a `cap_call` without the token.** The only path to the wire is `dispatch` → `channel.perform` → `Perform` → `handle` → `wire.encode_cap_call(id, state.token, …)` (`channel.gleam:244`), which always injects `state.token`. `wire.encode_cap_call` and the socket (`ffi_transport`) are internal/unreachable. There is no program-reachable path to emit a frame that skips the token.
- **Adversarial inbound bytes (deframer totality).** Every hostile shape I traced yields a value, not a crash: length prefix > 16 MiB → `Oversized` before any large allocation (`inbound.gleam:108-116`); `<4` bytes or short frame → carry, no loop; payload that will not parse → `Malformed` (`msgpack.decode` is total, `core/msgpack.gleam:126`, with bounded depth 256 / no trailing bytes / duplicate-key rejection per `core` invariants); wrong protocol version → `BadVersion`; body that is not a map, or `cap_result` with missing/wrong-typed/extra fields → `Malformed` via the total `wire.*_field` extractors (`wire.gleam:126-181`, `inbound.gleam:207-232`). Each fault becomes `channel.fail` → in-flight callers settled in-band and the channel latched dead (`runtime.gleam:246-256`, `channel.gleam:284-293`). Chunk-boundary invariance is real (`push_loop` carries the whole buffer until a full frame is available) and is regression-tested (`runtime_test.gleam:203-211`). Zero-length and duplicate-key frames do not loop or crash.
- **Crash/hang the boot runtime.** A program panic/`let assert` becomes `ProgramDown` → `Errored` outcome (`runtime.gleam:276-292`); the satellite always emits exactly one outcome. An unencodable outcome falls back to a tiny `Errored`, then to an empty frame — never a panic (`runtime.gleam:317-328`). Reader death is unlinked and harmless; channel-actor death leaves callers to time out to `Unreachable` rather than block forever. The only genuine "hang" is a program with a pure infinite loop/deadlock, which is bounded by the satellite's external wall-clock deadline (documented reliance, `runtime.gleam:283-286`) — acceptable by design.
- **Cancellation is real and unsuppressible.** The channel monitors the *caller* of every in-flight call (`channel.gleam:250`, `select_monitors` at `channel.gleam:166`). A `cap/task.race`/`fail_fast` loser is `process.kill`ed (`task.gleam:352-358`); its `DOWN` reaches the channel as `CallerDown` → `cancel_for_caller` emits a `cancel` frame for exactly that caller's in-flight id(s) (`channel.gleam:304-316`), regression-tested (`cap_test.gleam:149-175`). The program cannot suppress it (it cannot reach or stop the channel's monitor) nor misdirect it (ids are channel-allocated; the program never sees or sets them). `Deliver`/`CallerDown` races are order-independent and idempotent (a `Deliver` for an already-cancelled id is dropped, `channel.gleam:264-267`).
- **Re-install a program-controlled channel.** `dispatch.install` is internal and not on the allowlist; a program cannot call it. (Note the slot is last-write-wins, *not* literally set-once — see F1 — but the write path is unreachable to program code, so this cannot be abused from within a single execution.)
- **Deadline widening.** All program cap calls go through `dispatch.call`, which hard-codes `wire.default_deadline_ms` (30 s); `call_within` (the only deadline-taking entry) is internal. A program cannot set a longer per-call deadline.

## What I did not verify (out of scope / not yet in-tree)

- The **broker side** of the token echo, revocation list, `net` policy default, and executor-pgroup kill — all live in `packages/broker`/`tools`/`codemode` executor, not cap. F1/F3 are contingent on the host revoking the token on satellite teardown and on the executor reaping program processes on kept-alive re-install; I confirmed the cap side but not those hosts.
- **Kernel/OS sandbox** (no-network, no-distribution, cgroups, deadline) — `code-mode.md` "Layer two" describes it; enforcement is `make selftest`/executor territory, not this package.
- `gleam_otp`'s `actor.start` **link semantics**, which F2's "actor crash propagates" and cap/actor's all-for-one claim depend on — taken from the docs, not re-derived from the vendored `gleam_otp` source.
