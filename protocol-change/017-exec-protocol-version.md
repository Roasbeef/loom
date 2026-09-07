# protocol-change/017 — version the exec channel's vocabulary

**Status**: ACCEPTED 2026-09-06 · **Affects**: Part 1.4 `hello.proto` ·
**Raised by**: issue #64, after the #61 incident · **Implemented**:
broker + sandbox

## Problem

Part 1.4 pinned `hello` as carrying `proto: 1` and said a mismatch closes
the channel. Two accepted changes since then altered what the exec helper
speaks, `006` by making `exec_exit.cancelled` required and `014` by
adding the `shutdown` kind, and neither moved the number, because the one
constant that filled `proto` also stamped `v` on every frame envelope,
including the capability socket's, and bumping it would have refused
every satellite. So a helper built before `006` still passed the
handshake and died later on an unnamed decode fault, which is the hour
issue #61 lost.

## Decision

The single constant splits in two. `v` stays the envelope version, `1`,
and moves only when the container shape does. `hello.proto` becomes the
exec channel's body version, `broker/framing.exec_protocol_version` and
`sandbox/internal/framing.ExecProtocolVersion`, and is **3**: 1 as first
frozen, 2 for `006`, 3 for `014`. `012`'s hook pair crosses only the
capability socket, which carries no `hello`, and is not counted. A
mismatch is `exec.ProtocolVersionMismatch(helper:, broker:)`, rendered
with both numbers and which side to rebuild.

The standing rule: a protocol change that adds, removes, or
makes-required a key on a frame the exec helper sends or receives, or
adds a kind to that channel, bumps `proto` on both sides in the same
commit. The constants' doc comments carry the mapping, and `broker`'s
`protocol_version_test` reads the Go source so the two literals cannot
drift. The full argument, including why the envelope version is held
still so a stale helper's `hello` can still be read, is the addendum in
[`006`](006-exec-exit-cancelled.md); this file exists so the rule has a
number of its own where the next reader looks for one.

## What it costs

Every helper built before this change now fails its handshake as
`helper: 1, broker: 3` and asks for `make binaries`, which is the failure
`006`'s helpers should always have had. The mtime comparison in
`codemode_live_test.check_helper_current` stays, because it answers the
narrower question the version cannot: whether a helper at the same
version was built from the sources beside it.
