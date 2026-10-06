# Foreground Launch custody

This record covers the foreground implementation through `7494a52ae` on
October 6, 2026. The source was imported from a frozen 35-file packet after
independent review, then verified in a separate checkout with matching file
hashes. It implements the local adapter and host side of the
[consumed Launch plan](../design-notes/distributed-launch-channel.md).
Remote Launch transport and ordinary registered-daemon assembly remain pending.

## What the implementation establishes

`codemode/run_channel` checks frame declarations and retains one original
consumption window in each direction. It charges the four-byte prefix and
payload against a fixed lifetime allowance before delivery. Chunk transfer,
timeouts and stale acknowledgements cannot return that capacity. The actual
capability host consumes incoming frames; the original socket writer consumes
outgoing replies.

`codemode/launch.foreground_launcher` owns token placement, listener creation,
native submission and the paused connection. The host installs its original
close handle before activation. Teardown closes the accepted socket independently
of blocked reader and writer work, then gathers their joins. A native observer
cannot send stream End ahead of a buffered cap terminal. Final consumption
precedes synchronous teardown.

`codemode/satellite` retains admitted reply slots until complete writer
consumption and carries a separate `RunCustody` observation through the pipeline.
The client removes its own execution directories only when that observation
permits it. A known program outcome does not erase unresolved cleanup; an unknown
Launch cannot trigger automatic replay or a broader-grant prompt. The configured
token path and private token writer both name `root/token/cap-token`.

The independent review found one reachable cleanup gap: transport closure did
not prove that already admitted capability work had joined. The correction
retains a pending-work count and sticky missing-drain evidence. Only the first
completion of the original Computing slot changes that count. Consuming a
timeout response, or later joining another call, cannot erase the missing
witness. The bounded recheck found that the correction closed the finding.

## Verification

The root's independent package gates used Gleam 1.19, OTP 29, a freshly built
regular helper and a regenerated offline code-mode seed. Each command's own
exit status was zero.

| Gate | Result |
| --- | --- |
| Code mode | 482 tests passed, including the actual jailed toolchain and satellite controls. |
| Tools | 749 tests passed. |
| Client | 3,073 tests passed; fifteen explicit platform or dependency skips. |
| Changed-package lint | Code mode, client and tools passed with existing warning censuses. |
| Documentation | Package coverage and byte-identical mirrors passed. |

The client skips remain the one Linux `/proc` witness, thirteen shipped-server
controls and one rust-analyzer control. They are absent coverage, not passing
executions. Separate real-socket controls exercise paused handoff, complete-write
consumption, Final ordering and close while output is blocked. A host-produced
unresolved result reaches the production client cleanup helper and preserves two
real directories.

Twelve compiling mutation controls were rejected by their intended assertions:
nine channel or capacity controls, two admitted-work drain controls and one
client deletion control. These were worker executions whose receipts and
assertions were inspected; the root independently reran the package gates rather
than rerunning every mutant. The [Launch channel model](../../protocol/models/launch-channel/README.md)
records its own bounded schedules, mutation witnesses and correspondence limits.

Earlier failed attempts remain failures: a mismatched token path, a missing
isolated-checkout helper, and concurrent packaging of the generated TUI shipment
were corrected before the final gates. Two concurrent Make targets can race in
that shared generated output. The final package checks ran sequentially against
the fresh helper and seed.

## Remaining acceptance

This evidence does not establish remote stream binding, per-Launch native
retirement, the composed scope owner, registered default consumers, separate-host
execution, or complete-report lifecycle across archive and restore. Compile
custody remains separate from Launch custody. The full repository gate and hosted
CI have not run on this candidate. The integration PR remains draft for the
remaining [issue 697 acceptance](../design-notes/distributed-runtime-integration.md#acceptance-before-merge-readiness).
