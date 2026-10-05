# host

## Purpose

Shared operating-system primitives for the daemon and terminal launcher.
Shared endpoint policy stays in Gleam; this package owns its typed private
record and the filesystem, lock, process, clock, and cryptographic operations
beneath it. The shared WebSocket transport owns socket startup and lifetime;
callers own launch timing, authentication policy, and application messages.

## Key Types

- `host/skill.Catalogue` captures canonical skill documents and discovery
  warnings. Each `Skill` keeps its name, description, argument hint, invocation
  modes, source path, body and complete document together. `discover` suppresses
  directory/file aliases and reports distinct name collisions; `expand` discloses
  the complete captured document only at activation, with bounded substitution.

- `host/bootstrap.LaunchLock` holds the original lock-helper port.
  `try_launch_lock` acquires it, `lock_monitor` observes its death, and
  `release_launch_lock` closes it. The calling process owns its lifetime.
- `host/bootstrap.ServerProcess` retains a paused wrapper's port.
  `spawn_server` returns it with the OS PID; `release_server_process` lets
  the wrapper exec the server after its identity has been published.
  `spawn_server` waits for one byte the wrapper's shell writes before it
  parks, so the PID it returns already leads its own process group: OTP
  reports a forked child's PID before the child calls `setsid`.
- `host/bootstrap.ProcessIdentity` distinguishes `ProcessPresent(birth)`
  from confirmed `ProcessAbsent`. Observation errors remain errors. The Erlang
  side returns exactly this shape, so nothing translates between the
  observation and the caller.
  On Linux, only `ENOENT` and `ESRCH` from the target `/proc/<pid>/stat`
  read establish absence; boot-id, self-stat and other read errors stay errors.
- `host/endpoint.{Paths, Fence, Endpoint}` defines fixed state-root paths and
  `Starting`/`Ready` discovery. `availability` permits replacement only for
  fresh state or an observed departed native identity. `claim` adopts only
  the matching paused-wrapper reservation; `publish_ready` replaces that exact
  reservation with the actual listener port and daemon epoch.
- Private-file operations validate ownership and permissions, bound reads,
  and atomically replace a file after flushing its complete contents.
- `host/claim` is the shape of a claim token (protocol-change/053) shared by
  the daemon that mints claims, `loomd access` that prints them and `loom
  claim` that redeems them: `prefix` (`loomclaim_`), `validate_token` (the
  prefix and 64 lowercase hex, nothing else), `is_claim_shaped`,
  `mint_token(entropy)`, `random_credential` (32 bytes of
  `crypto:strong_rand_bytes`), and `digest` (lowercase SHA-256 hex). It also
  owns `remote_address`, the rule that a bearer or a claim crosses cleartext
  `ws` only to a literal loopback address, and `endpoint`, which turns a
  `/v2/control` address into its `/v2/claim` twin.
- `host/access` is the owner's access command (protocol-change/053), one
  implementation behind `loomd access` and `loom access`. `parse(arguments,
  program)` turns the positional grammar (`list`, `show`, `members`, `invite`,
  `set-role`, `revoke`, `rotate`, `revoke-credentials`, `isolate`) into an
  opaque `Request` whose target is `Local` (the state directory's endpoint
  record and `owner.token`) or `Remote` (`--addr` with `--token-file`, which
  only `Loom` accepts). `run(arguments, program, check)` prints through a
  `Console` and answers `Succeeded` or `Failed`; the binary turns that into
  its exit status, and `check` lets `loomd` add the daemon's own decoder as a
  further refusal. `principal_lines`, `membership_lines` and `member_lines` (a
  session's members, `loom access members SESSION [--after PRINCIPAL]`) are the
  listing checks on their own, and `invite_line` and `rotate_line` render the `loom
  access` lines the terminal's `/access` overlay shows in place of granting
  (phase 3). Replies are re-encoded from checked fields: a listing row
  keeps a 16-hex fingerprint and never a longer value, a claim is printed only
  for an invitation or rotation that asked for one, and any other field the
  daemon sent is dropped. `raw_request`, `discover` and `exchange` are the
  seam the peer commands share.
- `host/websocket.Connection` retains the original socket subject.
  `connect_mapped` maps every lifecycle event in the existing socket owner, so
  terminal adapters need no forwarding process. `Connected` is minted in the
  Stratus initialiser, which runs after the upgrade and before the actor's
  first loop pass, so it cannot arrive behind an `Incoming` or `Closed` the
  socket delivered while startup was still returning.

## Relationships

- **Depends on**: `glaml`/`yamerl` for YAML skill frontmatter and `gleam_regexp`
  for Unicode skill names; `core/json` for the bounded total endpoint codec;
  `gleam_stdlib` for typed results; `gleam_erlang` for the whole of
  `gleam/erlang/process` that `host/websocket` runs on — monitors, selectors,
  links, trapped exits — and for the lock monitor type; `gleam_http` and
  `stratus` for the existing WebSocket transport; `weft` for guarded startup,
  socket custody and the monotonic clock; and `gleam_crypto`, `gleam_time`,
  `envoy`, `simplifile` and `filepath` for the facts that used to be
  hand-written Erlang. These transport dependencies moved from the TUI; no
  second WebSocket implementation was added.
- **Depended on by**: `client` for daemon state-root ownership, the claim
  token shape and `loomd access`; `tui` for local server bootstrap, its own
  bounded file reads, the remote-address rule, `loom claim` and `loom access`. Terminal logger suppression,
  stdout forwarding, and VM exit remain in `tui`.
- **FFI**: `host/internal/ffi_zlib` exposes the shared bounded gzip inflater
  in `host_zlib_ffi.erl`. Extension installation retains its original client
  adapter, while release installation calls the shared primitive directly.
  OTP zlib produces bounded chunks; the shim rejects excess output before
  retaining another chunk. `host/bootstrap` and `host_bootstrap_ffi.erl` hold
  the remaining operations no Gleam package reaches: cross-process advisory locking through a helper port,
  `open_port` process launch and release, a positioned bounded read
  (`read_prefix`/`read_bounded`), an exclusive-create atomic rename,
  `realpath`, `os:find_executable`, `os:getpid`, `id -u`, procfs and Darwin
  `ps` birth identity, and the loopback-port reservation the legacy v1
  launcher still uses. Clocks, digests, the environment, `stat`, directory
  listing and permission bits are Gleam over the packages above. OTP's port
  monitor is called directly from `host/bootstrap` because `gleam_erlang`
  exposes `process.PortDown` but no public port-monitor constructor.

## Traffic

- **Actor messages**: `websocket.Message` delivers `Connected`, `Incoming`,
  `Closed`, and `NetworkFault` to the original reader-owned inbox.
  `Outbound.SendText` and `Stop` reach the existing Stratus socket actor.
  Its guardian monitors the reader and startup attempt; Erlang ports separately
  deliver data and exit status, and `lock_monitor` delivers `process.PortDown`.
- **Commits and registers**: none. Conversation databases are outside this package.
- **OS boundary**: lock helpers use `lockf` on Darwin and `flock` on Linux.
  A paused server wrapper waits for one release line before exec, and its
  environment is this VM's plus `LOOM_LOG` rather than a replacement for it,
  so the daemon inherits provider credentials and locale. Birth identity uses
  Linux procfs or Darwin `ps`; canonical paths use `realpath`, and
  `ensure_private_directory`/`read_private_bounded` use `/usr/bin/id` for the
  one fact `stat` cannot give them. `host/endpoint` therefore needs a platform
  `realpath` and `/usr/bin/id` on the startup path.

## Invariants

- Skill discovery reads at most 256 direct entries per configured location and
  64 KiB per document. Metadata and body share one capture; model context gets
  only selection metadata until invocation. No skill frontmatter or shell
  snippet executes in the host, and expansion grants no tool permissions.

- The lock owner must outlive readiness. Port loss can release the kernel
  lock even if a pathname still exists; the pathname alone proves nothing.
- Darwin uses `lockf -k` to preserve one inode across releases. Competing
  owners must never lock different inodes through the same pathname.
- Paths cross the Erlang boundary as Unicode characters, never UTF-8 bytes
  expanded into separate codepoints.
- A wrapper starts paused. Its caller publishes PID and birth identity before
  release. Closing its port after exec does not prove that the server stopped.
- Failure to observe a process is not confirmed absence. Startup policy must
  not infer safe replacement from an observation error.
- Birth identity is not equally strong on both platforms. Linux pairs the
  kernel boot id with `/proc/<pid>/stat`'s `starttime`, which is jiffy-grained;
  Darwin's `ps -o lstart=` has one-second resolution, so two processes born
  within the same second under one recycled pid are indistinguishable there.
  Nothing in the design closes that gap; it bounds how much a Darwin birth
  marker proves.
- A daemon log is arbitrary child output, so `current_log_tail` returns bytes
  and `host/bootstrap` decodes them. A byte offset can land inside a codepoint,
  and a `String` minted from such a slice breaks the type's invariant for every
  later `string.*` call on the one path that reports why startup failed.
- A failed probe, root death, or released lifetime lock never replaces a
  still-live VM. Missing discovery beside existing catalogue state and malformed
  records fail closed. Endpoint removal is not part of normal shutdown.
- The launcher releases `launch.lock` before waiting for a child which must
  reacquire it. `daemon.lock` independently bounds the root's live resources.
- Guarded WebSocket startup retains its links until the guardian acknowledges
  ownership. Abnormal attempt loss or reader death closes the original socket;
  normal startup-worker exit does not close a successfully returned handle.
  A guardian that fails to start is the one exit that would otherwise leave a
  socket with no owner — the worker exits normally and a normal exit over a
  link is ignored — so that path kills the socket explicitly.
- The transport does not implement application credits or bound an arbitrary
  reader's inbox. Callers enforce their protocol's frame and outstanding-work
  limits; moving the transport does not establish a new memory bound.
- A claim token and a bearer are told apart by shape alone: a claim always
  carries the prefix and a bearer never does. Every place that accepts one
  refuses the other, and no function here logs, formats or echoes either;
  `validate_token`'s refusal is a fixed sentence that does not repeat its
  input.

## Deep Docs

- [Skills](../../docs/skills.md) describes discovery and progressive disclosure.

- [Client architecture](../../docs/architecture/client.md) explains local startup.
- [Root CLAUDE.md](../../CLAUDE.md) contains repository rules and the doc graph.
