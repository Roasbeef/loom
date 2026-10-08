# 079: Browser pages and downloads for large results

Status: implemented; local affected gate passes. Hosted CI and Linux signoff
are checked separately on the published head.

## Problem

The browser includes expanded tool text in its transcript patches even before a
reader opens an expander. Its bounded preview is necessary, but a cut result has
no browser access to the rest. Rendering a complete megabyte result in every
patch would remove the bound. A byte-budget check followed by grapheme slicing
also exceeds its own bound for Unicode and scans the complete large string.

## Decision

A completed step MUST retain its immutable result entry identity separately from
its bounded text. Narrative joins MUST retain the identity of the same result
whose text they display. An orphan result block derives its identity from its
existing durable source. No second complete result string is retained.

The browser offers a paged viewer and a full JSON attachment. Their addresses
name the immutable entry, so navigation remains usable after a turn collapses
or the chat changes focus. These routes live under the existing keyed session
page and authorize the same read access as that page. No additional read grant
is inferred from an entry identity: lookup MUST use that authorized session's
concrete storage reader, never another session's store.

Each GET MUST check the host, fetch site, page cookie, page key, page scope,
credential and session authority before reading bytes. It MUST repeat the page
grant check before delivering a successfully read response. A page with ended
credentials or membership MUST receive no result bytes. The routes introduce no
browser websocket event and require no component-side result reader or ledger.
The immutable-record read scope is the existing authorized conversation, while
normal UI links name only tool-result entries.

A viewer page has a 16,000-byte stride and adjusts its boundaries by at most
three bytes to partition complete UTF-8 codepoints. The backend reads one bounded
storage fragment, and the document escapes that window as a text node. A download
MUST honor the existing 33,554,432-byte record ceiling and one shared five-second
read deadline. It MUST refuse an incomplete read rather than return a partial
JSON attachment. The response is an attachment with a fixed filename, JSON MIME
type, `nosniff`, `no-store`, and the existing page security policy.

The existing preview keeps its 300-line/8,000-byte bound and cuts UTF-8 within that
byte budget. It does not segment the complete output into graphemes. This is a
rendering and scanning bound, not a resident-memory bound: BEAM subbinaries may
retain the original backing binary, as the preceding implementation did.

## Alternatives and cost

Expanding every result in place multiplies output bytes across DOM patches and
retained lane state. Resolving every page through the component's currently drawn
rows makes pagination fail when the chat changes or a turn closes. An extra
per-page result ledger or signed ticket is unnecessary: the existing session
membership check and session-owned immutable storage already define the read
boundary.

The viewer shows the stored JSON record in text windows. A window may split a
JSON token or a displayed line, and browser search applies to that window. The
complete attachment preserves every stored byte and requires no JSON decode or
second escaped copy. The transcript's initial preview remains unchanged in
size. Old clients ignore the extra internal projection metadata; the v2 wire
contract and language-server policy do not change.
