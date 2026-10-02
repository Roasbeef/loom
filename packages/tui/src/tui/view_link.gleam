//// How `loom ui` hands the web view's link to the person
//// (protocol-change/051, addendum "Opening the browser").
////
//// The link carries a single-use ticket, so where the link goes is the whole
//// question this module answers. It is printed to standard output every
//// time, and printed first: a headless machine or an SSH session has no
//// browser to open, and the printed line is then the only way in. With
//// `--open` the link is also handed to the platform's opener, `open` on
//// macOS and `xdg-open` on Linux, as a single argument with no shell
//// between. An opener that is missing, fails or exits non-zero costs a note
//// on standard error and nothing else; the link above it still works, and
//// the command still succeeds.
////
//// Nothing here writes the link anywhere but standard output and the
//// opener's argument vector. A note is built only from the opener's name,
//// its exit status or the platform name, never from text the opener or the
//// operating system produced, so a failure cannot carry the ticket into a message a person
//// might paste into a bug report.
////
//// The platform is read from `LOOM_BUILD_PLATFORM`, which every launcher
//// Loom builds (`bin/loom`, the shipment and the release) exports as
//// `macos-<arch>` or `linux-<arch>`. Reading it costs no FFI, and it is the
//// same fact `loom version` and `loom update` already trust. A `loom` run
//// without a launcher has no such variable, and `--open` then prints a note
//// instead of guessing: on some Linux distributions `/bin/open` is `openvt`,
//// so probing for whichever opener exists would run the wrong program.
////
//// `deliver` takes the opener and the printer as functions, so the tests
//// choose the platform and the opener's behaviour without a browser.

import gleam/int
import gleam/result
import host/bootstrap as host
import tui/internal/ffi_terminal
import weft

/// What `loom ui` does with a minted link.
pub type Delivery {
  /// Print the link and nothing else. The default.
  PrintLink

  /// Print the link, then hand it to the platform's opener (`--open`).
  OpenInBrowser
}

/// One line `deliver` produces, by the stream it belongs on.
pub type Output {
  /// The link itself, for standard output.
  Link(link: String)

  /// A note about the opener, for standard error. It never holds the link.
  Note(note: String)
}

/// How a launched opener ended, as far as `loom` waited to see.
pub type Launched {
  /// The opener exited with this status.
  Exited(status: Int)

  /// The opener was still running when the wait ended.
  ///
  /// `open` and a desktop's `xdg-open` hand the link to a running browser
  /// and exit at once. `xdg-open` outside a known desktop runs the browser
  /// itself and exits only when the browser does, so an opener still
  /// running is a browser that started, not a failure.
  StillRunning
}

/// How long `loom ui --open` waits for the opener before it exits and
/// leaves the opener running.
pub const opener_wait_ms = 5000

/// Names the command that opens a link in the default browser on a
/// platform, as `LOOM_BUILD_PLATFORM` spells it.
///
/// ## Examples
///
/// ```gleam
/// assert view_link.opener_for(Ok("macos-arm64")) == Ok("open")
/// assert view_link.opener_for(Ok("linux-x86_64")) == Ok("xdg-open")
/// let assert Error(_) = view_link.opener_for(Error(Nil))
/// ```
pub fn opener_for(platform: Result(String, Nil)) -> Result(String, String) {
  case platform {
    Ok("macos-" <> _arch) -> Ok("open")
    Ok("linux-" <> _arch) -> Ok("xdg-open")
    Ok(other) -> Error("no browser opener is known for platform " <> other)
    Error(Nil) ->
      Error(
        "this loom was not started by its launcher, so its platform is unknown",
      )
  }
}

/// Prints the link, then opens it when asked, reporting an opener's failure
/// as a note.
///
/// The link is emitted before the opener runs, so a person whose opener
/// hangs or fails already has it on screen. The note says why the browser
/// did not open and nothing more.
///
/// ## Examples
///
/// ```gleam
/// view_link.deliver(link, view_link.OpenInBrowser, opener, fn(output) {
///   case output {
///     view_link.Link(link) -> io.println(link)
///     view_link.Note(note) -> io.println_error(note)
///   }
/// })
/// ```
pub fn deliver(
  link: String,
  delivery: Delivery,
  open: fn(String) -> Result(Nil, String),
  emit: fn(Output) -> Nil,
) -> Nil {
  emit(Link(link))
  case delivery {
    PrintLink -> Nil
    OpenInBrowser ->
      case open(link) {
        Ok(Nil) -> Nil
        Error(reason) ->
          emit(Note(
            "could not open a browser ("
            <> reason
            <> "); open the link above instead",
          ))
      }
  }
}

/// Builds the opener for a platform from a way to find an executable and a
/// way to launch one.
///
/// Every error it returns is assembled here from the opener's name and exit
/// status. The finder's and the launcher's own error text is dropped on
/// purpose: it comes from outside this module, and the one guarantee a note
/// makes is that it holds no part of the link.
///
/// ## Examples
///
/// ```gleam
/// let open =
///   view_link.platform_opener(Ok("linux-x86_64"), host.find_executable, launch)
/// open("http://127.0.0.1:4000/ui/sessions/…")
/// ```
pub fn platform_opener(
  platform: Result(String, Nil),
  find: fn(String) -> Result(String, String),
  launch: fn(String, List(String)) -> Result(Launched, String),
) -> fn(String) -> Result(Nil, String) {
  fn(link) {
    use name <- result.try(opener_for(platform))
    use executable <- result.try(
      find(name)
      |> result.map_error(fn(_) { name <> " was not found on PATH" }),
    )
    case launch(executable, [link]) {
      Ok(Exited(0)) | Ok(StillRunning) -> Ok(Nil)
      Ok(Exited(status)) ->
        Error(name <> " exited with status " <> int.to_string(status))
      Error(_) -> Error(name <> " could not be started")
    }
  }
}

/// The opener `loom ui --open` uses: the platform its launcher exported,
/// found on `PATH`, and waited on for at most `opener_wait_ms`.
///
/// ## Examples
///
/// ```gleam
/// view_link.deliver(link, delivery, view_link.system_opener(), print)
/// ```
pub fn system_opener() -> fn(String) -> Result(Nil, String) {
  platform_opener(
    host.getenv("LOOM_BUILD_PLATFORM"),
    host.find_executable,
    fn(executable, arguments) {
      launch_within(executable, arguments, opener_wait_ms)
    },
  )
}

/// Runs an opener through `ffi_terminal.run_forwarding` and waits for it
/// for at most `within_ms`.
///
/// The opener runs in a one-task weft run with a deadline, so the worker
/// that owns the opener's port belongs to weft's scope and is joined before
/// this returns. When the deadline cuts the wait short the port closes and
/// the opener keeps running: closing a port closes the opener's pipes and
/// sends it no signal. That is what a foreground `xdg-open` needs, because
/// it is the browser. A browser that later writes to the closed pipe gets
/// `EPIPE`, and browsers ignore `SIGPIPE`.
///
/// Whatever the opener prints goes to this process's standard output, as
/// `run_forwarding` does for `loom ext`. `open` prints nothing on success;
/// an `xdg-open` that fails may echo the link, onto the terminal the link
/// is already printed on.
///
/// ## Examples
///
/// ```gleam
/// view_link.launch_within("/usr/bin/open", [link], view_link.opener_wait_ms)
/// ```
pub fn launch_within(
  executable: String,
  arguments: List(String),
  within_ms: Int,
) -> Result(Launched, String) {
  launch_with(ffi_terminal.run_forwarding, executable, arguments, within_ms)
}

/// The opener the terminal hands a file to while it owns the screen: the
/// platform's opener, as `system_opener` finds it, run with its output
/// dropped (`ffi_terminal.run_quiet`) so nothing it writes lands over the
/// frame.
///
/// ## Examples
///
/// ```gleam
/// let open = view_link.quiet_opener()
/// open("/var/folders/…/loom-images/image-1.png")
/// ```
pub fn quiet_opener() -> fn(String) -> Result(Nil, String) {
  platform_opener(
    host.getenv("LOOM_BUILD_PLATFORM"),
    host.find_executable,
    fn(executable, arguments) {
      launch_with(ffi_terminal.run_quiet, executable, arguments, opener_wait_ms)
    },
  )
}

// One opener run under a deadline, by whichever runner says what becomes
// of the opener's output.
fn launch_with(
  run: fn(String, List(String)) -> Result(Int, String),
  executable: String,
  arguments: List(String),
  within_ms: Int,
) -> Result(Launched, String) {
  let outcomes =
    weft.new([fn() { run(executable, arguments) }])
    |> weft.deadline(within_ms)
    |> weft.start

  // A one-task run yields exactly one outcome. The impossible shapes are
  // answered rather than asserted away, because a wrong account from the
  // engine should cost a note, not the link the person already has.
  case outcomes {
    [weft.Completed(value: status, ..)] -> Ok(Exited(status))
    [weft.Failed(error:, ..)] -> Error(error)
    [weft.Abandoned(..)] -> Ok(StillRunning)
    [weft.Crashed(..)] -> Error("opener worker crashed")

    // Only a managed task can lose or leave unconfirmed a drain proof, and
    // this run carries none; the arms are exhaustiveness, not cases.
    //
    // A task that never started only happens with no time to start it, and
    // is an opener that did not run, so it is an error too.
    [weft.DrainProofLost(..)]
    | [weft.CancellationUnconfirmed(..)]
    | [weft.NeverStarted(..)] -> Error("opener run produced no account")
    [] | [_, _, ..] -> Error("opener run produced no account")
  }
}
