# Distributed runtime acceptance

Issue [1137](https://github.com/Roasbeef/loom/issues/1137) tracks repository
handoff, placement, movement and page parity. The owner selected the Depth
workflow on October 29, 2026: an always-on trusted brain or gateway may hold
provider keys, while remote executors remain keyless. A gateway on a sleeping
laptop cannot provide close-lid progress.

## Device sign-in command

Source baseline: `4beaa6d96`. A signed-out page at a listed origin emits
`loom ui --device`, but the copy component rejected that literal and rendered an
empty shadow root. The grammar now admits that exact command beside `loom ui`;
the bounded session form and other subjects are unchanged.

The new positive regression fails with the old production line. A primary
verification restored only that line, ran `scripts/web_client_test.sh`, and
observed exit 1 with the device test failing and the other 317 tests passing.
After restoring the fix, the same suite exits 0 with 318 passing tests; the
reconnect transport check also passes. Added negative cases refuse whitespace,
extra flags, shell separators and command substitution.

The old committed bundle reproduces an empty copy component in Chromium. The
rebuilt bundle renders the exact command and its button at 375 by 812. A real
button click against a recording clipboard API makes one write of
`loom ui --device` and draws `Command copied`. That proves the component's call
to the clipboard API, not a write to the operating system clipboard. The fixture
uses the markup emitted by the root page; `page_test` separately checks that
markup. It does not exercise remote enrollment or device authentication.

`make gen-client` regenerated the bundle and stylesheet. Independent review
found no actionable issues and verified the generated hashes; the stylesheet
body is unchanged. Required affected checks are in progress; their final status
belongs on the PR. No live daemon was restarted or deployed.
