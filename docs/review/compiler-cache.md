# Deterministic compiler and build reporting

## Problem and boundary

Gleam 1.18.1 emits different compiler-cache bytes for identical inputs because
it serializes randomized maps and sets, and allocates imported type IDs while
traversing unordered maps. Loom's releases retain those caches in the warm
code-mode seed, so normalizing tar/gzip headers alone cannot reproduce the
complete server archive. The issue also reproduces on upstream main at
`3b046ec5a7417dfd83dbd4a9cc46f7d4aed62cf1`.

The maintained compiler patch is recorded with its provenance and standalone
fixture in [the toolchain directory](../../scripts/toolchain/gleam/README.md).
It preserves cache wire shapes and randomized runtime hashing. CI, the runtime
image and the Linux signoff image apply the same checked-in patch. Both the
compiler cache and the compiled-module cache include its digest, including
restore prefixes. A compiler restored from cache still runs the determinism
fixture.

Ordinary development can continue with a released compiler. Reproduction
claims require the pinned compiler, full dependency graph, source timestamps,
source prefix and immutable builder image. No production signing or embedded
trust roots are enabled.

## Candidate execution

CI's manual `build-release-image` input builds the committed signoff Dockerfile,
publishes an OCI toolchain image to GHCR, and passes its registry digest to the
two-runner candidate workflow. Only that image-publication job can write
packages; the candidate runners can only pull. Registry credentials remain on
the runner and are never mounted into the build container. An existing image
can instead be supplied through `release-builder`.

The two candidates use separate hosted runners and clean source clones, with no
shared compiled artifacts. Each performs release smoke tests, and the comparison
checks every byte of all complete archives, manifests and checksum files. A
failed image build cannot select the optional supplied image as a fallback.
Publishing this toolchain image is distinct from publishing or signing a Loom
release; neither occurs in this workflow.

## Client build reporting

`loom version` and `loom --version` report the invoked client's version, full
build commit and platform. The command reads launcher metadata; it does not
query the current checkout or a daemon that might be running another build.
Help and invalid-argument paths are detached as well. Existing identity defaults
remain `dev` and `unknown` for unstamped direct runs.

The slim-launcher checks exercise metadata precedence, both aliases, help,
invalid arguments and absence of daemon state. The bundled-client smoke invokes
the actual command with no host Erlang and deliberately stale inherited identity
variables, requiring the launcher's own metadata to win.

## Evidence before the committed pin

The compiler patch passed 3,498 core and 123 CLI tests. Five cold builds of the
complete code-mode seed matched across 343 checked files and reused caches on
warm builds. Two clean Linux builds of Loom
`21da91d8992cdc02e50ec6d6631beee88b47d236`, using the patched compiler, matched
all complete archives and manifests and passed smoke tests. Those builds used
two fresh containers on one host, so they established same-host repeatability.
The new hosted workflow run is the independent-host check; its current outcome
must be taken from the run and attached comparison artifact, not inferred from
these earlier results.

## Integration review and local gates

The independent integration review found that the profiling launcher consumed
`--profile` after `loom version` before application validation. Both version
aliases now retain their argument tail, with regressions proving that invalid
profiling arguments create no credentials. No other actionable integration
finding remained.

The pin's local checks passed 513 TUI tests, TUI lint with no errors, 17 Python
script tests, the compiler fixture, profile-launcher regressions, bundled-client
smoke and documentation checks with no errors. The documentation and lint
censuses retain existing warnings. Hosted CI, Linux signoff and independent
hosted reproduction must be checked at the pushed head.
