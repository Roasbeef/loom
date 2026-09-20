//// Stock OTP observations for the bounded real-daemon lifecycle soak and the
//// session-assembly heap census.
//// These values describe the shared test VM, not an isolated shipped daemon.
//// No production metrics API or native process machinery is introduced here.
//// Every external below is a standard OTP function that `gleam_stdlib`,
//// `gleam_erlang`, `gleam_otp` and weft expose no binding for; the ones they
//// do expose are used instead, which is why the heap census reaches
//// suspension through `gleam/otp/system` rather than through a fourteenth
//// external here.

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

/// Every live process in the VM, so that a census can difference two
/// snapshots and keep only what the thing it is measuring added.
///
/// ## Examples
///
/// `processes()` grows by one for every process a session assembly starts.
@external(erlang, "erlang", "processes")
pub fn processes() -> List(Pid)

/// Forces a full sweep of one process, which is what separates its live
/// state from heap a minor collection has not looked at.
///
/// `erlang:garbage_collect/1` is already a major collection, so no option
/// list is needed. It answers `False` for a process that has already died,
/// which is why a census may call it without checking liveness first.
///
/// ## Examples
///
/// `garbage_collect(owner)` returns `True` once the sweep has run.
@external(erlang, "erlang", "garbage_collect")
pub fn garbage_collect(pid: Pid) -> Bool

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
