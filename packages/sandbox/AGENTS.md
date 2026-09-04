# sandbox (Go)

## Purpose

`loom-exec`, Loom's kernel-enforcement helper: the Go binary the broker
spawns to run untrusted commands inside a real jail. It speaks the frozen
effect-plane framing protocol on stdio, builds the jail from a strict
`SandboxPolicyV1` decode, and reports honestly what the running kernel
actually enforced. WP-H's Linux phase 1 and macOS phase 2 are implemented;
the Windows phase 3 sandbox remains unbuilt and the binary refuses to serve
there rather than run with nothing enforcing the policy. This is the tree's
only Go module.

## Key Types

- `cmd/loom-exec` — the binary's three roles, selected by the first
  argument: no argument is **server mode** (read the base policy from fd 3,
  then frames on stdio); `--exec` is **stage 2** (read the policy from
  fd 3, apply the platform's in-process restrictions and rlimits, report on
  fd 4, execve the target); `--self-test` runs the regression probes against
  the live kernel. `--probe-socket`, `--probe-setsid`, and `--probe-fork`
  are the internal network, session-escape, and process-limit witnesses.
  `internal/selftest` also
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
- `internal/jail.{MountPlan, MountOp, MountClass}` — the mount precedence
  model. `MountPlan` turns a policy into the ordered operations
  `BwrapArgs` renders; `MountClass` says whether an op widens the jail's
  view or subtracts from it, and settles which of two ops naming the same
  path takes it. Pure, and the thing to read before changing any mount
  behaviour. `PathKind` and `MaskSource` are its protected-path half.
- `internal/jail.PlatformSupport` (`Platform`, `PlatformFor`, `Refusal`) —
  not a probe of the kernel but a fact about the *build*: whether Loom has
  a jail for the OS it was compiled for. `PlatformFor` is pure and takes
  the OS as an argument, which is the only way the macOS and Windows
  answers can be tested at all.
- `internal/cgroup.{Detect, DetectBase, BaseEnvVar}` — the memory and pid
  ceilings. `DetectBase` takes the base as an argument: a delegated,
  process-empty cgroup v2 directory from the operator, or "" to fall back
  to the helper's own cgroup (which works only in the true root cgroup).
  It asks the kernel by `statfs(2)` whether the base is on a cgroup v2
  filesystem, verifies the controllers are delegated and the base is
  empty, checks that a process could actually be migrated into a child,
  and reports a reason naming the delegation when it cannot. It does not
  write: distributing `memory` and `pids` to the base's children is
  `Setup`'s job, because detection answers a question and must not
  reconfigure the operator's tree to do so.
- `internal/jail.{CgroupSkip, CgroupSkipPrefix, CgroupCeilings}` — the
  enforcement entry emitted when a policy asked for a ceiling and no
  cgroup held it. `CgroupCeilings` names *which* of `memory.max` and
  `pids.max` were asked for, so the skip cannot report a ceiling the
  policy never wanted.
- `internal/jail.{MountReport, AuditMounts, MountSkipPrefix}` — the mount
  layer's contribution to the enforcement report. `AuditMounts` replays a
  `MountPlan` and counts the policy's own paths whose *effective* view is
  the one asked for; see "The mount layer says what it achieved" below.
- `internal/jail.UnmountableProtected` — the pre-dispatch half of #60: it
  replays a `MountPlan` the same way `AuditMounts` does and names every
  `PathMissing` protected path whose parent the plan leaves read-only, so
  `run.go` can refuse before bwrap ever runs instead of a bare `code=1`.
- `internal/jail.{SeatbeltPlan, SeatbeltPlanFor}`: the Darwin backend's
  deny-default profile, path definitions, audit digest, and enforcement
  tags. Model-influenced paths travel through `sandbox-exec -D`, never as
  interpolated SBPL. Broad grants precede the protected logical/resolved
  path denies, and the denies are the final rules in the profile. Two
  roots the policy never names are granted on every plan: the user's
  darwin temp and cache directories (`confstr(3)`, in
  `seatbelt_userdirs_darwin.go`, via `/usr/bin/getconf` rather than cgo so
  `CGO_ENABLED=0` still builds), because Apple's `git`/`make`/`clang`
  shims write `xcrun`'s cache and clang's module cache there whatever
  `TMPDIR` says — and the private per-execution scratch is made under
  `/private/tmp`, not the helper's `TMPDIR`, precisely so that grant does
  not make one execution's scratch writable by another.
- `internal/jail.{Stage2Skip, Stage2SkipPrefix, BwrapUnwitnessedSkip}` —
  the entries for a stage 2 that never reported on fd 4, and for the
  bwrap layer that consequently has no witness.
- `internal/jail.{ProcEntry, TermTargets}` — who the TERM rung is
  addressed to, selected by descent from the supervisor rather than by
  process group. `ProcEntry` is `{Pid, Ppid}`: the parent link is the
  one relation a payload cannot rearrange.
- `internal/jail.processTracker`: Darwin's lifecycle backstop. It records
  descendants it observes with their process birth time and rechecks that
  identity immediately before signaling. This narrows PID reuse but cannot
  make the check and `kill(2)` atomic. It complements rather than replaces
  process-group signals for children that call `setsid(2)`. macOS has no PID
  namespace, subreaper, or stable process handle, so a rapid daemonizing
  double-fork can be reparented between samples. Every Darwin execution reports
  `skip:darwin-process-lifecycle`; Seatbelt confinement remains inherited, but
  `FullEnforcement` does not pretend sampled cleanup is a kernel guarantee.
- `internal/llock`, `internal/seccompf`, `internal/cgroup` — the three
  in-process restriction layers. `seccompf` and `jail`'s `no_new_privs`
  are split by build tag (`*_linux.go` / `*_other.go`) so the module
  compiles and vets for `GOOS=darwin`; Darwin uses Seatbelt for filesystem
  and network confinement rather than either Linux-only layer.
  `internal/jail/stage2.go`'s `landlockView` is the one function that
  turns a decoded policy into `llock.PolicyView`, and is where the
  layering contract below is actually decided rather than just stated.
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
  (`landlock:abi=5`, `seccomp-net`, `seatbelt-net`, `rlimit-cpu`), `Skipped`
  entries carry reasons. It is also the helper's **witness that the outer
  platform jail reached stage 2**: bwrap/mount and Seatbelt profile claims
  are published only when this report arrives, and its absence is a `skip:`,
  never silence.
- **Environment** — `LOOM_CGROUP_BASE` names the delegated cgroup v2 base
  when the operator supplies one that way; `--cgroup-base` overrides it.
  Erlang ports cannot set a child's environment, so the broker uses the
  argument (`broker/exec.SpawnConfig.helper_args`) and a systemd unit uses
  the variable.
- **Process signals** — cancel is SIGTERM to the *payload and its
  descendants*, SIGKILL to the pgroup after `KillGrace` (2 s), matching
  the broker's own patience window exactly. The two rungs address
  different sets on purpose; see "The TERM rung is addressed to the
  payload" below and `jail/cancel.go`.
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
- **Landlock has no deny rules, and the layering contract is: strictly
  weaker than the mounts, never independent of them.** Landlock's grants
  union — RWDirs, RWFiles, and RODirs only ever add access, and nothing
  in the API can subtract from a region another rule already opened — so
  a reader must not assume Landlock is a second, independent enforcement
  point that would still hold if the mount plan were wrong. It is not: a
  protected path *inside* a writable root cannot be carved out at the
  Landlock layer, masking it is bwrap's job alone (tmpfs or ro-bind
  shadowing), and without bwrap the carve-out is unenforceable —
  reported in the enforcement summary, never hidden. The one place
  Landlock *is* load-bearing on its own is degraded mode (no bwrap at
  all), where it is briefly promoted to the only filesystem confinement
  there is, and even then it can only restrict what the mount layer
  would also have restricted, never narrow what a mount would have left
  open. Concretely: `internal/llock.Rules` grants the same three policy
  regions bwrap's own grant phase would bind — the readable roots, the
  writable roots, and (for a host-path scratch only) the scratch — plus
  the unconditional root-read every jail needs to exec anything. Its one
  non-policy exception is an exact-file RWFiles grant for `/dev/null`, so
  programs retain a null sink without widening the containing `/dev`
  directory or granting device ioctls. It never sees `protected` at all;
  that list is bwrap's alone.
  `internal/jail/stage2.go`'s `landlockView` is where the policy becomes
  that grant set, and it deliberately omits a tmpfs scratch (issue #59):
  stage 2 has no unforgeable evidence that bwrap replaced `/tmp`, while
  without bwrap there is no tmpfs to grant write on at all. Omitting the
  grant keeps degraded execution from silently substituting real host
  `/tmp`; callers that need temporary writes under Landlock place TMPDIR
  inside a writable root. `scratch: "/"` is refused even earlier,
  in `broker/policy.gleam`'s `validate` (`ScratchIsRoot`): a host-path
  scratch of the literal root would otherwise reach `internal/llock` as
  `RWDirs("/")`, and because grants union there is no way for any later
  rule — including every protected-path mask, which Landlock cannot
  express in the first place — to narrow it back down. Refusing it at
  the policy boundary, before the policy ever reaches this package,
  keeps `internal/jail/mounts.go`'s own rule intact: the mount layer
  binds exactly what the policy says and narrows nothing on its own
  initiative (4b4983d).
- **Linux uses cgroups, not rlimits, for memory and pids.** `RLIMIT_AS` is
  per-process and trivially escaped by forking; `RLIMIT_NPROC` is per-user
  (useless when the jail shares a uid, ignored for root). The construction
  half is pure — policy in, `{path, contents}` pairs out — so the exact
  writes are unit-tested even where no v2 delegation exists.
- **Darwin reports the weaker rlimit truth.** The platform exposes no
  per-execution cgroup equivalent. A requested finite `RLIMIT_AS` is attempted
  and currently returns `EINVAL`, so `mem_bytes` produces an explicit
  `skip:rlimit-address-space` rather than aborting the otherwise confined run
  or claiming a limit. `RLIMIT_NPROC` is per-user: it is installed only when
  the account's current process count leaves a 16-process reserve below the
  requested ceiling. When it does not, the run reports
  `skip:rlimit-processes`; this avoids turning ordinary child spawns into
  immediate `EAGAIN`. The sample and `setrlimit` cannot be atomic with
  unrelated same-user forks, so the reserve narrows rather than eliminates
  that race. Either skip fails `FullEnforcement`, while `BestEffort` retains
  filesystem and network confinement and exposes the missing ceiling to its
  caller.
- **The cgroup base is configuration, and its absence is reported, not
  swallowed.** cgroup v2 forbids a cgroup from having both member
  processes and controllers enabled for its children, so the helper's own
  cgroup — which always contains the helper — can only serve as a base in
  the true root cgroup. That is a fact about that choice of base, not
  about cgroup v2: any delegated, process-empty cgroup distributes
  controllers to its children, which is what `Delegate=yes` (and
  `DelegateSubgroup=` on systemd v254+) produces. The operator names one
  in `LOOM_CGROUP_BASE` or `--cgroup-base`. When there
  is no usable base **and the policy asked for `mem_bytes` or `pids`**,
  the per-exec `enforcement` list carries `skip:cgroup-v2: …`, naming
  which of `memory.max` and `pids.max` was actually dropped, which fails
  a `FullEnforcement` demand. Emitting nothing — which is what the helper
  used to do — let a policy that demanded both ceilings pass strict
  enforcement with neither in place, on every host that could not
  delegate. A policy that asked for no such ceiling gets no such skip.
- **Only `statfs(2)` can tell a directory from a cgroup, so it is asked
  first.** Reading `cgroup.controllers`, reading `cgroup.procs`, writing
  `cgroup.subtree_control` and creating a child directory are all things
  an ordinary directory does perfectly well. With nothing asking the
  kernel, three text files under a typo'd `--cgroup-base` became a
  "cgroup v2 base": `memory.max` and `pids.max` were written as ordinary
  files, `Enter` wrote a pid into one and returned nil, a 32-way fork
  burst under `pids: 8` ran to completion, and the frame reported
  `cgroup-v2` **applied** (#52). `DetectBase` now checks
  `CGROUP2_SUPER_MAGIC` before anything else, in a `_linux.go`/`_other.go`
  pair so the module still vets for darwin. The interface-file reasoning
  stays unit-testable against a directory shaped like a base, because
  `usable` is reachable from a test while `DetectBase` is what production
  calls.
- **Detection is a question; it does not reconfigure the operator's
  tree.** Enabling `+memory +pids` in the base's `cgroup.subtree_control`
  is a write into the operator's cgroups that a probe reading as
  read-only has no business making, and it was never reverted. It moved
  to `Setup`, which runs after the base is validated and an execution
  actually needs a child; a failure there is an ordinary
  `skip:cgroup-v2:`. `DetectBase` also refuses a base the helper lives
  *outside* of, since cgroup v2's delegation containment rule needs write
  access to the `cgroup.procs` of the common ancestor to migrate a
  process in — advertising `cgroup-v2` in the hello frame for a base no
  process could ever enter was the other half of #52. `Cleanup` rmdirs
  child cgroups depth-first before the directory itself: a cgroup's
  interface files are kernel-created and unremovable, so `RemoveAll` is
  wrong and a bare `Remove` leaves an `exec-N-PID/` behind.
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
  rung skips the scaffolding, KILL still goes to the group, and cleanup
  keeps its unconditional group-wide sweep, so "no orphaned jails" is
  unchanged.
- **The payload is found by descent, and both exclusions are
  structural.** `jail.TermTargets` walks parent links from the supervisor
  and takes everything at depth two or more: depth 0 is the supervisor,
  depth 1 is bwrap's namespace init, and the rest is the payload and what
  it spawned. It used to scan the supervisor's *process group* and spare
  anything whose innermost `/proc/<pid>/status` `NSpid` was `1`. Both
  were evadable with one unprivileged syscall (#53): `setsid(2)` took the
  payload out of the group, the selection came back empty, and the caller
  fell back to signalling the group — the collapse above, on a payload
  nothing had asked to stop; and `unshare -U -p -f` made a payload look
  like a namespace init, so it was skipped *by name*. Descent cannot be
  left, and under `--unshare-pid` the kernel reparents orphans onto the
  namespace's own init rather than host pid 1, so the walk enumerates the
  whole jail. The two spared processes are now known by construction —
  the pid the helper spawned, and that process's own children — so
  nothing a payload does to itself puts it in the exempt set. A selection
  that comes back empty still falls back to the whole group, because a
  TERM silently not sent is worse than one sent too widely.
- **TERM is complete under bwrap and best-effort without it, and the
  ladder's documentation says so.** The PID namespace is what makes the
  descendant walk exhaustive. In degraded mode there is no namespace, the
  group leader *is* the payload, and a payload that calls `setsid(2)`
  leaves the group with nothing to put it back. That is one more thing a
  missing bwrap costs; it is reported as degraded like the rest, and the
  KILL rung's group sweep is what still bounds it.
- **A cancelled run says it was cancelled, because nothing else can.**
  `Result.Cancelled` (and `exec_exit.cancelled`, protocol-change/006) is
  set from the ladder's own state machine, which keeps the fact after the
  process exits. The exit status cannot carry it in either direction: a
  cancelled run whose payload had backgrounded its work reported `code=0
  signal=0` — a clean success for a forcibly truncated execution, 3 runs
  out of 3 — and `sh -c 'exit 143'` reports the TERM-killed payload's
  `code=143` with no cancel involved at all. `TimedOut` separates an
  explicit cancel from the wall clock, which climbs the same ladder.
- **A jailed exec reports `signal: 0` even when the payload was
  signalled.** The helper waits on its direct child, which under bwrap is
  the supervisor; the supervisor outlives the payload and relays a
  signalled payload by *exiting* 128+signal rather than dying of it.
  `code` is 143 for a TERM-killed payload jailed or unjailed; `signal` is
  15 only unjailed. Callers must read `code`, never `signal`, for "how did
  the payload end" — and `cancelled`, never `code`, for "was it allowed
  to finish".
- **Mount precedence is decided, not inherited from argv order.** bwrap
  applies mount operations in argv order, so argv order *is* the
  precedence between overlapping mounts. `jail.BwrapArgs` therefore does
  not build that argv by concatenating the four policy path lists. It
  resolves the policy into an ordered plan of `jail.MountOp`s — a region,
  a `jail.MountClass` saying what the op does to it, and the argv
  fragment — and orders the plan by two rules:
  - **Grants first, masks last, and nothing after a mask.** A readable
    root, a writable root and the scratch area *widen*; `--proc`, `--dev`
    and the protected masks *subtract*. A grant after a mask undoes it
    and fails **open**; a mask after a grant only narrows. So masks are
    last unconditionally — including after the scratch mount, which is a
    grant and used to be emitted dead last (#51).
  - **Inside a phase, the most specific region wins.** Ops sort by path,
    which puts a parent before every descendant of it, so the nested op
    lands on top. A readable root inside a writable root comes out
    read-only; a writable root under the scratch mount survives it.
  Masks are deliberately exempt from the second rule against grants:
  `protected` is the policy's only subtractive verb, so no grant at any
  depth carves a hole in one. Where two entries name the *same* path the
  higher `MountClass` takes it and the loser is not emitted at all —
  writable beats readable, because `workspace_default` names the
  workspace in both lists and means writable; the scratch tmpfs beats a
  root at exactly `/tmp`, because dropping the scratch the policy asked
  for is the worse of the two, and the tmpfs is the narrower.
  `TestBwrapArgsNothingFollowsTheMasks` pins the first rule against the
  plan rather than against a verb spelling, which matters because two
  masks are spelled with bind verbs; the `TestJailed…` tests pin every
  case in a real jail.
- **What that ordering cost before it was written down.** #37: a policy
  naming `/` as a readable root — what a jailed build asking for the
  toolchain sends — emitted a `--ro-bind / /` after `--proc`/`--dev` and
  put the host's procfs and device tree back. A confinement gap (82 host
  pids and the host's `/proc/1/cmdline` readable from inside a jail
  reporting itself fully enforced, `/proc/self` resolving to the host
  pid) and a hang at once: bwrap binds `MS_NODEV` unless asked for
  `--dev-bind`, so the re-exposed `/dev` is a view in which no node can
  be opened, and the BEAM `gleam build` spawns retries
  `openat("/dev/null", O_WRONLY)` against EACCES forever. #51: the same
  argv, at the other end — the scratch mount was emitted after the
  masks, so `scratch: "/"` reproduced the whole of #37 with `--bind`
  rather than `--ro-bind` (writable), and a protected directory under a
  scratch path came back readable *and* writable, host file and all.
  `TestFreshProcAndDevSurviveAReadableRootOfSlash` and
  `TestJailedScratchOfRootDoesNotRestoreHostProcAndDev` pin the two ends
  in a real jail.
- **The scratch mount and the writable roots, stated once.** A `tmpfs`
  scratch mounts a fresh tmpfs at `jail.ScratchMount` (`/tmp`). It is a
  grant, so it sorts with the other grants: a writable root *underneath*
  it is emitted after it and survives (bwrap creates the mountpoint
  inside the fresh tmpfs and binds the host directory there), and a
  protected path underneath it is masked afterwards like any other. What
  does *not* survive is a path under `/tmp` that the policy never named
  — that is still replaced by empty scratch, which is why
  `codemode/launch` refuses a cap socket there up front. Before #41 was
  fixed the writable root did not survive either, and the write
  evaporated silently.
- **A protected path is masked once, at its resolved target.** Two
  bubblewrap facts, both measured, decide the shape of the mask loop. A
  protected path nested inside another protected path must not get a
  mask of its own: the ancestor's tmpfs is remounted read-only, so the
  descendant's mountpoint cannot be created and bwrap refuses to start —
  `protected: ["~/.ssh", "~/.ssh/id_rsa"]` killed every jail built from
  it. And a mask lands on whatever its destination *resolves* to, so
  `jail.PathKind` must describe the resolved target: a symlink to a
  directory classified `PathFile` emits a file mask against a directory
  and bwrap refuses; an absolute symlink is worse, since during setup its
  target resolves inside bwrap's pivot root where it does not exist and
  every mask form fails with ENOENT.
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
- **The mount layer says what it achieved, not that it ran.** `bwrap`
  meant "bubblewrap was on PATH and we spawned it"; it never meant "the
  policy's paths were narrowed as asked", which made every finding in the
  mount-precedence family invisible to a full-enforcement demand (#54).
  `jail.AuditMounts` replays the ordered `MountPlan` and emits
  `mounts:ro=N,rw=M,mask=K,scratch=…,plan=…`. The counts are of the
  policy's own paths whose **effective** view — after the whole ordered
  plan, taking the last operation that covers each path — is the one the
  policy asked for, which is why they catch what a count of requested
  operations cannot: that number is identical in a healthy plan and in
  one whose mask a later bind of an ancestor undoes. Such a path drops
  out of `mask=` and gets a `skip:mounts:` naming it and the operation
  that re-exposed it. The `plan=` digest is a diffing aid and a golden-test
  anchor, not a check: it detects *change*, and nobody holds the expected
  value. The audit proves the plan, not its execution — for that, see the
  witness rule below. Proving the resulting *view* would mean probing
  from inside stage 2, and `faccessat` is unreliable for uid 0, which is
  the common case inside a bwrap user namespace.
- **A layer that says nothing is not a layer that was applied.** The
  per-exec report used to be trusted for what it *omitted*: no `skip:`
  entry meant fully enforced. A stage 2 that died before writing fd 4
  produced `enforcement: ["bwrap"]` — no skip anywhere — and satisfied a
  `FullEnforcement` demand with the whole inner report missing (#54). So
  the helper now claims `bwrap` and the `mounts:` audit **only when stage
  2 reported**, that report being the one thing that could not have
  arrived unless bubblewrap built the namespace and exec'd into it; and a
  silent stage 2 emits `skip:stage2: …` and `skip:bwrap: …` instead of
  nothing. The broker's half is `exec.required_layers`, which derives the
  demanded set from the policy and refuses a report that never mentions
  one of them.
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
- **A protected path is masked at its inode, not at its name.** bwrap
  resolves a mount's destination inside the pivot root it is building,
  where a symlink's target does not exist yet, so masking the link's own
  name fails outright — measured: `Can't mount tmpfs on …/dot-ssh: No
  such file or directory`, exit 1, no jail at all, and for an *absolute*
  symlink every mask form fails. `run.go` therefore rewrites
  `Protected` through `filepath.EvalSymlinks` before building the plan,
  and `statKinds` uses `os.Stat` rather than `os.Lstat` so the inode type
  the mask form is chosen for is the target's. Masking the target covers
  both names, since the link still resolves into the mask from inside. A
  path that does not resolve keeps its own name: that is the
  `PathMissing` case, where masking the name is the whole point.
- **A policy bwrap cannot realise fails in Loom's words, not bwrap's**
  (issue #60). Three shapes made bubblewrap refuse to start with a bare
  `code=1` and its own chatter on stderr, indistinguishable from the
  payload's own command failing:
  - A nested protected path — already handled by 4b4983d's plan model
    (the redundant descendant is dropped before it ever gets a mask of
    its own; see the mount-precedence bullets above).
  - A `PathMissing` protected path whose parent the plan leaves
    read-only. bwrap needs write access to create the mount point for a
    path that does not exist yet, and refuses with `Can't mkdir parents
    for PATH: Read-only file system` when it does not have it. `~/.ssh`
    — a default protected path — hits this on any policy that does not
    also grant write under `$HOME`, which is the ordinary case, not an
    edge one. `internal/jail.UnmountableProtected` (mounts.go) replays
    the mount plan the same way `AuditMounts` does and flags exactly
    this shape; `run.go` calls it before building the argv at all and
    refuses with a message naming the path, so the caller gets a
    structured `error` frame instead of an opaque spawn failure.
  - A nonexistent readable root. Unlike the other three path lists,
    `readable_roots` names paths that may legitimately vary by host — an
    optional toolchain root, a platform-specific system directory — so
    it is bound with `--ro-bind-try` rather than refused up front,
    matching the `Optional`/`IgnoreIfMissing()` treatment
    `internal/llock.Rules` already gives the same list. The other three
    lists (`writable_roots`, `protected`, and a host-path `scratch`) do
    not tolerate absence the same way, and each has its own reason: see
    "which path lists tolerate a missing path" above `readableRootOp` in
    bwrap.go for the decision and the two lists (`writable_roots`, a
    host-path `scratch`) left as an open gap rather than fixed here.
- **That rigour applies to every probe, not one.** Two probes asserted
  only the *absence* of an effect — an untouched secret file, a prompt
  `Wait` — and nothing having run satisfies both. With a `bwrap` on PATH
  that is `#!/bin/sh\nexit 1`, eight probes said FAILED and those two said
  ENFORCED (#54), and `.github/scripts/enforcement_report.sh` reads
  exactly those per-probe verdicts. Both now carry a witness that the
  payload executed: `probeProtected` performs an effect the policy
  *allows* inside the same jail and requires its `ALLOWED-OK`, and
  `probeOrphanReap` requires the shell to print the orphan's own pid,
  which it can only do after forking it. `internal/selftest`'s own test
  puts that shim on `PATH` and fails if any probe reports ENFORCED.
- **The probe's name says what it checks.** `probeProtected` was
  "protected path write denied" and asserted only that a protected
  *file*'s bytes were unchanged. Since #55 resolved `protected` to mean
  the contents are gone from the jail's view whatever the inode type, it
  is "protected path masked from reads and writes" and asserts that
  neither a protected file's contents nor a protected directory's are
  reachable from inside — the resolution pinned by a test rather than by
  prose. Renaming a probe changes the probe set, which
  `.github/scripts/enforcement_report.sh` fails on by design, so the
  rename and the line in `.github/enforcement-expectations` move
  together.
- **What the hostile-`.beam` probe claims is narrower than "reaches
  nothing".** The base view is `--ro-bind / /` and Landlock grants
  `RODirs("/")`, so an unprotected host path is *readable* from inside the
  jail; `readable_roots` does not narrow reads, only `protected` removes
  them. The observed claim is that an unvetted `.beam` cannot write outside
  the writable roots (`erofs`), cannot see a protected path, and
  cannot reach the network (`eperm`, from the seccomp filter, behind an
  empty network namespace). Closing the gap between those two sentences is
  `protocol-change/004-sandbox-policy-explicit-mounts.md`, not this probe.
- **"Cannot see a protected path" means the contents, and it now holds
  for a file too.** A protected *directory* — and a path that does not
  exist yet, so a protected `~/.ssh` stays uncreatable — is shadowed by
  an empty tmpfs remounted read-only: the directory is there and it is
  empty, so its contents are `enoent`. A protected *file* used to be
  bind-mounted onto itself read-only, which left it fully **readable**;
  `protected: ["~/.aws/credentials"]`, the most obvious use of the
  feature, handed the credentials to the jailed process and only stopped
  it writing them back (#55). It is now shadowed by a read-only bind of
  `jail.MaskSource` (`/dev/null`) instead — tmpfs cannot mount over a
  non-directory, and bwrap binds `MS_NODEV`, so the masked path cannot
  be opened at all: EACCES on read and on write, not `enoent`. Were nodev
  ever absent the read would see an empty file and the write would go
  nowhere near the host, so the mask is safe either way. The design's
  `protected_paths` comment says "never writable"; the implementation is
  deliberately stronger than that, and uniformly so, because a read is
  what an adversary in the jail actually wants from a credential file.
- **A probe's own scratch directory must live outside the scratch mount.**
  `os.MkdirTemp("")` lands under `/tmp` on a host with no `TMPDIR`, which
  is most CI runners, and so does a helper binary built by
  `internal/testbin`. A probe whose fixtures the jail's own scratch
  covers reports a broken jail and the jailed Go tests fail for a reason
  that has nothing to do with confinement; both now build outside it.
  Since #41 an explicitly granted writable root under `/tmp` survives the
  scratch mount, so the sharpest version of this hazard is gone — but a
  probe directory that no policy entry names is still replaced by empty
  scratch, and a fixture outside `/tmp` is the version that does not
  depend on remembering which.
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
  the policy and nothing enforcing it. This is now the Windows/unknown-target
  path; Darwin instead runs its live Seatbelt suite and advertises `seatbelt`.

## Deep Docs

- [docs/adr/006-macos-seatbelt-boundary.md](../../docs/adr/006-macos-seatbelt-boundary.md):
  the Seatbelt boundary, Darwin's resource semantics, and the explicit
  descendant-lifecycle limit.
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
