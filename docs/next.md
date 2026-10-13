# Current handoff

Baselined October 13, 2026 against `526fb44c4` on
`docs/archive-ui-captures`, based on `main` at
`dc70d25d42da531284225bf399f40f82e13539d4`. This edition covers the capture
cleanup and its CI repair. It records evidence from this checkout; earlier validation does not
establish the state of this branch. The project plan remains `docs/issue-plan.md`.

The previous edition still instructed the reader to publish the web browsing
branch. [PR #967](https://github.com/Roasbeef/loom/pull/967) merged on October 12,
2026 at `138fe472ae5897ef95182298ccf3ef9be019c53b`. Its implementation details,
validation and separate parent/child follow-up remain in the
[previous handoff](https://github.com/Roasbeef/loom/blob/dc70d25d42da531284225bf399f40f82e13539d4/docs/next.md).
Those historical test counts are not carried forward as cleanup validation.

## Where the tree is

The cleanup removes 782 historical terminal, web and website capture files,
representing 55,965,157 bytes. Tracked content falls from 99.53 MiB to 46.32 MiB
at the baseline above, including the manifest and repaired links. The
[capture archive](design-notes/capture-archive.md) names the original GitHub
snapshot and recovery commands; its SHA-256 manifest covers every deletion.

The useful design notes, review records, both terminal generators, tmux renderer,
README images and published website assets remain. The generators and renderer
retain their existing paths. Ignore rules cover generated exploration captures,
website QA screenshots, local session journals and nested scratch worktrees.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Preserve history for this PR.** Historical links name the exact original
commit. The archive guide explains that this removes captures from current
checkouts, while full-history clones retain their original objects.

**Keep published assets curated.** README and website assets remain tracked
under `docs/images/` and `site/public/img/`. Temporary captures belong outside
the checkout or in the ignored exploration directories.

## Verification boundary

The website gate passed 68 tests, its copy check and build. Both preserved
terminal generators ran from an empty scratch directory without the archived
captures; the tmux renderer produced a PNG. All 782 manifest entries matched
the original Git blobs and an independently exported tarball. A whole-tree
Markdown sweep verified 570 pinned archive destinations and found no remaining
local link to a deleted capture. Ignore checks covered capture/scratch paths
and useful docs, scripts and curated assets. Independent review found two
multiline-label image links; both were fixed and rechecked.

The initial network-enabled full gate on `8de625cfd` used the runner's
sequential default. The client suite exhausted its 1,200-second test budget
while the real TUI E2E test was running; the full lane exited 124 after no
reported assertion failures, and the final skip census passed. That attempt
is historical evidence of an aggregate timeout, not a whole-tree green claim.
The follow-up uses the existing `LOOM_TEST_PARALLEL=8` arrangement documented in
`docs/execution.md`, retaining the existing deadlines and `scripts/serial-tests`
isolation. No test assertion or process deadline changes.

Hosted Linux jobs at `526fb44c4` passed beneath an aggregate census failure:
`SKIP shipped deployment status: platform enforcement unavailable` had no
ordinary-Linux declaration. The CI repair declares that measured prerequisite
failure only in `.github/declared-skips-linux-gate`. The delegated jail also
runs the exact deployment-status fixture and rejects every skip with an empty
declaration set, so its live executor up/down assertions remain mandatory.
The new step joins the existing delegated cgroup and uses the shipment built
by that lane. Its log is included in the lane's artifacts.

Replaying the actual failed Linux log fails with the old declarations, passes
with the repair, and fails under the delegated lane's empty declarations.
Skip-reporting tests, YAML/shell checks and independent review passed. These
checks verify the repair's wiring; its actual Linux execution and all final
hosted results belong on [PR #976](https://github.com/Roasbeef/loom/pull/976).
Require the exact pushed head's hosted checks and genuine `signoff/linux`
status before calling it merge-ready. Neither a local pass nor an earlier
head's signoff substitutes for those results.

## What to do next

1. Review the cleanup and CI repair in PR #976. Exit: archive recovery, links
   and preservation checks remain green, hosted CI executes the delegated
   deployment-status fixture, and the exact pushed head has green hosted checks
   plus `signoff/linux`. Mark the PR ready after those checks; merging remains
   the owner's decision. The cleanup does not update a daemon.
2. Before considering a history rewrite or a new repository, export the
   checksummed captures to independent durable storage and update archive links.
   Exit: the archive is recoverable without the original Git objects. The
   current local tarball alone is not a replacement for that migration.
3. Measure a disposable rewritten clone before choosing a GitHub migration.
   Exit: actual clone-size savings and consequences for branches, tags and
   collaborators are known. Existing refs and history remain untouched here.

Full verification and sandbox hazards are documented in `docs/execution.md`.
