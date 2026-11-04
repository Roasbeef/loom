# protocol-change/106: preserve and preflight daemon launches

**Status:** approach accepted by the owner on 2026-10-29; implementation and
verification in progress. **Affects:** native daemon launch, update and readiness
and distribution startup under 078. Part of issue #1137; follows the peer
exchange in 105.

## Problem and alternatives

The updater's environment can differ from the environment that launched a
working daemon. Losing its distribution options can make the replacement exit
at boot, after the old VM has already been retired. The caller then sees a
generic readiness failure rather than the missing setting.

Guessing from the updater's environment cannot recover the original launch.
Persisting the whole environment or config would also copy secrets. A rollback
mechanism would add another lifecycle without preventing the configuration
failure. We instead record only nonsecret launch facts and validate the staged
replacement before retiring the captured daemon.

## Decision

The daemon records its actual launch source while startup reads and validates
it, not by resolving a possibly retargeted symlink at Ready publication. Capture
uses actual VM boot arguments, including options supplied through ERL_FLAGS,
rather than assuming the current environment describes what the VM consumed.

The private `launch.json` record is versioned and bounded to 4,096 bytes. Version
1 has eight required fields: `version`, `pid`, `birth`, `started_at_ms`, `epoch`,
`config`, `mode` and `options`. Config is its canonical original file path or
explicit absence. Mode is `local` with null options, or `tls` with the canonical
original options path. PID/birth are the native reservation and epoch is the
authenticated ready incarnation. Start time remains diagnostic. The record holds
no certificate, cookie, token, config contents or whole environment.

Startup writes the private record atomically under launch.lock against the same
Starting reservation immediately before publishing Ready. A crash between those
writes leaves metadata that cannot establish readiness or replacement authority.
An otherwise valid custom launch that cannot be reproduced still starts; it does
not publish fabricated current-epoch metadata. Automatic replacement then refuses
before stopping it. Unrepresentable settings are not a new daemon startup ban. This includes
unsupported original CLI choices and schema or escaped-size overflow. The
canonical installed adjacent helper remains reproducible; actual filesystem
write failures still propagate.

## Staged validation and replacement

The staged server has an internal exit-only validation invocation:

```text
loomd __launch_preflight local [config-path]
loomd __launch_preflight tls config-path
```

The shipped launcher and profiling wrapper both classify it as exit-only before
reading automatic profiling settings. It must not create a profile node or cookie
home, start distribution or epmd, bind a listener, open the catalogue, claim an
endpoint or take the daemon lifetime lock. Starting OTP dependency supervisors
is not assumed sufficient proof of this property; the shipped test must observe
forbidden effects as well as the validation result.

Validation shares startup's read-only config decoders and actual distribution
checks: options/boot shape, bounded private credential reads, cookie-home binding
and certificate identity and private-key possession. The peer trust CA may be
independent of the local leaf issuer. Ledger mode replays complete records and
audits authority, membership and references without modifying the file; only
owning startup repairs a torn tail. It does not duplicate those rules in TUI
or add a client dependency there. Native startup reuses the validated values and still
validates again in the actual replacement.

The updater captures an authenticated endpoint, loads and matches its launch
record, and runs staged validation before publishing/retiring where the existing
pipeline permits. An explicit updater config that names a different source is
refused rather than substituted. No-running-daemon cold start keeps its existing
path. Missing, unreadable, malformed or stale metadata, options and credentials
produce a specific refusal while the captured daemon keeps serving.

The validation child and replacement receive explicit literal child environment
changes. Inherited VM flag sources and the distribution options variable are
cleared before VM boot; TLS then sets the recorded options path. Absent config is passed to the replacement as the literal existing `--config
""`; the profiling wrapper preserves that explicit absence. A local config
that now enables profiling is refused before retirement. Profiling/debug
argument sources that can create a named VM are cleared too. Traced epmd
environment settings must not silently redirect a reproduced launch. Scheduler
flags alone do not invalidate ordinary startup. The updater never mutates its
global environment, and argv paths with spaces remain literal arguments.

Immediately before shutdown, the updater rechecks the captured native identity
and authenticated epoch. A private metadata file or PID alone is never authority
to stop a process. Replacement retains the existing PID/birth departure wait and
authenticated hello/ready-epoch check. No second retirement or readiness protocol
is introduced.

## Cost and limits

A pre-metadata daemon or an unrepresentable original launch requires explicit
initial setup; automatic update does not guess its settings. A very long launch
record that cannot fit the bound is not silently truncated. The operator sees a
specific recovery error. Config paths identify the actual source, not a frozen
copy of secret config contents.

Preflight observes a point in time. Files can change afterward and an unrelated
bind or startup failure can still prevent readiness; startup validation and
identity fences remain necessary. The owner's approval covers code and isolated
tests. A live daemon upgrade, deployment or publishing a release still requires
its own concrete authorization.

## Verification

Use the actual isolated staged/shipped launcher with private state. Missing or
stale options, invalid credentials, absent/mismatched metadata, wrong PID/birth or
epoch, incompatible updater HOME and different explicit config must refuse
before retirement; assert the original authenticated daemon and native fence
remain live. Verify local-only under conflicting TLS, VM/debug and profiling
environment, without forbidden preflight effects. Include config/options paths
with spaces and a symlink identity change between reading and Ready publication.

A valid TLS replacement must retire the original fence and become ready with a
new authenticated epoch and expected build. Unit tests with placeholder shell
servers do not establish this lifecycle. Record the native proof, full gates,
independent review and exact-head CI/Linux signoff before readiness.

## Review and current evidence

The [review record](../docs/review/launch-preflight-1137.md) records the four
reachable independent-review findings and their fixes, the preliminary shipped
smoke, and the final gates still pending. The original malformed private-key
witness caused retirement before readiness and led to shared native credential
validation. A later smoke passed before the final fixes; it is not proof of the
current source. No live upgrade has been authorized.
