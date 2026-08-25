# protocol-change/004 — an explicit `mounts` vocabulary for SandboxPolicy

**Status**: PROPOSED 2026-08-25 · **Affects**: Part 1.4 `SandboxPolicyV1` ·
**Raised by**: WP-J (J3c, the code-mode launcher) · **Implemented**: no

## Problem

A jailed satellite node needs exactly two host paths inside its jail: the
AF_UNIX capability socket, which it must `connect(2)`, and the private cap
token file, which it must read. `docs/architecture/code-mode.md` describes
the second as "bind-mounted read-only into the jail".

`SandboxPolicyV1` cannot say either of those things. Its filesystem
vocabulary is `writable_roots`, `readable_roots`, `protected`, and
`scratch`; there is no verb for "make this path visible in the jail", none
for "bind this single file read-only", and none for "the jail must be able
to reach this socket".

Both requirements are nonetheless met today, but *incidentally*, and that is
the finding. The helper's base view is the whole host filesystem bound
read-only (`jail.BwrapArgs`: `--ro-bind / /`), so every host path is already
visible; `readable_roots` only adds a redundant explicit `--ro-bind`, and
Landlock's rule set grants `RODirs("/")` for the same reason. Three
consequences:

1. **`readable_roots` does not restrict reads.** Everything not named in
   `protected` is readable inside the jail whether or not a root covers it.
   The code-mode narrative ("a hostile `.beam` ... cannot read a file the
   policy forbids") is true only of `protected` paths, not of an allowlist.
2. **Two ordinary-looking paths are invisible inside the jail.** Anything
   under a `protected` entry is shadowed (ro-bind for a file, an empty
   read-only tmpfs for a directory or a missing path), and when
   `scratch` is `"tmpfs"` everything under `/tmp` is replaced by the
   scratch mount. A cap socket in either place exists on the host and is
   simply absent in the jail — a failure that looks like the satellite
   never connecting.
3. **Nothing records the dependency.** Tightening the base view to a
   minimal root — which is the right direction for the threat model —
   would silently break code mode, because no policy value says the socket
   and token have to be there.

For completeness, the kernel facts that make the current arrangement work,
so that a future change knows what it must preserve: `sb_permission`
exempts sockets from `EROFS`, so `connect(2)` on a socket inside a
read-only mount succeeds; Landlock's filesystem access rights do not govern
connecting to an existing socket; and the network-off seccomp filter denies
only non-`AF_UNIX` socket creation.

## Proposal

Add one field to the policy — a list of explicit binds, applied after the
protected masks so an explicit mount is not silently shadowed:

```
mounts: [ { path: str, access: "ro"|"rw", kind: "file"|"dir"|"socket",
            required: bool } ]
```

```gleam
pub type MountAccess {
  MountReadOnly
  MountReadWrite
}

pub type MountKind {
  MountFile
  MountDirectory
  /// An AF_UNIX socket the jail must be able to connect to. Named
  /// separately from `MountFile` because connect(2) needs write
  /// permission on the inode, which is a different question from whether
  /// the mount is read-only.
  MountSocket
}

pub type Mount {
  Mount(path: String, access: MountAccess, kind: MountKind, required: Bool)
}
```

- **Helper**: each mount becomes a `--ro-bind`/`--bind` emitted *after* the
  protected masks and after the scratch mount, so an explicit mount wins
  over a shadow. A `required: True` mount whose source does not exist
  refuses the execution rather than running a jail the caller believes has
  it. `MountSocket` is bound read-only today; if a kernel is found where a
  read-only bind refuses `connect(2)`, only this one case changes.
- **Composition**: mounts are widening, so they follow the existing rule
  for widening — a tool's requirements may only *request* a mount the
  session base already carries, and anything else is a `Narrowing`
  convertible to a `GrantMount`. A tool cannot mount arbitrary host paths.
- **Prerequisite, not the change itself**: this vocabulary is what a
  minimal-root base view would need before it could replace `--ro-bind /
  /`. That is a separate, larger proposal; this one only makes the two
  requirements statable.

## Impact

`broker/policy` (type, encoder, decoder, `compose`, `narrow_unenforceable`),
the Go `internal/policy` decoder and `jail.BwrapArgs`, the golden fixtures
under `protocol/msgpack-fixtures/`, and the spec's Part 1.4 text. No durable
format impact — policy is never persisted.

Because the field is additive, a v1 decoder on either side would reject it
(both decoders are strict and refuse unknown keys, correctly), so this is a
policy version bump rather than a compatible extension.

## Interim behaviour (what J3c does instead)

`codemode/launch` expresses the two requirements as `readable_roots`
entries, composes the policy itself, and refuses the launch in-band when
the composed policy does not cover the socket or token directory. It
additionally refuses the two cases the vocabulary cannot express at all — a
path under a `protected` entry, and a path under the scratch tmpfs mount —
rather than discovering them as a satellite that never connects. The module
doc records why that is sufficient today and what it depends on.
