//// The pass of the delegate session's second drainer instance: what a session
//// sends its parent's orchestrator, and when (protocol-change/084, phase 2).
////
//// A delegate session runs two instances of the outbox drainer
//// (`client/peer_outbox_drain`). The first is the peer-mail one every session
//// has. The second is given this pass, and it sends what the session's children
//// owe their parent: the mail rows in `client/delegate_outbox` and the newest
//// glance of each child.
////
//// ## Nothing here dials
////
//// The pass asks `Laptop.connected` and, if the laptop's node is not connected,
//// sends nothing and reports what it still owes. The laptop may sit behind a
//// NAT, so the remote has no address it could reach, and a dial could only fail
//// and take a connect timeout with it. The laptop's link keeper holds the
//// connection up while its parent has a child here
//// (`client/remote/link_keeper`), so the pass sends when the laptop is there and
//// costs one read of the connection set when it is not.
////
//// ## What the pass owes
////
//// While a mail row is pending, or any child has a run, the pass is `Owed` and
//// the drainer ticks at its fixed interval. The second reason is why a pass does
//// not stop when it has sent everything: a glance can appear at any moment and
//// nothing rings the drainer for it. When no row is pending and no child runs it
//// is `Clear` and the drainer goes idle with no timer. The Agency rings it when
//// it writes a row and when it admits a child.
////
//// ## Flow
////
//// `pass` → `send_if_connected` → `mail_step` → `progress_step`
////
//// 1. `pass` reads the rows once through the session's runtime, which it fetches
////    afresh each time because the drainer outlives a restart of the runtime.
//// 2. `send_if_connected` sends only while the laptop's node is connected, and
////    says whether anything is still unsent.
//// 3. `mail_step` sends each pending row and settles it on an answer. A laptop
////    that does not answer is not asked again in the same pass.
//// 4. `progress_step` sends the newest unacknowledged glance of each child, and
////    stops at the first silence.

import client/delegate_outbox.{type Laptop, type Mail, type SpawnerLink, Mail}
import client/peer_outbox_drain.{type Backlog, Clear, Owed, Quick}
import client/remote_mail
import client/remote_spawn
import gleam/list
import runtime/api
import telemetry/field
import telemetry/log.{type Logger}

// What a pass owes while a row is pending, the laptop is silent or a child may
// still glance. The pace is the drainer's fixed interval, whatever kept the pass
// from finishing: a laptop that did not answer may be back by the next tick.
const owed = Owed(Quick)

/// The pass: sends the mail that is owed and the newest glance of each child,
/// only while the laptop's node is connected, and says whether anything is still
/// owed.
///
/// `running` says whether any child of the session has a run, and is asked once
/// a pass. `runtime` is asked at each pass, and a session whose runtime is not up
/// yet has nothing to read and reports owed.
///
/// ## Examples
///
/// ```gleam
/// // peer_outbox_drain.over(delegate_drain.pass(runtime_supplier, running, link, laptop, logger), after)
/// ```
pub fn pass(
  runtime: fn() -> Result(api.Runtime, Nil),
  running: fn() -> Bool,
  link: SpawnerLink,
  laptop: Laptop,
  logger: Logger,
) -> fn() -> Backlog {
  fn() {
    case runtime() {
      Error(Nil) -> owed
      Ok(open) ->
        case delegate_outbox.mail_rows(open) {
          Error(reason) -> {
            log.warn(logger, "delegate_drain.unreadable", [
              field.text("reason", reason),
            ])
            owed
          }
          Ok(rows) -> {
            let pending =
              list.filter(rows, fn(row) {
                row.1.state == delegate_outbox.Pending
              })
            owed_if(
              send_if_connected(open, link, laptop, logger, pending)
              || running(),
            )
          }
        }
    }
  }
}

// Sends what is owed when the laptop's node is connected, and answers whether
// anything is still unsent. A laptop that is away is not asked, and what is
// pending stays owed.
fn send_if_connected(
  runtime: api.Runtime,
  link: SpawnerLink,
  laptop: Laptop,
  logger: Logger,
  pending: List(#(String, Mail)),
) -> Bool {
  case laptop.connected() {
    False -> pending != []
    True -> {
      let #(left, silent) = mail_step(runtime, link, laptop, logger, pending)
      case silent {
        True -> True
        False -> left || progress_step(runtime, link, laptop, logger)
      }
    }
  }
}

fn owed_if(condition: Bool) -> Backlog {
  case condition {
    True -> owed
    False -> Clear
  }
}

// --- mail ----------------------------------------------------------------------

// Sends each pending row in key order and settles it on an answer. Answers
// whether any row is still pending and whether the laptop went silent, which
// ends the pass: every row owed to a laptop that did not answer would wait out
// the same deadline to learn the same thing.
fn mail_step(
  runtime: api.Runtime,
  link: SpawnerLink,
  laptop: Laptop,
  logger: Logger,
  rows: List(#(String, Mail)),
) -> #(Bool, Bool) {
  case rows {
    [] -> #(False, False)
    [#(key, row), ..rest] -> {
      let parent =
        remote_spawn.Parent(
          session: link.parent_session,
          strand: row.parent_strand,
        )
      case laptop.mail(parent, row.child, row.id, row.text) {
        // Silence leaves the row pending, and the remaining rows with it.
        Error(Nil) -> #(True, True)

        Ok(Ok(receipt)) -> {
          settle(
            runtime,
            logger,
            key,
            Mail(..row, state: delegate_outbox.Answered(receipt)),
          )
          mail_step(runtime, link, laptop, logger, rest)
        }

        // The parent session is closed, or the laptop could not reach its own
        // store: this row stays pending and the others are still tried, because
        // they may be for a parent that is open.
        Ok(Error(remote_mail.ParentSessionNotOpen))
        | Ok(Error(remote_mail.Busy(..))) -> {
          let #(_left, silent) = mail_step(runtime, link, laptop, logger, rest)
          #(True, silent)
        }

        // Any other refusal is the laptop saying it will never admit the
        // message, which is an answer, so the row settles.
        Ok(Error(refusal)) -> {
          settle(
            runtime,
            logger,
            key,
            Mail(
              ..row,
              state: delegate_outbox.Refused(remote_mail.describe_refusal(
                refusal,
              )),
            ),
          )
          mail_step(runtime, link, laptop, logger, rest)
        }
      }
    }
  }
}

// Writes the answer on the row. A write that fails leaves the row pending, so
// the next pass sends the mail again and the laptop answers from its receipt.
fn settle(runtime: api.Runtime, logger: Logger, key: String, row: Mail) -> Nil {
  case delegate_outbox.settle_mail(runtime, key, row) {
    Ok(Nil) ->
      log.info(logger, "delegate_drain.settled", [
        field.text("message_id", row.id),
      ])
    Error(reason) ->
      log.warn(logger, "delegate_drain.unsettled", [
        field.text("message_id", row.id),
        field.text("reason", reason),
      ])
  }
}

// --- progress ------------------------------------------------------------------

// Sends the newest glance of each child that the laptop has not acknowledged.
// Answers whether any is still unsent: a glance the laptop did not answer for, a
// parent that was closed, or a read that failed. The first silence ends the step.
fn progress_step(
  runtime: api.Runtime,
  link: SpawnerLink,
  laptop: Laptop,
  logger: Logger,
) -> Bool {
  case delegate_outbox.unsent_glances(runtime) {
    Error(reason) -> {
      log.warn(logger, "delegate_drain.glances_unreadable", [
        field.text("reason", reason),
      ])
      True
    }
    Ok(unsent) -> send_glances(runtime, link, laptop, logger, unsent)
  }
}

fn send_glances(
  runtime: api.Runtime,
  link: SpawnerLink,
  laptop: Laptop,
  logger: Logger,
  unsent: List(delegate_outbox.Unsent),
) -> Bool {
  case unsent {
    [] -> False
    [next, ..rest] -> {
      let parent =
        remote_spawn.Parent(
          session: link.parent_session,
          strand: next.parent_strand,
        )
      case laptop.progress(parent, next.child, next.glance) {
        Error(Nil) -> True

        // The parent session is closed or the laptop is busy: the glance stays
        // unacknowledged and the next pass sends the newest one again.
        Ok(Error(remote_mail.ParentSessionNotOpen))
        | Ok(Error(remote_mail.Busy(..))) -> {
          let _left = send_glances(runtime, link, laptop, logger, rest)
          True
        }

        // Answered, or refused for good. Either way the laptop will not be asked
        // about this glance again.
        Ok(Ok(Nil)) | Ok(Error(_)) -> {
          case
            delegate_outbox.acknowledge(
              runtime,
              next.child.strand,
              next.glance.at,
            )
          {
            Ok(Nil) -> Nil
            Error(reason) ->
              log.warn(logger, "delegate_drain.progress_unrecorded", [
                field.text("strand", next.child.strand),
                field.text("reason", reason),
              ])
          }
          send_glances(runtime, link, laptop, logger, rest)
        }
      }
    }
  }
}
