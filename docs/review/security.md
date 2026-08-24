# Security review — Loom enforcement layer (broker + sandbox)

Adversarial read-only review of the trusted computing boundary:
`packages/broker` (policy, framing, token, budget, escalation, exec,
broker, internal/ffi_crypto, internal/ffi_port) and `packages/sandbox`
(the Go `loom-exec` helper: cmd + all internal packages). No tracked
files were modified. No throwaway probes were compiled (all findings are
static; the kernel layers this container lacks are noted below).

## Threat model recap (design §5.1)

Attackers, hardest last: (1) prompt-injected model steering tools toward
exfiltration/destruction; (2) malicious generated code (code-mode /
satellite); (3) compromised MCP servers or language-server binaries.
Every security property is enforced *below* the model by kernel
primitives (bwrap/Landlock/seccomp/cgroup/rlimits) plus broker-side
checks (policy composition, capability tokens, pooled budget). A crash of
the trusted broker is itself a denial-of-service. This review looks for
where enforcement has a hole, or where hostile/malformed input crashes or
starves the broker.

---

## Findings by severity

### HIGH — 1. Pooled per-execution budget is inert; the amplification cap is not enforced (CONFIRMED)

`packages/broker/src/broker/broker.gleam:366`

```gleam
case budget.reserve(budget.open(spec.budget), now:) {
  Error(refusal) -> #(state, Error(BudgetRefused(refusal:)))
  Ok(_ledger) ->            // <-- ledger discarded, never stored
```

Every `clear_call` opens a **brand-new** ledger (`budget.open`), reserves
one slot, and throws the ledger away. The broker `State`
(`broker.gleam:164`) holds `vault`, `next_call`, `active`, `self` — there
is **no ledger, and no per-op/per-token ledger table**. `Settle`
(`broker.gleam:312`) checks the helper back in and revokes the token but
releases no budget, because nothing was ever persistently reserved.

Consequence: the `max_outstanding` cap the `budget` module exists to
enforce does nothing. On a fresh ledger `outstanding` is always 0, and
the invariant makes `max_outstanding >= 1`, so `0 >= cap` is never true —
`reserve` can only ever fail on `DeadlinePassed`. The design's headline
amplification defense (design §6.5: "10,000 polite parallel reads; 50
spawned test runs … refused past the cap, however politely they ask") is
**completely unenforced**. 10,000 concurrent `clear_call`s each get their
own ledger and each pass.

This is exactly the amplification hole the budget module's doc claims to
close. The re-mint / settle-underflow attacks the brief asks about are
moot: no re-mint is needed, and `settle` (which floors at 0, correctly) is
never even reached for budgeting because the ledger is not retained.

Fix direction: hold a `Dict(op_id_or_token, budget.Ledger)` in broker
`State`; `reserve` against the *stored* ledger at `authorize`, persist the
returned ledger, and `settle` it on `Settle`/`abort`/relay teardown.

---

### HIGH — 2. Network `proxy` mode grants unrestricted egress and reports full enforcement (CONFIRMED behavior; phase-1 gap, but silently)

- `packages/sandbox/internal/jail/bwrap.go:63` — `--unshare-net` is added
  **only** for `NetworkOff`.
- `packages/sandbox/internal/jail/stage2.go:120` — the seccomp
  socket-blocking filter is installed **only** for `NetworkOff`.
- `packages/sandbox/internal/policy/policy.go:33` — proxy "records the
  proxy address and allowlist but the enforcing sidecar is a later work
  item".

Design §5.2 states of `Proxy(allowlist)`: "the sandbox **blocks direct
sockets**, making the allowlist enforceable and loggable." The
implementation does the opposite: under `network: proxy` the jail keeps
the host network namespace **and** has no socket seccomp filter, so the
child has full, direct, unrestricted egress to anywhere — the allowlist
and proxy address are decorative.

The sharper defect is that this is **not surfaced as reduced
enforcement**. For a proxy-mode exec the `enforcement` list contains no
network entry at all (no `seccomp-net`, no `unshare-net`), and
`Result.Degraded` stays `false` because `Features.Degraded()` keys only on
bwrap presence (`features.go:66`). So:

- `exec.gleam` FullEnforcement checks only the `degraded` bool
  (`exec.gleam:724`) — it passes.
- there is no `skip:` marker announcing that proxy confinement was not
  applied.

A prompt-injected or malicious flow that gets `network: proxy` approved
(far less alarming to a human than `full`) obtains a wide-open
exfiltration channel that the broker believes is confined. The helper's
own doc claims it "reports this honestly" — it does not.

Fix direction (short of the sidecar): treat `proxy` as at-least-as-
restrictive as `off` at the kernel layer until the proxy exists (unshare
net + seccomp, egress only via the proxy fd), or at minimum emit a
mandatory `skip:network-proxy-unenforced` enforcement entry and have
`FullEnforcement` refuse it.

---

### MEDIUM — 3. Unbounded msgpack nesting depth → stack/heap exhaustion DoS (SUSPECTED)

`packages/core/src/core/msgpack.gleam:240` (`decode_value` →
`decode_array`/`decode_map` → `decode_value` …) has **no depth limit**.
`broker/framing.decode_payload` calls `msgpack.decode` on the whole frame
payload up front, and the frame cap is 16 MiB
(`framing.gleam:38`). A payload of ~16.7M `0x91` bytes (fixarray, length
1) is a ~16.7M-deep nested array — a non-tail recursion 16.7M frames deep
in the decoder. On the BEAM this grows the process stack/heap without
bound and can OOM the process (or the node), which for the broker is a
denial-of-service.

Reachability: the data-plane framing/msgpack decoder is the shared
decoder for *all* semi-trusted/untrusted peers per the two-channel
doctrine (§5.6): executors, satellites (model-authored code), MCP servers,
language servers. `decode_body` handles `cap_call`, whose `args` is
arbitrary attacker-shaped msgpack that `msgpack.decode` fully parses
before any field is read. The satellite→broker channel (WP-J) is
deferred, so I could not confirm a live path today — hence SUSPECTED —
but the decoder is the boundary that path will use.

The Go side (`vmihailenco/msgpack`) has the analogous property (deep
nesting → goroutine stack panic), but the helper only decodes frames from
the trusted broker.

Fix direction: thread a depth counter through `decode_value` and reject
beyond a small bound (the protocol's real structures are shallow) in
`core/msgpack`; mirror a `DecodeMaxDepth`/manual bound on the Go decoder.

---

### LOW — 4. Duplicate-key precedence differs between the two decoders (CONFIRMED; latent desync)

- Gleam: `framing.check_keys`/`policy.reject_unknown_keys` accept
  duplicate *known* keys, and `find` (`framing.gleam:787`,
  `policy.gleam:767`) takes the **first** occurrence.
- Go: `DisallowUnknownFields` struct decoding and `DecodeInterfaceLoose`
  map decoding take the **last** occurrence and raise no error on
  duplicates.

`{v:1, v:2, kind:"heartbeat", kind:"exec_start", …}` is read as
`heartbeat` by the broker and `exec_start` by the helper. Not exploitable
today — both framing endpoints are trusted (broker↔helper), and policy
bytes are broker-generated — so this is a latent robustness gap, not a
live bypass. It becomes live the moment either decoder is pointed at an
attacker-controlled frame (the same cap_call path as #3). Fix direction:
both decoders should reject any duplicate map key outright.

---

### LOW — 5. fd-3 policy temp file: guaranteed unlink only on in-actor death paths (CONFIRMED)

`packages/broker/src/broker/exec.gleam` + `broker_ffi.erl:100`.

The mode-0600 policy file in a mode-0700 dir is unlinked by `run_cleanup`
on hello and on every in-actor death path (`mark_dead`, `Shutdown` →
`run_cleanup`), and on `spawn_helper`'s error branches. But if the helper
actor is killed abnormally (supervisor brutal-kill, node crash) after the
file is written and before hello, `run_cleanup` never runs and the file
leaks. It is not a disclosure (the 0700 dir denies other users
regardless of the file mode — the write-then-chmod window is correctly
closed by the private directory), only a disk-fill leak over many spawns.

Secondary hardening: `write_private_file` does `filelib:ensure_path` then
`change_mode(dir, 0700)`. If `SpawnConfig.tmp_dir` is a predictable,
pre-existing, attacker-owned directory the `change_mode` fails closed
(spawn errors), but the safety depends entirely on the caller passing a
private per-session `tmp_dir`. Prefer `mkdtemp`-style exclusive directory
creation with a random component rather than `ensure_path` on a
caller-named path.

---

### LOW — 6. Ground-truth enforcement `skip:` entries are not auto-checked; degraded-mode gaps rely on the bool alone (CONFIRMED; mostly by-design)

`exec.gleam:724` decides FullEnforcement pass/fail from the `degraded`
bool only, ignoring the `enforcement` `skip:` entries that are the actual
ground truth. For network-off this is safe (bwrap netns and seccomp are
independent, and `degraded=false` implies bwrap⇒netns present), and for
protected-path masking degraded mode correctly sets `degraded=true`. The
one place it bites is finding #2 (proxy), where neither layer runs yet
`degraded=false` and no `skip:` is emitted. Also worth stating plainly
(consistent with `spec-gaps` WP-H #7): in degraded mode `protected` paths
are entirely unenforced (bwrap absent; Landlock has no deny rules —
`llock.go:8`), and a `setsid()` target escapes the pgroup kill with no PID
namespace to reap it. All of that is gated by `degraded=true` ⇒
FullEnforcement refusal, so it is acceptable *provided callers demand
FullEnforcement*. Recommend the runtime inspect the `enforcement` list
(via `escalation.ExecutionDenial`) rather than trusting the bool.

---

## Checked and sound

- **Constant-time token compare.** `ffi_crypto.constant_time_equal`
  (`broker_ffi.erl:34`) routes to OTP `crypto:hash_equals/2` with a
  length pre-check answering `false` (lengths are public — all tokens 32
  bytes). `token.scan` (`token.gleam:237`) folds over every entry with no
  early exit, so neither a match's position nor a near-miss leaks timing.
  Entropy is `crypto:strong_rand_bytes` (`broker_ffi.erl:26`), injected
  as a function so production never uses a PRNG.
- **Token lifecycle.** Single-use: `Settle` revokes
  (`broker.gleam:318`), `BrokerUnavailable` revokes
  (`broker.gleam:428`), `abort` `revoke_all`s by op
  (`broker.gleam:303`). Revoked entries are retained (refuse as
  `Revoked`, never resurrected as unknown). `check_for` binds op_id +
  step_id, so a live token cannot be used cross-op. Revocation precedence
  is total and correct.
- **Policy composition is most-restrictive-wins.** `meet` intersects root
  coverage, meets the network lattice (`Off` dominates), takes per-field
  limit minima (0 = unlimited handled at the correct lattice pole),
  intersects env, unions protected, collapses differing scratch to tmpfs
  (`policy.gleam:273`). I found no composition that widens. Grants widen
  only within escalation bounds (see below).
- **Prefix-aware roots are path-component correct.** `covered_by`
  (`policy.gleam:297`) uses `path == root || root == "/" ||
  starts_with(path, root <> "/")`, so `/work` does **not** cover
  `/worker`, and non-coverage fails to the restrictive side. (Traversal
  like `/work/../etc` is a non-absolute-after-normalization concern the
  jail's kernel layers handle; the string form here never treats `..` as
  coverage.)
- **Escalation single-consume.** Pure state machine; `consume` only fires
  from `Approved` and moves to `Consumed` (`escalation.gleam:147`), so a
  second consume is `NotApproved`. `approve` rejects any grant not in the
  denial's `wanted` diff (`escalation.gleam:114`), and a rejected
  escalation can never yield grants. The "one re-execution" invariant
  holds by construction.
- **Budget arithmetic itself.** `reserve`/`settle` are correct in
  isolation — `settle` floors at 0 (no underflow on double-settle),
  `reserve` refuses at cap and past deadline. The defect is that the
  broker never *uses* a persistent ledger (#1), not the module.
- **Framing length handling / no over-allocation.** Both decoders cap at
  16 MiB (`framing.gleam:38`, `framing.go:29`) before allocating; the
  Gleam deframer waits for bytes via `take_frame` and never pre-sizes
  from the prefix; array/map headers decode element-by-element and error
  on exhaustion rather than pre-allocating (`msgpack.gleam:349`). A u32
  length near 2^32 is rejected by the cap. Oversized ⇒ dead deframer,
  matching the close-the-channel contract.
- **Shell / argv injection.** The fd-3 spawn passes `["-c", 'exec
  3<"$2" "$1"', "loom-exec", helper_path, policy_path]` as an execv-style
  arg list to `spawn_executable` (no intervening shell); helper and
  policy paths are positional `$1`/`$2`, quoted, never interpolated into
  the script string (`exec.gleam:970`). bwrap argv is built as a
  `[]string` and run via `exec.Command` (execve, no shell); every policy
  path is a single argv element and is validated absolute by *both* the
  broker and the helper (`policy.gleam:837`, `policy.go:231`), so a path
  cannot masquerade as a `--`-flag operand. No injection found on either
  path.
- **seccomp filter shape.** Arch is checked and mismatches
  `RET_KILL_PROCESS` (defeats the foreign-arch table bypass); x32 is
  killed on amd64 (`seccompf.go:112`); `socket`/`socketpair` allow only
  `AF_UNIX` (low 32 bits of arg0, which the kernel also reads as a 32-bit
  `int`) and EPERM everything else. amd64/arm64 have no multiplexed
  `socketcall`, so socket creation has no unfiltered second entry point.
  TSYNC binds every runtime thread and `no_new_privs` precedes the
  filter; both persist across the stage-2 `execve` into the target
  (`stage2.go`), which is the restrict-then-exec trick done correctly.
- **cgroup membership.** Descendants inherit the per-exec cgroup, making
  `pids.max` fork-bomb-proof; the pre-Enter fork race is acknowledged and
  the broker learns from `enforcement` whether cgroups applied
  (`run.go:203`).
- **Total decoders.** No `panic`/`let assert` on the decode paths;
  malformed msgpack, invalid utf-8, ext/float32/`0xc1`, non-finite
  float64, and trailing bytes are all `CorruptionReport`s
  (`msgpack.gleam`). Aside from the unbounded *depth* of #3, I found no
  input that crashes rather than returns an error.

---

## Untestable in this container

The kernel enforcement layers are not exercisable here (the dev container
lacks bwrap, and offers no Landlock, no delegated cgroup v2, per
`spec-gaps` WP-H #7). The following were reviewed **statically only** and
not verified against a live kernel:

- bwrap namespace/mount construction and mask ordering (`bwrap.go`).
- Landlock ruleset application and BestEffort ABI downgrade (`llock.go`).
- seccomp installation against a real kernel (`seccompf.Install`) — the
  cBPF *program* shape was reviewed; live syscall denial was not run.
- cgroup v2 delegation, `pids.events` accounting (`cgroup.go`).
- PID-namespace + `--die-with-parent` reaping of `setsid` escapees under
  bwrap (the mechanism that makes the degraded-mode orphan gap in #6
  bwrap-mode-safe).
- BEAM behavior under the #3 deep-nesting input (OOM vs `max_heap_size`
  kill) was reasoned about, not measured.

The self-test (`internal/selftest`) is the intended live witness for the
bwrap/Landlock/seccomp/cgroup layers and should be run on a target-tier
kernel; this review does not substitute for it.
