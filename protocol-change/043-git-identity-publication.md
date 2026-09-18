# 043: Confined Git identity publication

Status: accepted for implementation. The operator approved a confined helper
publication operation while repairing PR #444's Linux startup failures.

## Problem

Startup publishes the operator's configured Git identity into the tool HOME.
On Linux, a bubblewrap mask for an absent protected SQLite side file beneath a
writable bind can create a directory at that host path. The subsequent SQLite
open then fails. A general jailed shell write therefore has effects outside
the identity file even when its command only writes that file.

Narrowing the writable policy to the tool HOME is insufficient: resolving a
model-planted HOME symlink would turn its target into a new write grant.
Dropping missing protected masks would allow later-created protected state to
be written by ordinary tools. Neither preserves the original authority.

## Decision

The helper accepts one private, fixed operation:

```
loom-exec --publish-git-identity POLICY_BASE64 WORKSPACE ENTRIES_JSON
```

There are exactly three operands. `POLICY_BASE64` is the existing strict
SandboxPolicyV1 msgpack encoding in standard padded Base64, bounded to one
MiB decoded. `ENTRIES_JSON` is a UTF-8 JSON array of two-string arrays, bounded
to 64 KiB. Only `user.name` and `user.email` keys are accepted; the last value
for each wins. NUL is refused. Output follows Git's quoted-value grammar and
always includes `user.useConfigOnly=true`. Rendered output is bounded to
64 KiB and the policy's nonzero file-size ceiling.

The only destination is `WORKSPACE/.codemode/home/gitconfig`. Publication
requires an original host-write grant under the policy's mount precedence;
read-only mounts, protected paths, and private scratch do not grant a host
write. The helper walks existing parent directories with directory descriptors
and no symlink traversal below the canonical granted root. It does not create
parents. An exclusive mode-0600 sibling temporary file is renamed over the
fixed destination through that directory descriptor. Existing destination
symlinks and hardlinks are replaced as directory entries, never followed.
Readers see a complete old or new file. This is atomic publication, not a
claim that a power failure durably preserves the new file.

This operation runs no Git, shell, model code, network request, or mount setup.
The server retains the read-only brokered Git query for conditional includes.
It passes its original base policy to publication; a child path cannot become
a new grant. Query failure yields empty defaults with a value-free warning;
publication failure refuses session assembly. Diagnostics contain no policy,
identity values, or command output. Unsupported platforms refuse publication.

## Compatibility and cost

The framed ExecProto version and vocabulary remain unchanged. This is a
helper CLI extension, shipped with the matching client. An older helper
refuses the unknown mode and startup fails rather than silently omitting
`useConfigOnly`. Ordinary model executions retain their resource limits and
kernel enforcement; the fixed read-only metadata query does not require
memory or process cgroup delegation.

The helper gains a small native file-publication boundary and its regression
suite. The tests cover actual Git parsing, malformed inputs, protected and
read-only destinations, parent and destination aliases, descriptor custody
during a parent rename, concurrent readers, and absent database side files.
