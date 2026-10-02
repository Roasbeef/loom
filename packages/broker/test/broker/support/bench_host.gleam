//// What the exec benchmark can observe about the machine it runs on.
////
//// `bench_exec_test` measures the helper pool from the outside: how long a
//// spawn takes, how much memory an idle jail holds, which OS processes a
//// cancelled execution left behind. None of that is visible to Gleam, and
//// none of it may be added to `src`, so every observation lives here and is
//// backed by `test/bench_exec_ffi.erl`. Each is a read of `/proc`, a clock,
//// or one `kill(1)`; none changes what the pool does.
////
//// Linux only. `/proc` is the interface, and the benchmark's gate refuses to
//// run where the helper has no jail to measure.

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
