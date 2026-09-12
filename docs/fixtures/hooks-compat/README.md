# Hook compatibility fixtures

Contract fixtures for the imported-hook layer (issue #350): the
payload shapes, decisions, failures, timeouts, multiple-matching-hooks,
and async cases the acceptance asks to be compared against the pinned
Claude contract (`docs/design-notes/claude-hooks-contract.md`).

Each fixture names the contract row it pins and where the assertion
lives. The `decisions/` files are the inputs and expected outputs a
reader can compare against by hand; the tests that pin the same rows
carry their inputs inline, so a file here is documentation of the
contract rather than something a test loads.

## The collection

| Fixture | What it pins | Where the assertion lives |
|---|---|---|
| `decisions/*` | One file per event's output contract: exit-2 blocking, `hookSpecificOutput` decisions, `additionalContext`, `updatedInput`, `updatedToolOutput`, plain-stdout context, timed-out-discards | `hookdecisions_test` — each row is one named test, with its input written inline |
| `owner-collection.json` | That a real collection parses verbatim: the owner's own `~/.claude/settings.json` hook entries, sixteen of them across eleven events, with home paths redacted to a leading `~` as the only change from what was read off the machine | `hookcompat_test` |

The both-shapes parse and the TOML round-trip are pinned by
`hookcompat_test`'s own inline fixtures (`json_fixture` and
`toml_fixture` in that module), not by files here.

## The acceptance proof

The acceptance case of issue #350 — an operator's collection loading
unedited and its hooks firing in a real session — is
`packages/client/test/client/hookserve_e2e_test.gleam`, and it runs
under `make check-client` like any other test.

The fixture boots a real instance through `serve.open_instance`, with
`Settings.home` pointed at a temporary directory it writes. That
directory holds a four-handler `~/.claude/settings.json` whose commands
are all `~/hooks/...` paths, and the stub scripts those commands name.
Three scripted provider replies carry one operation across both
boundaries the gates sit on: a `Stop` hook blocks the first finishable
boundary by exiting 2, a `bash` call then fires `PreToolUse` and
`PostToolUse` and creates the marker the gate was waiting for, and the
second boundary finishes the run. `SessionStart` context and the `Stop`
block's follow-up are both asserted in the provider request bodies,
which is where a message that was never sent could not appear.

A shell demo was here until the fixture replaced it. It asked an
operator to run two commands by hand around a session they drove
themselves, so nothing ever ran it, and three of its steps were wrong
from the first commit: it told the reader to use a one-shot prompt flag
the launcher does not have, its merge of a Stop gate into the collection
did nothing, and it wrote the collection to a source the trust layer
skips. This section records the replacement rather than dropping the
demo without saying so.

The fixture needs the host's jailed executor, the same prerequisite
`hookrunner_test` has: it does not run inside a nested sandbox (see the
parity matrix's "What is verified where").
