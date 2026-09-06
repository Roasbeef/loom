# Single-daemon and multiplayer review

**Date**: 2026-09-06 · **Status**: report complete, release acceptance open

## Scope and baseline

This read-only review covered the working tree on `client/instance-custody`,
including untracked daemon, storage-reader, shared-history and terminal-channel
modules. The pinned base was `2c8405f3319be04c51110766e8509da4eeefeead`;
the current commit was `c32c1f44a680d6aba2c70ca8420233391f902b88`. The
implementation was uncommitted, so a commit-only diff would not reproduce
the reviewed scope. Dependency checkouts and build artifacts were excluded.

The review traced request admission and final event delivery, session and
domain cleanup custody, shared-history authorization, and terminal replacement.
It also inspected the joined provider-drain and detached-schedule tests for
false success, plus nearby instances of stale-incarnation routing,
timeout-as-drain success and automatic mutation resend.

## Findings

No new actionable finding was reported in the inspected paths.

Request admission and final delivery recheck attachment authority. Observer
mutations are refused before dispatch. Session and domain slots remain
occupied through stopping or failed cleanup, and the retained original
retirement witness controls their release.

Shared history checks current domain membership before exact-entry publication
and before search ranking. Terminal replacement preserves the original session
identity when reporting an uncertain submission. A queued, unsent mutation is
released only after snapshot completion and presentation validation.

The joined containment test checks peer execution, writer exclusion and the
original retirement witnesses. The schedule test checks durable occurrence
identity and inactivity while Saved across restart. The review found no
concrete simplification that justified changing those tests.

## Limits

This was source review, not a test run or release sign-off. Known SQLite
descriptor retention and dependency adoption were disclosed, as were missing
combined/platform gates. The separate private-query repair received its own
independent review, with no actionable findings; its evidence and adoption
constraint are in [ADR-002](../adr/002-sqlite-binding.md).

The unfinished filesystem dispatcher and restricted native PrivateScratch
work were outside this review. No workspace-overlap confidentiality claim
follows from this report. See [the triage](single-daemon-final-triage.md) for
the remaining acceptance work.
