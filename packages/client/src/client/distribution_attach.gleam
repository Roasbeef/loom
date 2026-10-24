//// The credential files an attaching tool needs to join a distributed daemon
//// (protocol-change/096).
////
//// A daemon that runs TLS distribution accepts a node only if its certificate
//// chains to the deployment's authority and its pin is in the membership
//// ledger. An inspection tool (pickglass, Observer, `erl -remsh`) is such a
//// node, so the operator enrolls it as a `tool` member and gives it a
//// certificate, a key, the authority certificate and the deployment's cookie.
//// This module is the part of that which is pure: where the files sit in
//// the directory the operator names, the standard `ssl_dist_optfile` that
//// points at them, and the sentences that say how to start a tool with them.
//// The command that mints and writes them is `client/daemon/ledger_cli`.
////
//// ## Why the options file is plain
////
//// The daemon's own options file names `client_distribution_ffi:verify/4`, a
//// function of the Loom release, because the daemon has to check pins. A tool
//// runs on a machine that may not have Loom at all, so its file names only
//// options every Erlang/OTP 25 or later understands: the three credential
//// files, `verify_peer` against the authority, and the TLS versions. The
//// daemon's certificate is checked by the usual chain verification. The
//// daemon, not the tool, is the side that pins.
////
//// ## Flow
////
//// 1. `files_in` names the five paths under the operator's directory.
//// 2. `options` renders the file for them, and refuses a path that could not
////    be written as an Erlang string.
//// 3. `instructions` prints the commands a person runs next.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The cookie file name Erlang reads from `$HOME`.
pub const cookie_file = ".erlang.cookie"

/// The options file name.
pub const options_file = "ssl_dist.conf"

/// The file naming the tool's own node, one line. Together with the options
/// file and the cookie it makes the directory a self-contained
/// `pickglass attach --attach-dir`.
pub const node_file = "node"

/// The six absolute paths of an attachment. Each sits directly in the
/// directory the operator named, which is created with mode 0700, and the key
/// and the cookie are written mode 0600.
pub type Files {
  Files(
    /// The directory itself, which `HOME` is pointed at to supply the cookie.
    directory: String,
    /// PEM of the deployment's authority certificate.
    ca: String,
    /// PEM of the tool's certificate.
    certificate: String,
    /// PEM of the tool's private key.
    key: String,
    /// The deployment's cookie, with no trailing newline.
    cookie: String,
    /// The `ssl_dist_optfile` that names the other four.
    options: String,
    /// The tool's node name and a newline, which a viewer reads to know what to
    /// start as.
    node: String,
  )
}

/// The six paths under `directory`, which is absolute and has no trailing
/// slash.
///
/// ## Examples
///
/// ```gleam
/// let files = distribution_attach.files_in("/home/me/attach")
/// assert files.options == "/home/me/attach/ssl_dist.conf"
/// ```
pub fn files_in(directory: String) -> Files {
  Files(
    directory:,
    ca: directory <> "/ca.pem",
    certificate: directory <> "/tool.pem",
    key: directory <> "/tool.key",
    cookie: directory <> "/" <> cookie_file,
    options: directory <> "/" <> options_file,
    node: directory <> "/" <> node_file,
  )
}

/// Renders the `ssl_dist_optfile` for `files`. It holds paths and no secret.
///
/// The file has a `client` section and no `server` one, on purpose. A tool
/// dials the daemon and must never be dialled: a listener here could only trust
/// the authority, not the ledger, so it would accept a member the ledger has
/// revoked. Without a `server` section a tool that listens anyway fails to
/// start its listener, and the recipe adds `-hidden -dist_listen false`.
///
/// A path with a quote, a backslash or a control character cannot be written
/// as an Erlang string literal, so it is refused with the sentence naming it.
///
/// ## Examples
///
/// ```gleam
/// distribution_attach.options(distribution_attach.files_in("/a"))
/// // -> Ok("%% coding: utf-8\n[{server, [{cacertfile, \"/a/ca.pem\"}, ..."
/// ```
pub fn options(files: Files) -> Result(String, String) {
  // Verify that all configured certificate paths are safe to embed in an Erlang
  // terms configuration file.
  case list.find(paths(files), fn(path) { !is_plain_path(path) }) {
    Ok(path) ->
      Error(
        "the path "
        <> path
        <> " has a quote, a backslash or a control "
        <> "character, which an Erlang options file cannot hold",
      )
    Error(Nil) -> {
      let shared =
        "{cacertfile, \""
        <> files.ca
        <> "\"}, {certfile, \""
        <> files.certificate
        <> "\"}, {keyfile, \""
        <> files.key
        <> "\"}, {verify, verify_peer}, {versions, ['tlsv1.3', 'tlsv1.2']}"
      Ok("%% coding: utf-8\n[{client, [" <> shared <> "]}].\n")
    }
  }
}

fn paths(files: Files) -> List(String) {
  [files.directory, files.ca, files.certificate, files.key, files.options]
}

/// Verifies that every codepoint in `path` is printable ASCII without quotes,
/// backslashes, or control characters, preventing term injection in Erlang config files.
fn is_plain_path(path: String) -> Bool {
  string.to_utf_codepoints(path)
  |> list.all(fn(point) {
    let code = string.utf_codepoint_to_int(point)
    code >= 32 && code != 127 && code != 34 && code != 92
  })
}

/// What a person runs after the files are written: a remote shell, Observer,
/// and any other tool, all with the same two standard flags. `tool_node` is the
/// node name the certificate was issued for, which the tool must start with,
/// and `daemons` are the nodes the tool was allowed to reach.
///
/// ## Examples
///
/// ```gleam
/// distribution_attach.instructions(files, "me@127.0.0.1", ["loom@hub.example"])
/// ```
pub fn instructions(
  files: Files,
  tool_node: String,
  daemons: List(String),
) -> String {
  let flags =
    "-proto_dist inet_tls -ssl_dist_optfile "
    <> shell_quote(files.options)
    <> " -name "
    <> tool_node
    <> " -hidden -dist_listen false"

  // Pick the target node if unambiguous, or leave a descriptive placeholder.
  let daemon = case daemons {
    [only] -> only
    _ -> "<daemon node>"
  }

  let directory = shell_quote(files.directory)
  string.join(
    [
      "Pickglass:     pickglass attach --node "
        <> daemon
        <> " --attach-dir "
        <> directory,
      "",
      "Any Erlang node started with these flags can join the daemon. The node "
        <> "must be named "
        <> tool_node
        <> ", and it reads the deployment's cookie from $HOME/"
        <> cookie_file
        <> ", so point HOME at "
        <> files.directory
        <> " for the run (or copy the cookie to your own $HOME).",
      "",
      "  Remote shell:  HOME="
        <> shell_quote(files.directory)
        <> " erl "
        <> flags
        <> " -remsh "
        <> daemon,
      "  Observer:      HOME="
        <> shell_quote(files.directory)
        <> " erl "
        <> flags
        <> " -eval 'observer:start().'  (then Nodes, Connect node)",
      "  Other tools:   pass `-proto_dist inet_tls -ssl_dist_optfile "
        <> files.options
        <> " -hidden -dist_listen false` to the tool's own VM, with the node "
        <> "name above. A tool must not listen: its options trust the "
        <> "authority and not the ledger, so a listener would accept a "
        <> "member that was revoked.",
    ],
    "\n",
  )
}

// Single quotes, so a path with a space survives the shell. A single quote in
// the path is closed, escaped and reopened.
fn shell_quote(text: String) -> String {
  "'" <> string.replace(text, "'", "'\\''") <> "'"
}

/// The attach root pickglass reads: `$PICKGLASS_ATTACH_HOME` when it is set and
/// not empty, else `<home>/.pickglass/attach`. Loom only agrees with pickglass
/// on the directory layout; it does not depend on it.
///
/// ## Examples
///
/// ```gleam
/// assert distribution_attach.attach_root(None, "/home/me")
///   == "/home/me/.pickglass/attach"
/// ```
pub fn attach_root(override: Option(String), home: String) -> String {
  case override {
    Some("") | None -> home <> "/.pickglass/attach"
    Some(root) -> root
  }
}

/// Whether `name` can be one directory below the attach root: not empty, not a
/// dot name and holding no path separator.
///
/// ## Examples
///
/// ```gleam
/// assert distribution_attach.is_directory_name("inspector")
/// assert !distribution_attach.is_directory_name("../x")
/// ```
pub fn is_directory_name(name: String) -> Bool {
  name != ""
  && !string.starts_with(name, ".")
  && !string.contains(name, "/")
  && !string.contains(name, "\\")
}

/// The lines `--for pickglass` adds to the recipe. `--attach NAME` is
/// pickglass's explicit short form of `--attach-dir ROOT/NAME`. Without either
/// flag pickglass picks nothing by itself, so both forms are shown.
///
/// ## Examples
///
/// ```gleam
/// distribution_attach.pickglass_lines("/r", "tool", "loom@hub.example")
/// ```
pub fn pickglass_lines(root: String, name: String, daemon: String) -> String {
  string.join(
    [
      "Pickglass attach root " <> root <> ":",
      "  pickglass attach --node " <> daemon <> " --attach " <> name,
      "  (the same as: pickglass attach --node "
        <> daemon
        <> " --attach-dir "
        <> shell_quote(root <> "/" <> name)
        <> ")",
    ],
    "\n",
  )
}
