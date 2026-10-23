//// What the exec benchmark can observe about the machine it runs on.
////
//// `bench_exec_test` measures the helper pool from the outside: how long a
//// spawn takes, how much memory an idle jail holds, which OS processes a
//// cancelled execution left behind. None of that is visible to Gleam, and
//// none of it may be added to `src`, so every observation lives here and is
//// backed by `test/bench_exec_ffi.erl`. Each is a read of native process
//// metadata, a clock, or one `kill(1)`; none changes what the pool does.
////
//// Linux observations read `/proc`; Darwin observations read native `/bin/ps`
//// with a bounded deadline and output. An observation failure raises rather
//// than becoming an empty census that falsely proves death. Metadata alone
//// never attests jailed descendant retirement: the broker's retained native
//// status and original owner still decide that verdict. `port_os_pids`,
//// `suspend` and `resume` use OTP's `erlang` and `sys` modules directly.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/port.{type Port}
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/result

/// The value of an environment variable, or `Error(Nil)` when it is unset.
///
/// ## Examples
///
/// ```gleam
/// // bench_host.getenv("LOOM_BENCH_OUT")
/// ```
@external(erlang, "bench_exec_ffi", "getenv")
pub fn getenv(name: String) -> Result(String, Nil)

/// Microseconds on the monotonic clock. Only differences are meaningful.
///
/// ## Examples
///
/// ```gleam
/// // let started = bench_host.now_us()
/// ```
@external(erlang, "bench_exec_ffi", "now_us")
pub fn now_us() -> Int

/// Nanoseconds on the wall clock, the clock `date +%s%N` reads, so a
/// payload's timestamps and the test's can be compared.
///
/// ## Examples
///
/// ```gleam
/// // let witnessed = bench_host.system_time_ns()
/// ```
@external(erlang, "bench_exec_ffi", "system_time_ns")
pub fn system_time_ns() -> Int

/// Closes the port this node holds to the process with this OS pid, from
/// outside the port's owner: the owner's next write fails and no exit status
/// ever arrives. `Error(Nil)` when no such port is held.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = bench_host.close_port_of(helper_pid)
/// ```
@external(erlang, "bench_exec_ffi", "close_port_of")
pub fn close_port_of(os_pid: Int) -> Result(Nil, Nil)

/// A positive integer no earlier call returned, for naming steps.
///
/// ## Examples
///
/// ```gleam
/// // "step-" <> int.to_string(bench_host.unique())
/// ```
@external(erlang, "bench_exec_ffi", "unique")
pub fn unique() -> Int

/// Open ports, live processes and allocated bytes, read together, so a
/// before/after pair describes two instants rather than six.
///
/// ## Examples
///
/// ```gleam
/// // let #(ports, processes, bytes) = bench_host.vm_counts()
/// ```
@external(erlang, "bench_exec_ffi", "vm_counts")
pub fn vm_counts() -> #(Int, Int, Int)

/// Allocated bytes after every process has been collected, so a difference
/// of two readings is retained memory rather than garbage awaiting its turn.
///
/// ## Examples
///
/// ```gleam
/// // let before = bench_host.vm_settled_memory()
/// ```
@external(erlang, "bench_exec_ffi", "vm_settled_memory")
pub fn vm_settled_memory() -> Int

/// OS pids of every `loom-exec` this node holds a port to.
///
/// ## Examples
///
/// ```gleam
/// // let mine = bench_host.helper_os_pids()
/// ```
@external(erlang, "bench_exec_ffi", "helper_os_pids")
pub fn helper_os_pids() -> List(Int)

/// The one helper, outside `exclude`, that has a child process, which is the
/// helper running an execution. `Error(Nil)` when none or several qualify.
///
/// ## Examples
///
/// ```gleam
/// // bench_host.busy_helper_os_pid(exclude: bench_host.helper_os_pids())
/// ```
@external(erlang, "bench_exec_ffi", "busy_helper_os_pid")
pub fn busy_helper_os_pid(exclude exclude: List(Int)) -> Result(Int, Nil)

/// A process and all its descendants as `#(os_pid, comm, vm_rss_kb)`.
///
/// ## Examples
///
/// ```gleam
/// // bench_host.proc_tree(helper_pid)
/// ```
@external(erlang, "bench_exec_ffi", "proc_tree")
pub fn proc_tree(root: Int) -> List(#(Int, String, Int))

/// Sends a named signal (`"STOP"`, `"CONT"`, `"KILL"`) to an OS pid, outside
/// the BEAM's port machinery, the way a wedged host would.
///
/// ## Examples
///
/// ```gleam
/// // bench_host.signal(helper_pid, "STOP")
/// ```
@external(erlang, "bench_exec_ffi", "signal")
pub fn signal(pid: Int, name: String) -> Nil

/// Every process whose command line contains one of `markers`, as
/// `#(os_pid, comm, cmdline)`.
///
/// ## Examples
///
/// ```gleam
/// // bench_host.census(["loom-exec", "bwrap"])
/// ```
@external(erlang, "bench_exec_ffi", "census")
pub fn census(markers: List(String)) -> List(#(Int, String, String))

@external(erlang, "erlang", "ports")
fn all_ports() -> List(Port)

@external(erlang, "erlang", "port_info")
fn port_info(port: Port, item: atom.Atom) -> Dynamic

/// The OS pids of every port this node holds that is backed by an OS
/// process. Unlike `helper_os_pids` it reads no `/proc`, so a test can take
/// the pid of the helper it just spawned by differencing two readings on a
/// host that has none.
///
/// ## Examples
///
/// ```gleam
/// // let before = bench_host.port_os_pids()
/// ```
pub fn port_os_pids() -> List(Int) {
  let os_pid = atom.create("os_pid")
  list.filter_map(all_ports(), fn(port) {
    // A port that is not an OS process answers `undefined`, and one that
    // closed between the listing and the query answers `undefined` too.
    decode.run(port_info(port, os_pid), decode.at([1], decode.int))
    |> result.replace_error(Nil)
  })
}

@external(erlang, "sys", "suspend")
fn sys_suspend(pid: Pid) -> Dynamic

@external(erlang, "sys", "resume")
fn sys_resume(pid: Pid) -> Dynamic

/// Stops an OTP process from handling messages. They keep arriving, in
/// order, and wait in its mailbox until `resume`. A test uses it to fix the
/// order in which two events reach an actor that would otherwise read them
/// as they come.
///
/// ## Examples
///
/// ```gleam
/// // bench_host.suspend(actor_pid)
/// ```
pub fn suspend(pid: Pid) -> Nil {
  let _ = sys_suspend(pid)
  Nil
}

/// Lets a suspended OTP process handle the messages that queued behind it.
///
/// ## Examples
///
/// ```gleam
/// // bench_host.resume(actor_pid)
/// ```
pub fn resume(pid: Pid) -> Nil {
  let _ = sys_resume(pid)
  Nil
}

@external(erlang, "erlang", "process_info")
fn process_info(pid: Pid, item: atom.Atom) -> Dynamic

/// How many messages wait in a process's mailbox, or `0` once it has
/// exited. A suspended actor's mailbox only grows, so a test reads it to
/// know that a request it sent has arrived before it does the next thing,
/// without guessing how long the send takes.
///
/// ## Examples
///
/// ```gleam
/// // bench_host.queued(actor_pid)
/// ```
pub fn queued(pid: Pid) -> Int {
  process_info(pid, atom.create("message_queue_len"))
  |> decode.run(decode.at([1], decode.int))
  |> result.unwrap(0)
}
