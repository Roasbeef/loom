# ADR-012: verified release manifests and native updates

**Status**: accepted · **Date**: 2026-09-15 · **Supersedes**: nothing

## The question

An installed Loom process keeps loading files from its original release tree.
The installer therefore publishes fresh immutable trees and retains old ones.
That solves live-file replacement, but it does not identify a download, establish
its provenance, or arrange graceful daemon restart. Complete releases also carry
OTP, a Gleam compiler, native code and code-mode caches: reproducing only the Go
helper does not establish reproducibility of the product.

## Decision

A schema-1 JSON manifest binds the repository, tag, full source commit, platform,
and the names, roots, byte sizes and SHA-256 digests of three artifacts: server,
bundled client and slim client. Each platform has a separate manifest. Archives
use a canonical ustar subset with sorted paths, normalized modes, zero owner
identities, commit timestamps and a gzip timestamp of zero. Hard links become
ordinary files. Only aliases of regular siblings are retained as symlinks.

Release candidates are built from committed source, with exact dependency locks,
a fixed source prefix and an identified toolchain. The code-mode seed has its
own committed complete dependency lock, installed before its first resolution
and checked after every online build. The recipe records tool
versions and executable digests, the OTP and Go trees, and the builder identity.
The comparison step checks that both complete artifact sets match their own
manifests before comparing every file byte. It emits an unsigned reproduction
record only after equality. The initial hosted workflow uses two separate Linux
x86_64 runners and a content-addressed OCI image. Other platform builds must be
compared independently; this workflow does not establish their reproducibility.

Signatures are optional until release signing is operational. There are no
production signing keys in the repository and no automatic key download. If a
manifest signature exists, verification against an explicitly supplied local
OpenPGP keyring is mandatory. `--require-signature` also refuses an absent
signature. An unsigned manifest gives transport integrity and internal digest
consistency, not independent publisher authentication. Introducing default trust
roots will require a separate, reviewed release-key decision.

`loom update` owns resolution, verification and installation in Gleam. Native
HTTPS uses Gun and OTP's system roots, with hostname verification. The small FFI
adapts native calls and events; Gleam owns redirect policy, byte budgets, staging,
manifest decoding and lifecycle. Gun was chosen because it streams bodies for all
statuses and exposes flow control. OTP's `httpc` streams only 200/206 responses;
using it would require a different approach to bound unsuccessful responses.

The updater calls the installer bundled with the running client. It never runs
an installer supplied by a downloaded archive. After publication it requests
authenticated graceful shutdown, waits for the original native process fence to
retire, and uses the ordinary bootstrap path to start or adopt the replacement.
The accepting daemon must report the manifest's full commit. `--install-only`
leaves lifecycle to the operator. The portable slim launcher discovers its execution platform at runtime; its
archive name identifies the builder so platform manifests have distinct assets.
An explicit tag or commit permits an intentional
downgrade; automatic latest selection refuses a known version downgrade.

## Consequences

Reproduction is conditional on the recorded toolchain and source prefix. The
code-mode seed retains compiler caches containing paths and timestamps, so this
recipe does not promise arbitrary-checkout-path independence. It also does not
bootstrap the compiler or operating system reproducibly from source.

Gun and Cowlib become terminal release dependencies. Download workers have one
overall deadline, bounded headers and one body-message credit at a time. Archive
validation has a bounded but potentially substantial in-memory footprint: the
compressed and inflated archives can coexist. This is not a streaming extractor.

Publication remains atomic per link, not across the entire installation. A
partial publication or failed restart leaves complete release trees for retry
and manual recovery. Old trees are never pruned automatically. The daemon may be
shared by other terminals, which can attempt their normal reconnection during
restart; accepting a replacement is therefore based on authenticated identity,
not on an assumption that the updater was its only launcher.

## Key rotation

Until default trust roots exist, the operator owns the local keyring. Obtain a
new key through a separately authenticated channel, check its fingerprint, and
use an overlap keyring containing the old and new release keys while releases
transition. Remove the retired key only after the transition has been verified.
The update channel itself does not authorize adding or replacing a trusted key.
