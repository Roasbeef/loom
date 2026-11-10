# Current handoff

## Platform-selected JSON decoding

[The fixed compatibility and storage replay](review/platform-json-2026-11-09.md)
evaluates OTP callbacks against main `72b8aadd2`. `json_codec.Codec` exposes
immutable callbacks, with native parsing on Erlang and the reference parser on
JavaScript. Encoding stays portable after compact-object regressions in the
experimental native encoder. Storage, provider and client byte boundaries select
the codec; pure core and application schemas retain their existing boundaries.
[The package README](../packages/json_codec/README.md) maps the implementation.

The reviewed implementation `61b1f5b18` preserves 25,700 complete parser results,
1,789 encoder byte strings and the existing output-binary ownership. Five
semantic mutants are rejected, native/fallback call counts are witnessed and
the unchanged-candidate control fails specifically with `no_improvement`.
Fixed register/transcript decoding measures 3.04×/5.45× wall speedups and
74.74%/91.60% fewer heap words. The uncached SQLite fixture improves 2.69× with
87.61% fewer actor heap words; warm hits allocate identically. These are fixed
synthetic workloads, not installed daemon CPU, RSS or latency measurements.

Independent review found and closed exponent-only negative-zero sign loss:
zero-valued floats now use the original-input reference parse. The package's
FFI exception is confined by ADR-023; no pure-package external, cache policy,
wire shape, operator setting or live daemon change is part of the work. Final
end-to-end, static, hosted and signoff receipts are recorded separately in the
PR. A PR does not establish live rollout readiness.

## November 9 live profile and whitespace replay

The [fresh profile and fixed replay](review/live-profile-2026-11-09.md) pin both
the running daemon and source baseline to `661dca824`. SQLite reads remain
prominent in sampled stacks. A separate allocation trace identifies JSON work,
including 23.24 MB in whitespace scanning. The owner-approved inspector-only
loopback mapping preserves the existing TLS identity and authentication after
the machine's Tailscale address changed; no daemon or network configuration
was changed.

The private JSON whitespace match now binds a suffix only after a permitted
literal byte matches. A symmetric replay preserves 25,634 complete results,
rejects three semantic mutants and fails the candidate-as-baseline control.
Compact/padded fixture heap words fall 5.33% to 8.67%, with roughly flat reduction
counts; no installed CPU, RSS or latency saving is established. The proof names
its source and measurement limits. PR validation records end-to-end checks,
independent review and hosted outcomes separately.

## Code-mode configuration capture

`CodeMode.submit` now dispatches `Run` and `Launch` through one closure.
The handle-only `Background` still controls whether asynchronous modes are
advertised. The client capture test inspects the registered tool's actual
closure environments and pins one configuration copy, including payload
growth with sharing unfolded. Approval retries still submit `Run` once more
with appended grants; executor launches still go through owner admission.

Local `make check-tools` passes all 818 tests, and the 48 client escalation
tests pass. Client and tools lint have no errors. Full client and real-helper
E2E signoff belongs to CI: this nested macOS jail and deep checkout produce
helper-start and Unix-socket-path fixture failures. Historical figures in
`startup-and-memory.md` are not current installed RSS savings.

## Host-defined code-mode seams (protocol-change/111)

A host that embeds Loom can give a session its own code-mode seam:
`client/host_seam.HostSeam` narrows the `cap/*` imports, withholds named
capabilities, and adds a generated `cap/<name>` whose functions are the host's
own tools. [Protocol-change 111](../protocol-change/111-host-code-mode-seam.md)
is the design and the threat model; `docs/architecture/code-mode.md`, "A seam
the host defines", is the map. The consumer is aegis's `cap/aegis` on its
untrusted runner pod.

- **Built:** the generator target (`mcp/codegen.generate_host`), the arm that
  runs the host's tool after `tool_gate.holding`, the seam on executors through
  `McpPlan.host` (remote protocol version 7), owner-side admission
  (`host_seam.owner_admits`), and the untrusted link's rule that a host call
  names an in-flight `code_mode` call. `serve.Settings.code_mode_host` wires it.
- **Rulings not to reopen:** a host function is a host `tool.Tool`, not a
  handler closure, so a program call and a direct call share one `run`; host
  calls travel as owner-bound capabilities over 109's callbacks, not a route of
  their own; a host seam only narrows.
- **Not done:** background programs reach no host module over the untrusted
  link (the rule needs a foreground `run`). Aegis must still place its sessions'
  workspaces on the runner through Loom's `Reach` (its 068's L5) before it can
  use this. No live drive with a model has been run.

## Untrusted executors (issue #1196, protocol-change/109)

An `[executors.<name>]` row can now say `trust = "untrusted"`: the executor is
never a distribution peer, and the orchestrator reaches it over a TLS 1.3 link
with a pinned leaf on each side, carrying 078's vocabulary as JSON frames.
[Protocol-change 109](../protocol-change/109-untrusted-executors.md) is the
design and the threat model; `docs/architecture/distributed.md`, "Untrusted
executors", is the map. The consumer is aegis, whose review pod runs
attacker-influenced code and must not be a peer.

- **Built (slice 1):** the link (`client/remote/untrusted_link`) and the gateway
  (`untrusted_gateway`), the wire and its total codec, the bridge between them
  and 078's subject-carrying messages, `[executor_link]` and
  `[executor_listener]`, tool calls with recovery and cancel, owner callbacks
  checked per binding, and state transport (pulled, never pushed).
- **Built (slice 2, stacked on slice 1):** background code mode. `StartExecution`
  and `StopExecution` are requests, `LaunchExecution` and `InteractExecution`
  callbacks; a program's capability reaches the owner only while its start is
  outstanding, and a launch or an interaction only from a `code_mode` call in
  flight. The wire version is 2.
- **Rulings not to reopen:** the cut stays at `ToolSurface.run` (no per-file
  RPC, no path on the wire); the link stands where the host's address was, so
  the surface and owner port are unchanged; no Erlang term crosses; a callback
  that names a call must name one the link has in flight, and an escalation must
  match it exactly.
- **Not done:** remote evolution, and a broker tunnel for non-tool callers
  (project hooks, goal checks, Git observation, the worktree diff), which are
  refused on an untrusted executor (slices 3 and 4 of 109). The
  links and the gateway are not restarted by a supervisor. No live drive with a
  real model or a real aegis pod has been run.

## Strand register decoding replay

The [fixed replay](review/strand-poll-replay-2026-11-05.md) isolates the
remaining strand control-read cost on main `b103ddd28`. A private first-match
field walk in `machine/codec` removes lookup closures/callbacks while preserving
all four fresh reads, typed decoding and corruption refusal. Across real memory
and SQLite writers with held assistant/summary requests, VM reductions fall
5.14% to 8.14% and caller allocation falls 1.97% to 2.85%. End-to-end CPU/wall
timings are mixed; no elapsed-time or installed-memory saving is claimed.

Full poll answers/read traces match in 1,356 comparisons, with 1,272 additional
complete typed-value/corruption-record comparisons. Four isolated semantic
mutants are rejected, and the candidate-as-baseline control fails the combined
improvement guard. All 890 selected native tests, the new properties on Erlang
and Node, and house lint pass. The PR records independent review, hosted results
and current merge rules separately. No public interface, dependency, cache,
timer or live process changed. Raw evidence is under
`.notes/benchmarks/strand-poll/`.

## November 4 live profile

The [fresh CPU/memory profile](review/live-profile-2026-11-04.md) measures
installed daemon `be9d81d843`, including PR #1153. Uninstrumented windows use
7.06% and 13.13% of one core; closing RSS is 499.42 MiB and footprint 548 MB.
The sampled CPU candidate remains SQLite register/snapshot queries (92 of 153
active samples). In the separate selected allocation trace, strand runtime
accounts for 63.6% and JSON 10.4%, with 19.43 MB total over 15.355 seconds. A
node-wide cache probe records 2,350 reads and 86 decodes; these observations do
not justify another cache. Closing VM allocation is 478.58 MiB across 807
processes, with a largest process of 10.65 MiB and maximum mailbox length of
one. These are capacity and activity measurements, not a leak diagnosis or
a matched installed-savings percentage.

Next, replay strand wait/poll register reads at a fixed workload and separate
message copying from typed payload decoding, preserving fresh sequence checks
and corruption refusal. Raw artifacts and the validator are in this tree's
`.notes/profiles/2026-11-04/`. That profiling round made no production or implementation
change. The older sections retain their historical workload/build limits.

## TLS launch preflight (issue #1137)

The owner approved this slice for code and isolated tests, not a live upgrade.
[Protocol 106](../protocol-change/106-launch-preflight.md) records the private
launch witness, read-only staged validation and fenced replacement.
The [review record](review/launch-preflight-1137.md) and
[PR #1146](https://github.com/Roasbeef/loom/pull/1146) separate the focused,
installed-update and full-gate evidence. At `074b22c6c`, both affected shards,
raw hosted checks, strict skip censuses and Linux signoff passed. The current
integration also includes merged #1148; that combined head requires fresh
validation before merge. No live upgrade is authorized.
Repository handoff, isolated child custody, movement, gateway, page relay and
fleet work remain open under #1137.

## Owned memory sessions (PR #1171)

Embedders outside Loom's supervision tree can use
`session.open_memory_owned` to obtain a session and a separate retirement
callback. The owner drains runtime work and readers before invoking it. The
callback seals the store, requests an orderly stop, and waits for the storage
actor to exit. Ordinary `open_memory` and `close` retain their seal-only
lifetime.

Retirement installs its monitor without a separate liveness check. A `noproc`
notification means the actor is already absent and cleanup is complete; other
observed abnormal exits remain faults. Sequential and concurrent retirement
are covered in the storage tests. The concurrent test exercises competing
callers but does not force the original check-to-monitor scheduling window.

## Project mode (draft PR #1164)

One router session decides what becomes work for a repository, and each piece
of work runs in its own session. Read
[docs/architecture/project-mode.md](architecture/project-mode.md) first; its
Known gaps section is the list of what's open. The owner merges this PR.

- **Rulings not to reopen:** typed routing with no free text for a worker;
  `auto` per source and rule, and only after a passing live verdict; the host
  runs the check, the push and the pull request; a person's turn is recorded
  with explicit strength; a project is a catalogue row and a role. Inferred text
  never reaches an explicit worker, and inferred work is published only by a
  person. A replay pass unlocks nothing, because replay agrees with its own
  recording whatever the labels say. An inferred worker has no network, since
  the broker refuses every allowlist.
- **Verified live, on macOS with Kimi K3 and publishing off:** fan-out, the host
  check catching bad work, close and resume keeping commits, strangers reaching
  no model, jail refusals of writes, and a passing live verdict that unlocked
  `auto`.
- **Never run:** Linux jail enforcement of a worker, publishing against real
  GitHub, posted replies, masked secret reads from a worker (the model refused
  to try), remote workers.
- **Unexplained:** one worker read failed with "the session was stopped" after a
  graceful restart. `daemon.session_stop` now logs who stopped a session, so
  look there if it recurs.
- **Next:** drive publishing against a real repository, then a Linux drive.
  An egress proxy would let inferred workers fetch dependencies.

## MicroVM executor tier (issue #85)

Two branches carry the tier. `microvm/libkrun-launcher` (PR #1154) is the
first slice: the `loom-vm` launcher, the Landlock libkrunfw, the guest root,
the executor-in-a-guest link and the node credential mask.
`microvm/dev-experience`, cut from its tip, is the developer path recorded in
ADR-022's "developer path" addendum. Neither has a hosted CI run.

- **What a developer runs:** `loom-vm setup --release TAG` (or `make
  vmm-install-dev` from a checkout), then `loom vm up --workspace DIR`, then
  `loom --executor vm --workspace NAME`. `loom vm down` stops the guest and
  `loom vm status` reports it. A second `up` resumes the guest's checkout and
  its state disk; `--fresh` starts both again. `--github gh|env|off` (default
  `gh`) chooses the token the credential proxy injects; the guest only ever
  holds a placeholder.
- **Verified on an Apple Silicon Mac:** `daemon_shipped_microvm_test` drives
  `loom vm up`. An orchestrator on the host runs a scripted turn whose
  jailed `bash` call shows the Landlock guest kernel and loom-exec, cannot
  read the node's cookie, and sees only the placeholder token. With
  `LOOM_VM_GITHUB_LIVE=1`, GitHub answers `/zen` with 200 and the injected
  fake token with 401 on `/user`. A host-side grep finds the fake token
  nowhere under the guest's directory. After `down` and `up`, a new session
  reads a file the first one wrote. A cold `up` takes about 7 s and a resume
  about 4 s.
- **Fixed on the way:** an executor's distribution key and cookie, and then
  the standing guest's deployment and the home's `.erlang.cookie`, were
  readable from host jails; all are masked now. Formatting the state disk in
  the guest shortened its image by 64 KiB, which refused the next boot;
  `loom-vm` restores the size. A symlinked guest root was booted in place of
  a private copy.
- **Ruled (owner, 2026-11-01):** a standing guest run by `loom vm`, separate
  from the daemon; the local daemon as a loopback-bound distribution member
  (protocol-change/106); prebuilt artifacts on GHCR and the release; the
  agent pushes from the guest through the credential proxy, superseding
  #214's no-injection line and #1137's owner-pushes ruling for this tier; a
  persistent state disk per guest. `loom vm sync` is #1155.
- **Several guests, one deployment (2026-11-02):** `loom vm up` mints in ledger
  mode and seals the authority key under `<vm home>/authority/<id>/`. A
  `loom.toml` that holds a ledger deployment gets a new guest enrolled through
  the running daemon (`vm_spec.deployment_state`, `vm_cli.join`,
  `ledger_cli.enroll_member`); `rm` revokes it (`ledger_cli.revoke_member`) and
  removes the minting guest last. A static deployment is refused, and so is a
  join with the daemon down or the key elsewhere. The live test joins a second
  guest and places a session on each. A guest is reached only from the
  orchestrators of its host; executor-to-executor placement is #1137. Not done:
  a join whose entry was signed but whose bundle could not be written has to be
  finished with `loom distribution renew`. A join the daemon did not take
  fails with the bundle kept, and `up` resumes from it after the operator's
  `loom distribution import`; that path is covered by pure tests and has no
  live step.
- **Unverified:** `.github/workflows/vmm-release.yml` has never run; the GHCR
  package must be made public once by hand after the first publish;
  `setup --release` has never downloaded a real release; Linux/KVM has not
  booted; no real push with a real token has been made.
- **Open:** a pool driver and a guest per session; the remaining #214 pieces
  (proxy as the only egress path, per-call allowlists, an enforcement-report
  entry, a self-test probe) before `narrow_unenforceable` stops downgrading
  for guests; whether the proxy should refuse private address ranges, which
  would break a GitHub Enterprise allowlist; a node key installed by `loom
  distribution install` outside the state root is still unmasked for host
  sessions (the cookie is masked); the Linux half of the firmware build and a
  Linux runner download; Firecracker.

## Correction: a Blue-tier entry must name its cyber access program

A `codex-subscription` session against `gpt-daybreak-blue-latest` began failing
with `provider stream error (cyber_policy)` at `seq=3` after several days of
working. The failing session's header read `codex-daybreak-blue`, and
`[profiles.codex-blue]` routes `main` to that entry. The session store is a
protected path, so this is header and catalogue evidence rather than a read
transcript.

That model is Blue-tier: it gets Daybreak Blue only when the program is
selected, and otherwise falls back to Standard safeguards
(`AccessProgramsParam.cyber`). Standard safeguards refuse ordinary
defensive-security work, and `cyber_policy` is a permanent code, so the attempt
is terminal: never retried, never walked to another target. The entry named no
`cyber_access`, so it requested Standard guards by omission.

The trigger was not a Loom commit. `6a2d8f4b4` dropped `access_programs` from
subscription bodies, but only an entry that configures `cyber_access` ever
attaches a selection, and this entry configured none: its wire bytes were
identical before and after that commit. The change is in how the endpoint
resolves an omitted program, which is consistent with the same week's Codex
work making Daybreak an explicit opt-in. That reading stays a hypothesis: no
comparison request was made, and nothing here dates the server change.

`6a2d8f4b4` was still a real and separate hazard. It silently discarded a
selection from any entry that did configure one, such as `codex-sol-6-blue`,
and its rationale inverted the contract. Subscription bodies forward the
operator's selection again, and both regression tests assert the forwarded
program. Entries that configure no selection still omit, which is correct for
a model without a Cyber tier and wrong for a Blue-tier one.

So the fix has two halves and only this tree carries one. A `codex-subscription`
entry for a Blue-tier model must also name its program, as
`cyber_access = "daybreak_blue"`. That is per-user configuration in
`loom.toml`, outside this workspace, and is recorded here rather than applied.

## JSON string cursor allocation

The [profile follow-up](review/json-cursor-2026-10-30.md) keeps one origin cursor
through simple JSON escapes and reconstructs exact source positions only at a
closing quote, Unicode escape or refusal. Against main `c06d33430`, the fixed
transcript fixture uses 28.6% fewer heap words and 20.1% less median VM CPU;
dense escapes use about 51% fewer words. Grammar, full corruption reports,
portable source and output-binary ownership remain unchanged. No installed
memory or whole-daemon CPU savings are claimed.

All 169 native core tests and 23,004 complete baseline/candidate comparisons
pass. Four semantic mutants are rejected and the unchanged-candidate control
fails the allocation guard. Independent Astra review found no actionable
issues. The branch PR records broad native/E2E, hosted and exact-head Linux
readiness; focused measurements alone do not complete those gates. The full
supplemental JavaScript core suite retains the same nine baseline failures,
with all new cursor properties passing on both implementations. No assertion,
test, dependency, public interface or live process policy changed.

## Mermaid failure diagnostics

`codex/mermaid-error-details` adds a bounded exception message above the open
source fallback. The [verification record](review/mermaid-error-details-2026-10-30.md)
records the screenshot reproducer, failing-before regression, 1,678 focused
Gleam tests, five FFI checks, all 28 real-browser checks and independent review.
The [protocol 091 addendum](../protocol-change/091-isolated-mermaid-diagrams.md#addendum-failure-diagnostics-2026-10-30)
keeps the diagnostic as bounded text under the existing frame identity,
revision, sandbox and content-policy checks. Integration with main preserved
the catalogue/profile handoff below; exact-head hosted and Linux validation
are being repeated on that integration. No live update was performed.

## Current local CPU and memory profile

Baseline `ccb795759` on October 30, 2026. The [current profile](review/live-profile-2026-10-30.md)
confirms the installed daemon includes the evolution and catalogue repairs,
superseding the older installed-version observations below. The quiet OS window
used 6.54% of one core at about 345 to 360 MiB RSS; a later uninstrumented active
window used 63.51% at about 413 to 441 MiB RSS. Pickglass's active sample ranks
register/snapshot SQLite work first, with web rendering secondary. The active
allocation trace counts 356.28 MiB over 17.165 seconds, at least 65.6% in JSON;
2,311 register-cache reads required only 104 decode calls. The closing VM census
is 348.28 MiB allocated across 503 processes. These are changing workloads,
not matched savings or proof of a leak.

Next, reproduce register/snapshot polling and subscribed-view work in a fixed
replay before changing caching or serialization. Captures and the validator
are in this worktree's `.notes/profiles/2026-10-30/`. No production process was
upgraded, restarted, collected or retired during this round. The historical
sections below retain their recorded scope; unrelated CI readiness was not
revalidated for this observation-only work.

## Catalogue source-read performance

The [catalogue hot-path record](review/catalogue-hot-paths-2026-10-29.md) tracks
the bounded joined source read and ASCII profile validation follow-up to the
live profile. Fresh registration and domain validation remain on each page;
the manager projects paths in the same owner turn. Preliminary matched results
show fewer queries, CPU work and caller allocation. Candidate storage and all
53 daemon-manager tests pass, with eight runtime mutation controls rejected.
Independent review found no actionable issues. [PR #1148](https://github.com/Roasbeef/loom/pull/1148)
carries full-gate, later benchmark and exact-head hosted/Linux receipts; use
those current receipts for readiness. No live process was upgraded or retired.

## October 29 CPU and memory baseline

The [October 29 profile](review/live-profile-2026-10-29.md) captures the unchanged
running daemon at `fcbc7d9b`, the older native client, and native descendants.
The largest RSS owner is `gopls` (about 2.04 GiB), while the daemon is about
1.06 GiB and six MCP servers add about 409 MiB. Eighteen old test daemons
remain a separate 1.45 GiB summed-RSS cleanup opportunity. No process was
restarted, collected or retired.

The active CPU sample and focused counters identify repeated history-source
catalogue lookups and session register/JSON reads. The catalogue follow-up
above supplies the fixed offline benchmark and implementation while preserving
fresh membership and path checks. That historical process predates #1138. The
October 30 profile above now measures a newer installed daemon, while a matched
replay is still needed to isolate the repairs from changes in process age and workload.

## Versioned peer compatibility (issue #1137)

The owner approved the stable peer exchange and TLS launch preflight for code
and isolated tests. The compatibility slice implements [protocol 105](../protocol-change/105-versioned-peer-exchange.md): page calls negotiate exact revisions
and serving epoch, then dispatch through the same stable endpoint. Missing
support, replacement and unavailable replies retain their distinct meanings.
The existing receiver still enforces spawner policy and approval ceilings.

The [verification record](review/peer-compatibility-1137.md) gives 107 primary
focused checks plus the shipped TLS regression, both manual mixed-version
directions and their precise limits. One independent pass and its native-test
delta check found no actionable issues. Full static gates pass; broad and
exact-head hosted/Linux validation remain required. TLS launch preflight is
the current slice above; no live upgrade is authorized.

## TLS launch and loopback listener (issue #1137, branch `dist/launcher-optfile`)

Two edges of distributed startup are closed by
[protocol 106](../protocol-change/106-distribution-launch-and-listen-address.md).
A daemon that `loom` starts no longer needs `LOOM_DISTRIBUTION_OPTFILE`: when its
configuration has a `[distribution]` table the client renders the options file into
the state root at every start and sets the variable for the child, and an
explicit variable still wins (`tui/distribution_launch`). A daemon started by hand
through `bin/loomd` still needs the variable; that was a ruling, not an omission,
and the reasons are in the architecture document ("Booting a distributed VM").
`[distribution] listen_address` binds the listener to an IPv4 loopback address,
for an orchestrator nobody dials; it is not in the options file, so the boot
comparison is unchanged. The live check (isolated home, static two-node plan, a
daemon started by `loom sessions list`) showed the node in `epmd -names` and its
listener on `*:14471`, then on `127.0.0.1:14471` with the key set.

Left open: `loom distribution install` treats a table with an extra
`listen_address` as a different table and refuses without `--force`, which drops
the key; plans and bundles do not carry it. In the client suite on macOS,
`start_without_an_epmd_reports_the_port_not_credentials_test` fails when the whole
`client@distribution_test` module runs and passes alone, with or without this
branch.

## Distributed runtime experience (issue #1137)

The first slice fixes the signed-out page's rejected `loom ui --device`
command. The [acceptance record](review/distributed-1137.md) gives the
failing regression and browser proof; independent review found no actionable
issues. Linux hosted gates passed; local census and macOS advisory results
remain unresolved, with exact receipts on PR #1143. The owner selected an
always-on trusted brain or gateway for model
access, with remote executors remaining keyless. Repository handoff, per-spawn
workspace custody, movement and full page relay remain open. The full page relay
(#1135) is proposed in [protocol-change/108](../protocol-change/108-live-session-relay.md).

The next slice makes distributed observations honest: remote refusals reach the
card, post-dispatch relay uncertainty survives later failures, and failed reads
retain the last complete page with its age. Failed resident overviews no longer
become idle rows. The same acceptance record distinguishes the modeled race
witnesses and component browser proof from live distributed acceptance. All 489
primary focused tests pass; actual hub/SQLite/registry witnesses also cover
uncertain Stop/Archive/Resolve replies and false idle success. The existing wire
error channels retain those facts. Independent review found and verified the
remaining child-send admission and asynchronous stop wording fixes. The primary
also ran all 211 agency tests and 17 web state tests with no skips after helper
preparation; the agency additions use the memory backend. Formatting, lint,
documentation and generated-artifact gates pass. At head 1dcb19505, both affected
client shards pass all 5,500 tests and their selected lanes/strict skip censuses.
Exact-head hosted and Linux signoff readiness is recorded with PR #1144.

## Running-version profile and native fixture ownership

PR #1138 was rebased on `fcbc7d9b` and merged at `da27f068` under the
owner's explicit force-merge authorization. Its rebased checks were pending;
the prior head's green checks do not cover that rebase. The installed daemon
was preserved on `fcbc7d9b` for the requested repeat profile.

The [repeat profile](review/running-memory-2026-10-28.md) distinguishes process
allocation, OS footprint and sampled allocation. It establishes no further
production retention bug beyond #1138. It does identify eighteen old native
test daemons, totaling about 1.45 GiB RSS. The follow-up gives the headless
and ACP fixtures explicit native ownership: a bounded managed body followed
by birth-fenced retirement outside its deadline. Existing saved-session and
shared-resident assertions remain inside the body. Existing orphaned daemons
were left alone; only fresh reproduction children were retired.

The rebase also restored an obsolete Darwin verifier-skip declaration after
main had replaced those skips with explicit production-refusal checks. The
follow-up restores main's declaration policy. A portable census regression
accepts refusal coverage and rejects the historical verifier skip; it fails
with the obsolete waiver. Linux still executes the enforced verifier proofs.
The earlier waiver record below describes the pre-rebase test arrangement.

Validation for this follow-up is still in progress. Do not infer installed
RSS savings or hosted readiness from the profiling baseline.

## Responses failure diagnostics and retry advice

Follow-up to merged PR #1140, integrated onto main `da27f068d` (October 28, 2026).
The [comparison and proof record](review/responses-failure-recovery.md) traces
Codex's error parser, HTTP bridge, retry loop, cleanup and tool settlement at
a pinned source revision. Two recorded generic failures prevented automatic
recovery, but their original upstream causes were not retained.

Nested and flat errors now retain safe structural context. Unclassified
Responses failures use the existing durable three-generation ceiling;
recognized permanent labels win over transient evidence. Owner-approved
[protocol 104](../protocol-change/104-streamed-failure-retry-advice.md) adds
optional `StreamError.retry_after_ms`, preserving HTTP/event advice through
scrubbing and durable backoff. Other named transient classes retain configured
retry policy. Strict terminal validation and transport drain remain unchanged.

Before integration, full provider/runtime/machine/harness/conformance gates
and all 5,468 local client tests pass, with shipped-daemon fixtures left to
hosted/signoff execution.
Eight semantic mutation checks pass and independent review found no actionable
findings. Require final-head hosted CI and Linux signoff before readiness;
their current outcomes belong in the PR verification record.
No deployment, restart or live model call was made.

## Responses completion and returned identity (issue #1139)

Source baseline: `6a2d8f4b4` on `codex/responses-done-arguments`, over main
`e4fb0b5e5` (October 27, 2026). The [validation record](review/responses-1139.md)
documents the reproduction, native parser comparison and remaining gates.

Function-argument done snapshots may supply the whole payload or extend the
streamed prefix. Only the missing suffix is emitted; conflicts still fail and
canonical item/terminal closure remains required. Subscription requests forward
`access_programs` as API-key requests do; the original omission was reverted.
Served-model headers and bounded

The final provider gate passed all 343 tests, the Responses suite passed 62,
and the catalogue suite passed 137. Eight semantic mutants were killed, and
independent review found no actionable issues. The macOS follow-up replaces
the historical mining fixture's `/proc/self/environ` lookup with the existing
portable home-directory boundary. With owner approval, all 22 real eval
verifier proofs remain on Linux; macOS runs explicit production-refusal
checks because its lifecycle enforcement cannot admit a verifier jail.
Pure checks still run on both hosts. The shipped remote-subagent fixture
also resizes its final transcript peek to 120 by 40 so the loaded page's
header and footer fit together; at 80 by 24 its header assertion raced the
transient loading frame. No assertion, deadline or production enforcement
rule was weakened. Before merge, require the
exact final head's hosted checks and configured Linux signoff. Live OAuth
endpoint behavior remains unverified by this patch's deterministic fixtures.

The directory follow-up preserves a local lookup-hint coverage request while
its creation is still assembling. The census returns its existing transient
error until active local reservations confirm; failed, inactive and remote
reservations do not block it. A barrier-controlled regression fails before
the fix and proves publication after confirmation without a second request.

The macOS package jobs run without optional package caches: the measured
537 MB restore consumed 12m49s, while the full check finished cold. This is
part of the PR workflow so its merge-commit checks exercise the setting.

The earlier handoff sections below retain their previous work records. Their
external CI and deployment claims were not revalidated for this scoped fix.

## Memory profiling CI follow-up

PR #1138 also fixes the macOS miner fixture's procfs assumption through the
existing portable home lookup. The historical before/after mining experiment
passes without a skip. A TUI stream profile found duplicate JSON parsing across
`session_wire` and `protocol`; package-internal value dispatch removes it while
preserving text APIs, frame admission, event checks and the 2,000/sec drain floor.
A reductions regression fails the old double parse and passes the shared-value
path. `docs/review/evolution-memory-2026-10-27.md` records the matched work and
throughput measurements. Exact-head review, hosted results and signoff for these
additions are recorded on the PR; earlier f1121f22c signoff covers only the memory
capture changes.

The final macOS census exposed 22 existing eval-verifier refusals for missing
address-space and process-lifecycle enforcement (ADR-006). The Darwin-only
declaration matches their complete reason. Production refusal is preserved;
Linux eval and signoff execute the matching tests. This records a macOS coverage
gap rather than claiming those verifier experiments ran there.

The test-only TLS verdict collector also waits for asynchronous trace delivery
before answering a read. A queued-message regression reproduces the former
empty-verdict result without weakening the real pin and allow-list assertions.


The runtime idle-poll fixture creates its real timer before synchronously
recording the arm. A regression suspends only its own recorder and requires the
37 ms wake within the existing 200 ms window. Recording first fails this test
because the observed timer does not yet exist. Existing polling assertions and
deadlines are unchanged; the PR preserves the earlier hosted failures and final
validation results without claiming their complete cause from partial logs.


The protocol stdin fixture also acknowledges the first read before its writer
sends valid UTF-8. The former fixed one-second pause let a slow-starting VM read
both byte chunks together; delaying startup reproduces the hosted exit 7 and
wrong bytes. A private FIFO and bounded wait synchronize the existing assertions.
Production decoding and test deadlines are unchanged. The delayed-reader
regression and final hosted evidence are recorded with the other CI follow-up.
Unexpected TLS spike failures print their full stack to stderr so a truncated
EUnit error still identifies the failing scenario step.

The compiled Gleam cache selects `build/dev`, `build/prod` and `build/packages`
instead of whole package build roots. A macOS shard passed every test but hit
the unchanged 50-minute job limit during cache save; its restored archive took
over eleven minutes to extract. Whole roots include prior session databases,
unique fixtures and exported runtimes. The archive regression preserves the
compiler artifacts and rejects those transient paths. New cache paths also
isolate the old archives through the cache action's version. A separate virtual
TUI WebSocket timeout passed five targeted and five full-module local repeats;
its cause is unproven. The PR retains these failed hosted outcomes and records
the replacement head's full checks and executed censuses before readiness.

## Evolution callback memory

`fix/evolution-captures` repairs a live profile that found fifteen evolution
actors holding 226.69 MiB of process allocation. Capability doors and generation
owners captured sibling machine operations repeatedly; notification runners
copied that configuration during startup to read only its clock.
[The evidence record](review/evolution-memory-2026-10-27.md) distinguishes live
measurements, isolated copy-cost regressions and unverified installed savings.

The two new regressions failed before the repair and pass afterward; all 185
focused evolution tests pass. The PR records the remaining local, independent
review, hosted and Linux signoff results. No live update or restart occurred.


## Agent Client Protocol server (issue #1026)

`loom acp` makes Loom an ACP agent on standard input and output, on branch `acp/agent-server`. It is a client of the daemon like `loom run -p`; the effect plane is untouched. [The architecture page](architecture/acp.md) is the reference: the method mapping, the `_meta.loom` keys, the workspace gate, and the compatibility table for Harbor's generic ACP runner, which was driven unmodified against it over a real pipe.

Open, in the order they matter:

- **Per-session MCP servers** (`session/new.mcpServers`) are refused with `invalid_params`. They need a daemon command that registers direct tools for one session, cleared by the broker and torn down with it, and so a `protocol-change/NNN.md`. aegis's typed `submit_*` tools depend on this.
- **The guidance opt-out** (`_meta.loom.project_instructions=false`) is refused for the same reason: the daemon assembles `AGENTS.md` and `CLAUDE.md` at session start with no per-session switch. The canary-`AGENTS.md` acceptance test cannot be written until the daemon can honour it; the refusal is tested instead.
- **Loom as an ACP client** (a strand whose model is `codex-acp` or `claude-code-acp`, under the broker's clearance and budget) is the second direction in the issue and has no design note yet.
- Sessions are not stopped on SIGKILL or an early SIGTERM (no signal handler); see the lifetime section of the architecture page.
- `session/load` replays the retained window (the newest 100 records), not the whole history.
- The stdio path was verified by hand against SDK 0.12.1; the automated end-to-end drives the same `server.serve` through a pair of subjects. A subprocess-level test belongs with the release smoke.

## Responses recovery integration

[PR #1130](https://github.com/Roasbeef/loom/pull/1130) adds extended Responses reasoning and bounded recovery for missing streamed-part closures. It is rebased onto main `f4a7991c9` for the owner's requested immediate merge. All implementation commits applied cleanly; this handoff was the only Git conflict. The evaluation handoff below is preserved.

Main introduced protocol 100 and reserved 101 while this PR was open. This PR's proposals are now [102, extended thinking levels](../protocol-change/102-extended-thinking-levels.md) and [103, bounded Responses recovery](../protocol-change/103-bounded-responses-recovery.md). Only their identifiers and references changed.

Full hosted checks, raw macOS whole-check logs, executed strict skip censuses, independent review and Linux signoff passed on pre-rebase head `2259f628b`. The [final verification record](https://github.com/Roasbeef/loom/pull/1130#issuecomment-6427364166) preserves both the initial throughput failure and the unchanged passing retest. Those results are not a new full signoff of this rebased head. See the [source validation report](review/responses-stream-recovery-2026-10-26.md) for the implementation proof and limitations.

The recovery ceiling is three total generation attempts, with stricter existing bounds preserved. Stream validation remains strict; no partial response or tool call is accepted. Diagnostics retain only structural metadata, not content. `xhigh` and `max` reach both Responses builders; other adapters retain their prior high-equivalent wire mapping.

No production installation or daemon restart is authorized or performed. After a separately authorized update, apply the desired personal profile settings and verify a live request. If the stream error recurs, obtain the structural diagnostic and a redacted minimal event reproducer before changing validation; bounded recovery does not establish the upstream cause.

## Evaluation instrument handoff

This is the evaluation instrument for #236, on the `eval/*` stack of pull
requests over main `9b8621641`. The [previous
handoff](next-2026-10-25-before-eval-instrument.md) is preserved exactly. Its
two bodies of work, remote evolution slice 3 (closed) and the post-merge CI
repair (still open on draft PR #1112), are unchanged by anything here.
The evolution operator UI handoff from October 24 is preserved
as [its own file](next-2026-10-24-evolution-ui.md); the architecture pages it
describes are current.

Start with [ADR-021](adr/021-evaluation-instrument-beside-governed-evolution.md)
for the decisions, [the architecture page](architecture/evaluation.md) for
how a run works and which module owns each step, and [the design
note](design-notes/eval-instrument.md) for the argument; its §15 lists what
review changed. [protocol-change/100](../protocol-change/100-task-set-v2-and-sampled-verdict.md)
records the governed-path change.

## What landed

Two packages and a change to the governed plane.

- `packages/evalstat` holds the statistics and the decision rule, and is
  held to the R6 portable set. It provides a task-level paired effect with
  a clustered interval, an exact sign test on task signs with a direction
  check, and a cluster bootstrap. It reports the minimum detectable effect
  first and returns Underpowered with a reason, and futility can only
  under-claim. Seeded A/A and planted-degradation properties run on both
  targets.
- `packages/eval` is the developer instrument; it never ships and never
  promotes. It holds:
  - content-addressed tasks with logical repository names, and a miner
    over Loom's own fix commits;
  - a jailed prover (gold one, null zero) and a hardened hidden verifier;
  - a runner and paired report;
  - the replay lane;
  - ATIF, Harbor and transcript exports;
  - holdout-sealed v2 admission and the production join;
  - the first task set (`tasks/loom-history-v1`, 21 proved tasks);
  - operator plans in `plans/`.
- `packages/gepa` is the prompt search as a stdlib-only library, held to
  R6 so a project that is not Loom can embed it: a pure state machine the
  host drives with `next`/`apply`, whose log replays exactly, with the
  front and draws, the budget holds, the reflection prompt and a default
  acceptance rule inside it. `eval/search` is now the adapter (Loom's rows
  and JSON codec unchanged on disk), `eval/reflect` builds Loom's records
  over `gepa/prompt`, and `eval/optimize` keeps the effectful driver and
  asks the library for every decision. An embedder resumes with
  `gepa.replay_checked`, which holds every row to the request `next` made
  before it; the log is printable ASCII by code point so both targets
  write and read the same line, and `scripts/check.sh` now runs gepa's and
  evalstat's suites on JavaScript too. Its README's host loop is a compiled
  test; the module doc of `gepa` names where N-proposal reflection,
  further dispositions, a richer reply and merge lineage would go.
- The governed `evolution.compare` now decides with evalstat over the
  plan's rows, and takes K samples. The door's turn ceiling is 100 and its
  wall 480 s, kept under the code-mode call timeout. The dollar and token
  ceilings are unchanged. The evaluator identity moved to `rollout-2`, so
  evidence judged under the old rule cannot approve.

Every slice was implemented by a worker, reviewed independently, and fixed
before it landed. The verifier's adversarial review found four ways to
forge a pass or escape the copy; all four were closed and re-probed.

## What this environment could not prove

The container had no model API keys and no cgroup v2. Under bwrap the
jail enforced 10 of 11 self-test layers; only the pids limit was missing.
Strict platform enforcement refuses every jailed exec here, so the prover
and the jailed tests ran best-effort. That mode tolerates only a missing
cgroup-v2 layer, and `prove.jsonl` records the posture on every line.
Not yet run anywhere:

1. The live plans in `packages/eval/plans/`:
   - `smoke-record-live` (measures a trial's dollars and records tapes);
   - `aa-live` (must not be Improved or Harmed);
   - `degrade-live` (should be Harmed if powered; at 21 tasks and K = 3
     the detectable effect is about 0.25).

   Their stamped commit and the `no-tests` arm's target are placeholders
   to re-mint; `plans/README.md` says how.
2. `evolution_prompt_acceptance_test` under full enforcement. It is now a
   powered seven-task plan whose arithmetic is proven by a unit test.
3. Harbor: the trajectory validator over an exported ATIF file, and a
   Docker build of an exported task.
4. The failure taxonomy (`docs/review/eval-failure-taxonomy-2026-10.md`)
   is a protocol with an empty results table. Labelling needs real
   sessions.

## Next, in order

1. Run the smoke pair, then `aa-live` and `degrade-live`, and write the
   verdicts and dollars into `plans/README.md`. If A/A is not quiet, the
   instrument is wrong. Debug it before trusting anything else.
2. Export real sessions with `transcripts_cli`, label the sample, and add
   hand-written tasks for every category that is at least 5% of failures.
3. Mine `client`, `tui` and `session_view` once a per-module verifier cost
   is measured (`client`'s full suite is 630 s; mined tasks scope
   pass-to-pass to the touched modules).
4. Then GEPA (#236 phase 5). The candidate is `Arm.components`, and the
   actionable side information is `Grade.side_info`. Acceptance is
   evalstat on the validate split; the holdout gap guards against
   memorisation.

## Deferred, with homes

- Per-role profiles: protocol-change/101 (reserved).
- A `Settings` field for prompt packs. Today `PromptPack` arms are refused
  by name, because the pack reaches a session only through
  `LOOM_PROMPT_PACK`.
- A refusal variant on `core/message.StopReason`. Today `trial.is_refusal`
  matches the adapters' fixed refusal text, pinned by tests.
- Program verifiers in governed comparisons. That needs the jailed
  verifier reachable from `client`; protocol-change/100 says why.
- Refunding the unused per-attempt reservation. Until then, large-window
  targets are always Inconclusive through the door (protocol-change/100).
- Journaling the entry id in `evolution/attempt/*` facts, which would make
  the production join exact.
- The governed door's default program deadline (`within_ms`, 300 s) is
  shorter than its compare wall (480 s), so a program that keeps the default
  can lose up to the dollar cap to trials whose evidence it never sees. Never
  a false Passed. Clamp `wall_ms` to the execution's remaining deadline.
- `loom run -p` and the Harbor agent adapter (#492). `eval/trial` is the
  headless runner it should wrap.

## Watch

Once, under three concurrent builds and a full client run on four cores,
`scripts/test.sh eval` failed one test whose name was lost. 60 loaded
reruns of the cassette suite and every later full run passed. The likeliest
cause is the cassette's 5 s actor waits being starved. If it recurs, write
the log to a file before rerunning so the test name survives, and do not
retry it away.
