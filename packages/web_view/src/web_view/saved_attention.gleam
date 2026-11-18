//// What the catalogue remembers of a session's attention, as Home is handed
//// it (protocol-change/122).
////
//// Home's live reads (`sessions.activity` and the attention feed) cover only
//// resident sessions, and after a daemon restart every session is saved. The
//// catalogue therefore keeps one summary row for each session, written when an
//// approval, ask or find changes, and the daemon hands the rows for a listing's
//// sessions to the page beside its activity read (`server.home_saved_attention`).
////
//// A row is a cache of the session's own records, never the truth, so a page
//// that draws it must say it came from the catalogue. A session with no row is
//// one that was never read, which is different from one whose row holds zeros,
//// and this module has no value for the first: the daemon's read leaves such a
//// session out, and the page counts the sessions it listed that are missing.
////
//// This module holds the row's type and the one constructor that builds it.
//// The page's view of it arrives in a later slice.

import gleam/option.{type Option}

/// One saved session's summary row.
///
/// Constructor invariants: every count is zero or more, which `from_row`
/// checks, so a page that sums rows never subtracts. `oldest_open_at` is Unix
/// milliseconds of the oldest open ask or find and is `None` when there is
/// none; it says nothing of approvals, which carry no raise time.
pub type Saved {
  Saved(
    /// The session the row summarizes.
    session_id: String,
    /// Escalations awaiting a decision when the row was written.
    pending_approvals: Int,
    /// Open asks routed to the owner when the row was written.
    open_asks: Int,
    /// Open finds when the row was written.
    open_finds: Int,
    /// Unix milliseconds of the oldest open ask or find, if any.
    oldest_open_at: Option(Int),
    /// Unix milliseconds on the daemon's clock when the row was written.
    updated_at: Int,
  )
}

/// Builds a row, refusing a negative count or time.
///
/// The catalogue's table refuses the same values, so a refusal here means the
/// row was damaged on disk, and the caller leaves the session out as a session
/// that was not read.
///
/// ## Examples
///
/// ```gleam
/// assert saved_attention.from_row("a", 1, 0, 0, None, 5)
///   == Ok(saved_attention.Saved("a", 1, 0, 0, None, 5))
/// assert saved_attention.from_row("a", -1, 0, 0, None, 5) == Error(Nil)
/// ```
pub fn from_row(
  session_id session_id: String,
  pending_approvals pending_approvals: Int,
  open_asks open_asks: Int,
  open_finds open_finds: Int,
  oldest_open_at oldest_open_at: Option(Int),
  updated_at updated_at: Int,
) -> Result(Saved, Nil) {
  let counts_ok = pending_approvals >= 0 && open_asks >= 0 && open_finds >= 0
  let times_ok = updated_at >= 0 && option.unwrap(oldest_open_at, 0) >= 0

  // The row is built only when every figure is one the table could hold.
  case counts_ok && times_ok {
    True ->
      Ok(Saved(
        session_id:,
        pending_approvals:,
        open_asks:,
        open_finds:,
        oldest_open_at:,
        updated_at:,
      ))
    False -> Error(Nil)
  }
}
