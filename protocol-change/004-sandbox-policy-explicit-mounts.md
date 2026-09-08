# protocol-change/004 — an explicit `mounts` vocabulary for SandboxPolicy

**Status**: ACCEPTED 2026-09-08 · **Affects**: Part 1.4 `SandboxPolicyV1` ·
**Raised by**: WP-J (J3c, the code-mode launcher) · **Implemented**: yes

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
mounts: [ { path: str, access: "ro"|"rw", required: bool } ]
```

```gleam
pub type MountAccess {
  MountReadOnly
  MountReadWrite
}

pub type MountRequirement {
  /// The execution is refused when the source path does not exist.
  MountRequired
  /// A missing source path is skipped rather than refused.
  MountOptional
}

pub type Mount {
  Mount(path: String, access: MountAccess, requirement: MountRequirement)
}
```

- **Helper**: each mount becomes a `--ro-bind`/`--bind` emitted *after* the
  protected masks and after the scratch mount, so an explicit mount wins
  over a shadow. A `MountRequired` mount whose source does not exist
  refuses the execution rather than running a jail the caller believes has
  it.
- **Composition**: mounts compose as the meet, like every other field. A
  mount survives composition only when both sides carry it, at the weaker
  of the two accesses and the stronger of the two requirements. A tool
  requesting a mount the session base does not carry is a `Narrowing` and
  an in-band refusal.
- **Prerequisite, not the change itself**: this vocabulary is what a
  minimal-root base view would need before it could replace `--ro-bind /
  /`. That is a separate, larger proposal, `protocol-change/020`; this one
  only makes the requirements statable.

### No `kind`, and no `GrantMount`

The original draft carried `kind: "file"|"dir"|"socket"` and answered
composition with a new `GrantMount`. Both are dropped.

`kind` is documentation pretending to be data. The draft itself recorded
that a socket is bound read-only exactly as a file is; bwrap's `--ro-bind`
does not consult the inode type, and the helper already stats every mount
source for its own refusals (`MissingMountSources`,
`packages/sandbox/internal/jail/mounts.go`). Three values that emit
identical argv are three values a reader must reconcile against the code.

`GrantMount` is dropped because a grant reaches the escalation path, and
#243 has not yet settled which principal an approval prompt goes to under a
shared daemon. Mounts do not need it: they compose as the meet like every
other field, so a tool asking for a mount the base does not carry produces
a `Narrowing` and an in-band refusal, exactly as `codemode/launch` refuses
today. Out-of-workspace access is decided before the session starts, by the
derived rule over manifest path dependencies or by an operator's
configuration line. #242 therefore touches nothing #243 has yet to settle.

`required` stays a bool on the wire, where msgpack has bools and the Go
side has one too. In Gleam it is the two-variant `MountRequirement`,
because lint R9 rejects a naked `Bool` in a record field: `Mount(path,
access, True)` names nothing at the call site.

## Impact

`broker/policy` (type, encoder, decoder, `compose`, `validate`,
`wanted_grants`), the Go `internal/policy` decoder and `jail.BwrapArgs`, the
golden fixtures under `protocol/msgpack-fixtures/`, and the spec's Part 1.4
text. No durable format impact — policy is never persisted.

Because the field is additive, a v1 decoder on either side would reject it
(both decoders are strict and refuse unknown keys, correctly), so this is a
policy version bump rather than a compatible extension. **The field lands as
policy version `v: 2`.** The two decoders are equally strict in the other
direction as well: a v2 harness and a v1 helper do not interoperate at all,
so the Gleam and Go halves landed together in one pull request rather than
two. Splitting them was considered and abandoned once measured: the
intermediate tree is not coherent, because the helper decodes the policy out
of `exec_start` strictly and refuses it with `policy: unknown keys [mounts]`,
which fails every test that spawns the real helper. The three
`sandbox_policy_*` fixtures move to v2 with the field.

Two files in this directory are numbered 019
(`019-session-display-names.md` and `019-sessions-delete.md`). Both are
merged, so renumbering one would break inbound links for no benefit. The
collision is recorded here rather than repaired. The minimal-root base view
is `protocol-change/020-minimal-jail-root.md`, which is the next free
number.

## Interim behaviour (what J3c does instead)

`codemode/launch` expresses the two requirements as `readable_roots`
entries, composes the policy itself, and refuses the launch in-band when
the composed policy does not cover the socket or token directory. It
additionally refuses the two cases the vocabulary cannot express at all — a
path under a `protected` entry, and a path under the scratch tmpfs mount —
rather than discovering them as a satellite that never connects. The module
doc records why that is sufficient today and what it depends on.

## Decision

**Accepted.** The alternative — leaving the two requirements as
`readable_roots` entries and letting the minimal-root change discover them —
was considered and dismissed: under `--ro-bind / /` a missing dependency has
no symptom at all, so it would be found by a satellite that never connects,
on the branch that is already the largest in the wave. The vocabulary lands
first precisely so that the narrowing has something to refuse against.
