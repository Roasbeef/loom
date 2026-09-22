# Code-mode utilities review

The follow-up starts at `c14a27b3` and adds both-seam server defaults, report
JSON conversion, bounded strand.map, and executable agent-facing recipes.
Protocol 046 records the API and partial-progress behavior. The existing
notes implementation is the baseline rather than part of this review.

## Independent review

One independent read-only pass examined the working tree and untracked files
for child custody, concurrency bounds, JSON fidelity, and authority changes.
It found no actionable issue or warranted simplification. Map's serial
admissions retain every returned handle, batch joins validate handle identity
and ordering, and pending/failed joins stop subsequent admissions. Defaulting
to both leaves per-submission allowlists, routers, ceilings, and Agency
lineage/depth enforcement intact. JSON conversion preserves numeric tags,
object order, and null while refusing non-JSON data and excessive nesting.

After that pass, the duplicate-key check was changed from a dictionary-size
comparison to a short-circuiting dictionary fold. Its semantics are unchanged;
it avoids retaining object values and the bounded-length lint warning.

## Validation

All 97 capability tests passed. The server-default regression and the real
jailed advertised-recipes fixture passed. The recipes are checked byte-for-byte
against their documentation files and executed from the exact strings included
in the model-visible description. Child responses are scripted at the Agency
boundary; note storage, conversion, vetting, compilation, routing, and jail
execution are real. The workspace recipe's exported JSON is checked on disk,
and a fresh workspace execution reads back the orchestration recipe's note.

The first complete run found one client failure: expanding the system prompt
raised it to 8837 bytes, beyond its existing 8500-byte budget. The other 2038
client tests passed. The prompt was condensed to point to the detailed tool
recipes, and the unchanged affordability regression now passes. The final complete
`make check` passed with exit zero against that correction: 2039 client,
609 TUI, 514 tools, 97 capability, and 306 code-mode tests, with zero lint
errors and 818 warnings. Generated-prelude and documentation checks passed. Hosted CI and Linux jail validation
have not been run for this follow-up. No installed daemon was changed.

The preceding PR head's Linux client job failed only
`layer_cleanup_uses_one_deadline_for_failed_starters_test`: its elapsed-time
assertion expected less than 500 ms and observed 1129 ms. That MCP cleanup
path is unchanged here; this is an observed prior CI failure, not proof of
a code-mode regression or a confirmed flake. The new head requires its own
CI result.
