//// Tests for `session.open_memory_owned`: the owner's capability stops the
//// memory storage actor with an orderly exit, and the sealed handle keeps
//// answering with error values afterwards.
////
//// The test process traps exits. The storage actor is linked to whoever
//// opened it, so an orderly stop arrives as a `Normal` exit message naming
//// the actor, which both identifies the actor and proves how it ended. A
//// logger probe counts error-level events, and a control crash shows the
//// probe would have seen a crash report.

import core/clock
import core/register
import gleam/erlang/process
import gleam/option.{None}
import session/session
import storage/storage

@external(erlang, "session_test_ffi", "install_probe")
fn install_probe(id: String) -> Nil

@external(erlang, "session_test_ffi", "remove_probe")
fn remove_probe(id: String) -> Nil

@external(erlang, "session_test_ffi", "captured_errors")
fn captured_errors() -> Int

@external(erlang, "session_test_ffi", "crash_proc_lib")
fn crash_proc_lib() -> Nil

/// Waits for the storage actor's exit message, returning its reason.
fn await_exit() -> Result(process.ExitReason, Nil) {
  process.new_selector()
  |> process.select_trapped_exits(fn(exit) { exit.reason })
  |> process.selector_receive(2000)
}

/// Discards exit messages left by earlier tests that shared this process.
fn drain_exits() -> Nil {
  case await_exit_within(0) {
    Ok(_) -> drain_exits()
    Error(Nil) -> Nil
  }
}

fn await_exit_within(ms: Int) -> Result(process.ExitReason, Nil) {
  process.new_selector()
  |> process.select_trapped_exits(fn(exit) { exit.reason })
  |> process.selector_receive(ms)
}

fn open_owned() -> #(session.Session, fn() -> Result(Nil, storage.StorageError)) {
  process.trap_exits(True)
  drain_exits()
  let assert Ok(opened) = session.open_memory_owned(clock.fixed(at: 1000))
    as "the memory session opens"
  opened
}

pub fn retire_stops_the_actor_with_a_normal_exit_test() {
  let #(_sess, retire) = open_owned()
  assert retire() == Ok(Nil)
  assert await_exit() == Ok(process.Normal)
}

pub fn retire_logs_no_crash_report_test() {
  let id = "session_memory_owned_probe_quiet"
  install_probe(id)
  let #(_sess, retire) = open_owned()
  assert retire() == Ok(Nil)
  assert await_exit() == Ok(process.Normal)
  let seen = captured_errors()
  remove_probe(id)
  assert seen == 0
}

pub fn the_probe_sees_a_real_crash_report_test() {
  let id = "session_memory_owned_probe_control"
  install_probe(id)
  crash_proc_lib()
  let seen = captured_errors()
  remove_probe(id)
  assert seen > 0
}

pub fn calls_after_retire_return_error_values_test() {
  let #(sess, retire) = open_owned()
  assert retire() == Ok(Nil)
  assert await_exit() == Ok(process.Normal)
  assert storage.get_register(sess.store, register.FactCustom, "k")
    == Error(storage.HandleClosed)
  assert storage.stats(sess.store) == Error(storage.HandleClosed)
  assert storage.scan_usage(
      sess.store,
      storage.UsageScan(None, None, storage.OldestFirst, None),
    )
    == Error(storage.HandleClosed)
}

pub fn close_after_retire_stays_idempotent_test() {
  let #(sess, retire) = open_owned()
  assert retire() == Ok(Nil)
  assert await_exit() == Ok(process.Normal)
  assert session.close(sess) == Ok(Nil)
}

pub fn retire_is_idempotent_test() {
  let #(_sess, retire) = open_owned()
  assert retire() == Ok(Nil)
  assert retire() == Ok(Nil)
  assert await_exit() == Ok(process.Normal)
}

pub fn the_session_works_until_retired_test() {
  let #(sess, retire) = open_owned()
  assert storage.stats(sess.store) == Ok(storage.empty_stats())
  assert retire() == Ok(Nil)
}

pub fn open_memory_keeps_the_actor_alive_after_close_test() {
  process.trap_exits(True)
  drain_exits()
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  assert session.close(sess) == Ok(Nil)
  assert await_exit_within(200) == Error(Nil)
  assert storage.stats(sess.store) == Error(storage.HandleClosed)
}
