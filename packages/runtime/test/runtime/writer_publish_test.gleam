//// Coverage for `writer.publish`'s fix (issue #43): resolve a
//// subscriber's name to a pid exactly once, never twice.
////
//// `publish` is a private function, so nothing outside `runtime/writer`
//// can call it directly — and the hazard it used to carry is a genuine
//// data race (a name unregistering in the gap between two resolutions),
//// which no amount of scheduling from a test can reliably land on. So
//// this file proves the mechanism two ways instead:
////
//// 1. `old_shape_publish` and `new_shape_publish` below are the two
////    resolution shapes `publish` had before and after the fix, copied
////    verbatim against the real `gleam/erlang/process` primitives (and
////    the real `ffi_sup.send_to_pid`) the production code uses — with
////    one addition no running function can offer from outside: a hook
////    that runs at the exact instant between resolution and send, so
////    "the name unregisters in that gap" is deterministic instead of a
////    coin toss. The old shape crashes there; the new shape, which has
////    only one resolution to land the hook after, does not.
//// 2. The integration tests below drive the real `writer` actor and its
////    real `publish` through a named subscriber, proving the rewrite
////    still delivers events correctly and still survives an
////    already-unregistered name — the boundary case both shapes always
////    handled.

import core/clock
import core/json
import core/register
import core/tx.{type Tx, SetRegister, Tx}
import gleam/erlang/process.{
  type Down, type ExitReason, type Name, type Subject, Abnormal, ProcessDown,
}
import runtime/internal/ffi_sup
import runtime/writer
import session/session
import weft/registry as address

// --- the two resolution shapes, reproduced -------------------------------

// `publish`'s shape before the fix: resolve the name to check aliveness,
// then let `process.send` resolve it again internally. `between` runs
// exactly at the gap the issue describes.
fn old_shape_publish(
  subscriber: Subject(String),
  between: fn() -> Nil,
  event: String,
) -> Nil {
  case process.subject_owner(subscriber) {
    Ok(pid) ->
      case process.is_alive(pid) {
        True -> {
          between()
          process.send(subscriber, event)
        }
        False -> Nil
      }
    Error(Nil) -> Nil
  }
}

// `publish`'s shape after the fix: resolve the name once, to a pid, and
// send straight to that pid. `between` runs at the same logical point —
// after the (one and only) resolution, before the send — to prove it is
// harmless there rather than merely unexercised.
fn new_shape_publish(
  subscriber: Subject(String),
  between: fn() -> Nil,
  event: String,
) -> Nil {
  case process.subject_name(subscriber) {
    Error(Nil) -> process.send(subscriber, event)
    Ok(name) ->
      case process.named(name) {
        Ok(pid) -> {
          between()
          ffi_sup.send_to_pid(pid, #(name, event))
        }
        Error(Nil) -> Nil
      }
  }
}

// Runs `body` on a disposable, monitored process and reports whether it
// crashed. The monitor is placed *before* the process can possibly reach
// the crash, because `spawn_unlinked` only returns after the process
// exists.
fn run_isolated(body: fn() -> Nil) -> Result(Nil, ExitReason) {
  let done = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      body()
      process.send(done, Nil)
    })
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(process.monitor(pid), fn(down) {
      Died(down)
    })
    |> process.select_map(done, fn(_nil) { Finished })
  case process.selector_receive(from: selector, within: 2000) {
    Ok(Finished) -> Ok(Nil)
    Ok(Died(ProcessDown(reason:, ..))) -> Error(reason)
    // A monitor placed on a process only ever reports `ProcessDown`.
    Ok(Died(process.PortDown(..))) ->
      panic as "a process monitor cannot report a PortDown"
    Error(Nil) -> panic as "isolated process neither finished nor died"
  }
}

type Signal {
  Finished
  Died(Down)
}

fn fresh_named_subject(prefix: String) -> #(Name(m), Subject(m)) {
  let name = process.new_name(prefix:)
  #(name, process.named_subject(name))
}

pub fn old_shape_crashes_when_the_name_unregisters_between_the_two_resolutions_test() {
  let #(name, subject) = fresh_named_subject("writer-publish-old-shape")
  let assert Ok(Nil) = process.register(process.self(), name)
    as "self-registration under a fresh name must succeed"

  let outcome =
    run_isolated(fn() {
      old_shape_publish(
        subject,
        fn() {
          let _ = process.unregister(name)
          Nil
        },
        "hint nobody needed",
      )
    })

  let _ = process.unregister(name)
  case outcome {
    Error(Abnormal(..)) -> Nil
    Error(other) ->
      panic as {
        "expected the old shape to crash abnormally on the re-resolution, got "
        <> string_of(other)
      }
    Ok(Nil) ->
      panic as "the old shape survived a name unregistering between its two resolutions — the reproduction is not exercising the race it claims to"
  }
}

pub fn new_shape_survives_and_still_delivers_when_the_name_unregisters_after_its_one_resolution_test() {
  let #(name, subject) = fresh_named_subject("writer-publish-new-shape")
  let assert Ok(Nil) = process.register(process.self(), name)
    as "self-registration under a fresh name must succeed"

  let outcome =
    run_isolated(fn() {
      new_shape_publish(
        subject,
        fn() {
          let _ = process.unregister(name)
          Nil
        },
        "hint",
      )
    })

  let assert Ok(Nil) = outcome
    as "the new shape must survive a name unregistering after its one resolution"
  // The event was still sent straight to the pid this process resolved
  // to, so it must have arrived even though the name is now gone.
  let assert Ok("hint") = process.receive(subject, within: 1000)
    as "the event must still have been delivered to the already-resolved pid"
}

fn string_of(reason: ExitReason) -> String {
  case reason {
    process.Normal -> "Normal"
    process.Killed -> "Killed"
    process.Abnormal(..) -> "Abnormal"
  }
}

// --- the real writer, through a named subscriber -------------------------

fn open_writer() -> #(address.Address(writer.Message), address.Registry) {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 2000))
    as "the memory session must open"
  let assert Ok(namespace) = address.start() as "the namespace must start"
  let name = address.new_address(namespace)
  let assert Ok(_started) =
    writer.start(
      writer.Options(
        session: sess,
        after_commit: fn(_) { Nil },
        subscribers: [],
      ),
      name,
    )
    as "the writer must start"
  #(name, namespace)
}

fn note_tx(text: String) -> Tx {
  Tx(
    writes: [
      SetRegister(
        ns: register.FactCustom,
        key: "note",
        value: register.value(json.String(text)),
      ),
    ],
    expected: [],
  )
}

pub fn writer_delivers_a_committed_event_to_a_named_subscriber_test() {
  let #(w, namespace) = open_writer()
  let #(name, subscriber) =
    fresh_named_subject("writer-publish-live-subscriber")
  let assert Ok(Nil) = process.register(process.self(), name)
    as "self-registration under a fresh name must succeed"
  writer.subscribe(w, subscriber)

  let assert Ok(_) = writer.commit(w, note_tx("hello"))
    as "the commit must apply"
  let assert Ok(writer.Committed(ordinal: 1, ..)) =
    process.receive(subscriber, within: 1000)
    as "the named subscriber must receive the committed event"

  let _ = process.unregister(name)
  assert address.stop(namespace) == Ok(Nil)
}

pub fn writer_survives_a_subscriber_whose_name_is_already_unregistered_test() {
  let #(w, namespace) = open_writer()
  // A subject built from a name nobody ever registered — the boundary
  // both the old and the new shape already handled without a race.
  let #(_name, ghost) = fresh_named_subject("writer-publish-ghost")
  writer.subscribe(w, ghost)

  let assert Ok(_) = writer.commit(w, note_tx("first"))
    as "the commit must apply despite an unreachable subscriber"

  // The writer itself must still be alive and serving: a second commit
  // through the same subject proves the ghost subscriber never crashed
  // the actor that is supposed to survive it.
  let assert Ok(_) = writer.commit(w, note_tx("second"))
    as "the writer must still be responsive after publishing to a ghost subscriber"
  assert address.stop(namespace) == Ok(Nil)
}
