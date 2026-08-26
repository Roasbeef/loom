# sandbox (Go)

## Purpose

`loom-exec`, Loom's kernel-enforcement helper: the Go binary the broker
spawns to run untrusted commands inside a real jail. It speaks the frozen
effect-plane framing protocol on stdio, builds the jail from a strict
`SandboxPolicyV1` decode, and reports honestly what the running kernel
actually enforced. WP-H, Linux phase 1 — and Linux is the only jail that
exists: macOS Seatbelt (phase 2) and the Windows sandbox (phase 3) are
specified and unbuilt, and this binary refuses to serve on either rather
than run with nothing enforcing the policy. One of the tree's two Go
modules, alongside `tui`.

## Key Types

- `cmd/loom-exec` — the binary's three roles, selected by the first
  argument: no argument is **server mode** (read the base policy from fd 3,
  then frames on stdio); `--exec` is **stage 2** (read the policy from
  fd 3, apply Landlock/seccomp/rlimits to self, report on fd 4, execve the
  target); `--self-test` runs the regression probes against the live
  kernel. `--probe-socket` and `--probe-setsid` are the internal
  network-off and session-escape witnesses. `internal/selftest` also
  carries `loom_hostile.erl`, the hostile-satellite tabletop's adversary,
  which the self-test compiles with `erlc` and loads into a jailed node.
  Server mode also takes `--allow-unenforced` (the explicit opt-out of the
  unsupported-platform refusal) and `--cgroup-base DIR` (the delegated
  cgroup v2 base, which `LOOM_CGROUP_BASE` also supplies); an unknown
  server flag is a usage error, never a shrug, because a misspelled
  `--cgroup-base` would silently drop the ceilings it was meant to grant.
- `internal/policy.Policy` — `SandboxPolicyV1` decoded strictly and
  totally.
- `internal/framing` — the helper side of the wire: `u32_be length ++
  msgpack(map)`, keys `v`, `id`, `kind`, `body`.
- `internal/server` — the frame loop: frames in on stdin, frames out on
  stdout, one execution at a time.
- `internal/jail.{Request, Features, Report, StreamLimiter}` — one
  execution's description, what the kernel actually offers, the
  enforcement summary stage 2 sends back on fd 4, and the per-stream
  output cap.
- `internal/jail.PlatformSupport` (`Platform`, `PlatformFor`, `Refusal`) —
  not a probe of the kernel but a fact about the *build*: whether Loom has
  a jail for the OS it was compiled for. `PlatformFor` is pure and takes
  the OS as an argument, which is the only way the macOS and Windows
  answers can be tested at all.
- `internal/cgroup.{Detect, DetectBase, BaseEnvVar}` — the memory and pid
  ceilings. `DetectBase` takes the base as an argument: a delegated,
  process-empty cgroup v2 directory from the operator, or "" to fall back
  to the helper's own cgroup (which works only in the true root cgroup).
  It verifies the base is empty, distributes `memory` and `pids` to its
  children, and reports a reason naming the delegation when it cannot.
- `internal/jail.{CgroupSkip, CgroupSkipPrefix}` — the enforcement entry
  emitted when a policy asked for a ceiling and no cgroup held it.
- `internal/llock`, `internal/seccompf`, `internal/cgroup` — the three
  in-process restriction layers. `seccompf` and `jail`'s `no_new_privs`
  are split by build tag (`*_linux.go` / `*_other.go`) so the module
  compiles and vets for `GOOS=darwin`; the non-Linux halves are stubs that
  report the layer unavailable and never pretend to install one.
- `internal/selftest` — the probes and the ENFORCED/SKIPPED report.

## Relationships

- **Depends on**: the Go standard library plus the msgpack and syscall
  support its own `go.mod` pins. It depends on no Loom package — the
  protocol is the entire coupling.
- **Depended on by**: `broker` at runtime (`broker/exec` spawns and
  supervises it), and `conformance`'s jailed e2e through the broker.
- **Counterpart**: `packages/broker` (`broker/framing`, `broker/policy`)
  speaks the other end. Both are pinned against the golden frames under
  `protocol/msgpack-fixtures/`.

## Traffic

- **Wire (stdio)** — the same frozen kinds the broker sends and receives:
  `hello`, `exec_start`, `exec_stdin`, `exec_out`, `exec_exit`,
  `cap_call`, `cap_result`, `cancel`, `heartbeat`, `error`.
- **fd 3** — the base `SandboxPolicyV1`, required at spawn in both server
  mode and stage 2. The broker delivers it as a mode-0600 file opened by a
  shell wrapper, because Erlang ports cannot map arbitrary descriptors.
- **fd 4** — stage 2's enforcement `Report` back to the supervising
  helper, sent just before execve: `Applied` entries are terse layer tags
  (`landlock:abi=5`, `seccomp-net`, `rlimit-cpu`), `Skipped` entries carry
  reasons.
- **Environment** — `LOOM_CGROUP_BASE` names the delegated cgroup v2 base
  when the operator supplies one that way; `--cgroup-base` overrides it.
  Erlang ports cannot set a child's environment, so the broker uses the
  argument (`broker/exec.SpawnConfig.helper_args`) and a systemd unit uses
  the variable.
- **Process signals** — cancel is SIGTERM to the *payload*, SIGKILL to the
  pgroup after `KillGrace` (2 s), matching the broker's own patience
  window exactly. The two rungs address different sets on purpose; see
  "The TERM rung is addressed to the payload" below and `jail/cancel.go`.
- **Commits / registers / actors**: none. The helper is stateless between
  executions and persists nothing.

## Invariants

- **Policy decoding is strict, total, and fail-closed.** An unknown
  version, a missing field, an unknown field, or a wrong type is an error —
  never a guess, never a partial value, never a panic. The jail is only as
  good as the reading of the bytes that describe it.
- **Malformed frames close the channel; unknown kinds do not.** A
  malformed frame is an error result per §3.3 invariant 6; a well-formed
  frame with an unrecognized kind gets an in-band `error` reply and the
  channel survives (forward compatibility).
- **bwrap owns all namespace and mount work.** The Go runtime is
  multithreaded from the first instruction, and unshare/fork namespace
  assembly in a multithreaded process is the runc `nsexec.c` tar pit. The
  helper only composes an argv — pure data, golden-tested — then stacks
  in-process restrictions on itself before exec. If bwrap is missing we run
  degraded and say so; we never build namespaces ourselves.
- **Restrict-then-exec is sound because the restrictions persist.**
  Landlock domains and seccomp filters both survive execve and stack (a
  child can only tighten), and seccomp installs with
  `SECCOMP_FILTER_FLAG_TSYNC` so it binds every thread of the Go runtime,
  not just the calling one. Installation requires `no_new_privs`, which
  also stops the filter being used to confuse a setuid binary.
- **Network-off is enforced at socket creation.** seccomp cannot
  dereference the sockaddr passed to `connect(2)`, but it can read the
  integer domain argument of `socket(2)`/`socketpair(2)`. A process that
  can never obtain an AF_INET/AF_INET6/AF_PACKET socket has nothing to
  connect, bind, or sendto with — and the helper constructs the child's fd
  table and environment, so no network fd can be smuggled in. AF_UNIX stays
  usable and is confined by the filesystem layers; bwrap's network unshare
  is the independent second layer.
- **Landlock has no deny rules.** A protected path *inside* a writable root
  cannot be carved out at that layer; masking it is bwrap's job (tmpfs or
  ro-bind shadowing). Without bwrap the carve-out is unenforceable —
  reported in the enforcement summary, never hidden.
- **cgroups, not rlimits, for memory and pids.** `RLIMIT_AS` is
  per-process and trivially escaped by forking; `RLIMIT_NPROC` is per-user
  (useless when the jail shares a uid, ignored for root). The construction
  half is pure — policy in, `{path, contents}` pairs out — so the exact
  writes are unit-tested even where no v2 delegation exists.
- **The cgroup base is configuration, and its absence is reported, not
  swallowed.** cgroup v2 forbids a cgroup from having both member
  processes and controllers enabled for its children, so the helper's own
  cgroup — which always contains the helper — can only serve as a base in
  the true root cgroup. That is a fact about that choice of base, not
  about cgroup v2: any delegated, process-empty cgroup distributes
  controllers to its children, which is what `Delegate=yes` (and
  `DelegateSubgroup=` on systemd v254+) produces. The operator names one
  in `LOOM_CGROUP_BASE` or `--cgroup-base`; `Detect` verifies it and
  enables `memory` and `pids` in its `cgroup.subtree_control`. When there
  is no usable base **and the policy asked for `mem_bytes` or `pids`**,
  the per-exec `enforcement` list carries `skip:cgroup-v2: …`, which fails
  a `FullEnforcement` demand. Emitting nothing — which is what the helper
  used to do — let a policy that demanded both ceilings pass strict
  enforcement with neither in place, on every host that could not
  delegate. A policy that asked for no such ceiling gets no such skip.
- **The environment is constructed, never inherited.** A name absent from
  `env_allow` is dropped even when the broker sent it, so the policy alone
  is enough to audit what a jail could see. Output is sorted for
  determinism.
- **`output_bytes` is per stream, and truncation does not stop reading.**
  After the cap the helper keeps draining and discards; stopping would
  wedge the child on a full pipe, turning an output limit into an
  accidental deadlock. The cap is crossed exactly once per stream.
- **One execution at a time per helper**; a second `exec_start` gets a
  `busy` error. Concurrency lives in the broker's pool, which keeps "the
  pgroup" in the cancel contract unambiguous.
- **The TERM rung is addressed to the payload; only the KILL rung takes
  the pgroup.** Under bwrap the helper's direct child is a *supervisor*
  which is also the group leader, with a second bwrap as the PID
  namespace's init below it and the payload below that. The supervisor is
  spawned `--die-with-parent`, so TERMing the group kills the supervisor,
  whose death SIGKILLs the namespace init and every process in the
  namespace with it. Measured: a payload with `trap "" TERM` and a
  30-second loop died in 813 µs, by SIGKILL, having never been asked to
  stop — `TERM → grace → KILL` was in practice just `KILL`. So the TERM
  rung skips the supervisor and any nested namespace init (`jail.TermTargets`,
  selected from `/proc` by pgid and `NSpid`), and falls back to the whole
  group when it cannot read the table, because a TERM silently not sent is
  worse than one sent too widely. KILL still goes to the group, and
  cleanup keeps its unconditional group-wide sweep, so "no orphaned jails"
  is unchanged. Sparing the namespace init is belt to the kernel's braces:
  a signal from an ancestor namespace reaches an init only if it installed
  a handler (`pid_namespaces(7)`), verified here — TERM to the init alone
  left both it and the payload running.
- **A jailed exec reports `signal: 0` even when the payload was
  signalled.** The helper waits on its direct child, which under bwrap is
  the supervisor; the supervisor outlives the payload and relays a
  signalled payload by *exiting* 128+signal rather than dying of it.
  `code` is 143 for a TERM-killed payload jailed or unjailed; `signal` is
  15 only unjailed. Callers must read `code`, never `signal`, for "how did
  the payload end".
- **Every mask must follow every bind.** bwrap applies mount operations in
  argv order, so `--proc /proc` and `--dev /dev` go *after* the readable
  and writable binds, not with the `--ro-bind / /` base view. A policy
  naming `/` as a readable root is ordinary — it is what a jailed build
  asking for the toolchain sends — and it emits a later `--ro-bind / /`
  that puts the host's procfs and device tree back on top of the masks.
  That cost two things at once: a confinement gap (82 host pids and the
  host's `/proc/1/cmdline` readable from inside a jail reporting itself
  fully enforced, with `/proc/self` resolving to the host pid), and a hang
  — bwrap binds `MS_NODEV` unless asked for `--dev-bind`, so the
  re-exposed `/dev` is a view in which no node can be opened, and the BEAM
  `gleam build` spawns retries `openat("/dev/null", O_WRONLY)` against
  EACCES forever. `TestBwrapArgsNoBindFollowsTheVirtualMounts` pins the
  general rule; `TestFreshProcAndDevSurviveAReadableRootOfSlash` pins the
  behaviour in a real jail.
- **The helper speaks first.** The spec does not say who does; the helper
  sends its hello so the broker learns features before committing work, and
  requires the broker's hello before any other frame.
- **Degraded means degraded, out loud.** When bwrap, Landlock, or cgroups
  are unavailable the helper enforces what it can and reports the truth in
  `hello.features` and per-exec `enforcement`/`degraded`. The self-test
  applies the same rule: a probe whose layer the environment cannot provide
  prints SKIPPED with a reason and never fakes a pass; a probe whose layer
  *is* available must enforce or the run exits nonzero. A green self-test
  in a neutered container cannot be mistaken for a verified sandbox.
- **A probe that can only fail must prove it can also succeed.** Three
  denials in a row look identical to a module that never loaded, a node
  that never booted, and a path that never existed — so the hostile-`.beam`
  probe never reports containment on silence. The adversary announces that
  it loaded and that it finished, it performs two effects the policy
  *allows* (reading a bound-in file, writing inside the writable root) and
  reports them, and the probe runs the identical module unjailed first: if
  the escape does not succeed there, the probe skips rather than claiming a
  jail held something the host never permitted anyway. The other end of
  that pair lives in the tree too, as a test that runs the same adversary,
  the same argv and the same jail with those three mechanisms *granted*
  instead of withheld, and insists it reaches all three.
- **What the hostile-`.beam` probe claims is narrower than "reaches
  nothing".** The base view is `--ro-bind / /` and Landlock grants
  `RODirs("/")`, so an unprotected host path is *readable* from inside the
  jail; `readable_roots` does not narrow reads, only `protected` removes
  them. The observed claim is that an unvetted `.beam` cannot write outside
  the writable roots (`erofs`), cannot see a protected path (`enoent`), and
  cannot reach the network (`eperm`, from the seccomp filter, behind an
  empty network namespace). Closing the gap between those two sentences is
  `protocol-change/004-sandbox-policy-explicit-mounts.md`, not this probe.
- **A probe's own scratch directory must live outside the scratch mount.**
  A `tmpfs` scratch policy mounts a fresh tmpfs over `jail.ScratchMount`
  (`/tmp`) *after* the writable binds, so a writable root underneath it is
  shadowed and every write to it fails. `os.MkdirTemp("")` lands exactly
  there on a host with no `TMPDIR`, which is most CI runners, and so does
  a helper binary built by `internal/testbin` — with the result that the
  probes report a broken jail and the jailed Go tests fail for a reason
  that has nothing to do with confinement. Both now build outside it. The
  confinement itself is fail-closed either way (the root becomes
  unwritable, never wider), which is why this went unseen on every host
  without bubblewrap installed.
- **A missing platform is not a missing kernel feature, and is never
  reported as one.** Everything else here probes the running kernel and
  calls a gap environmental. A build with no jail for its OS has a gap in
  *Loom*, so it takes a different path everywhere: `hello.features` gains
  `platform-unsupported` and `Degraded()` is true; every per-exec
  `enforcement` list leads with `skip:jail: …` naming what was not applied;
  `--self-test` prints `RESULT: UNSUPPORTED PLATFORM` and exits nonzero
  rather than repeating "skips are environmental, not passes"; and server
  mode refuses to start without `--allow-unenforced`, because a BestEffort
  caller would otherwise run model-influenced code with `network: off` in
  the policy and nothing enforcing it. **None of the non-Linux path has
  ever executed.** Its acceptance is `make selftest` on a real macOS host;
  the unit tests only pin the wording and the branching.

## Deep Docs

- [docs/architecture/effects.md](../../docs/architecture/effects.md) —
  the threat model and Rule Zero, the jail, enforced versus reported.
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From WP-H (`sandbox`)":
  policy source, `exec_start.limits`, output caps, hello ordering,
  one-exec-at-a-time, network filtering, degraded mode, unknown input.
- [packages/broker/CLAUDE.md](../broker/CLAUDE.md) — the other end of the
  wire.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
  `make selftest` probes the current kernel; `make e2e` runs the jailed
  acceptance against a freshly built helper.
