# Design note: running the test suite in parallel

Status: **measured, opt-in, not defaulted.** `scripts/test.sh` now accepts
`LOOM_TEST_PARALLEL=<N>`. Unset or `1` is the behaviour the runner has always
had. Set to anything larger, the runner wraps its test list in an EUnit
`inparallel` group and up to N tests run at once on the one emulator it
already starts. Nothing in the build turns this on; `make check` and CI still
run sequentially.

This note records what the variable does, what it cost to measure, which
tests it breaks and on what they collide, and what would have to change
before a default could be turned on.

---

## What the variable does

Gleam has no test parallelism of its own. EUnit does: a test representation
of the form `{inparallel, N, Tests}` runs up to N of its members at a time.
The runner already builds a list of every test module in the package and
hands it to `eunit:test/2`, so the change is to wrap that list when the
variable is set and to leave it alone when it is not.

One thing about `inparallel` is worth stating plainly, because it is not
what the name suggests and it decided how the census below had to be read.
**EUnit propagates the group's ordering into every item beneath it.** The
list handed to `inparallel` is a list of modules, but the concurrency does
not stop at the module boundary: each module expands into its own tests, and
those inherit the parallel ordering too. So N counts individual tests, not
modules, and no module is internally sequential. Two tests in the same file
that share a fixture between themselves are exactly as exposed as two
unrelated suites. The first failure this work found was of that shape.

The `--match` path is deliberately left sequential. It already names
individual tests rather than modules, and a focused debugging run that
reordered them would be answering a different question than the one asked.

A value that is not a positive integer is refused with exit 2 rather than
quietly treated as 1. A typo that fell back to sequential would let a timing
measurement report a speedup that never happened, which is the specific way
this measurement could have lied.

---

## The timing table

Every number below is one run of `bash scripts/test.sh <package>` on a
32-core Linux box (Erlang/OTP 29, Gleam 1.18.1), wall-clock seconds from
`date +%s` around the invocation, with the runner's own exit status
recorded. `LOOM_BOOTSTRAP_E2E_SERVER` and `LOOM_TEST_PROVIDER_KEY` were
exported so the shipped fixtures ran rather than skipping. The per-package
process deadline was 900 seconds; nothing reached it.

Times include compilation, which is why the small packages bottom out
around a second no matter what N is: for those the run is almost entirely
`gleam build`, and there is nothing left to parallelize.

`pass` means the runner exited 0. Failures are named in the census.

| package | N=1 | N=4 | N=8 | N=16 |
|---|---|---|---|---|
| host | 2 pass | 1 **fail**† | 1 **fail**† | 0 **fail**† |
| core | 1 pass | 1 pass | 0 pass | 1 pass |
| storage | 36 pass | 3 pass | 3 pass | 11 **fail** |
| session | 33 pass | 1 pass | 1 pass | 1 pass |
| machine | 2 pass | 0 pass | 1 pass | 0 pass |
| prompt | 2 pass | 1 pass | 0 pass | 1 pass |
| telemetry | 2 pass | 1 pass | 1 pass | 1 pass |
| runtime | 53 pass | 12 pass | 10 **fail** | 8 **fail** |
| provider | 13 pass | 5 **fail** | 4 **fail** | 3 **fail** |
| broker | 17 pass | 6 pass | 2 **fail** | 3 **fail** |
| mcp | 3 pass | 1 pass | 1 pass | 1 pass |
| tools | 4 pass | 1 pass | 0 pass | 1 pass |
| cap | 3 pass | 2 **fail** | 3 **fail** | 2 **fail** |
| ext | 2 pass | 5 **fail** | 6 **fail** | 6 **fail** |
| codemode | 29 pass | 17 pass | 10 pass | 8 pass |
| events | 34 pass | 2 pass | 2 pass | 3 pass |
| client | 381 fail* | 196 fail* | 166 fail* | 128 fail* |
| conformance | 69 pass | 16 pass | 9 pass | 10 pass |
| tui | 19 pass | 11 pass | 10 pass | 10 pass |
| lint | 3 pass | 0 pass | 1 pass | 0 pass |

† The `host` row is the measurement *before* the fix in the census
below. Re-run afterwards, `host` passes at N=1, 4, 8 and 16, three runs
each. Its row is left as measured so the census has something to point at.

\* The `client` package fails at N=1 as well, on
`client@extension_test:real_jailed_build` — the fixture extension's hermetic
build is refused by the sandbox helper in this environment. That failure is
present in the baseline and is not caused by parallelism, so `client` is
read below by comparing its *other* failures against the sequential run
rather than by its exit status.

The `client` package was run three times at each parallel setting, because
one run of a 1,463-test suite is not evidence about races. Its times were
196/195/201 at N=4, 166/164/166 at N=8, and 128/124/124 at N=16 — tight
enough that the elapsed figures are trustworthy even where the pass/fail
result is not.

### What the timings say

Four packages carry almost all of the wall-clock cost, and all four
improve substantially:

- `client` 381 → 128 seconds (3.0x at N=16)
- `conformance` 69 → 9 seconds (7.7x at N=8)
- `runtime` 53 → 8 seconds, but not correctly above N=4
- `storage` 36 → 3 seconds (12x at N=4), `session` 33 → 1, `events` 34 → 2

Returns flatten between N=8 and N=16 everywhere. `client` still gains
(166 → 126 mean), but `conformance`, `tui` and `codemode` are level or
marginally worse, and `storage` gets *worse* and starts failing. The
suites that gain most are the ones whose tests spend their time waiting —
on SQLite, on sleeps inside fixtures, on process deadlines — rather than
computing, which is where an extra scheduler has something to overlap.

Restricting to the fourteen packages that pass at both N=1 and N=8, the
sequential column sums to 239 seconds and the N=8 column to 40. That is the
size of the prize on the part of the tree the flag already works for. The
remaining six packages hold another 469 sequential seconds, almost all of
it `client`, and none of it is collectible yet.

---

## The census

Every test below fails under `LOOM_TEST_PARALLEL` and passes without it,
grouped by the thing it collides on. The resource in each case was read out
of the test and the code under it, not inferred from the failure text.

### The VM-global atom counter

`erlang:system_info(atom_count)` is a node-wide number. Three tests assert
that it does not change across a measured window, which is only true if
nothing else in the VM is creating atoms during that window. Under
parallelism something always is, most obviously other tests loading modules
for the first time.

- `packages/runtime/test/runtime/service_lifetime_test.gleam:70`
  `repeated_sessions_execute_and_close_without_atom_growth_test` (fails from
  N=8)
- `packages/runtime/test/runtime/registry_test.gleam:28`
  `allocating_strand_addresses_does_not_grow_atoms_test` (N=16)
- `packages/runtime/test/runtime/registry_test.gleam`
  `factory_replacements_use_live_handles_without_new_atoms_test` (N=16)

**Follow-up, not fixed.** The property these tests check — that closing a
session leaks no permanent routing atom — is real and worth keeping, and
there is no local edit that makes a global counter private. Either these
three run in their own sequential group, or the measurement has to change
to something scoped to the code under test.

### The capability channel's `persistent_term` slot

`packages/cap/src/cap/internal/dispatch.gleam:16` installs the capability
channel into a VM-global `persistent_term` slot, and the module says so:
"The channel and token live in a VM-global slot." Every test that installs
a fake channel writes that one slot, and `reset()` clears it. Two such tests
running at once each see the other's channel, or none.

In `cap`, 11 of 65 tests fail at N=4. The ones EUnit named:
`cap_test:fs_read_ok_test`, `fs_read_not_found_test`,
`fs_read_channel_down_test`;
`cap@mcp_test:absent_is_error_reads_as_success_test`,
`invoke_wire_shape_is_pinned_test`; `runtime_test:boot_round_trip_test`,
`boot_drops_unknown_id_test`, `boot_malformed_frame_settles_in_band_test`;
and `strand_test:a_result_shape_crosses_as_field_descriptors_test`, whose
failure surfaced inside a spawned helper.

In `ext` (3 failures at N=4), through `start_serving` at
`packages/ext/test/ext_test.gleam:505`, which calls `cap_dispatch.reset()`:
`a_cap_call_presents_the_invocation_token_test`,
`a_recall_carries_the_key_alone_test`,
`a_remember_carries_the_key_and_the_rendered_value_test`.

**Follow-up, not fixed.** The single slot is a deliberate property of the
capability prelude — it is what stops a surviving process from picking up
the next execution's token — so this is not a test bug to patch. These two
packages are simply not parallelizable as written.

### The shared `httpc` profile

Both HTTP clients route through a single named `httpc` profile, which is one
manager process with one connection pool per VM.

`provider` uses httpc's **default** profile and, at
`packages/provider/src/provider_ffi.erl:383`, reads the global
`httpc_manager__handler_db` ETS table to find the handler for a request —
a dependency the comment there calls intentionally confined. Concurrent
tests put several in-flight requests on that one profile, and the
handler-identification logic answers about the wrong one:

- `production_handler_capture_ignores_busy_unrelated_handler_test` fails at
  N=4, 8 and 16 — the most direct statement of the collision, since "an
  unrelated busy handler" is precisely what a concurrent test now supplies.
- `production_cancel_never_follows_a_redirect_to_hanging_peer_test` (N=4,
  `packages/provider/test/provider/http_test.gleam:370`),
  `production_cancel_survives_httpc_manager_restart_test` (N=8) and
  `production_fast_terminal_preserves_normal_drain_reason_test` (N=16) join
  it, one per setting. All four live in
  `packages/provider/test/provider/http_test.gleam`.

`broker` owns a private profile (`?EGRESS_PROFILE`,
`packages/broker/src/broker_ffi.erl:268`) rather than the default one, but
it is still one profile shared by every concurrent egress request in the VM:

- `broker@egress_test:injects_a_credential_only_for_the_origin_it_is_bound_to_test`
  (N=8 and N=16, `packages/broker/test/broker/egress_test.gleam:405`) fails
  with `failed_connect` against the second of its two TLS origins.

**Follow-up, not fixed.** The profile is shared because production shares
it. A test-local fix would mean a profile per test, which is a fixture
restructure rather than a mechanical edit.

### One scratch directory asserted to be empty

`packages/broker/test/broker/integration_test.gleam:308`,
`real_helper_policy_file_unlinked_test` (fails at N=8 and N=16). The test
asserts that `build/integration/tmp` is empty after its own helper exits,
which is how it proves the helper's policy file was unlinked. Every other
test in the suite that spawns a real helper writes its policy file into that
same directory. Sequentially each file is gone before the next test starts;
in parallel a sibling's live file is sitting there and the assertion sees a
non-empty listing.

**Follow-up, not fixed.** The assertion is about a directory, so the fix is
to give each helper its own tmp root through `with_real_helper` — a change
to the fixture rather than to this test, which puts it outside what this
work touches.

### A scratch root named by a millisecond reading — *fixed*

`packages/host/test/host/bootstrap_test.gleam:13`. Three tests call the same
`root()` helper, and each deletes the whole directory when it finishes. The
name was `build/host-test-é-<system_time_ms>`, so two calls landing in the
same millisecond named the same directory and one test's cleanup removed the
other's fixture mid-assertion. Sequentially the calls are far enough apart in
wall-clock time that this never appeared; in parallel two of the four tests
in the module failed with `enoent` on a file they had just written, at every
setting tried.

Fixed by appending a random component, which is what the helper always
meant. `host` now passes at N=1, 4, 8 and 16, three runs each.

`packages/client/test/client/tui_e2e_test.gleam:437` derives a root the same
way and is the other instance of the pattern in the tree. It has not failed
in any run here, so it is left alone; if `client` is ever parallelized in
earnest it is the first place to look.

### In-test deadlines and ordering assumptions, not shared state

These fail under load without colliding on anything shared. They are grouped
together because the fix in each case is to the test's own timing
assumption, and none of them is mechanical.

- `packages/storage/test/storage/sqlite_test.gleam:342`
  `racing_creates_write_one_catalog_row_test` (N=16 only). The test spawns
  eight of its own racers and waits on `process.receive(results, 10_000)`.
  At N=16 on 32 cores the emulator is oversubscribed by the other tests and
  a racer misses that fixed 10-second deadline. `scale_timeouts` does not
  reach a `process.receive` inside a test body.
- `packages/client/test/client/daemon_manager_test.gleam:577`
  `reserved_creation_requires_explicit_retry_after_capacity_refusal_test`
  (once at N=4, once at N=8, out of six runs). After stopping the session
  holding the only capacity slot and awaiting `Saved`, the retry is still
  refused with `Capacity`: reaching `Saved` does not imply the slot has been
  released, and only an uncontended scheduler hides the gap.
- `packages/client/test/client/tui_approval_effect_test.gleam:469`
  `tui_approval_effect_two_approvals_execute_once_test_` (once at N=8, out
  of six runs). The captured drive neither completed nor timed out within
  its window.
- `packages/client/test/client/history_test.gleam:302`
  `an_unopenable_index_starts_and_repairs_in_band_test` (once at N=4, out
  of six runs). The restart over the repaired file reports the index still
  unopenable. Its scratch path is unique to the test and no other test
  touches it, so no collided resource was identified; recorded here as an
  observation rather than a diagnosis.

**All follow-ups.** Each would need either a longer deadline, a retry, or a
sleep, and adding any of those to buy a green parallel run would be paying
for the flag with a weaker test.

### Not a parallelism failure

`client@extension_test:real_jailed_build`
(`packages/client/test/client/extension_test.gleam:902`) fails at N=1 too:
the hermetic build is refused by the sandbox helper in this environment. It
appears in every `client` row above and is excluded from the counts.

---

## What the data recommends

**No default should be turned on yet.** Seven of twenty packages fail under
the flag, and three of those (`cap`, `ext`, `provider`) fail from N=4 for
structural reasons that no test edit will remove.

For a developer who wants the flag today, the data supports three tiers:

- **N=8 is safe and worth it** for `session`, `events`, `conformance`,
  `codemode`, `tui`, `machine`, `prompt`, `telemetry`, `core`, `mcp`,
  `tools`, `lint` and `host`. All pass at every setting tried; the first
  five are where the time actually is.
- **N=4, and no higher, for `storage`, `runtime` and `broker`.** Each gets
  most of its speedup there — `storage` 36 → 3, `runtime` 53 → 12, `broker`
  17 → 6 — and each starts failing above it.
- **Leave `provider`, `cap`, `ext` and `client` sequential.** `client` is
  the tempting one: it is the single most expensive package in the tree and
  it drops from 381 to 128 seconds. But it produced three distinct extra
  failures across nine parallel runs, and a suite that fails one run in
  three is worse than a slow one.

Nothing above N=8 pays for itself anywhere. `storage` regresses and starts
failing, `conformance`, `codemode` and `tui` are flat, and the one package
that still improves at N=16 is `client`, which cannot use the flag at all.

**What would have to change before a default could flip on.** In rough
order of what it buys:

1. The three `atom_count` tests need a scope narrower than the node, or an
   escape hatch that keeps them sequential inside an otherwise parallel run.
   EUnit has `inorder` for exactly this, so a per-module opt-out is the
   cheapest shape.
2. `cap` and `ext` need the capability channel to be reachable per-process
   in tests, or they stay sequential permanently. Given the slot's security
   purpose, staying sequential is the honest answer.
3. `provider` and `broker` need a private `httpc` profile per test rather
   than per VM.
4. The four in-test deadlines need to stop being wall-clock assumptions.

Only after (1) and (4) would a per-package default be worth encoding in the
Makefile, and it would then have to live beside the package rather than as
one number for the tree, because the safe N is not the same everywhere.
