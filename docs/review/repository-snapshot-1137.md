# Repository snapshot prerequisites for issue 1137

Implementation source: `4a0523624bf6e4ffe7b3f8b3458adf49937d5169`, based on
launch-preflight source `074b22c6ca8f3889866ed9db784dcc7bbf89c8e3`.
This is a local capture/import prerequisite. Spawning, peer transfer, durable
child ownership, returned results and session movement are not connected here.

## Behavior and ownership

A native caller supplies a serialized, drained and quiescent source workspace.
Capture builds a private index, object store and WIP ref from final working
bytes. Staged and unstaged distinctions collapse in the clean child; the real
source HEAD, index, refs and working files remain unchanged. Git executable
mode and symlink text are preserved. Ignored untracked files and untracked
Loom runtime data are excluded; tracked protected collisions refuse capture.
Source discovery uses the workspace's server-owned tool HOME and projected
Git identity configuration, not the operator's ambient global configuration.
An unreadable ignore rule refuses capture rather than changing eligibility.

All Git execution uses the existing broker and helper, with network off,
finite resource ceilings and one monotonic work deadline. Private writes are
confined to one stage. Ordinary session policies mask the complete store
before admission; the dedicated capture policy removes only that store mask,
narrows its reads and retains every other mask. A failed artifact stays private
until the caller establishes native drain. There is no aggregate disk quota or
space reservation: the free-space estimate can be invalidated by other writers.
External writers are a stated precondition, not an atomic filesystem snapshot.
No production caller currently enforces drain or serialization for this API.

An offline bundle is verified in a fresh repository before returning the private
child. Reachable HEAD history is included; other refs, hooks, configuration and
credentials are not copied as metadata. Authorized history or ordinary files
can still contain arbitrary secrets; this is not a content scanner.

## Independent review

One fresh independent review found three reachable defects. Native controls
reproduced legacy `crlf=input` normalization and a missing-HEAD promisor
transport executing before refusal. Both attribute lists now include `crlf`;
effective configuration, including worktree settings and includes, is checked
before object resolution. Capture also disables lazy fetching explicitly.
Admission and collection now share a deadline, output does not renew it, and
settlement grace cannot authorize late success. The same reader checked the
scoped fixes and found no remaining issue in them.

Primary verification then found a home-relative ignore mismatch: the old
capture environment exported an otherwise ignored canary. The source tool-home
selection and strict untracked-query diagnostics fix that mismatch. The same
reader checked this additional delta. No new actionable finding was reported.

## Focused evidence

The primary tests use the actual broker/helper. Formatting, both affected house
linters, documentation and prelude gates pass. Compiler warnings remain errors.

| Focused module | Tests |
| --- | ---: |
| `worktree_git_test` | 9 |
| `git_identity_test` | 10 |
| `repository_snapshot_test` | 6 |
| `daemon_state_masks_test` | 5 |
| `daemon_root_test` | 21 |
| `collector_deadline_test` | 3 |

Snapshot fixtures compare source HEAD, index bytes, refs and contents, and cover
staged B/working C, staged ignored additions, deleted-index/recreated HEAD paths,
nonignored and ignored files, executable mode, outward symlink text, literal
pathspec-looking names and runtime canaries. Linked worktree metadata is read
under existing grants demoted to reads. A sibling stage remains inaccessible.
Native fsmonitor and promisor controls establish that the dangerous commands
can run outside capture and remain disabled inside it.

Negative fixtures cover clean and dirty submodules, gitlinks, LFS filters and
pointer headers, legacy and current transformations, conflicts, unborn HEAD,
shallow history, promisor/worktree configuration, missing reachable objects,
grafts, protected paths, missing identity and unreadable ignore rules.

Reproduce the focused modules with `bash scripts/test.sh client --match <module>`
and `bash scripts/test.sh tools --match collector_deadline_test`. The filter is
a substring. These native tests need the normal host filesystem/network and
sandbox facilities; an enclosing desktop sandbox can invalidate the result.

## Resource and failure evidence

A working-copy production-path drive, before the final ignore-context change,
used a 270,532,608-byte incompressible file. The real broker/helper produced a
270,615,518-byte bundle, verified and imported matching bytes, preserved source
HEAD/index/refs/payload and drained its helper. The stage was mode 0700. An
external sampler observed 167 process-tree samples over 57.748 seconds:

| Observation | Sampled peak bytes |
| --- | ---: |
| BEAM process | 97,320,960 |
| Largest native process | 547,241,984 |
| Native processes together | 568,131,584 |
| Observed descendant tree | 790,986,752 |

These are sampled peaks, not hard resource bounds. Native Git window/cache
settings are not aggregate RSS bounds either. The exact committed-source drive
will be recorded in the PR before readiness; the earlier result is retained as
its own measurement.

Separate brokered one-MiB file-limit and one-second wall-limit failures exposed
no child, left only private artifacts, preserved source state and returned a
successful helper drain. The file-limit case left a bounded temporary object
and index lock; it is not an ENOSPC proof. The wall-limit case reached a private
WIP ref before failing during the later build path. Native parent-only kill
controls left a pack child alive and therefore were rejected as cancellation
proof; the identified test process was retired and its exit verified.

## Remaining gates

Actual post-admission ENOSPC is unproved. The local Docker runtime could not
create a container because its overlay storage was read-only. An isolated
Linux filesystem experiment is being prepared; filling the host filesystem
is not an acceptable substitute. Full affected checks, exact-head hosted CI and
Linux signoff also remain required before readiness. Live distributed
acceptance belongs to the later connected runtime, not these local helpers.
