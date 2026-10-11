//// Operator commands for a dedicated native ChatGPT subscription profile.
////
//// Login, status, logout, and model discovery use the same profile owner as
//// inference. This module receives redacted control events and presents them
//// to the operator. It never reads an OAuth token, account ID, or credential
//// file. A command that fails or times out is cancelled through its request owner.

import client/codex/credentials
import client/codex/oauth
import client/codex/profile_control.{type Command, type ControlEvent} as control
import client/codex/transport
import client/internal/ffi_os
import gleam/erlang/process
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/result
import provider/http

/// Usage for the Codex subscription control commands.
pub const usage =
  "usage: loomd codex <command> [--profile NAME]\n  login               Sign in with ChatGPT using your browser.\n  status              Show whether the profile is signed in.\n  models              Show models available to this profile as JSON.\n  logout              Remove this profile's saved credential.\n\nThe default profile is `default`. A profile is 1-64 ASCII letters, digits,\nunderscores, or hyphens, starting with a letter or digit."

/// A parsed request contains only a command and a portable profile name.
@internal
pub type Request {
  /// A command whose flags have already been checked.
  Request(profile: String, command: Command)
}

/// Runs one operator command without starting the daemon.
///
/// ## Examples
///
/// ```gleam
/// // cli.main(["status", "--profile", "default"])
/// ```
pub fn main(arguments: List(String)) -> Nil {
  let outcome = {
    use request <- result.try(parse(arguments))
    execute(request, io.println)
  }
  case outcome {
    Ok(Nil) -> Nil
    Error(reason) -> {
      io.println_error("loom codex: " <> reason)
      ffi_os.halt(1)
    }
  }
}

/// Parses the operator's exact verb and flag shape before preparing an operation.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(Request("default", control.Status)) = parse(["status"])
/// ```
@internal
pub fn parse(arguments: List(String)) -> Result(Request, String) {
  case arguments {
    ["login", ..flags] -> parse_flags(flags, control.LoginBrowser, None)
    ["status", ..flags] -> parse_flags(flags, control.Status, None)
    ["models", ..flags] -> parse_flags(flags, control.Models, None)
    ["logout", ..flags] -> parse_flags(flags, control.Logout, None)
    [] -> Error("a command is required\n" <> usage)
    [other, ..] -> Error("unknown command `" <> other <> "`\n" <> usage)
  }
}

fn parse_flags(
  flags: List(String),
  command: Command,
  profile: Option(String),
) -> Result(Request, String) {
  case flags {
    [] -> {
      let profile = option.unwrap(profile, "default")
      use Nil <- result.try(
        credentials.valid_profile(profile)
        |> result.map_error(fn(_) { "invalid profile name\n" <> usage }),
      )
      Ok(Request(profile:, command:))
    }
    ["--profile", name, ..rest] ->
      case profile {
        None -> parse_flags(rest, command, Some(name))
        Some(_) -> Error("--profile may be passed only once\n" <> usage)
      }
    [other, ..] -> Error("unknown argument `" <> other <> "`\n" <> usage)
  }
}

fn execute(request: Request, emit: fn(String) -> Nil) -> Result(Nil, String) {
  let events = process.new_subject()
  use prepared <- result.try(transport.command(
    request.profile,
    request.command,
    events,
  ))

  // The owner is monitored before `begin`, because the operation does no work
  // until it holds the permit. An owner that exits early is then reported as
  // `OwnerGone` instead of leaving the wait to run out its deadline.
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

  // Any failure asks the owner to stop. Cancellation is idempotent and
  // harmless once the owner has exited, so the failure kind does not matter.
  case answer {
    Error(_) -> http.cancel(running)
    Ok(Nil) -> Nil
  }
  process.demonitor_process(monitor)
  answer
}

type Observation {
  Observed(ControlEvent)
  OwnerGone(process.ExitReason)
}

// OAuth can involve a human leaving the terminal for several minutes. The
// command still has a finite wait so its owner can cancel a stranded operation.
const login_wait_ms = 600_000

const control_wait_ms = 30_000

const drain_wait_ms = 30_000

fn await_event(
  selector,
  command: Command,
  emit: fn(String) -> Nil,
) -> Result(Nil, String) {
  let within = case command {
    control.LoginBrowser -> login_wait_ms
    control.Status | control.Logout | control.Models -> control_wait_ms
  }
  case process.selector_receive(selector, within) {
    Error(Nil) -> Error("subscription command timed out")
    Ok(OwnerGone(_)) ->
      Error("subscription operation stopped before completion")
    Ok(Observed(event)) ->
      case presentation(event) {
        Continue(lines) -> {
          print_lines(lines, emit)
          await_event(selector, command, emit)
        }
        Complete(_) as terminal -> await_owner(selector, terminal, emit)
        Refused(_) as terminal -> await_owner(selector, terminal, emit)
      }
  }
}

// A control result is complete only after the witnessed owner exits normally.
// Its surviving ledger waits for credential work and every adopted HTTP or
// listener owner to retire, even when the operation worker disappears.
fn await_owner(
  selector,
  terminal: Presentation,
  emit: fn(String) -> Nil,
) -> Result(Nil, String) {
  case process.selector_receive(selector, drain_wait_ms) {
    Error(Nil) -> Error("subscription command timed out")
    Ok(OwnerGone(reason)) -> {
      use lines <- result.try(drained_result(reason, terminal))
      print_lines(lines, emit)
      Ok(Nil)
    }
    Ok(Observed(_)) ->
      Error("subscription operation sent duplicate terminal result")
  }
}

/// Accepts a control result only when its request owner exited normally.
///
/// ## Examples
///
/// ```gleam
/// // drained_result(process.Normal, Complete(["done"])) == Ok(["done"])
/// ```
@internal
pub fn drained_result(
  reason: process.ExitReason,
  terminal: Presentation,
) -> Result(List(String), String) {
  case reason, terminal {
    process.Normal, Complete(lines) -> Ok(lines)
    process.Normal, Refused(code) ->
      Error("subscription operation refused " <> code)
    process.Normal, Continue(_) ->
      Error("subscription operation ended before completion")
    process.Killed, _ | process.Abnormal(_), _ ->
      Error("subscription operation drain proof lost")
  }
}

fn print_lines(lines: List(String), emit: fn(String) -> Nil) -> Nil {
  case lines {
    [] -> Nil
    [line, ..rest] -> {
      emit(line)
      print_lines(rest, emit)
    }
  }
}

/// The only rendering path for native control events. Model JSON is already
/// reduced to validated, non-secret IDs at the profile boundary.
@internal
pub type Presentation {
  /// Instructions precede a login's terminal completion.
  Continue(lines: List(String))

  /// A terminal success.
  Complete(lines: List(String))

  /// A terminal operation refusal identified only by a code.
  Refused(code: String)
}

/// Projects one redacted control event onto terminal text.
///
/// ## Examples
///
/// ```gleam
/// // presentation(control.LoginStatus(control.SignedOut))
/// ```
@internal
pub fn presentation(event: ControlEvent) -> Presentation {
  case event {
    control.LoginInstructions(port) ->
      Continue(["Open " <> oauth.start_url(port)])
    control.LoginComplete(permission) -> signed_in(permission)
    control.LoginStatus(control.SignedIn(permission)) -> signed_in(permission)
    control.LoginStatus(control.SignedOut) ->
      Complete(["Not signed in with ChatGPT."])
    control.LogoutComplete -> Complete(["Signed out of ChatGPT."])
    control.LogoutRevocationUnconfirmed ->
      Complete([
        "Signed out locally. Remote revocation was not confirmed; disconnect Loom in ChatGPT Settings.",
      ])
    control.ModelCatalogue(json) -> Complete([json])
    control.ControlFailed(code) -> Refused(code)
  }
}

fn signed_in(permission: control.Permission) -> Presentation {
  let label = case permission {
    control.PlanEnabled -> "plan_enabled"
    control.IdentityOnly -> "identity_only"
  }
  Complete(["Signed in with ChatGPT (" <> label <> ")."])
}
