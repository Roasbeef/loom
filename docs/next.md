# Current handoff

This is a scoped reconnect handoff, baselined October 21, 2026 against
`8b97b3b70` on `fix/web-reconnect`. The source baseline was
`bb5587a1727d4c2ebf52563c8b820fdc847e976b`. It records this repair's code and
validation; it is not a fresh audit of main, releases or hosted CI.
For publication, the branch integrates main `d9d1df193`, including the relayed
page changes and TLS profiling support. The full-package validation counts
below precede that integration; the integration row records the focused reruns.

The [previous handoff](next-2026-10-21-before-web-reconnect.md) preserves the
resource measurements, distributed-runtime drive and placement follow-ups.
Those claims retain their original observation dates and were not revalidated
for this repair. In particular, its publication instructions do not describe
this branch's delivery state. The
[incoming handoff](next-2026-10-21-before-reconnect-integration.md) preserves
main's newer relayed-session entry record exactly. PRs #1065, #1067 and #1066
are merged in the integrated main; their earlier delivery language is historical.

## Where the tree is

| Work | Verified state |
| --- | --- |
| Protocol | `4449f2afb` records protocol 097: reconnect the page without replaying an uncertain command. The owner requested recovery, logging and a no-replay regression. |
| Implementation | `18c36bd1d` makes `ConnectionFailed` retryable and propagates a live lane's close to the browser socket. Authorization is rechecked; revoked access and expired pages stay final. Component teardown still only detaches. |
| Diagnostics | `daemon.page_request_failed` records timeout versus dead gateway versus returned failure, identifiers, elapsed request time and request bytes. `daemon.page_connection_ended` records request failure, lane close, gateway close or gateway death. Command frames and page credentials are omitted. |
| Generated assets | `8b97b3b70` refreshes the stylesheet's source digest. The rendered CSS and browser bundle are unchanged. |
| Focused evidence | All 21 relay tests passed in the full client run. The real gateway commits a prompt, holds delivery beyond the six-second reply deadline, and accepts a fresh relay afterward. The transcript contains one prompt; the old relay's queued prompt is absent. Revocation during lane closure remains final. |
| Browser evidence | All 310 browser decision tests and the pinned Lustre transport regression passed. Removing the queue reset in an isolated source copy makes the transport regression fail by replaying the queued submit. A component regression checks that a fresh page subscribes without reissuing its old prompt. |
| Review | One independent adversarial pass found no actionable issue in authorization, shutdown or replay. It inspected code and independently ran the transport test, not a browser DOM remount. |
| Gates | The web-view gate passed all 1,219 tests, including the reconnect component regression. The client gate exited 2: 5,075 tests passed and the existing page startup-memory fixture failed because the component did not start. An isolated run also failed; a traced run passed, followed by all 12 socket-module tests passing. The startup failure is intermittent and its underlying cause is unproven. Package lints pass with warnings; doc-check passes with zero errors and 208 warnings. |
| Integration | With main `d9d1df193`, all 21 relay tests, the reconnect component regression, 312 browser tests and the pinned transport regression pass. The asset check and doc-check pass. The reconnect implementation itself merged unchanged. |
| Delivery | The owner requested PR publication. The PR remains a draft while the full client gate has an unresolved failure. No installation, restart or hotpatch was performed by this work. |

## What remains

1. Resolve the intermittent component startup failure before claiming the full
   client gate is green. **Exit:** inspect each
   command's own exit status and saved output, including failures and skip
   diagnostics. The failed fixture is
   `session_socket_test.admitted_page_socket_releases_its_startup_runtime_test`;
   the socket reported `start_page: the component did not start`, then the
   fixture expired waiting for its registered socket. No deadline or assertion
   was relaxed. Current client fixtures automatically skip
   code-mode cases without `build/codemode-seed` and shipped-release cases
   without `LOOM_BOOTSTRAP_E2E_SERVER`; these are not a live-browser acceptance.
2. Install and drive the repair only when requested. **Exit:** a fresh release
   runs the repaired head, and a real authenticated browser recovers from an
   interrupted lane without duplicate commands. The everyday daemon has not
   received this change.
3. Resume live profiling using main's TLS profiling support from PR #1066.
   The earlier untracked `protocol-change/096-tls-profiling.md` draft is
   superseded by main's `096-tool-members-and-profile-over-tls.md` and remains
   outside the reconnect commits. This integration does not install or restart
   the everyday daemon.

## Rulings retained

**Reconnect the connection, never replay the command.** A lost acknowledgement
is an unknown outcome. Discard the retired relay and its queued commands;
repeat authorization and read a new snapshot through a fresh lane. Protocol
[097](../protocol-change/097-reconnect-failed-pages.md) records the decision.

**A failed live lane must close the browser socket.** Otherwise the browser
can remain connected to a component whose lane has ended. Component death is
separate: its monitor detaches without initiating a reconnect.

**Diagnostic records are metadata.** Identifiers, byte counts, elapsed time and
sanitized gateway reasons identify the failing boundary without copying the
command body or a page's authentication material into logs.

## Verification

Run shipment-building package gates sequentially:

```sh
make check-client
make check-web_view
bash scripts/web_client_test.sh
make lint-client lint-web_view lint-web_client
make doc-check
```

The targeted relay command is
`LOOM_TEST_TIMEOUT_SECONDS=180 bash scripts/test.sh client --match ui_relay_test`.
Its timeout regression intentionally spends the real six-second request budget.
`node packages/web_client/test/reconnect_transport_test.mjs` exercises the built
pinned dependency with controlled sockets and timers; it needs the browser
package built first. It is also part of `scripts/web_client_test.sh`.

Logs for this work are local under `/private/tmp/loom-reconnect-*`. Read
[docs/execution.md](execution.md) before treating a gate or a skip as evidence.
The full client run is `loom-reconnect-client-check.log`; the isolated failure
is `loom-reconnect-startup-rerun-1.log`; the passing trace and socket-module
runs are `loom-reconnect-startup-trace.log` and
`loom-reconnect-socket-module-rerun.log`. The passing web-view gate is
`loom-reconnect-web-view-final.log`. Shipment-building package targets must
run sequentially: an earlier concurrent attempt raced over their shared TUI
shipment directory before reaching the web-view tests.
The integration reruns are `loom-reconnect-integrated-relay.log`,
`loom-reconnect-integrated-component.log`,
`loom-reconnect-integrated-browser.log` and
`loom-reconnect-integrated-doc-check.log`.
