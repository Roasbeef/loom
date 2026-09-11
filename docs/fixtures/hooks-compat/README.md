# Hook compatibility fixtures

Contract fixtures for the imported-hook layer (issue #350): the
payload shapes, decisions, failures, timeouts, multiple-matching-hooks,
and async cases the acceptance asks to be compared against the pinned
Claude contract (`docs/design-notes/claude-hooks-contract.md`).

Each fixture names the contract row it pins and the module whose tests
hold the assertion. They are inputs and expected outputs — the tests
read them directly, so a fixture here is executable documentation.

## The collection

| Fixture | What it pins | Asserted by |
|---|---|---|
| `settings-user.json` | A real-shaped user-level Claude settings file: nine events, all five handler kinds, both matcher paths, exec and shell forms, async, timeouts | `hookcompat_test` (both-shapes test parses it and the paired TOML to one model) |
| `settings-user.toml` | The same collection in the native `[[hooks.Event]]` shape, written the way `loom hooks convert` renders it | `hookcompat_test` (round-trip: `parse_loom(to_toml(c)) == c`) |
| `decisions/*` | One file per event's output contract: exit-2 blocking, `hookSpecificOutput` decisions, `additionalContext`, `updatedInput`, `updatedToolOutput`, plain-stdout context, timed-out-discards | `hookdecisions_test` (each row is one named test) |
| `owner-collection.json` | The owner's real `~/.claude/settings.json` hook entries, verbatim, as the end-to-end demo's input — the primary acceptance case: this file loads and runs **unedited** | the e2e demo script |

## Running the demo

`demo.sh` boots a Loom session against a workspace carrying
`owner-collection.json` and drives one turn per composed gate:
SessionStart context injection, a PreToolUse gate on a bash call, a
PostToolUse check on a write, a PreCompact note, and a Stop
continuation that holds the run open until its check passes.

The demo needs the host's jailed executor: it does not run inside a
nested sandbox (see the parity matrix's "What is verified where").
