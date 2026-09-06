//// Stock OTP observations for the bounded real-daemon lifecycle soak.
//// These values describe the shared test VM, not an isolated shipped daemon.
//// No production metrics API or native process machinery is introduced here.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}

/// Reads an existing OTP VM counter without allocating a new process.
///
/// ## Examples
///
/// `system_info(atom.create("atom_count"))` observes the current atom table.
@external(erlang, "erlang", "system_info")
pub fn system_info(item: Atom) -> Dynamic

/// Reads one original process's current mailbox counter.
///
/// ## Examples
///
/// `process_info(owner, atom.create("message_queue_len"))` observes its queue.
@external(erlang, "erlang", "process_info")
pub fn process_info(pid: Pid, item: Atom) -> Dynamic

/// Reads the VM's current allocated-memory accounting, distinct from OS RSS.
///
/// ## Examples
///
/// `memory(atom.create("total"))` reports allocated bytes across the test VM.
@external(erlang, "erlang", "memory")
pub fn memory(item: Atom) -> Int
