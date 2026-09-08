//// Whether the shipped helper beside a server executable can actually
//// enforce a policy on this host, answered by running one harmless jailed
//// command through it.
////
//// Two shipped fixtures need the same verdict before they may run a
//// subsection that depends on real confinement, and the verdict has to be
//// *measured*: an OS name proves nothing, and the presence of `bwrap` on
//// `PATH` proves less — a helper can be built, present and current and
//// still be handed a kernel with no Landlock, no seccomp and no user
//// namespaces, which is exactly the ordinary Linux gate. So the probe
//// spawns the real sibling `loom-exec` with the production workspace
//// policy, demands platform enforcement, and reads the terminal event.
////
//// It lives here rather than inside one fixture because the *reason* is
//// what `.github/declared-skips` matches on, and two copies of a reason
//// drift. Each caller supplies its own label so the skip line still names
//// which fixture declined, and the reason after the colon is one string
//// with one declaration per gate.

import broker/exec
import broker/policy
import client/serve
import filepath
import gleam/bit_array
import gleam/bool
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{Some}
import gleam/result
import gleam/string
import host/bootstrap as native
import weft/poll

/// The exact reason a declined probe prints, and therefore the substring a
/// declared skip is written against.
pub const unavailable_reason = "platform enforcement unavailable"

/// What the probe measured.
pub type Enforcement {
  /// The helper ran a harmless command under the demanded enforcement.
  EnforcementLive

  /// The helper or the execution came back degraded. The caller has
  /// already had its skip line printed.
  EnforcementAbsent
}

/// Probes the `loom-exec` beside `server`, printing a skip line naming
/// `label` when enforcement is absent.
///
/// Panics rather than skipping on any other failure: a helper that is
/// missing, that refuses to start, or that fails a harmless command is a
/// broken shipment, not an environment without a jail.
///
/// ## Examples
///
/// ```gleam
/// // enforcement.probe(server, "shipped jobs live tool")
/// ```
///
pub fn probe(server: String, label: String) -> Enforcement {
  let helper_path = filepath.join(filepath.directory_name(server), "loom-exec")
  let assert Ok(helper_path) = native.find_executable(helper_path)
    as "a configured shipped server must have its sibling loom-exec executable"
  let directory = private_directory()
  let base = serve.base_policy(directory)
  let assert Ok(helper) =
    exec.spawn_helper(exec.SpawnConfig(
      helper_path: helper_path,
      shell_path: serve.shell_path,
      base_policy: base,
      helper_args: exec.unenforced_helper_args(exec.host_platform()),
      tmp_dir: directory <> "/tmp",
      handshake_timeout_ms: 5000,
      cancel_grace_ms: 3000,
      heartbeat_interval_ms: 0,
    ))
    as "the exact shipped enforcement helper must start"
  verdict(helper, base, directory, label)
}

// Authorized shipment fixtures place loom-exec beside their server
// launcher, and each probe owns a private workspace so two suites running
// in the same checkout cannot observe each other's scratch.
fn private_directory() -> String {
  let directory =
    "build/shipped-enforcement-"
    <> int.to_string(native.current_process_id())
    <> "-"
    <> int.to_string(native.system_time_ms())
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the enforcement prerequisite owns a private workspace"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the prerequisite policy uses an absolute workspace"
  directory
}

// No verdict, including a timeout or refusal, bypasses original
// retirement: `close` joins the native exit status and the original helper
// actor monitor before anything here is allowed to conclude.
fn verdict(
  helper: exec.Helper,
  base: policy.SandboxPolicy,
  directory: String,
  label: String,
) -> Enforcement {
  let events = process.new_subject()
  let dispatched =
    exec.run(
      helper,
      exec.ExecRequest(
        argv: [serve.shell_path, "-c", ":"],
        env: [],
        cwd: directory,
        policy: Some(base),
        token: <<0:size(32)-unit(8)>>,
        demand: exec.PlatformEnforcement,
      ),
      events: events,
      waiting: 1000,
    )
  let outcome = case dispatched {
    Error(reason) -> Ok(exec.Failed(reason))
    Ok(Nil) -> probe_terminal(events)
  }
  let retired = exec.close(helper, waiting: 5000)
  assert retired == Ok(Nil)
    as "the prerequisite helper proves original retirement"
  let assert Ok(outcome) = outcome
    as "the bounded enforcement probe must answer"
  classify(outcome, label)
}

fn classify(outcome: exec.ExecEvent, label: String) -> Enforcement {
  case outcome {
    exec.Failed(exec.DegradedHelper(features:)) -> {
      decline(label, "helper hello: " <> string.join(features, " "))
      EnforcementAbsent
    }

    exec.Failed(exec.DegradedExecution(result:)) -> {
      decline(label, execution_report(result))
      EnforcementAbsent
    }

    exec.Exited(result) -> {
      assert result.code == 0 && result.signal == 0
        as "the enforced harmless prerequisite must succeed"
      EnforcementLive
    }

    exec.Failed(reason) -> {
      let reason = "enforcement prerequisite failed: " <> string.inspect(reason)
      panic as reason
    }

    exec.Output(..) ->
      panic as "the silent enforcement prerequisite produced unexpected output"
  }
}

// The skip line and the reason are two lines rather than one because the
// census in `.github/declared-skips` matches the first of them literally.
// A reason appended to that line would have to be part of the declared
// string, so every new way to degrade would edit the census; on its own
// line it can say whatever the helper said.
fn decline(label: String, detail: String) -> Nil {
  io.println_error("SKIP " <> label <> ": " <> unavailable_reason)
  io.println_error("  " <> label <> " degraded: " <> detail)
}

// The enforcement report is what the reader has to act on. Each entry is
// either a layer tag that was applied or a `skip:` entry carrying the
// helper's own sentence about why that layer is missing, so the list is
// printed verbatim rather than summarised.
fn execution_report(result: exec.ExecResult) -> String {
  let layers = case result.enforcement {
    [] -> "(no layers reported)"
    entries -> string.join(entries, ", ")
  }
  "exit "
  <> int.to_string(result.code)
  <> ", degraded flag "
  <> case result.degraded {
    True -> "set"
    False -> "clear"
  }
  <> ", enforcement: "
  <> layers
}

// Output is not completion, even for a silent requested command: the launch
// path can report diagnostics before its enforcement verdict. Each receive is
// nonblocking; the enclosing poll owns one deadline for the entire stream.
fn probe_terminal(
  events: process.Subject(exec.ExecEvent),
) -> Result(exec.ExecEvent, String) {
  let outcome =
    poll.fold_until(
      clock: poll.monotonic(),
      within: 5000,
      every: poll.Fixed(1),
      from: Ok(Nil),
      attempt: fn(output) {
        case process.receive(events, 0) {
          Error(Nil) -> poll.Pending(output)
          Ok(exec.Output(data: data, ..)) ->
            poll.Pending(probe_output(output, data))
          Ok(exec.Exited(result)) ->
            poll.Settled(#(exec.Exited(result), output))
          Ok(exec.Failed(reason)) ->
            poll.Settled(#(exec.Failed(reason), output))
        }
      },
    )
  case outcome {
    poll.Answer(#(event, Ok(Nil))) -> Ok(event)
    poll.Answer(#(_, Error(reason))) -> Error(reason)
    poll.RanOut(_) -> Error("enforcement prerequisite terminal deadline")
    poll.Failure(reason) -> Error(reason)
  }
}

// Retain only a small error, never accumulated output. Invalid UTF-8, any
// non-whitespace output, or a chunk over the diagnostic budget fails after the
// terminal event and original helper retirement have both been collected.
fn probe_output(
  previous: Result(Nil, String),
  data: BitArray,
) -> Result(Nil, String) {
  use Nil <- result.try(previous)
  use <- bool.guard(
    when: bit_array.byte_size(data) > 256,
    return: Error("enforcement prerequisite produced oversized output"),
  )
  use text <- result.try(
    bit_array.to_string(data)
    |> result.replace_error("enforcement prerequisite output is not UTF-8"),
  )
  use <- bool.guard(
    when: string.trim(text) != "",
    return: Error("enforcement prerequisite produced non-whitespace output"),
  )
  Ok(Nil)
}
