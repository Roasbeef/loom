# Current handoff

Baselined October 14, 2026 against main
`3ee679ca7b7a36bb2e518f4494214de364217e7b`. PR #985's login implementation
is rebased without source changes from reviewed `2c7a99c61`.
Main includes #972's register decoding, #979's Responses diagnostics and
deployment CI enforcement, #982's per-strand timing, and #976's capture archive
and CI repair. The cleanup manifest, recovery commands and upstream timing
rulings remain in the [main handoff](https://github.com/Roasbeef/loom/blob/3ee679ca7b7a36bb2e518f4494214de364217e7b/docs/next.md).
Its pending-validation wording describes that historical branch. The project
plan remains `docs/issue-plan.md`. No installed daemon was changed by this work.

## Confirmed login failure

A fresh native `personal` sign-in failed the JWT issued-at check:
`invalid_identity_issued_in_future`. This was reproduced with diagnostic labels
and the existing zero-second clock tolerance. With a five-second tolerance,
a second fresh browser sign-in succeeded and saved the grant normally.
The host's HTTP Date comparison suggested a small clock offset; the explicit
JWT refusal, rather than that approximate measurement, identifies the check.
A displayed timezone change does not change UTC JWT timestamps.

The client now tolerates five seconds for issued-at, not-before and expiry,
matching OpenAI's published ID-token verification example. Larger offsets remain
refused. Signature, algorithm, issuer, audience, authorized party, nonce and
subject validation remain enforced. Fixed diagnostic codes identify refused
checks without reflecting tokens, claims, key identifiers or parser messages.
Unknown signing keys retain the existing bounded key-set refetch path.

## Verification boundary

All 34 focused Codex tests passed. All eight identity tests passed under both
UTC and America/New_York. Real RSA-signed boundary tests cover browser and refresh
issued-at validation, not-before and expiry. A zero-skew control failed the new
clock test as expected; restoring five seconds passed. The live patched browser
login succeeded. At prior head `be753e0c67c027680ec3acf0164e97ec1911aa82`,
the affected gate passed in 571 seconds and full Linux signoff passed in 1,647
seconds. Independent review found no actionable issues. Hosted aggregate gates
passed, but the macOS advisory raw log contained a native-launcher readiness
assertion failure and later reached the separate client 1,200-second deadline.
Five focused unchanged local controls passed; one hosted advisory retry was
requested. The original assertion failure is retained as evidence rather than
counted as a completed advisory suite.

The rebase preserves main's source, CI and capture cleanup. Current-head
integration review, hosted CI and Linux signoff must finish before merge;
prior-head validation is historical evidence.

The successful login updates the saved profile, which the daemon rereads for
operations. The installed daemon does not yet contain this clock-policy fix;
installing a future reviewed release and restarting remains a separate operator
action. This work has not installed or restarted the daemon.

## Separate provider failure

Model discovery initially returned HTTP 520 from Cloudflare after successful
login. The owner subsequently reported progress with a VPN. A later Responses
attempt failed with `event_unsupported`, `event=unknown`, `last_seq=5` and
`bytes=316248`. Saved history identifies the rejected dispatch check but does
not retain the unknown event name. This evidence cannot establish which event
was sent or whether it was valid. The byte count is cumulative delivered chunks,
not the offending event's size. No provider acceptance rule has been changed. A read-only context-only replay
settled successfully; a closer replay with 23 production builtin tool definitions
reproduced an unsupported event at sequence 19. Five extension definitions and
dynamic MCP surfaces were omitted, so it was not a byte-exact request replay.
No tool or hook ran, and no audit session was changed. The owner subsequently
reported that the real session was responding again without a provider patch;
that recovery does not identify the earlier unknown event.

## Next steps

1. Complete rebased-head integration review, required hosted checks and Linux
   signoff, then merge #985 under the owner's explicit authorization.
2. Keep the separate Fast-mode PR #987 and its CI investigation independent.
3. Identify the reproduced unsupported Responses event with fixed allowlisted
   structural diagnostics before changing acceptance. Preserve the distinction
   between observed recovery and a demonstrated fix.
