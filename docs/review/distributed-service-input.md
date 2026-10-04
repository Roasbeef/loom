# Remote service input review

The Compile and Launch input codec retains the complete enrollment, original
policy, environment and selected source bodies. Constructors bound collections
before encoding. Decoders check segment sizes, UTF-8 and canonical re-encoding;
the 9 MiB envelope allowance includes its actual service header and framing.

Compile admission re-vets against the trusted effective policy and compares the
ordered generated catalogue bodies. Launch admission requires the exact retained
successful Compile result and full original parent, while permitting different
physical steps. A local Artifact cannot enter this remote path. Neither a codec
nor its constructors authenticate the sender or establish genuine journal custody.

The independent review found no actionable functional defect. It identified a
coverage gap in the parent-substitution test: the argument digest and reserved
result entry were not independently varied. Both valid-parent substitutions now
appear in the existing regression. Production source was unchanged by that fix.
A compiling mutation replacing the effective policy with its broader seam default
incorrectly admitted a workspace strand import and failed the intended assertion;
the original source was restored byte-for-byte.

## Validation and limits

The focused slice passes 14 tests. An independent component gate passed 374 tests,
and the combined integration gate, including the resource receipts, passed all
387 tests in 50.376 seconds with exit 0 and no reported skips. The component also
passed formatting, lint and documentation checks. The combined gate used the
existing offline seed fixture; the physical compiler extraction separately checks
and refreshes its transitive seed sources before claiming current-source parity.

Bounds on serialized bytes are not a proof of equal heap or parsing CPU bounds.
The admission caller still owes bounded re-vetting time and hash authentication.
Real retained Compile evidence, resource ownership, native admission, final-wall
selection and physical service routing remain assembly obligations. These checks
do not constitute two-host acceptance or a full-stack Linux signoff.
