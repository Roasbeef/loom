# Session directory permissions

Reviewed against base `c5fb6038`, September 16, 2026.

## Authority and behavior

`/add-dir PATH` commits read access to an existing canonical directory.
`/add-write-dir PATH` (also `/add-dir --write PATH`) commits read/write access. The addition belongs to
one saved session, survives reopen, and is captured before each invocation.
Running jobs keep their captured policy. Reserved facts and the authenticated
operator gateway prevent tools or observer connections from adding authority.

Native filesystem authority is separate from host-readable jail policy.
Shell and code-mode calls can declare extra permissions before execution;
native file calls ask for missing target access. Approval remains tied to the
exact displayed action. A kernel denial never causes automatic replay.

## Independent review

The implementation review found two reachable defects. Both were confirmed
against the source and corrected:

1. Structured search metadata lookup resolved a leaf's parent using only
   the workspace. It now includes explicit readable roots, while preserving
   final-leaf symlink metadata. A capability regression covers an added
   directory and a denied neighboring directory.
2. Directory admission applied write protection to read-only additions.
   Read additions now use canonical read resolution; write additions retain
   protected-path checks. Gateway regressions cover both modes.

The reviewer found no confirmed authorization bypass, observer widening,
cross-session leakage, or automatic replay after effects. Separate permission
and execution-limit requests may each prompt before execution; neither
restarts an already-running command.

## Validation

The focused tools suite passed 464 tests and the TUI suite passed 555 tests.
Directory persistence, symlink retargeting, gateway admission, capability
filesystem/search access, and captured background-job policy have focused
regressions. The production-dispatch regression verifies denial before a grant,
access after the committed grant, and isolation from a second session.

`make check` completed with exit status zero after the review fixes and command
alias were included. It passed all package suites, including 464 tools, 1,843
client and 555 TUI tests, release checks and native Go tests. House-rule lint
reported zero errors and 814 warnings. `make doc-check` also passed with zero
errors and 154 warnings. Initial validation caught test assertion and command
completion compile errors; both were corrected before this successful gate.

The full gate reported seed-dependent, Linux-only and shipped-server skips.
After preparing the pinned compiler seed, `make e2e-codemode` passed all 304
code-mode tests, including the jailed end-to-end fixture. The client live
code-mode suite reported 13 passing tests, including real capability calls
and approval consumption; its real MCP-process death fixture still reported
a skip because macOS has no `/proc`. Both commands exited zero. Linux kernel
enforcement and installed-release behavior were not validated on this host.

## Remaining boundaries

This change preserves boot defaults: shell host reads, workspace writes and
full networking unless configured more narrowly. It adds authority rather
than changing those defaults. Installed extensions retain their separate
installation policy. Native path checking retains the existing race with
concurrent host renames; it is not descriptor-based filesystem confinement.

Host-filtered jailed networking remains issue #214. Pluggable secret-store
backends remain issue #181; host-command resolution and origin-bound
brokered HTTP credential injection already exist. Transparent HTTPS CONNECT
proxying alone cannot inject an origin request header.
