# Current handoff

This file describes the current feature and its remaining acceptance gates.
Rewrite it after a body of work, checking the tree and gate results rather than
carrying forward a preceding edition's claims.

This edition is baselined against `d7d2d5a9` on October 6, 2026
(America/Los_Angeles), on `codex/config-edit-approval`. Its parent is hot-reload
PR #901 at `a1818b81a`; #901 is open and ready for review. The feature checkout
is isolated, and the original checkout's unrelated files remain preserved.
Neither feature has been merged or installed by this work.

## Where the tree is

| Body of work | Current state |
| --- | --- |
| Explicit configuration hot reload, #901 | Parent source is independently reviewed and its exact head has privileged Linux signoff. |
| Approved configuration edits | Default native tool and host writer are wired through durable approval and immediate reload. |
| Terminal and web approval UI | Both show the selected path, base digest, and complete literal edit, with one-time Approve edit consent. |
| Final publication and signoff | Feature source is committed; final full-tree and privileged Linux gates remain to be completed on its published head. |

The previous edition said #901 was a draft and Linux signoff had not run.
Those statements are now false: the parent head `a1818b81a` passed all six
Linux lanes, release update verification and skip census, and the PR is ready.
That result covers the parent, not the configuration-edit commits in this branch.
Older CPU and release work has not been reverified here.

The new `loom_config` tool reads only the explicitly selected real configuration
path and returns its document and digest. An edit replaces one unique literal
match, or appends text when the old string is empty. Complete arguments fit the
2 KiB durable preview. The host validates the complete resulting configuration
before asking and again after approval under the existing kernel lock.

Approval retains the original action digest and call scope and is consumed once.
It grants no sandbox write permission and cannot be remembered. The host rejects
changed base bytes, saves privately and atomically, and requests immediate refresh.
Supported settings publish for the next operation; in-flight operations retain
their captured revision. Boot-owned changes return restart guidance. If refresh
fails after saving, the result explicitly reports that the save occurred.

Assembly establishes a regular sibling lock before publishing jail policy. An
unavailable lock disables edits without blocking ordinary tools or reading the
configuration. Approval budgets distinguish validated base revisions, so later
edits are separate questions while retries against one revision remain bounded.

## What to do next

1. Finish the full-tree gates; the independent recheck clears all three fixes.
   **Exit:** no unresolved reachable finding; required static and test gates pass.
2. Publish the feature PR stacked on **#901** while its dependency remains open.
   **Exit:** the complete source, generated stylesheet and documentation are on
   the remote, and the PR explains the dependency and validation limits.
3. Run privileged Linux signoff on that exact published head and inspect hosted
   CI. **Exit:** all required lanes and skip census pass before marking ready.
   Merging and installation require their own user instruction.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Explicit selection defines configuration authority.** Workspace discovery
cannot authorize host writes. See [configuration edit consent](architecture/approvals.md#configuration-edit-consent).

**Consent binds the whole edit.** Keep the complete canonical action within the
preview, retain call scope, and consume an empty-grant resume once. The same
architecture section records this boundary and the one-time UI behavior.

**Reload preserves operation pins.** Publication affects supported settings at
the next operation. Background service graphs and executable tools remain
boot-owned, as described in [live file edits](architecture/models.md#live-file-edits).

## Deliberately open

- External editors do not share Loom's lock. The final digest check is optimistic
  against a concurrent non-Loom save; this limit is explicit in the approval design.
- The web E2E uses the repository's shipped Lustre component, actual patch stream,
  and click dispatch. It does not establish browser layout in a real browser.
- Cancellation and crash behavior is source-traced through existing custody and
  Never replay semantics; this feature does not add fault-injection coverage.

None of these is unfinished work somebody forgot.

## How to verify

Six `tui_approval_effect_test` regressions pass against production daemon wiring:
ordinary native approval, approved config edit, denied edit, stale-base refusal,
web approval, and four successive edits on one strand. The last regression runs
an unrelated jailed command before the first edit with the configuration outside
the workspace, then uses real HTTP provider requests for subsequent iterations.
Five host-file tests and four native-tool tests pass. Weakening the argument-size
guard makes the size-specific regression fail; restoring it returns the suite
to green. Shared projection and web card tests pass.

The independent review identified the missing-lock jail failure, a three-edit
approval budget, and a duplicate-field false-pass in the size test. All three
have source fixes and focused regressions; the bounded independent recheck
clears all three, including their immediate same-shape variants.
Formatting, affected-package lint and documentation coverage, mirrors and
citations pass. Existing lint and documentation warnings remain visible.

Run `make check` for the complete native gate. The earlier attempt passed through
client and TUI before Hex rate limiting stopped conformance preparation; it is
an incomplete run. A final retry is in progress. Run `scripts/signoff_remote.sh`
with the operator's Linux host for exact-head privileged signoff after pushing.
Do not carry parent #901's green result onto this feature head.

**Pin Gleam 1.19 for this checkout.** The older formatter rewrites unrelated
source layout. **Capture each gate's own exit status.** A tail command's status
is not the gate's status. See [execution](execution.md) for the remaining hazards.
