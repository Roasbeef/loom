# protocol-change/065: process ownership label for runtime inspectors

**Status**: PROPOSED 2026-10-03. **Affects**: the shape of the OTP process
label on Loom's processes; `telemetry/log.adopt`'s signature. No frozen Part 1
interface, client wire schema or durable row changes. **Raised by**: issue #720
(native runtime inspector), phase 1 ownership model. **Implemented**:
telemetry, runtime, client

## Problem

An inspector attached to a running `loomd --profile` node can read a process's
memory, reductions and mailbox length from `process_info/2`. It cannot learn
which session or strand accounts for them. Registration, links and supervision
are evidence of ownership and not proof of it, and a strand's restart factory
and its effect workers sit under different supervisors than the session that
owns them. Without a declaration by the process itself, every heap in the node
reads as unattributed.

Pickglass is such an inspector: a separate project that attaches over Erlang
distribution and reads ownership from process labels only
(`docs/design/plan.md`, "Ownership is a protocol, not a library call"). The
convention is defined on its side. Loom has to agree to emit it, and has to say
which processes carry which role, because a label is a wire format between two
projects that release independently.

## What was considered

- **Infer ownership from the supervision tree and registered names.** Rejected.
  Effect workers are spawned unlinked, so they appear under no supervisor, and
  names carry no session. An inference that is right most of the time attributes
  a leak to the wrong session the rest of the time.
- **Process dictionary or `logger` metadata.** `logger` metadata already carries
  `{session, strand, op, step}` (`telemetry/context`), but reading it from
  outside needs `process_info(Pid, dictionary)`, which copies the whole
  dictionary of a possibly busy process. The label is read with
  `process_info(Pid, label)`, which returns that one term. Metadata stays what
  it is: correlation for log lines.
- **A Loom-specific tuple with its own tag.** Rejected. The reader is written
  against one shape, and a second tag would be a second decoder for no gain.
- **A pickglass library dependency.** Rejected. Loom emits a plain Erlang term;
  nothing in the tree imports pickglass.

## Decision

A Loom process that has an owner calls
`proc_lib:set_label({pickglass_owner, 1, Path, Role})` once, from its own
process, at the top of its body.

- `Path` is a list of `{Kind, Id}` pairs of binaries, outermost first. Loom
  emits `{<<"session">>, SessionId}` and, for a strand-scoped process,
  `{<<"strand">>, StrandId}` after it. A process owned by the daemon and not by
  a session has the path `[]`. Ids are the canonical Loom ids already used in
  log lines, never a display name or a path on disk.
- `Role` is a binary in lowercase snake case. The set below is closed. Adding a
  role is an edit to this proposal and to `telemetry/owner.Role`, not to a call
  site, because an inspector groups by role name.
- Loom emits exactly the four-element form. A fifth element listing capability
  binaries (for example `[<<"measure">>]`) is reserved by the reader and Loom
  does not emit it. Loom does not answer `pickglass_measure` messages.
- The first element is the atom `pickglass_owner` and the second is the integer
  version `1`. A change to the shape bumps the version, and a reader that sees a
  version it does not know shows the process as `unknown`.

`proc_lib:set_label/1` replaces any label the calling process set earlier. Loom
therefore uses the label for ownership and for nothing else, and no module
outside `telemetry/owner` may call it. A process that must carry another label
for another reader needs a combined shape agreed here first. A label is
per process and is not inherited by a spawn, so each spawned body labels
itself. Loom never reads a label back and no behavior depends on one.

### Roles

| Role | Path | Process |
| --- | --- | --- |
| `strand_driver` | session, strand | The strand's driver actor (`runtime/strand_runtime`). It is also the strand's restart custodian: the factory restarts it and its options are what a replacement starts from. |
| `effect_worker` | session, strand | A process running one tool, hook or timer effect for a strand. |
| `provider_effect_worker` | session, strand | A process running one provider request for a strand, the top-level drain witness for its stream. |
| `gateway` | session | The session's client gateway actor (`client/gateway`). |
| `page_socket` | session | The process serving one web view page's socket, which owns the page's Lustre component (`client/daemon/ui_socket`). |
| `page_sessions` | none | The daemon's table of web view tickets and UI sessions (`client/daemon/ui_sessions`). |

`log.adopt` takes the role as an argument and labels the process from the
logger's context, so a process that adopts a logger cannot carry a path that
disagrees with its log lines. A process with no logger in reach calls
`owner.label` with the path it supplies.

### Not labelled

These stay `unknown` to an inspector until a seam exists that does not need a
session id threaded through a package that has none:

- The session supervisor tree's root and the writer and registry actors.
  A process cannot label another, and the writer's session id is behind a
  fallible accessor.
- The language-server manager and its keepers (`client/lsp/manager`). Its
  `Config` carries a workspace and no session id.
- The provider gateway and custodian (`provider/gateway`). The provider package
  does not depend on telemetry.
- Code-mode launch and satellite processes (`codemode/launch`,
  `codemode/satellite`), for the same reason.
- The effect reaper's weft scope, the claimant, timer sleepers and the
  Lustre component's own process, which belongs to the Lustre runtime.

## What it costs

One process-dictionary write per labelled process, measured at about 30 ns for
a two-element path on OTP 29. A strand driver labels once per incarnation and
an effect worker once per effect, which is already the frequency at which
`log.adopt` stamps `logger` metadata. The label retains the ids as binaries
the process already holds.

`log.adopt` gains a parameter, so its two callers and the test callers change.
`ui_sessions` moves from `actor.new` to `actor.new_with_initialiser` so its
initialiser can label the process it runs in. The label exposes session and
strand ids to anyone who can attach to the node over distribution. That
principal already has full control of the node, and the ids are not secrets,
but the owner-only distribution cookie remains the only gate.

The roles above are a contract with a separately released reader. Renaming one
silently regroups an inspector's view, which is why the set lives here.

## Addendum: roles added after a live census (issue #720)

A census of a profiled `loomd` with two open sessions, taken through pickglass
and a hidden node, showed 221 processes and 79.7 MiB under `unknown`. This
addendum adds the roles that attribute the session-owned part of it and
records what stays unlabelled. The shape of the label, the path kinds and
the version are unchanged.

### Roles added

| Role | Path | Process |
| --- | --- | --- |
| `session_host` | session | The resident builder that assembled the session and stays as its cleanup custodian (`client/internal/instance_host`, started from `client/daemon/manager`). |
| `domain_host` | none | The same builder and custodian for a workspace domain. It serves no one session. |
| `agency` | session | The session's agency actor (`client/agency`), which holds the runtime and the child-strand ledger. |
| `escalation` | session | The session's escalation holder (`client/escalate`). |
| `async_runs` | session | The asynchronous code-mode run supervisor (`client/async_runs`). |
| `background_jobs` | session | The background jobs actor (`client/jobs`). |
| `advisor` | session | The advisor actor (`client/advisor`). |
| `glance` | session | The glance loop (`client/glance`). |
| `block_summarizer` | session | The block summarizer (`client/blocksummary`). |
| `rule_scanner` | session | The rule scanner (`client/rulescan`). |
| `schedule_scanner` | session | The schedule scanner (`client/schedulescan`). |

The path of each session role is the canonical session id from the runtime the
process was wired with (`client/internal/session_owner`), which is the key the
gateway already uses. The block summarizer has no runtime in its wiring, so the
host scopes the logger it receives to the session and the machine adopts it
(`log.adopt`), the same route the strand driver takes. The advisor, glance and
background jobs actors hold the runtime only as a borrow through the agency;
their initialisers ask for it once, and a refused borrow leaves the process
unlabelled instead of failing its start. Each label is set in the initialiser
of the process it names. The `async_runs` and `escalation` labels are covered
by tests that read `process_info(Pid, label)`, the host's label hook by a test
that runs it in the host's own process, and the role names by the
`telemetry/owner` test; a live census confirmed every role except
`rule_scanner`, which a session with no rules does not start.

### Still unlabelled, and why

- **The supervisors.** `gleam_otp`'s static and factory supervisors run their
  `init` inside the library, and a process labels only itself, so Loom has no
  seam. They hold most of what remains under `unknown`: a session's top
  supervisor was about 9.8 MiB hibernating, and its `sys:get_state` is
  about 20 MiB of child specifications before sharing, because each
  `supervision.worker(fn() { ... })` retains the closure it restarts from. That
  is retained configuration, and it is a separate finding for #720 rather than
  a labelling gap.
- **Every ETS owner.** None of the 47 tables was owned by a process Loom
  starts and can label. They belong to OTP (`code_server`, `logger`,
  `application_controller`, `inet_db`, `global_name_server`, `auth`,
  `net_kernel`, `httpc_manager`, `ssl_manager`, `ssl_pem_cache`,
  `inet_gethost_native`, `dtls_listener_sup`), to dependencies (`mist_clock`,
  `gun_pools`), to the `loom_events` `pg` scope that
  `events/internal/ffi_pg` starts and OTP runs, and to weft's per-scope
  registry actors (`weft_registry_ffi`, about 0.5 KiB each). Of the 1.8 MiB,
  `code_server` accounts for 1.2 MiB. The weft registries belong to weft, which
  does not depend on telemetry and should not.
- **OTP's own processes**, notably `code_server` (about 4 MiB) and
  `application_controller`.
- **Small Loom actors**, each under 0.1 MiB: the broker's executor and exec
  machines, the session writer (`runtime/api`), the language-server manager and
  its keepers (still without a session id in its `Config`), and the other
  small service actors, such as the scratch store.

After the change a census of the same shape (two fresh sessions) showed 201
processes and 42.1 MiB under `unknown`. The two runs differ in session age, so
the figure shows the order of the change and not an exact delta.
