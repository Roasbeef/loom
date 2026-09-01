//// The production satellite launcher — the `codemode/satellite.Launcher`
//// that turns a `LaunchSpec` into a real jailed `erl` node on the far end
//// of a real AF_UNIX capability socket (design §6.3 "Layer two: the
//// satellite node", `docs/architecture/code-mode.md`).
////
//// The host's module doc states the contract; this module realizes it,
//// in this order:
////
//// 1. **Refuse before anything exists.** The launch composes the session
////    base with the node's requirements *itself*, purely, and refuses
////    in-band when the base cannot host a satellite — no socket is
////    created, no node is dispatched, and the message names the exact
////    shortfall. The dispatch then also carries `RefuseNarrowed`, so a
////    broker that composes differently refuses rather than running a
////    weaker jail than the one this module checked.
//// 2. **Cap socket first.** An AF_UNIX *stream* listener is created at
////    `cap_socket_path` before the node is launched, so the satellite's
////    `gen_tcp:connect` cannot lose a race with it.
//// 3. **Then the node**, dispatched through `broker.clear_call` under the
////    *same* `{op_id, step_id}` the host uses. That is what makes
////    `broker.abort` on the host's deadline actually kill it.
////
//// # Two processes, one ordering guarantee
////
//// The socket is served by two unlinked processes. The **reader** accepts
//// the connection, owns it, and blocks in `recv`, pushing every chunk to
//// `LaunchSpec.wire` as `WireBytes` and, at end of stream, exactly one
//// `WireClosed`. The **writer** holds the outbound side: it buffers frames
//// the host emits before the satellite connected, flushes them on attach,
//// and closes both sockets on teardown.
////
//// Splitting them buys the ordering the host depends on. Every inbound
//// byte and the close both come from the reader, in stream order, and
//// `gen_tcp:recv` yields buffered data before it reports the peer gone —
//// so a satellite that writes its terminal `outcome` frame and exits can
//// never have its death overtake its result. The node's own exit status
//// travels a different path (the exec settlement), and is therefore used
//// only to *enrich* the reason on a close the reader already observed,
//// never to announce one.
////
//// # What `SandboxPolicyV1` can and cannot say about reachability
////
//// The node needs two host paths inside the jail: the cap socket, which it
//// must `connect(2)`, and the token file, which it must read. The frozen
//// policy vocabulary (spec Part 1.4) has no "bind this path" verb, so this
//// module expresses both as `readable_roots` entries and *checks* the
//// composed policy actually covers them. What makes that sufficient today
//// is the helper's base view — bwrap ro-binds the whole host filesystem
//// read-only — plus three kernel facts: `sb_permission` exempts sockets
//// from `EROFS`, so `connect(2)` on a read-only mount succeeds; Landlock's
//// filesystem rights do not govern connecting to an existing socket; and
//// the network-off seccomp filter denies only non-`AF_UNIX` socket
//// creation.
////
//// Two things the policy type genuinely cannot express, and which this
//// module therefore refuses rather than discovers at runtime: a cap socket
//// or token under a `protected` path (bwrap shadows it with a read-only
//// tmpfs) and, when scratch is a tmpfs, one under `/tmp` (the helper mounts
//// the scratch tmpfs there, hiding whatever the host had). Both make the
//// path unreachable inside the jail while looking perfectly fine outside
//// it. See `protocol-change/004-sandbox-policy-explicit-mounts.md` for the
//// vocabulary that would state this positively instead.

import broker/broker.{type Broker, type CallSpec}
import broker/budget.{type Budget}
import broker/exec.{type EnforcementDemand}
import broker/policy.{type Grant, type Narrowing, type SandboxPolicy}
import codemode/compile.{type Artifact}
import codemode/enforcement.{type Report}
import codemode/identity
import codemode/internal/ffi_unix.{type Listener, type Socket}
import codemode/satellite.{type CapConnection, type LaunchSpec}
import core/clock.{type Clock}
import filepath
import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import tools/tool.{type Collected}
import weft/poll
import weft/state_machine as sm

/// The environment variable naming the cap socket. Mirrors
/// `cap/runtime.sock_env`; the host does not depend on the `cap` package
/// (it must never link model-facing code), so the name is restated here
/// and pinned by a test against the boot contract.
pub const sock_env = "LOOM_CAP_SOCK"

/// The environment variable naming the private cap-token file. Mirrors
/// `cap/runtime.token_env`; see `sock_env`.
pub const token_env = "LOOM_CAP_TOKEN_FILE"

/// Where the Go helper mounts a `ScratchTmpfs` policy's scratch area
/// (`jail.ScratchMount`). A cap socket under this path is invisible inside
/// the jail, so the launcher refuses one.
pub const scratch_mount = "/tmp"

// How long a handoff from a freshly spawned socket process may take.
const handoff_timeout_ms = 2000

// One accept poll. The accept is sliced so the reader can notice, between
// slices, that the node died before it ever reached the socket.
const accept_poll_ms = 200

// How long the synchronous `clear_call` for the node itself may take.
const clear_timeout_ms = 5000

// Slack over the wall deadline before the node's collector gives up.
const settle_margin_ms = 10_000

// How long the reader waits, after end of stream, for the node's own exit
// status to arrive and sharpen the close reason.
const exit_reason_wait_ms = 2000

// How long `destroy` waits for the node's own settlement, and with it the
// helper's enforcement report.
//
// `destroy` aborts first, so by the time it waits the node is either
// already gone (the program returned and the node exited) or being killed.
// A cancelled execution still answers with `exec_exit`, but only after the
// helper's TERM-then-KILL ladder; the broker's relay gives that ladder a
// 5s grace and then settles the call itself as `CancelEscalated`.
//
// This wait must outlast that grace, and the number is chosen for a
// reason beyond patience: whichever of the two expires first decides what
// the report *says*. Giving up first would answer "nobody reported in
// time", which is a statement about this timer; waiting for the broker
// answers "the helper was killed before it could report", which is a
// statement about the node. The second is the truth, and a report that
// describes a race rather than a jail is the failure this whole path was
// built to remove (issue #5). Still bounded either way: a broker that
// never settles at all costs this once.
const node_report_wait_ms = 6000

// The satellite node itself holds one outstanding effect for the whole
// execution, so a pooled budget of one would starve every `cap_call`.
const minimum_outstanding = 2

// A cross-platform margin under Linux's 108-byte and macOS's 104-byte
// `sun_path` limits. Client-side workspace preparation uses the same budget.
const max_socket_path_bytes = 100

/// Everything the production launcher needs beyond the `LaunchSpec`.
pub type LaunchConfig {
  LaunchConfig(
    /// The running broker. The node is dispatched through it, and
    /// `destroy` aborts through it.
    broker: Broker,
    /// Reads the wall clock to size the node's own deadline.
    clock: Clock,
    /// Absolute path to the `erl` executable.
    erl_path: String,
    /// Enforcement strictness demanded of the jailed node.
    demand: EnforcementDemand,
    /// How long to wait for the satellite to connect back.
    accept_timeout_ms: Int,
  )
}

/// Builds the production `satellite.Launcher`.
///
/// The returned function is what `satellite.run` calls: it creates the
/// cap socket, dispatches the jailed node, and hands back the
/// `CapConnection` the host writes frames to and destroys the node with.
pub fn launcher(config: LaunchConfig) -> satellite.Launcher {
  fn(spec) { launch(config, spec) }
}

fn launch(
  config: LaunchConfig,
  spec: LaunchSpec,
) -> Result(CapConnection, String) {
  use _ <- result.try(check_budget(identity.pooled_budget(spec.identity)))
  let #(now, _clock) = clock.read(config.clock)
  let requirements = node_requirements(spec, now)
  use effective <- result.try(composed_policy(
    spec.base_policy,
    requirements,
    identity.grants(spec.identity),
  ))
  use _ <- result.try(path_reachable(
    effective,
    spec.cap_socket_path,
    "the cap socket",
  ))
  use _ <- result.try(path_reachable(
    effective,
    spec.token_path,
    "the cap token file",
  ))
  use _ <- result.try(private_directory(directory_of(spec.cap_socket_path)))

  // The kernel truncates nothing and rejects instead: an AF_UNIX bind
  // address longer than the platform's sun_path limit fails with einval,
  // which reads as a kernel fault when the real problem is a workspace
  // (or test scratch) sitting too deep. Name it before listen can see it.
  // The budget mirrors client/codemode's guard, chosen once so both layers
  // tell the same story.
  use _ <- result.try(
    case socket_path_bytes(spec.cap_socket_path) > max_socket_path_bytes {
      False -> Ok(Nil)
      True ->
        Error(
          "the cap socket would be "
          <> spec.cap_socket_path
          <> ", which is longer than the 100 bytes a unix socket path may "
          <> "have; run the session from a shallower workspace",
        )
    },
  )
  use listener <- result.try(
    result.map_error(ffi_unix.listen(spec.cap_socket_path), fn(reason) {
      "could not listen on the cap socket: " <> reason
    }),
  )
  start_channel(config, spec, requirements, listener, now)
}

// Everything from here on owns a live listener, so every failure path
// closes it and unlinks the socket file rather than returning.
fn start_channel(
  config: LaunchConfig,
  spec: LaunchSpec,
  requirements: SandboxPolicy,
  listener: Listener,
  now: Int,
) -> Result(CapConnection, String) {
  let writer_handoff = process.new_subject()
  let _writer =
    process.spawn_unlinked(fn() { writer_main(listener, writer_handoff) })
  case process.receive(writer_handoff, handoff_timeout_ms) {
    Error(Nil) -> {
      ffi_unix.close_listener(listener)
      unlink(spec.cap_socket_path)
      Error("the cap-socket writer did not start")
    }
    Ok(outbox) ->
      start_reader(config, spec, requirements, listener, outbox, now)
  }
}

fn start_reader(
  config: LaunchConfig,
  spec: LaunchSpec,
  requirements: SandboxPolicy,
  listener: Listener,
  outbox: Subject(Out),
  now: Int,
) -> Result(CapConnection, String) {
  let reader_handoff = process.new_subject()
  let _reader =
    process.spawn_unlinked(fn() {
      reader_main(
        listener,
        outbox,
        spec.wire,
        config.accept_timeout_ms,
        reader_handoff,
      )
    })
  case process.receive(reader_handoff, handoff_timeout_ms) {
    Error(Nil) -> {
      process.send(outbox, Shutdown)
      unlink(spec.cap_socket_path)
      Error("the cap-socket reader did not start")
    }
    Ok(exits) -> {
      let settlement = start_reporter(config.broker)
      spawn_node(config, spec, requirements, exits, settlement, now)
      start_janitor(config, spec, outbox, settlement)
      Ok(
        satellite.CapConnection(
          send: fn(bytes) { process.send(outbox, Emit(bytes:)) },
          destroy: fn() { destroy(config, spec, outbox, settlement) },
        ),
      )
    }
  }
}

// Destroying the satellite: abort the operation (which revokes its tokens
// and kills the node and every executor it fanned out), collect what the
// kernel enforced on the node, close both ends of the socket, and unlink
// the socket file. Idempotent — the host calls it once on every exit path,
// and `satellite.hand_over` may call it instead.
//
// The abort is what makes the report *reachable* rather than what loses
// it: a node that has already exited has already settled, and a node still
// running settles because the abort cancels it, which the helper answers
// with an `exec_exit` carrying the same report. So destroy aborts, then
// waits (bounded) for the settlement, and hands the report to the caller —
// which is the host, about to report the execution's outcome (issue #5).
fn destroy(
  config: LaunchConfig,
  spec: LaunchSpec,
  outbox: Subject(Out),
  settlement: Subject(Settlement),
) -> Report {
  broker.abort(config.broker, identity.op_id(spec.identity))
  let report = await_report(settlement)
  process.send(outbox, Shutdown)
  unlink(spec.cap_socket_path)
  report
}

// --- the node's enforcement report ---------------------------------------

// The node's lifecycle, held for whoever destroys the connection.
//
// A plain subject would not do: the collector, the host actor, and the
// janitor are three different processes, and a subject is received on only
// by its owner. This is a tiny holder machine instead — a
// `weft/state_machine`, so the states below are an ADT every event is
// dispatched against exhaustively rather than a tuple of loop arguments.
// It does two things no shared mailbox could:
//
// - It **remembers** the one settlement the collector produced, so a
//   second `destroy` — the janitor's, after the host's — is answered from
//   memory rather than left waiting for a settlement that already
//   happened.
// - It **orders teardown against the clearance**. `destroy` may run before
//   the node's `clear_call` has even returned, and an `abort` that arrives
//   first cancels nothing: the node would then run on to its jail's wall
//   limit, and no settlement — so no report — would ever arrive. The
//   holder knows both events, so it cancels whichever arrives second and
//   the node settles either way.
type Settlement {
  /// The node's clearance succeeded; this is the handle to cancel it by.
  Cleared(handle: broker.CallHandle)

  /// The node settled, and this is what its helper reported.
  Settled(report: Report)

  /// Someone is tearing the node down and wants its report.
  Ask(reply: Subject(Report))
}

// Where the node has got to, from the holder's point of view.
//
// This is the machine's *state*, and only this: what cancels the holder's
// lingering deadline is a change of state, and what replays a postponed
// `Ask` is a change of state, so anything that must not do either — the
// broker to cancel through, the teardown fact — lives in `Holder` instead.
type NodeState {
  /// The clearance has not come back yet.
  Pending

  /// Cleared and running under this handle.
  Running(handle: broker.CallHandle)

  /// Settled, with the report to hand out.
  Done(report: Report)
}

// Whether teardown has reached the holder yet.
//
// An `Ask` is the teardown: nobody asks for the report except a `destroy`
// on its way out. Two named variants rather than a bare flag, because the
// two arms that read it read it for opposite reasons — the clearance
// cancels a node nobody wants any more, and the settlement arms the
// deadline that ends a holder nobody will ask again.
type Teardown {
  /// No `destroy` has been through; the execution still owns the node.
  Intact

  /// A `destroy` has been through, so the node is on its way out.
  TornDown
}

// What the holder carries across its states, unchanged by any of them.
type Holder {
  Holder(
    /// The broker to cancel the node's clearance through.
    broker_actor: Broker,
    /// Whether a `destroy` has already asked for the report.
    teardown: Teardown,
  )
}

// Every event the holder handles.
//
// The machine's message type is wider than the settlement protocol, so
// that `Linger` exists at all: the holder's own deadline is not something
// a sender could produce, and wrapping keeps it that way. The subject
// handed out is a `Subject(Settlement)` mapped into this, so no process
// outside the holder can forge a deadline it never armed.
type Held {
  /// One settlement, from the collector or from a `destroy`.
  Incoming(settlement: Settlement)

  /// The lingering deadline on `Done` expired; nobody else is coming.
  Linger
}

// The holder is deliberately **unlinked** from whoever launched the
// satellite: it has to outlive the host so the janitor's second `destroy`
// is answered from memory rather than left waiting on a settlement that
// already happened. weft's `unlinked` is that arrangement made a setting.
//
// The subject the machine returns is the one it built for itself, not the
// default weft would have given it: the default carries the machine's own
// `Held`, and what every sender in this module holds is a
// `Subject(Settlement)`.
fn start_reporter(broker_actor: Broker) -> Subject(Settlement) {
  let started =
    sm.new_with_initialiser(handoff_timeout_ms, fn(_default) {
      let inbox = process.new_subject()
      let selector =
        process.new_selector()
        |> process.select_map(inbox, Incoming)
      sm.initialised(Pending, Holder(broker_actor:, teardown: Intact))
      |> sm.selecting(selector)
      |> sm.returning(inbox)
      |> Ok
    })
    |> sm.on_event(reporter_step)
    |> sm.unlinked
    |> sm.start
  case started {
    Ok(machine) -> machine.data

    // A holder that would not start is a report nobody can collect; the
    // ask then times out and says so, which is the honest answer.
    Error(_error) -> process.new_subject()
  }
}

// One event, in one state.
//
// The pairs are exhaustive by construction: a fourth `Settlement` or a
// fourth node state is a compile error here rather than a message the
// holder silently drops.
fn reporter_step(
  node: NodeState,
  holder: Holder,
  event: Held,
) -> sm.Next(NodeState, Holder, Held) {
  case node, event {
    // An ask before the clearance has come back needs no pending list:
    // weft holds the event and replays it on the transition to `Done`, in
    // arrival order, where the arm below answers it. The teardown fact is
    // recorded first because the `Cleared` arm reads it to decide whether
    // the node it just learned about is already unwanted.
    Pending, Incoming(Ask(..)) -> mark_torn_down(holder) |> sm.postpone

    // Teardown while the node runs. The cancel goes out *before* the ask
    // is postponed because it is what makes the settlement the ask waits
    // for ever arrive: the helper answers a cancel with an `exec_exit`
    // carrying the same enforcement report.
    Running(handle:), Incoming(Ask(..)) -> {
      broker.cancel(holder.broker_actor, handle)
      mark_torn_down(holder) |> sm.postpone
    }

    // The report is in hand, so the ask is answered from memory. Arming
    // the deadline again here is what re-starts it for the next asker:
    // `keep` is not a state change, so the timeout survives, and arming
    // replaces the pending one rather than adding a second.
    Done(report:), Incoming(Ask(reply:)) -> {
      process.send(reply, report)
      linger(mark_torn_down(holder))
    }

    // Teardown got here first, so its cancel had nothing to name. Now it
    // does.
    Pending, Incoming(Cleared(handle:)) -> {
      case holder.teardown {
        Intact -> Nil
        TornDown -> broker.cancel(holder.broker_actor, handle)
      }
      sm.transition(to: Running(handle:), data: holder)
    }

    // A clearance is sent exactly once, by the one process that made the
    // call, and can only find the holder `Pending`: `Running` is the state
    // it produces itself and `Done` is downstream of it. Unreachable by
    // construction.
    Running(..), Incoming(Cleared(..)) | Done(..), Incoming(Cleared(..)) ->
      sm.keep(holder)

    // The node settled. Every ask postponed while it ran is replayed by
    // this transition, ahead of the mailbox and in arrival order, and each
    // is answered by the `Done` arm above — which is exactly what the
    // holder's old hand-kept `waiting` list did. The deadline is armed
    // only when teardown has already been through; a holder nobody has
    // asked yet still has an execution to serve and must not time out.
    Pending, Incoming(Settled(report:))
    | Running(..), Incoming(Settled(report:))
    -> {
      let settled = sm.transition(to: Done(report:), data: holder)
      case holder.teardown {
        Intact -> settled
        TornDown -> linger(settled)
      }
    }

    // Likewise settled twice: the collector sends one settlement and then
    // stops collecting. Unreachable by construction.
    Done(..), Incoming(Settled(..)) -> sm.keep(holder)

    // The second `destroy` never came. The report has been handed over and
    // the execution is over, so the holder ends here rather than outliving
    // every execution the session ever ran.
    Done(..), Linger -> sm.stop()

    // The deadline is armed only on `Done`, which the holder never leaves,
    // so no fire can reach these two states — weft's timer book drops a
    // fire that raced its own cancellation rather than delivering it.
    Pending, Linger | Running(..), Linger -> sm.keep(holder)
  }
}

// Record that a `destroy` has been through, without moving the node on: an
// ask says the execution is over whatever state the node itself reached.
fn mark_torn_down(holder: Holder) -> sm.Next(NodeState, Holder, Held) {
  sm.keep(Holder(..holder, teardown: TornDown))
}

// Arm the holder's last deadline.
//
// Once the node has settled, the report has been handed over, and teardown
// has been through, the only event still worth waiting for is a second
// `destroy` — the janitor's, right behind the host's. A *state* timeout is
// what bounds that wait honestly: it belongs to `Done`, which the holder
// never leaves, so the holder ends when the deadline expires instead of
// lingering for the life of the session.
fn linger(
  step: sm.Next(NodeState, Holder, Held),
) -> sm.Next(NodeState, Holder, Held) {
  sm.with_state_timeout(step, after: node_report_wait_ms, sending: Linger)
}

fn await_report(settlement: Subject(Settlement)) -> Report {
  let reply = process.new_subject()
  process.send(settlement, Ask(reply:))
  case process.receive(reply, node_report_wait_ms) {
    Ok(report) -> report
    Error(Nil) ->
      enforcement.Unreported(
        "its helper did not report within "
        <> int.to_string(node_report_wait_ms)
        <> "ms of teardown",
      )
  }
}

// The safety net for a host that never gets to clean up.
//
// The host's own teardown runs *inside* the host actor, so a host killed
// from outside — a supervisor shutdown, a kill signal — takes its `destroy`
// with it and leaves the node running, the socket bound, and the token file
// on disk (M4 triage CH-F3(b)). This mirrors the broker's fd-3 janitor: an
// unlinked process monitoring the actor, running the same teardown when it
// dies, however it died.
//
// `LaunchSpec.wire` is owned by the host actor, so its owner *is* the pid to
// watch. Running on an ordinary teardown too is harmless: abort is
// idempotent, the writer is already gone, and the unlinks are no-ops.
fn start_janitor(
  config: LaunchConfig,
  spec: LaunchSpec,
  outbox: Subject(Out),
  settlement: Subject(Settlement),
) -> Nil {
  case process.subject_owner(spec.wire) {
    Error(Nil) -> Nil
    Ok(host) -> {
      process.spawn_unlinked(fn() {
        run_janitor(config, spec, outbox, settlement, host)
      })
      Nil
    }
  }
}

fn run_janitor(
  config: LaunchConfig,
  spec: LaunchSpec,
  outbox: Subject(Out),
  settlement: Subject(Settlement),
  host: Pid,
) -> Nil {
  let monitor = process.monitor(host)
  let down =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_down) { Nil })
  let _ = process.selector_receive_forever(down)

  // Nobody is left to carry the report: the host that would have reported
  // the outcome is the process that just died.
  let _report = destroy(config, spec, outbox, settlement)

  // The token file is the host's to unlink, and a killed host will not do
  // it. A leaked token is not a disclosure — its directory is mode 0700 —
  // but it is a leak.
  unlink(spec.token_path)
}

// --- the writer process ---------------------------------------------------

// The outbound side of the cap socket.
type Out {
  /// The reader accepted a connection; adopt it and flush what buffered.
  Attach(socket: Socket)

  /// One encoded frame from the host.
  Emit(bytes: BitArray)

  /// Teardown: close the connection and the listener.
  Shutdown
}

fn writer_main(listener: Listener, handoff: Subject(Subject(Out))) -> Nil {
  let outbox = process.new_subject()
  process.send(handoff, outbox)
  writer_loop(listener, outbox, None, [])
}

fn writer_loop(
  listener: Listener,
  outbox: Subject(Out),
  socket: Option(Socket),
  pending: List(BitArray),
) -> Nil {
  case process.receive_forever(outbox) {
    Attach(socket: attached) -> {
      list.each(list.reverse(pending), fn(bytes) { write(attached, bytes) })
      writer_loop(listener, outbox, Some(attached), [])
    }
    Emit(bytes:) ->
      case socket {
        // Frames the host emitted before the satellite connected buffer
        // here rather than being dropped; the host's own `pending_out`
        // covers only what it emits before `Connected`.
        None -> writer_loop(listener, outbox, socket, [bytes, ..pending])
        Some(open) -> {
          write(open, bytes)
          writer_loop(listener, outbox, socket, pending)
        }
      }
    Shutdown -> {
      case socket {
        Some(open) -> ffi_unix.close(open)
        None -> Nil
      }
      ffi_unix.close_listener(listener)
    }
  }
}

// A failed write is the channel dying, which the reader reports as a close;
// there is nothing useful to do with the error here.
fn write(socket: Socket, bytes: BitArray) -> Nil {
  let _ = ffi_unix.send(socket, bytes)
  Nil
}

// --- the reader process ---------------------------------------------------

fn reader_main(
  listener: Listener,
  outbox: Subject(Out),
  wire: Subject(satellite.WireIn),
  accept_timeout_ms: Int,
  handoff: Subject(Subject(String)),
) -> Nil {
  let exits = process.new_subject()
  process.send(handoff, exits)
  accept_loop(listener, outbox, wire, exits, accept_timeout_ms)
}

// Polls the accept so a node that died before connecting is noticed as a
// death rather than as a timeout. `poll.until` owns the wall-clock budget
// and the sleep between attempts; there is deliberately almost none of
// the latter (`every: 1`) because the real wait already happens inside
// `accept_attempt`, which blocks in the FFI call for one slice at a time.
fn accept_loop(
  listener: Listener,
  outbox: Subject(Out),
  wire: Subject(satellite.WireIn),
  exits: Subject(String),
  accept_timeout_ms: Int,
) -> Nil {
  case
    poll.until(within: accept_timeout_ms, every: 1, attempt: fn() {
      accept_attempt(listener, exits)
    })
  {
    poll.Answered(socket) -> {
      process.send(outbox, Attach(socket:))
      read_loop(socket, wire, exits)
    }
    poll.Failed(reason) -> close_wire(wire, reason)
    poll.Expired ->
      close_wire(wire, "the satellite never connected to the cap socket")
  }
}

// One slice of the accept poll. The node's own exit is checked *before*
// the accept, non-blockingly, so a node that died between slices is
// reported as a death on the very next attempt rather than waiting out
// the rest of the budget only to time out — the distinction
// `retry_or_give_up` used to draw by giving up early is drawn here by
// answering `Fail` instead of `Retry`. Finding nothing yet blocks in
// `ffi_unix.accept` for up to `accept_poll_ms`, which is what stands in
// for the sleep between polls.
fn accept_attempt(
  listener: Listener,
  exits: Subject(String),
) -> poll.Attempt(Socket, String) {
  case process.receive(exits, 0) {
    Ok(reason) -> poll.Fail(reason)
    Error(Nil) ->
      case ffi_unix.accept(listener, accept_poll_ms) {
        Ok(socket) -> poll.Done(socket)
        Error(ffi_unix.AcceptTimeout) -> poll.Retry
        Error(ffi_unix.AcceptFailed(reason:)) ->
          poll.Fail(
            "the cap socket faulted before the satellite connected: " <> reason,
          )
      }
  }
}

fn read_loop(
  socket: Socket,
  wire: Subject(satellite.WireIn),
  exits: Subject(String),
) -> Nil {
  case ffi_unix.recv(socket) {
    Ok(bytes) -> {
      process.send(wire, satellite.WireBytes(data: bytes))
      read_loop(socket, wire, exits)
    }

    // End of stream. The node's own exit status says far more than "the
    // peer closed", so wait briefly for it before reporting.
    Error(reason) ->
      case process.receive(exits, exit_reason_wait_ms) {
        Ok(diagnosis) -> close_wire(wire, diagnosis)
        Error(Nil) -> close_wire(wire, reason)
      }
  }
}

fn close_wire(wire: Subject(satellite.WireIn), reason: String) -> Nil {
  process.send(wire, satellite.WireClosed(reason:))
}

// --- the node ------------------------------------------------------------

// Dispatches the jailed `erl` and collects its settlement off the host's
// timeline, reporting the outcome to the reader as a close reason.
fn spawn_node(
  config: LaunchConfig,
  spec: LaunchSpec,
  requirements: SandboxPolicy,
  exits: Subject(String),
  settlement: Subject(Settlement),
  now: Int,
) -> Nil {
  let call = node_call(config, spec, requirements)
  let deadline_ms = identity.pooled_budget(spec.identity).deadline_ms
  let waiting = int.max(deadline_ms - now, 0) + settle_margin_ms
  process.spawn_unlinked(fn() {
    run_node(config, call, exits, settlement, waiting)
  })
  Nil
}

fn run_node(
  config: LaunchConfig,
  call: CallSpec,
  exits: Subject(String),
  settlement: Subject(Settlement),
  waiting: Int,
) -> Nil {
  let events = process.new_subject()
  case
    broker.clear_call(config.broker, call, events:, waiting: clear_timeout_ms)
  {
    Error(refusal) -> report_refused(exits, settlement, refusal)
    Ok(handle) -> {
      process.send(settlement, Cleared(handle:))
      collect_node_result(exits, settlement, events, waiting)
    }
  }
}

fn report_refused(
  exits: Subject(String),
  settlement: Subject(Settlement),
  refusal: broker.Refusal,
) -> Nil {
  process.send(
    settlement,
    Settled(report: enforcement.Unreported("it was refused before it ran")),
  )
  process.send(
    exits,
    "the satellite node was refused before launch: " <> refusal_text(refusal),
  )
}

fn collect_node_result(
  exits: Subject(String),
  settlement: Subject(Settlement),
  events: Subject(broker.CallEvent),
  waiting: Int,
) -> Nil {
  case tool.collect_events(events, waiting:) {
    Ok(collected) -> {
      process.send(
        settlement,
        Settled(report: enforcement.of_call(collected.outcome)),
      )
      process.send(exits, exit_text(collected))
    }
    Error(Nil) -> {
      process.send(
        settlement,
        Settled(report: enforcement.Unreported(
          "it produced no settlement, so its helper never reported",
        )),
      )
      process.send(exits, "the satellite node produced no settlement")
    }
  }
}

/// The clearance that launches the node: the same `{op_id, step_id}` the
/// host services cap calls under, so `broker.abort` reaches it, and the
/// same approved grants `launch` already composed the effective policy
/// with.
///
/// Both come off the run phase's identity. Reading them from one place
/// is what keeps this call and the composition check below in agreement:
/// a node cleared under grants the pre-check did not apply would be
/// running in a jail nobody checked, and one cleared without grants the
/// pre-check did apply would be refused by the broker for a shortfall the
/// launch had already satisfied.
pub fn node_call(
  config: LaunchConfig,
  spec: LaunchSpec,
  requirements: SandboxPolicy,
) -> CallSpec {
  broker.CallSpec(
    op_id: identity.op_id(spec.identity),
    step_id: identity.step_id(spec.identity),
    base_policy: spec.base_policy,
    requirements:,
    grants: identity.grants(spec.identity),
    // The launch already composed and checked this policy; refusing a
    // narrowing here means the broker disagreed, and a satellite in a
    // weaker jail than the one that was checked must not run.
    response: broker.RefuseNarrowed,
    demand: config.demand,
    argv: node_argv(config.erl_path, spec.artifact),
    env: node_env(spec),
    cwd: spec.cwd,
    budget: identity.pooled_budget(spec.identity),
  )
}

/// The node's argv: distribution off, no epmd, no node name, booting the
/// artifact's generated entry.
///
/// `-s init stop` closes the node once the entry returns — `-run` alone
/// leaves a `-noshell` node idling until its deadline, and the whole point
/// is that the node dies with the program.
pub fn node_argv(erl_path: String, artifact: Artifact) -> List(String) {
  [
    erl_path,
    "-noshell",
    "-boot",
    "no_dot_erlang",
    "-pa",
    artifact.beam_dir,
    "-proto_dist",
    "none",
    "-start_epmd",
    "false",
    "-run",
    artifact.entry_module,
    "main",
    "-s",
    "init",
    "stop",
  ]
}

/// The node's environment: the two cap-channel handles the boot runtime
/// reads, plus whatever the execution's policy already permits.
///
/// Allowlist-constructed, never inherited, and the two handles are set
/// here — a caller's `env` cannot shadow them into pointing a satellite at
/// somebody else's socket or token.
pub fn node_env(spec: LaunchSpec) -> List(#(String, String)) {
  let permitted =
    list.filter(spec.env, fn(pair) { pair.0 != sock_env && pair.0 != token_env })
  [
    #(sock_env, spec.cap_socket_path),
    #(token_env, spec.token_path),
    ..permitted
  ]
}

/// What the jailed node requires of the session base: the socket, token,
/// and `.beam` directories readable, the network off, the two cap handles
/// in the environment allowlist, and a wall limit no longer than what is
/// left of the pooled deadline.
///
/// Nothing here widens the base — composition takes the meet — so a base
/// that cannot cover one of these produces a narrowing, which the launch
/// reports as an in-band refusal.
pub fn node_requirements(spec: LaunchSpec, now_ms: Int) -> SandboxPolicy {
  let wanted = [
    directory_of(spec.cap_socket_path),
    directory_of(spec.token_path),
    spec.artifact.beam_dir,
  ]
  let base = spec.base_policy
  policy.SandboxPolicy(
    ..base,
    readable_roots: list.unique(list.append(base.readable_roots, wanted)),
    network: policy.NetworkOff,
    limits: policy.Limits(
      ..base.limits,
      wall_s: bound_wall(base.limits.wall_s, remaining_seconds(spec, now_ms)),
    ),
    env_allow: list.map(node_env(spec), fn(pair) { pair.0 }),
  )
}

// Seconds left of the pooled wall deadline, rounded up and never zero —
// zero means "no limit" on the wire, which is the opposite of what an
// exhausted deadline should say.
fn remaining_seconds(spec: LaunchSpec, now_ms: Int) -> Int {
  let deadline_ms = identity.pooled_budget(spec.identity).deadline_ms
  int.max({ int.max(deadline_ms - now_ms, 0) + 999 } / 1000, 1)
}

// A base wall of zero is "no limit", so the deadline is the only bound;
// otherwise take the tighter of the two.
fn bound_wall(base_wall_s: Int, remaining_s: Int) -> Int {
  case base_wall_s {
    0 -> remaining_s
    other -> int.min(other, remaining_s)
  }
}

// --- policy checks -------------------------------------------------------

fn check_budget(pooled: Budget) -> Result(Nil, String) {
  case pooled.max_outstanding >= minimum_outstanding {
    True -> Ok(Nil)
    False ->
      Error(
        "the pooled budget allows "
        <> int.to_string(pooled.max_outstanding)
        <> " outstanding effects; the satellite node itself holds one, so a "
        <> "code-mode execution needs at least "
        <> int.to_string(minimum_outstanding),
      )
  }
}

// The effective policy the node will actually run under, or the reason
// the session base cannot host one.
//
// This is the launch policy composition — the site an approval has to
// reach for a widened re-run to mean anything. `base ⊕ requirements ⊕
// grants` is the broker's own rule; running it here first is a pre-check,
// so that a base which cannot host a node is refused in band with the
// exact shortfall named rather than dying somewhere inside a jail. The
// grants are therefore not decoration: without them the pre-check would
// refuse a launch the broker would then have cleared, and the approval
// would be spent on a call this function had already turned away.
//
// Grants only ever widen, so the reachability checks that run on the
// result of this stay sound: a path the unwidened policy covered is still
// covered, and one it did not may now be, which is the whole point.
fn composed_policy(
  base: SandboxPolicy,
  requirements: SandboxPolicy,
  grants: List(Grant),
) -> Result(SandboxPolicy, String) {
  let #(effective, narrowings) = policy.compose(base:, requirements:, grants:)
  case narrowings {
    [] -> Ok(effective)
    shortfalls ->
      Error(
        "the session base cannot host a satellite node: "
        <> string.join(list.map(shortfalls, narrowing_text), "; "),
      )
  }
}

/// Whether `path` is actually reachable inside a jail built from `policy`.
///
/// The three ways it is not, none of which the policy vocabulary can state
/// positively: the path is relative (the wire requires absolute paths);
/// it sits under a `protected` entry, which bwrap shadows; or it sits
/// under the scratch tmpfs mount, which hides whatever the host had there.
/// A path no root covers is reported too — under today's ro-bound host
/// root it would still be readable, but relying on that is exactly the
/// implicitness this check exists to remove.
pub fn path_reachable(
  effective: SandboxPolicy,
  path: String,
  what: String,
) -> Result(Nil, String) {
  use _ <- result.try(refuse_relative(path, what))
  use _ <- result.try(refuse_protected(effective, path, what))
  use _ <- result.try(refuse_scratch_shadow(effective, path, what))
  refuse_uncovered(effective, path, what)
}

// The wire requires absolute paths; a relative one would be resolved
// against the jail's cwd, which is not where the host put anything.
fn refuse_relative(path: String, what: String) -> Result(Nil, String) {
  case string.starts_with(path, "/") {
    True -> Ok(Nil)
    False -> Error(what <> " path " <> path <> " is not absolute")
  }
}

// bwrap shadows a protected path: an existing file with a read-only bind
// of itself, a directory or a missing path with an empty read-only tmpfs.
fn refuse_protected(
  effective: SandboxPolicy,
  path: String,
  what: String,
) -> Result(Nil, String) {
  case
    list.find(effective.protected, fn(root) { policy.covers(root:, path:) })
  {
    Error(Nil) -> Ok(Nil)
    Ok(root) ->
      Error(
        what
        <> " at "
        <> path
        <> " is under the protected path "
        <> root
        <> ", which the jail masks",
      )
  }
}

// A tmpfs scratch is mounted over `scratch_mount`, so whatever the host
// had under it is simply not in the jail's filesystem.
fn refuse_scratch_shadow(
  effective: SandboxPolicy,
  path: String,
  what: String,
) -> Result(Nil, String) {
  case
    effective.scratch == policy.ScratchTmpfs
    && policy.covers(root: scratch_mount, path:)
  {
    False -> Ok(Nil)
    True ->
      Error(
        what
        <> " at "
        <> path
        <> " is under "
        <> scratch_mount
        <> ", which the jail replaces with the scratch tmpfs",
      )
  }
}

// Under today's ro-bound host root an uncovered path would still be
// readable, but relying on that is exactly the implicitness these checks
// exist to remove.
fn refuse_uncovered(
  effective: SandboxPolicy,
  path: String,
  what: String,
) -> Result(Nil, String) {
  let directory = directory_of(path)
  let roots = list.append(effective.readable_roots, effective.writable_roots)
  case list.any(roots, fn(root) { policy.covers(root:, path: directory) }) {
    True -> Ok(Nil)
    False ->
      Error(
        what <> " at " <> path <> " is under no root the composed policy admits",
      )
  }
}

fn directory_of(path: String) -> String {
  filepath.directory_name(path)
}

// --- filesystem ----------------------------------------------------------

// The cap socket lives in its own mode-0700 directory, so nothing else on
// the host can even reach the socket to connect to it. Mirrors the token
// file's discipline in `satellite.private_token_writer`.
fn private_directory(directory: String) -> Result(Nil, String) {
  use _ <- result.try(
    simplifile.create_directory_all(directory)
    |> file_error("create the cap socket directory"),
  )
  simplifile.set_permissions_octal(for_file_at: directory, to: 0o700)
  |> file_error("lock down the cap socket directory")
}

fn unlink(path: String) -> Nil {
  let _ = simplifile.delete(path)
  Nil
}

fn file_error(
  outcome: Result(a, simplifile.FileError),
  what: String,
) -> Result(a, String) {
  result.map_error(outcome, fn(error) {
    "could not " <> what <> ": " <> simplifile.describe_error(error)
  })
}

// --- diagnostics ---------------------------------------------------------

// How the node ended, as the close reason the host reports when no
// terminal `outcome` frame arrived first.
fn exit_text(collected: Collected) -> String {
  case collected.outcome {
    broker.CallExited(result:) ->
      case result.timed_out {
        True -> "the satellite node hit its wall limit and was killed"
        False ->
          "the satellite node exited with code "
          <> int.to_string(result.code)
          <> stderr_tail(collected)
      }
    broker.CallFailed(failure:) ->
      "the satellite node failed: " <> tool.exec_failure_text(failure)
  }
}

// A node that died on a boot error says why on stderr; carrying a little
// of it turns "the satellite is gone" into something actionable.
fn stderr_tail(collected: Collected) -> String {
  case bit_array_text(collected.stderr) {
    "" -> ""
    text -> ": " <> string.slice(string.trim(text), at_index: 0, length: 400)
  }
}

// The socket path's UTF-8 length in bytes — what the kernel's sun_path
// limit actually counts, not the character count.
fn socket_path_bytes(path: String) -> Int {
  bit_array.byte_size(<<path:utf8>>)
}

fn bit_array_text(bytes: BitArray) -> String {
  case bit_array.to_string(bytes) {
    Ok(text) -> text
    Error(Nil) -> ""
  }
}

fn refusal_text(refusal: broker.Refusal) -> String {
  case refusal {
    broker.PolicyRefused(denial:) -> "policy refused: " <> denial.reason
    broker.InvalidPolicy(error: _) -> "the composed policy is invalid"
    broker.BudgetRefused(refusal: _) -> "the pooled budget refused it"
    broker.MintRefused(error: _) -> "the broker could not mint a token"
    broker.NoHelper(error: _) -> "no sandbox helper was available"
    broker.OperationAborted -> "the operation was aborted"
    broker.BrokerUnavailable -> "the tool broker is unavailable"
  }
}

fn narrowing_text(narrowing: Narrowing) -> String {
  case narrowing {
    policy.NarrowedWritableRoot(path:) -> "writable root " <> path
    policy.NarrowedReadableRoot(path:) -> "readable root " <> path
    policy.NarrowedNetwork(wanted: _, granted: _) -> "network policy"
    policy.NarrowedEnv(name:) -> "environment variable " <> name
    policy.NarrowedLimit(field: _, wanted:, granted:) ->
      "limit "
      <> int.to_string(wanted)
      <> " (granted "
      <> int.to_string(granted)
      <> ")"
    policy.NarrowedScratch(wanted: _) -> "scratch area"
  }
}
