//// Keeping the operator's copy of the ledger and a daemon's in step
//// (protocol-change/086, design note section 6.2).
////
//// `enroll`, `revoke` and `renew` sign against the operator's copy of the
//// ledger, in the authority's directory, and then hand the new entry to a
//// daemon. Two things can be wrong between the copy and the daemon, and this
//// module is the part of the commands that deals with both.
////
//// - The daemon is ahead. Another machine signed an entry the copy never saw,
////   which happens when the key and a copy are restored on a second machine.
////   An entry signed against the stale copy would take a sequence number the
////   daemon's ledger has used, and the deployment would fork. `catch_up` pulls
////   what the daemon has, verifies each line against the chain, and appends it
////   to the copy first.
//// - The two disagree. The daemon holds an entry at a sequence number the copy
////   has, with another identity. That is a fork already, and the command stops
////   with the sequence number.
////
//// The daemon is a record of three functions rather than a socket, so the
//// commands run against a real daemon, and the tests against a ledger process
//// in the same VM, through the same code. Everything it returns went through
//// the total decoders of `client/ledger_control`.
////
//// ## Order of work
////
//// 1. `catch_up` compares the heads and pulls what the copy lacks.
//// 2. The caller signs and appends one entry to the copy.
//// 3. `hand_over` sends the daemon every line after its head, which is the new
////    entry and also anything an earlier offline command left in the copy.
//// 4. `await` polls the daemon's status until every member holds the head, or
////    the wait ends.

import client/ledger_control.{type AppliedView, type PageView, type StatusView}
import client/ledger_operator
import client/membership_entry.{type Verifier}
import client/membership_ledger.{type Ledger}
import client/membership_store.{type Store}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import weft/poll

/// A daemon's three ledger commands.
pub type Daemon {
  Daemon(
    /// `ledger.status`.
    status: fn() -> Result(StatusView, String),
    /// `ledger.entries` after a sequence number, at most a limit of lines.
    entries: fn(Int, Int) -> Result(PageView, String),
    /// `ledger.append` of a page of lines.
    append: fn(List(String)) -> Result(AppliedView, String),
  )
}

/// Why the copy and the daemon could not be brought together.
pub type Mismatch {
  /// The daemon's ledger belongs to another deployment.
  OtherDeployment

  /// The daemon holds a different entry at this sequence number, or a history
  /// that does not extend the copy's.
  Forked(seq: Int)

  /// The daemon answered and the answer could not be used.
  Unusable(reason: String)
}

/// A sentence for a mismatch.
///
/// ## Examples
///
/// ```gleam
/// ledger_sync.describe(ledger_sync.Forked(4))
/// ```
pub fn describe(mismatch: Mismatch) -> String {
  case mismatch {
    OtherDeployment ->
      "the daemon runs another deployment's ledger than this authority's"
    Forked(seq:) ->
      "the daemon's ledger and this copy hold different entries at or "
      <> "before sequence number "
      <> int.to_string(seq)
      <> "; one of them is a fork, and nothing was signed"
    Unusable(reason:) -> "the daemon's answer could not be used: " <> reason
  }
}

/// Brings the copy up to the daemon's head and checks that the two agree up to
/// the lower of the heads. Returns the copy and its ledger, extended by any
/// lines the daemon had that the copy lacked.
///
/// ## Examples
///
/// ```gleam
/// ledger_sync.catch_up(store, ledger, verifier, daemon, status)
/// // -> Ok(#(store, ledger))
/// ```
pub fn catch_up(
  store: Store,
  ledger: Ledger,
  verifier: Verifier,
  daemon: Daemon,
  status: StatusView,
) -> Result(#(Store, Ledger), Mismatch) {
  use Nil <- result.try(
    case status.deployment == membership_ledger.deployment(ledger) {
      True -> Ok(Nil)
      False -> Error(OtherDeployment)
    },
  )
  let ours = membership_ledger.head(ledger)
  case status.head.seq > ours.seq {
    True -> pull(store, ledger, verifier, daemon, status.head.seq)
    False -> {
      // At or behind: the daemon's head must be the copy's entry at that
      // sequence number.
      case membership_ledger.id_at(ledger, status.head.seq) {
        Ok(id) ->
          case membership_entry.id_to_hex(id) == status.head.id {
            True -> Ok(#(store, ledger))
            False -> Error(Forked(status.head.seq))
          }
        Error(Nil) -> Error(Forked(status.head.seq))
      }
    }
  }
}

// Pulls pages after the copy's head until it reaches the daemon's, applying
// each line through the fold. A line that does not chain from the copy's head is
// a history that does not extend it.
fn pull(
  store: Store,
  ledger: Ledger,
  verifier: Verifier,
  daemon: Daemon,
  target: Int,
) -> Result(#(Store, Ledger), Mismatch) {
  let have = membership_ledger.head(ledger).seq
  case have >= target {
    True -> Ok(#(store, ledger))
    False -> {
      use page <- result.try(
        daemon.entries(have, 64) |> result.map_error(Unusable),
      )
      case page.lines {
        [] ->
          Error(Unusable(
            "the daemon sent no lines after sequence " <> int.to_string(have),
          ))
        lines -> {
          use #(store, ledger) <- result.try(
            list.try_fold(lines, #(store, ledger), fn(state, line) {
              apply_line(state.0, state.1, verifier, line)
            }),
          )
          pull(store, ledger, verifier, daemon, target)
        }
      }
    }
  }
}

fn apply_line(
  store: Store,
  ledger: Ledger,
  verifier: Verifier,
  line: String,
) -> Result(#(Store, Ledger), Mismatch) {
  let seq = membership_ledger.head(ledger).seq + 1
  use signed <- result.try(
    membership_entry.read(bit_array.from_string(line), verifier)
    |> result.replace_error(Unusable("a line the daemon sent does not verify")),
  )
  use outcome <- result.try(
    membership_ledger.apply(ledger, signed)
    |> result.replace_error(Forked(seq)),
  )
  case outcome {
    membership_ledger.Applied(ledger: next, entry:) ->
      membership_store.append(store, entry)
      |> result.map(fn(appended) { #(appended, next) })
      |> result.map_error(fn(error) {
        let membership_store.Unwritable(reason:) = error
        Unusable("this copy cannot be written: " <> reason)
      })
    membership_ledger.Duplicate | membership_ledger.Gap(_) ->
      Error(Unusable("the daemon sent lines out of order"))
  }
}

/// Sends the daemon every line of the copy after sequence number `after`, in
/// pages. Returns the daemon's head after the last page, or `None` when there
/// was nothing to send.
///
/// ## Examples
///
/// ```gleam
/// ledger_sync.hand_over(store, daemon, 3) // -> Ok(Some(AppliedView(..)))
/// ```
pub fn hand_over(
  store: Store,
  daemon: Daemon,
  after: Int,
) -> Result(Option(AppliedView), String) {
  let lines =
    membership_store.lines_after(
      store,
      after,
      membership_ledger.max_entries,
      membership_store.max_file_bytes,
    )
    |> list.filter_map(bit_array.to_string)
  list.try_fold(ledger_control.pages(lines), None, fn(_, page) {
    daemon.append(page) |> result.map(Some)
  })
}

/// Polls the daemon's status until every member reports the entry at `seq`, or
/// `within_ms` passes. Returns the last status it read and whether the wait
/// found every member confirmed. A status that cannot be read ends the wait
/// with what the last good read said.
///
/// ## Examples
///
/// ```gleam
/// ledger_sync.await(daemon, 4, 10_000, first_status)
/// ```
pub fn await(
  daemon: Daemon,
  seq: Int,
  within_ms: Int,
  last: StatusView,
) -> #(StatusView, Bool) {
  let verdict =
    poll.fold_until(
      clock: poll.monotonic(),
      within: within_ms,
      every: poll.Fixed(250),
      from: last,
      attempt: fn(previous) {
        case daemon.status() {
          Error(_) -> poll.Pending(previous)
          Ok(status) ->
            case
              ledger_operator.all_confirmed(ledger_operator.confirmations(
                status,
                seq,
              ))
            {
              True -> poll.Settled(status)
              False -> poll.Pending(status)
            }
        }
      },
    )
  case verdict {
    poll.Answer(status) -> #(status, True)
    poll.RanOut(status) -> #(status, False)
    poll.Failure(_) -> #(last, False)
  }
}
