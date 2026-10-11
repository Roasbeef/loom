//// The session summary's rows from a read and from the presence roster: the
//// live jobs of the strand asked about, and the attached viewers.
////
//// A board for another strand, or none, is `Unread` and never a count of
//// zero. Both lists are bounded and say what they left out. A viewer's name is
//// principal text, so it comes out on one line and free of control
//// characters.

import core/json
import core/message
import core/usage_evidence
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/live_jobs
import session_view/session_summary.{Another, Live, Unread, Viewer, You}
import session_view/snapshot
import session_view/snapshot_view

fn job(index: Int) -> live_jobs.Job {
  live_jobs.Job(
    id: "job-" <> int.to_string(index),
    state: "running",
    started_by: "op-1",
    command: "sleep " <> int.to_string(index),
    age_ms: 2000,
    deadline_ms: 30_000,
  )
}

fn board(strand: String, count: Int, omitted: Int) -> live_jobs.Board {
  live_jobs.Board(
    strand:,
    observed_at_ms: 10_000,
    jobs: list.repeat(Nil, count) |> list.index_map(fn(_, index) { job(index) }),
    total: count + omitted,
    omitted:,
  )
}

pub fn no_board_is_unread_and_not_zero_test() {
  assert session_summary.jobs(None, "main") == Unread
}

pub fn a_board_for_another_strand_is_unread_test() {
  assert session_summary.jobs(Some(board("advisor", 2, 0)), "main") == Unread
}

pub fn a_board_for_the_strand_is_its_count_and_rows_test() {
  let assert Live(total:, rows:, omitted:) =
    session_summary.jobs(Some(board("main", 2, 0)), "main")
    as "a live board"

  assert #(total, omitted) == #(2, 0)
  assert list.length(rows) == 2
  let assert [first, ..] = rows as "a row"
  assert string.contains(first, "job-0 · running · started by op-1 · sleep 0")
  assert string.contains(first, "age 2s")
}

pub fn an_empty_board_is_live_with_no_jobs_test() {
  assert session_summary.jobs(Some(board("main", 0, 0)), "main")
    == Live(total: 0, rows: [], omitted: 0)
}

pub fn the_rows_are_bounded_and_the_rest_is_counted_test() {
  // Twelve rows held and five the daemon counted and did not send.
  let assert Live(total:, rows:, omitted:) =
    session_summary.jobs(Some(board("main", 12, 5)), "main")
    as "a live board"

  assert total == 17
  assert list.length(rows) == session_summary.max_job_rows
  assert omitted == 9
}

// --- viewers --------------------------------------------------------------------

fn peer(
  connection: String,
  name: String,
  role: snapshot.Role,
) -> snapshot_view.Peer {
  snapshot_view.Peer(
    connection,
    message.Origin("principal-" <> name, name),
    role,
  )
}

fn captured(peers: List(snapshot_view.Peer)) {
  let cut =
    snapshot.Captured(
      snapshot.Attachment(
        snapshot.Expected("session", "epoch", "incarnation"),
        "mine",
        message.Origin("principal-Alice", "Alice"),
        snapshot.Operator,
      ),
      1,
      json.Null,
      snapshot.Window([], 0, None),
      None,
    )
  let view =
    snapshot_view.View(
      [],
      dict.new(),
      dict.new(),
      dict.new(),
      message.Usage(
        0,
        0,
        0,
        0,
        None,
        None,
        0,
        message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
        usage_evidence.none(),
      ),
      snapshot_view.RunSettings("one_at_a_time", "parallel", None),
      peers,
      [],
      None,
      None,
      None,
    )
  Some(#(cut, view))
}

pub fn no_capture_has_no_viewers_test() {
  assert session_summary.viewers(None) == session_summary.Viewers([], 0)
}

pub fn each_principal_is_a_viewer_with_its_roles_and_whose_it_is_test() {
  let viewers =
    session_summary.viewers(
      captured([
        peer("mine", "Alice", snapshot.Operator),
        peer("theirs", "Bob", snapshot.Observer),
        peer("third", "Carol", snapshot.Owner),
      ]),
    )

  assert viewers.total == 3
  assert viewers.rows
    == [
      Viewer("Alice", ["operator"], 1, You),
      Viewer("Bob", ["observer"], 1, Another),
      Viewer("Carol", ["owner"], 1, Another),
    ]
}

// One person's pages are one viewer: the list names who is watching, the
// total still counts attachments, and the roles are each named once.
pub fn a_principal_attached_three_times_is_one_viewer_test() {
  let viewers =
    session_summary.viewers(
      captured([
        peer("a", "Owner", snapshot.Owner),
        peer("b", "Owner", snapshot.Operator),
        peer("mine", "Owner", snapshot.Operator),
        peer("c", "Bob", snapshot.Observer),
      ]),
    )

  assert viewers.total == 4
  assert viewers.rows
    == [
      Viewer("Owner", ["owner", "operator"], 3, You),
      Viewer("Bob", ["observer"], 1, Another),
    ]
}

pub fn another_principals_pages_are_not_yours_test() {
  let viewers =
    session_summary.viewers(
      captured([
        peer("x", "Alice", snapshot.Operator),
        peer("y", "Alice", snapshot.Operator),
      ]),
    )

  assert list.map(viewers.rows, fn(viewer) { viewer.whose }) == [Another]
}

pub fn a_name_is_one_line_free_of_controls_test() {
  let viewers =
    session_summary.viewers(
      captured([peer("mine", "Al\nice\u{1b}[31m", snapshot.Operator)]),
    )

  let assert [viewer] = viewers.rows as "one viewer"
  assert !string.contains(viewer.name, "\n")
  assert !string.contains(viewer.name, "\u{1b}")
}

pub fn the_viewers_are_bounded_and_counted_test() {
  let peers =
    list.repeat(Nil, 40)
    |> list.index_map(fn(_, index) {
      peer(
        "c" <> int.to_string(index),
        "V" <> int.to_string(index),
        snapshot.Observer,
      )
    })
  let viewers = session_summary.viewers(captured(peers))

  assert list.length(viewers.rows) == session_summary.max_viewer_rows
  assert viewers.total == 40
}
