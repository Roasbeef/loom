# Complete report codec review

The pure report codec separates complete program values from the bounded
ToolResultMessage used in the transcript. It supplies checked terminal,
metadata, bundle and reference constructors. Storage custody, terminal framing,
preview rendering and authenticated reads are separate integration obligations.

## Independent review and correction

Astra reviewed the frozen codec and found one reachable portability defect:
JavaScript callers could construct NaN or infinite FloatValue terms, while the
codec's own decoder refused their encoding. The constructor now rejects every
nonfinite binary64 value before encoding. This uses a pure range comparison;
core gained no FFI or process dependency.

The independent corrected replay passed 185 Erlang tests and 72 explicit Node
checks: 24 nonfinite constructor refusals and 48 finite admission/readback
checks, including subnormals and signed zero. Removing the finite guard still
compiled on both targets and failed all 24 refusals. Earlier compiled mutations
also exercised the shared recursive node budget, canonical encoding and array
length bounds. Those three controls preceded the isolated finite correction.
A differential control compared the extracted native scanner against its
original implementation over 77,648 inputs without a changed answer.

## Root integration

Root verified the five frozen file hashes against their baseline before copying
them into the integration branch. The corrected report module's SHA-256 was
`51f805c912e2a8bab4a1aa18c368e6473534af42c717293b0ee18244e7741394`.
The only subsequent source edit clarified that the MessagePack decoder, after
raw scanning, rejects nonfinite encoded floats.

`make check-core` exited zero with 185 Erlang tests and the same 72 Node checks.
The Node regression is now part of the normal core gate, with bounded build and
execution deadlines. The Erlang build remains warning-free. The supplemental
JavaScript build reports existing and new unsafe-u64 literal warnings: exact u64
metadata custody on JavaScript's Number representation is not established.
The test covers finite-float admission, not that separate numeric limitation.

## Limits

A canonical reference proves shape, not existence, session ownership or digest
agreement with stored bytes. The authenticated owner must check those facts.
Logical codec limits do not establish a resident-memory ceiling. These tests do
not prove SQLite commit behavior, physical cleanup, actual power-loss durability
or the assembled distributed runtime. The
[retention design](../design-notes/distributed-final-results.md) records those
separate obligations and the implementation budgets.
