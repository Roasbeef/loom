//// Test-only externals for the codemode suite: a client end of the cap
//// socket, and the shell lookups the feature-detected end-to-end test uses
//// to find the toolchain and build the Go helper. Backed by
//// `codemode_test_ffi.erl`; production code never uses these.

/// A connected client end of a cap socket.
pub type PeerSocket

/// Connects to a cap socket exactly as `cap/internal/ffi_transport` does,
/// so a test drives the launcher's real listener over a real AF_UNIX
/// stream. Uses `gen_tcp:connect/3` with a `{local, Path}` address.
@external(erlang, "codemode_test_ffi", "connect_unix")
pub fn connect(path: String) -> Result(PeerSocket, Nil)

/// Writes bytes to the cap socket. Uses `gen_tcp:send/2`.
@external(erlang, "codemode_test_ffi", "peer_send")
pub fn send(socket: PeerSocket, bytes: BitArray) -> Result(Nil, Nil)

/// Reads whatever is available, up to `timeout_ms`. Uses `gen_tcp:recv/3`.
@external(erlang, "codemode_test_ffi", "peer_recv")
pub fn recv(socket: PeerSocket, timeout_ms: Int) -> Result(BitArray, Nil)

/// Closes the client end, which the launcher's reader sees as EOF. Uses
/// `gen_tcp:close/1`.
@external(erlang, "codemode_test_ffi", "peer_close")
pub fn close(socket: PeerSocket) -> Nil

/// Looks an executable up on PATH. Uses `os:find_executable/1`; PATH
/// lookup has no pure alternative.
@external(erlang, "codemode_test_ffi", "find_executable")
pub fn find_executable(name: String) -> Result(String, Nil)

/// Runs a shell command and returns its stdout. Uses `os:cmd/1`;
/// test-only, for driving `go build`.
@external(erlang, "codemode_test_ffi", "os_cmd")
pub fn os_cmd(command: String) -> String

/// Reads the real wall clock in Unix milliseconds. Uses
/// `erlang:system_time/1`; the end-to-end suite runs against real
/// deadlines, which a fixture clock cannot provide.
@external(erlang, "codemode_test_ffi", "now_ms")
pub fn now_ms() -> Int

/// Reads an environment variable, returning `Error(Nil)` when it is unset.
/// Uses `os:getenv/1`; the launcher tests use the process environment to
/// select a short scratch directory outside `/tmp`.
@external(erlang, "codemode_test_ffi", "get_env")
pub fn get_env(name: String) -> Result(String, Nil)
