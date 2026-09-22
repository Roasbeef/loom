# Code-mode notes review

The change starts at `543d641a` and adds a host-installed data door to the
default workspace code-mode surface. It reuses the existing Agency blackboard,
with typed put/get/list calls and a read-only JSON view through cap/fs.read.
Protocol 045 records the contract. The installed daemon is outside this change.

## Independent review

A read-only design consultation required host-dependent import and prompt
advertisement, exact-key filtering after prefix lookup, and a separate metered
notes.read operation for virtual reads. It rejected expanding cap/strand into
the workspace surface, adding an OS mount, or granting extension hooks note
writes. Those restrictions are implemented in the shared data door.

The final independent review found one reachable key-boundary bug: Agency
accepted a 128-character write key, while its read validator applied that same
bound after the strand namespace was prepended. The fix preserves the write
limit and allows namespace-qualified read prefixes up to 4096 characters,
retaining the alphabet check and mandatory agent/ namespace. A regression
writes the maximum-length key, obtains its relative name from list, then feeds
that returned name to get and the virtual-read router. It also tests the new
read bound. The reviewer verified this fix and found no additional actionable
invariant, simplification, or nearby variant issue. A follow-up duplicate-key
scenario was dismissed: the complete inbound frame passes through msgpack's
recursive uniqueness and depth checks before any capability router runs.
The notes router retains only the necessary binary/non-text-key conversion
checks, avoiding a redundant serialize-and-parse pass.

## Verification

The cap suite passed all 89 tests. The final focused client wiring suite passed all
65 tests, including real Agency reads/writes, exact-prefix separation,
caller-namespace binding, invalid JSON rejection, and the maximum byte boundary.
The maximum-key regression also passes.

A real jailed fixture writes nested analysis from the documented program,
closes the SQLite runtime, reopens the database, and runs the documented reuse
program in a fresh satellite. The typed read and JSON view agree, and a third
program reaches the virtual-read admission limit. This fixture passed without
skipping. The first iterations caught and corrected two example-only compiler
errors, rather than treating a substituted capability call as an end-to-end run.

The complete `make check` gate passed with exit zero, including 2037 client,
609 TUI, and 306 code-mode tests. Lint reported zero errors and 818 warnings.
After the last assertion and boundary-test refinements, the focused wiring
and real jailed fixture were rerun. The doc gate has zero errors and
152 existing warnings. Linux jail enforcement and hosted CI have not been run;
the local real-program tests use macOS Seatbelt with the platform's reported
resource and process-lifecycle limitations.

## Follow-up: preserve blackboard read failures

The PR review correctly identified that Agency's shared notes_under helper
converted api.facts errors into an empty list. This affected direct notes
and the saved notes attached to child joins. It could turn a storage failure
into None, an empty list, a virtual not_found, or an absent child result.

The helper now returns Result and maps the runtime error to PlaneFailed.
Both callers propagate the refusal through their existing Result interfaces.
No RPC or public type changed. The independent review found no actionable
issue in the fix and confirmed that all notes routes already preserve refusals.

A regression writes a real note, injects backend and corruption errors in
storage.list_registers behind the real writer/Agency, then verifies plane_failed
from notes.get, notes.list, and notes.read. It failed against the original
implementation and passed with the fix. A second regression saves a completed
child's structured result and verifies that a failed note scan refuses its join
instead of reporting ResultAbsent. Both focused tests passed, followed by `make check-client` with all 2041
tests passing, client lint with zero errors, and documentation checks.
