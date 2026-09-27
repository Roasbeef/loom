//// The root of the server's process tree: the one process everything
//// long-lived is linked to, and the policy for what a death there means.
////
//// ## Why a host process exists at all
////
//// `boot` starts a stack — helper pool, broker, summary sink, session
//// handle, runtime tree, hub, listener — and almost every piece of it is
//// an actor started with a plain linked `actor.start`. The links attach
//// to whichever process ran the boot. That used to be the process that
//// then blocked waiting for `SIGTERM`, and it did not trap exits, so any
//// one of those deaths killed it, and the Gleam-generated runner above
//// it turned that into `init:stop(1)`. The shutdown path never ran: the
//// session's writer lease was left to expire on its sixty-second TTL, so
//// crashing the server locked the session out for a minute.
////
//// `adopt` moves the boot onto a dedicated process that **does** trap
//// exits. Every link the boot forms lands there, so a child's death
//// arrives as a message rather than as a signal, and the host answers it
//// by running the orderly teardown *first* — releasing the lease — and
//// reporting afterwards. The entry point learns what happened from a
//// `Stop` on a subject and decides its own exit status; nothing halts the
//// node as a side effect of a link.
////
//// ## Fatal and restartable are different questions
////
//// This module implements only the fatal half: a death here ends the
//// server, in order. Children that should be *restarted* instead belong
//// under a supervisor of their own, whose pid the host watches — the
//// supervisor absorbs the individual crashes and only its own death,
//// once its restart budget is spent, reaches here. `client/serve` builds
//// exactly that: a service supervisor over the pieces that can be
//// replaced in place, and everything else linked to the host.
////
//// ## The host is the only process that tears down
////
//// A caller that wants the stack gone asks the host with `retire` and
//// waits for the host to exit; it never runs the teardown itself. The
//// teardown therefore runs exactly once, on this process, whether a
//// fault or a request started it.
////
//// Two teardowns used to run instead. A caller's own teardown stopped
//// the listener first, the host read that death as a fault, and both
//// then closed the runtime at once. Only one of them can hold the drain
//// witness that authorizes releasing the writer lease, and the other
//// returned as soon as it found the witness gone. When the caller was
//// the one that lost, its shutdown returned while the host was still on
//// its way to the release, and a reopen straight afterwards was refused
//// with the old incarnation's lease. Idempotent steps did not make the
//// two teardowns safe; a caller must return only after the one teardown
//// that releases the lease has finished, and waiting on the host's exit
//// is what gives it that.
////
//// ## What the host cannot cover
////
//// Two things. A process that unlinks itself is invisible to the trap,
//// which is why `adopt` also takes a list of pids to *monitor* — the
//// session tree and the `mist` listener both unlink from their starter
//// by design. And the storage actor's own death is unrecoverable rather
//// than merely fatal: it is the connection that would delete the lease
//// row, so when it goes the lease can only expire. Everything else
//// releases it.

import gleam/erlang/process.{
  type Pid, type Subject, Abnormal, ExitMessage, Killed, Normal, PortDown,
  ProcessDown,
}
import gleam/list
import gleam/string

/// Why the server is stopping.
pub type Stop {
  /// `SIGTERM` arrived. Nothing has been torn down yet — the entry point
  /// runs the shutdown itself and exits zero.
  Signalled

  /// A fatal child died. The teardown has **already run**, so the writer
  /// lease is released and the listener is closed; `child` names the
  /// process as well as the host could and `reason` is its exit reason,
  /// both for the log line before a nonzero exit.
  Faulted(child: String, reason: String)
}

/// The process that owns one boot's teardown, and the one door a caller
/// uses to ask for it.
///
/// Constructor invariants: `pid` is the host process `adopt` spawned, and
/// `retirement` is a subject that process created and selects on.
pub opaque type Host {
  Host(pid: Pid, retirement: Subject(Nil))
}

/// Runs `boot` on a dedicated exit-trapping host process and hands its
/// result back, so that everything `boot` links to is linked to the host
/// rather than to the caller.
///
/// After a successful boot the host stays alive watching the stack until
/// one of two things ends it, and then runs `teardown` once and exits.
/// The first fatal death — a trapped exit from anything the boot linked,
/// or a `Down` from one of the pids `fatal` names — also sends `Faulted`
/// on the `Stop` subject `boot` was given. A `retire` request sends
/// nothing, because its caller is waiting on the host's exit rather than
/// on that subject. A linked process exiting `Normal` is not a fault and
/// is ignored.
///
/// `boot` receives the `Host` it runs on so that it can keep the handle
/// beside what it builds; `retire` needs it later. The `Stop` subject is
/// created here and owned by the *caller*, so the caller is the process
/// that must receive on it. A boot that fails, or that dies with its
/// host, comes back as `Error` with the reason already worded.
///
/// ## Examples
///
/// ```gleam
/// // host.adopt(
/// //   boot: fn(stops, host) { assemble(settings, stops, host) },
/// //   fatal: fn(booted) { [#("the session tree", booted.tree)] },
/// //   teardown: tear_down,
/// // )
/// ```
///
pub fn adopt(
  boot boot: fn(Subject(Stop), Host) -> Result(booted, String),
  fatal fatal: fn(booted) -> List(#(String, Pid)),
  teardown teardown: fn(booted) -> Nil,
) -> Result(booted, String) {
  let replies = process.new_subject()
  let stops = process.new_subject()
  let host =
    process.spawn_unlinked(fn() {
      process.trap_exits(True)

      // The request subject must belong to this process, which is the
      // only one that ever selects on it.
      let retirement = process.new_subject()
      case boot(stops, Host(pid: process.self(), retirement:)) {
        Error(reason) -> process.send(replies, Error(reason))
        Ok(booted) -> {
          process.send(replies, Ok(booted))
          watch(fatal(booted), retirement, teardown, booted, stops)
        }
      }
    })

  // The host is the only thing that can answer, so its death before it
  // answers is the answer: a boot step crashed rather than returning.
  let monitor = process.monitor(host)
  let selector =
    process.new_selector()
    |> process.select(replies)
    |> process.select_specific_monitor(monitor, fn(_down) {
      Error("the server host died during boot")
    })
  let outcome = process.selector_receive_forever(from: selector)
  process.demonitor_process(monitor)
  outcome
}

/// Asks the host to tear the stack down and returns once it has.
///
/// The host runs the teardown itself and exits when it finishes, so the
/// host's `Down` is the completion signal: after `retire` returns, the
/// writer lease has been released, or retained on purpose because its
/// drain could not be proved. A host that a fault already ended answers
/// at once, since its teardown ran before it exited. The wait is not
/// bounded, because the teardown's own drain is not.
///
/// Callable from any process except the host itself, and any number of
/// times: every caller waits on the same exit, and the teardown still
/// runs once.
///
/// ## Examples
///
/// ```gleam
/// // host.retire(booted.host)
/// ```
///
pub fn retire(host: Host) -> Nil {
  // Monitor before asking, so a host that exits between the two steps is
  // still observed rather than waited on forever.
  let watch = process.monitor(host.pid)
  process.send(host.retirement, Nil)
  let _down =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive_forever()
  Nil
}

/// The host process itself, for a test that must observe it.
///
/// ## Examples
///
/// ```gleam
/// // process.is_alive(host.pid(booted.host))
/// ```
///
@internal
pub fn pid(host: Host) -> Pid {
  host.pid
}

/// Relays `SIGTERM` into a `Stop` subject from a process of its own, so
/// the entry point can wait on one subject for both a signal and a
/// fault.
///
/// The signal handler is installed by the relay process, not by the
/// caller — installing it replaces the default handler for the whole VM,
/// whose response to `SIGTERM` is an immediate `init:stop()`, so this is
/// deliberately something an entry point does and a test does not.
///
/// ## Examples
///
/// ```gleam
/// // host.relay_sigterm(to: booted.stops, through: ffi_os.wait_for_sigterm)
/// ```
///
pub fn relay_sigterm(
  to stops: Subject(Stop),
  through wait: fn() -> Nil,
) -> Nil {
  let _relay =
    process.spawn_unlinked(fn() {
      wait()
      process.send(stops, Signalled)
    })
  Nil
}

// What ends the watch: a death the host observed, or a caller's request.
type Event {
  Died(child: String, reason: process.ExitReason)
  Retire
}

// Waits for the first fatal death or a retirement request, and tears the
// stack down. Monitors go on the pids that unlinked themselves from their
// starter; everything else the boot linked arrives through the exit trap.
fn watch(
  watched: List(#(String, Pid)),
  retirement: Subject(Nil),
  teardown: fn(booted) -> Nil,
  booted: booted,
  stops: Subject(Stop),
) -> Nil {
  let by_pid = list.map(watched, fn(entry) { #(entry.1, entry.0) })
  let selector =
    list.fold(watched, process.new_selector(), fn(selector, entry) {
      process.select_specific_monitor(
        selector,
        process.monitor(entry.1),
        fn(down) {
          case down {
            ProcessDown(pid:, reason:, ..) -> Died(named(by_pid, pid), reason)
            PortDown(reason:, ..) -> Died("a port the server held", reason)
          }
        },
      )
    })
    |> process.select_trapped_exits(fn(exit) {
      let ExitMessage(pid:, reason:) = exit
      Died(named(by_pid, pid), reason)
    })
    |> process.select_map(retirement, fn(_request) { Retire })
  await_end(selector, teardown, booted, stops)
}

fn await_end(
  selector: process.Selector(Event),
  teardown: fn(booted) -> Nil,
  booted: booted,
  stops: Subject(Stop),
) -> Nil {
  case process.selector_receive_forever(from: selector) {
    // A linked process that finished its work is not a fault. Boot
    // spawns short-lived helpers, and one of them retiring must not read
    // as the server falling over.
    Died(reason: Normal, ..) -> await_end(selector, teardown, booted, stops)

    // A caller asked. The deaths the teardown itself causes are never
    // read: the host returns afterwards, and its exit is what the caller
    // in `retire` is waiting on.
    Retire -> teardown(booted)

    Died(child:, reason:) -> {
      teardown(booted)
      process.send(stops, Faulted(child:, reason: describe(reason)))
    }
  }
}

fn named(by_pid: List(#(Pid, String)), pid: Pid) -> String {
  case list.key_find(by_pid, pid) {
    Ok(label) -> label
    Error(Nil) -> "a linked service (" <> string.inspect(pid) <> ")"
  }
}

fn describe(reason: process.ExitReason) -> String {
  case reason {
    Normal -> "normal"
    Killed -> "killed"
    Abnormal(reason:) -> string.inspect(reason)
  }
}
