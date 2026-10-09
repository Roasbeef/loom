//// Tests for `loom sessions list`: the `--all` flag, the default filter
//// down to the resident track, the hidden-count note a terminal prints
//// when rows are held back, and the plain format scripts already parse.
////
//// `tui.format_listing` is the seam: it takes the daemon's full page of
//// rows, a `Showing`, and a stand-in for `ffi_terminal.require_terminal`,
//// so every case here runs with no daemon and no real terminal.

import gleam/list
import gleam/option
import gleam/string
import tui
import tui/daemon/protocol as control_protocol

fn session(
  id: String,
  status: control_protocol.Lifecycle,
) -> control_protocol.Session {
  control_protocol.Session(
    session_id: id,
    workspace: "/w",
    name: "n",
    created_at: 0,
    status:,
    subtitle: option.None,
    executor: option.None,
  )
}

fn catalogue() -> List(control_protocol.Session) {
  [
    session("s-resident", control_protocol.Resident("i")),
    session("s-saved-1", control_protocol.Saved),
    session("s-saved-2", control_protocol.Saved),
    session("s-saved-3", control_protocol.Saved),
    session("s-saved-4", control_protocol.Saved),
    session("s-reserved", control_protocol.Reserved),
  ]
}

// The default view keeps the resident row and hides every saved and
// reserved one, both in the table body and the row count the hidden-count
// note reports.
pub fn default_hides_saved_and_reserved_test() {
  let printed = tui.format_listing(catalogue(), tui.ResidentOnly, Ok(Nil))
  assert string.contains(printed, "s-resident")
  assert !string.contains(printed, "s-saved-1")
  assert !string.contains(printed, "s-reserved")
}

// The trailing line counts each hidden lifecycle by its own word, in the
// wording the owner asked for.
pub fn hidden_count_line_wording_test() {
  let printed = tui.format_listing(catalogue(), tui.ResidentOnly, Ok(Nil))
  let assert Ok(note) = string.split(printed, "\n") |> list.last
  assert note == "4 saved, 1 reserved not shown (use --all)"
}

// No saved or reserved row at all leaves nothing to count, so the note is
// never appended.
pub fn hidden_count_line_absent_when_nothing_hidden_test() {
  let printed =
    tui.format_listing(
      [session("s-resident", control_protocol.Resident("i"))],
      tui.ResidentOnly,
      Ok(Nil),
    )
  assert !string.contains(printed, "not shown")
}

// An empty resident track still says so, and still reports what --all
// would add.
pub fn no_resident_sessions_still_reports_hidden_test() {
  let printed =
    tui.format_listing(
      [session("s-saved", control_protocol.Saved)],
      tui.ResidentOnly,
      Ok(Nil),
    )
  assert printed == "no resident sessions\n1 saved not shown (use --all)"
}

// `--all` (`Every`) shows every row and never appends a hidden-count note,
// because nothing was hidden to report.
pub fn all_shows_everything_test() {
  let printed = tui.format_listing(catalogue(), tui.Every, Ok(Nil))
  assert string.contains(printed, "s-resident")
  assert string.contains(printed, "s-saved-1")
  assert string.contains(printed, "s-reserved")
  assert !string.contains(printed, "not shown")
}

// Off a terminal the plain format is exactly the rows the filter kept, one
// per line, byte for byte, with no trailing note to trip up a parser.
pub fn plain_format_is_byte_identical_with_no_count_line_test() {
  let printed =
    tui.format_listing(catalogue(), tui.ResidentOnly, Error("not a tty"))
  assert printed == "s-resident  resident  /w  n"
}

// `--all` off a terminal is the same one-line-per-row format over the
// whole catalogue, still with no count line.
pub fn plain_format_all_lists_every_row_test() {
  let printed = tui.format_listing(catalogue(), tui.Every, Error("not a tty"))
  assert printed
    == "s-resident  resident  /w  n\n"
    <> "s-saved-1  saved  /w  n\n"
    <> "s-saved-2  saved  /w  n\n"
    <> "s-saved-3  saved  /w  n\n"
    <> "s-saved-4  saved  /w  n\n"
    <> "s-reserved  reserved  /w  n"
  assert !string.contains(printed, "not shown")
}

// `loom sessions list --all` parses to the widened `Showing`; plain `list`
// stays narrowed to the resident track. `--all` is taken out before the
// shared local options see the remaining flags, so it composes with them
// in either order.
pub fn all_flag_parses_to_every_test() {
  let assert Ok(tui.ListRegistrations(showing: tui.Every)) =
    tui.launch_sessions(["list", "--all"])
  let assert Ok(tui.ListRegistrations(showing: tui.ResidentOnly)) =
    tui.launch_sessions(["list"])
  let assert Ok(tui.ListRegistrations(showing: tui.Every)) =
    tui.launch_sessions(["list", "--all", "--state-dir", "/tmp/x"])
}

// The help text documents `--all` and names all three lifecycles a person
// can see across the default view and the widened one.
pub fn help_mentions_all_and_lifecycles_test() {
  let assert Error(reason) = tui.launch_sessions(["bogus"])
  assert string.contains(reason, "--all")
  assert string.contains(reason, "resident")
  assert string.contains(reason, "saved")
  assert string.contains(reason, "reserved")
}
