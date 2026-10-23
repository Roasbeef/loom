# Reviewed scratch implementation releases

This boundary replaces the implementation of an existing per-session scratch
actor. The actor keeps its PID, mailbox, bounded KV contents and supervision
owner. An authenticated native owner submits an official release tag and exact
manifest digest through `core_upgrade` or `core_downgrade`; `core_status` reports
current identity and PID, or the result of a queued request. Authored extension
candidates never reach this loader.

A reviewed release carries `harness-scratch.json` and one `loom_scratch_a.beam`
or `loom_scratch_b.beam`. The fixed module exports exactly `handle/2`,
`migrate/1` and `version/0`, plus Erlang's two `module_info` exports. It has no
`on_load` callback. Both implementations use the concrete generated
`client/upgrade/state` ABI, boundary `loom.scratch.v1`, state version `v1`, and
the same message envelope. The VM-wide slot owner refuses replacement while
another live actor holds that slot. The builtin implementation stays available.

For a concrete reviewed artifact, compile an Erlang module against the same
Loom build and OTP toolchain as the daemon:

```erlang
-module(loom_scratch_a).
-export([handle/2, migrate/1, version/0]).
version() -> <<"reviewed-v2">>.
handle(State, Message) ->
    'client@scratch':handle_release(State, Message, version()).
migrate(State) -> {ok, State}.
```

Run `erlc loom_scratch_a.erl` after the daemon has started, then compute the
SHA-256 and byte size of the resulting BEAM. Publish those exact bytes alongside
this manifest in a reviewed `Roasbeef/loom` GitHub release:

```json
{"schema":1,"repository":"Roasbeef/loom","release":"reviewed-v2","component":"scratch","module":"loom_scratch_a","version":"reviewed-v2","state_version":"v1","boundary":"loom.scratch.v1","size":1234,"sha256":"REPLACE_WITH_BEAM_SHA256","accepts":["v1"]}
```

Replace `size` and `sha256` with measurements, and supply the manifest's own
SHA-256 in the operator request. No local path, arbitrary URL or raw BEAM input
is accepted. Production builds must use this pinned typed ABI; the manifest's
ABI declaration cannot establish compiler compatibility by itself.

Migration runs as bounded work outside the paused actor. It must be pure:
reviewed code is trusted to avoid effects, since BEAM does not sandbox a trusted
module's calls. This scratch boundary also checks that KV contents, accounting,
limits and inbox ownership remain unchanged. Failure leaves the old state and
callbacks active. A downgrade transforms the current state, retaining writes
made since the upgrade; it never restores a historical snapshot.

The managed custodian owns suspension and resumption, including cancellation
and operation-owner death. Token, expected identity and absolute expiry checks
refuse stale change requests. A completed receipt requires observed resumption
and an exact slot-lease reconciliation. Unknown recovery remains held rather
than authorizing another replacement. Scheduler stalls or noncooperative native
code can exceed wall-clock budgets; these are cooperative BEAM deadlines, not a
hard real-time guarantee. There is no forced purge or general release manager.

`client@upgrade_native_test` compiles fresh BEAM after starting production
scratch actors. It proves callback replacement, stable PID and current-state
contents, queued work, unrelated actor progress, failed migration recovery and
slot conflicts. The fixture intentionally instruments migration to observe the
pause; released migration must remain pure. The test does not claim a full
served-session or kernel-jail integration proof.
