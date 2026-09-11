# Markdown skills review

The feature through `5626d1b5` is based on merged PR #344 (`329002f1`). It shares a captured
catalogue between daemon prompt admission, the `load_skill` tool and terminal
completion. The independent review covered progressive disclosure, invocation
flags, prompt custody, authority, bounded metadata pages and attachment changes.

## Findings and disposition

The terminal recognized `/sample` with trailing newlines or tabs while the
server could leave that text unexpanded. Both command-name parsing branches now
trim trailing whitespace, preserving argument bytes. The regression includes
newline followed by space, tab, and CRLF cases.

The malformed invocation-flag test previously failed earlier because its name
did not match the parent directory. It now uses a matching directory and asserts
the exact flag-validation error. The reviewer confirmed both corrections and
reported no outstanding findings.

## Validation

The initial full `make check` completed packages through events before Hex API
rate limiting interrupted client dependency resolution. A continuation of the
remaining gates passed with its own exit status: 16 host, 1535 client, 315 TUI,
77 conformance and 127 lint-package tests, plus native helper format, vet, build
and tests. After the final whitespace fix, all three focused client skill tests
and the joined skills fixture passed again. House-rule lint passed with zero
errors and 659 warnings; documentation checks passed with zero errors and
existing warnings.

The joined fixture uses a real daemon, websocket, terminal loop and deterministic
provider. It proves Tab completion, argument delivery, immutable document capture
across a source-file change, and automatic `load_skill` activation. Unselected
bodies do not appear in earlier provider requests. It runs without a skip.
A virtual display and fixture provider do not establish external-provider or
all-layout native-terminal acceptance.

The installed user library loaded all 34 documents without warnings after a
quoting-only YAML repair to one description. It exposes 33 slash commands and
30 model-selectable skills according to their invocation flags. Referenced
scripts were not executed during discovery.

The three bounded-length lint warnings in the loader compare Unicode codepoint
counts after conversion of a document already limited to 64 KiB. They are
bounded work; replacing the comparison cannot avoid that preceding conversion.
The remaining lint census includes existing project warnings.

Real code-mode fixtures reported the missing seed and opt-in shipped bootstrap
fixtures were not enabled. No single uninterrupted full-gate success, new
hosted CI result or Linux signoff is claimed for this local feature.
