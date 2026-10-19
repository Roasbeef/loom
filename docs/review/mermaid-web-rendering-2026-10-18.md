# Web Mermaid rendering: validation and review

**Status**: partial, browser validation blocked · **Date**: 2026-10-18 · **Base**: `dd43362c86b43000e69e291550a41c21f5ffc13b` · **Branch**: `feature/web-mermaid`

The web implementation follows
[protocol-change/091](../../protocol-change/091-isolated-mermaid-diagrams.md).
The source stays in the session page as text, and a separate opaque frame owns
Mermaid's DOM generation. The TUI remains unchanged. These results describe the
local implementation, not an installed release or a completed end-to-end signoff.

## Verified locally

| Gate | Observed result |
| --- | --- |
| `web_view` package suite | All 1,131 tests passed, including Markdown dispatch and escaping. |
| `make test-web_client` | All 309 Gleam tests and five isolated renderer adapter checks passed. The adapter checks also passed under Bun independently. |
| `bash scripts/test.sh client --match client@ui_` | All 353 web UI tests passed, including real listener responses for the renderer's HTML, script and independent CSP. |
| License collector unit tests | Three tests passed. Notice generation found license files for every locked production dependency. |
| `make gen-client` and `make client-check` | Generation, source/body digest checks and negative gate self-tests passed. |
| `make fmt-check` and `make doc-check` | Passed. Existing documentation warnings remain; source-line citations moved by the route changes were repaired. |
| Affected package lint | `web_client`, `web_view` and `client` passed with zero errors. Existing census warnings remain. |
| `make server-shipment` | Built successfully twice during implementation. Rebuild after the final asset generation before the browser drive. |
| `npm audit --omit=dev` | Zero reported vulnerabilities for the pinned dependency graph at the time of the run. |

The adapter tests use a controlled vendor promise and a minimal DOM fixture.
They prove the adapter's queue, request restrictions, result vocabulary and
rejection behavior, not actual Mermaid layout or browser enforcement. The route
tests prove response headers and asset selection, not that a browser applied them.

## Independent review

One report-only adversarial pass examined the isolation contract, revision and
lifecycle ownership, build gate and test failure modes. Every reported finding
was checked against source before fixing it. A focused re-check of the fixes
reported no additional code findings.

The fixed findings were:

- Indented YAML frontmatter bypassed the initial configuration guard. The pinned
  Mermaid parser accepted a two-space-indented `theme: forest` configuration.
  The guard now recognizes leading whitespace, with space/tab regression cases.
  Replacing it with the old guard in a scratch copy makes the adapter test fail.
- The browser drive required a new light-theme render even when light was already
  effective. It now switches to the opposite effective theme first and requires
  a newer rendered revision for each transition.
- Selecting the first cached Bun could use a different version. Generation now
  reads the version in the locked Lustre tool and selects only a matching binary.

The build also retains dependency license notices as a separately stamped
release artifact. No test was removed or assertion weakened to address the
local environment failures below.

## Unfinished validation

`make check` failed before package execution in five unchanged script tests:
four installer pruning expectations and one signoff fixture's fake Git remote
lookup. The jail denies `/bin/ps`, and the signoff fixture attempted to resolve
`origin.example.invalid`. These failures are not a successful full gate.

A subsequent full client-suite attempt encountered jail-dependent failures and
was terminated with exit 152 (the runner reported signal 24) before completing.
It establishes no complete client-suite result. An initial broad `ui_` filter
also selected `tui_` fixtures; the exact `client@ui_` module prefix was used for
the separate, passing web UI run above. This does not replace the full suite.

The disposable browser seed could not start through `bin/loomd`: daemon
startup reported that `/bin/ps` could not be consulted. The check is in
`host_bootstrap_ffi.erl`'s native process-identity path. An initial suggestion
to use the shipment entrypoint directly was wrong: inspection confirms that
`bin/loomd` already executes that entrypoint, so it would reach the same check.
The identity check is unchanged; a live daemon run needs an unjailed runner.

Consequently, `scripts/web_mermaid_check.sh` has not been executed. Real SVG
contents, browser CSP enforcement, layout, source disclosure/copy interaction,
streaming recovery, theme changes and reconnect behavior still need the live
browser drive. Full hosted CI and strict Linux signoff are also unverified.
The branch must remain draft until those validation requirements are met.
