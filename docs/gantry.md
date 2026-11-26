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
lane, and its header comment says why each answer has the shape it has:

- HOME, TMPDIR and every cache live under `.gantry/` in the workspace.
- The action image carries an offline Hex and Go module cache, each package's
  resolved `build/packages`, and a code-mode seed's resolved packages. The
  script copies them in before anything compiles. A dependency the image lacks
  cannot be fetched, which means the image needs rebuilding.
- The lanes that need the server shipment and the code-mode seed build them
  (`make binaries server-shipment`), since a Gantry output is a list of regular
  files and both are directory trees. A fresh seed has to resolve against Hex
  once, so `scripts/codemode_seed.sh` takes the image's resolved packages
  through `LOOM_CODEMODE_SEED_PACKAGES` and still runs all of its checks on the
  result.
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
Loom's own `bwrap` jail can start inside the container.

## Measured on the fleet

Measured on 2026-11-25 at commit `6da5d2751`, and for `fast-2` and
`conformance` at `55d4e3228`, which gives those two lanes the seed and server
they had been skipping tests without. Every lane ran as its own
target on the fleet's `loom` pool: two slots on one 32-core worker host, each
with 12 CPUs, 8 GiB of memory, a 6000 MiB workspace, a 2048 MiB `/tmp` and
`/var/tmp`, and the `userns` profile. The action image is
`gantry-loom-actions@sha256:a96aba61…`, built from Loom `d6e3551a1` on Loom's
release-builder image with stock Gleam 1.19.0, Node 18, the offline caches, a
code-mode seed's resolved packages, and the rust-analyzer toolchain that
`.github/scripts/install_rust_analyzer.sh` installs.

| Lane | Result | Lane time | Action time | Failures |
| --- | --- | --- | --- | --- |
| `static` | pass | 77 s | about 90 s | |
| `mid` | pass | 266 s | 281 s | |
| `fast-1` | pass | 196 s | 209 s | |
| `fast-2` | pass | 647 s | about 660 s | |
| `fast-3` | pass | 45 s | about 60 s | |
| `conformance` | pass | 315 s | about 330 s | |
| `eval` | fail | 271 s | 287 s | does not compile |
| `client-1` | fail | 712 s | 720 s | 1 of 2,055 |
| `client-2` | fail | 812 s | 819 s | 3 of 2,622 |
| `client-3` | fail | 592 s | 607 s | 18 of 2,775 |

Lane time is what `scripts/gantry_lane.sh` reports, including its preparation:
about 30 s for `make binaries`, and about 177 s for `fast-2`, `conformance`,
`eval` and the client lanes, which also build the server shipment and the
code-mode seed because their tests need them. Action time is from the worker's
lease to the verdict, so the difference, ten to fifteen seconds, is Gantry
staging the 87.5 MiB tree and collecting the log.

The ten lanes took about 32 minutes from admission to the last verdict. That
is within 1.02 times the total action time divided by the two slots, so the
slots were never idle while work was queued. The longest single action,
`client-2`, is 14 minutes, so more slots would shorten the run until it
approaches that. That run predates the `fast-2` and `conformance` change, which adds about
five minutes of action time between them, so the same two slots would now take
about 35 minutes.

The previous round, on the image without the Rust toolchain, failed the same
counts for the same causes; only the test that overran its deadline differed.
The language-server rust-analyzer fixture skipped there and now runs and
passes.

## Remaining failures, by cause

Every failure in the measured run falls under one of four causes.

**No delegated cgroup v2 (20 tests).** Loom's jail starts under the `userns`
profile, but its cgroup layer has no delegated cgroup to use, so it reports
partial enforcement. The tests that require every layer refuse to run their
work and fail:

- the 16 tests of `client@project_template_test` in `client-3`, which report
  that "the sandbox ran Git without full enforcement";
- the four tests that `make e2e-evolution` runs:
  `evolution_acceptance_test` (`client-3`),
  `evolution_program_acceptance_test` (`client-1`),
  `evolution_prompt_acceptance_test` and `live_upgrade_acceptance_test`
  (`client-2`). Each fails inside the scripted provider's callback, because
  the evolution plane refuses to author on degraded execution:
  `evolution_refused: authority: DegradedExecution(…skip:cgroup-v2: cgroup
  /sys/fs/cgroup not delegated…)`.

The `project_check_test` tests skip for the same reason. This is the delegated
cgroup that Gantry's sandbox-profile work set aside; it needs a worker change,
not a Loom change.

**The real-terminal TUI test (1 test).**
`client@tui_e2e_test: the_real_tui_drives_the_real_server_test` reports "the
TUI never attached: the hub still counts 0 connections" in every run. In the
earlier plain `docker run` probes it failed as uid 65534 and passed as root,
which is the user every action runs as. It has not been traced inside the test.

**A deadline under load (1 test, a different one each run).** One client-3
test overruns its own deadline each run: `ui_route_test`'s
`fixture_lasting_with_root` in two runs, and
`tui_shipped_multiplayer_test`'s fan-out test in the run before. It does not
line up with two client lanes running at once; in both cases `client-3` shared
the host with `eval`, `conformance` and `fast-1`. The two slots together hold
24 of the host's 32 CPUs.

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
