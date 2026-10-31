# Mermaid failure diagnostics

Baseline: `678aefa489da9d4bd9fa5c633b7a072097a7821c`. Source commit:
`9b29a49cd`; generated assets: `aad5efc49`.

A sequence diagram failed because `Loop` was parsed as the reserved `loop`
keyword and a semicolon split its message. The frame discarded both parser
errors and the parent showed only the generic source fallback.

The implementation keeps the exception's string `message`, truncates it to
2,000 Unicode code points in the child reply and independently in the parent,
and draws it through `html.text` above the open source disclosure. The parent
accepts at most 12,512 UTF-8 bytes, enough for worst-case JSON escaping and the
fixed envelope. Exception objects and stacks stay inside the frame. The
[protocol 091 addendum](../../protocol-change/091-isolated-mermaid-diagrams.md#addendum-failure-diagnostics-2026-10-30)
records the extended internal contract; the sandbox and content policies are
unchanged.

## Verified

- `make check-web_mermaid`: 22 controller tests and five FFI checks passed.
- `make check-web_client`: 320 tests and the reconnect transport check passed.
- `make check-web_view`: all 1,336 tests and generated-asset checks passed.
- `make lint`: zero errors; existing non-gating census warnings remain.
- `make doc-check`: zero errors; existing documentation warnings remain.
- `make gen-client` and `make client-check`: the rebuilt asset digests pass.
- `bash -n scripts/web_mermaid_check.sh` and source whitespace checks pass.

The FFI regression was also run against the original binding. It fails with
`undefined` where the parser message is required, then passes with the repair.
Controller and parent tests cover stale/current failures, late replies after a
timeout, clearing errors on source/theme change, malformed and older replies,
Unicode code points, combining characters and worst-case JSON escapes.

The real browser drive, `scripts/web_mermaid_check.sh`, passed all 28 checks
against a freshly built disposable daemon and the scripted provider. It
rendered flowchart/sequence diagrams under the actual HTTP content policy,
showed each screenshot syntax error with its parser diagnostic, preserved line
breaks and source text, and recovered after invalid and oversized source. The
markup check requires literal `<img` in the real vendor diagnostic and zero
child elements, so it cannot pass merely because the parser omitted the
snippet. Theme changes, disconnect/reconnect and the original iframe isolation
checks also pass. Foreign/stale failure replies were injected into an existing
failed display; active-render stale failures are covered by the unit test.

The strengthened markup witness initially failed because Mermaid's short error
excerpt clipped `<img` off the longer input. The final input is `<img src=x>`,
which keeps the literal marker in the excerpt. No production change was needed.

## Independent review

One fresh report-only pass found no production correctness or security issue.
It found two browser-test defects: an exact-source assertion ran after later
inputs replaced the source, and an injected-message assertion ran before the
scheduled DOM update. Both were verified and fixed before the final browser
run. The reviewer also passed nine compiled child-to-parent boundary samples
and found no nearby diagnostic-to-markup or stale-publication variant.

## Remaining validation

`make check-affected` selects the full repository gate because the browser
script is build/test machinery. That run is in progress. Focused results above
do not establish a full repository pass or hosted/Linux signoff. No installed
daemon was updated and no merge was performed.
