import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui
import tui/daemon/protocol as control_protocol
import tui/view_link

const ticket = "6f1d0c9e2b7a4f3a8c5e1d0b9a7f6e5d4c3b2a1908f7e6d5c4b3a29180f7e6d5"

const link =
  "http://127.0.0.1:4000/ui/sessions/0198c0de-0000-7000-8000-000000000001?ticket="
  <> ticket

// Everything `deliver` emits, in order, read back from the subject the test's
// printer sent it to.
fn emitted(subject: Subject(view_link.Output)) -> List(view_link.Output) {
  case process.receive(subject, 0) {
    Ok(output) -> [output, ..emitted(subject)]
    Error(Nil) -> []
  }
}

fn deliver_with(
  delivery: view_link.Delivery,
  open: fn(String) -> Result(Nil, String),
) -> List(view_link.Output) {
  let subject = process.new_subject()
  view_link.deliver(link, delivery, open, process.send(subject, _))
  emitted(subject)
}

pub fn view_arguments_parse_test() {
  let assert Ok(printed) = tui.view_request(["--session", "s"])
  assert printed.session == Some("s")
  assert printed.delivery == view_link.PrintLink

  let assert Ok(opened) = tui.view_request(["--open", "--session", "s"])
  assert opened.session == Some("s")
  assert opened.delivery == view_link.OpenInBrowser

  // `--open` has no value, so it must not take the next flag with it, and
  // the shared local options still reach the daemon options.
  let assert Ok(request) =
    tui.view_request(["--session", "s", "--open", "--state-dir", "/state"])
  assert request.delivery == view_link.OpenInBrowser
  assert request.options.state_directory == "/state"

  // No `--session` is the home, which opens like any other link.
  let assert Ok(home) = tui.view_request(["--open"])
  assert home.session == None
  assert home.delivery == view_link.OpenInBrowser

  // A `--session` with nothing after it is a forgotten id, and never the home.
  let assert Error(reason) = tui.view_request(["--session", "--open"])
    as "--open is not a session id"
  assert string.contains(reason, "needs a session id")
  let assert Error(_) = tui.view_request(["--open", "--session"])
    as "a trailing --session has no id"
  let assert Error(_) = tui.view_request(["--session", "s", "--opened", "x"])
    as "an unknown flag is refused, not taken for --open"
}

// Protocol-change/065, the third question: the home is a link for oneself, so
// it is an operator's page unless `--observe` asks for a read-only one, while
// a session's link keeps the observer default because it is the one a person
// hands out. `--operate` and `--observe` together are refused.
pub fn the_home_defaults_to_an_operators_page_test() {
  let assert Ok(home) = tui.view_request([])
  assert home.session == None
  assert home.page == control_protocol.OperatorPage
  assert home.delivery == view_link.PrintLink

  let assert Ok(observed) = tui.view_request(["--observe"])
  assert observed.session == None
  assert observed.page == control_protocol.ObserverPage

  let assert Ok(operated) = tui.view_request(["--operate", "--open"])
  assert operated.session == None
  assert operated.page == control_protocol.OperatorPage

  let assert Ok(session) = tui.view_request(["--session", "s"])
  assert session.page == control_protocol.ObserverPage
  let assert Ok(watching) = tui.view_request(["--observe", "--session", "s"])
  assert watching.page == control_protocol.ObserverPage
  let assert Ok(driving) = tui.view_request(["--session", "s", "--operate"])
  assert driving.page == control_protocol.OperatorPage

  let assert Error(reason) = tui.view_request(["--operate", "--observe"])
  assert string.contains(reason, "not both")
}

// `loom ui` and `loom --ui` with the daemon options around them reach the
// same parser without a session, and the daemon options still apply.
pub fn the_home_takes_the_daemon_options_in_any_order_test() {
  let assert Ok(home) =
    tui.launch_view(["ui", "--state-dir", "/s", "--open", "--observe"])
  assert home.session == None
  assert home.options.state_directory == "/s"
  assert home.page == control_protocol.ObserverPage
  assert home.delivery == view_link.OpenInBrowser

  let assert Ok(spelled) = tui.launch_view(["--state-dir", "/s", "--ui"])
  assert spelled.session == None
  assert spelled.page == control_protocol.OperatorPage
}

pub fn view_page_and_delivery_parse_together_test() {
  let assert Ok(observer) = tui.view_request(["--session", "s"])
  assert observer.page == control_protocol.ObserverPage
  let assert Ok(operator) = tui.view_request(["--operate", "--session", "s"])
  assert operator.page == control_protocol.OperatorPage
  assert operator.delivery == view_link.PrintLink
    as "--operate alone asks for no browser"

  // Both switches take no value, in either order, and each keeps its own
  // meaning: `--operate` sets the page's ceiling, `--open` the delivery.
  let assert Ok(both) =
    tui.view_request(["--operate", "--session", "s", "--open"])
  assert both.page == control_protocol.OperatorPage
  assert both.delivery == view_link.OpenInBrowser
  let assert Ok(swapped) =
    tui.view_request(["--open", "--operate", "--session", "s"])
  assert swapped.page == control_protocol.OperatorPage
  assert swapped.delivery == view_link.OpenInBrowser
  assert swapped.session == Some("s")
}

// `loom ui` is the command and `--ui` its older spelling. Both reach the one
// parser, so each takes the daemon options in any order around it.
pub fn ui_subcommand_routes_to_the_view_test() {
  let assert Ok(plain) = tui.launch_view(["ui", "--session", "x"])
  assert plain.session == Some("x")
  assert plain.page == control_protocol.ObserverPage
  assert plain.delivery == view_link.PrintLink

  let assert Ok(operated) =
    tui.launch_view(["ui", "--state-dir", "/s", "--session", "x", "--operate"])
  assert operated.session == Some("x")
  assert operated.options.state_directory == "/s"
  assert operated.page == control_protocol.OperatorPage

  let assert Error(reason) =
    tui.launch_view(["ui", "--state-dir", "/s", "--session"])
    as "a --session with no id is refused, not read as the home"
  assert string.contains(reason, "loom ui needs a session id")
}

pub fn ui_alias_reads_options_in_any_order_test() {
  let assert Ok(first) = tui.launch_view(["--ui", "--session", "x"])
  assert first.session == Some("x")

  // The live drive that motivated the subcommand: the daemon options came
  // before `--ui`, and the launcher refused `--ui` as an unknown local option.
  let assert Ok(late) =
    tui.launch_view([
      "--state-dir", "/s", "--config", "/s/loom.toml", "--ui", "--session", "x",
    ])
  assert late.session == Some("x")
  assert late.options.state_directory == "/s"
  assert late.options.config == "/s/loom.toml"

  let assert Ok(opened) =
    tui.launch_view(["--session", "x", "--open", "--ui", "--operate"])
  assert opened.delivery == view_link.OpenInBrowser
  assert opened.page == control_protocol.OperatorPage

  let assert Error(_) = tui.launch_view(["--state-dir", "/s", "--session", "x"])
    as "without ui or --ui the launch is the terminal's, not the view's"
}

pub fn opener_is_chosen_per_platform_test() {
  assert view_link.opener_for(Ok("macos-arm64")) == Ok("open")
  assert view_link.opener_for(Ok("macos-x86_64")) == Ok("open")
  assert view_link.opener_for(Ok("linux-x86_64")) == Ok("xdg-open")
  assert view_link.opener_for(Ok("linux-arm64")) == Ok("xdg-open")
  let assert Error(_) = view_link.opener_for(Ok("freebsd-x86_64"))
    as "an unknown platform opens nothing"
  let assert Error(_) = view_link.opener_for(Error(Nil))
    as "a loom run without its launcher does not guess"
}

pub fn platform_opener_passes_the_link_as_one_argument_test() {
  let calls = process.new_subject()
  let open =
    view_link.platform_opener(
      Ok("linux-x86_64"),
      fn(name) { Ok("/usr/bin/" <> name) },
      fn(executable, arguments) {
        process.send(calls, #(executable, arguments))
        Ok(view_link.Exited(0))
      },
    )

  assert open(link) == Ok(Nil)
  assert process.receive(calls, 0) == Ok(#("/usr/bin/xdg-open", [link]))

  let open =
    view_link.platform_opener(
      Ok("macos-arm64"),
      fn(name) { Ok("/usr/bin/" <> name) },
      fn(executable, arguments) {
        process.send(calls, #(executable, arguments))
        Ok(view_link.StillRunning)
      },
    )
  assert open(link) == Ok(Nil)
    as "an opener still running is a browser that started"
  assert process.receive(calls, 0) == Ok(#("/usr/bin/open", [link]))
}

pub fn failing_opener_still_prints_the_link_test() {
  let missing =
    view_link.platform_opener(
      Ok("linux-x86_64"),
      fn(name) { Error("not_executable " <> name) },
      fn(_, _) { Ok(view_link.Exited(0)) },
    )
  let refused =
    view_link.platform_opener(
      Ok("linux-x86_64"),
      fn(name) { Ok("/usr/bin/" <> name) },
      fn(_, _) { Ok(view_link.Exited(3)) },
    )

  // A launcher whose own error text carries the link, as an echoing opener
  // or a crash report could. The note must still hold no part of it.
  let crashed =
    view_link.platform_opener(
      Ok("macos-arm64"),
      fn(name) { Ok("/usr/bin/" <> name) },
      fn(_, arguments) {
        Error("could not run " <> string.join(arguments, " "))
      },
    )
  let unknown =
    view_link.platform_opener(
      Error(Nil),
      fn(name) { Ok("/usr/bin/" <> name) },
      fn(_, _) { Ok(view_link.Exited(0)) },
    )

  list.each([missing, refused, crashed, unknown], fn(open) {
    let assert [view_link.Link(printed), view_link.Note(note)] =
      deliver_with(view_link.OpenInBrowser, open)
      as "the link is printed first and the failure is a note"
    assert printed == link
    assert !string.contains(note, ticket)
    assert string.contains(note, "open the link above")
  })

  let assert [_, view_link.Note(note)] =
    deliver_with(view_link.OpenInBrowser, refused)
  assert string.contains(note, "xdg-open exited with status 3")
}

pub fn printing_alone_never_runs_the_opener_test() {
  let opened = process.new_subject()
  let outputs =
    deliver_with(view_link.PrintLink, fn(argument) {
      process.send(opened, argument)
      Ok(Nil)
    })
  assert outputs == [view_link.Link(link)]
  assert process.receive(opened, 0) == Error(Nil)

  assert deliver_with(view_link.OpenInBrowser, fn(_) { Ok(Nil) })
    == [view_link.Link(link)]
}

pub fn launch_reports_exit_and_stops_waiting_at_the_deadline_test() {
  assert view_link.launch_within("/bin/sh", ["-c", "exit 3"], 5000)
    == Ok(view_link.Exited(3))
  assert view_link.launch_within("/bin/sh", ["-c", "exit 0"], 5000)
    == Ok(view_link.Exited(0))

  // An opener that runs the browser in the foreground outlives the wait,
  // and that is a browser starting rather than a failure.
  assert view_link.launch_within("/bin/sh", ["-c", "sleep 2"], 100)
    == Ok(view_link.StillRunning)
}
