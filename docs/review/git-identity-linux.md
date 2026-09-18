# Git identity Linux repair

PR #444's original head is `b823a6455f7fb3b75d18e8a5be78124bfe848ade`.
The repair covers startup policy timing, protected-mask planning, the fixed
metadata query's resource requirements, confined config publication, and
adoption of the existing esqlite query-retirement repair through a Git pin.

## Independent review

A fresh reader reviewed the tracked and untracked repair against that head,
including the helper, client call path, compiler patch, packaging fixture and
native dependency metadata. No introduced correctness or security defect and
no necessary simplification was found. The author checked the two reported
residuals against their callers and the compiler's existing freshness logic.

The publisher checks the original host-write grant, preserves protected
aliases, rejects symlink parents and atomically replaces the fixed destination.
It never constructs the bubblewrap mount tree that materialized a missing
SQLite journal directory. The query still requires its filesystem and network
enforcement. The compiler rebuilds native artifacts for changed Git commits,
including a commit change that retains the package version.

Two pre-existing paths remain outside this repair:

- Startup's general `create_directories` follows a planted `.codemode` symlink
  and can create `home` or `tmp` under its target before publication refuses
  the parent. This is source-traced, not reproduced. The new publisher itself
  neither creates directories nor follows that alias.
- The compiler's Hex freshness branch compares package version alone. Removing
  a Git pin in favor of the same Hex version can retain Git build output.
  Retiring this pin therefore requires a clean build. The changed-Git-commit
  regression does not claim to cover source-kind transitions.

## Verification

The combined compiler patches pass 3,499 core and 125 CLI unit tests, plus
integration tests. Native and Linux compiler smoke fixtures pass clean native
resolution, exact-pin retention, changed-commit rebuild and deterministic
cache checks. Storage passes 104 tests against the actual pinned build.

The helper passes its full macOS Go suite and focused race tests. Replacing
`O_NOFOLLOW` in an isolated test overlay makes both planted-parent regressions
fail; the normal helper passes them. Tests exercise Git's parser, input bounds,
protected and read-only paths, aliases, concurrent readers and missing database
side files.

Full native and Linux `make check` gates pass with 1,868 client, 563 TUI and
306 code-mode tests, zero lint errors and 809 warnings. Runtime was rechecked
on macOS after its manifest refresh and passes all 144 tests. The native
release smoke passes. The Linux daemon soak retains 35 file descriptors at
every retirement over two warmup and 16 measured cycles.

The rebuilt Linux shipment passes the bootstrap, multiplayer, live-delivery,
stop, schedule, jobs, confinement and reservation-recovery fixtures. The last
identity-recovery fixture reached orderly shutdown but failed its native-exit
witness because the diagnostic container used `sleep` as PID 1 and retained
a zombie daemon. Its rerun uses Docker's init reaper; the assertion is retained.
The reaper-enabled recovery rerun passes, including the natural lease-expiry
wait. Linux release smoke also passes, including an offline build with its
bundled compiler. The focused Linux publisher and mount-planning race tests
pass. An extra whole-module race run was not completed: a diagnostic container
lacked the required proc-mount setup, and recreating that broader configuration
was not approved. This does not replace the passing full Linux Go gate or the
hosted jail integration result.

Hosted [CI at the source repair](https://github.com/Roasbeef/loom/actions/runs/35296373952)
passes its Linux jail and complete bootstrap lanes. The
[toolchain build and release comparison](https://github.com/Roasbeef/loom/actions/runs/35296389719)
publishes image digest
`sha256:03edc3c58c7962f51b1faf4634d8efa4a0f63b1ca0699fc5eaaea45fa20694af`
and passes matching artifact comparison on two independent Linux runners.
The tag-release workflow selects that digest. Current aggregate CI belongs to
the PR's latest head; these links name the source repair's evidence.
