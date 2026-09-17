# Whole-host system aliases

Reviewed source: `a98c7b63`, based on `928b3dd9`.

A whole-root grant imports host symlinks into the jail. The automatic system
bind for `/bin` then targets an inherited symlink on merged-usr Linux, and
bubblewrap refuses to start. The repair resolves only automatic system roots
for those policies. It retains read-only system directories even under a
writable root, and audit and execution consume the same prepared plan.

The independent review found no introduced correctness or security defect.
It checked grant precedence, proc/dev and protected masks, minimal-root
behavior, and successful controls in the new tests. A nearby pre-existing
variant remains: an explicit policy root such as `/bin` combined with `/`
can still name the inherited symlink. This repair does not normalize explicit
policy roots.

Both original CI failures reproduced on exact main source in an isolated
Ubuntu 24.04 arm64 container with bubblewrap 0.9.0. The patched existing
regressions and new alias tests passed three runs with the race detector.
The full sandbox Go race suite then passed with delegated memory/pid
controllers, protocol fixtures, and Erlang available; no Go tests skipped.
That container used Go 1.26.5 and OTP 25, so hosted CI remains the check for
its amd64 and pinned OTP configuration. The full native macOS sandbox race
suite also passed. Replacing resolution with the original roots made the new
unit regression fail all three whole-root policy cases.
