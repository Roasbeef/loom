# Markdown skills review

The feature through `5626d1b5` is based on merged PR #344 (`329002f1`). It
shares a captured catalogue between daemon prompt admission, the `load_skill` tool and terminal
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

The initial local runs lacked the real code-mode seed and opt-in shipped
bootstrap fixtures. At PR #346 head `45ca3b22`, hosted macOS gates and Linux
package/bootstrap/soak jobs passed. The dedicated Linux signoff passed all six
lanes, eleven enforcement checks and its strict skip census in 495 seconds.

Hosted Linux deliverables exposed a separate packaging regression: glaml 3.0.2
emits `yamerl` twice in its application dependencies, which relx refuses.
The local release reproduced that exact error. Removing glaml's redundant
`extra_applications` declaration passed its six tests and the same release
assembly. Loom pins the correction at `Roasbeef/glaml` revision `084857e`,
with [upstream PR #6](https://github.com/katekyy/glaml/pull/6) open. The parser
source matches the published package. Both Loom release scripts now retain
relx diagnostics. The full local macOS distribution target passed with the
pin, including bundled server and client smoke checks. The corrected head
requires fresh platform checks and Linux signoff; the earlier green signoff does not cover this dependency change.
