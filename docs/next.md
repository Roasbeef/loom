# Current handoff

Baselined October 14, 2026 against main
`3ee679ca7b7a36bb2e518f4494214de364217e7b`. The owner requested one combined
merge of login PR #985, Fast-mode PR #987 and keepalive PR #988 through #985.
Their reviewed commits are preserved as merge parents. Main's register cache,
Responses diagnostics, deployment enforcement, per-strand timing and capture
archive remain intact; their detailed rulings and recovery commands remain in
the [pinned main handoff](https://github.com/Roasbeef/loom/blob/3ee679ca7b7a36bb2e518f4494214de364217e7b/docs/next.md).
The project plan remains `docs/issue-plan.md`.

## Confirmed login bug

Fresh native sign-in failed `invalid_identity_issued_in_future` with zero clock
tolerance. With five seconds, fresh browser login succeeded. Signed regression
fixtures cover the exact issued-at, not-before and expiry boundaries under UTC
and America/New_York. Signature, algorithm, issuer, audience, authorized party,
nonce, subject and account binding remain mandatory. Fixed refusal codes discard
untrusted error payloads. A displayed timezone does not alter UTC JWT timestamps.

## Confirmed stream bug

A real native stream sent `keepalive` at sequence 343 and was rejected as
`event_unsupported`, aborting after 57.46 seconds before its 60-second deadline.
The fix consumes only that fixed control after JSON, SSE-name and sequence
validation. It emits no content and preserves item, usage and terminal witnesses,
cumulative bytes and the absolute attempt deadline. Unknown semantic events
still fail; keepalive cannot settle an unfinished response.

The patched native stream crossed keepalive at 333, completed canonically at
338 and settled in 54.73 seconds. The loaded adapter BEAM and source were checked
against `489fd0703`. The probe used a known synthetic prompt and executed no tools
or private audit context. Original screenshots match the failure class and shape,
but their unknown event names were not retained, so not every historical error
is attributed to keepalive. Observed real-session recovery alone was not treated
as a code fix.

## Optional Fast mode

Responses model entries accept `service_tier = "fast"` or `"default"`; omission
preserves provider defaults. Fast mode sends the documented `priority` alias
because native subscription inference rejected the newer `fast` wire spelling.
A live priority request completed but reported the served tier as `default`,
so eligibility and a speed improvement are not established by configuration.
Each fallback sends its own selection. Reasoning and cybersecurity access are
independent. Fast processing can consume more allowance or cost more; configured
price estimates are not authoritative subscription charges. This integration
does not enable Fast mode in the owner's configuration.

## Prior evidence and current gate

Each individual change passed one independent adversarial review. Login's
rebased source and tests were byte-identical to its reviewed original, and the
integration review preserved main. Its 34 focused tests passed and affected gate
passed in 737 seconds. The keepalive provider suite passed 309 tests; removing
only its no-op made the new regression fail as intended. Fast mode's provider
suite passed 308 tests, its focused catalogue cases passed, and its affected gate
passed in 589 seconds. The scoped Linux remote-move reproduction passed all four
variants after an earlier full Fast signoff hit an unchanged options-file refusal.
These are individual-head results, not signoff for the combined head.

A prior login macOS advisory retry had no assertion failures but reached the
client's 1,200-second suite deadline. Its successful job does not establish a
completed suite. Current main uses a two-shard macOS client matrix; inspect both
raw logs before describing the combined checks. Existing owner-approved deadline
policy cannot excuse unexplained assertions.

The owner revised the merge criteria to focused affected tests and integration
review, explicitly choosing not to wait for the full gate. The combined provider
suite passed all 311 tests and the Codex authentication group passed all 34.
Catalogue tests passed 134 cases and gateway tests passed 153. Formatting,
focused provider/client lint, documentation checks and independent integration
review passed; the review found no actionable integration issues or lost tests.
Full combined hosted CI and Linux signoff
are not established by those results. No installed daemon, operator configuration,
audit tools or hooks have been changed or executed by this integration.

## Next steps

1. Publish the combined head and update PR #985's scope and the focused
   validation evidence recorded above.
2. Merge the exact reviewed head using the normal merge path, as authorized
   after focused checks. Do not claim the full gate passed. If branch protection
   prevents the merge, report its actual refusal before considering a bypass.
3. Verify main contains all three reviewed changes, report the merge and stop
   the follow-up. Installation and daemon restart remain separate owner actions.
