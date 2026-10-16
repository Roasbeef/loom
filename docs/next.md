# Current handoff

Baselined October 15, 2026 against main
`054816c5b9b57f0a3ea343e4158a2a074f3ec015`, which merged PR #991.
The previous handoff's instruction to merge the performance PR is obsolete.
Its measurements, recovery rulings and open retention investigation remain in
the [performance handoff](https://github.com/Roasbeef/loom/blob/054816c5b9b57f0a3ea343e4158a2a074f3ec015/docs/next.md)
and `docs/review/poll-reload-2026-10-14.md`.

## TLS options encoding

The options writer emits UTF-8, but OTP's `ssl_dist_sup:consult/1` defaults an
unmarked file to Latin-1. Erlang's `~p` can print a binary pin as a quoted
Latin-1 string, so consulting the generated file can change its bytes.
The exact options comparison then refuses boot with `options_mismatch`.
This is a fail-closed availability bug found during #991's macOS validation;
its fix belongs to this separate PR at the owner's request.

The writer now declares UTF-8 before the Erlang term. Pin verification, PKIX,
node-name checks and the exact options comparison retain their existing rules.
The deterministic regression uses the production encoder and OTP's actual
reader for all 256 repeated-byte 32-byte pins, checking the callback and exact
pin in both TLS roles. The fixture fails against the original encoder and
passes with the declaration. Existing positive and negative handshake tests
remain unchanged.

## Remaining gates and work

All 35 selected distribution tests passed, including the unchanged positive
and negative handshake scenarios and live-ledger distribution scenarios.
Formatting, client lint (zero errors), documentation checks and independent
adversarial review passed. Hosted CI and normal/containerised Linux signoff
still need to pass for the published head. Read saved macOS logs and actual skip censuses: advisory green badges
alone do not prove `make check` passed. The PR carries current validation
status; this source checkpoint is not merge evidence.

The installed daemon has not been updated or restarted. A comparable live
Pickglass capture still requires operator authorization to deploy. CPU,
cumulative allocation, retained memory and RSS remain separate claims; no
additional retained-memory reduction was established by #991. Field-level
attribution in an isolated representative release is the next memory
experiment, as recorded in the performance report.
