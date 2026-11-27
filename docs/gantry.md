# Building Loom on Gantry

Gantry is a self-hosted build and merge queue. A controller holds the queue,
and worker slots pull one action at a time and run it in a Docker container.
This page says how Loom's Linux CI lanes run there, what each lane measured on
the fleet, and which failures remain and why.

## What runs

`gantry.json` at the repository root names one action per Linux lane of
`.github/workflows/ci.yml`. Each action runs `scripts/gantry_lane.sh` with its
lane's name, and the script runs the same command as the matching CI job.

| Action | CI job | Command |
| --- | --- | --- |
| `static` | static (linux) | script self-tests, `make fmt-check prelude-check lint doc-check` |
| `mid` | check, runtime-storage-session-events | `scripts/check.sh runtime storage session events` |
| `fast-1` | check, fast (first cut) | `scripts/check.sh host core … web_mermaid telemetry` |
| `fast-2` | check, fast (second cut) | `scripts/check.sh provider broker … tui lint` |
| `fast-3` | check, fast (third cut) | `scripts/check.sh sandbox vmm` |
| `conformance` | check, conformance | `scripts/check.sh conformance` |
| `eval` | check, eval | `scripts/check.sh eval`, with a shallow `.git` |
| `client-1` to `client-3` | check, client-1 to client-3 | `scripts/check.sh client` with `LOOM_CLIENT_TEST_SHARD` |

CI's fast bucket is one job. Here it is three actions, because
`scripts/check.sh` stops at the first package that fails, and in a single
action one red package would hide every package after it.

The `check` target runs every action. Gantry stops scheduling a target's
remaining actions once one fails, so each lane also has a target of its own
with the lane's name, for running or retrying it alone:

```bash
gantry run <id> fleet/loom <commit> client-2
```

## How an action differs from a CI job

A Gantry action has a read-only root, no network, and nothing restored from an
upstream job. `scripts/gantry_lane.sh` answers each of these once for every
lane, and its comments say why each answer has the shape it has:

- HOME, TMPDIR and every cache live under `.gantry/` in the workspace.
- The action image carries an offline Hex and Go module cache, each package's
  resolved `build/packages`, and a code-mode seed's resolved packages. The
  script copies them in before anything compiles. A dependency the image lacks
  cannot be fetched, which means the image needs rebuilding.
- The image also carries a warm build: the build output of one Loom revision,
  made by the script's `bake` mode when the image is built, as a tar per
  package `build/`, the root `build/` and the Go build cache, with a hash of
  the lockfiles it came from. A lane copies in the parts it uses when the
  tree's lockfiles hash the same, then stamps the tree's own files with the
  current time. Gleam compares a module's content with its cache only when the
  source is newer than the cache entry, and Gantry stages every file with one
  fixed, older time, so without the stamp an edited module would be tested as
  the image's revision compiled it. With it Gleam recompiles only what changed
  since that revision. With other lockfiles the lane builds from nothing.
- The `prepare` action builds the server shipment and the code-mode seed once
  (`make binaries server-shipment`) and publishes them, with `bin/`, the TUI
  shipment and the helper, as two tarballs, since a Gantry output is a list of
  regular files of at most 64 MiB each and these are directory trees. The six
  lanes that need them list `prepare` in their `deps` and unpack them. A fresh
  seed has to resolve against Hex once, so `scripts/codemode_seed.sh` takes the image's resolved packages
  through `LOOM_CODEMODE_SEED_PACKAGES` and still runs all of its checks on the
  result. That `make` runs with only the variables the build reads, so
  `scripts/shipment.py`'s environment digest is the same in the image's bake
  and in an action, and the shipments reuse what the image cached.
- Test modules run concurrently, through the same `scripts/test.sh` mechanism
  `make signoff` uses: eight at a time, as signoff runs them, and sixty-four
  at a time for the client package, whose tests mostly wait. `scripts/serial-tests`
  still holds back the modules that must run alone.
- Gantry keeps only the first 64 KiB of an action's output. The script writes
  the whole lane log to `.gantry/lane.log` and prints a condensed view: section
  headers, each failure with the sixteen lines after it, every SKIP, the
  suites' totals, and on failure the last forty lines.
- The script sets the variables CI sets for these jobs (`LOOM_EVOLUTION_E2E`,
  `LOOM_TEST_PROVIDER_KEY`, and `LOOM_BOOTSTRAP_E2E_SERVER` where a shipment
  exists). It also sets `LOOM_TEST_OFFLINE=1`, which only
  `client@lsp@manager_test`'s Hex download test reads. That test needs the Hex
  registry, so it skips on Gantry and still runs in GitHub CI.

The fleet runs these actions under Gantry's `userns` sandbox profile, so that
Loom's own `bwrap` jail can start inside the container, and the worker hands
each action a delegated cgroup v2, so the jail applies every layer.

## Measured on the fleet

Measured on 2026-11-26 on the fleet's `loom` pool: two slots on one 32-core
worker host, each with 12 CPUs, 8 GiB of memory, a 6000 MiB workspace, a
2048 MiB `/tmp` and `/var/tmp`, the `userns` profile and a delegated cgroup.
Every lane ran as its own target. Times are action seconds, from the worker's
lease to the verdict.

| Lane | Before | After | Failures (after) |
| --- | --- | --- | --- |
| `client-1` | 1,044 | 365 | 1 of 2,055 |
| `client-2` | 1,083 | 353 | 1 of 2,622 |
| `client-3` | 1,005 | 423 | 1 of 2,775 |
| `fast-2` | 656 | 309 | |
| `conformance` | 325 | 175 | |
| `eval` | 276 | 150 | does not compile |
| `mid` | 273 | 53 | |
| `fast-1` | 205 | 138 | |
| `static` | 80 | 79 | |
| `fast-3` | 51 | 34 | |
| **Makespan, all ten** | **2,828** | **1,107** | |

Before is a run at `27be14453` on the image without the warm build; a second
run of the same tree took 2,573 s, the difference being only which lanes the
two slots took in which order, since every lane's time matched within 2%.
After is `a5b939a86` on the image with the warm build, with the fix described
below. Every lane's test outcome is the same in both: the same exit status, the
same test total, no new SKIP, and no failure outside the calibration runs' set.

### Where the time went, and what cut it

Before, more than half of all lane time was compiling. Every package has its
own `build/`, so each compiled its dependencies again, a client lane compiled
`client` twice (once for the server shipment, once for its tests), and every
action did all of it from nothing. The tests themselves ran one module at a
time and used one to three of a slot's twelve cores. Gantry's own overhead was
about fourteen seconds an action, half of it fetching the tree, which a later
worker release caches.

The cut came from four changes, each measured alone on the four slowest lanes
and kept only when it beat the best so far by more than the run-to-run noise:

| Change | Four-lane makespan |
| --- | --- |
| (before) | 2,075 s |
| Test modules eight at a time | 1,554 s |
| The warm build | 1,310 s |
| The preparation's fixed environment (shipment reuse) | 1,232 s |
| Client modules sixteen at a time | 1,108 s |
| Client modules thirty-two at a time | 895 s |
| Client modules sixty-four at a time | 806 s |

A hundred and twenty-eight client modules at a time failed shipped-daemon and
project tests that pass at sixty-four, so sixty-four is the setting, and those
tests are the first to show strain under load. Twelve modules at a time for the
other packages saved fast-2 twenty seconds but left the makespan level, and
storage, runtime and broker are recorded colliding above eight, so they stay at
eight.

A review of the result found that the warm build, as first written, let Gleam
skip edited modules: a deliberately failing assertion passed on the fleet. The
lane now stamps the tree after copying the build in, the same assertion fails,
and the times above the line were taken on commits whose compiled code matched
the image's. The fix costs about three percent: the same four lanes took 813 s with it, against 803 s without.

### Preparing once

In the run above, six lanes each spent about 130 s on the same preparation, of
which about 92 s is exporting the server shipment. `scripts/shipment.py` does
not reuse that export by design: the client's closure holds `esqlite_loom`,
`khepri`, `ra` and other builds outside its reviewed `ERLANG_ONLY` list. Six
copies were close to 40% of all slot time, so the `prepare` action now builds it
once and those lanes unpack its output. Measured at `eb3d61ffc` on the same
pool, with every lane's outcome checked against the same expectations:

| Action | Before | After |
| --- | --- | --- |
| `prepare` | | 158 |
| `client-1` | 365 | 241 |
| `client-2` | 353 | 244 |
| `client-3` | 423 | 289 |
| `fast-2` | 309 | 175 |
| `conformance` | 175 | 44 |
| `eval` | 150 | 13 |
| **Slot time, all eleven** | **2,079** | **1,478** |

The lanes without a server shipment are unchanged (`static` 86, `mid` 55,
`fast-1` 139, `fast-3` 34). The makespan was not measured as one run, because
a `check` run stops admitting work at its first failing action and `eval`
fails before the client shards start; laid out on two slots, these times give
about 750 s, against 1,107 s.

### What binds it now

A client lane is now about 230 to 290 s of tests and a few seconds of setup.
`client-3` runs longest because the runner deals modules to shards
round-robin rather than by weight. With two slots the makespan is about the
total action time divided by two; more slots would bring it toward the
longest chain, `prepare` then `client-3`, about seven and a half minutes, but
the worker host has no memory to spare for a third or fourth slot at a client
lane's peak of about 5 GiB.

## Remaining failures, by cause

With the delegated cgroup, the twenty tests that needed full enforcement pass,
and tests that used to skip on "platform enforcement unavailable" run. What
fails now:

**A newly exposed failure (1 test, `client-1`).** The shipped remote
evolution acceptance test fails in `support@remote_pair:fixture` ("the
shipped remote body completes before native teardown"), crashing inside the
scripted provider's callback. Without the cgroup it skipped. It has not been
traced yet.

**The real-terminal TUI test (1 test, `client-2`).**
`client@tui_e2e_test: the_real_tui_drives_the_real_server_test` reports "the
TUI never attached: the hub still counts 0 connections" in every run. In
plain `docker run` probes it failed as uid 65534, the user every action runs
as, and passed as root. It has not been traced inside the test.

**A deadline under load (1 test, `client-3`).** One test overruns its own
deadline in most runs, usually `ui_route_test`'s `fixture_lasting_with_root`.
`delegate_host_test`'s idle-sweep test is a known flake that fails about one
run in five, with a shell syntax error over a list of PIDs.

**`eval` does not compile at main.** Since `95b4186e7` ("client: create a
local session in its own Git worktree"), the client's settings record has a
51st field, and the eval package's run command still builds the record with
the 50 it had before (the compiler names the missing `released` label). This
is a defect on main that the fleet found, not a property of Gantry, and it is
left for its own fix.

Skipped here and run in CI: `client@lsp@manager_test`'s
`gleam_preparation_downloads_hex_and_loads_a_sibling_in_a_fresh_workspace_test`,
which needs the Hex registry and skips on `LOOM_TEST_OFFLINE=1`. The gopls
fixture skips here as it does on Linux CI, where
`.github/declared-skips-linux-gate` declares it.

## Known differences from CI

- CI pins a patched Gleam 1.19.0 (`scripts/toolchain/gleam`). The action image
  uses the stock 1.19.0 release.
- The image carries Node 18. GitHub's runners ship Node 20. The JavaScript
  suites pass on 18.
- Gantry mounts a private tmpfs at `/var/tmp` as well as `/tmp`, as a runner
  has both writable. Several client fixtures keep their sockets under
  `/var/tmp`, because the jail replaces `/tmp` and a socket path has a byte
  budget, so they need it.
- The `eval` lane's shallow `.git` has one commit, so the mined tasks that name
  older Loom commits skip, as they would on a depth-1 checkout. CI's eval job
  fetches the full history.
