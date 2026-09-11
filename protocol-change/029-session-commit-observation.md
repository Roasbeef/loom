# Commits since the session started

Status: proposed implementation of the requested committed-changes view.
Extends the optional worktree observation in Part 1.6 and protocol 025.

## Problem

A clean worktree hides changes which the session has already committed. Recent
commit dates cannot establish the session's starting revision, and a restarted
session must not silently move its baseline to the current HEAD.

## Decision

Before starting the runtime on first activation, the host observes HEAD through
the existing read-only broker and records it under reserved fact
`session/git-start`. The record binds the session ID and workspace. An unborn
repository records an empty baseline. The host persists an unavailable result
when Git cannot be observed; later activation never substitutes a new baseline.
An older session with an existing pinned prompt but no baseline remains explicitly
unavailable. Forked records belonging to another session are unavailable too.
The single boot owner writes before the runtime writer starts, using an absence
expectation. Model-facing fact writes cannot alter the reserved `session/` keys.

The ready worktree board gains a `committed` object with `message`, `patch`, and
`extent`. Older boards omit it; newer clients show an unavailable notice. The
patch contains at most 24 commits reachable from captured HEAD but not from the
starting revision, scoped to the attached workspace. It uses ordinary commit
headers and unified patches. Merge patches compare the first parent, including
bytes introduced while resolving the merge. The display labels the 24-commit bound even when
output fits. A starting commit which is no longer an ancestor produces an
unavailable notice instead of claiming unrelated history belongs to the session.
These commits are repository changes since the baseline, not proof of authorship
by the agent. Other processes can commit to the same branch.

History shares protocol 025's deadline, read authority, aggregate output budget,
and encoded board ceiling. Its patch has a 4 KiB raw limit, so JSON escaping
cannot exhaust the board before file fitting. Output truncation is explicit.
History failures are labelled unavailable; they never become an empty committed
result. The working-tree file census retains its existing meaning.

## Cost and alternatives

This adds a reserved durable fact and bounded Git probes during first activation
and requested refresh. No new actor, dependency, filesystem grant, command input,
automatic polling, or repository mutation is introduced. Timestamp filtering and
capturing HEAD on the first diff request were rejected because both can omit
commits already made by the session.
