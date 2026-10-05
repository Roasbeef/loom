//// Shared test-only administrative provisioning for independent owner and
//// executor BEAMs. Tests choose a repository-local directory when satellites
//// need real jail-visible sockets; none of these fixtures enters production.

import executor/remote/distribution

/// Credentials and public boot configuration for two distinct test runtimes.
pub type Provisioned {
  Provisioned(
    /// Parent-owned private fixture directory.
    directory: String,
    /// Owner's actual public bootstrap configuration.
    owner_config: distribution.Config,
    /// Executor's actual public bootstrap configuration.
    executor_config: distribution.Config,
    /// Private owner OTP options file.
    owner_options: String,
    /// Private executor OTP options file.
    executor_options: String,
    /// Full fixed owner identity for this fixture.
    owner_name: String,
    /// Full fixed executor identity for this fixture.
    executor_name: String,
  )
}

/// Mints ephemeral same-CA certificates, separate exact pins and private files.
/// The caller owns deletion after both independent OS processes have exited.
///
/// ## Examples
/// ```gleam
/// distribution_fixture.provision("/repo/build/tls-fixture", "compile")
/// ```
@external(erlang, "executor_distribution_fixture_ffi", "provision")
pub fn provision(directory: String, prefix: String) -> Result(Provisioned, Nil)

/// Returns this parent VM's Unix OTP launcher, including bundled runtimes.
/// Using the same ERTS avoids resolving a different installed OTP through PATH.
///
/// ## Examples
/// ```gleam
/// distribution_fixture.current_executable()
/// ```
@external(erlang, "executor_distribution_fixture_ffi", "current_executable")
pub fn current_executable() -> String

/// Returns fixed TLS flags, current absolute code paths and original OS HOME
/// restoration. Set the spawned erlexec environment HOME to the options file's
/// private parent directory, so OTP captures exactly that home before restoring
/// the original OS HOME. Tests add their fixed entrypoint and finite lifetime.
/// An absent original HOME becomes an empty runtime HOME value.
///
/// ## Examples
/// ```gleam
/// distribution_fixture.node_arguments(fixture.owner_options)
/// ```
@external(erlang, "executor_distribution_fixture_ffi", "node_arguments")
pub fn node_arguments(options: String) -> List(String)

/// Starts one test OS BEAM with private erlexec HOME, preserving argv as a vector.
/// Pair with `node_arguments`, which restores the original runtime OS HOME.
/// The enclosing test must use a finite weft deadline and a fixed role runner;
/// exit zero alone is insufficient without that runner's completion witness.
///
/// ## Examples
/// ```gleam
/// distribution_fixture.run_node(erl, args, directory, private_otp_home)
/// ```
@external(erlang, "executor_distribution_fixture_ffi", "run_node")
pub fn run_node(
  executable: String,
  args: List(String),
  directory: String,
  otp_home: String,
) -> Result(#(Int, String), String)

/// Saves a trusted finite test fixture without serializing functions.
///
/// ## Examples
/// ```gleam
/// distribution_fixture.write_provisioned(fixture, "/repo/build/fixture.term")
/// ```
@external(erlang, "executor_distribution_fixture_ffi", "write_provisioned")
pub fn write_provisioned(fixture: Provisioned, path: String) -> Result(Nil, Nil)

/// Reads only the original bounded administrator-written test fixture.
/// Its Config values still must pass public `distribution.start` locally.
///
/// ## Examples
/// ```gleam
/// distribution_fixture.read_provisioned("/repo/build/fixture.term")
/// ```
@external(erlang, "executor_distribution_fixture_ffi", "read_provisioned")
pub fn read_provisioned(path: String) -> Result(Provisioned, Nil)
