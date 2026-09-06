# ADR-011: bound websocket frames in a fork of mist and gramps

**Status**: accepted · **Date**: 2026-09-05 · **Supersedes**: nothing ·
**Spec ref**: Part 1.6 client protocol, `protocol-change/015`

## The question

`docs/review/m3-gateway.md` L-1 recorded that the daemon's websocket
listener accepts an unbounded frame: the handler passed each `mist.Text`
straight to the gateway, "the Gleam side sets no read limit and I found no
max-frame configuration in the vendored mist websocket internals", so one
authenticated client could send a multi-gigabyte text frame that mist
assembles in memory before `json.parse` ever runs. The review noted the
asymmetry that the Go client caps its peer at 16 MiB while the server caps
nobody.

Protocol-change/015 then made the bound normative rather than merely
desirable. It sets 64 KiB for control and observer connections and 32 MiB
for operator connections, and it says why chunking is not a substitute:
"admission must also bound aggregate connection and parser memory before
enabling the default. Chunking alone is not a transport memory bound."
Loom cannot honour that clause with a library that reassembles a frame of
any size before the handler sees it.

## Decision

Loom depends on a fork of both libraries, taken at exact git revisions
rather than at a version range:

- `packages/client/gleam.toml` requires
  `mist = { git = "https://github.com/Roasbeef/mist.git", ref =
  "65b29375ecefc9a5d58bf4190a2eee41d7dd1db5" }`. The fork adds
  `mist.websocket_with_options` and
  `WebsocketOptions{max_frame_bytes, max_message_bytes, compression}`
  with `CompressionDisabled`, and threads an optional decoder through
  `mist/internal/websocket`. `mist.websocket` keeps its old behaviour by
  delegating to the new function.
- `gramps a37a8ae3fe2531375b49b865c155eb2987d4d22a` arrives transitively,
  because the mist fork repoints its own `gramps` requirement. It appears
  in no Loom `gleam.toml`, only in the resolved `manifest.toml` of
  `client` and `conformance`. The fork adds one file,
  `src/gramps/websocket/decoder.gleam`, and its test; no existing module
  is touched.

The daemon uses the option at both upgrade sites:
`client/daemon/server.gleam:229` passes `protocol.max_bytes` for the
control endpoint, and `client/daemon/session_socket.gleam:47` passes
`root.message_limit(class)`, which is 65,536 bytes for a control or
observer connection and 33,554,432 for an operator.

Both changes are upstream as pull requests: rawhat/mist#92
("websocket: add opt-in bounded upgrades") and rawhat/gramps#11
("websocket: add bounded incremental decoding"). Both were open at the
time of writing.

## Why

The three candidates were waiting for upstream, bounding the frame inside
Loom's own handler, and forking.

Waiting was rejected because the bound is a released protocol clause, not
a nice-to-have: 015 is accepted and the daemon ships with it, so the
listener would run unbounded for however long review takes on someone
else's repository.

Bounding inside Loom's handler cannot work, and this is the load-bearing
point. The exhaustion happens *before* the handler runs. mist reassembles
a fragmented message and hands the handler one complete `Text` value, so
by the time Loom could measure the frame it has already been allocated.
A ceiling has to live where the frames are read, which is the library.

Forking was therefore the only option that puts the check in the right
place, and it was kept as small as a fork can be: one new module in
gramps, one new public function and one option record in mist, with the
existing entry point preserved by delegation. Nothing was rewritten, so
rebasing onto a future upstream release is a merge rather than a
re-derivation.

## Consequences

The release carries code that is not on hex. `make release` and `make
dist` build from `packages/client`'s shipment, so the forked framing
library is inside the artifact people download, and reproducing a build
needs both git remotes reachable rather than only the hex mirror.

Loom owns the maintenance until the two pull requests land. Every mist or
gramps upgrade is a rebase of the fork first, and the pinned revisions
must be moved by hand because a git dependency has no version range to
resolve.

The tree now holds two different codebases under one name and version.
Both forks keep their upstream version numbers, `gramps 6.0.1` and `mist
6.0.3`, while carrying different code, and `gramps 6.0.1` resolves from
hex in `packages/host/manifest.toml` and `packages/tui/manifest.toml` but
from git in `packages/client/manifest.toml` and
`packages/conformance/manifest.toml`. This is harmless today because the
client shipment and the TUI shipment are separate artifacts with separate
application closures, so no single build ever has to choose between the
two. It stops being harmless the moment anything merges those closures,
and the fix at that point is to make the fork's version distinct rather
than to reason about which copy won.

The git `gramps` entry also carries no `otp_app = "gramps"` field where
the hex entry does. `make release-smoke` boots the packaged server with
no `erl` on `PATH`, so it is the gate that would catch a missing
application in the release closure.

When the upstream pull requests merge, this ADR gets an addendum rather
than an edit: the decision to fork was real and its cost was paid, and a
later reader looking at a hex-only `gleam.toml` should still be able to
find out why the fork existed.
