# Current handoff

This edition records the October 7, 2026 nightly-update work on
`update/nightly`, based on main `7091d5a42` and implementation `25da5f13c`.
Work is isolated in `.worktrees/update-nightly`; the original checkout's
unrelated files were preserved. Rewrite this handoff after the next body of
work. Earlier runtime profiling and its PR milestones were not revalidated
here, so the previous edition's claims about them are not current signoff.

## Where the tree is

`loom update --nightly` captures GitHub main once and intersects its recent
history with published immutable `commit-<full-sha>` releases. An unpublished
head leaves its published ancestor selectable. Drafts and off-main releases
cannot select a build. The existing manifest, archive, installation and restart
path remains the authority after selection. No source is compiled by this flag.

The new `Publish nightly` workflow runs daily at 08:23 UTC and supports manual
runs from main. It reuses the native release pipeline: two Linux x86_64 builders
and two macOS arm64 builders, release smokes, byte comparison and manifest
binding precede publication. Nightlies are prereleases with `--latest=false`;
version-tag releases still create drafts. Existing published nightlies are
immutable and skipped. A draft left by interrupted publication fails explicitly
for operator inspection instead of silently reporting success.

The previous tree could select an explicit published commit but had no nightly
selector or automatic commit publisher. Both now exist on this branch. There
are still no published GitHub releases: the live native `--nightly --check`
request reached GitHub and returned `no published nightly commit builds found`.
The scheduled workflow has not run and cannot be certified by shell fixtures.

## Verification

`make check-tui` returned exit 0 with all 1,271 tests passing. Its nine nightly
resolver tests cover unpublished heads, draft and off-main exclusion,
pagination with a captured main SHA, manifest mismatch, selector conflicts and
bounded searches. A draft-admission mutation failed five resolver tests and was
restored before the complete TUI gate.

All seven local updater installation/signature fixtures passed, including
nightly selection, installation and tamper rejection. The signature fixture
required permission for its temporary GPG agent outside the sandbox. Nine
release-automation tests and three workflow-shell tests passed. Actionlint,
format checking and the documentation gate passed; TUI lint had zero errors.
The independent review's interrupted-publication finding was fixed and the
reviewer confirmed the delta.

The full `make check` returned exit 2 at its aggregate 20-second Python deadline
(runner 124), before package gates. The focused
`DriverSessionTest.test_a_red_run_brings_back_why` returned exit 1 on both this
branch and pristine main `7091d5a42`: its expected client-lane log text was
absent. This is not a complete green gate or Linux signoff. Hosted paired
native builds, publication and a download of an actually published nightly
remain unverified. No installed daemon or client was replaced by this work.

## Rulings already made

Nightly selection is explicit and exclusive with tags or commits. It cannot
use local-directory or mirror overrides. Stable default selection is unchanged.
Both release and main-history windows contain at most 300 entries; no match or
API failure stops before installation and never selects the stable channel.
Existing signature policy and immutable installation behavior remain in force.

The publisher retains package versions for commit-addressed builds and binds
the full source SHA and platform. It never overwrites published assets or
silently resumes an interrupted draft. The current builders cover Linux
x86_64 and macOS arm64; the updater's other native platforms report a missing
manifest until builders exist for them.

## What to do next

1. Complete the new PR's hosted checks and required Linux signoff on its exact
   head. Exit: the required checks and signoff are green for that SHA.
2. Resolve the existing signoff fixture and aggregate Python-runner limitation
   separately if a complete local gate is required. Exit: the baseline failure
   passes without removing tests or weakening their deadlines.
3. After merge, run the nightly workflow from main and verify a real
   `loom update --nightly --check`, then installation in an isolated prefix.
   Exit: both platforms publish matching immutable assets, selection reports the
   expected main SHA, and the installed daemon reports that SHA after restart.
