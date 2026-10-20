# Current handoff

This file records the verified state and next steps for this checkout. Rewrite
it after a body of work; retain measurements in their evidence documents.

Baselined October 19, 2026 against resource commits `35a0957cb` and
`a0c42df95` on `perf/swarm-resources`. This edition includes their
published integration `4f3c6f458` and the subsequent main updates through
`0e00dc736`. The profiling comparisons retain
their original `c444fca25` baseline.
The claims below were checked against this tree, the saved local gates and the
live observations identified in the report. This is a scoped resource handoff,
not a fresh audit of the repository's architecture or hosted CI.

## Where the tree is

| Work | Verified state |
| --- | --- |
| Live profiling | Pickglass sampled installed daemon PID 50242, launch metadata commit `3cd330739`, OTP 29 / ERTS 17.0.5. The captures declared five sessions and ten strands. No live restart, forced GC or application-state walk occurred. |
| JSON CPU | `35a0957cb` adds an eight-byte ordinary-run scan while preserving the four-byte and byte tails. Three alternating fixture pairs reduce median reductions by 10.0% on plain text, 3.8% on escaped text and 2.7% on transcript-shaped input. Heap allocation is unchanged. |
| Page ownership | `a0c42df95` narrows component session-list and sign-in callbacks to registry and identity fields. The observer fixture's enlarged-hook component falls from 191,308 to 9,550 flattened words. This is a copy-size bound, not installed RSS. |
| Prior-head validation | On `96554f554`, all local package and static stages passed after selecting Homebrew's `rg` for the Seatbelt PATH fixture. Client passed 4,885 tests, TUI 1,544 and conformance 111. All hosted Linux jobs and the combined skip census passed. The 882-input complete-result JSON equivalence digest matches baseline. Independent adversarial and integration reviews found no blocking issue. These results precede the latest integration. |
| Upstream integration | Main `0e00dc736` includes remote-approval fixes from PRs #1036 and #1039, the sparse-renderer resource fix from PR #1023, and the private admin-read fixture adjustment from PR #1040. It also includes image-follow-up and Herdr support from PR #1022. Their source changes and fixture repairs are retained. Incoming handoffs are preserved in the linked snapshots below. |
| Publication and installation | The owner explicitly authorized merge after the rebase, basic checks and independent review, without waiting for the full gate. Earlier CI is historical evidence; this exception does not make unfinished or failed checks green. The owner accepts hosted CI as the Linux evidence; remote Obelisk signoff is not a prerequisite. Installation and restart remain separate. |

The [resource report](review/swarm-resources-2026-10-19.md) records the probe
coverage, counter meanings, fixture methods, test results and remaining limits.
Its [numeric evidence](review/swarm-resources-2026-10-19.json) retains all 36
final JSON observations and twelve component measurements. Raw captures and logs
remain local under `/private/tmp/loom-swarm-20261019-*`.

The [previous handoff](next-2026-10-19-before-swarm-resources.md) described an
older idle-resource branch and Mermaid work. Its branch baseline does not
identify this tree, and its pending-publication statements do not establish
current GitHub state. They remain historical; their PRs and browser follow-ups
were not re-audited during this profiling task.

The [incoming renderer handoff](next-2026-10-19-before-swarm-integration.md)
preserves the upstream resource measurements, fixture failures and Mermaid
follow-ups. Its statement that PR #1023 is awaiting publication is now false:
that PR merged in `698a693de`. The renderer measurements remain in the
[frame-resource report](review/live-frame-resources-2026-10-19.md).

The [incoming admin-read handoff](next-2026-10-19-before-swarm-admin-integration.md)
preserves the renderer merge exception and fixture follow-up evidence. PR #1040
has since merged at `b65857090`; its private admin-read wait is five seconds,
and the later image integration moves generic HTTP reads to the managed fixture
deadline. Explicit timing probes retain their own bounds. The known-failure
merge exception described there applied to #1023 only.

The [incoming image handoff](next-2026-10-19-before-swarm-image-integration.md)
preserves PR #1022's measurements and its explicit known-failure merge exception.
That exception applies to #1022 only. The current integration retains its image
and Herdr changes without altering either production resource patch.

The page regression now measures the component model that owns the callbacks,
excluding Lustre's runtime rendering cache. Five fresh fixture runs pass; three
original-capture controls fail the unchanged 4,096-word growth bound. The full
client coverage on the preceding integration passed 4,891 tests in two shards.
The rebased core and harness package gates pass. Formatting, lint, documentation and prelude checks passed before publication. Historical hosted
head `8bdb8ac0e` passed every Linux lane and its combined skip census, plus
macOS E2E. Its first advisory macOS shard failed internally in
`tools_interleave_test` with "the armed crash bomb never fired"; its success
badge conceals the failed runner. Five fresh interleave-module runs and all
207 runtime tests passed locally, without establishing the original cause.
The second advisory shard and macOS combined census remain unfinished.
The owner explicitly directed merge after basic checks rather than waiting
for those full gates; no fully green CI claim is made.

## 2026-10-19: the real-machine distributed drive

This section is separate from the resource handoff above. It records a drive of
the distributed runtime on real machines, the fixes it produced, and what is
still open.

### What was driven

The topology was a laptop orchestrator and an exe.dev Linux box, all on one
tailnet. The box ran two daemons: a second orchestrator (`box`) and an executor
(`exec`). The model was GLM-5.3. Every combination worked:

1. Laptop orchestrator, local session.
2. Laptop to `exec`, repo workspace.
3. Laptop to `exec`, the `lnd-test` workspace.
4. Laptop to the `linux` pool.
5. Box orchestrator, local session.
6. Box orchestrator to `exec`.
7. Laptop spawning a remote subagent on `box`, including sending a message to
   an idle child and answering the child's approvals remotely.
8. The web view reached from a phone through Tailscale Serve.

The executor's sandbox self-test passed 11 of 11 under a delegated cgroup. The
evidence (logs, screenshots, transcripts) stayed in a scratch directory outside
the repository, so nothing here is a recorded measurement in `docs/review/`.

### Deploying an executor from a source build

[The distributed setup guide](distributed-setup.md) covers the Docker
deployment and the cgroup delegation its entrypoint performs, but not a bare
systemd service on a Linux host. These four requirements cost time during the
drive:

- **The daemon must run inside a delegated cgroup v2.** Use a systemd user
  service with `Delegate=yes`. Its start-up script must split the service's
  cgroup into `supervisor/` and `base/`, move the daemon into `supervisor/`,
  and export `LOOM_CGROUP_BASE` pointing at `base/`. Without that, every `bash`
  call fails with "sandbox was lost" or "ran without the demanded enforcement".
- **A source build needs two extra inputs.** Pass
  `--codemode-seed <build>/build/codemode-seed` (made by `make codemode-seed`)
  and put `gleam` on the service's `PATH`. Otherwise the executor's census
  reports no code-mode toolchain.
- **Scopes can stay `unknown` after a restart.** When the executor daemon
  restarts with sessions open, their scopes are left `unknown`. Stop the daemon
  and run `loom executor release SESSION --state-dir ~/.loom`, as the setup
  guide's troubleshooting section describes.
- **A restart must wait for the old daemon VM to exit** before the new one
  starts. Starting early leaves two daemons contending for the same state
  directory and ports.

These belong in the setup guide as a systemd quick start. They are recorded
here until that section is written.

### What landed

- [#1009](https://github.com/Roasbeef/loom/pull/1009): the web view through a
  listed https origin, and `loom ui --device`.
- [#1025](https://github.com/Roasbeef/loom/pull/1025): a `[daemon]` bind setting.
- [#1027](https://github.com/Roasbeef/loom/pull/1027): a confirmation page for
  sign-in links opened from other apps.
- [#1028](https://github.com/Roasbeef/loom/pull/1028): builds from a git archive
  carry their commit.
- [#1038](https://github.com/Roasbeef/loom/pull/1038): one New session form, a
  grouped Admin deployment view, a phone layout, a host name card, and the
  daemon titled by its ledger name.
- [#1036](https://github.com/Roasbeef/loom/pull/1036): remote approvals stay
  answerable, and a spawner's decision wakes an idle remote child.
- [#1039](https://github.com/Roasbeef/loom/pull/1039): remote approval cards
  are addressed by id, and daemon options may precede the verb.
- [#1043](https://github.com/Roasbeef/loom/pull/1043): protocol-change 093, a
  durable failed session start.

The Linux signoff host was down, so these merges had package gates, reviews and
live checks but no full signoff.

### Open follow-ups

- Issue #1042: the laptop's stub for a remote child does not track the child's
  later runs.
- A device link's expiry was seen once on first open and was not reproduced.
- A `name` key on `[distribution]` is needed for self names in peers mode.
- The web "other orchestrators" list shows a peer's failed start as reserved.
- GLM-5.3-Flash returned 502 responses on large prompts, so the box's child
  profile was switched to GLM-5.3.
- The laptop keeps a request row whose answer window closed on the box. This
  behavior is documented in protocol-change 089.
- Some client tests are load-sensitive under `LOOM_TEST_PARALLEL=8`. A
  separate fix session is working on them.
- Joining the owner's everyday daemon to the deployment waits for the owner's
  go-ahead. Nothing has touched that daemon or `~/.loom`.

## What to do next

1. Publish and merge the authorized rebased PR after basic checks and the
   completed independent review. **Exit:** the published SHA matches the checked
   source and GitHub confirms the guarded merge. Preserve the failed and
   unfinished CI results above; the owner waived waiting for the full gate.
   Obelisk is not a merge gate.
2. Measure remaining memory owners with an isolated fixture. **Exit:** identify
   the retaining callback and prove its bound while preserving authorization
   and lifecycle behavior. Owner-page capabilities in `ui_socket.upgrade`
   still capture attachments; the current observer fixture does not validate
   the owner-only sign-in callback's retained size.
3. Coordinate an authorized update and matched installed comparison. **Exit:**
   compare CPU, cumulative allocation, process/binary memory and OS RSS/footprint
   at the same concurrency and lifecycle cuts. Keep active swarm interruption
   outside an unannounced profiling step.
4. Attribute remaining storage and JSON work before another repair. **Exit:** a
   bounded workload identifies removable work. SQLite sample widths alone do
   not justify statement caching, new synchronization or allocator tuning.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Counter scope remains explicit.** The [BEAM memory review
skill](../skills/beam-memory-review/SKILL.md) distinguishes heap allocation,
flattened copied terms, process capacity, binary ownership and RSS. The report
keeps live observations separate from offline comparisons.

**Narrowing captures does not cache authorization.** The [client package
account](../packages/client/CLAUDE.md) records the callback ownership. Each
session-list read still authenticates its original credential; each sign-in
read still checks the page and registry. Admission remains bound to its
original gateway.

**The scanner preserves the durability boundary.** The [core package
account](../packages/core/CLAUDE.md) records checked byte boundaries and total
error behavior. The complete-result equivalence corpus matches unchanged
corruption reports, not just accepted values. The wider scan adds no FFI or
public API.

**Blank frames keep sparse cells.** The [terminal package
account](../packages/tui/CLAUDE.md) records the inherited sparse-canvas and
first-column repaint-marker invariants. The frame-resource report retains the
renderer comparison; the swarm report measures the parser and page callbacks.

## Deliberately open

None of these is unfinished work somebody forgot.

- Installed CPU and RSS savings are unmeasured. Three fixture pairs support
  parser-work reductions; active host load makes timing much noisier.
- Other owner-page callbacks retain attachments. The component measurement
  observes returned application state and excludes other actor-loop roots.
- A selected 96-byte JSON string still references its 1,048,679-byte input in
  the existing ownership probe. The scanner does not change binary ownership.
- The older idle-resource and Mermaid follow-ups remain in the linked previous
  handoffs. Their cross-browser state is unverified here.

## How to verify

From the repository root:

```sh
bash scripts/check.sh core
LOOM_TEST_TIMEOUT_SECONDS=180 bash scripts/test.sh client --match session_socket_test
LOOM_TEST_TIMEOUT_SECONDS=180 bash scripts/test.sh client --match ui_socket_test
LOOM_TEST_TIMEOUT_SECONDS=180 bash scripts/test.sh client --match ui_relay_test
bash scripts/lint.sh packages/core/src packages/client/src
make doc-check
```

Put `/opt/homebrew/bin` first on PATH for native gates. The Seatbelt PATH
fixture must select the installed Homebrew tool rather than a bundled `rg`
under `/Applications`, which is outside the jail's filesystem grants.

Use `scripts/json_decode_perf.sh` with separately built baseline/candidate
artifacts for performance comparisons, and its `equivalence` mode for complete
results. Run builds one at a time per checkout and measure timing without a
concurrent repository gate. The extended page regression intentionally fails
against the original callback capture. Its forced collection belongs only to
its owned fixture socket, never to a live daemon. See
[execution guidance](execution.md) for build, sandbox and exact-gate hazards.
