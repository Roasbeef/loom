# Loom UX and diagnostics continuation — September 15

This is an in-progress local handoff. It supersedes the September 14 status table; it does not declare the overall request complete. Source changes remain in isolated worktrees, and the user daemon has not been restarted or replaced.

## Verified work

The transcript renderer (#401/#402), cancellation/model selection (#403), help (#406/#410), shorter compaction notice (#407), history prefetch (#408), profiling tools (#409), hook capture repair (#411), session names (#412), terminal EOF handling (#413 and etui #2), closure capture lint (#414), and streamed-response handoff (#416) are merged. The latest #416 head was 48b5dda1, merged as 4d262bd4 after hosted CI and Linux signoff passed. The audit did not find a final-head Linux signoff status for #412, which another actor merged.

The stream fix retains bounded fragments until the exact reserved response entry arrives. A deterministic regression failed on the old implementation, then passed for normal completion, preview-only attachment, stale samples, late fragments, and unrelated equal text. A 20,000-delta fixture remained within the existing memory bound. This is evidence for the completion jump fix, not a claim to have re-recorded the user's live model session.

## Remaining reviewed changes

| PR | Pushed head | Evidence and remaining gate |
|---|---|---|
| #417 persistent profiling configuration | 30f6f103 | Reviewed; paired release, smoke, and isolated install passed. Hosted CI is finishing. Required remote Linux signoff remains blocked on approval. |
| #418 archive and restore | 4845862c | Storage 104, client 1,802, TUI 490 tests passed, with lint and documentation checks. Actual WebSocket control and SQLite history preservation are covered. Hosted CI is running; required remote Linux signoff remains blocked on approval. |
| #420 parsed-terminal cleanup | 182a5806 | Provider 213, client 1,800, runtime 135 tests passed, with lint and documentation checks. A real adapter fixture reproduces terminal completion entering the cancellation grace; the fix awaits original-owner retirement proof. Hosted CI is running; required remote Linux signoff remains blocked on approval. |

The combined release in `.worktrees/profile-release-integration` is based on 4d262bd4 with those three exact heads. Merges were clean. Documentation checks, both bundled releases, and release smoke passed. The staged paired install is `build/profile-install` inside that worktree. A temporary example catalogue with `[daemon] profile = true` produced the profiling activation marker; its isolated process was terminated and reaped without a model call or session creation. This candidate is local and has not replaced the user's installation. Local smoke retains its documented kernel limitations and does not replace Linux signoff.

## Measurements and limits

The existing daemon PID 98740 was measured at roughly 5 GiB physical footprint. It predates the newer installation files and has no named Erlang distribution endpoint, so native sampling cannot attribute its process heaps. No forced collection or restart was performed. The earlier model-backed memory comparison was 1,511.755 MiB baseline versus 695.782 MiB with only the hook-wrapper change. The final three-module repair still lacks a repeated model-backed comparison.

With the paired isolated profiling install, fresh daemon plus empty picker startup took 0.94–1.10 seconds. A read-only picker in the actual Wavelength workspace against the existing daemon took 0.44–0.54 seconds. No provider request or session activation was involved. These samples did not reproduce the several-second symptom; opening a large saved conversation remains unmeasured. Full observations and raw artifact paths are in `/private/tmp/loom-startup-observations.md`.

Kimi K3 supports low/high/max reasoning effort; Loom's off selection omits the field and does not turn off K3 reasoning. The user-approved model configuration now selects high. The approved model-created wake policy is configured for new engines and wake-enabled registrations; existing steer-only schedules were not silently converted.

Linux jail `/tmp` is private scratch tmpfs. The macOS jail grants its private scratch directory but does not remap arbitrary absolute `/tmp` paths or automatically set TMPDIR.

## Pending authorization and separate work

Automatic approval review rejected the new remote signoff action because it transfers the checkout to obelisk, uses the repository's privileged Linux container, and may publish the resulting GitHub status. No retry has been made. Obtain approval before starting signoff for #417/#418/#420; do not substitute local checks or manually publish success.

A separate pending question asks whether to configure the existing host secret resolver to supply only the saved Litbucket token to new jailed sessions. No Keychain credential was read, and no jail permission was widened. The completed GitHub login cannot persist its credential through the jailed macOS Keychain boundary.

The final model-backed memory experiment previously hit an approval rejection for real paid provider traffic. Read-only profiling permission does not authorize that experiment or a user daemon restart.

The separately requested Terra rate-limit/partial-tool-call task returned only queued client ID `client-new-thread:11545787-193f-4385-8a98-4c031c6f2f86`; execution is unconfirmed. Do not create a duplicate. Earlier Substrate #97 validation and installed watcher details remain in the September 14 handoff; its unrelated frontend baseline failure remains explicit.
