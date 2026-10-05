//// A page's read of its session's workspace (protocol-change/051, the
//// addendum on the worktree read).
////
//// The gateway admits `worktree_diff` to an `Owner` binding, and no page
//// carries `Owner`, so the page reads through the daemon's own observation
//// under an admission of its own. These tests pin that admission: who is
//// handed the capability, who is answered when it is called (an owner and an
//// operator, never an observer, never a page whose standing has since been
//// revoked or whose ceiling is an observer's), that a refused page never runs
//// the observation, that the answer is the daemon's validated board and not a
//// forwarded error, that the page's own bounds hold over what the daemon
//// sends, and that asking returns at once while the observation is still
//// running.

import client/daemon/ui_socket
import core/json
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/worktree_view
import storage/access
import web_view/worktrees

fn principal() -> access.Principal {
  access.Principal(id: "p", display_name: "P", kind: access.MemberPrincipal)
}

// A check that still passes with `authority`, as the page's attachment check
// answers while its UI session is open and its credential authenticates.
fn standing(
  authority: access.Authority,
) -> fn() -> Result(#(access.Principal, access.Authority), String) {
  fn() { Ok(#(principal(), authority)) }
}

// A reservation that always succeeds, for a test that is not about the
// allowance.
fn allowed() -> Result(Nil, Nil) {
  Ok(Nil)
}

fn revoked() -> Result(#(access.Principal, access.Authority), String) {
  Error("access revoked")
}

fn file(path: String, patch: String) -> json.JsonValue {
  json.Object([
    #("path", json.String(path)),
    #("index_status", json.String(" ")),
    #("worktree_status", json.String("M")),
    #("patch", json.String(patch)),
    #("kind", json.String("text")),
    #("extent", json.String("complete")),
  ])
}

// The daemon's board as `worktree_diff.to_json` encodes it, with `entries`
// and the census the caller names.
fn board(
  repository: String,
  entries: List(json.JsonValue),
  total: Int,
  omitted: Int,
) -> json.JsonValue {
  json.Object([
    #("source", json.String("git")),
    #(
      "committed",
      json.Object([
        #("message", json.String("0 commits since session start")),
        #("patch", json.String("")),
        #("extent", json.String("complete")),
      ]),
    ),
    #("observed_at_ms", json.Int(7)),
    #("repository", json.String(repository)),
    #("entries", json.Array(entries)),
    #("total", json.Int(total)),
    #("omitted", json.Int(omitted)),
    #("extent", json.String("complete")),
  ])
}

fn one_file() -> json.JsonValue {
  board("head", [file("src/a.gleam", "@@ -1 +1 @@\n-a\n+b")], 1, 0)
}

// An observation that reports it ran, so a test can tell a refusal that never
// started it from an answer that did.
fn counting(
  ran: process.Subject(Nil),
  result: Result(json.JsonValue, String),
) -> fn() -> Result(json.JsonValue, String) {
  fn() {
    process.send(ran, Nil)
    result
  }
}

fn board_of(read: worktrees.Read) -> worktree_view.Board {
  let assert worktrees.Seen(board) = read as "the page was shown the board"
  board
}

// Only a page that may operate is handed the capability. An observer's page
// holds none, so it draws the tool edits and has nothing to call.
pub fn only_an_owners_or_operators_page_is_handed_the_capability_test() {
  let start = fn(_deliver) { Nil }
  assert ui_socket.worktree_capability(ui_socket.Observing, start) == None
  let assert Some(_) = ui_socket.worktree_capability(ui_socket.Operating, start)
  let assert Some(_) = ui_socket.worktree_capability(ui_socket.Owning, start)
}

// An owner and an operator are shown the board, with the page's standing
// capped at Operator as every page's is.
pub fn an_owner_and_an_operator_are_admitted_test() {
  list.each(
    [
      #(access.Owner, access.Operator),
      #(access.Participant(access.Operator), access.Operator),
    ],
    fn(standing_and_ceiling) {
      let ran = process.new_subject()
      let read =
        ui_socket.worktree_answer(
          standing(standing_and_ceiling.0),
          standing_and_ceiling.1,
          allowed,
          counting(ran, Ok(one_file())),
        )
      assert process.receive(ran, 0) == Ok(Nil)
      assert board_of(read).files != []
    },
  )
}

// An observer is refused and the observation never runs, whether the member is
// an observer or an operator whose page was minted with an observer's ceiling.
pub fn an_observer_is_refused_without_running_the_observation_test() {
  list.each(
    [
      #(access.Participant(access.Observer), access.Operator),
      #(access.Participant(access.Observer), access.Observer),
      #(access.Participant(access.Operator), access.Observer),
      #(access.Owner, access.Observer),
    ],
    fn(standing_and_ceiling) {
      let ran = process.new_subject()
      let read =
        ui_socket.worktree_answer(
          standing(standing_and_ceiling.0),
          standing_and_ceiling.1,
          allowed,
          counting(ran, Ok(one_file())),
        )
      assert read == worktrees.Declined
      assert process.receive(ran, 0) == Error(Nil)
    },
  )
}

// The standing is read at every call. A page that was admitted and whose
// grant has since been revoked, or whose UI session has ended, is refused at
// its next read and the observation does not run.
pub fn a_revoked_page_is_refused_at_its_next_read_test() {
  let ran = process.new_subject()
  let read =
    ui_socket.worktree_answer(
      revoked,
      access.Operator,
      allowed,
      counting(ran, Ok(one_file())),
    )

  assert read == worktrees.Declined
  assert process.receive(ran, 0) == Error(Nil)
}

// A failed observation is `Unreadable` and says nothing else: its text can be
// a repository's own words, and none of it is forwarded to a page.
pub fn a_failed_observation_is_unreadable_and_its_text_is_not_forwarded_test() {
  let read =
    ui_socket.worktree_answer(
      standing(access.Owner),
      access.Operator,
      allowed,
      fn() { Error("fatal: <script>alert(1)</script> in /secret/path") },
    )

  assert read == worktrees.Unreadable
}

// What is not a board the page accepts is `Unreadable` too: an answer that is
// not an object, one that breaks the census, and one past the page's own
// bounds. The daemon bounds its board, and the page does not rely on that.
pub fn an_answer_that_breaks_the_pages_bounds_is_unreadable_test() {
  let owner = standing(access.Owner)
  let read = fn(answer) {
    ui_socket.worktree_answer(owner, access.Operator, allowed, fn() {
      Ok(answer)
    })
  }

  assert read(json.String("not a board")) == worktrees.Unreadable

  // A census that does not add up.
  assert read(board("head", [file("a", "@@ -1 +1 @@\n-a\n+b")], 5, 0))
    == worktrees.Unreadable

  // More than twenty-four files.
  let many =
    list.index_map(list.repeat(Nil, 25), fn(_, n) {
      file("f" <> string.inspect(n), "")
    })
  assert read(board("head", many, 25, 0)) == worktrees.Unreadable

  // A patch past sixteen kilobytes.
  let huge = string.repeat("+x\n", 6000)
  assert read(board("head", [file("big", huge)], 1, 0)) == worktrees.Unreadable

  // A repository state the page does not know.
  assert read(board("elsewhere", [], 0, 0)) == worktrees.Unreadable
}

// A workspace that is not a checkout is a board, not a failure: the daemon
// says so and the page falls back to the agent's edits with a sentence.
pub fn a_workspace_that_is_not_a_checkout_is_a_board_test() {
  let read =
    ui_socket.worktree_answer(
      standing(access.Owner),
      access.Operator,
      allowed,
      fn() { Ok(board("not_repository", [], 0, 0)) },
    )

  assert board_of(read).repository == "not_repository"
}

// A path under a hidden directory, with markup in it, reaches the page as
// data: the board holds the string as given and nothing decodes or filters it.
pub fn a_hidden_directory_path_with_markup_survives_as_data_test() {
  let path = ".claude/worktrees/x/<b>y</b>.toml"
  let read =
    ui_socket.worktree_answer(
      standing(access.Owner),
      access.Operator,
      allowed,
      fn() { Ok(board("head", [file(path, "@@ -1 +1 @@\n-a\n+b")], 1, 0)) },
    )

  let assert [only] = board_of(read).files as "one file"
  assert only.path == path
}

// Asking returns at once while the observation is still running, so the
// page's runtime never waits for it; the answer is delivered from the task
// once the observation finishes.
pub fn asking_returns_before_the_observation_finishes_test() {
  let delivered = process.new_subject()
  let started = process.new_subject()

  ui_socket.worktree_task(
    standing(access.Owner),
    access.Operator,
    allowed,
    fn() {
      // The observation holds here until the test lets it go. The gate is
      // made in the observation's own process, which is the only one that
      // may receive from it, and handed to the test.
      let gate = process.new_subject()
      process.send(started, gate)
      let assert Ok(Nil) = process.receive(gate, 5000)
        as "the test released the observation"
      Ok(one_file())
    },
    fn(read) { process.send(delivered, read) },
  )

  // The call came back with the observation unfinished and nothing delivered.
  let assert Ok(gate) = process.receive(started, 2000)
    as "the observation started in a task"
  assert process.receive(delivered, 0) == Error(Nil)

  process.send(gate, Nil)
  let assert Ok(read) = process.receive(delivered, 5000)
    as "the answer was delivered after the observation finished"
  assert board_of(read).files != []
}

// A credential's reads are counted together: a read the allowance refuses is
// `Unreadable` and the observation does not run, so a credential holding many
// sockets cannot spend the session's helper pool on Git calls. The first two
// reads inside the window run; the third does not.
pub fn a_third_read_inside_the_window_is_refused_without_running_test() {
  let taken = process.new_subject()
  let ran = process.new_subject()
  let reserve = fn() {
    case process.receive(taken, 0) {
      Ok(0) -> Error(Nil)
      Ok(left) -> {
        process.send(taken, left - 1)
        Ok(Nil)
      }
      Error(Nil) -> Error(Nil)
    }
  }
  process.send(taken, 2)
  let read = fn() {
    ui_socket.worktree_answer(
      standing(access.Owner),
      access.Operator,
      reserve,
      counting(ran, Ok(one_file())),
    )
  }

  assert board_of(read()).files != []
  assert board_of(read()).files != []
  assert read() == worktrees.Throttled
  assert process.receive(ran, 0) == Ok(Nil)
  assert process.receive(ran, 0) == Ok(Nil)
  assert process.receive(ran, 0) == Error(Nil)
}
