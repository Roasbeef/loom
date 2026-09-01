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
//// ## A shutdown the caller runs looks like a fault from here
////
//// Nothing distinguishes "a child died" from "somebody stopped the
//// server", so a `SIGTERM` shutdown — or a test taking its own server
//// apart — makes the host tear down a second time and report a
//// `Faulted` nobody reads. Both are harmless: the teardown is
//// idempotent by construction (every stop is a send or is guarded on
//// liveness), and in production the entry point has already finished by
//// the time the second one runs. Buying the distinction would mean a
//// channel into the host, which is more surface than the wart is worth.
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

/// Runs `boot` on a dedicated exit-trapping host process and hands its
/// result back, so that everything `boot` links to is linked to the host
/// rather than to the caller.
///
/// After a successful boot the host stays alive watching the stack. The
/// first fatal death — a trapped exit from anything the boot linked, or
/// a `Down` from one of the pids `fatal` names — runs `teardown` and then
/// sends `Faulted` on the `Stop` subject `boot` was given. A linked
/// process exiting `Normal` is not a fault and is ignored.
///
/// The `Stop` subject is created here and owned by the *caller*, so the
/// caller is the process that must receive on it. A boot that fails, or
/// that dies with its host, comes back as `Error` with the reason
/// already worded.
///
/// ## Examples
///
/// ```gleam
/// // host.adopt(
/// //   boot: fn(stops) { assemble(settings, stops) },
/// //   fatal: fn(booted) { [#("the session tree", booted.tree)] },
/// //   teardown: shutdown,
/// // )
/// ```
///
pub fn adopt(
  boot boot: fn(Subject(Stop)) -> Result(booted, String),
  fatal fatal: fn(booted) -> List(#(String, Pid)),
  teardown teardown: fn(booted) -> Nil,
) -> Result(booted, String) {
  let replies = process.new_subject()
  let stops = process.new_subject()
  let host =
    process.spawn_unlinked(fn() {
      process.trap_exits(True)
      case boot(stops) {
        Error(reason) -> process.send(replies, Error(reason))
        Ok(booted) -> {
          process.send(replies, Ok(booted))
          watch(fatal(booted), teardown, booted, stops)
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

// Waits for the first fatal death, tears the stack down, and reports.
// Monitors go on the pids that unlinked themselves from their starter;
// everything else the boot linked arrives through the exit trap.
fn watch(
  watched: List(#(String, Pid)),
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
            ProcessDown(pid:, reason:, ..) -> #(named(by_pid, pid), reason)
            PortDown(reason:, ..) -> #("a port the server held", reason)
          }
        },
      )
    })
    |> process.select_trapped_exits(fn(exit) {
      let ExitMessage(pid:, reason:) = exit
      #(named(by_pid, pid), reason)
    })
  await_fault(selector, teardown, booted, stops)
}

fn await_fault(
  selector: process.Selector(#(String, process.ExitReason)),
  teardown: fn(booted) -> Nil,
  booted: booted,
  stops: Subject(Stop),
) -> Nil {
  let #(child, reason) = process.selector_receive_forever(from: selector)
  case reason {
    // A linked process that finished its work is not a fault. Boot
    // spawns short-lived helpers, and one of them retiring must not read
    // as the server falling over.
    Normal -> await_fault(selector, teardown, booted, stops)
    _ -> {
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
