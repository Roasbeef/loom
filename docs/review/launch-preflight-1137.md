# TLS launch preflight: review and evidence (issue #1137)

Status: implementation and final verification in progress on base `781616bdb`.
The owner authorized code and isolated tests, not a live daemon upgrade. The
peer compatibility parent is draft PR #1145; no merge is authorized here.

## Source and review

The private `launch.json` contains eight bounded fields, tied to the native
fence and authenticated epoch. Startup captures canonical config and VM options
before reading them and omits metadata if the options alias switches or the
original launch cannot be reproduced. Unsupported CLI choices and records that
cannot fit the schema do not block serving; real write failures do. The staged
exit-only command shares complete daemon decoders and native TLS validation.
Ledger inspection replays complete records and checks authority, members and
references without repair. Only owning startup repairs a torn tail.

One independent adversarial review found four reachable issues: lost CLI
overrides, missing ledger validation, profiling/config absence divergence, and
size limits preventing Ready. All four were fixed. The same reader's scoped
recheck found no new actionable issue. The replacement rechecks the original
fence and authenticated epoch before shutdown, waits for departure, and requires
a new authenticated epoch and expected build.

## Evidence and limits

Focused worker tests covered overrides, size, ledger and alias behavior, plus
lint and TUI/launcher tests. The primary host, ledger, store and bootstrap tests
passed. A full distribution run exposed three overbroad new test expectations:
read-only validation can succeed when runtime startup later reports
`EpmdUnavailable` or `StartFailed`. The primary corrected those new assertions
while preserving original startup assertions. The rerun passes all 38 matched
distribution tests, including separate ledger distribution fixtures; all three
TUI lifecycle tests pass. Together with host (2), ledger (20), store (12) and
bootstrap (8), the primary focused set passes 83 tests without skips.

Three semantic mutants remove CLI admission, propagate unrepresentable metadata
failure, or repair a ledger during inspection. Each fails its intended production
witness; every source is restored byte-for-byte and all three restored tests pass.

The first shipped smoke exposed a malformed mode-0600 private key accepted before
retiring the original daemon. Shared native credential validation fixed that
witness. The expanded primary `make update-release-smoke` passes at source commit
`a1acc3266af1dbd56b07f8d32389ac398c04480c` in 140.69 seconds, under the unchanged
300-second deadline. Both self-contained artifacts embed that exact commit.
It verifies two installed bundled/slim local replacements, explicit config
absence beside a profiling default, and a valid TLS replacement with a new
authenticated epoch and expected build. Changed local profiling, stale native
or epoch metadata, missing/malformed metadata, changed config, missing/stale
options, missing/corrupt/mismatched keys, cookie and HOME all refuse before
retirement. Missing and corrupt ledgers use regenerated valid ledger options,
so a credential-only preflight would pass; both refuse while the original
remains authenticated. Corrupt ledger bytes remain unchanged.

The release smoke pauses actual local and TLS staged launchers on a config FIFO
after OTP dependency startup. It observes child and descendant Internet sockets,
epmd PIDs and HOME/state metadata before resuming, then checks exit and persistent
filesystem/epmd state. This is bounded observation, not a complete transient
effect trace after resume. The independent source reader found no effectful path
in validation. A subsequent guard also refuses incomplete socket observations.

Full formatting, lint, documentation, prelude and client-artifact gates pass:
zero errors, 2,672 lint and 228 documentation census warnings. Final-head broad
checks, hosted CI and required Linux signoff remain readiness gates; their
current receipts belong on the PR. No live daemon was upgraded.

This slice does not complete #1137: repository handoff, isolated child custody,
movement, gateway, page relay and fleet work remain open.
