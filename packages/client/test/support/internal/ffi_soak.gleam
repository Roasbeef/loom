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

/// Lists every module the VM has loaded so far, one pair per module.
///
/// The atom-leak detector reads only the length. A module's first load
/// interns its name, its function names and every atom literal in its
/// code, so a growth in this list is the one benign reason the atom
/// table may grow between two samples of an otherwise warmed VM.
///
/// ## Examples
///
/// `all_loaded()` grows by one after the first call into a lazily loaded
/// module.
@external(erlang, "code", "all_loaded")
pub fn all_loaded() -> Dynamic
