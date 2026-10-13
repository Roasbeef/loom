# Current handoff

Baselined October 13, 2026 against `b815734f3` on
`docs/archive-ui-captures`, based on `main` at
`dc70d25d42da531284225bf399f40f82e13539d4`. This edition covers the capture
cleanup. It records evidence from this checkout; earlier validation does not
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

The affected selector chooses the full gate because it does not classify
`site/screenshots/`. Static gates passed. The first full-gate preparation failed
to fetch a dependency from `repo.hex.pm`; a network-enabled rerun is in progress.
Record its final result and the exact tested head on the PR. Hosted CI at the
upstream baseline has both successful and failed runs; no project-wide green
claim follows from this cleanup.

## What to do next

1. Publish the cleanup PR and inspect its exact-head checks. Exit: archive
   recovery, links and preservation checks pass, and remaining gate failures
   are explicitly accounted for. The PR does not merge or update a daemon.
2. Before considering a history rewrite or a new repository, export the
   checksummed captures to independent durable storage and update archive links.
   Exit: the archive is recoverable without the original Git objects. The
   current local tarball alone is not a replacement for that migration.
3. Measure a disposable rewritten clone before choosing a GitHub migration.
   Exit: actual clone-size savings and consequences for branches, tags and
   collaborators are known. Existing refs and history remain untouched here.

Full verification and sandbox hazards are documented in `docs/execution.md`.
