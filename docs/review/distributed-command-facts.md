# Pinned enrollment and shared command construction

The owner needs enough executor configuration to derive an exact command
before clearing it. Enrollment retains that configuration as bounded data:
the full workspace scope, native ceiling and enforcement demand, compiler
and runtime paths, seed and toolchain roots, and private allocation areas.
The executor's registration exposes those facts through a total conversion.
It keeps its filesystem canonicalizer private.

## Authority and allocation

The enrollment constructor checks counts and byte lengths before traversing
or encoding peer data. Its decoder applies the bounded MessagePack preflight,
reconstructs through the constructor and requires canonical reencoding.
Enrollment comparison checks the full snapshot, including both digest claims.
Those claims still require trusted provisioning; the codec does not prove
that a peer's claimed digest describes the host.

Workspace, build and channel regions are disjoint. Seed, toolchain and PATH
roots cannot overlap writable or scratch regions, and declared host mounts
must match read-only entries in the native ceiling. Compile and channel paths
derive from the original service UUID after checking scope, role and digest
claims. These checks are lexical. Provisioning and the sandbox still own
filesystem canonicalization and enforcement.

A derived pathname does not authorize resource creation. The executor must
commit preparation intent before creating the directory, socket or token.
Retained Ready evidence proves issuance; a usable channel also requires the
original resource owner to remain alive. Those custody mechanisms remain
implementation work after this slice.

## Shared local and remote command rules

`codemode/native_command` constructs compiler and satellite command data
without performing I/O or clearance. The existing local build and launch
wrappers call it, preserving argument order, environment replacement,
network-off policy, access roots, mount entries and untouched policy fields.
The local launcher still refuses remote artifacts before reading paths.

The protocol-067 addendum selects the final native wall allowance after
preparation, using the remaining original deadline and the actual remaining
control bounds. Repeated observation cannot renew that deadline or replace
the retained offer. The new module supplies shared construction rules;
owner-side expected-command validation and remote physical assembly still
need to use them.

## Validation and independent review

Enrollment was frozen as `d685141e` and integrated as `064069dca`. Root's
independent full package gates exited zero: 422 broker tests in 82.07 seconds
and 160 executor tests in 75.47 seconds. The broker log includes two existing
Darwin tests that skip Linux `/proc` kill witnesses. The executor log contains
no prerequisite skips. Removing the workspace from the isolation check
compiled, then failed the intended overlap assertion; restoration reproduced
the frozen source hash.

Command construction was frozen as `90e231b8` and integrated as `ba2b831e8`.
The final seeded code-mode gate exited zero in 31.97 seconds with 360 tests
and no prerequisite skips. It ran the local jailed compiler and satellite
fixtures. Replacing the distribution-disabled argument compiled but failed
the existing launch assertion. Restoring the original bytes returned that
test to green. Earlier runs with missing seed prerequisites or outer sandbox
permission failures are not counted as complete validation.

The combined integration run at `e92dcc561` also exited zero for all three
packages: 435 broker tests in 82.79 seconds, 160 executor tests in 76.35
seconds and 360 code-mode tests in 33.09 seconds. The additional broker
tests come from the preceding command-codec slice. That run retained the
same two Darwin witness skips and had no executor or code-mode skips.

The independent Astra review verified all thirteen frozen source, test and
package-document hashes, then checked the protocol appendix. It found no
actionable defect in construction bounds, path isolation, exact equality,
command equivalence or the wall-selection ordering. The review inspected
the test and mutation artifacts; root ran the independent component gates.
These results establish component behavior, not shipped remote execution,
hosted CI or separate-host acceptance.
