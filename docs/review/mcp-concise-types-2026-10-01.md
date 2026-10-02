# Concise typed MCP generation

Status: package tests, independent review, full local macOS signoff, and an
isolated daemon-to-Jevelin HTTP fixture passed at `ac0c26ca`. Hosted checks
remain outstanding. The fixture did not call the live Jev service.

## The public API problem

The first typed renderer exposed trusted node ordinals and full schema paths as
public names. Tagged object branches required a wrapper record plus an explicit
literal discriminator enum. Those names preserved identity but made callers
carry renderer bookkeeping. Type safety did not require that spelling.

Generated declarations now prefer nearby schema roles and allocate their names
across the complete module. Every preferred spelling and imported identifier is
reserved before suffix assignment. The renderer retains trusted occurrence keys
internally, so equal preferred names do not merge nominal types and adversarial
suffix spellings cannot capture another declaration. Both source and API prose
use the same allocation.

Required distinct singleton literal tags become constructor-owned values.
`ChoiceQuestion(...)` and `ScoreQuestion(...)` accept their own branch fields;
the encoder writes the tag. Output decoding still requires the exact literal,
checks the object's allowed keys, and proves rendered branches disjoint. Optional
or repeated discriminators retain the ordinary union representation. Genuine
single-branch unions are transparent. Jev state, descriptions, and levels still
have their real string/object/array alternatives, named `StateText`,
`DescriptionText`, and `LevelText` where applicable.

## Measured size

The comparison uses the same captured four-tool listing, not revised schemas or
shortened field documentation. Complete generated API prose falls from 15,163
to 7,832 bytes, a 48.35 percent reduction. Source falls from 40,798 to 26,395
bytes, a 35.30 percent reduction. These are UTF-8 byte counts, not tokenizer
counts. The captured listing and its provenance live in the MCP test fixtures.

## Verification

The MCP gate passed 123 tests. Negative controls for preferred-name reservation
and required literal decoding compiled successfully and then failed their
intended assertions. Their source mutations were restored before the green gate.

Three real code-mode tests compile the documented Jev mixed Choice/Score batch,
assert the complete tool arguments and result, reject incorrect variant fields
and element types before dispatch, and refuse missing/wrong response tags after
an actual call. The exact program in `docs/jev-mcp.md` is the test's source.

A fresh report-only Astra review of `f4c2c994..ac0c26ca` found no actionable
correctness, simplification, or nearby-variant findings. The complete local
signoff passed with its own exit status 0 in 726 seconds, including 2,639 client
tests, 1,052 TUI tests, all other package lanes, enforcement, and release/update
verification. Its declared macOS `/proc` and rust-analyzer exclusions were the
existing ones; no undeclared skip appeared. An initial sandbox dependency fetch
failed before tests; explicit network access resolved it without source changes.

The self-contained release at `ac0c26ca` then booted an isolated real daemon and
launched the installed self-contained Jevelin server. A scripted model discovered
`cap://mcp/jev`, submitted the complete mixed batch through `code_mode`, and
observed the credited durable result. Jevelin made exactly one authenticated
request to a local HTTP fixture. The result was `jev-fixture`, choice `logs`,
confidence 0.9, score 0.25, and usage of 10 input and 3 output tokens. The dummy
credential appeared in no model request. Both build and satellite reported
Seatbelt filesystem and network enforcement; their macOS resource-limit and
process-lifecycle gaps remained explicit. Authenticated shutdown exited zero.

The first driver launch rejected a stale expected release SHA copied from an
earlier resource experiment, before creating a session or issuing any model/HTTP
request. Cleanup exited zero. The corrected driver verified the checkout's exact
release commit and passed. Temporary drivers and evidence remain outside tracked
source; the repeatable channel regressions are committed tests.

## Upgrade boundary

New session runtimes regenerate their modules automatically. Resident sessions
retain the surface assembled at their startup. Stored programs using old names
must read the new `cap://mcp/<server>` surface and update their constructors.
Numeric/string refinements beyond the supported structural schema remain the
server's validation responsibility, as before.
