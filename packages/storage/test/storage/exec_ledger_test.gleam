//// The execution ledger's rules, exercised against real SQLite files.
////
//// Each test opens a ledger in its own scratch directory and drives the public
//// API. Raw SQL appears only to tamper with a stored row, which is the one way
//// to reach a state the ledger itself refuses to write.
////
//// One test is a stateful property rather than a scenario. `statem` generates
//// sequences of symbolic commands (session, key slot, incarnation skew and token
//// choice, all small indices), runs each against a fresh in-memory ledger, and
//// checks every answer against a model of the scopes and call rows that the
//// test keeps beside the ledger. A failing sequence is shrunk by deleting
//// commands and lowering their indices, so a stale-token bug reports as an
//// attach followed by one admit. The seed and run count are fixed constants, so
//// the gate is deterministic.

import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import qcheck
import simplifile
import sqlight
import statem
import storage/exec_ledger.{
  type Key, type Ledger, Admitted, AllRetired, Closed, Closing, Created,
  Existing, Fenced, Found, Fresh, Key, Limits, Missing, Open, Rebound, Reopened,
  Standing, Terminal, Unknown, UnknownCleanup,
}
import storage/exec_ledger_acks_schema
import storage/exec_ledger_releases_schema
import storage/exec_ledger_schema
import storage/exec_ledger_worktrees_schema
import support/fixtures

fn path(name: String) -> String {
  fixtures.scratch("exec-ledger-" <> name) <> "/ledger.db"
}

fn open_at(path: String) -> Ledger {
  let assert Ok(ledger) = exec_ledger.open(path) as "the ledger opens"
  ledger
}

fn token(n: Int) -> BitArray {
  bit_array.from_string("attach-token-" <> int.to_string(n))
}

fn call(n: Int) -> Key {
  Key(session: "s", op: "op", step: "step", source_index: n)
}

// The integers from `first` to `last`, both included.
fn upto(first: Int, last: Int) -> List(Int) {
  int.range(first, last + 1, [], fn(acc, n) { [n, ..acc] }) |> list.reverse
}

fn bytes(text: String) -> BitArray {
  bit_array.from_string(text)
}

fn limits() -> exec_ledger.Limits {
  exec_ledger.default_limits()
}

// Attaches session `s` at incarnation zero under token one, which most tests
// begin from.
fn attached(ledger: Ledger) -> Nil {
  let assert Ok(exec_ledger.Attached(how: Created, terminal: [], unknown: [])) =
    exec_ledger.attach(ledger, "s", "/work", 0, token(1), limits())
    as "the first attach creates the scope"
  Nil
}

fn admit(ledger: Ledger, key: Key, reservation: Int) {
  exec_ledger.admit(ledger, key, 0, token(1), "bash", reservation, limits())
}

// Runs SQL on a second connection, with CHECK constraints off so a test can
// write the states those constraints would otherwise keep out of the file.
fn tamper(path: String, statements: String) -> Nil {
  let assert Ok(connection) = sqlight.open(path)
    as "the tamper connection opens"
  let assert Ok(Nil) =
    sqlight.exec(
      "PRAGMA ignore_check_constraints = ON; " <> statements,
      on: connection,
    )
    as "the tamper statements run"
  let assert Ok(Nil) = sqlight.close(connection)
    as "the tamper connection closes"
  Nil
}

fn count(path: String, query: String) -> Int {
  let assert Ok(connection) = sqlight.open(path) as "the count connection opens"
  let assert Ok([value]) =
    sqlight.query(
      query,
      on: connection,
      with: [],
      expecting: decode.at([0], decode.int),
    )
    as "the count returns one row"
  let assert Ok(Nil) = sqlight.close(connection)
    as "the count connection closes"
  value
}

pub fn embedded_schema_matches_the_sqlc_input_test() {
  let assert Ok(schema) = simplifile.read("sql/exec_ledger.sql")
    as "the ledger schema is checked in"
  assert exec_ledger_schema.schema == schema
  let assert Ok(releases) = simplifile.read("sql/exec_ledger_releases.sql")
    as "the release schema is checked in"
  assert exec_ledger_releases_schema.schema == releases
  let assert Ok(acks) = simplifile.read("sql/exec_ledger_acks.sql")
    as "the tombstone schema is checked in"
  assert exec_ledger_acks_schema.schema == acks
  let assert Ok(worktrees) = simplifile.read("sql/exec_ledger_worktrees.sql")
    as "the worktree schema is checked in"
  assert exec_ledger_worktrees_schema.schema == worktrees
}

pub fn a_new_ledger_is_stamped_with_the_current_version_test() {
  let file = path("version")
  let _ledger = open_at(file)
  assert count(file, "PRAGMA user_version") == 4
}

pub fn admit_finish_query_ack_round_trip_test() {
  let ledger = open_at(path("round-trip"))
  attached(ledger)
  let key = call(0)
  assert exec_ledger.query(ledger, key) == Ok(Missing)
  assert admit(ledger, key, 64) == Ok(Fresh)
  assert exec_ledger.query(ledger, key) == Ok(Found(Admitted))
  assert exec_ledger.finish(ledger, key, bytes("done")) == Ok(Nil)
  assert exec_ledger.query(ledger, key) == Ok(Found(Terminal(bytes("done"))))
  assert exec_ledger.ack(ledger, key) == Ok(Nil)
  assert exec_ledger.query(ledger, key) == Ok(Found(exec_ledger.Acked))

  // An acknowledgement that arrives twice, or for a row never written, is the
  // same answer as the first.
  assert exec_ledger.ack(ledger, key) == Ok(Nil)
  assert exec_ledger.ack(ledger, call(9)) == Ok(Nil)
  assert exec_ledger.query(ledger, call(9)) == Ok(Missing)
}

pub fn an_empty_outcome_is_a_terminal_outcome_test() {
  let ledger = open_at(path("empty-outcome"))
  attached(ledger)
  assert admit(ledger, call(0), 0) == Ok(Fresh)
  assert exec_ledger.finish(ledger, call(0), <<>>) == Ok(Nil)
  assert exec_ledger.query(ledger, call(0)) == Ok(Found(Terminal(<<>>)))
}

pub fn a_duplicate_admit_returns_the_row_and_inserts_nothing_test() {
  let file = path("duplicate")
  let ledger = open_at(file)
  attached(ledger)
  assert admit(ledger, call(0), 64) == Ok(Fresh)

  // Admitted rows answer `Existing(Admitted)`, and the second request neither
  // adds a row nor reserves a second budget.
  assert admit(ledger, call(0), 64) == Ok(Existing(Admitted))
  assert count(file, "SELECT count(*) FROM call") == 1
  assert count(file, "SELECT sum(outcome_bytes) FROM call") == 64

  // A finished call hands the stored outcome to any repeat, so a retry after a
  // lost reply never starts a second run.
  assert exec_ledger.finish(ledger, call(0), bytes("done")) == Ok(Nil)
  assert admit(ledger, call(0), 64) == Ok(Existing(Terminal(bytes("done"))))
  assert count(file, "SELECT count(*) FROM call") == 1
}

pub fn a_stale_token_is_refused_and_writes_nothing_test() {
  let file = path("stale-token")
  let ledger = open_at(file)
  attached(ledger)

  // A new runtime incarnation of the same session replaces the token.
  let assert Ok(exec_ledger.Attached(how: Rebound, terminal: [], unknown: [])) =
    exec_ledger.attach(ledger, "s", "/work", 0, token(2), limits())
    as "the second runtime attaches"

  // The first runtime's request arrives late. Content refuses it.
  assert exec_ledger.admit(ledger, call(0), 0, token(1), "bash", 8, limits())
    == Error(exec_ledger.StaleToken)
  assert count(file, "SELECT count(*) FROM call") == 0
  assert exec_ledger.admit(ledger, call(0), 0, token(2), "bash", 8, limits())
    == Ok(Fresh)
}

pub fn a_stale_incarnation_is_refused_test() {
  let file = path("stale-incarnation")
  let ledger = open_at(file)
  attached(ledger)
  assert exec_ledger.admit(ledger, call(0), 1, token(1), "bash", 8, limits())
    == Error(exec_ledger.StaleIncarnation(0))
  assert count(file, "SELECT count(*) FROM call") == 0
}

pub fn admission_needs_a_scope_that_is_open_test() {
  let ledger = open_at(path("not-open"))
  assert admit(ledger, call(0), 8) == Error(exec_ledger.NoSuchScope)
  attached(ledger)
  assert exec_ledger.begin_close(ledger, "s", "/work", 0) == Ok(Nil)
  assert admit(ledger, call(0), 8) == Error(exec_ledger.ScopeNotOpen(Closing))
  assert exec_ledger.finish_close(ledger, "s", "/work", 0, AllRetired)
    == Ok(Nil)
  assert admit(ledger, call(0), 8)
    == Error(exec_ledger.ScopeNotOpen(Closed(AllRetired)))
}

pub fn current_is_the_admission_check_without_a_row_test() {
  let file = path("current")
  let ledger = open_at(file)
  assert exec_ledger.current(ledger, "s", 0, token(1))
    == Error(exec_ledger.NoSuchScope)
  assert exec_ledger.current_incarnation(ledger, "s", 0)
    == Error(exec_ledger.NoSuchScope)
  attached(ledger)
  assert exec_ledger.current(ledger, "s", 0, token(1)) == Ok(Nil)
  assert exec_ledger.current(ledger, "s", 0, token(2))
    == Error(exec_ledger.StaleToken)
  assert exec_ledger.current(ledger, "s", 1, token(1))
    == Error(exec_ledger.StaleIncarnation(0))

  // The incarnation-only read ignores the token.
  assert exec_ledger.current_incarnation(ledger, "s", 0) == Ok(Nil)
  assert exec_ledger.current_incarnation(ledger, "s", 1)
    == Error(exec_ledger.StaleIncarnation(0))

  // A closing scope and a closed one are both not open.
  assert exec_ledger.begin_close(ledger, "s", "/work", 0) == Ok(Nil)
  assert exec_ledger.current(ledger, "s", 0, token(1))
    == Error(exec_ledger.ScopeNotOpen(Closing))
  assert exec_ledger.current_incarnation(ledger, "s", 0)
    == Error(exec_ledger.ScopeNotOpen(Closing))
  assert exec_ledger.finish_close(ledger, "s", "/work", 0, AllRetired)
    == Ok(Nil)
  assert exec_ledger.current(ledger, "s", 0, token(1))
    == Error(exec_ledger.ScopeNotOpen(Closed(AllRetired)))
  assert count(file, "SELECT count(*) FROM call") == 0
}

pub fn a_closing_scope_still_settles_the_calls_it_cancels_test() {
  let ledger = open_at(path("closing-settles"))
  attached(ledger)
  assert admit(ledger, call(0), 8) == Ok(Fresh)
  assert admit(ledger, call(1), 8) == Ok(Fresh)
  assert exec_ledger.begin_close(ledger, "s", "/work", 0) == Ok(Nil)
  assert exec_ledger.finish(ledger, call(0), bytes("cut")) == Ok(Nil)
  assert exec_ledger.mark_unknown(ledger, call(1)) == Ok(Nil)
  assert exec_ledger.query(ledger, call(0)) == Ok(Found(Terminal(bytes("cut"))))
  assert exec_ledger.query(ledger, call(1)) == Ok(Found(Unknown))
}

pub fn begin_close_is_idempotent_and_finish_close_needs_it_test() {
  let ledger = open_at(path("close-steps"))
  attached(ledger)
  assert exec_ledger.finish_close(ledger, "s", "/work", 0, AllRetired)
    == Error(exec_ledger.ScopeNotClosing(Open))
  assert exec_ledger.begin_close(ledger, "s", "/work", 1)
    == Error(exec_ledger.StaleIncarnation(0))
  assert exec_ledger.begin_close(ledger, "s", "/work", 0) == Ok(Nil)
  assert exec_ledger.begin_close(ledger, "s", "/work", 0) == Ok(Nil)
  assert exec_ledger.finish_close(ledger, "s", "/work", 1, AllRetired)
    == Error(exec_ledger.StaleIncarnation(0))
  assert exec_ledger.finish_close(ledger, "s", "/work", 0, UnknownCleanup(-1))
    == Error(exec_ledger.Invalid("unknown cleanup count is negative"))
  assert exec_ledger.finish_close(ledger, "s", "/work", 0, AllRetired)
    == Ok(Nil)

  // A close does not repeat: the scope is closed now, and a second request for
  // the same close is a question for the actor to answer from `scope`.
  assert exec_ledger.begin_close(ledger, "s", "/work", 0)
    == Error(exec_ledger.ScopeNotOpen(Closed(AllRetired)))
  assert exec_ledger.finish_close(ledger, "s", "/work", 0, AllRetired)
    == Error(exec_ledger.ScopeNotClosing(Closed(AllRetired)))
}

pub fn a_scope_is_bound_to_its_workspace_test() {
  let ledger = open_at(path("workspace"))
  attached(ledger)
  assert exec_ledger.attach(ledger, "s", "/elsewhere", 0, token(2), limits())
    == Error(exec_ledger.WorkspaceMismatch("/work"))
  assert exec_ledger.begin_close(ledger, "s", "/elsewhere", 0)
    == Error(exec_ledger.WorkspaceMismatch("/work"))
  assert exec_ledger.begin_close(ledger, "missing", "/work", 0)
    == Error(exec_ledger.NoSuchScope)
}

pub fn a_clean_close_reopens_at_the_next_incarnation_only_test() {
  let ledger = open_at(path("reopen"))
  attached(ledger)
  assert admit(ledger, call(0), 8) == Ok(Fresh)
  assert exec_ledger.finish(ledger, call(0), bytes("first")) == Ok(Nil)
  assert exec_ledger.begin_close(ledger, "s", "/work", 0) == Ok(Nil)

  // The close is not finished yet, so no attach may race it.
  assert exec_ledger.attach(ledger, "s", "/work", 1, token(2), limits())
    == Error(exec_ledger.ScopeClosing)
  assert exec_ledger.finish_close(ledger, "s", "/work", 0, AllRetired)
    == Ok(Nil)

  // Rows never move: a closed scope's call is still answered.
  assert exec_ledger.query(ledger, call(0))
    == Ok(Found(Terminal(bytes("first"))))
  assert exec_ledger.attach(ledger, "s", "/work", 0, token(2), limits())
    == Error(exec_ledger.StaleIncarnation(0))
  assert exec_ledger.attach(ledger, "s", "/work", 2, token(2), limits())
    == Error(exec_ledger.StaleIncarnation(0))

  // The reopen reports the unacknowledged result from the earlier incarnation.
  assert exec_ledger.attach(ledger, "s", "/work", 1, token(2), limits())
    == Ok(exec_ledger.Attached(how: Reopened, terminal: [call(0)], unknown: []))

  // The reopened scope admits only under its new incarnation and token.
  assert exec_ledger.admit(ledger, call(1), 0, token(1), "bash", 8, limits())
    == Error(exec_ledger.StaleIncarnation(1))
  assert exec_ledger.admit(ledger, call(1), 1, token(1), "bash", 8, limits())
    == Error(exec_ledger.StaleToken)
  assert exec_ledger.admit(ledger, call(1), 1, token(2), "bash", 8, limits())
    == Ok(Fresh)
}

pub fn a_close_with_unknown_cleanup_never_reopens_test() {
  let ledger = open_at(path("unclean"))
  attached(ledger)
  assert exec_ledger.begin_close(ledger, "s", "/work", 0) == Ok(Nil)
  assert exec_ledger.finish_close(ledger, "s", "/work", 0, UnknownCleanup(2))
    == Ok(Nil)
  assert exec_ledger.attach(ledger, "s", "/work", 1, token(2), limits())
    == Error(exec_ledger.UncleanClose(2))
  assert exec_ledger.attach(ledger, "s", "/work", 0, token(2), limits())
    == Error(exec_ledger.UncleanClose(2))
  assert exec_ledger.scope(ledger, "s")
    == Ok(
      Some(exec_ledger.Scope(
        session: "s",
        workspace: "/work",
        incarnation: 0,
        state: Closed(UnknownCleanup(2)),
        token: token(1),
      )),
    )
}

fn scope_name(n: Int) -> String {
  "session-" <> int.to_string(n)
}

fn attach_scope(ledger: Ledger, n: Int) {
  exec_ledger.attach(ledger, scope_name(n), "/work", 0, token(n), limits())
}

fn close_cleanly(ledger: Ledger, n: Int) -> Nil {
  let assert Ok(Nil) =
    exec_ledger.begin_close(ledger, scope_name(n), "/work", 0)
    as "the close begins"
  let assert Ok(Nil) =
    exec_ledger.finish_close(ledger, scope_name(n), "/work", 0, AllRetired)
    as "the close finishes"
  Nil
}

pub fn the_seventeenth_unclean_scope_is_refused_test() {
  let ledger = open_at(path("capacity"))
  list.each(upto(0, 15), fn(n) {
    let assert Ok(exec_ledger.Attached(how: Created, ..)) =
      attach_scope(ledger, n)
      as "the first sixteen scopes attach"
    Nil
  })
  assert attach_scope(ledger, 16) == Error(exec_ledger.CapacityExhausted(16))

  // A scope that already holds a slot may still rebind its token at capacity.
  assert exec_ledger.attach(
      ledger,
      scope_name(3),
      "/work",
      0,
      token(99),
      limits(),
    )
    == Ok(exec_ledger.Attached(how: Rebound, terminal: [], unknown: []))

  // A clean close frees its slot at once.
  close_cleanly(ledger, 3)
  assert attach_scope(ledger, 16)
    == Ok(exec_ledger.Attached(how: Created, terminal: [], unknown: []))
  assert attach_scope(ledger, 17) == Error(exec_ledger.CapacityExhausted(16))
}

pub fn more_than_sixteen_sequential_sessions_work_test() {
  let ledger = open_at(path("sequential"))
  list.each(upto(0, 39), fn(n) {
    let assert Ok(exec_ledger.Attached(how: Created, ..)) =
      attach_scope(ledger, n)
      as "each session attaches in a free slot"
    close_cleanly(ledger, n)
  })
}

pub fn unknown_cleanup_and_reopen_both_hold_a_slot_test() {
  let ledger = open_at(path("slots"))
  list.each(upto(0, 14), fn(n) {
    let assert Ok(_) = attach_scope(ledger, n) as "fifteen scopes stay open"
    Nil
  })

  // The sixteenth scope closed uncleanly, so its slot never frees.
  let assert Ok(_) = attach_scope(ledger, 15) as "the sixteenth attaches"
  let assert Ok(Nil) =
    exec_ledger.begin_close(ledger, scope_name(15), "/work", 0)
    as "its close begins"
  let assert Ok(Nil) =
    exec_ledger.finish_close(
      ledger,
      scope_name(15),
      "/work",
      0,
      UnknownCleanup(1),
    )
    as "its close ends unclean"
  assert attach_scope(ledger, 16) == Error(exec_ledger.CapacityExhausted(16))

  // Reopening takes a slot back, so it meets the same limit as a new scope.
  close_cleanly(ledger, 14)
  let assert Ok(_) = attach_scope(ledger, 16) as "the freed slot is reused"
  assert exec_ledger.attach(
      ledger,
      scope_name(14),
      "/work",
      1,
      token(5),
      limits(),
    )
    == Error(exec_ledger.CapacityExhausted(16))
}

pub fn the_byte_budget_counts_reservations_and_releases_them_test() {
  let ledger = open_at(path("budget"))
  attached(ledger)
  let small = Limits(max_unclean_scopes: 16, max_ledger_bytes: 100)
  let admit = fn(key, reservation) {
    exec_ledger.admit(ledger, key, 0, token(1), "bash", reservation, small)
  }
  assert admit(call(0), 60) == Ok(Fresh)
  assert admit(call(1), 60) == Error(exec_ledger.BudgetExhausted(100))
  assert exec_ledger.query(ledger, call(1)) == Ok(Missing)

  // Finishing shrinks the 60-byte reservation to the 10-byte outcome.
  assert exec_ledger.finish(ledger, call(0), bytes("0123456789")) == Ok(Nil)
  assert admit(call(1), 90) == Ok(Fresh)
  assert admit(call(2), 1) == Error(exec_ledger.BudgetExhausted(100))

  // An unknown call holds nothing, and an acknowledgement releases the rest.
  assert exec_ledger.mark_unknown(ledger, call(1)) == Ok(Nil)
  assert admit(call(2), 90) == Ok(Fresh)
  assert exec_ledger.ack(ledger, call(0)) == Ok(Nil)
  assert admit(call(3), 10) == Ok(Fresh)
  assert admit(call(4), 1) == Error(exec_ledger.BudgetExhausted(100))
}

pub fn an_outcome_beyond_its_reservation_is_refused_test() {
  let ledger = open_at(path("too-large"))
  attached(ledger)
  assert admit(ledger, call(0), 4) == Ok(Fresh)
  assert exec_ledger.finish(ledger, call(0), bytes("12345"))
    == Error(exec_ledger.OutcomeTooLarge(reserved: 4, size: 5))
  assert exec_ledger.query(ledger, call(0)) == Ok(Found(Admitted))
  assert exec_ledger.finish(ledger, call(0), bytes("1234")) == Ok(Nil)
}

pub fn only_an_admitted_call_can_be_settled_test() {
  let ledger = open_at(path("settle"))
  attached(ledger)
  assert exec_ledger.finish(ledger, call(0), bytes("x"))
    == Error(exec_ledger.NoSuchCall)
  assert exec_ledger.mark_unknown(ledger, call(0))
    == Error(exec_ledger.NoSuchCall)
  assert admit(ledger, call(0), 8) == Ok(Fresh)
  assert exec_ledger.finish(ledger, call(0), bytes("x")) == Ok(Nil)
  assert exec_ledger.finish(ledger, call(0), bytes("y"))
    == Error(exec_ledger.CallNotAdmitted)
  assert exec_ledger.mark_unknown(ledger, call(0))
    == Error(exec_ledger.CallNotAdmitted)
  assert exec_ledger.query(ledger, call(0)) == Ok(Found(Terminal(bytes("x"))))
}

pub fn an_acknowledgement_never_discards_a_live_run_test() {
  let ledger = open_at(path("ack-admitted"))
  attached(ledger)
  assert admit(ledger, call(0), 8) == Ok(Fresh)
  assert exec_ledger.ack(ledger, call(0)) == Ok(Nil)
  assert exec_ledger.query(ledger, call(0)) == Ok(Found(Admitted))
}

pub fn reopening_the_file_turns_admitted_into_unknown_and_never_back_test() {
  let file = path("restart")
  let ledger = open_at(file)
  attached(ledger)
  assert admit(ledger, call(0), 50) == Ok(Fresh)
  assert admit(ledger, call(1), 50) == Ok(Fresh)
  assert admit(ledger, call(2), 50) == Ok(Fresh)
  assert exec_ledger.finish(ledger, call(1), bytes("ok")) == Ok(Nil)
  let assert Ok(Nil) = exec_ledger.close(ledger) as "the first VM stops"

  // The next VM finds nothing to relaunch: the runs it cannot vouch for are
  // unknown, and the stored outcome is untouched.
  let restarted = open_at(file)
  assert exec_ledger.query(restarted, call(0)) == Ok(Found(Unknown))
  assert exec_ledger.query(restarted, call(1))
    == Ok(Found(Terminal(bytes("ok"))))
  assert exec_ledger.query(restarted, call(2)) == Ok(Found(Unknown))
  assert exec_ledger.finish(restarted, call(0), bytes("late"))
    == Error(exec_ledger.CallNotAdmitted)

  // Unknown rows hold no bytes, so only the two-byte outcome counts.
  let tight = Limits(max_unclean_scopes: 16, max_ledger_bytes: 100)
  assert exec_ledger.admit(restarted, call(3), 0, token(1), "bash", 98, tight)
    == Ok(Fresh)
  assert exec_ledger.admit(restarted, call(4), 0, token(1), "bash", 1, tight)
    == Error(exec_ledger.BudgetExhausted(100))
  let assert Ok(Nil) = exec_ledger.close(restarted) as "the second VM stops"

  // A second restart does not resurrect the first one's admitted rows.
  let again = open_at(file)
  assert exec_ledger.query(again, call(0)) == Ok(Found(Unknown))
  assert exec_ledger.query(again, call(3)) == Ok(Found(Unknown))
  assert admit(again, call(0), 8) == Ok(Existing(Unknown))
}

pub fn attach_lists_the_unacknowledged_results_for_the_orchestrator_test() {
  let file = path("attach-keys")
  let ledger = open_at(file)
  attached(ledger)
  assert admit(ledger, call(0), 8) == Ok(Fresh)
  assert admit(ledger, call(1), 8) == Ok(Fresh)
  assert admit(ledger, call(2), 8) == Ok(Fresh)
  assert exec_ledger.finish(ledger, call(2), bytes("r2")) == Ok(Nil)
  assert exec_ledger.finish(ledger, call(0), bytes("r0")) == Ok(Nil)
  assert exec_ledger.mark_unknown(ledger, call(1)) == Ok(Nil)

  // Another session's rows are not this session's to acknowledge.
  assert exec_ledger.attach(ledger, "other", "/work", 0, token(7), limits())
    == Ok(exec_ledger.Attached(how: Created, terminal: [], unknown: []))
  assert exec_ledger.attach(ledger, "s", "/work", 0, token(2), limits())
    == Ok(
      exec_ledger.Attached(how: Rebound, terminal: [call(0), call(2)], unknown: [
        call(1),
      ]),
    )

  // The orchestrator acknowledges what its store holds, and the next attach no
  // longer lists it.
  assert exec_ledger.ack(ledger, call(0)) == Ok(Nil)
  assert exec_ledger.ack(ledger, call(1)) == Ok(Nil)
  assert exec_ledger.attach(ledger, "s", "/work", 0, token(3), limits())
    == Ok(exec_ledger.Attached(how: Rebound, terminal: [call(2)], unknown: []))
}

pub fn unacked_lists_the_same_keys_without_replacing_the_token_test() {
  let ledger = open_at(path("unacked"))
  attached(ledger)
  assert admit(ledger, call(0), 8) == Ok(Fresh)
  assert admit(ledger, call(1), 8) == Ok(Fresh)
  assert admit(ledger, call(2), 8) == Ok(Fresh)
  assert exec_ledger.finish(ledger, call(0), bytes("r0")) == Ok(Nil)
  assert exec_ledger.mark_unknown(ledger, call(1)) == Ok(Nil)

  // A session with no rows has nothing to acknowledge, and asking is not an
  // attach, so it needs no scope.
  assert exec_ledger.unacked(ledger, "nobody")
    == Ok(exec_ledger.Unacked(terminal: [], unknown: []))

  // The admitted call is still running, so it is neither list.
  assert exec_ledger.unacked(ledger, "s")
    == Ok(exec_ledger.Unacked(terminal: [call(0)], unknown: [call(1)]))

  // The read did not touch the scope: the original token still admits.
  assert admit(ledger, call(3), 8) == Ok(Fresh)
  assert exec_ledger.ack(ledger, call(0)) == Ok(Nil)
  assert exec_ledger.unacked(ledger, "s")
    == Ok(exec_ledger.Unacked(terminal: [], unknown: [call(1)]))
}

pub fn a_damaged_outcome_is_a_digest_error_never_a_result_test() {
  let file = path("digest")
  let ledger = open_at(file)
  attached(ledger)
  list.each(upto(0, 2), fn(n) {
    let assert Ok(Fresh) = admit(ledger, call(n), 16) as "the call is admitted"
    let assert Ok(Nil) = exec_ledger.finish(ledger, call(n), bytes("payload"))
      as "the call finishes"
    Nil
  })

  // Same length, different bytes: only the digest can notice.
  tamper(
    file,
    "UPDATE call SET outcome = CAST('paYload' AS BLOB) WHERE source_index = 0;",
  )

  // The digest itself is damaged.
  tamper(
    file,
    "UPDATE call SET outcome_digest = zeroblob(32) WHERE source_index = 1;",
  )

  // The recorded size no longer matches the stored bytes.
  tamper(file, "UPDATE call SET outcome_bytes = 3 WHERE source_index = 2;")
  list.each(upto(0, 2), fn(n) {
    assert exec_ledger.query(ledger, call(n))
      == Error(exec_ledger.DigestMismatch(call(n)))

    // A repeated admit reads the same row, so it fails closed as well.
    assert admit(ledger, call(n), 16)
      == Error(exec_ledger.DigestMismatch(call(n)))
  })
}

pub fn a_malformed_call_row_fails_closed_test() {
  let file = path("malformed-call")
  let ledger = open_at(file)
  attached(ledger)
  list.each(upto(0, 4), fn(n) {
    let assert Ok(Fresh) = admit(ledger, call(n), 16) as "the call is admitted"
    Nil
  })

  // An unknown state string.
  tamper(file, "UPDATE call SET state = 'acked' WHERE source_index = 0;")

  // Terminal with no outcome, admitted with an outcome, unknown with a digest.
  tamper(file, "UPDATE call SET state = 'terminal' WHERE source_index = 1;")
  tamper(file, "UPDATE call SET outcome = x'00' WHERE source_index = 2;")
  tamper(
    file,
    "UPDATE call SET state = 'unknown', outcome_digest = x'00' WHERE source_index = 3;",
  )
  list.each(upto(0, 3), fn(n) {
    let assert Error(exec_ledger.MalformedRow(_)) =
      exec_ledger.query(ledger, call(n))
      as "a row that fits no state is an error, not a default"
    let assert Error(exec_ledger.MalformedRow(_)) = admit(ledger, call(n), 16)
      as "admission fails closed on the same row"
    Nil
  })
  assert exec_ledger.query(ledger, call(4)) == Ok(Found(Admitted))
}

pub fn a_malformed_scope_row_fails_closed_test() {
  let file = path("malformed-scope")
  let ledger = open_at(file)
  attached(ledger)
  let broken = fn(statement) {
    tamper(file, statement)
    let assert Error(exec_ledger.MalformedRow(_)) =
      exec_ledger.scope(ledger, "s")
      as "the scope row decodes to no state"
    let assert Error(exec_ledger.MalformedRow(_)) = admit(ledger, call(0), 8)
      as "admission fails closed"
    let assert Error(exec_ledger.MalformedRow(_)) =
      exec_ledger.attach(ledger, "s", "/work", 0, token(2), limits())
      as "an attach fails closed as well"
    tamper(file, "UPDATE scope SET state = 'open', close_outcome = NULL;")
  }
  broken("UPDATE scope SET state = 'bogus';")
  broken("UPDATE scope SET state = 'closed', close_outcome = NULL;")
  broken("UPDATE scope SET state = 'closed', close_outcome = 'unknown:x';")
  broken("UPDATE scope SET state = 'closed', close_outcome = 'unknown:-1';")
  broken("UPDATE scope SET state = 'open', close_outcome = 'all_retired';")
  assert exec_ledger.scope(ledger, "s")
    == Ok(
      Some(exec_ledger.Scope(
        session: "s",
        workspace: "/work",
        incarnation: 0,
        state: Open,
        token: token(1),
      )),
    )
}

pub fn a_file_that_is_not_a_ledger_is_refused_test() {
  let file = path("foreign")
  let assert Ok(connection) = sqlight.open(file) as "the foreign file opens"
  let assert Ok(Nil) =
    sqlight.exec("CREATE TABLE notes(id INTEGER PRIMARY KEY);", on: connection)
    as "the foreign file gets a table"
  let assert Ok(Nil) = sqlight.close(connection) as "the foreign file closes"
  assert result_is_unsupported(exec_ledger.open(file))

  // A ledger of a version this build does not know is refused as well.
  let versioned = path("future")
  let first = open_at(versioned)
  let assert Ok(Nil) = exec_ledger.close(first) as "the ledger closes"
  tamper(versioned, "PRAGMA user_version = 5;")
  assert result_is_unsupported(exec_ledger.open(versioned))
}

fn result_is_unsupported(opened: Result(Ledger, exec_ledger.Error)) -> Bool {
  case opened {
    Error(exec_ledger.Unsupported) -> True
    Error(_) | Ok(_) -> False
  }
}

pub fn invalid_arguments_are_refused_before_any_write_test() {
  let ledger = open_at(path("invalid"))
  assert exec_ledger.attach(ledger, "s", "/work", -1, token(1), limits())
    == Error(exec_ledger.Invalid("incarnation is negative"))
  assert exec_ledger.attach(ledger, "s", "/work", 0, <<>>, limits())
    == Error(exec_ledger.Invalid("attach token is empty"))
  attached(ledger)
  assert admit(ledger, call(0), -1)
    == Error(exec_ledger.Invalid("result reservation is negative"))
  assert admit(ledger, Key(..call(0), source_index: -1), 8)
    == Error(exec_ledger.Invalid("call source index is negative"))
}

pub fn two_connections_racing_one_key_produce_one_fresh_test() {
  let file = path("race")
  let first = open_at(file)
  let second = open_at(file)
  attached(first)
  let results = process.new_subject()
  let handoff = process.new_subject()
  let keys = upto(0, 29)
  let racer = fn(ledger) {
    process.spawn_unlinked(fn() {
      let go = process.new_subject()
      process.send(handoff, go)
      let assert Ok(Nil) = process.receive(go, 5000) as "the starting signal"
      list.each(keys, fn(n) {
        process.send(results, #(n, admit(ledger, call(n), 8)))
      })
    })
  }
  let _first_racer = racer(first)
  let _second_racer = racer(second)
  let assert Ok(first_go) = process.receive(handoff, 5000)
    as "first racer ready"
  let assert Ok(second_go) = process.receive(handoff, 5000)
    as "second racer ready"
  process.send(first_go, Nil)
  process.send(second_go, Nil)
  let answers = collect(results, list.length(keys) * 2, [])
  list.each(keys, fn(n) {
    let for_key =
      list.filter_map(answers, fn(answer) {
        case answer.0 == n {
          True -> Ok(answer.1)
          False -> Error(Nil)
        }
      })
    assert list.count(for_key, fn(answer) { answer == Ok(Fresh) }) == 1
    assert list.count(for_key, fn(answer) { answer == Ok(Existing(Admitted)) })
      == 1
  })
  assert count(file, "SELECT count(*) FROM call") == 30
}

fn collect(subject, remaining: Int, acc: List(a)) -> List(a) {
  case remaining {
    0 -> acc
    _ -> {
      let assert Ok(message) = process.receive(subject, 10_000)
        as "a racer answers in time"
      collect(subject, remaining - 1, [message, ..acc])
    }
  }
}

// --- the stateful property: random operation sequences ---------------------
//
// The sequence test below is a `statem` specification. A command names a
// session, a key slot, an incarnation skew and a token choice by small index,
// never by value, so deleting any prefix of a failing sequence leaves another
// meaningful sequence and shrinking can reach a short one. `execute` resolves
// those choices against the model it is handed and then against the real
// ledger, and the model, not the ledger, is what every answer is checked
// against.

/// The number of random sequences the property runs. Each is generated from
/// its own position in the seeded stream, so a failure names the run that
/// reproduces it alone.
const sequence_count = 40

/// The longest sequence one run may draw. Greedy shrinking re-executes
/// candidates against a fresh database, so the bound stays moderate.
const sequence_length = 200

/// The seed every sequence derives from. Fixed, so the gate is the same gate
/// on every machine.
const sequence_seed = 7919

/// How a command picks the attach token it presents.
type TokenChoice {
  /// The token the model says the scope holds now, which is the only token
  /// admission accepts. A session with no scope has none, and the model then
  /// stands in token zero.
  Own

  /// One of three tokens drawn from a shared pool, usually not the held one.
  Pooled(n: Int)
}

/// One ledger operation, symbolic. `session` is an index into the two session
/// names, `slot` an index into that session's four call keys, and `skew` how
/// far above the scope's current incarnation the request claims to be.
type Command {
  Attach(session: Int, skew: Int, choice: TokenChoice)
  Admit(session: Int, skew: Int, choice: TokenChoice, slot: Int)
  Finish(session: Int, slot: Int)
  MarkUnknown(session: Int, slot: Int)
  Ack(session: Int, slot: Int)
  BeginClose(session: Int, skew: Int)
  FinishClose(session: Int, skew: Int, outcome: exec_ledger.CloseOutcome)
}

/// What the model expects a scope to hold: the incarnation, the identity of
/// the attach token (an index into the pool, not its bytes) and the stage.
type Held {
  Held(incarnation: Int, token: Int, state: exec_ledger.ScopeState)
}

/// The expected ledger: each session's scope and every call row, including
/// acknowledgement tombstones, which stay in the dictionary as `Acked`.
type Model {
  Model(
    scopes: dict.Dict(Int, Held),
    rows: dict.Dict(#(Int, Int), exec_ledger.CallState),
  )
}

/// The part of an answer the properties compare, with the ledger's error
/// variants folded into one `Refused`: the properties say which requests are
/// refused, and the unit tests above say why.
type Reply {
  Attachment(how: exec_ledger.Attachment)
  Decision(admission: exec_ledger.Admission)
  Applied
  Refused
}

fn session_name(session: Int) -> String {
  case session % 2 {
    0 -> "a"
    _ -> "b"
  }
}

fn key_for(session: Int, slot: Int) -> Key {
  let n = slot % 4
  Key(
    session: session_name(session),
    op: "op" <> int.to_string(n % 2),
    step: "step",
    source_index: n / 2,
  )
}

fn slots() -> List(Int) {
  [0, 1, 2, 3]
}

fn stored_incarnation(model: Model, session: Int) -> Int {
  case dict.get(model.scopes, session % 2) {
    Ok(Held(incarnation:, ..)) -> incarnation
    Error(Nil) -> 0
  }
}

fn token_index(model: Model, session: Int, choice: TokenChoice) -> Int {
  case choice, dict.get(model.scopes, session % 2) {
    Own, Ok(Held(token:, ..)) -> token
    Own, Error(Nil) -> 0
    Pooled(n:), _ -> n
  }
}

// The scope's tombstones go when its incarnation changes or a close retires
// every child; the keys that only a tombstone held go with them.
fn forget_acks(model: Model, session: Int) -> Model {
  let rows =
    dict.filter(model.rows, fn(key, state) {
      key.0 != session % 2 || state != exec_ledger.Acked
    })
  Model(..model, rows:)
}

fn settle(
  model: Model,
  session: Int,
  slot: Int,
  from: fn(exec_ledger.CallState) -> option.Option(exec_ledger.CallState),
) -> #(Reply, Model) {
  let key = #(session % 2, slot % 4)
  case dict.get(model.rows, key) |> option.from_result |> option.then(from) {
    Some(next) -> #(
      Applied,
      Model(..model, rows: dict.insert(model.rows, key, next)),
    )
    None -> #(Refused, model)
  }
}

// What the ledger must answer, and the model after it. This is the whole
// state machine of the ledger's attach, admission and close rules, written
// over small integers; the capacity limit is never reached with two sessions
// and the byte budget never with eight-byte reservations, so neither appears.
fn step(model: Model, command: Command) -> #(Reply, Model) {
  case command {
    Attach(session:, skew:, choice:) -> {
      let incarnation = stored_incarnation(model, session) + skew
      let held = Held(incarnation, token_index(model, session, choice), Open)
      let joined = fn(how, model: Model) {
        let scopes = dict.insert(model.scopes, session % 2, held)
        #(Attachment(how), Model(..model, scopes:))
      }
      case dict.get(model.scopes, session % 2) {
        Error(Nil) -> joined(Created, model)
        Ok(Held(incarnation: stored, state:, ..)) ->
          case state {
            Open if incarnation == stored -> joined(Rebound, model)
            Open -> #(Refused, model)
            Closing | Closed(UnknownCleanup(_)) -> #(Refused, model)
            Closed(AllRetired) if incarnation == stored + 1 ->
              joined(Reopened, forget_acks(model, session))
            Closed(AllRetired) -> #(Refused, model)
          }
      }
    }

    Admit(session:, skew:, choice:, slot:) -> {
      let incarnation = stored_incarnation(model, session) + skew
      let presented = token_index(model, session, choice)
      let key = #(session % 2, slot % 4)
      case dict.get(model.scopes, session % 2) {
        Ok(Held(incarnation: stored, token: held, state: Open))
          if stored == incarnation && held == presented
        ->
          case dict.get(model.rows, key) {
            Ok(state) -> #(Decision(Existing(state)), model)
            Error(Nil) -> #(
              Decision(Fresh),
              Model(..model, rows: dict.insert(model.rows, key, Admitted)),
            )
          }
        Ok(_) | Error(Nil) -> #(Refused, model)
      }
    }

    Finish(session:, slot:) ->
      settle(model, session, slot, fn(state) {
        case state {
          Admitted -> Some(Terminal(bytes("ok")))
          Terminal(_) | Unknown | exec_ledger.Acked -> None
        }
      })

    MarkUnknown(session:, slot:) ->
      settle(model, session, slot, fn(state) {
        case state {
          Admitted -> Some(Unknown)
          Terminal(_) | Unknown | exec_ledger.Acked -> None
        }
      })

    // An acknowledgement of a missing or unsettled key is accepted and
    // changes nothing; only a settled row becomes a tombstone.
    Ack(session:, slot:) -> {
      let key = #(session % 2, slot % 4)
      case dict.get(model.rows, key) {
        Ok(Terminal(_)) | Ok(Unknown) -> #(
          Applied,
          Model(..model, rows: dict.insert(model.rows, key, exec_ledger.Acked)),
        )
        Ok(Admitted) | Ok(exec_ledger.Acked) | Error(Nil) -> #(Applied, model)
      }
    }

    BeginClose(session:, skew:) -> {
      let incarnation = stored_incarnation(model, session) + skew
      case dict.get(model.scopes, session % 2) {
        Ok(Held(incarnation: stored, state:, ..) as held)
          if stored == incarnation
        ->
          case state {
            Open -> #(
              Applied,
              Model(
                ..model,
                scopes: dict.insert(
                  model.scopes,
                  session % 2,
                  Held(..held, state: Closing),
                ),
              ),
            )
            Closing -> #(Applied, model)
            Closed(_) -> #(Refused, model)
          }
        Ok(_) | Error(Nil) -> #(Refused, model)
      }
    }

    FinishClose(session:, skew:, outcome:) -> {
      let incarnation = stored_incarnation(model, session) + skew
      case dict.get(model.scopes, session % 2) {
        Ok(Held(incarnation: stored, state: Closing, ..) as held)
          if stored == incarnation
        -> {
          let closed =
            Model(
              ..model,
              scopes: dict.insert(
                model.scopes,
                session % 2,
                Held(..held, state: Closed(outcome)),
              ),
            )
          case outcome {
            AllRetired -> #(Applied, forget_acks(closed, session))
            UnknownCleanup(_) -> #(Applied, closed)
          }
        }
        Ok(_) | Error(Nil) -> #(Refused, model)
      }
    }
  }
}

// The command on the real ledger, with the request resolved the way `step`
// resolved it, so that the two see the same incarnation, token and key.
fn perform(ledger: Ledger, model: Model, command: Command) -> Reply {
  let applied = fn(answer: Result(Nil, exec_ledger.Error)) {
    case answer {
      Ok(Nil) -> Applied
      Error(_) -> Refused
    }
  }
  case command {
    Attach(session:, skew:, choice:) ->
      case
        exec_ledger.attach(
          ledger,
          session_name(session),
          "/work",
          stored_incarnation(model, session) + skew,
          token(token_index(model, session, choice)),
          limits(),
        )
      {
        Ok(exec_ledger.Attached(how:, ..)) -> Attachment(how)
        Error(_) -> Refused
      }

    Admit(session:, skew:, choice:, slot:) ->
      case
        exec_ledger.admit(
          ledger,
          key_for(session, slot),
          stored_incarnation(model, session) + skew,
          token(token_index(model, session, choice)),
          "bash",
          8,
          limits(),
        )
      {
        Ok(admission) -> Decision(admission)
        Error(_) -> Refused
      }

    Finish(session:, slot:) ->
      applied(exec_ledger.finish(ledger, key_for(session, slot), bytes("ok")))

    MarkUnknown(session:, slot:) ->
      applied(exec_ledger.mark_unknown(ledger, key_for(session, slot)))

    Ack(session:, slot:) ->
      applied(exec_ledger.ack(ledger, key_for(session, slot)))

    BeginClose(session:, skew:) ->
      applied(exec_ledger.begin_close(
        ledger,
        session_name(session),
        "/work",
        stored_incarnation(model, session) + skew,
      ))

    FinishClose(session:, skew:, outcome:) ->
      applied(exec_ledger.finish_close(
        ledger,
        session_name(session),
        "/work",
        stored_incarnation(model, session) + skew,
        outcome,
      ))
  }
}

fn violation(tag: String, detail: String) -> Result(Nil, statem.Violation) {
  Error(statem.Violation(tag:, detail:))
}

// The two properties the design rests on, then plain agreement. A request
// the model refuses but the ledger answered was admitted under a stale
// incarnation or token; a `Fresh` for a key the model holds would start a
// call twice. Both are named before the general comparison, so shrinking a
// failure of one never slides into the other.
fn check_reply(
  command: Command,
  expected: Reply,
  observed: Reply,
) -> Result(Nil, statem.Violation) {
  case command, expected, observed {
    Admit(..), Refused, Decision(_) ->
      violation(
        "stale-admitted",
        "admitted under an incarnation or token the scope does not hold: "
          <> string.inspect(observed),
      )
    Admit(..), Decision(Existing(_)), Decision(Fresh) ->
      violation("fresh-while-held", "Fresh for a key the ledger already holds")
    _, _, _ ->
      case expected == observed {
        True -> Ok(Nil)
        False ->
          violation(
            "reply",
            "expected "
              <> string.inspect(expected)
              <> ", the ledger answered "
              <> string.inspect(observed),
          )
      }
  }
}

// Every call key of the session the command touched, because a reopen or a
// retiring close changes keys the command never named: presence first, then
// the exact row.
fn check_rows(
  ledger: Ledger,
  model: Model,
  session: Int,
) -> Result(Nil, statem.Violation) {
  list.try_each(slots(), fn(slot) {
    case
      exec_ledger.query(ledger, key_for(session, slot)),
      dict.get(model.rows, #(session % 2, slot % 4))
    {
      Ok(Missing), Error(Nil) -> Ok(Nil)
      Ok(Missing), Ok(_) ->
        violation("row-missing", "slot " <> int.to_string(slot))
      Ok(Found(found)), Error(Nil) ->
        violation(
          "row-extra",
          "slot " <> int.to_string(slot) <> " holds " <> string.inspect(found),
        )
      Ok(Found(found)), Ok(state) ->
        case found == state {
          True -> Ok(Nil)
          False ->
            violation(
              "row-state",
              "slot "
                <> int.to_string(slot)
                <> " holds "
                <> string.inspect(found)
                <> ", expected "
                <> string.inspect(state),
            )
        }
      Error(error), _ -> violation("read", string.inspect(error))
    }
  })
}

// The scope the ledger stores matches the model's incarnation, token and
// stage, which is what makes the model's admission verdicts meaningful.
fn check_scope(
  ledger: Ledger,
  model: Model,
  session: Int,
) -> Result(Nil, statem.Violation) {
  case
    exec_ledger.scope(ledger, session_name(session)),
    dict.get(model.scopes, session % 2)
  {
    Ok(None), Error(Nil) -> Ok(Nil)
    Ok(Some(exec_ledger.Scope(incarnation:, state:, token: stored, ..))),
      Ok(Held(incarnation: expected, token: index, state: expected_state))
    ->
      case
        incarnation == expected
        && state == expected_state
        && stored == token(index)
      {
        True -> Ok(Nil)
        False ->
          violation(
            "scope",
            "ledger holds incarnation "
              <> int.to_string(incarnation)
              <> " "
              <> string.inspect(state)
              <> ", model expects incarnation "
              <> int.to_string(expected)
              <> " "
              <> string.inspect(expected_state),
          )
      }
    Ok(found), expected ->
      violation(
        "scope",
        "ledger holds "
          <> string.inspect(found)
          <> ", model expects "
          <> string.inspect(expected),
      )
    Error(error), _ -> violation("read", string.inspect(error))
  }
}

fn session_of(command: Command) -> Int {
  case command {
    Attach(session:, ..)
    | Admit(session:, ..)
    | Finish(session:, ..)
    | MarkUnknown(session:, ..)
    | Ack(session:, ..)
    | BeginClose(session:, ..)
    | FinishClose(session:, ..) -> session
  }
}

fn execute(
  ledger: Ledger,
  model: Model,
  command: Command,
) -> Result(Ledger, statem.Violation) {
  let #(expected, after) = step(model, command)
  let observed = perform(ledger, model, command)
  use Nil <- result.try(check_reply(command, expected, observed))
  use Nil <- result.try(check_rows(ledger, after, session_of(command)))
  use Nil <- result.try(check_scope(ledger, after, session_of(command)))
  Ok(ledger)
}

fn skew() -> qcheck.Generator(Int) {
  qcheck.bounded_int(from: 0, to: 3)
  |> qcheck.map(fn(n) {
    case n {
      3 -> 2
      2 -> 1
      _ -> 0
    }
  })
}

fn token_choice() -> qcheck.Generator(TokenChoice) {
  qcheck.bounded_int(from: 0, to: 5)
  |> qcheck.map(fn(n) {
    case n {
      0 | 1 | 2 -> Own
      _ -> Pooled(n - 3)
    }
  })
}

// Commands never read the model: every choice is an index the model resolves,
// so any subsequence of a generated list is admissible. The weights are the
// old harness's, simplest first so shrinking prefers an attach.
fn command() -> qcheck.Generator(Command) {
  let session = qcheck.bounded_int(from: 0, to: 1)
  let slot = qcheck.bounded_int(from: 0, to: 3)
  let outcome =
    qcheck.bounded_int(from: 0, to: 2)
    |> qcheck.map(fn(n) {
      case n {
        2 -> UnknownCleanup(1)
        _ -> AllRetired
      }
    })
  qcheck.from_weighted_generators(
    #(
      4,
      qcheck.map3(session, skew(), token_choice(), fn(session, skew, choice) {
        Attach(session:, skew:, choice:)
      }),
    ),
    [
      #(
        6,
        qcheck.map4(
          session,
          skew(),
          token_choice(),
          slot,
          fn(session, skew, choice, slot) {
            Admit(session:, skew:, choice:, slot:)
          },
        ),
      ),
      #(
        3,
        qcheck.map2(session, slot, fn(session, slot) { Finish(session:, slot:) }),
      ),
      #(
        2,
        qcheck.map2(session, slot, fn(session, slot) { Ack(session:, slot:) }),
      ),
      #(
        1,
        qcheck.map2(session, slot, fn(session, slot) {
          MarkUnknown(session:, slot:)
        }),
      ),
      #(
        1,
        qcheck.map2(session, skew(), fn(session, skew) {
          BeginClose(session:, skew:)
        }),
      ),
      #(
        3,
        qcheck.map3(session, skew(), outcome, fn(session, skew, outcome) {
          FinishClose(session:, skew:, outcome:)
        }),
      ),
    ],
  )
}

fn ledger_spec() -> statem.Spec(Model, Command, Ledger) {
  statem.Spec(
    initial: Model(scopes: dict.new(), rows: dict.new()),
    command: fn(_model) { command() },
    precondition: fn(_model, _command) { statem.Admit },
    // Each execution opens a ledger of its own in memory, so nothing a run
    // or a shrink candidate wrote can reach the next.
    next_model: fn(model, command) { step(model, command).1 },
    new_sut: fn() { open_at(":memory:") },
    execute:,
    finish: fn(_ledger, _model) { Ok(Nil) },
    teardown: fn(ledger) {
      let _closed = exec_ledger.close(ledger)
      Nil
    },
  )
}

fn ledger_config() -> statem.Config {
  statem.default_config(seed: sequence_seed)
  |> statem.with_test_count(sequence_count)
  |> statem.with_max_commands(sequence_length)
}

pub fn random_sequences_never_admit_a_key_twice_or_under_a_stale_token_test() {
  case statem.check(ledger_spec(), ledger_config()) {
    Ok(Nil) -> Nil
    Error(failure) ->
      panic as statem.report(failure, fn(command) { string.inspect(command) })
  }
}

// A property that never reaches an outcome proves nothing about it, so the
// model is replayed over the generated lists and must predict every kind of
// answer the properties judge, refusals and tombstoned keys among them.
pub fn the_generated_sequences_reach_every_outcome_test() {
  let config = ledger_config()
  let replies =
    upto(0, config.test_count - 1)
    |> list.flat_map(fn(run) {
      let spec = ledger_spec()
      let #(_, answered) =
        list.map_fold(
          statem.commands(spec, config, run),
          spec.initial,
          fn(model, command) {
            let #(reply, next) = step(model, command)
            #(next, #(command, reply))
          },
        )
      answered
    })
  let reached = fn(want: Reply) {
    list.any(replies, fn(pair) { pair.1 == want })
  }
  assert reached(Attachment(Created))
  assert reached(Attachment(Rebound))
  assert reached(Attachment(Reopened))
  assert reached(Decision(Fresh))
  assert reached(Decision(Existing(Admitted)))
  assert reached(Decision(Existing(Terminal(bytes("ok")))))
  assert reached(Decision(Existing(Unknown)))
  assert reached(Decision(Existing(exec_ledger.Acked)))
  assert reached(Applied)
  assert list.any(replies, fn(pair) {
    pair.1 == Refused && string.starts_with(string.inspect(pair.0), "Admit(")
  })
}

pub fn a_session_without_a_scope_reads_as_none_test() {
  let ledger = open_at(path("no-scope"))
  assert exec_ledger.scope(ledger, "nobody") == Ok(None)
}

pub fn a_fence_with_no_row_inserts_a_terminal_row_and_blocks_admission_test() {
  let file = path("fence-first")
  let ledger = open_at(file)
  attached(ledger)
  let key = call(0)
  assert exec_ledger.query_or_fence(ledger, key, 0, bytes("did not run"))
    == Ok(Fenced)
  assert count(file, "SELECT count(*) FROM call WHERE state = 'terminal'") == 1
  assert exec_ledger.query(ledger, key)
    == Ok(Found(Terminal(bytes("did not run"))))

  // A stale `Run` that arrives after the fence finds the key taken. It gets
  // the stored outcome back and is never told to start.
  assert admit(ledger, key, 64) == Ok(Existing(Terminal(bytes("did not run"))))
  assert count(file, "SELECT count(*) FROM call") == 1

  // A second fence for the same key changes nothing and says what stands.
  assert exec_ledger.query_or_fence(ledger, key, 0, bytes("different"))
    == Ok(Standing(Terminal(bytes("did not run"))))
}

pub fn a_fence_after_the_run_reports_the_row_it_finds_test() {
  let file = path("run-first")
  let ledger = open_at(file)
  attached(ledger)
  let key = call(0)
  assert admit(ledger, key, 64) == Ok(Fresh)

  // The stale `Run` got in first: recovery learns the call is live and writes
  // nothing.
  assert exec_ledger.query_or_fence(ledger, key, 0, bytes("did not run"))
    == Ok(Standing(Admitted))
  assert count(file, "SELECT count(*) FROM call WHERE state = 'admitted'") == 1
  assert exec_ledger.finish(ledger, key, bytes("done")) == Ok(Nil)
  assert exec_ledger.query_or_fence(ledger, key, 0, bytes("did not run"))
    == Ok(Standing(Terminal(bytes("done"))))
}

pub fn a_fence_row_is_acknowledged_like_any_settled_row_test() {
  let file = path("fence-ack")
  let ledger = open_at(file)
  attached(ledger)
  let assert Ok(Fenced) =
    exec_ledger.query_or_fence(ledger, call(0), 0, bytes("did not run"))
  let assert Ok(unacked) = exec_ledger.unacked(ledger, "s")
  assert unacked.terminal == [call(0)]
  assert exec_ledger.ack(ledger, call(0)) == Ok(Nil)
  assert exec_ledger.query(ledger, call(0)) == Ok(Found(exec_ledger.Acked))
}

pub fn a_fence_needs_the_scope_at_the_callers_incarnation_test() {
  let file = path("fence-scope")
  let ledger = open_at(file)
  assert exec_ledger.query_or_fence(ledger, call(0), 0, bytes("x"))
    == Error(exec_ledger.NoSuchScope)
  attached(ledger)
  assert exec_ledger.query_or_fence(ledger, call(0), 1, bytes("x"))
    == Error(exec_ledger.StaleIncarnation(0))
  assert exec_ledger.query_or_fence(
      ledger,
      Key(..call(0), source_index: -1),
      0,
      bytes("x"),
    )
    == Error(exec_ledger.Invalid("call source index is negative"))
  assert count(file, "SELECT count(*) FROM call") == 0
}

pub fn a_fence_still_answers_in_a_closed_scope_test() {
  let ledger = open_at(path("fence-closed"))
  attached(ledger)
  assert exec_ledger.begin_close(ledger, "s", "/work", 0) == Ok(Nil)
  assert exec_ledger.finish_close(ledger, "s", "/work", 0, AllRetired)
    == Ok(Nil)

  // Recovery of an orphaned call may run after the scope closed, and a row
  // never moves, so the key is fenced and queryable all the same.
  assert exec_ledger.query_or_fence(ledger, call(0), 0, bytes("did not run"))
    == Ok(Fenced)
  assert exec_ledger.query(ledger, call(0))
    == Ok(Found(Terminal(bytes("did not run"))))
}

pub fn a_stop_turns_a_running_call_lost_and_frees_its_bytes_test() {
  let file = path("stop-running")
  let ledger = open_at(file)
  attached(ledger)
  assert exec_ledger.admit(
      ledger,
      call(0),
      0,
      token(1),
      "execution",
      4096,
      limits(),
    )
    == Ok(Fresh)
  assert exec_ledger.admitted(ledger, "s", "execution") == Ok([call(0)])
  assert exec_ledger.stop_or_fence(ledger, call(0), 0, "execution")
    == Ok(exec_ledger.Stopped)
  assert exec_ledger.query(ledger, call(0)) == Ok(Found(Unknown))
  assert count(file, "SELECT sum(outcome_bytes) FROM call") == 0
  assert exec_ledger.admitted(ledger, "s", "execution") == Ok([])

  // A second stop finds the lost row and writes nothing.
  assert exec_ledger.stop_or_fence(ledger, call(0), 0, "execution")
    == Ok(exec_ledger.Untouched(Unknown))
}

pub fn a_stop_for_an_execution_leaves_a_running_tool_call_alone_test() {
  let file = path("stop-other-kind")
  let ledger = open_at(file)
  attached(ledger)
  assert exec_ledger.admit(ledger, call(0), 0, token(1), "bash", 4096, limits())
    == Ok(Fresh)

  // A stop names a background execution. The row under this key is a tool
  // call that is still running, so the stop writes nothing and the call keeps
  // its row and its reservation.
  assert exec_ledger.stop_or_fence(ledger, call(0), 0, "execution")
    == Ok(exec_ledger.Untouched(Admitted))
  assert exec_ledger.query(ledger, call(0)) == Ok(Found(Admitted))
  assert exec_ledger.admitted(ledger, "s", "bash") == Ok([call(0)])
  assert count(file, "SELECT sum(outcome_bytes) FROM call") == 4096
}

pub fn a_stop_with_no_row_bars_the_key_from_a_later_start_test() {
  let file = path("stop-first")
  let ledger = open_at(file)
  attached(ledger)
  assert exec_ledger.stop_or_fence(ledger, call(0), 0, "execution")
    == Ok(exec_ledger.Barred)
  assert count(file, "SELECT count(*) FROM call WHERE state = 'unknown'") == 1
  assert count(file, "SELECT sum(outcome_bytes) FROM call") == 0

  // A start still in flight from a dead worker arrives after the stop. It finds
  // the key lost and is never told to start, whatever token it carries.
  assert exec_ledger.admit(
      ledger,
      call(0),
      0,
      token(1),
      "execution",
      4096,
      limits(),
    )
    == Ok(Existing(Unknown))

  // The barred row is listed as lost, and the acknowledgement retires it into a
  // tombstone like any other.
  let assert Ok(unacked) = exec_ledger.unacked(ledger, "s")
  assert unacked.unknown == [call(0)]
  assert exec_ledger.ack(ledger, call(0)) == Ok(Nil)
  assert exec_ledger.stop_or_fence(ledger, call(0), 0, "execution")
    == Ok(exec_ledger.Untouched(exec_ledger.Acked))
}

pub fn a_stop_leaves_a_settled_call_alone_test() {
  let ledger = open_at(path("stop-settled"))
  attached(ledger)
  assert admit(ledger, call(0), 64) == Ok(Fresh)
  assert exec_ledger.finish(ledger, call(0), bytes("done")) == Ok(Nil)
  assert exec_ledger.stop_or_fence(ledger, call(0), 0, "execution")
    == Ok(exec_ledger.Untouched(Terminal(bytes("done"))))
  assert exec_ledger.query(ledger, call(0))
    == Ok(Found(Terminal(bytes("done"))))
}

pub fn a_stop_needs_the_scope_at_the_callers_incarnation_test() {
  let file = path("stop-scope")
  let ledger = open_at(file)
  assert exec_ledger.stop_or_fence(ledger, call(0), 0, "execution")
    == Error(exec_ledger.NoSuchScope)
  attached(ledger)
  assert exec_ledger.stop_or_fence(ledger, call(0), 1, "execution")
    == Error(exec_ledger.StaleIncarnation(0))
  assert count(file, "SELECT count(*) FROM call") == 0
}

pub fn admitted_lists_only_running_calls_of_the_named_kind_test() {
  let ledger = open_at(path("admitted-kind"))
  attached(ledger)
  assert admit(ledger, call(0), 64) == Ok(Fresh)
  assert exec_ledger.admit(
      ledger,
      call(1),
      0,
      token(1),
      "execution",
      64,
      limits(),
    )
    == Ok(Fresh)
  assert exec_ledger.admit(
      ledger,
      call(2),
      0,
      token(1),
      "execution",
      64,
      limits(),
    )
    == Ok(Fresh)
  assert exec_ledger.finish(ledger, call(2), bytes("done")) == Ok(Nil)
  assert exec_ledger.admitted(ledger, "s", "execution") == Ok([call(1)])
  assert exec_ledger.admitted(ledger, "s", "bash") == Ok([call(0)])
  assert exec_ledger.admitted(ledger, "other", "execution") == Ok([])
}

pub fn two_connections_racing_a_fence_and_an_admit_agree_test() {
  let file = path("fence-race")
  let first = open_at(file)
  let second = open_at(file)
  attached(first)
  let outcomes = process.new_subject()
  let keys = upto(0, 29)
  let _fencer =
    process.spawn_unlinked(fn() {
      list.each(keys, fn(n) {
        process.send(outcomes, #(
          n,
          Fencer,
          exec_ledger.query_or_fence(first, call(n), 0, bytes("no")),
        ))
      })
    })
  let _admitter =
    process.spawn_unlinked(fn() {
      list.each(keys, fn(n) {
        let admitted = case admit(second, call(n), 8) {
          Ok(Fresh) -> Ok(Fenced)
          Ok(Existing(state)) -> Ok(Standing(state))
          Error(error) -> Error(error)
        }
        process.send(outcomes, #(n, Admitter, admitted))
      })
    })
  let gathered = gather(outcomes, 60, [])

  // For every key exactly one side won: either the fence inserted (and the
  // admit found a terminal row) or the admit inserted (and the fence found it
  // admitted). Never both inserting, never neither.
  list.each(keys, fn(n) {
    let mine = list.filter(gathered, fn(entry) { entry.0 == n })
    let wins =
      list.filter(mine, fn(entry) { entry.2 == Ok(Fenced) })
      |> list.length
    assert wins == 1
  })
}

type Side {
  Fencer
  Admitter
}

fn gather(
  from: process.Subject(
    #(Int, Side, Result(exec_ledger.Fencing, exec_ledger.Error)),
  ),
  remaining: Int,
  seen: List(#(Int, Side, Result(exec_ledger.Fencing, exec_ledger.Error))),
) -> List(#(Int, Side, Result(exec_ledger.Fencing, exec_ledger.Error))) {
  case remaining {
    0 -> seen
    _ -> {
      let assert Ok(entry) = process.receive(from, 5000) as "a racer reports"
      gather(from, remaining - 1, [entry, ..seen])
    }
  }
}

// --- release ---------------------------------------------------------------

pub fn releasing_a_closing_scope_closes_it_and_the_next_attach_reopens_test() {
  let ledger = open_at(path("release-closing"))
  attached(ledger)
  assert exec_ledger.begin_close(ledger, "s", "/work", 0) == Ok(Nil)
  assert exec_ledger.attach(ledger, "s", "/work", 1, token(2), limits())
    == Error(exec_ledger.ScopeClosing)

  assert exec_ledger.release(ledger, "s", 5000)
    == Ok(exec_ledger.Released(
      workspace: "/work",
      incarnation: 0,
      was: exec_ledger.Closing,
    ))

  assert exec_ledger.attach(ledger, "s", "/work", 1, token(2), limits())
    == Ok(exec_ledger.Attached(how: Reopened, terminal: [], unknown: []))
  assert exec_ledger.releases(ledger, "s")
    == Ok([
      exec_ledger.Release(
        workspace: "/work",
        incarnation: 0,
        was: exec_ledger.Closing,
        released_at_ms: 5000,
      ),
    ])
}

pub fn releasing_an_unknown_cleanup_frees_its_slot_and_the_session_test() {
  let ledger = open_at(path("release-unknown"))
  let one_slot = Limits(..limits(), max_unclean_scopes: 1)
  let assert Ok(_) =
    exec_ledger.attach(ledger, "s", "/work", 0, token(1), one_slot)
  assert exec_ledger.begin_close(ledger, "s", "/work", 0) == Ok(Nil)
  assert exec_ledger.finish_close(ledger, "s", "/work", 0, UnknownCleanup(0))
    == Ok(Nil)

  // The scope holds the only slot and refuses its own session.
  assert exec_ledger.attach(ledger, "other", "/work", 0, token(2), one_slot)
    == Error(exec_ledger.CapacityExhausted(1))
  assert exec_ledger.attach(ledger, "s", "/work", 1, token(2), one_slot)
    == Error(exec_ledger.UncleanClose(0))

  assert exec_ledger.release(ledger, "s", 7000)
    == Ok(exec_ledger.Released(
      workspace: "/work",
      incarnation: 0,
      was: Closed(UnknownCleanup(0)),
    ))

  // The slot is free again, and the session reopens one incarnation higher.
  assert exec_ledger.attach(ledger, "other", "/work", 0, token(3), one_slot)
    == Ok(exec_ledger.Attached(how: Created, terminal: [], unknown: []))
  assert exec_ledger.scope(ledger, "s")
    == Ok(
      Some(exec_ledger.Scope(
        session: "s",
        workspace: "/work",
        incarnation: 0,
        state: Closed(AllRetired),
        token: token(1),
      )),
    )
  assert exec_ledger.releases(ledger, "s")
    == Ok([
      exec_ledger.Release(
        workspace: "/work",
        incarnation: 0,
        was: Closed(UnknownCleanup(0)),
        released_at_ms: 7000,
      ),
    ])
}

pub fn a_scope_that_is_not_stuck_is_not_released_test() {
  let ledger = open_at(path("release-refused"))
  attached(ledger)

  // An open scope may belong to a running session.
  assert exec_ledger.release(ledger, "s", 1)
    == Error(exec_ledger.NotReleasable(Open))
  assert exec_ledger.begin_close(ledger, "s", "/work", 0) == Ok(Nil)
  assert exec_ledger.finish_close(ledger, "s", "/work", 0, AllRetired)
    == Ok(Nil)

  // A cleanly closed scope has nothing to release.
  assert exec_ledger.release(ledger, "s", 2)
    == Error(exec_ledger.NotReleasable(Closed(AllRetired)))
  assert exec_ledger.release(ledger, "missing", 3)
    == Error(exec_ledger.NoSuchScope)

  // Every refusal left the record empty.
  assert exec_ledger.releases(ledger, "s") == Ok([])
}

pub fn a_release_is_one_transaction_test() {
  let file = path("release-atomic")
  let ledger = open_at(file)
  attached(ledger)
  assert exec_ledger.begin_close(ledger, "s", "/work", 0) == Ok(Nil)

  // A record that cannot be written takes the state change back with it.
  tamper(file, "DROP TABLE scope_release;")
  let assert Error(exec_ledger.Database(_)) =
    exec_ledger.release(ledger, "s", 9)
    as "the missing table fails the release"
  let assert Ok(Some(scope)) = exec_ledger.scope(ledger, "s")
    as "the scope still reads"
  assert scope.state == Closing
}

pub fn a_version_one_ledger_gains_the_release_record_on_open_test() {
  let file = path("release-migrate")
  let first = open_at(file)
  attached(first)
  assert exec_ledger.begin_close(first, "s", "/work", 0) == Ok(Nil)
  let assert Ok(Nil) = exec_ledger.close(first) as "the ledger closes"

  // What an executor wrote before the release record existed.
  tamper(
    file,
    "DROP TABLE scope_release; DROP TABLE call_ack; DROP TABLE scope_worktree; PRAGMA user_version = 1;",
  )
  let migrated = open_at(file)

  assert exec_ledger.releases(migrated, "s") == Ok([])
  assert exec_ledger.release(migrated, "s", 11)
    == Ok(exec_ledger.Released(
      workspace: "/work",
      incarnation: 0,
      was: exec_ledger.Closing,
    ))
  assert count(file, "PRAGMA user_version") == 4
}

// --- acknowledgement tombstones ----------------------------------------------

pub fn an_acknowledged_key_is_never_admitted_again_in_its_incarnation_test() {
  let file = path("tombstone")
  let ledger = open_at(file)
  attached(ledger)
  assert admit(ledger, call(0), 64) == Ok(Fresh)
  assert exec_ledger.finish(ledger, call(0), bytes("done")) == Ok(Nil)
  assert exec_ledger.ack(ledger, call(0)) == Ok(Nil)

  // The row went and a tombstone stands in its place, holding no bytes.
  assert count(file, "SELECT count(*) FROM call") == 0
  assert count(file, "SELECT count(*) FROM call_ack") == 1
  assert count(file, "SELECT COALESCE(SUM(outcome_bytes), 0) FROM call") == 0

  // A `Run` that was still in flight finds the key taken and starts nothing.
  assert admit(ledger, call(0), 64) == Ok(Existing(exec_ledger.Acked))
  assert count(file, "SELECT count(*) FROM call") == 0
  assert exec_ledger.query(ledger, call(0)) == Ok(Found(exec_ledger.Acked))
  assert exec_ledger.unacked(ledger, "s")
    == Ok(exec_ledger.Unacked(terminal: [], unknown: []))
}

pub fn a_fence_that_was_acknowledged_still_blocks_a_late_run_test() {
  // Recovery fenced the key and told the model it did not run, the
  // acknowledgement followed, and the dead runtime's `Run` for the same key
  // arrives last, under the same attach token.
  let ledger = open_at(path("fence-then-ack"))
  attached(ledger)
  let assert Ok(Fenced) =
    exec_ledger.query_or_fence(ledger, call(0), 0, bytes("did not run"))
  assert exec_ledger.ack(ledger, call(0)) == Ok(Nil)

  assert admit(ledger, call(0), 8) == Ok(Existing(exec_ledger.Acked))
  assert exec_ledger.query_or_fence(ledger, call(0), 0, bytes("again"))
    == Ok(Standing(exec_ledger.Acked))
}

pub fn an_acknowledgement_of_a_live_or_missing_key_leaves_no_tombstone_test() {
  let file = path("tombstone-none")
  let ledger = open_at(file)
  attached(ledger)
  assert admit(ledger, call(0), 8) == Ok(Fresh)
  assert exec_ledger.ack(ledger, call(0)) == Ok(Nil)
  assert exec_ledger.ack(ledger, call(1)) == Ok(Nil)
  assert count(file, "SELECT count(*) FROM call_ack") == 0
  assert exec_ledger.query(ledger, call(0)) == Ok(Found(Admitted))
}

pub fn an_unknown_row_is_acknowledged_into_a_tombstone_too_test() {
  let file = path("tombstone-unknown")
  let ledger = open_at(file)
  attached(ledger)
  assert admit(ledger, call(0), 8) == Ok(Fresh)
  assert exec_ledger.mark_unknown(ledger, call(0)) == Ok(Nil)
  assert exec_ledger.ack(ledger, call(0)) == Ok(Nil)
  assert admit(ledger, call(0), 8) == Ok(Existing(exec_ledger.Acked))
  assert count(file, "SELECT count(*) FROM call_ack") == 1
}

pub fn a_reopen_at_a_new_incarnation_drops_the_tombstones_test() {
  let file = path("tombstone-reopen")
  let ledger = open_at(file)
  attached(ledger)
  assert admit(ledger, call(0), 8) == Ok(Fresh)
  assert exec_ledger.finish(ledger, call(0), bytes("done")) == Ok(Nil)

  // The clean close drops what is there, and a later acknowledgement of a row
  // the close left behind makes a tombstone in the closed scope.
  assert exec_ledger.begin_close(ledger, "s", "/work", 0) == Ok(Nil)
  assert exec_ledger.finish_close(ledger, "s", "/work", 0, AllRetired)
    == Ok(Nil)
  assert exec_ledger.ack(ledger, call(0)) == Ok(Nil)
  assert count(file, "SELECT count(*) FROM call_ack") == 1

  let assert Ok(exec_ledger.Attached(how: Reopened, ..)) =
    exec_ledger.attach(ledger, "s", "/work", 1, token(2), limits())
    as "the scope reopens"
  assert count(file, "SELECT count(*) FROM call_ack") == 0
  assert exec_ledger.query(ledger, call(0)) == Ok(Missing)
  assert exec_ledger.admit(ledger, call(0), 1, token(2), "bash", 8, limits())
    == Ok(Fresh)
}

pub fn a_clean_close_and_a_release_drop_the_tombstones_but_an_unclean_one_does_not_test() {
  let file = path("tombstone-close")
  let ledger = open_at(file)
  attached(ledger)
  assert admit(ledger, call(0), 8) == Ok(Fresh)
  assert exec_ledger.finish(ledger, call(0), bytes("done")) == Ok(Nil)
  assert exec_ledger.ack(ledger, call(0)) == Ok(Nil)
  assert exec_ledger.begin_close(ledger, "s", "/work", 0) == Ok(Nil)

  // Unknown cleanup proves nothing, so the tombstones stay.
  assert exec_ledger.finish_close(ledger, "s", "/work", 0, UnknownCleanup(1))
    == Ok(Nil)
  assert count(file, "SELECT count(*) FROM call_ack") == 1

  // The release is a clean close by the operator's word.
  let assert Ok(_released) = exec_ledger.release(ledger, "s", 5)
    as "the scope is released"
  assert count(file, "SELECT count(*) FROM call_ack") == 0

  let other = open_at(path("tombstone-close-clean"))
  attached(other)
  assert exec_ledger.admit(other, call(0), 0, token(1), "bash", 8, limits())
    == Ok(Fresh)
  assert exec_ledger.finish(other, call(0), bytes("done")) == Ok(Nil)
  assert exec_ledger.ack(other, call(0)) == Ok(Nil)
  assert exec_ledger.begin_close(other, "s", "/work", 0) == Ok(Nil)
  assert exec_ledger.finish_close(other, "s", "/work", 0, AllRetired) == Ok(Nil)
  assert exec_ledger.query(other, call(0)) == Ok(Missing)
}

pub fn a_version_two_ledger_gains_the_tombstone_table_on_open_test() {
  let file = path("tombstone-migrate")
  let first = open_at(file)
  attached(first)
  assert admit(first, call(0), 8) == Ok(Fresh)
  assert exec_ledger.finish(first, call(0), bytes("done")) == Ok(Nil)
  let assert Ok(Nil) = exec_ledger.close(first) as "the ledger closes"

  // What an executor wrote before acknowledgements left tombstones.
  tamper(
    file,
    "DROP TABLE call_ack; DROP TABLE scope_worktree; PRAGMA user_version = 2;",
  )
  let migrated = open_at(file)

  assert exec_ledger.ack(migrated, call(0)) == Ok(Nil)
  assert exec_ledger.query(migrated, call(0)) == Ok(Found(exec_ledger.Acked))
  assert count(file, "PRAGMA user_version") == 4
}

// --- summary ---------------------------------------------------------------

fn counts(open: Int, closing: Int, clean: Int, unknown: Int) {
  exec_ledger.ScopeCounts(
    open:,
    closing:,
    closed_clean: clean,
    closed_unknown: unknown,
  )
}

fn no_trees() -> exec_ledger.TreeCounts {
  exec_ledger.TreeCounts(
    creating: 0,
    present: 0,
    kept: 0,
    removing: 0,
    removed: 0,
  )
}

pub fn an_empty_ledger_summarises_to_zeros_test() {
  let ledger = open_at(path("summary-empty"))
  assert exec_ledger.summary(ledger)
    == Ok(exec_ledger.Summary(
      scopes: counts(0, 0, 0, 0),
      unclean: [],
      bytes: 0,
      unacknowledged: 0,
      trees: no_trees(),
    ))
}

pub fn scopes_are_counted_by_state_and_the_blocking_ones_are_listed_test() {
  let ledger = open_at(path("summary-scopes"))

  // Session 0 stays open, 1 is closing, 2 closed clean, 3 and 4 closed with
  // different counts of children left, which group apart in the table.
  list.each(upto(0, 4), fn(n) {
    let assert Ok(_) = attach_scope(ledger, n) as "the scope attaches"
    Nil
  })
  close_cleanly(ledger, 2)
  assert exec_ledger.begin_close(ledger, scope_name(1), "/work", 0) == Ok(Nil)
  list.each([#(3, 0), #(4, 2)], fn(entry) {
    let #(n, left) = entry
    let assert Ok(Nil) =
      exec_ledger.begin_close(ledger, scope_name(n), "/work", 0)
    let assert Ok(Nil) =
      exec_ledger.finish_close(
        ledger,
        scope_name(n),
        "/work",
        0,
        UnknownCleanup(left),
      )
    Nil
  })

  assert exec_ledger.summary(ledger)
    == Ok(exec_ledger.Summary(
      scopes: counts(1, 1, 1, 2),
      unclean: [
        exec_ledger.UncleanScope(session: scope_name(1), state: Closing),
        exec_ledger.UncleanScope(
          session: scope_name(3),
          state: Closed(UnknownCleanup(0)),
        ),
        exec_ledger.UncleanScope(
          session: scope_name(4),
          state: Closed(UnknownCleanup(2)),
        ),
      ],
      bytes: 0,
      unacknowledged: 0,
      trees: no_trees(),
    ))
}

pub fn a_release_takes_a_scope_out_of_the_blocking_list_test() {
  let ledger = open_at(path("summary-release"))
  attached(ledger)
  assert exec_ledger.begin_close(ledger, "s", "/work", 0) == Ok(Nil)
  let assert Ok(before) = exec_ledger.summary(ledger)
  assert before.scopes == counts(0, 1, 0, 0)
  assert list.length(before.unclean) == 1

  let assert Ok(_) = exec_ledger.release(ledger, "s", 5000)
  let assert Ok(after) = exec_ledger.summary(ledger)
  assert after.scopes == counts(0, 0, 1, 0)
  assert after.unclean == []
}

pub fn bytes_and_unacknowledged_calls_follow_the_calls_test() {
  let ledger = open_at(path("summary-calls"))
  attached(ledger)

  // One admitted reservation, one terminal outcome and one lost call.
  assert admit(ledger, call(0), 100) == Ok(Fresh)
  assert admit(ledger, call(1), 200) == Ok(Fresh)
  assert admit(ledger, call(2), 300) == Ok(Fresh)
  assert exec_ledger.finish(ledger, call(1), bytes("done")) == Ok(Nil)
  assert exec_ledger.mark_unknown(ledger, call(2)) == Ok(Nil)

  // The admitted row holds its reservation, the terminal row its real size,
  // and the lost row nothing. Only the settled and lost rows are unacknowledged.
  let assert Ok(held) = exec_ledger.summary(ledger)
  assert held.bytes == 100 + 4
  assert held.unacknowledged == 2

  // An acknowledgement removes the outcome and its bytes.
  assert exec_ledger.ack(ledger, call(1)) == Ok(Nil)
  let assert Ok(acked) = exec_ledger.summary(ledger)
  assert acked.bytes == 100
  assert acked.unacknowledged == 1
}

pub fn a_scope_whose_state_and_outcome_disagree_is_a_malformed_row_test() {
  let file = path("summary-malformed")
  let ledger = open_at(file)
  attached(ledger)
  tamper(file, "UPDATE scope SET state = 'closed', close_outcome = 'bogus';")
  assert exec_ledger.summary(ledger)
    == Error(exec_ledger.MalformedRow(
      "scope state does not match its close outcome",
    ))
}

// --- worktree records (protocol-change/095) ------------------------------------

fn tree(session: String, state: exec_ledger.TreeState) -> exec_ledger.Tree {
  exec_ledger.Tree(
    session:,
    workspace: "repo",
    path: "/state/worktrees/repo/" <> session,
    branch: "loom/" <> session,
    state:,
  )
}

pub fn a_session_with_no_tree_reads_none_test() {
  let ledger = open_at(path("tree-none"))
  assert exec_ledger.tree(ledger, "s") == Ok(None)
  assert exec_ledger.all_trees(ledger) == Ok([])
}

pub fn a_tree_record_is_replaced_in_place_as_its_state_moves_test() {
  let ledger = open_at(path("tree-moves"))
  let states = [
    exec_ledger.Creating,
    exec_ledger.Present,
    exec_ledger.Kept,
    exec_ledger.Removing,
    exec_ledger.Removed,
  ]
  list.each(states, fn(state) {
    assert exec_ledger.record_tree(ledger, tree("s", state)) == Ok(Nil)
    assert exec_ledger.tree(ledger, "s") == Ok(Some(tree("s", state)))
  })
  assert exec_ledger.all_trees(ledger) == Ok([tree("s", exec_ledger.Removed)])
}

pub fn trees_are_listed_by_workspace_and_counted_by_state_test() {
  let ledger = open_at(path("tree-list"))
  let other =
    exec_ledger.Tree(..tree("c", exec_ledger.Present), workspace: "docs")
  list.each(
    [
      tree("b", exec_ledger.Kept),
      tree("a", exec_ledger.Present),
      other,
      tree("d", exec_ledger.Present),
    ],
    fn(each) {
      let assert Ok(Nil) = exec_ledger.record_tree(ledger, each)
      Nil
    },
  )
  assert exec_ledger.workspace_trees(ledger, "repo")
    == Ok([
      tree("a", exec_ledger.Present),
      tree("b", exec_ledger.Kept),
      tree("d", exec_ledger.Present),
    ])
  let assert Ok(summary) = exec_ledger.summary(ledger)
  assert summary.trees
    == exec_ledger.TreeCounts(
      creating: 0,
      present: 3,
      kept: 1,
      removing: 0,
      removed: 0,
    )
}

pub fn a_record_without_a_session_or_path_is_refused_test() {
  let ledger = open_at(path("tree-invalid"))
  let blank = exec_ledger.Tree(..tree("s", exec_ledger.Creating), path: "")
  let assert Error(exec_ledger.Invalid(_)) =
    exec_ledger.record_tree(ledger, blank)
  assert exec_ledger.all_trees(ledger) == Ok([])
}

pub fn a_stored_state_this_build_does_not_know_fails_closed_test() {
  let file = path("tree-damaged")
  let ledger = open_at(file)
  assert exec_ledger.record_tree(ledger, tree("s", exec_ledger.Present))
    == Ok(Nil)
  tamper(file, "UPDATE scope_worktree SET state = 'lost';")
  let assert Error(exec_ledger.MalformedRow(_)) = exec_ledger.tree(ledger, "s")
}

pub fn a_second_connection_shares_records_and_recovers_nothing_test() {
  let file = path("tree-connect")
  let host = open_at(file)
  attached(host)
  assert admit(host, call(0), 8) == Ok(Fresh)

  // The plane's connection sees the host's file and writes its own rows, and
  // opening it leaves the host's live call `admitted`, where `open` would have
  // turned it unknown.
  let assert Ok(plane) = exec_ledger.connect(file)
  assert exec_ledger.record_tree(plane, tree("s", exec_ledger.Creating))
    == Ok(Nil)
  assert exec_ledger.tree(host, "s")
    == Ok(Some(tree("s", exec_ledger.Creating)))
  assert exec_ledger.query(host, call(0)) == Ok(Found(Admitted))
}

pub fn a_second_connection_refuses_a_file_that_is_not_the_current_ledger_test() {
  let missing = path("tree-connect-fresh")
  let assert Error(exec_ledger.Unsupported) = exec_ledger.connect(missing)

  let old = path("tree-connect-old")
  let first = open_at(old)
  let assert Ok(Nil) = exec_ledger.close(first) as "the ledger closes"
  tamper(old, "PRAGMA user_version = 3;")
  let assert Error(exec_ledger.Unsupported) = exec_ledger.connect(old)
}

pub fn a_version_three_ledger_gains_the_worktree_table_on_open_test() {
  let file = path("worktree-migrate")
  let first = open_at(file)
  attached(first)
  let assert Ok(Nil) = exec_ledger.close(first) as "the ledger closes"

  // What an executor wrote before worktree workspaces existed.
  tamper(file, "DROP TABLE scope_worktree; PRAGMA user_version = 3;")
  let migrated = open_at(file)

  assert exec_ledger.tree(migrated, "s") == Ok(None)
  assert exec_ledger.record_tree(migrated, tree("s", exec_ledger.Present))
    == Ok(Nil)
  assert count(file, "PRAGMA user_version") == 4
}
