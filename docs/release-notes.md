# Release notes

## Updating an installation

`loom update` can install a published release or a locally built distribution,
verify its manifest and artifact hashes, and gracefully restart the shared
daemon. Existing conversations remain available after the terminal reconnects.
Signing is optional; verifying a signed manifest requires an explicit local
keyring. No production signing keys are bundled.

From a clean, committed source checkout, `make update` builds that checkout and
runs the newly built updater. `UPDATE_ARGS` passes updater options, including
`--install-only` when an automatic restart is unwanted. `loom version` and
`loom --version` report the invoked client's version, full commit and platform
without starting a daemon.

## Preparing a release

`make release-tag TAG=vX.Y.Z` previews a release from the current checkout.
After committing matching client and TUI package versions, add
`RELEASE_ARGS=--push` to create an annotated tag and atomically push main and
the tag. Existing release tags cannot be reused.

A version tag starts two builds each for Linux x86_64 and macOS arm64. Both
builds must agree byte for byte before CI uploads the archives, manifests,
checksums and comparison record to a draft GitHub release. Publishing the draft
remains an operator action. Linux arm64 has no hosted release lane.

See [updating](https://github.com/Roasbeef/loom/blob/main/docs/updating.md) for installation and restart options, and
[distribution](https://github.com/Roasbeef/loom/blob/main/docs/distribution.md#tagging-and-uploading-a-release) for the release
procedure and validation requirements. Before tagging, update these notes for
the intended release; CI prepends them to GitHub's generated change list.
