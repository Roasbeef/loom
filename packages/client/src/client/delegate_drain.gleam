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
//// ## Requests for more authority
////
//// A child that is refused by its sandbox and whose spawner has an approval
//// ceiling parks on the box's escalation record, and the spawner's operator is
//// asked (protocol-change/089). `question_step` is the part of the pass that
//// asks. Each request row names a record and the `seq` it was raised at, and the
//// pass sends the record as it is when it sends. A row ends in one of four ways:
//// a newer raise replaced it, its answer window closed
//// (`delegate_outbox.answer_window_ms` past the call's park, because a decision
//// after the park still reaches the child), the record was decided and the
//// decided state was sent, or the laptop said it would never admit the message. A row whose record is still pending and was acknowledged waits, and
//// the pass stays owed for it, because the decision can come at any moment and
//// nothing rings the drainer for it.
////
//// ## Flow
////
//// `pass` → `send_if_connected` → `mail_step` → `progress_step` →
//// `question_step`
////
//// 1. `pass` reads the rows once through the session's runtime, which it fetches
////    afresh each time because the drainer outlives a restart of the runtime.
//// 2. `send_if_connected` sends only while the laptop's node is connected, and
////    says whether anything is still unsent.
//// 3. `mail_step` sends each pending row and settles it on an answer. A laptop
////    that does not answer is not asked again in the same pass.
//// 4. `progress_step` sends the newest unacknowledged glance of each child, and
////    stops at the first silence.
//// 5. `question_step` sends each request that is pending and not yet
////    acknowledged, and the decided state of each that has been decided.

import client/approval_ceiling
import client/delegate_outbox.{type Laptop, type Mail, type SpawnerLink, Mail}
import client/escalation_view
import client/peer_outbox_drain.{type Backlog, Clear, Owed, Quick}
import client/protocol
import client/remote_mail
import client/remote_spawn
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import runtime/api
import runtime/escalation as durable
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
  now: fn() -> Int,
  link: SpawnerLink,
  laptop: Laptop,
  logger: Logger,
) -> fn() -> Backlog {
  fn() {
    // This branch resolves runtime before the operation continues.
    case runtime() {
      Error(Nil) -> owed
      Ok(open) ->
        // This branch resolves delegate_outbox mail_rows open before the operation continues.
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
              send_if_connected(open, link, laptop, logger, pending, now())
              || running(),
            )
          }
        }
    }
  }
}

/// Drains pending mail, progress glances, and authority questions to the laptop if connected.
fn send_if_connected(
  runtime: api.Runtime,
  link: SpawnerLink,
  laptop: Laptop,
  logger: Logger,
  pending: List(#(String, Mail)),
  now: Int,
) -> Bool {
  // Check connectivity to the remote laptop before processing queued items.
  case laptop.connected() {
    False -> pending != [] || questions_waiting(runtime, now)
    True -> {
      let #(left, silent) = mail_step(runtime, link, laptop, logger, pending)
      let asking = question_step(runtime, link, laptop, logger, now)

      // Halt step if the laptop went silent during mail delivery.
      case silent {
        True -> True
        False -> {
          let glancing = progress_step(runtime, link, laptop, logger)
          left || glancing || asking
        }
      }
    }
  }
}

/// Owed if keeps this client decision explicit for its callers.
fn owed_if(condition: Bool) -> Backlog {
  // This branch resolves condition before the operation continues.
  case condition {
    True -> owed
    False -> Clear
  }
}

// --- mail ----------------------------------------------------------------------

/// Drains queued mail rows sequentially across active delegate strands.
fn mail_step(
  runtime: api.Runtime,
  link: SpawnerLink,
  laptop: Laptop,
  logger: Logger,
  rows: List(#(String, Mail)),
) -> #(Bool, Bool) {
  // Process queued mail rows recursively until empty.
  case rows {
    [] -> #(False, False)
    [#(key, row), ..rest] -> {
      let parent =
        remote_spawn.Parent(
          session: link.parent_session,
          strand: row.parent_strand,
        )

      // Transmit the mail message to the laptop over the spawner link.
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

/// Persists the settlement receipt or refusal state for a delivered mail row.
fn settle(runtime: api.Runtime, logger: Logger, key: String, row: Mail) -> Nil {
  // This branch resolves delegate_outbox settle_mail runtime key row before the operation continues.
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

/// Inspects unsent progress glances and flushes them to the remote laptop.
fn progress_step(
  runtime: api.Runtime,
  link: SpawnerLink,
  laptop: Laptop,
  logger: Logger,
) -> Bool {
  // Retrieve unsent glances from outbox storage.
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

/// Transmits a batch of progress glances to the laptop in sequence.
fn send_glances(
  runtime: api.Runtime,
  link: SpawnerLink,
  laptop: Laptop,
  logger: Logger,
  unsent: List(delegate_outbox.Unsent),
) -> Bool {
  // Recursively transmit unacknowledged glances.
  case unsent {
    [] -> False
    [next, ..rest] -> {
      let parent =
        remote_spawn.Parent(
          session: link.parent_session,
          strand: next.parent_strand,
        )

      // Deliver progress glance notification to the spawner laptop.
      case laptop.progress(parent, next.child, next.glance) {
        Error(Nil) -> True

        // The parent session is closed or the laptop is busy: the glance stays
        // unacknowledged and the next pass sends the newest one again.
        Ok(Error(remote_mail.ParentSessionNotOpen))
        | Ok(Error(remote_mail.Busy(..))) -> {
          // This branch resolves the input state before the operation continues.
          let _left = send_glances(runtime, link, laptop, logger, rest)
          True
        }

        // Answered, or refused for good. Either way the laptop will not be asked
        // about this glance again.
        Ok(Ok(Nil)) | Ok(Error(_)) -> {
          // Record progress acknowledgement timestamp in outbox storage.
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

// --- requests for more authority ------------------------------------------------

// Whether a request row is still worth keeping the pass alive for, when the
// laptop is away and nothing can be sent. A row whose answer window has closed
// will be dropped when the laptop is back, and does not keep the pass ticking
// until then.
/// Questions waiting keeps this client decision explicit for its callers.
fn questions_waiting(runtime: api.Runtime, now: Int) -> Bool {
  // This branch resolves delegate_outbox question_rows runtime before the operation continues.
  case delegate_outbox.question_rows(runtime) {
    Ok(rows) -> list.any(rows, fn(row) { row.1.until > now })
    Error(_) -> True
  }
}

/// Drains pending escalation questions and forwards decisions or status updates.
fn question_step(
  runtime: api.Runtime,
  link: SpawnerLink,
  laptop: Laptop,
  logger: Logger,
  now: Int,
) -> Bool {
  // Load pending question rows from outbox.
  case delegate_outbox.question_rows(runtime) {
    Error(reason) -> {
      log.warn(logger, "delegate_drain.questions_unreadable", [
        field.text("reason", reason),
      ])
      True
    }
    Ok(rows) ->
      list.fold(rows, False, fn(waiting, row) {
        let still = one_question(runtime, link, laptop, logger, now, row)
        waiting || still
      })
  }
}

/// Evaluates and dispatches a single authority question row.
fn one_question(
  runtime: api.Runtime,
  link: SpawnerLink,
  laptop: Laptop,
  logger: Logger,
  now: Int,
  entry: #(String, delegate_outbox.Question),
) -> Bool {
  let #(key, row) = entry
  let drop = fn() {
    // Drop obsolete question row from outbox storage.
    case delegate_outbox.drop_question(runtime, key) {
      Ok(Nil) -> False
      Error(reason) -> {
        log.warn(logger, "delegate_drain.question_undropped", [
          field.text("reason", reason),
        ])
        True
      }
    }
  }

  // Inspect durable escalation cell to verify current record status.
  case api.escalation_cell(runtime, row.id) {
    Error(_) -> drop()
    Ok(cell) ->
      // This branch resolves cell record status before the operation continues.
      case cell.record.status {
        durable.Pending ->
          pending_question(runtime, link, laptop, logger, now, key, row, cell)
          |> result.lazy_unwrap(drop)
        durable.Approved | durable.Rejected | durable.Consumed -> {
          let delivered =
            send_record(link, laptop, row, escalation_record(link, cell))

          // Check delivery result to drop settled question or keep waiting.
          case delivered {
            Delivered | Final -> drop()
            Waiting -> True
          }
        }
      }
  }
}

/// Handles an escalation record that remains in pending state.
fn pending_question(
  runtime: api.Runtime,
  link: SpawnerLink,
  laptop: Laptop,
  logger: Logger,
  now: Int,
  key: String,
  row: delegate_outbox.Question,
  cell: api.EscalationCell,
) -> Result(Bool, Nil) {
  // This branch resolves cell seq row seq now row until before the operation continues.
  case cell.seq > row.seq || now >= row.until {
    True -> Error(Nil)
    False ->
      // This branch resolves row sending before the operation continues.
      case row.sending {
        delegate_outbox.Acknowledged -> Ok(True)
        delegate_outbox.NotAcknowledged ->
          Ok(send_question(runtime, link, laptop, logger, key, row, cell))
      }
  }
}

/// Transmits a pending escalation request and records acknowledgment on delivery.
fn send_question(
  runtime: api.Runtime,
  link: SpawnerLink,
  laptop: Laptop,
  logger: Logger,
  key: String,
  row: delegate_outbox.Question,
  cell: api.EscalationCell,
) -> Bool {
  // Attempt transmission of escalation record to the remote laptop.
  case send_record(link, laptop, row, escalation_record(link, cell)) {
    Waiting -> True
    Final -> {
      // Drop permanently refused question from outbox.
      case delegate_outbox.drop_question(runtime, key) {
        Ok(Nil) -> Nil
        Error(reason) ->
          log.warn(logger, "delegate_drain.question_undropped", [
            field.text("reason", reason),
          ])
      }

      False
    }
    Delivered -> {
      // Mark question row as acknowledged after successful delivery.
      case
        delegate_outbox.settle_question(
          runtime,
          key,
          delegate_outbox.Question(..row, sending: delegate_outbox.Acknowledged),
        )
      {
        Ok(Nil) -> Nil
        Error(reason) ->
          log.warn(logger, "delegate_drain.question_unsettled", [
            field.text("reason", reason),
          ])
      }

      True
    }
  }
}

// What the laptop said to one record.
type Sent {
  // It holds the record or a newer one.
  Delivered

  // It said it would never admit the record, so asking again is pointless.
  Final

  // Silence, or a refusal worth asking again about.
  Waiting
}

/// Sends an escalation record to the remote laptop and maps the transport outcome.
fn send_record(
  link: SpawnerLink,
  laptop: Laptop,
  row: delegate_outbox.Question,
  record: protocol.EscalationRecord,
) -> Sent {
  let parent =
    remote_spawn.Parent(session: link.parent_session, strand: row.parent_strand)

  // Dispatch escalation RPC to the laptop.
  case laptop.escalation(parent, row.child, record) {
    Error(Nil) -> Waiting
    Ok(Ok(Nil)) -> Delivered
    Ok(Error(refusal)) ->
      // This branch resolves remote_mail retryable refusal before the operation continues.
      case remote_mail.retryable(refusal) {
        True -> Waiting
        False -> Final
      }
  }
}

/// Prepares a wire-format escalation record bounded by the spawner approval ceiling.
fn escalation_record(
  link: SpawnerLink,
  cell: api.EscalationCell,
) -> protocol.EscalationRecord {
  let shown = escalation_view.view(cell.record, cell.seq)

  // Extract requested grants from denial detail if present.
  let wanted = case shown.denial {
    Some(denial) -> denial.wanted
    None -> []
  }

  protocol.EscalationRecord(
    ..shown,
    // This branch resolves link ceiling before the operation continues.
    admitted: Some(case link.ceiling {
      Some(ceiling) -> approval_ceiling.admitted(ceiling, wanted)
      None -> []
    }),
  )
}
