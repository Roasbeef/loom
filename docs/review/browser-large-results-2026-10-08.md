# Browser access to complete tool results

This report records the October 8 implementation on
`fix/browser-tool-output`, based on terminal-fix head `16c3c0ee5`. The user
selected paged viewing plus a full download. PR #925 subsequently merged as
`fa4e45f8b`; issue #924 is handled separately by PR #927.

## Behavior and ownership

The transcript keeps a 300-line/8,000-byte preview. Its Unicode cut now stays
within the byte budget without scanning the complete result into graphemes.
A result offers **View full result** and **Download result**. The viewer loads
one 16,000-byte window of stored JSON at a time, with previous/next controls
and an attachment link. UTF-8 boundaries partition the original bytes; a page
may split a JSON token or a displayed line. Download returns the complete
stored conversation record, rather than only its output field.

`session_view/turns` carries an immutable result entry identity alongside the
outcome it projects. Narrative joins preserve the matching identity, and an
orphan result uses its durable source. URLs remain usable when the transcript
folds or changes focus. No component callback or result ledger is added.

The daemon uses the same keyed page authorization as existing session reads.
Host/fetch-site checks precede its live page grant; lookup uses that session's
resident storage reader, and the grant is checked again before successful
response delivery. An entry ID grants no access to another session. Normal
links name result entries, while the route's read scope remains the authorized
conversation. A download enforces the existing 33,554,432-byte record limit
and one shared five-second read deadline. A short or failed read cannot become
a partial successful attachment. Responses retain no-store, nosniff and the
page content security policy.

The resident reader captures only a storage subject. The preview bounds
rendering and scanning, not all retained memory: an 8,000-byte BEAM subbinary
can retain its larger backing binary. Independent measurement found the same
retention in the preceding string slicing implementation. No resident-memory
savings are claimed, and the installed daemon/client were not replaced.

## Validation

`PATH=/opt/homebrew/bin:$PATH LOOM_TEST_PARALLEL=8 make check-affected
BASE=16c3c0ee5a7a31e419ed4a3b80816f5aad15fb04` returned exit 0 in 329 seconds.
Static checks, prepared seed/binaries/shipment, all selected lanes and the
skip census passed. Counts were 427 session-view, 922 web-view, 272 web-client,
3,090 client, 1,266 TUI and 97 conformance tests. No undeclared skip was accepted.

Five browser result regressions cover Unicode bounds, adjacent byte windows,
escaped navigation, bounded HTML for a 1.62 MB result, and results whose calls
fall outside the transcript window. Three reader regressions cover joined
pages and complete bytes, incomplete-fragment refusal, and a real SQLite
result. Four real HTTP regressions cover bounded HTML and exact attachments,
page-cookie/fetch-site isolation, credential revocation and page expiry.

Chrome visually showed the generated viewer with synthetic Unicode and escaped
script-like text; clicking Next page reached Page 2 of 3. A final CSS-only
adjustment made navigation visibly clickable and keyboard focus explicit.
Assets were regenerated and the complete static gate passed afterward. The
browser automation's synthetic download was canceled; complete attachment
bytes and headers were verified through the real HTTP regression instead.
No private session payload, credential or cookie is included in these fixtures.

The fresh independent review found no HIGH or MEDIUM issue. Both LOW findings
were applied: stale boundary comments were corrected, and the reader became a
required function rather than an optional capability with no absent callers.
The reviewer independently ran four compiled browser tests and three reader
tests, including SQLite; the later orphan regression passed in the full gate.
The reviewer did not independently run the HTTP suite or Linux signoff.

Hosted CI and required Linux signoff are separate gates on the eventual
published head; local success is not a substitute for either. See
`protocol-change/079-browser-result-records.md` for the interface decision.

## Integration before merge

PR #927's readiness head `71887e1b7` and main `16f886bd0` are integrated so
CI exercises both requested fixes together. No source conflict occurred. Both
client documentation sections are preserved; the handoff is reconciled and
shifted source citations are checked against the merged tree. Generated browser
assets are rebuilt rather than manually resolving CSS. The PR still targets
main and will show only its browser changes after #927 merges.

The readiness follow-up corrects a Darwin-only declaration for two existing
broker /proc prerequisites, without changing their tests or assertions. The
original browser gate remains historical evidence; fresh CI and Linux signoff
are required for this integration head before the authorized merge.

A narrow independent integration review found no findings. Browser read,
authorization, identity and paging/download modules match reviewed `0d1bd8180`;
readiness files match `71887e1b7`, and the Link-form source/tests match main
`16f886bd0`. It confirmed the client doc mirror and Darwin-only prerequisite
scope. This was a source-composition review, not a replacement for fresh tests.
