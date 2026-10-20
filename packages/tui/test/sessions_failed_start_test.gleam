//// A reservation whose start failed (protocol-change/093): how the terminal
//// reads the daemon's `failure` member and how `loom sessions list` shows it.
////
//// The wire keeps `state: "reserved"`, so every case here is about the one
//// optional member: present and well formed, absent as an older daemon sends
//// it, and present but malformed, which must read as a plain reservation and
//// never fail the row.

import gleam/list
import gleam/option
import gleam/string
import tui
import tui/daemon/protocol

const session = "0198c0de-0000-7000-8000-000000000001"

const census =
  "executor exec declares toolchain codemode but its census reports []"

fn reply(status: String) -> String {
  "{\"v\":2,\"reply_to\":3,\"event\":\"sessions.get\",\"body\":{\"session_id\":\""
  <> session
  <> "\",\"workspace\":\"exec:repo\",\"name\":\"draft\",\"created_at\":1760000000000,\"status\":"
  <> status
  <> "}}"
}

fn decoded(status: String) -> protocol.Lifecycle {
  let assert Ok(protocol.Answer(3, "sessions.get", protocol.SessionReply(row))) =
    protocol.decode(reply(status))
    as "the reply decodes whatever the failure member holds"
  row.status
}

fn failure_of(member: String) -> protocol.Lifecycle {
  decoded("{\"state\":\"reserved\",\"failure\":" <> member <> "}")
}

fn row(status: protocol.Lifecycle) -> protocol.Session {
  protocol.Session(
    session_id: session,
    workspace: "/w",
    name: "n",
    created_at: 0,
    status:,
    subtitle: option.None,
    executor: option.None,
  )
}

pub fn a_reserved_status_with_a_failure_reads_as_a_failed_start_test() {
  assert failure_of("{\"reason\":\"" <> census <> "\",\"at\":1760000000123}")
    == protocol.FailedStart(census, 1_760_000_000_123)
}

pub fn an_older_daemons_reserved_status_stays_reserved_test() {
  assert decoded("{\"state\":\"reserved\"}") == protocol.Reserved
}

pub fn a_malformed_failure_reads_as_a_plain_reservation_test() {
  // Each is a failure a newer daemon would never send; none may fail the row.
  list.each(
    [
      "\"not an object\"",
      "{}",
      "{\"reason\":\"why\"}",
      "{\"at\":1}",
      "{\"reason\":\"\",\"at\":1}",
      "{\"reason\":\"two\\nlines\",\"at\":1}",
      "{\"reason\":\"carriage\\rreturn\",\"at\":1}",
      "{\"reason\":\"why\",\"at\":-1}",
      "{\"reason\":\"why\",\"at\":\"soon\"}",
      "{\"reason\":7,\"at\":1}",
    ],
    fn(member) {
      assert failure_of(member) == protocol.Reserved
    },
  )
}

pub fn an_oversized_failure_reads_as_a_plain_reservation_test() {
  let at_limit = string.repeat("x", 512)
  assert failure_of("{\"reason\":\"" <> at_limit <> "\",\"at\":1}")
    == protocol.FailedStart(at_limit, 1)
  assert failure_of("{\"reason\":\"" <> at_limit <> "x\",\"at\":1}")
    == protocol.Reserved
}

// A failed start is stuck and says why, so the default view shows it where it
// hides an ordinary reservation.
pub fn a_failed_start_is_listed_by_default_with_its_reason_test() {
  let failed = row(protocol.FailedStart(census, 5))
  let printed = tui.format_listing([failed], tui.ResidentOnly, Ok(Nil))
  assert string.contains(printed, "failed")
  assert string.contains(printed, "failed to start: " <> census)
  assert !string.contains(printed, "not shown")

  let hidden =
    tui.format_listing([row(protocol.Reserved)], tui.ResidentOnly, Ok(Nil))
  assert !string.contains(hidden, session)
}

// Scripts split the plain format on whitespace, so the state token is one word
// and the reason trails the name.
pub fn the_plain_listing_keeps_the_state_token_and_trails_the_reason_test() {
  let printed =
    tui.format_listing(
      [row(protocol.FailedStart("no census", 5))],
      tui.ResidentOnly,
      Error("not a tty"),
    )
  assert printed == session <> "  failed  /w  n  failed to start: no census"
}

pub fn a_hostile_reason_is_drawn_as_one_clean_line_test() {
  let printed =
    tui.format_listing(
      [row(protocol.FailedStart("one\ntwo\u{1b}[31m red", 5))],
      tui.ResidentOnly,
      Error("not a tty"),
    )
  assert !string.contains(printed, "\u{1b}")
  assert list.length(string.split(printed, "\n")) == 1
}
