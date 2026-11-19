# protocol-change/119 — `validate` refuses a `..` segment in a root or the scratch path

**Status**: ACCEPTED 2026-11-19; the owner delegated the call · **Affects**:
Part 1.4 `SandboxPolicyV1` (which documents are valid, not their shape) and
`broker/policy.PolicyError` (one new variant) · **Raised by**: the review of
[117](117-broker-tunnel.md), which found that the meet compares roots as
text · **Implemented**: yes, `broker` (plus the exhaustive `PolicyError`
matches in `tools` and `client`) · **Closes**: loom #1276

## Problem

`policy.covers` is a text prefix compared by path component, and
`policy.meet` keeps a root of one side when a root of the other covers it.
`validate` checks only that a root is absolute (`refuse_uncanonical_mounts`
covers mounts alone). So a readable or writable root spelled `/w/..` is kept
under a plane root `/w`: the text `/w/..` has `/w` as a component prefix. The
helper cleans every root lexically when it builds the jail, and `/w/..` becomes
`/`. The call then holds the whole filesystem where the plane granted one
directory.

[117](117-broker-tunnel.md) first met this at the tunnel, where the root comes
from bytes an executor sent. `client/remote/tunnel_paths.plain_spec` refuses it
there, with a reason, before the call is cleared. Every dispatch, tunnelled or
not, passes `broker.validate` on the composed policy
(`broker/broker.gleam`), so one check in `validate` closes the shape for every
caller, including those that never touch the tunnel.

The scratch path has the same shape. `refuse_scratch_root` matched the literal
`"/"` only, so `ScratchPath("/x/..")`, `ScratchPath("//")` and
`ScratchPath("/.")` cleaned to `/` and reached the whole-filesystem Landlock
grant of issue #59 (Landlock has no deny rules to carve a hole back out).
Whether a scratch path can come from uncontrolled input is not established; the
check costs a few lines.

## What was considered

**Refuse every unplain path, as `tunnel_paths.plain` does.** `.`, `//` and a
trailing slash are all lexical noise, and one rule is simpler to state. Rejected
because none of them widens. `/w/.` and `/w/` clean to `/w`, and `//w` is not
covered by `/w` as text, so the meet drops it. Honest unplain paths exist: a
daemon whose `HOME` is `/` produces `//.loom/vm`
(`client/remote/tunnel_paths.gleam` records it). Refusing them would fail honest
dispatches to prevent nothing. `tunnel_paths.plain_spec` stays strict because it
guards a trust boundary and refuses early with a reason; it is the first line,
and `validate` is the second.

**Canonicalize in `meet`.** Clean each root before comparing it. Rejected: it
makes the Gleam meet a second implementation of the helper's cleaning, which
must agree with it byte for byte on both platforms, where a refusal needs to
know only one segment.

**Judge the text with `string.split`.** Rejected for the reason `tunnel_paths`
gives. A split matches grapheme clusters, and a slash followed by a combining
mark is one cluster, so a `..` segment before it would pass as another segment
while the helper cleans it away. The walk reads bytes.

**Change the decoders.** Make the helper's decoder refuse the same document.
Not done: the document is carried out identically on both platforms, so there
is no disagreement to remove, and the fault is in the Gleam meet. The helper
cleans whatever it is sent.

**Refuse only the roots.** Leaves the scratch variant open. The scratch is
included.

## Decision

`broker/policy.validate` returns `RootPathParentSegment(path:)` for a readable
root, a writable root or a host-path scratch that has a segment equal to `..`,
judged by bytes. Nothing else about those paths is newly refused. In the same
place `refuse_scratch_root` now refuses a scratch path that has no segment other
than the empty segment or `.`, so `/`, `//` and `/.` are the root
(`ScratchIsRoot`).

The wire shape is unchanged, so `v` stays 2: no key is added, removed or made
required. `PolicyError` gains a variant, which crosses the executor wire in
`untrusted_codec` as `root_path_parent_segment`; the variant is added to its
encoder and decoder and to the two descriptions that render a `PolicyError`
(`tools/tool.policy_error_text` and `client/workspace_policy.policy_fault_text`).

`tunnel_paths.plain_spec` and its code are unchanged. Its module doc now says
that `validate` is the second line.

## What it costs

A policy that validated yesterday can be refused today when a root or scratch
spells `..`. The tree was searched for one (Gleam sources and tests, the Go
helper and configuration docs) and none builds a root or scratch with `..` on
purpose. The configuration parsers already refuse it for workspace roots and
for a spawner's `writable_roots` and `readable_roots`, so a hand-written
configuration is stopped earlier and in better words. A caller that composes a
root from a model's `permissions.readable_roots` or `writable_roots` argument is
not shown to canonicalize first; such a call now settles in band as a policy
refusal naming the path, where before it reached the jail.

The check is lexical, and it is a limit. A root that is a symlink under a
writable workspace is the helper's concern, because `broker` cannot stat. That
the helper cleans roots is taken from the issue and
`packages/sandbox/CLAUDE.md`, not re-read in Go for this change. A root that
reaches outside its plane through a symlink is outside what `validate` can say.
