# Workspace selection and local effect boundaries

## Scope

This slice retains registered workspace identity in the daemon catalogue and
makes local workspace access explicit in tool contexts. It prepares the owner
for remote assembly; the shipped daemon still refuses registered startup.
The next assembly must select executor services before local Git, toolchain,
seed, guidance or temporary-directory probes.

`core/workspace.WorkspaceKey` groups defaults and shared domains by stable
selector. A session's `Binding` separately retains its workspace and session
authority epochs. Catalogue schema version 5 adds canonical binding JSON;
local rows keep their original pathname keys and NULL binding content.
Named Parrot/sqlc queries own every row read and write. The DAL rejects a row
whose key and binding disagree, whose content is noncanonical, or whose
binding shape is invalid. A retained creation key is checked before resolving
current administration, so an exact retry cannot replace the original epochs.

`tool.Ctx.workspace` is either local root/filesystem access or a registered
scope. `OwnerBlobs` holds output storage independently. Local filesystem,
permission, grep, Bash, code-mode and extension entry points require the local
variant before physical resolution, clearance or launch. Semantic filesystem
constructors use their captured executor callback and preserve the registered
context. A remote scope has no fake root or owner-filesystem fallback.

Compile and satellite native commands now have separate child roles from
outer Compile and Launch services. Admitted capability roles contain the
trusted name, its existing ordinal and semantic/native purpose. Legacy child
addresses are unchanged. These coordinates do not grant effect authority.

## Independent review and correction

The initial independent review found one reachable compatibility defect. An
older TUI sends no registered-workspace feature assertion and requires a local
`workspace` field when decoding session metadata. Rename, archive and restore
could commit a registered session mutation before returning a reply that this
client could not decode. Its control connection then reported disconnection,
even though the mutation had succeeded. `operations.get` had the same reply
shape, without the mutation.

The fix extends the existing compatibility check. Owner and epoch checks run
first, then support is checked before the three mutations. Both operation-read
paths check their authorized view before encoding. The existing manager still
performs its serialized mutation checks. No executor revalidation is added to
metadata changes or resident transcript attachment: owner-held session state
remains accessible during an executor outage.

The wire regression creates actual registered metadata and sends unsupported
requests over the control socket. It checks `unsupported_workspace`, unchanged
catalogue revision, original name and visibility, stale-epoch precedence, and
a successful feature-enabled rename with one revision increment. The focused
regression passes. Focused independent review verified that the production
correction resolves the finding. It also identified an asynchronous fixture
race: session confirmation can increment the catalogue revision after creation
returns Opening. The regression must witness residency before capturing its
revision baseline. That witness now precedes the baseline, and root's final
20-test daemon-server run passes with it.

## Verification evidence

Root's integrated component run passed core (157 tests), storage (150), tools
(672), executor (157) and client. The full client run after the compatibility
correction passed 2,747 tests. After the fixture's residency witness was added,
root reran all 20 daemon-server tests successfully. Conformance's final run
passed all 96 tests, including its real jailed code-mode and LSP fixtures.
The conformance snapshot compares catalogue identity keys with binding keys.

Full repository lint, documentation citations and capability-prelude checks
also passed. Independent SQL regeneration reproduced the generated query and
migration modules byte for byte. The tests report macOS kernel-enforcement
limits separately; a passing fixture does not turn those skipped layers into
provided isolation.

Three intentional mutations compiled and failed the intended assertions:

- Borrowing OwnerBlobs as registered workspace access failed on an unexpected
  owner path-resolution callback through the real filesystem tool.
- Omitting the capability name from child identity collapsed ten distinct
  addresses to eight.
- Accepting disagreement between a catalogue key and registered binding failed
  the real catalogue-reader corruption regression.

A fourth compiling mutation resolved current administration during a retained
creation retry. It failed the control-socket regression requiring the original
registration and epochs. Each mutation was restored byte for byte before the
subsequent clean checks. Compiler or fixture failures are not counted as kills.

The Linux signoff attempt at PR #786 found two test assumptions that differed
under process scheduling: an expired observation can remain transport-uncertain,
and a parent's DOWN message does not prove its linked service has died. The
fixed tests retain the original identity/no-reexecution assertions and wait for
both process deaths. Both focused tests passed in the same Linux container.
The affected-package expectation also needed the new executor dependency, and
the conformance manifest needed regeneration. This does not establish a fresh
full Linux signoff for this slice.

## Remaining acceptance

The full repository gate, fresh Linux signoff and hosted CI remain separate
from these component checks. Registered browser attachment and typed native
client selection are not enabled by the compatibility assertion alone. The
production gate still requires shipped owner and executor processes on
separate hosts/filesystems, with no owner copy of the target checkout, and
ordinary session paths for files, Bash, compilation, capabilities and LSP.
Neither this source guard nor the bounded formal models prove that product.
