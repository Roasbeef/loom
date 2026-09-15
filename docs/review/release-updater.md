# Release updater review and verification

Baseline: `cc797e4182ab37d79f10b851bf4262d36be1832a`, the merged #404
installation and daemon-drain foundation. This record covers the subsequent
release/updater working tree, checked September 15, 2026.

## Independent review dispositions

| Finding | Disposition | Evidence |
|---|---|---|
| A portable slim launcher baked in its builder's platform and would request that platform's server after being copied elsewhere. | Fixed. The slim launcher runs its bundled platform detector on the execution host. Slim artifact names include the build platform to avoid cross-builder asset collisions. | Installed bundled-to-slim smoke passed; a stub execution host reports Linux arm64 through the generated launcher. Native bundles retain their build-platform stamp. |
| Recreating the code-mode seed resolved unpinned transitive dependencies online. | Fixed. Seed preparation installs a committed complete lock before building and requires the same bytes after every resolution pass. | `make codemode-seed` passed with the committed lock, including Gleam Erlang/OTP transitive dependencies. |

The review found no additional actionable issue in manifest signatures,
publication ordering, download bounds, or original-daemon retirement. The
review did not establish complete-build reproducibility or Linux execution.

## Bundle interoperability correction

The first real-bundle test found that the archive reader's component alphabet
rejected `@` in generated Gleam BEAM filenames. Archive component validation now
admits that separator without rewriting stored names. The existing root,
ancestor, duplicate-path and regular-sibling alias checks remain in force. The
canonical archive regression fixture now contains `core@clock.beam`.

## Verification

The following checks have completed locally on macOS arm64:

- Host package gate: 23 tests.
- Client package gate: 1,807 tests.
- TUI package gate: 513 tests.
- Canonical archive and complete-comparison regressions: four tests.
- Native HTTPS integration: five tests, including system-verification behavior
  against a private test CA, hostname rejection, multi-fragment downloads,
  status handling, redirects and byte limits.
- Actual CLI offline integration: six tests, including check-only behavior,
  bundled/slim installation, retained trees and local-keyring signatures.
- Complete server, bundled client and slim shipment builds.
- Installed bundled and slim update/restart smoke: two original daemon
  lifetimes retired, distinct replacement epochs accepted, expected full commit
  confirmed, previous trees retained, and the installed updater still runnable.
- Scoped updater lint: no errors. Existing warning categories remain warnings.
- Documentation graph: no errors; historical citation/staleness warnings remain.

The installed-release smoke used locally built bundles labeled with their
baseline source commit. It is an interoperability and lifecycle test of the
working tree, not an attestation that those development artifacts were built
from a clean committed source snapshot. The fixture's original child is reaped
concurrently: leaving a stopped child as a zombie correctly prevents the
updater from treating its native lifetime as absent.

The full `make check` gate completed with exit status 0, including the new
integration fixtures, every package and house lint. Lint reported no errors
and 806 warnings. A package's successful EUnit count is not substituted for the
enclosing command's status.

## Outstanding release evidence

The manual candidate workflow has not run. An independent complete-artifact
comparison has not run, and there is no reproducibility certificate for any
platform in this change. The initial hosted workflow provisions Linux x86_64
builders only. Other platforms require their own pinned builders and comparisons.

Linux release smoke tests exercise nested sandbox namespaces. The ordinary
candidate container's default restrictions have not been shown sufficient;
its smoke environment must be approved and provisioned before relying on this
workflow. The comparison and updater do not weaken their checks to turn that
missing execution evidence into a successful result.

There are no production signatures or embedded release trust roots. Optional
signature mode, explicit keyring verification, and the rotation procedure are
implemented; production key introduction remains a separate release decision.
