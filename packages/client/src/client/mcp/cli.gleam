//// Operator commands for remote MCP server OAuth 2.1 credentials.
////
//// `loomd mcp login <server>`, `status <server>`, and `logout <server>` read
//// `[mcp.<server>]` from `--config PATH` (or `~/.loom/loom.toml` by default),
//// verify that the server is a remote HTTP entry configured with
//// `auth = "oauth"`, and run the requested credential operation inside a
//// witnessed `weft` scope so every loopback callback listener and HTTP
//// exchange drains before the command exits. No token value ever reaches
//// terminal output.

import client/catalog
import client/codex/transport
import client/internal/ffi_os
import client/mcp/credentials
import client/mcp/oauth
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import host/bootstrap
import provider/http
import simplifile
import weft

/// Usage text for `loomd mcp`.
pub const usage =
  "usage: loomd mcp <command> <server> [--config PATH]\n  login <server>      Authorize an OAuth MCP server in your browser.\n  status <server>     Show whether an OAuth MCP server is signed in.\n  logout <server>     Remove saved OAuth tokens for an MCP server.\n\nThe server must be configured under `[mcp.<server>]` with `url` and\n`auth = \"oauth\"`. When `--config` is omitted, `~/.loom/loom.toml` is read."

/// Which MCP OAuth operator command to execute.
pub type Command {
  /// Authorize `<server>` through a loopback browser PKCE flow.
  Login

  /// Report whether `<server>` holds a saved OAuth grant.
  Status

  /// Clear saved OAuth tokens for `<server>`.
  Logout
}

/// A parsed CLI invocation before reading the configuration file.
@internal
pub type Request {
  Request(command: Command, server: String, config_path: Option(String))
}

/// Redacted observations emitted by a running MCP OAuth command.
@internal
pub type Event {
  /// The loopback port whose `/auth/start` route begins browser authorization.
  LoginInstructions(port: Int)

  /// Login completed and the grant was saved.
  LoginComplete(server: String)

  /// Status report for `server`.
  StatusReport(server: String, signed_in: SignInState)

  /// Saved tokens for `server` were cleared.
  LogoutComplete(server: String)

  /// Operation failed with a redacted error reason.
  CommandFailed(reason: String)
}

/// Whether a server currently holds a saved OAuth grant.
@internal
pub type SignInState {
  SignedIn
  SignedOut
}

/// Runs one `loomd mcp` operator command and exits non-zero on failure.
///
/// ## Examples
///
/// ```gleam
/// // cli.main(["status", "linear"])
/// ```
pub fn main(arguments: List(String)) -> Nil {
  let outcome = {
    use request <- result.try(parse(arguments))
    execute(request, io.println)
  }
  case outcome {
    Ok(Nil) -> Nil
    Error(reason) -> {
      io.println_error("loomd mcp: " <> reason)
      ffi_os.halt(1)
    }
  }
}

/// Parses `loomd mcp` arguments before touching the filesystem or network.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(Request(Status, "linear", None)) = cli.parse(["status", "linear"])
/// ```
@internal
pub fn parse(arguments: List(String)) -> Result(Request, String) {
  case arguments {
    ["login", ..rest] -> parse_rest(Login, rest, None, None)
    ["status", ..rest] -> parse_rest(Status, rest, None, None)
    ["logout", ..rest] -> parse_rest(Logout, rest, None, None)
    [] -> Error("a command is required\n" <> usage)
    [other, ..] -> Error("unknown command `" <> other <> "`\n" <> usage)
  }
}

fn parse_rest(
  command: Command,
  flags: List(String),
  server: Option(String),
  config_path: Option(String),
) -> Result(Request, String) {
  case flags {
    [] ->
      case server {
        None -> Error("a server name is required\n" <> usage)
        Some(name) -> {
          use Nil <- result.try(
            credentials.valid_server(name)
            |> result.map_error(fn(_) {
              "invalid server name `" <> name <> "`\n" <> usage
            }),
          )
          Ok(Request(command:, server: name, config_path:))
        }
      }
    ["--config", path, ..rest] ->
      case config_path {
        None if path != "" -> parse_rest(command, rest, server, Some(path))
        None -> Error("--config requires a non-empty path\n" <> usage)
        Some(_) -> Error("--config may be passed only once\n" <> usage)
      }
    ["--config"] -> Error("--config requires a path\n" <> usage)
    [word, ..rest] ->
      case server {
        None -> parse_rest(command, rest, Some(word), config_path)
        Some(_) -> Error("unexpected argument `" <> word <> "`\n" <> usage)
      }
  }
}

fn execute(request: Request, emit: fn(String) -> Nil) -> Result(Nil, String) {
  use directory <- result.try(credentials.directory())
  let events = process.new_subject()
  use prepared <- result.try(
    transport.prepare_with(events, fn(ledger) {
      case
        run_in_scope(
          directory,
          request,
          oauth.services_on(ledger),
          events,
          ledger,
        )
      {
        Ok(Nil) -> Ok(Nil)
        Error(reason) -> {
          process.send(events, CommandFailed(reason))
          Ok(Nil)
        }
      }
    }),
  )

  // Monitor the operation owner before releasing its begin permit.
  let running = prepared.running
  let monitor = process.monitor(http.owner(running))
  let selector =
    process.new_selector()
    |> process.select_map(events, Observed)
    |> process.select_specific_monitor(monitor, fn(down) {
      OwnerGone(down.reason)
    })
  prepared.begin()
  let answer = await_event(selector, request.command, emit)
  case answer {
    Error(_) -> http.cancel(running)
    Ok(Nil) -> Nil
  }
  process.demonitor_process(monitor)
  answer
}

/// Runs a parsed command against an explicit credential directory and `Services`.
///
/// ## Examples
///
/// ```gleam
/// // cli.run_in_scope(dir, request, services, events, ledger)
/// ```
@internal
pub fn run_in_scope(
  directory: String,
  request: Request,
  services: oauth.Services,
  events: process.Subject(Event),
  ledger: weft.Ledger,
) -> Result(Nil, String) {
  case request.command {
    Logout -> {
      use Nil <- result.try(oauth.logout_at(directory, request.server))
      process.send(events, LogoutComplete(request.server))
      Ok(Nil)
    }
    Login -> {
      use #(url, client_id) <- result.try(resolve_oauth_target(
        request.server,
        request.config_path,
      ))
      use _binding <- result.try(oauth.login_at(
        directory,
        request.server,
        url,
        client_id,
        services,
        fn(port) { process.send(events, LoginInstructions(port)) },
        ledger,
      ))
      process.send(events, LoginComplete(request.server))
      Ok(Nil)
    }
    Status -> {
      use #(url, client_id) <- result.try(resolve_oauth_target(
        request.server,
        request.config_path,
      ))
      use grant <- result.try(oauth.status_at(
        directory,
        request.server,
        url,
        client_id,
      ))
      let state = case grant {
        Some(_) -> SignedIn
        None -> SignedOut
      }
      process.send(events, StatusReport(request.server, state))
      Ok(Nil)
    }
  }
}

fn resolve_oauth_target(
  server: String,
  config_path: Option(String),
) -> Result(#(String, Option(String)), String) {
  use path <- result.try(resolve_config_path(config_path))
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(_) { "could not read configuration at " <> path }),
  )
  use servers <- result.try(catalog.parse_mcp(text))
  use found <- result.try(
    list.find(servers, fn(entry) { entry.name == server })
    |> result.map_error(fn(_) {
      "no [mcp." <> server <> "] table is configured in " <> path
    }),
  )
  case found.target {
    catalog.McpHttp(url:, auth: catalog.McpOAuth(client_id:)) ->
      Ok(#(url, client_id))
    catalog.McpHttp(..) ->
      Error(
        "[mcp."
        <> server
        <> "] does not use OAuth (set `auth = \"oauth\"` to sign in)",
      )
    catalog.McpStdio(..) ->
      Error(
        "[mcp."
        <> server
        <> "] is a stdio server; OAuth sign-in is only for remote `url` servers",
      )
  }
}

fn resolve_config_path(explicit: Option(String)) -> Result(String, String) {
  case explicit {
    Some(path) -> Ok(path)
    None ->
      bootstrap.getenv("HOME")
      |> result.map(fn(home) { home <> "/.loom/loom.toml" })
      |> result.replace_error("HOME is not set; pass --config PATH")
  }
}

type Observation {
  Observed(Event)
  OwnerGone(process.ExitReason)
}

const login_wait_ms = 600_000

const control_wait_ms = 30_000

const drain_wait_ms = 30_000

fn await_event(
  selector: process.Selector(Observation),
  command: Command,
  emit: fn(String) -> Nil,
) -> Result(Nil, String) {
  let within = case command {
    Login -> login_wait_ms
    Status | Logout -> control_wait_ms
  }
  case process.selector_receive(selector, within) {
    Error(Nil) -> Error("mcp command timed out")
    Ok(OwnerGone(_)) -> Error("mcp operation stopped before completion")
    Ok(Observed(event)) ->
      case presentation(event) {
        Continue(lines) -> {
          list.each(lines, emit)
          await_event(selector, command, emit)
        }
        Complete(_) as terminal -> await_owner(selector, terminal, emit)
        Refused(_) as terminal -> await_owner(selector, terminal, emit)
      }
  }
}

fn await_owner(
  selector: process.Selector(Observation),
  terminal: Presentation,
  emit: fn(String) -> Nil,
) -> Result(Nil, String) {
  case process.selector_receive(selector, drain_wait_ms) {
    Error(Nil) -> Error("mcp command timed out")
    Ok(OwnerGone(reason)) -> {
      use lines <- result.try(drained_result(reason, terminal))
      list.each(lines, emit)
      Ok(Nil)
    }
    Ok(Observed(_)) -> Error("mcp operation sent duplicate terminal result")
  }
}

/// Accepts a terminal result only after its operation owner exits normally.
///
/// ## Examples
///
/// ```gleam
/// assert cli.drained_result(process.Normal, cli.Complete(["ok"])) == Ok(["ok"])
/// ```
@internal
pub fn drained_result(
  reason: process.ExitReason,
  terminal: Presentation,
) -> Result(List(String), String) {
  case reason, terminal {
    process.Normal, Complete(lines) -> Ok(lines)
    process.Normal, Refused(reason) -> Error(reason)
    process.Normal, Continue(_) ->
      Error("mcp operation ended before completion")
    process.Killed, _ | process.Abnormal(_), _ ->
      Error("mcp operation drain proof lost")
  }
}

/// How one event renders to terminal lines.
@internal
pub type Presentation {
  Continue(lines: List(String))
  Complete(lines: List(String))
  Refused(reason: String)
}

/// Renders one redacted event into user-facing text.
///
/// ## Examples
///
/// ```gleam
/// assert cli.presentation(cli.LoginInstructions(1455))
///   == cli.Continue(["Open http://127.0.0.1:1455/auth/start"])
/// ```
@internal
pub fn presentation(event: Event) -> Presentation {
  case event {
    LoginInstructions(port) -> Continue(["Open " <> oauth.start_url(port)])
    LoginComplete(server) ->
      Complete(["Signed in to MCP server " <> server <> "."])
    StatusReport(server, SignedIn) ->
      Complete(["Signed in to MCP server " <> server <> "."])
    StatusReport(server, SignedOut) ->
      Complete(["Not signed in to MCP server " <> server <> "."])
    LogoutComplete(server) ->
      Complete(["Signed out of MCP server " <> server <> "."])
    CommandFailed(reason) -> Refused(reason)
  }
}
