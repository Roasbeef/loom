# host

## Purpose

Shared operating-system primitives for the daemon and terminal launcher.
Shared endpoint policy stays in Gleam; this package owns its typed private
record and the filesystem, lock, process, clock, and cryptographic operations
beneath it. The shared WebSocket transport owns socket startup and lifetime;
callers own launch timing, authentication policy, and application messages.

## Key Types

- `host/bootstrap.LaunchLock` holds the original lock-helper port.
  `try_launch_lock` acquires it, `lock_monitor` observes its death, and
  `release_launch_lock` closes it. The calling process owns its lifetime.
- `host/bootstrap.ServerProcess` retains a paused wrapper's port.
  `spawn_server` returns it with the OS PID; `release_server_process` lets
  the wrapper exec the server after its identity has been published.
- `host/bootstrap.ProcessIdentity` distinguishes `ProcessPresent(birth)`
  from confirmed `ProcessAbsent`. Observation errors remain errors.
- `host/endpoint.{Paths, Fence, Endpoint}` defines fixed state-root paths and
  `Starting`/`Ready` discovery. `availability` permits replacement only for
  fresh state or an observed departed native identity. `claim` adopts only
  the matching paused-wrapper reservation; `publish_ready` replaces that exact
  reservation with the actual listener port and daemon epoch.
- Private-file operations validate ownership and permissions, bound reads,
  and atomically replace a file after flushing its complete contents.
- `host/websocket.Connection` retains the original socket subject.
  `connect_mapped` maps lifecycle events in the existing socket owner, so
  terminal adapters need no forwarding process.

## Relationships

- **Depends on**: `core/json` for the bounded total endpoint codec;
  `gleam_stdlib` for typed results; `gleam_erlang` for the
  lock monitor type; `gleam_http` and `stratus` for the existing WebSocket
  transport; `weft` for guarded startup and socket custody. These transport
  dependencies moved from the TUI; no second WebSocket implementation was added.
- **Depended on by**: `client` for daemon state-root ownership; `tui` for
  local server bootstrap. Terminal logger suppression, stdout forwarding,
  and VM exit remain in `tui`.
- **FFI**: `host/internal/ffi_bootstrap` confines calls into
  `host_bootstrap_ffi.erl` and OTP's port monitor. The Erlang implementation
  is extracted from the TUI, not a second implementation of its primitives.

## Traffic

- **Actor messages**: `websocket.Message` delivers `Connected`, `Incoming`,
  `Closed`, and `NetworkFault` to the original reader-owned inbox.
  `Outbound.SendText` and `Stop` reach the existing Stratus socket actor.
  Its guardian monitors the reader and startup attempt; Erlang ports separately
  deliver data and exit status, and `lock_monitor` delivers `process.PortDown`.
- **Commits and registers**: none. Conversation databases are outside this package.
- **OS boundary**: lock helpers use `lockf` on Darwin and `flock` on Linux.
  A paused server wrapper waits for one release line before exec. Birth
  identity uses Linux procfs or Darwin `ps`; canonical paths use `realpath`.

## Invariants

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
- A failed probe, root death, or released lifetime lock never replaces a
  still-live VM. Missing discovery beside existing catalogue state and malformed
  records fail closed. Endpoint removal is not part of normal shutdown.
- The launcher releases `launch.lock` before waiting for a child which must
  reacquire it. `daemon.lock` independently bounds the root's live resources.
- Guarded WebSocket startup retains its links until the guardian acknowledges
  ownership. Abnormal attempt loss or reader death closes the original socket;
  normal startup-worker exit does not close a successfully returned handle.
- The transport does not implement application credits or bound an arbitrary
  reader's inbox. Callers enforce their protocol's frame and outstanding-work
  limits; moving the transport does not establish a new memory bound.

## Deep Docs

- [Client architecture](../../docs/architecture/client.md) explains local startup.
- [Root CLAUDE.md](../../CLAUDE.md) contains repository rules and the doc graph.
