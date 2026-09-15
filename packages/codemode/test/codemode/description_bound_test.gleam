//// The size of the `code_mode` description a real host serves, pinned
//// against the allowlist the tree actually ships.
////
//// This bound lives here rather than beside the rest of the `code_mode`
//// tool tests because the dependency edge only runs one way: `tools`
//// cannot import `codemode/vet/policy`, since the vetting package is the
//// one that renders a `tool.Collected`. A bound test written in `tools`
//// therefore has to restate the shipped allowlist as a literal, and a
//// copied list that falls behind the policy makes the bound *looser*
//// than the tree rather than tighter — a cap module added to
//// `default_cap_modules` and forgotten here would grow every request's
//// cached prefix with the test still green. `codemode` already depends
//// on `tools`, so from this side the offer is built from the policy
//// itself and there is nothing to fall behind.

import codemode/vet/policy
import core/json
import gleam/string
import tools/codemode

// --- fixtures --------------------------------------------------------------

// The description reads only the seams, so the pipeline behind the tool
// is a stub. Every field of the `Execution` is the most inert value of
// its type: nothing here is ever called.
fn described_over(seams: codemode.Seams) -> codemode.CodeMode {
  codemode.CodeMode(
    execute: fn(_request) {
      codemode.Execution(
        result: codemode.VetRejected(rejections: []),
        enforcement: codemode.Enforcement(
          build: codemode.Unreported(reason: "stub"),
          node: codemode.Unreported(reason: "stub"),
        ),
        refusal: codemode.NothingRefused,
      )
    },
    seams: seams,
    default_within_ms: 30_000,
    max_within_ms: 120_000,
  )
}

// The workspace seam exactly as a shipped host offers it: the default
// vetting policy's allowlist, read through the same accessor
// `client/codemode.seam_offer` uses. `serviced_caps` is the one call
// every host routes, which is what the legend's serviced line renders
// from.
fn shipped_workspace_offer() -> codemode.SeamOffer {
  codemode.SeamOffer(
    seam: codemode.WorkspaceSeam,
    allowed_imports: policy.allowed_imports(policy.default()),
    serviced_caps: ["proc.run"],
    extra_surfaces: [],
  )
}

// --- the size of what every request pays for -------------------------------

pub fn the_workspace_description_stays_under_its_bound_test() {
  // The description is the byte prefix of the provider's cached region:
  // it is read on every request of every strand for the life of the
  // session, whether or not the turn writes a program. Moving the
  // function signatures behind `cap://` took a workspace-only host's
  // whole `code_mode` entry from 52,162 bytes on the wire to 25,690.
  //
  // The bound is that measurement with about a tenth of headroom, and it
  // exists so that the next increase is a decision somebody took and
  // wrote down — a capability added to the prelude, a type widened —
  // rather than a drift nobody noticed until a session's prefix had
  // doubled again.
  let made =
    codemode.tool_for(
      described_over(codemode.one_seam(shipped_workspace_offer())),
    )
  let wire =
    string.byte_size(made.name)
    + string.byte_size(made.description)
    + string.byte_size(json.to_string(made.schema))
  assert wire < 28_000

  // And it is the real allowlist being measured, not an empty filter.
  assert string.contains(made.description, "### cap/job")
  assert string.contains(made.description, "### cap/fs")
}
