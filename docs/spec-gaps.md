# Spec gaps and recorded interpretations

Running log of places where implementation forced an interpretation of the
spec or revealed a gap. Each entry says what was decided and where. Items
that would change a frozen Part 1 interface go through `protocol-change/`
instead and are only referenced here.

## From WP-A (`core`)

1. **Id minting signature.** Part 1.1's comment reads `mint(Clock)`, but
   purity requires entropy injection too. Implemented as an opaque
   `Generator` threading a `Clock` and a seeded SplitMix64 state through
   every mint. This *is* §0.2's "injected UUIDv7 generator"; the literal
   signature in the contract comment is looser than the implementation.
2. **`BranchSummaryEntry.from_id` nullability.** pi allows `fromId: null`
   (summary sourced at the root); our contract says `from_id: EntryId`.
   Implemented per our contract, which makes a root-sourced branch summary
   unrepresentable. Raised as `protocol-change/001`.
3. **`details` payloads.** pi §2.1 carries optional `details` on compaction
   and branch-summary entries; Part 1.1 omits it. Followed Part 1.1. The
   format-4 import will need somewhere to put these — revisit with
   follow-up track 6.
4. **`UsageRow`.** Referenced by `InsertUsage(UsageRow)` in Part 1.1 but
   never defined there. Transcribed from pi §1.1 into `core/entry`.
5. **Custom messages.** pi's open `CustomAgentMessages` interface became
   `CustomMessage(schema, payload)`; unknown roles are decode corruption.
   The import shim maps pi's application roles into this form.
6. **`RegisterValue` representation.** Part 1.1 says the namespace forces
   the value type, but those types (StrandConfiguration, OperationState,
   …) belong to WP-D. Core carries payloads as tagged JSON; machine owns
   the rich codecs. Documented in `core/register`'s module doc.
7. **Decoder coverage criterion.** WP-A's "≥95% branch coverage on
   decoders" is not machine-verified — no Gleam coverage tooling exists.
   Compensated with adversarial corpora (90+ inputs) and per-variant
   property tests. The criterion should be restated in testable terms.
8. **Numeric edges.** JSON floats beyond IEEE 754 double range decode as
   corruption (the BEAM has no Inf/NaN); JSON ints are arbitrary
   precision; msgpack ints outside `[-2^63, 2^64-1]` are encode errors.
