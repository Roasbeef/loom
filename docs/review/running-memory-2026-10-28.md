# Running Loom memory and native fixture lifetime

On October 28, 2026, we repeated the profile after merging #1138. The owner
requested measurements of the already-running version, so we preserved that
process and its workload. Merging source did not update the installed daemon.

The daemon was Loom 0.3.2, commit
`fcbc7d9b468f8381a5ada5579d5b23a690e4ea65`, PID 96649. The persistent native
client was commit `3cf6bdc09c281e39dd126d5b7daa6c9d7eb4308d`, PID 28061.
OTP was 29, ERTS 17.0.5, with eight-byte words. The fix in #1138 was rebased
at `34791d819f6fd962d4edb1be28207e10cda456da` and merged at
`da27f068d4084d1e4e9d0c401f86e8e67531a6f9`. The owner explicitly authorized
an admin merge while the rebased checks were pending. Earlier green checks
cover their earlier head, not that rebase.

## Independent counters

We used ordinary OTP RPC counters, OS `ps` and `footprint`, then Pickglass
through the existing enrolled TLS inspector. The observer was hidden and
non-listening; cookie contents stayed out of arguments and logs. The native
client's diagnostic node used its existing loopback TCP enrollment instead.
Neither process was restarted, garbage-collected, hotpatched or installed.

| Cut | Daemon | Native client |
| --- | ---: | ---: |
| Initial RSS, KiB | 301,680 | 34,400 |
| Physical footprint, tool display | 250 MB | 76 MB |
| Ordinary OTP total before, bytes | 203,911,440 | 50,119,041 |
| Ordinary OTP process allocation before, bytes | 132,904,648 | 20,851,520 |
| Pickglass OTP total, bytes | 213,667,532 | 50,633,734 |
| Pickglass process allocation, bytes | 140,299,824 | 20,867,904 |

The ordinary daemon cut lasted ten seconds; total allocation ended at
206,365,760 bytes and process allocation at 135,328,768 bytes. These are
separate, non-atomic cuts during real user activity. Footprint and RSS use
different accounting and observation times. None measures reachable state
alone, and their difference is not proof of a leak.

The largest daemon process triple allocated 19,900,128, 13,821,400 and
13,819,752 bytes. It matches the evolution callback ownership pattern already
fixed in #1138, which the installed build predates. A later metadata-only
census found the same sizes at new PIDs: the live session changed between
cuts. We did not treat that as persistent ownership by the original processes
or as a matched before/after experiment. Code-server capacity and an active
provider pump were also substantial; their sizes do not establish redundant
reachable state. We found no further production retention bug in this pass.

The ten-second CPU sample selected the top eight processes at 50 Hz. Only nine
of 4,000 samples were running or runnable, so this window does not support a
CPU bottleneck claim. A separate 10.1-second allocation trace of
`storage@sqlite` and `client@daemon@manager` recorded 2,905,872 allocated bytes.
`handle_open` accounted for 1,002,496 bytes in 109 calls; eight `json_of_blob`
calls accounted for 737,472 bytes. That is cumulative traced allocation, not
retained bytes or RSS. The earlier profile used a different build and workload;
we make no savings claim by comparing those totals.

Raw ordinary, footprint and Pickglass captures were saved locally as
`/private/tmp/loom-memory-*-20261028-repeat.*`. Pickglass captures are gzip
JSONL. We inspected process metadata, stacks and counters, without dumping
session payloads, dictionaries, cookies or closure environments.

## Native fixture leak

A separate OS census found eighteen older test daemons reparented to PID 1,
with total RSS of 1,483.94 MiB. Six came from the headless `loom run` fixtures;
twelve came from ACP fixtures. Their private state directories and isolated
homes identified the owning tests. They were not the production daemon, and
we left those existing processes alone.

The distinction is in the production lifecycle: ending a session or hanging
up an ACP client intentionally leaves the user's shared daemon available.
The fixtures had private state and needed to own that native lifetime
explicitly. Their successful session assertions did not prove native teardown.

On merged main `da27f068`, an isolated run of both real headless fixtures
exited zero and reported two tests passed. Both newly created daemons remained
under PID 1, with RSS 114,816 and 116,832 KiB (226.22 MiB combined). We then
retired only those two fresh identities through the existing endpoint birth
fence. This reproduction used the previously built shipped server from the
original worktree; the fixture source was the unchanged merged-main source.
The follow-up validation builds its own current shipment.

`support/native_fixture.with_directory` allocates the private root and its
`state` endpoint before running the test body through weft. All receives and
session assertions stay in that managed body. On completion, assertion
failure or deadline expiry, the outer fixture retires the recorded native
identity and waits for departure before reporting the body outcome. The
existing `remote_daemons.retire` supplies the process-birth check and bounded
wait. Production APIs and daemon lifetime are unchanged. An untrappably killed
test VM cannot execute this in-VM teardown.

Three regressions launch a real detached native child through the production
paused-wrapper and endpoint publication path. They require absence after a
successful body, an assertion failure and a body deadline. Each samples that
absence before its own fallback retirement, so the negative control cannot
leave another orphan. Removing only the fixture retirement (and its otherwise
unused import) compiled successfully and failed all three absence assertions:
`Failed: 3. Skipped: 0. Passed: 0.` Restoring it passed all three. The initial
control attempt stopped at an unused-import warning and is not counted as
runtime regression proof.

## Validation

The current merged-main shipment and helper built successfully. The three
native ownership regressions passed, both real headless tests passed, and all
sixteen ACP tests passed (including twelve shipped-daemon drives). A separate
birth-fenced census checked all fourteen fresh endpoints after those tests and
found every recorded native identity absent. No affected shipped test skipped.
The final negative control uses the same assertion-failure regression as the
fixed run and fails all three runtime absence assertions.

Formatting, client lint and documentation checks passed. Client lint reports
zero errors and 804 existing advisory warnings. The full client gate,
exact-head hosted CI, Linux signoff and independent review are in progress;
these are not claimed as passed by the targeted results. The measured target
of zero fresh survivors is met while preserving saved-session, shared-resident,
permission and timeout checks.

A narrow check of neighboring shipped fixtures found explicit native
retirement in their existing wrappers. We reused their managed-body and
birth-fenced cleanup pattern here, rather than changing production client
shutdown semantics or adding a second process-management mechanism.
