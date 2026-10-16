# Current handoff

Baselined October 16, 2026 on `6430703a98c6371020c09aedb5b067e8c5c570aa`,
which includes performance PR #991, model/profile completion PR #992 and the TLS
options encoding fix PR #993. Their remaining operational work is recorded in the
[baseline handoff](https://github.com/Roasbeef/loom/blob/6430703a98c6371020c09aedb5b067e8c5c570aa/docs/next.md).
No installed daemon or user session was changed during this work.

## Strand notes in the web view

The current branch adds a dedicated Notes tab to the resizable panel. The owner
requested this separate tab so advisor information does not clutter the reader.
The [design record](design-notes/strand-notes.md) records the independent selection and links to the candidate and production
screenshots in [PR #990](https://github.com/Roasbeef/loom/pull/990). Images are not
part of the branch's commits.

The browser reuses the existing bounded notes command and shared presentation.
It searches available keys and text, opens a note, preserves the query and browser
position on return, and exposes the exact supplied raw value. Complete values use
the safe Markdown renderer; excerpts remain literal and explicitly incomplete.
Snapshot and cell revisions are separate. Omitted cells are counted, and search
never claims to cover them. There is no editing or full-value fetch.

`step.update_retaining_surfaces` transfers surface-fact custody to the web host;
`component.settled` adopts matching notes replies and forgets the facts. The
existing `step.update` behavior is preserved. A focus change clears the departing
strand's queued notes request as well as its presentation. Row identities are
numeric, stable across filtering and refresh, and never reused across focus
changes; removed keys are pruned. Observer input is admitted only at the exact
notes search path, with read-only clicks confined to the appended pane.

## Verification and remaining boundaries

Before this rebase, the web-view gate passed 1,009 tests, the shared reducer gate passed 487,
and the browser-client gate passed 296. The client web-UI route/socket sweep
passed 383 tests. Lint passed with zero errors and the existing warning census.
Generated web assets passed their integrity gate. Removing either the queued-read
reset or surface-fact custody made its real-lane regression fail at the expected
assertion; restored source passed all eight focused notes tests.

One fresh independent adversarial review found an obsolete queued notes read
surviving a focus change. The one-field fix and real-lane regression were verified
by the same reviewer. Its follow-up check also approved the existing Markdown
renderer and memo used for previews.

The production Lustre components were exercised in a disposable localhost
WebSocket harness with representative notes replies, including readable/raw
inspection, filtering, back navigation and empty/excerpt states. These captures
are fixture-backed evidence, not a deployment or a read of an operator's session.

PR #990 is rebased on this baseline. Its current head requires fresh hosted CI,
Linux signoff and integration review before the authorized merge. Installation and daemon restart remain
owner actions.
