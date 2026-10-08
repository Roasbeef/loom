# ADR-019: native reads follow the session's read policy, and protected paths are refused on reads

**Status**: accepted · **Date**: 2026-10-07 · **Supersedes**: nothing (it
narrows the "reads are not checked against `protected`" statement in
`tools/fs.resolve_for_write`) ·
**Spec ref**: Part 1 (sandbox policy, unchanged), `docs/spec-gaps.md`
"harness-side filesystem tools"

## The problem

In a session opened on `aperture`, a code-mode program called `search.grep`
on two sibling repositories, `../loop` and `../nautilus`. All sixteen calls
came back `permission_denied` within a few milliseconds. The model then ran
the same grep through `bash`, which read both repositories without any
approval, and stopped using code mode.

The two reads were judged by different boundaries.

- A jailed process (`bash`, `proc.run`, a language server) reads under the
  session base policy. With the default `[workspace] read_scope = "host"` its
  readable root is `/`, and the paths in `protected` are masked out of view.
- A native read (`fs_read`, code mode's `cap/fs` and `cap/search`, the
  working-directory check) allowed the workspace plus explicit additions
  (`/add-dir` roots and per-call `permissions.readable_roots` grants). It did
  not consult the policy's `readable_roots`, and it did not consult
  `protected` at all.

So under host reads an approval prompt guarded nothing: the same model read
the same file through `bash` without asking. The friction pushed it out of
code mode and bought no isolation.

## Options considered

1. **Change the refusal text only.** Tell the model how to request access.
   This leaves the two boundaries disagreeing, so the model is still asked to
   approve a read that `bash` makes for free.
2. **Prompt for approval on a sibling read.** `fs_read` already does this. It
   has the same defect, and a code-mode program cannot prompt in the middle of
   its run.
3. **Make native reads follow the policy the jail is built from.** One value
   decides both. This is the option taken.

## Decision

A native read is allowed when its fully resolved path is under the workspace
or under a root in the session's composed policy, and no entry of that
policy's `protected` list covers it.

- The roots are `base_policy.readable_roots` widened by session additions and
  approved grants (`directory_access.widen`). Under `HostReads` that is `/`;
  under `WorkspaceReads` it is the workspace plus explicit additions, as
  before. `tools/fs` does not branch on the read scope and keeps no second
  list; `fs.resolve_readable` takes the policy value itself.
- `protected` is refused on reads. Every mask the jail applies to a session is
  an entry of `base_policy.protected`: the blob directory, the search index
  and memory stores, and the state-root entries (`owner.token`,
  `catalogue.db`, `sessions`, the cap-socket root and the lazily created
  ones). `client/serve` adds them to the base policy at boot, and the native
  check reads that same list. No grant lifts a protected path. A relative
  entry refuses the read, as it refuses a write and as the jail refuses the
  policy.
- The session's blob root is the one protected entry native reads still
  open. Blobs are the harness's output to the model, which is told to read a
  ref with `fs_read`; protection exists so nothing can write behind a hash,
  not to hide them. `fs.exempting_blob_root` drops that entry from the list a
  read is judged by, and writes judge the unmodified list.
- A read under `/proc`, `/dev` or `/tmp` is refused unless it is under the
  session workspace. The jail mounts its own procfs, device tree and scratch
  tmpfs there, so a tool never sees the host's version, and under host reads
  the roots would otherwise reach the daemon's `/proc/self/environ`. The three
  roots are one constant, `broker/policy.jail_replaced_roots`, which the
  scratch-mount check in `codemode/launch` reads too. They are not in
  `protected`, because bwrap refuses a mask over them. A workspace that lives
  under `/tmp` keeps working.
- Directory walks skip a protected subtree and the replaced roots that do not
  contain the walk's own root. `search.glob` and `search.grep`
  take the protected list and neither report nor descend into an entry under
  it. `search.stat` checks its unresolved leaf against the list.
- Writes are unchanged: the workspace plus explicit writable additions, and
  the same `protected` list.
- A read outside the readable roots is refused with a message naming the two
  ways in: list the path in `permissions.readable_roots` on a `code_mode` or
  `bash` call (the tools that accept `permissions`), or ask the operator to run
  `/add-dir`. In code mode the refusal travels under the code
  `outside_readable_roots`, and a protected refusal under `protected_path`,
  because `cap/fs` and `cap/search` drop the message of a `permission_denied`.
- Search results for a root outside the workspace carry absolute paths, so a
  program can pass them to the next call.

## What it costs

- The harness path check is the only boundary for native reads. It runs in the
  harness, so it must stay identical to the jail's view. The agreement test in
  `packages/client/test/client/workspace_test.gleam` drives the native
  decision, the code-mode bridge's decision and `codemode/launch.path_reachable`
  from one policy value for both read scopes. A change to how the jail masks a
  path needs a matching change here, and that test is what notices when it is
  missing.
- Reading a protected path was allowed before and is refused now, except
  for the blob root. That exemption is the one place the native view is wider
  than the jail's, which masks the blob root too.
- `/proc`, `/dev` and `/tmp` are refused on reads outside the workspace
  although a jailed command can read the jail's own versions of them. The
  native view is narrower there on purpose; the shared constant is what keeps
  it from drifting from `bwrap.go`'s mounts.
- Only a regular file is read natively, and `read_lines` refuses anything
  that is not one, so a device or FIFO cannot hang a read.
- The path check is point-in-time, as `resolve_real` always was.
