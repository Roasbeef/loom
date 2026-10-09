//// The execution ledger's rules, exercised against real SQLite files.
////
//// Each test opens a ledger in its own scratch directory and drives the public
//// API. Raw SQL appears only to tamper with a stored row, which is the one way
//// to reach a state the ledger itself refuses to write.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import simplifile
import sqlight
import storage/exec_ledger.{
  type Key, type Ledger, Admitted, AllRetired, Closed, Closing, Created,
  Existing, Fenced, Found, Fresh, Key, Limits, Missing, Open, Rebound, Reopened,
  Standing, Terminal, Unknown, UnknownCleanup,
}
import storage/exec_ledger_acks_schema
import storage/exec_ledger_releases_schema
import storage/exec_ledger_schema
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
}

pub fn a_new_ledger_is_stamped_with_the_current_version_test() {
  let file = path("version")
  let _ledger = open_at(file)
  assert count(file, "PRAGMA user_version") == 3
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
  tamper(versioned, "PRAGMA user_version = 4;")
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

// A seeded generator for the property test, so a failure names its seed.
fn draw(seed: Int, bound: Int) -> #(Int, Int) {
  let next = { seed * 1_103_515_245 + 12_345 } % 2_147_483_648
  #({ next / 65_536 } % bound, next)
}

fn key_for(session: String, n: Int) -> Key {
  Key(
    session:,
    op: "op" <> int.to_string(n % 2),
    step: "step",
    source_index: n / 2,
  )
}

fn authorized(
  current: option.Option(exec_ledger.Scope),
  incarnation: Int,
  attach_token: BitArray,
) -> Bool {
  case current {
    Some(exec_ledger.Scope(state: Open, incarnation: stored, token: held, ..)) ->
      stored == incarnation && held == attach_token
    Some(_) | None -> False
  }
}

fn present(keys: List(Key), key: Key) -> Bool {
  list.contains(keys, key)
}

// Runs random sequences of every operation against a ledger and checks the two
// properties the design rests on after each step: a key is `Fresh` only while
// the ledger holds no row for it, and a request is admitted only under the
// scope's current incarnation and token.
fn exercise(
  ledger: Ledger,
  seed: Int,
  held: List(Key),
  acked: List(Key),
  remaining: Int,
) -> Nil {
  case remaining {
    0 -> Nil
    _ -> {
      let #(op, seed) = draw(seed, 20)
      let #(which, seed) = draw(seed, 2)
      let session = case which {
        0 -> "a"
        _ -> "b"
      }
      let assert Ok(current) = exec_ledger.scope(ledger, session)
        as "the scope reads"
      let #(skew, seed) = draw(seed, 4)
      let stored = case current {
        Some(scope) -> scope.incarnation
        None -> 0
      }
      let incarnation =
        stored
        + case skew {
          3 -> 2
          2 -> 1
          _ -> 0
        }
      let #(own, seed) = draw(seed, 2)
      let #(pooled, seed) = draw(seed, 3)
      let attach_token = case current, own {
        Some(scope), 0 -> scope.token
        _, _ -> token(pooled)
      }
      let #(slot, seed) = draw(seed, 4)
      let key = key_for(session, slot)
      let #(held, acked) = case op {
        0 | 1 | 2 | 3 -> {
          let attached =
            exec_ledger.attach(
              ledger,
              session,
              "/work",
              incarnation,
              attach_token,
              limits(),
            )

          // A reopen is a new incarnation, and the scope's tombstones go.
          case attached {
            Ok(exec_ledger.Attached(how: Reopened, ..)) ->
              forget(session, held, acked)
            Ok(exec_ledger.Attached(..)) | Error(_) -> #(held, acked)
          }
        }
        4 | 5 | 6 | 7 | 8 | 9 -> #(
          admit_checked(ledger, current, key, incarnation, attach_token, held),
          acked,
        )
        10 | 11 | 12 -> {
          let _finished = exec_ledger.finish(ledger, key, bytes("ok"))
          #(held, acked)
        }
        13 | 14 -> acknowledge(ledger, key, held, acked)
        15 -> {
          let _lost = exec_ledger.mark_unknown(ledger, key)
          #(held, acked)
        }
        16 -> {
          let _begun =
            exec_ledger.begin_close(ledger, session, "/work", incarnation)
          #(held, acked)
        }
        _ -> {
          // The two clean closes for every unclean one keep scopes reopening.
          let outcome = case op {
            19 -> UnknownCleanup(1)
            _ -> AllRetired
          }
          let ended =
            exec_ledger.finish_close(
              ledger,
              session,
              "/work",
              incarnation,
              outcome,
            )

          // A close with every child retired drops the scope's tombstones.
          case ended, outcome {
            Ok(Nil), AllRetired -> forget(session, held, acked)
            _, _ -> #(held, acked)
          }
        }
      }

      // Presence in the model and in the ledger agree for the key just used.
      let assert Ok(looked) = exec_ledger.query(ledger, key) as "the key reads"
      assert { looked == Missing } == !present(held, key)
      exercise(ledger, seed, held, acked, remaining - 1)
    }
  }
}

fn admit_checked(
  ledger: Ledger,
  before: option.Option(exec_ledger.Scope),
  key: Key,
  incarnation: Int,
  attach_token: BitArray,
  held: List(Key),
) -> List(Key) {
  let permitted = authorized(before, incarnation, attach_token)
  case
    exec_ledger.admit(
      ledger,
      key,
      incarnation,
      attach_token,
      "bash",
      8,
      limits(),
    )
  {
    Ok(Fresh) -> {
      assert permitted
      assert !present(held, key)
      [key, ..held]
    }
    Ok(Existing(_)) -> {
      assert permitted
      assert present(held, key)
      held
    }
    Error(_) -> {
      assert !permitted
      held
    }
  }
}

// An acknowledged key stays taken: its tombstone reads as `Acked` until the
// scope's incarnation changes.
fn acknowledge(
  ledger: Ledger,
  key: Key,
  held: List(Key),
  acked: List(Key),
) -> #(List(Key), List(Key)) {
  let assert Ok(before) = exec_ledger.query(ledger, key) as "the key reads"
  let assert Ok(Nil) = exec_ledger.ack(ledger, key) as "the ack succeeds"
  case before {
    Found(Terminal(_)) | Found(Unknown) -> #(held, [key, ..acked])
    Found(Admitted) | Found(exec_ledger.Acked) | Missing -> #(held, acked)
  }
}

// The scope's tombstones are gone, and so are the keys that only they held.
fn forget(
  session: String,
  held: List(Key),
  acked: List(Key),
) -> #(List(Key), List(Key)) {
  let gone = list.filter(acked, fn(key) { key.session == session })
  #(
    list.filter(held, fn(key) { !list.contains(gone, key) }),
    list.filter(acked, fn(key) { key.session != session }),
  )
}

pub fn random_sequences_never_admit_a_key_twice_or_under_a_stale_token_test() {
  list.each(upto(1, 40), fn(seed) {
    let ledger = open_at(":memory:")
    exercise(ledger, seed * 7919, [], [], 200)
    let assert Ok(Nil) = exec_ledger.close(ledger) as "the ledger closes"
    Nil
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
    "DROP TABLE scope_release; DROP TABLE call_ack; PRAGMA user_version = 1;",
  )
  let migrated = open_at(file)

  assert exec_ledger.releases(migrated, "s") == Ok([])
  assert exec_ledger.release(migrated, "s", 11)
    == Ok(exec_ledger.Released(
      workspace: "/work",
      incarnation: 0,
      was: exec_ledger.Closing,
    ))
  assert count(file, "PRAGMA user_version") == 3
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
  tamper(file, "DROP TABLE call_ack; PRAGMA user_version = 2;")
  let migrated = open_at(file)

  assert exec_ledger.ack(migrated, call(0)) == Ok(Nil)
  assert exec_ledger.query(migrated, call(0)) == Ok(Found(exec_ledger.Acked))
  assert count(file, "PRAGMA user_version") == 3
}
