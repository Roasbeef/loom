# Current handoff

## Model and profile autocomplete

Baselined October 14, 2026 against main
`806d0cd20bcab551662195e8d31047de15c407bf` (merged PR #989).
The prior handoff's instruction to publish the Responses diagnostics PR is
obsolete: that change is now on main. Its retained observation limits and
validation are recorded on [PR #989](https://github.com/Roasbeef/loom/pull/989).

The operator composer now offers `/model` as an argument-taking command,
with configured model keys, and completes configured profiles under both
`/profile` and `/model-profile`, retaining `default`. A model changes the
active strand through the existing configuration command; a profile changes
the session's role routing and retains the existing restart behavior.

Session socket attachments carry the same configuration-name readers as the
home page. Operator admission reads them once; observer admission reads
neither. Reopen the page to refresh suggestions after configuration changes.
The daemon still validates every submitted selection. Catalogue names travel
as escaped JSON child text in the composer's `commands` slot, and every
completion label is a browser text node. The editor memo includes both name
lists, and its profiler counts `completion.table_with` rather than the former
static table function.

## Validation and remaining gates

The browser-component suite passed 297 tests. A live generated-bundle fixture
verified command discovery, Tab expansion, arrow/Enter model selection,
profile click selection and alias submission. Daemon compilation and
documentation checks passed. Independent adversarial review found one missing
session-attachment wiring step; it was fixed and the reviewer confirmed the
resolution, with no further findings.

The affected-package gate is running after updating the two render-memo
profiler tests to the new table function. Hosted CI and fresh-container Linux
signoff must pass for the published head before merge. No installed daemon
has been changed. Deployment and restart remain separate operator actions.

Earlier architecture rulings and deliberately open tracks remain in
`docs/issue-plan.md` and the subsystem documents. The prior diagnostics
handoff is preserved in the main baseline above rather than carried here as
pending work.
