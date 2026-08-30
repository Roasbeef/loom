# Design note: the microVM executor tier

Status: **note, not a work package.** Research only; nothing here is
built, and nothing here changes a frozen interface. It asks what it would
actually take to run Loom's executor pool inside a microVM (Firecracker,
libkrun) or an ephemeral container instead of — or alongside — the
bubblewrap process jail the tree ships, and it ends with four blocking
items and an order to do them in.

Every load-bearing claim below was checked against the tree at `290753e`
(2026-08-27). Where a claim about the design docs turned out to be true
only of half the system, the half it is false of is named rather than
smoothed over. The design's own words are the thing under test:

> **Hard tier**: the entire executor pool inside a microVM (Firecracker)
> or container for hosted/multi-tenant deployments — same policy
> language, different driver. (`docs/loom-design.md:232`)

and, three sections later, the conclusion of the two-channel doctrine:

> **Remote execution is a driver, not an architecture change.**
> (`docs/loom-design.md:282`)

The verdict, one paragraph: the *transport* claim is true, and better
supported by the tree than the design doc has any right to expect — the
coupling really is one framing protocol and one injected function. The
*policy language* claim is true of `SandboxPolicyV1` itself and false of
the thing that gives the policy teeth, which is the per-execution
enforcement report. That report's vocabulary is Linux-specific, lives on
the broker side rather than in the helper, and is checked by string
matching against a hardcoded list. A VM driver that reused it would be
claiming layers it does not have; a VM driver that did not would fail
every `FullEnforcement` demand in the tree. Between those two failures
sits most of the real work, and none of it is the hypervisor.

---

## 1. What genuinely is a driver swap

Four properties of the tree make the transport half of the claim hold,
and they are worth stating first because they are the reason this is
worth doing at all.

**The harness↔jail coupling is one wire format and nothing else.** The Go
module's own doc says it outright: it "depends on no Loom package — the
protocol is the entire coupling" (`packages/sandbox/CLAUDE.md`). That
protocol is the frozen Part 1.4 framing — `u32_be length ++
msgpack(map)`, keys `v`/`id`/`kind`/`body`, ten kinds — and the spec
already names remote pools among its intended carriers
(`docs/loom-implementation-spec.md:180`). Anything that speaks those
frames is a helper, whatever it is running on.

**The channel is already a seam with two implementations.**
`Transport` (`packages/broker/src/broker/exec.gleam:230`) has exactly two
variants: `PortTransport`, a real OS port onto a spawned helper, and
`ChannelTransport`, an in-process fake the tests drive the same actor
with. A vsock or virtio-serial transport is a third variant of a type
that already exists in order to have variants. Nothing above it — the
handshake, the frame loop, the deadline ladder, the settlement — knows
which one it has.

**The pool is where a VM lifecycle would live, and its callers do not
watch it.** `start_pool` (`packages/broker/src/broker/exec.gleam:1754`)
takes a `spawn` closure and hands helpers out through `checkout`
(`packages/broker/src/broker/exec.gleam:1533`) and `checkin`
(`packages/broker/src/broker/exec.gleam:1542`). "One microVM per helper"
and "a warm pool of snapshot-restored VMs" are both descriptions of what
that closure does. Its own doc comment already flags the place a warm
pool would change things. Spawning runs inside the pool actor, which
costs the pool's one run-time borrower nothing — the broker is serial,
so there is never a second checkout waiting behind a spawn — but it
costs the broker a helper handshake for every slot the pool has not
filled yet, so a session's first wide batch dispatches behind a short
series of spawns, and "pre-warming is the fix if that ever shows up in a
trace; it has not." A VM boot is exactly the slow spawn that sentence
was written for, and it arrives with the multiplier: a handshake of
milliseconds becomes one of hundreds, once per cold slot.

**Driver choice is a wiring decision, not a broker one.** Production
injects the pool into the broker as two closures — `checkout` at
`packages/client/src/client/serve.gleam:906`, `checkin` on the line below
— so a session could be wired to a VM-backed pool without the broker, the
tools, or the runtime being recompiled against a different type.

To which add the doctrine's own point, which is real: the effect sandwich
already assumes an effect is uncertain and possibly remote, so a VM that
fails to boot, or a partition mid-execution, is the existing recovery
path rather than a new failure class. `docs/loom-design.md:278` makes
that argument for remote pools and it transfers to VMs unchanged.

So the parts a reader expects to be hard — the plumbing, the concurrency,
the failure model — are the parts that genuinely are a driver swap.

---

## 2. What is not a driver swap

### 2.1 The enforcement vocabulary is Linux-specific, and lives on the broker side

This is the largest item, and the one that most directly threatens the
sandbox package's central promise: *degraded means degraded, out loud*.

**Status addendum, 2026-08-29.** The Seatbelt work implemented the driver-
selected matrix described below. `required_layers_for_features` now chooses
Linux or Darwin from the helper's hello features, and each backend names its
own mechanisms. The discussion remains as the argument that led there.

`required_layers` (`packages/broker/src/broker/exec.gleam:883`) derives
the layer tags an execution must be able to show as applied. Four are
unconditional — `["bwrap", "mounts", "landlock", "no-new-privs"]` — and
four more are conditional on what the policy asked for: `seccomp-net`
when the network is off or proxied, `cgroup-v2` under a memory or pid
ceiling, `rlimit-cpu` under a CPU ceiling, `rlimit-fsize` under a
file-size ceiling. `unapplied_layers`
(`packages/broker/src/broker/exec.gleam:936`) subtracts what the report
shows from what the policy demanded, splitting each report entry at its
first `:` or `=` through `layer_tag`
(`packages/broker/src/broker/exec.gleam:951`) so that `landlock:abi=5`
counts as the landlock layer and `mounts:ro=2,rw=1,…` as the mount layer.
`degraded_report` (`packages/broker/src/broker/exec.gleam:1039`) then
fails a `FullEnforcement` demand on any of three grounds: the helper's
degraded bool, any `skip:` entry, or any required layer simply absent
from the list.

Every one of those eight tags names a Linux kernel mechanism. The
function's own doc comment concedes the scope — "four tags are
unconditional on a Linux jail" — but the scoping lives in prose, not in a
type. The demanded set is a `List(String)` compared by string equality
against whatever the far end sent.

A microVM enforces the same policy by different means. There is no
`bwrap`, because there is no host mount namespace to construct a view in:
the guest's root filesystem *is* the view. There may well be no
`landlock` and no `seccomp-net`, because a guest with one virtual NIC and
no host paths does not need a syscall filter to be unable to reach the
network or the host's files. A VM driver therefore has two options today
and both are bad. It can emit the existing tags, in which case `bwrap`
means "a VM booted" and the report lies in the exact way #54 was filed
about — a layer that says nothing being trusted for what it omits. Or it
can emit honest tags of its own, in which case `unapplied_layers` reports
four missing required layers on every execution and `FullEnforcement`
refuses everything.

The fix is that the demanded set has to become a property of the driver
rather than a constant, or be negotiated at handshake. The helper already
sends a `hello` with a feature list the broker reads
(`handle_hello`, `packages/broker/src/broker/exec.gleam:1126`), and at the time
that list was consulted for exactly one thing: whether it contained
`"degraded"` (`degraded_features`,
`packages/broker/src/broker/exec.gleam:828`). Issue #64 already proposes
putting a protocol version in that frame and explicitly raises the
adjacent question — "what is versioned, the frame protocol as a whole, or
a feature set the client can negotiate against?" — while noting that
`hello` "already carries the enforcement features, so it is where a
caller learns what this helper can do." This note's answer to #64's
question is that a VM tier forces the second option: a driver announces
the layer vocabulary it can speak for, the broker's demand is expressed
against that vocabulary, and the ground-truth check stays exactly as
strict. Doing this without a VM tier is a refactor; doing it with one is
a prerequisite.

There is a companion trap. `host_platform_for`
(`packages/broker/src/broker/exec.gleam:1292`) answers `JailedHost` for
`"linux"` and `UnjailedHost` for everything else, mirroring the helper's
own `jail.PlatformFor` — which, as `packages/sandbox/CLAUDE.md` is
careful to say, is "not a probe of the kernel but a fact about the
*build*". A VM tier adds a third answer that is neither: whether *this
host* can run a VM is a genuine runtime probe (`/dev/kvm`, or its absence
in a container). Collapsing that into the existing two-valued type would
put a real capability question into a type designed to hold a build fact.

### 2.2 The filesystem tools bypass the sandbox entirely — and this is the fork in the road

`packages/tools/CLAUDE.md` states the invariant without hedging: "Path
discipline is the sole boundary for the filesystem tools. `fs_*` run in
the harness and never pass through the broker or the kernel jail."
`resolve_real` (`packages/tools/src/tools/fs.gleam:217`) walks the
candidate path and the workspace root component by component through
`read_link`, follows at most forty links, and requires the fully resolved
candidate to land under the fully resolved root. It is a careful boundary
and it holds against symlinks planted inside the workspace by a jailed
process — but it is a boundary drawn *in the harness*, over the harness's
own view of the filesystem.

That is coherent today for one reason: `bash` inside the jail and `fs_*`
inside the harness are looking at the same inodes. The jail's writable
roots are host bind mounts of the workspace, so a file written by a
jailed `bash` is the same file `fs_read` reads a moment later.

A microVM breaks that identity, and there are only two ways out.

**Share the workspace into the guest** — virtio-fs, or a 9p mount. The
filesystem stays one tree, `fs_*` keeps working unchanged, and hashline
keeps its meaning. But then the VM boundary is not a filesystem boundary:
the guest has a live, writable channel into the host's workspace, and a
guest escape through the shared-filesystem device is precisely the bug
class such devices have. Much of what the tier was bought for is spent on
the way in. It is still a real gain — the interface a virtio-fs device
exposes is far narrower than a kernel's whole syscall surface — but the
honest description is "a much narrower host interface", not "the guest
cannot reach the host filesystem".

**Copy or overlay the workspace into the guest.** Now the isolation is
real and `fs_*` and `bash` observe different trees. Every consequence of
that is unpleasant and at least one is a correctness failure rather than
an ergonomic one: hashline plans are digest-bound, and `apply` rejects
any content whose digest differs from the content the plan was computed
against (`packages/tools/CLAUDE.md`, "Hashline plans are digest-bound;
re-apply always rejects"). A `bash` step that writes a file in the guest
leaves the host copy at its old digest, so the next `fs_edit` against
that file rejects as stale — correctly, by its own contract, and
uselessly, because nothing the model can do reconciles the two trees.
Making this work means either a sync protocol with well-defined ordering
against every tool call, or moving `fs_*` inside the jail, which is a far
larger change to `tools` than anything else in this note (§7).

**There is no third way, and this note declines to invent one.**
Whichever is chosen is the decision the rest of the tier is shaped
around, and it should be made before any transport code is written. The
shared-workspace option is the one that makes the tier a drop-in and the
one that gives up the most; the copied-workspace option is the one that
delivers the isolation the threat model is asking for and costs a
redesign of the filesystem tool boundary.

### 2.3 Code mode's capability channel is AF_UNIX over host paths, and works incidentally

The satellite reaches the broker over an AF_UNIX socket at a host path,
and reads its private token from a second host path. `SandboxPolicyV1`
has no verb for either. `codemode/launch`'s module doc says so in as many
words: the frozen vocabulary has no "bind this path" verb, so the module
expresses both as `readable_roots` entries and *checks* that the composed
policy actually covers them.

What makes that sufficient is not the policy. It is the helper's base
view — bwrap ro-binds the entire host filesystem read-only, so every host
path is already visible inside the jail and a `readable_roots` entry adds
only a redundant explicit bind — plus three kernel facts the module doc
enumerates: `sb_permission` exempts sockets from `EROFS`, so `connect(2)`
succeeds on a socket inside a read-only mount; Landlock's filesystem
rights do not govern connecting to an existing socket; and the
network-off seccomp filter denies only non-`AF_UNIX` socket creation.
`docs/architecture/code-mode.md` adds that the first of those is reasoned
rather than observed, because the development container has no bubblewrap
and no run so far has actually connected through a `--ro-bind`.

Not one of those three facts survives into a VM, because the shared host
filesystem they all depend on is gone. The channel becomes vsock (or a
virtio-serial port), and the token has to arrive in band or through VM
configuration — kernel cmdline, a config block, a first frame — rather
than as a file the guest reads from a path the host also sees.

That is not, by itself, hard. What makes it a blocking item is that
nothing in the policy *records* the dependency, so nothing fails loudly
when it stops holding. `protocol-change/004` is exactly the vocabulary
that would state the requirement positively; its Problem section already
names this shape from the other direction, observing that tightening the
base view "would silently break code mode, because no policy value says
the socket and token have to be there." A VM driver is a much more abrupt
version of tightening the base view. **Land 004 first** is a real
recommendation and not a hedge: with an explicit `mounts` list a VM
driver has something concrete to translate — a socket the guest must
reach, a file it must read — and a driver that cannot satisfy a
`required: True` mount refuses the execution instead of producing a
satellite that never connects.

### 2.4 Policy paths are host-absolute, and the mount plan is audited by replay

`writable_roots`, `readable_roots`, `protected` and `scratch` are
absolute host paths, validated at compose time and resolved by the helper
into an ordered mount plan. A VM driver needs guest-path translation for
all four lists — and, much more importantly, an equivalent of the audit.

`jail.AuditMounts` replays the ordered `MountPlan` and emits
`mounts:ro=N,rw=M,mask=K,scratch=…,plan=…`, where the counts are of *the
policy's own paths whose effective view is the one the policy asked for*,
taking the last operation in the plan that covers each path.
`packages/sandbox/CLAUDE.md` explains why that is the only useful count: a
count of *requested* operations is identical in a healthy plan and in one
whose mask a later bind of an ancestor silently undoes.

The reason to insist on this for a new driver is that the repo has the
receipts. #37: a policy naming `/` as a readable root — which is what a
jailed build asking for the toolchain sends — emitted `--ro-bind / /`
*after* `--proc` and `--dev`, putting the host's procfs and device tree
back inside a jail that reported itself fully enforced; 82 host pids and
`/proc/1/cmdline` were readable from inside, `/proc/self` resolved to the
host pid, and the same argv hung the BEAM's `gleam build` spawns in a
retry loop on `openat("/dev/null", O_WRONLY)`. #51 is the same bug at the
other end of the argv: the scratch mount was emitted after the masks, so
`scratch: "/"` reproduced the whole of #37 with `--bind` instead of
`--ro-bind` — writable — and a protected directory under a scratch path
came back readable *and* writable, host file and all. Both were invisible
to a full-enforcement demand until #54 made the mount layer report what
it achieved rather than that it ran.

Every one of those is a *precedence* bug: the mount operations were all
present, and each was individually correct. A new filesystem driver —
overlay layers, virtio-fs mappings, a guest fstab, a snapshot's baked-in
view — has its own precedence rules and will have its own version of this
family. Shipping it with a mount list and no audit is shipping the
pre-#54 state of the world in a new codebase.

### 2.5 Cancellation gets simpler, but the contract does not move

Today's ladder is the most-derived piece of machinery in the helper. TERM
is addressed to the payload and its descendants, selected by descent from
the supervisor through `jail.TermTargets`, because the previous selection
scanned the supervisor's process group and one unprivileged `setsid(2)`
emptied it — after which the caller fell back to signalling the whole
group, and a measured payload with `trap "" TERM` died in 813 µs by
SIGKILL having never been asked to stop (#53). KILL goes to the pgroup
after a 2 s grace. And `exec_exit.cancelled` is set from the ladder's own
state machine rather than inferred from the exit status, because the
status cannot carry it in either direction: a cancelled run whose payload
had backgrounded its work reported `code=0 signal=0`, and
`sh -c 'exit 143'` reports 143 with no cancel involved at all
(`protocol-change/006-exec-exit-cancelled.md`).

In a VM most of this collapses into "destroy the VM", which is both
stronger and simpler — there is no descent to walk and no `setsid(2)` to
evade, because the unit of destruction contains everything. Two things
still have to be carried across rather than assumed. `cancelled` must
stay truthful, which means it is still set from the driver's own state
machine and never inferred from how the guest exited. And `abort` must
still leave nothing running, which for a VM means the janitor pattern
applies unchanged: `watch_cleanup`
(`packages/broker/src/broker/exec.gleam:1419`) spawns an unlinked process
that runs an idempotent cleanup when a pid dies, "including a brutal kill
that skips every in-actor path" — exactly the guarantee a VM handle
needs, since a leaked microVM is a leaked *machine*, not a leaked
process.

---

## 3. What the tier buys, ranked against the stated priorities

The repo's priorities are security and isolation, then correctness, then
robustness, then performance, then capability. Ranked that way, one
benefit is in a different category from the rest.

**1. It closes the one gap the threat model concedes.** Design §5.1 lists
kernel zero-days as a non-goal — "we reduce surface; VM-grade isolation
only in the microVM tier" (`docs/loom-design.md:221`) — and
`docs/architecture/effects.md:22` says the same thing from the other
side: "machine-grade isolation waits for the microVM tier." That is not
rhetorical. bwrap, Landlock, seccomp and cgroups all sit on one host
kernel, and a seccomp filter that denies socket creation still leaves
every syscall the payload *is* allowed to make as attack surface against
the kernel that the payload and the harness share. A microVM moves the
boundary to a hypervisor whose device model is small and whose
guest-visible interface is a handful of virtio queues. **This is the only
benefit on this list that changes the threat model rather than the
ergonomics**, and it is why the tier is worth its cost even though
everything below it could be bought more cheaply some other way.

**2. Degraded mode largely disappears.** Today's enforcement is
conditional on whatever host the operator happens to have. No bwrap and
the helper runs degraded and says so. No delegated, process-empty cgroup
v2 base, and a policy that asked for `mem_bytes` or `pids` gets
`skip:cgroup-v2:` and a failed `FullEnforcement` demand. On macOS or
Windows the helper refuses to serve at all without `--allow-unenforced`,
because `jail.PlatformFor` is a fact about the build and Loom has no jail
there. A VM brings its own kernel and its own userland, so those layers
become properties of the *image* — built once, tested once, identical on
every host that can run a VM at all. That is also the most plausible
route to the macOS story WP-H phase 2 still owes: a hardened tier on
macOS through a hypervisor is a smaller project than a Seatbelt profile
generator that has to be as trustworthy as the Linux stack.

**3. Ceilings become VM configuration.** `mem_bytes` and `pids` are the
two limits that need a cgroup, and the whole `--cgroup-base` /
`LOOM_CGROUP_BASE` delegation apparatus exists because cgroup v2 forbids
a cgroup from having both member processes and controllers enabled for
its children, so the helper's own cgroup can serve as a base only in the
true root. #52 is the history behind the care that apparatus now takes:
three text files under a typo'd `--cgroup-base` were accepted as a cgroup
v2 base, `memory.max` and `pids.max` were written as ordinary files, a
32-way fork burst under `pids: 8` ran to completion, and the frame
reported `cgroup-v2` **applied**. A VM's memory and vCPU count are
arguments to the VMM. A pid ceiling still needs a guest-side mechanism,
but the operator-delegation problem — the part that produced #52 — goes
away entirely.

**4. `Proxy(allowlist)` finally gets somewhere to live.**
`narrow_unenforceable` (`packages/broker/src/broker/policy.gleam:347`)
has exactly one rule today: `NetworkProxy` becomes `NetworkOff`, because
the egress proxy sidecar does not exist and a proxy-mode jail would
otherwise run with unrestricted direct egress. Spec Part 5 track 10
("egress proxy hardening") is explicit that it hardens something unbuilt.
A microVM has exactly one virtual NIC and the host owns the other end of
it, so a harness-owned proxy on the host side makes the allowlist
enforceable *by construction* — every packet the guest can emit goes
through it — rather than by a syscall filter that can only refuse socket
creation wholesale. This is the one place where the VM tier makes a
feature possible that the process tier makes awkward.

**5. Multi-tenant and hosted serving become tenable.** This is the case
§5.2 actually names, and the one that pairs with Part 5 track 1 (remote
executor pools) over the same protocol: a pool of VM-backed helpers on a
build server, reached over the framing protocol through a tunnel, is the
two tracks composed rather than two separate projects.

**6. Snapshot-boot warm pools.** Track 3's own words, and the answer to
the one cost lazy spawning still carries. The production pool is no
longer a literal: it is the node's scheduler count clamped to `[4, 16]`
(`pool_size_for`, `packages/broker/src/broker/exec.gleam:1700`), wired
through `LOOM_HELPER_POOL` (`start_pool`,
`packages/client/src/client/serve.gleam:894`), which means there are
several cold slots to fill rather than one, and a wide first batch pays
for each of them in turn. Snapshot restore is fast enough that a warm
pool's checkout can beat a cold process spawn. This is a performance
benefit, and it is ranked last deliberately.

---

## 4. What it costs, stated honestly

**It needs KVM.** `/dev/kvm` means bare metal or nested virtualization,
and it is routinely absent on a developer laptop (macOS without HVF, a
Linux VM without nested virt enabled) and inside CI containers. This is
decisive for the shape of the work: the VM tier is an **additional tier,
not a replacement**. The bwrap driver stays the local default, and
`host_platform_for` (`packages/broker/src/broker/exec.gleam:1461`) grows
a third answer rather than having its two replaced. Any plan that treats
the microVM as the new baseline is a plan to make the tree untestable on
the machines it is developed on.

**Latency per execution**, unless snapshotting absorbs it. A cold boot is
tens of milliseconds for the VMM and considerably more for a guest that
has to mount a filesystem and start a helper; against a bwrap spawn
measured in single-digit milliseconds, that is a real regression for the
short commands that dominate an agent session. Snapshot restore is the
answer track 3 already names, which makes a warm pool not an optimization
to defer but part of the minimum viable driver.

**The self-test story needs a VM-tier equivalent, or the tree loses its
best property.** `make selftest` runs `internal/selftest`'s probes
against the live kernel and prints ENFORCED or SKIPPED per layer, under
the rule that a probe whose layer the environment cannot provide skips
with a reason and never fakes a pass. The hostile-satellite tabletop
compiles `loom_hostile.erl` with `erlc` and loads it into a real jailed
node, and it refuses to report containment on silence: the adversary
announces that it loaded, performs two effects the policy *allows* and
reports them, and the identical module runs unjailed first, so a jail is
never credited with holding something the host never permitted anyway. A
VM tier with no equivalent of that is a tier whose isolation claims are
read from a hypervisor's documentation.

That this concern is already live for the *existing* tier is issue #62's
whole subject: `llock.Apply` has never executed in any environment this
repository has run in, so every claim about what Landlock actually does
is read rather than measured — and the one configuration where Landlock
is load-bearing on its own (degraded mode, no bwrap) is the configuration
nothing has exercised. A second unobserved enforcement layer is not the
thing to add on top of that.

---

## 5. The three candidates

**Ephemeral Docker (or podman) containers buy nothing on point 1, and
this should be said plainly.** A container shares the host kernel. It is,
mechanism for mechanism, a repackaging of what the helper already builds
by hand — namespaces, cgroups, a seccomp profile — with a *weaker*
default filter than the helper installs, since the common default
profiles permit socket creation and the helper's network-off filter does
not. And a container runtime has no equivalent of the per-execution
enforcement report: the helper's fd-4 report is a witness that bubblewrap
built the namespace and stage 2 exec'd inside it, and the mount audit
says what the resolved plan actually narrowed. `docker run` returns an
exit code. Adopting containers would trade a reporting mechanism the tree
spent #37, #52 and #54 learning to build for isolation that is no
stronger. The one honest case for them is operational packaging of an
already-hardened image, which is a deployment question rather than a
sandbox one.

**libkrun is the interesting middle path for a local hardened tier.** It
is a library rather than a VMM daemon, so a guest is launched from inside
a process rather than by talking to a supervisor — which preserves the
shape the broker already has, where a helper is a process the pool
spawned and a port is the channel to it. It also offers a macOS route via
Virtualization.framework/HVF, which makes it the only candidate here that
speaks to the unbuilt phase 2. If the goal is "the local jail, but with
its own kernel", this is the one to prototype against.

**Firecracker is the better fit for the case the design doc actually
names.** Hosted, multi-tenant serving with a warm pool of snapshot-booted
VMs is what it was built for, it is the one with a real snapshot story,
and it is what spec track 3 already names. It also composes cleanly with
the remote-pool track, since a VM fleet and a framing-protocol tunnel are
independent halves of one deployment.

The two are not exclusive. They answer different questions — "how do I
harden one developer's machine" and "how do I serve many tenants" — and
the transport seam described in §1 is indifferent to which sits behind
it.

---

## 6. Sequencing

Nothing here is scheduled; this is the order the dependencies force if it
ever is.

1. **Land `protocol-change/004` (explicit mounts).** It is the
   prerequisite for two separate things: a tightened base view on the
   existing tier, and any driver at all whose filesystem is not the
   host's. Until a policy can *say* that the cap socket and the token
   have to be reachable, every driver that changes the filesystem
   topology breaks code mode silently rather than refusing.
2. **Make the enforcement vocabulary driver-scoped, or negotiate it in
   `hello`.** This answers issue #64's second design question in the
   affirmative. It is a refactor of `required_layers` and its two
   companions today; it becomes a correctness prerequisite the moment a
   second driver exists, because otherwise the first VM execution either
   lies about `bwrap` or fails every `FullEnforcement` demand.
3. **Settle the workspace question (§2.2).** Shared filesystem or copied
   filesystem is the decision everything else is shaped around: the
   transport, the policy translation, whether `fs_*` can stay where it
   is, and how much of point 1's benefit actually survives. It is a
   decision rather than an implementation, and it should be written down
   as one.
4. **Then the transport and the pool.** A vsock `Transport` variant, a
   VM-lifecycle `spawn` closure for `start_pool`, a `watch_cleanup`
   janitor on the VM handle, and a wiring switch. At that point — and
   only at that point — this really is the small diff the design doc
   promises.

The ordering is forced rather than preferred. Doing 4 first produces a
driver that works in a demo and misreports its own enforcement, which is
the one failure mode this codebase has consistently refused to ship.

---

## 7. What is not settled

- **Whether the two tiers share one `SandboxPolicyV1`.** The design says
  "same policy language" and that is very nearly true — the four path
  lists, the network lattice, the limits and `env_allow` all mean
  something in a guest. But `scratch: "tmpfs"` names a mount the guest
  makes for itself, `protected` means "masked from this view" rather than
  "masked from the host's view", and every path is host-absolute. Whether
  that is a translation layer over v1 or a versioned successor is open,
  and 004 is the change that would settle much of it by making the
  filesystem vocabulary explicit instead of implied by the base view.
- **Whether `fs_*` moves inside the jail.** If the workspace is copied
  rather than shared, the coherent answer is that the filesystem tools
  stop being harness-side and become capability calls like every other
  effect — which would delete `resolve_real`'s reason to exist and
  replace path discipline with the same kernel boundary `bash` already
  gets. It is the *right* shape, and it is a much larger change to
  `tools` than anything else named here, touching hashline, replay
  safety, and the `Concurrent`/`Exclusive` scheduling tags. It should not
  be smuggled in as part of a driver.
- **How a VM tier's enforcement report should read.** The tags an
  operator sees today name mechanisms they can reason about and check
  independently: `landlock:abi=5` is a fact about their kernel.
  Inventing `microvm` or `hypervisor` as a tag would produce a report
  that is technically honest and operationally empty — one word standing
  in for everything, with no way to tell a correctly configured guest
  from a misconfigured one. Whatever the vocabulary becomes, it has to
  preserve the property #54 bought: a layer that says nothing is not a
  layer that was applied.
- **Whether the guest runs `loom-exec` unchanged.** The cheapest design
  is that it does — the same binary, the same fd-3 policy, the same
  stage-2 report, just inside a guest — which would keep the Linux
  enforcement stack meaningful *and* add the hypervisor boundary beneath
  it. That is attractive precisely because it makes §2.1 much smaller:
  the layer tags stay true. It is also the design where the VM buys the
  least incremental isolation per unit of work, since everything the
  process jail already did is still being done. Nobody has costed the two
  against each other.
- **What a VM-tier self-test actually probes.** §4 says one is needed; it
  does not say what it asserts. "The guest cannot reach the host" is not
  a property a probe inside the guest can witness the way `probeProtected`
  witnesses a masked path, and the honest version may be a host-side
  observation of the VM's device interface rather than a probe at all.

## See also

- `docs/loom-design.md` §5.1, §5.2, §5.6 — the threat model, the tier
  list, and the two-channel doctrine this note tests.
- `docs/loom-implementation-spec.md` Part 5, tracks 1, 3 and 10 — remote
  pools, the microVM tier, and the egress proxy that does not exist.
- `docs/architecture/effects.md` — the plane as built, and Rule Zero.
- `docs/architecture/code-mode.md` — the cap channel, and what the policy
  cannot say about reaching it.
- `packages/sandbox/CLAUDE.md` — the jail layers, the mount precedence
  model, and the honest-reporting contract.
- `protocol-change/004-sandbox-policy-explicit-mounts.md` — PROPOSED, and
  the first prerequisite.
