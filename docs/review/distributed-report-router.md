# Owner-local complete-report reader review

The optional code-mode report reader pins a concrete owner and authenticated
session. One configuration choice installs its capability declaration, route and
per-invocation ceiling. Both Workspace and Orchestration receive that choice;
Extension and Resident do not. No executor workspace can supply report authority.

The only route accepts exactly a result reference and aligned offset. Known
malformed, foreign-session or missing references never fall through to workspace
routing. Owner custody independently checks original entry, digest, length and
admitted final association before a named SQL query returns its bounded slice.
Unknown capabilities preserve the original request for the existing router.

Replies use ScopedService, retaining the satellite's existing task, deadline and
cancellation behavior. The router creates no retry loop, quota actor or renewed
budget. Each complete framed response is checked against 66,048 bytes; using the
maximum admitted u64 wire ID proves the envelope allowance without mistaking the
admission ordinal for that ID. One host ceiling allows 261 calls across all
references, bounding aggregate serialized replies to 17,238,528 bytes.

## Evidence

Independent Astra review found no actionable defect. Eight actual owner/router
controls, the optional configuration control and six existing ScopedService
lifetime controls passed. Nine compiling mutants failed their intended checks,
covering session validation, missing identity, known-route fallback, response
width and removing the composition's route, declaration or ceiling.

Root's current focused client replay passes 101 tests with no skips, including
the renderer, report custody, routing and configuration controls. The original
router freeze digest is
`57d7f1e6104560331f29d1ad3c012454f95e5ee5c0acf754da018417675aac28`.
Its fixture subsequently adopted the actual prefixed compiler fingerprint; the
router implementation remained byte-identical and independent replay passed.
The independent review digest is
`432d5b7e2b0ab6dc7a11e28b959d1a830cfbeb0f048d168e5b2f22b266f6c39d`.

These controls establish the component and optional configuration, not default
registered-daemon availability. Actual jailed result retrieval and quota
exhaustion are the next integration gate. Companion archive/restore/compaction,
remote Launch and separate-host acceptance remain required.
