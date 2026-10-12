//// A list of configured rows that is read when it is used, and not once when
//// the daemon starts (protocol-change/086, phase 2).
////
//// The `[executors.<name>]` and `[orchestrators.<name>]` tables are parsed
//// once, at start, into lists that the daemon passes around for its whole
//// life. In ledger mode those two tables also have rows that come from the
//// membership ledger, and the ledger changes while the daemon runs: an executor
//// that an operator enrolls a minute from now has to be usable by the next
//// `sessions.create`, and one that is revoked has to stop being offered. A list
//// cannot do that, so a part of the daemon that outlives one request holds a
//// `Roster` instead, and reads the rows at the moment it needs them.
////
//// A `Roster` is a function and nothing more. `fixed` wraps a list that never
//// changes, which is every static-mode daemon and every test that has no
//// ledger, so the same code serves both modes and the reader of a call site
//// sees one shape.
////
//// ## Where a read happens
////
//// A read of a ledger-backed roster asks the ledger process for its state
//// (`client/ledger_rows`), so it costs one process call. Callers read once for
//// each decision they make and use the list they got for that whole decision.
//// They never keep the list across requests, which would turn a roster back
//// into a snapshot taken at the first read.

/// Rows of one kind, read when they are needed.
pub opaque type Roster(row) {
  Roster(read: fn() -> List(row))
}

/// A roster of rows that never change.
///
/// ## Examples
///
/// ```gleam
/// assert roster.rows(roster.fixed([1, 2])) == [1, 2]
/// ```
pub fn fixed(rows: List(row)) -> Roster(row) {
  Roster(read: fn() { rows })
}

/// A roster whose rows are whatever `read` answers when it is asked. `read` is
/// called from the process that needs the rows, so it must not block for long
/// and must not depend on being called from one particular process.
///
/// ## Examples
///
/// ```gleam
/// let roster = roster.reading(fn() { current_rows() })
/// ```
pub fn reading(read: fn() -> List(row)) -> Roster(row) {
  Roster(read:)
}

/// The rows as they are at this moment.
///
/// ## Examples
///
/// ```gleam
/// assert roster.rows(roster.fixed([])) == []
/// ```
pub fn rows(roster: Roster(row)) -> List(row) {
  roster.read()
}
