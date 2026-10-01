# Watcher consent and LSP reliability

This review covers the reliability branch based on `f84842d17`, on October 1,
2026. [Protocol 061](../../protocol-change/061-watch-and-lsp-reliability.md)
records the accepted authority and custody boundaries.

## Evidence and scope

The live session's durable records showed two session-lifetime watcher jobs
stopped by originating-operation abort after 28.6 and 54.6 seconds. A third
launch asked again because wall grants could not be remembered. The fix
separates session-job custody from durable initiating-operation attribution
and stores wall-zero consent only for the same strand, tool and canonical
arguments. Existing filesystem and network consent remains unchanged.

A raw-server probe resolved 51 symbols and a definition. Denying only its
sibling `core` dependency reproduced zero symbols, a null definition and an
error-level window message. This identifies an actual lease boundary failure;
it does not establish cache environment stripping or network as the cause.
The lease now intersects workspace reads with existing session authority.
Writes and server-named answer admission remain rooted at the chosen package.

## Independent review and triage

One independent adversarial pass found two reachable error-reporting gaps.
Both were verified against source and fixed.

| Finding | Correction | Regression |
|---|---|---|
| Settlement expiry discarded a retained server failure. | Deadline expiry returns the same `Unavailable` as normal settlement. | A versioned server reports a load error and never publishes the edited version. |
| A non-null empty hover or rename object falsely cleared the failure. | Recovery requires a nonempty result from the feature's typed decoder. | Empty string, list and markup hovers, malformed hover, and empty rename edits retain the error. |

The same reviewer checked the fixes. Call hierarchy has three method-specific
decoders behind one capability: nonempty replies reach the caller while
retaining a prior failure. A regression passes a valid prepare item as an
invalid incoming call and verifies the caller rejects it without erasing the
load error. Another typed semantic query can establish recovery.

The review found no further authority or custody issue. Reserved facts reject
model writes, approval and consent persist atomically, exact dispatch reads
cannot authorize changed actions, session custody still permits owner kill,
and workspace reads remain bounded by existing authority.

## Validation boundary

`make check-affected BASE=f84842d17bc3230c2a796f136d222b5179b5be28` exited
zero in 495 seconds on the final executable tree `0372d301b`. It built a fresh
helper, server, client and offline code-mode seed before running the suites.
All 2,613 client, 1,050 terminal, 91 conformance, 100 prompt, 176 session-view,
374 web-view, 170 LSP, 608 tools and 331 code-mode tests passed. Compilation
was warning-free, and the skip census found no undeclared skip. The static
gates passed with zero lint errors, 963 lint warnings and 163 documentation
warnings. The final documentation update was checked separately.

The client suite includes SQLite close/reopen consent, action isolation,
finite/session abort distinctions and explicit cleanup. After the review
fixes, all 38 focused native LSP jail tests and all four LSP session
end-to-end tests also passed. The code-mode session compiled and ran a real
`cap/lsp` program over a package with a sibling dependency, returning a
nonempty outline and `fn(String) -> String` hover. The Go fixture used real
`gopls`. No LSP prerequisite skip occurred.

The first aggregate run failed only its Go LSP case. The test invocation
set a temporary `GOCACHE`: the fixture granted that path but did not forward
the override to its server, whose default cache was therefore denied. The
same compiler and source passed all four LSP cases with only that override
removed, and the complete corrected gate above passed. No assertion, grant
or deadline was weakened.

Earlier focused checks used stock Gleam 1.19.0-rc2; the aggregate gate used
Loom's pinned patched 1.19.0-rc2 compiler. Native probes report this macOS
platform's existing resource and lifecycle limits. Hosted CI and a fresh
Linux signoff remain separate requirements; these local results do not claim
either, nor a live daemon upgrade.

The prompt version is `loom-default-11`, avoiding the version reserved by
concurrent PR #683; both PRs touch the prompt and tool description and need
their guidance retained when integrating.
